/// 模拟数据流式连接器 - 用于验证动效、无网络断开演示与单元测试
library;

import 'dart:async';
import '../../core/models/package.dart';
import '../../core/models/package_status.dart';
import 'platform_connector.dart';

class MockPlatformConnector implements PlatformConnector {
  @override
  final String platformId;
  @override
  final String displayName;
  @override
  final String brandColorHex;

  final List<Package> _mockPackages;

  MockPlatformConnector({
    required this.platformId,
    required this.displayName,
    required this.brandColorHex,
    required List<Package> mockPackages,
  }) : _mockPackages = mockPackages;

  @override
  Future<bool> isAuthenticated() async => true;

  @override
  Stream<Package> streamSync() async* {
    for (final pkg in _mockPackages) {
      // 模拟流式增量到达间隔（获取一点，加载一点）
      await Future.delayed(const Duration(milliseconds: 350));
      yield pkg;
    }
  }

  @override
  Future<void> cancelSync() async {}

  @override
  String? get lastIssue => null;

  /// 预制真实电商多场景数据
  static List<PlatformConnector> createStandardConnectors() {
    final now = DateTime.now();

    final taobaoPackages = [
      Package(
        id: 'TB_SF98234112',
        trackingNumber: 'SF98234112093',
        courier: CourierType.sf,
        goodsName: '戴森 (Dyson) 吹风机配件风嘴',
        goodsImageUrl: 'https://images.unsplash.com/photo-1522337360788-8b13dee7a37e?w=200',
        pickupCode: '3-2-1002',
        stationName: '菜鸟驿站（科技园南区店）',
        location: '2号货架C区',
        platform: 'taobao',
        urgency: UrgencyLevel.normal,
        status: PackageStatus.arrived,
        addedAt: now.subtract(const Duration(hours: 3)),
      ),
      Package(
        id: 'TB_ZTO77889901',
        trackingNumber: '778899012345',
        courier: CourierType.zto,
        goodsName: '无印风全棉水洗四件套 (米白)',
        goodsImageUrl: 'https://images.unsplash.com/photo-1631679706909-1844bbd07221?w=200',
        pickupCode: '11-4-2015',
        stationName: '菜鸟驿站（科技园南区店）',
        location: '大件区堆放架',
        platform: 'taobao',
        urgency: UrgencyLevel.warning,
        status: PackageStatus.arrived,
        addedAt: now.subtract(const Duration(hours: 6)),
      ),
    ];

    final jdPackages = [
      Package(
        id: 'JD_JD00192837',
        trackingNumber: 'JD00192837461',
        courier: CourierType.jd,
        goodsName: '罗技 (G) PRO X SUPERLIGHT 2 机械无线鼠标',
        goodsImageUrl: 'https://images.unsplash.com/photo-1527864550417-7fd91fc51a46?w=200',
        pickupCode: '8910',
        stationName: '京东便民自提柜（东门）',
        location: '03号中柜',
        platform: 'jd',
        urgency: UrgencyLevel.urgent,
        status: PackageStatus.arrived,
        addedAt: now.subtract(const Duration(hours: 1)),
      ),
      Package(
        id: 'JD_JD00881923',
        trackingNumber: 'JD00881923812',
        courier: CourierType.jd,
        goodsName: '三得利乌龙茶 500ml*15瓶 无糖',
        goodsImageUrl: 'https://images.unsplash.com/photo-1556881286-fc6915169721?w=200',
        pickupCode: '',
        stationName: '京东自营配送',
        location: '派送员正在派送途中',
        platform: 'jd',
        urgency: UrgencyLevel.normal,
        status: PackageStatus.delivering,
        addedAt: now.subtract(const Duration(hours: 4)),
      ),
    ];

    final pddPackages = [
      Package(
        id: 'PDD_YT66554433',
        trackingNumber: 'YT66554433221',
        courier: CourierType.yt,
        goodsName: '天然竹浆本色抽纸 30包整箱',
        goodsImageUrl: 'https://images.unsplash.com/photo-1584556812952-905ffd0c611a?w=200',
        pickupCode: 'B-098',
        stationName: '多多驿站（欣悦便利店）',
        location: '前台货架',
        platform: 'pdd',
        urgency: UrgencyLevel.normal,
        status: PackageStatus.arrived,
        addedAt: now.subtract(const Duration(hours: 5)),
      ),
    ];

    return [
      MockPlatformConnector(
        platformId: 'taobao',
        displayName: '淘宝 / 天猫',
        brandColorHex: '#FF5000',
        mockPackages: taobaoPackages,
      ),
      MockPlatformConnector(
        platformId: 'jd',
        displayName: '京东',
        brandColorHex: '#E1251B',
        mockPackages: jdPackages,
      ),
      MockPlatformConnector(
        platformId: 'pdd',
        displayName: '拼多多',
        brandColorHex: '#E02E24',
        mockPackages: pddPackages,
      ),
    ];
  }
}
