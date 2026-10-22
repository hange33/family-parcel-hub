// 物流详情抽屉的收回行为测试：点击抽屉外的区域应当收起抽屉。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/models/package.dart';
import 'package:pickup_app/core/models/package_status.dart';
import 'package:pickup_app/ui/screens/home/widgets/tracking_timeline_sheet.dart';

Package _pkg() => Package(
      id: 'QA_1',
      trackingNumber: 'YT0000000000001',
      courier: CourierType.yt,
      urgency: UrgencyLevel.normal,
      status: PackageStatus.transit,
      addedAt: DateTime(2026, 10, 7),
      platform: 'pdd',
    );

Widget _host() => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => TrackingTimelineSheet.show(context, _pkg()),
              child: const Text('打开物流详情'),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('点击抽屉外的首页区域可收回物流详情抽屉', (tester) async {
    await tester.pumpWidget(_host());

    await tester.tap(find.text('打开物流详情'));
    await tester.pumpAndSettle();
    expect(find.byType(TrackingTimelineSheet), findsOneWidget);

    // 抽屉占屏幕下部 82%，上方留白处是点击收回区域
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(find.byType(TrackingTimelineSheet), findsNothing);
  });
}
