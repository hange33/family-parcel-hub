/// 包裹状态胶囊 —— 首页卡片与已完成抽屉共用同一份实现。
///
/// 配色与文案都取自单一真源（`theme/status_extension.dart` + core 的
/// `PackageStatusSemantics.label`）。改版前这两处各写了一份：
/// 主卡片是 `#007AFF` 浅底，已完成抽屉则是把 `#34C759` 直接当 12px 正文用
/// （白底上只有 2.22:1，远低于 AA 的 4.5:1）。
library;

import 'package:flutter/material.dart';

import '../../core/models/package_status.dart';
import '../constants/app_constants.dart';
import '../theme/motion.dart';
import '../theme/status_extension.dart';

class StatusPill extends StatelessWidget {
  final PackageStatus status;

  const StatusPill({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Motion.of(context, Motion.normal),
      curve: Motion.standard,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: status.pillBackground,
        borderRadius: AppRadius.xsAll,
      ),
      child: AnimatedSwitcher(
        duration: Motion.of(context, Motion.fast),
        child: Text(
          status.label,
          key: ValueKey(status.label),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: status.pillForeground,
          ),
        ),
      ),
    );
  }
}
