#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pdd-web worker —— 拼多多网页端取件码抓取（NAS 常驻，无头）

工作方式：
  1. 没有有效登录态时：无头打开包裹助手页 → 截图二维码 → 存成 qr.png →
     通过 HTTP 暴露（/qr.png?t=<qr_token>）→ 由 qq-bridge 推一条带链接的消息
  2. 用户用手机扫码后，轮询到 pdd_user_id Cookie → 保存 storage_state → 推「已登录」
  3. 之后每 N 分钟抓一次页面，解析取件码，POST 给 parcel-hub
  4. Cookie 失效 → 回到第 1 步，重新出码

安全：
  - 登录态文件等同账号凭证，只放 /app/state，容器内不对外
  - /qr.png 需要 qr_token 才能取，防止被扫到别人的登录二维码
  - dry_run 时只打印解析结果，不向 hub 上报

运行：
  python worker.py --hub-url http://127.0.0.1:8790 --hub-token xxx --device wo
"""

from __future__ import annotations

import argparse
import json
import os
import re
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib import error, request

HERE = Path(__file__).resolve().parent
TARGET_URL = ("https://mobile.pinduoduo.com/psnl_goods_help.html"
              "?_t_module_name=assistant_search")
MOBILE_UA = ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
             "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36")

CODE_RE = re.compile(r"\b\d{1,3}-\d{1,3}-\d{2,5}\b")
TRACK_RE = re.compile(r"\b(?:JT|SF|YT|ST|JD|ZTO|YD|EMS|DB)[A-Z0-9]{8,16}\b", re.I)
STATION_RE = re.compile(r"([\u4e00-\u9fa5A-Za-z0-9()（）\-]{2,30}?(?:驿站|自提点|快递柜|服务站|代收点))")
# 拼多多常见的「后5位 98898」形态，只在同行出现“取件/取货”时才认
TAIL_CODE_RE = re.compile(r"后\s*(\d)\s*位\s*[:：]?\s*(\d{4,6})")

STATE_HTML = HERE / "state" / "latest.html"
STATE_TXT = HERE / "state" / "latest.txt"
STATE_QR = HERE / "state" / "qr.png"

# 共享给 HTTP 线程的状态
SERVE = {"qr_token": os.getenv("QR_TOKEN", ""), "ready": False, "ts": 0}


def log(msg: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


# ---------------------------------------------------------------- QR 静态服务
class QRHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/health":
            body = json.dumps({"ok": True, "has_qr": STATE_QR.exists(),
                               "ts": SERVE["ts"]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/qr.png":
            token = ""
            for kv in query.split("&"):
                k, _, v = kv.partition("=")
                if k == "t":
                    token = v
            if SERVE["qr_token"] and token != SERVE["qr_token"]:
                self.send_response(403)
                self.end_headers()
                return
            if not STATE_QR.exists():
                self.send_response(404)
                self.end_headers()
                return
            data = STATE_QR.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404)
        self.end_headers()


def start_qr_server(port: int) -> None:
    srv = ThreadingHTTPServer(("0.0.0.0", port), QRHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log(f"QR 服务 :{port}（/qr.png?t=<QR_TOKEN>）")


# ---------------------------------------------------------------- 推送 / 上报
def push(cfg, content: str) -> None:
    if not cfg.qq_url:
        log("[push] 未配置 qq-bridge，跳过")
        return
    body = json.dumps({"target": cfg.qq_target, "content": content}).encode()
    req = request.Request(cfg.qq_url, data=body, method="POST",
                          headers={"Content-Type": "application/json",
                                   "X-Bridge-Token": cfg.qq_token})
    try:
        with request.urlopen(req, timeout=10):
            pass
    except Exception as exc:
        log(f"[push] 失败：{exc}")


def post_to_hub(cfg, packages: list[dict]) -> None:
    if cfg.dry_run:
        log(f"[dry-run] 应上报 {len(packages)} 件：{json.dumps(packages[:2], ensure_ascii=False)}")
        return
    payload = {"device": cfg.device, "device_label": cfg.device_label,
               "snapshot": True, "packages": packages}
    req = request.Request(f"{cfg.hub_url}/api/v1/report",
                          data=json.dumps(payload).encode(), method="POST",
                          headers={"Content-Type": "application/json",
                                   "X-Hub-Token": cfg.hub_token})
    try:
        with request.urlopen(req, timeout=15) as r:
            log(f"[hub] {r.status} {r.read()[:200].decode(errors='ignore')}")
    except Exception as exc:
        log(f"[hub] 上报失败：{exc}")


# ---------------------------------------------------------------- 解析
def parse_page_text(text: str) -> list[dict]:
    """从页面纯文本里尽力提取包裹。DOM 未知，先用文本启发式，拿到真实 dump 再收紧。"""
    items: list[dict] = []
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    for i, ln in enumerate(lines):
        codes = CODE_RE.findall(ln)
        if not codes:
            continue
        # 上下文窗口：本行 + 前 3 行 + 后 2 行
        ctx = " ".join(lines[max(0, i - 3): i + 3])
        station = STATION_RE.search(ctx)
        track = TRACK_RE.search(ctx)
        items.append({
            "platform": "pdd",
            "pickup_code": codes[0],
            "station": station.group(1) if station else "",
            "tracking": track.group(0) if track else "",
            "courier": "",
            "goods": "",
            "status": "arrived",
            "raw_line": ln[:120],
        })
    # 去重（同码只留一条）
    seen, out = set(), []
    for it in items:
        if it["pickup_code"] in seen:
            continue
        seen.add(it["pickup_code"])
        out.append(it)
    return out


# ---------------------------------------------------------------- Playwright
def cookie_names(ctx) -> set[str]:
    return {c["name"] for c in ctx.cookies()}


def ensure_login(p: dict, cfg) -> bool:
    """返回是否已就绪（登录态有效）。"""
    from playwright.sync_api import sync_playwright  # 延迟导入，便于无浏览器环境跑 linter

    state_file = Path(cfg.state_dir) / f"{cfg.device}.json"
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True, args=["--no-sandbox"])
        kwargs = {"viewport": {"width": 430, "height": 932},
                  "user_agent": MOBILE_UA, "locale": "zh-CN",
                  "timezone_id": "Asia/Shanghai"}
        if state_file.exists():
            kwargs["storage_state"] = str(state_file)
        ctx = browser.new_context(**kwargs)
        page = ctx.new_page()
        page.goto(TARGET_URL, wait_until="domcontentloaded", timeout=60_000)
        page.wait_for_timeout(2500)

        names = cookie_names(ctx)
        if "pdd_user_id" in names or "PDDAccessToken" in names:
            log("登录态有效")
            ctx.close(); browser.close()
            return True

        # 未登录：出码
        STATE_QR.parent.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(STATE_QR), full_page=True)
        SERVE["ts"] = int(time.time())
        log(f"未登录，二维码截图已保存 {STATE_QR}")
        url = f"{cfg.qr_base}/qr.png?t={SERVE['qr_token']}"
        push(cfg, "🔑 拼多多登录已失效\n请用电脑打开下面的链接，用手机拼多多 App 扫码：\n" + url)

        deadline = time.time() + cfg.login_timeout
        while time.time() < deadline:
            time.sleep(3)
            try:
                if "pdd_user_id" in cookie_names(ctx):
                    ctx.storage_state(path=str(state_file))
                    log(f"扫码成功，登录态已保存 {state_file}")
                    push(cfg, "✅ 拼多多已登录，抓取恢复")
                    ctx.close(); browser.close()
                    return True
            except Exception:
                pass
        log("等待扫码超时")
        ctx.close(); browser.close()
        return False


def scrape_once(cfg) -> list[dict]:
    from playwright.sync_api import sync_playwright

    state_file = Path(cfg.state_dir) / f"{cfg.device}.json"
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True, args=["--no-sandbox"])
        ctx = browser.new_context(viewport={"width": 430, "height": 932},
                                  user_agent=MOBILE_UA, locale="zh-CN",
                                  timezone_id="Asia/Shanghai",
                                  storage_state=str(state_file))
        page = ctx.new_page()
        page.goto(TARGET_URL, wait_until="domcontentloaded", timeout=60_000)
        page.wait_for_timeout(2500)
        # 滚动触发懒加载
        last = 0
        for _ in range(10):
            h = page.evaluate("document.body.scrollHeight")
            page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            page.wait_for_timeout(1200)
            if h == last:
                break
            last = h

        text = page.inner_text("body")
        STATE_TXT.parent.mkdir(parents=True, exist_ok=True)
        STATE_TXT.write_text(text, encoding="utf-8")
        STATE_HTML.write_text(page.content(), encoding="utf-8")

        logged = "pdd_user_id" in cookie_names(ctx)
        ctx.close(); browser.close()

    if not logged:
        return []  # 交给上层重新登录
    return parse_page_text(text)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default=os.getenv("PDD_DEVICE", "wo"))
    ap.add_argument("--device-label", default=os.getenv("PDD_DEVICE_LABEL", ""))
    ap.add_argument("--interval-min", type=int, default=int(os.getenv("PDD_INTERVAL_MIN", "30")))
    ap.add_argument("--state-dir", default=os.getenv("PDD_STATE_DIR", str(HERE / "state")))
    ap.add_argument("--hub-url", default=os.getenv("HUB_URL", "http://127.0.0.1:8790"))
    ap.add_argument("--hub-token", default=os.getenv("HUB_TOKEN", ""))
    ap.add_argument("--qq-url", default=os.getenv("QQ_BRIDGE_URL", ""))
    ap.add_argument("--qq-token", default=os.getenv("QQ_BRIDGE_TOKEN", ""))
    ap.add_argument("--qq-target", default=os.getenv("QQ_TARGET", "group"))
    ap.add_argument("--qr-port", type=int, default=int(os.getenv("QR_PORT", "8791")))
    ap.add_argument("--qr-base", default=os.getenv("QR_BASE", "http://127.0.0.1:8791"))
    ap.add_argument("--login-timeout", type=int, default=int(os.getenv("PDD_LOGIN_TIMEOUT", "600")))
    ap.add_argument("--dry-run", action="store_true", default=os.getenv("PDD_DRY_RUN", "1") == "1")
    cfg = ap.parse_args()
    Path(cfg.state_dir).mkdir(parents=True, exist_ok=True)

    start_qr_server(cfg.qr_port)
    log(f"启动 device={cfg.device} interval={cfg.interval_min}min dry_run={cfg.dry_run}")

    while True:
        try:
            if not ensure_login(None, cfg):
                time.sleep(60)
                continue
            pkgs = scrape_once(cfg)
            if not pkgs:
                log("未解析到包裹（可能未登录或页面结构变化）")
            else:
                log(f"解析到 {len(pkgs)} 件：{', '.join(p['pickup_code'] for p in pkgs[:5])}")
                post_to_hub(cfg, pkgs)
        except Exception as exc:
            log(f"循环异常：{type(exc).__name__}: {exc}")
        time.sleep(max(60, cfg.interval_min * 60))


if __name__ == "__main__":
    raise SystemExit(main())
