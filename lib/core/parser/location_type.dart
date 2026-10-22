/// 位置类型定义
/// 
/// 职责：
/// 1. 定义位置类型枚举
/// 2. 提供位置类型判断逻辑
library;

/// 位置类型
enum LocationType {
  /// 取件站点（菜鸟驿站、代收点、快递柜等）
  pickupStation,
  
  /// 转运中心（物流节点，不是取件地点）
  transitCenter,
  
  /// 仓库
  warehouse,
  
  /// 派送区域
  deliveryArea,
  
  /// 未知
  unknown,
}

/// 位置类型扩展
extension LocationTypeX on LocationType {
  /// 是否为有效取件地点
  bool get isValidPickupLocation => this == LocationType.pickupStation;
  
  /// 是否为物流节点（不是取件地点）
  bool get isTransitNode => 
      this == LocationType.transitCenter || 
      this == LocationType.warehouse;
  
  /// 类型标签
  String get label {
    switch (this) {
      case LocationType.pickupStation:
        return '取件站点';
      case LocationType.transitCenter:
        return '转运中心';
      case LocationType.warehouse:
        return '仓库';
      case LocationType.deliveryArea:
        return '派送区域';
      case LocationType.unknown:
        return '未知';
    }
  }
}

/// 位置解析结果
class LocationParseResult {
  /// 位置文本
  final String value;
  
  /// 位置类型
  final LocationType type;
  
  /// 置信度
  final double confidence;
  
  /// 匹配来源
  final String? source;

  const LocationParseResult({
    required this.value,
    required this.type,
    this.confidence = 0.0,
    this.source,
  });

  /// 空结果
  factory LocationParseResult.empty() {
    return const LocationParseResult(
      value: '',
      type: LocationType.unknown,
      confidence: 0.0,
      source: 'no_match',
    );
  }

  /// 是否有效
  bool get isValid => value.isNotEmpty && confidence > 0.0;
  
  /// 是否为有效取件地点
  bool get isValidPickupLocation => 
      isValid && type.isValidPickupLocation;
  
  /// 是否为物流节点
  bool get isTransitNode => type.isTransitNode;
}
