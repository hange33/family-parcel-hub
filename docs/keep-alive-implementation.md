# 电商平台保活机制

> 最后更新：2026-10-08
> 状态：前台调度 + 进程外续期 + 失效提醒闭环均已实现

本文描述**当前代码的实际行为**。历史上的旧版本文档曾声称淘宝用 WebView 心跳、京东检查
`retcode`、定时器为 12 小时 —— 这些都与实现不符，已在本轮一并纠正（见文末变更记录）。

---

## 一、组件与职责

| 层 | 文件 | 职责 |
|---|---|---|
| core | `lib/core/engine/keep_alive_plan.dart` | 纯决策：间隔计算、跳过规则、健康度、失效提醒判定。无 Flutter 依赖、时间可注入，可直接单测 |
| core | `lib/core/models/keep_alive_state.dart` | 不可变模型：`KeepAliveRecord` / `KeepAliveHistory` / `PlatformKeepAliveStatus` / `KeepAliveSnapshot` |
| core | `lib/core/models/platform_ids.dart` | 平台标识与显示名的唯一来源（`kPlatformIds`），消除三处硬编码 |
| platform | `lib/platform/storage/keep_alive_store.dart` | 保活调度状态持久化（Hive box `keep_alive_state`） |
| platform | `lib/platform/keep_alive/keep_alive_service.dart` | 前台保活编排：按闸门与冷却决定发不发心跳，落盘结果 |
| platform | `lib/platform/keep_alive/keep_alive_controller.dart` | Riverpod `Notifier`，把状态暴露为可 watch 的 `KeepAliveSnapshot` |
| platform | `lib/platform/keep_alive/platform_heartbeat.dart` | 心跳接口 + 淘宝/京东实现 |
| platform | `lib/platform/keep_alive/taobao_token_refresher.dart` | 淘宝 mtop `getTimeStamp` 签名请求与令牌轮换 |
| platform | `lib/platform/keep_alive/pdd_connector_heartbeat.dart` | 拼多多心跳，委托给 `PddH5Connector` |
| platform | `lib/platform/keep_alive/keep_alive_notifier.dart` | 失效提醒收口：去重标记 + 发送 |
| platform | `lib/platform/keep_alive/keep_alive_worker.dart` | WorkManager 后台 isolate：App 进程被杀后仍能续期 |
| ui | `lib/ui/screens/settings/keep_alive_status_screen.dart` | 保活状态页：开关、健康度、历史 |

---

## 二、调度策略

间隔按 Cookie 年龄分档（`KeepAlivePlan.calculateInterval`）。注意「Cookie 年龄」是
`now - PlatformAuthStore.getBoundTime()`，即**距用户上次授权的时间**，不是 Cookie 上次刷新的时间
（令牌轮换刻意不改写 `_boundTime`）。

| Cookie 年龄 | 保活间隔 |
|---|---|
| 0-3 天 | 24 小时 |
| 4-7 天 | 12 小时 |
| 8-10 天 | 6 小时 |
| 11 天以上 | 4 小时 |

对每个平台，一轮检查按顺序判定，任一不通过就跳过该平台：

1. 用户是否关闭了总开关 / 该平台开关；
2. 该平台是否已绑定（有 Cookie）；
3. **闸门**：`now < next_keep_alive_at` → 跳过（该值已落盘，重启后仍生效）；
4. 冷却：用户 6 小时内同步过、或 2 小时内刚保活过 → 跳过。

通过后发送心跳，并把 `next_keep_alive_at` 置为 `now + 间隔 ± 随机 0-30 分钟`（抖动用来避开固定时间点）。

前台检查定时器为 **1 小时一次**，各平台按自己的动态间隔独立放行；后台 WorkManager 周期任务为 **6 小时一次**，
与前台共用同一份闸门状态。

---

## 三、持久化

Hive box `keep_alive_state`，明文存储（只含时间戳与计数，无凭据）。

| key | 类型 | 说明 |
|---|---|---|
| `enabled` | bool | 保活总开关（默认 true） |
| `{platform}_enabled` | bool | 单平台开关（默认 true） |
| `{platform}_last_keep_alive_at` | int (ms) | 上次保活成功时间 |
| `{platform}_next_keep_alive_at` | int (ms) | **冷启动闸门**，决定重启后是否立刻发心跳 |
| `{platform}_failure_count` | int | 连续失败计数 |
| `{platform}_last_notify_expired_at` | int (ms) | 失效提醒去重标记 |
| `history` | List\<Map\> | 最近 50 条保活记录 |
| `schema_version` | int | 当前为 1 |

### 前后台并发写同一 box

前台进程与 WorkManager 后台 isolate 会各自打开该 box，约定的写入边界：

- 后台 isolate **只写单 key 标量**（`last_keep_alive_at` / `failure_count` / `next_keep_alive_at`），
  幂等且 last-writer-wins，交错写入不会造成结构损坏；
- 需要 read-modify-write 的 `history` **只由主 isolate 写**，后台绝不触碰；
- 前台启动时 `KeepAliveStore.loadIntoCache()` 以磁盘为准覆盖内存缓存，由此与后台写入收敛。

两个 isolate 各有独立的内存缓存，**不要跨 isolate 假设缓存一致**。

---

## 四、各平台心跳

| 平台 | 实现 | 判定口径 | 可后台运行 |
|---|---|---|---|
| 淘宝/天猫 | `TaobaoTokenRefresher`：mtop `mtop.cainiao.pickup.search.getTimeStamp` 签名请求 | `FAIL_SYS_SESSION_EXPIRED` / `FAIL_SYS_SID_INVALID` / `您需要登录才能继续访问` → 失效 | ✅ 纯 HTTP |
| 京东 | `GET https://wqs.jd.com/order/orderlist_jdm.shtml`，校验响应体 | 响应体含 `请登录` / `login.m.jd.com` / `passport.jd.com` / `"isLogin":false` / `"loginFlag":false`，或重定向到 login，或 HTTP 401/403 → 失效 | ✅ 纯 HTTP |
| 拼多多 | 委托 `PddH5Connector.keepAliveProbe()`，复用其常驻 WebView 加载订单页 | 落地页含 `login`，或订单接口返回 `HTTPSTATUS:424` / `login.html` → 失效 | ❌ 见下 |

淘宝心跳成功且服务端下发了新令牌时，会就地轮换 `_m_h5_tk` / `_m_h5_tk_enc` 并落盘
（`updateCookieTokenFields` 刻意不刷新授权绑定时间）。mtop 只在服务端判定令牌过期时才下发新令牌，
因此新登录后头几次心跳不轮换属正常。

### 拼多多为什么只能前台保活

`PddHeartbeat` 曾经自己 `WebViewController()` 发心跳，而 webview_flutter 4.14.1 的
`WebViewController` **没有 `dispose()`** —— 原生 WebView 只在 `WebViewWidget` 销毁时释放，
而心跳从不构建 widget，于是每调用一次就泄漏一个原生 WebView。现在改为复用
`PddH5Connector` 已持有的常驻控制器，随其宿主页面生命周期回收。

顺带补上了该连接器此前缺失的并发保护：`_busy` 互斥位让同步与探活串行，避免两个 `loadRequest` 互相打断。

后台不尝试拼多多的原因有两层：WebView 需要 platform view 与主线程，WorkManager 的裸
FlutterEngine 没有 Activity；且拼多多 proxy 接口要求 `anti_content` 动态签名，纯 HTTP 会被风控返回 424
（见 `pdd_connector.dart` 文件头注释）。因此**不要**试图把拼多多改成纯 HTTP 心跳。

---

## 五、失效提醒闭环

「检测」与「通知」刻意解耦：失效可能由前台保活、后台 worker 或连接器同步发现，但通知只在
`KeepAliveNotifier` 发出，去重标记也只在这里落盘。

- **渠道**：`keep_alive_channel` / 「登录状态提醒」，与「快递通知」分开，用户可单独静音。
- **通知 id**：`30000 + 平台槽位`（槽位取自 `kPlatformIds` 下标 + 1），同一平台重复提醒是**替换**而非堆叠。
- **去重**：仅当「当前已失效 且 该平台 `last_notify_expired_at` 为空」时提醒；**只有发送成功才写标记**。
- **兜底**：后台 isolate 弹通知是尽力而为，失败不写标记，前台下次检查会补发，提醒不会丢。
- **恢复**：心跳成功会清空该标记，于是下一个失效周期可以再提醒一次。
- **点击跳转**：回调里没有 `BuildContext` 且 App 可能冷启动，因此 payload 只投递到
  `NotificationAdapter.pendingRoute`，由 `lib/ui/app.dart` 在首帧后消费并借助全局
  `appNavigatorKey` 跳到设置页。冷启动场景通过 `getNotificationAppLaunchDetails()` 补投。

---

## 六、开关与历史

- 状态页顶部有**保活总开关**，每个平台卡片右侧有**单平台开关**，选择会持久化，重启后仍生效。
- 关闭总开关后前台不启动、后台 worker 直接返回；关闭单平台则两个路径都跳过该平台。
- 「保活历史」区展示最近 10 条记录与总成功率；`KeepAliveHistory.successRate` 会排除
  `skipped` 记录（跳过既不算成功也不算失败），无有效样本时返回 null。

---

## 七、调试

```bash
adb logcat | grep -E "KeepAlive|KeepAliveWorker|KeepAliveStore"
```

关键日志：

```
[KeepAliveService] Skip taobao: next keep-alive in 342 min    ← 闸门生效（冷启动不重发）
[KeepAliveService] Skip pdd: disabled                          ← 用户关闭了该平台
[KeepAliveService] Sending heartbeat to jd (age: 9 days)...
[KeepAliveService] ✓ jd heartbeat success
[KeepAliveService] - pdd heartbeat skipped: 拼多多 WebView 当前不可探活
[KeepAliveNotifier] expiry notified: jd
```

状态页的「测试后台续期任务」会注册一个 3 秒后触发的 one-off WorkManager 任务，用于验证后台
isolate 链路（Hive 初始化 → Keystore 解密 → HTTP 心跳 → 落盘）。强制运行 periodic 任务对未到期的
work 无效，验证后台请用这个入口。

---

## 八、已知限制

- 拼多多无法进程外续期，只能靠前台心跳与用户打开 App 时的同步恢复。
- WorkManager 周期任务最小间隔 15 分钟且由系统批量调度，不保证精确时刻。
- 部分国产 ROM 需要用户手动允许后台运行，否则系统回收后无法唤醒。
- 保活只能延长登录态寿命，不能保证永不失效：平台主动清理异常登录态、用户在其他设备登录导致的
  互踢，都不是保活能覆盖的。

---

## 九、变更记录

**2026-10-08**

1. **修复冷启动心跳风暴**：原先「上次保活 / 失败次数 / 下次保活时间」三个 Map 都在内存里，
   进程重启即清零，导致每次冷启动都对全部已绑定平台重发一轮心跳。现在 `next_keep_alive_at`
   落盘，重启后闸门依然生效（`test/keep_alive_service_test.dart` 有对应回归测试）。
2. **修复拼多多 WebView 泄漏**：删除自建控制器的 `PddHeartbeat`，改为委托连接器常驻控制器。
3. **接通「用户同步后 6 小时跳过」**：`SyncHistoryManager.recordPlatformSync` 此前从未被调用，
   该规则因 `lastSyncTime` 恒为 null 而永远不触发；现在由 `ConnectorManager` 在每次同步结束时记录。
4. **新增失效提醒闭环**：本地通知 + 设置页入口，带去重与成功后写标记的兜底语义。
5. **新增保活总开关与单平台开关**、**保活历史与成功率**。
6. **纯逻辑下沉 core**：`KeepAliveScheduler` → `KeepAlivePlan`，去掉 `debugPrint`、时间参数化，
   并删除从未被调用的 `isPreferredTimeSlot()`。
7. **前台/后台共用闸门**：后台 worker 也读 `next_keep_alive_at` 并尊重用户开关，前后台不再各自发心跳。
8. **修复健康度配色与文案不一致**：徽章文字可能显示「失效」而颜色仍按 Cookie 年龄取绿色，
   现在两者同源。
