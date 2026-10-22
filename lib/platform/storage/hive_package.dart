/// 包裹数据模型 - Hive持久化层
/// 
/// 职责：
/// 1. 提供Hive序列化支持
/// 2. 桥接核心模型和持久化层
/// 3. 保持向后兼容
library;

import '../../core/models/package.dart';
import '../../core/models/package_status.dart';

// 重新导出核心模型，保持API兼容
export '../../core/models/package.dart';
export '../../core/models/package_status.dart';

/// Hive持久化的Package模型
/// 
/// 注意：这个类主要用于Hive序列化，
/// 业务逻辑应该使用核心模型
/// 
/// 适配器在 adapters/hive_adapters.dart 中定义
class HivePackage {
  final String id;
  final String trackingNumber;
  final CourierType courier;
  final String pickupCode;
  final String location;
  final String originalStation;
  final String description;
  final UrgencyLevel urgency;
  final PackageStatus status;
  final DateTime addedAt;
  final DateTime? pickedUpAt;
  final bool notifiedArrived;
  final DateTime? archivedAt;
  final String? transitFingerprint;  // transit 阶段的弱身份标识
  final String? goodsName;
  final String? goodsImageUrl;
  final String? platform;
  final String? stationName;
  final String? rawTimelineJson;
  final String fingerprint;  // 包裹唯一识别指纹

  HivePackage({
    required this.id,
    required this.trackingNumber,
    required this.courier,
    this.pickupCode = '',
    this.location = '',
    this.originalStation = '',
    this.description = '',
    required this.urgency,
    required this.status,
    required this.addedAt,
    this.pickedUpAt,
    this.notifiedArrived = false,
    this.archivedAt,
    this.transitFingerprint,
    this.goodsName,
    this.goodsImageUrl,
    this.platform,
    this.stationName,
    this.rawTimelineJson,
    String? fingerprint,
  }) : this.fingerprint = fingerprint ?? Package.buildFingerprintStatic(pickupCode, courier, trackingNumber);

  /// 从核心模型创建
  factory HivePackage.fromPackage(Package package) {
    return HivePackage(
      id: package.id,
      trackingNumber: package.trackingNumber,
      courier: package.courier,
      pickupCode: package.pickupCode,
      location: package.location,
      originalStation: package.originalStation,
      description: package.description,
      urgency: package.urgency,
      status: package.status,
      addedAt: package.addedAt,
      pickedUpAt: package.pickedUpAt,
      notifiedArrived: package.notifiedArrived,
      archivedAt: package.archivedAt,
      transitFingerprint: package.transitFingerprint,
      goodsName: package.goodsName,
      goodsImageUrl: package.goodsImageUrl,
      platform: package.platform,
      stationName: package.stationName,
      rawTimelineJson: package.rawTimelineJson,
      fingerprint: package.fingerprint,
    );
  }

  /// 转换为核心模型
  Package toPackage() {
    return Package(
      id: id,
      trackingNumber: trackingNumber,
      courier: courier,
      pickupCode: pickupCode,
      location: location,
      originalStation: originalStation,
      description: description,
      urgency: urgency,
      status: status,
      addedAt: addedAt,
      pickedUpAt: pickedUpAt,
      notifiedArrived: notifiedArrived,
      archivedAt: archivedAt,
      transitFingerprint: transitFingerprint,
      goodsName: goodsName,
      goodsImageUrl: goodsImageUrl,
      platform: platform,
      stationName: stationName,
      rawTimelineJson: rawTimelineJson,
      fingerprint: fingerprint,
    );
  }

  HivePackage copyWith({
    String? id,
    String? trackingNumber,
    CourierType? courier,
    String? pickupCode,
    String? location,
    String? originalStation,
    String? description,
    UrgencyLevel? urgency,
    PackageStatus? status,
    DateTime? addedAt,
    DateTime? pickedUpAt,
    bool? notifiedArrived,
    DateTime? archivedAt,
    String? transitFingerprint,
    String? goodsName,
    String? goodsImageUrl,
    String? platform,
    String? stationName,
    String? fingerprint,
  }) {
    return HivePackage(
      id: id ?? this.id,
      trackingNumber: trackingNumber ?? this.trackingNumber,
      courier: courier ?? this.courier,
      pickupCode: pickupCode ?? this.pickupCode,
      location: location ?? this.location,
      originalStation: originalStation ?? this.originalStation,
      description: description ?? this.description,
      urgency: urgency ?? this.urgency,
      status: status ?? this.status,
      addedAt: addedAt ?? this.addedAt,
      pickedUpAt: pickedUpAt ?? this.pickedUpAt,
      notifiedArrived: notifiedArrived ?? this.notifiedArrived,
      archivedAt: archivedAt ?? this.archivedAt,
      transitFingerprint: transitFingerprint ?? this.transitFingerprint,
      goodsName: goodsName ?? this.goodsName,
      goodsImageUrl: goodsImageUrl ?? this.goodsImageUrl,
      platform: platform ?? this.platform,
      stationName: stationName ?? this.stationName,
      fingerprint: fingerprint ?? this.fingerprint,
    );
  }
}
