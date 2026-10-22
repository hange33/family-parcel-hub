/// 解析结果数据结构 - 纯Dart
/// 
/// 职责：
/// 1. 定义解析结果的数据结构
/// 2. 包含置信度和警告信息
/// 3. 提供结果验证
library;

import '../models/package.dart';
import '../models/package_status.dart';
import 'extractors.dart';
import 'location_type.dart';

/// 解析结果
class ParseResult {
  final ExtractionResult<CourierType> courier;
  final ExtractionResult<String> pickupCode;
  final ExtractionResult<String> trackingNumber;
  final ExtractionResult<String> phoneTail;
  final ExtractionResult<String> location;
  final LocationType locationType;
  final ExtractionResult<String> station;
  final ExtractionResult<PackageStatus> status;
  final List<String> warnings;
  final double overallConfidence;

  const ParseResult({
    required this.courier,
    required this.pickupCode,
    required this.trackingNumber,
    required this.phoneTail,
    required this.location,
    this.locationType = LocationType.unknown,
    required this.station,
    required this.status,
    this.warnings = const [],
    this.overallConfidence = 0.0,
  });

  /// 是否为有效解析结果
  bool get isValid {
    // 至少需要有快递公司或运单号
    return courier.value != CourierType.other || 
           trackingNumber.value.isNotEmpty;
  }

  /// 是否有足够信息创建包裹
  bool get canCreatePackage {
    // 需要有快递公司和状态
    return courier.value != CourierType.other && 
           status.confidence > 0.5;
  }

  /// 获取所有警告
  List<String> get allWarnings {
    final warnings = <String>[];
    
    if (courier.confidence < 0.7) {
      warnings.add('快递公司识别置信度较低');
    }
    if (trackingNumber.confidence < 0.7) {
      warnings.add('运单号识别置信度较低');
    }
    if (location.confidence < 0.7) {
      warnings.add('取货地点识别置信度较低');
    }
    if (status.confidence < 0.7) {
      warnings.add('状态识别置信度较低');
    }
    
    return [...warnings, ...this.warnings];
  }

  /// 转换为ParsedPackage（向后兼容）
  ParsedPackage toParsedPackage() {
    return ParsedPackage(
      courier: courier.value,
      pickupCode: pickupCode.value,
      trackingNumber: trackingNumber.value,
      phoneLast4: phoneTail.value,
      location: location.value,
      status: status.value,
    );
  }
}

/// 向后兼容的ParsedPackage
class ParsedPackage {
  final CourierType courier;
  final String pickupCode;
  final String trackingNumber;
  final String phoneLast4;
  final String location;
  final PackageStatus status;

  const ParsedPackage({
    required this.courier,
    required this.pickupCode,
    this.trackingNumber = '',
    this.phoneLast4 = '',
    required this.location,
    required this.status,
  });
}
