#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
拼多多网页端「包裹助手」探测脚本（P0.5 第二步）

用途：验证网页端登录后能否拿到取件码，并导出现场供后续写解析器。
不解析业务数据，只做三件事：
  1. 扫码登录（登录态存 state/<账号>.json，下次复用）
  2. 打开包裹助手页，滚动到底，导 HTML / 纯文本 / 截图
  3. 打印 Cookie 名字与到期时间（只打名字，不打值）

运行：
    pip install playwright
    python -m playwright install chromium
    python probe_login.py --account wo

首次会弹浏览器窗口，用手机拼多多 App 扫码。登录成功后自动继续。
"""

import argparse
import json
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

HERE = Path(__file__).resolve().parent
STATE_DIR = HERE / "state"
DUMP_DIR = HERE / "dump"

TARGET_URL = (
    "https://mobile.pinduoduo.com/psnl_goods_help.html"
    "?_t_module_name=assistant_search"
)


def log(msg: str) -> None:
    print(f"[probe] {msg}", flush=True)


def wait_login(page, timeout_sec: int = 300) -> bool:
    """等登录成功：看 Cookie 里是否出现 pdd_user_id。"""
    log(f"等待扫码登录（最多 {timeout_sec}s）… 请用手机拼多多 App 扫码")
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        try:
            cookies = page.context.cookies()
            names = {c["name"] for c in cookies}
            if "pdd_user_id" in names or "PDDAccessToken" in names:
                log(f"检测到登录态，Cookie 共 {len(names)} 个")
                return True
        except Exception as exc:  # 页面跳转中可能取不到
            log(f"读取 cookie 失败（可忽略）：{exc}")
        time.sleep(2)
    return False


def scroll_to_bottom(page, rounds: int = 12, pause: float = 1.2) -> None:
    """缓慢滚到底，触发懒加载。"""
    last_h = 0
    for i in range(rounds):
        h = page.evaluate("document.body.scrollHeight")
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        page.wait_for_timeout(int(pause * 1000))
        log(f"滚动 {i + 1}/{rounds}，页面高度 {h}")
        if h == last_h and i >= 2:
            log("高度不再变化，停止滚动")
            break
        last_h = h


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--account", default="wo", help="账号标识，用于命名 state 文件")
    ap.add_argument("--headless", action="store_true", help="无头模式（首次登录别用）")
    args = ap.parse_args()

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    DUMP_DIR.mkdir(parents=True, exist_ok=True)
    state_file = STATE_DIR / f"{args.account}.json"

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=args.headless, slow_mo=80)
        ctx_kwargs = {
            "viewport": {"width": 430, "height": 932},
            "user_agent": (
                "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
            ),
            "locale": "zh-CN",
            "timezone_id": "Asia/Shanghai",
        }
        if state_file.exists():
            log(f"复用登录态 {state_file.name}")
            ctx_kwargs["storage_state"] = str(state_file)

        ctx = browser.new_context(**ctx_kwargs)
        page = ctx.new_page()

        log(f"打开 {TARGET_URL}")
        try:
            page.goto(TARGET_URL, wait_until="domcontentloaded", timeout=60_000)
        except PWTimeout:
            log("首次加载超时，继续尝试")
        page.wait_for_timeout(2500)

        if not wait_login(page, 300 if not state_file.exists() else 20):
            log("未检测到登录态。若是首次登录，请确认已扫码；否则可能 Cookie 已失效")
            page.screenshot(path=str(DUMP_DIR / f"{args.account}_login_fail.png"),
                            full_page=True)
            ctx.close()
            browser.close()
            return 2

        ctx.storage_state(path=str(state_file))
        log(f"登录态已保存 → {state_file}")

        # 登录后回到目标页（扫码后通常会跳首页）
        if "psnl_goods_help" not in page.url:
            log("回到包裹助手页")
            page.goto(TARGET_URL, wait_until="domcontentloaded", timeout=60_000)
            page.wait_for_timeout(3000)

        scroll_to_bottom(page)

        stamp = time.strftime("%Y%m%d-%H%M%S")
        html_path = DUMP_DIR / f"{args.account}_{stamp}.html"
        txt_path = DUMP_DIR / f"{args.account}_{stamp}.txt"
        png_path = DUMP_DIR / f"{args.account}_{stamp}.png"

        html_path.write_text(page.content(), encoding="utf-8")
        text = page.inner_text("body")
        txt_path.write_text(text, encoding="utf-8")
        page.screenshot(path=str(png_path), full_page=True)

        log(f"当前 URL: {page.url}")
        log(f"HTML → {html_path}")
        log(f"文本 → {txt_path}")
        log(f"截图 → {png_path}")
        log(f"纯文本长度 {len(text)} 字符")
        log("---- 文本前 800 字 ----")
        print(text[:800])

        # 只打印 Cookie 名与到期时间，不打印值
        log("---- Cookie 概况（不含值）----")
        for c in sorted(ctx.cookies(), key=lambda x: x["name"]):
            exp = c.get("expires", -1)
            exp_s = time.strftime("%Y-%m-%d %H:%M", time.localtime(exp)) if exp and exp > 0 else "会话级"
            log(f"  {c['name']:<24} 域={c['domain']:<28} 到期={exp_s}")

        # 顺手标出疑似取件码片段，方便肉眼确认
        import re
        hits = re.findall(r"\b\d{1,3}-\d{1,3}-\d{2,5}\b", text)
        log(f"---- 疑似取件码（形如 8-3-2015）：{len(hits)} 个 ----")
        for h in sorted(set(hits))[:20]:
            log(f"  {h}")

        ctx.close()
        browser.close()

    log("完成。请把 dump/ 下的 .txt 和截图看一眼，确认有没有取件码。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
