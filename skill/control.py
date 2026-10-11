#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
米家设备控制极速脚本 (mihome-controller)
基于用户原始版本增强：
- 别名包含匹配（"客厅的空调"也能命中"客厅空调"）
- light 命令兼容 on/off 关键词
- 令牌多路径读取：环境变量 HA_TOKEN > 技能目录 HA_TOKEN.txt > ~/hass/HA_TOKEN.txt
"""
import os
import sys
import json
import urllib.request
import urllib.parse
from typing import Dict, Any, List, Optional

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HA_URL = os.environ.get("HA_URL", "http://127.0.0.1:8123").rstrip("/")

# 常用中文别名映射表
# ⚠️ 以下实体 ID 为作者家庭设备示例，仅作格式参考。
#    首次使用请执行 `python3 control.py list` 查看您自己的实体 ID 后替换。
#    实体 ID 格式：<域>.<厂商>_<国家>_<设备序列>_<型号>[_子实体]
ALIASES = {
    "客厅空调": "climate.xiaomi_cn_698223954_m9",
    "卧室空调": "climate.xiaomi_cn_574394105_m4",
    "主卧空调": "climate.xiaomi_cn_574394105_m4",
    "次卧空调": "climate.xiaomi_cn_590617918_mc8",
    "德州空调": "climate.xiaomi_cn_590617918_mc8",
    "床头灯": "light.yeelink_cn_827196410_bslamp2_s_2_light",
    "卧室灯": "light.yeelink_cn_827196410_bslamp2_s_2_light",
    "卧室的灯": "light.yeelink_cn_827196410_bslamp2_s_2_light",
    "加湿器": "humidifier.xiaomi_cn_2094885839_4lite",
    "热水器": "water_heater.xiaomi_cn_748162218_ym02_s_2_water_heater",
    "鱼缸灯": "light.hfjh_cn_833434035_m100_s_15_light",
    "鱼缸": "light.hfjh_cn_833434035_m100_s_15_light",
    "小米智能音箱pro": "media_player.xiaomi_cn_980937485_oh2p",
    "智能音箱pro": "media_player.xiaomi_cn_980937485_oh2p",
    "音箱pro": "media_player.xiaomi_cn_980937485_oh2p",
    "客厅音箱": "media_player.xiaomi_cn_980937485_oh2p",
    "小爱音箱play": "media_player.xiaomi_cn_634510573_l05b",
    "卧室音箱": "media_player.xiaomi_cn_634510573_l05b",
    "小爱音箱": "media_player.xiaomi_cn_980937485_oh2p",
    "音箱": "media_player.xiaomi_cn_980937485_oh2p",
    "客厅电视": "media_player.xiaomi_cn_mitv_0f607264fc6318a92b9e13c65db7cd3c_b5f5e6a88c0542abaf8459edf47e336b_v1",
    "小米电视": "media_player.xiaomi_cn_mitv_0f607264fc6318a92b9e13c65db7cd3c_b5f5e6a88c0542abaf8459edf47e336b_v1",
    "电视": "media_player.xiaomi_cn_mitv_0f607264fc6318a92b9e13c65db7cd3c_b5f5e6a88c0542abaf8459edf47e336b_v1",
    "风扇": "fan.dmaker_cn_241294893_p5_s_2_fan",
    "电暖器": "climate.xiaomi_cn_827525171_ma9",
    "德州电暖器": "climate.xiaomi_cn_827525171_ma9",
    "踢脚线电暖器": "climate.xiaomi_cn_827525171_ma9",
    "油烟机灯": "light.xiaomi_cn_753953142_ymv5_s_4_light",
    "吸油烟机灯": "light.xiaomi_cn_753953142_ymv5_s_4_light",
    "王集客厅": "switch.chuangmi_cn_1063579718_046d02_on_p_2_1",
    "摄像头": "switch.chuangmi_cn_1063579718_046d02_on_p_2_1",
}

TOKEN_FALLBACKS = (
    os.path.join(SCRIPT_DIR, "HA_TOKEN.txt"),
    os.path.expanduser("~/hass/HA_TOKEN.txt"),
    os.path.expanduser("~/HA_TOKEN.txt"),
)

# 中文连接词（归一化用："客厅的空调" -> "客厅空调"）
STOPWORDS = ("的", "在", "把", "帮", "请", "麻烦", "给我", "帮我", "打开", "开启", "关闭", "调")


def normalize(s: str) -> str:
    s = s.strip().lower().replace(" ", "")
    for w in STOPWORDS:
        s = s.replace(w, "")
    return s


def get_token() -> str:
    env_token = os.environ.get("HA_TOKEN")
    if env_token:
        return env_token.strip()
    for token_file in TOKEN_FALLBACKS:
        try:
            with open(token_file, "r", encoding="utf-8") as f:
                t = f.read().strip()
            if t:
                return t
        except OSError:
            continue
    raise RuntimeError("未找到 HA 访问令牌，请配置 HA_TOKEN.txt 或 HA_TOKEN 环境变量。")


def api_request(path: str, method: str = "GET", data: Optional[Dict[str, Any]] = None) -> Any:
    token = get_token()
    url = f"{HA_URL}{path}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }
    payload = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=payload, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=8) as resp:
        return json.load(resp)


def get_all_states() -> List[Dict[str, Any]]:
    return api_request("/api/states", "GET")


def find_entity(query: str, domain_prefix: Optional[str] = None) -> Optional[Dict[str, Any]]:
    query_clean = normalize(query)
    # 别名包含匹配：归一化后精确或双向包含（"客厅的空调" -> "客厅空调"）
    for alias, mapped_eid in ALIASES.items():
        ac = normalize(alias)
        if query_clean == ac or (ac in query_clean) or (query_clean in ac):
            if domain_prefix is None or mapped_eid.startswith(domain_prefix):
                try:
                    return api_request(f"/api/states/{mapped_eid}", "GET")
                except Exception:
                    pass
    states = get_all_states()
    for s in states:
        if s["entity_id"] == query:
            return s
    matched = []
    for s in states:
        eid = s["entity_id"]
        if domain_prefix and not eid.startswith(domain_prefix):
            continue
        fname = s.get("attributes", {}).get("friendly_name", "")
        if query_clean in normalize(fname) or query_clean in eid.lower():
            matched.append(s)
    if matched:
        matched.sort(key=lambda x: len(x.get("attributes", {}).get("friendly_name", "")))
        return matched[0]
    return None


def call_service(domain: str, service: str, entity_id: str, extra_data: Optional[Dict[str, Any]] = None) -> Any:
    data = {"entity_id": entity_id}
    if extra_data:
        data.update(extra_data)
    return api_request(f"/api/services/{domain}/{service}", "POST", data)


def cmd_list(args):
    states = get_all_states()
    print(f"=== 全部设备与实体清单 (共 {len(states)} 个) ===")
    for s in states:
        eid = s["entity_id"]
        fname = s.get("attributes", {}).get("friendly_name", "无名称")
        print(f"[{eid}] {fname} -> {s.get('state')}")


def cmd_states(args):
    if not args: return
    entity = find_entity(args[0])
    if not entity:
        print(f"未找到匹配设备: {args[0]}")
        return
    eid = entity["entity_id"]
    name = entity.get("attributes", {}).get("friendly_name", eid)
    attrs = entity.get("attributes", {})
    print(f"设备：{name}")
    print(f"实体：{eid}")
    print(f"状态：{entity.get('state')}")
    for k in ("temperature", "current_temperature", "hvac_mode", "brightness",
              "humidity", "current_humidity", "fan_mode", "preset_mode"):
        if k in attrs:
            print(f"{k}: {attrs[k]}")


def cmd_on(args):
    if not args: return
    entity = find_entity(args[0])
    if not entity:
        print(f"未找到匹配设备: {args[0]}")
        return
    eid = entity["entity_id"]
    name = entity.get("attributes", {}).get("friendly_name", eid)
    domain = eid.split(".")[0]
    if domain in ("light", "switch", "fan", "humidifier"):
        call_service(domain, "turn_on", eid)
    elif domain == "climate":
        call_service("climate", "set_hvac_mode", eid, {"hvac_mode": "cool"})
    elif domain == "media_player":
        call_service("media_player", "media_play", eid)
    elif domain == "button":
        call_service("button", "press", eid)
    else:
        call_service("homeassistant", "turn_on", eid)
    print(f"已开启: {name}")


def cmd_off(args):
    if not args: return
    entity = find_entity(args[0])
    if not entity:
        print(f"未找到匹配设备: {args[0]}")
        return
    eid = entity["entity_id"]
    name = entity.get("attributes", {}).get("friendly_name", eid)
    domain = eid.split(".")[0]
    if domain in ("light", "switch", "fan", "humidifier"):
        call_service(domain, "turn_off", eid)
    elif domain == "climate":
        call_service("climate", "set_hvac_mode", eid, {"hvac_mode": "off"})
    elif domain == "media_player":
        call_service("media_player", "media_pause", eid)
    else:
        call_service("homeassistant", "turn_off", eid)
    print(f"已关闭: {name}")


def cmd_climate(args):
    if len(args) < 2: return
    query, mode = args[0], args[1].lower()
    temp = float(args[2]) if len(args) > 2 else None
    entity = find_entity(query, domain_prefix="climate.")
    if not entity:
        print(f"未找到空调: {query}")
        return
    eid = entity["entity_id"]
    name = entity.get("attributes", {}).get("friendly_name", eid)
    if mode == "off":
        call_service("climate", "set_hvac_mode", eid, {"hvac_mode": "off"})
        print(f"空调已关闭: {name}")
    else:
        call_service("climate", "set_hvac_mode", eid, {"hvac_mode": mode})
        if temp:
            call_service("climate", "set_temperature", eid, {"temperature": temp})
        print(f"空调已设置: {name} -> 模式: {mode}, 温度: {temp}")


def cmd_light(args):
    if len(args) < 2: return
    query, pct_str = args[0], args[1].lower()
    entity = find_entity(query, domain_prefix="light.")
    if not entity:
        print(f"未找到灯: {query}")
        return
    eid = entity["entity_id"]
    name = entity.get("attributes", {}).get("friendly_name", eid)
    if pct_str in ("on", "开", "打开"):
        call_service("light", "turn_on", eid)
        print(f"灯光已开启: {name}")
        return
    if pct_str in ("off", "关", "关闭"):
        call_service("light", "turn_off", eid)
        print(f"灯光已关闭: {name}")
        return
    pct = int(pct_str)
    if pct <= 0:
        call_service("light", "turn_off", eid)
    else:
        call_service("light", "turn_on", eid, {"brightness_pct": pct})
    print(f"灯光已调节: {name} -> {pct}%")


def cmd_speaker(args):
    if len(args) < 2: return
    query, action = args[0], args[1]
    notify_eid = "notify.xiaomi_cn_980937485_oh2p_execute_text_directive_a_7_4"
    if action in ("stop", "停止", "关闭"):
        try:
            call_service("media_player", "media_pause", "media_player.xiaomi_cn_980937485_oh2p")
        except Exception:
            pass
        call_service("notify", "send_message", notify_eid, {"message": "停止播放"})
        print(f"音箱已停止: {query}")
    elif action in ("play", "播放", "开启"):
        call_service("button", "press", "button.xiaomi_cn_980937485_oh2p_play_music_a_7_5")
        print(f"音箱已播放: {query}")
    else:
        call_service("notify", "send_message", notify_eid, {"message": action})
        print(f"音箱已执行: [{action}]")


def main():
    if len(sys.argv) < 2:
        sys.exit(1)
    dispatch = {
        "list": cmd_list, "states": cmd_states, "on": cmd_on, "off": cmd_off,
        "climate": cmd_climate, "light": cmd_light, "speaker": cmd_speaker,
    }
    cmd = sys.argv[1].lower()
    if cmd in dispatch:
        dispatch[cmd](sys.argv[2:])


if __name__ == "__main__":
    main()
