// P14：拼多多 / 京东写入轨迹前统一规范化时间，time|text 相同保留带标签的节点。
// 全部为自造数据（结构复刻拼多多旧用例案例 4、5 和 QA「连接器约定」用例），不含真实个人信息。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/engine/timeline_merge.dart';
import 'package:pickup_app/core/models/package_status.dart';
import 'package:pickup_app/platform/connectors/jd_trace_parser.dart';
import 'package:pickup_app/platform/connectors/pdd_connector.dart';
import 'package:pickup_app/platform/connectors/pdd_trace_parser.dart';

final _contract = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$');
final _now = DateTime.parse('2026-10-07T09:00:00+08:00');

void _expectAllContract(List<dynamic> nodes) {
  for (final n in nodes) {
    expect(_contract.hasMatch(n['time'] as String), isTrue, reason: '不合约定的 time: ${n['time']}');
  }
}

/// 按约定倒序（与 timeline_merge / P12 一致：字符串比较）
List<Map<String, String>> _sorted(List<Map<String, String>> nodes) =>
    [...nodes]..sort((a, b) => b['time']!.compareTo(a['time']!));

void main() {
  group('连接器约定：DOM 兜底解析的 time 是 yyyy-MM-dd HH:mm:ss', () {
    test('拼多多：/ 分隔、缺秒的节点规范化后最新节点排在最前', () {
      const dom = '包裹追踪\n'
          '2026/10/07 08:05\n'
          '【测试市示例驿站】您的快递已到站，请及时取件\n'
          '2026-10-06 10:00:22\n'
          '快件已到达测试转运中心\n'
          '2026.10.05 21:10\n'
          '快件已从测试仓库发出\n';
      final parsed = parsePddDomTimeline(dom, now: _now);
      expect(parsed.length, 3);
      _expectAllContract(parsed);
      expect(parsed.first['time'], '2026-10-07 08:05:00');
      final merged = jsonDecode(mergeTimelineJson(null, jsonEncode(_sorted(parsed)))!) as List;
      expect(merged.first['text'], contains('已到站'));
    });

    test('京东：缺秒的节点规范化', () {
      const dom = '订单跟踪\n'
          '2026-10-07 08:05\n'
          '您的快件正在派送中，配送员测试员\n'
          '2026-10-06 10:00:22\n'
          '您的快件已到达测试营业部\n';
      final parsed = parseJdDomTimeline(dom, now: _now);
      expect(parsed.length, 2);
      _expectAllContract(parsed);
      expect(parsed.first['time'], '2026-10-07 08:05:00');
      expect(parsed.last['time'], '2026-10-06 10:00:22');
    });

    test('京东：日期越界的时间行不写入，其后的描述也不挂到上一条时间上', () {
      const dom = '2026-10-07 08:05\n您的快件正在派送中\n2026-02-30 10:00\n您的快件已到达测试营业部\n';
      final parsed = parseJdDomTimeline(dom, now: _now);
      expect(parsed.length, 1);
      expect(parsed.single['text'], '您的快件正在派送中');
    });
  });

  group('拼多多 window.name JSON 兜底', () {
    test('epoch 毫秒、/ 分隔都规范化，解析不出的时间不写入', () {
      final root = {
        'data': {
          'traces': [
            {'time': 1791273600000, 'desc': '快件已到达测试转运中心'},
            {'time': '2026/10/07 08:05', 'desc': '您的快递已到站'},
            {'time': '昨天 14:03', 'desc': '快件已揽收'},
          ]
        }
      };
      final nodes = extractPddTimelineFromJson(root, now: _now);
      expect(nodes.map((n) => n['time']).toList(), ['2026-10-06 16:00:00', '2026-10-07 08:05:00']);
    });
  });

  group('拼多多 parseLogisticsText（案例 4、5 结构）', () {
    // 复刻案例 4/5 的结构：「标签 + 时间」同一行，正文在下一行；后面几条只有时间没有标签
    const page = '''
圆通速递: YT0000000000001
订单编号: 000000-000000000000000
派件中 2026-10-05 06:35:07
【测试市示例区网点】的测试快递员正在为您派件
运输中 2026-10-05 06:34:17
您的快件已经到达【测试市示例区网点】
2026-10-05 02:48:46
您的快件离开【测试转运中心】，已发往【测试市示例区网点】
已发货 2026-10-02 08:41:23
商家已发货，正在通知圆通快递取件
''';

    test('最新节点保留标签「派件中」（DOM 兜底的无标签节点不再挤掉带标签节点）', () {
      final r = PddH5Connector.parseLogisticsText(page, orderSn: '000000-000000000000000', now: _now)!;
      final list = jsonDecode(r.rawTimelineJson!) as List;
      expect(list.length, 4);
      expect(list.first['tag'], '派件中');
      expect(list.first['time'], '2026-10-05 06:35:07');
      expect(list.first['text'], contains('正在为您派件'));
      expect(list[1]['tag'], '运输中');
      expect(list[2]['tag'], '');
      expect(list[3]['tag'], '已发货');
      expect(r.status, PackageStatus.delivering);
    });

    test('/ 分隔、缺秒的标签行：规范化后带标签且排序正确', () {
      const p2 = '''
极兔速递: JT0000000000001
派件中 2026/10/07 08:05
【测试市示例网点】的测试快递员正在为您派件
2026-10-06 23:35:24
快件离开【测试转运中心】已发往【测试市示例网点】
''';
      final r = PddH5Connector.parseLogisticsText(p2, now: _now)!;
      final list = jsonDecode(r.rawTimelineJson!) as List;
      _expectAllContract(list);
      expect(list.first['time'], '2026-10-07 08:05:00');
      expect(list.first['tag'], '派件中');
      expect(list.length, 2);
    });

    test('官方 traces：epoch 时间规范化；同时间同正文时官方带标签节点保留', () {
      final r = PddH5Connector.parseLogisticsText(
        page,
        orderSn: '000000-000000000000000',
        now: _now,
        rawTraces: [
          // 1791153307000 = 北京时间 2026-10-05 06:35:07
          {'time': 1791153307000, 'info': '【测试市示例区网点】的测试快递员正在为您派件', 'status': 'DELIVERING'},
          {'time': '无效时间', 'info': '这条不应写入', 'status': ''},
        ],
      )!;
      final list = jsonDecode(r.rawTimelineJson!) as List;
      _expectAllContract(list);
      expect(list.length, 4);
      expect(list.where((n) => n['time'] == '2026-10-05 06:35:07').length, 1);
      expect(list.first['time'], '2026-10-05 06:35:07');
      expect(list.first['tag'], isNotEmpty);
      expect(list.any((n) => n['text'] == '这条不应写入'), isFalse);
    });
  });

  group('timeline_merge：time|text 相同保留带标签的那条', () {
    String j(List<Map<String, String>> l) => jsonEncode(l);
    const t = '2026-10-05 06:35:07';
    const text = '快递员正在为您派件';

    test('新数据无标签、旧数据有标签 → 保留旧的带标签节点', () {
      final out = jsonDecode(mergeTimelineJson(
        j([{'tag': '派件中', 'time': t, 'text': text}]),
        j([{'tag': '', 'time': t, 'text': text}]),
      )!) as List;
      expect(out.length, 1);
      expect(out.single['tag'], '派件中');
    });

    test('新数据有标签、旧数据无标签 → 保留新的带标签节点', () {
      final out = jsonDecode(mergeTimelineJson(
        j([{'tag': '', 'time': t, 'text': text}]),
        j([{'tag': '派件中', 'time': t, 'text': text}]),
      )!) as List;
      expect(out.single['tag'], '派件中');
    });

    test('两条都有标签 → 仍以新数据为准（原有行为）', () {
      final out = jsonDecode(mergeTimelineJson(
        j([{'tag': '运输中', 'time': t, 'text': text}]),
        j([{'tag': '派件中', 'time': t, 'text': text}]),
      )!) as List;
      expect(out.single['tag'], '派件中');
    });

    test('同一份数据内部重复也适用', () {
      final out = jsonDecode(mergeTimelineJson(
        j([{'tag': '', 'time': '2026-10-01 00:00:00', 'text': 'x旧节点'}]),
        j([
          {'tag': '', 'time': t, 'text': text},
          {'tag': '派件中', 'time': t, 'text': text},
        ]),
      )!) as List;
      expect(out.length, 2);
      expect(out.first['tag'], '派件中');
    });
  });
}
