# pdd_web · 拼多多网页端取件码抓取

**为什么单独做这一块**：拼多多 App 与任何第三方 H5 会话**双向互踢**（2026-10-20 实测）。
但**网页端扫码登录不会顶掉手机 App**（同日实测），所以拼多多走网页端，App 照常用。

## 两个脚本，两种场景

| 脚本 | 跑在哪 | 用途 |
|---|---|---|
| `probe_login.py` | 家里电脑（有屏幕） | 一次性探测：扫码 → 导 HTML/文本/截图，用来写解析器 |
| `worker.py` | NAS 容器（无屏） | 常驻抓取：定时拉取件码 → 上报 parcel-hub |

## 关于「登录」这件事

**登录动作始终由你自己完成**，脚本不碰你的密码、不收验证码。

- **家里电脑跑 `probe_login.py`**：浏览器窗口直接弹二维码，你拿手机扫一下。
- **NAS 跑 `worker.py`**：机器没有屏幕，所以脚本把二维码截成图片，
  通过 qq-bridge 推给你一条消息（带链接），你用电脑打开链接看到二维码，再拿手机扫。

> 换句话说：AI 只负责「把二维码送到你眼前」，扫码、授权、确认全是你本人在拼多多 App 里做的。
> 这也是一次性动作——登录态存在容器里，之后自动复用，失效时才重新出码。

## 一、家里电脑探测（验证阶段）

```bash
pip install playwright
python -m playwright install chromium
python probe_login.py --account wo
```

跑完看 `dump/` 下的 `.txt` / `.png` / `.html`，确认有没有取件码、长什么样。

## 二、NAS 常驻（正式阶段）

```bash
cp docker-compose.example.yml docker-compose.yml
# 填 HUB_TOKEN / QQ_BRIDGE_TOKEN / QR_TOKEN，PDD_DRY_RUN 先保持 1
docker compose up -d --build
docker logs -f pdd-web
```

工作循环：

```
无登录态 → 出码 → QQ 推送链接 → 你扫码 → 保存 storage_state
       → 每 30 分钟抓一次 → 解析取件码 → POST parcel-hub/api/v1/report
       → 上报成功由 hub 决定推不推 QQ
```

- `PDD_DRY_RUN=1`：只打印解析结果，不向 hub 上报（先跑一天看日志）
- Cookie 失效：自动回到出码流程，QQ 收到「登录已失效」消息
- 登录态文件在 `./state/<device>.json`，等同账号凭证，**不要提交、不要外传**

## 三、二维码对外暴露的安全

NAS 上的 `/qr.png` 需要 `?t=<QR_TOKEN>` 才能访问，且二维码本身有时效（拼多多几十秒刷新一次）。
公网域名建议单独开一个 `pdd.example.com` 指到 8791，用完可在 CF 面板删掉。

## 四、解析策略

`parse_page_text()` 目前是**文本启发式**（DOM 未知时的临时手段）：

- 取件码：`\d{1,3}-\d{1,3}-\d{2,5}`（货架码）
- 驿站名：含「驿站 / 自提点 / 快递柜 / 服务站 / 代收点」的短语
- 运单号：`JT/SF/YT/ST/JD/ZTO/YD/EMS/DB` 前缀

拿到真实 `dump/*.html` 后应改成 DOM 选择器，稳定性会好很多。

## 五、判定

| 结果 | 含义 |
|---|---|
| 文本里有取件码 | ✅ 路线成立，收紧解析器 |
| 只有物流轨迹、没有取件码 | 页面上应有「查看取件码」入口，把 HTML 给我 |
| 被弹回首页 | 该页可能下线，改走订单列表逐单展开 |
