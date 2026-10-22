/// 同步历史记录管理器
///
/// 记录每个平台和订单的最近同步时间，用于智能跳过已同步订单
library;

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

class SyncHistoryManager {
  static const String _boxName = 'sync_history';
  Box? _box;

  /// 初始化（在 main.dart 中调用）
  static Future<void> initialize() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
  }

  Future<void> _ensureInit() async {
    if (_box == null || !_box!.isOpen) {
      if (Hive.isBoxOpen(_boxName)) {
        _box = Hive.box(_boxName);
      } else {
        _box = await Hive.openBox(_boxName);
      }
    }
  }

  /// 记录平台同步时间
  Future<void> recordPlatformSync(String platform) async {
    await _ensureInit();
    await _box!.put('${platform}_last_sync', DateTime.now().millisecondsSinceEpoch);
  }

  /// 获取平台最近同步时间
  DateTime? getPlatformLastSync(String platform) {
    if (_box == null || !_box!.isOpen) return null;
    final ms = _box!.get('${platform}_last_sync') as int?;
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// 记录订单同步时间
  Future<void> recordOrderSync(String platform, String orderId) async {
    await _ensureInit();
    final key = '${platform}_order_${orderId}';
    await _box!.put(key, DateTime.now().millisecondsSinceEpoch);
  }

  /// 获取订单最近同步时间
  DateTime? getOrderLastSync(String platform, String orderId) {
    if (_box == null || !_box!.isOpen) return null;
    final key = '${platform}_order_${orderId}';
    final ms = _box!.get(key) as int?;
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// 判断订单是否应该跳过详情请求
  ///
  /// 跳过条件：
  /// 1. 24 小时内已同步过
  /// 2. 本地已有包裹数据
  /// 3. 包裹状态为已完成（已取件/已归档/已拒收）
  bool shouldSkipOrderDetail({
    required String platform,
    required String orderId,
    required bool hasLocalData,
    required bool isCompleted,
  }) {
    if (!hasLocalData) return false; // 本地没数据，必须拉取
    if (!isCompleted) return false; // 未完成的包裹，需要更新

    final lastSync = getOrderLastSync(platform, orderId);
    if (lastSync == null) return false; // 从未同步过

    final timeSinceSync = DateTime.now().difference(lastSync);
    if (timeSinceSync.inHours < 24) {
      debugPrint('[SyncHistory] Skip order detail: $platform/$orderId (synced ${timeSinceSync.inHours}h ago)');
      return true;
    }

    return false;
  }

  /// 判断平台是否应该跳过同步
  ///
  /// 跳过条件：
  /// 1. 5 分钟内已同步过（防止频繁手动刷新）
  bool shouldSkipPlatformSync(String platform) {
    final lastSync = getPlatformLastSync(platform);
    if (lastSync == null) return false;

    final timeSinceSync = DateTime.now().difference(lastSync);
    if (timeSinceSync.inMinutes < 5) {
      debugPrint('[SyncHistory] Skip platform sync: $platform (synced ${timeSinceSync.inMinutes}min ago)');
      return true;
    }

    return false;
  }

  /// 清理过期记录（7 天前的记录）
  Future<void> cleanExpiredRecords() async {
    await _ensureInit();
    final now = DateTime.now().millisecondsSinceEpoch;
    final expireTime = now - (7 * 24 * 60 * 60 * 1000); // 7 天

    final keysToDelete = <String>[];
    for (final key in _box!.keys) {
      final value = _box!.get(key);
      if (value is int && value < expireTime) {
        keysToDelete.add(key as String);
      }
    }

    for (final key in keysToDelete) {
      await _box!.delete(key);
    }

    if (keysToDelete.isNotEmpty) {
      debugPrint('[SyncHistory] Cleaned ${keysToDelete.length} expired records');
    }
  }

  /// 获取同步统计信息
  Map<String, dynamic> getStats() {
    if (_box == null || !_box!.isOpen) return {};

    final stats = <String, dynamic>{};
    for (final platform in ['taobao', 'jd', 'pdd']) {
      final lastSync = getPlatformLastSync(platform);
      stats[platform] = {
        'lastSync': lastSync,
        'timeSinceSync': lastSync != null
            ? DateTime.now().difference(lastSync).inMinutes
            : null,
      };
    }

    return stats;
  }
}
