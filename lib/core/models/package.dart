/// 包裹核心模型 - 纯Dart，不依赖Flutter
/// 
/// 职责：
/// 1. 定义包裹数据结构
/// 2. 提供不可变的数据操作
/// 3. 提供业务逻辑判断
library;

import 'dart:convert';
import 'package_status.dart';

/// 快递公司类型
enum CourierType {
  sf,    // 顺丰
  jd,    // 京东
  zto,   // 中通
  yd,    // 韵达
  yt,    // 圆通
  sto,   // 申通
  ems,   // EMS
  jt,    // 极兔
  db,    // 德邦
  best,  // 百世
  other, // 其他
}

/// 快递公司信息
extension CourierTypeX on CourierType {
  String get displayName {
    switch (this) {
      case CourierType.sf:
        return '顺丰速运';
      case CourierType.jd:
        return '京东快递';
      case CourierType.zto:
        return '中通快递';
      case CourierType.yd:
        return '韵达快递';
      case CourierType.yt:
        return '圆通速递';
      case CourierType.sto:
        return '申通快递';
      case CourierType.ems:
        return 'EMS';
      case CourierType.jt:
        return '极兔速递';
      case CourierType.db:
        return '德邦快递';
      case CourierType.best:
        return '百世快递';
      case CourierType.other:
        return '其他';
    }
  }

  String get shortName {
    switch (this) {
      case CourierType.sf:
        return '顺丰';
      case CourierType.jd:
        return '京东';
      case CourierType.zto:
        return '中通';
      case CourierType.yd:
        return '韵达';
      case CourierType.yt:
        return '圆通';
      case CourierType.sto:
        return '申通';
      case CourierType.ems:
        return 'EMS';
      case CourierType.jt:
        return '极兔';
      case CourierType.db:
        return '德邦';
      case CourierType.best:
        return '百世';
      case CourierType.other:
        return '其他';
    }
  }
}

/// 紧急程度
enum UrgencyLevel {
  low,     // 不急
  normal,  // 明后天
  warning, // 今日取
  urgent,  // 紧急
}

extension UrgencyLevelX on UrgencyLevel {
  String get label {
    switch (this) {
      case UrgencyLevel.low:
        return '不急';
      case UrgencyLevel.normal:
        return '明后天';
      case UrgencyLevel.warning:
        return '今日取';
      case UrgencyLevel.urgent:
        return '紧急';
    }
  }
  
  /// 紧急程度评分
  int get score {
    switch (this) {
      case UrgencyLevel.low:
        return 0;
      case UrgencyLevel.normal:
        return 1;
      case UrgencyLevel.warning:
        return 2;
      case UrgencyLevel.urgent:
        return 3;
    }
  }
}

/// 包裹核心模型
class Package {
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
  final DateTime? archivedAt;
  final bool notifiedArrived;
  final List<StatusTransition> statusHistory;
  final String? transitFingerprint;  // transit 阶段的弱身份标识
  final String? goodsName;
  final String? goodsImageUrl;
  final String? platform;
  final String? stationName;
  final String? rawTimelineJson; // 序列化的完整物流节点列表
  final String fingerprint;  // 包裹唯一识别指纹

  /// 获取展示用的有效承运商（若未指定则通过单号规则推断，如 JT 开头为极兔）
  CourierType get effectiveCourier {
    if (courier != CourierType.other) return courier;
    final tn = trackingNumber.toUpperCase();
    if (tn.startsWith('JT')) return CourierType.jt;
    if (tn.startsWith('SF')) return CourierType.sf;
    if (tn.startsWith('YT')) return CourierType.yt;
    if (tn.startsWith('ST')) return CourierType.sto;
    if (tn.startsWith('JD')) return CourierType.jd;
    if (tn.startsWith('ZTO')) return CourierType.zto;
    return courier;
  }

  /// 获取订单原始编号（去除平台前缀）
  String get displayOrderSn {
    if (id.startsWith('PDD_')) return id.substring(4);
    if (id.startsWith('JD_')) return id.substring(3);
    if (id.startsWith('TB_')) return id.substring(3);
    return id;
  }

  String get displayLocation {
    // 包裹未到达时，不显示驿站相关信息
    if (!status.isArrived) {
      if (location.isNotEmpty) return location;
      if (status == PackageStatus.pendingShipment) return '等待商家发货';
      return '运输途中';
    }

    // 包裹已到达：优先显示驿站信息
    if (stationName != null && stationName!.isNotEmpty && stationName != '未知驿站') {
      // 确定是驿站
      if (location.isNotEmpty) return '$stationName · $location';
      return stationName!;
    }

    // 包裹已到达但不是驿站：显示取货地点
    if (location.isNotEmpty && originalStation.isNotEmpty) return '$originalStation · $location';
    if (location.isNotEmpty) return location;
    if (originalStation.isNotEmpty) return originalStation;

    // 已到达但无明确地点信息
    return '请查看物流详情';
  }

  /// 获取解析后的完整时间轴节点列表
  List<Map<String, String>> get parsedTimeline {
    if (rawTimelineJson == null || rawTimelineJson!.isEmpty) return const [];
    try {
      final list = jsonDecode(rawTimelineJson!) as List<dynamic>;
      return list.map((e) => Map<String, String>.from(e as Map)).toList();
    } catch (_) {
      return const [];
    }
  }

  Package({
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
    this.archivedAt,
    this.notifiedArrived = false,
    this.statusHistory = const [],
    this.transitFingerprint,
    this.goodsName,
    this.goodsImageUrl,
    this.platform,
    this.stationName,
    this.rawTimelineJson,
    String? fingerprint,
  }) : fingerprint = fingerprint ?? buildFingerprintStatic(pickupCode, courier, trackingNumber);

  /// 构建包裹指纹
  /// 优先级：pickupCode > trackingNumber > courier
  static String buildFingerprintStatic(
    String pickupCode,
    CourierType courier, [
    String trackingNumber = '',
  ]) {
    final carrierName = courier.displayName;
    if (pickupCode.trim().isNotEmpty) {
      return '${pickupCode}_$carrierName'.toLowerCase().trim();
    }
    if (trackingNumber.trim().isNotEmpty) {
      return '${trackingNumber}_$carrierName'.toLowerCase().trim();
    }
    return carrierName.toLowerCase().trim();
  }

  /// 构建包裹指纹（带 phoneTail）
  static String buildFingerprint({
    required String pickupCode,
    String? carrier,
    String? phoneTail,
  }) {
    return '${pickupCode}_${carrier ?? ''}_${phoneTail ?? ''}'
        .toLowerCase()
        .trim();
  }

  Package copyWith({
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
    DateTime? archivedAt,
    bool? notifiedArrived,
    List<StatusTransition>? statusHistory,
    String? transitFingerprint,
    String? goodsName,
    String? goodsImageUrl,
    String? platform,
    String? stationName,
    bool clearStationName = false,
    String? rawTimelineJson,
    String? fingerprint,
  }) {
    return Package(
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
      archivedAt: archivedAt ?? this.archivedAt,
      notifiedArrived: notifiedArrived ?? this.notifiedArrived,
      statusHistory: statusHistory ?? this.statusHistory,
      transitFingerprint: transitFingerprint ?? this.transitFingerprint,
      goodsName: goodsName ?? this.goodsName,
      goodsImageUrl: goodsImageUrl ?? this.goodsImageUrl,
      platform: platform ?? this.platform,
      stationName: clearStationName ? null : (stationName ?? this.stationName),
      rawTimelineJson: rawTimelineJson ?? this.rawTimelineJson,
      fingerprint: fingerprint ?? this.fingerprint,
    );
  }

  /// 转换状态，自动记录历史
  Package transitionTo(PackageStatus newStatus, {String? reason}) {
    final transition = StatusTransition(
      from: status,
      to: newStatus,
      timestamp: DateTime.now(),
      reason: reason,
    );
    
    if (!transition.isValid) {
      throw StateError('Invalid status transition: ${status.label} → ${newStatus.label}');
    }
    
    return copyWith(
      status: newStatus,
      pickedUpAt: newStatus == PackageStatus.pickedUp ? DateTime.now() : pickedUpAt,
      archivedAt: newStatus == PackageStatus.archived ? DateTime.now() : archivedAt,
      statusHistory: [...statusHistory, transition],
    );
  }

  /// 是否需要自动归档（已取件超过7天）
  bool get shouldAutoArchive {
    if (status != PackageStatus.pickedUp) return false;
    if (pickedUpAt == null) return false;
    return DateTime.now().difference(pickedUpAt!).inDays >= 7;
  }

  /// 是否与其他包裹在同一取件点
  bool isSameLocation(Package other) {
    if (location.isEmpty || other.location.isEmpty) return false;
    return location == other.location;
  }

  /// 是否为同一快递（基于快递公司和运单号）
  bool isSamePackage(Package other) {
    return courier == other.courier && trackingNumber == other.trackingNumber;
  }

  /// 综合紧急程度评分（状态 + 紧急级别）
  int get compositeUrgencyScore {
    return status.urgencyScore + urgency.score * 10;
  }
}
