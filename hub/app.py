#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
parcel-hub —— 家庭取件码聚合服务（零第三方依赖）

职责：
  1. 接收各端上报的包裹快照，按 hub_key 去重合并（两人 / 多平台）
  2. 状态机推进：transit → delivering → arrived → picked / rejected
  3. 三种推送：新到件（即时）/ 每日 17:00 未取汇总 / 取件完成
  4. 推送走已有的 qq-bridge（POST /notify），不直接对接 QQ 开放平台

运行：
  python app.py --port 8790 --db data/hub.sqlite --config config.json

安全：
  - 所有写接口要求 X-Hub-Token
  - dry_run=true 时只打印不推送（默认，防误发）
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import threading
import time
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib import error, request
from urllib.parse import unquote, quote as _quote
import urllib.parse

HERE = Path(__file__).resolve().parent
DEFAULTS = {
    "dry_run": True,
    "token": "",
    "owners": {"wo": "我", "ta": "对象"},
    "qq_bridge": {"url": "http://127.0.0.1:8787/notify", "token": "", "target": "group"},
    "summary_at": "17:00",
    # 夜间免打扰：这段时间内不推手机通知，攒到 end 之后一起发
    "quiet_hours": {"start": "22:30", "end": "08:00"},
    "max_pickup_age_hours": 72,
    # scrapers 容器地址：Web 端的「绑定账号」靠它触发扫码
    "scrapers": {"url": "http://192.0.2.10:8791", "qr_token": ""},
}

DB_SCHEMA = """
CREATE TABLE IF NOT EXISTS packages (
  hub_key     TEXT PRIMARY KEY,
  owner       TEXT NOT NULL,
  platform    TEXT,
  order_id    TEXT,
  tracking    TEXT,
  courier     TEXT,
  pickup_code TEXT,
  station     TEXT,
  location    TEXT,
  goods       TEXT,
  status      TEXT NOT NULL,
  arrived_at  TEXT,
  picked_at   TEXT,
  first_seen  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  notified_arrived INTEGER DEFAULT 0,
  notified_picked  INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_status ON packages(status);
CREATE INDEX IF NOT EXISTS idx_tracking ON packages(tracking);
CREATE TABLE IF NOT EXISTS devices (
  device TEXT PRIMARY KEY,
  label  TEXT,
  last_seen TEXT
);
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
"""

ARRIVED = "arrived"
PICKED = "picked"
TERMINAL = {"picked", "rejected", "archived"}


# ---------------------------------------------------------------- 配置 / 工具
def load_config(path: str | None) -> dict:
    cfg = json.loads(json.dumps(DEFAULTS))
    if path and Path(path).exists():
        with open(path, "r", encoding="utf-8") as f:
            user = json.load(f)
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    # 环境变量优先，方便容器部署
    if os.getenv("HUB_TOKEN"):
        cfg["token"] = os.environ["HUB_TOKEN"]
    if os.getenv("QQ_BRIDGE_URL"):
        cfg["qq_bridge"]["url"] = os.environ["QQ_BRIDGE_URL"]
    if os.getenv("QQ_BRIDGE_TOKEN"):
        cfg["qq_bridge"]["token"] = os.environ["QQ_BRIDGE_TOKEN"]
    if os.getenv("QQ_TARGET"):
        cfg["qq_bridge"]["target"] = os.environ["QQ_TARGET"]
    if os.getenv("HUB_DRY_RUN", "").lower() in ("1", "true", "yes"):
        cfg["dry_run"] = True
    return cfg


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def short_time(iso: str | None) -> str:
    if not iso:
        return ""
    try:
        return datetime.fromisoformat(iso).strftime("%m-%d %H:%M")
    except Exception:
        return iso


LOG_PATH = Path(os.getenv("HUB_LOG", str(HERE / "dump" / "hub.log")))
LOG_MAX_BYTES = 2 * 1024 * 1024
# 自动「已取」合并推送：最后一次状态变化后静默这么久再推（用户要求约 10 分钟）
PICK_BATCH_QUIET_SEC = 600
PICK_BATCH_TICK_SEC = 15


def log(msg: str) -> None:
    """写 dump/hub.log（同时 stdout）。fnOS 读不到容器日志，只能落盘 + Web 查看。"""
    line = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    print(line, flush=True)
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        if LOG_PATH.exists() and LOG_PATH.stat().st_size > LOG_MAX_BYTES:
            os.replace(LOG_PATH, LOG_PATH.with_name(LOG_PATH.name + ".1"))
        with LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def tail_log(n: int = 300) -> list[str]:
    try:
        if not LOG_PATH.exists():
            return []
        with LOG_PATH.open("rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 200_000))
            data = f.read().decode("utf-8", "ignore")
        return data.splitlines()[-n:]
    except Exception:
        return []


DEFER_PATH = Path(os.getenv("HUB_DEFER", str(HERE / "dump" / "deferred.json")))
_DEFER_LOCK = threading.Lock()


def _load_deferred() -> list:
    try:
        return json.loads(DEFER_PATH.read_text(encoding="utf-8"))
    except Exception:
        return []


def _save_deferred(items: list) -> None:
    try:
        DEFER_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = DEFER_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(items, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(DEFER_PATH)
    except Exception:
        pass


def in_quiet_hours(cfg: dict, now: datetime | None = None) -> bool:
    qh = cfg.get("quiet_hours") or {}
    start = str(qh.get("start") or "").strip()
    end = str(qh.get("end") or "").strip()
    if not start or not end:
        return False
    cur = (now or datetime.now()).strftime("%H:%M")
    if start <= end:
        return start <= cur < end
    return cur >= start or cur < end


def push(cfg: dict, content: str, title: str = "", force: bool = False) -> bool:
    """调 qq-bridge；dry_run 只写日志不发送；夜间自动顺延到早上。"""
    if not force and in_quiet_hours(cfg):
        with _DEFER_LOCK:
            items = _load_deferred()
            items.append({"ts": datetime.now().strftime("%m-%d %H:%M"),
                          "title": title, "content": content})
            _save_deferred(items)
        log(f"[push] 夜间免打扰，「{title}」顺延到 {cfg['quiet_hours']['end']} 之后（队列 "
            f"{len(items)} 条）")
        return True
    if cfg["dry_run"] or not cfg["qq_bridge"]["url"]:
        log(f"[push] dry_run，未发送「{title}」：{content.replace(chr(10), ' / ')[:120]}")
        return True
    body = json.dumps({
        "target": cfg["qq_bridge"]["target"],
        "title": title,
        "content": content,
    }).encode("utf-8")
    req = request.Request(
        cfg["qq_bridge"]["url"], data=body, method="POST",
        headers={"Content-Type": "application/json",
                 "X-Bridge-Token": cfg["qq_bridge"]["token"]},
    )
    for attempt in range(3):
        try:
            with request.urlopen(req, timeout=10) as resp:
                ok = 200 <= resp.status < 300
                log(f"[push] 「{title}」→ {cfg['qq_bridge']['target']} HTTP {resp.status} "
                    f"{'成功' if ok else '失败'}")
                return ok
        except (error.URLError, error.HTTPError, TimeoutError) as exc:
            log(f"[push] 失败({attempt + 1}/3)「{title}」: {exc}")
            time.sleep(2 ** attempt)
    return False


# ---------------------------------------------------------------- 数据库操作
class Hub:
    def __init__(self, db_path: str, cfg: dict, config_path: str = ""):
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(db_path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(DB_SCHEMA)
        self.db.commit()
        self.lock = threading.Lock()
        self.cfg = cfg
        self.config_path = config_path
        self.cfg.setdefault("owners", {})
        # 自动「已取」合并队列：key -> {code, station, owner}
        self._pick_q: dict[str, dict] = {}
        self._pick_last = 0.0
        self._pick_lock = threading.Lock()

    # ---- 上报
    def report(self, payload: dict) -> dict:
        device = payload.get("device") or "unknown"
        owner = self.cfg["owners"].get(device, payload.get("device_label") or device)
        pkgs = payload.get("packages") or []
        events: list[dict] = []

        with self.lock:
            self.db.execute(
                "INSERT INTO devices(device,label,last_seen) VALUES(?,?,?) "
                "ON CONFLICT(device) DO UPDATE SET label=excluded.label,last_seen=excluded.last_seen",
                (device, payload.get("device_label") or owner, now_iso()),
            )
            for p in pkgs:
                ev = self._upsert(owner, p)
                if ev:
                    events.append(ev)
            if payload.get("snapshot"):
                # 只在「本次快照覆盖到的平台」范围内标 stale。
                # 否则同一 owner 下，一个平台的局部快照会把另一个平台的件误标 stale。
                plats = {str(p.get("platform") or "").lower() for p in pkgs}
                plats.discard("")
                # 端侧显式声明的平台范围优先（覆盖「本轮 0 件」的情况）
                for pz in payload.get("platforms") or []:
                    plats.add(str(pz).lower())
                if plats:
                    keys = [self._key(p) for p in pkgs]
                    if payload.get("platforms"):
                        # 带 platforms 的只有权威快照（抓取器 parse 成功才会带）。
                        # 权威快照里「不见了」= 已被取走，自动置 picked 并进合并队列。
                        self._auto_pick_missing(owner, keys, plats)
                    else:
                        self._mark_stale(owner, keys, plats)
            self.db.commit()

        summary = self.stats()
        plats_dbg = sorted(str(x) for x in (payload.get("platforms") or []))
        log(f"[report] {owner} {plats_dbg or '-'} {len(pkgs)} 件 "
            f"权威={bool(payload.get('platforms'))} 事件={len(events)}")
        if events:
            self._notify_events(events, summary)
        return {"ok": True, "events": events, **summary}

    def _key(self, p: dict) -> str:
        platform = (p.get("platform") or "unknown").lower()
        ident = (p.get("order_id") or p.get("tracking") or "").strip()
        if not ident:
            ident = (p.get("pickup_code") or "").strip() or "nokey"
        return f"{platform}:{ident}"

    def _upsert(self, owner: str, p: dict) -> dict | None:
        key = self._key(p)
        row = self.db.execute("SELECT * FROM packages WHERE hub_key=?", (key,)).fetchone()
        status = (p.get("status") or "transit").lower()
        ts = now_iso()
        code = (p.get("pickup_code") or "").strip()
        arrived_at = p.get("arrived_at") or (ts if status == ARRIVED else None)
        picked_at = p.get("picked_at")

        if row is None:
            self.db.execute(
                "INSERT INTO packages(hub_key,owner,platform,order_id,tracking,courier,pickup_code,"
                "station,location,goods,status,arrived_at,picked_at,first_seen,updated_at) "
                "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (key, owner, p.get("platform"), p.get("order_id"), p.get("tracking"),
                 p.get("courier"), code, p.get("station"), p.get("location"), p.get("goods"),
                 status, arrived_at, picked_at, ts, ts),
            )
            if status == ARRIVED and code:
                # 首次到站且有码 → 立即推送，并标记已通知。
                # 必须同时置 notified_arrived，否则这一件以后每次上报都会再推一次。
                self.db.execute("UPDATE packages SET notified_arrived=1 WHERE hub_key=?", (key,))
                return {"type": "arrived", "key": key, "code": code, "owner": owner,
                        "station": p.get("station"), "goods": p.get("goods"),
                        "courier": p.get("courier")}
            return None

        prev_status = row["status"]
        # 状态只能单向推进，避免同步抖动把已取翻回在途
        order = {"pendingShipment": 0, "transit": 1, "delivering": 2,
                 "arrived": 3, "picked": 4, "archived": 5, "rejected": 4}
        if order.get(status, 0) < order.get(prev_status, 0) and prev_status in TERMINAL:
            status = prev_status

        self.db.execute(
            "UPDATE packages SET owner=?,pickup_code=?,station=?,location=?,goods=?,courier=?,"
            "tracking=?,status=?,arrived_at=COALESCE(arrived_at,?),picked_at=COALESCE(?,picked_at),"
            "updated_at=? WHERE hub_key=?",
            (owner, code or row["pickup_code"], p.get("station") or row["station"],
             p.get("location") or row["location"], p.get("goods") or row["goods"],
             p.get("courier") or row["courier"], p.get("tracking") or row["tracking"],
             status, arrived_at, picked_at, ts, key),
        )
        # 首次拿到取件码 → 新件事件。
        # 判据用 notified_arrived 而不是 prev_status：
        #   · 先到站但还没出码，后来才出码 → 该推（prev_status 已是 arrived，用旧判据会漏推）
        #   · stale 后又同步到 → 不该重复推（notified_arrived 已置位）
        if status == ARRIVED and code and not row["notified_arrived"]:
            self.db.execute("UPDATE packages SET notified_arrived=1 WHERE hub_key=?", (key,))
            return {"type": "arrived", "key": key, "code": code, "owner": owner,
                    "station": p.get("station") or row["station"],
                    "goods": p.get("goods") or row["goods"],
                    "courier": p.get("courier") or row["courier"]}
        # 变成已取：手动标记立即推；平台侧转为已签收则并入 10 分钟合并队列
        if status == PICKED and prev_status != PICKED:
            self.db.execute("UPDATE packages SET picked_at=COALESCE(picked_at,?),notified_picked=1 "
                            "WHERE hub_key=?", (now_iso(), key))
            if p.get("manual_pick"):
                return {"type": "picked", "key": key, "code": code or row["pickup_code"],
                        "owner": owner}
            self._queue_picked({
                "key": key,
                "code": code or row["pickup_code"] or "",
                "station": p.get("station") or row["station"] or "",
                "owner": owner,
            })
            log(f"[auto-pick] {key} 平台状态转为已取（{code or row['pickup_code'] or '—'}），入队")
            return None
        return None

    def _mark_stale(self, owner: str, keys: list[str], plats: set[str]) -> None:
        """快照里没出现、但仍是 arrived 的，标 stale（不删除，供汇总提示）。

        plats 限定只动本次快照覆盖到的平台，避免一个平台的局部快照
        把同一 owner 下其他平台的件误标 stale。
        keys 为空表示「本次快照该平台 0 件」，此时该平台所有 arrived 都算过时。
        """
        if not plats:
            return
        pq = ",".join("?" * len(plats))
        if keys:
            q = ",".join("?" * len(keys))
            self.db.execute(
                f"UPDATE packages SET status='stale',updated_at=? "
                f"WHERE owner=? AND status='arrived' AND platform IN ({pq}) "
                f"AND hub_key NOT IN ({q})",
                (now_iso(), owner, *plats, *keys),
            )
        else:
            self.db.execute(
                f"UPDATE packages SET status='stale',updated_at=? "
                f"WHERE owner=? AND status='arrived' AND platform IN ({pq})",
                (now_iso(), owner, *plats),
            )

    def _auto_pick_missing(self, owner: str, keys: list[str], plats: set[str]) -> None:
        """权威快照里消失的 arrived 件 → 自动置 picked，进入 10 分钟合并队列。

        只在「权威快照」时调用：抓取器解析成功才会带 platforms，
        解析失败/登录失效不会走到这里，避免把「没抓到」当成「已取走」。
        """
        if not plats:
            return
        pq = ",".join("?" * len(plats))
        sql = (f"SELECT * FROM packages WHERE owner=? AND status='{ARRIVED}' "
               f"AND platform IN ({pq})")
        params: list = [owner, *plats]
        if keys:
            sql += f" AND hub_key NOT IN ({','.join('?' * len(keys))})"
            params += keys
        rows = self.db.execute(sql, params).fetchall()
        if not rows:
            return
        ts = now_iso()
        codes = []
        for r in rows:
            self.db.execute(
                "UPDATE packages SET status=?,picked_at=?,notified_picked=1,updated_at=? "
                "WHERE hub_key=?", (PICKED, ts, ts, r["hub_key"]))
            self._queue_picked({
                "key": r["hub_key"],
                "code": r["pickup_code"] or "",
                "station": r["station"] or "",
                "owner": owner,
            })
            codes.append(r["pickup_code"] or r["hub_key"])
        log(f"[auto-pick] 快照里消失 {len(rows)} 件 → 已取（{', '.join(codes[:8])}），"
            f"{PICK_BATCH_QUIET_SEC // 60} 分钟后合并推送")

    def _queue_picked(self, item: dict) -> None:
        with self._pick_lock:
            self._pick_q[item["key"]] = item
            self._pick_last = time.time()

    def _pick_batch_loop(self) -> None:
        """后台线程：队列里最后一件变化后静默 10 分钟，统一推一条。"""
        while True:
            time.sleep(PICK_BATCH_TICK_SEC)
            try:
                with self._pick_lock:
                    if not self._pick_q:
                        continue
                    if time.time() - self._pick_last < PICK_BATCH_QUIET_SEC:
                        continue
                    items = list(self._pick_q.values())
                    self._pick_q.clear()
                self._flush_picked(items)
            except Exception as exc:
                log(f"[pick-batch] 异常：{type(exc).__name__}: {exc}")

    def _flush_picked(self, items: list[dict]) -> None:
        items.sort(key=lambda x: (x.get("station") or "", x.get("code") or ""))
        lines = [f"✅ 已取 {len(items)} 件"]
        for it in items[:12]:
            tail = "｜".join(x for x in (it.get("station"), it.get("owner")) if x)
            lines.append(f"· {it.get('code') or '—'}" + (f"  {tail}" if tail else ""))
        if len(items) > 12:
            lines.append(f"… 另有 {len(items) - 12} 件")
        remain = self.stats().get("arrived", 0)
        lines.append(f"还剩 {remain} 件未取")
        ok = push(self.cfg, "\n".join(lines), title="已取")
        log(f"[pick-batch] 推送 {len(items)} 件 → {'成功' if ok else '失败'}，剩余 {remain}")

    # ---- 手动标记已取（QQ 回执）
    def pick_by_code(self, code: str) -> dict | None:
        code = (code or "").strip()
        if not code:
            return None
        with self.lock:
            row = self.db.execute(
                "SELECT * FROM packages WHERE pickup_code=? AND status IN ('arrived','stale') "
                "ORDER BY updated_at DESC LIMIT 1", (code,)).fetchone()
            if row is None:
                return None
            self.db.execute("UPDATE packages SET status=?,picked_at=?,updated_at=? WHERE hub_key=?",
                            (PICKED, now_iso(), now_iso(), row["hub_key"]))
            self.db.commit()
        summary = self.stats()
        ev = {"type": "picked", "key": row["hub_key"], "code": code, "owner": row["owner"]}
        self._notify_events([ev], summary)
        return ev

    def add_owner(self, aid: str, label: str) -> None:
        """新增账号到 owners 映射，并落盘（否则重启后 owner 又显示成 id）。"""
        aid = (aid or "").strip()
        if not aid:
            return
        self.cfg["owners"][aid] = (label or "").strip() or aid
        self._save_owners()

    def remove_owner(self, aid: str) -> None:
        aid = (aid or "").strip()
        if aid and aid in self.cfg["owners"]:
            self.cfg["owners"].pop(aid, None)
            self._save_owners()

    def _save_owners(self) -> None:
        """把 owners 写回配置文件。写失败只打印，不影响主流程。"""
        path = getattr(self, "config_path", "")
        if not path or not Path(path).exists():
            return
        try:
            with self.lock:
                raw = json.loads(Path(path).read_text(encoding="utf-8"))
                raw["owners"] = self.cfg["owners"]
                tmp = Path(path).with_suffix(".json.tmp")
                tmp.write_text(json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8")
                tmp.replace(Path(path))
            print(f"[hub] owners 已更新：{self.cfg['owners']}", flush=True)
        except Exception as exc:
            print(f"[hub] owners 落盘失败（本次运行内仍生效）：{exc}", flush=True)

    def set_push_target(self, target: str) -> str:
        """切换推送目标（me=私聊 / group=群聊），并写回配置文件。"""
        t = (target or "").strip().lower()
        if t not in ("me", "group"):
            return ""
        self.cfg.setdefault("qq_bridge", {})["target"] = t
        self._save_push_target()
        log(f"[push] 目标切换为 {t}（{'私聊' if t == 'me' else '群聊'}）")
        return t

    def _save_push_target(self) -> None:
        path = getattr(self, "config_path", "")
        if not path or not Path(path).exists():
            return
        try:
            with self.lock:
                raw = json.loads(Path(path).read_text(encoding="utf-8"))
                qb = raw.setdefault("qq_bridge", {})
                qb["target"] = self.cfg["qq_bridge"]["target"]
                tmp = Path(path).with_suffix(".json.tmp")
                tmp.write_text(json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8")
                tmp.replace(Path(path))
        except Exception as exc:
            log(f"[push] 目标落盘失败（本次运行内仍生效）：{exc}")

    def pick_by_key(self, key: str) -> dict | None:
        """按 hub_key 标记已取（Web 端用）。取件码可能重复，key 更精确。"""
        key = (key or "").strip()
        if not key:
            return None
        with self.lock:
            row = self.db.execute(
                "SELECT * FROM packages WHERE hub_key=? AND status IN ('arrived','stale')",
                (key,)).fetchone()
            if row is None:
                return None
            self.db.execute(
                "UPDATE packages SET status=?,picked_at=COALESCE(picked_at,?),"
                "notified_picked=1,updated_at=? WHERE hub_key=?",
                (PICKED, now_iso(), now_iso(), key))
            self.db.commit()
        summary = self.stats()
        log(f"[manual-pick] {key} 取件码={row['pickup_code'] or '—'} 由 Web 端标记已取")
        ev = {"type": "picked", "key": key, "code": row["pickup_code"], "owner": row["owner"]}
        self._notify_events([ev], summary)
        return ev

    def unpick_by_key(self, key: str) -> dict | None:
        """撤销「已取」：Web 端误点回滚用。不推送任何消息。"""
        key = (key or "").strip()
        if not key:
            return None
        with self.lock:
            row = self.db.execute("SELECT * FROM packages WHERE hub_key=?", (key,)).fetchone()
            if row is None or row["status"] not in ("picked", "stale", "arrived"):
                return None
            # 回到 arrived，但清掉「已推送过已取」的标记，
            # 这样若真被取走，平台再次同步时仍能正确落状态。
            self.db.execute(
                "UPDATE packages SET status=?,picked_at=NULL,notified_picked=0,updated_at=? "
                "WHERE hub_key=?", (ARRIVED, now_iso(), key))
            self.db.commit()
        return {"type": "unpicked", "key": key, "code": row["pickup_code"]}

    # ---- 查询
    def arrived_list(self) -> list[sqlite3.Row]:
        return self.db.execute(
            "SELECT * FROM packages WHERE status IN ('arrived','stale') "
            "ORDER BY arrived_at IS NULL, arrived_at"
        ).fetchall()

    def all_list(self, limit: int = 200) -> list[sqlite3.Row]:
        """全量：未取 + 已取 + 在途，按更新时间倒序。"""
        return self.db.execute(
            "SELECT * FROM packages ORDER BY updated_at DESC LIMIT ?", (limit,)
        ).fetchall()

    def device_list(self) -> list[dict]:
        """各账号（设备）的上报情况，供 Web 端展示。"""
        rows = self.db.execute(
            "SELECT device,label,last_seen FROM devices ORDER BY device"
        ).fetchall()
        out = []
        for r in rows:
            cnt = self.db.execute(
                "SELECT COUNT(*) c FROM packages WHERE owner=? AND status IN ('arrived','stale')",
                (self.cfg["owners"].get(r["device"], r["label"] or r["device"]),),
            ).fetchone()
            total = self.db.execute(
                "SELECT COUNT(*) c FROM packages WHERE owner=?",
                (self.cfg["owners"].get(r["device"], r["label"] or r["device"]),),
            ).fetchone()
            out.append({
                "device": r["device"],
                "label": r["label"] or r["device"],
                "last_seen": r["last_seen"],
                "arrived": cnt["c"] if cnt else 0,
                "total": total["c"] if total else 0,
            })
        return out

    def stats(self) -> dict:
        rows = self.db.execute("SELECT status,COUNT(*) c FROM packages GROUP BY status").fetchall()
        by = {r["status"]: r["c"] for r in rows}
        return {"total": sum(by.values()), "arrived": by.get("arrived", 0) + by.get("stale", 0),
                "in_transit": by.get("transit", 0) + by.get("delivering", 0)}

    # ---- 推送编排
    def _notify_events(self, events: list[dict], summary: dict) -> None:
        arrived = [e for e in events if e["type"] == "arrived"]
        picked = [e for e in events if e["type"] == "picked"]

        if arrived:
            lines = [f"📦 新到 {len(arrived)} 件"]
            for e in arrived:
                bits = [e.get("station") or "未知驿站", e.get("code") or "无码"]
                tail = "｜".join(x for x in (e.get("owner"), e.get("courier"), e.get("goods")) if x)
                lines.append("· " + "  ".join(bits) + (f"  {tail}" if tail else ""))
            if any(e.get("code") for e in arrived):
                lines.append("在 Web 端点「标记已取」即可")
            push(self.cfg, "\n".join(lines), title="新到件")

        if picked:
            lines = ["✅ 已取"]
            for e in picked:
                lines.append(f"· {e.get('code') or '—'}（{e.get('owner')}）")
            lines.append(f"还剩 {summary.get('arrived', 0)} 件未取")
            push(self.cfg, "\n".join(lines), title="取件完成")

    def daily_summary(self) -> None:
        rows = self.arrived_list()
        if not rows:
            return
        lines = [f"📋 {self.cfg['summary_at']} 未取汇总 · 共 {len(rows)} 件"]
        for i, r in enumerate(rows, 1):
            parts = [r["pickup_code"] or "——", r["station"] or "未知驿站", r["owner"]]
            if r["courier"]:
                parts.append(r["courier"])
            line = f"{i}) " + "  ".join(str(x) for x in parts if x)
            line += f"（{short_time(r['arrived_at'])} 到）"
            if r["status"] == "stale":
                line += " ⚠️本次未同步到"
            lines.append(line)
        lines.append("在 Web 端点「标记已取」即可（取走后也会自动识别）")
        push(self.cfg, "\n".join(lines), title="未取汇总")


# ---------------------------------------------------------------- HTTP 层
class Handler(BaseHTTPRequestHandler):
    hub: Hub = None  # type: ignore
    cfg: dict = None  # type: ignore
    server_version = "parcel-hub/0.1"

    def log_message(self, fmt, *args):  # 静音默认日志
        print(f"[http] {self.address_string()} {fmt % args}", flush=True)

    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        # require_token=false → 完全免令牌（打开网页即可用）；
        # 仍保留 token 值，改回 true 立刻恢复鉴权。
        if not self.cfg.get("require_token", True):
            return True
        token = self.cfg.get("token") or ""
        if not token:
            return True  # 未配置 token 时（仅本地调试）放行
        return self.headers.get("X-Hub-Token", "") == token

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            return {}

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            self._send(200, {"ok": True,
                             "require_token": bool(self.cfg.get("require_token", True)),
                             **self.hub.stats()})
            return
        if path == "/" or path == "/index.html":
            self._send_file("index.html", "text/html; charset=utf-8")
            return
        if path.startswith("/web/"):
            self._send_file(path[len("/web/"):], "text/html; charset=utf-8")
            return
        if path.startswith("/qr/"):
            # 代理 scrapers 的二维码（scrapers 与 hub 不同容器，直接转发更省事）
            self._proxy_get(path + (("?" + self.path.split("?", 1)[1]) if "?" in self.path else ""))
            return
        if path == "/api/v1/list":
            if not self._authed():
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            self._send(200, {"ok": True, "items": [dict(r) for r in self.hub.arrived_list()]})
            return
        if path == "/api/v1/all":
            # Web 端用：未取 + 已取全量
            if not self._authed():
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            self._send(200, {"ok": True, "items": [dict(r) for r in self.hub.all_list()]})
            return
        if path == "/api/v1/push":
            if not self._authed():
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            self._send(200, {"ok": True,
                             "target": (self.cfg.get("qq_bridge") or {}).get("target"),
                             "dry_run": self.cfg.get("dry_run")})
            return
        if path == "/api/v1/logs":
            if not self._authed():
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            qs = dict(kv.split("=", 1) for kv in
                      (self.path.split("?", 1)[1] if "?" in self.path else "").split("&") if "=" in kv)
            try:
                n = max(20, min(2000, int(qs.get("lines", "300"))))
            except Exception:
                n = 300
            self._send(200, {"ok": True, "file": str(LOG_PATH),
                             "dry_run": self.cfg.get("dry_run"),
                             "target": (self.cfg.get("qq_bridge") or {}).get("target"),
                             "lines": tail_log(n)})
            return
        if path == "/api/v1/devices":
            if not self._authed():
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            self._send(200, {"ok": True, "devices": self.hub.device_list()})
            return
        if path == "/api/v1/scan/accounts":
            if not self._authed():
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            self._scan_accounts()
            return
        if path == "/api/v1/scan/status":
            if not self._authed():
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            q = dict(kv.split("=", 1) for kv in
                     (self.path.split("?", 1)[1] if "?" in self.path else "").split("&") if "=" in kv)
            self._scan_status(unquote(q.get("account", "")), unquote(q.get("platform", "")))
            return
        self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if not self._authed():
            self._send(401, {"ok": False, "error": "unauthorized"})
            return
        path = self.path.split("?")[0]
        body = self._body()
        if path == "/api/v1/report":
            self._send(200, self.hub.report(body))
            return
        if path == "/api/v1/alert":
            text = (body.get("text") or "").strip()
            if not text:
                self._send(400, {"ok": False, "error": "text 不能为空"})
                return
            ok = push(self.cfg, text, title=body.get("title") or "账号提醒")
            log(f"[alert] {text.splitlines()[0][:100]} → {'成功' if ok else '失败'}")
            self._send(200, {"ok": bool(ok)})
            return
        if path == "/api/v1/push_target":
            t = self.hub.set_push_target(body.get("target", ""))
            if not t:
                self._send(400, {"ok": False, "error": "target 只能是 me 或 group"})
                return
            self._send(200, {"ok": True, "target": t})
            return
        if path == "/api/v1/test_push":
            ok = push(self.cfg, "这是一条测试消息 · 来自 parcel-hub\n如果你看到它，说明推送链路是通的。",
                      title="测试推送", force=True)
            log(f"[test_push] 结果={ok} dry_run={self.cfg.get('dry_run')} "
                f"target={(self.cfg.get('qq_bridge') or {}).get('target')}")
            self._send(200, {"ok": bool(ok), "dry_run": self.cfg.get("dry_run"),
                             "target": (self.cfg.get("qq_bridge") or {}).get("target")})
            return
        if path == "/api/v1/pick":
            ev = self.hub.pick_by_code(body.get("code", ""))
            self._send(200 if ev else 404, {"ok": bool(ev), "event": ev})
            return
        if path == "/api/v1/pick_key":
            # Web 端按 hub_key 标记已取（比按取件码更精确：取件码可能重复）
            ev = self.hub.pick_by_key(body.get("key", ""))
            self._send(200 if ev else 404, {"ok": bool(ev), "event": ev})
            return
        if path == "/api/v1/unpick":
            # 撤销「已取」（误点回滚）
            ev = self.hub.unpick_by_key(body.get("key", ""))
            self._send(200 if ev else 404, {"ok": bool(ev), "event": ev})
            return
        if path == "/api/v1/scan/start":
            if not self._authed():
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            self._scan_start(body.get("account", ""), body.get("platform", ""),
                             bool(body.get("force")))
            return
        if path == "/api/v1/accounts/add":
            if not self._authed():
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            aid = (body.get("id") or "").strip().lower()
            label = (body.get("label") or "").strip()
            # ⚠️ 校验必须放在 hub 侧（权威方）。
            # 只在 scrapers 侧校验是不够的：hub 侧照样会把非法 id 写进 owners，
            # 而 owners 是用来决定推送里显示谁的名字的。
            if not aid:
                self._send(400, {"ok": False, "error": "账号 id 不能为空"})
                return
            if not re.fullmatch(r"[a-z0-9_]{2,16}", aid):
                self._send(400, {"ok": False,
                                 "error": "账号 id 只能用 2-16 位小写字母、数字或下划线"})
                return
            code, j = self._scrapers_json("/api/accounts/add", "POST",
                                           {"id": aid, "label": label or aid})
            if j.get("ok"):
                # hub 侧的 owners 映射也要同步，否则新账号的件 owner 会显示成 id
                self.hub.add_owner(aid, label or aid)
            self._send(code, j)
            return
        if path == "/api/v1/accounts/remove":
            if not self._authed():
                self._send(401, {"ok": False, "error": "unauthorized"})
                return
            aid = (body.get("id") or "").strip()
            if not aid:
                self._send(400, {"ok": False, "error": "缺少 id"})
                return
            # hub 侧也守「至少留一个」，即使下游实现漏了也不会把账号删光
            if len(self.cfg.get("owners") or {}) <= 1:
                self._send(400, {"ok": False, "error": "至少要保留一个账号"})
                return
            code, j = self._scrapers_json("/api/accounts/remove", "POST", {"id": aid})
            if j.get("ok"):
                self.hub.remove_owner(aid)
            self._send(code, j)
            return
        self._send(404, {"ok": False, "error": "not found"})

    # ---------------------------------------------------------------- Web 辅助
    WEB_DIR = HERE / "web"

    def _send_file(self, rel: str, ctype: str = "text/html; charset=utf-8") -> None:
        """发送静态文件（限 web/ 目录内，防路径穿越）。"""
        rel = rel.lstrip("/")
        if ".." in rel or rel.startswith("/"):
            self._send(404, {"ok": False, "error": "not found"})
            return
        f = (self.WEB_DIR / rel).resolve()
        try:
            f.relative_to(self.WEB_DIR.resolve())
        except ValueError:
            self._send(404, {"ok": False, "error": "not found"})
            return
        if not f.exists() or not f.is_file():
            self._send(404, {"ok": False, "error": "not found"})
            return
        data = f.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _scrapers_url(self, path: str) -> str:
        base = (self.cfg.get("scrapers") or {}).get("url") or "http://127.0.0.1:8791"
        return base.rstrip("/") + path

    def _proxy_get(self, path: str) -> None:
        """把请求转发给 scrapers 容器（二维码图片等）。"""
        try:
            req = request.Request(self._scrapers_url(path),
                                  headers={"X-Hub-Token": self.cfg.get("token", "")})
            with request.urlopen(req, timeout=20) as r:
                data = r.read()
                ctype = r.headers.get("Content-Type", "application/octet-stream")
        except Exception as exc:
            self._send(502, {"ok": False, "error": f"scrapers 不可达：{exc}"})
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _scrapers_json(self, path: str, method: str = "GET",
                       payload: dict | None = None) -> tuple[int, dict]:
        try:
            data = json.dumps(payload).encode() if payload is not None else None
            req = request.Request(self._scrapers_url(path), data=data, method=method,
                                  headers={"Content-Type": "application/json",
                                           "X-Hub-Token": self.cfg.get("token", "")})
            with request.urlopen(req, timeout=20) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except error.HTTPError as exc:
            try:
                return exc.code, json.loads(exc.read().decode("utf-8"))
            except Exception:
                return exc.code, {"ok": False, "error": f"HTTP {exc.code}"}
        except Exception as exc:
            return 502, {"ok": False, "error": f"scrapers 不可达：{exc}"}

    def _scan_accounts(self) -> None:
        code, j = self._scrapers_json("/api/accounts")
        j["qr_token"] = (self.cfg.get("scrapers") or {}).get("qr_token", "")
        self._send(code, j)

    def _scan_status(self, account: str, platform: str) -> None:
        q = urllib.parse.quote(account)
        p = urllib.parse.quote(platform)
        code, j = self._scrapers_json(f"/api/login/status?account={q}&platform={p}")
        self._send(code, j)

    def _scan_start(self, account: str, platform: str, force: bool = False) -> None:
        if not account or not platform:
            self._send(400, {"ok": False, "error": "缺少 account 或 platform"})
            return
        q = urllib.parse.quote(account)
        p = urllib.parse.quote(platform)
        url = f"/api/login/start?account={q}&platform={p}"
        if force:
            url += "&force=1"
        code, j = self._scrapers_json(url, "POST")
        self._send(code, j)


def deferred_loop(cfg: dict) -> None:
    """免打扰结束后，把夜里攒下的消息合并成一条发出去。"""
    while True:
        time.sleep(30)
        try:
            if in_quiet_hours(cfg):
                continue
            with _DEFER_LOCK:
                items = _load_deferred()
                if not items:
                    continue
                _save_deferred([])
            lines = [f"🌙 夜间顺延 {len(items)} 条（{cfg['quiet_hours']['start']}-"
                     f"{cfg['quiet_hours']['end']} 免打扰）"]
            for it in items:
                lines.append(f"\n—— {it['ts']} {it['title']}\n{it['content']}")
            push(cfg, "\n".join(lines)[:1500], title="夜间消息", force=True)
            log(f"[push] 夜间顺延 {len(items)} 条已发出")
        except Exception as exc:
            log(f"[defer] 异常：{type(exc).__name__}: {exc}")


# ---------------------------------------------------------------- 定时汇总
def summary_loop(hub: Hub, cfg: dict) -> None:
    hh, mm = (cfg.get("summary_at") or "17:00").split(":")
    target = (int(hh), int(mm))
    fired = ""
    while True:
        now = datetime.now()
        stamp = now.strftime("%Y-%m-%d")
        if (now.hour, now.minute) == target and fired != stamp:
            fired = stamp
            try:
                hub.daily_summary()
                log("[summary] 已执行 17:00 汇总")
            except Exception as exc:
                log(f"[summary] 失败: {type(exc).__name__}: {exc}")
        time.sleep(20)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.getenv("HUB_PORT", "8790")))
    ap.add_argument("--host", default=os.getenv("HUB_HOST", "0.0.0.0"))
    ap.add_argument("--db", default=os.getenv("HUB_DB", str(HERE / "data" / "hub.sqlite")))
    ap.add_argument("--config", default=os.getenv("HUB_CONFIG", str(HERE / "config.json")))
    args = ap.parse_args()

    cfg = load_config(args.config)
    hub = Hub(args.db, cfg, args.config)
    Handler.hub = hub
    Handler.cfg = cfg

    threading.Thread(target=summary_loop, args=(hub, cfg), daemon=True).start()
    threading.Thread(target=hub._pick_batch_loop, daemon=True).start()
    threading.Thread(target=deferred_loop, args=(cfg,), daemon=True).start()
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    log(f"[start] :{args.port} db={args.db} dry_run={cfg['dry_run']} "
        f"target={(cfg.get('qq_bridge') or {}).get('target')} "
        f"summary_at={cfg.get('summary_at')} log={LOG_PATH}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
