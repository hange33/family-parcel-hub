/// 设置与多平台账号管理界面
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/models/platform_ids.dart';
import '../../../platform/storage/platform_auth_store.dart';
import '../../../platform/connectors/connector_manager.dart';
import '../../../platform/connectors/hub_diag.dart';
import '../../components/platform_meta.dart';
import '../../providers/package_provider.dart';
import '../login/platform_login_screen.dart';
import 'background_sync_test_screen.dart';
import 'diagnostics_screen.dart';
import 'keep_alive_status_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _authStore = PlatformAuthStore();

  @override
  Widget build(BuildContext context) {
    // 监听同步状态：后台同步结束（如检测到登录失效）后立即刷新卡片标签
    ref.watch(syncStateProvider);
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text(
          '设置与平台绑定',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1C1C1E),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        children: [
          // ── Section 1: 平台账号绑定 ────────────────────────
          _buildSectionHeader('电商平台账号绑定', '绑定后下拉即可聚合多端在途包裹与取件码'),
          const SizedBox(height: 10),
          // 平台清单与名称/图标/品牌色的唯一来源：core/models/platform_ids.dart
          // 与 ui/components/platform_meta.dart，不再逐平台复制一份
          for (final platform in kPlatformIds) ...[
            if (platform != kPlatformIds.first) const SizedBox(height: 12),
            _buildPlatformCard(platform),
          ],

          const SizedBox(height: 28),

          // ── Section 3: 数据与调试 ─────────────────────────
          _buildSectionHeader('数据管理', '本地缓存与数据同步控制'),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.sync_rounded, color: Color(0xFF007AFF)),
                  title: const Text('从已绑平台同步', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('立即检查并聚合在途订单', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 20, color: Colors.grey),
                  onTap: () async {
                    HapticFeedback.lightImpact();
                    Navigator.pop(context);
                    await ref.read(connectorManagerProvider).syncAll();
                    if (context.mounted) {
                      final issue = ref.read(connectorManagerProvider).lastIssue;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(issue ?? '已同步最新物流状态'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.refresh_rounded, color: Color(0xFFFF9500)),
                  title: const Text('强制重拉订单详情', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('忽略 24 小时同步跳过，重新拉取全部订单', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 20, color: Colors.grey),
                  onTap: () async {
                    HapticFeedback.lightImpact();
                    final manager = ref.read(connectorManagerProvider);
                    // 先取 messenger 再 pop：回到首页才能立刻看到重拉后的卡片，
                    // 而 pop 之后 context 已失效，用它弹提示会静默失败
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.pop(context);
                    final count = await manager.syncAll(force: true);
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(manager.lastIssue ?? '已强制重拉订单详情（$count 条）'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore_rounded, color: Color(0xFF34C759)),
                  title: const Text('恢复已删除的包裹', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('清空删除记录并重新同步，被删的包裹会回来', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 20, color: Colors.grey),
                  onTap: () async {
                    HapticFeedback.mediumImpact();
                    final store = PlatformAuthStore();
                    final removed = store.getBlacklist().length;
                    final manager = ref.read(connectorManagerProvider);
                    // 先取 messenger / navigator 再 pop：和强制重拉一样，回首页才能看到回来的卡片；
                    // 弹窗关闭后 context 已跨过 await 间隙，不能再拿来导航
                    final messenger = ScaffoldMessenger.of(context);
                    final navigator = Navigator.of(context);

                    if (removed == 0) {
                      messenger.showSnackBar(const SnackBar(
                        content: Text('没有已删除的包裹记录'),
                        behavior: SnackBarBehavior.floating,
                      ));
                      return;
                    }

                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('确认恢复已删除的包裹？'),
                        content: Text('将清空 $removed 条删除记录并重新同步。'
                            '当初故意删掉的脏数据（外卖闪送单、广告污染包裹）也会一并回来，需要再手动删一次。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF34C759)),
                            child: const Text('确认恢复'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true) return;

                    store.clearBlacklist();
                    navigator.pop();
                    final count = await manager.syncAll();
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(manager.lastIssue ?? '已清空删除记录并重新同步（处理 $count 条）'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.favorite_rounded, color: Color(0xFF4CAF50)),
                  title: const Text('平台保活状态', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('查看登录态健康度与保活记录', style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 20, color: Colors.grey),
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const KeepAliveStatusScreen()),
                    );
                  },
                ),
                const Divider(height: 1, indent: 56),
                // 后台同步测试工具只在 debug 包出现，release 包（如 1.0 正式版）不含此入口
                if (kDebugMode) ...[
                  ListTile(
                    leading: const Icon(Icons.bug_report_rounded, color: Color(0xFFFF9500)),
                    title: const Text('后台同步测试工具', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                    subtitle: const Text('测试后台同步与到件通知功能', style: TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 20, color: Colors.grey),
                    onTap: () {
                      HapticFeedback.lightImpact();
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const BackgroundSyncTestScreen()),
                      );
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                ],
                ListTile(
                  leading: const Icon(Icons.cleaning_services_rounded, color: Colors.redAccent),
                  title: const Text('清空所有包裹数据', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.redAccent)),
                  subtitle: const Text('清理本地数据库中的所有包裹', style: TextStyle(fontSize: 12)),
                  onTap: () async {
                    HapticFeedback.mediumImpact();
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('确认清空所有数据？'),
                        content: const Text('此操作将删除所有本地存储的待取与历史包裹，平台绑定关系将保留。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            style: FilledButton.styleFrom(backgroundColor: Colors.red),
                            child: const Text('确认清空'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      ref.read(packageListProvider.notifier).clearAll();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空所有包裹数据')));
                      }
                    }
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // ── Section 4: 诊断（family-hub 新增）───────────────
          _buildSectionHeader('诊断', '抓不到数据时，先复制这里的内容发出来'),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.bug_report_rounded, color: Color(0xFF007AFF)),
                  title: const Text('复制诊断信息',
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('含绑定状态、Cookie 名、抓取到的页面原文',
                      style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                  onTap: () async {
                    HapticFeedback.lightImpact();
                    final lastIssue = ref.read(connectorManagerProvider).lastIssue;
                    final text = await HubDiag.build(lastIssue: lastIssue);
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!context.mounted) return;
                    showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('诊断信息已复制'),
                        content: SizedBox(
                          width: double.maxFinite,
                          height: 320,
                          child: SingleChildScrollView(
                            child: SelectableText(
                              text,
                              style: const TextStyle(fontSize: 11, height: 1.35),
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.science_rounded, color: Colors.orange),
                  title: const Text('拼多多会话诊断（进阶）',
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  subtitle: const Text('三步实验：判断登录/访问哪一步会踢官方 App',
                      style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF1C1C1E)),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildPlatformCard(String platform) {
    final displayName = platformDisplayName(platform);
    final subtitle = platformSubtitle(platform);
    final icon = platformIcon(platform);
    final brandColor = platformBrandColor(platform);
    final isBound = _authStore.isBound(platform);
    final liveIssue = ref.watch(connectorManagerProvider).lastIssue ?? '';
    final isExpired = isBound &&
        (_authStore.isExpired(platform) || liveIssue.contains(_issueKeyword(platform)));
    final boundTime = _authStore.getBoundTime(platform);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isExpired
              ? Colors.orange.withValues(alpha: 0.4)
              : (isBound ? brandColor.withValues(alpha: 0.25) : Colors.black.withValues(alpha: 0.05)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: brandColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: brandColor, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      displayName,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isExpired
                            ? Colors.orange.withValues(alpha: 0.15)
                            : (isBound
                                ? const Color(0xFF34C759).withValues(alpha: 0.12)
                                : Colors.grey.withValues(alpha: 0.12)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isExpired ? '已失效' : (isBound ? '已绑定' : '未绑定'),
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          color: isExpired
                              ? Colors.orange.shade800
                              : (isBound ? const Color(0xFF34C759) : Colors.grey.shade600),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  isExpired
                      ? '登录已失效，请点击重新授权'
                      : (isBound && boundTime != null
                          ? '已于 ${boundTime.month}月${boundTime.day}日 授权绑定'
                          : subtitle),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: isExpired ? Colors.orange.shade800 : Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _buildPlatformAction(
            platform: platform,
            displayName: displayName,
            brandColor: brandColor,
            isBound: isBound,
            isExpired: isExpired,
          ),
        ],
      ),
    );
  }

  /// 卡片右侧操作区：三个平台共用同一套几何样式，只按绑定状态切换文案与菜单项。
  ///
  /// 未绑定 → 「去登录」按钮；已绑定（含登录失效）→ 「管理」下拉菜单。
  Widget _buildPlatformAction({
    required String platform,
    required String displayName,
    required Color brandColor,
    required bool isBound,
    required bool isExpired,
  }) {
    if (!isBound) {
      return _buildActionButton(
        label: '去登录',
        color: brandColor,
        onTap: () => _openLogin(platform: platform, displayName: displayName, brandColor: brandColor),
      );
    }

    final Color? menuColor = isExpired ? Colors.orange.shade800 : null;

    return PopupMenuButton<String>(
      onSelected: (val) => _onPlatformActionSelected(
        val,
        platform: platform,
        displayName: displayName,
        brandColor: brandColor,
      ),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'relogin',
          child: Text(isExpired ? '重新授权' : '重新登录'),
        ),
        const PopupMenuItem(
          value: 'unbind',
          child: Text('解除绑定', style: TextStyle(color: Colors.red)),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: (menuColor ?? Colors.grey).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isExpired ? '重新授权' : '管理',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: menuColor),
            ),
            Icon(Icons.arrow_drop_down_rounded, size: 16, color: menuColor),
          ],
        ),
      ),
    );
  }

  /// 未绑定态的登录/授权入口，与「管理」下拉保持一致的尺寸与圆角。
  Widget _buildActionButton({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return FilledButton.tonal(
      onPressed: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      style: FilledButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.12),
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }

  /// 「管理」菜单的统一处理：重新授权 / 重新登录、解除绑定。
  Future<void> _onPlatformActionSelected(
    String val, {
    required String platform,
    required String displayName,
    required Color brandColor,
  }) async {
    if (val == 'relogin') {
      await _openLogin(platform: platform, displayName: displayName, brandColor: brandColor);
    } else if (val == 'unbind') {
      await _authStore.unbind(platform);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已解除 $displayName 绑定')),
        );
      }
    }
  }

  /// 登录态失效提示在同步问题上对应的平台关键词
  String _issueKeyword(String platform) {
    switch (platform.toLowerCase()) {
      case 'taobao':
      case 'tmall':
        return '淘宝';
      case 'jd':
        return '京东';
      case 'pdd':
        return '拼多多';
      default:
        return platform;
    }
  }

  /// 平台登录入口：拼多多内置移动网页端直接打开，其他平台使用专属登录
  Future<void> _openLogin({
    required String platform,
    required String displayName,
    required Color brandColor,
  }) async {
    // family-hub: 拼多多不再走 PddWebScreen。
    // 那个是「内置商城」容器：安卓手机 UA + mobile.yangkeduo.com，属于 App 同款会话，
    // 一登录就把官方 App 顶下线。改走 PlatformLoginScreen：
    // 桌面 UA + 包裹助手页（mobile.pinduoduo.com），扫码登录与手机 App 相互独立。
    if (!mounted) return;
    final ok = await PlatformLoginScreen.show(
      context,
      platform: platform,
      displayName: displayName,
      brandColor: brandColor,
    );
    if (ok == true && mounted) {
      setState(() {});
      // 授权成功后清理旧失效提示并立即同步：刷新状态并补齐取件码
      final manager = ref.read(connectorManagerProvider);
      manager.clearLastIssue();
      manager.syncAll();
    }
  }
}
