/// 平台连接器接口抽象 - 桥接各电商平台与包裹聚合引擎
library;

import '../../core/models/package.dart';

enum ConnectorStatus {
  idle,
  syncing,
  challenging, // 遇到验证码
  success,
  failed,
}

abstract class PlatformConnector {
  String get platformId;
  String get displayName;
  String get brandColorHex;

  /// 检查当前是否拥有有效登录态
  Future<bool> isAuthenticated();

  /// 触发拉取/流式同步包裹
  Stream<Package> streamSync();

  /// 取消当前同步任务
  Future<void> cancelSync();

  /// 最近一次同步中出现的问题（例如登录态失效），无问题时为 null
  String? get lastIssue => null;
}
