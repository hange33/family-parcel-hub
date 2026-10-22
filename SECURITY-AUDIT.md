---
title: 源码安全审查 · parcly v1.0.0
date: 2026-10-20
scope: Granter-z/parcly@dcc750d（本仓库 fork 基点）
verdict: 未发现外发/后门；有 1 项加固建议
---

# 源码安全审查

> 目的：这个 App 要拿着你的淘宝 / 京东登录态跑在手机上，必须先确认它不往外送数据。

## 一、结论

**未发现数据外发、后门、动态加载或第三方统计 SDK。** 外联域名只有三家电商和图示占位图。
有 1 项加固建议（明文 HTTP 开关），不影响使用。

## 二、逐项核查

### 1. 权限（`android/app/src/main/AndroidManifest.xml`）

```
INTERNET / ACCESS_NETWORK_STATE / RECEIVE_BOOT_COMPLETED / SCHEDULE_EXACT_ALARM / VIBRATE
```

✅ 没有 READ_SMS、READ_CONTACTS、READ_PHONE_STATE、存储权限、定位、悬浮窗。
✅ 与「账号抓取、不读短信」的定位一致。

### 2. 全部外联域名（`lib` + `android` + `pubspec.yaml` 全量提取去重）

| 域名 | 用途 | 判定 |
|---|---|---|
| `mobile.yangkeduo.com` / `yangkeduo.com` / `mobile.pinduoduo.com` | 拼多多 | 正常 |
| `h5.m.taobao.com` / `main.m.taobao.com` / `h5api.m.taobao.com` / `login.taobao.com` 等 | 淘宝 / MTOP | 正常 |
| `trade.m.jd.com` / `wqs.jd.com` / `api.m.jd.com` / `plogin.m.jd.com` 等 | 京东 | 正常 |
| `page.cainiao.com` / `pages.cainiao.com` / `m.cainiao.com` | 菜鸟驿站取件页 | 正常 |
| `images.unsplash.com` | 商品图占位 | 正常（无数据上传） |
| `flutter.dev` / `developer.android.com` / `schemas.android.com` | 文档链接 / XML 命名空间 | 正常 |

✅ **没有任何自有服务器、短链、统计域名、云函数地址。**
✅ 未发现字符串拼接混淆的 URL（`'https' + ...` 之类 0 处）。

### 3. 依赖（`pubspec.yaml`）

`flutter_riverpod / intl / cupertino_icons / hive / hive_flutter / flutter_local_notifications /
timezone / uuid / equatable / crypto / webview_flutter / http / url_launcher / workmanager` +
本地插件 `plugins/secure_store`。

✅ 全部为公开主流包，无统计/推送 SDK（firebase / sentry / bugly / umeng / jpush / getui 均 0 处）。
✅ 无原生 `.so`，Android 侧仅一个 `androidx.webkit`。

### 4. 凭据存储（`plugins/secure_store/.../SecureStorePlugin.kt`）

- 用 **Android Keystore** 生成 AES 密钥，AES-GCM 加解密，密钥不出 TEE/Keystore
- 只有 `encrypt` / `decrypt` / `isAvailable` 三个方法，**没有任何网络调用**
- 用途：把平台 Cookie 加密后落本地 Hive，后台 WorkManager 也能读

✅ 凭据不上传、不明文落盘。

### 5. WebView 桥接（`MainActivity.kt`，71 行）

- 只有两个方法：`setCookie`（写入本机 WebView 的 CookieManager）、`installDocumentStartHook`
- 注入脚本要求调用方**显式声明 origins 白名单**，缺省为空集合（即默认不生效）
- ❌ 没有 `addJavascriptInterface`（这是最常见的 WebView 逃逸面）
- ❌ 没有 `setAllowFileAccess` / `setAllowUniversalAccessFromFileURLs`

✅ 攻击面小。

### 6. 数据外发特征扫描

| 特征 | 命中 |
|---|---|
| `eval(` / `base64Decode` / `Process.run` / `loadLibrary` / `HttpServer` / `Socket(` | 0 |
| `upload` / `sendCookie` / `report cookie` 之类 | 0 |
| `ANDROID_ID` / `getImei` / `getDeviceId` | 0（不采集设备标识） |

✅ 无外发、无设备指纹采集。

## 三、发现的问题

| # | 级别 | 问题 | 建议 |
|---|---|---|---|
| 1 | 低 | `AndroidManifest` 里 `usesCleartextTraffic="true"` | 代码里所有地址都是 HTTPS，可改为 `false`，防止将来误用明文。属加固项，不阻塞 |
| 2 | 提示 | 项目 2026-10-06 建仓、3★、单人维护 | 不构成安全风险，但**上游可能随时停更**；已用 fork + `upstream` remote 保留跟进能力 |
| 3 | 提示 | 我们从 Releases 装的 APK 由作者签名 | 自用应**自己编译**（用本仓库源码），不要装作者签名包，避免「源码干净但发行包不同」 |

## 四、残余风险（无法靠审代码消除）

1. **账号侧风险**：抓取行为本身可能违反平台用户协议；本方案已把拼多多改为网页端、淘宝/京东低频同步，降低触发风控概率。
2. **Cookie 失窃 = 账号失窃**：`tools/pdd_web/state/*.json` 与 App 内的加密 Cookie 等价于登录凭证，已在 `.gitignore` 排除，切勿外传。
3. **上游改版**：连接器随时可能因平台接口变化失效，属正常维护成本。

## 五、审查方法（可复现）

```bash
grep -h "uses-permission" android/app/src/main/AndroidManifest.xml
grep -rhoE "https?://[a-zA-Z0-9._-]+" lib android pubspec.yaml | sed 's#https\?://##' | sort | uniq -c | sort -rn
grep -rn --include="*.dart" -E "eval\(|base64Decode|Process\.run|HttpServer|Socket\(" lib
grep -rn --include="*.dart" -iE "upload|sendCookie|report.*cookie" lib
grep -rn --include="*.dart" --include="*.kt" -E "ANDROID_ID|getImei|getDeviceId" lib android
```
