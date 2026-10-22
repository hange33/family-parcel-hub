/// 同步优化器 - 智能跳过最近已同步的订单
///
/// 减少重复请求，提升二次及后续同步速度
library;

import 'package:flutter/foundation.dart';
import '../../core/models/package.dart';
import '../../core/models/package_status.dart';

class SyncOptimizer {
  /// 判断是否应该跳过订单详情请求
  ///
  /// 规则：
  /// 1. 本地无此订单 → 不跳过（首次同步）
  /// 2. 已完成状态（已取件/已归档/已拒收）→ 跳过
  /// 3. 在途状态但 24 小时内已同步过 → 跳过
  /// 4. 在途状态且超过 24 小时 → 不跳过（需要更新）
  ///
  /// [force] 为真时用户主动要求强制重拉：忽略规则 3 的 24 小时窗口，但规则 2 仍然生效
  /// （已完成订单的详情不会再变化，重拉只是白费请求）。用在数据卡住需要立刻刷新时，
  /// 例如驿站名/取件码被降级后想立刻拉回正确值。
  static bool shouldSkipDetailFetch({
    required Package? localPackage,
    required PackageStatus incomingStatus,
    Duration recentThreshold = const Duration(hours: 24),
    bool force = false,
  }) {
    // 本地无此订单，首次同步
    if (localPackage == null) return false;

    // 已完成状态，跳过
    if (localPackage.status == PackageStatus.pickedUp ||
        localPackage.status == PackageStatus.archived ||
        localPackage.status == PackageStatus.rejected) {
      debugPrint('[SyncOptimizer] Skip: already completed (${localPackage.status.label})');
      return true;
    }

    // 强制重拉：忽略 24 小时窗口
    if (force) {
      debugPrint('[SyncOptimizer] Fetch: forced, ignoring recent-sync window');
      return false;
    }

    // 在途状态，检查最近更新时间
    final now = DateTime.now();
    final lastUpdate = localPackage.addedAt;
    final timeSinceUpdate = now.difference(lastUpdate);

    if (timeSinceUpdate < recentThreshold) {
      debugPrint('[SyncOptimizer] Skip: recently synced ${timeSinceUpdate.inHours}h ago');
      return true;
    }

    // 需要更新
    debugPrint('[SyncOptimizer] Fetch: last sync ${timeSinceUpdate.inHours}h ago');
    return false;
  }

  /// 过滤需要拉取详情的订单列表
  static List<T> filterNeedsFetch<T>({
    required List<T> orders,
    required List<Package> localPackages,
    required String Function(T) getOrderId,
    required PackageStatus Function(T) getStatus,
    Duration recentThreshold = const Duration(hours: 24),
    bool force = false,
  }) {
    final result = <T>[];
    var skippedCount = 0;

    for (final order in orders) {
      final orderId = getOrderId(order);
      final status = getStatus(order);

      // 查找本地包裹
      final localPackage = localPackages.firstWhere(
        (p) => p.id.endsWith(orderId),
        orElse: () => Package(
          id: 'NOT_FOUND',
          trackingNumber: '',
          courier: CourierType.other,
          urgency: UrgencyLevel.normal,
          status: PackageStatus.transit,
          addedAt: DateTime.now(),
        ),
      );

      final shouldSkip = localPackage.id != 'NOT_FOUND' &&
          shouldSkipDetailFetch(
            localPackage: localPackage,
            incomingStatus: status,
            recentThreshold: recentThreshold,
            force: force,
          );

      if (shouldSkip) {
        skippedCount++;
      } else {
        result.add(order);
      }
    }

    debugPrint('[SyncOptimizer] Total: ${orders.length}, Need fetch: ${result.length}, Skipped: $skippedCount');
    return result;
  }

  /// 判断是否应该执行同步（基于上次同步时间）
  static bool shouldSync({
    DateTime? lastSyncTime,
    Duration minInterval = const Duration(minutes: 5),
  }) {
    if (lastSyncTime == null) return true;

    final now = DateTime.now();
    final timeSinceSync = now.difference(lastSyncTime);

    if (timeSinceSync < minInterval) {
      debugPrint('[SyncOptimizer] Skip sync: last synced ${timeSinceSync.inMinutes} min ago (min: ${minInterval.inMinutes} min)');
      return false;
    }

    return true;
  }

  /// 计算推荐的同步间隔（基于包裹状态分布）
  static Duration recommendedSyncInterval({
    required int arrivedCount,
    required int deliveringCount,
    required int transitCount,
    required int pendingCount,
  }) {
    // 有已到达待取件 → 30-45 分钟（高频）
    if (arrivedCount > 0) {
      return const Duration(minutes: 30);
    }

    // 有派送中 → 45-60 分钟（中频）
    if (deliveringCount > 0) {
      return const Duration(minutes: 45);
    }

    // 仅在途 → 1-2 小时（低频）
    if (transitCount > 0) {
      return const Duration(hours: 1);
    }

    // 仅待发货 → 2-4 小时（极低频）
    if (pendingCount > 0) {
      return const Duration(hours: 2);
    }

    // 无活跃包裹 → 暂停
    return const Duration(hours: 24);
  }
}
