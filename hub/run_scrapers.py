#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""三家平台定时抓取 → 上报 parcel-hub（服务端常驻，替代手机 App）

运行：
    python run_scrapers.py --config config.json

工作方式：
    for 每个账号 × 每个平台：
        打开浏览器（复用登录态）→ 判断是否登录
          已登录：抓列表页 → 解析取件码 → POST /api/v1/report
          未登录：截二维码 → 落盘 → qq-bridge 推「点开链接扫码」
    每轮间隔 interval_min 分钟，重启容器不丢登录态（state/*.json）

改解析逻辑只需改 parsers/ 并重启容器，不用重新打包 App。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib import error, request
from urllib.parse import unquote

from playwright.sync_api import sync_playwright

from scrapers import SCRAPERS, atomic_write
import alerting

HERE = Path(__file__).resolve().parent
DEFAULTS = {
    "accounts": [{"id": "wo", "label": "我"}],
    "platforms": ["pdd", "taobao", "jd"],
    "interval_min": 30,
    "dry_run": True,
    "hub": {"url": "http://127.0.0.1:8790", "token": ""},
    "qq": {"url": "http://127.0.0.1:8787/notify", "token": "", "target": "group"},
    "qr": {"port": 8791, "token": "", "base": ""},
    "login_wait_sec": 300,
    # 定时任务是否在未登录时就地等扫码。
    # 默认 False：未绑定/掉登录态的平台直接跳过，等 Web 端「绑定」处理，
    # 避免几个平台串行等待把一轮拖到远超 interval_min。
    "wait_on_login": False,
    "state_dir": str(HERE / "state"),
    "dump_dir": str(HERE / "dump"),
}

QR_DIR = HERE / "state" / "qr"


def bind_time(cfg: dict, key: str) -> str:
    """登记并返回「首次绑定时间」。

    以前页面上的「绑定时间」取的是 state/<key>.json 的 mtime，而定时任务每轮
    成功都会重写该文件 → 绑定时间等于最近一轮抓取时间，完全不是绑定时间。
    现在首次保存登录态时登记一次，之后不再变化。
    """
    d = Path(cfg.get("state_dir") or (HERE / "state"))
    f = d / "bind_times.json"
    try:
        st = json.loads(f.read_text(encoding="utf-8")) if f.exists() else {}
    except Exception:
        st = {}
    if key not in st:
        st[key] = time.strftime("%Y-%m-%d %H:%M")
        try:
            d.mkdir(parents=True, exist_ok=True)
            tmp = f.with_suffix(".tmp")
            tmp.write_text(json.dumps(st, ensure_ascii=False, indent=1), encoding="utf-8")
            tmp.replace(f)
        except Exception:
            pass
    return st.get(key, "")


def set_status(cfg: dict, key: str, ok: bool, note: str = "") -> None:
    """记录某账号×平台「最近一轮登录态是否有效」，供 Web 端展示真实状态。

    只靠 state/<key>.json 是否存在判断「已绑定」是不够的：cookie 过期后文件还在，
    页面仍显示已绑定，用户就不知道为什么抓不到件。
    """
    try:
        d = Path(cfg.get("state_dir") or (HERE / "state"))
        f = d / "last_status.json"
        st = json.loads(f.read_text(encoding="utf-8")) if f.exists() else {}
        st[key] = {"ok": bool(ok), "ts": time.time(), "note": note}
        d.mkdir(parents=True, exist_ok=True)
        tmp = f.with_suffix(".tmp")
        tmp.write_text(json.dumps(st, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(f)
    except Exception:
        pass
# 秒：任务等待超过这个时长后再点「绑定」，视为二维码已过期，换一个新 worker 重新出码。
QR_REFRESH_AFTER = 150
_recent_notice: dict[str, float] = {}


LOG_FILE = Path(os.getenv("SCRAPER_LOG", str(HERE / "dump" / "run.log")))


def log(msg: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


# 把 run.log 的 logger 注入淘宝接口，抓不到件时能看到 ret / HTTP 状态
try:
    import taobao_api as _taobao_api
    _taobao_api.set_logger(log)
except Exception:
    pass


# ---------------------------------------------------------------- 按需登录（Web 端触发）
_LOGIN_LOCK = threading.Lock()
_LOGIN_TASKS: dict[str, dict] = {}


def _task_key(account: str, platform: str) -> str:
    return f"{account}_{platform}"


def _set_task(key: str, **kw) -> dict:
    with _LOGIN_LOCK:
        t = _LOGIN_TASKS.setdefault(key, {"key": key, "state": "idle"})
        t.update(kw)
        return dict(t)


def start_login_task(cfg: dict, account: str, platform: str, force: bool = False) -> dict:
    """Web 端点「绑定账号」用：按需触发某账号某平台的扫码登录。

    复用定时任务里那套 open_context/login_qr/wait_login 逻辑，
    区别只是由人按需触发，而不是等定时轮询发现未登录。

    重要：二维码 2 分钟左右就过期。如果任务已经等待超过 QR_REFRESH_AFTER 秒，
    再点「绑定」必须换一个新的 worker（旧 worker 会被 gen 校验劝退），
    否则会把几分钟前那张早已失效的二维码又显示一遍，用户怎么扫都扫不上。
    """
    key = _task_key(account, platform)
    gen = uuid.uuid4().hex
    with _LOGIN_LOCK:
        cur = _LOGIN_TASKS.get(key)
        if cur and cur.get("state") in ("running", "waiting"):
            if not force and time.time() - float(cur.get("started") or 0) < QR_REFRESH_AFTER:
                return dict(cur)   # 刚开过，直接把当前二维码给前端
            cur["message"] = "二维码已过期，正在重新打开…"
            cur["gen"] = gen        # 旧 worker 下一轮轮询会自行退出并关浏览器
    threading.Thread(target=_login_worker, args=(cfg, account, platform, gen, force),
                     daemon=True).start()
    return _set_task(key, state="running", account=account, platform=platform,
                     message="正在打开浏览器…", started=time.time(), gen=gen)


def _login_worker(cfg: dict, account: str, platform: str, gen: str = "",
                  force: bool = False) -> None:
    key = _task_key(account, platform)

    def stale() -> bool:
        """被新的「绑定」点击顶掉了吗？顶掉了就安静退出，别覆盖新任务的状态。"""
        if not gen:
            return False
        with _LOGIN_LOCK:
            cur = _LOGIN_TASKS.get(key) or {}
        return cur.get("gen") != gen

    try:
        from scrapers import SCRAPERS, atomic_write
        cls = SCRAPERS.get(platform)
        if not cls:
            _set_task(key, state="error", message=f"未知平台 {platform}")
            return
        state_dir = Path(cfg.get("state_dir") or (HERE / "state"))
        dump_dir = Path(cfg.get("dump_dir") or (HERE / "dump"))
        with sync_playwright() as pw:
            s = cls(account, state_dir, dump_dir)
            ctx = s.open_context(pw)
            try:
                # force=True：用户主动点「重新扫码」，即使 cookie 看起来还行也重新出码。
                # 否则 cookie 半失效时永远给「已是登录态」，用户永远扫不到新码。
                if s.is_logged_in(ctx) and not force:
                    set_status(cfg, key, True, "")
                    _set_task(key, state="done", message="已是登录态，无需扫码")
                    return
                png = s.login_qr(ctx)
                if stale():
                    return
                name = f"{key}.png"
                QR_DIR.mkdir(parents=True, exist_ok=True)
                atomic_write(QR_DIR / name, png)
                base = cfg.get("qr", {}).get("base", "")
                token = cfg.get("qr", {}).get("token", "")
                url = f"{base}/qr/{name}?t={token}" if base else ""
                _set_task(key, state="waiting", message="等待扫码", qr=name, url=url)
                timeout = int(cfg.get("login_wait_sec") or 900)
                last_url = {"v": ""}

                def tick(c, p):
                    # 把「当前页面 + cookie 名」暴露到 status 里：
                    # 扫码后到底跳没跳、pt_key/unb 有没有下发，一眼就能看出来。
                    try:
                        cur_url = p.url or ""
                    except Exception:
                        return
                    try:
                        names = sorted({x["name"] for x in c.cookies()})
                    except Exception:
                        names = []
                    _set_task(key, page_url=cur_url[:140],
                              cookie_names=",".join(names[:14]))
                    if cur_url != last_url["v"]:
                        last_url["v"] = cur_url
                        log(f"{key} 页面 → {cur_url[:120]}｜cookie {len(names)} 个")

                entered = s.wait_login(ctx, s._login_page, QR_DIR / name,
                                       timeout=timeout, should_stop=stale,
                                       on_tick=tick)
                if stale():
                    return
                if entered:
                    s.save_state(ctx)
                    bind_time(cfg, key)
                    # 扫码成功的瞬间就把「登录态正常」写进状态文件，
                    # 否则页面要等到下一轮定时抓取（最多 30 分钟）才变回正常。
                    set_status(cfg, key, True, "")
                    _set_task(key, state="done", message="登录成功，登录态已保存")
                else:
                    _set_task(key, state="timeout", message="二维码已过期，请重新点「绑定」")
            finally:
                try:
                    ctx._own_browser.close()
                except Exception:
                    pass
    except Exception as exc:
        if not stale():
            _set_task(key, state="error", message=f"{type(exc).__name__}: {exc}")


# ---------------------------------------------------------------- 账号增删（Web 端）
_CONFIG_LOCK = threading.Lock()
CONFIG_PATH = ""


def set_config_path(p: str) -> None:
    global CONFIG_PATH
    CONFIG_PATH = p


def _save_config(cfg: dict) -> None:
    """把账号变更写回 config.json（保留其他字段）。"""
    if not CONFIG_PATH or not Path(CONFIG_PATH).exists():
        return
    user = json.loads(Path(CONFIG_PATH).read_text(encoding="utf-8"))
    user["accounts"] = cfg["accounts"]
    tmp = Path(CONFIG_PATH).with_suffix(".json.tmp")
    tmp.write_text(json.dumps(user, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(Path(CONFIG_PATH))


def add_account(cfg: dict, aid: str, label: str, cfg_path: str = "") -> dict:
    """新增账号。id 限 2-16 位小写字母/数字/下划线，避免生成非法文件名。"""
    set_config_path(cfg_path or CONFIG_PATH)
    aid = (aid or "").strip().lower()
    label = (label or "").strip() or aid
    if not aid:
        return {"ok": False, "error": "账号 id 不能为空"}
    if not re.fullmatch(r"[a-z0-9_]{2,16}", aid):
        return {"ok": False, "error": "账号 id 只能用 2-16 位小写字母、数字或下划线"}
    with _CONFIG_LOCK:
        accounts = list(cfg.get("accounts") or [])
        if any(a.get("id") == aid for a in accounts):
            return {"ok": False, "error": f"账号 {aid} 已存在"}
        accounts.append({"id": aid, "label": label})
        cfg["accounts"] = accounts
        try:
            _save_config(cfg)
        except Exception as exc:
            return {"ok": False, "error": f"写配置失败：{exc}"}
    log(f"新增账号 {aid}（{label}）")
    return {"ok": True, "account": {"id": aid, "label": label}}


def remove_account(cfg: dict, aid: str, cfg_path: str = "") -> dict:
    """删除账号。至少保留一个，否则抓取无从下手。"""
    set_config_path(cfg_path or CONFIG_PATH)
    aid = (aid or "").strip()
    with _CONFIG_LOCK:
        accounts = list(cfg.get("accounts") or [])
        if len(accounts) <= 1:
            return {"ok": False, "error": "至少要保留一个账号"}
        new = [a for a in accounts if a.get("id") != aid]
        if len(new) == len(accounts):
            return {"ok": False, "error": f"账号 {aid} 不存在"}
        cfg["accounts"] = new
        try:
            _save_config(cfg)
        except Exception as exc:
            return {"ok": False, "error": f"写配置失败：{exc}"}
    log(f"删除账号 {aid}")
    return {"ok": True, "removed": aid}


def list_accounts(cfg: dict) -> list[dict]:
    """列出各账号在各平台的登录态，供 Web 端展示。"""
    from scrapers import SCRAPERS, atomic_write
    state_dir = Path(cfg.get("state_dir") or (HERE / "state"))
    try:
        _sf = state_dir / "last_status.json"
        _status = json.loads(_sf.read_text(encoding="utf-8")) if _sf.exists() else {}
    except Exception:
        _status = {}
    out = []
    for acct in cfg.get("accounts") or []:
        aid = acct.get("id", "")
        label = acct.get("label", aid)
        for pname in cfg.get("platforms") or list(SCRAPERS):
            f = state_dir / f"{aid}_{pname}.json"
            exists = f.exists()
            mtime = ""
            if exists:
                try:
                    mtime = time.strftime("%Y-%m-%d %H:%M",
                                          time.localtime(f.stat().st_mtime))
                except OSError:
                    pass
            _rec = _status.get(f"{aid}_{pname}") or {}
            try:
                _bf = state_dir / "bind_times.json"
                _bt = (json.loads(_bf.read_text(encoding="utf-8"))
                       if _bf.exists() else {}).get(f"{aid}_{pname}", "")
            except Exception:
                _bt = ""
            out.append({
                "account": aid,
                "label": label,
                "platform": pname,
                "display": getattr(SCRAPERS.get(pname), "display", pname),
                "bound": exists,
                "bound_at": _bt or mtime,
                "state_saved_at": mtime,
                "valid": _rec.get("ok"),
                "checked_at": (time.strftime("%Y-%m-%d %H:%M",
                                             time.localtime(_rec["ts"])) if _rec.get("ts") else ""),
                "note": _rec.get("note", ""),
            })
    return out


# ---------------------------------------------------------------- HTTP（二维码）
class QrHandler(BaseHTTPRequestHandler):
    token = ""
    hub_token = ""
    cfg: dict = None  # type: ignore
    config_path: str = ""

    def log_message(self, *a):
        pass

    def _json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _api_authed(self) -> bool:
        """Web 端调用的接口需要 hub token 鉴权。"""
        tok = self.hub_token or ""
        if not tok:
            return True
        return self.headers.get("X-Hub-Token", "") == tok

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            return {}

    def do_POST(self):
        path, _, query = self.path.partition("?")
        body = self._body()
        if path == "/api/login/start":
            if not self._api_authed():
                self._json(401, {"ok": False, "error": "unauthorized"})
                return
            q = dict(kv.split("=", 1) for kv in query.split("&") if "=" in kv)
            account = unquote(q.get("account", ""))
            platform = unquote(q.get("platform", ""))
            force = unquote(q.get("force", "")) in ("1", "true", "yes")
            if not account or not platform:
                self._json(400, {"ok": False, "error": "缺少 account 或 platform"})
                return
            task = start_login_task(self.cfg or {}, account, platform, force=force)
            self._json(200, {"ok": True, "task": task})
            return
        if path == "/api/accounts/add":
            if not self._api_authed():
                self._json(401, {"ok": False, "error": "unauthorized"})
                return
            self._json(200, add_account(self.cfg or {}, body.get("id", ""),
                                         body.get("label", ""), self.config_path))
            return
        if path == "/api/accounts/remove":
            if not self._api_authed():
                self._json(401, {"ok": False, "error": "unauthorized"})
                return
            self._json(200, remove_account(self.cfg or {}, body.get("id", ""),
                                           self.config_path))
            return
        self._json(404, {"ok": False, "error": "not found"})

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/health":
            body = json.dumps({"ok": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/api/accounts":
            if not self._api_authed():
                self._json(401, {"ok": False, "error": "unauthorized"})
                return
            self._json(200, {"ok": True, "accounts": list_accounts(self.cfg or {})})
            return
        if path == "/api/login/status":
            if not self._api_authed():
                self._json(401, {"ok": False, "error": "unauthorized"})
                return
            q = dict(kv.split("=", 1) for kv in query.split("&") if "=" in kv)
            key = f"{unquote(q.get('account', ''))}_{unquote(q.get('platform', ''))}"
            with _LOGIN_LOCK:
                task = dict(_LOGIN_TASKS.get(key) or {"state": "idle"})
            # 带上二维码版本号：wait_login 每 15s 重截一次图，mtime 变化即代表二维码换了。
            # 前端靠它决定是否重新拉图，避免每 3s 无条件重建 <img> 导致画面闪烁/回退。
            if task.get("qr"):
                try:
                    task["qr_ts"] = int((QR_DIR / task["qr"]).stat().st_mtime)
                except OSError:
                    pass
            self._json(200, {"ok": True, "task": task})
            return
        if path.startswith("/qr/"):
            t = ""
            for kv in query.split("&"):
                k, _, v = kv.partition("=")
                if k == "t":
                    t = v
            if self.token and t != self.token:
                self.send_response(403)
                self.end_headers()
                return
            f = QR_DIR / path[len("/qr/"):]
            if not f.exists() or f.suffix != ".png":
                self.send_response(404)
                self.end_headers()
                return
            data = f.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404)
        self.end_headers()


def start_qr_server(port: int, token: str, hub_token: str = "", cfg: dict | None = None,
                    config_path: str = "") -> None:
    QrHandler.token = token
    QrHandler.hub_token = hub_token
    QrHandler.cfg = cfg
    QrHandler.config_path = config_path
    set_config_path(config_path)
    srv = ThreadingHTTPServer(("0.0.0.0", port), QrHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log(f"二维码服务 :{port}")


# ---------------------------------------------------------------- 推送 / 上报
def notify(cfg: dict, content: str) -> None:
    qq = cfg["qq"]
    if not qq.get("url"):
        log("[notify] 未配置 qq-bridge")
        return
    body = json.dumps({"target": qq.get("target", "group"), "content": content}).encode()
    req = request.Request(qq["url"], data=body, method="POST",
                          headers={"Content-Type": "application/json",
                                   "X-Bridge-Token": qq.get("token", "")})
    try:
        with request.urlopen(req, timeout=10):
            pass
    except Exception as exc:
        log(f"[notify] 失败：{exc}")


def report(cfg: dict, account: str, packages: list[dict], platform: str = "",
           authoritative: bool = False) -> None:
    hub = cfg["hub"]
    payload = {
        "device": account,
        "snapshot": True,
        "packages": packages,
    }
    # 带上平台范围：即使本轮 0 件，hub 也知道这次快照覆盖了哪个平台，
    # 可以把该平台上「本次没出现」的老件标 stale，而不会误伤别的平台。
    # 但只有「权威快照」才允许这么判——解析失败导致的 0 件不能当成真的清空了。
    if platform and authoritative:
        payload["platforms"] = [platform]
    if cfg.get("dry_run"):
        log(f"[dry-run] {account} 上报 {len(packages)} 件："
            + ", ".join(p.get("pickup_code", "?") for p in packages[:5]))
        return
    req = request.Request(f"{hub['url']}/api/v1/report",
                          data=json.dumps(payload).encode(), method="POST",
                          headers={"Content-Type": "application/json",
                                   "X-Hub-Token": hub.get("token", "")})
    try:
        with request.urlopen(req, timeout=15) as r:
            log(f"[hub] {account} {r.status}")
    except Exception as exc:
        log(f"[hub] 上报失败：{exc}")


WEB_URL = "https://parcel.example.com/"


def hub_alert(cfg: dict, text: str, title: str = "账号提醒") -> None:
    """把提醒交给 hub 推送：目标（私聊/群聊）由 hub 的配置统一决定。"""
    hub = cfg.get("hub") or {}
    url = (hub.get("url") or "").rstrip("/")
    if not url:
        return
    req = request.Request(
        f"{url}/api/v1/alert",
        data=json.dumps({"text": text, "title": title}).encode(),
        method="POST",
        headers={"Content-Type": "application/json",
                 "X-Hub-Token": hub.get("token", "")},
    )
    try:
        with request.urlopen(req, timeout=10) as r:
            log(f"[alert] 已推送提醒（hub {r.status}）：{text.splitlines()[0]}")
    except Exception as exc:
        log(f"[alert] 提醒推送失败：{exc}")


def login_alert(cfg: dict, key: str, label: str, display: str, ok: bool) -> None:
    """登录态变化时提醒一次；持续失效按 12h 冷却重复提醒。"""
    state_path = Path(cfg.get("state_dir") or (HERE / "state")) / "login_notify.json"
    state = "ok" if ok else "lost"
    if not alerting.should_notify(state_path, key, state):
        return
    web = (cfg.get("web_url") or WEB_URL).rstrip("/")
    if ok:
        text = f"✅ {label} 的{display}登录已恢复，抓取继续。"
    else:
        text = (f"⚠️ {label} 的{display}登录态已失效，该平台抓取暂停。\n"
                f"打开 {web} → 账号绑定 → 点「{display}」重新扫码。")
    hub_alert(cfg, text)


def ask_login(cfg: dict, key: str, account_label: str, platform_display: str,
              png: bytes, name: str) -> None:
    """把二维码落盘并推送链接（同一 key 30 分钟内不重复提醒）"""
    QR_DIR.mkdir(parents=True, exist_ok=True)
    atomic_write(QR_DIR / name, png)
    last = _recent_notice.get(key, 0)
    if time.time() - last < 1800:
        return
    _recent_notice[key] = time.time()

    base = cfg["qr"].get("base", "")
    token = cfg["qr"].get("token", "")
    if base:
        url = f"{base}/qr/{name}?t={token}"
        notify(cfg, f"🔑 {account_label} 的{platform_display}登录已失效\n"
                    f"请用电脑打开下面的链接，再用手机对应 App 扫码：\n{url}")
    else:
        notify(cfg, f"🔑 {account_label} 的{platform_display}登录已失效，"
                    f"二维码已保存到 NAS：state/qr/{name}")


# ---------------------------------------------------------------- 主循环
def run_once(cfg: dict) -> None:
    state_dir = Path(cfg["state_dir"])
    dump_dir = Path(cfg["dump_dir"])
    # 只有「已经登录过、只是这次掉了登录态」的平台才值得在定时任务里等扫码。
    # 首次接入的平台（还没绑定）若也等 login_wait_sec（默认 900s），
    # 几个平台串行下来一轮远超抓取间隔，反而把已跑通的平台饿死。
    # 这类平台一律交给 Web 端「绑定」按钮处理，定时任务里只留日志。
    wait_on_login = bool(cfg.get("wait_on_login", False))
    with sync_playwright() as pw:
        for account in cfg["accounts"]:
            aid, label = account["id"], account.get("label", account["id"])
            for pname in cfg["platforms"]:
                cls = SCRAPERS.get(pname)
                if not cls:
                    continue
                s = cls(aid, state_dir, dump_dir)
                key = f"{aid}_{pname}"
                ctx = None
                try:
                    ever_bound = s.state_file.exists()
                    if not ever_bound and not wait_on_login:
                        log(f"{key} 未绑定，跳过（Web 端「账号绑定」扫码后自动纳入）")
                        continue
                    ctx = s.open_context(pw)
                    res = s.scrape(ctx)
                    set_status(cfg, key, res.logged_in,
                               "" if res.logged_in else "登录态失效")
                    if not res.logged_in:
                        if not wait_on_login:
                            log(f"{key} 登录态失效，出码待扫码（Web 端点「重新扫码」）")
                            login_alert(cfg, key, label, s.display, ok=False)
                            continue
                        png = s.login_qr(ctx)
                        name = f"{key}.png"
                        ask_login(cfg, key, label, s.display, png, name)
                        log(f"{key} 未登录，已出码，等待扫码（{cfg['login_wait_sec']}s）")
                        if s.wait_login(ctx, s._login_page,
                                        QR_DIR / name,
                                        timeout=int(cfg["login_wait_sec"])):
                            s.save_state(ctx)
                            notify(cfg, f"✅ {label} 的{s.display}已登录")
                            log(f"{key} 扫码成功，登录态已保存")
                        else:
                            log(f"{key} 等待扫码超时")
                        continue
                    if ctx:
                        s.save_state(ctx)
                        bind_time(cfg, key)
                    login_alert(cfg, key, label, s.display, ok=True)
                    # 无论是否命中都上报全量快照。
                    # 原因：平台把已取走的件从「待取件」列表移走后，页面里就查不到取件码了。
                    # 若只在命中时上报，那件会永远停在 hub 的 arrived 状态，
                    # 每天 17:00 汇总都会推一个早就取走的件。
                    report(cfg, aid, res.packages, pname, res.authoritative)
                    if res.packages:
                        arrived = [p for p in res.packages if p.get("status") == "arrived"]
                        picked = [p for p in res.packages if p.get("status") == "picked"]
                        log(f"{key} 命中 {len(arrived)} 件待取 / {len(picked)} 件已签收")
                    else:
                        if res.authoritative:
                            log(f"{key} 已登录，接口正常，当前 0 件（快照权威）")
                        else:
                            log(f"{key} 已登录但未解析到包裹"
                                f"（页面 {len(res.text)} 字，快照非权威）")
                except Exception as exc:
                    log(f"{key} 异常：{type(exc).__name__}: {exc}")
                    set_status(cfg, key, False, f"{type(exc).__name__}")
                finally:
                    if ctx is not None:
                        try:
                            ctx._own_browser.close()
                        except Exception:
                            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.getenv("SCRAPER_CONFIG", str(HERE / "config.json")))
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()

    cfg = json.loads(json.dumps(DEFAULTS))
    if Path(args.config).exists():
        user = json.loads(Path(args.config).read_text(encoding="utf-8"))
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v

    start_qr_server(int(cfg["qr"].get("port", 8791)), cfg["qr"].get("token", ""),
                    cfg["hub"].get("token", ""), cfg, args.config)
    log(f"启动：账号 {[a['id'] for a in cfg['accounts']]}，平台 {cfg['platforms']}，"
        f"间隔 {cfg['interval_min']}min，dry_run={cfg['dry_run']}")

    while True:
        t0 = time.time()
        run_once(cfg)
        if args.once:
            return 0
        wait = max(60, int(cfg["interval_min"] * 60 - (time.time() - t0)))
        log(f"本轮结束，{wait}s 后再跑")
        time.sleep(wait)


if __name__ == "__main__":
    raise SystemExit(main())
