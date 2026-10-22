/// 快递公司词典 - 纯数据配置
/// 
/// 职责：
/// 1. 定义快递公司关键词映射
/// 2. 定义平台别名
/// 3. 不包含任何逻辑
library;

import '../models/package.dart';

/// 快递公司词典
class CourierDictionary {
  /// 平台别名映射：关键词 → 标准名称
  ///
  /// 包含 OCR 常见误识别变体（形近字、多一字、少一字）
  static const Map<String, String> platformAliases = {
    // 菜鸟
    '菜鸟': '菜鸟驿站',
    '菜鸟裹裹': '菜鸟驿站',
    // 顺丰
    '顺丰': '顺丰速运',
    'SF': '顺丰速运',
    '须丰': '顺丰速运',    // 顺→须 (OCR 形近字)
    '顺丰速': '顺丰速运',
    // 京东
    '京东': '京东快递',
    'JD': '京东快递',
    '京东快': '京东快递',
    // 中通 — OCR 常把"通"认错
    '中通': '中通快递',
    'ZTO': '中通快递',
    '中過': '中通快递',    // 通→過
    '中兔': '中通快递',    // 通→兔
    '中遁': '中通快递',    // 通→遁
    '中道': '中通快递',    // 通→道
    '中通快': '中通快递',
    // 圆通 — OCR 常把"圆"认错
    '圆通': '圆通速递',
    'YT': '圆通速递',
    '园通': '圆通速递',    // 圆→园
    '圆运': '圆通速递',    // 通→运
    '圆通速': '圆通速递',
    '圆通快递': '圆通速递',
    // 韵达
    '韵达': '韵达快递',
    '韵运': '韵达快递',    // 达→运
    '韵选': '韵达快递',    // 达→选
    '韵达快': '韵达快递',
    // 申通
    '申通': '申通快递',
    '申兔': '申通快递',    // 通→兔
    '甲通': '申通快递',    // 申→甲
    '申通快': '申通快递',
    // 极兔 — OCR 常把"兔"认错
    '极兔': '极兔速递',
    'JT': '极兔速递',
    '极免': '极兔速递',    // 兔→免
    '兔兔': '极兔速递',    // 极→兔
    '极兔速': '极兔速递',  // 少一字
    // EMS / 邮政
    '邮政': '邮政EMS',
    'EMS': '邮政EMS',
    '中国邮政': '邮政EMS',
    // 德邦
    '德邦': '德邦快递',
    'DB': '德邦快递',
    '德帮': '德邦快递',    // 邦→帮
    // 百世
    '百世': '百世快递',
    '百世快': '百世快递',
    // 平台
    '拼多多': '拼多多',
    '淘宝': '淘宝',
    '天猫': '淘宝',
  };

  /// 具体快递公司关键词（优先级更高）
  /// 包含 OCR 误识别变体
  static const List<String> specificCouriers = [
    '申通', '申兔', '甲通',
    '圆通', '园通', '圆运',
    '中通', '中過', '中兔', '中遁', '中道',
    '韵达', '韵运', '韵选',
    '极兔', '极免', '兔兔',
    '顺丰', '须丰',
    '邮政', 'EMS',
    '德邦', '德帮',
    '百世',
    '京东',
  ];

  /// 标准名称 → CourierType 映射
  static const Map<String, CourierType> nameToType = {
    '顺丰速运': CourierType.sf,
    '京东快递': CourierType.jd,
    '中通快递': CourierType.zto,
    '韵达快递': CourierType.yd,
    '圆通速递': CourierType.yt,
    '申通快递': CourierType.sto,
    '邮政EMS': CourierType.ems,
    '极兔速递': CourierType.jt,
    '德邦快递': CourierType.db,
    '百世快递': CourierType.best,
  };

  /// 从标准名称获取CourierType
  static CourierType getCourierType(String name) {
    for (final entry in nameToType.entries) {
      if (name.contains(entry.key)) {
        return entry.value;
      }
    }
    return CourierType.other;
  }
}
