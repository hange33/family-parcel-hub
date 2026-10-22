/// 平台连接管理器 - 仅调度真实已绑定平台同步并汇总数据流
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/package_status.dart';
import '../../ui/providers/package_provider.dart';
import 'platform_connector.dart';
import 'taobao_connector.dart';
import 'jd_connector.dart';
import 'pdd_web_connector.dart';
import '../storage/platform_auth_store.dart';
import '../sync/sync_history_manager.dart';

final connectorManagerProvider = Provider<ConnectorManager>((ref) {
  final manager = ConnectorManager(ref);
  return manager;
});

final syncStateProvider = StateProvider<bool>((ref) => false);

class ConnectorManager {
  final Ref _ref;
  final List<PlatformConnector> _realConnectors = [];
  String? _lastIssue;

  /// 本次同步是否为用户主动触发的强制重拉（忽略「24 小时内已同步」跳过）
  bool _forceRefetch = false;

  ConnectorManager(this._ref) {
    _realConnectors.addAll([
      TaobaoH5Connector(
        getActiveTrackingNumbers: () {
          final list = _ref.read(packageListProvider);
          return list
              .where((p) =>
                  p.status == PackageStatus.arrived &&
                  !RegExp(r'^\d{1,3}-\d{1,3}-\d{2,5}$').hasMatch(p.pickupCode.trim()))
              .map((p) => p.trackingNumber.trim())
              .where((tn) => tn.isNotEmpty && !tn.contains('-'))
              .toList();
        },
        // 已签收订单只请求一次详情：连接器请求前查本地包裹
        getLocalPackages: () => _ref.read(packageListProvider),
        shouldForceRefetch: () => _forceRefetch,
      ),
      JdH5Connector(),
      // family-hub: 拼多多改走「网页端包裹助手」。
      // 原 PddH5Connector 走 mobile.yangkeduo.com，会与手机官方 App 双向互踢，
      // 故不再注册（文件保留，便于上游修复后切回）。
      PddWebConnector(),
    ]);
  }

  List<PlatformConnector> get realConnectors => List.unmodifiable(_realConnectors);

  /// 最近一次同步出现的可提示问题（如登录态失效）
  String? get lastIssue => _lastIssue;

  /// 用户重新授权后清理上一次的失效提示，避免设置页残留旧状态
  void clearLastIssue() {
    _lastIssue = null;
    for (final c in _realConnectors) {
      if (c is TaobaoH5Connector) c.clearLastIssue();
      if (c is JdH5Connector) c.clearLastIssue();
      if (c is PddWebConnector) c.clearLastIssue();
    }
  }

  /// 触发所有可用真实平台在途包裹聚合同步
  /// [onEarlyProgress]：首批在途件到达或首个通道完成时触发，供 UI 提前结束下拉刷新动画
  /// [force]：忽略「24 小时内已同步」跳过，强制重新拉取订单详情
  Future<int> syncAll({void Function()? onEarlyProgress, bool force = false}) async {
    final activeRealConnectors = <PlatformConnector>[];
    for (final c in _realConnectors) {
      final auth = await c.isAuthenticated();
      if (auth) {
        activeRealConnectors.add(c);
      }
    }
    return syncWithConnectors(activeRealConnectors, onEarlyProgress: onEarlyProgress, force: force);
  }

  /// 以指定连接器列表执行同步（支持依赖注入与单测）
  Future<int> syncWithConnectors(
    List<PlatformConnector> connectors, {
    void Function()? onEarlyProgress,
    bool force = false,
  }) async {
    debugPrint('[ConnectorManager] syncWithConnectors invoked (${connectors.length} connectors)');
    final syncState = _ref.read(syncStateProvider.notifier);
    if (syncState.state) {
      debugPrint('[ConnectorManager] already syncing, skip');
      return 0;
    }

    syncState.state = true;
    _forceRefetch = force;
    final notifier = _ref.read(packageListProvider.notifier);
    int newCount = 0;
    final sw = Stopwatch()..start();
    _lastIssue = null;

    var earlyProgressFired = false;
    void triggerEarly() {
      if (!earlyProgressFired) {
        earlyProgressFired = true;
        onEarlyProgress?.call();
      }
    }

    try {
      debugPrint('[ConnectorManager] Active connectors: ${connectors.map((e) => e.platformId).toList()}');
      if (connectors.isEmpty) {
        triggerEarly();
        return 0;
      }

      final futures = connectors.map((connector) async {
        final cw = Stopwatch()..start();
        try {
          await for (final package in connector.streamSync()) {
            if (!PlatformAuthStore().isBlacklisted(package.id, trackingNumber: package.trackingNumber)) {
              notifier.addPackage(package);
              newCount++;
              if (package.status == PackageStatus.delivering ||
                  package.status == PackageStatus.arrived ||
                  package.status == PackageStatus.transit) {
                triggerEarly();
              }
            }
          }
        } catch (e, stack) {
          debugPrint('[ConnectorManager] Error syncing ${connector.platformId}: ${e.runtimeType}\n$stack');
          final msg = '${connector.displayName}同步响应异常，已保留旧数据';
          _lastIssue = _lastIssue == null ? msg : '$_lastIssue；$msg';
        } finally {
          cw.stop();
          triggerEarly();
          debugPrint('[ConnectorManager] ${connector.platformId} sync took ${cw.elapsedMilliseconds}ms');
          // 记录本次同步时间：保活据此在「用户刚同步过」的 6 小时内跳过心跳
          await SyncHistoryManager().recordPlatformSync(connector.platformId);
          final issue = connector.lastIssue;
          if (issue != null && (_lastIssue == null || !_lastIssue!.contains(issue))) {
            _lastIssue = _lastIssue == null ? issue : '$_lastIssue；$issue';
          }
        }
      });

      await Future.wait(futures);
      sw.stop();
      debugPrint('[ConnectorManager] sync done: $newCount packages in ${sw.elapsedMilliseconds}ms');
      return newCount;
    } finally {
      _forceRefetch = false;
      syncState.state = false;
    }
  }
}
