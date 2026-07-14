#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
nikon_ptpip_probe.py —— 尼康「连接到电脑」PTP/IP 握手实验探针

这个脚本做什么:
  1) 在杂乱的局域网里【精准】定位哪台设备是尼康相机;
  2) 主动完成 PTP/IP Init 握手,观察相机是否要求配对(Init Ack / Init Fail);
  3) 若放行,再 OpenSession + GetDeviceInfo,dump 机型/序列号/操作码/属性码,并判定
     "仅下载类 / 含控制类"操作码;
  4) --hold 保持会话,观测相机是否/多久主动掐断、心跳能否保住(方案成立与否的关键数据);
  5) 全部结果落盘成带时间戳的 JSON + 控制台日志,单次实验即可复盘。

精准识别相机的三重信号(越往后越硬,MAC/OUI 仅辅助):
  A. mDNS 广播(枚举全部服务类型,实证尼康真实服务名)  —— 需 pip install zeroconf
  B. TCP 15740 端口开放  —— 局域网里几乎只有相机监听
  C. PTP/IP Init 握手成功并回读到相机 FriendlyName(如 "Z50") —— 不可伪造,确定就是它

============================ 实验前提(缺一不可) ============================
一、网络:相机和电脑连【同一个 wifi / 同一网段】(家里路由器或手机热点均可)
   - 路由器不能开 "AP 隔离 / 客户端隔离"(会禁止设备互通,脚本扫不到相机)。

二、相机:进【连接到电脑 Connect to PC】,不是「连接到智能设备/SnapBridge」
   - 设置菜单 → 连接到电脑 → 网络设置 → 创建配置文件 → 搜索 Wi-Fi 网络(infrastructure)
     → 选 wifi → 输密码;把 "Wi-Fi 连接" 设为启用,保持在线(相机 wifi 会休眠,别熄屏)。
   - 记下相机拿到的 IP(连接状态里能看到),运行时 --ip 传进去最稳;看不到则脚本扫描。

三、配对岔路(这正是实验目的,两种都要跑):
   - A. 先【不配对】直接跑脚本:相机只加入了 wifi、不开 WTU → 看 Init 成功还是被拒,
        直接回答"未配对到底连不连得上"。
   - B. 再用【WTU 配对】后跑:电脑装 WTU 走一遍官方配对(相机显示认证码输入 WTU),
        全程 Wireshark 抓包;配对完再跑脚本(尤其 --hold 看会话、--guid 做 A/B)。

四、电脑:
   - 连同一 wifi。
   - 防火墙:一般【不用改】——连相机(TCP 15740)和端口扫描都是"出站",Windows 默认放行。
     只有走 mDNS 自动发现时,zeroconf 要监听"入站"UDP 5353,首次运行 Windows 会弹窗
     问是否允许 python,勾"专用网络"即可;不想用 mDNS 就直接 --ip / --subnet,无需任何放行。
   - pip install zeroconf(mDNS 用,可选);
   - 同一时刻只连一个:别让 WTU / SnapBridge / 手机 App 同时连着相机(尼康单会话会互抢)。

================================ 使用步骤 ================================
  # ① 基本探测:定位相机 + Init + DeviceInfo + 操作码判定
  python nikon_ptpip_probe.py --ip 192.168.1.55
  #   (不知道 IP 就扫网段:--subnet 192.168.1.0/24;只发现不握手加 --discover-only)

  # ② 关键:观测相机是否/多久掐断会话(先只观察 60 秒)
  python nikon_ptpip_probe.py --ip 192.168.1.55 --hold 60
  #   若被掐,试心跳能否续命:
  python nikon_ptpip_probe.py --ip 192.168.1.55 --hold 120 --keepalive getdeviceinfo

  # ③ 抓完 WTU 配对后,做 GUID A/B(判定相机是否按固定 GUID 放行)
  python nikon_ptpip_probe.py --ip 192.168.1.55 --guid <pcap里WTU用的GUID>
  python nikon_ptpip_probe.py --ip 192.168.1.55 --guid <把上面改一位>

  每次生成 ptpip_probe_<时间戳>.json,留好。

=========================== Wireshark 抓包(第③步前置) ===========================
  官方唯一能配对的 WTU 只有 Win/Mac 版,故用 PC 抓一次配对流量(与产品无关):
   1) Wireshark 选【连该 wifi 的那张网卡】,capture filter 填:host <相机IP> or udp port 5353
   2) 相机上先删掉旧配对记录 → 开 WTU 走一遍首次配对(输认证码)→ 配对后再传一张图多抓点;
   3) 停止,File→Save As 存成 .pcapng。
  抓包重点(认证码是带外的,别指望找"认证码字段"):
   - 配对后那次连接里 WTU 填的 GUID(拿去做第③步 A/B);
   - 连接建立后 WTU 每隔几秒发什么包维持会话不掉(→ 我们的 --keepalive 依据);
   - GetDeviceInfo 响应里的 OperationsSupported 是否只有下载类;
   - udp 5353 里尼康真实的 mDNS 服务名(是不是 _ptp._tcp)。
  追一条流:右键任一 15740 包 → Follow → TCP Stream。

三个新开关:--hold <秒>(保持会话观测掐断)、--keepalive none|ping|getdeviceinfo(试心跳)、
           --guid <32位hex>(做 GUID A/B)。判定出口见 docs/连接到手机热点调研.md 第六节。

作者备注:PTP/IP 帧格式与操作码事实来源于 ISO 15740 与 libgphoto2 camlibs/ptp2/ptpip.c,
仅参考协议事实,代码为独立实现。
"""

import argparse
import ipaddress
import json
import os
import select
import socket
import struct
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

PTPIP_PORT = 15740

# ---- PTP/IP 包类型 ----
PKT_INIT_CMD_REQ = 1
PKT_INIT_CMD_ACK = 2
PKT_INIT_EVT_REQ = 3
PKT_INIT_EVT_ACK = 4
PKT_INIT_FAIL = 5
PKT_CMD_REQUEST = 6
PKT_CMD_RESPONSE = 7
PKT_EVENT = 8
PKT_START_DATA = 9
PKT_DATA = 10
PKT_CANCEL = 11
PKT_END_DATA = 12
PKT_PING = 13
PKT_PONG = 14

# ---- 常用操作码 / 响应码 ----
OP_GET_DEVICE_INFO = 0x1001
OP_OPEN_SESSION = 0x1002
OP_CLOSE_SESSION = 0x1003
RC_OK = 0x2001

# 数据阶段:1 = 无数据 / 数据从相机来(data-in);2 = 我们向相机发数据(data-out)
DP_NODATA_OR_IN = 1
DP_DATA_OUT = 2

# 本机默认身份:GUID 固定,便于测「配对一次后能否自动重连」。可用 --guid 覆盖。
DEFAULT_GUID = bytes.fromhex("6e6b5f73656e64000000626f78303031")  # "nk_send\0\0\0box001"
DEFAULT_NAME = "nk_send-probe"

# Nikon 厂商扩展 ID(GetDeviceInfo 里出现即为尼康)
NIKON_VENDOR_EXT_ID = 0x0000000A

# 操作码名(够用即可,用于判定"仅下载类 / 含控制类")
OPCODE_NAMES = {
    0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession",
    0x1004: "GetStorageIDs", 0x1005: "GetStorageInfo", 0x1006: "GetNumObjects",
    0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo", 0x1009: "GetObject",
    0x100A: "GetThumb", 0x100B: "DeleteObject", 0x100E: "InitiateCapture",
    0x1014: "GetDevicePropDesc", 0x1015: "GetDevicePropValue", 0x1016: "SetDevicePropValue",
    0x101B: "GetPartialObject", 0x9201: "Nikon_StartLiveView", 0x9203: "Nikon_GetLiveViewImg",
    0x9207: "Nikon_InitiateCaptureRecInMedia", 0x90C0: "Nikon_InitiateCaptureRecInSdram",
    0x90C7: "Nikon_GetEvent", 0x90C8: "Nikon_DeviceReady",
}
# 判定"含控制/遥控能力"的关键操作码(有其一即非纯下载)
CONTROL_OPCODES = {0x1016, 0x100E, 0x9201, 0x9203, 0x9207, 0x90C0, 0x90CB}
# 判定"具备下载能力"的关键操作码
DOWNLOAD_OPCODES = {0x1007, 0x1009}


def classify_ops(ops):
    ops = set(ops)
    has_dl = DOWNLOAD_OPCODES.issubset(ops)
    has_ctrl = bool(ops & CONTROL_OPCODES)
    if has_ctrl:
        verdict = "含控制/遥控类操作码(不止下载)"
    elif has_dl:
        verdict = "仅下载类操作码(与 gphoto2 #1135 的 STA 模式观察一致)"
    else:
        verdict = "操作码集异常/受限(连基本下载码都不全)"
    named = [f"0x{c:04X} {OPCODE_NAMES.get(c, '?')}" for c in sorted(ops)]
    return {"verdict": verdict, "has_download": has_dl,
            "has_control": has_ctrl, "named": named}

# 尼康 MAC OUI 提示 —— 默认空:真判据是能否完成 PTP/IP 握手,OUI 只是可选的眼力辅助。
# 想用就把相机菜单「网络设置 → MAC 地址」显示的前 3 段(如 "b8:e9:37")填进来。
NIKON_OUI_HINTS = set()


def log(msg=""):
    print(msg, flush=True)


# ======================================================================
# 底层:socket 读写与 PTP/IP 帧
# ======================================================================
def recvall(sock, n):
    """精确读 n 字节,不足即断开则抛异常。"""
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError(f"连接被对端关闭,期望 {n} 字节,已收 {len(buf)}")
        buf += chunk
    return buf


def send_packet(sock, pkt_type, payload):
    length = 8 + len(payload)  # 4字节长度 + 4字节类型 + 载荷
    sock.sendall(struct.pack("<II", length, pkt_type) + payload)


def read_packet(sock):
    """返回 (pkt_type, payload_bytes)。长度字段含自身,故先读4字节长度。"""
    header = recvall(sock, 4)
    (length,) = struct.unpack("<I", header)
    if length < 8:
        raise ValueError(f"非法 PTP/IP 包长度 {length}")
    body = recvall(sock, length - 4)
    (pkt_type,) = struct.unpack("<I", body[:4])
    return pkt_type, body[4:]


def utf16z(s):
    """UTF-16LE + 双字节 null 结尾。"""
    return s.encode("utf-16-le") + b"\x00\x00"


def read_utf16z(data, offset):
    """从 offset 读 UTF-16LE 直到双 null;返回 (字符串, 结束后偏移)。"""
    end = offset
    while end + 1 < len(data):
        if data[end] == 0 and data[end + 1] == 0:
            break
        end += 2
    text = data[offset:end].decode("utf-16-le", errors="replace")
    return text, end + 2


# ======================================================================
# PTP/IP 握手 + GetDeviceInfo
# ======================================================================
def ptpip_init(ip, guid, name, timeout=10.0):
    """
    执行 PTP/IP 双通道 Init 握手。
    返回 dict:{ok, camera_name, camera_guid, connection_number, fail_reason, cmd_sock, evt_sock}
    """
    result = {"ok": False, "camera_name": None, "camera_guid": None,
              "connection_number": None, "fail_reason": None,
              "cmd_sock": None, "evt_sock": None, "error": None}

    # ---- 命令通道 ----
    cmd = socket.create_connection((ip, PTPIP_PORT), timeout=timeout)
    cmd.settimeout(timeout)
    payload = guid + utf16z(name) + struct.pack("<I", 0x00010000)  # 协议版本 1.0
    send_packet(cmd, PKT_INIT_CMD_REQ, payload)

    ptype, body = read_packet(cmd)
    if ptype == PKT_INIT_FAIL:
        (reason,) = struct.unpack("<I", body[:4]) if len(body) >= 4 else (0,)
        result["fail_reason"] = reason
        result["error"] = f"相机拒绝 Init(Init Fail),reason=0x{reason:08X} —— 很可能就是未配对/需要认证码"
        cmd.close()
        return result
    if ptype != PKT_INIT_CMD_ACK:
        result["error"] = f"意外的响应包类型 {ptype}(期望 Init Cmd Ack=2)"
        cmd.close()
        return result

    conn_num = struct.unpack("<I", body[:4])[0]
    cam_guid = body[4:20]
    cam_name, off = read_utf16z(body, 20)
    result.update(connection_number=conn_num,
                  camera_guid=cam_guid.hex(),
                  camera_name=cam_name)

    # ---- 事件通道 ----
    try:
        evt = socket.create_connection((ip, PTPIP_PORT), timeout=timeout)
        evt.settimeout(timeout)
        send_packet(evt, PKT_INIT_EVT_REQ, struct.pack("<I", conn_num))
        etype, ebody = read_packet(evt)
        if etype == PKT_INIT_FAIL:
            (reason,) = struct.unpack("<I", ebody[:4]) if len(ebody) >= 4 else (0,)
            result["fail_reason"] = reason
            result["error"] = f"事件通道 Init Fail,reason=0x{reason:08X}"
            cmd.close(); evt.close()
            return result
        result["evt_sock"] = evt
    except Exception as e:
        result["error"] = f"事件通道建立失败:{e}"
        cmd.close()
        return result

    result["cmd_sock"] = cmd
    result["ok"] = True
    return result


def ptp_transaction(sock, opcode, params=(), tid=0, dataphase=DP_NODATA_OR_IN):
    """
    发一个 Operation Request,读回(可选)数据阶段 + Operation Response。
    返回 (response_code, params_list, data_bytes)。
    """
    payload = struct.pack("<I", dataphase)
    payload += struct.pack("<H", opcode)
    payload += struct.pack("<I", tid)
    for p in params:
        payload += struct.pack("<I", p)
    send_packet(sock, PKT_CMD_REQUEST, payload)

    data = b""
    while True:
        ptype, body = read_packet(sock)
        if ptype == PKT_START_DATA:
            continue  # body: tid(4) + total_len(8),这里不需要
        elif ptype == PKT_DATA:
            data += body[4:]  # 去掉 tid(4)
        elif ptype == PKT_END_DATA:
            data += body[4:]
        elif ptype == PKT_CMD_RESPONSE:
            rc = struct.unpack("<H", body[:2])[0]
            rest = body[2:]
            rtid = struct.unpack("<I", rest[:4])[0] if len(rest) >= 4 else None
            rparams = []
            i = 4
            while i + 4 <= len(rest):
                rparams.append(struct.unpack("<I", rest[i:i + 4])[0])
                i += 4
            return rc, rparams, data
        elif ptype == PKT_INIT_FAIL:
            reason = struct.unpack("<I", body[:4])[0] if len(body) >= 4 else 0
            raise ConnectionError(f"事务中收到 Init Fail 0x{reason:08X}")
        else:
            # 忽略事件等无关包,继续等响应
            continue


def hold_session(sock, seconds, keepalive="none", ping_interval=5.0, tid_start=1):
    """
    保持会话打开 `seconds` 秒,观测相机是否/何时主动掐断——回答"该模式会话能不能保持"。
    keepalive:
      none          只观察,不发任何包(测相机自然掐断时间)
      ping          每 ping_interval 秒发一个 PTP/IP Ping(type 13)
      getdeviceinfo 每 ping_interval 秒重发一次 GetDeviceInfo 当心跳
    返回 dict:{mode, dropped(bool), alive_seconds, note, events}
    """
    start = time.monotonic()
    events = []
    res = {"mode": keepalive, "dropped": None, "alive_seconds": None,
           "note": "", "events": events}

    if keepalive == "getdeviceinfo":
        # 主动轮询法:靠"发得出去且收得到 OK"判断会话是否还活着
        sock.settimeout(max(ping_interval, 6.0))
        tid = tid_start
        while True:
            elapsed = time.monotonic() - start
            if elapsed >= seconds:
                res.update(dropped=False, alive_seconds=round(elapsed, 1),
                           note=f"周期 GetDeviceInfo 心跳下保持 {seconds}s 未断")
                return res
            try:
                rc, _, _ = ptp_transaction(sock, OP_GET_DEVICE_INFO, tid=tid,
                                           dataphase=DP_NODATA_OR_IN)
                tid += 1
                events.append({"t": round(elapsed, 1), "getdeviceinfo_rc": f"0x{rc:04X}"})
            except Exception as e:
                res.update(dropped=True, alive_seconds=round(elapsed, 1),
                           note=f"心跳在 {round(elapsed,1)}s 时失败,会话已断:{e}")
                return res
            remaining = seconds - (time.monotonic() - start)
            if remaining <= 0:
                res.update(dropped=False, alive_seconds=round(time.monotonic() - start, 1),
                           note=f"周期 GetDeviceInfo 心跳下保持 {seconds}s 未断")
                return res
            time.sleep(min(ping_interval, remaining))

    # 被动观察(none)/ ping:靠 select 捕获相机的 FIN 或事件包
    sock.settimeout(1.0)
    last_ka = start
    while True:
        now = time.monotonic()
        elapsed = now - start
        if elapsed >= seconds:
            res.update(dropped=False, alive_seconds=round(elapsed, 1),
                       note=f"保持 {seconds}s 未被掐断(keepalive={keepalive})")
            return res
        if keepalive == "ping" and (now - last_ka) >= ping_interval:
            try:
                send_packet(sock, PKT_PING, b"")
                last_ka = now
            except Exception as e:
                res.update(dropped=True, alive_seconds=round(elapsed, 1),
                           note=f"发 Ping 失败,会话已断:{e}")
                return res
        try:
            r, _, _ = select.select([sock], [], [], 0.5)
        except Exception:
            r = []
        if r:
            try:
                ptype, body = read_packet(sock)
                events.append({"t": round(time.monotonic() - start, 1),
                               "pkt_type": ptype, "len": len(body)})
            except Exception as e:
                dropped_at = round(time.monotonic() - start, 1)
                res.update(dropped=True, alive_seconds=dropped_at,
                           note=f"相机在 {dropped_at}s 时掐断连接:{e}")
                return res


# ---- DeviceInfo 数据集解析 ----
def _read_u16(data, o): return struct.unpack("<H", data[o:o + 2])[0], o + 2
def _read_u32(data, o): return struct.unpack("<I", data[o:o + 4])[0], o + 4


def _read_ptpstr(data, o):
    n = data[o]; o += 1
    if n == 0:
        return "", o
    raw = data[o:o + n * 2]; o += n * 2
    return raw.decode("utf-16-le", errors="replace").rstrip("\x00"), o


def _read_u16_array(data, o):
    count, o = _read_u32(data, o)
    arr = []
    for _ in range(count):
        v, o = _read_u16(data, o)
        arr.append(v)
    return arr, o


def parse_device_info(data):
    o = 0
    info = {}
    info["standard_version"], o = _read_u16(data, o)
    info["vendor_ext_id"], o = _read_u32(data, o)
    info["vendor_ext_version"], o = _read_u16(data, o)
    info["vendor_ext_desc"], o = _read_ptpstr(data, o)
    info["functional_mode"], o = _read_u16(data, o)
    info["operations_supported"], o = _read_u16_array(data, o)
    info["events_supported"], o = _read_u16_array(data, o)
    info["device_props_supported"], o = _read_u16_array(data, o)
    info["capture_formats"], o = _read_u16_array(data, o)
    info["image_formats"], o = _read_u16_array(data, o)
    info["manufacturer"], o = _read_ptpstr(data, o)
    info["model"], o = _read_ptpstr(data, o)
    info["device_version"], o = _read_ptpstr(data, o)
    info["serial_number"], o = _read_ptpstr(data, o)
    return info


def probe_device_info(ip, guid, name, hold=0, keepalive="none"):
    """完整流程:Init → OpenSession → GetDeviceInfo(→ 可选 hold 观测会话保持)。返回结果 dict。"""
    out = {"ip": ip, "init": None, "open_session_rc": None,
           "get_device_info_rc": None, "device_info": None,
           "ops_classification": None, "hold": None, "error": None}
    init = ptpip_init(ip, guid, name)
    out["init"] = {k: init[k] for k in
                   ("ok", "camera_name", "camera_guid", "connection_number",
                    "fail_reason", "error")}
    if not init["ok"]:
        out["error"] = init["error"]
        return out

    cmd = init["cmd_sock"]
    tid = 0
    try:
        # OpenSession(session id = 1)
        rc, _, _ = ptp_transaction(cmd, OP_OPEN_SESSION, params=(1,), tid=tid,
                                   dataphase=DP_NODATA_OR_IN)
        out["open_session_rc"] = f"0x{rc:04X}"
        tid += 1
        if rc != RC_OK:
            out["error"] = (f"OpenSession 被拒 0x{rc:04X} —— 若为 0x2019/0x201E 类,"
                            f"多半是未配对/需先在相机上确认认证码")
            # 仍尝试 GetDeviceInfo(部分机型允许无会话取)
        rc, _, data = ptp_transaction(cmd, OP_GET_DEVICE_INFO, tid=tid,
                                      dataphase=DP_NODATA_OR_IN)
        tid += 1
        out["get_device_info_rc"] = f"0x{rc:04X}"
        if rc == RC_OK and data:
            di = parse_device_info(data)
            out["device_info"] = di
            out["ops_classification"] = classify_ops(di["operations_supported"])
        # 会话保持观测(最关键的新数据)
        if hold > 0:
            log(f"    [hold] 保持会话 {hold}s,keepalive={keepalive},观测相机是否掐断...")
            out["hold"] = hold_session(cmd, hold, keepalive=keepalive, tid_start=tid)
    except Exception as e:
        out["error"] = f"事务异常:{e}"
    finally:
        for s in (init.get("cmd_sock"), init.get("evt_sock")):
            try:
                if s: s.close()
            except Exception:
                pass
    return out


# ======================================================================
# 局域网发现
# ======================================================================
def local_ipv4():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return None
    finally:
        s.close()


def guess_subnet():
    ip = local_ipv4()
    if not ip:
        return None
    net = ipaddress.ip_interface(ip + "/24").network
    return str(net)


def scan_port(ip, port=PTPIP_PORT, timeout=0.4):
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except Exception:
        return False


def scan_subnet(cidr, workers=256):
    net = ipaddress.ip_network(cidr, strict=False)
    hosts = [str(h) for h in net.hosts()]
    log(f"[扫描] 网段 {cidr},共 {len(hosts)} 个地址,探测 TCP {PTPIP_PORT} ...")
    hits = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(scan_port, h): h for h in hosts}
        for f in as_completed(futs):
            if f.result():
                hits.append(futs[f])
                log(f"    命中 {futs[f]}:{PTPIP_PORT}")
    return sorted(hits, key=lambda x: tuple(int(p) for p in x.split(".")))


def arp_table():
    """解析本机 ARP 表:{ip: mac}。仅 Windows/常见 Linux。失败返回 {}。"""
    table = {}
    try:
        out = subprocess.run(["arp", "-a"], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return table
    import re
    for line in out.splitlines():
        m = re.search(r"(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F]{2}[:-][0-9a-fA-F]{2}"
                      r"[:-][0-9a-fA-F]{2}[:-][0-9a-fA-F]{2}[:-][0-9a-fA-F]{2}[:-]"
                      r"[0-9a-fA-F]{2})", line)
        if m:
            table[m.group(1)] = m.group(2).lower().replace("-", ":")
    return table


def oui_hint(mac):
    if not mac:
        return ""
    prefix = ":".join(mac.split(":")[:3])
    return "  <== MAC 命中尼康 OUI 提示" if prefix in NIKON_OUI_HINTS else ""


def mdns_discover(timeout=5.0):
    """
    用 zeroconf 发现相机。返回 (found, service_types):
      found         = [(name, ip, port, service_type)]  各服务实例
      service_types = 局域网上枚举到的全部服务类型(用来实证尼康到底用哪个服务名,
                      而不是想当然认定 _ptp._tcp)
    无 zeroconf 返回 (None, None)。
    """
    try:
        from zeroconf import Zeroconf, ServiceBrowser, ZeroconfServiceTypes
    except ImportError:
        return None, None

    zc = Zeroconf()
    service_types = []
    try:
        # 1) 先枚举局域网广告的所有服务类型(元查询)
        try:
            service_types = sorted(ZeroconfServiceTypes.find(zc=zc, timeout=timeout))
        except Exception:
            service_types = []

        # 2) 对每个类型(至少包含 _ptp._tcp)逐一浏览,拿实例地址
        browse_types = sorted(set(service_types) | {"_ptp._tcp.local."})
        found = []

        class Listener:
            def __init__(self, stype):
                self.stype = stype

            def add_service(self, zc_, type_, name):
                info = zc_.get_service_info(type_, name, timeout=3000)
                if info:
                    for addr in info.parsed_addresses():
                        found.append((name, addr, info.port, type_))

            def update_service(self, *a):
                pass

            def remove_service(self, *a):
                pass

        browsers = [ServiceBrowser(zc, t, Listener(t)) for t in browse_types]
        time.sleep(min(timeout, 4.0))
        return found, service_types
    finally:
        zc.close()


# ======================================================================
# 主流程
# ======================================================================
def main():
    ap = argparse.ArgumentParser(
        description="尼康「连接到电脑」PTP/IP 握手实验探针",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ip", help="已知相机 IP,跳过发现直接握手")
    ap.add_argument("--subnet", help="要扫描的网段 CIDR,如 192.168.137.0/24;缺省自动猜测本机 /24")
    ap.add_argument("--discover-only", action="store_true", help="只发现设备,不做握手")
    ap.add_argument("--no-mdns", action="store_true", help="跳过 mDNS 浏览")
    ap.add_argument("--guid", help="自定义本机 GUID(32 位十六进制)")
    ap.add_argument("--name", default=DEFAULT_NAME, help=f"本机 FriendlyName(默认 {DEFAULT_NAME})")
    ap.add_argument("--hold", type=int, default=0, metavar="SEC",
                    help="握手后保持会话 SEC 秒,观测相机是否/何时掐断(0=不保持)")
    ap.add_argument("--keepalive", choices=("none", "ping", "getdeviceinfo"),
                    default="none", help="hold 期间的心跳方式(默认 none 只观察)")
    ap.add_argument("--out", help="结果 JSON 输出路径(默认 ./ptpip_probe_<时间戳>.json)")
    args = ap.parse_args()

    guid = bytes.fromhex(args.guid) if args.guid else DEFAULT_GUID
    if len(guid) != 16:
        log("[错误] GUID 必须是 16 字节(32 位十六进制)"); sys.exit(2)

    stamp = time.strftime("%Y%m%d_%H%M%S")
    out_path = args.out or os.path.join(os.getcwd(), f"ptpip_probe_{stamp}.json")
    report = {"timestamp": stamp, "local_ip": local_ipv4(),
              "our_name": args.name, "our_guid": guid.hex(),
              "candidates": [], "probes": []}

    log("=" * 68)
    log("尼康 PTP/IP 握手实验探针")
    log("=" * 68)
    log(f"本机 IP      : {report['local_ip']}")
    log(f"本机 GUID    : {guid.hex()}   (Wireshark 里按这个认我们的包)")
    log(f"本机名称     : {args.name}")
    log("")

    candidates = []  # [(ip, source, mac)]

    if args.ip:
        candidates.append((args.ip, "手动指定", None))
    else:
        # 1) mDNS(枚举全部服务类型 + 拿实例)
        if not args.no_mdns:
            log("[发现-1] mDNS:枚举局域网服务类型 + 浏览(约 5 秒)...")
            m, stypes = mdns_discover()
            if m is None:
                log("    未安装 zeroconf,跳过 mDNS(pip install zeroconf 可启用)")
            else:
                if stypes:
                    log(f"    局域网广告的服务类型({len(stypes)} 种,用于确认尼康真实服务名):")
                    for t in stypes:
                        log(f"      - {t}")
                    report["mdns_service_types"] = stypes
                if not m:
                    log("    未解析到具体服务实例(相机可能不广播 mDNS,靠端口扫描兜底)")
                for name, ip, port, stype in m:
                    log(f"    mDNS 实例:{ip}:{port}  type={stype}  ({name})")
                    candidates.append((ip, f"mDNS:{stype}", None))

        # 2) 端口扫描
        subnet = args.subnet or guess_subnet()
        if subnet:
            hits = scan_subnet(subnet)
            arp = arp_table()
            for ip in hits:
                mac = arp.get(ip)
                if ip not in [c[0] for c in candidates]:
                    candidates.append((ip, "端口15740", mac))
        else:
            log("[发现-2] 无法自动判断网段,请用 --subnet 指定")

    # 去重
    seen, uniq = set(), []
    for ip, src, mac in candidates:
        if ip in seen:
            continue
        seen.add(ip)
        if mac is None:
            mac = arp_table().get(ip)
        uniq.append((ip, src, mac))

    log("")
    log("-" * 68)
    log(f"候选设备({len(uniq)} 台):")
    for ip, src, mac in uniq:
        log(f"  {ip:<16} 来源={src:<22} MAC={mac or '?'}{oui_hint(mac)}")
        report["candidates"].append({"ip": ip, "source": src, "mac": mac})
    log("-" * 68)

    if not uniq:
        log("没有找到任何候选设备。检查:相机是否已连上同一网络?防火墙是否放行 15740?")
        _dump(report, out_path)
        return

    if args.discover_only:
        log("(--discover-only)不做握手。")
        _dump(report, out_path)
        return

    # 3) 逐个握手确认 —— 能完成 PTP/IP Init 的才是相机
    log("")
    log("[握手] 逐个尝试 PTP/IP Init + GetDeviceInfo(能回读 FriendlyName 的即为相机)...")
    for ip, src, mac in uniq:
        log("")
        log(f">>> 探测 {ip} ...")
        res = probe_device_info(ip, guid, args.name, hold=args.hold,
                                keepalive=args.keepalive)
        res["source"] = src
        res["mac"] = mac
        report["probes"].append(res)
        _print_probe(res)

    _dump(report, out_path)
    log("")
    log(f"[完成] 完整结果已写入:{out_path}")
    log("       把这个 JSON 连同 Wireshark 的 .pcapng 一起发我,即可分析。")


def _print_probe(res):
    init = res.get("init") or {}
    if init.get("ok"):
        log(f"    ✅ Init 成功 —— 相机名:『{init.get('camera_name')}』")
        log(f"       相机 GUID:{init.get('camera_guid')}")
        log(f"       OpenSession:{res.get('open_session_rc')}  "
            f"GetDeviceInfo:{res.get('get_device_info_rc')}")
        di = res.get("device_info")
        if di:
            vendor = "Nikon" if di["vendor_ext_id"] == NIKON_VENDOR_EXT_ID else f"0x{di['vendor_ext_id']:08X}"
            log(f"       机型:{di['manufacturer']} {di['model']}  固件:{di['device_version']}")
            log(f"       序列号:{di['serial_number']}  厂商扩展:{vendor}")
            log(f"       操作码 {len(di['operations_supported'])} 个,"
                f"属性码 {len(di['device_props_supported'])} 个 "
                f"(详见 JSON)")
        cls = res.get("ops_classification")
        if cls:
            log(f"       操作码判定:{cls['verdict']}")
        hold = res.get("hold")
        if hold:
            if hold["dropped"] is True:
                log(f"       ⏱ 会话保持:相机在 {hold['alive_seconds']}s 掐断"
                    f"(keepalive={hold['mode']})—— {hold['note']}")
            elif hold["dropped"] is False:
                log(f"       ⏱ 会话保持:{hold['note']} ✅")
        if res.get("error"):
            log(f"       ⚠ {res['error']}")
    else:
        log(f"    ❌ 未能握手:{init.get('error') or res.get('error')}")
        if init.get("fail_reason") is not None:
            log(f"       Init Fail reason = 0x{init['fail_reason']:08X}")
        log(f"       (这台大概率不是相机,或相机在等你确认配对认证码)")


def _dump(report, path):
    def default(o):
        if isinstance(o, bytes):
            return o.hex()
        return str(o)
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2, default=default)
    except Exception as e:
        log(f"[警告] 写 JSON 失败:{e}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("\n已中断。")
