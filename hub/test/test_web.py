#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Web 端联调测试：起一个假 scrapers + 真 hub，验证页面与接口全链路。

覆盖：
  1. GET /                返回页面（HTML，含关键元素）
  2. GET /api/v1/all      全量列表
  3. GET /api/v1/devices  账号信息
  4. POST /api/v1/pick_key      手动标记已取
  5. POST /api/v1/unpick        撤销已取
  6. GET /api/v1/scan/accounts  账号绑定列表（转发 scrapers）
  7. POST /api/v1/scan/start    触发扫码（转发 scrapers）
  8. GET /api/v1/scan/status    扫码状态（转发 scrapers）
  9. 未带 token → 401
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
HUB_PORT = 18792
FAKE_PORT = 18793
BASE = f"http://127.0.0.1:{HUB_PORT}"
TOKEN = "test-token-123"

FAILURES: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(f"  [{'PASS' if cond else 'FAIL'}] {msg}")
    if not cond:
        FAILURES.append(msg)


def call(path: str, body=None, method=None, token=TOKEN, raw=False):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 method=method or ("POST" if data else "GET"),
                                 headers={"Content-Type": "application/json",
                                          **({"X-Hub-Token": token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            body_bytes = r.read()
            if raw:
                return r.status, body_bytes
            return r.status, json.loads(body_bytes.decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, (e.read().decode("utf-8", "replace") if raw else {})


# ---------------------------------------------------------------- 假 scrapers
class FakeScrapers(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _j(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/accounts":
            self._j(200, {"ok": True, "accounts": [
                {"account": "wo", "label": "我", "platform": "pdd", "display": "拼多多",
                 "bound": True, "bound_at": "2026-10-20 19:40"},
                {"account": "wo", "label": "我", "platform": "taobao", "display": "淘宝",
                 "bound": False, "bound_at": ""},
            ]})
            return
        if path == "/api/login/status":
            self._j(200, {"ok": True, "task": {"state": "waiting", "message": "等待扫码",
                                               "qr": "wo_pdd.png",
                                               "url": "https://pdd.example.com/qr/wo_pdd.png?t=abc"}})
            return
        if path.startswith("/qr/"):
            b = b"\x89PNG\r\n\x1a\n" + b"0" * 32
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        self._j(404, {"ok": False})

    def do_POST(self):
        if self.path.split("?")[0] == "/api/login/start":
            self._j(200, {"ok": True, "task": {"state": "running", "account": "wo",
                                               "platform": "pdd"}})
            return
        self._j(404, {"ok": False})


def main() -> int:
    tmp = HERE / "data" / "_webtest"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)

    fake = ThreadingHTTPServer(("127.0.0.1", FAKE_PORT), FakeScrapers)
    import threading
    threading.Thread(target=fake.serve_forever, daemon=True).start()

    cfg = {
        "dry_run": True,
        "token": TOKEN,
        "owners": {"wo": "我"},
        "qq_bridge": {"url": "", "token": "", "target": "group"},
        "summary_at": "17:00",
        "scrapers": {"url": f"http://127.0.0.1:{FAKE_PORT}", "qr_token": "abc"},
    }
    cfg_path = tmp / "config.json"
    cfg_path.write_text(json.dumps(cfg, ensure_ascii=False), encoding="utf-8")

    env = dict(os.environ, HUB_DRY_RUN="true")
    proc = subprocess.Popen(
        [sys.executable, str(HERE / "app.py"), "--port", str(HUB_PORT),
         "--db", str(tmp / "t.sqlite"), "--config", str(cfg_path)],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        for _ in range(40):
            try:
                call("/health", token="")
                break
            except Exception:
                time.sleep(0.3)
        else:
            print("hub 未就绪")
            return 1

        # 先造点数据
        call("/api/v1/report", {
            "device": "wo", "snapshot": True, "platforms": ["pdd"],
            "packages": [
                {"platform": "pdd", "order_id": "SF111", "tracking": "SF111",
                 "pickup_code": "1-1-1111", "station": "示例小区1栋101",
                 "goods": "牛奶", "courier": "顺丰", "status": "arrived"},
            ]})

        print("\n--- 1) 首页可访问 ---")
        st, body = call("/", raw=True, token="")
        html = body.decode("utf-8", "replace")
        check(st == 200, f"GET / 返回 200（实际 {st}）")
        check("取件码" in html, "页面含标题")
        check("标记已取" in html, "页面含「标记已取」按钮")
        check("账号绑定" in html, "页面含「账号绑定」页签")

        print("\n--- 2) 全量列表 ---")
        st, j = call("/api/v1/all")
        check(st == 200 and len(j.get("items", [])) >= 1, f"全量列表有数据（{st}）")

        print("\n--- 3) 账号信息 ---")
        st, j = call("/api/v1/devices")
        check(st == 200 and j.get("devices"), f"设备列表非空（{st}）")
        if j.get("devices"):
            d = j["devices"][0]
            check("last_seen" in d and "arrived" in d, f"设备含上报时间与计数（{d}）")

        print("\n--- 4) 手动标记已取 ---")
        st, j = call("/api/v1/list")
        item = j["items"][0]
        st, j = call("/api/v1/pick_key", {"key": item["hub_key"]})
        check(st == 200 and j.get("ok"), f"标记成功（{st} {j}）")
        st, j = call("/api/v1/list")
        check(len(j["items"]) == 0, f"已从未取清单移除（剩 {len(j['items'])}）")
        st, j = call("/api/v1/all")
        picked = [i for i in j["items"] if i["status"] == "picked"]
        check(len(picked) == 1, f"状态变为 picked（{len(picked)}）")

        print("\n--- 5) 撤销已取 ---")
        st, j = call("/api/v1/unpick", {"key": item["hub_key"]})
        check(st == 200 and j.get("ok"), f"撤销成功（{st}）")
        st, j = call("/api/v1/list")
        check(len(j["items"]) == 1, f"回到未取清单（{len(j['items'])}）")

        print("\n--- 6) 账号绑定列表（转发 scrapers） ---")
        st, j = call("/api/v1/scan/accounts")
        check(st == 200 and len(j.get("accounts", [])) == 2, f"拿到 2 个账号位（{st}）")
        check(j.get("qr_token") == "abc", f"带出 qr_token（{j.get('qr_token')}）")
        if j.get("accounts"):
            a = j["accounts"][0]
            check(all(k in a for k in ("account", "platform", "bound", "display")),
                  f"账号项字段完整（{a}）")

        print("\n--- 7) 触发扫码 ---")
        st, j = call("/api/v1/scan/start", {"account": "wo", "platform": "pdd"})
        check(st == 200 and j.get("ok"), f"触发成功（{st} {j}）")

        print("\n--- 8) 扫码状态 ---")
        st, j = call("/api/v1/scan/status?account=wo&platform=pdd")
        check(st == 200 and j.get("task", {}).get("state") == "waiting",
              f"状态为 waiting（{j}）")

        print("\n--- 9) 二维码代理 ---")
        st, body = call("/qr/wo_pdd.png?t=abc", raw=True, token="")
        check(st == 200 and body[:4] == b"\x89PNG", f"二维码代理返回 PNG（{st}）")

        print("\n--- 10) 鉴权：缺 token 应 401 ---")
        st, _ = call("/api/v1/all", token="")
        check(st == 401, f"无 token 返回 401（实际 {st}）")
        st, _ = call("/api/v1/all", token="wrong")
        check(st == 401, f"错 token 返回 401（实际 {st}）")

        time.sleep(0.4)
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            out = proc.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            proc.kill()
            out = proc.communicate()[0]
        print("\n--- hub 输出 ---")
        print(out[-1500:])
        fake.shutdown()

    shutil.rmtree(tmp, ignore_errors=True)
    print("=" * 60)
    if FAILURES:
        print(f"失败 {len(FAILURES)} 项：")
        for f in FAILURES:
            print("  -", f)
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
