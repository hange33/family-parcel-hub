/// 保活调度决策 - 纯Dart
///
/// 由 `platform/keep_alive/keep_alive_scheduler.dart` 迁移而来，下沉到 core 的目的：
/// 决策逻辑不依赖 Flutter 与任何插件，可直接单测。
/// 因此这里**不得**使用 `debugPrint`，且所有时间必须可注入（不做隐式 `DateTime.now()`）。
library;

/// 保活间隔、跳过规则与健康度判定
class KeepAlivePlan {
  const KeepAlivePlan._();

  /// 用户主动同步后多久内跳过保活（同步本身就是最强的保活活动）
  static const Duration syncCooldown = Duration(hours: 6);

  /// 距上次保活多久内跳过（避免同进程内重复发送）
  static const Duration keepAliveCooldown = Duration(hours: 2);

  /// 连续失败多少次判定登录态失效
  static const int failureThreshold = 3;

  /// 根据 Cookie 年龄计算保活间隔：越老越频繁
  static Duration calculateInterval(Duration cookieAge) {
    final days = cookieAge.inDays;

    if (days <= 3) return const Duration(hours: 24); // 新鲜期，低频维护
    if (days <= 7) return const Duration(hours: 12); // 中期，适度保活
    if (days <= 10) return const Duration(hours: 6); // 临期，积极保活
    return const Duration(hours: 4); // 危险期，高频保活
  }

  /// 是否应跳过本轮保活（用户最近有活动 / 刚保活过）
  static bool shouldSkip({
    DateTime? lastSyncTime,
    DateTime? lastKeepAliveTime,
    required DateTime now,
  }) {
    if (lastSyncTime != null && now.difference(lastSyncTime) < syncCooldown) {
      return true;
    }
    if (lastKeepAliveTime != null && now.difference(lastKeepAliveTime) < keepAliveCooldown) {
      return true;
    }
    return false;
  }

  /// 计算下次保活时间
  ///
  /// [jitter] 为随机偏移，用于避开固定时间点（调用方注入，便于测试）。
  static DateTime calculateNextTime(
    Duration interval, {
    required DateTime now,
    Duration jitter = Duration.zero,
  }) {
    return now.add(interval).add(jitter);
  }

  /// 健康度：失效标记 > 连续失败达阈值 > 有失败 > Cookie 年龄
  static String resolveHealth({
    required bool isExpired,
    required int failureCount,
    Duration? cookieAge,
  }) {
    if (isExpired || failureCount >= failureThreshold) return '失效';
    if (failureCount >= 1) return '不稳定';
    if (cookieAge != null) return cookieHealthDescription(cookieAge);
    return 'unknown';
  }

  /// 失效是否应发通知：当前已失效，且本失效周期还没通知过
  ///
  /// 恢复（`setExpired(false)`）时清空通知标记，于是下一个失效周期可再通知一次。
  static bool shouldNotifyExpiry({
    required bool isExpired,
    required DateTime? lastNotifiedAt,
  }) {
    return isExpired && lastNotifiedAt == null;
  }

  /// Cookie 健康度描述
  static String cookieHealthDescription(Duration cookieAge) {
    final days = cookieAge.inDays;

    if (days <= 3) return '健康';
    if (days <= 7) return '良好';
    if (days <= 10) return '临期';
    if (days <= 14) return '需要保活';
    return '即将过期';
  }

  /// Cookie 健康度颜色（ARGB 十六进制字符串，渲染层负责解析）
  static String cookieHealthColorHex(Duration cookieAge) {
    final days = cookieAge.inDays;

    if (days <= 3) return '#4CAF50'; // 绿色
    if (days <= 7) return '#8BC34A'; // 浅绿
    if (days <= 10) return '#FFC107'; // 黄色
    if (days <= 14) return '#FF9800'; // 橙色
    return '#F44336'; // 红色
  }
}
