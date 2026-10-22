/// 拼多多物流轨迹与网络捕获解析辅助工具 - 纯 Dart
library;

import 'dart:convert';

import '../../core/parser/trace_time.dart';

/// 推荐流与商品广告识别正则：遇此特征立即阻断 DOM 时间轴收集
final _recStreamRegex = RegExp(
  r'(即将恢复|本店已拼|全店总售|已抢|券后|立减|未发货秒退|24小时发货|限\d+件|退货包运费|推荐商品|\d+\.\d+$)',
);

final _dateRegex = RegExp(
  r'(\d{4}[-/.]\d{2}[-/.]\d{2}\s+\d{2}:\d{2}(?::\d{2})?)',
);

final _skipRegex = RegExp(
  r'(订单编号|收货地址|快递员|网点电话|投诉电话|联系电话|微信公众号|^：$|^\d+$)',
);

const _noiseWords = {
  '包裹追踪', '在App打开', '在APP打开', '打赏快递员', '拨打电话', '复制',
  '展开', '物流服务', '货物跟踪', '顶部', '暂无数据',
};

const _logisticsKeywords = [
  '快件', '包裹', '派件', '揽收', '签收', '发往', '到达', '转运',
  '投递', '取件', '出库', '配送', '妥投', '物流', '运输', '发出',
  '已投', '送达', '自提', '极兔', '圆通', '中通', '韵达', '申通',
  '顺丰', '邮政', '京东',
];

/// 从 DOM 纯文本中按行解析时间轴，并在遭遇推荐流时立即截断。
/// 节点时间经 [normalizeTraceTime] 规范成 yyyy-MM-dd HH:mm:ss，解析不出时间的节点不写入；[now] 供测试注入。
List<Map<String, String>> parsePddDomTimeline(String rawText, {DateTime? now}) {
  var text = rawText.trim();
  if (text.startsWith('"') && text.endsWith('"')) {
    text = text.substring(1, text.length - 1).replaceAll(r'\n', '\n');
  }

  final nodes = <Map<String, String>>[];
  String? currentTime;
  StringBuffer? pendingDesc;

  void flush() {
    final t = currentTime;
    final p = pendingDesc;
    if (t != null && p != null) {
      final desc = p.toString().trim();
      if (desc.isNotEmpty && desc.length >= 4) {
        nodes.add({
          'tag': '',
          'time': t,
          'text': desc,
        });
      }
    }
    pendingDesc = null;
  }

  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    // 一旦撞见推荐流特征，立即保存当前节点并停止向下遍历，彻底截断
    if (_recStreamRegex.hasMatch(line)) {
      flush();
      break;
    }

    final dm = _dateRegex.firstMatch(line);
    if (dm != null && line.length <= 25) {
      flush();
      currentTime = normalizeTraceTime(dm.group(1), now: now);
      continue;
    }

    if (_noiseWords.contains(line)) continue;

    final looksLikeDesc = line.contains('【') || _logisticsKeywords.any(line.contains);
    if (looksLikeDesc) {
      if (pendingDesc == null) {
        pendingDesc = StringBuffer(line);
      } else {
        pendingDesc!.write(' $line');
      }
      continue;
    }

    if (_skipRegex.hasMatch(line)) continue;
  }

  flush();
  return nodes;
}

class PddCapturedResponse {
  final String url;
  final String body;

  const PddCapturedResponse(this.url, this.body);
}

/// 解析 window.name 暂存的 JSON 数组捕获项
List<PddCapturedResponse> parsePddWindowNameCaptures(String raw) {
  final text = raw.trim();
  if (text.isEmpty || !text.startsWith('[')) return const [];

  try {
    final list = jsonDecode(text) as List<dynamic>;
    final result = <PddCapturedResponse>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final url = item['u']?.toString() ?? '';
      final body = item['b']?.toString() ?? '';
      if (url.isEmpty || body.isEmpty) continue;

      final lowerUrl = url.toLowerCase();
      // 过滤统计打点等无用网络包
      if (lowerUrl.contains('analytics') || lowerUrl.contains('/event') || lowerUrl.contains('/log')) {
        continue;
      }
      final isRelevant = lowerUrl.contains('proxy/api') &&
          (lowerUrl.contains('order') ||
              lowerUrl.contains('logistic') ||
              lowerUrl.contains('express') ||
              lowerUrl.contains('track') ||
              lowerUrl.contains('parcel') ||
              lowerUrl.contains('shipping') ||
              lowerUrl.contains('goods'));
      if (isRelevant) {
        result.add(PddCapturedResponse(url, body));
      }
    }
    return result;
  } catch (_) {
    return const [];
  }
}

const _timeCandidateKeys = {
  'time', 'create_time', 'update_time', 'logistics_time', 'tracking_time',
  'subtitle', 'format_time', 'formatTime', 'gmt_create',
};

const _descCandidateKeys = {
  'desc', 'description', 'context', 'status_desc', 'statusDesc', 'text',
  'content', 'track_desc', 'logistics_desc', 'sub_desc',
};

/// 递归扫描任意 JSON 树，通过候选键集合提取时间轴节点。
/// 节点时间经 [normalizeTraceTime] 规范化，解析不出时间的节点不写入；[now] 供测试注入。
List<Map<String, String>> extractPddTimelineFromJson(dynamic root, {DateTime? now}) {
  final nodes = <Map<String, String>>[];
  final seen = <String>{};

  void scan(dynamic node) {
    if (node is Map<String, dynamic>) {
      String foundTime = '';
      String foundDesc = '';

      for (final k in node.keys) {
        final lower = k.toLowerCase();
        if (foundTime.isEmpty && _timeCandidateKeys.contains(lower)) {
          final v = node[k];
          if (v != null && v.toString().trim().isNotEmpty) {
            foundTime = v.toString().trim();
          }
        }
        if (foundDesc.isEmpty && _descCandidateKeys.contains(lower)) {
          final v = node[k];
          if (v != null && v.toString().trim().isNotEmpty) {
            foundDesc = v.toString().trim();
          }
        }
      }

      if (foundTime.isNotEmpty && foundDesc.isNotEmpty && foundTime != foundDesc) {
        final time = normalizeTraceTime(foundTime, now: now);
        if (time != null) {
          final key = '$time|$foundDesc';
          if (seen.add(key)) {
            nodes.add({
              'tag': '',
              'time': time,
              'text': foundDesc,
            });
          }
        }
        return;
      }

      for (final child in node.values) {
        scan(child);
      }
    } else if (node is List<dynamic>) {
      for (final child in node) {
        scan(child);
      }
    }
  }

  scan(root);
  return nodes;
}
