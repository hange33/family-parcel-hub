#!/usr/bin/env bash
# 提交前检查：test/ 下不能出现真实手机号（仓库是公开的）。
# 覆盖：连写 11 位、+86/86 前缀、空格或横杠分隔（如 138 0000 1111、138-0000-1111）。
# 用法：bash tools/check_no_pii.sh   （发现可疑内容时返回非 0）
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d test ] || exit 0
re='(^|[^0-9])((\+|＋)?86[ -]?)?1[3-9][0-9]([ -]?[0-9]){8}([^0-9]|$)'
hits=$(grep -rEn --include='*.txt' --include='*.json' --include='*.dart' \
  "$re" test/ --exclude-dir=fixtures_private || true)
if [ -n "$hits" ]; then
  echo "发现疑似真实手机号，请先脱敏（替换成 1**********）："
  echo "$hits"
  exit 1
fi
echo "OK：test/ 下没有发现手机号"
