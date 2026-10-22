/// 物流关键词
/// 
/// 职责：
/// 1. 定义物流相关的关键词
/// 2. 用于识别物流信息行
library;

/// 物流关键词
class LogisticsKeywords {
  /// 快递公司名称（含 OCR 误识别变体）
  static const List<String> courierNames = [
    '顺丰', '须丰',
    '京东',
    '中通', '中過', '中兔', '中遁', '中道',
    '韵达', '韵运', '韵选',
    '圆通', '园通', '圆运',
    '申通', '申兔', '甲通',
    '极兔', '极免', '兔兔',
    '邮政', 'EMS', '德邦', '德帮', '百世',
    '丰巢', '菜鸟', '菜鸟驿站',
  ];

  /// 运输状态关键词
  static const List<String> transitStatus = [
    '运输中', '已发往', '离开', '已发出', '已发货',
    '已揽收', '分拣中', '在路上', '运输途中',
    '已到达', '到达', '已到',
  ];

  /// 取件状态关键词
  static const List<String> arrivalStatus = [
    '待取件', '已放至', '已到驿站', '请及时领取',
    '已入库', '请取件', '来取', '领取',
    '已放', '存放', '代收点',
  ];

  /// 取件码关键词
  static const List<String> pickupCodeKeywords = [
    '取件码', '收件码', '凭码', '提取码', '验证码',
  ];

  /// 物流节点关键词（不是取件地点）
  static const List<String> logisticsNodes = [
    '转运中心', '分拨中心', '集运仓', '物流园',
    '运输中心', '分拣中心', '中转站', '配送中心',
  ];

  /// 取件地点关键词
  static const List<String> pickupLocations = [
    '驿站', '营业部', '网点', '快递柜', '丰巢',
    '配送站', '自提点', '代收点', '服务点',
    '门店', '商店', '超市',
  ];

  /// 快递员关键词
  static const List<String> courierPersonnel = [
    '快递员', '配送员', '派件员', '收件员',
  ];

  /// 联系方式关键词
  static const List<String> contactKeywords = [
    '电话', '手机', '联系', '客服', '热线',
  ];

  /// 获取所有物流关键词
  static List<String> get allKeywords => [
    ...courierNames,
    ...transitStatus,
    ...arrivalStatus,
    ...pickupCodeKeywords,
    ...logisticsNodes,
    ...pickupLocations,
    ...courierPersonnel,
    ...contactKeywords,
  ];

  /// 检查文本是否包含物流关键词
  static bool containsLogistics(String text) {
    return allKeywords.any((kw) => text.contains(kw));
  }

  /// 检查是否为运输状态
  static bool isTransitStatus(String text) {
    return transitStatus.any((kw) => text.contains(kw));
  }

  /// 检查是否为取件状态
  static bool isArrivalStatus(String text) {
    return arrivalStatus.any((kw) => text.contains(kw));
  }

  /// 检查是否为物流节点
  static bool isLogisticsNode(String text) {
    return logisticsNodes.any((kw) => text.contains(kw));
  }

  /// 检查是否为取件地点
  static bool isPickupLocation(String text) {
    return pickupLocations.any((kw) => text.contains(kw));
  }
}
