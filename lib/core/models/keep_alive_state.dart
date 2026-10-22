/// 保活状态模型 - 纯Dart
///
/// 描述「一次保活的结果」与「当前各平台保活状态」的不可变快照，
/// 供保活服务、持久化层与界面共用。
library;

/// 一次保活尝试的结果
class KeepAliveRecord {
  final String platform;
  final DateTime time;

  /// 是否成功。跳过的记录 [skipped] 为 true 时，此字段无意义。
  final bool success;

  /// 是否为登录态失效（区别于网络错误）
  final bool authFailure;

  /// 本轮未真正发起心跳（平台不可探活 / 连接器正忙）
  final bool skipped;

  /// 失败原因摘要
  final String? error;

  const KeepAliveRecord({
    required this.platform,
    required this.time,
    required this.success,
    this.authFailure = false,
    this.skipped = false,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'platform': platform,
    'time': time.toIso8601String(),
    'success': success,
    'authFailure': authFailure,
    'skipped': skipped,
    'error': error,
  };

  factory KeepAliveRecord.fromJson(Map<String, dynamic> json) => KeepAliveRecord(
    platform: json['platform'] as String? ?? '',
    time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
    success: json['success'] as bool? ?? false,
    authFailure: json['authFailure'] as bool? ?? false,
    skipped: json['skipped'] as bool? ?? false,
    error: json['error'] as String?,
  );
}

/// 保活历史（新 -> 旧），超过上限自动截断
class KeepAliveHistory {
  /// 保留的最近记录条数
  static const int defaultCap = 50;

  final List<KeepAliveRecord> records;

  const KeepAliveHistory(this.records);

  static const KeepAliveHistory empty = KeepAliveHistory(<KeepAliveRecord>[]);

  /// 成功率：跳过的记录既不算成功也不算失败，直接排除
  ///
  /// 没有任何有效记录时返回 null（由调用方决定如何展示）。
  double? get successRate {
    final counted = records.where((r) => !r.skipped).toList();
    if (counted.isEmpty) return null;
    return counted.where((r) => r.success).length / counted.length;
  }

  /// 追加一条记录并截断到 [cap] 条（保留最新的）
  KeepAliveHistory appended(KeepAliveRecord record, {int cap = defaultCap}) {
    final next = <KeepAliveRecord>[record, ...records];
    if (next.length > cap) {
      next.removeRange(cap, next.length);
    }
    return KeepAliveHistory(next);
  }

  List<Map<String, dynamic>> toJson() => records.map((r) => r.toJson()).toList();

  factory KeepAliveHistory.fromJson(List<dynamic> json) => KeepAliveHistory(
    json
        .whereType<Map>()
        .map((e) => KeepAliveRecord.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

/// 单平台的保活状态快照
class PlatformKeepAliveStatus {
  final String platform;

  /// 是否已授权绑定（有 Cookie）
  final bool bound;

  /// 用户是否为该平台启用了保活
  final bool enabled;

  /// 距用户上次授权已过去多久（不是 Cookie 上次刷新的时间）
  final Duration? cookieAge;

  final DateTime? lastKeepAliveAt;
  final DateTime? nextKeepAliveAt;
  final int failureCount;
  final bool isExpired;

  /// 健康度文案（见 [KeepAlivePlan.resolveHealth]）
  final String health;

  const PlatformKeepAliveStatus({
    required this.platform,
    required this.bound,
    required this.enabled,
    required this.cookieAge,
    required this.lastKeepAliveAt,
    required this.nextKeepAliveAt,
    required this.failureCount,
    required this.isExpired,
    required this.health,
  });

  /// 需要用户处理：已绑定但登录态失效
  bool get needsReauth => bound && isExpired;
}

/// 全局保活快照（界面 watch 的对象）
class KeepAliveSnapshot {
  /// 保活总开关
  final bool enabled;

  final List<PlatformKeepAliveStatus> platforms;
  final List<KeepAliveRecord> history;
  final DateTime? lastCheckAt;

  const KeepAliveSnapshot({
    required this.enabled,
    required this.platforms,
    required this.history,
    required this.lastCheckAt,
  });

  static const KeepAliveSnapshot empty = KeepAliveSnapshot(
    enabled: true,
    platforms: <PlatformKeepAliveStatus>[],
    history: <KeepAliveRecord>[],
    lastCheckAt: null,
  );

  /// 需要重新授权的平台
  List<PlatformKeepAliveStatus> get expiredPlatforms =>
      platforms.where((p) => p.needsReauth).toList();
}
