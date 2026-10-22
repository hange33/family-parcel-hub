// P11-b：淘宝物流详情 SSR 解析（括号配对截取 JSON）。
// fixture 由仓库外脚本从 CEO 真机采集包生成：订单号、运单号、手机号、姓名、地址、驿站、快递员等
// 全部换成假值，正文按关键词套模板重写，只保留结构（运单号打码形态、物流公司编码、节点数、节点时间格式）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/engine/logistics_status_engine.dart';
import 'package:pickup_app/core/models/package_status.dart';
import 'package:pickup_app/core/parser/taobao_trace_parser.dart';

final _contract = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$');
final _now = DateTime.parse('2026-10-07T09:00:00+08:00');
const _fixtureDir = 'test/fixtures/taobao';

String _fixture(String name) => File('$_fixtureDir/$name').readAsStringSync();

void _expectContractAndOrder(List<Map<String, String>> nodes) {
  for (final n in nodes) {
    expect(_contract.hasMatch(n['time']!), isTrue, reason: '不合约定的 time: ${n['time']}');
    expect(n.keys.toSet(), {'tag', 'time', 'text'});
  }
  for (var i = 1; i < nodes.length; i++) {
    expect(nodes[i - 1]['time']!.compareTo(nodes[i]['time']!) >= 0, isTrue, reason: '没有按最新在前排序');
  }
}

/// 用假数据拼一个 SSR 页：标记后接 [payload]，模拟页面立即执行函数尾巴
String _page(String payload) => '<html><body><script>!function(){window[\'$taobaoSsrMarker$payload'
    '</script><script>var other = {"x":1};</script></body></html>';

String _detailJson({String name = '***', String cpCode = 'YUNDA', required List<Map<String, Object>> stages}) =>
    jsonEncode({
      'result': {
        'data': {
          'newLogistics': {
            'fields': {
              'logisticCompany': {'mailNo': 'TEST0000000001', 'name': name},
              'mailNo': 'TEST0000000001',
              'multiStage': stages,
            },
            'events': {
              'exposureItemV2': [
                {
                  'fields': {
                    'args': {'cpCode': cpCode, 'lgStatus': 'TRANSPORT'},
                  },
                },
              ],
            },
          },
        },
      },
    });

void main() {
  group('真机样本 fixture（已脱敏）', () {
    test('在途包裹 1：韵达，7 个阶段 → 6 个带时间的节点（末尾「送至」节点无时间不写入）', () {
      final logs = <String>[];
      final t = TaobaoTraceParser.parseHtml(_fixture('ssr_detail_transit_1.txt'), now: _now, log: logs.add)!;
      expect(t.cpCode, 'YUNDA');
      expect(t.cpName, '韵达快递'); // 采集器把 name 打成 ***，按 cpCode 兜底
      expect(t.mailNo, '0000*******0001');
      expect(t.stateLabel, '运输中');
      expect(t.lgStatus, 'TRANSPORT');
      expect(t.nodes.length, 6);
      expect(t.nodes.first, {
        'tag': '运输中',
        'time': '2026-10-07 01:05:00',
        'text': '【测试市】已离开 测试分拨中心；发往 测试转运中心（物流问题请拨打专属电话：1**********）',
      });
      expect(t.nodes.last['time'], '2026-10-06 07:17:00');
      expect(t.nodes.last['tag'], '已下单');
      expect(t.nodes.any((n) => n['text']!.contains('送至') || n['tag']!.contains('送至')), isFalse);
      expect(t.pickupCode, '');
      _expectContractAndOrder(t.nodes);
      expect(logs, isEmpty); // 「送至」收件人卡片静默跳过，不算解析失败
    });

    test('在途包裹 2：邮政，11 个阶段 → 10 个节点', () {
      final t = TaobaoTraceParser.parseHtml(_fixture('ssr_detail_transit_2.txt'), now: _now)!;
      expect(t.cpCode, 'POSTB');
      expect(t.cpName, '邮政快递包裹');
      expect(t.mailNo, '0000*****0002');
      expect(t.stateLabel, '运输中');
      expect(t.nodes.length, 10);
      expect(t.nodes.first['time'], '2026-10-06 16:01:00');
      expect(t.nodes.last['time'], '2026-10-06 07:17:00');
      _expectContractAndOrder(t.nodes);
    });

    test('已签收包裹：圆通，14 个阶段 → 13 个节点，同一时间的两条保持页面顺序', () {
      final t = TaobaoTraceParser.parseHtml(_fixture('ssr_detail_signed_1.txt'), now: _now)!;
      expect(t.cpCode, 'YTO');
      expect(t.cpName, '圆通速递');
      expect(t.mailNo, 'YT00*******0003');
      expect(t.stateLabel, '已签收');
      expect(t.lgStatus, 'SIGN');
      expect(t.nodes.length, 13);
      expect(t.nodes.first['tag'], '已签收');
      expect(t.nodes.first['time'], '2026-09-05 19:33:00');
      expect(t.stationName, '测试小区北门店');
      final same = t.nodes.where((n) => n['time'] == '2026-08-31 13:12:00').toList();
      expect(same.map((n) => n['tag']), ['派送中', '运输中']);
      _expectContractAndOrder(t.nodes);
    });

    test('15 个订单：3 个有「查看物流」→ 解析出 2 个在途 + 1 个已签收；其余 12 个不请求', () {
      final bought = jsonDecode(_fixture('bought_list.json')) as Map<String, dynamic>;
      final inner = jsonDecode((bought['data'] as Map)['result'] as String) as Map<String, dynamic>;
      final orders = (inner['mainOrders'] as List).cast<Map<String, dynamic>>();
      expect(orders.length, 15);
      final withLogistics = orders.where(TaobaoTraceParser.orderHasLogistics).toList();
      final skipped = orders.where((o) => !TaobaoTraceParser.orderHasLogistics(o)).toList();
      expect(withLogistics.length, 3);
      expect(skipped.length, 12);
      expect(skipped.every((o) => (o['extra'] as Map)['bizType'] == 5000), isTrue);

      final statuses = <PackageStatus>[];
      for (final name in ['ssr_detail_transit_1.txt', 'ssr_detail_transit_2.txt', 'ssr_detail_signed_1.txt']) {
        final t = TaobaoTraceParser.parseHtml(_fixture(name), now: _now)!;
        statuses.add(LogisticsStatusEngine.derive(
          events: t.nodes,
          isOrderSigned: t.stateLabel.contains('签收') || t.lgStatus == 'SIGN',
          pickupCode: t.pickupCode,
          stationName: t.stationName,
        ).status);
      }
      expect(statuses.where((s) => s == PackageStatus.transit).length, 2);
      expect(statuses.where((s) => s == PackageStatus.pickedUp).length, 1);
    });

    test('饿了么订单详情 JUMP_302：返回 null，日志写明 code', () {
      final logs = <String>[];
      expect(TaobaoTraceParser.parseHtml(_fixture('ssr_detail_jump302.txt'), log: logs.add), isNull);
      expect(logs.single, contains('code=JUMP_302'));
      expect(logs.single, isNot(contains('1000000000000000099')));
    });

    test('日志不含运单号', () {
      final logs = <String>[];
      for (final name in ['ssr_detail_transit_1.txt', 'ssr_detail_transit_2.txt', 'ssr_detail_signed_1.txt']) {
        TaobaoTraceParser.parseHtml(_fixture(name), now: _now, log: logs.add);
      }
      expect(logs.join('\n'), isNot(contains('0000*')));
      expect(logs.join('\n'), isNot(contains('YT00')));
    });
  });

  group('括号配对截取 JSON（边界）', () {
    final stage = <String, Object>{
      'title': '运输中',
      'subtitle': '10-07 01:05',
      'labelDesc': {'text': '快件已到达测试转运中心'},
    };

    test('末尾跟 }(); 也能解析（根因回归）', () {
      final t = TaobaoTraceParser.parseHtml(_page('${_detailJson(stages: [stage])}}();'), now: _now);
      expect(t, isNotNull);
      expect(t!.nodes.single['time'], '2026-10-07 01:05:00');
    });

    test('字符串里带 { } [ ] 不影响配对', () {
      const s = r'{"a":"x{y}}}z","b":{"c":"]{["},"d":"}"}}();var t={"no":1};';
      expect(TaobaoTraceParser.extractFirstJsonObject(s), r'{"a":"x{y}}}z","b":{"c":"]{["},"d":"}"}');
      final page = _page('${_detailJson(stages: [
            {
              'title': '派送中',
              'subtitle': '10-07 08:00',
              'labelDesc': {'text': '快递员{测试}正在派件}}}，取件码 {3-2-1002}'},
            },
          ])}}();');
      final t = TaobaoTraceParser.parseHtml(page, now: _now)!;
      expect(t.nodes.single['text'], '快递员{测试}正在派件}}}，取件码 {3-2-1002}');
    });

    test('转义引号 \\" 和转义反斜杠 \\\\ 不会提前结束字符串', () {
      const s = r'{"a":"he said \"}\" ok","b":"C:\\","c":"\\\"}","d":1}}();';
      final got = TaobaoTraceParser.extractFirstJsonObject(s)!;
      expect(got, r'{"a":"he said \"}\" ok","b":"C:\\","c":"\\\"}","d":1}');
      final m = jsonDecode(got) as Map;
      expect(m['a'], 'he said "}" ok');
      expect(m['b'], r'C:\');
      expect(m['c'], r'\"}');
      expect(m['d'], 1);

      final page = _page('${_detailJson(stages: [
            {
              'title': '运输中',
              'subtitle': '10-07 01:05',
              'labelDesc': {'text': r'他说"到了}"，路径 C:\ 结束'},
            },
          ])}}();');
      expect(TaobaoTraceParser.parseHtml(page, now: _now)!.nodes.single['text'], r'他说"到了}"，路径 C:\ 结束');
    });

    test('标记后的 JSON 被截断（括号不闭合）：返回 null，不解析出半截数据', () {
      final full = _detailJson(stages: [stage]);
      for (final cut in [full.length - 1, full.length ~/ 2, 20, 1]) {
        final logs = <String>[];
        final html = 'xx $taobaoSsrMarker${full.substring(0, cut)}';
        expect(TaobaoTraceParser.parseHtml(html, now: _now, log: logs.add), isNull, reason: 'cut=$cut');
        expect(logs.single, contains('括号不闭合'));
      }
      // 内层对象闭合、外层没闭合：不能把内层当结果
      expect(TaobaoTraceParser.findJsonObjectEnd('{"result":{"data":{}}', 0), -1);
      // 截断在字符串中间、在转义符后面
      expect(TaobaoTraceParser.extractFirstJsonObject('{"a":"abc}'), isNull);
      expect(TaobaoTraceParser.extractFirstJsonObject(r'{"a":"abc\'), isNull);
    });

    test('页面里找不到标记：返回 null 并记原因', () {
      final logs = <String>[];
      const html = '<html><script>var x = {"result":{"data":{}}};</script>登录</html>';
      expect(TaobaoTraceParser.parseHtml(html, log: logs.add), isNull);
      expect(logs.single, contains('未找到 SSR 数据标记'));
    });

    test('标记后不是 { ：返回 null，不去后面别处找对象', () {
      final logs = <String>[];
      expect(TaobaoTraceParser.parseHtml('$taobaoSsrMarker undefined; var a = {"result":{}};', log: logs.add), isNull);
      expect(logs.single, contains('标记后不是 JSON 对象'));
    });

    test('括号配平但 JSON 不合法：返回 null，日志不带原文', () {
      final logs = <String>[];
      expect(TaobaoTraceParser.parseHtml(_page('{"orderId":"9876543210123456789",,}}();'), log: logs.add), isNull);
      expect(logs.single, contains('JSON 解析失败'));
      expect(logs.single, isNot(contains('9876543210123456789')));
    });

    test('没有物流字段 / 没有 result：返回 null 并记原因', () {
      final logs = <String>[];
      expect(TaobaoTraceParser.parseHtml(_page('{"result":{"data":{"root":{}}}}}();'), log: logs.add), isNull);
      expect(TaobaoTraceParser.parseHtml(_page('{"other":1}}();'), log: logs.add), isNull);
      expect(logs, [contains('没有 newLogistics.fields'), contains('没有 result 字段')]);
    });

    test('大输入线性扫描：5MB 不闭合 / 5MB 字符串里全是括号都很快', () {
      final sw = Stopwatch()..start();
      final unclosed = '$taobaoSsrMarker{"a":"${'{x}' * 1700000}';
      expect(TaobaoTraceParser.parseHtml(unclosed), isNull);
      final opens = '$taobaoSsrMarker${'{' * 5000000}';
      expect(TaobaoTraceParser.parseHtml(opens), isNull);
      final bigString = '{"a":"${r'\"{[' * 1000000}"}}();';
      expect(TaobaoTraceParser.extractFirstJsonObject(bigString)!.length, bigString.length - 4);
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('P11-a 采集的 raw 文本（已截到标记后）也能直接解析', () {
      final t = TaobaoTraceParser.parseSsrText('  ${_detailJson(stages: [stage])}}();', now: _now);
      expect(t!.nodes.length, 1);
    });
  });

  group('字段提取', () {
    test('取件码在全部节点里找，取最新一条；物流公司名非打码时直接用', () {
      final t = TaobaoTraceParser.parseHtml(
        _page('${_detailJson(name: '测试快递', stages: [
              {'title': '已签收', 'subtitle': '10-07 08:30', 'labelDesc': {'text': '您的快件已签收，感谢使用'}},
              {
                'title': '待取件',
                'subtitle': '10-07 08:00',
                'labelDesc': {
                  'richContent': [
                    {'text': '您的快件已暂存至测试小区南门店菜鸟驿站，取件码 3-2-1002，联系'},
                    {'event': 'talkPhone', 'text': '1**********'},
                  ],
                  'text': '忽略',
                },
              },
              {'title': '待取件', 'subtitle': '10-06 08:00', 'labelDesc': {'text': '【测试旧驿站】取件码：9-9-9999'}},
            ])}}();'),
        now: _now,
      )!;
      expect(t.cpName, '测试快递');
      expect(t.pickupCode, '3-2-1002');
      expect(t.stationName, '测试小区南门店菜鸟驿站');
      expect(t.nodes[1]['text'], '您的快件已暂存至测试小区南门店菜鸟驿站，取件码 3-2-1002，联系1**********');
    });

    test('无年份时间跨年补上一年；解析不出的时间不写该节点并记数量', () {
      final logs = <String>[];
      final t = TaobaoTraceParser.parseHtml(
        _page('${_detailJson(stages: [
              {'title': '运输中', 'subtitle': '01-01 08:00', 'labelDesc': {'text': '快件已发出'}},
              {'subtitle': '昨天 10:00', 'labelDesc': {'text': '快件已揽收'}},
              {'subtitle': '12-31 23:00', 'labelDesc': {'text': '商品已经下单'}},
            ])}}();'),
        now: DateTime.parse('2027-01-01T09:00:00+08:00'),
        log: logs.add,
      )!;
      expect(t.nodes.map((n) => n['time']), ['2027-01-01 08:00:00', '2026-12-31 23:00:00']);
      expect(logs.single, contains('跳过 1 个'));
    });

    test('订单是否有「查看物流」：按文案或 viewLogistic', () {
      expect(TaobaoTraceParser.orderHasLogistics({
        'statusInfo': {
          'operations': [
            {'text': '查看物流'},
          ],
        },
      }), isTrue);
      expect(TaobaoTraceParser.orderHasLogistics({
        'statusInfo': {
          'operations': [
            {'id': 'viewLogistic', 'text': ''},
          ],
        },
      }), isTrue);
      expect(TaobaoTraceParser.orderHasLogistics({'statusInfo': {'operations': []}}), isFalse);
      expect(TaobaoTraceParser.orderHasLogistics({'statusInfo': 'x'}), isFalse);
      expect(TaobaoTraceParser.orderHasLogistics({}), isFalse);
    });
  });
}
