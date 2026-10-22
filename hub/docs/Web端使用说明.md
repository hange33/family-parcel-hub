---
title: 取件码聚合 · Web 端使用说明
date: 2026-10-20
status: 已上线（内网可用，公网入口待加）
---

# 取件码聚合 · Web 端

## 访问

| 入口 | 地址 | 备注 |
|---|---|---|
| **公网** | `https://parcel.example.com/` | 家里 / 公司 / 手机都能开 |
| 内网 | `http://192.0.2.10:8790/` | 局域网直连，更快 |

首次打开先在右上角填**访问令牌**（= `config.hub.json` 的 `token`），
点「保存」。令牌存在浏览器 localStorage，之后不用再输。

## 三个页签

### 未取件
当前所有待取包裹。列：取件码 / 驿站 / 平台 / 归属 / 商品 / 快递 / 到件时间。
点右侧 **「标记已取」** 按钮 → 这件立刻从未取清单消失，并推一条「✅ 已取」到 QQ。

### 已取件
已取走的包裹历史。点 **「撤销」** 可回滚成未取（误点救命用，不推消息）。

### 账号绑定
三段：

1. **新增账号**（卡片在顶部）
   - 填 `账号 id`（如 `ta`）+ `显示名`（如 `对象`）→ 点「添加账号」
   - id 限 **2-16 位小写字母 / 数字 / 下划线**，用于登录态文件名（`state/<id>_<平台>.json`）
   - 加完后各平台会自动补上空位，点「绑定」扫码即可
   - 每行有「删除」按钮（**至少保留一个账号**，删光会导致抓取无从下手）
   - 变更立即写回 `config.json` 与 `config.hub.json`，**重启容器不丢**
2. **账号绑定表**：列出「账号 × 平台」的绑定状态
   - `已绑定` = 该平台有登录态文件
   - 点「绑定」→ 页面下方出现二维码 → **用对应 App 扫**（拼多多 / 淘宝 / 京东）
   - 扫完页面自动变「✅ 绑定成功」
   - 二维码约 1 分钟过期，失效了点「重新扫码」
3. **账号信息表**：各账号的上次上报时间、当前待取数、历史总数。

## 三个新增接口

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/api/v1/all` | 全量（未取 + 已取 + 在途），Web 端列表用 |
| GET | `/api/v1/devices` | 各账号上报情况 |
| POST | `/api/v1/pick_key` | 按 `hub_key` 标记已取（比按取件码精确） |
| POST | `/api/v1/unpick` | 撤销「已取」 |
| GET | `/api/v1/scan/accounts` | 账号×平台绑定状态（转发 scrapers） |
| POST | `/api/v1/scan/start` | 触发扫码（转发 scrapers） |
| GET | `/api/v1/scan/status` | 扫码进度 |
| POST | `/api/v1/accounts/add` | 新增账号（校验 + 落盘 + 同步 owners） |
| POST | `/api/v1/accounts/remove` | 删除账号（至少保留一个） |
| GET | `/qr/<file>.png?t=<token>` | 二维码图片（代理 scrapers） |

全部需要 `X-Hub-Token` 头（除 `/` 与 `/health`）。

## 架构

```
浏览器
  │  http://192.0.2.10:8790
  ▼
parcel-hub 容器 (8790)  ──┬─ SQLite: data/hub.sqlite
                          ├─ 静态页: web/index.html
                          └─ 代理 → parcel-scrapers (8791) /api/login/*
                                                 │
                                          Playwright 出码
```

- **hub** 提供页面与数据（读同一个 SQLite）
- **scrapers** 负责真正开浏览器出二维码
- 两容器共享挂载 `/vol1/xxx/backup/parcel-hub-deploy`，所以 `state/*.json` 登录态两边都能看到

## 改前端

Web 页面是**单文件**：`web/index.html`（HTML+CSS+JS 全内联，零构建）。

改完推到 NAS：

```bash
cd /d/workbuddy/webdav-backup
python _push_parcel.py web/index.html
```

然后浏览器强刷（Ctrl+F5）即可，**不用重启容器**。

## 接手时修掉的问题（2026-10-20）

| 问题 | 根因 | 修法 |
|---|---|---|
| 已取走的件永远停在 arrived，每天 17:00 汇总重复推 | `run_scrapers` 只在命中时上报；平台把已取件移出列表后就再也报不到了 | 无论是否命中都上报全量快照；结构化解析能读出「已签收」状态 |
| 运单号/商品名丢失 | 老解析器只做 `inner_text` 文本匹配 | 改读页面内嵌的 `window.rawData` JSON（权威结构化数据） |
| 跨平台误标 stale | `_mark_stale` 只按 owner 过滤 | 限定在本次快照覆盖的平台范围内 |
| 插入时不置 `notified_arrived` | `_upsert` 漏了 | 补上；并把判据从 `prev_status` 改成 `notified_arrived`（先到站后出码也要能补推） |
| QQ 推送连不通 | hub 在 bridge 网络，配置写 `127.0.0.1:8787` 指到自己 | 改 `192.0.2.10:8787` |
| 容器重建后 chromium 消失 | `bootstrap.sh` 只判断 `.venv` 是否存在，而 venv 在挂载卷里、chromium 在容器文件系统里 | venv 与 chromium 分别判断 |
| NAS 重启后容器不自动起 | RestartPolicy 是 `no` | 改为 `always` |
| dump 每天涨 1.3GB | 全页 PNG 28MB/张且无清理 | 改视口截图 + 保留最近 3 天/60 轮 |

## 回归测试

```bash
cd D:/workbuddy/parcel-hub/work
python test_pdd_parser.py   # 解析器（用 3 份真实 dump）
python test_hub_flow.py      # hub 端到端（状态机 / 去重 / stale 隔离）
python test_web.py           # Web 端（页面 / 手动已取 / 扫码代理 / 鉴权）
python test_account_add.py   # 新增账号（落盘 / owners 同步 / 校验 / 最后账号保护）
```

四份测试都**不依赖网络**（Web 端测试用本地假 scrapers），可直接跑。

## 公网入口（CF 隧道）

`parcel.example.com` → `http://192.0.2.10:8790`（hub）

隧道是 remote-managed，改 ingress 走 Cloudflare API。凭据取自
vault `raw/credentials/cloudflare.md`（已同步到本机
`D:\workbuddy\70-基础设施-凭据\cloudflare.md`），工具：

```bash
cd /d/workbuddy/webdav-backup
python _cf_tunnel.py list                                        # 看当前 ingress
python _cf_tunnel.py add parcel.example.com http://192.0.2.10:8790
python _cf_tunnel.py remove parcel.example.com
```

⚠️ PUT 必须包一层 `{"config": {...}}`，否则报 `missing field config`。
⚠️ `catch-all`（`http_status:404`）必须留在 ingress 数组最后。
