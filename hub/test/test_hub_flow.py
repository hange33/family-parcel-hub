#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""parcel-hub 端到端回归：验证「件被取走后必须从未取清单里消失」。

这是接手时发现的核心缺陷的守门测试：
  - 场景 A：先上报一件待取件 → 应当推送「新到件」且进未取清单
  - 场景 B：再上报同一件但状态变已签收（manual_pick 不带）→ 不应再推「新到件」
  - 场景 C：该件应从未取清单消失（不再是 arrived/stale）
  - 场景 D：跨平台不误伤 —— pdd 的快照不应把 taobao 的件标 stale
  - 场景 E：先到站后出码 → 应补推「新到件」（只推一次）

全程 dry-run，不发真消息。
"""

from __future__ import annotations

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
PORT = 18791
BASE = f"http://127.0.0.1:{PORT}"
TMP = HERE / "data" / "_selftest2"

FAILURES: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(f"  [{'PASS' if cond else 'FAIL'}] {msg}")
    if not cond:
        FAILURES.append(msg)


def call(path: str, body=None, method=None):
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
        for _ in range(40):
            try:
                call("/health")
                break
            except Exception:
                time.sleep(0.3)
        else:
            print("服务未就绪")
            return 1

        print("\n--- A) 首次上报：一件到站（应有 arrived 事件） ---")
        r = call("/api/v1/report", {
            "device": "wo", "snapshot": True, "platforms": ["pdd"],
            "packages": [
                {"platform": "pdd", "order_id": "9000000000001",
                 "tracking": "9000000000001", "courier": "邮政",
                 "pickup_code": "1-2-0001", "station": "示例小区1栋101",
                 "goods": "川珍八角", "status": "arrived"},
            ],
        })
        ev = r.get("events") or []
        check(len(ev) == 1 and ev[0]["type"] == "arrived",
              f"产生 1 个 arrived 事件（实际 {ev}）")

        print("\n--- B) 同一件再报一次（不应重复推 arrived） ---")
        r = call("/api/v1/report", {
            "device": "wo", "snapshot": True, "platforms": ["pdd"],
            "packages": [
                {"platform": "pdd", "order_id": "9000000000001",
                 "tracking": "9000000000001", "courier": "邮政",
                 "pickup_code": "1-2-0001", "station": "示例小区1栋101",
                 "goods": "川珍八角", "status": "arrived"},
            ],
        })
        ev = r.get("events") or []
        check(len(ev) == 0, f"不重复推 arrived（实际 {ev}）")

        print("\n--- C) 另加一件淘宝件（跨平台不误伤） ---")
        call("/api/v1/report", {
            "device": "wo", "snapshot": True, "platforms": ["taobao"],
            "packages": [
                {"platform": "taobao", "order_id": "TB3821765490123",
                 "tracking": "JT000123456789", "courier": "极兔速递",
                 "pickup_code": "8-3-2015", "station": "菜鸟驿站(阳光花园)",
                 "goods": "洗衣液", "status": "arrived"},
            ],
        })
        r = call("/api/v1/list")
        codes = sorted(i["pickup_code"] for i in r["items"])
        check(codes == ["1-2-0001", "8-3-2015"],
              f"两件都在未取清单（实际 {codes}）")

        print("\n--- D) 拼多多件被取走（status=picked，不带 manual_pick） ---")
        r = call("/api/v1/report", {
            "device": "wo", "snapshot": True, "platforms": ["pdd"],
            "packages": [
                {"platform": "pdd", "order_id": "9000000000001",
                 "tracking": "9000000000001", "courier": "邮政",
                 "pickup_code": "1-2-0001", "station": "示例小区1栋101",
                 "goods": "川珍八角", "status": "picked"},
            ],
        })
        ev = r.get("events") or []
        check(not any(e["type"] == "arrived" for e in ev),
              f"平台签收不推 arrived（实际 {ev}）")
        check(not any(e["type"] == "picked" for e in ev),
              f"非人工确认不推 picked（实际 {ev}）")

        r = call("/api/v1/list")
        codes = sorted(i["pickup_code"] for i in r["items"])
        check("1-2-0001" not in codes,
              f"已取走的拼多多件从未取清单消失（实际 {codes}）")
        check("8-3-2015" in codes,
              f"淘宝件不受拼多多快照影响，仍在清单（实际 {codes}）")

        print("\n--- E) 人工确认取件（manual_pick=true，应推 picked） ---")
        r = call("/api/v1/report", {
            "device": "wo", "snapshot": True, "platforms": ["taobao"],
            "packages": [
                {"platform": "taobao", "order_id": "TB3821765490123",
                 "tracking": "JT000123456789", "courier": "极兔速递",
                 "pickup_code": "8-3-2015", "station": "菜鸟驿站(阳光花园)",
                 "goods": "洗衣液", "status": "picked", "manual_pick": True},
            ],
        })
        ev = r.get("events") or []
        check(any(e["type"] == "picked" for e in ev),
              f"人工确认产生 picked 事件（实际 {ev}）")

        print("\n--- F) 先到站后出码（应补推一次 arrived） ---")
        call("/api/v1/report", {
            "device": "ta", "snapshot": True, "platforms": ["pdd"],
            "packages": [
                {"platform": "pdd", "order_id": "SF9999", "tracking": "SF9999",
                 "status": "arrived"},
            ],
        })
        r = call("/api/v1/report", {
            "device": "ta", "snapshot": True, "platforms": ["pdd"],
            "packages": [
                {"platform": "pdd", "order_id": "SF9999", "tracking": "SF9999",
                 "pickup_code": "9-9-8888", "status": "arrived"},
            ],
        })
        ev = r.get("events") or []
        check(any(e["type"] == "arrived" for e in ev),
              f"后补的取件码触发 arrived（实际 {ev}）")

        r = call("/api/v1/report", {
            "device": "ta", "snapshot": True, "platforms": ["pdd"],
            "packages": [
                {"platform": "pdd", "order_id": "SF9999", "tracking": "SF9999",
                 "pickup_code": "9-9-8888", "status": "arrived"},
            ],
        })
        ev = r.get("events") or []
        check(len(ev) == 0, f"不重复推（实际 {ev}）")

        print("\n--- G) 权威快照 0 件 → 标 stale（仍在清单但有提示） ---")
        call("/api/v1/report", {
            "device": "ta", "snapshot": True, "platforms": ["pdd"], "packages": [],
        })
        r = call("/api/v1/list")
        stale = [i for i in r["items"] if i["status"] == "stale"]
        check(len(stale) == 1 and stale[0]["pickup_code"] == "9-9-8888",
              f"该件被标 stale（实际 {[i['status'] for i in r['items']]}）")

        print("\n--- G2) 非权威 0 件快照 → 不得把 arrived 件标 stale ---")
        # 先造一件仍为 arrived 的件
        call("/api/v1/report", {
            "device": "tb", "snapshot": True, "platforms": ["pdd"],
            "packages": [
                {"platform": "pdd", "order_id": "SF7777", "tracking": "SF7777",
                 "pickup_code": "7-7-7777", "status": "arrived"},
            ],
        })
        before = call("/api/v1/list")
        n_stale_before = sum(1 for i in before["items"] if i["status"] == "stale")
        # 非权威快照：只带 packages，不带 platforms
        call("/api/v1/report", {
            "device": "tb", "snapshot": True, "packages": [],
        })
        after = call("/api/v1/list")
        n_stale_after = sum(1 for i in after["items"] if i["status"] == "stale")
        check(n_stale_after == n_stale_before,
              f"未声明平台范围时 stale 数不变（{n_stale_before} → {n_stale_after}）")
        check(any(i["pickup_code"] == "7-7-7777" and i["status"] == "arrived"
                  for i in after["items"]),
              "该 arrived 件未被误标 stale")

        print("\n--- H) 0 件快照不应误伤其他平台的件 ---")
        r = call("/api/v1/list")
        others = [i for i in r["items"] if i["platform"] != "pdd"]
        check(not any(i["status"] == "stale" for i in others),
              f"非 pdd 的件没有被标 stale（实际 {[(i['platform'], i['status']) for i in r['items']]}）")

        print("\n--- I) 汇总推送内容 ---")
        print(json.dumps(call("/api/v1/list"), ensure_ascii=False, indent=2)[:1200])

        time.sleep(0.5)
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            out = proc.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            proc.kill()
            out = proc.communicate()[0]
        print("\n--- 服务端输出（dry-run 推送内容） ---")
        print(out)

    shutil.rmtree(TMP, ignore_errors=True)
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
