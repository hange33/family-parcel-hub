/// Regex模式集合 - 纯数据配置
/// 
/// 职责：
/// 1. 定义所有正则表达式模式
/// 2. 按功能分组
/// 3. 不包含任何逻辑
library;

/// Regex模式集合
class RegexPatterns {
  // ── 预处理 ──────────────────────────────────────────────────

  /// 中文字符间的空格
  static final chineseSpace = RegExp(r'([一-鿿])\s+([一-鿿])');
  
  /// 时间格式
  static final timeFormat = RegExp(r'\d{1,2}:\d{2}\s*[APMapm]*');
  
  /// 信号相关
  static final signalNoise = RegExp(
    r'(?:5G|4G|LTE|WiFi?|信号|电量|\d+%)',
    caseSensitive: false,
  );
  
  /// 价格相关
  static final priceNoise = RegExp(r'[¥￥]\d+\.?\d*');
  
  /// 补贴相关
  static final subsidyNoise = RegExp(r'\d+亿补贴', caseSensitive: false);
  
  /// 促销相关
  static final promoNoise = RegExp(
    r'(?:领券后|抢购|立享|补贴|优惠券|限时)[^。\n]{0,30}',
  );

  // ── 取件码 ──────────────────────────────────────────────────

  /// 带标签的取件码
  static final labeledPickupCode = RegExp(
    r'(?:取件码|取货码|提取码|验证码|凭码|收件码)[：:\s]*([A-Za-z0-9\-—－]{2,20})',
  );
  
  /// 短格式取件码
  static final shortPickupCode = RegExp(
    r'码[：:\s]*([A-Za-z0-9\-—－]{2,20})',
  );
  
  /// Bay格式取件码
  static final bayFormatCode = RegExp(
    r'\b(\d{1,2})[\-—－](\d{1,2})[\-—－](\d{2,4})\b',
  );
  
  /// 纯数字取件码（4-8位）
  static final digitCode = RegExp(r'\b(\d{4,8})\b');
  
  /// 运单号前缀（用于排除）
  static final trackingPrefix = RegExp(r'(?:单号|运单|订单|快递)\s*$');
  
  /// 快递公司前缀（用于排除）
  static final courierPrefix = RegExp(r'^(?:SF|JD|YT|ZTO)');

  // ── 取货地点 ──────────────────────────────────────────────────

  /// 地点标题格式1：城市+区域+具体位置+店/驿站
  static final locationTitle1 = RegExp(
    r'([\u4e00-\u9fa5]{2,6}(?:市|省|区|县|镇)[\u4e00-\u9fa5]{2,15}(?:店|驿站|网点|营业部|快递柜))',
  );
  
  /// 地点标题格式2：具体位置+驿站/营业部等
  static final locationTitle2 = RegExp(
    r'([\u4e00-\u9fa5]{4,20}(?:驿站|营业部|网点|配送站|自提点|快递柜))',
  );
  
  /// 到达格式：已到[XXXX]
  static final arrivalFormat = RegExp(
    r'(?:到[达了]?|已到|入[了]?)[【\[]?([^】\]，。！\n]{2,30}?[站店柜中心部])',
  );
  
  /// 到达前缀清理
  static final arrivalPrefix = RegExp(r'^[到达了入]+');

  // ── 运单号 ──────────────────────────────────────────────────

  /// 带标签的运单号
  static final labeledTrackingNumber = RegExp(
    r'(?:快递单号|运单号|物流单号|包裹编号|单号)[：:\s]*([A-Za-z0-9]{10,25})',
  );
  
  /// 快递公司+运单号（保留完整格式含前缀）
  static final courierTrackingNumber = RegExp(
    r'((?:中通速递|中通快递|中通|圆通速递|圆通|申通快递|申通|韵达快递|韵达|极兔速递|极兔|顺丰速运|顺丰)\s*(?:[A-Za-z]{2})?\d{8,25})',
  );

  /// 宽松的快递公司+运单号（短名称 + 运单号，如"申通777407042267539"）
  static final looseCourierTrackingNumber = RegExp(
    r'((?:中通|圆通|申通|韵达|极兔|顺丰|京东|EMS|邮政|德邦|百世)\s*\d{8,25})',
  );

  /// 极兔运单号 (JT开头)
  static final jtTracking = RegExp(r'\b(JT\d{12,18})\b');
  
  /// 顺丰运单号
  static final sfTracking = RegExp(r'\b(SF\d{8,20})\b');
  
  /// 京东运单号
  static final jdTracking = RegExp(r'\b(JD\d{8,20})\b');
  
  /// 中通运单号
  static final ztoTracking = RegExp(r'\b(ZTO?\d{10,20})\b', caseSensitive: false);
  
  /// 圆通运单号
  static final ytTracking = RegExp(r'\b(YT\d{8,20})\b');
  
  /// 圆通新格式运单号
  static final yt88Tracking = RegExp(r'\b(YT88\d{10,20})\b');
  
  /// 纯数字运单号
  static final numericTracking = RegExp(r'\b(\d{14,22})\b');

  /// 宽松纯数字运单号（兜底：10-18位）
  static final looseNumericTracking = RegExp(r'\b(\d{10,18})\b');
  
  /// 手机号（用于排除）
  static final phoneNumber = RegExp(r'^1[3-9]\d{9}$');

  // ── 手机尾号 ──────────────────────────────────────────────────

  /// 明确的手机尾号
  static final explicitTail = RegExp(
    r'(?:手机尾号|尾号|末四位)[号：:\s]*(\d{4})',
  );
  
  /// 掩码手机号
  static final maskedPhone = RegExp(
    r'(?:手机|电话|机主)[号：:\s]*[\*]*1[3-9]\d[*\s]*(\d{4})',
  );
  
  /// 完整手机号
  static final fullPhone = RegExp(r'\b(1[3-9]\d{9})\b');
  
  /// 机主相关尾号
  static final ownerTail = RegExp(
    r'(?:本人|收件人|机主)[^0-9]{0,20}(\d{4})\b',
  );

  // ── 地址清理 ──────────────────────────────────────────────────

  /// 空白字符
  static final whitespace = RegExp(r'\s+');
  
  /// 特殊字符前缀
  static final specialPrefix = RegExp(r'^[>\s\-•·]+');
  
  /// 字母数字前缀
  static final alphaPrefix = RegExp(r'^[A-Za-z0-9]{1,3}[\s\-]');
}
