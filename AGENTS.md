# AGENTS.md — 给 AI Agent 的执行手册

> 本文件供 **豆包工作 / Claude / Codex 等 AI Agent** 读取，用于快速理解并部署本项目。
> 豆包工作用户：把这个仓库交给豆包工作，按本文件执行即可完整部署。

## 一句话理解

本项目让 AI 通过 `control.py` 调用**本机 Home Assistant REST API**，控制已接入米家的设备（灯/空调/加湿器/音箱等）。豆包工作以「自定义技能」方式调用 `control.py`，实现自然语言 → 真实设备动作。

## 部署前必须知道

- 依赖：本机 Home Assistant（`http://127.0.0.1:8123`）、Xiaomi Home 官方集成、长期访问令牌
- 令牌路径：`~/hass/HA_TOKEN.txt`（`control.py` 自动读取；也支持环境变量 `HA_TOKEN`）
- **无需 sudo / 无需 Docker**（云电脑可用）；需要外网（pypi / github / 小米云）
- HA 启动方式（防 pkill 自杀）：`pkill -9 -f '[v]env/bin/hass'` 后 `nohup ~/hass/.venv/bin/hass -c ~/hass/config > ~/hass/hass.log 2>&1 &`

## 文件职责

| 文件 | 作用 | Agent 何时使用 |
|---|---|---|
| `skill/SKILL.md` | 豆包工作技能定义（YAML frontmatter） | 创建豆包技能时，上传 `skill/` 整个目录 |
| `skill/control.py` | 设备控制脚本（别名直连/归一化/TTS） | 豆包技能运行时执行；部署时复制到技能目录 |
| `scripts/install.sh` | 一键安装 HA + 依赖 + onboarding + 开机自启（onboarding 失败仅 warn 不中止） | 新机器部署第一步 |
| `scripts/start.sh` | 健壮启动脚本：venv 解释器自愈 + 防自杀启动 + 就绪轮询；crontab 自启亦调用它 | 日常启动 / HA 起不来时优先用它 |
| `docs/速通手册-避坑版.md` | 完整配置手册 + 14 条坑清单 | 遇到 OAuth/令牌/集成加载/启动失败时查 |

## 执行序列（新机器完整部署）

```bash
# 1. 安装（HA + 小米集成 + 自启；onboarding 用 API 自动完成）
bash scripts/install.sh
#    - 管理员密码由脚本随机生成，落盘 ~/hass/.admin_password（权限 600），登录 HA 用它
#    - 开机自启 crontab 调用 ~/hass/start.sh（自带 venv 解释器自愈，见坑#11）

# 2. GUI 两步（唯一必须人工/浏览器操作的部分）：
#    A. 集成页 → Xiaomi Home → 小米 OAuth 授权（可能需短信验证码）
#       坑：基础配置页把「认证跳转地址」设为 http://127.0.0.1:8123，
#           避免回调跳 homeassistant.local 打不开（坑#5/#14）
#    B. 用户资料 → 安全 → 长期访问令牌 → 保存到 ~/hass/HA_TOKEN.txt
#       坑：令牌只显示一次，立即复制；弹窗输入框在 shadow DOM，需用
#           bu.snapshot 找 input ref + bu.type 输入、bu.text 读值

# 3. 部署技能
cp skill/control.py <豆包工作技能目录>/control.py
python3 control.py list          # 查看设备实体 ID
# 更新 control.py 顶部 ALIASES 为真实实体 ID（仓库中为示例）

# 4. 端到端验证（真实控制，结束后恢复原状态）
python3 control.py states "加湿器"
python3 control.py on "床头灯" && sleep 2 && python3 control.py off "床头灯"
```

## 常用操作

| 操作 | 命令 |
|---|---|
| 启动 HA（含解释器自愈） | `bash ~/hass/start.sh` |
| 停止 HA | `pkill -9 -f '[v]env/bin/hass'` |
| 查看全部设备 | `python3 control.py list` |
| 查询设备状态 | `python3 control.py states "加湿器"` |
| 开关设备 | `python3 control.py on/off "床头灯"` |
| 空调模式+温度 | `python3 control.py climate "客厅空调" cool 26` |
| 灯光亮度 | `python3 control.py light "床头灯" 60` |
| 音箱 TTS | `python3 control.py speaker "音箱" "说点什么"` |

## 硬约束（Agent 必须遵守）

1. **凭据安全**：`HA_TOKEN`、小米账号密码、短信验证码属于敏感信息——不得写入文件、不得出现在回复正文、不得提交到仓库。
2. **真实设备操作**：验证类控制命令执行后，**必须将设备恢复到操作前状态**（如测试开灯后关灯）。
3. **匹配规则**：别名支持中文名/实体ID/自然语言变体（"客厅的空调"）；模糊匹配优先可控制域（light/humidifier/climate 等），避免命中 button/sensor 附属实体。
4. **climate 调用**：`set_hvac_mode` 只传模式，`set_temperature` 单独调用（合并会 400）。
5. **命令必须成功**：失败时先看 `~/hass/hass.log`，再查 `docs/速通手册-避坑版.md` 坑清单。

## 验证清单（交付前逐项过）

- [ ] `curl -H "Authorization: Bearer $(cat ~/hass/HA_TOKEN.txt)" http://127.0.0.1:8123/api/` 返回 `API running.`
- [ ] 集成页 Xiaomi Home 显示设备数 > 0
- [ ] `python3 control.py states "加湿器"` 命中 humidifier 域实体
- [ ] 真实开关一次且状态恢复原状
