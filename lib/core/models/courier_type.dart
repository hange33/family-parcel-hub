// lib/core/models/courier_type.dart
// 快递商类型枚举

enum CourierType {
  shunfeng('顺丰', 'SF'),
  jitu('极兔', 'JT'),
  yuantong('圆通', 'YT'),
  zhongtong('中通', 'ZT'),
  yunda('韵达', 'YD'),
  shentong('申通', 'ST'),
  jd('京东', 'JD'),
  ems('EMS', 'EMS'),
  unknown('未知', null);

  const CourierType(this.label, this.trackingPrefix);

  final String label;
  final String? trackingPrefix;

  /// 从快递商名称字符串解析
  static CourierType fromString(String name) {
    for (final type in CourierType.values) {
      if (type == CourierType.unknown) continue;
      if (name.contains(type.label) || name.toUpperCase().contains(type.trackingPrefix ?? '')) {
        return type;
      }
    }
    return CourierType.unknown;
  }
}
