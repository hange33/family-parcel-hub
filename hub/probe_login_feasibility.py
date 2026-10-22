#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探测淘宝/京东在桌面浏览器下的扫码登录可行性（容器内跑，带真实 Playwright）。

要回答三个问题：
  1. 桌面 UA + 桌面视口能不能打开登录页（不被风控拦）
  2. 页面上有没有「扫码登录」入口，能不能点出来
  3. 登录后代码里用来判定的 cookie（taobao: cookie2/unb；jd: pt_key/pt_pin）
     是否真能从登录流程里拿到 —— 这一条最关键，决定「扫码成功」能不能被识别

结果落 dump/probe_<platform>.txt。
"""
from __future__ import annotations

import os
import re
import sys

OUT = "/app/dump/probe_%s.txt"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

TARGETS = {
    "taobao": {
        "url": "https://www.taobao.com/",
        "login": "https://login.taobao.com/",
        "cookies": ["cookie2", "unb", "_m_h5_tk"],
        "qr_selectors": ["text=扫码登录", "#login", ".qrcode", "text=二维码登录",
                         "text=扫码", "iframe"],
    },
    "jd": {
        "url": "https://home.jd.com/",
        "login": "https://passport.jd.com/new/login.aspx",
        "cookies": ["pt_key", "pt_pin", "pt_key_hash"],
        "qr_selectors": ["text=二维码登录", ".QR-img", "#qrcode", "text=扫码",
                         "text=更多登录方式", "iframe"],
    },
}


def find_browser() -> str | None:
    """找可用的 chromium 可执行文件。返回 None 表示交给 Playwright 默认逻辑。"""
    import glob
    import os
    # ⚠️ 必须判「可执行」，Playwright 解包失败会留下空目录，
    # 只看存在会把半成品当成品，最后 launch 报 Executable doesn't exist。
    env = os.getenv("CHROMIUM_PATH")
    if env and os.access(env, os.X_OK):
        return env
    if os.access("/usr/bin/chromium", os.X_OK):
        return "/usr/bin/chromium"
    pats = [
        "/app/.pw-browsers/chromium-*/chrome-linux/chrome",
        "/app/.pw-browsers/chromium_headless_shell-*/chrome-linux/headless_shell",
        "/app/.pw-browsers/chromium-*/chrome-linux/headless_shell",
        "/root/.cache/ms-playwright/chromium-*/chrome-linux/chrome",
        "/root/.cache/ms-playwright/chromium_headless_shell-*/chrome-linux/headless_shell",
    ]
    for pat in pats:
        hits = [p for p in sorted(glob.glob(pat)) if os.access(p, os.X_OK)]
        if hits:
            return hits[-1]
    return None


def probe(platform: str, spec: dict) -> str:
    from playwright.sync_api import sync_playwright
    out = [f"===== {platform} ====="]
    exe = find_browser()
    out.append(f"浏览器: {exe}")

    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(
                headless=True, executable_path=exe,
                args=["--no-sandbox", "--disable-dev-shm-usage",
                      "--disable-blink-features=AutomationControlled"])
            ctx = browser.new_context(
                viewport={"width": 1440, "height": 900},
                user_agent=UA, locale="zh-CN", timezone_id="Asia/Shanghai")
            ctx.add_init_script(
                "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});")
            page = ctx.new_page()

            # 1) 入口页
            try:
                page.goto(spec["url"], wait_until="domcontentloaded", timeout=90_000)
                page.wait_for_timeout(4000)
                out.append(f"入口 {spec['url']} → {page.url[:110]}")
                txt = page.inner_text("body")[:400]
                out.append(f"  页面文字片段: {txt.replace(chr(10), ' | ')[:300]}")
                for w in ("登录", "扫码", "二维码"):
                    out.append(f"  含「{w}」: {w in txt}")
            except Exception as e:
                out.append(f"入口失败: {type(e).__name__}: {e}")

            # 2) 登录页 + 找扫码入口
            try:
                page.goto(spec["login"], wait_until="domcontentloaded", timeout=90_000)
                page.wait_for_timeout(4000)
                out.append(f"登录页 {spec['login']} → {page.url[:110]}")
                html = page.content()
                low = html.lower()
                out.append(f"  页面长度 {len(html)}")
                for kw in ("qrcode", "qr-code", "二维码", "扫码", "qrCode",
                           "errmsg", "风险", "captcha", "滑块"):
                    out.append(f"  HTML 含「{kw}」: {kw.lower() in low}")
                # iframe 里通常嵌二维码
                out.append(f"  iframe 数: {len(page.frames)}")
                for fr in page.frames:
                    try:
                        ftxt = fr.inner_text("body")[:200].replace(chr(10), " | ")
                        out.append(f"    frame {fr.url[:70]}: {ftxt}")
                    except Exception:
                        pass
                # 尝试点扫码
                for sel in spec["qr_selectors"]:
                    try:
                        loc = page.locator(sel).first
                        if loc.count() > 0:
                            out.append(f"  找到可点元素 {sel}")
                    except Exception:
                        continue
            except Exception as e:
                out.append(f"登录页失败: {type(e).__name__}: {e}")

            # 3) 当前 cookie 情况（未登录时应为空）
            names = sorted({c["name"] for c in ctx.cookies()})
            out.append(f"  当前 cookie 名: {names[:30]}")
            for c in spec["cookies"]:
                out.append(f"  判定 cookie「{c}」: {'有' if c in names else '无'}")

            # 截图存证
            try:
                page.screenshot(path=f"/app/dump/probe_{platform}.png", full_page=False)
                out.append(f"  截图: /app/dump/probe_{platform}.png")
            except Exception:
                pass

            browser.close()
    except Exception as e:
        out.append(f"整体失败: {type(e).__name__}: {e}")
    return "\n".join(out)


if __name__ == "__main__":
    want = sys.argv[1:] or list(TARGETS)
    for p in want:
        txt = probe(p, TARGETS[p])
        print(txt, flush=True)
        try:
            with open(OUT % p, "w", encoding="utf-8") as f:
                f.write(txt)
        except Exception:
            pass