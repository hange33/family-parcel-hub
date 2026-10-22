/// 状态词典 - 纯数据配置
/// 
/// 职责：
/// 1. 定义状态关键词映射
/// 2. 定义状态推断规则
/// 3. 不包含任何逻辑
library;

import '../models/package_status.dart';

/// 状态词典
class StatusDictionary {
  /// 状态关键词映射：关键词 → PackageStatus
  /// 这些是高置信度关键词，单独出现就足以判定状态
  static const Map<String, PackageStatus> stageMap = {
    // 已拒收（异常终结态，优先级最高：拒收后不应再被识别为签收/在途）
    '已拒收': PackageStatus.rejected,
    '拒收': PackageStatus.rejected,
    '已退回': PackageStatus.rejected,
    '退回发件人': PackageStatus.rejected,
    '退件': PackageStatus.rejected,

    // 已取件（高置信度）
    '已签收': PackageStatus.pickedUp,
    '签收': PackageStatus.pickedUp,
    '代收': PackageStatus.pickedUp,
    '前台代收': PackageStatus.pickedUp,
    '物业代收': PackageStatus.pickedUp,
    '门卫代收': PackageStatus.pickedUp,
    
    // 已到达（高置信度）
    '已到驿站': PackageStatus.arrived,
    '入驿站': PackageStatus.arrived,
    '到驿站': PackageStatus.arrived,
    '驿站入库': PackageStatus.arrived,
    '已到菜鸟': PackageStatus.arrived,
    '入柜': PackageStatus.arrived,
    '已入柜': PackageStatus.arrived,
    '待取件': PackageStatus.arrived,
    '到营业部': PackageStatus.arrived,
    '已到达顺丰': PackageStatus.arrived,
    '已到达申通': PackageStatus.arrived,
    '已到达圆通': PackageStatus.arrived,
    '已到达中通': PackageStatus.arrived,
    '已到达韵达': PackageStatus.arrived,
    '已到达极兔': PackageStatus.arrived,
    '已到达': PackageStatus.arrived,
    
    // 派送中（高置信度）
    '派送中': PackageStatus.delivering,
    '配送中': PackageStatus.delivering,
    '正在派送': PackageStatus.delivering,
    
    // 运送中（高置信度）
    '已揽收': PackageStatus.transit,
    '揽收': PackageStatus.transit,
    '运输中': PackageStatus.transit,
    '已发出': PackageStatus.transit,
    '已发货': PackageStatus.transit,
    '已到达分拣': PackageStatus.transit,
    '分拣': PackageStatus.transit,

    // 待发货（高置信度）
    '待发货': PackageStatus.pendingShipment,
    '等待发货': PackageStatus.pendingShipment,
    '未发货': PackageStatus.pendingShipment,
    '等待商家发货': PackageStatus.pendingShipment,
  };

  // ── 多信号关键词分类 ──────────────────────────────────────────

  /// 取件码信号关键词
  static const List<String> pickupCodeSignals = [
    '取件码', '取货码', '提取码', '验证码', '凭码', '收件码',
  ];

  /// 驿站/地点信号关键词
  static const List<String> locationSignals = [
    '驿站', '菜鸟', '营业部', '网点', '快递柜', '丰巢',
    '配送站', '自提点', '代收点', '服务点',
  ];

  /// 已到达/待取件信号关键词
  static const List<String> arrivedSignals = [
    '已到达', '已到', '待取件', '已入库', '入库',
    '请取件', '来取', '领取', '收取',
  ];

  /// 取件动作信号关键词
  static const List<String> pickupActionSignals = [
    '取件', '提取', '提货', '领取', '收取',
  ];

  /// 签收/已取件信号关键词
  static const List<String> pickedUpSignals = [
    '签收', '代收', '已收', '已取', '已签',
  ];

  /// 派送中信号关键词
  static const List<String> deliveringSignals = [
    '派送', '配送', '派件', '送件',
  ];

  /// 运送中信号关键词
  static const List<String> transitSignals = [
    '揽收', '运输', '已发出', '已发货', '已发', '分拣',
  ];

  // ── Bay 格式正则 ──────────────────────────────────────────────

  /// Bay 格式取件码（如 6-8-2301）
  static final bayFormatRegex = RegExp(r'\b\d{1,2}-\d{1,2}-\d{2,4}\b');

  /// 纯数字取件码（4-8位）
  static final digitCodeRegex = RegExp(r'\b\d{4,8}\b');
}
