// 旧测试集（pickup_app 历史仓库）里值得保留的文本样本回归。
//
// 样本来源：test/fixtures/legacy/**.json 全部是 P11-a 脱敏器
// `DiagSanitizer.sanitizeRaw`（PR #3，origin/feat/p11a-taobao-capture @ fd41655）的原样输出，
// 未做任何手工修改；脱敏后取件码数字全部变成 9（如 `9-9-9999`），所以下面的期望值也是脱敏后的值。
// 原始样本只存放在仓库外的私有目录，不进 git。详见 test/fixtures/legacy/README.md。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/core/models/package.dart';
import 'package:pickup_app/core/models/package_status.dart';
import 'package:pickup_app/core/parser/text_parser.dart';
import 'package:pickup_app/core/sanitizer/text_sanitizer.dart';

/// 读取脱敏器输出（`{"_unparsed": true, "raw": "..."}`）里的文本。
String _legacy(String path) {
  final json = jsonDecode(File('test/fixtures/legacy/$path.json').readAsStringSync());
  return (json as Map<String, dynamic>)['raw'] as String;
}

void main() {
  group('legacy bad：非物流页面必须触发熔断', () {
    for (final name in ['dashboard_homepage', 'settings_page', 'shopping_product']) {
      test(name, () {
        expect(TextSanitizer.shouldAbortParse(_legacy('bad/$name')), isTrue,
            reason: '$name：非物流内容应该触发熔断');
      });
    }
  });

  group('legacy edge：边缘输入不崩溃', () {
    for (final name in ['conflict_transit_arrival', 'mixed_courier_names', 'very_short_sms']) {
      test(name, () {
        expect(() => TextParser.parseMulti(_legacy('edge/$name')), returnsNormally);
      });
    }
  });

  group('legacy good：必须解析成功', () {
    test('sf_arrived_with_code：顺丰到站短信可创建包裹', () {
      final results = TextParser.parseMulti(_legacy('good/sf_arrived_with_code'));
      expect(results, isNotEmpty);
      expect(results.first.isValid, isTrue);
      expect(results.first.canCreatePackage, isTrue);
      expect(results.first.courier.value, CourierType.sf);
    });

    test('arrived_with_code_override：有取件码时状态为待取件而不是已取件', () {
      final results = TextParser.parseMulti(_legacy('good/arrived_with_code_override'));
      expect(results, isNotEmpty);
      expect(results.first.pickupCode.value, '9-9-9999');
      expect(results.first.status.value, PackageStatus.arrived);
    });
  });

  group('legacy notifications：通知文本解析', () {
    test('pdd_arrived：取件码、待取件状态、驿站', () {
      final results = TextParser.parseMulti(_legacy('notifications/pdd_arrived'));
      expect(results, isNotEmpty);
      final r = results.first;
      expect(r.pickupCode.value, '9-9-9999');
      expect(r.status.value, PackageStatus.arrived);
      expect(r.station.value, '驿站');
    });

    test('multi_package_notification：一条通知里的两个包裹都解析出来', () {
      final results = TextParser.parseMulti(_legacy('notifications/multi_package_notification'));
      expect(results.length, greaterThanOrEqualTo(2));
      expect(results.map((r) => r.pickupCode.value), everyElement('99-9-9999'));
      expect(results.map((r) => r.courier.value), containsAll([CourierType.zto, CourierType.yt]));
    });

    test('non_courier_notification：非快递通知不应识别成某家快递', () {
      final results = TextParser.parseMulti(_legacy('notifications/non_courier_notification'));
      if (results.isNotEmpty) {
        expect(results.first.courier.value, CourierType.other);
      }
    });
  });
}
