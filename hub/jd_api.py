#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""京东 · 订单列表接口解析（照搬原项目 jd_connector.dart）

原项目做法：加载 `https://trade.m.jd.com/order/orderlist_jdm.shtml`，
拦截响应里含 `orderList` 的 JSON，取 `body.orderList[]`：
  - 订单号        orderId
  - 状态          orderStatusInfo.orderStatusName
  - 轨迹文案      progressInfo.content / progressInfo.tip
  - 商品名        wareInfoList[0].wareName
  - 自提码        从「轨迹文案 + 状态名 + tip」里用正则取
                (?:取件码|提货码|取货码|凭码|自提码)[:：\s]*([A-Za-z0-9\-]{3,12})
服务端用 Playwright 监听 response 拿到同一份 JSON，解析规则保持一致。
"""

from __future__ import annotations

import json
import re
from typing import Any

CODE_RE = re.compile(r"(?:取件码|提货码|取货码|凭码|自提码)[:：\s]*([A-Za-z0-9\-]{3,12})")
STATION_RE = re.compile(
    r"([\u4e00-\u9fa5A-Za-z0-9（）()]{2,24}(?:驿站|快递柜|自提柜|自提点|代收点|服务点|超市))"
)
SKIP_STATUS = ("取消", "关闭", "退款")
DONE_STATUS = ("完成", "签收", "妥投", "已收货")


def pickup_code_from_text(block: str) -> str:
    m = CODE_RE.search(block)
    return m.group(1) if m else ""


def station_from_text(block: str) -> str:
    m = STATION_RE.search(block)
    return m.group(1) if m else ""


def parse_order_list(raw: str) -> list[dict[str, Any]]:
    s = raw.strip()
    if s.startswith('"') and s.endswith('"'):
        try:
            s = json.loads(s)
        except Exception:
            pass
    try:
        root = json.loads(s)
    except Exception:
        return []

    body = root.get("body") if isinstance(root, dict) else None
    orders = (body or {}).get("orderList") if isinstance(body, dict) else None
    if not isinstance(orders, list):
        return []

    out: list[dict[str, Any]] = []
    for item in orders:
        if not isinstance(item, dict):
            continue
        order_id = str(item.get("orderId") or "")
        if not order_id:
            continue

        status_info = item.get("orderStatusInfo") or {}
        status_name = str(status_info.get("orderStatusName") or "")
        if any(w in status_name for w in SKIP_STATUS):
            continue
        # 已签收/已完成的不是「待取」，跳过；取件完成由 hub 侧人工回执
        if any(w in status_name for w in DONE_STATUS):
            continue

        prog = item.get("progressInfo") or {}
        content = str(prog.get("content") or "")
        tip = str(prog.get("tip") or "")
        block = f"{content} {status_name} {tip}"

        code = pickup_code_from_text(block)
        if not code:
            continue

        goods = ""
        ware = item.get("wareInfoList") or []
        if isinstance(ware, list) and ware and isinstance(ware[0], dict):
            goods = str(ware[0].get("wareName") or "")[:60]

        out.append({
            "platform": "jd",
            "order_id": order_id,
            "pickup_code": code,
            "station": station_from_text(block),
            "tracking": "",
            "goods": goods,
            "status": "arrived",
        })
    return out
