// P11-b 后续：同步合并（Hive 临时目录 + PackageListNotifier）。全部为自造数据。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pickup_app/core/engine/logistics_status_engine.dart';
import 'package:pickup_app/main.dart' show kPackagesBox;
import 'package:pickup_app/platform/connectors/taobao_sync_rules.dart';
import 'package:pickup_app/platform/storage/hive_adapters.dart';
import 'package:pickup_app/platform/storage/hive_package.dart';
import 'package:pickup_app/ui/providers/package_provider.dart';

const _order1 = '1000000000000000001';
const _order2 = '1000000000000000002';
const _full1 = 'YT0055555550001';
const _mask1 = 'YT00*******0001';
const _maskOther = 'ZT00*******0002';
const _code = '3-2-0101';

Package _tb(String order, String tracking, PackageStatus status) => Package(
      id: 'TB_$order',
      trackingNumber: tracking,
      courier: tracking.startsWith('ZT') ? CourierType.zto : CourierType.yt,
      urgency: UrgencyLevel.normal,
      status: status,
      addedAt: DateTime(2026, 10, 6, 9),
      platform: 'taobao',
      rawTimelineJson: '[{"tag":"运输中","time":"2026-10-06 08:00:00","text":"快件已到达测试转运中心"}]',
    );

Package _cn() => Package(
      id: 'CN_$_full1',
      trackingNumber: _full1,
      courier: CourierType.yt,
      pickupCode: _code,
      urgency: UrgencyLevel.urgent,
      status: PackageStatus.arrived,
      addedAt: DateTime(2026, 10, 6, 10),
      platform: 'taobao',
      stationName: '测试小区北门店',
    );

late Directory _dir;
late Box<HivePackage> _box;

Future<void> _seed(List<Package> pkgs) async {
  for (final p in pkgs) {
    await _box.put(p.id, HivePackage.fromPackage(p));
  }
}

/// 模拟一次淘宝同步：阶段 1 菜鸟列表 → 阶段 2 淘宝订单（与连接器顺序一致）
/// 阶段 2 照连接器的做法：按订单号找本地包裹，淘宝已签收而菜鸟仍待取时以菜鸟为准。
void _sync(PackageListNotifier n, {List<Package> cainiao = const [], List<Package> taobao = const []}) {
  for (final p in cainiao) {
    n.addPackage(p);
  }
  for (final p in taobao) {
    final local = findLocalTaobaoPackage(n.state, p.id.substring(3));
    n.addPackage(applyCainiaoPriority(p, cainiao, local: local));
  }
}

Package _only(PackageListNotifier n) {
  expect(n.state, hasLength(1));
  return n.state.single;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(PackageStatusAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(UrgencyLevelAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(CourierTypeAdapter());
    if (!Hive.isAdapterRegistered(3)) Hive.registerAdapter(HivePackageAdapter());
  });

  setUp(() async {
    _dir = await Directory.systemTemp.createTemp('parcly_merge_');
    Hive.init(_dir.path);
    _box = await Hive.openBox<HivePackage>(kPackagesBox);
  });

  tearDown(() async {
    await Hive.close();
    await _dir.delete(recursive: true);
  });

  group('旧 ID TB_<打码运单号> 迁移', () {
    test('换成 TB_<订单号>，Hive 旧 key 真删掉，用户已取状态和 pickedUpAt 带过去；连续同步两次不变', () async {
      final pickedAt = DateTime(2026, 10, 6, 20, 30);
      await _seed([
        _tb('', _mask1, PackageStatus.pickedUp).copyWith(id: 'TB_$_mask1', pickedUpAt: pickedAt),
      ]);
      final n = PackageListNotifier();
      expect(_box.keys, ['TB_$_mask1']);

      for (var i = 0; i < 2; i++) {
        _sync(n, taobao: [_tb(_order1, _mask1, PackageStatus.pickedUp)]);
        final p = _only(n);
        expect(p.id, 'TB_$_order1');
        expect(p.status, PackageStatus.pickedUp);
        expect(p.pickedUpAt, pickedAt);
        expect(_box.keys.toList(), ['TB_$_order1']);
        expect(_box.get('TB_$_order1')!.pickedUpAt, pickedAt);
      }
    });

    test('已归档的旧记录迁移后仍是已归档（archivedAt 保留）', () async {
      final archivedAt = DateTime(2026, 10, 5, 12);
      await _seed([
        _tb('', _mask1, PackageStatus.archived)
            .copyWith(id: 'TB_$_mask1', pickedUpAt: DateTime(2026, 9, 28), archivedAt: archivedAt),
      ]);
      final n = PackageListNotifier();
      _sync(n, cainiao: [_cn()], taobao: [_tb(_order1, _mask1, PackageStatus.pickedUp)]);
      final p = _only(n);
      expect(p.id, 'TB_$_order1');
      expect(p.status, PackageStatus.archived);
      expect(p.archivedAt, archivedAt);
      expect(_box.keys.toList(), ['TB_$_order1']);
    });
  });

  group('菜鸟完整单号 ↔ 淘宝打码单号合并', () {
    test('连续两次同步：包裹数不变、一包一卡、Hive 无旧 key，ID 为 TB_<订单号>、单号为完整单号', () async {
      final n = PackageListNotifier();
      for (var i = 0; i < 2; i++) {
        _sync(n, cainiao: [_cn()], taobao: [
          _tb(_order1, _mask1, PackageStatus.arrived),
          _tb(_order2, _maskOther, PackageStatus.transit),
        ]);
        expect(n.state, hasLength(2));
        final ids = n.state.map((p) => p.id).toSet();
        expect(ids, {'TB_$_order1', 'TB_$_order2'});
        expect(_box.keys.toSet(), ids);
        final p1 = n.state.firstWhere((p) => p.id == 'TB_$_order1');
        expect(p1.trackingNumber, _full1);
        expect(p1.pickupCode, _code);
        expect(p1.status, PackageStatus.arrived);
      }
    });

    test('命中多个淘宝包裹 → 菜鸟件不合并，单独成卡', () async {
      // 两个不同订单打码单号相同：载入时也不能被当成同一包裹
      await _seed([
        _tb(_order1, _mask1, PackageStatus.transit),
        _tb(_order2, _mask1, PackageStatus.transit),
      ]);
      final n = PackageListNotifier();
      _sync(n, cainiao: [_cn()]);
      expect(n.state, hasLength(3));
      expect(n.state.where((p) => p.id == 'CN_$_full1'), hasLength(1));
      expect(n.state.where((p) => p.id.startsWith('TB_')).every((p) => p.trackingNumber == _mask1), isTrue);
    });

    test('快递公司不同 → 不合并', () async {
      await _seed([_tb(_order1, _mask1, PackageStatus.transit).copyWith(courier: CourierType.zto)]);
      final n = PackageListNotifier();
      _sync(n, cainiao: [_cn()]);
      expect(n.state, hasLength(2));
    });
  });

  group('淘宝已签收 + 菜鸟仍在待取列表：以菜鸟为准，用户手动已取 / 归档不改', () {
    test('平台签收（pickedUpAt 为空）→ 改回待取件并显示取件码；同步两次不变', () async {
      await _seed([_tb(_order1, _mask1, PackageStatus.pickedUp)]);
      final n = PackageListNotifier();
      for (var i = 0; i < 2; i++) {
        _sync(n, cainiao: [_cn()], taobao: [_tb(_order1, _mask1, PackageStatus.pickedUp)]);
        final p = _only(n);
        expect(p.id, 'TB_$_order1');
        expect(p.status, PackageStatus.arrived);
        expect(p.displayPickupCode, _code);
        expect(p.pickedUpAt, isNull);
        expect(_box.keys.toList(), ['TB_$_order1']);
      }
    });

    test('用户点已取 → 同步两次 → pickedUpAt 还在，状态没被菜鸟改回', () async {
      await _seed([_tb(_order1, _mask1, PackageStatus.arrived)]);
      final n = PackageListNotifier();
      n.markPickedUp('TB_$_order1');
      final pickedAt = n.state.single.pickedUpAt;
      expect(pickedAt, isNotNull);
      for (var i = 0; i < 2; i++) {
        _sync(n, cainiao: [_cn()], taobao: [_tb(_order1, _mask1, PackageStatus.pickedUp)]);
        final p = _only(n);
        expect(p.status, PackageStatus.pickedUp);
        expect(p.pickedUpAt, pickedAt);
        expect(p.displayPickupCode, isEmpty);
        expect(_box.get('TB_$_order1')!.pickedUpAt, pickedAt);
      }
    });

    test('已归档 → 不改', () async {
      await _seed([
        _tb(_order1, _mask1, PackageStatus.archived).copyWith(archivedAt: DateTime(2026, 10, 6)),
      ]);
      final n = PackageListNotifier();
      _sync(n, cainiao: [_cn()], taobao: [_tb(_order1, _mask1, PackageStatus.pickedUp)]);
      expect(_only(n).status, PackageStatus.archived);
    });

    test('清掉 pickedUpAt 后（如 #9 撤销已取）菜鸟又能改回', () async {
      // 第一次：用户已取，菜鸟改不回
      await _seed([
        _tb(_order1, _mask1, PackageStatus.pickedUp).copyWith(pickedUpAt: DateTime(2026, 10, 6, 21)),
      ]);
      var n = PackageListNotifier();
      _sync(n, cainiao: [_cn()]);
      expect(_only(n).status, PackageStatus.pickedUp);
      // 撤销：已取状态保留但 pickedUpAt 清空（#9 restorePackage 的效果，直接写进 Hive）
      final restored = n.state.single;
      await _box.put(
        restored.id,
        HivePackage.fromPackage(Package(
          id: restored.id,
          trackingNumber: restored.trackingNumber,
          courier: restored.courier,
          pickupCode: restored.pickupCode,
          urgency: restored.urgency,
          status: PackageStatus.pickedUp,
          addedAt: restored.addedAt,
          platform: restored.platform,
          rawTimelineJson: restored.rawTimelineJson,
        )),
      );
      n.dispose();
      n = PackageListNotifier();
      expect(n.state.single.pickedUpAt, isNull);
      _sync(n, cainiao: [_cn()]);
      final p = _only(n);
      expect(p.status, PackageStatus.arrived);
      expect(p.displayPickupCode, _code);
    });
  });

  group('驿站名择优：泛称不覆盖具体网点名', () {
    Package arrived(String station, {String pickupCode = ''}) => Package(
          id: 'TB_$_order1',
          trackingNumber: _full1,
          courier: CourierType.yt,
          pickupCode: pickupCode,
          urgency: UrgencyLevel.urgent,
          status: PackageStatus.arrived,
          addedAt: DateTime(2026, 10, 8, 9),
          platform: 'taobao',
          stationName: station,
        );

    test('具体名本身含「菜鸟驿站」时，不被菜鸟接口回落的泛称覆盖', () {
      final n = PackageListNotifier();
      n.addPackage(arrived('邢台信都区绿城诚园北门店菜鸟驿站'));
      n.addPackage(arrived('菜鸟驿站', pickupCode: _code));
      final p = _only(n);
      expect(p.stationName, '邢台信都区绿城诚园北门店菜鸟驿站');
      // 取件码照常合并，被降级的只是驿站名
      expect(p.displayPickupCode, _code);
    });

    test('具体名不含「菜鸟驿站」时，泛称补成前缀而不是覆盖', () {
      final n = PackageListNotifier();
      n.addPackage(arrived('绿城诚园北门对面大院驿站'));
      n.addPackage(arrived('菜鸟驿站'));
      expect(_only(n).stationName, '菜鸟驿站 · 绿城诚园北门对面大院驿站');
    });

    test('已有泛称时，更具体的网点名可以覆盖', () {
      final n = PackageListNotifier();
      n.addPackage(arrived('菜鸟驿站'));
      n.addPackage(arrived('邢台信都区绿城诚园北门店菜鸟驿站'));
      expect(_only(n).stationName, '邢台信都区绿城诚园北门店菜鸟驿站');
    });

    test('新数据没带驿站名时不覆盖已有网点名', () {
      final n = PackageListNotifier();
      n.addPackage(arrived('邢台信都区绿城诚园北门店菜鸟驿站'));
      n.addPackage(arrived(''));
      expect(_only(n).stationName, '邢台信都区绿城诚园北门店菜鸟驿站');
    });
  });
}
