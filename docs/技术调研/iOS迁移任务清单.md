# iOS 迁移任务清单

> 给后续实现过程使用的轻量执行账本。架构结论见 [iOS版本1比1复刻方案](./iOS版本1比1复刻方案.md)。

## 当前状态

- 分支：`research/ios`
- 产品版本：`1.81`（Android `versionCode` / iOS build 均为 `54`）
- 当前阶段：Android 可复用核心与最小 presentation 规则共享化已完成（Windows 阶段 100%）
- 下一项：`M01`，在 M1 Mac 上验收 Xcode/shared framework 链路
- Mac 最近检查点：`M01`，在第一批真实共享协议完成后执行

状态只使用：`DONE`、`NEXT`、`TODO`、`MAC`、`BLOCKED`。

## 完成规则

一个迁移任务只有同时满足以下条件才能标记 `DONE`：

1. 代码迁入 `commonMain`，不是复制一份。
2. Android 已改为使用迁入后的实现，原包名/API 尽量保持不变。
3. 共享逻辑及对应测试迁入 `commonTest`，固定输入输出不变。
4. Android 相关测试、Lint 和标准 Debug 打包按风险完成验证。
5. 涉及 Native/Apple API 时，在 Mac 补齐 Kotlin/Native、模拟器或真机证据。
6. 本文状态和“验证记录”同步更新。

## 任务

### 0. 基础设施

| ID | 状态 | 任务 | 完成点 |
|---|---|---|---|
| F01 | DONE | Android 1.81 基线、方案和迁移分支 | 版本、方案、分支已建立 |
| F02 | DONE | 建立单一 `shared` KMP 模块 | Android 已依赖 shared；`commonMain/commonTest` 可用 |
| F03 | DONE | 建立 iOS 工程入口 | 真机/M1 模拟器 target、framework、Xcode 脚本和 Shared Scheme 已配置 |
| F04 | DONE | Windows 侧 Android 安全验收 | 测试、Lint、Debug APK、真机安装启动通过 |
| M01 | MAC | 首次 Mac 工程链路验收 | `xcodebuild` 成功，Swift 可导入 `ZTransferShared`，模拟器启动 |
| M02 | MAC | 首次 iPhone 权限/网络探针 | Local Network 授权与相机 Wi-Fi 基础连通通过 |

### 1. Android 可共享代码盘点

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| S01 | DONE | 列出可共享类型、Android/Java 依赖和迁移顺序 | 已按直接迁移、先拆边界、平台保留三类完成盘点 |
| S02 | DONE | 冻结协议和业务固定样本 | PTP 字节、排序结果、队列状态、GPS payload、EXIF/滤镜结果均有确定性 oracle |
| S03 | DONE | 明确平台接口清单 | 九类能力已有端侧归属和窄接口时机；不预建空壳总接口 |

### 2. 纯模型与基础规则

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| C01 | DONE | 迁移连接方式模型 | `CameraConnectionType` 已由 Android 使用 |
| C02 | DONE | 迁移通用枚举、错误和相机/文件值模型 | 文件、下载、相机响应、遥控结果及 GPS 地名状态已共享；Android IO 内部状态未扩大 API |
| C03 | DONE | 迁移格式化、坐标、日期和数值规则 | 阈值/单位/坐标/日期标签共享；Locale 与 `LocalDate` 保留平台薄适配 |
| C04 | DONE | 迁移共享测试工具和固定样本加载 | 内联 hex/byte fixture 统一且保持零文件系统/平台依赖 |

### 3. PTP 与相机协议

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| P01 | DONE | PTP/PTP-IP 常量和格式映射 | 纯常量迁入 shared；Android 响应文案留平台层 |
| P02 | DONE | PTP 基础字节读写与容器 codec | 包头、端序、长度边界和异常输入已固定，Socket 流读取仍留 Android |
| P03 | DONE | PTP/IP 握手和命令/事件包 | AP/STA 握手、命令/data-out、响应码、事件与 Cancel 已共享；Socket/身份/TID 留平台层 |
| P04 | DONE | Nikon 属性、能力和对象信息解析 | DeviceInfo、属性描述/标量、ObjectInfo/文件名均以固定二进制样本共享 |
| P05 | DONE | 存储卡、对象元数据与双卡合并规则 | AUINT32、顺序、别名、去重、双卡归属及 Nikon 文件头元数据均已共享 |
| P06 | DONE | AP/STA 发现和配对状态规则 | IPv4 扫描策略、配对/档案/连接状态规则已共享；网络扫描与状态发布留在平台层 |
| P07 | DONE | 遥控、实时监看和录像协议状态 | Lab 码表、Live View 帧元数据解析和纯录像判定已共享；平台视频渲染/相机 IO 保留 Android |

### 4. 文件浏览与传输

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| T01 | DONE | 文件排序、筛选、日期分组和连拍识别 | 原文件模型直接实现只读共享边界；排序/筛选/日期/连拍规则及测试已共享 |
| T02 | DONE | 缩略图调度、优先级和缓存规则 | 通用队列、优先级、键材料、身份、过期与负缓存规则已共享；平台存储/解码/IO 保持原位 |
| T03 | DONE | 传输任务、队列和暂停/继续状态机 | 状态/进度、最小任务边界、FIFO/撤回和执行状态已共享；UI、Service 与 IO 保持原位 |
| T04 | DONE | 重试、错误分类、分块和断点规则 | 数值/响应/断点/失败处置纯决策已共享；异常、协议与文件 IO 留平台层 |
| T05 | DONE | 命名、同名文件、临时文件和完整性规则 | 原片副本/目录/临时名、索引、MIME 与长度规则已共享；SAF 文件操作保留 Android |

### 5. 遥控、GPS 与媒体规则

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| R01 | DONE | 曝光、ISO、快门、光圈等格式与档位 | 参数模型、显示语义、属性兼容、Auto ISO 与拨轮规则已共享；Android Locale 渲染保持原位 |
| R02 | DONE | 对焦、拍摄、录像与实时监看调度状态机 | 纯调度通过闭包共享；平台 IO、锁、时钟、渲染与 USB 原子序列留在端侧 |
| G01 | DONE | GPS 更新频率模型 | 原包名/API 不变，现有单测迁入 `commonTest` |
| G02 | DONE | GPS 公开状态模型 | `GpsStatus/GpsState` 已共享，Android 恢复策略独立验证 |
| G03 | DONE | GPS 恢复与海拔规则 | 公共规则已共享，常量保持模块内可见，原测试迁入 `commonTest` |
| G04 | DONE | GPS payload codec | 完整 41 字节向量固定；纯 Kotlin writer 与平台 UTC 适配已分离 |
| G05 | DONE | GPS 配对业务状态机 | 17B codec、熵映射、认证算法与四阶段决策共享；BLE/加密/随机数分平台 |
| E01 | DONE | EXIF、相框元数据和布局规则 | 模型、EXIF 归一、布局、文本、水印位置和元数据设置已共享；Bitmap/Canvas/ExifInterface/Geocoder 留平台层 |
| E02 | DONE | 滤镜参数、收藏和水印规则 | 参数/强度/50 个 NP3、收藏、水印偏好、像素内核和成片身份材料已共享；Bitmap/线程池/SHA-256 留平台层 |
| L01 | DONE | 免费版限制和会员权益判断 | 三项限制与额度判断共享；日账、验签和支付流程保留平台层 |

### 6. ViewModel 与共享 UI

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| V01 | DONE | 从 `CameraViewModel` 提取连接、扫描和浏览用例 | 发布/双卡归并、扫描句柄、EXIF 与预览身份规则共享；会话、锁、State/UI 留 Android |
| V02 | DONE | 从 `TransferViewModel` 提取队列和恢复用例 | 完整任务快照、入队、进度、撤回、清理与重试规则共享；AtomicLong、SAF、Service 生命周期留 Android |
| V03 | DONE | 建立共享 presentation state | Home 连接、列表信号/队列胶囊/删除身份及队列操作规则共享；Compose 与动画留 Android |
| U01 | TODO | 核心稳定后启用 Compose Multiplatform | 单独验证 Android Compose 依赖变化 |
| U02 | TODO | 主题、资源与通用组件 | 按组件迁移，不整页搬迁 |
| U03 | TODO | 首页、设置与授权状态 UI | Android/iOS 共用 Composable |
| U04 | TODO | 文件列表、预览与传输 UI | 保留性能基线 |
| U05 | TODO | 遥控、实时监看、相框与滤镜 UI | 最后迁移高风险页面 |

### 7. 平台实现与最终验收

| ID | 状态 | 任务 | 完成点 |
|---|---|---|---|
| A01 | DONE | 收口 Android 平台实现 | USB、Service、MediaStore、Socket、BLE、Bitmap、Locale/时钟/锁均只在 Android 层 |
| I01 | MAC | iOS 网络实现 | `NWConnection`、热点引导、AP/STA 发现 |
| I02 | MAC | iOS 文件与照片实现 | PhotoKit、Files、临时文件和恢复 |
| I03 | MAC | iOS 蓝牙、定位与后台实现 | CoreBluetooth、CoreLocation、后台宽限 |
| I04 | MAC | iOS 录像、购买和更新实现 | AVFoundation、StoreKit、App Store |
| Q01 | DONE | Android 迁移最终多轮回归 | 667 项测试、双模块 Lint、标准 APK、Manifest/DEX 与独立等价审计通过 |
| Q02 | MAC | iOS 模拟器和真机功能矩阵 | 权限、网络、传输、后台、异常恢复 |
| Q03a | DONE | Android/common 边界审计 | `commonMain/commonTest` 无平台 API，迁入模型/规则单一定义，依赖保持 `app -> shared` |
| Q03b | MAC | 双端代码边界审计 | iOS 实现完成后确认双端无重复业务规则 |

## Android 阶段结束条件

只有 `C/P/T/R/G/E/L/V/A` 中计划共享的任务全部完成，并且 `Q01`、`Q03a` 通过，才宣布 Android 共享化改造结束。平台专属代码保留不算未完成；`U/I/Q03b` 属于随后进行的 iOS 与共享 UI 阶段。

## S01 盘点结论

- 可直接迁移：公开纯 Kotlin 模型/规则，如 GPS 更新频率；公开 GPS 状态模型可在下一批拆出。
- 先拆再迁：PTP 常量与本地化、Live View 元数据与 Lab 常量、相机文件顶层模型、滤镜内核、相框领域模型、ViewModel 纯策略。
- 平台保留：Android USB/Service/MediaStore/Bitmap/BLE/定位、JVM Socket/文件流，以及 iOS 对应系统实现。
- 强约束：`internal` 不能跨 `app`/`shared`；不为“方便搬运”公开实现细节，先设计小而稳定的公共 API。
- 迁移顺序：公开纯模型 → 固定样本与协议 codec → 文件/队列状态机 → ViewModel 用例 → 共享 UI → 双端平台实现。

## S02 固定样本矩阵

| 范围 | 固定内容 | 主要证据 |
|---|---|---|
| PTP/PTP-IP | 包头、握手、命令、事件、响应、对象与属性二进制 | `shared` protocol `commonTest` |
| 文件浏览 | 多卡排序、筛选、日期分组、连拍识别 | `CameraFileRulesTest` 等 `commonTest` |
| 传输队列 | FIFO、撤回、暂停/继续、重试、断点和完整性 | `Transfer*Test` `commonTest` |
| GPS | 完整 41 字节 payload、频率、恢复与海拔规则 | `Gps*Test` `commonTest` |
| EXIF/相框 | 固定标签到完整元数据、DMS/rational 回退和布局规则 | `PhotoFrameExporterTest` |
| 滤镜 | NCP、NP3 curve、NP3 tonal 的完整 ARGB 输出 | `PhotoFilterRendererTest` |

## S03 平台能力边界

原则：共享层只接触业务语义，不接触 `Context`、`Uri`、Socket、GATT、系统任务或商店对象。只有共享用例已经成为真实调用方时才建立窄接口，不提前创建一套没人使用的总接口。

| 能力 | Android 当前归属 | iOS 对应实现/差异 | 共享边界与接口时机 |
|---|---|---|---|
| 相机网络 | `NikonCamera`、`PtpIpDiscovery`、`RemoteLab` 的 Network/Socket | `Network.framework` / `NWConnection`、热点引导和局域网权限 | PTP codec、扫描/连接决策已共享；到 `I01` 有真实调用方时再建窄 transport |
| USB | `UsbPtpConnection`、`UsbManager`、Bulk Endpoint | 普通 iOS App 无任意 USB Host PTP 等价能力，首版不提供 | 协议规则共享；不做虚假 iOS USB 实现，只由平台能力控制入口可见性 |
| 文件/照片 | `TransferViewModel` 的 SAF、`PhotoFrameExporter` 的 MediaStore/ContentResolver | PhotoKit、Files、安全作用域 URL，权限模型不同 | 命名、队列、断点、元数据规则共享；到 `I02` 建语义化 `PhotoStorage` |
| 蓝牙 | `NikonGpsBleClient` 的扫描、GATT 与 Android Classic bond | CoreBluetooth；系统配对行为和 Classic API 不同 | 配对包与握手决策在 `G05` 共享；transport 只暴露通知/写入等语义事件 |
| 定位 | `NikonGpsService`、LocationManager、Geocoder | CoreLocation / CLGeocoder | fix、频率、恢复、海拔和 payload 共享；provider 返回平台中立位置值 |
| 后台 | `CameraSessionService`、`TransferService`、`NikonGpsService`、通知/WakeLock | iOS background task/宽限，不能托管长期自定义 PTP TCP | 共享任务状态和可恢复检查点；生命周期与续跑能力由各平台编排 |
| 录像 | `ViewfinderRecorder` 的 MediaCodec/MediaMuxer/音频 | AVFoundation / VideoToolbox | 录像允许/回退/状态规则已共享；需要共享用例调用时再引入 recorder 接口 |
| 支付/会员 | `LicenseManager` 的外部支付、二维码、激活码与服务器恢复 | StoreKit 2 购买/恢复；不可直接复制 Android 购买入口 | 只共享权益、额度与商品语义；两端购买流程不强行抽成相同实现 |
| 更新 | `AppUpdateManager` 的 APK 下载、验包和安装 | App Store / TestFlight，不能自行安装 IPA | 更新执行完全平台化；需要共用 UI 时最多共享“有更新”等展示状态 |

执行约束：平台接口使用领域值和确定性结果；不返回平台异常或句柄；不为 USB、后台、支付、更新的客观差异伪造“1:1”实现；`expect/actual` 仅用于很小的值适配，长期对象优先显式注入。

## 验证记录

| 日期 | 任务 | 结果/证据 |
|---|---|---|
| 2026-09-04 | F02/C01 | shared 测试通过；Android APK 中 `CameraConnectionType` 仅一个定义 |
| 2026-09-04 | F03 | PBX 无悬空引用；Scheme XML、Blueprint、POSIX 脚本和 LF 属性静态检查通过 |
| 2026-09-04 | F04 | App/shared Lint、Debug 构建通过；APK 已在 Android 真机安装启动且无启动崩溃 |
| 2026-09-04 | F04 | `ZTransfer-debug-1.81-20260904-133704.apk`，SHA-256 `06573A4FB10506F022FA8AA4ADA974FB9C3F34F467E152F789836A83F8D06C48` |
| 2026-09-04 | S01/G01 | 盘点完成；GPS 频率源码逐行等价迁移，shared/GPS 测试及 App/shared Lint 通过 |
| 2026-09-04 | G01 | `ZTransfer-debug-1.81-20260904-135947.apk`；Manifest 不变，真机启动无崩溃，源码/APK 均为单一定义 |
| 2026-09-04 | G02 | `GpsStatus/GpsState` 逐行等价迁移；shared/Android GPS 测试和双模块 Lint 通过 |
| 2026-09-04 | G03 | 恢复/海拔逻辑仅调整跨模块可见性，测试输入输出不变并迁入 `commonTest` |
| 2026-09-04 | G02/G03 | `ZTransfer-debug-1.81-20260904-141505.apk`，SHA-256 `5CE2951E743A13D8C141345EC833F36ED88CD65CFB5E734E11B55B68E6BFC5EA`；Manifest 不变，真机启动无崩溃，共享类均为单一定义 |
| 2026-09-04 | G04 | 两组完整 41 字节向量先在旧 JVM encoder 通过，再由纯 Kotlin commonMain encoder 原样通过；Android UTC 适配测试通过，无新增依赖 |
| 2026-09-04 | G04 | App/shared Lint、Debug 打包及真机启动通过；`ZTransfer-debug-1.81-20260904-143655.apk`，SHA-256 `6D9519CAA95A12DE44B6B8B218CC5027BBA19BAD686373570F60E1AF69327203`；Manifest 不变，codec/时间模型均为单一定义 |
| 2026-09-04 | P01 | PTP/IP 包类型、关键操作/响应码、地址及完整格式映射先由旧实现固定，再迁入 `commonTest`；纯常量源码逐行一致，7 个 Android 翻译调用保持原样 |
| 2026-09-04 | P01 | shared 20 项测试、Android 协议相关测试、App/shared Lint 通过；`ZTransfer-debug-1.81-20260904-145323.apk`，SHA-256 `5EC71A3B15C8A52682E041EC19C42786C238BDA187C7FFF5F1A36B903CCD3832`；Manifest 不变，真机启动无崩溃 |
| 2026-09-04 | P02 | PONG、事件包头、高位小端数值和长度上下界固定向量迁入 `commonTest`；Android `PacketReader` 保留原流读取、缓冲复用、本地化异常及空 payload 行为，只复用共享包头 codec |
| 2026-09-04 | P02 | shared 测试、Android 远程事件/响应回归和 App/shared Lint 通过；`ZTransfer-debug-1.81-20260904-151547.apk`，SHA-256 `2E1DDE62EA5C72874084427520B70B5FFBC407F8B5400669229665DEC62AADCE`；Manifest 不变，真机 PID `24554` 且无启动崩溃，codec 在 APK 中仅一个定义 |
| 2026-09-04 | P03 | AP 44B/STA 48B Init、Ack、EventInit、普通命令、5 参数截断、空/非空 data-out 三段包、Cancel、响应码及事件边界均以独立 hex 向量固定；旧的异常输入、TID、USB、单次写入和 PING 行为保持不变 |
| 2026-09-04 | P03 | shared 测试、Android `protocol` 包全量测试和 App/shared Lint 通过；`ZTransfer-debug-1.81-20260904-154404.apk`，SHA-256 `E0C33A30EB9B3E186283DC132D2394D714E9328E64FC1ABDA7575A23F81E0D44`；Manifest 不变，真机 PID `28195` 且无启动崩溃，共享协议类均为单一定义 |
| 2026-09-04 | P04 | DeviceInfo/厂商能力/Nikon 事件、ObjectInfo/缓存身份/PTP 文件名、DevicePropDesc/标量全部迁入 shared；固定高位无符号、UTF-16/emoji/畸形代理项、逐字节截断、文件夹、保护位、未知大小、range/enum 与虚假 count 样本，Android nested `FileInfo` 和遥控策略保持原位 |
| 2026-09-04 | P04 | shared 测试、Android `protocol` 包全量测试和 App/shared Lint 通过；`ZTransfer-debug-1.81-20260904-162447.apk`，SHA-256 `C9A63A7410399A2D7C520EC633AC7B623D335F11EBC38113A7B32813D1734100`；Manifest 不变，共享解析类在 APK 中均为单一定义；本轮无已授权 ADB 设备，安装启动待设备恢复后补验 |
| 2026-09-04 | P05 | PTP AUINT32、StorageID/卡槽、handle 差量与顺序、STA 双卡归属、逻辑别名/成员集合、跨卡文件头比较、Nikon 0x9434/DCF/MakerNote/内嵌文件名已迁入 shared；`NikonCamera.FileInfo`、Socket/Mutex、会话快照、流式扫描和 StateFlow 留在 Android，未引入重复文件模型 |
| 2026-09-04 | P05 | shared 与 Android 全量单测、App/shared Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-171031.apk`，SHA-256 `28E0DA9AC6CFFD6BB7790847B0DFBC516DA260D8740AA481E10AB2851A2F50DF`；Manifest 与 P04 相同，共享类均为单一定义，真机 `3B65BV001L500000` 安装启动成功、PID `32068` 且未发现启动崩溃 |
| 2026-09-04 | P06 | IPv4 路由归属/扫描主机、STA initiator identity、配对门槛、responder 匹配、相机档案选择、AP/STA 状态枚举、偏好恢复、发现保活、会话激活和 3/8/15/30 秒重连退避已迁入 shared；Android NSD/网卡/Socket、SharedPreferences、Throwable 分类、StateFlow/Job/generation 和状态发布保持原位 |
| 2026-09-04 | P06 | shared 与 Android 全量单测、App/shared Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-174118.apk`，SHA-256 `9C50881D3568125EFFD78F49002DE3A70DBEE0F58298AAC930D87DDC8BB8D6F7`；Manifest 与 P05 相同，迁入类型均为单一 DEX 定义且旧包定义为 0；本轮无已授权 ADB 设备，安装启动待设备恢复后补验 |
| 2026-09-04 | P07 | Nikon `Lab` 操作/事件/响应/属性码表、Live View 包头与对焦/声音元数据解析、录像禁止条件和应用模式回退/重启判定已迁入 shared；Android Socket/USB/Mutex、命令时序、事件调度、Compose/Bitmap 及 MediaCodec/MediaMuxer 保持原位 |
| 2026-09-04 | P07 | shared 与 Android 全量单测、App/shared Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-180743.apk`，SHA-256 `B1D2BCC2057D07F5C20B5CE34F1519188DFA92E2336FD7B288D5D7C24EC2E7C4`；Manifest 与 P06 相同，9 个迁入类型/文件门面均为单一 DEX 定义，`commonMain/commonTest` 无 Android/JVM 平台导入；本轮无已授权 ADB 设备，安装启动待设备恢复后补验 |
| 2026-09-04 | T01 | 文件扩展名、PTP 日期日键/范围、多卡 head 选择、稳定新旧排序、宽松日期分组、六条件 AND 筛选、双卡选择状态和连拍识别已迁入 shared；Android 原 `NikonCamera.FileInfo` 仅实现最小只读接口，构造/copy/equality 不变，Compose/动画/导出索引/SharedPreferences/`java.time` UI 适配保持原位 |
| 2026-09-04 | T01 | shared 与 Android 全量单测、App/shared Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-183000.apk`，SHA-256 `E4C34ADFE343441BBD5D510E57168D8B1383CE26937C9EFF9F2B2260F7DEEF76`；Manifest 与 P07 相同，9 个共享类型/文件门面及 Android 原 `FileInfo` 均为单一 DEX 定义，`commonMain/commonTest` 无 Android/JVM 平台导入；本轮无已授权 ADB 设备，安装启动待设备恢复后补验 |
| 2026-09-04 | T02 | 原缩略图填充队列以泛型只读文件边界迁入 shared；日期优先级、重扫 revision、去重、失败重试和新文件插队保持原顺序。缓存键材料、STA 无符号 handle、机身身份归一化、90 天边界以及直连 STA 的负缓存/后台预取规则已共享；Android SHA-256、文件系统、Bitmap、协程和相机 IO 保持原位 |
| 2026-09-04 | T02 | 迁移前后固定哈希/目录名向量一致；shared 与 Android 全量单测、App/shared Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-184505.apk`，SHA-256 `675C68963CA7B9C758D7799182A9A970B4D5A7986029043D815CF4694346BDB3`；Manifest 与 T01 完全相同，两项新增共享类在 APK 中各只有一个定义，`commonMain/commonTest` 无 Android/JVM 平台导入；本轮无已授权 ADB 设备，安装启动待设备恢复后补验 |
| 2026-09-04 | T03 | `TransferStatus`、活动进度、最小任务只读边界、FIFO/预检查撤回队列、执行状态转换以及入队/暂停/速度/重试判定已迁入 shared；Android 原 `TransferTask` 直接实现接口，原队列保留 `synchronized` 薄壳，`TransferState` 只映射原执行标志；SAF、相机下载、协程 Job、效果生成和 `TransferService` 未改 |
| 2026-09-04 | T03 | shared 与 Android 全量单测、App/shared Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-185744.apk`，SHA-256 `35BF8D7901BDB5F620B15E8E404BD467320867F28F3E51308117CD57DADEF57E`；Manifest 与 T02 完全相同，5 个共享传输类型均为单一 DEX 定义，`commonMain/commonTest` 无 Android/JVM 平台导入；本轮无已授权 ADB 设备，安装启动待设备恢复后补验 |
| 2026-09-04 | T04 | 未知大小解析、PartialObject/全量路径、4/32/64 MiB 分块、128/512 MiB 阈值、安全回退、短读/总长完整性、匹配半成品的完成/续传/丢弃规划、速度、失败后半成品处置和平台中立错误展示类别已迁入 shared；Android 保留异常对象、PTP/USB/Socket、SAF、取消排空和本地化文案，重试任务完整快照由 Android 适配测试固定 |
| 2026-09-04 | T04 | shared 与 Android 全量单测、App/shared Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-191117.apk`，SHA-256 `C9D981428AB4C87A0D3B076048227CBAAB4030CBF1FB4A126A42FEEBFF45D31B`；Manifest 与 T03 完全相同，6 个共享下载策略类型/门面及 Android 原续传异常均为单一 DEX 定义，`commonMain/commonTest` 无 Android/JVM 平台导入；当前仍是进程内失败重试，未虚报跨进程队列/断点恢复；本轮无已授权 ADB 设备 |
| 2026-09-04 | T05 | 原片副本后缀/目录键、日期目录、自动任务身份、MIME、无平台文件索引、`.nkpart_` 身份与解析、1..99 重名候选及严格复制长度已迁入 shared；Android 保留同步锁、`ConcurrentHashMap`、`LocalDate` 时间来源、SAF/Uri、provider 实际名、rename/copy、取消和失败清理，相框渲染身份留待 E01/E02 |
| 2026-09-04 | T05 | JVM 旧正则与 `Locale.ROOT` 对照、year 0000、未知大小、旧 part 名和复制边界样本通过；shared 与 Android 全量单测、App/shared Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-192902.apk`，SHA-256 `3C4439DA91F072F1B5707E32E45FD59CA6B3BDC31DA472DEEC5597F128AF8A7C`；Manifest 与 T04 完全相同，5 个迁入/适配类型在 APK 中各一个定义，`commonMain/commonTest` 无 Android/JVM 平台导入；本轮无已授权 ADB 设备 |
| 2026-09-04 | R01 | `RcParam`、照片/录像曝光网格、DevicePropDesc 转换、属性别名与探测顺序、详细/紧凑显示语义、Auto ISO、拨轮方向/锚点/步进、电池及水平仪规则已迁入 shared；Android 继续负责默认 Locale 字符串渲染、相机命令/重试/协程及 Compose 状态，保留标准快门回退等现有边界行为 |
| 2026-09-04 | R01 | shared 与 Android 遥控定向测试、全量单测、App/shared Lint、标准 Debug 打包均通过；`ZTransfer-debug-1.81-20260904-195509.apk`，SHA-256 `6AF889A3E1C99918D14EAB9AA36ADB42A471504763F109F59F250CD22B030E04`；Manifest 与 T05 完全相同，共享策略/参数/展示类型均为单一 DEX 定义，`commonMain/commonTest` 无 Android/JVM 平台导入；真机 `3B65BV001L500000` 安装启动成功、PID `14875` |
| 2026-09-04 | R02 | 对焦模式/主体追踪/AF 轮询与点击对焦结果归约、Live View 启停/就绪/预热/取帧回退和错误恢复、拍摄确认顺序、录像事件/迟到回声/启动接管/停止收尾及诊断规则已迁入 shared；Android Socket/USB、锁、SystemClock、协程/Flow/Channel、Bitmap/触感/媒体和 USB 录像原子序列保持原位，未扩大为高耦合平台接口 |
| 2026-09-04 | R02 | 三路只读审查、shared/Android 定向及全量单测、App/shared Lint、标准 Debug 打包均通过；`ZTransfer-debug-1.81-20260904-203223.apk`，SHA-256 `EFDEB52988CBEFAA5D7BED7A4AC4912314AAB22AE5CB34978B24244F69A28741`；Manifest 与 R01 完全相同，12 个抽查共享类型/门面均为单一 DEX 定义，`commonMain/commonTest` 无 Android/JVM 平台导入；真机 `3B65BV001L500000` 安装启动成功、PID `31359`，最近日志无启动崩溃 |
| 2026-09-04 | C02 | `CameraFileInfo`、公开下载进度/统计、FHD 响应判定、遥控设置结果与 GPS 地名查询状态迁入 shared；字段顺序、默认值、扩展名派生、64 位计数及 `ByteArray` 引用语义保持不变；三个 Android 相机内部结果及 IO 异常继续保持 `internal`，没有为搬运扩大 iOS API |
| 2026-09-04 | C02 | 三路边界/测试复核、shared/Android 全量单测与 Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-210207.apk`，SHA-256 `8538E3A41FC046E221E4102ED4F4251FD71DEC85E0969D5D76A4F9D54287B6F6`；Manifest 与 R02 完全相同，7 个迁入类型均为单一 DEX 定义且旧嵌套文件/下载类型为 0；本轮无已授权 ADB 设备，安装启动待设备恢复后补验 |
| 2026-09-04 | C03 | 文件大小/速度/时长的二进制阈值、单位和分钟秒规则，坐标范围/精度/半球/标点，以及日期范围短标签迁入 shared；Android 原函数/API 保持不变并继续用 `Locale.US String.format` 与 `LocalDate` 处理舍入和日历适配，无新依赖、无 UI/状态/IO 改动 |
| 2026-09-04 | C03 | 迁移前后金样本、两路只读复核、shared/Android 全量单测与 Lint、标准 Debug 打包通过；覆盖阈值两侧、59.999 秒旧显示、`Long.MAX_VALUE`、Java 半入舍入、负零、坐标极值和闰年；`ZTransfer-debug-1.81-20260904-211608.apk`，SHA-256 `EBFCBBEC5F03C4B55A24E146B3D6263CCFDFF9C7BAE871954BDEC3A848C6D111`，Manifest 与 C02 完全相同；本轮无已授权 ADB 设备 |
| 2026-09-04 | C04 | commonTest 的 6 份 hex 解码与 3 份 Int 字节构造统一为两个 `internal` 固定样本工具；协议 hex 文本逐项比对完全一致，工具覆盖大小写、高位/空字节、非法输入和低 8 位转换；shared 全量测试通过，未新增生产 API、依赖、资源目录或平台/文件 IO，因此沿用 C03 Android 验收结果 |
| 2026-09-04 | S02 | 六类迁移 oracle 齐全；新增三组 NCP/NP3 完整 ARGB 金向量及固定 EXIF 标签到完整元数据样本，直接复用生产算法，没有复制公式或修改公开 API；两路只读复核均通过 |
| 2026-09-04 | S02 | shared/Android 全量单测与 Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-213525.apk`，SHA-256 `7ADA03F50161AF940873A628CFA6F0F0BE6263515EFB5E289E8EF30113384EC2`；Manifest 与 C03 完全相同；本轮无已授权 ADB 设备 |
| 2026-09-04 | S03 | 网络、USB、文件/照片、蓝牙、定位、后台、录像、支付/会员、更新九类能力逐项确认 Android 所有者、iOS 等价/限制和共享边界；不新增空壳接口、模块或依赖；将 Windows 可完成的 `Q03a` 与 iOS 完成后执行的 `Q03b` 分开，避免伪验收 |
| 2026-09-04 | G05 | Nikon GPS 17B 小端包、stage-1 熵映射、8 组 salt 的 stage-2/3 算法及四阶段握手决策迁入 shared；Android 原 facade 和 captured Blowfish 向量不变，真实 BLE 路径使用共享 decision；SecureRandom、Cipher、GATT、Classic bond、日志和超时均留 Android |
| 2026-09-04 | L01 | 免费版每日 25 个、单文件 400 MiB、监看 3 分钟及 quota/limit 判断迁入 shared；Android `LicenseManager` 保持原 API、Pro 短路和 SharedPreferences 日账读写，验签/设备身份/订单/二维码/更新未动 |
| 2026-09-04 | E02 第一批 | 滤镜模型、强度/tone curve、50 个 NP3 定义与目录迁入 shared；原转换 ID 预计算保持 SHA-256 身份，Android 只保留 `R.string` 映射；完整顺序、代表参数、曲线及原 ARGB renderer 金向量通过 |
| 2026-09-04 | G05/L01/E02 第一批 | shared/Android 全量单测与 Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-215225.apk`，SHA-256 `54EBA8A919A31B16D18B85A262B20293CDB6E6E82029D7430EF34C5F99E7EC15`；Manifest 与 S02 完全相同；本轮无已授权 ADB 设备 |
| 2026-09-04 | E01/E02 收藏 | 相框模型、13 种持久化预设、水印值与位置规则、全部布局族、品牌/元数据文本、设置 codec/fingerprint、EXIF APEX/DMS/rational 回退及滤镜/相框收藏迁入 shared；Android 仅保留 Locale/date、ExifInterface/Geocoder、Bitmap/Canvas、MediaStore/SAF 和文件 IO 适配，原 app 回归测试继续通过 |
| 2026-09-04 | E01/E02 收藏 | shared/Android 全量单测与 Lint、标准 Debug 打包通过；`ZTransfer-debug-1.81-20260904-221343.apk`，SHA-256 `1DEE83D781642E70ADF17FFD032C3F5A53D8FEB4A2284C9974D19FCA0E04A5AF`；APK 内 Manifest SHA-256 仍为 `1C7620E06744AFF427B45331EA741318EA5A2F6A0D970CE9B5DA616679044A80`；`commonMain/commonTest` 无 Android/JVM 导入；本轮无已授权 ADB 设备 |
| 2026-09-04 | E02 | 旧水印尺寸/透明度恢复、免费版权益水印、图片水印与边框位置约束、JPG/JPEG/PNG 派生门槛、成片 unhashed identity 迁入 shared；Android 继续负责 SHA-256 和本地路径。NCP/NP3 HSL、tone curve、色带、tonal controls 与中性色保护像素内核迁入 shared，Android 仍保留 Bitmap、ForkJoinPool、24-bit LUT、分条与取消编排 |
| 2026-09-04 | E02 | 三组完整 ARGB 金向量、透明像素、旧摘要/成片文件名及水印兼容样本在 shared/app 全量单测中通过；双模块 Lint 与标准 Debug 打包通过。`ZTransfer-debug-1.81-20260904-223436.apk`，SHA-256 `8AFE0FEBDCA01DB4D336BCF16F412F266561ADB5F5E70CA68BC4063195C1D061`；APK 内 Manifest SHA-256 仍为 `1C7620E06744AFF427B45331EA741318EA5A2F6A0D970CE9B5DA616679044A80`；本轮无已授权 ADB 设备 |
| 2026-09-04 | V01/V02/V03 | `CameraViewModel` 的发布/双卡归并、扫描句柄、EXIF/预览身份规则，`TransferViewModel` 的完整任务快照、入队/进度/撤回/清理/重试 reducer，以及 Home/文件列表/队列最小 presentation state 迁入 shared；Android 原调用点改用共享实现，平台会话、锁、StateFlow、AtomicLong、LocalDate、Compose、动画、Service 和 IO 保持原位 |
| 2026-09-04 | A01/Q03a | 两路独立只读审计逐项对照 `c06c1e6`，未发现语义、性能或线程变化；`app -> shared` 单向依赖，`commonMain/commonTest` 的 Android/JVM API 导入为 0；相册发布 typed identity 已收为单一定义，未改成存在分隔符碰撞可能的字符串身份 |
| 2026-09-04 | Q01 | shared 350 项 + app 317 项单测全部通过，双模块 Lint 各 0 issue，标准 Debug 打包成功；`ZTransfer-debug-1.81-20260904-231421.apk`，SHA-256 `C101D923527EB2B22D5E0C270CD895AFEF6E7B43553E7455081EF4D4F3CB7E0F`；APK 内 Manifest SHA-256 仍为 `1C7620E06744AFF427B45331EA741318EA5A2F6A0D970CE9B5DA616679044A80`，7 个抽查迁入模型均为单一 DEX 定义；本轮无已授权 ADB 设备，沿用本分支此前真机安装启动证据 |

## 更新约定

- 开始任务：把该项改成 `NEXT`，顶部“下一项”同步更新。
- 完成任务：改成 `DONE`，在验证记录追加一行。
- 需要 Mac：保持 `MAC`，Windows 能完成的准备工作写进完成点。
- 不记录零碎编辑，只记录可以独立验收的迁移批次。
