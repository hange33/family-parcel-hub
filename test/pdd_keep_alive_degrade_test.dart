import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_app/platform/connectors/pdd_connector.dart';
import 'package:pickup_app/platform/keep_alive/pdd_connector_heartbeat.dart';

/// 只覆写探活入口，避免触碰真实 WebView
class _StubPddConnector extends PddH5Connector {
  _StubPddConnector(this.probe);

  final PddKeepAliveProbe? probe;

  @override
  Future<PddKeepAliveProbe?> keepAliveProbe() async => probe;
}

void main() {
  group('拼多多心跳委托给连接器', () {
    test('连接器正忙 / 网络异常 → 跳过，不误判失效', () async {
      final heartbeat = PddConnectorHeartbeat(_StubPddConnector(null));

      final result = await heartbeat.performHeartbeat('k=v');

      expect(result.skipped, isTrue);
      expect(result.success, isFalse);
      expect(result.isAuthFailure, isFalse, reason: '无法探活不等于登录失效');
    });

    test('探活判定失效 → 明确的登录失效', () async {
      final heartbeat = PddConnectorHeartbeat(
        _StubPddConnector(const PddKeepAliveProbe.expired()),
      );

      final result = await heartbeat.performHeartbeat('k=v');

      expect(result.success, isFalse);
      expect(result.isAuthFailure, isTrue);
      expect(result.skipped, isFalse);
    });

    test('探活健康 → 成功', () async {
      final heartbeat = PddConnectorHeartbeat(
        _StubPddConnector(const PddKeepAliveProbe.healthy()),
      );

      final result = await heartbeat.performHeartbeat('k=v');

      expect(result.success, isTrue);
      expect(result.isAuthFailure, isFalse);
      expect(result.skipped, isFalse);
    });

    test('platformId 为 pdd', () {
      expect(PddConnectorHeartbeat(_StubPddConnector(null)).platformId, 'pdd');
    });
  });
}
