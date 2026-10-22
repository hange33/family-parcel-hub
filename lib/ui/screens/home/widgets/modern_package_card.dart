/// 现代化流体卡片组件 - 采用弹簧物理按压反馈与高层级信息布局
///
/// 改版要点：
/// - 状态配色不再由本文件私有维护，统一取自 `theme/status_extension.dart`（唯一真源）；
/// - 状态文案取自 core 的 `PackageStatusSemantics.label`，不再在 UI 里另写一份；
/// - 圆角收敛到令牌（卡片 16 / 内嵌条 12 / 标签 8）；
/// - 修掉三处正文级对比度不达标的内联灰：`Colors.grey`(2.68:1)、
///   `Colors.grey.shade600`、`Colors.orange.shade800`(3.08:1)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/models/package.dart';
import '../../../../core/models/package_status.dart';
import '../../../providers/package_provider.dart';
import '../../../components/spring_card.dart';
import '../../../components/hero_pickup_badge.dart';
import '../../../components/platform_badge.dart';
import '../../../components/status_pill.dart';
import '../../../constants/app_constants.dart';
import '../../../theme/motion.dart';
import 'tracking_timeline_sheet.dart';

class ModernPackageCard extends ConsumerWidget {
  final Package package;

  const ModernPackageCard({
    super.key,
    required this.package,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isArrived = package.status.isArrived;
    final isDelivering = package.status == PackageStatus.delivering;

    return SpringCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      borderRadius: AppRadius.mdAll,
      border: Border.all(
        color: isArrived
            ? AppColors.primary.withValues(alpha: 0.22)
            : AppColors.textPrimary.withValues(alpha: 0.06),
        width: isArrived ? 1.2 : 0.8,
      ),
      onTap: () => TrackingTimelineSheet.show(context, package),
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _showCardActions(context, ref);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶栏：平台来源 + 快递公司 + 状态标签
          Row(
            children: [
              PlatformBadge(platform: package.platform),
              const SizedBox(width: AppSpacing.sm),
              Text(
                package.effectiveCourier.displayName,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              StatusPill(status: package.status),
            ],
          ),

          const SizedBox(height: AppSpacing.md),

          // 主体：商品缩略图 + 标题 + 驿站信息
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProductImage(url: package.goodsImageUrl),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _displayTitle(package),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(
                          Icons.location_on_outlined,
                          size: 14,
                          color: AppColors.textTertiary,
                        ),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            package.displayLocation,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          // 最新物流轨迹（来自订单详情页的真实动态）
          if (!isArrived && _hasUsableDescription(package))
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.local_shipping_outlined,
                    size: 14,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      package.description,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 14),

          // 底栏：取件码核心展现 / 派送提示 + 确认取件动作
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 10,
            ),
            decoration: BoxDecoration(
              color: isArrived ? AppColors.primaryContainer : AppColors.surfaceSunken,
              borderRadius: AppRadius.smAll,
            ),
            child: Row(
              children: [
                // 左侧：取件码 / 派送提示 / 运单号（用 Wrap 避免长取件码溢出）
                Expanded(
                  child: isArrived && package.pickupCode.isNotEmpty
                      ? Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: AppSpacing.sm,
                          runSpacing: 6,
                          children: [
                            const Text(
                              '取件码',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.primaryStrong,
                              ),
                            ),
                            HeroPickupBadge(pickupCode: package.pickupCode),
                          ],
                        )
                      : isDelivering
                          ? const Row(
                              children: [
                                Icon(
                                  Icons.delivery_dining_rounded,
                                  size: 18,
                                  color: AppColors.statusDelivering,
                                ),
                                SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    '快件派送中',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.statusDelivering,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              _displayTracking(package),
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textTertiary,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                ),

                const SizedBox(width: AppSpacing.sm),

                // 右侧：标记已取 / 查看轨迹
                if (isArrived)
                  _PickupConfirmButton(
                    onConfirmed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已完成「${package.goodsName ?? "包裹"}」取件'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                      ref.read(packageListProvider.notifier).markPickedUp(package.id);
                    },
                  )
                else
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '查看轨迹',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: AppColors.textTertiary,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 长按菜单：复制运单号 / 删除包裹。
  void _showCardActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制运单号'),
              subtitle: Text(package.trackingNumber),
              onTap: () {
                Clipboard.setData(ClipboardData(text: package.trackingNumber));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('已复制运单号: ${package.trackingNumber}'),
                  ),
                );
              },
            ),
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
                ref.read(packageListProvider.notifier).removePackage(package.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  static bool _hasUsableDescription(Package p) =>
      p.description.isNotEmpty &&
      p.description != '快件包裹' &&
      p.description != 'OCR';

  static String _displayTitle(Package p) {
    final name = p.goodsName;
    if (name != null && name.isNotEmpty && name != 'OCR') return name;
    if (p.description.isNotEmpty && p.description != 'OCR') return p.description;
    return '快件包裹';
  }

  static String _displayTracking(Package p) {
    final no = p.trackingNumber.trim();
    if (p.status == PackageStatus.pendingShipment) {
      if (no.isEmpty) return '等待商家发货';
      return '订单号：$no';
    }
    // 排除前端生成的12位哈希，友好展示
    if (RegExp(r'^[0-9a-f]{12}$').hasMatch(no) || no.isEmpty) {
      return '${p.effectiveCourier.displayName} · 运输中';
    }
    return '运单号：$no';
  }
}

/// 商品缩略图，带协议补全与占位兜底。
class _ProductImage extends StatelessWidget {
  final String? url;

  const _ProductImage({required this.url});

  @override
  Widget build(BuildContext context) {
    final raw = url;
    if (raw == null || raw.isEmpty) return const _Placeholder();

    // 兜底历史数据：淘宝曾存过 //img.alicdn.com/... 这类缺协议 scheme 的 URL，
    // 直接请求必然失败。
    final normalized = raw.startsWith('//') ? 'https:$raw' : raw;
    return ClipRRect(
      borderRadius: AppRadius.smAll,
      child: Image.network(
        normalized,
        width: 54,
        height: 54,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const _Placeholder(),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: AppRadius.smAll,
      ),
      child: const Icon(
        Icons.inventory_2_outlined,
        color: AppColors.textTertiary,
        size: 26,
      ),
    );
  }
}

/// 「确认取件」按钮：点按后在原位上做一次绿色脉冲 + 放大回弹，
/// 动画播完才真正标记已取，让卡片消失前先给出明确反馈。
class _PickupConfirmButton extends StatefulWidget {
  final VoidCallback onConfirmed;

  const _PickupConfirmButton({required this.onConfirmed});

  @override
  State<_PickupConfirmButton> createState() => _PickupConfirmButtonState();
}

class _PickupConfirmButtonState extends State<_PickupConfirmButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: Motion.emphasized);
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.08)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.08, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 70,
      ),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (_controller.isAnimating) return;
    HapticFeedback.mediumImpact();

    // 移除动画时跳过脉冲，直接确认 —— 反馈仍有（触觉 + 列表退场）。
    if (!Motion.reduce(context)) {
      await _controller.forward(from: 0);
      if (!mounted) return;
      _controller.value = 0; // 复位，避免交回上层时残留高亮
    }
    widget.onConfirmed();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // 底色由浅绿加深为实心绿，文字同步反白
        final t = Curves.easeOut.transform(_controller.value);
        final tint = Color.lerp(
          AppColors.statusPickedUp.withValues(alpha: 0.12),
          AppColors.statusPickedUp,
          t,
        );
        final onTint = Color.lerp(AppColors.statusPickedUp, Colors.white, t);

        return Transform.scale(
          scale: _scale.value,
          child: InkWell(
            onTap: _handleTap,
            borderRadius: AppRadius.xsAll,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: tint,
                borderRadius: AppRadius.xsAll,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_rounded, size: 14, color: onTint),
                  const SizedBox(width: 3),
                  Text(
                    '确认取件',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: onTint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
