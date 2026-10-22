/// 已完成包裹二级抽屉面板 - 隔离主屏幕在途视线
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/models/package.dart';
import '../../../providers/package_provider.dart';
import '../../../components/spring_card.dart';
import '../../../components/platform_badge.dart';
import '../../../components/status_pill.dart';
import '../../../components/staggered_entrance.dart';
import '../../../constants/app_constants.dart';
import 'tracking_timeline_sheet.dart';

class CompletedPackagesSheet extends ConsumerWidget {
  const CompletedPackagesSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const CompletedPackagesSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final completedPackages = ref.watch(completedPackagesProvider);
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      // expand 必须为 false：否则控件会撑满整屏，模态遮罩高度被压成 0，
      // 点击抽屉上方留白就无法收回抽屉。
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.lg),
            ),
          ),
          child: Column(
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(
                    top: AppSpacing.md,
                    bottom: AppSpacing.md,
                  ),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '已完成包裹 (${completedPackages.length})',
                      style: theme.textTheme.titleLarge,
                    ),
                    Text(
                      '历史记录已归档',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: completedPackages.isEmpty
                    ? Center(
                        child: Text(
                          '暂无已完成的包裹记录',
                          style: theme.textTheme.bodyMedium,
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        itemCount: completedPackages.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: AppSpacing.md),
                        itemBuilder: (context, index) => StaggeredEntrance(
                          index: index,
                          child: _CompletedPackageCard(
                            package: completedPackages[index],
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 已完成列表里的单张卡片：点击进入物流轨迹抽屉，长按可删除。
class _CompletedPackageCard extends ConsumerWidget {
  final Package package;

  const _CompletedPackageCard({required this.package});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pkg = package;

    return SpringCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      borderRadius: AppRadius.mdAll,
      onTap: () => TrackingTimelineSheet.show(context, pkg),
      onLongPress: () {
        HapticFeedback.mediumImpact();
        showModalBottomSheet(
          context: context,
          builder: (ctx) => SafeArea(
            child: Wrap(
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.statusRejected,
                  ),
                  title: const Text(
                    '删除该包裹',
                    style: TextStyle(color: AppColors.statusRejected),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    ref.read(packageListProvider.notifier).removePackage(pkg.id);
                  },
                ),
              ],
            ),
          ),
        );
      },
      child: Row(
        children: [
          PlatformBadge(platform: pkg.platform),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pkg.goodsName ?? pkg.description.ifEmpty('快件包裹'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  '${pkg.courier.displayName} · ${pkg.trackingNumber}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textTertiary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // 已取件 / 已归档 / 已拒收 共用同一套状态胶囊，
          // 不再把 #34C759 直接当 12px 正文（白底上只有 2.22:1）。
          StatusPill(status: pkg.status),
        ],
      ),
    );
  }
}

extension _StringEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
