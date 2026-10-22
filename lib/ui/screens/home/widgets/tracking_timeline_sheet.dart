/// 深度映射电商官方风格的物流轨迹抽屉
///
/// 视觉与交互复刻：
/// 1. 顶部承运商与运单号条：品牌名称 + 运单号 + 一键复制
/// 2. 订单与收货信息卡片：订单编号 + 一键复制 + 收货地址（支持折叠展开）
/// 3. 商品与取件凭证栏：商品图文预览，待取件时呈现 Hero 提货码徽章
/// 4. 真实物流时间轴（P12：三平台共用 [TrackingTimeline] 组件）：
///    - 数据经 timelineForDisplay 容错解析、去重、按时间倒序
///    - 最新节点绿色高亮，历史节点灰点串联
///    - 电话号码可点击拨打，取件码加粗
///    - 没有轨迹时如实显示空状态，不再编造节点
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/engine/timeline_view.dart';
import '../../../../core/models/package.dart';
import '../../../../core/models/package_status.dart';
import '../../../components/hero_pickup_badge.dart';
import '../../../components/platform_badge.dart';
import '../../../components/tracking_timeline.dart';

class TrackingTimelineSheet extends StatefulWidget {
  final Package package;

  const TrackingTimelineSheet({super.key, required this.package});

  static void show(BuildContext context, Package package) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TrackingTimelineSheet(package: package),
    );
  }

  @override
  State<TrackingTimelineSheet> createState() => _TrackingTimelineSheetState();
}

class _TrackingTimelineSheetState extends State<TrackingTimelineSheet> {
  bool _isAddressExpanded = false;

  /// 整理好的时间轴节点（最新在前），只在包裹变化时重新计算。
  late List<TimelineNode> _timeline;

  /// 从最新节点里提取的驿站/派送员电话，没有则为 null。
  String? _stationPhone;

  @override
  void initState() {
    super.initState();
    _prepareTimeline();
  }

  @override
  void didUpdateWidget(covariant TrackingTimelineSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.package.rawTimelineJson != widget.package.rawTimelineJson ||
        oldWidget.package.pickupCode != widget.package.pickupCode) {
      _prepareTimeline();
    }
  }

  void _prepareTimeline() {
    final pkg = widget.package;
    _timeline = timelineForDisplay(pkg.rawTimelineJson);
    _stationPhone = extractStationPhone(
      nodes: _timeline,
      pickupCode: pkg.pickupCode,
    );
  }

  void _copyToClipboard(String text, String label) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label 已复制到剪贴板'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 取件凭证栏的站点文案：优先用简洁的驿站名，避免整段收货地址把取件码挤出屏幕
  String _credentialLocation(Package pkg) {
    final station = pkg.stationName?.trim() ?? '';
    if (station.isNotEmpty && station != '未知驿站') return station;
    final original = pkg.originalStation.trim();
    if (original.isNotEmpty) return original;
    return pkg.displayLocation;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pkg = widget.package;
    final courierName = pkg.effectiveCourier.displayName;
    final trackingNo = pkg.trackingNumber;
    final orderSn = pkg.displayOrderSn;
    final address = pkg.location.trim();
    final stationPhone = _stationPhone;

    return DraggableScrollableSheet(
      // expand 必须为 false：否则控件会撑满整屏，模态遮罩高度被压成 0，
      // 点击抽屉上方留白就无法收回抽屉。
      expand: false,
      initialChildSize: 0.82,
      minChildSize: 0.50,
      maxChildSize: 0.96,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            children: [
              // 顶部拖拽把手
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 12),
                  width: 38,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),

              // 滚动内容主体
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
                  children: [
                    // ── 模块 1：快递承运商与运单号（仿拼多多顶条） ──
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F8FA),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: const Color(0xFF00B578).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: const Icon(
                              Icons.local_shipping_rounded,
                              size: 16,
                              color: Color(0xFF00B578),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: RichText(
                              text: TextSpan(
                                children: [
                                  TextSpan(
                                    text: '$courierName: ',
                                    style: const TextStyle(
                                      color: Color(0xFF00B578),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14.5,
                                    ),
                                  ),
                                  TextSpan(
                                    text: trackingNo,
                                    style: const TextStyle(
                                      color: Color(0xFF1C1C1E),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          _buildCopyButton(
                            onTap: () => _copyToClipboard(trackingNo, '运单号'),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 10),

                    // ── 模块 2：订单编号与收货地址卡片 ──
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F8FA),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 订单编号
                          Row(
                            children: [
                              const Icon(
                                Icons.receipt_long_outlined,
                                size: 16,
                                color: Color(0xFF8E8E93),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '订单编号：$orderSn',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF3A3A3C),
                                    fontWeight: FontWeight.w500,
                                    fontFamily: 'monospace',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              _buildCopyButton(
                                onTap: () => _copyToClipboard(orderSn, '订单编号'),
                              ),
                            ],
                          ),

                          // 收货地址
                          if (address.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            const Divider(height: 1, color: Color(0xFFE5E5EA)),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(top: 1.5),
                                  child: Icon(
                                    Icons.location_on_outlined,
                                    size: 16,
                                    color: Color(0xFF8E8E93),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '收货地址：$address',
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      color: Color(0xFF3A3A3C),
                                      height: 1.4,
                                    ),
                                    maxLines: _isAddressExpanded ? 4 : 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (address.length > 18)
                                  InkWell(
                                    onTap: () {
                                      HapticFeedback.lightImpact();
                                      setState(() => _isAddressExpanded = !_isAddressExpanded);
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: Text(
                                        _isAddressExpanded ? '收起 ∧' : '展开 ∨',
                                        style: const TextStyle(
                                          fontSize: 11.5,
                                          color: Color(0xFF8E8E93),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // ── 模块 3：商品快件概要 ──
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.grey.withValues(alpha: 0.15)),
                      ),
                      child: Row(
                        children: [
                          if (pkg.goodsImageUrl != null && pkg.goodsImageUrl!.isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              // 兜底历史数据：旧 URL 可能缺协议 scheme（//img.alicdn.com/...），直接请求必然失败
                              child: Image.network(
                                pkg.goodsImageUrl!.startsWith('//') ? 'https:${pkg.goodsImageUrl!}' : pkg.goodsImageUrl!,
                                width: 50,
                                height: 50,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _buildPlaceholderIcon(),
                              ),
                            )
                          else
                            _buildPlaceholderIcon(),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    PlatformBadge(platform: pkg.platform),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        pkg.goodsName ?? (pkg.description.isNotEmpty ? pkg.description : '包裹快件'),
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF1C1C1E),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  pkg.displayLocation,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF8E8E93),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    // ── 模块 4：取件码突出展示（若已到驿站） ──
                    if (pkg.pickupCode.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF007AFF).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFF007AFF).withValues(alpha: 0.22),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '取件凭证',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFF007AFF),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _credentialLocation(pkg),
                                    style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  // 驿站/派送员电话：从最新轨迹节点里提取，点一下直接拨打
                                  if (stationPhone != null) ...[
                                    const SizedBox(height: 6),
                                    _buildCallButton(stationPhone),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            HeroPickupBadge(
                              pickupCode: pkg.pickupCode,
                              isLarge: true,
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),
                    const Divider(height: 1, color: Color(0xFFE5E5EA)),
                    const SizedBox(height: 16),

                    // ── 模块 5：物流轨迹时间轴（对齐拼多多官方风格） ──
                    const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: Text(
                        '物流跟踪轨迹',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1C1C1E),
                        ),
                      ),
                    ),

                    TrackingTimeline(
                      nodes: _timeline,
                      pickupCode: pkg.pickupCode,
                      statusLabel: pkg.status.label,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCopyButton({required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFD1D1D6)),
        ),
        child: const Text(
          '复制',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFF3A3A3C),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholderIcon() {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.inventory_2_outlined, color: Colors.grey, size: 24),
    );
  }

  /// 取件凭证卡片里的拨号按钮
  Widget _buildCallButton(String phone) {
    return InkWell(
      key: const ValueKey('station_phone_call_button'),
      onTap: () {
        HapticFeedback.lightImpact();
        launchPhoneCall(phone);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: const Color(0xFF007AFF).withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.phone_rounded, size: 14, color: Color(0xFF007AFF)),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '联系电话 $phone',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF007AFF),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
