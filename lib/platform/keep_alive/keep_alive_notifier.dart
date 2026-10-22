/// 登录态失效提醒的收口点
///
/// 「检测」与「通知」刻意解耦：失效可能由前台保活、后台 worker 或连接器同步发现，
/// 但通知只在这里发出，去重标记也由这里落盘。
///
/// 后台 isolate 里弹通知是尽力而为（裸 FlutterEngine 调通知插件不保证成功），
/// 因此**只有发送成功才写标记**：失败时前台下次检查会补发，提醒不会丢。
library;

import 'package:flutter/foundation.dart';

import '../../core/engine/keep_alive_plan.dart';
import '../../core/models/platform_ids.dart';
import '../notification/notification_adapter.dart';
import '../storage/keep_alive_store.dart';
import '../storage/platform_auth_store.dart';

class KeepAliveNotifier {
  final KeepAliveStore _store;
  final PlatformAuthStore _authStore;

  /// 实际发送动作，抽成回调以便测试注入假实现（通知走平台通道，无法在单测里真发）
  final Future<void> Function(String platform, String displayName) _send;

  KeepAliveNotifier({
    KeepAliveStore? store,
    PlatformAuthStore? authStore,
    Future<void> Function(String platform, String displayName)? send,
  })  : _store = store ?? KeepAliveStore(),
        _authStore = authStore ?? PlatformAuthStore(),
        _send = send ?? _sendViaAdapter;

  static Future<void> _sendViaAdapter(String platform, String displayName) async {
    final adapter = NotificationAdapter();
    await adapter.initialize();
    await adapter.showKeepAliveExpiredNotification(
      platform: platform,
      displayName: displayName,
    );
  }

  /// 若该平台已失效且本失效周期尚未提醒过，则推送一次
  ///
  /// 返回是否真的发出。调用方无需关心失败：标记未落盘即代表「还没提醒成功」。
  Future<bool> notifyIfNeeded(String platform) async {
    if (!KeepAlivePlan.shouldNotifyExpiry(
      isExpired: _authStore.isExpired(platform),
      lastNotifiedAt: _store.lastNotifiedAt(platform),
    )) {
      return false;
    }

    try {
      await _send(platform, platformDisplayName(platform));
    } catch (e) {
      debugPrint('[KeepAliveNotifier] notify failed for $platform: $e');
      return false;
    }

    await _store.setLastNotifiedAt(platform, DateTime.now());
    debugPrint('[KeepAliveNotifier] expiry notified: $platform');
    return true;
  }

  /// 对一批平台逐一检查是否需要提醒
  Future<void> notifyExpired(List<String> platforms) async {
    for (final platform in platforms) {
      await notifyIfNeeded(platform);
    }
  }
}
