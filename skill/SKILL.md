---
name: mihome-controller
description: 通过本机 Home Assistant (http://127.0.0.1:8123) 控制家里的小米/米家设备。支持查询设备与实体状态、开关灯光/插座、控制空调制冷制热与温度、调节加湿器、查看电视音箱等媒体设备状态、让小米音箱开口说话。当用户说"开灯/关灯""空调调到X度""打开加湿器""让音箱说XX""查看家里设备状态"等涉及小米设备控制或状态查询的请求时使用。
---

# 米家设备控制器（mihome-controller）

本技能通过 Home Assistant REST API 控制已接入米家的设备。所有命令在本机执行，调用 `control.py` 完成。

## 部署要求

| 项 | 要求 |
|---|---|
| Home Assistant | 本机运行，地址 `http://127.0.0.1:8123`（安装见 `scripts/install.sh`） |
| Xiaomi Home 集成 | 官方 OAuth 版，已同步家庭设备 |
| 长期令牌 | 保存于 `~/hass/HA_TOKEN.txt`（control.py 自动读取；也可用环境变量 `HA_TOKEN`） |
| control.py | 与 SKILL.md 同目录 |

## 命令用法

```bash
# 查看全部设备与状态摘要（首次配置时用它查自己的实体 ID）
python3 control.py list

# 查询指定设备/实体的当前状态（支持模糊匹配，如"床头灯"）
python3 control.py states "床头灯"

# 开/关设备（支持名称或实体ID）
python3 control.py on "床头灯"
python3 control.py off "床头灯"

# 控制空调：制冷/制热/送风/除湿/关闭 + 温度
python3 control.py climate "客厅空调" cool 26
python3 control.py climate "客厅空调" heat 28
python3 control.py climate "客厅空调" off

# 调节灯光亮度（0-100，兼容 on/off/开/关）
python3 control.py light "床头灯" 50
python3 control.py light "床头灯" on

# 加湿器开关
python3 control.py humidifier "加湿器" on
python3 control.py humidifier "加湿器" off

# 音箱控制：播放/停止音乐、让音箱说话（文本指令 TTS）
python3 control.py speaker "音箱" play
python3 control.py speaker "音箱" stop
python3 control.py speaker "音箱" "今天天气不错，记得多喝水"
```

## 别名与实体 ID

`control.py` 内置常见设备别名表（客厅空调 / 卧室空调 / 床头灯 / 加湿器 / 热水器 / 鱼缸 / 音箱系列），
别名可直接映射到实体 ID 实现 **0.1s 极速直连**。

> ⚠️ 仓库中的实体 ID 为作者家庭示例。**首次使用请执行 `python3 control.py list`，
> 把别名表替换为您自己设备的实体 ID**（`control.py` 顶部 `ALIASES` 字典）。

## 匹配规则

- 支持中文名、实体 ID、别名精确匹配
- 自动去掉"的/在/把/帮我/打开"等连接词："客厅的空调" → 客厅空调
- 模糊匹配优先可控制域（light/switch/humidifier/climate），过滤按钮/传感器等附属实体

## 安全

- `HA_TOKEN` 是设备控制钥匙，**严禁提交到仓库或云同步目录**，建议仅存 `~/hass/HA_TOKEN.txt`
- 令牌泄露时：HA 用户资料 → 安全 → 删除该令牌即可作废
