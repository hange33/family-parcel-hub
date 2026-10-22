# -*- coding: utf-8 -*-
"""登录态告警去重（无第三方依赖，可单独测试）

抓取器每轮都会检查 cookie 是否还有效。失效时不能每 30 分钟推一次，
否则一天刷 48 条。规则：
  · 状态从 ok/未知 → lost：立刻可推
  · 持续 lost：冷却 COOLDOWN 秒后才再推一次（默认 12h）
  · 从 lost → ok：可推一次「已恢复」
状态落盘在 state/login_notify.json，容器重启不丢。
"""
from __future__ import annotations

import json
import time
from pathlib import Path

COOLDOWN = 12 * 3600


def load(path) -> dict:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception:
        return {}


def save(path, st: dict) -> None:
    try:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(st, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(p)
    except Exception:
        pass


def should_notify(path, key: str, new_state: str, cooldown: int = COOLDOWN) -> bool:
    """记录状态并返回「这次是否需要推送」。"""
    st = load(path)
    rec = st.get(key) or {}
    prev = rec.get("state")
    ts = float(rec.get("ts") or 0)
    now = time.time()

    if prev is None and new_state == "ok":
        # 首次就正常：静默记一笔，别推「已恢复」
        st[key] = {"state": new_state, "ts": now}
        save(path, st)
        return False

    if prev == new_state:
        # 一直处于同一状态：只有 lost 需要按冷却时间重复提醒
        if new_state == "lost" and now - ts >= cooldown:
            st[key] = {"state": new_state, "ts": now}
            save(path, st)
            return True
        return False

    st[key] = {"state": new_state, "ts": now}
    save(path, st)
    return True
