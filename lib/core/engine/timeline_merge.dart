/// 物流时间轴合并 - 纯 Dart。
///
/// 职责：把两份时间轴 JSON（节点为 {tag, time, text}）合并成一份，去重并按时间倒序。
/// 合并时清洗历史脏数据：剔除脚本垃圾节点与非法时间节点，同键冲突以新数据为准。
library;

import 'dart:convert';

/// 脚本垃圾特征：历史 DOM 抓取会把页面脚本当成轨迹节点混入。
const _garbageMarkers = ['{', '}', 'window.', 'function', 'GLOBAL__', 'ptag='];

final _timePattern = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$');

/// 节点是否合法：文本不含脚本特征，且时间符合 yyyy-MM-dd HH:mm:ss。
bool _isValidNode(Map node) {
  final text = '${node['tag'] ?? ''}${node['text'] ?? ''}';
  if (_garbageMarkers.any(text.contains)) return false;
  return _timePattern.hasMatch((node['time'] ?? '').toString());
}

String _tagOf(Map node) => (node['tag'] ?? '').toString().trim();

/// 合并两份时间轴 JSON，返回合并后的 JSON 字符串；任一为空则返回另一方。
String? mergeTimelineJson(String? existingJson, String? incomingJson) {
  final existingEmpty = existingJson == null || existingJson.isEmpty;
  final incomingEmpty = incomingJson == null || incomingJson.isEmpty;
  if (existingEmpty) return incomingJson;
  if (incomingEmpty) return existingJson;
  try {
    final existing = (jsonDecode(existingJson) as List).cast<Map>();
    final incoming = (jsonDecode(incomingJson) as List).cast<Map>();
    final seenIndex = <String, int>{};
    final merged = <Map>[];
    // 新数据优先：同 time|text 冲突时保留最新抓取，自愈旧版错误标签；
    // 但先保留的那条没有标签、后面的带标签时，保留带标签的那条（技术方案第 1 节）。
    for (final node in [...incoming, ...existing]) {
      if (!_isValidNode(node)) continue;
      final key = '${node['time']}|${node['text']}';
      final idx = seenIndex[key];
      if (idx == null) {
        seenIndex[key] = merged.length;
        merged.add(node);
      } else if (_tagOf(merged[idx]).isEmpty && _tagOf(node).isNotEmpty) {
        merged[idx] = node;
      }
    }
    merged.sort((a, b) =>
        (b['time'] ?? '').toString().compareTo((a['time'] ?? '').toString()));
    return jsonEncode(merged);
  } catch (_) {
    return incomingJson.length >= existingJson.length ? incomingJson : existingJson;
  }
}
