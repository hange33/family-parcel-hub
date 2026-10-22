#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""拼多多解析器回归测试 —— 用真实 dump，不依赖 Playwright / 网络。

跑法：
    python test_pdd_parser.py [dump目录]

默认 dump 目录 = 本文件同级的 dump/。
用例基于 2026-10-20 NAS 上抓到的三份真实页面：
    wo_pdd_20261020-194336  19:43 轮：4 件（3 已签收 + 1 待取件）
    wo_pdd_20261020-201335  20:13 轮：同 19:43（这件还没取）
    wo_pdd_20261020-204334  20:43 轮：4 件全部已签收（取件码已从页面消失）
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.stdout.reconfigure(encoding="utf-8")

from parsers.pdd import extract_raw_data, parse_page, parse_text  # noqa: E402

FAILURES: list[str] = []


def check(cond: bool, msg: str) -> None:
    if cond:
        print(f"  [PASS] {msg}")
    else:
        print(f"  [FAIL] {msg}")
        FAILURES.append(msg)


def load(dump_dir: Path, stem: str) -> tuple[str, str]:
    txt = dump_dir / f"{stem}.txt"
    htm = dump_dir / f"{stem}.html"
    text = txt.read_text(encoding="utf-8") if txt.exists() else ""
    html = htm.read_text(encoding="utf-8") if htm.exists() else ""
    return text, html


def main() -> int:
    dump_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / "dump"
    if not dump_dir.is_dir():
        print(f"dump 目录不存在：{dump_dir}")
        return 2

    stems = sorted(p.stem for p in dump_dir.glob("wo_pdd_*.html"))
    if not stems:
        print(f"{dump_dir} 里没有 wo_pdd_*.html，无法回归")
        return 2

    for stem in stems:
        text, html = load(dump_dir, stem)
        print(f"\n===== {stem} =====")

        # 1) 结构化数据可提取
        raw = extract_raw_data(html)
        check(raw is not None, "rawData 可从 HTML 提取")
        if not raw:
            continue

        # 2) 解析结果
        items = parse_page(text, html)
        check(len(items) == 4, f"解析出 4 件包裹（实际 {len(items)}）")

        # 3) 每件都有稳定去重键（运单号）
        missing_key = [i for i in items if not i.get("order_id")]
        check(not missing_key, f"每件都有 order_id（缺失 {len(missing_key)} 件）")
        check(len({i["order_id"] for i in items}) == len(items), "order_id 互不重复")

        # 4) 已签收 / 待取件 状态分类正确
        picked = [i for i in items if i["status"] == "picked"]
        arrived = [i for i in items if i["status"] == "arrived"]
        # 19:43 / 20:13 两轮：3 已签收 + 1 待取件；20:43 那轮件已取走 → 4 全签收
        expect_picked = 4 if "204334" in stem else 3
        check(len(picked) == expect_picked,
              f"{expect_picked} 件已签收（实际 {len(picked)}）")

        # 5) 运单号与取件码的对应正确
        by_code = {i["pickup_code"]: i for i in items if i.get("pickup_code")}
        if "204334" not in stem:
            check("1-2-0001" in by_code, "取件码 1-2-0001 被解析到")
            if "1-2-0001" in by_code:
                it = by_code["1-2-0001"]
                check(it["order_id"] == "9000000000001",
                      f"取件码 1-2-0001 对应运单号 9000000000001（实际 {it['order_id']}）")
                check(it["station"] == "示例小区1栋101",
                      f"驿站地址正确（实际 {it['station']}）")
                check(it["goods"] == "川珍八角250g袋装广西大料茴香烧炖卤肉调料香辛料家庭装火锅佐料",
                      f"商品名来自 rawData（实际 {it['goods'][:20]}…）")
                check(it["courier"] == "邮政", f"快递公司识别正确（实际 {it['courier']}）")

        # 6) 末轮（件已取走）不应再有 arrived 件
        if "204334" in stem:
            check(len(arrived) == 0,
                  f"20:43 轮件已取走，arrived 件应为 0（实际 {len(arrived)}）")
            check(len(picked) == 4, f"20:43 轮 4 件全部已签收（实际 {len(picked)}）")
            check(not by_code, "20:43 轮页面已无取件码")

    # 7) 文本兜底路径不能崩，且仍能捞出取件码
    text, html = load(dump_dir, stems[0])
    fallback = parse_text(text)
    check(len(fallback) >= 1, f"文本兜底解析仍能捞出取件码（{len(fallback)} 件）")
    check(all(i["status"] == "arrived" for i in fallback), "文本兜底只报 arrived")

    # 8) 空输入不崩
    check(parse_page("", "") == [], "空输入返回空列表")
    check(parse_page("随便一段文字", "<html></html>") == [], "无 rawData 且无匹配码返回空列表")

    print("\n" + "=" * 60)
    if FAILURES:
        print(f"失败 {len(FAILURES)} 项：")
        for f in FAILURES:
            print("  -", f)
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
