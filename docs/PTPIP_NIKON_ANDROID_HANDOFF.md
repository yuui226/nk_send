# Nikon PTP/IP 手机热点连接模式：抓包分析与 Android 实现交接

> 文档用途：将本文件复制到 Android App 项目根目录后，后续开发者或 AI 可以直接据此实现 Nikon PTP/IP 连接模式，无需重新分析原始抓包。

## 1. 目标与范围

目标是在现有 Android App 的 Nikon FTP 连接模式之外，增加 PTP/IP 连接模式：

1. 用户在 Android 系统中开启可共享移动网络的手机热点。
2. 用户在 Nikon 相机端选择该热点并手动输入 Wi-Fi 密码。
3. 相机作为 Wi-Fi STA 客户端加入手机热点。
4. App 在热点局域网内发现相机。
5. App 通过 TCP 15740 建立 PTP/IP 命令通道和事件通道。
6. App 枚举相机存储、目录和照片，显示缩略图，并下载原图。

明确不属于 App 的范围：

- 不通过 App 配置相机 Wi-Fi。
- 不通过 BLE 下发热点 SSID 或密码。
- 不负责相机端输入热点密码的步骤。
- 不需要逆向 Nikon 蓝牙配对协议。

## 2. 证据来源

分析了以下两份 PCAPdroid 抓包：

- `PCAPdroid_20_7月_10_49_59.pcap`
  - 约 23 MB，57.269 秒，11,260 个包。
  - 包含完整 PTP/IP 握手、照片枚举、38 次缩略图请求和 2 次原图下载。
- `PCAPdroid_20_7月_14_51_09.pcap`
  - 约 243 KB，34.038 秒，694 个包。
  - 包含 mDNS 查询、局域网端口扫描、PTP/IP 探测、正式命令/事件通道建立和缩略图加载。

PCAPdroid 使用 Android VPN 层抓包。抓包中的地址可能经过虚拟映射：

```text
手机/App：10.215.173.1
相机：    10.126.252.124
DNS：     10.215.173.2
```

这些地址不能硬编码到 App。实现时必须从 Android 当前热点/本地网络的 `LinkProperties` 推导 IPv4 地址和 prefix。

## 3. 已确认的协议与设备

协议为标准 PTP/IP（Picture Transfer Protocol over IP），不是 FTP，也不是加密私有传输协议。

```text
传输层：TCP
服务端口：15740
字节序：Little Endian
TLS：无
额外文件加密：无
```

抓包中的相机：

```text
Manufacturer：Nikon Corporation
Model：       Z 30
Firmware：    V1.20
Serial：      00000000000000000000000007634604
PTP/IP Version：0x00010000
Responder Name：JJJJ_7634604
Responder GUID：04b004520000100180013cbee12fd59d
```

参考实现：

- https://github.com/mmattes/ptpip
- https://github.com/gphoto/libgphoto2
- libgphoto2 `camlibs/ptp2/ptp.h` 包含 PTP/IP packet type、operation code 和 response code 定义。

建议原生 Kotlin 实现本项目实际使用的协议子集，不建议为了少量操作将整个 libgphoto2 编译进 Android。

## 4. 高层状态机

```text
用户开启手机系统热点
        ↓
用户在相机端选择热点并输入密码
        ↓
相机加入热点局域网
        ↓
App 获取热点网络 IPv4/prefix
        ↓
并行/分级发现
  ① mDNS _ptp._tcp.local
  ② mDNS _nikon._tcp.local
  ③ 无响应时扫描子网 TCP 15740
        ↓
对候选地址进行 PTP/IP InitCommand 探测
        ↓
识别并保存相机 IP/GUID/名称
        ↓
建立正式 Command Socket
        ↓
建立 Event Socket（携带 Command Ack 的 connectionNumber）
        ↓
Ping/Pong（可选健康检查）
        ↓
OpenSession(sessionId=1)
        ↓
Storage → 目录 → ObjectInfo → Thumb/Object
```

## 5. 相机发现流程

### 5.1 mDNS

第二份抓包中，App 首先向 `224.0.0.251:5353` 发送两个 PTR 查询：

```text
_ptp._tcp.local.
_nikon._tcp.local.
```

本次没有收到 mDNS 响应，因此竞争产品回退到子网扫描。

Android 可使用 `NsdManager.discoverServices()`：

```text
serviceType = "_ptp._tcp."
serviceType = "_nikon._tcp."
```

注意：`NsdManager` 的 API 和并发 discovery 限制需要按 App 的 minSdk/targetSdk 封装。mDNS 是优化项，不能作为唯一发现方式。

### 5.2 TCP 15740 子网扫描

抓包显示竞争产品依次扫描：

```text
10.126.252.1:15740
10.126.252.2:15740
...
10.126.252.124:15740  ← Nikon 返回 SYN-ACK
```

行为特征：

- 大致每批投放约 32 个连接。
- 并发执行，而不是逐地址串行等待。
- 找到 `.124` 后停止继续投放 `.130` 之后的地址。
- TCP 端口开放后还会执行 PTP/IP 应用层验证。

推荐实现：

- 从 `ConnectivityManager`/`LinkProperties` 获取热点局域网对应的 IPv4 LinkAddress。
- 根据 prefix 计算候选 host，不能假设一定是 `/24`。
- 排除 network address、broadcast address 和手机自己的地址。
- 并发度建议 16～32。
- 单地址 connect timeout 建议先使用 500～1000 ms，根据真机调整。
- 找到经过 PTP/IP 验证的相机后取消其他任务。
- 保存上次成功 IP，下一次先快速探测该 IP，再执行全扫描。

安全/兼容性要求：不要扫描当前默认互联网接口或任意公网段；只扫描被识别为热点本地网络的私有 IPv4 子网。

### 5.3 PTP/IP 应用层验证

TCP 15740 建连成功后发送 `InitCommandRequest`。收到合法 `InitCommandAck` 才能确认是 PTP/IP 设备。

竞争产品的发现探测流程：

```text
14.668s  TCP SYN → 10.126.252.124:15740
14.835s  收到 SYN-ACK
14.849s  发送 InitCommandRequest
14.883s  收到 InitCommandAck
14.886s  主动关闭探测连接
```

正式使用时可以重新连接；也可以设计为复用已验证 socket，但重新连接更容易保持 discovery 与 session 生命周期分离。

## 6. PTP/IP 封包基础

所有 PTP/IP 包都以如下 8 字节 header 开始：

```text
uint32 length       // 包含 header 的完整包长，小端
uint32 packetType   // 小端
byte[] body         // length - 8 字节
```

已使用的 packet type：

| Type | 名称 | 方向/用途 |
|---:|---|---|
| 1 | Init Command Request | App → Camera，初始化命令通道 |
| 2 | Init Command Ack | Camera → App，返回连接号和相机身份 |
| 3 | Init Event Request | App → Camera，初始化事件通道 |
| 4 | Init Event Ack | Camera → App |
| 5 | Init Fail | 初始化失败 |
| 6 | Command Request | App → Camera，PTP 操作 |
| 7 | Command Response | Camera → App |
| 8 | Event | Camera → App，异步 PTP 事件 |
| 9 | Start Data Packet | 数据阶段开始，包含总长度 |
| 10 | Data Packet | 中间数据块 |
| 11 | Cancel Transaction | 取消事务 |
| 12 | End Data Packet | 最后数据块 |
| 13 | Ping | 保活/验证 |
| 14 | Pong | Ping 响应 |

TCP 是字节流：一次 socket `read()` 可能只返回半个 header，也可能返回一个半包或多个完整包。必须：

1. 精确读取 8 字节 header。
2. 校验 `length >= 8` 且不超过合理上限。
3. 再精确读取 `length - 8` 字节 body。
4. 大文件数据必须流式消费，不能把整张图片读入内存。

## 7. 双通道初始化

### 7.1 Command Socket

连接 `cameraIp:15740` 后发送：

```text
InitCommandRequest body:
byte[16] initiatorGuid
UTF-16LE initiatorName + 00 00
uint32 protocolVersion = 0x00010000
```

注意：这里的 GUID 在抓包中是 16 个 ASCII 字节，不是 RFC UUID 的二进制布局：

```text
第一份抓包："0acc0293783de869"
第二份抓包："d85a83c60bbf2934"
```

名称为 UTF-16LE、以双零结束：

```text
Ace6T
```

GUID 每次可能不同，说明可在安装时生成并持久化，或者每次连接生成；优先持久化一个随机 16 位十六进制 ASCII initiator ID。

相机响应：

```text
InitCommandAck body:
uint32 connectionNumber
byte[16] responderGuid
UTF-16LE responderName + 00 00
uint32 protocolVersion
```

抓包实际值：

```text
connectionNumber = 1
responderGuid = 04b004520000100180013cbee12fd59d
responderName = JJJJ_7634604
protocolVersion = 0x00010000
```

### 7.2 Event Socket

建立第二个 TCP 15740 连接，然后发送：

```text
length = 12
type = 3
uint32 connectionNumber  // 必须使用 Command Ack 返回值
```

相机响应：

```text
length = 8
type = 4
```

第二份抓包中的正式初始化时间线：

```text
26.869s  建立 command TCP
26.906s  InitCommandRequest
26.926s  InitCommandAck
26.931s  建立 event TCP
26.944s  InitEventRequest(connectionNumber=1)
26.966s  InitEventAck
26.968s  Ping
26.993s  Pong
```

## 8. Command、Response 与数据阶段

### 8.1 Command Request

```text
uint32 length
uint32 type = 6
uint32 dataPhase
uint16 operationCode
uint32 transactionId
uint32 params[0..5]
```

本次抓包中读取操作的 `dataPhase` 为 `1`。

### 8.2 Command Response

```text
uint32 length
uint32 type = 7
uint16 responseCode
uint32 transactionId
uint32 optionalParams[]
```

抓包中成功响应：

```text
0x2001 = OK
```

必须校验 Response 的 transactionId 与当前请求一致。

### 8.3 相机到 App 的数据

`StartDataPacket (type=9)` body：

```text
uint32 transactionId
uint64 totalDataLength
```

`DataPacket (type=10)` 或 `EndDataPacket (type=12)` body：

```text
uint32 transactionId
byte[] payload
```

常见序列：

```text
CommandRequest
StartDataPacket
DataPacket × N       // 小数据可能没有
EndDataPacket
CommandResponse
```

实现必须累计 payload 字节数，并与 StartData 的 `totalDataLength` 比较。

## 9. 抓包确认的 PTP 操作

| Opcode | 名称 | 作用 |
|---:|---|---|
| `0x1001` | GetDeviceInfo | 标准设备信息；相机声明支持 |
| `0x1002` | OpenSession | 打开 PTP session |
| `0x1003` | CloseSession | 关闭 session |
| `0x1004` | GetStorageIDs | 获取存储 ID |
| `0x1005` | GetStorageInfo | 获取存储信息 |
| `0x1007` | GetObjectHandles | 获取对象 handle 列表 |
| `0x1008` | GetObjectInfo | 获取文件/目录元数据 |
| `0x1009` | GetObject | 下载完整对象/原图 |
| `0x100A` | GetThumb | 获取缩略图 |
| `0x1015` | GetDevicePropValue | 读取相机属性 |
| `0x941C` | Nikon vendor operation | 初始化阶段出现，返回 4 个零字节，意义未确认 |

抓包中使用的主要顺序：

```text
OpenSession(1)
Nikon 0x941C
GetStorageIDs
GetStorageInfo(storageId)
GetObjectHandles(...)
GetObjectInfo(handle) × N
GetThumb(handle) × N
GetObject(handle)       // 用户选择下载原图时
```

特殊兼容点：该 Z30 在抓包中对 `OpenSession(1)` 返回了 351 字节 DeviceInfo 数据，而不是单纯无数据 OK。实现不能把 OpenSession 的意外数据阶段视为协议错误。建议兼容：

- OpenSession 后直接收到 DeviceInfo；或
- OpenSession 只收到 OK，再主动执行 GetDeviceInfo。

`0x941C` 暂时实现为可选兼容调用：失败时记录日志，不应阻止标准枚举流程，除非实机验证表明 Nikon 必须调用。

## 10. 存储、目录与对象

抓包中的存储和目录：

```text
Storage ID：       0x00010001
DCIM Handle：      0x11004000
101NZ_30 Handle：  0x11194000
```

示例目录枚举：

```text
GetObjectHandles(
    storageId = 0x00010001,
    objectFormat = 0,
    associationHandle = 0x11194000
)
```

返回 PTP uint32 array：

```text
uint32 count
uint32 handles[count]
```

抓包中也使用了 Association（目录）format 筛选：

```text
objectFormat = 0x3001  // Association/目录，不是 JPEG；JPEG/EXIF 是 0x3801
```

建议首版采用稳妥的树遍历：获取 storage 根对象，识别 Association 目录，再进入 DCIM 子目录；不要硬编码 `DCIM` handle 或 `101NZ_30` 名称。

## 11. PTP ObjectInfo 需要解析的字段

ObjectInfo 至少包含：

```text
StorageID
ObjectFormat
ProtectionStatus
ObjectCompressedSize
ThumbFormat
ThumbCompressedSize
ThumbPixWidth
ThumbPixHeight
ImagePixWidth
ImagePixHeight
ImageBitDepth
ParentObject
AssociationType
AssociationDesc
SequenceNumber
Filename
CaptureDate
ModificationDate
Keywords
```

PTP 字符串格式：

```text
uint8 charCount       // 包含结尾 NUL 的 UTF-16 code unit 数量
uint16 chars[count]   // UTF-16LE
```

不能直接把剩余 buffer 当作普通零结尾 UTF-16 字符串。

抓包示例：

```text
Handle：    0x2919604F
Filename：  Z30_8271.JPG
Size：      10,219,943 bytes
Thumb：     12,830 bytes，160×120
Image：     5568×3712
Created：   20260719T221831
Parent：    0x11194000
Format：    0x3801 (JPEG)
```

## 12. 缩略图

调用：

```text
GetThumb = 0x100A
param1 = objectHandle
```

抓包确认：

```text
格式：标准 JPEG
起始字节：FF D8
尺寸：160 × 120
大小：约 9.3～12.8 KB
```

第一份抓包共请求 38 张缩略图。缩略图数据可直接提供给 Coil/Glide/BitmapFactory。

建议：

- 对 `(cameraGuid, objectHandle, objectSize/modifiedDate)` 建立磁盘缓存 key。
- 首屏按可见范围加载，避免无条件拉取整个卡的所有缩略图。
- PTP command channel 初期保持单事务串行；不要在同一 command socket 上同时发多个 GetThumb。
- UI 可并发解码，但协议请求队列保持串行。

## 13. 原图下载与真实性能

调用：

```text
GetObject = 0x1009
param1 = objectHandle
```

抓包中的两张原图：

| 文件 | Handle | 字节数 | 分辨率 | 数据阶段耗时 | 有效吞吐 |
|---|---:|---:|---:|---:|---:|
| Z30_8271.JPG | `0x2919604F` | 10,219,943 | 5568×3712 | 13.750 s | 0.743 MB/s（0.709 MiB/s） |
| Z30_8264.JPG | `0x29196048` | 11,709,343 | 5568×3712 | 14.043 s | 0.834 MB/s（0.795 MiB/s） |

结论：这份 Z30 抓包里的 PTP/IP 原图吞吐只有约 0.7～0.8 MiB/s，不能预设它一定比现有 FTP 更快。PTP/IP 的明确优势是标准化对象浏览、缩略图、事件和按 handle 下载。最终速度必须在同一相机、同一热点、同一文件下与 FTP 实测。

下载实现要求：

- 收到 StartData 后创建临时文件。
- Data/EndData payload 直接写 `FileOutputStream`/buffered sink。
- 不要为 10 MB～数百 MB 文件分配等长 ByteArray。
- 校验实际接收长度与 `uint64 totalDataLength`。
- 下载成功后 flush/fsync（按产品可靠性要求）并原子重命名。
- 失败或取消时删除临时文件，不影响已完成文件。
- 提供基于已接收字节数的进度。

## 14. 事件通道

相机 DeviceInfo 声明的部分标准事件：

```text
0x4001 CancelTransaction
0x4002 ObjectAdded
0x4003 ObjectRemoved
0x4004 StoreAdded
0x4005 StoreRemoved
0x4006 DevicePropChanged
0x4007 ObjectInfoChanged
0x4008 DeviceInfoChanged
0x4009 RequestObjectTransfer
0x400A StoreFull
0x400C StorageInfoChanged
0x400D CaptureComplete
```

还声明了 Nikon vendor event（例如 `0xC101` 等）。首版至少处理：

- `0x4002 ObjectAdded`：获取新 handle 的 ObjectInfo，根据需求自动加载缩略图或下载。
- `0x4003 ObjectRemoved`：从列表/缓存索引移除。
- `0x4006 DevicePropChanged`：必要时刷新属性。
- socket EOF/异常：触发断线状态和重连。

未知 vendor event 应记录 code、transactionId 和参数，但不能导致 reader 崩溃。

## 15. Android 推荐模块结构

```text
connection/ptpip/
├── PtpIpDiscovery.kt
│   ├── discoverMdns()
│   ├── scanLocalSubnet()
│   └── probePtpIp()
├── PtpIpPacket.kt
│   ├── packet type constants
│   ├── encode helpers
│   └── decode helpers
├── PtpIpSocketReader.kt
│   └── readExactly / length-prefixed packet parser
├── PtpIpConnection.kt
│   ├── commandSocket
│   ├── eventSocket
│   ├── initCommandChannel()
│   ├── initEventChannel()
│   └── close()
├── PtpTransactionQueue.kt
│   ├── transactionId
│   ├── Mutex / Channel
│   └── response correlation
├── PtpSession.kt
│   ├── openSession()
│   ├── getStorageIds()
│   ├── getStorageInfo()
│   ├── getObjectHandles()
│   ├── getObjectInfo()
│   ├── getThumb()
│   └── getObjectToFile()
├── PtpEventLoop.kt
└── model/
    ├── DiscoveredCamera.kt
    ├── PtpDeviceInfo.kt
    ├── PtpStorageInfo.kt
    └── PtpObjectInfo.kt
```

推荐用 Kotlin coroutines，但 socket reader 必须保证每条通道只有一个消费者。Command writer 可以通过 `Channel<PtpRequest>` 串行化。

## 16. 网络与权限注意事项

基本权限：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
```

按 targetSdk 和所用 Wi-Fi/本地网络 API 评估：

- Android 13+ 的 `NEARBY_WIFI_DEVICES`。
- 新 Android 版本的本地网络访问权限变化。
- NsdManager 的版本差异。

本模式要求“手机系统热点仍提供互联网”。`WifiManager.startLocalOnlyHotspot()` 明确不提供互联网，所以不能用它替代用户开启的系统共享热点。

普通第三方 App 不应假设能够静默开启带互联网共享的 tethering hotspot。产品流程应引导用户打开系统热点，然后检测热点本地网络和相机连接状态。

PCAPdroid 抓包证明 PTP/IP 和手机互联网流量可同时存在。

## 17. 并发、超时与恢复策略

推荐默认值（需要真机调优）：

```text
mDNS 等待：       1.5～2.0 s
扫描并发度：      16～32
扫描 connect：    500～1000 ms
PTP 探测握手：    1～2 s
正式连接握手：    3～5 s
普通命令：        3～10 s
缩略图：          5～15 s
原图：            按长度/吞吐动态计算，不使用很短的固定超时
```

恢复顺序：

1. command/event socket 任一关键通道断开，停止发新事务。
2. 取消或失败完成当前事务，关闭两条 socket。
3. 优先探测上次 IP。
4. 失败则 mDNS + 子网扫描。
5. 重新建立双通道并 OpenSession。
6. 根据 UI 状态重新枚举或恢复未完成下载；不要假设旧 handle 永远有效。

## 18. 协议健壮性与安全检查

- 限制 packet length，拒绝 `< 8` 或不合理的大控制包。
- 大数据包长度使用 `Long`/uint64 语义处理，防止 Int 溢出。
- 校验 transactionId。
- 校验数据阶段累计长度。
- 文件名只取 basename，禁止 `../`、绝对路径或相机提供的路径逃逸。
- 不因未知 packet type/opcode/event 崩溃；记录并按协议安全跳过或断开。
- 不把扫描扩展到当前热点私有子网之外。
- initiator GUID 不视为安全凭证；PTP/IP 握手本身未显示认证或加密。
- 当前模式的安全边界依赖 WPA2/WPA3 手机热点和用户物理控制。

## 19. MVP 实施顺序

### Phase 1：协议最小闭环

1. Little-endian codec 和 `readExactly`。
2. InitCommand/InitEvent/Ping/Pong。
3. OpenSession。
4. GetStorageIDs/GetStorageInfo。
5. GetObjectHandles/GetObjectInfo。
6. GetThumb，UI 显示单张缩略图。
7. GetObjectToFile，验证大小和 JPEG。

初期允许手工输入相机 IP，以隔离 discovery 与协议问题。

### Phase 2：自动发现

1. 上次 IP 快速探测。
2. mDNS `_ptp._tcp.` 与 `_nikon._tcp.`。
3. 热点私有子网并发扫描 15740。
4. PTP/IP 应用层验证和设备选择。

### Phase 3：产品化

1. 照片分页/可见项缩略图加载。
2. 磁盘缓存。
3. Event ObjectAdded 自动刷新。
4. 下载队列、进度、取消、失败重试。
5. 断线重连。
6. 与现有 FTP 模式抽象统一的 connection/session/repository 接口。
7. 同条件 FTP/PTP-IP 性能基准。

## 20. 验收标准

- 相机手动加入手机热点后，App 能在合理时间内自动发现 Z30。
- 能正确显示型号 `Z 30`、固件 `V1.20` 或实际连接设备信息。
- Command/Event 两条通道初始化成功。
- 能解析存储和 DCIM 目录，不依赖抓包中的固定 handle。
- 能显示 160×120 JPEG 缩略图。
- 能完整下载原图，输出大小与 ObjectInfo/StartData 一致。
- 下载过程中内存不会随文件大小线性增长。
- 热点保持移动网络可用。
- 相机断开/重连后 App 能恢复。
- 未知 Nikon vendor event/opcode 不造成崩溃。

## 21. 尚未确认、需要实机验证的事项

- 不同 Nikon 型号是否都响应 `_ptp._tcp` 或 `_nikon._tcp` mDNS。
- Z30 之外的相机是否需要 `0x941C` 初始化。
- 不同固件对 OpenSession 返回 DeviceInfo 的行为是否一致。
- Android 各厂商热点接口在 `ConnectivityManager` 中的识别方式。
- `/24` 之外 prefix 的扫描性能和限制。
- event socket 的长期保活周期；抓包只确认了 Ping/Pong 能用。
- 多张连续下载是否需要额外 Nikon vendor 操作。
- PTP/IP 与现有 FTP 在相同 RF 条件下的真实速度差异。

## 22. 给后续开发者/AI 的直接任务提示

如果此文档位于 Android App 项目根目录，可直接使用以下任务描述：

> 阅读 `PTPIP_NIKON_ANDROID_HANDOFF.md`，检查现有 FTP 连接架构和项目约束。在不破坏 FTP 模式的前提下，按文档 Phase 1 实现 Nikon PTP/IP Kotlin 客户端，先支持手工 IP 的双通道握手、OpenSession、存储/对象枚举、缩略图和原图流式下载；为后续 discovery 保留接口。运行现有测试并补充协议 codec、分包读取和解析测试。

发现阶段的后续提示：

> 基于 `PTPIP_NIKON_ANDROID_HANDOFF.md` 的第 5、16、17 节，为 PTP/IP 模式加入上次 IP、mDNS 和热点私有子网 TCP 15740 扫描。候选设备必须通过 InitCommandRequest/Ack 验证；禁止扫描热点局域网之外的网络。
