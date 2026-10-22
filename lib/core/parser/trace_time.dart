/// 物流轨迹时间规范化 - 纯 Dart（三平台共用）
///
/// 技术方案第 1 节约定：`rawTimelineJson` 节点的 `time` 必须是 `yyyy-MM-dd HH:mm:ss`（北京时间）。
/// 各连接器写入轨迹前调用 [normalizeTraceTime]；返回 null 表示解析不出时间，调用方不写入该节点。
library;

const Duration _beijingOffset = Duration(hours: 8);

/// 缺年份补当年后，比当前时间晚超过这个量才视为跨年、减一年（容忍设备与服务端的时钟误差）
const Duration _futureTolerance = Duration(days: 1);

/// 带年份或缺年份的日期 + 时分(秒)：
/// 2026-10-06 14:23:05 / 2026/10/06 14:23 / 2026.10.06 14:23 / 10-06 14:23 /
/// 2026年10月6日 14:23 / 10月6日 14时23分 / 2026-10-06T14:23:05(.123)
final RegExp _dateTimeReg = RegExp(
  r'^(?:(\d{4})\s*[-/.年]\s*)?(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*[日号]?\s*[T\s]?\s*'
  r'(\d{1,2})\s*[:：时]\s*(\d{1,2})(?:\s*[:：分]\s*(\d{1,2})\s*秒?|\s*分)?(?:\.\d+)?$',
);

/// 带时区的 ISO 8601（Z 或 ±hh:mm），按时区换算成北京时间
final RegExp _isoWithZoneReg = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})$');

/// 把轨迹时间规范成 `yyyy-MM-dd HH:mm:ss`（北京时间），解析不出返回 null。
///
/// 支持：
/// - 已是约定格式；`/`、`.` 分隔；中文年月日（时分秒）；日期与时间之间多个空格或 `T`；
/// - 缺秒补 `:00`；带毫秒小数的丢弃小数；
/// - 缺年份补当年（北京时间），结果比当前时间晚一天以上时减一年（跨年）；
/// - 秒级（10 位）/ 毫秒级（13 位）时间戳，数字或数字字符串；
/// - 带 `Z` / `+08:00` 等时区的 ISO 8601。
///
/// [now] 用于测试注入，缺省为 `DateTime.now()`；任何时区的 DateTime 都会先换算成北京时间。
String? normalizeTraceTime(Object? raw, {DateTime? now}) {
  if (raw == null) return null;
  if (raw is num) return _fromEpoch(raw.toInt());
  final s = raw.toString().trim();
  if (s.isEmpty) return null;

  if (RegExp(r'^\d+$').hasMatch(s)) {
    return _fromEpoch(int.tryParse(s));
  }

  if (_isoWithZoneReg.hasMatch(s)) {
    final dt = DateTime.tryParse(s);
    return dt == null ? null : _format(dt.toUtc().add(_beijingOffset));
  }

  final m = _dateTimeReg.firstMatch(s);
  if (m == null) return null;
  final month = int.parse(m.group(2)!);
  final day = int.parse(m.group(3)!);
  final hour = int.parse(m.group(4)!);
  final minute = int.parse(m.group(5)!);
  final second = m.group(6) != null ? int.parse(m.group(6)!) : 0;

  final yearStr = m.group(1);
  if (yearStr != null) {
    return _validFormat(int.parse(yearStr), month, day, hour, minute, second);
  }

  final bjNow = (now ?? DateTime.now()).toUtc().add(_beijingOffset);
  final thisYear = _validFormat(bjNow.year, month, day, hour, minute, second);
  final bjNowWall = DateTime.utc(bjNow.year, bjNow.month, bjNow.day, bjNow.hour, bjNow.minute, bjNow.second);
  if (thisYear != null) {
    final candidate = DateTime.utc(bjNow.year, month, day, hour, minute, second);
    if (!candidate.isAfter(bjNowWall.add(_futureTolerance))) return thisYear;
  }
  // 跨年（或 2 月 29 日在今年不存在）：用上一年
  return _validFormat(bjNow.year - 1, month, day, hour, minute, second);
}

/// 10 位秒级 / 13 位毫秒级时间戳 → 北京时间
String? _fromEpoch(int? v) {
  if (v == null || v <= 0) return null;
  final digits = v.toString().length;
  final int ms;
  if (digits == 10) {
    ms = v * 1000;
  } else if (digits == 13) {
    ms = v;
  } else {
    return null;
  }
  return _format(DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(_beijingOffset));
}

/// 校验各字段合法（含大小月、闰年）后格式化；不合法返回 null
String? _validFormat(int year, int month, int day, int hour, int minute, int second) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;
  final dt = DateTime.utc(year, month, day, hour, minute, second);
  if (dt.month != month || dt.day != day) return null;
  return _format(dt);
}

String _format(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}
