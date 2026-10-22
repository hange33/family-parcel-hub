# parcel-hub · NAS 聚合服务

把「两个人的多个平台取件码」汇总成一份清单，并推送到 QQ。

**状态：已实现，自测通过（`python selftest.py`）**。尚未部署到 NAS。

## 职责边界

| 做 | 不做 |
|---|---|
| 接收各端上报的包裹快照，去重合并 | 不登录任何账号（抓取在端侧） |
| 状态机：在途 → 派送 → 待取 → 已取 | 不存完整物流轨迹（只存摘要） |
| 三种推送：新到件 / 17:00 汇总 / 已取 | 不直接对接 QQ 开放平台（复用 `qq-bridge:8787`） |
| 端侧漏报时标记 `stale` 提示 | 不删除历史记录 |

## 运行

```bash
# 自测（dry-run，不发真消息）
python selftest.py

# 本地起服务
python app.py --port 8790 --db data/hub.sqlite --config config.json
```

`config.json` 参考 `config.example.json`。环境变量优先：`HUB_TOKEN` / `QQ_BRIDGE_URL` /
`QQ_BRIDGE_TOKEN` / `QQ_TARGET` / `HUB_DRY_RUN`。

**默认 `dry_run: true`** —— 只把推送内容打到日志，不发真消息。确认内容对了再改 `false`。

## 登录态可视与夜间免打扰（2026-10-22）

- **Web 端显示真实登录态**：抓取器每轮把「最近一次 cookie 检查结果」写入
  `state/last_status.json`，`/api/v1/scan/accounts` 返回 `valid / checked_at / note`；
  页面在「账号绑定」新增**登录态**列（正常 / 已失效 / 待检测），未取件页顶部出现红色横幅。
  > 之前只看 `state/<key>.json` 是否存在 → cookie 早过期了页面仍写「已绑定」，与 QQ 告警自相矛盾。
- **重新扫码强制出码**：`startBind(..., force)` → `POST /api/v1/scan/start {force:true}` →
  抓取器跳过「已是登录态，无需扫码」的短路，直接开登录页出码。
- **夜间免打扰**：`quiet_hours: {"start":"22:30","end":"08:00"}`。
  这段时间内的推送不入手机，写入 `dump/deferred.json`；到 `end` 之后合并成一条
  「🌙 夜间顺延 N 条」发出。手动「发送测试消息」不受限制（force）。

## 鉴权（2026-10-21）

`config.hub.json` 的 `require_token` 控制是否要求 `X-Hub-Token`：

| 值 | 行为 |
|---|---|
| `true`（默认） | 所有接口要令牌；Web 端顶部显示令牌输入框 |
| `false` | 免令牌，打开网页即可用；前端读 `/health` 自动隐藏令牌框 |

⚠️ 免令牌意味着**拿到公网地址的人都能看取件码、改推送目标、发测试消息**。
临时调试可以关，调完建议改回 `true`（token 值一直保留在配置里，改一行 + 重启即可恢复）。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/v1/report` | 端侧上报快照，返回触发的 events |
| POST | `/api/v1/pick` | 按取件码标记已取（QQ 回执用） |
| GET | `/api/v1/list` | 未取清单 |
| GET | `/health` | 探针（不需 token） |

写接口需请求头 `X-Hub-Token`；`token` 为空时（仅本地调试）放行。

### 上报体

```json
{
  "device": "wo",
  "device_label": "程启航的手机",
  "snapshot": true,
  "packages": [{
    "platform": "taobao", "order_id": "3821765490123", "tracking": "JT000123",
    "courier": "极兔速递", "pickup_code": "8-3-2015",
    "station": "菜鸟驿站(阳光花园店)", "location": "180栋1楼",
    "goods": "洗衣液", "status": "arrived",
    "arrived_at": "2026-10-20T09:12:00+08:00"
  }]
}
```

- `snapshot: true`：本设备全量快照，未出现且仍是 `arrived` 的标 `stale`（汇总里提示「本次未同步到」）
- `manual_pick: true`：端侧**人工**确认取件，才推「已取」；平台签收只落状态不打扰

## 推送模板

```
📦 新到 2 件
· 菜鸟驿站(阳光花园)  8-3-2015  我｜极兔速递｜洗衣液
· 丰巢A区  5-2-1188  我｜顺丰｜耳机
回复「取 <取件码>」标记已取
```

```
📋 17:00 未取汇总 · 共 3 件
1) 8-3-2015  菜鸟驿站(阳光花园)  我  极兔速递（10-20 09:12 到）
2) 3-1-2201  菜鸟驿站(东门)  对象  圆通（10-20 11:05 到）
回复「取 <取件码>」标记已取
```

```
✅ 已取
· 8-3-2015（我）
还剩 2 件未取
```

## 平台现状（2026-10-21）

| 平台 | 服务端抓取 | 登录方式 | 备注 |
|---|---|---|---|
| 拼多多 | ✅ | 网页包裹助手（桌面 UA），与官方 App 不互踢 | 读页面内嵌 `window.rawData`；**空列表也算权威**（页面显示「暂无全部的包裹」即认定确实无件，自动已取才生效） |
| 淘宝 | ✅ | 扫码登录 `login.taobao.com`，之后纯 HTTP 调菜鸟 MTOP | 只返回「当前在站待取」，**不提供历史已取件**；接口 `SUCCESS` 时「0 件」是权威事实 |
| 京东 | ❌ 暂不启用 | —— | 扫码后被 `aq.jd.com/certified`（认证魔方）要求「手机语音验证码」本人认证，无头容器无法通过 |

京东要重新启用，需先解决风控身份认证，可选：
1. 真实浏览器环境再试（有头 Chromium + Xvfb + 持久化 user-data-dir），降低指纹嫌疑；
2. 加「粘贴 Cookie」绑定：用户在自己浏览器登录后把 `pt_key` / `pt_pin` 粘进来，绕开扫码风控
   （cookie 会过期，需要续期）；
3. 回退到手机 App 侧上报（原 parcly 的 JD connector）。

暂不启用时，把 `config.json` 的 `platforms` 保持为 `["pdd", "taobao"]` 即可（Web 端也不会出现 JD 行）。

## 推送与日志（2026-10-21）

| 消息 | 触发 | 时机 |
|---|---|---|
| 📦 新到件 | 首次拿到取件码 | 立即 |
| ✅ 已取（可多件合并） | 权威快照里消失 **或** 平台状态转为已签收 | **最后一次变化后静默 10 分钟**统一推一条 |
| 📋 未取汇总 | 每日 `summary_at`（17:00） | 有未取件才推 |
| ✅ 已取（单件） | Web 端点「标记已取」 | 立即（人工确认，给即时反馈） |
| ⚠️ 登录态失效 | 抓取器每轮检查 cookie（拼多多 `pdd_user_id`/`PDDAccessToken`、淘宝 `cookie2`+`unb`） | 首次立即推；持续失效每 12h 再提醒一次；恢复时推一条「已恢复」 |

- 「自动已取」只在**权威快照**下判定：抓取器解析成功才会带 `platforms`；
  解析失败/登录失效不带，退化成 `stale`，不会被误判成已取。
- 推送目标：`config.hub.json` 的 `qq_bridge.target`（`me` 私聊 / `group` 群聊）。
  Web 端「日志」页顶部有 **私聊 / 群聊** 两个按钮，点一下即切换并写回配置（`POST /api/v1/push_target`），
  旁边还有「发送测试消息」可直接验证链路。
- 登录失效提醒走 `POST /api/v1/alert`（由抓取器调用），推送目标同样跟随 hub 的私聊/群聊设置；
  去重状态存 `state/login_notify.json`，容器重启不会重复轰炸。
- 日志：写 `dump/hub.log`（超 2MB 轮转成 `.log.1`），`GET /api/v1/logs?lines=300` 可读，
  Web 端「日志」页签直接看；fnOS 读不到容器日志，这是唯一可观测通道。
- 自测：`POST /api/v1/test_push` 发一条测试消息，返回 `{ok, dry_run, target}`。

## 部署（待做）

```bash
docker compose -f docker-compose.example.yml up -d --build
```

- `network_mode: host` 复用宿主网络的 `qq-bridge:8787`
- 凭据从 vault 只读挂载，不另存
- 上线前保持 `HUB_DRY_RUN=1`，先看一天日志

## 待办

- [x] 表结构与去重
- [x] `/report` 差分与事件生成
- [x] 推送模板
- [x] 17:00 汇总
- [ ] 60s 内多事件合并（当前按上报批次合并，够用）
- [ ] 登录失效告警（PDD Cookie / parcly token）
- [ ] 超 72h 未取的 ⏰ 标注（`max_pickup_age_hours` 已留配置位）
