# 豆包工作 × 米家设备控制器（mihome-controller）

让 **豆包工作（AI 助手）直接控制家里的米家设备**：说一句"打开加湿器""客厅空调调到 26 度""让音箱说：该睡觉了"，设备真实执行。

面向 **豆包工作（云电脑 / 本机）+ 米家智能爱好者**，全程本机闭环，无需 Docker、无需 sudo，云电脑（Linux）可直接部署。

## 架构

```
豆包工作（自定义技能 mihome-controller）
        │  自然语言 → 解析为命令
        ▼
control.py（本机执行，别名直连）
        │  Home Assistant REST API（Bearer Token）
        ▼
Home Assistant（本机 127.0.0.1:8123）
        │  Xiaomi Home 官方集成（OAuth 云同步）
        ▼
小米云 ⇄ 家里的米家设备（灯 / 空调 / 加湿器 / 音箱 / 电视…）
```

## 特性

| 能力 | 说明 |
|---|---|
| ⚡ 极速响应 | 别名直连实体 API，单次命令 **0.1s** 内返回 |
| 🗣️ 中文自然语言 | "打开加湿器""客厅的空调""卧室的灯" 均可命中（停用词归一化） |
| 🔊 音箱 TTS | 让小米音箱 Pro / 小爱音箱 **开口说话**（文本指令） |
| 🏠 覆盖主流品类 | 灯 / 空调（制冷制热+温度）/ 加湿器 / 热水器 / 电视 / 鱼缸 |
| 🔄 开机自启 | crontab `@reboot` 自动拉起，重启无忧 |
| 🔒 本机闭环 | 控制请求不出本机，只有设备状态同步走米家官方云 |
| 📦 零特权依赖 | 无 sudo / 无 Docker / 无 docker，云电脑可直接跑 |

## 快速开始（约 15–25 分钟）

1. 安装 Home Assistant 到 `~/hass`：`bash scripts/install.sh`（含依赖、onboarding、自启）
2. 浏览器打开 `http://127.0.0.1:8123`，添加集成 → 搜索 **Xiaomi Home**（官方 OAuth 版）→ 小米账号授权（需短信验证码）
3. 创建长期访问令牌（用户资料 → 安全），保存到 `~/hass/HA_TOKEN.txt`
4. 把 `skill/control.py` 复制到豆包工作技能目录，按 `python3 control.py list` 输出的实体 ID 更新别名表
5. 在豆包工作聊天里喊：**"帮我打开加湿器"**

> 详细步骤与全部已知坑点见 [docs/速通手册-避坑版.md](docs/速通手册-避坑版.md)

## 目录结构

```
doubao-mihome-controller/
├── README.md                 # 本文件
├── LICENSE                   # MIT
├── .gitignore                # 敏感文件过滤（HA_TOKEN 等）
├── docs/
│   └── 速通手册-避坑版.md     # 完整配置手册 + 10 条坑清单
├── skill/
│   ├── SKILL.md              # 豆包工作技能定义（frontmatter + 命令用法）
│   └── control.py            # 设备控制脚本（别名直连 / 归一化 / 音箱 TTS）
└── scripts/
    └── install.sh            # 一键安装：HA + 依赖 + onboarding + 开机自启
```

## 命令速览

```bash
# 查看全部设备与状态
python3 control.py list
python3 control.py states "加湿器"

# 开关
python3 control.py on "床头灯"
python3 control.py off "床头灯"

# 空调：制冷 / 制热 / 送风 / 关闭 + 温度
python3 control.py climate "客厅空调" cool 26
python3 control.py climate "客厅空调" off

# 灯光亮度（0-100，兼容 on/off）
python3 control.py light "床头灯" 60

# 音箱：播放 / 停止 / 让音箱说话
python3 control.py speaker "音箱" play
python3 control.py speaker "音箱" "今天天气不错，记得多喝水"
```

## 安全提示（重要）

- `HA_TOKEN`（长期访问令牌）是家里设备的控制钥匙，**有效期内=可控制您所有设备**。
  - 已加入 `.gitignore`，**不要提交到仓库**，也不要放进会被云同步的技能目录。
  - 建议保存到 `~/hass/HA_TOKEN.txt`（`control.py` 自动读取，也支持环境变量 `HA_TOKEN`）。
- 令牌泄露时：HA 用户资料 → 安全 → 删除该令牌即可作废。
- 本仓库 `control.py` 中的别名实体 ID 为作者家庭示例，请用 `python3 control.py list` 查看您自己的实体后替换。

## 兼容性

- **云电脑（Linux，无 sudo/docker）**：✅ 本方案主战场（uv 预编译 Python）
- **macOS**：✅ 同样适用
- **HA 版本**：2026.2+（REST API 稳定，长期兼容）
- **米家账号**：中国大陆区（其他区域请调整 OAuth 地区配置）

## License

[MIT](LICENSE)

## 贡献

欢迎提 Issue / PR：新设备别名、新命令（如电视音量、窗帘）、Windows 支持、Docker 版等。

**如果你觉得有用，点个 ⭐ 让更多米家玩家看到！**
