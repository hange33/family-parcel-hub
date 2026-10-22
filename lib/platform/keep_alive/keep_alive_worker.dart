/// 后台保活 Worker（WorkManager 后台 isolate 入口）
///
/// App 进程被杀后，WorkManager 定时唤醒本 isolate，对淘宝/京东执行纯 HTTP
/// 续期。拼多多心跳依赖 WebView，后台无 Activity 无法运行，故不在表内。
///
/// 调度闸门与前台 `KeepAliveService` 共用同一份落盘状态（`KeepAliveStore`），
/// 因此前后台不会各自发一轮重复心跳；本 isolate 只写标量键，绝不碰历史记录。
///
/// 判定失效后会尽力推送一次本地通知；是否成功都会由前台在下次检查时兜底。
library;

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/engine/keep_alive_plan.dart';
import '../storage/keep_alive_store.dart';
import '../storage/platform_auth_store.dart';
import 'keep_alive_notifier.dart';
import 'platform_heartbeat.dart';

/// 后台可续期平台 → 心跳实现。
///
/// 这是一份显式的 registry：不在表内的平台（拼多多）不可在后台续期，
/// 领域知识由表结构表达，而非散落的 if/else。
final Map<String, PlatformHeartbeat> _backgroundHeartbeats = {
  'taobao': TaobaoHeartbeat(),
  'jd': JdHeartbeat(),
};

/// WorkManager 回调入口（顶层函数，@pragma 保证 release 下不被 tree-shake）。
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      await _runBackgroundKeepAlive();
      return true;
    } catch (e) {
      debugPrint('[KeepAliveWorker] task error: $e');
      return false;
    }
  });
}

/// 后台续期主体：初始化存储后，对每个后台可续期平台发送心跳并落盘结果。
Future<void> _runBackgroundKeepAlive() async {
  // 后台 isolate 独立于主进程，需重新初始化存储路径与解密通道。
  await Hive.initFlutter();
  await PlatformAuthStore.initialize();
  await KeepAliveStore.initialize();

  final authStore = PlatformAuthStore();
  final store = KeepAliveStore();
  await store.loadIntoCache();

  if (!store.enabled) {
    debugPrint('[KeepAliveWorker] keep-alive disabled by user, skip');
    return;
  }

  final now = DateTime.now();

  for (final entry in _backgroundHeartbeats.entries) {
    final platform = entry.key;

    if (!store.platformEnabled(platform)) {
      debugPrint('[KeepAliveWorker] Skip $platform: disabled');
      continue;
    }
    if (!authStore.isBound(platform)) {
      debugPrint('[KeepAliveWorker] Skip $platform: not bound');
      continue;
    }
    final cookies = authStore.getCookies(platform);
    if (cookies == null || cookies.trim().isEmpty) {
      debugPrint('[KeepAliveWorker] Skip $platform: no cookies');
      continue;
    }

    // 与前台共用闸门：前面刚续期过就不重复发
    final nextTime = store.nextAt(platform);
    if (nextTime != null && now.isBefore(nextTime)) {
      debugPrint(
          '[KeepAliveWorker] Skip $platform: next keep-alive in ${nextTime.difference(now).inMinutes} min');
      continue;
    }

    debugPrint('[KeepAliveWorker] Refresh $platform...');
    HeartbeatResult result;
    try {
      result = await entry.value.performHeartbeat(cookies);
    } catch (e) {
      debugPrint('[KeepAliveWorker] $platform error: $e');
      continue;
    }

    // 跳过既不是成功也不是失败，不得据此清失效标记或累计失败
    if (result.skipped) {
      debugPrint('[KeepAliveWorker] $platform skipped: ${result.errorMessage}');
      continue;
    }

    final interval = KeepAlivePlan.calculateInterval(_cookieAge(authStore, platform, now));

    if (result.success) {
      // 淘宝令牌轮换已在 TaobaoHeartbeat 内部落盘。
      await authStore.setExpired(platform, false);
      await store.setLast(platform, DateTime.now());
      await store.setFailureCount(platform, 0);
      await store.setLastNotifiedAt(platform, null);
      debugPrint('[KeepAliveWorker] $platform refreshed');
    } else {
      final failureCount = store.failureCount(platform) + 1;
      await store.setFailureCount(platform, failureCount);
      if (result.isAuthFailure) {
        await authStore.setExpired(platform, true);
        debugPrint('[KeepAliveWorker] $platform login expired');
      } else if (failureCount >= KeepAlivePlan.failureThreshold) {
        await authStore.setExpired(platform, true);
        debugPrint('[KeepAliveWorker] $platform login expired ($failureCount failures)');
      } else {
        debugPrint('[KeepAliveWorker] $platform refresh failed: ${result.errorMessage}');
      }
    }

    await store.setNext(
      platform,
      KeepAlivePlan.calculateNextTime(interval, now: DateTime.now()),
    );
  }

  // 失效提醒：后台 isolate 里弹通知是尽力而为。KeepAliveNotifier 只在发送成功后才写
  // 去重标记，因此这里失败也不会丢提醒 —— 前台下次检查会补发。
  final expired = _backgroundHeartbeats.keys
      .where((p) => store.platformEnabled(p) && authStore.isExpired(p))
      .toList();
  if (expired.isNotEmpty) {
    try {
      await KeepAliveNotifier(store: store, authStore: authStore).notifyExpired(expired);
    } catch (e) {
      debugPrint('[KeepAliveWorker] notify failed: $e');
    }
  }
}

Duration _cookieAge(PlatformAuthStore authStore, String platform, DateTime now) {
  final boundTime = authStore.getBoundTime(platform);
  return boundTime != null ? now.difference(boundTime) : const Duration(days: 999);
}
