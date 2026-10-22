# family-parcel-hub · 家庭取件码聚合

<p align="center">
  <img src="https://img.shields.io/badge/Python-3.11-blue" alt="Python" />
  <img src="https://img.shields.io/badge/hub依赖-零第三方-success" alt="stdlib only" />
  <img src="https://img.shields.io/badge/Docker-支持-2496ED?logo=docker&logoColor=white" alt="Docker" />
  <img src="https://img.shields.io/badge/License-GPLv3-blue" alt="License" />
</p>

把全家人在 **拼多多 / 淘宝 / 京东** 的包裹，聚合到一个完全自托管的服务里：

**到站即推送 · 取走自动识别 · 每天 17:00 汇总**，全部跑在自己的 NAS 上，不经手任何第三方云。

> 本项目基于 [Granter-z/parcly](https://github.com/Granter-z/parcly)（GPL-3.0）二次开发：
> 保留其 Flutter 客户端并做适配，新增了 NAS 常驻服务端、Web 看板与推送体系。
> 对上游的逐条改动见 [MODIFICATIONS.md](MODIFICATIONS.md)。

## 功能

- 📦 **多平台到站监控**
  拼多多：网页包裹助手桌面会话（不踢官方 App）✅；
  淘宝：菜鸟驿站 MTOP 接口（纯 HTTP，不开页面）✅；
  京东 ⏸：解析与登录探测代码已内置，但登录被风控（要求本人语音认证），**默认未启用**。
- ✅ **取走自动识别**
  权威快照对比 + 平台状态签名，变化后静默 10 分钟合并成一条推送，一个驿站一次取完只打扰一次。
- 📋 **每日 17:00 未取汇总**
  没有未取件就不发，绝不空转打扰。
- ⚠️ **登录失效提醒**
  cookie 失效立即私聊提醒（12 小时冷却防刷屏），恢复登录也会通知。
- 🌙 **夜间免打扰**
  `22:30–08:00` 的消息顺延到早上，合并成一条补发；时段可配置。
- 🖥 **Web 看板**
  未取件 / 已取件 / 账号绑定（扫码出码）/ 运行日志，手机电脑浏览器直接用。
- 🔐 **登录态自主可控**
  cookie 只存 NAS 的 `state/` 目录，绝不入 git；支持令牌鉴权开关。

## 架构

```
                    ┌──────────────────────────────────────┐
 手机 QQ ←── qq-bridge ←──│  parcel-hub :8790                    │
                    │  （Web 看板 + API + SQLite，零依赖）   │
                    └──────────────┬───────────────────────┘
                                   │ 上报 / 出码代理
浏览器 ──→ Web 看板（公网/内网）──→│  parcel-scrapers :8791
                    └──────────────┬───────────────────────┘
                                   │ Playwright / HTTP
                          拼多多 · 淘宝(菜鸟) · 京东
```

## 目录

| 路径 | 说明 |
|---|---|
| `hub/` | NAS 常驻服务端：`app.py`（Web+API+状态机）、`run_scrapers.py`（抓取调度）、`scrapers.py`（三家平台实现）、`web/`（单文件看板）、`test/`（回归测试） |
| `lib/` `android/` `test/` | Flutter 客户端（基于 parcly 二次开发，可选；改动清单见 MODIFICATIONS.md） |
| `tools/pdd_web/` | 拼多多网页端取件码探测脚本 |
| `docs/` | 原版验证清单等记录 |

## 快速开始（Docker）

两份配置放在仓库根：`config.hub.json`（服务端）、`config.json`（抓取器），
示例在 [hub/config.hub.example.json](hub/config.hub.example.json) 与
[hub/config.scrapers.example.json](hub/config.scrapers.example.json)。

```bash
git clone https://github.com/hange33/family-parcel-hub.git
cd family-parcel-hub
cp hub/config.hub.example.json config.hub.json      # hub 侧：token / owners / qq_bridge
cp hub/config.scrapers.example.json config.json     # 抓取器侧：accounts / platforms / qr

# 编辑两份配置后：
docker compose up -d --build
# 抓取器首次启动 bootstrap.sh 会自动装 chromium + playwright，之后不再重复

# 打开看板
http://<NAS 内网 IP>:8790/
```

主要配置字段：

**config.hub.json（服务端）**

| 字段 | 说明 |
|---|---|
| `token` / `require_token` | Web/API 鉴权；`require_token=false` 时打开网页即可用（公网不建议） |
| `owners` | 账号 id → 显示名（推送里显示谁取的） |
| `qq_bridge` | QQ 桥地址、令牌与目标（`me` 私聊 / `group` 群聊） |
| `quiet_hours` | 夜间免打扰窗口，默认 `22:30–08:00`，窗口内的推送顺延合并补发 |
| `summary_at` | 每日汇总时间，默认 `17:00` |
| `scrapers` | 抓取器地址与二维码令牌（hub 代理出码用） |

**config.json（抓取器）**

| 字段 | 说明 |
|---|---|
| `accounts` / `platforms` | 谁的哪些平台要抓；京东默认不在列表里 |
| `interval_min` | 抓取间隔，默认 30 分钟 |
| `hub` | 上报地址与令牌（与 hub 的 `token` 一致） |
| `qr` | 扫码二维码服务的端口 / 令牌 / 公网前缀 |
| `wait_on_login` | 登录失效时是否阻塞等扫码；默认 `false`（跳过并告警） |

## 推送

| 消息 | 触发 | 时机 |
|---|---|---|
| 📦 新到件 | 首次拿到取件码 | 立即 |
| ✅ 已取（合并） | 权威快照中消失 / 平台状态转已签收 | 最后一次变化后静默 10 分钟，合并一条 |
| ✅ 已取（单件） | Web 端手动标记 | 立即 |
| 📋 未取汇总 | 每日定时 | 有未取件才推 |
| ⚠️ 登录失效 | cookie 检查失败 | 立即，12 小时冷却防刷屏 |

推送通道是通用的 HTTP POST（`qq_bridge.url`），接 QQ 机器人、Telegram bot、 Bark 等都可以。

## 安全

- 登录态 cookie 只存 NAS 本地 `state/`，**绝不入 git**（`.gitignore` 已覆盖）
- 默认建议 `require_token: true`；`false` 仅限临时调试，公网上等于裸奔
- 仅供个人/家庭使用，请遵守各平台服务条款，控制抓取频率

## License

GPL-3.0。基于 [Granter-z/parcly](https://github.com/Granter-z/parcly) 二次开发，感谢原作者。
