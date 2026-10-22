#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通用保守解析：只认「取件码/取货码/提货码/凭码」标签后面的码

淘宝/京东的页面结构还没验证，先用这条最保守的规则：
宁可漏报，也不把商品型号、订单号误当取件码。拿到真实 dump 后再按平台细化。

判定与 PDD 一致的三条底线：
  1. 只认标签后的码，或独占一行的码；
  2. 「已签收/已取件」只看命中行自身；
  3. 驿站地址按【】内容打分，排除电话/快递员。
"""

from __future__ import annotations

import re
from typing import Any

CODE_RE = re.compile(r"(?<![0-9A-Za-z_])\d{1,3}-\d{1,3}-\d{2,5}(?![0-9A-Za-z_])")
LABEL_RE = re.compile(r"(取件码|取货码|提货码|凭码|取件号)[\s:：]*")
TRACK_RE = re.compile(r"\b(?:JT|SF|YT|ST|JD|ZTO|YD|EMS|DB)[A-Z0-9]{8,16}\b", re.I)
BRACKET_RE = re.compile(r"【([^】]{2,40})】")
MODEL_RE = re.compile(r"(变频器|电机|水泵|功率|电压|型号|规格|适用|通用|重载|KW|kW)")

PLACE_HINTS = ("区", "栋", "号", "路", "街", "苑", "园", "村", "驿站", "自提点", "柜")
PLACE_BAD = ("电话", "快递员", "客服", "投诉")


def _pick_place(ctx: str) -> str:
    best, best_score = "", 0
    for cand in BRACKET_RE.findall(ctx):
        score = 2 if any(h in cand for h in PLACE_HINTS) else 0
        if any(b in cand for b in PLACE_BAD):
            score -= 3
        if score > best_score:
            best, best_score = cand, score
    return best


def parse_labeled_codes(text: str, platform: str) -> list[dict[str, Any]]:
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    out: dict[str, dict[str, Any]] = {}

    for i, line in enumerate(lines):
        label = LABEL_RE.search(line)
        code = None
        if label:
            after = line[label.end():]
            m = CODE_RE.search(after) or CODE_RE.search(line)
            if m:
                code = m.group(0)
        else:
            m = CODE_RE.search(line)
            if m and m.group(0) == line:
                code = m.group(0)
        if not code:
            continue

        ctx = " ".join(lines[max(0, i - 2): i + 3])
        if not label and MODEL_RE.search(ctx):
            continue
        if any(w in line for w in ("已取件", "已签收", "已提取")):
            continue

        track = TRACK_RE.search(ctx)
        key = f"{platform}:{track.group(0) if track else code}"
        out[key] = {
            "platform": platform,
            "pickup_code": code,
            "station": _pick_place(ctx),
            "tracking": track.group(0) if track else "",
            "goods": "",
            "status": "arrived",
        }
    return list(out.values())
