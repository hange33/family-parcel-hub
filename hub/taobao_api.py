#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""淘宝 · 菜鸟驿站取件码（HTTP 直连，逻辑照搬原项目 taobao_connector.dart）

原项目做法：
  GET https://h5api.m.taobao.com/h5/<api>/<v>/
      ?jsv=2.3.18&appKey=12574478&t=<ms>&sign=<md5>&type=jsonp&data=<json>
  sign = md5(token & t & appKey & data)，token 取 Cookie `_m_h5_tk` 的下划线前段
  api  = mtop.cainiao.pickup.plus.queryMultiStaPackages4Xy   （菜鸟多站点包裹列表，直接带取件码）

服务端沿用同一套：用 Playwright 登录一次拿到 Cookie，之后纯 HTTP 调用，不必开页面。
"""

from __future__ import annotations

import hashlib
import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

APP_KEY = "12574478"
API = "mtop.cainiao.pickup.plus.queryMultiStaPackages4Xy"
V = "1.0"
UA = ("Mozilla/5.0 (Linux; Android 14; 25102RKBEC Build/UP1A.231005.007) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36")

CODE_RE = re.compile(r"^\d{1,3}-\d{1,3}-\d{2,5}$")

# 诊断输出：由 run_scrapers 在启动后注入（写 dump/run.log）。
LOGGER = None

# 最近一次调用的结果，供上层判断「0 件」到底是真的没有、还是解析失败
LAST_STATE: dict = {"ret_ok": False, "ret": ""}


def set_logger(fn) -> None:
    global LOGGER
    LOGGER = fn


def _d(msg: str) -> None:
    if LOGGER:
        try:
            LOGGER(msg)
        except Exception:
            pass
CODE_KEYS = ("takeCode", "fetchCode", "pickupCode", "shelfCode", "pickCode",
             "pickupNo", "takeNo", "fetchNo", "codeValue", "pickupCodeText")
MAIL_KEYS = ("mailNo", "waybillNo", "trackingNo", "trackingNumber", "mailno")
STATION_KEYS = ("stationName", "stationTitle", "siteName", "cpName", "storeName")


def strip_jsonp(s: str) -> str:
    s = s.strip()
    i, j = s.find("("), s.rfind(")")
    return s[i + 1:j] if i != -1 and j > i else s


def cookie_token(cookies: str) -> str:
    m = re.search(r"_m_h5_tk=([^;]+)", cookies)
    return m.group(1).split("_")[0] if m else ""


def mtop_call(cookies: str, data: dict, retry: int = 3) -> dict | None:
    """返回解析后的 JSON；令牌过期会自动从 Set-Cookie 取新令牌重试。"""
    data_raw = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
    cur = cookies

    for _ in range(retry):
        token = cookie_token(cur)
        t = str(int(time.time() * 1000))
        sign = hashlib.md5(f"{token}&{t}&{APP_KEY}&{data_raw}".encode()).hexdigest()
        url = (f"https://h5api.m.taobao.com/h5/{API}/{V}/"
               f"?jsv=2.3.18&appKey={APP_KEY}&t={t}&sign={sign}"
               f"&type=jsonp&dataType=jsonp&data={urllib.parse.quote(data_raw)}")
        req = urllib.request.Request(url, headers={
            "User-Agent": UA,
            "Origin": "https://h5.m.taobao.com",
            "Referer": "https://h5.m.taobao.com/",
            "Cookie": cur,
        })
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                body = r.read().decode("utf-8", "ignore")
                set_cookie = r.headers.get_all("Set-Cookie") or []
        except Exception as e:
            _d(f"[taobao] HTTP 失败 {type(e).__name__}: {e}")
            return None

        for sc in set_cookie:
            m = re.search(r"(_m_h5_tk(?:_enc)?)=([^;]+)", sc)
            if not m:
                continue
            cname, cval = m.group(1), m.group(2)
            # ⚠️ _m_h5_tk 与 _m_h5_tk_enc 是**一对**：只换前者，后者还是旧的，
            # 服务端照样判 token 失效（实测 3 轮全 FAIL_SYS_TOKEN 就是这么来的）。
            cur = (re.sub(rf"{cname}=[^;]*", f"{cname}={cval}", cur)
                   if f"{cname}=" in cur else f"{cur}; {cname}={cval}")

        if "FAIL_SYS_TOKEN" in body:
            try:
                j = json.loads(strip_jsonp(body))
                _d(f"[taobao] token 失效：ret={j.get('ret')} api={j.get('api')} "
                   f"v={j.get('v')}")
            except Exception:
                _d(f"[taobao] token 失效（非 JSON）：{body[:120]}")
            continue
        try:
            j = json.loads(strip_jsonp(body))
        except Exception:
            _d(f"[taobao] 响应非 JSON（前 160 字）：{body[:160]}")
            return None
        # MTOP 的 ret 是**数组**：['SUCCESS::调用成功']；直接 str() 会变成 "[SUCCESS..."
        raw = j.get("ret")
        if isinstance(raw, list):
            raw = raw[0] if raw else ""
        ret = str(raw or "")
        LAST_STATE.update(ret_ok=ret.startswith("SUCCESS"), ret=ret)
        _d(f"[taobao] ret={j.get('ret')} 响应 {len(body)} 字 "
           f"data={json.dumps(j.get('data'), ensure_ascii=False)[:260]}")
        return j
    return None


# 键名里出现这些词，就认为这个字段可能是取件码 / 运单号 / 驿站名。
# 目的：接口改字段名时不至于一条都抓不到（已知键优先，键名特征兜底）。
CODE_HINTS = ("code", "取件", "取货", "提货", "pick", "shelf", "fetch", "take")
MAIL_HINTS = ("mail", "waybill", "tracking", "运单", "order", "trade", "物流")
STATION_HINTS = ("station", "site", "store", "驿站", "网点", "自提点", "point")


def _first_by_hint(node: dict, hints: tuple[str, ...], match=None) -> str:
    for k, v in node.items():
        if not isinstance(v, str):
            continue
        if not any(h in str(k).lower() for h in hints):
            continue
        val = v.strip()
        if match and not match(val):
            continue
        if val:
            return val
    return ""


def _walk(node: Any, out: list[dict]) -> None:
    if isinstance(node, dict):
        code = ""
        for k in CODE_KEYS:
            v = node.get(k)
            if isinstance(v, str) and CODE_RE.match(v.strip()):
                code = v.strip()
                break
        if not code:
            code = _first_by_hint(node, CODE_HINTS, lambda v: bool(CODE_RE.match(v)))
        if code:
            mail = ""
            for k in MAIL_KEYS:
                v = node.get(k)
                if isinstance(v, str) and v.strip():
                    mail = v.strip()
                    break
            if not mail:
                mail = _first_by_hint(node, MAIL_HINTS,
                                      lambda v: 10 <= len(v) <= 32 and v.isalnum())
            station = ""
            for k in STATION_KEYS:
                v = node.get(k)
                if isinstance(v, str) and v.strip():
                    station = v.strip()
                    break
            if not station:
                station = _first_by_hint(node, STATION_HINTS,
                                         lambda v: 1 < len(v) < 60)
            out.append({
                "platform": "taobao",
                "pickup_code": code,
                "station": station,
                "tracking": mail,
                "goods": "",
                "status": "arrived",
            })
        for v in node.values():
            _walk(v, out)
    elif isinstance(node, list):
        for v in node:
            _walk(v, out)


def query_pickups(cookies: str, dump_dir=None) -> list[dict]:
    LAST_STATE.update(ret_ok=False, ret="")
    trace = f"{int(time.time() * 1000)}-x{int(time.time() * 1000) % 100000}"
    root = mtop_call(cookies, {
        "stationType": "XY",
        "source": "",
        "traceId": trace,
        "pageNo": 1,
        "pageSize": 30,
    })
    if not root:
        _d("[taobao] 接口无有效响应，按 0 件处理")
        return []
    out: list[dict] = []
    _walk(root, out)
    # 每次成功都留一份原始 data（空的也只有几百字节），只保留最近 10 份。
    # 万一哪天「明明有件却 0 件」，直接看这份 JSON 就知道字段长什么样。
    if dump_dir and LAST_STATE.get("ret_ok"):
        try:
            d = Path(dump_dir)
            d.mkdir(parents=True, exist_ok=True)
            f = d / f"taobao_{time.strftime('%Y%m%d-%H%M%S')}.json"
            f.write_text(json.dumps({"ret": root.get("ret"), "data": root.get("data")},
                                    ensure_ascii=False, indent=1), encoding="utf-8")
            for old_f in sorted(d.glob("taobao_*.json"))[:-10]:
                old_f.unlink(missing_ok=True)
        except Exception:
            pass
    # 去重（同码同单号）
    seen, uniq = set(), []
    for it in out:
        key = (it["pickup_code"], it["tracking"])
        if key in seen:
            continue
        seen.add(key)
        uniq.append(it)
    return uniq


if __name__ == "__main__":
    import sys
    ck = sys.stdin.read().strip()
    print(json.dumps(query_pickups(ck), ensure_ascii=False, indent=2))
