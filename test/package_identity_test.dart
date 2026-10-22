// P11-b 后续：打码单号匹配、旧 ID 迁移、菜鸟为准、阶段 3 跳过打码单号。全部为自造数据。
import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/engine/logistics_status_engine.dart';
import 'package:pickup_app/core/engine/package_identity.dart';
import 'package:pickup_app/core/models/package.dart';
import 'package:pickup_app/core/models/package_status.dart';
import 'package:pickup_app/platform/connectors/taobao_sync_rules.dart';

Package _p(
  String id,
  String tracking, {
  CourierType courier = CourierType.yt,
  PackageStatus status = PackageStatus.transit,
  String code = '',
  DateTime? pickedUpAt,
}) =>
    Package(
      id: id,
      trackingNumber: tracking,
      courier: courier,
      pickupCode: code,
      urgency: UrgencyLevel.normal,
      status: status,
      addedAt: DateTime(2026, 10, 6),
      pickedUpAt: pickedUpAt,
      platform: 'taobao',
    );

// 完整单号 15 位；打码 = 前 4 + 7 个 * + 后 4（露出 8 位）
const _full1 = 'YT0055555550001';
const _mask1 = 'YT00*******0001';
const _full2 = 'YT0066666660001'; // 与 _full1 前后各 4 位相同

void main() {
  group('maskedTrackingMatches：长度相同、露出的前后几位逐位相同、露出≥6 位', () {
    test('露出 8 位且前后都对上 → 匹配', () {
      expect(maskedTrackingMatches(_mask1, _full1), isTrue);
    });
    test('露出 5 位 → 不合并', () {
      expect(visibleTrackingChars('YT0**********01'), 5);
      expect(maskedTrackingMatches('YT0**********01', _full1), isFalse);
    });
    test('露出 6 位 → 合并', () {
      expect(visibleTrackingChars('YT0*********001'), 6);
      expect(maskedTrackingMatches('YT0*********001', _full1), isTrue);
    });
    test('长度不同 → 不匹配', () {
      expect(maskedTrackingMatches(_mask1, '${_full1}9'), isFalse);
    });
    test('前缀或后缀有一位不同 → 不匹配', () {
      expect(maskedTrackingMatches('YT01*******0001', _full1), isFalse);
      expect(maskedTrackingMatches('YT00*******0002', _full1), isFalse);
    });
    test('不区分大小写；两边都完整或都打码 → 不匹配', () {
      expect(maskedTrackingMatches('yt00*******0001', _full1), isTrue);
      expect(maskedTrackingMatches(_full1, _full1), isFalse);
      expect(maskedTrackingMatches(_mask1, _mask1), isFalse);
    });
  });

  group('findUniqueMaskedMatch：恰好一个才合并', () {
    final cn = _p('CN_$_full1', _full1, status: PackageStatus.arrived, code: '3-2-0101');
    test('恰好一个 → 返回下标', () {
      final local = [_p('TB_1000000000000000009', 'ZT0000000000009'), _p('TB_1000000000000000001', _mask1)];
      expect(findUniqueMaskedMatch(local, cn), 1);
    });
    test('命中多个 → 不合并', () {
      final local = [
        _p('TB_1000000000000000001', _mask1),
        _p('TB_1000000000000000002', _mask1),
      ];
      expect(findUniqueMaskedMatch(local, cn), -1);
    });
    test('快递公司不同 → 不合并', () {
      final local = [_p('TB_1000000000000000001', _mask1, courier: CourierType.zto)];
      expect(findUniqueMaskedMatch(local, cn), -1);
    });
    test('快递公司认不出（other）→ 不合并', () {
      final local = [_p('TB_1000000000000000001', '9900*******0001', courier: CourierType.other)];
      final c = _p('CN_990055555550001', '990055555550001', courier: CourierType.other);
      expect(findUniqueMaskedMatch(local, c), -1);
    });
    test('露出 5 位 → 不合并；6 位 → 合并', () {
      expect(findUniqueMaskedMatch([_p('TB_1000000000000000001', 'YT0**********01')], cn), -1);
      expect(findUniqueMaskedMatch([_p('TB_1000000000000000001', 'YT0*********001')], cn), 0);
    });
    test('方向反过来（本地完整、来的是打码）也能匹配', () {
      expect(findUniqueMaskedMatch([cn], _p('TB_1000000000000000001', _mask1)), 0);
    });
    test('两个不同淘宝订单：打码单号再像也不合并', () {
      final merged = _p('TB_1000000000000000001', _full1);
      expect(findUniqueMaskedMatch([merged], _p('TB_1000000000000000002', _mask1)), -1);
    });
  });

  group('旧 ID 迁移与单号保留', () {
    test('isLegacyMaskedTaobaoId：TB_<打码运单号> 是旧 ID；TB_<订单号>、拆单 ID、CN_ 不是', () {
      expect(isLegacyMaskedTaobaoId('TB_$_mask1'), isTrue);
      expect(isLegacyMaskedTaobaoId('TB_1000000000000000001'), isFalse);
      expect(isLegacyMaskedTaobaoId('TB_1000000000000000001_$_mask1'), isFalse);
      expect(isLegacyMaskedTaobaoId('CN_$_full1'), isFalse);
    });
    test('resolveMergedPackageId：旧 TB_<*> / CN_ 遇到 TB_<订单号> → 换成新 ID', () {
      final incoming = _p('TB_1000000000000000001', _mask1);
      expect(resolveMergedPackageId(_p('TB_$_mask1', _mask1), incoming), 'TB_1000000000000000001');
      expect(resolveMergedPackageId(_p('CN_$_full1', _full1), incoming), 'TB_1000000000000000001');
    });
    test('resolveMergedPackageId：CN_ 来合并时保留 TB_<订单号>；其他平台不动', () {
      final tb = _p('TB_1000000000000000001', _mask1);
      expect(resolveMergedPackageId(tb, _p('CN_$_full1', _full1)), 'TB_1000000000000000001');
      expect(resolveMergedPackageId(_p('PDD_2000000001', _full1), _p('CN_$_full1', _full1)), 'PDD_2000000001');
    });
    test('keepFullTrackingNumber：已有完整单号时不被打码单号覆盖', () {
      expect(keepFullTrackingNumber(_full1, _mask1), _full1);
      expect(keepFullTrackingNumber(_mask1, _full1), _full1);
      expect(keepFullTrackingNumber('', _mask1), _mask1);
    });
    test('packageIdForLog：只留平台前缀', () {
      expect(packageIdForLog('TB_1000000000000000001'), 'TB_…');
      expect(packageIdForLog('CN_$_full1'), 'CN_…');
      expect(packageIdForLog('noprefix'), '…');
    });
  });

  group('阶段 3：打码单号不查菜鸟', () {
    test('queryableTrackingNumbers 去掉含 * 的和空的', () {
      expect(queryableTrackingNumbers([_mask1, _full1, ' ', 'ZT0000000000009']), [_full1, 'ZT0000000000009']);
    });
  });

  group('applyCainiaoPriority：淘宝已签收 + 菜鸟仍待取 → 以菜鸟为准', () {
    final cn = _p('CN_$_full1', _full1, status: PackageStatus.arrived, code: '3-2-0101');
    final signed = _p('TB_1000000000000000001', _mask1, status: PackageStatus.pickedUp);

    test('改回待取件，带上取件码和完整单号，ID 不变', () {
      final r = applyCainiaoPriority(signed, [cn]);
      expect(r.id, 'TB_1000000000000000001');
      expect(r.status, PackageStatus.arrived);
      expect(r.pickupCode, '3-2-0101');
      expect(r.trackingNumber, _full1);
      expect(r.displayPickupCode, '3-2-0101');
    });
    test('用户手动点过已取（pickedUpAt 有值）或已归档 → 不改', () {
      final userPicked = signed.copyWith(pickedUpAt: DateTime(2026, 10, 6, 20));
      expect(identical(applyCainiaoPriority(signed, [cn], local: userPicked), signed), isTrue);
      final archived = signed.copyWith(status: PackageStatus.archived);
      expect(identical(applyCainiaoPriority(signed, [cn], local: archived), signed), isTrue);
    });
    test('平台签收（本地 pickedUpAt 为空）→ 改回', () {
      expect(applyCainiaoPriority(signed, [cn], local: signed).status, PackageStatus.arrived);
    });
    test('菜鸟命中多个 / 没有取件码 / 淘宝不是已签收 → 不改', () {
      final cn2 = _p('CN_$_full2', _full2, status: PackageStatus.arrived, code: '3-2-0102');
      expect(identical(applyCainiaoPriority(signed, [cn, cn2]), signed), isTrue);
      expect(identical(applyCainiaoPriority(signed, [cn.copyWith(pickupCode: '')]), signed), isTrue);
      final transit = signed.copyWith(status: PackageStatus.transit);
      expect(identical(applyCainiaoPriority(transit, [cn]), transit), isTrue);
    });
  });

  test('isUserHandledPickup：已归档，或已取件且 pickedUpAt 有值', () {
    expect(isUserHandledPickup(_p('a_1', '', status: PackageStatus.archived)), isTrue);
    expect(isUserHandledPickup(_p('a_1', '', status: PackageStatus.pickedUp, pickedUpAt: DateTime(2026))), isTrue);
    expect(isUserHandledPickup(_p('a_1', '', status: PackageStatus.pickedUp)), isFalse);
  });
}
