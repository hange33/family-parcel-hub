/// 淘宝物流详情 SSR 页（logisticsV2/h5-detail）解析 - 纯 Dart（不引用 Flutter）
///
/// 技术方案 §2.3 P11-c：输入详情页 HTML（或已截出的 SSR JSON 文本），输出
/// `{mailNo, cpName, pickupCode, stationName, nodes}`；连接器只负责请求。
///
/// 根因（P11-b，10-07 真机样本）：页面脚本是立即执行函数，从数据标记截到
/// `</script>` 的文本末尾多出 `}();`，旧实现直接 `jsonDecode` 报错后被吞掉，
/// 15 个订单全部解析失败。这里改为从标记后的 `{` 开始按括号配对截出第一个
/// 完整 JSON 对象（跳过字符串里的括号和转义），再解码。
///
/// 每个返回 null 的分支都通过 [TaobaoTraceLogger] 报一条原因；原因里只有步骤、
/// 错误类型和数量，不含订单号、运单号、手机号、Cookie 等。
library;

import 'dart:convert';

import 'trace_time.dart';

/// SSR 页里数据的赋值标记
const String taobaoSsrMarker = "__ICE_SUSPENSE_LOADER__']['undefined'] = ";

/// 解析原因日志回调（连接器传 debugPrint 包装；测试可收集断言）
typedef TaobaoTraceLogger = void Function(String message);

/// 一个淘宝物流详情的解析结果
class TaobaoTrace {
  /// 运单号（可能为空）
  final String mailNo;

  /// 物流公司名；页面给的 name 为空或被打码时按 cpCode 映射
  final String cpName;

  /// 物流公司编码（如 YUNDA / YTO / POSTB），可能为空
  final String cpCode;

  /// 取件码：在全部节点里找，取最新的一条
  final String pickupCode;

  /// 驿站名：在全部节点里找，取最新的一条；找不到为空
  final String stationName;

  /// 最新阶段标题（如「运输中」「已签收」）
  final String stateLabel;

  /// 页面埋点里的物流状态编码（如 TRANSPORT / SIGN），可能为空
  final String lgStatus;

  /// 时间轴节点 `{tag, time, text}`，time 为 `yyyy-MM-dd HH:mm:ss`，最新在前
  final List<Map<String, String>> nodes;

  const TaobaoTrace({
    required this.mailNo,
    required this.cpName,
    required this.cpCode,
    required this.pickupCode,
    required this.stationName,
    required this.stateLabel,
    required this.lgStatus,
    required this.nodes,
  });

  Map<String, Object> toMap() => {
        'mailNo': mailNo,
        'cpName': cpName,
        'pickupCode': pickupCode,
        'stationName': stationName,
        'nodes': nodes,
      };
}

/// 淘宝 SSR 物流详情解析器
class TaobaoTraceParser {
  TaobaoTraceParser._();

  static const _tag = '[TaobaoTrace]';

  /// 解析详情页 HTML：找数据标记 → 括号配对截 JSON → 解码 → 取物流字段。
  ///
  /// 找不到标记、JSON 不完整/不合法、`result.code` 是跳转（如 JUMP_302）、
  /// 没有物流字段时返回 null，并通过 [log] 报原因。[now] 供测试注入。
  static TaobaoTrace? parseHtml(String html, {DateTime? now, TaobaoTraceLogger? log}) {
    final idx = html.indexOf(taobaoSsrMarker);
    if (idx == -1) {
      log?.call('$_tag 未找到 SSR 数据标记（页面长度 ${html.length}，可能被跳转登录或页面改版）');
      return null;
    }
    return _parseFrom(html, idx + taobaoSsrMarker.length, now: now, log: log);
  }

  /// 解析已从标记后截出的文本（如 P11-a 诊断采集的 `raw`，末尾可能带 `}();`）。
  static TaobaoTrace? parseSsrText(String text, {DateTime? now, TaobaoTraceLogger? log}) =>
      _parseFrom(text, 0, now: now, log: log);

  static TaobaoTrace? _parseFrom(String s, int start, {DateTime? now, TaobaoTraceLogger? log}) {
    // 标记后只允许空白，然后必须是 `{`；否则不去别处找，避免截到无关对象
    var i = start;
    while (i < s.length && _isWs(s.codeUnitAt(i))) {
      i++;
    }
    if (i >= s.length || s.codeUnitAt(i) != 0x7B /* { */) {
      log?.call('$_tag 标记后不是 JSON 对象（第一个非空白字符不是 {）');
      return null;
    }

    final end = findJsonObjectEnd(s, i);
    if (end == -1) {
      log?.call('$_tag JSON 括号不闭合（文本被截断，扫描了 ${s.length - i} 个字符）');
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(s.substring(i, end));
    } on FormatException catch (e) {
      // 只记 message 和位置；FormatException.toString() 会带原文片段（可能含订单号），不能打
      log?.call('$_tag JSON 解析失败：${e.message}（offset ${e.offset ?? -1}）');
      return null;
    }
    if (decoded is! Map) {
      log?.call('$_tag JSON 顶层不是对象（${decoded.runtimeType}）');
      return null;
    }
    return parseSsrObject(decoded, now: now, log: log);
  }

  /// 解析已解码的 SSR 对象（`{result: {data: ...}}`）。
  static TaobaoTrace? parseSsrObject(Map<dynamic, dynamic> root, {DateTime? now, TaobaoTraceLogger? log}) {
    final result = root['result'];
    if (result is! Map) {
      log?.call('$_tag 没有 result 字段');
      return null;
    }
    final code = result['code'];
    final data = result['data'];
    if (data is! Map) {
      if (code != null) {
        log?.call('$_tag 没有 result.data，code=${_safeCode(code)}'
            '${_safeCode(code) == 'JUMP_302' ? '（非淘宝物流订单，如饿了么，详情页跳转外部）' : ''}');
      } else {
        log?.call('$_tag 没有 result.data');
      }
      return null;
    }

    final newLogistics = data['newLogistics'];
    var fields = newLogistics is Map ? newLogistics['fields'] : null;
    if (fields is! Map) {
      final legacy = data['logisticsDetailH5'];
      fields = legacy is Map ? legacy['fields'] : null;
    }
    if (fields is! Map) {
      log?.call('$_tag 没有 newLogistics.fields / logisticsDetailH5.fields');
      return null;
    }

    final company = fields['logisticCompany'] is Map ? fields['logisticCompany'] as Map : const {};
    final args = newLogistics is Map ? _exposureArgs(newLogistics) : const {};

    final mailNo = _str(fields['mailNo']).isNotEmpty ? _str(fields['mailNo']) : _str(company['mailNo']);
    final cpCode = _str(args['cpCode']);
    var cpName = _str(company['name']);
    if (cpName.isEmpty || RegExp(r'^\*+$').hasMatch(cpName)) {
      cpName = cpNameFromCode(cpCode);
    }
    final lgStatus = _str(args['lgStatus']);

    final stagesRaw = fields['multiStage'];
    final stages = stagesRaw is List ? stagesRaw : const [];
    if (stages.isEmpty) {
      log?.call('$_tag multiStage 为空（有物流字段但没有轨迹）');
    }

    var stateLabel = '';
    final indexed = <(int, Map<String, String>)>[];
    var noTime = 0;
    for (var k = 0; k < stages.length; k++) {
      final st = stages[k];
      if (st is! Map) continue;
      final tag = _str(st['title']);
      if (k == 0) stateLabel = tag;
      final text = stageText(st);
      if (text.isEmpty && tag.isEmpty) continue;
      final rawTime = st['subtitle'] ?? st['time'] ?? st['timeDesc'] ?? st['timeStr'];
      final time = normalizeTraceTime(rawTime, now: now);
      if (time == null) {
        // 末尾「送至 收件地址」是收件人卡片（无时间、含姓名电话），不是轨迹，静默跳过
        if (rawTime == null && tag.startsWith('送至')) continue;
        noTime++;
        continue;
      }
      indexed.add((k, {'tag': tag, 'time': time, 'text': text}));
    }
    if (noTime > 0) {
      log?.call('$_tag 跳过 $noTime 个时间无法解析的节点（共 ${stages.length} 个阶段）');
    }
    // 最新在前；同一时间保持页面原顺序
    indexed.sort((a, b) {
      final c = b.$2['time']!.compareTo(a.$2['time']!);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    final nodes = [for (final e in indexed) e.$2];

    var pickupCode = '';
    var stationName = '';
    for (final n in nodes) {
      final text = n['text']!;
      if (pickupCode.isEmpty) pickupCode = extractPickupCode(text);
      if (stationName.isEmpty) stationName = extractStationName(text);
      if (pickupCode.isNotEmpty && stationName.isNotEmpty) break;
    }

    return TaobaoTrace(
      mailNo: mailNo,
      cpName: cpName,
      cpCode: cpCode,
      pickupCode: pickupCode,
      stationName: stationName,
      stateLabel: stateLabel,
      lgStatus: lgStatus,
      nodes: nodes,
    );
  }

  /// 从 [start]（必须指向 `{`）开始按括号配对，返回第一个完整 JSON 对象结束位置
  /// （右花括号之后的下标）；括号不闭合返回 -1。
  ///
  /// 单次线性扫描：双引号字符串内的 `{}` 不计数，`\"`、`\\` 等转义跳过下一个字符。
  static int findJsonObjectEnd(String s, int start) {
    if (start < 0 || start >= s.length || s.codeUnitAt(start) != 0x7B) return -1;
    var depth = 0;
    var inString = false;
    for (var i = start; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (inString) {
        if (c == 0x5C /* \ */) {
          i++; // 跳过被转义的字符（含 \" 和 \\）
        } else if (c == 0x22 /* " */) {
          inString = false;
        }
        continue;
      }
      if (c == 0x22) {
        inString = true;
      } else if (c == 0x7B) {
        depth++;
      } else if (c == 0x7D) {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return -1;
  }

  /// 截出 [s] 中从 [from] 起第一个 `{` 开始的完整 JSON 对象文本；不闭合返回 null。
  static String? extractFirstJsonObject(String s, {int from = 0}) {
    final open = s.indexOf('{', from);
    if (open == -1) return null;
    final end = findJsonObjectEnd(s, open);
    return end == -1 ? null : s.substring(open, end);
  }

  /// 节点正文：`labelDesc.richContent[].text` 拼接 → `labelDesc.text` → `labelDesc`(字符串) → `text` → `desc`
  static String stageText(Map<dynamic, dynamic> stage) {
    final labelDesc = stage['labelDesc'];
    if (labelDesc is Map) {
      final rich = labelDesc['richContent'];
      if (rich is List) {
        final sb = StringBuffer();
        for (final r in rich) {
          if (r is Map) sb.write(_str(r['text']));
        }
        final joined = sb.toString().trim();
        if (joined.isNotEmpty) return joined;
      }
      final t = _str(labelDesc['text']);
      if (t.isNotEmpty) return t;
    } else if (labelDesc is String && labelDesc.trim().isNotEmpty) {
      return labelDesc.trim();
    }
    final text = _str(stage['text']);
    if (text.isNotEmpty) return text;
    return _str(stage['desc']);
  }

  static final _pickupCodeReg =
      RegExp(r'(?:取件码|取货码|提货码|凭码)\s*(?:为|是)?\s*[:：]?\s*([A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)');

  /// 从一段轨迹正文里取取件码（必须含数字），取不到返回空串
  static String extractPickupCode(String text) {
    for (final m in _pickupCodeReg.allMatches(text)) {
      final code = m.group(1)!;
      if (RegExp(r'\d').hasMatch(code) && code.length <= 16) return code;
    }
    return '';
  }

  static final _stationAfterVerbReg = RegExp(
    r'(?:暂存至|存放至|放至|放入|已到达|到达|已在|送至|投递至|已由)\s*'
    r'([\u4e00-\u9fa5A-Za-z0-9（）()·\-]{2,40}(?:菜鸟驿站|驿站|快递柜|丰巢柜|自提点|代收点|服务站|门店|超市))',
  );
  static final _stationBracketReg =
      RegExp(r'【([^【】]{2,40}(?:菜鸟驿站|驿站|快递柜|丰巢柜|自提点|代收点|服务站|门店|超市))】');

  /// 从一段轨迹正文里取驿站/代收点名，取不到返回空串
  static String extractStationName(String text) {
    final b = _stationBracketReg.firstMatch(text);
    if (b != null) return b.group(1)!.trim();
    final m = _stationAfterVerbReg.firstMatch(text);
    if (m != null) return m.group(1)!.trim();
    return '';
  }

  /// 物流公司编码 → 中文名（页面 name 缺失或被打码时的兜底；未知编码原样返回）
  static String cpNameFromCode(String cpCode) {
    const map = {
      'YUNDA': '韵达快递',
      'YTO': '圆通速递',
      'ZTO': '中通快递',
      'STO': '申通快递',
      'POSTB': '邮政快递包裹',
      'EMS': 'EMS',
      'SF': '顺丰速运',
      'JD': '京东快递',
      'JTSD': '极兔速递',
      'DBKD': '德邦快递',
      'HTKY': '百世快递',
    };
    return map[cpCode.toUpperCase()] ?? cpCode;
  }

  /// `events.exposureItemV2[*].fields.args` 里第一个带 cpCode 的
  static Map<dynamic, dynamic> _exposureArgs(Map<dynamic, dynamic> newLogistics) {
    final events = newLogistics['events'];
    if (events is! Map) return const {};
    final list = events['exposureItemV2'];
    if (list is! List) return const {};
    for (final e in list) {
      if (e is! Map) continue;
      final f = e['fields'];
      final a = f is Map ? f['args'] : null;
      if (a is Map && a['cpCode'] != null) return a;
    }
    return const {};
  }

  static String _str(Object? v) => v == null || v is Map || v is List ? '' : v.toString().trim();

  /// 日志里的 code 只保留 [A-Za-z0-9_]，最多 40 个字符
  static String _safeCode(Object? code) {
    final s = code.toString().replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
    return s.length > 40 ? s.substring(0, 40) : s;
  }

  static bool _isWs(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

  /// 订单列表里的订单是否值得请求物流详情：`statusInfo.operations` 里有「查看物流」。
  /// 饿了么等 bizType 5000 订单没有这个按钮，请求详情只会返回 JUMP_302。
  static bool orderHasLogistics(Map<dynamic, dynamic> mainOrder) {
    final statusInfo = mainOrder['statusInfo'];
    if (statusInfo is! Map) return false;
    final ops = statusInfo['operations'];
    if (ops is! List) return false;
    for (final op in ops) {
      if (op is! Map) continue;
      if (_str(op['text']).contains('查看物流') || _str(op['id']) == 'viewLogistic') return true;
    }
    return false;
  }
}
