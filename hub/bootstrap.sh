#!/bin/sh
# 首次启动安装 chromium + playwright（装在挂载卷里，重启不重装）
# ⚠️ 容器日志读不到（fnOS 的 containerLogs 端点不存在），所以把过程日志
# 写到挂载卷的 dump/bootstrap.log，出问题能直接看，不用猜。
LOG=/app/dump/bootstrap.log
mkdir -p /app/dump 2>/dev/null || true
say() {
  echo "[bootstrap] $*" | tee -a "$LOG" 2>/dev/null || echo "[bootstrap] $*"
}
say "=== 启动 $(date '+%F %T') ==="

export PLAYWRIGHT_BROWSERS_PATH=/app/.pw-browsers

if [ ! -x /app/.venv/bin/python ]; then
  say "创建 venv 并安装 playwright"
  python -m venv /app/.venv
  /app/.venv/bin/pip install -q --upgrade pip
  /app/.venv/bin/pip install -q playwright
  say "venv 就绪"
fi

# 浏览器可执行文件：优先系统 chromium，其次 Playwright 自带浏览器。
# 两者都装在挂载卷 /app/.pw-browsers 或系统路径，容器重建也不该丢。
have_browser() {
  # ⚠️ 必须用 `-x` 判「可执行」，不能只判目录/文件存在。
  # Playwright 解包时会先建目录再写文件，中途失败会留下空目录，
  # 只看存在性会把「装了一半」误判成「装好了」，然后启动失败。
  for c in /usr/bin/chromium \
           /app/.pw-browsers/chromium-*/chrome-linux/chrome \
           /app/.pw-browsers/chromium_headless_shell-*/chrome-linux/headless_shell; do
    [ -x "$c" ] && return 0
  done
  return 1
}

if ! have_browser; then
  say "系统 chromium 缺失，尝试 apt 安装"
  # ⚠️ 国内直连 Debian 官方源极慢，先切阿里云镜像。
  # python:3.11-slim 用 deb822 格式的 /etc/apt/sources.list.d/debian.sources，
  # 不只是老的 sources.list，两种都要改。
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    sed -i 's|deb\.debian\.org|mirrors.aliyun.com|g; s|security\.debian\.org|mirrors.aliyun.com|g; s|http://deb\.debian\.org|http://mirrors.aliyun.com|g' \
      "$f" 2>/dev/null || true
  done
  {
    echo "deb http://mirrors.aliyun.com/debian bookworm main"
    echo "deb http://mirrors.aliyun.com/debian bookworm-updates main"
    echo "deb http://mirrors.aliyun.com/debian-security bookworm-security main"
  } > /etc/apt/sources.list 2>/dev/null || true
  apt-get update -qq >/tmp/aptupd.log 2>&1 || tail -3 /tmp/aptupd.log | tee -a "$LOG" 2>/dev/null || true
  # ⚠️ 只装 chromium 本身，让 apt 自己解依赖。
  # 早先手动点名 libatk1.0-0 等包 → 与新版 chromium 依赖的 libatk1.0-0t64 冲突
  # （libatk1.0-0t64 Breaks libatk1.0-0），apt 直接报
  # "Unable to correct problems, you have held broken packages" 而装不上。
  # ⚠️ 另：不能用 `if ! cmd | tee`，那判断的是 tee 的退出码而非 apt 的。
  # 这里用临时文件取真实退出码。
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      chromium fonts-noto-cjk fonts-noto-color-emoji >/tmp/apt.log 2>&1; then
    say "系统 chromium 安装失败 → 改用 Playwright 自带浏览器"
    tail -5 /tmp/apt.log | tee -a "$LOG" 2>/dev/null || true
  else
    say "系统 chromium 就绪"
  fi
fi

if ! have_browser; then
  say "安装 Playwright 自带浏览器到挂载卷（容器重建也不丢）"
  # ⚠️ Playwright 默认 CDN 在国内极慢（实测 18 分钟仍未下完），
  # 走 npmmirror 镜像。镜像缺某个版本时回落到官方源。
  if ! PLAYWRIGHT_DOWNLOAD_HOST=https://cdn.npmmirror.com/binaries/playwright \
      /app/.venv/bin/python -m playwright install chromium >/tmp/pw.log 2>&1; then
    say "镜像源安装失败，回落官方源重试"
    if ! /app/.venv/bin/python -m playwright install chromium >/tmp/pw2.log 2>&1; then
      say "Playwright 浏览器安装失败"
      tail -10 /tmp/pw.log 2>/dev/null | tee -a "$LOG" 2>/dev/null || true
      tail -10 /tmp/pw2.log 2>/dev/null | tee -a "$LOG" 2>/dev/null || true
      exit 1
    fi
    tail -3 /tmp/pw2.log | tee -a "$LOG" 2>/dev/null || true
  else
    tail -3 /tmp/pw.log | tee -a "$LOG" 2>/dev/null || true
  fi
  say "Playwright 浏览器就绪"
fi

export CHROMIUM_PATH=/usr/bin/chromium
export TZ=Asia/Shanghai

# 探测模式：跑一次平台登录可行性检查就退出，不进常驻循环。
# 用 `docker container run -e PARCEL_MODE=probe` 触发，
# 好处是复用上面这套浏览器安装流程（不必另建容器再折腾一遍）。
if [ "${PARCEL_MODE:-}" = "probe" ]; then
  say "探测模式：检查淘宝/京东桌面端扫码可行性"
  /app/.venv/bin/python /app/probe_login_feasibility.py 2>&1 | tee -a "$LOG" 2>/dev/null || true
  say "探测完成，结果见 dump/probe_<platform>.txt"
  exit 0
fi

say "启动 run_scrapers"
exec /app/.venv/bin/python /app/run_scrapers.py --config /app/config.json
