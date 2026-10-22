/// 保活状态控制器（Riverpod）
///
/// 把保活状态提升为可观察的 [KeepAliveSnapshot]，取代原先「provider body 里直接
/// `service.start()`」的写法：那种写法任何一次 read 都会触发启动，且状态无法被 watch。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/keep_alive_state.dart';
import '../connectors/connector_manager.dart';
import '../connectors/pdd_connector.dart';
import '../storage/keep_alive_store.dart';
import '../storage/platform_auth_store.dart';
import '../sync/sync_history_manager.dart';
import 'keep_alive_service.dart';
import 'pdd_connector_heartbeat.dart';
import 'platform_heartbeat.dart';

class KeepAliveController extends Notifier<KeepAliveSnapshot> {
  late final KeepAliveService _service;
  bool _disposed = false;

  @override
  KeepAliveSnapshot build() {
    final store = KeepAliveStore();

    ref.onDispose(() {
      _disposed = true;
      _service.dispose();
    });

    _service = KeepAliveService(
      authStore: ref.read(platformAuthStoreProvider),
      store: store,
      heartbeats: _buildHeartbeats(ref),
      lastSyncTimeResolver: (platform) =>
          SyncHistoryManager().getPlatformLastSync(platform),
      onChanged: _pushSnapshot,
    );

    return _service.snapshot();
  }

  /// 拼多多心跳复用连接器已持有的常驻 WebView
  ///
  /// 后台 isolate 不持有本对象，因此不会（也无法）在后台尝试 PDD 心跳。
  Map<String, PlatformHeartbeat> _buildHeartbeats(Ref ref) {
    final heartbeats = <String, PlatformHeartbeat>{
      'taobao': TaobaoHeartbeat(),
      'jd': JdHeartbeat(),
    };

    final pdd = ref
        .read(connectorManagerProvider)
        .realConnectors
        .whereType<PddH5Connector>()
        .firstOrNull;
    if (pdd != null) {
      heartbeats['pdd'] = PddConnectorHeartbeat(pdd);
    }
    return heartbeats;
  }

  void _pushSnapshot() {
    if (_disposed) return;
    state = _service.snapshot();
  }

  /// 启动前台保活（由首页首帧触发；进程外续期由 WorkManager 承担）
  Future<void> start() async {
    await _service.start();
    _pushSnapshot();
  }

  Future<void> setEnabled(bool enabled) async {
    await _service.setEnabled(enabled);
    _pushSnapshot();
  }

  Future<void> setPlatformEnabled(String platform, bool enabled) async {
    await _service.setPlatformEnabled(platform, enabled);
    _pushSnapshot();
  }

  /// 手动保活：绕过闸门与冷却，立即真实执行一轮
  Future<void> manualKeepAlive() async {
    await _service.performManualKeepAlive();
    _pushSnapshot();
  }

  /// 重新读取持久化状态并刷新界面
  Future<void> refresh() async {
    await _service.refreshFromStore();
    _pushSnapshot();
  }
}

final keepAliveControllerProvider =
    NotifierProvider<KeepAliveController, KeepAliveSnapshot>(
  KeepAliveController.new,
);
