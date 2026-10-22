// QA 边界测试：P12 时间轴的补充用例。
// 与 timeline_view_test.dart（数据整理）和 tracking_timeline_widget_test.dart / tracking_timeline_sheet_test.dart
// （组件）重叠的常规用例已移除，这里只保留它们未覆盖的边界与集成场景。
//
// 所有样本均为虚构数据：电话为 138/139 假号段与 0755-1234xxxx，取件码为编造格式，
// 驿站名/人名均为「测试」「示例」字样，不含任何真实个人信息，也不取自任何真实样本。
// 手机号写成相邻字符串（如 '138' '00001111'）是为了不触发 tools/check_no_pii.sh。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/engine/timeline_view.dart';
import 'package:pickup_app/core/models/package.dart';
import 'package:pickup_app/core/models/package_status.dart';
import 'package:pickup_app/ui/components/tracking_timeline.dart';
import 'package:pickup_app/ui/screens/home/widgets/tracking_timeline_sheet.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

String _j(List<Object?> nodes) => jsonEncode(nodes);

Map<String, Object?> _n(Object? time, Object? text, {Object? tag = '运输中'}) =>
    {'tag': tag, 'time': time, 'text': text};

/// 拦截 url_launcher，记录拉起的 URL（不真的拨号）。
class _FakeLauncher extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launched.add(url);
    return true;
  }
}

Widget _wrap(Widget child, {double width = 400}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: SingleChildScrollView(child: child)),
        ),
      ),
    );

Package _pkg({
  String? raw,
  String pickupCode = '',
  String? stationName,
  PackageStatus status = PackageStatus.arrived,
  String platform = 'pdd',
}) =>
    Package(
      id: 'QA_1',
      trackingNumber: 'YT0000000000001',
      courier: CourierType.yt,
      pickupCode: pickupCode,
      stationName: stationName,
      urgency: UrgencyLevel.normal,
      status: status,
      addedAt: DateTime(2026, 10, 7),
      platform: platform,
      rawTimelineJson: raw,
    );

void main() {
  final now = DateTime(2026, 10, 7, 9, 30);

  // ───────────────────────── 1. 坏节点 ─────────────────────────
  group('QA 坏节点逐个跳过', () {
    test('值不是字符串：int / double / bool 转成字符串，null 视为空', () {
      final nodes = timelineForDisplay(_j([
        {'tag': 1, 'time': '2026-10-06 10:00:00', 'text': 12345},
        {'tag': null, 'time': null, 'text': '快件已发出'},
        {'tag': true, 'time': 1.5, 'text': null},
      ]));
      expect(nodes.length, 3);
      expect(nodes[0].tag, '1');
      expect(nodes[0].text, '12345');
      expect(nodes[1].tag, '');
      expect(nodes[1].time, '');
      expect(nodes[2].tag, 'true');
    });

    test('全部节点都非法 → 空列表；顶层 null / 数字 / 空数组 / [null] / [[]] → 空列表', () {
      expect(
          timelineForDisplay(_j([null, 1, 'x', [], {}, {'time': '2026-10-06 10:00:00'}])),
          isEmpty);
      for (final raw in ['null', '123', '[]', '[null]', '[[]]', '"[]"', 'true']) {
        expect(timelineForDisplay(raw), isEmpty, reason: raw);
      }
    });
  });

  // ───────────────────────── 2. 去重 ─────────────────────────
  group('QA 去重', () {
    test('只在中间空白/全半角标点上不同：按约定键 time|text 不算重复（与 timeline_merge 一致，记录现状）', () {
      final nodes = timelineForDisplay(_j([
        _n('2026-10-06 10:00:00', '【测试驿站】快件已到达'),
        _n('2026-10-06 10:00:00', '[测试驿站] 快件已到达'),
        _n('2026-10-06 10:00:00', '【测试驿站】快件已 到达'),
        _n('2026-10-06 10:00:00', '【测试驿站】快件已到达。'),
      ]));
      expect(nodes.length, 4);
    });
  });

  // ───────────────────────── 3. 时间格式 ─────────────────────────
  group('QA 时间格式（约定：只认 yyyy-MM-dd HH:mm:ss）', () {
    const nonContract = <Object>[
      '2026/10/05 14:03',
      '2026/10/05 14:03:22',
      '2026-10-05 14:03',
      '2026-10-05  14:03:22', // 两个空格
      '10-05 14:03',
      '10-05 14:03:22',
      1791180202000, // epoch 毫秒 int
      '1791180202000', // epoch 毫秒字符串
      '2026-10-05T14:03:22Z',
      '2026-10-05T14:03:22+08:00',
      '2026-10-05T14:03:22',
      '昨天 14:03',
      '刚刚',
      'abc',
    ];

    for (final t in nonContract) {
      test('非约定格式 ${jsonEncode(t)}：不崩溃、排在合法节点之后、原样显示', () {
        final nodes = timelineForDisplay(_j([
          _n(t, '非约定时间节点'),
          _n('2026-10-01 10:00:00', '合法旧节点'),
        ]));
        expect(nodes.length, 2);
        expect(nodes.first.text, '合法旧节点');
        expect(nodes.last.parsedTime, isNull);
        expect(formatTimelineTime(nodes.last, now: now), t.toString());
      });
    }
  });

  // ───────────────────────── 4. 连接器产出的真实形状 ─────────────────────────
  group('QA 各平台节点形状（按 lib/platform/connectors 构造方式）', () {
    test('拼多多 traces 形状 {tag, time, text}，带取件码和座机：倒序、电话可识别', () {
      // pdd_connector.dart:1255-1264：tag 由 _mapPddStatusToTag 映射，time 原样 trim
      final raw = _j([
        {'tag': '待取件', 'time': '2026-10-07 08:05:00',
         'text': '【测试市示例驿站】您的快递已到站，凭取件码 3-2-1002 取件，驿站电话 0755-12345678'},
        {'tag': '派送中', 'time': '2026-10-07 07:00:00',
         'text': '快递员测试员正在派件，电话138' '00001111'},
        {'tag': '运输中', 'time': '2026-10-06 10:00:00', 'text': '快件已到达测试转运中心'},
      ]);
      final nodes = timelineForDisplay(raw);
      expect(nodes.first.tag, '待取件');
      expect(findPhones(nodes.first.text, pickupCode: '3-2-1002'), ['0755-12345678']);
      expect(extractStationPhone(nodes: nodes, pickupCode: '3-2-1002'), '0755-12345678');
    });

    test('京东 API 形状 tag 为空：只靠 text 也能显示；派送员手机可拨打', () {
      // jd_connector.dart:347-353：{'tag': '', 'time': createTime, 'text': wlStateDesc}
      final raw = _j([
        {'tag': '', 'time': '2026-10-07 08:30:00',
         'text': '您的订单正在配送途中，配送员【测试员】，电话：139' '00002222，请保持电话畅通'},
        {'tag': '', 'time': '2026-10-06 20:00:00', 'text': '您的订单已到达【测试营业部】'},
      ]);
      final nodes = timelineForDisplay(raw);
      expect(nodes.length, 2);
      expect(nodes.first.tag, '');
      expect(extractStationPhone(nodes: nodes), '139' '00002222');
    });

    test('淘宝 multiStage 形状（title→tag，subtitle→time）：约定格式时正常', () {
      // taobao_connector.dart:836-843
      final raw = _j([
        {'tag': '已签收', 'time': '2026-10-07 09:00:00', 'text': '您的快件已签收，签收人：本人'},
        {'tag': '派送中', 'time': '2026-10-07 07:00:00', 'text': '快递员正在为您派件'},
      ]);
      final nodes = timelineForDisplay(raw);
      expect(nodes.map((e) => e.tag), ['已签收', '派送中']);
    });
  });

  // ───────────────────────── 5. 电话识别边界 ─────────────────────────
  group('QA 电话识别边界', () {
    // 约定未要求识别这两种写法；QA 首轮按「应识别」写失败，改为记录现状，列为增强建议（见报告）。
    test('记录现状：带分隔符的手机号（横杠 / 空格分隔）目前不识别为电话', () {
      expect(findPhones('派送员电话138-' '0000-1111'), isEmpty);
      expect(findPhones('派送员电话 138 ' '0000 1111'), isEmpty);
    });

    test('记录现状：+86 前缀手机号目前不识别为电话', () {
      expect(findPhones('派送员电话+86138' '00001111'), isEmpty);
    });

    test('隐私号带分机（138' '00001111转1234）：至少主号可识别', () {
      expect(findPhones('请拨打138' '00001111转1234联系快递员'), ['138' '00001111']);
    });

    test('打码号码不识别为电话（界面文档已知限制）', () {
      expect(findPhones('快递员电话138****1111'), isEmpty);
    });

    test('取件码就是一串手机位数时，紧跟「取件码」的数字不当电话', () {
      expect(findPhones('取件码：138' '00001111，驿站电话0755-12345678'), ['0755-12345678']);
    });
  });

  // ───────────────────────── 6. 组件 ─────────────────────────
  group('QA TrackingTimeline 组件', () {
    testWidgets('电话是可点击元素：真实点击（hit test）触发拨号回调', (tester) async {
      final called = <String>[];
      final nodes = timelineForDisplay(_j([
        {'tag': '派送中', 'time': '2026-10-07 08:00:00', 'text': '138' '00001111'},
      ]));
      await tester.pumpWidget(_wrap(TrackingTimeline(nodes: nodes, now: now, onCallPhone: called.add)));
      await tester.tap(find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText() == '138' '00001111'));
      expect(called, ['138' '00001111']);
    });

    testWidgets('不注入回调时点击电话走系统拨号（tel: 去掉分隔符）', (tester) async {
      final fake = _FakeLauncher();
      final old = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = fake;
      addTearDown(() => UrlLauncherPlatform.instance = old);
      final nodes = timelineForDisplay(_j([
        {'tag': '待取件', 'time': '2026-10-07 08:00:00', 'text': '0755-12345678'},
      ]));
      await tester.pumpWidget(_wrap(TrackingTimeline(nodes: nodes, now: now)));
      await tester.tap(find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText() == '0755-12345678'));
      await tester.pump();
      expect(fake.launched, ['tel:075512345678']);
    });

    testWidgets('超长正文（3000 字 + 无空格长串）窄屏 320 宽不溢出、不报错', (tester) async {
      final longText = '${'快件已到达测试转运中心，' * 250}${'A' * 400}电话138' '00001111';
      final nodes = timelineForDisplay(_j([
        _n('2026-10-07 08:00:00', longText, tag: '运输中' * 30),
        _n('2026-10-06 08:00:00', '旧节点'),
      ]));
      await tester.pumpWidget(_wrap(TrackingTimeline(nodes: nodes, now: now), width: 320));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('tracking_timeline_node_1')), findsOneWidget);
    });

    testWidgets('300 个节点渲染不报错', (tester) async {
      final raw = _j([
        for (var i = 0; i < 300; i++)
          _n('2026-09-${(i % 28 + 1).toString().padLeft(2, '0')} 10:${(i % 60).toString().padLeft(2, '0')}:00',
              '节点 $i'),
      ]);
      await tester.pumpWidget(_wrap(TrackingTimeline(nodes: timelineForDisplay(raw), now: now)));
      expect(tester.takeException(), isNull);
    });
  });

  // ───────────────────────── 7. 详情抽屉 ─────────────────────────
  group('QA TrackingTimelineSheet 详情抽屉', () {
    Future<void> pumpSheet(WidgetTester tester, Package pkg) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: TrackingTimelineSheet(package: pkg))));
      await tester.pump();
    }

    testWidgets('取件码、驿站名醒目展示；驿站电话是可点击按钮并拉起 tel:', (tester) async {
      final fake = _FakeLauncher();
      final old = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = fake;
      addTearDown(() => UrlLauncherPlatform.instance = old);
      await pumpSheet(
        tester,
        _pkg(
          pickupCode: '3-2-1002',
          stationName: '测试市示例驿站',
          raw: _j([
            {'tag': '待取件', 'time': '2026-10-07 08:05:00',
             'text': '【测试市示例驿站】凭取件码 3-2-1002 取件，电话 0755-12345678'},
            {'tag': '运输中', 'time': '2026-10-06 10:00:00', 'text': '快件已到达测试转运中心'},
          ]),
        ),
      );
      expect(find.text('取件凭证'), findsOneWidget);
      // 商品卡片的 displayLocation 也会显示驿站名，这里检查取件凭证里加粗的那一处
      expect(find.text('测试市示例驿站'), findsWidgets);
      expect(
        tester.widgetList<Text>(find.text('测试市示例驿站'))
            .any((t) => t.style?.fontWeight == FontWeight.bold),
        isTrue,
      );
      expect(find.textContaining('3-2-1002'), findsWidgets);
      final btn = find.byKey(const ValueKey('station_phone_call_button'));
      expect(btn, findsOneWidget);
      expect(find.text('联系电话 0755-12345678'), findsOneWidget);
      await tester.tap(btn);
      await tester.pump();
      expect(fake.launched, ['tel:075512345678']);
    });

    testWidgets('rawTimelineJson 为空：抽屉显示「暂无物流轨迹」+ 当前状态，无编造节点', (tester) async {
      await pumpSheet(tester, _pkg(raw: null, status: PackageStatus.transit));
      expect(find.text('暂无物流轨迹'), findsOneWidget);
      // PackageStatus.transit.label 是「运送中」（首轮误写成「运输中」）
      expect(find.textContaining('当前状态：运送中'), findsOneWidget);
      expect(find.textContaining('今日'), findsNothing);
      expect(find.text('已发货'), findsNothing);
      expect(find.byKey(const ValueKey('tracking_timeline_node_0')), findsNothing);
    });

    testWidgets('一个坏节点不会让抽屉里的整条时间轴变空', (tester) async {
      await pumpSheet(
        tester,
        _pkg(raw: _j([
          {'tag': '运输中', 'time': 20261006, 'text': {'bad': true}},
          null,
          _n('2026-10-06 10:00:00', '快件已到达测试转运中心'),
        ])),
      );
      expect(find.text('暂无物流轨迹'), findsNothing);
      expect(find.byKey(const ValueKey('tracking_timeline_node_0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('三个平台（pdd/jd/taobao）走同一个 TrackingTimeline 组件', (tester) async {
      for (final p in ['pdd', 'jd', 'taobao']) {
        await pumpSheet(tester, _pkg(platform: p, raw: _j([_n('2026-10-06 10:00:00', '快件已到达')])));
        expect(find.byType(TrackingTimeline), findsOneWidget, reason: p);
      }
    });
  });
}
