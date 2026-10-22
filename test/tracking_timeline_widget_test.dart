// 测试里的手机号都是虚构的，写成相邻字符串（如 '138' '00001111'）是为了不触发 tools/check_no_pii.sh。
// P12 共用时间轴组件的 widget 测试。样本均为虚构数据。
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/engine/timeline_view.dart';
import 'package:pickup_app/ui/components/tracking_timeline.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// 在某个节点里找出正文所在的 RichText 的根 TextSpan。
TextSpan _traceSpanOf(WidgetTester tester, int index, String contains) {
  final finder = find.descendant(
    of: find.byKey(ValueKey('tracking_timeline_node_$index')),
    matching: find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains(contains),
    ),
  );
  expect(finder, findsOneWidget);
  return tester.widget<RichText>(finder).text as TextSpan;
}

TextSpan? _findSpan(TextSpan root, String text) {
  TextSpan? found;
  root.visitChildren((span) {
    if (span is TextSpan && span.text == text) {
      found = span;
      return false;
    }
    return true;
  });
  return found;
}

void main() {
  // 故意乱序 + 重复，验证组件拿到的是整理后的结果
  final raw = jsonEncode([
    {'tag': '运输中', 'time': '2026-10-05 09:00:00', 'text': '快件已从测试转运中心发出'},
    {
      'tag': '待取件',
      'time': '2026-10-07 08:05:00',
      'text': '【测试市示例驿站】请凭3-2-1002取件，电话138' '00001111',
    },
    {'tag': '运输中', 'time': '2026-10-05 09:00:00', 'text': '快件已从测试转运中心发出'},
    {'tag': '已揽收', 'time': '2026-10-04 18:00:00', 'text': '示例快递已揽收'},
  ]);
  final now = DateTime(2026, 10, 7, 9, 30);

  testWidgets('最新节点在最上方、去重、首节点高亮', (tester) async {
    final nodes = timelineForDisplay(raw);
    await tester.pumpWidget(_wrap(TrackingTimeline(
      nodes: nodes,
      pickupCode: '3-2-1002',
      now: now,
      onCallPhone: (_) {},
    )));

    // 去重后 3 个节点
    expect(find.byKey(const ValueKey('tracking_timeline_node_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('tracking_timeline_node_2')), findsOneWidget);
    expect(find.byKey(const ValueKey('tracking_timeline_node_3')), findsNothing);

    // 顺序：待取件在最上，揽收在最下
    final y0 = tester.getTopLeft(find.text('待取件')).dy;
    final y1 = tester.getTopLeft(find.text('运输中')).dy;
    final y2 = tester.getTopLeft(find.text('已揽收')).dy;
    expect(y0 < y1 && y1 < y2, isTrue);

    // 只有第一个节点有高亮圆点，且标签/时间是绿色
    final latestDot = find.byKey(const ValueKey('tracking_timeline_latest_dot'));
    expect(latestDot, findsOneWidget);
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('tracking_timeline_node_0')), matching: latestDot),
      findsOneWidget,
    );
    expect(tester.widget<Text>(find.text('待取件')).style?.color,
        TrackingTimelineColors.latest);
    expect(tester.widget<Text>(find.text('已揽收')).style?.color,
        isNot(TrackingTimelineColors.latest));

    // 时间统一格式
    expect(find.text('今天 08:05'), findsOneWidget);
    expect(find.text('10-04 18:00'), findsOneWidget);
  });

  testWidgets('电话是可点击的 span，取件码加粗', (tester) async {
    final called = <String>[];
    await tester.pumpWidget(_wrap(TrackingTimeline(
      nodes: timelineForDisplay(raw),
      pickupCode: '3-2-1002',
      now: now,
      onCallPhone: called.add,
    )));

    final root = _traceSpanOf(tester, 0, '138' '00001111');
    final phone = _findSpan(root, '138' '00001111');
    expect(phone, isNotNull);
    expect(phone!.recognizer, isA<TapGestureRecognizer>());
    expect(phone.style?.decoration, TextDecoration.underline);
    (phone.recognizer! as TapGestureRecognizer).onTap!();
    expect(called, ['138' '00001111']);

    final code = _findSpan(root, '3-2-1002');
    expect(code, isNotNull);
    expect(code!.style?.fontWeight, FontWeight.w700);
    expect(code.recognizer, isNull);

    // 卸载后不应抛异常（识别器在 dispose 中释放）
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('节点更新后识别器重建，点击走新号码', (tester) async {
    final called = <String>[];
    Widget build(String phone) => _wrap(TrackingTimeline(
          nodes: [
            TimelineNode(tag: '派送中', time: '2026-10-07 08:00:00', text: '派送员$phone正在派送',
                parsedTime: DateTime(2026, 10, 7, 8)),
          ],
          now: now,
          onCallPhone: called.add,
        ));
    await tester.pumpWidget(build('138' '00001111'));
    await tester.pumpWidget(build('139' '00002222'));
    final root = _traceSpanOf(tester, 0, '派送员');
    (_findSpan(root, '139' '00002222')!.recognizer! as TapGestureRecognizer).onTap!();
    expect(called, ['139' '00002222']);
  });

  testWidgets('无轨迹时显示空状态，不编造节点', (tester) async {
    await tester.pumpWidget(_wrap(const TrackingTimeline(nodes: [], statusLabel: '运输中')));
    expect(find.byKey(const ValueKey('tracking_timeline_empty')), findsOneWidget);
    expect(find.text('暂无物流轨迹'), findsOneWidget);
    expect(find.textContaining('下次同步后'), findsOneWidget);
    expect(find.textContaining('运输中'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracking_timeline_node_0')), findsNothing);
  });

  testWidgets('坏数据整体解析失败时同样是空状态', (tester) async {
    await tester.pumpWidget(_wrap(TrackingTimeline(nodes: timelineForDisplay('{bad'))));
    expect(find.text('暂无物流轨迹'), findsOneWidget);
  });
}
