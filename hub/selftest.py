#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地自测：起一个临时 hub，灌假数据，验证三种推送编排（dry-run，不发真消息）。"""

import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PORT = 18790
BASE = f"http://127.0.0.1:{PORT}"
TMP = HERE / "data" / "_selftest"


def call(path, body=None, method=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 method=method or ("POST" if data else "GET"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def main() -> int:
    if TMP.exists():
        shutil.rmtree(TMP)
    TMP.mkdir(parents=True)
    env = dict(os.environ, HUB_DRY_RUN="true", HUB_TOKEN="")
    proc = subprocess.Popen(
        [sys.executable, str(HERE / "app.py"), "--port", str(PORT),
         "--db", str(TMP / "t.sqlite"), "--config", str(TMP / "none.json")],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        for _ in range(30):
            try:
                health = call("/health")
                print("health:", health)
                break
            except Exception:
                time.sleep(0.3)
        else:
            print("服务未就绪")
            return 1

        print("\n--- 1) 我：两件到站 + 一件在途 ---")
        r = call("/api/v1/report", {
            "device": "wo", "snapshot": True,
            "packages": [
                {"platform": "pdd", "order_id": "A1", "tracking": "JT001",
                 "courier": "极兔速递", "pickup_code": "8-3-2015",
                 "station": "菜鸟驿站(阳光花园)", "goods": "洗衣液", "status": "arrived"},
                {"platform": "taobao", "order_id": "B2", "tracking": "SF002",
                 "courier": "顺丰", "pickup_code": "5-2-1188",
                 "station": "丰巢A区", "goods": "耳机", "status": "arrived"},
                {"platform": "jd", "order_id": "C3", "tracking": "JD003",
                 "courier": "京东快递", "status": "transit"},
            ],
        })
        print(json.dumps(r, ensure_ascii=False, indent=2))

        print("\n--- 2) 对象：一件到站 ---")
        r = call("/api/v1/report", {
            "device": "ta", "snapshot": True,
            "packages": [
                {"platform": "taobao", "order_id": "D4", "tracking": "YT004",
                 "courier": "圆通", "pickup_code": "3-1-2201",
                 "station": "菜鸟驿站(东门)", "goods": "纸巾", "status": "arrived"},
            ],
        })
        print(json.dumps(r, ensure_ascii=False, indent=2))

        print("\n--- 3) QQ 回执：取 8-3-2015 ---")
        r = call("/api/v1/pick", {"code": "8-3-2015"})
        print(json.dumps(r, ensure_ascii=False, indent=2))

        print("\n--- 4) 平台同步显示已签收（manual_pick=false，预期：不推「已取」） ---")
        r = call("/api/v1/report", {
            "device": "wo", "snapshot": True,
            "packages": [
                {"platform": "pdd", "order_id": "A1", "tracking": "JT001",
                 "pickup_code": "8-3-2015", "status": "picked"},
                {"platform": "taobao", "order_id": "B2", "tracking": "SF002",
                 "pickup_code": "5-2-1188", "status": "picked"},
            ],
        })
        print(json.dumps(r, ensure_ascii=False, indent=2))

        print("\n--- 5) 端侧手动确认取件（manual_pick=true，预期：推「已取」） ---")
        r = call("/api/v1/report", {
            "device": "ta", "snapshot": True,
            "packages": [
                {"platform": "taobao", "order_id": "D4", "tracking": "YT004",
                 "pickup_code": "3-1-2201", "status": "picked", "manual_pick": True},
            ],
        })
        print(json.dumps(r, ensure_ascii=False, indent=2))

        print("\n--- 6) 未取清单 ---")
        print(json.dumps(call("/api/v1/list"), ensure_ascii=False, indent=2))

        print("\n--- 7) 服务端输出（含 dry-run 推送内容） ---")
        time.sleep(0.5)
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            out = proc.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            proc.kill()
            out = proc.communicate()[0]
        print(out)

    shutil.rmtree(TMP, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
