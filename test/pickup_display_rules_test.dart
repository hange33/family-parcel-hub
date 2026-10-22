// P11-b 后续：签收后不显示取件码、不标急件（规则在状态引擎层，原始 pickupCode 保留）。全部为自造数据。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/engine/logistics_status_engine.dart';
import 'package:pickup_app/core/models/package.dart';
import 'package:pickup_app/core/models/package_status.dart';
import 'package:pickup_app/core/parser/taobao_trace_parser.dart';

const _code = '3-2-1002';
final _now = DateTime.parse('2026-10-07T09:00:00+08:00');

Package _pkg(PackageStatus status, {String code = _code, UrgencyLevel urgency = UrgencyLevel.urgent}) => Package(
      id: 'TB_1000000000000000001',
      trackingNumber: 'YT0000000000001',
      courier: CourierType.yt,
      pickupCode: code,
      urgency: urgency,
      status: status,
      addedAt: DateTime(2026, 10, 6),
    );

void main() {
  group('有效取件码', () {
    test('已签收 / 已归档 / 已拒收：为空', () {
      for (final s in [PackageStatus.pickedUp, PackageStatus.archived, PackageStatus.rejected]) {
        expect(LogisticsStatusEngine.effectivePickupCode(status: s, pickupCode: _code), '', reason: '$s');
        expect(LogisticsStatusEngine.isPickupClosed(s), isTrue);
      }
    });

    test('未结束：原样（去首尾空白）', () {
      for (final s in [
        PackageStatus.arrived,
        PackageStatus.delivering,
        PackageStatus.transit,
        PackageStatus.pendingShipment,
      ]) {
        expect(LogisticsStatusEngine.effectivePickupCode(status: s, pickupCode: ' $_code '), _code, reason: '$s');
      }
    });
  });

  group('是否急件', () {
    test('已签收 / 已归档 / 已拒收：有取件码也不是急件', () {
      for (final s in [PackageStatus.pickedUp, PackageStatus.archived, PackageStatus.rejected]) {
        expect(LogisticsStatusEngine.isUrgent(status: s, pickupCode: _code), isFalse, reason: '$s');
      }
    });

    test('已到站：没有取件码也是急件', () {
      expect(LogisticsStatusEngine.isUrgent(status: PackageStatus.arrived, pickupCode: ''), isTrue);
    });

    test('派送中 / 运输中：有取件码是急件，没有不是', () {
      for (final s in [PackageStatus.delivering, PackageStatus.transit]) {
        expect(LogisticsStatusEngine.isUrgent(status: s, pickupCode: _code), isTrue, reason: '$s');
        expect(LogisticsStatusEngine.isUrgent(status: s, pickupCode: '  '), isFalse, reason: '$s');
      }
    });

    test('待发货：有取件码也不是急件', () {
      expect(LogisticsStatusEngine.isUrgent(status: PackageStatus.pendingShipment, pickupCode: _code), isFalse);
    });
  });

  group('紧急级别 urgencyFor', () {
    test('急件 → urgent；取件结束 → low', () {
      expect(LogisticsStatusEngine.urgencyFor(status: PackageStatus.arrived, pickupCode: ''), UrgencyLevel.urgent);
      expect(
        LogisticsStatusEngine.urgencyFor(status: PackageStatus.pickedUp, pickupCode: _code, fallback: UrgencyLevel.urgent),
        UrgencyLevel.low,
      );
    });

    test('非急件：沿用 fallback，但 urgent 残留降为 normal', () {
      expect(
        LogisticsStatusEngine.urgencyFor(status: PackageStatus.transit, pickupCode: '', fallback: UrgencyLevel.warning),
        UrgencyLevel.warning,
      );
      expect(
        LogisticsStatusEngine.urgencyFor(status: PackageStatus.transit, pickupCode: '', fallback: UrgencyLevel.urgent),
        UrgencyLevel.normal,
      );
      expect(LogisticsStatusEngine.urgencyFor(status: PackageStatus.transit, pickupCode: ''), UrgencyLevel.normal);
    });
  });

  group('Package 扩展 getter（前端读这里）', () {
    test('已签收：displayPickupCode 为空、isUrgentNow false、effectiveUrgency low，原始 pickupCode 和 urgency 不动', () {
      final p = _pkg(PackageStatus.pickedUp);
      expect(p.displayPickupCode, '');
      expect(p.isUrgentNow, isFalse);
      expect(p.effectiveUrgency, UrgencyLevel.low);
      expect(p.pickupCode, _code);
      expect(p.urgency, UrgencyLevel.urgent);
    });

    test('已归档同样不显示', () {
      final p = _pkg(PackageStatus.archived);
      expect(p.displayPickupCode, '');
      expect(p.isUrgentNow, isFalse);
    });

    test('待取件：正常显示并标急件', () {
      final p = _pkg(PackageStatus.arrived, urgency: UrgencyLevel.normal);
      expect(p.displayPickupCode, _code);
      expect(p.isUrgentNow, isTrue);
      expect(p.effectiveUrgency, UrgencyLevel.urgent);
    });

    test('签收后再收到 transitionTo 的包裹：同一对象状态一变，显示立刻跟着变', () {
      final arrived = _pkg(PackageStatus.arrived);
      final picked = arrived.transitionTo(PackageStatus.pickedUp);
      expect(arrived.displayPickupCode, _code);
      expect(picked.displayPickupCode, '');
      expect(picked.pickupCode, _code);
    });
  });

  test('淘宝已签收轨迹里留有旧取件码：解析器保留原始码，引擎推导为已签收且不标急件', () {
    final payload = jsonEncode({
      'result': {
        'data': {
          'newLogistics': {
            'fields': {
              'mailNo': 'TEST0000000001',
              'multiStage': [
                {'title': '已签收', 'subtitle': '10-07 08:30', 'labelDesc': {'text': '您已在测试小区北门店完成取件'}},
                {'title': '待取件', 'subtitle': '10-06 18:00', 'labelDesc': {'text': '快件已到测试小区北门店菜鸟驿站，取件码 $_code'}},
              ],
            },
            'events': {
              'exposureItemV2': [
                {
                  'fields': {
                    'args': {'cpCode': 'YTO', 'lgStatus': 'SIGN'},
                  },
                },
              ],
            },
          },
        },
      },
    });
    final html = "<script>!function(){window['$taobaoSsrMarker$payload}();</script>";
    final t = TaobaoTraceParser.parseHtml(html, now: _now)!;
    expect(t.pickupCode, _code); // 原始数据保留
    final status = LogisticsStatusEngine.derive(
      events: t.nodes,
      isOrderSigned: t.stateLabel.contains('签收') || t.lgStatus == 'SIGN',
      pickupCode: t.pickupCode,
      stationName: t.stationName,
    ).status;
    expect(status, PackageStatus.pickedUp);
    expect(LogisticsStatusEngine.urgencyFor(status: status, pickupCode: t.pickupCode), UrgencyLevel.low);
    expect(LogisticsStatusEngine.effectivePickupCode(status: status, pickupCode: t.pickupCode), '');
  });
}
