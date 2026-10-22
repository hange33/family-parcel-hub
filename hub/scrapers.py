#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""三家平台的抓取器（Playwright，服务端常驻）

统一约定：
  - 每个账号 + 平台一份登录态：state/<account>_<platform>.json
  - 登录态判定只看关键 Cookie，不猜页面
  - 未登录：打开登录页 → 截图 → 通过 qq-bridge 推一条带链接的消息
  - 抓到的页面原文一律落盘到 dump/，改解析不用重新部署

平台现状：
  PDD     ✅ 已验证（桌面 UA + 包裹助手页，解析器见 parsers/pdd.py）
  淘宝    ⚠️ 待验证页面结构（先 dump，再写解析）
  京东    ⚠️ 待验证页面结构（先 dump，再写解析）
"""

from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from playwright.sync_api import BrowserContext, Page, sync_playwright

UA_DESKTOP = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

# Playwright 自带浏览器的可能位置（挂载卷优先，其次默认缓存目录）
_PW_BROWSER_GLOBS = (
    "/app/.pw-browsers/chromium-*/chrome-linux/chrome",
    "/app/.pw-browsers/chromium-*/chrome-linux/headless_shell",
    "/root/.cache/ms-playwright/chromium-*/chrome-linux/chrome",
    "/root/.cache/ms-playwright/chromium_headless_shell-*/chrome-linux/headless_shell",
)


def _find_pw_browser() -> str | None:
    """找 Playwright 自带浏览器的可执行文件；找不到返回 None（走 Playwright 默认）。"""
    import glob
    for pat in _PW_BROWSER_GLOBS:
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[-1]
    return None


def atomic_write(path: Path, data: bytes) -> None:
    """原子写文件：先写 .tmp 再 replace。

    `/qr/<name>.png` 是边写边被浏览器读的：直接 write_bytes 会让请求恰好在写一半时
    拿到截断的 PNG，浏览器解码失败 → 画面空白，用户看到的就是「二维码消失了一会儿」。
    """
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


# 在页面（含 iframe）里找二维码：接近正方形、尺寸 80~460、带 qr/code/canvas/img 特征。
# 登录页整页截图缩到 220px 宽后二维码只剩几十像素，扫码枪都读不出来，必须裁出来。
_QR_FIND_JS = r"""
() => {
  const out = [];
  for (const el of document.querySelectorAll('img,canvas,svg,div,p')) {
    const r = el.getBoundingClientRect();
    const w = r.width, h = r.height;
    if (w < 80 || h < 80 || w > 460 || h > 460) continue;
    if (Math.abs(w - h) > Math.min(40, w * 0.25)) continue;
    const st = getComputedStyle(el);
    if (st.visibility === 'hidden' || st.display === 'none' || Number(st.opacity) === 0) continue;
    const hint = (el.tagName + ' ' + (el.id || '') + ' ' + (el.getAttribute('class') || '')
                  + ' ' + (el.getAttribute('src') || '')).toLowerCase();
    if (!/qr|code|canvas|img/.test(hint)) continue;
    let score = w * h;
    if (/qr|code/.test(hint)) score *= 2;
    out.push({x: r.left + scrollX, y: r.top + scrollY, w: w, h: h,
              score: score, hint: hint.slice(0, 60)});
  }
  out.sort((a, b) => b.score - a.score);
  return out.slice(0, 3);
}
"""

# 登录判定：(必须同时存在的 cookie 名) —— 任一组合成立即视为已登录
LOGIN_COOKIES = {
    "pdd": [["pdd_user_id"], ["PDDAccessToken"]],
    "taobao": [["cookie2", "unb"]],
    "jd": [["pt_key", "pt_pin"]],
}

ENTRY_URLS = {
    "pdd": "https://mobile.pinduoduo.com/psnl_goods_help.html?_t_module_name=assistant_search",
    "taobao": "https://www.taobao.com/",
    "jd": "https://home.jd.com/",
}

# 扫码登录页 ≠ 入口页。
# 淘宝的二维码在 login.taobao.com 的登录 iframe 里，首页 www.taobao.com 只有
# 「亲，请登录」文字（2026-10-21 实测截图确认）：直接截首页会得到电脑版首页，
# 用户看不到任何二维码。京东 home.jd.com 会 302 到 passport，可沿用入口页。
LOGIN_URLS = {
    "taobao": "https://login.taobao.com/",
}


@dataclass
class ScrapeResult:
    platform: str
    logged_in: bool
    packages: list[dict]
    text: str
    url: str
    # 快照是否「权威」：True 表示拿到了完整结构化列表，
    # 可以放心用「本次没出现」去判定某件已不在列表里。
    # False 表示只是尽力而为的文本匹配——若此时结果为 0 件，
    # 更可能是解析失败而非真的没有包裹，不能据此把老件标 stale。
    authoritative: bool = False


class Scraper:
    platform = ""
    display = ""

    def __init__(self, account: str, state_dir: Path, dump_dir: Path):
        self.account = account
        self.state_dir = state_dir
        self.dump_dir = dump_dir
        self.state_file = state_dir / f"{account}_{self.platform}.json"

    # ---------------------------------------------------------------- 会话
    def is_logged_in(self, ctx: BrowserContext) -> bool:
        names = {c["name"] for c in ctx.cookies()}
        return any(all(n in names for n in group) for group in LOGIN_COOKIES[self.platform])

    def open_context(self, pw, headless: bool = True) -> BrowserContext:
        # 浏览器可执行文件优先级：
        #   1) CHROMIUM_PATH 环境变量（系统 chromium）
        #   2) Playwright 自带浏览器（装在挂载卷 /app/.pw-browsers，容器重建也不丢）
        #   3) Playwright 默认（自带的 ~/.cache/ms-playwright）
        # 早先只认环境变量，容器重建后系统 chromium 没了就直接起不来。
        exe = os.getenv("CHROMIUM_PATH") or None
        if exe and not os.path.exists(exe):
            exe = None
        if not exe:
            exe = _find_pw_browser()
        browser = pw.chromium.launch(
            headless=headless,
            executable_path=exe,
            args=[
                "--no-sandbox",
                "--disable-dev-shm-usage",
                # 去掉最常见的自动化特征，否则拼多多二维码接口会直接返回失败
                "--disable-blink-features=AutomationControlled",
            ],
        )
        kwargs = {
            "viewport": {"width": 1440, "height": 900},
            "user_agent": UA_DESKTOP,
            "locale": "zh-CN",
            "timezone_id": "Asia/Shanghai",
        }
        if self.state_file.exists():
            kwargs["storage_state"] = str(self.state_file)
        ctx = browser.new_context(**kwargs)
        ctx.add_init_script(
            "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});"
        )
        ctx._own_browser = browser  # 便于统一关闭
        return ctx

    def save_state(self, ctx: BrowserContext) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        ctx.storage_state(path=str(self.state_file))

    # ---------------------------------------------------------------- 抓取主流程
    def scrape(self, ctx: BrowserContext) -> ScrapeResult:
        """抓取 + 解析。首次加载慢或网络抖动时重试一次。

        重试的理由：容器里 chromium 刚起或页面偶发慢，一次超时就丢掉
        整轮（30 分钟一轮，丢一轮就是半小时盲区）。
        """
        last_exc: Exception | None = None
        for attempt in range(2):
            try:
                return self._scrape_once(ctx)
            except Exception as exc:
                last_exc = exc
                if attempt == 0:
                    time.sleep(5)
        raise last_exc if last_exc else RuntimeError("scrape 失败")

    def _scrape_once(self, ctx: BrowserContext) -> ScrapeResult:
        page = ctx.new_page()
        url = ENTRY_URLS[self.platform]
        page.goto(url, wait_until="domcontentloaded", timeout=120_000)
        page.wait_for_timeout(4000)

        if not self.is_logged_in(ctx):
            return ScrapeResult(self.platform, False, [], "", page.url)

        page = self.navigate_to_list(page)
        self.soft_scroll(page)
        text = page.inner_text("body")
        html = page.content()
        self.dump(page, text, html)
        packages = self.parse(text, html)
        # 「权威」= 拿到了结构化完整列表（rawData），此时 0 件也是可信事实。
        authoritative = self._is_authoritative(html, packages)
        return ScrapeResult(self.platform, True, packages, text, page.url, authoritative)

    def _is_authoritative(self, html: str, packages: list[dict]) -> bool:
        """判断本次快照是否可信（可用于判定「某件已不在列表里」）。"""
        return False

    def navigate_to_list(self, page: Page) -> Page:
        """默认：入口页就是列表页。子类可覆盖。"""
        return page

    def soft_scroll(self, page: Page, rounds: int = 8) -> None:
        last = 0
        for _ in range(rounds):
            h = page.evaluate("document.body.scrollHeight")
            page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            page.wait_for_timeout(1000)
            if h == last:
                break
            last = h

    def dump(self, page: Page, text: str, html: str = "") -> None:
        self.dump_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        base = f"{self.account}_{self.platform}_{stamp}"
        (self.dump_dir / f"{base}.txt").write_text(text, encoding="utf-8")
        if html:
            (self.dump_dir / f"{base}.html").write_text(html, encoding="utf-8")
        # 截图用视口而非全页：包裹列表在页面顶部，排查足够；
        # 全页截图 28MB/张，dump/ 每天涨 1.3GB，会把 NAS 撑爆。
        try:
            page.screenshot(path=str(self.dump_dir / f"{base}.png"), full_page=False)
        except Exception:
            pass
        self.prune_dumps()

    def prune_dumps(self, keep_days: int = 3, keep_rounds: int = 60) -> None:
        """清理历史 dump。

        必须做：全页截图单张 28MB，每 30 分钟一轮 ≈ 1.3GB/天，
        而 dump/ 在 WebDAV 共享目录里，不清理会把 NAS 撑爆。
        策略：只保留最近 keep_rounds 轮，且不超过 keep_days 天。
        """
        try:
            files = [p for p in self.dump_dir.glob(f"{self.account}_{self.platform}_*")
                     if p.suffix in (".txt", ".html", ".png")]
        except Exception:
            return
        if not files:
            return
        by_round: dict[str, list] = {}
        for p in files:
            by_round.setdefault(p.stem.rsplit("_", 1)[-1], []).append(p)
        rounds = sorted(by_round.keys())
        expired = set(rounds[:-keep_rounds]) if len(rounds) > keep_rounds else set()
        cutoff = time.time() - keep_days * 86400
        for rnd, group in by_round.items():
            for p in group:
                if rnd in expired:
                    try:
                        p.unlink()
                    except OSError:
                        pass
                    continue
                try:
                    if p.stat().st_mtime < cutoff:
                        p.unlink()
                except OSError:
                    pass

    def parse(self, text: str, html: str = "") -> list[dict]:
        return []

    # ---------------------------------------------------------------- 登录
    _login_page = None

    def _qr_clip(self, page: Page) -> dict | None:
        """算出二维码在页面里的裁剪框（含 iframe 偏移）；找不到就返回 None。"""
        best = None
        for frame in page.frames:
            try:
                cands = frame.evaluate(_QR_FIND_JS)
            except Exception:
                continue
            if not cands:
                continue
            c = dict(cands[0])
            if frame != page.main_frame:
                # 子 frame 的坐标是 frame 内的，得加上 iframe 在父页面的位置
                try:
                    box = frame.frame_element().bounding_box()
                except Exception:
                    box = None
                if not box:
                    continue
                c = dict(c, x=c["x"] + box["x"], y=c["y"] + box["y"])
            if best is None or c["score"] > best["score"]:
                best = c
        if not best:
            return None
        vp = page.viewport_size or {"width": 1440, "height": 900}
        pad = 14
        x = max(0.0, best["x"] - pad)
        y = max(0.0, best["y"] - pad)
        w = max(60.0, min(vp["width"] - x, best["w"] + pad * 2))
        h = max(60.0, min(vp["height"] - y, best["h"] + pad * 2))
        return {"x": x, "y": y, "width": w, "height": h}

    def _shot(self, page: Page) -> bytes:
        """优先截二维码区域，失败再退回整页（整页缩到 220px 基本没法扫）。"""
        clip = None
        try:
            clip = self._qr_clip(page)
        except Exception:
            clip = None
        if clip:
            try:
                return page.screenshot(clip=clip)
            except Exception:
                pass
        return page.screenshot(full_page=False)

    def login_qr(self, ctx: BrowserContext) -> bytes:
        """打开登录页 → 切到扫码登录 → 截图（先给一版，后续会持续刷新）。"""
        page = ctx.new_page()
        url = LOGIN_URLS.get(self.platform, ENTRY_URLS[self.platform])
        page.goto(url, wait_until="domcontentloaded", timeout=120_000)
        page.wait_for_timeout(4000)

        # 淘宝兜底：login.taobao.com 偶尔会被打回首页，而首页只有「亲，请登录」，
        # 直接截首页等于给用户一张电脑版首页（2026-10-21 用户实测反馈）。
        if self.platform == "taobao":
            try:
                txt = page.inner_text("body")
            except Exception:
                txt = ""
            if "扫码" not in txt and ("请登录" in txt or "免费注册" in txt):
                for sel in ("text=亲，请登录", "text=登录"):
                    try:
                        loc = page.locator(sel).first
                        if loc.count() > 0:
                            loc.click(timeout=3000)
                            page.wait_for_timeout(3500)
                            break
                    except Exception:
                        continue

        # 拼多多等平台默认给「手机登录/扫码登录」两个按钮，必须点扫码才会出二维码
        for sel in ("text=扫码登录", "text=扫码", "text=二维码登录"):
            try:
                loc = page.locator(sel).first
                if loc.count() > 0:
                    loc.click(timeout=3000)
                    page.wait_for_timeout(2000)
                    break
            except Exception:
                continue

        self._login_page = page
        return self._shot(page)

    @staticmethod
    def _refresh_qr_if_needed(page: Page) -> None:
        """拼多多二维码会过期或加载失败，出现提示时自动点「刷新」。"""
        try:
            txt = page.inner_text("body")
        except Exception:
            return
        if not any(w in txt for w in ("加载失败", "已失效", "二维码失效")):
            return
        for sel in ("text=刷新", "text=点击刷新", "text=重新获取"):
            try:
                loc = page.locator(sel).first
                if loc.count() > 0:
                    loc.click(timeout=2500)
                    page.wait_for_timeout(1800)
                    return
            except Exception:
                continue

    def wait_login(self, ctx: BrowserContext, page: Page, png_path: Path,
                   timeout: int = 300, interval: int = 15,
                   should_stop: Callable[[], bool] | None = None,
                   on_tick: Callable | None = None) -> bool:
        """保持登录页打开，定期刷新二维码截图，直到登录成功或超时。

        这样做是因为二维码会过期：用户扫的时候必须看到「当前有效」的那一版。
        should_stop：被新的「绑定」点击顶掉时返回 True，这里立刻退出（浏览器由调用方关）。
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(interval)
            if should_stop and should_stop():
                return False
            self._refresh_qr_if_needed(page)
            try:
                atomic_write(png_path, self._shot(page))
            except Exception:
                pass
            if on_tick:
                try:
                    on_tick(ctx, page)
                except Exception:
                    pass
            if self.is_logged_in(ctx):
                try:
                    atomic_write(png_path, self._shot(page))
                except Exception:
                    pass
                return True
        return False


# ---------------------------------------------------------------- PDD
class PddScraper(Scraper):
    platform = "pdd"
    display = "拼多多"

    def parse(self, text: str, html: str = "") -> list[dict]:
        from parsers.pdd import parse_page  # 延迟导入，便于单测
        return parse_page(text, html)

    def _is_authoritative(self, html: str, packages: list[dict]) -> bool:
        """页面内嵌 rawData 且「我的收件」确实渲染出来，才算权威快照。

        以前要求「list 非空」才算权威，导致包裹全部取走后永远判非权威，
        自动已取逻辑对拼多多失效。现在补一条：expressListData 存在且页面
        明确显示「暂无全部的包裹」，同样视为权威（空 = 真的没有）。
        """
        from parsers.pdd import _iter_express_items, extract_raw_data
        raw = extract_raw_data(html) if html else None
        if not raw:
            return False
        if _iter_express_items(raw):
            return True
        store = (raw or {}).get("store") or {}
        return (isinstance(store.get("expressListData"), (dict, list))
                and "暂无全部的包裹" in (html or ""))


# ---------------------------------------------------------------- 淘宝
class TaobaoScraper(Scraper):
    platform = "taobao"
    display = "淘宝"

    def scrape(self, ctx: BrowserContext) -> ScrapeResult:
        """淘宝走接口，不开页面：用登录态直接调菜鸟驿站多站点包裹列表。"""
        if not self.is_logged_in(ctx):
            return ScrapeResult(self.platform, False, [], "", ENTRY_URLS[self.platform])
        # 只带淘宝系的 cookie，并按名字去重（同名取后写入的）。
        # 直接把 ctx.cookies() 全拼上会出现同名不同域的多份，服务端可能取到旧值。
        jar: dict[str, str] = {}
        for c in ctx.cookies():
            dom = c.get("domain") or ""
            if not any(dom.endswith(d) for d in ("taobao.com", "tmall.com", "alicdn.com")):
                continue
            jar[c["name"]] = c["value"]
        cookies = "; ".join(f"{k}={v}" for k, v in jar.items())
        from taobao_api import LAST_STATE, query_pickups
        pkgs = query_pickups(cookies, self.dump_dir)
        # 接口 SUCCESS 时，「0 件」是可信事实（而不是解析失败），
        # 只有此时才允许用「本次没出现」去推进/失效老件。
        return ScrapeResult(self.platform, True, pkgs, "",
                            ENTRY_URLS[self.platform],
                            authoritative=bool(LAST_STATE.get("ret_ok")))

    ORDER_URLS = [
        "https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm",
        "https://www.taobao.com/",
    ]

    def navigate_to_list(self, page: Page) -> Page:
        for url in self.ORDER_URLS:
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=120_000)
                page.wait_for_timeout(3000)
                txt = page.inner_text("body")
                if "订单" in txt or "待收货" in txt or "取件" in txt:
                    return page
            except Exception:
                continue
        return page

    def parse(self, text: str, html: str = "") -> list[dict]:
        # 页面结构未验证前，只做「有取件码就报」的保守解析，避免误报
        from parsers.generic import parse_labeled_codes
        return parse_labeled_codes(text, platform="taobao")


# ---------------------------------------------------------------- 京东
class JdScraper(Scraper):
    platform = "jd"
    display = "京东"

    def scrape(self, ctx: BrowserContext) -> ScrapeResult:
        """京东：打开订单页，监听 orderList 响应，按原项目规则解析。"""
        if not self.is_logged_in(ctx):
            return ScrapeResult(self.platform, False, [], "", ENTRY_URLS[self.platform])

        page = ctx.new_page()
        captured: list[str] = []

        def on_response(resp):
            try:
                url = resp.url.lower()
                if "orderlist" not in url and "order/list" not in url:
                    return
                txt = resp.text()
                if "orderList" in txt and len(txt) > 200:
                    captured.append(txt)
            except Exception:
                pass

        page.on("response", on_response)
        try:
            page.goto("https://trade.m.jd.com/order/orderlist_jdm.shtml",
                      wait_until="domcontentloaded", timeout=120_000)
            page.wait_for_timeout(5000)
            self.soft_scroll(page, rounds=4)
            page.wait_for_timeout(2000)
        except Exception:
            pass

        if not captured:
            self.dump(page, page.inner_text("body") if page else "")
            return ScrapeResult(self.platform, True, [], "", page.url)

        from jd_api import parse_order_list
        pkgs = parse_order_list(max(captured, key=len))
        return ScrapeResult(self.platform, True, pkgs, "", page.url)

    ORDER_URLS = [
        "https://order.jd.com/center/list.action",
        "https://home.jd.com/",
    ]

    def navigate_to_list(self, page: Page) -> Page:
        for url in self.ORDER_URLS:
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=120_000)
                page.wait_for_timeout(3000)
                txt = page.inner_text("body")
                if "订单" in txt or "待收货" in txt:
                    return page
            except Exception:
                continue
        return page

    def parse(self, text: str, html: str = "") -> list[dict]:
        from parsers.generic import parse_labeled_codes
        return parse_labeled_codes(text, platform="jd")


SCRAPERS: dict[str, type[Scraper]] = {
    "pdd": PddScraper,
    "taobao": TaobaoScraper,
    "jd": JdScraper,
}
