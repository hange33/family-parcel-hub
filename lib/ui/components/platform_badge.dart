/// 来源电商平台标识徽标
///
/// 这里保留各平台的品牌色（淘宝橙、京东红、拼多多红、抖音黑），属于品牌忠实度，
/// 不并入应用的单一强调色体系 —— 用户正是靠颜色区分「这件是哪个平台的」。
library;

import 'package:flutter/material.dart';

import '../constants/app_constants.dart';

class PlatformBadge extends StatelessWidget {
  final String? platform;

  const PlatformBadge({super.key, this.platform});

  @override
  Widget build(BuildContext context) {
    final (name, color, icon) = _getPlatformMeta(platform);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadius.xsAll,
        border: Border.all(
          color: color.withValues(alpha: 0.25),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3.5),
          Text(
            name,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  (String, Color, IconData) _getPlatformMeta(String? platform) {
    switch (platform?.toLowerCase()) {
      case 'taobao':
      case 'tmall':
        return ('淘宝', const Color(0xFFFF5000), Icons.shopping_bag_outlined);
      case 'jd':
        return ('京东', const Color(0xFFE1251B), Icons.flash_on_rounded);
      case 'pdd':
        return ('拼多多', const Color(0xFFE02E24), Icons.local_fire_department_rounded);
      case 'douyin':
        return ('抖音', const Color(0xFF161823), Icons.music_note_rounded);
      default:
        return ('快递', const Color(0xFF5856D6), Icons.local_shipping_outlined);
    }
  }
}
