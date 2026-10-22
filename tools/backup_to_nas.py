#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把「项目源码 + 签名密钥」备份到 NAS。

用法（在家/公司电脑都能跑，需要能连 NAS）：
    python tools/backup_to_nas.py

产出与去向：
    backup/family-parcel-hub/family-parcel-hub-<日期>.bundle   ← git bundle（含全部提交与 tag）
    obsidian/vaults/knowledge-base/raw/credentials/
        family-parcel-hub-keystore-<日期>.zip                  ← 签名密钥 + 口令

为什么用 git bundle：单个文件即完整仓库，恢复时 `git clone <bundle>` 即可，不依赖 GitHub。

⚠️ 密钥库存放于 vault 的 credentials 目录（与本项目其他凭据一致），
   仓库不要转为公开，密钥不要外传。
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO.parent / "backup"

sys.path.insert(0, r"D:\workbuddy\70-基础设施-凭据")
sys.path.insert(0, r"D:\workbuddy\70-基础设施-WebDAV备份")


def make_bundle(date: str) -> Path:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / f"family-parcel-hub-{date}.bundle"
    subprocess.run(
        ["git", "bundle", "create", str(out), "--all"],
        cwd=REPO, check=True,
    )
    return out


def make_keystore_zip(date: str) -> Path | None:
    src = REPO / "android" / "keystore"
    if not src.exists():
        print("跳过密钥库：目录不存在")
        return None
    out = OUT_DIR / f"family-parcel-hub-keystore-{date}.zip"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name in ("hub-release.p12", "keystore.properties", "README.md"):
            p = src / name
            if p.exists():
                z.write(p, name)
    return out


def upload() -> None:
    import cred
    from webdav_client import CurlWebDAV

    boot = cred._bootstrap()
    dav = CurlWebDAV(
        "https://dav.example.com/共享目录/backup",
        boot["username"], boot["password"],
    )
    dav.ensure_collection("family-parcel-hub")
    for p in sorted(OUT_DIR.glob("family-parcel-hub-*.bundle")):
        dav.put_local(f"family-parcel-hub/{p.name}", str(p))
        print("uploaded", p.name)

    vault = CurlWebDAV(
        "https://dav.example.com/共享目录/"
        "obsidian/vaults/knowledge-base/raw/credentials",
        boot["username"], boot["password"],
    )
    for p in sorted(OUT_DIR.glob("family-parcel-hub-keystore-*.zip")):
        vault.put_local(p.name, str(p))
        print("uploaded", p.name)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default=dt.date.today().strftime("%Y%m%d"))
    ap.add_argument("--no-upload", action="store_true")
    args = ap.parse_args()

    bundle = make_bundle(args.date)
    print("bundle:", bundle, bundle.stat().st_size // 1024, "KB")
    ks = make_keystore_zip(args.date)
    if ks:
        print("keystore:", ks, ks.stat().st_size, "B")

    if not args.no_upload:
        upload()
    print("完成。恢复方式见 docs/family-hub/备份与恢复.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
