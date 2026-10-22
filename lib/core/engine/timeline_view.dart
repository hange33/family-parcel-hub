/// 时间轴展示数据准备 - 纯 Dart，不依赖 Flutter。
///
/// 职责（P12）：把 `Package.rawTimelineJson` 变成界面可以直接渲染的节点列表，
/// 三个平台共用同一套规则，界面层不写任何平台特判。
/// 1. 容错解析：单个坏节点只跳过它自己，不会让整条时间轴变空；
/// 2. 清洗：值统一 toString + trim，tag 和 text 都为空的节点丢弃；
/// 3. 去重：去重键 `time|text`（与 timeline_merge 保持一致），保留先出现的一条；
/// 4. 排序：合法时间（yyyy-MM-dd HH:mm:ss）稳定倒序，非法时间的节点排在后面并保持原顺序；
/// 5. 文本切分：识别正文里的电话号码（可点击拨打）与取件码（加粗）；
/// 6. 从最新节点提取驿站/派送员电话，供取件凭证卡片使用；
/// 7. 时间显示统一为「今天/昨天/具体日期 + 时分」。
///
/// 注意：这里只做「展示层」的整理，不回写存储；存储层的合并仍由 timeline_merge 负责。
library;

import 'dart:convert';

/// 一个可展示的时间轴节点。
class TimelineNode {
  /// 节点标签，例如「派送中」「已签收」，可能为空。
  final String tag;

  /// 原始时间字符串（已 trim）。
  final String time;

  /// 轨迹描述正文，可能为空（此时 tag 不为空）。
  final String text;

  /// 按数据约定解析出的时间；时间不符合 `yyyy-MM-dd HH:mm:ss` 时为 null。
  final DateTime? parsedTime;

  const TimelineNode({
    required this.tag,
    required this.time,
    required this.text,
    this.parsedTime,
  });

  /// 去重键，与 timeline_merge 的 `time|text` 一致。
  String get dedupeKey => '$time|$text';

  @override
  bool operator ==(Object other) =>
      other is TimelineNode &&
      other.tag == tag &&
      other.time == time &&
      other.text == text;

  @override
  int get hashCode => Object.hash(tag, time, text);

  @override
  String toString() => 'TimelineNode($time, $tag, $text)';
}

/// 数据约定的时间格式：yyyy-MM-dd HH:mm:ss。
final RegExp _contractTimePattern =
    RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$');

/// 严格解析约定格式的时间；格式不对或日期越界（如 13 月、25 点）都返回 null。
DateTime? parseContractTime(String raw) {
  final m = _contractTimePattern.firstMatch(raw);
  if (m == null) return null;
  final parts = List<int>.generate(6, (i) => int.parse(m.group(i + 1)!));
  final dt = DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
  // DateTime 会把越界值自动进位（例如 2 月 30 日变成 3 月 2 日），这里要求逐项一致。
  final valid = dt.year == parts[0] &&
      dt.month == parts[1] &&
      dt.day == parts[2] &&
      dt.hour == parts[3] &&
      dt.minute == parts[4] &&
      dt.second == parts[5];
  return valid ? dt : null;
}

/// 把标量值转成去掉首尾空白的字符串；null、对象、数组都视为空串，
/// 免得界面上出现 `{desc: …}` 这样的原始结构。
String _asText(Object? value) {
  if (value is String) return value.trim();
  if (value is num || value is bool) return value.toString();
  return '';
}

/// 把 rawTimelineJson 整理成展示用的节点列表（最新在前、已去重）。
///
/// - JSON 为空、解析失败、顶层不是数组：返回空列表（界面显示空状态）；
/// - 数组里不是对象的元素、tag 和 text 都为空的节点：跳过；
/// - 同一 `time|text` 只保留第一次出现的节点；
/// - 合法时间按时间倒序（相同时间保持原顺序），非法时间节点放在最后、保持原顺序。
List<TimelineNode> timelineForDisplay(String? rawJson) {
  if (rawJson == null || rawJson.trim().isEmpty) return const [];

  Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];

  final seen = <String>{};
  final valid = <TimelineNode>[];
  final invalid = <TimelineNode>[];

  for (final item in decoded) {
    if (item is! Map) continue;
    final tag = _asText(item['tag']);
    final time = _asText(item['time']);
    final text = _asText(item['text']);
    if (tag.isEmpty && text.isEmpty) continue;

    final node = TimelineNode(
      tag: tag,
      time: time,
      text: text,
      parsedTime: parseContractTime(time),
    );
    if (!seen.add(node.dedupeKey)) continue;
    (node.parsedTime != null ? valid : invalid).add(node);
  }

  // List.sort 不保证稳定，带上原始下标做稳定倒序。
  final indexed = List.generate(valid.length, (i) => MapEntry(i, valid[i]));
  indexed.sort((a, b) {
    final byTime = b.value.parsedTime!.compareTo(a.value.parsedTime!);
    return byTime != 0 ? byTime : a.key.compareTo(b.key);
  });

  return List.unmodifiable([...indexed.map((e) => e.value), ...invalid]);
}

// ───────────────────────── 时间显示 ─────────────────────────

String _two(int v) => v.toString().padLeft(2, '0');

/// 时间轴上的时间文案：今天 HH:mm / 昨天 HH:mm / MM-dd HH:mm（今年）/ yyyy-MM-dd HH:mm。
///
/// 时间不符合约定格式时原样返回原始字符串，不做任何猜测。
/// [now] 只用于测试注入，默认取当前时间。
String formatTimelineTime(TimelineNode node, {DateTime? now}) {
  final t = node.parsedTime;
  if (t == null) return node.time;
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(t.year, t.month, t.day);
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  // 用日历日差而不是 Duration，避免夏令时之类的问题（国内无夏令时，但保持稳妥）。
  final diffDays = DateTime.utc(today.year, today.month, today.day)
      .difference(DateTime.utc(day.year, day.month, day.day))
      .inDays;
  if (diffDays == 0) return '今天 $hm';
  if (diffDays == 1) return '昨天 $hm';
  if (t.year == current.year) return '${_two(t.month)}-${_two(t.day)} $hm';
  return '${t.year}-${_two(t.month)}-${_two(t.day)} $hm';
}

// ───────────────────────── 电话与取件码识别 ─────────────────────────

/// 电话类型：手机、座机、客服热线（95 开头短号、400/800）。
enum PhoneKind { mobile, landline, hotline }

/// 电话号码：
/// - 手机：1[3-9] 开头共 11 位；
/// - 座机：0 + 2~3 位区号，可带一个「-」或空格，+ 7~8 位号码；
/// - 热线：95 开头 5~7 位；400/800 开头 10 位（可带「-」）。
/// 前后用「不能紧挨数字或英文字母」限定边界：中文、标点、空格紧挨号码都能识别，
/// 但运单号（如 YT1234…）、更长的数字串中间不会被误截成电话。
final RegExp _phonePattern = RegExp(
  r'(?<![0-9A-Za-z])'
  r'(?:'
  r'(?<mobile>1[3-9]\d{9})'
  r'|(?<landline>0\d{2,3}[- ]?\d{7,8})'
  r'|(?<hotline>95\d{3,5}|[48]00-?\d{3}-?\d{4})'
  r')'
  r'(?![0-9A-Za-z])',
);

/// 号码前面紧挨着这些词时它是取件码/验证码，不是电话。
final RegExp _codeContextBefore =
    RegExp(r'(取件码|取货码|提货码|取件号|验证码|货架号|编码)\s*[:：]?\s*$');

/// 正文里的一段文字。
enum TraceSegmentType { plain, phone, pickupCode }

class TraceSegment {
  final TraceSegmentType type;
  final String text;

  /// 仅 phone 类型有值。
  final PhoneKind? phoneKind;

  const TraceSegment(this.type, this.text, {this.phoneKind});

  @override
  bool operator ==(Object other) =>
      other is TraceSegment &&
      other.type == type &&
      other.text == text &&
      other.phoneKind == phoneKind;

  @override
  int get hashCode => Object.hash(type, text, phoneKind);

  @override
  String toString() => 'TraceSegment($type, $text)';
}

class _Span {
  final int start;
  final int end;
  final TraceSegmentType type;
  final PhoneKind? kind;
  const _Span(this.start, this.end, this.type, [this.kind]);
}

/// 取件码太短（如 1~2 位）时在正文里匹配容易误伤，不做强调。
const int _minPickupCodeLength = 3;

List<_Span> _pickupCodeSpans(String text, String? pickupCode) {
  final code = pickupCode?.trim() ?? '';
  if (code.length < _minPickupCodeLength) return const [];
  final pattern = RegExp(
    '(?<![0-9A-Za-z])${RegExp.escape(code)}(?![0-9A-Za-z])',
  );
  return [
    for (final m in pattern.allMatches(text))
      _Span(m.start, m.end, TraceSegmentType.pickupCode),
  ];
}

List<_Span> _phoneSpans(String text, List<_Span> blocked) {
  final result = <_Span>[];
  for (final m in _phonePattern.allMatches(text)) {
    final overlaps = blocked.any((b) => m.start < b.end && b.start < m.end);
    if (overlaps) continue;
    if (_codeContextBefore.hasMatch(text.substring(0, m.start))) continue;
    final kind = m.namedGroup('mobile') != null
        ? PhoneKind.mobile
        : m.namedGroup('landline') != null
            ? PhoneKind.landline
            : PhoneKind.hotline;
    result.add(_Span(m.start, m.end, TraceSegmentType.phone, kind));
  }
  return result;
}

/// 把轨迹正文切成「普通文字 / 电话 / 取件码」几段，界面按段渲染。
///
/// 取件码优先：和取件码重叠的数字不会被当成电话。
List<TraceSegment> segmentTraceText(String text, {String? pickupCode}) {
  if (text.isEmpty) return const [];
  final codes = _pickupCodeSpans(text, pickupCode);
  final spans = [...codes, ..._phoneSpans(text, codes)]
    ..sort((a, b) => a.start.compareTo(b.start));

  final segments = <TraceSegment>[];
  var cursor = 0;
  for (final s in spans) {
    if (s.start > cursor) {
      segments.add(TraceSegment(TraceSegmentType.plain, text.substring(cursor, s.start)));
    }
    segments.add(TraceSegment(s.type, text.substring(s.start, s.end), phoneKind: s.kind));
    cursor = s.end;
  }
  if (cursor < text.length) {
    segments.add(TraceSegment(TraceSegmentType.plain, text.substring(cursor)));
  }
  return segments;
}

/// 正文里所有电话（按出现顺序）。
List<String> findPhones(String text, {String? pickupCode}) => [
      for (final s in segmentTraceText(text, pickupCode: pickupCode))
        if (s.type == TraceSegmentType.phone) s.text,
    ];

/// 去掉分隔符，得到可以直接拨打的号码（用于 `tel:`）。
String dialablePhone(String phone) => phone.replaceAll(RegExp(r'[^0-9]'), '');

/// 从最新的几个节点里取驿站/派送员电话（`Package` 还没有 stationPhone 字段前的过渡方案）。
///
/// - 只看最新的 [maxNodes] 个节点（默认 2 个），越新越优先；
/// - 只取手机和座机；95xxx、400 这类是快递公司总客服，不算驿站电话；
/// - 和取件码重叠、或紧跟在「取件码」等字样后面的数字不算电话；
/// - 找不到返回 null。
///
/// 也可以直接传一段文字（[text]）用于单条正文。
String? extractStationPhone({
  List<TimelineNode> nodes = const [],
  String? text,
  String? pickupCode,
  int maxNodes = 2,
}) {
  final texts = <String>[
    if (text != null) text,
    for (final n in nodes.take(maxNodes)) n.text,
  ];
  for (final t in texts) {
    for (final s in segmentTraceText(t, pickupCode: pickupCode)) {
      if (s.type == TraceSegmentType.phone && s.phoneKind != PhoneKind.hotline) {
        return s.text;
      }
    }
  }
  return null;
}
