/// 电商平台标识与显示名 - 纯Dart
library;

/// 全部支持保活的平台标识（顺序即界面展示顺序）
///
/// 需求方不要各自硬编码平台列表：保活服务、同步历史统计、设置页都从这里取。
const List<String> kPlatformIds = ['taobao', 'jd', 'pdd'];

/// 平台中文显示名；未知平台回退为标识本身
String platformDisplayName(String platform) {
  switch (platform) {
    case 'taobao':
      return '淘宝 / 天猫';
    case 'jd':
      return '京东商城';
    case 'pdd':
      return '拼多多';
    default:
      return platform;
  }
}
