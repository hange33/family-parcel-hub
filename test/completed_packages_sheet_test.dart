// 首页「已完成」抽屉的收回行为测试：点击抽屉外的区域应当收起抽屉。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/models/package.dart';
import 'package:pickup_app/ui/providers/package_provider.dart';
import 'package:pickup_app/ui/screens/home/widgets/completed_packages_sheet.dart';

Widget _host() => ProviderScope(
      overrides: [
        completedPackagesProvider.overrideWithValue(const <Package>[]),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => CompletedPackagesSheet.show(context),
                child: const Text('打开已完成'),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('点击抽屉外的首页区域可收回「已完成」菜单', (tester) async {
    await tester.pumpWidget(_host());

    await tester.tap(find.text('打开已完成'));
    await tester.pumpAndSettle();
    expect(find.byType(CompletedPackagesSheet), findsOneWidget);

    // 抽屉只占屏幕下部 65%，上方留白处是点击收回区域
    await tester.tapAt(const Offset(200, 60));
    await tester.pumpAndSettle();
    expect(find.byType(CompletedPackagesSheet), findsNothing);
  });
}
