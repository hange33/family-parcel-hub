# FAMILY-HUB · 家庭聚合分支说明

本仓库基于 [Granter-z/parcly](https://github.com/Granter-z/parcly) **二次开发**（遵循其 GPL-3.0 许可），
用于「两个人的多平台取件码 → 家里 NAS 聚合 → QQ 机器人推送」。

上游代码保持原样，所有改动集中在下面几个目录，便于日后 `git fetch upstream` 跟进。

## 目录约定

| 路径 | 内容 | 是否改动上游 |
|---|---|---|
| `lib/` `android/` `test/` … | parcly 原始代码 | 已改拼多多连接器与登录入口（见 `MODIFICATIONS.md`） |
| `hub/` | NAS 侧聚合服务（Python 零依赖 + SQLite，已自测） | 新增 |
| `tools/pdd_web/` | 拼多多网页端取件码探测脚本（Playwright） | 新增 |
| `docs/family-hub/` | 原版验证清单等记录（设计细节文档未随仓库分发） | 新增 |
| `SECURITY-AUDIT.md` | 源码安全审查结论 | 新增 |

## 核心设计

```
拼多多：网页端扫码登录抓取（会话独立，不顶手机 App）
淘宝/京东：parcly 账号抓取（实测不顶 App）
                     ↓
        每台手机 / 每个账号 → 上报 → NAS parcel-hub（SQLite 去重合并）
                     ↓
        QQ 机器人：新件即时推 / 17:00 未取汇总 / 取件完成推
```

## 关键结论（实测，勿再重复踩）

| 事实 | 日期 | 说明 |
|---|---|---|
| 拼多多 App 与第三方 H5 双向互踢 | 2026-10-20 | parcly 登 PDD → 官方 App 掉线；App 重登 → parcly 失效 |
| **拼多多网页端与 App 会话独立** | 2026-10-20 | 扫码登录网页端，App 不掉线 → 拼多多改走网页端 |
| 淘宝 / 京东 账号抓取不顶 App | 2026-10-20 | 可直接复用 parcly 的 connector |

## ⚠️ 与上游路线的重要分歧

上游 parcly 的拼多多设计是：**用 App 内置商城替代官方 App**（`PddWebScreen` 文档头写明「无需安装或打开拼多多官方 App，彻底避免双端互踢」）。
它依赖 `mobile.yangkeduo.com` 的**移动会话**，与官方 App 天然互斥。

本分支的选择相反：**官方 App 照常用**，拼多多只读 `mobile.pinduoduo.com` 的包裹助手页（桌面会话）。
因此本分支**移除了首页「拼多多内置商城」入口**，并让 `PddH5Connector` 不再注册。
`lib/ui/screens/pdd/pdd_web_screen.dart` 文件仍保留（供日后回滚），但不再是任何入口。

> 这意味着：本分支不能在上游 PDD 相关代码上直接 rebase 而不处理冲突，冲突点集中在
> `home_screen` / `settings_screen` / `connector_manager` / `platform_login_screen` 四处。

## 许可证

上游为 **GPL-3.0**。本分支同样遵循 GPL-3.0，仅个人自用，不对外分发。
