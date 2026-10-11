#!/usr/bin/env bash
# =============================================================================
# 豆包工作 × 米家设备控制器 - 一键安装脚本（云电脑 / macOS 通用）
#
# 用法:  bash install.sh
# 要求:  无 sudo / 无 docker 亦可；需要外网（pypi / github / 小米云）
# 产物:  ~/hass/.venv (Python 3.14 + Home Assistant + 依赖)
#        ~/hass/config (含小米官方集成 ha_xiaomi_home)
#        crontab @reboot 开机自启
# 之后:  浏览器 GUI 完成 2 步（小米 OAuth 授权、创建长期令牌），详见输出指引
# =============================================================================
set -euo pipefail

HA_DIR="${HA_DIR:-$HOME/hass}"
HA_PORT=8123
PY_VER=3.14
HA_XIAOMI_REPO="https://github.com/XiaoMi/ha_xiaomi_home.git"

log()  { echo -e "\033[1;32m[install]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

# ---------- 0. 基础检查 ----------
command -v curl >/dev/null || die "需要 curl"
command -v git  >/dev/null || die "需要 git"
command -v python3 >/dev/null || die "需要 python3"

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
PYBIN="$HA_DIR/.venv/bin/python"
"$PYBIN" --version

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

# ---------- 4. 启动 HA ----------
if pgrep -f '[v]env/bin/hass' >/dev/null; then
  warn "检测到 HA 已在运行，跳过启动"
else
  log "启动 Home Assistant（首次启动约 60-90 秒）..."
  nohup "$HA_DIR/.venv/bin/hass" -c "$HA_DIR/config" > "$HA_DIR/hass.log" 2>&1 &
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

# ---------- 5. onboarding（API 完成，免 GUI） ----------
CLIENT_ID="https://127.0.0.1:$HA_PORT/oauth/authorize"

onboarding_done() {
  curl -sf -o /dev/null "http://127.0.0.1:$HA_PORT/api/onboarding" \
    && ! curl -sf "http://127.0.0.1:$HA_PORT/api/onboarding" | grep -q '"done":false'
}

if onboarding_done; then
  log "onboarding 已完成，跳过"
else
  log "执行 onboarding API..."
  AUTH_CODE=$(curl -sf -X POST "http://127.0.0.1:$HA_PORT/api/onboarding/users" \
    -H "Content-Type: application/json" \
    -d "{\"client_id\": \"$CLIENT_ID\", \"name\": \"admin\"}" \
    | sed -n 's/.*"auth_code":"\([^"]*\)".*/\1/p')
  [ -z "$AUTH_CODE" ] && die "onboarding/users 未返回 auth_code"

  TOKEN=$(curl -sf -X POST "http://127.0.0.1:$HA_PORT/auth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code&code=$AUTH_CODE&client_id=$CLIENT_ID" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
  [ -z "$TOKEN" ] && die "获取 access_token 失败"

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
    pkill -9 -f '[v]env/bin/hass' || true
    sleep 3
    nohup "$HA_DIR/.venv/bin/hass" -c "$HA_DIR/config" > "$HA_DIR/hass.log" 2>&1 &
    echo $! > "$HA_DIR/hass.pid"
    for i in $(seq 1 30); do
      curl -sf -o /dev/null "http://127.0.0.1:$HA_PORT/" 2>/dev/null && break
      sleep 5
    done
  fi
  log "onboarding 完成"
fi

# ---------- 6. 开机自启 ----------
log "配置开机自启 (crontab @reboot)..."
( crontab -l 2>/dev/null | grep -v 'hass' ; \
  echo "@reboot sleep 30 && $HA_DIR/.venv/bin/hass -c $HA_DIR/config >> $HA_DIR/hass.log 2>&1" ) | crontab -
log "crontab 已更新:"
crontab -l | grep hass || true

# ---------- 7. 完成与下一步指引 ----------
echo
echo "============================================================"
echo " ✅ 安装完成！还剩 2 步需要浏览器 GUI 操作（本机 127.0.0.1:8123）"
echo "============================================================"
echo
echo " 步骤 A：接入米家设备"
echo "   1) 浏览器打开 http://127.0.0.1:$HA_PORT，登录 admin"
echo "   2) 设置 → 设备与服务 → 添加集成 → 搜索 Xiaomi"
echo "   3) 选择「Xiaomi Home」（官方 OAuth 版，勿选 miio 直连）"
echo "   4) 小米账号授权（账号+密码或扫码，可能需短信验证码）"
echo "      ⚠️ 授权回调如跳 homeassistant.local 打不开，"
echo "         把地址栏 URL 中的 homeassistant.local 换成 127.0.0.1 再回车"
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
echo " 详细文档见 docs/速通手册-避坑版.md"
echo "============================================================"
