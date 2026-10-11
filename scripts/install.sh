#!/usr/bin/env bash
# =============================================================================
# 豆包工作 × 米家设备控制器 - 一键安装脚本（云电脑 / macOS 通用）
#
# 用法:  bash install.sh
# 要求:  无 sudo / 无 docker 亦可；需要外网（pypi / github / 小米云）
# 产物:  ~/hass/.venv (Python 3.14 + Home Assistant + 依赖)
#        ~/hass/config (含小米官方集成 ha_xiaomi_home)
#        ~/hass/.admin_password (HA 管理员密码, 权限 600)
#        ~/hass/start.sh (健壮启动脚本, 含 venv 解释器自愈)
#        crontab @reboot 开机自启 (调用 start.sh)
# 之后:  浏览器 GUI 完成 2 步（小米 OAuth 授权、创建长期令牌），详见输出指引
#
# 变更记录:
#  - 修复 onboarding/users 仅传 name 导致 HA 2026.2+ 报错 (curl 22)：
#    补全 password/username/language 字段，并自动生成随机密码落盘 .admin_password。
#  - onboarding 失败不再中止脚本：改为 warn 继续，保证 crontab 开机自启无条件写入。
#  - 新增 venv 解释器自愈：venv 的 bin/python 指向 uv 托管目录，环境/设备切换后
#    该目录可能消失导致 "hass: No such file or directory"；安装时与 start.sh 均会自检重建。
# =============================================================================
set -uo pipefail

HA_DIR="${HA_DIR:-$HOME/hass}"
HA_PORT=8123
PY_VER=3.14
HA_XIAOMI_REPO="https://github.com/XiaoMi/ha_xiaomi_home.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYBIN="$HA_DIR/.venv/bin/python"

log()  { echo -e "\033[1;32m[install]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

# ---------- 0. 基础检查 ----------
command -v curl >/dev/null || die "需要 curl"
command -v git  >/dev/null || die "需要 git"
command -v python3 >/dev/null || die "需要 python3"

# ---------- 0.5 venv 解释器自愈（环境切换后 uv 托管目录可能丢失） ----------
ensure_pybin() {
  if [ ! -x "$PYBIN" ] || ! "$PYBIN" --version >/dev/null 2>&1; then
    warn "venv 解释器失效（可能因环境/设备切换，uv 托管目录丢失）"
    command -v uv >/dev/null 2>&1 || { warn "未找到 uv，尝试安装..."; curl -LsSf https://astral.sh/uv/install.sh | sh; export PATH="$HOME/.local/bin:$PATH"; }
    command -v uv >/dev/null || die "uv 不可用，无法自愈解释器"
    log "用 uv 重新安装 Python ${PY_VER} 并重建 venv 链接..."
    uv python install "$PY_VER"
    # 若 venv 已存在但链接损坏：直接重建成新的空 venv 会丢包，这里仅重建 bin/python 链接不可行，
    # 稳妥做法是强制重装同版本解释器后重建 venv（包会通过下方 uv pip install 重装）。
    if [ -d "$HA_DIR/.venv" ]; then
      # 优先只重建 python 链接（uv python find 返回解释器真实路径）；若仍不可用则重建整个 venv
      UV_PY="$(uv python find "$PY_VER" 2>/dev/null)" || UV_PY=""
      if [ -n "$UV_PY" ] && [ -x "$UV_PY" ]; then
        ln -sf "$UV_PY" "$PYBIN"
      fi
      if ! "$PYBIN" --version >/dev/null 2>&1; then
        warn "仅重建链接不可用，重建整个 venv（后续步骤会重装依赖）..."
        rm -rf "$HA_DIR/.venv"
        uv venv --python "$PY_VER" "$HA_DIR/.venv"
      fi
    else
      uv venv --python "$PY_VER" "$HA_DIR/.venv"
    fi
    "$PYBIN" --version || die "解释器自愈失败，请手动检查"
  fi
}

# ---------- 1. uv + Python 3.14 + venv（预编译，免编译坑） ----------
if ! command -v uv >/dev/null 2>&1; then
  log "安装 uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v uv >/dev/null || die "uv 安装失败，请手动安装后重试"

log "安装预编译 Python ${PY_VER}（避免编译失败导致前端卡死）..."
uv python install "$PY_VER"
log "创建虚拟环境 $HA_DIR/.venv ..."
mkdir -p "$HA_DIR"
uv venv --python "$PY_VER" "$HA_DIR/.venv"
ensure_pybin
log "Python 版本: $("$PYBIN" --version)"

# ---------- 2. 安装 HA + 小米集成依赖（一次装全） ----------
log "安装 Home Assistant 与依赖..."
uv pip install --python "$PYBIN" homeassistant
# ha_xiaomi_home 依赖；paho-mqtt 漏装会导致集成不加载（历史坑）
uv pip install --python "$PYBIN" paho-mqtt construct numpy cryptography psutil

# ---------- 3. 小米官方集成 ----------
log "克隆小米官方集成 ha_xiaomi_home ..."
TMP_REPO="$(mktemp -d)"
git clone --depth 1 "$HA_XIAOMI_REPO" "$TMP_REPO" || die "克隆 ha_xiaomi_home 失败"
mkdir -p "$HA_DIR/config/custom_components"
if [ -d "$TMP_REPO/custom_components/xiaomi_home" ]; then
  cp -r "$TMP_REPO/custom_components/xiaomi_home" "$HA_DIR/config/custom_components/"
  log "已安装 xiaomi_home 自定义集成"
else
  warn "未找到 custom_components/xiaomi_home，请检查仓库结构"
fi
rm -rf "$TMP_REPO"

# ---------- 4. 启动 HA + 部署 start.sh ----------
cp "$SCRIPT_DIR/start.sh" "$HA_DIR/start.sh" && chmod +x "$HA_DIR/start.sh"
log "已部署健壮启动脚本 $HA_DIR/start.sh（含解释器自愈 + 就绪轮询）"

if pgrep -f '[v]env/bin/hass' >/dev/null; then
  warn "检测到 HA 已在运行，跳过启动"
else
  log "启动 Home Assistant（首次启动约 60-90 秒）..."
  "$HA_DIR/start.sh" &
  echo $! > "$HA_DIR/hass.pid"
fi

log "等待 HA 就绪 (端口 $HA_PORT)..."
for i in $(seq 1 30); do
  if curl -sf -o /dev/null "http://127.0.0.1:$HA_PORT/" 2>/dev/null; then
    break
  fi
  sleep 5
  [ "$i" = 30 ] && die "HA 未在预期时间内就绪，请查看 $HA_DIR/hass.log"
done
log "HA 已就绪: http://127.0.0.1:$HA_PORT"

# ---------- 5. onboarding（API 完成，免 GUI；失败不中止，仅 warn） ----------
CLIENT_ID="https://127.0.0.1:$HA_PORT/oauth/authorize"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS_FILE="$HA_DIR/.admin_password"

# 首次创建管理员账号：随机生成密码落盘（600），后续重复运行读回，避免重置
if [ ! -s "$ADMIN_PASS_FILE" ]; then
  ADMIN_PASS="$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)"
  umask 077
  printf '%s' "$ADMIN_PASS" > "$ADMIN_PASS_FILE"
  umask 022
  log "已生成管理员密码 → $ADMIN_PASS_FILE (权限 600)"
else
  ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"
fi

onboarding_done() {
  local body
  body="$(curl -sf "http://127.0.0.1:$HA_PORT/api/onboarding" 2>/dev/null)" || return 1
  echo "$body" | grep -q '"done":false' && return 1
  return 0
}

run_onboarding() {
  log "执行 onboarding API..."
  # 坑：HA 2026.2+ 的 /api/onboarding/users 强制要求 username/password/language，只传 name 会 curl 22
  local AUTH_CODE
  AUTH_CODE="$(curl -s -X POST "http://127.0.0.1:$HA_PORT/api/onboarding/users" \
    -H "Content-Type: application/json" \
    -d "{\"client_id\": \"$CLIENT_ID\", \"name\": \"$ADMIN_USER\", \"username\": \"$ADMIN_USER\", \"password\": \"$ADMIN_PASS\", \"language\": \"zh-Hans\"}" \
    | sed -n 's/.*"auth_code":"\([^"]*\)".*/\1/p')" || AUTH_CODE=""
  [ -n "$AUTH_CODE" ] || { warn "onboarding/users 未返回 auth_code"; return 1; }

  local TOKEN
  TOKEN="$(curl -s -X POST "http://127.0.0.1:$HA_PORT/auth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code&code=$AUTH_CODE&client_id=$CLIENT_ID" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')" || TOKEN=""
  [ -n "$TOKEN" ] || { warn "获取 access_token 失败"; return 1; }

  curl -sf -X POST "http://127.0.0.1:$HA_PORT/api/onboarding/core_config" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"country":"CN","language":"zh-Hans","currency":"CNY","time_zone":"Asia/Shanghai"}' >/dev/null \
    || warn "core_config 设置失败"
  curl -sf -X POST "http://127.0.0.1:$HA_PORT/api/onboarding/analytics" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"analytics":false}' >/dev/null \
    || warn "analytics 设置失败"

  # integration 步可能 401（refresh_token invalid_grant，历史坑）：直接改存储完成
  if ! curl -sf -X POST "http://127.0.0.1:$HA_PORT/api/onboarding/integration" \
       -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1; then
    warn "integration 步 API 失败，改用存储绕过（历史坑）"
    "$PYBIN" - <<'EOF'
import json, os
p = os.path.expanduser("~/hass/config/.storage/onboarding")
try:
    with open(p) as f:
        d = json.load(f)
    done = d.get("data", {}).get("done", [])
    if "integration" not in done:
        done.append("integration")
        d["data"]["done"] = done
        with open(p, "w") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
        print("已写入 integration 到 onboarding done")
    else:
        print("integration 已在 done 中")
except Exception as e:
    print("修改 onboarding 失败:", e)
EOF
    log "重启 HA 使 onboarding 生效..."
    "$HA_DIR/start.sh" >/dev/null 2>&1 &
  fi
  log "onboarding 完成"
  return 0
}

if onboarding_done; then
  log "onboarding 已完成，跳过"
else
  run_onboarding || warn "onboarding 未完全成功，请参照 docs/速通手册-避坑版.md 手动补完（不影响开机自启配置）"
fi

# ---------- 6. 开机自启（无条件写入，调用 start.sh 自带解释器自愈） ----------
log "配置开机自启 (crontab @reboot → start.sh)..."
( crontab -l 2>/dev/null | grep -v 'hass' ; \
  echo "@reboot sleep 30 && $HA_DIR/start.sh >> $HA_DIR/hass.log 2>&1" ) | crontab -
log "crontab 已更新:"
crontab -l | grep hass || true

# ---------- 7. 完成与下一步指引 ----------
echo
echo "============================================================"
echo " ✅ 安装完成！还剩 2 步需要浏览器 GUI 操作（本机 127.0.0.1:8123）"
echo "============================================================"
echo
echo " 管理员: $ADMIN_USER  密码文件: $ADMIN_PASS_FILE (权限 600)"
echo
echo " 步骤 A：接入米家设备"
echo "   1) 浏览器打开 http://127.0.0.1:$HA_PORT，用上述管理员密码登录"
echo "   2) 设置 → 设备与服务 → 添加集成 → 搜索 Xiaomi"
echo "   3) 选择「Xiaomi Home」（官方 OAuth 版，勿选 miio 直连）"
echo "   4) 小米账号授权（账号+密码或扫码，可能需短信验证码）"
echo "      ⚠️ 基础配置页把「认证跳转地址」直接设为 http://127.0.0.1:8123，"
echo "        可避免回调跳 homeassistant.local 打不开的问题（见速通手册坑#5）"
echo "   5) 勾选要导入的家庭（如「全家」），完成设备导入"
echo
echo " 步骤 B：创建长期令牌（control.py 的控制钥匙）"
echo "   1) 用户资料（左下角）→ 安全 → 长期访问令牌 → 创建令牌"
echo "   2) 命名后创建，令牌只显示一次，立即复制"
echo "   3) 保存到 $HA_DIR/HA_TOKEN.txt"
echo
echo " 步骤 C：部署技能"
echo "   1) 把本仓库 skill/ 目录中的 control.py 放入豆包工作技能目录"
echo "   2) python3 control.py list 查看您的设备实体 ID"
echo "   3) 按需更新 control.py 顶部 ALIASES 别名表"
echo "   4) 在豆包工作聊天里说：帮我打开加湿器"
echo
echo " 日常启动/停止:"
echo "   启动: $HA_DIR/start.sh          （自带解释器自愈 + 就绪轮询）"
echo "   停止: pkill -9 -f '[v]env/bin/hass'"
echo
echo " 详细文档见 docs/速通手册-避坑版.md"
echo "============================================================"
