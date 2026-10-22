// AnimatedPackageList 的插入 / 移除 / 重排行为测试。样本均为虚构数据。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/models/package.dart';
import 'package:pickup_app/core/models/package_status.dart';
import 'package:pickup_app/ui/components/staggered_entrance.dart';
import 'package:pickup_app/ui/screens/home/widgets/animated_package_list.dart';
import 'package:pickup_app/ui/screens/home/widgets/modern_package_card.dart';

Package _pkg(String id) => Package(
      id: id,
      trackingNumber: 'YT0000000000001',
      courier: CourierType.yt,
      urgency: UrgencyLevel.normal,
      status: PackageStatus.transit,
      addedAt: DateTime(2026, 10, 7),
      platform: 'pdd',
    );

Widget _host(List<Package> packages) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [AnimatedPackageList(packages: packages)],
          ),
        ),
      ),
    );

/// 让交错入场的定时器全部触发并跑完动画，避免测试结束时留下 pending timer。
Future<void> _settleEntrance(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 600));

void main() {
  testWidgets('首屏包裹全部渲染，并走交错入场', (tester) async {
    await tester.pumpWidget(_host([_pkg('QA_1'), _pkg('QA_2')]));
    await _settleEntrance(tester);

    expect(find.byType(ModernPackageCard), findsNWidgets(2));
    expect(find.byType(StaggeredEntrance), findsNWidgets(2));
    expect(find.byKey(const ValueKey('QA_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('QA_2')), findsOneWidget);
  });

  testWidgets('新增包裹插入到队首，卡片总数正确且带插入过渡', (tester) async {
    await tester.pumpWidget(_host([_pkg('QA_1'), _pkg('QA_2')]));
    await _settleEntrance(tester);

    await tester.pumpWidget(_host([_pkg('QA_0'), _pkg('QA_1'), _pkg('QA_2')]));
    // Navigator 会晚一帧才把新的 home 交给列表组件，再补一帧让插入动画起步
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(ModernPackageCard), findsNWidgets(3));
    expect(find.byKey(const ValueKey('QA_0')), findsOneWidget);
    // 新增项由 AnimatedList 的插槽过渡承载
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('QA_0')),
        matching: find.byType(SizeTransition),
      ),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ModernPackageCard), findsNWidgets(3));
  });

  testWidgets('移除包裹先播退出动画，播完才真正消失', (tester) async {
    await tester.pumpWidget(_host([_pkg('QA_1'), _pkg('QA_2')]));
    await _settleEntrance(tester);

    await tester.pumpWidget(_host([_pkg('QA_1')]));
    await tester.pump();

    // 退场项用独立 Key 挂在过渡上，与仍在列表里的同 id 项不会撞 Key
    expect(find.byKey(const ValueKey('exiting_QA_2')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('exiting_QA_2')), findsNothing);
    expect(find.byType(ModernPackageCard), findsOneWidget);
  });

  testWidgets('仅顺序变化时不丢也不重复卡片，且不产生退场过渡', (tester) async {
    await tester.pumpWidget(_host([_pkg('QA_1'), _pkg('QA_2')]));
    await _settleEntrance(tester);

    await tester.pumpWidget(_host([_pkg('QA_2'), _pkg('QA_1')]));
    await tester.pump();

    expect(find.byType(ModernPackageCard), findsNWidgets(2));
    expect(find.byKey(const ValueKey('QA_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('QA_2')), findsOneWidget);
    expect(find.byKey(const ValueKey('exiting_QA_1')), findsNothing);
    expect(find.byKey(const ValueKey('exiting_QA_2')), findsNothing);
  });
}
