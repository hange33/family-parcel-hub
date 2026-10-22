/// 拼多多心跳：委托给 [PddH5Connector] 已持有的常驻 WebView
///
/// 为什么不自己建 WebView：webview_flutter 的 `WebViewController` 没有 `dispose()`，
/// 原生 WebView 只在 `WebViewWidget` 销毁时释放。心跳若自行新建控制器却从不构建 widget，
/// 每次调用都会泄漏一个原生 WebView。复用连接器的控制器则随其宿主页面生命周期回收。
///
/// 代价是 PDD 心跳只能在前台进行：后台 isolate 不持有连接器，
/// 且拼多多 proxy 接口要求 `anti_content` 动态签名，纯 HTTP 会被风控（424）。
library;

import '../connectors/pdd_connector.dart';
import 'platform_heartbeat.dart';

class PddConnectorHeartbeat implements PlatformHeartbeat {
  final PddH5Connector _connector;

  PddConnectorHeartbeat(this._connector);

  @override
  String get platformId => 'pdd';

  @override
  Future<HeartbeatResult> performHeartbeat(String cookies) async {
    final probe = await _connector.keepAliveProbe();

    // 无法判定（正忙 / 网络异常）不等于登录失效，按「跳过」处理
    if (probe == null) {
      return HeartbeatResult.skipped('拼多多 WebView 当前不可探活');
    }
    if (!probe.healthy) {
      return HeartbeatResult.failure('登录态已失效', isAuthFailure: true);
    }
    return HeartbeatResult.success();
  }
}
