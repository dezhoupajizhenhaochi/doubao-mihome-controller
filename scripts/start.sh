#!/usr/bin/env bash
# =============================================================================
# 豆包工作 × 米家设备控制器 - 健壮启动脚本
#
# 用途:  日常启动 Home Assistant；crontab @reboot 亦调用本脚本。
# 特性:  ① venv 解释器自愈（bin/python 指向 uv 托管目录，环境/设备切换后
#         该目录可能消失 → "hass: No such file or directory"；自动用 uv 重建）
#         ② 防 pkill 自杀启动（'[v]env/bin/hass' 方括号模式）
#         ③ 就绪轮询（等到 http://127.0.0.1:8123 可访问）
# 用法:  bash ~/hass/start.sh
# =============================================================================
set -uo pipefail

HA_DIR="${HA_DIR:-$HOME/hass}"
HA_PORT=8123
PY_VER=3.14
PYBIN="$HA_DIR/.venv/bin/python"

log()  { echo -e "\033[1;32m[start]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

# ---------- 0. venv 解释器自愈 ----------
if [ ! -x "$PYBIN" ] || ! "$PYBIN" --version >/dev/null 2>&1; then
  warn "venv 解释器失效（uv 托管目录丢失？），开始自愈..."
  command -v uv >/dev/null 2>&1 || { curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1; export PATH="$HOME/.local/bin:$PATH"; }
  command -v uv >/dev/null || die "uv 不可用，无法自愈解释器；请先安装 uv"
  uv python install "$PY_VER" >/dev/null 2>&1
  if [ -d "$HA_DIR/.venv" ]; then
    # 优先只重建 python 链接；若仍不可用则重建整个 venv 并重装依赖
    UV_PY="$(uv python find "$PY_VER" 2>/dev/null)" || UV_PY=""
    if [ -n "$UV_PY" ] && [ -x "$UV_PY" ]; then
      ln -sf "$UV_PY" "$PYBIN"
    fi
    if ! "$PYBIN" --version >/dev/null 2>&1; then
      warn "仅重建链接不可用，重建整个 venv（包将重装，可能需数分钟）..."
      rm -rf "$HA_DIR/.venv"
      uv venv --python "$PY_VER" "$HA_DIR/.venv"
      log "重装 Home Assistant 与依赖（自愈）..."
      uv pip install --python "$PYBIN" homeassistant paho-mqtt construct numpy cryptography psutil
    fi
  else
    uv venv --python "$PY_VER" "$HA_DIR/.venv"
  fi
  "$PYBIN" --version >/dev/null 2>&1 || die "解释器自愈失败，请手动检查 $HA_DIR"
fi

# ---------- 1. 防自杀启动 ----------
if pgrep -f '[v]env/bin/hass' >/dev/null; then
  log "HA 已在运行，跳过启动"
else
  log "启动 Home Assistant ..."
  nohup "$HA_DIR/.venv/bin/hass" -c "$HA_DIR/config" >> "$HA_DIR/hass.log" 2>&1 &
  echo $! > "$HA_DIR/hass.pid"
fi

# ---------- 2. 就绪轮询 ----------
log "等待 HA 就绪 (端口 $HA_PORT)..."
for i in $(seq 1 36); do
  if curl -sf -o /dev/null "http://127.0.0.1:$HA_PORT/" 2>/dev/null; then
    log "HA 已就绪: http://127.0.0.1:$HA_PORT"
    exit 0
  fi
  sleep 5
done
die "HA 未在预期时间内就绪，请查看 $HA_DIR/hass.log"
