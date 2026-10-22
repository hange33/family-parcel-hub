/// 平台图标与品牌色
///
/// 这些是 Flutter 类型（`IconData` / `Color`），因此不能放进 `core/`；
/// 平台标识与显示名的权威定义仍在 `core/models/platform_ids.dart`。
library;

import 'package:flutter/material.dart';

IconData platformIcon(String platform) {
  switch (platform) {
    case 'taobao':
      return Icons.shopping_bag_rounded;
    case 'jd':
      return Icons.flash_on_rounded;
    case 'pdd':
      return Icons.local_fire_department_rounded;
    default:
      return Icons.store_rounded;
  }
}

Color platformBrandColor(String platform) {
  switch (platform) {
    case 'taobao':
      return const Color(0xFFFF5000);
    case 'jd':
      return const Color(0xFFE1251B);
    case 'pdd':
      return const Color(0xFFE02E24);
    default:
      return Colors.grey;
  }
}

/// 设置页里每个平台的一句话能力说明
String platformSubtitle(String platform) {
  switch (platform) {
    case 'taobao':
      return '支持菜鸟驿站取件码及在途商品图文';
    case 'jd':
      return '支持自营物流、便民柜自提码与在途配送';
    case 'pdd':
      return '内置登录免双端互踢，自动同步在途包裹与取件码';
    default:
      return '';
  }
}
