/// 平台保活状态展示页面
///
/// 显示各平台的保活开关、Cookie 年龄、健康度与最近保活记录。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/engine/keep_alive_plan.dart';
import '../../../core/models/keep_alive_state.dart';
import '../../../core/models/platform_ids.dart';
import '../../../platform/keep_alive/keep_alive_controller.dart';
import '../../components/platform_meta.dart';

class KeepAliveStatusScreen extends ConsumerStatefulWidget {
  const KeepAliveStatusScreen({super.key});

  @override
  ConsumerState<KeepAliveStatusScreen> createState() => _KeepAliveStatusScreenState();
}

class _KeepAliveStatusScreenState extends ConsumerState<KeepAliveStatusScreen> {
  bool _isRefreshing = false;

  /// 手动触发保活（绕过闸门，立即真实执行一轮）
  Future<void> _performManualKeepAlive() async {
    setState(() => _isRefreshing = true);

    try {
      await ref.read(keepAliveControllerProvider.notifier).manualKeepAlive();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('保活完成'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('保活失败: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    }
  }

  /// 注册一个 3 秒后触发的 one-off 后台任务，验证后台 isolate 续期链路
  Future<void> _testBackgroundWorker() async {
    await Workmanager().registerOneOffTask(
      'keep_alive_test_once',
      'keepAliveTask',
      initialDelay: const Duration(seconds: 3),
      constraints: Constraints(networkType: NetworkType.connected),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已注册后台续期任务，3 秒后执行，日志见 logcat'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _toggleEnabled(bool enabled) async {
    await ref.read(keepAliveControllerProvider.notifier).setEnabled(enabled);
  }

  Future<void> _togglePlatform(String platform, bool enabled) async {
    await ref.read(keepAliveControllerProvider.notifier).setPlatformEnabled(platform, enabled);
  }

  String _formatAgo(Duration? duration) {
    if (duration == null) return '未知';
    if (duration.inDays > 0) return '${duration.inDays} 天前';
    if (duration.inHours > 0) return '${duration.inHours} 小时前';
    if (duration.inMinutes > 0) return '${duration.inMinutes} 分钟前';
    return '刚刚';
  }

  /// 距离某个时刻还有多久（用于「下次保活」）
  String _formatUntil(DateTime? time) {
    if (time == null) return '待安排';
    final remaining = time.difference(DateTime.now());
    if (remaining.isNegative) return '即将执行';
    if (remaining.inHours > 0) return '${remaining.inHours} 小时后';
    if (remaining.inMinutes > 0) return '${remaining.inMinutes} 分钟后';
    return '即将执行';
  }

  Color _parseColor(String hexColor) {
    return Color(int.parse('FF${hexColor.replaceAll('#', '')}', radix: 16));
  }

  /// 健康度颜色：与徽章文案同源，避免「文案写失效、颜色仍显绿」的不一致
  Color _healthColor(PlatformKeepAliveStatus status) {
    if (status.isExpired || status.failureCount >= KeepAlivePlan.failureThreshold) {
      return const Color(0xFFF44336);
    }
    if (status.failureCount >= 1) return const Color(0xFFFF9800);
    return _parseColor(KeepAlivePlan.cookieHealthColorHex(status.cookieAge ?? Duration.zero));
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(keepAliveControllerProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text(
          '平台保活状态',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1C1C1E),
        elevation: 0,
        actions: [
          if (_isRefreshing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _performManualKeepAlive,
              tooltip: '手动保活',
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildInfoBanner(),
          const SizedBox(height: 16),
          _buildMasterSwitch(snapshot.enabled),
          const SizedBox(height: 16),
          ...snapshot.platforms.map(_buildPlatformCard),
          const SizedBox(height: 20),
          _buildHistorySection(snapshot),
          const SizedBox(height: 20),
          _buildSettingsSection(snapshot),
        ],
      ),
    );
  }

  Widget _buildInfoBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF007AFF).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            color: Color(0xFF007AFF),
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '保活机制定期访问平台保持登录态有效，减少重新登录次数',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMasterSwitch(bool enabled) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: SwitchListTile(
        value: enabled,
        onChanged: _toggleEnabled,
        title: const Text('启用自动保活', style: TextStyle(fontSize: 15)),
        subtitle: Text(
          enabled ? '已开启，按 Cookie 年龄自动调整频率' : '已关闭，登录态可能更快失效',
          style: const TextStyle(fontSize: 12),
        ),
        secondary: const Icon(Icons.shield_moon_rounded, color: Color(0xFF007AFF)),
        activeThumbColor: const Color(0xFF007AFF),
      ),
    );
  }

  Widget _buildPlatformCard(PlatformKeepAliveStatus status) {
    final platform = status.platform;
    final brandColor = platformBrandColor(platform);
    final healthColor = _healthColor(status);
    // 未绑定无从保活；总开关关闭时单平台开关无意义
    final canToggle = status.bound;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: brandColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(platformIcon(platform), color: brandColor, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        platformDisplayName(platform),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        status.bound
                            ? (status.isExpired ? '登录态已失效，请重新授权' : '已绑定')
                            : '未绑定',
                        style: TextStyle(
                          fontSize: 13,
                          color: status.isExpired
                              ? const Color(0xFFF44336)
                              : (status.bound ? Colors.green : Colors.grey),
                        ),
                      ),
                    ],
                  ),
                ),
                if (status.bound)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: healthColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      status.health,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: healthColor,
                      ),
                    ),
                  ),
                Switch(
                  value: status.enabled,
                  onChanged: canToggle ? (v) => _togglePlatform(platform, v) : null,
                  activeThumbColor: const Color(0xFF007AFF),
                ),
              ],
            ),
          ),
          if (status.bound) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildInfoRow(
                    icon: Icons.calendar_today_rounded,
                    label: 'Cookie 年龄',
                    value: status.cookieAge != null ? '${status.cookieAge!.inDays} 天' : '未知',
                  ),
                  const SizedBox(height: 12),
                  _buildInfoRow(
                    icon: Icons.access_time_rounded,
                    label: '最近保活',
                    value: status.lastKeepAliveAt != null
                        ? _formatAgo(DateTime.now().difference(status.lastKeepAliveAt!))
                        : '未执行',
                  ),
                  const SizedBox(height: 12),
                  _buildInfoRow(
                    icon: Icons.schedule_rounded,
                    label: '下次保活',
                    value: status.enabled ? _formatUntil(status.nextKeepAliveAt) : '已停用',
                  ),
                  if (status.failureCount > 0) ...[
                    const SizedBox(height: 12),
                    _buildInfoRow(
                      icon: Icons.error_outline_rounded,
                      label: '连续失败',
                      value: '${status.failureCount} 次',
                      valueColor: const Color(0xFFF44336),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey.shade600,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: valueColor ?? const Color(0xFF1C1C1E),
          ),
        ),
      ],
    );
  }

  Widget _buildHistorySection(KeepAliveSnapshot snapshot) {
    final history = KeepAliveHistory(snapshot.history);
    final rate = history.successRate;
    final recent = snapshot.history.take(10).toList();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                const Text(
                  '保活历史',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (rate != null)
                  Text(
                    '成功率 ${(rate * 100).round()}%',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: rate >= 0.8 ? Colors.green : const Color(0xFFFF9800),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (recent.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '暂无保活记录',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            )
          else
            ...recent.map(_buildHistoryRow),
        ],
      ),
    );
  }

  Widget _buildHistoryRow(KeepAliveRecord record) {
    final brandColor = platformBrandColor(record.platform);
    final (icon, color, label) = switch (record) {
      _ when record.skipped => (Icons.remove_rounded, Colors.grey, '已跳过'),
      _ when record.success => (Icons.check_rounded, Colors.green, '成功'),
      _ when record.authFailure => (Icons.error_rounded, const Color(0xFFF44336), '登录失效'),
      _ => (Icons.close_rounded, const Color(0xFFFF9800), '失败'),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(platformIcon(record.platform), size: 18, color: brandColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  platformDisplayName(record.platform),
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                ),
                if (record.error != null && record.error!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      record.error!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatAgo(DateTime.now().difference(record.time)),
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(width: 10),
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsSection(KeepAliveSnapshot snapshot) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '保活设置',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.schedule_rounded, color: Color(0xFF007AFF)),
            title: const Text('保活频率', style: TextStyle(fontSize: 14.5)),
            subtitle: const Text('根据 Cookie 年龄自动调整', style: TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => _showFrequencyDialog(snapshot),
          ),
          ListTile(
            leading: const Icon(Icons.play_circle_outline_rounded, color: Color(0xFF007AFF)),
            title: const Text('测试后台续期任务', style: TextStyle(fontSize: 14.5)),
            subtitle: const Text('注册 3 秒后触发的 one-off 任务，验证后台 isolate 链路',
                style: TextStyle(fontSize: 12)),
            onTap: _testBackgroundWorker,
          ),
        ],
      ),
    );
  }

  void _showFrequencyDialog(KeepAliveSnapshot snapshot) {
    // 展示一个已绑定平台的当前生效间隔，让「智能模式」不是一句空话
    final sample = snapshot.platforms.where((p) => p.bound && p.cookieAge != null).firstOrNull;
    final current = sample != null
        ? '当前生效：${platformDisplayName(sample.platform)} '
            '${KeepAlivePlan.calculateInterval(sample.cookieAge!).inHours} 小时'
        : null;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保活频率'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '当前使用智能模式，根据 Cookie 年龄自动调整：\n\n'
              '• 0-3 天：每 24 小时\n'
              '• 4-7 天：每 12 小时\n'
              '• 8-10 天：每 6 小时\n'
              '• 11+ 天：每 4 小时',
            ),
            if (current != null) ...[
              const SizedBox(height: 12),
              Text(
                current,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF007AFF),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
