/// 噪音词典
/// 
/// 职责：
/// 1. 定义 OCR 文本中的噪音关键词
/// 2. 用于过滤广告、商品标题、UI 元素等
library;

/// 噪音词典
class NoiseDictionary {
  /// 广告/促销关键词
  static const List<String> adKeywords = [
    '优惠', '补贴', '领券', '限时', '抢购', '立享',
    '元', '¥', '￥', '折', '免费', '赠送',
    '广告', '推广', '推荐商品', '秒杀', '爆款',
    '包邮', '满减', '折扣', '特价', '清仓',
    '旗舰店', '官方旗舰店', '品牌店',
  ];

  /// 商品描述关键词
  static const List<String> productKeywords = [
    '颜色', '尺码', '规格', '型号', '材质',
    '重量', '尺寸', '容量', '数量',
    '颜色分类', '款式', '套餐',
    '购买', '下单', '付款', '订单',
    '退货', '退款', '换货', '售后',
    '评价', '好评', '差评', '追评',
    '收藏', '加购', '分享',
  ];

  /// UI 元素关键词
  static const List<String> uiKeywords = [
    '返回', '首页', '我的', '设置', '搜索',
    '更多', '展开', '收起', '查看', '点击',
    '复制', '粘贴', '编辑', '删除', '取消',
    '确认', '提交', '保存', '加载中',
    '刷新', '重试', '确定', '取消',
    '上拉加载', '下拉刷新', '滑动', '左右滑动',
  ];

  /// 系统信息关键词
  static const List<String> systemKeywords = [
    '5G', '4G', 'LTE', 'WiFi', '信号', '电量',
    '时间', '日期', '星期', '上午', '下午',
    '分钟前', '小时前', '天前', '刚刚',
    '网络', '蓝牙', 'GPS', 'NFC',
    '版本', '更新', '升级', '下载',
  ];

  /// 社交/分享关键词
  static const List<String> socialKeywords = [
    '分享', '转发', '朋友圈', '微博', '抖音',
    '快手', '小红书', '微信', 'QQ',
    '点赞', '评论', '关注', '粉丝',
    '私信', '聊天', '消息', '通知',
  ];

  /// 获取所有噪音关键词
  static List<String> get allKeywords => [
    ...adKeywords,
    ...productKeywords,
    ...uiKeywords,
    ...systemKeywords,
    ...socialKeywords,
  ];

  /// 检查文本是否包含噪音关键词
  static bool containsNoise(String text) {
    return allKeywords.any((kw) => text.contains(kw));
  }

  /// 获取文本中包含的噪音关键词
  static List<String> getNoiseKeywords(String text) {
    return allKeywords.where((kw) => text.contains(kw)).toList();
  }
}
