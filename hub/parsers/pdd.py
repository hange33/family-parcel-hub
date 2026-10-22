#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""拼多多包裹助手页解析（服务端版，与 App 内逻辑等价）

为什么单独抽出来：抓取要搬到 NAS 常驻，解析逻辑必须能在无手机的环境里跑。
本文件不依赖 Playwright，可单独用真实页面做回归测试。

解析策略（两条路，优先结构化）
--------------------------------
1. **结构化（首选）**：页面把包裹列表以 JSON 内嵌在 `window.rawData` 里，
   每个包裹带 `tracking_number / pick_code / goods_name / status_type /
   status_type_desc / track_desc / sign_time_desc`。这是权威数据源——
   运单号、商品名、状态全都是现成的，不用猜。
2. **文本（兜底）**：`window.rawData` 缺失时退回 `inner_text` 逐行匹配。
   只认「取件码/取货码/提货码/凭码」标签后的码或独占一行的码。

历史踩坑（都写在这里，别改回去）
--------------------------------
  1. 取件码只认「取件码/取货码/提货码/凭码」标签后的数字，或独占一行的数字；
  2. 「已签收/已取件」只看命中行自身，绝不看上下文（否则上一件的状态会误杀下一件）；
  3. 商品名不取标签页文字（我的收件/我的寄件/全部…）和物流行；
  4. 驿站地址优先取含「区/栋/号/路/驿站」的【】，排除含「电话/快递员」的【】。
  5. ⚠️ **已签收的件也必须上报**（status=picked），否则 hub 里那件永远停在
     arrived，每天 17:00 汇总会一直推一个早就取走的件。
  6. ⚠️ **hub 去重键是 platform:order_id/tracking**，所以必须给出稳定的
     `order_id`（用运单号），否则同一件会因取件码变化被当成新件重复推送。
"""

from __future__ import annotations

import json
import re
from typing import Any

CODE_RE = re.compile(r"(?<![0-9A-Za-z_])\d{1,3}-\d{1,3}-\d{2,5}(?![0-9A-Za-z_])")
LABEL_RE = re.compile(r"(取件码|取货码|提货码|凭码|取件号)[\s:：]*")
TRACK_RE = re.compile(r"\b(?:JT|SF|YT|ST|JD|ZTO|YD|EMS|DB)[A-Z0-9]{8,16}\b", re.I)
MODEL_RE = re.compile(
    r"(变频器|电机|马达|水泵|功率|电压|型号|规格|适用|通用|重载|轴承|电池|容量|尺寸|KW|kW)"
)
BRACKET_RE = re.compile(r"【([^】]{2,40})】")

# 页面上的固定文案 / 标签页，不能当商品名
NOISE_WORDS = (
    "我的收件", "我的寄件", "全部", "已签收", "待取件", "派件中", "运输中", "待发货",
    "取快递", "寄快递", "输入快递单号", "查询全网物流", "取件码",
)
LOGISTICS_WORDS = ("：", ":", "快递", "电话", "派送", "自提", "签收", "揽投", "驿站")
PLACE_HINTS = ("区", "栋", "号", "路", "街", "苑", "园", "村", "驿站", "自提点", "柜")
PLACE_BAD = ("电话", "快递员", "客服", "投诉")

# 拼多多 status_type → 内部状态
#   400 待取件 / 500 已签收 / 300 运输中 / 200 派送中 …
STATUS_MAP = {
    400: "arrived",
    500: "picked",
    300: "transit",
    200: "delivering",
}

# rawData 提取：页面里内嵌 `window.rawData = {...};`
RAWDATA_RE = re.compile(r"window\.rawData\s*=\s*(\{.*?\});\s*\n", re.S)


# ---------------------------------------------------------------- 结构化解析
def extract_raw_data(html: str) -> dict | None:
    """从 HTML 里抠出 window.rawData 并解析成 dict。失败返回 None。"""
    if not html:
        return None
    m = RAWDATA_RE.search(html)
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except Exception:
        return None


def _iter_express_items(raw: dict) -> list[dict]:
    """遍历 rawData 里所有包裹条目（expressListData 是分组的 list）。"""
    store = (raw or {}).get("store") or {}
    groups = store.get("expressListData") or {}
    items: list[dict] = []
    if isinstance(groups, dict):
        for _, grp in groups.items():
            if isinstance(grp, dict):
                for it in grp.get("list") or []:
                    if isinstance(it, dict):
                        items.append(it)
    elif isinstance(groups, list):
        for grp in groups:
            if isinstance(grp, dict):
                for it in grp.get("list") or []:
                    if isinstance(it, dict):
                        items.append(it)
    return items


def _pick_place(ctx: str) -> str:
    best, best_score = "", 0
    for cand in BRACKET_RE.findall(ctx):
        score = 0
        if any(h in cand for h in PLACE_HINTS):
            score += 2
        if any(b in cand for b in PLACE_BAD):
            score -= 3
        if len(cand) < 4:
            score -= 1
        if score > best_score:
            best, best_score = cand, score
    return best


def _pick_courier(track_desc: str) -> str:
    """从轨迹文案开头取快递公司：「顺丰快递：」「邮政快递包裹：」→ 顺丰 / 邮政。"""
    m = re.match(r"^\s*([一-龥A-Za-z]{2,8}?)(?:快递|速递|邮政|物流|包裹|运输)", track_desc or "")
    if m:
        return m.group(1)
    m = re.match(r"^\s*([一-龥A-Za-z]{2,8})[：:]", track_desc or "")
    return m.group(1) if m else ""


def parse_raw_data(raw: dict) -> list[dict[str, Any]]:
    """结构化解析：产出全量包裹（含已签收），每件带稳定 order_id=运单号。"""
    out: list[dict[str, Any]] = []
    for it in _iter_express_items(raw):
        tracking = str(it.get("tracking_number") or "").strip()
        if not tracking:
            continue
        try:
            status_type = int(it.get("status_type"))
        except (TypeError, ValueError):
            status_type = None
        desc = str(it.get("status_type_desc") or "").strip()
        status = STATUS_MAP.get(status_type, "")
        if not status:
            # 兜底按中文描述判断
            if "签收" in desc or "已取走" in desc:
                status = "picked"
            elif "待取" in desc:
                status = "arrived"
            elif "派送" in desc:
                status = "delivering"
            elif "运输" in desc:
                status = "transit"
            else:
                status = "transit"

        raw_pick = str(it.get("pick_code") or "").strip()
        code = ""
        if raw_pick:
            m = CODE_RE.search(raw_pick)
            code = m.group(0) if m else raw_pick.replace("取件码", "").strip()

        track_desc = str(it.get("track_desc") or "")
        item = {
            "platform": "pdd",
            "order_id": tracking,          # 运单号做去重键，稳定
            "pickup_code": code,
            "station": _pick_place(track_desc),
            "tracking": tracking,
            "courier": _pick_courier(track_desc),
            "goods": str(it.get("goods_name") or "").strip(),
            "status": status,
        }
        sign_time = str(it.get("sign_time_desc") or "").strip()
        if sign_time:
            item["sign_time"] = sign_time
        out.append(item)
    return out


# ---------------------------------------------------------------- 文本兜底
def _pick_goods(lines: list[str], idx: int) -> str:
    for j in range(idx - 1, max(-1, idx - 9), -1):
        s = lines[j]
        if not (4 <= len(s) <= 60):
            continue
        if LABEL_RE.search(s):
            continue
        if any(w in s for w in NOISE_WORDS):
            continue
        if any(w in s for w in LOGISTICS_WORDS):
            continue
        if re.fullmatch(r"[\d\s\-:.]*", s):
            continue
        return s
    return ""


def parse_text(text: str) -> list[dict[str, Any]]:
    """文本兜底解析：只报「待取件」的件（拿不到运单号，去重键不稳）。"""
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

        # 无标签的候选，若上下文出现型号词，判为商品型号
        if not label and MODEL_RE.search(ctx):
            continue
        # 已取件只看本行
        if any(w in line for w in ("已取件", "已签收", "已提取")):
            continue

        track = TRACK_RE.search(ctx)
        item = {
            "platform": "pdd",
            "pickup_code": code,
            "station": _pick_place(ctx),
            "tracking": track.group(0) if track else "",
            "courier": _pick_courier(ctx),
            "goods": _pick_goods(lines, i),
            "status": "arrived",
        }
        key = f"pdd:{track.group(0) if track else code}"
        out[key] = item

    return list(out.values())


# ---------------------------------------------------------------- 统一入口
def parse_page(text: str, html: str = "") -> list[dict[str, Any]]:
    """解析拼多多包裹助手页。

    优先走结构化 rawData（字段全、可识别已签收）；
    rawData 缺失时退回文本解析。
    """
    raw = extract_raw_data(html) if html else None
    if raw:
        items = _iter_express_items(raw)
        if items:
            return parse_raw_data(raw)
    return parse_text(text)


if __name__ == "__main__":
    import sys
    from pathlib import Path

    if len(sys.argv) > 1:
        p = Path(sys.argv[1])
        html = p.read_text(encoding="utf-8") if p.suffix == ".html" else ""
        text = p.read_text(encoding="utf-8") if p.suffix == ".txt" else \
            (re.sub(r"<[^>]+>", "\n", html) if html else "")
        print(json.dumps(parse_page(text, html), ensure_ascii=False, indent=2))
    else:
        print("用法: python pdd.py <dump.html|dump.txt>")
