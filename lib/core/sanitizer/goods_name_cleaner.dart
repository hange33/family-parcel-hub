// lib/core/sanitizer/goods_name_cleaner.dart
// 纯 Dart：商品长标题智能精简规则

class GoodsNameCleaner {
  GoodsNameCleaner._();

  /// 营销/促销类标签前缀匹配正则（如 【官方正品】、[百亿补贴]、〖顺丰包邮〗）
  static final RegExp _bracketTagsPattern = RegExp(
    r'(?:【[^】]*(?:官方|旗舰|正品|专柜|包邮|速发|现货|热销|补贴|秒杀|推荐|爆款|特惠|促销|折扣|新款|限量|送|假一|顺丰|自营|直营|新品)[^】]*】|'
    r'\[[^\]]*(?:官方|旗舰|正品|专柜|包邮|速发|现货|热销|补贴|秒杀|推荐|爆款|特惠|促销|折扣|新款|限量|送|假一|顺丰|自营|直营|新品)[^\]]*\]|'
    r'〖[^〗]*(?:官方|旗舰|正品|专柜|包邮|速发|现货|热销|补贴|秒杀|推荐|爆款|特惠|促销|折扣|新款|限量|送|假一|顺丰|自营|直营|新品)[^〗]*〗|'
    r'〔[^〕]*(?:官方|旗舰|正品|专柜|包邮|速发|现货|热销|补贴|秒杀|推荐|爆款|特惠|促销|折扣|新款|限量|送|假一|顺丰|自营|直营|新品)[^〕]*〕)',
  );

  /// 常见电商 SEO 营销修饰词正则
  static final RegExp _marketingWordsPattern = RegExp(
    r'(202\d款?|官方旗舰店?|专柜正品|正品保障|正品包邮|顺丰速达|顺丰包邮|极速发货|现货速发|限时秒杀|百亿补贴|爆款热卖|爆款推荐|热销推荐|热卖推荐|特惠促销|限时特惠|买\d+送\d+|假一赔[三四五千百十]+)',
  );

  /// 多余连续空白字符
  static final RegExp _multiSpacePattern = RegExp(r'\s{2,}');

  /// 智能清洗与精简电商商品长标题
  /// [maxLength]：最大保留长度，默认 36
  static String clean(String? raw, {int maxLength = 36}) {
    if (raw == null) return '';
    var text = raw.trim();
    if (text.isEmpty) return '';

    // 1. 去除营销类括号标签
    text = text.replaceAll(_bracketTagsPattern, ' ');

    // 2. 剥离高频电商 SEO 营销词
    text = text.replaceAll(_marketingWordsPattern, ' ');

    // 3. 规范化空格与首尾清理
    text = text.replaceAll(_multiSpacePattern, ' ').trim();

    // 4. 清除可能残留的孤立前导或末尾标点
    text = text.replaceAll(RegExp(r'^[\s,，、/|-]+|[\s,，、/|-]+$'), '');

    // 5. 长度截断保护
    if (text.length > maxLength) {
      text = text.substring(0, maxLength).trim();
    }

    // 若清洗后完全变空（极端情况如纯营销词标题），回退安全使用原标题的前 N 个字
    if (text.isEmpty) {
      final fallback = raw.replaceAll(RegExp(r'[【】\[\]]'), '').trim();
      return fallback.length > maxLength ? fallback.substring(0, maxLength) : fallback;
    }

    return text;
  }
}
