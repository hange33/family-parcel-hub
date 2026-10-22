#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Web 端「新增账号」功能测试。

验证：hub 的 /api/v1/accounts/{add,remove} 能正确转发到 scrapers、
同步 owners 映射、并把账号写回 config.json（真的落盘，不是只在内存里）。
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
HUB_PORT = 18794
FAKE_PORT = 18795
BASE = f"http://127.0.0.1:{HUB_PORT}"
TOKEN = "acct-test-token"

FAILURES: list[str] = []


def check(cond, msg):
    print(f"  [{'PASS' if cond else 'FAIL'}] {msg}")
    if not cond:
        FAILURES.append(msg)


def call(path, body=None, token=TOKEN):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 method="POST" if data is not None else "GET",
                                 headers={"Content-Type": "application/json",
                                          **({"X-Hub-Token": token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8"))
        except Exception:
            return e.code, {}


# 假 scrapers：把账号变更落到本临时 JSON，模拟真实落盘
class FakeScrapers(BaseHTTPRequestHandler):
    store = None  # 指向临时 config 路径

    def log_message(self, *a):
        pass

    def _j(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _read(self):
        return json.loads(Path(self.store).read_text(encoding="utf-8"))

    def _write(self, d):
        Path(self.store).write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")

    def do_GET(self):
        if self.path.split("?")[0] == "/api/accounts":
            cfg = self._read()
            out = []
            for a in cfg["accounts"]:
                for p in cfg.get("platforms", []):
                    out.append({"account": a["id"], "label": a["label"], "platform": p,
                                "display": p, "bound": False, "bound_at": ""})
            self._j(200, {"ok": True, "accounts": out})
            return
        self._j(404, {"ok": False})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n).decode()) if n else {}
        p = self.path.split("?")[0]
        cfg = self._read()
        if p == "/api/accounts/add":
            aid = (body.get("id") or "").strip().lower()
            if not aid:
                return self._j(400, {"ok": False, "error": "id 不能为空"})
            if any(a["id"] == aid for a in cfg["accounts"]):
                return self._j(200, {"ok": False, "error": f"账号 {aid} 已存在"})
            cfg["accounts"].append({"id": aid, "label": body.get("label") or aid})
            self._write(cfg)
            return self._j(200, {"ok": True, "account": cfg["accounts"][-1]})
        if p == "/api/accounts/remove":
            aid = body.get("id") or ""
            if len(cfg["accounts"]) <= 1:
                return self._j(200, {"ok": False, "error": "至少要保留一个账号"})
            cfg["accounts"] = [a for a in cfg["accounts"] if a["id"] != aid]
            self._write(cfg)
            return self._j(200, {"ok": True, "removed": aid})
        self._j(404, {"ok": False})


def main() -> int:
    tmp = HERE / "data" / "_accttest"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)

    scraper_cfg = tmp / "scraper.json"
    scraper_cfg.write_text(json.dumps(
        {"accounts": [{"id": "wo", "label": "我"}], "platforms": ["pdd"]},
        ensure_ascii=False), encoding="utf-8")

    FakeScrapers.store = str(scraper_cfg)
    fake = ThreadingHTTPServer(("127.0.0.1", FAKE_PORT), FakeScrapers)
    threading.Thread(target=fake.serve_forever, daemon=True).start()

    hub_cfg = tmp / "hub.json"
    hub_cfg.write_text(json.dumps({
        "dry_run": True, "token": TOKEN,
        "owners": {"wo": "我"},
        "qq_bridge": {"url": "", "token": "", "target": "group"},
        "summary_at": "17:00",
        "scrapers": {"url": f"http://127.0.0.1:{FAKE_PORT}", "qr_token": ""},
    }, ensure_ascii=False), encoding="utf-8")

    env = dict(os.environ, HUB_DRY_RUN="true")
    proc = subprocess.Popen(
        [sys.executable, str(HERE / "app.py"), "--port", str(HUB_PORT),
         "--db", str(tmp / "t.sqlite"), "--config", str(hub_cfg)],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
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

        print("\n--- 1) 新增账号 ---")
        st, j = call("/api/v1/accounts/add", {"id": "ta", "label": "对象"})
        check(st == 200 and j.get("ok"), f"添加成功（{st} {j}）")
        check(j.get("account", {}).get("id") == "ta", "返回的账号 id 正确")

        print("\n--- 2) scrapers 侧真的落盘了吗 ---")
        on_disk = json.loads(scraper_cfg.read_text(encoding="utf-8"))["accounts"]
        check(any(a["id"] == "ta" for a in on_disk), f"config.json 已写入（{[a['id'] for a in on_disk]}）")

        print("\n--- 3) hub 的 owners 映射同步了吗 ---")
        hub_owners = json.loads(hub_cfg.read_text(encoding="utf-8"))["owners"]
        check(hub_owners.get("ta") == "对象", f"owners 已落盘（{hub_owners}）")

        print("\n--- 4) 重复添加应被拒 ---")
        st, j = call("/api/v1/accounts/add", {"id": "ta", "label": "对象"})
        check(not j.get("ok"), f"重复添加返回失败（{j}）")

        print("\n--- 5) 非法 id 应被 hub 侧拦下 ---")
        st, j = call("/api/v1/accounts/add", {"id": "带空格", "label": "x"})
        check(not j.get("ok"), f"非法 id 被拒（{j}）")
        st, j = call("/api/v1/accounts/add", {"id": "", "label": "x"})
        check(not j.get("ok"), f"空 id 被拒（{j}）")
        st, j = call("/api/v1/accounts/add", {"id": "A" * 20, "label": "x"})
        check(not j.get("ok"), f"超长 id 被拒（{j}）")
        # 关键：非法 id 绝不能进 owners（那是推送里显示名字的依据）
        hub_owners = json.loads(hub_cfg.read_text(encoding="utf-8"))["owners"]
        check(set(hub_owners) == {"wo", "ta"},
              f"owners 未被非法 id 污染（{hub_owners}）")

        print("\n--- 6) 账号列表能看到新账号 ---")
        st, j = call("/api/v1/scan/accounts")
        accs = j.get("accounts", [])
        check(any(a["account"] == "ta" for a in accs), f"列表含新账号（{[a['account'] for a in accs]}）")

        print("\n--- 7) 删除账号 ---")
        st, j = call("/api/v1/accounts/remove", {"id": "ta"})
        check(st == 200 and j.get("ok"), f"删除成功（{j}）")
        on_disk = json.loads(scraper_cfg.read_text(encoding="utf-8"))["accounts"]
        check(not any(a["id"] == "ta" for a in on_disk), f"scraper 配置已移除（{[a['id'] for a in on_disk]}）")
        hub_owners = json.loads(hub_cfg.read_text(encoding="utf-8"))["owners"]
        check("ta" not in hub_owners, f"hub owners 已移除（{hub_owners}）")

        print("\n--- 8) 最后一个账号不许删 ---")
        st, j = call("/api/v1/accounts/remove", {"id": "wo"})
        check(not j.get("ok"), f"保留最后账号（{j}）")
        hub_owners = json.loads(hub_cfg.read_text(encoding="utf-8"))["owners"]
        check("wo" in hub_owners, f"owners 里 wo 还在（{hub_owners}）")

        print("\n--- 9) 未授权应 401 ---")
        st, _ = call("/api/v1/accounts/add", {"id": "x"}, token="")
        check(st == 401, f"无 token 返回 401（实际 {st}）")

        print("\n--- 10) 页面含新增账号表单 ---")
        req = urllib.request.Request(BASE + "/")
        with urllib.request.urlopen(req, timeout=10) as r:
            html = r.read().decode("utf-8")
        check("新增账号" in html, "页面有「新增账号」卡片")
        check("addAccount" in html, "页面有 addAccount 函数")
        check("delAccount" in html, "页面有 delAccount 函数")

        time.sleep(0.4)
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            out = proc.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            proc.kill()
            out = proc.communicate()[0]
        print("\n--- hub 输出 ---")
        print(out[-800:])
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