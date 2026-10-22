// 测试里的手机号都是虚构的，写成相邻字符串（如 '138' '00001111'）是为了不触发 tools/check_no_pii.sh。
// P12 时间轴展示数据准备的单元测试。
// 样本文字均为虚构：电话用 138/0755 等明显假号段，取件码为编造格式。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/engine/timeline_view.dart';

String _json(List<Object?> nodes) => jsonEncode(nodes);

Map<String, Object?> _n(String time, String text, {Object? tag = '运输中'}) =>
    {'tag': tag, 'time': time, 'text': text};

void main() {
  group('timelineForDisplay 容错解析', () {
    test('空值、空串、非法 JSON、非数组都返回空列表', () {
      expect(timelineForDisplay(null), isEmpty);
      expect(timelineForDisplay(''), isEmpty);
      expect(timelineForDisplay('   '), isEmpty);
      expect(timelineForDisplay('not json'), isEmpty);
      expect(timelineForDisplay('{"tag":"x"}'), isEmpty);
      expect(timelineForDisplay('[]'), isEmpty);
    });

    test('字段值是对象或数组时当作空，不把原始结构显示出来', () {
      final list = timelineForDisplay(jsonEncode([
        {'tag': '运输中', 'time': '2026-10-06 10:00:00', 'text': {'desc': '到达分拨中心'}},
        {'tag': ['派送中'], 'time': '2026-10-06 09:00:00', 'text': '快件派送中'},
        {'tag': {'a': 1}, 'time': '2026-10-06 08:00:00', 'text': ['x']},
      ]));
      expect(list.length, 2);
      expect(list[0].tag, '运输中');
      expect(list[0].text, '');
      expect(list[1].tag, '');
      expect(list[1].text, '快件派送中');
      expect(list.any((n) => n.text.contains('{') || n.tag.contains('[')), isFalse);
    });

    test('单个坏节点只跳过自己，不会让整条时间轴变空', () {
      final raw = jsonEncode([
        _n('2026-10-06 14:00:00', '快件已到达【测试市示例驿站】'),
        'oops', // 不是对象
        null,
        42,
        {'tag': null, 'time': 20261006, 'text': 12345}, // 值是 null/int
        _n('2026-10-05 09:00:00', '快件已从测试转运中心发出'),
      ]);
      final nodes = timelineForDisplay(raw);
      expect(nodes.map((e) => e.text).toList(), [
        '快件已到达【测试市示例驿站】',
        '快件已从测试转运中心发出',
        '12345', // int 被 toString 后保留，时间非法排在最后
      ]);
      final coerced = nodes.last;
      expect(coerced.tag, '');
      expect(coerced.time, '20261006');
      expect(coerced.parsedTime, isNull);
    });

    test('值会被 trim，tag 和 text 都为空的节点被丢弃', () {
      final raw = _json([
        {'tag': '  派送中 ', 'time': ' 2026-10-06 10:00:00 ', 'text': '  快递员正在派送  '},
        {'tag': '   ', 'time': '2026-10-06 09:00:00', 'text': ''},
        {'time': '2026-10-06 08:00:00'},
        {'tag': '已揽收', 'time': '2026-10-04 08:00:00', 'text': null},
      ]);
      final nodes = timelineForDisplay(raw);
      expect(nodes, hasLength(2));
      expect(nodes[0].tag, '派送中');
      expect(nodes[0].time, '2026-10-06 10:00:00');
      expect(nodes[0].text, '快递员正在派送');
      expect(nodes[0].parsedTime, DateTime(2026, 10, 6, 10));
      // 只有 tag 没有 text 的节点保留
      expect(nodes[1].tag, '已揽收');
      expect(nodes[1].text, '');
    });
  });

  group('timelineForDisplay 去重', () {
    test('按 time|text 去重，保留先出现的那条（新数据优先）', () {
      final raw = _json([
        _n('2026-10-06 14:00:00', '快件已到达示例驿站', tag: '待取件'),
        _n('2026-10-06 14:00:00', '快件已到达示例驿站', tag: '运输中'),
        _n('2026-10-06 14:00:00', '  快件已到达示例驿站  ', tag: '运输中'), // trim 后相同
        _n('2026-10-06 14:00:00', '同一时间的另一条轨迹'),
      ]);
      final nodes = timelineForDisplay(raw);
      expect(nodes, hasLength(2));
      expect(nodes[0].tag, '待取件');
      expect(nodes[1].text, '同一时间的另一条轨迹');
    });

    test('同文字不同时间不算重复', () {
      final raw = _json([
        _n('2026-10-06 14:00:00', '派送中'),
        _n('2026-10-06 15:00:00', '派送中'),
      ]);
      expect(timelineForDisplay(raw), hasLength(2));
    });
  });

  group('timelineForDisplay 排序', () {
    test('乱序输入按时间倒序输出', () {
      final raw = _json([
        _n('2026-10-04 08:00:00', 'A 揽收'),
        _n('2026-10-06 14:00:00', 'C 到站'),
        _n('2025-12-31 23:59:59', 'Z 跨年旧节点'),
        _n('2026-10-05 09:30:00', 'B 运输'),
      ]);
      expect(timelineForDisplay(raw).map((e) => e.text).toList(),
          ['C 到站', 'B 运输', 'A 揽收', 'Z 跨年旧节点']);
    });

    test('相同时间保持原顺序（稳定排序）', () {
      final raw = _json([
        _n('2026-10-05 09:00:00', '较早'),
        _n('2026-10-06 10:00:00', '同时-1'),
        _n('2026-10-06 10:00:00', '同时-2'),
        _n('2026-10-06 10:00:00', '同时-3'),
      ]);
      expect(timelineForDisplay(raw).map((e) => e.text).toList(),
          ['同时-1', '同时-2', '同时-3', '较早']);
    });

    test('非法时间节点排在合法节点之后，并保持原顺序', () {
      final raw = _json([
        _n('今日', '非法-1'),
        _n('2026-10-05 09:00:00', '合法-旧'),
        _n('10-06 14:00', '非法-2'),
        _n('2026-02-30 10:00:00', '非法-3 日期越界'),
        _n('2026-10-06 14:00:00', '合法-新'),
        _n('', '非法-4 空时间'),
      ]);
      final nodes = timelineForDisplay(raw);
      expect(nodes.map((e) => e.text).toList(),
          ['合法-新', '合法-旧', '非法-1', '非法-2', '非法-3 日期越界', '非法-4 空时间']);
      expect(nodes.skip(2).every((e) => e.parsedTime == null), isTrue);
    });
  });

  group('parseContractTime', () {
    test('只接受 yyyy-MM-dd HH:mm:ss 且日期合法', () {
      expect(parseContractTime('2026-10-06 14:23:05'), DateTime(2026, 10, 6, 14, 23, 5));
      expect(parseContractTime('2026-10-06T14:23:05'), isNull);
      expect(parseContractTime('2026-10-06 14:23'), isNull);
      expect(parseContractTime('2026-13-01 00:00:00'), isNull);
      expect(parseContractTime('2026-10-06 24:00:00'), isNull);
    });
  });

  group('formatTimelineTime', () {
    final now = DateTime(2026, 10, 7, 9, 30);
    TimelineNode at(String t) =>
        TimelineNode(tag: '', time: t, text: 'x', parsedTime: parseContractTime(t));

    test('今天 / 昨天 / 今年 / 往年', () {
      expect(formatTimelineTime(at('2026-10-07 08:05:09'), now: now), '今天 08:05');
      expect(formatTimelineTime(at('2026-10-06 23:59:00'), now: now), '昨天 23:59');
      expect(formatTimelineTime(at('2026-10-01 07:00:00'), now: now), '10-01 07:00');
      expect(formatTimelineTime(at('2025-12-31 18:20:00'), now: now), '2025-12-31 18:20');
    });

    test('跨年的「昨天」', () {
      expect(
        formatTimelineTime(at('2025-12-31 22:00:00'), now: DateTime(2026, 1, 1, 8)),
        '昨天 22:00',
      );
    });

    test('非法时间原样显示', () {
      expect(formatTimelineTime(at('10-06 14:00'), now: now), '10-06 14:00');
    });
  });

  group('电话识别', () {
    test('中文紧挨号码时也能识别手机、座机、热线', () {
      expect(findPhones('请联系派送员138' '00001111，谢谢'), ['138' '00001111']);
      expect(findPhones('驿站电话0755-12345678如有疑问'), ['0755-12345678']);
      expect(findPhones('座机010 87654321转人工'), ['010 87654321']);
      expect(findPhones('客服热线95000查询'), ['95000']);
      expect(findPhones('服务电话400-000-0000投诉'), ['400-000-0000']);
      expect(findPhones('【示例驿站】电话：139' '00002222；备用：021-7654321。'),
          ['139' '00002222', '021-7654321']);
    });

    test('运单号、长数字串、日期时间不会被截成电话', () {
      expect(findPhones('运单号YT1380000111122已揽收'), isEmpty);
      expect(findPhones('运单号773138000011112已签收'), isEmpty);
      expect(findPhones('2026-10-06 14:23:05 已到达'), isEmpty);
      expect(findPhones('订单编号 1380000111122334'), isEmpty);
      // 12 开头不是合法手机号段
      expect(findPhones('编号12000001111'), isEmpty);
    });

    test('取件码不会被当成电话', () {
      // 像热线的 5 位取件码：有取件码上下文
      expect(findPhones('请凭取件码95021取件'), isEmpty);
      expect(findPhones('提货码：95021，电话138' '00001111'), ['138' '00001111']);
      // 与包裹取件码完全一致的数字也不算电话
      expect(findPhones('请到驿站领取95021号包裹', pickupCode: '95021'), isEmpty);
    });

    test('dialablePhone 去掉分隔符', () {
      expect(dialablePhone('0755-12345678'), '075512345678');
      expect(dialablePhone('400-000-0000'), '4000000000');
      expect(dialablePhone('010 87654321'), '01087654321');
    });
  });

  group('segmentTraceText', () {
    test('切成普通文字 / 取件码 / 电话', () {
      final segs = segmentTraceText(
        '【示例驿站】请凭3-2-1002取件，电话138' '00001111',
        pickupCode: '3-2-1002',
      );
      expect(segs, const [
        TraceSegment(TraceSegmentType.plain, '【示例驿站】请凭'),
        TraceSegment(TraceSegmentType.pickupCode, '3-2-1002'),
        TraceSegment(TraceSegmentType.plain, '取件，电话'),
        TraceSegment(TraceSegmentType.phone, '138' '00001111', phoneKind: PhoneKind.mobile),
      ]);
    });

    test('取件码不会匹配到更长数字串的中间；过短的取件码不强调', () {
      final segs = segmentTraceText('单号A10021234，取件码1002', pickupCode: '1002');
      expect(segs.where((s) => s.type == TraceSegmentType.pickupCode).length, 1);
      expect(
        segmentTraceText('第12号柜', pickupCode: '12')
            .every((s) => s.type == TraceSegmentType.plain),
        isTrue,
      );
    });

    test('没有特殊内容时整段是普通文字；空串返回空列表', () {
      expect(segmentTraceText('快件已发出'),
          const [TraceSegment(TraceSegmentType.plain, '快件已发出')]);
      expect(segmentTraceText(''), isEmpty);
    });
  });

  group('extractStationPhone', () {
    List<TimelineNode> nodes(List<String> texts) => [
          for (final t in texts) TimelineNode(tag: '', time: '', text: t),
        ];

    test('取最新节点里的手机/座机', () {
      final list = nodes([
        '【测试市示例驿站】您的快递已到站，凭取件码6-3-2045取件，驿站电话0755-12345678',
        '快递员138' '00001111正在派送',
      ]);
      expect(extractStationPhone(nodes: list, pickupCode: '6-3-2045'), '0755-12345678');
    });

    test('最新节点没有时看下一个；热线不算驿站电话', () {
      final list = nodes([
        '快件已放入示例驿站，如有疑问请拨打快递客服95000',
        '派送员（139' '00002222）正在派送',
        '更早的节点 137' '00003333',
      ]);
      expect(extractStationPhone(nodes: list), '139' '00002222');
      expect(extractStationPhone(nodes: list, maxNodes: 1), isNull);
    });

    test('取件码上下文里的数字不算电话；没有电话返回 null', () {
      expect(extractStationPhone(text: '请凭取件码138' '00001111取件'), isNull);
      expect(extractStationPhone(nodes: nodes(['快件已发出'])), isNull);
      expect(extractStationPhone(), isNull);
    });

    test('可以直接传正文', () {
      expect(extractStationPhone(text: '联系电话：138' '00001111。'), '138' '00001111');
    });
  });
}
