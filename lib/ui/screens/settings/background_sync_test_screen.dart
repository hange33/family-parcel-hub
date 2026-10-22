/// 后台同步与通知测试工具
///
/// 用途：在开发环境下测试后台同步与到件通知功能
/// 使用方法：在设置页添加隐藏的「开发者测试」入口
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/models/package.dart';
import '../../../core/models/package_status.dart';
import '../../../platform/notification/notification_adapter.dart';
import '../../providers/package_provider.dart';

class BackgroundSyncTestScreen extends ConsumerStatefulWidget {
  const BackgroundSyncTestScreen({super.key});

  @override
  ConsumerState<BackgroundSyncTestScreen> createState() => _BackgroundSyncTestScreenState();
}

class _BackgroundSyncTestScreenState extends ConsumerState<BackgroundSyncTestScreen> {
  String _log = '';

  void _addLog(String message) {
    setState(() {
      final timestamp = DateTime.now().toString().substring(11, 19);
      _log = '[$timestamp] $message\n$_log';
    });
    debugPrint('[BackgroundSyncTest] $message');
  }

  /// 测试 1: 创建模拟包裹（在途状态）
  void _testCreateTransitPackage() {
    final package = Package(
      id: 'TEST_${DateTime.now().millisecondsSinceEpoch}',
      trackingNumber: 'YT${DateTime.now().millisecondsSinceEpoch % 10000000000000}',
      courier: CourierType.yt,
      urgency: UrgencyLevel.normal,
      status: PackageStatus.transit,
      addedAt: DateTime.now(),
      platform: 'test',
      goodsName: '测试商品（在途中）',
      rawTimelineJson: '[{"tag":"运输中","time":"${DateTime.now().toString().substring(0, 19)}","text":"快件已到达测试转运中心"}]',
    );

    ref.read(packageListProvider.notifier).addPackage(package);
    _addLog('✅ 创建在途测试包裹: ${package.trackingNumber}');
  }

  /// 测试 2: 模拟包裹到达（触发通知）
  void _testSimulateArrival() {
    final packages = ref.read(packageListProvider);
    final transitPackages = packages.where((p) =>
      p.status == PackageStatus.transit &&
      p.platform == 'test'
    ).toList();

    if (transitPackages.isEmpty) {
      _addLog('❌ 没有在途测试包裹，请先创建');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先创建在途测试包裹')),
      );
      return;
    }

    final package = transitPackages.first;
    final arrivedPackage = package.copyWith(
      status: PackageStatus.arrived,
      pickupCode: '${DateTime.now().millisecondsSinceEpoch % 10000}',
      stationName: '测试驿站',
      urgency: UrgencyLevel.urgent,
      rawTimelineJson: '[{"tag":"已到达","time":"${DateTime.now().toString().substring(0, 19)}","text":"快件已到达测试驿站，请凭取件码领取"}]',
    );

    ref.read(packageListProvider.notifier).addPackage(arrivedPackage);
    _addLog('✅ 模拟包裹到达: 取件码 ${arrivedPackage.pickupCode}');
    _addLog('📱 应该收到通知: 「快递到了！」');
  }

  /// 测试 3: 创建派送中包裹（触发 15 分钟高频同步）
  void _testCreateDeliveringPackage() {
    final package = Package(
      id: 'TEST_DELIVERING_${DateTime.now().millisecondsSinceEpoch}',
      trackingNumber: 'SF${DateTime.now().millisecondsSinceEpoch % 10000000000000}',
      courier: CourierType.sf,
      urgency: UrgencyLevel.urgent,
      status: PackageStatus.delivering,
      addedAt: DateTime.now(),
      platform: 'test',
      goodsName: '测试商品（派送中）',
      rawTimelineJson: '[{"tag":"派送中","time":"${DateTime.now().toString().substring(0, 19)}","text":"快递小哥正在派送中，请保持手机畅通"}]',
    );

    ref.read(packageListProvider.notifier).addPackage(package);
    _addLog('✅ 创建派送中测试包裹');
    _addLog('⏱️ 后台同步间隔应为 15 分钟');
  }

  /// 测试 4: 直接测试通知（不走包裹系统）
  Future<void> _testNotificationOnly() async {
    final testPackage = Package(
      id: 'NOTIFICATION_TEST',
      trackingNumber: 'TEST123456',
      courier: CourierType.yt,
      pickupCode: '9999',
      urgency: UrgencyLevel.urgent,
      status: PackageStatus.arrived,
      addedAt: DateTime.now(),
      platform: 'test',
      stationName: '测试驿站',
    );

    try {
      await NotificationAdapter().showArrivedNotification(testPackage);
      _addLog('✅ 发送测试通知成功');
      _addLog('📱 请检查通知栏');
    } catch (e) {
      _addLog('❌ 发送通知失败: $e');
    }
  }

  /// 测试 5: 清理所有测试包裹
  void _testCleanup() {
    final packages = ref.read(packageListProvider);
    final testPackages = packages.where((p) => p.platform == 'test' || p.id.startsWith('TEST_')).toList();

    for (final package in testPackages) {
      ref.read(packageListProvider.notifier).removePackage(package.id);
    }

    _addLog('✅ 清理了 ${testPackages.length} 个测试包裹');
  }

  /// 测试 6: 查看当前包裹状态统计
  void _testShowStats() {
    final packages = ref.read(packageListProvider);
    final delivering = packages.where((p) => p.status == PackageStatus.delivering).length;
    final arrived = packages.where((p) => p.status == PackageStatus.arrived).length;
    final transit = packages.where((p) => p.status == PackageStatus.transit).length;
    final testCount = packages.where((p) => p.platform == 'test' || p.id.startsWith('TEST_')).length;

    _addLog('📊 当前包裹统计:');
    _addLog('  派送中: $delivering 个');
    _addLog('  待取件: $arrived 个');
    _addLog('  在途中: $transit 个');
    _addLog('  测试包裹: $testCount 个');

    if (delivering > 0) {
      _addLog('⏱️ 预期同步间隔: 15 分钟');
    } else if (arrived > 0) {
      _addLog('⏱️ 预期同步间隔: 30-45 分钟');
    } else if (transit > 0) {
      _addLog('⏱️ 预期同步间隔: 1 小时');
    } else {
      _addLog('⏱️ 预期同步间隔: 暂停');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('后台同步测试工具'),
        backgroundColor: const Color(0xFF007AFF),
      ),
      body: Column(
        children: [
          // 测试按钮区域
          Expanded(
            flex: 2,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '后台同步测试',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  '测试步骤：\n'
                  '1. 创建在途测试包裹\n'
                  '2. 模拟包裹到达（触发通知）\n'
                  '3. 按 Home 键进入后台观察日志\n'
                  '4. 等待通知出现',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 16),

                _buildTestButton(
                  icon: Icons.add_box,
                  label: '1. 创建在途包裹',
                  color: Colors.blue,
                  onPressed: _testCreateTransitPackage,
                ),
                const SizedBox(height: 8),

                _buildTestButton(
                  icon: Icons.notifications_active,
                  label: '2. 模拟包裹到达（触发通知）',
                  color: Colors.green,
                  onPressed: _testSimulateArrival,
                ),
                const SizedBox(height: 8),

                _buildTestButton(
                  icon: Icons.local_shipping,
                  label: '3. 创建派送中包裹（15分钟高频）',
                  color: Colors.orange,
                  onPressed: _testCreateDeliveringPackage,
                ),
                const SizedBox(height: 8),

                _buildTestButton(
                  icon: Icons.notification_important,
                  label: '4. 直接测试通知',
                  color: Colors.purple,
                  onPressed: _testNotificationOnly,
                ),
                const SizedBox(height: 8),

                _buildTestButton(
                  icon: Icons.info,
                  label: '5. 查看包裹统计',
                  color: Colors.teal,
                  onPressed: _testShowStats,
                ),
                const SizedBox(height: 8),

                _buildTestButton(
                  icon: Icons.delete_sweep,
                  label: '6. 清理测试包裹',
                  color: Colors.red,
                  onPressed: _testCleanup,
                ),
              ],
            ),
          ),

          // 日志区域
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.black87,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '测试日志',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _log = ''),
                        child: const Text(
                          '清空',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24),
                  Expanded(
                    child: SingleChildScrollView(
                      reverse: true,
                      child: SelectableText(
                        _log.isEmpty ? '等待测试操作...' : _log,
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTestButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton.icon(
      icon: Icon(icon),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 16),
        alignment: Alignment.centerLeft,
      ),
      onPressed: onPressed,
    );
  }
}
