// 恢复已删除的包裹：删除会进黑名单，清空黑名单后必须能重新同步进来。全部为自造数据。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pickup_app/main.dart' show kPackagesBox;
import 'package:pickup_app/platform/storage/hive_adapters.dart';
import 'package:pickup_app/platform/storage/hive_package.dart';
import 'package:pickup_app/platform/storage/platform_auth_store.dart';
import 'package:pickup_app/ui/providers/package_provider.dart';

const _orderId = '1000000000000000001';
const _tracking = 'YT0055555550001';

/// 淘宝侧推来的包裹
Package _taobao() => Package(
      id: 'TB_$_orderId',
      trackingNumber: _tracking,
      courier: CourierType.yt,
      urgency: UrgencyLevel.normal,
      status: PackageStatus.arrived,
      addedAt: DateTime(2026, 10, 8, 9),
      platform: 'taobao',
    );

/// 菜鸟侧推来的同一件：ID 不同，运单号相同
Package _cainiao() => Package(
      id: 'CN_$_tracking',
      trackingNumber: _tracking,
      courier: CourierType.yt,
      urgency: UrgencyLevel.urgent,
      status: PackageStatus.arrived,
      addedAt: DateTime(2026, 10, 8, 10),
      platform: 'cainiao',
    );

late Directory _dir;

bool _blocked(String id) =>
    PlatformAuthStore().isBlacklisted(id, trackingNumber: _tracking);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(PackageStatusAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(UrgencyLevelAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(CourierTypeAdapter());
    if (!Hive.isAdapterRegistered(3)) Hive.registerAdapter(HivePackageAdapter());
  });

  setUp(() async {
    _dir = await Directory.systemTemp.createTemp('parcly_restore_');
    Hive.init(_dir.path);
    await Hive.openBox<HivePackage>(kPackagesBox);
    await Hive.openBox(kPlatformAuthBox);
    // 黑名单缓存是静态的，逐条用例之间必须复位
    PlatformAuthStore().clearBlacklist();
  });

  tearDown(() async {
    await Hive.close();
    await _dir.delete(recursive: true);
  });

  test('删除后黑名单拦住重新同步；清空黑名单后包裹能回来', () {
    final notifier = PackageListNotifier();

    notifier.addPackage(_taobao());
    expect(notifier.state, hasLength(1));

    notifier.removePackage('TB_$_orderId');
    expect(notifier.state, isEmpty);
    expect(_blocked('TB_$_orderId'), isTrue);

    // 同步重新推同一件 → 被挡住。这正是「删掉之后强制重拉也不显示」的原因
    notifier.addPackage(_taobao());
    expect(notifier.state, isEmpty);

    // 设置页点「恢复已删除的包裹」＝清空黑名单
    PlatformAuthStore().clearBlacklist();
    expect(_blocked('TB_$_orderId'), isFalse);

    notifier.addPackage(_taobao());
    expect(notifier.state, hasLength(1));
  });

  test('运单号一并进黑名单：换个 ID 的同一件同样被拦，恢复后也能回来', () {
    final notifier = PackageListNotifier();
    notifier.addPackage(_taobao());
    notifier.removePackage('TB_$_orderId');

    notifier.addPackage(_cainiao());
    expect(notifier.state, isEmpty);
    expect(_blocked('CN_$_tracking'), isTrue);

    PlatformAuthStore().clearBlacklist();
    notifier.addPackage(_cainiao());
    expect(notifier.state, hasLength(1));
    expect(notifier.state.single.id, 'CN_$_tracking');
  });

  test('删除只拦住被删的那件，其它包裹照常进来', () {
    final notifier = PackageListNotifier();
    notifier.addPackage(_taobao());
    notifier.removePackage('TB_$_orderId');

    final other = Package(
      id: 'TB_1000000000000000002',
      trackingNumber: 'YT0055555550002',
      courier: CourierType.yt,
      urgency: UrgencyLevel.normal,
      status: PackageStatus.arrived,
      addedAt: DateTime(2026, 10, 8, 11),
      platform: 'taobao',
    );
    notifier.addPackage(other);
    expect(notifier.state, hasLength(1));
    expect(notifier.state.single.id, other.id);
  });
}
