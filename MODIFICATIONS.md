# MODIFICATIONS · 相对上游的改动清单

> 上游：https://github.com/Granter-z/parcly（GPL-3.0）
> 本文件逐条记录对 `lib/` 的侵入式改动，便于 `git fetch upstream && git rebase` 时逐条核对。

## 原则

1. **抓取层零改动**：`lib/platform/connectors/*`、`lib/core/parser/*`、`lib/core/engine/*` 一律不动。
2. 改动只发生在「状态变化」与「设置页」两处，且每个改动点加 `// family-hub:` 注释前缀。
3. 新增文件优先新建目录，不散落在既有目录里。

## 改动清单

| 状态 | 文件 | 位置 | 改动 |
|---|---|---|---|
| ✅ 已改 | `lib/platform/connectors/pdd_web_connector.dart` | 新增 | 拼多多改走网页端包裹助手（隐藏 WebView + 文本解析） |
| ✅ 已改 | `lib/platform/connectors/connector_manager.dart` | L32-55 | 注册 `PddWebConnector`，不再注册 `PddH5Connector`（会与官方 App 互踢） |
| ✅ 已改 | `lib/ui/screens/login/platform_login_screen.dart` | `_initialUrl` / `_loginUserAgent` / `onPageFinished` | 拼多多登录页改为包裹助手页；按平台切 UA（pdd 用桌面 UA）；pdd 强制桌面视口；pdd 增 Cookie 兜底判定 |
| ✅ 已改 | `lib/ui/screens/home/home_screen.dart` | 首页 Sliver 列表 | **移除「拼多多内置商城」入口**（旧路线：移动会话，必与官方 App 互踢） |
| ✅ 已改 | `lib/ui/screens/settings/settings_screen.dart` | 绑定流程 | 删除 pdd 特判（原本走 `PddWebScreen`），统一走通用登录页 |
| ✅ 已改 | `android/keystore/` + `android/app/build.gradle.kts` | 签名配置 | 固定 PKCS12 签名，CI 出包可覆盖安装（不再丢登录态） |
| ✅ 已改 | `lib/platform/connectors/pdd_parse_diag.dart` | 新增 | 抓取诊断缓存（各候选页原文 / Cookie 名 / 丢弃样本） |
| 待做 | `lib/platform/report/hub_client.dart` | 新增 | HTTP 上报客户端（token、超时、吞异常） |
| 待做 | `lib/platform/report/report_queue.dart` | 新增 | 本地队列 + 幂等 + 断网重试 |
| 待做 | `lib/ui/providers/package_provider.dart` | `_triggerArrivedNotification()` | 埋点：新到件上报 |
| 待做 | `lib/ui/providers/package_provider.dart` | `markPickedUp()` | 埋点：手动确认取件上报（`manual_pick: true`） |
| 待做 | `lib/ui/screens/settings/settings_screen.dart` | 新增「家庭聚合」分组 | 地址 / Token / 身份 / 测试连接 |
| 待做 | `lib/platform/sync/background_sync_service.dart` | 同步结束后 | flush 队列 |
| 待做 | `android/app/src/main/AndroidManifest.xml` | L10 | `usesCleartextTraffic` 改 `false` |

## 已知约束（改代码时必须遵守）

- **拼多多在 parcly 里必须保持未绑定**：它也是 H5 会话，与网页端抓取互顶。
  设置页需要对「绑定拼多多」给出明确警告。
- 上报失败**绝不阻塞**同步主流程，异常一律吞掉并记本地日志。
- 取件码属于隐私：日志里只记前缀与计数，不打印完整值（沿用上游 `packageIdForLog` 的做法）。
