/// 后台自动同步服务 - 仅在 App 后台运行时执行
///
/// 职责：
/// 1. App 启动后注册定时器
/// 2. 根据包裹状态动态调整同步间隔（自适应）
/// 3. App 生命周期监听：前台时暂停，后台时恢复
/// 4. 通知由 PackageListNotifier 自动触发（已有逻辑）
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/package.dart';
import '../../core/models/package_status.dart';
import '../../ui/providers/package_provider.dart';
import '../connectors/connector_manager.dart';

/// 后台同步服务单例
class BackgroundSyncService {
  final WidgetRef _ref;
  Timer? _syncTimer;
  AppLifecycleListener? _lifecycleListener;
  DateTime? _lastSyncTime;
  bool _isBackgroundSyncEnabled = true;

  BackgroundSyncService(this._ref);

  /// 初始化服务并注册生命周期监听
  void initialize() {
    debugPrint('[BackgroundSyncService] Initializing...');

    _lifecycleListener = AppLifecycleListener(
      onStateChange: _onAppLifecycleChanged,
    );

    debugPrint('[BackgroundSyncService] Lifecycle listener registered');
  }

  /// App 生命周期变化处理
  void _onAppLifecycleChanged(AppLifecycleState state) {
    debugPrint('[BackgroundSyncService] Lifecycle changed: $state');

    switch (state) {
      case AppLifecycleState.resumed:
        // App 回到前台，暂停后台同步
        _pauseBackgroundSync();
        break;

      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
        // App 进入后台，启动后台同步
        _startBackgroundSync();
        break;

      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // App 即将退出或被隐藏
        _pauseBackgroundSync();
        break;
    }
  }

  /// 启动后台自动同步
  void _startBackgroundSync() {
    if (!_isBackgroundSyncEnabled) {
      debugPrint('[BackgroundSyncService] Background sync is disabled');
      return;
    }

    debugPrint('[BackgroundSyncService] Starting background sync...');

    // 取消现有定时器
    _syncTimer?.cancel();

    // 计算同步间隔
    final interval = _calculateNextSyncInterval();

    if (interval.inHours >= 24) {
      debugPrint('[BackgroundSyncService] No active packages, sync paused');
      return;
    }

    debugPrint('[BackgroundSyncService] Next sync interval: ${interval.inMinutes} minutes');

    // 创建定时器
    _syncTimer = Timer.periodic(interval, (_) async {
      await _performSync();
      // 同步完成后重新计算间隔（自适应）
      _restartWithNewInterval();
    });

    // 立即执行一次同步
    _performSync();
  }

  /// 暂停后台同步
  void _pauseBackgroundSync() {
    debugPrint('[BackgroundSyncService] Pausing background sync...');
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  /// 执行同步
  Future<void> _performSync() async {
    debugPrint('[BackgroundSyncService] Performing sync...');
    _lastSyncTime = DateTime.now();

    try {
      final manager = _ref.read(connectorManagerProvider);
      final count = await manager.syncAll();
      debugPrint('[BackgroundSyncService] Sync completed: $count packages');
    } catch (e, stack) {
      debugPrint('[BackgroundSyncService] Sync error: $e\n$stack');
    }
  }

  /// 根据新的包裹状态重新启动定时器
  void _restartWithNewInterval() {
    if (_syncTimer == null) return;

    final newInterval = _calculateNextSyncInterval();
    final currentInterval = _syncTimer!.tick > 0
        ? Duration(milliseconds: (_syncTimer!.tick * newInterval.inMilliseconds))
        : newInterval;

    // 如果间隔发生显著变化（超过 5 分钟差异），重启定时器
    if ((newInterval.inMinutes - currentInterval.inMinutes).abs() > 5) {
      debugPrint('[BackgroundSyncService] Interval changed, restarting timer...');
      _startBackgroundSync();
    }
  }

  /// 计算下次同步间隔（自适应策略）
  Duration _calculateNextSyncInterval() {
    final packages = _ref.read(packageListProvider);

    // 过滤出在途/派送中/待取的包裹
    final activePackages = packages.where((p) =>
        p.status == PackageStatus.delivering ||
        p.status == PackageStatus.transit ||
        p.status == PackageStatus.arrived ||
        p.status == PackageStatus.pendingShipment).toList();

    if (activePackages.isEmpty) {
      // 无在途包裹，暂停同步（返回极长间隔）
      debugPrint('[BackgroundSyncService] No active packages');
      return const Duration(hours: 24);
    }

    // 检查是否有派送中的包裹
    final hasDelivering = activePackages.any((p) => p.status == PackageStatus.delivering);
    if (hasDelivering) {
      debugPrint('[BackgroundSyncService] Has delivering packages → 15min');
      return const Duration(minutes: 15);
    }

    // 检查是否有今日紧急待取的包裹
    final hasUrgent = activePackages.any((p) =>
        p.status == PackageStatus.arrived &&
        p.urgency == UrgencyLevel.urgent);
    if (hasUrgent) {
      debugPrint('[BackgroundSyncService] Has urgent packages → 30min');
      return const Duration(minutes: 30);
    }

    // 检查是否有待取的包裹（非紧急）
    final hasArrived = activePackages.any((p) => p.status == PackageStatus.arrived);
    if (hasArrived) {
      debugPrint('[BackgroundSyncService] Has arrived packages → 45min');
      return const Duration(minutes: 45);
    }

    // 只有在途包裹
    debugPrint('[BackgroundSyncService] Only transit packages → 1hour');
    return const Duration(hours: 1);
  }

  /// 获取最近同步时间
  DateTime? get lastSyncTime => _lastSyncTime;

  /// 开启/关闭后台同步
  void setEnabled(bool enabled) {
    _isBackgroundSyncEnabled = enabled;
    if (!enabled) {
      _pauseBackgroundSync();
    } else {
      // 检查当前生命周期状态，如果在后台则启动
      final binding = WidgetsBinding.instance;
      if (binding.lifecycleState == AppLifecycleState.paused ||
          binding.lifecycleState == AppLifecycleState.inactive) {
        _startBackgroundSync();
      }
    }
    debugPrint('[BackgroundSyncService] Background sync ${enabled ? 'enabled' : 'disabled'}');
  }

  /// 销毁服务
  void dispose() {
    debugPrint('[BackgroundSyncService] Disposing...');
    _syncTimer?.cancel();
    _lifecycleListener?.dispose();
  }
}
