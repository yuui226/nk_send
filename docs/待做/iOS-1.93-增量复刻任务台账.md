# iOS：安卓 1.93 增量复刻任务台账

## 范围与完成口径

2026-10-07 用户要求：拉取安卓新功能合入 ios，先形成变动文档，深入阅读通用调度器专门文档，再按原规则逐项完整复刻。首轮已从 `origin/android` 拉取并将 `2b2bf0c2802cacc909e9373562d912bce2d21175` 合入 `ios`，合并提交 `5d583d60`。旧安卓基准 `617082c3`，合并前 iOS `27fba4bf`；增量 **62 个提交、79 个净变化文件**，安卓 versionName **1.93**、versionCode **66**。本轮追加同步已确认 `origin/android=8138e2dec22aa8c8b998a7a9a7b2fa0b9f3a1ec5`，相对 `5d583d60` 新增 `f40f6bbf`、`8138e2de` 两个提交，并以 `77fde8d9` 无冲突合入；详细核对见 [追加同步核对](iOS-1.93-追加同步核对.md)。本次同步与按类型存放复刻将在本轮用户明确要求后提交并推送。

新轮原始进度 **5/15**（N01–N05 已完成开发侧复刻，待用户真机验收）；追加诊断任务后按 **5/16** 播报。N06 已有实现代码但尚缺专项自动化与集中构建，因此状态改为“实现中”；N11 的按类型存放最终前缀修正尚未迁移。状态采用待调查→调查中→实现中→复刻完成，待用户真机验收；不能沿用上一轮 26/26 证明本轮完成。共享文件按差异块分别归属，任务之间允许先处理依赖，但不扩大单项边界或遗漏总范围。[来源索引](iOS-1.93-增量来源索引.json)保留首轮全部提交；追加提交与调度器核对见 [追加同步来源索引](iOS-1.93-追加同步来源索引.json)。

先读对应安卓提交、最终源码、上下游及测试，写明状态、文本、布局、动画、取消/错误/重试和保存范围，然后实施。迁移安卓测试，同时补足已识别但安卓未测的边界。每完成一大块才集中构建和必要自动化测试；真机测试与验收由用户负责。本轮功能实现不自动提交、推送或安装。

仍保留已批准的平台差异：StoreKit 权益、入队水印冻结、STA 会话内缩略图顺序加载和前台任务让路等。新日期加载范围约束可加载集合，集合内顺序规则仍保留；不能重新引入按格子出现/消失取消或重排 STA 请求。已排除的实验性全量能力扫描不能借新版诊断恢复；新版正式“完全控制”工具须按实际产品入口调查。

## 新功能与任务边界

| 编号 | 任务与必须覆盖的行为 | 主要安卓依据、测试 | 状态 |
|---|---|---|---|
| N01 | 统一调度核心：8 类请求、有效优先级/FIFO、不可抢占、评级计数屏障、预约、下载活动、取消、shutdown、嵌套拒绝及快照；不包含全部业务调用迁移 | NikonCamera.CameraIoGate；CameraIoGateTest；权威逻辑文档 | 复刻完成，待用户验收 |
| N02 | 调度生产接入：监看/AF/录像、FHD/EXIF、目录批次、缩略图、下载、事件/心跳/余量、关闭重连统一入口；PTP 排空/取消在释放前；整文件计时和照片/视频边界 | NikonCamera、RemoteLab、MonitorStorage、CameraViewModel、ThumbnailFillQueue；CameraIoGateTest、既有协议/下载测试 | 复刻完成，待用户验收 |
| N03 | 照片加载 1/3/5/全部拍摄日范围：持久化、旧尾部快照、扩大续扫、缩小隐藏、删除后重枚举、新事件、批次就绪信号 | PhotoDateRange、CameraViewModel、NikonCamera、TransferViewModel；安卓暂无专项范围测试，iOS 需补 | 复刻完成，待用户验收 |
| N04 | 评级协议：STA JPG/RAW 100 KiB+8 KiB≤256 KiB 连续探测、视频结构区、AP/USB 对象属性、能力短路、JPG/NEF 唯一配对及未知值 | PhotoRating、PhotoRatingPairs、VideoRating、NikonCamera；对应三个解析/配对测试 | 复刻完成，待用户验收 |
| N05 | 评级扫描生命周期：开关刷新代次、范围交集/锚点、来源快照、逐文件/区域 P3、进度、取消屏障、8192 值缓存和来源、重连隔离 | PhotoRatingScan、RatingDiagnostics、CameraViewModel；调度/评级测试 | 复刻完成，待用户验收 |
| N06 | 评级筛选 UI：开关、0–5 星条件、日期拨轮、等待/进度/完成、角标/帮助、触感、固定布局、独立 UI 状态避免重播网格 | FileListScreen、TransferViewModel、三语资源；相关方案仅用于解释最终代码 | 实现中，待专项测试/集中构建 |
| N07 | 实时多对焦框：帧头多框/坐标/颜色/显隐/有效期、照片录像差异、60 秒被动诊断/步骤标记及工具入口 | LiveViewMetadata、LiveViewFocusDiagnostic、RemoteScreen；帧头/诊断测试及专门方案 | 待调查 |
| N08 | 对焦模式与点按路径：AF/MF 固定状态、模式切换回读、坐标修正、单点/动态/宽区域路径、机型名称及不支持提示 | RemoteCameraTools、RemoteLab、RemoteCameraToolPanel；RemoteFocusModeTest、RemoteFocusTest、标签测试 | 待调查 |
| N09 | 监看完全控制、工具排列与启动/模式切换：持久化/独立模式、横竖稳定槽位、启动壳保留、提示和工具名称、旧诊断删除范围 | RemoteToolPreferences、RemoteToolBar、LandscapeMonitorControls、RemoteScreen；相关标签/交互测试 | 待调查 |
| N10 | 录像规格、剩余时长和 DISP：读取来源、解码、无效值/回退、排列/统一提示、被动及开发诊断入口 | MonitorMovieFormat、MonitorStorage、LiveViewVideoDiagnostic、RemoteDispOverlay；MonitorMovieFormatTest、MonitorRemainingTest | 待调查 |
| N11 | 存放方式与传输交互：统一/按天/按类、旧布尔迁移、目录/重名/已传识别/重试快照、效果图独立目录、队列飞行动画边界；追加同步必须使用 `ZT-` 大写类型目录和通用安全校验 | TransferViewModel、SettingsScreen、FileListScreen、TransferScreen、PhotoPreview；`NewMediaTransferPolicyTest` 最终前缀测试 | 复刻完成，待用户验收 |
| N12 | 照片 LUT 微调：对比/饱和/高光/阴影/浓度、精确颜色顺序、预览/原图统一、收藏/快照/持久化/旧值迁移、菜单动画 | LutColorPipeline、PhotoFilterPreset/Renderer、PhotoLutStore/EditorState/Editor；LutColorPipelineTest、PhotoFilterOutputTest | 待调查 |
| N13 | 底片胶片及旧胶片细节：新增模板、编号、品牌颜色/布局、宽度/背景支持、预览/导出/收藏身份、调试预览 | PhotoFrameExporter、PhotoFrameMetadataSettings、FrameBrandLogo、SettingsScreen；边框导出/元数据测试 | 待调查 |
| N14 | STA 配对真实性与短断线目录保留：当前连接相册验证、v2 标记/旧值迁移、失败回退、重连旧目录与新评级代次区分 | NikonCamera、StaCameraProfileStore、CameraViewModel；StaPairingStateTest | 待调查 |
| N15 | 全差异收口：逐 hunk 核销、跨模块接线、三语逐字、版本、诊断裁剪/平台排除依据、最终集中构建/回归和验收表 | MainActivity、三语资源、build.gradle、全部未归属差异与文档 | 待调查 |
| N16 | 诊断构建专用的传输损坏取证：R/T/F/L/C 五阶段、整文件与 4MiB 分段指纹、有界 Wi‑Fi/USB 协议追踪、续传前缀、取消/暂停与默认构建零副作用 | `TransferCorruptionDiagnostic`、`TransferFingerprint`、`DownloadTrace`、`NikonCamera`、`UsbPtpConnection`；`TransferFingerprintTest`（15 项） | 待调查 |

依赖：N01→N02；N02/N03/N04→N05→N06；N07–N10 使用 N02 的运行期事务；N11–N14 形成各自完整功能块；N16 先调查 iOS 传输字节和文件生命周期，再决定诊断钩子；最后 N15 审计所有源文件差异，不能只数测试通过。

## 调度器调查结论（N01/N02）

权威依据为 [全局任务调度器权威逻辑](../技术调研/全局任务调度器权威逻辑.md) 和当前 `NikonCamera.kt`，旧重构方案保留了过时的“缩略图与传输同级 FIFO”等描述，不按旧方案实现。

- P0 交互、P1 当前预览、P2 传输、P3 评级、P4 可见缩略图、P5 后台缩略图/目录、P6 空闲。后台事件基础值 0，但评级关闭时有效值 2；评级开启时阻塞。监看事件始终 P0。
- 有评级阶段时阻塞 P4/P5/P6/后台事件，即使两张评级间暂时没有 P3 排队也不能放行。阶段用计数处理重叠，结束/取消不能错误释放另一轮屏障。
- 兼容预览预约按基础优先级挡住大于 P1 的请求；后台事件基础值 0，因此仅由评级屏障及有效优先级决定。预约不持有协议通道。
- 完整下载活动跨分块；IDLE 准入被挡住。心跳还在提交前、入场后两次检查，返回 skippedValue；普通 IDLE（存储余量）等待下载结束。不可把这两种行为合并。
- 事务被选中之后保持所有权直至操作（含取消/排空）返回；取消已选中等待者和取消正在执行的操作必须区分，不能由取消回调提前释放协议通道。
- shutdown 拒绝新业务、取消等待者、保留活动事务；唯一关闭事务显式允许 shutdown 后入场。新连接新 gate。
- 嵌套事务必须立即拒绝，不能互相等待；本地缓存/解码不入队，无时间片、老化或新增公平机制。
- iOS 当前仅有 ordinary/transfer 的两类 gate；监看多处直接调用 PTPSession，其 FIFO 仅保护协议串行，不能证明业务优先级已经统一。N02 必须逐入口迁移，不能仅替换 gate 后宣称全局接入完成。
- iOS 旧测试“预约不阻止 idle”和“排队 idle 在下载活动中立刻跳过”依赖旧准入规则，需要按新的实际准入/入场后竞态分别迁移，不能为了绿测保留旧行为。

## 本次合并对旧范围的修正

新版 `00f78187` 起重新实现星级筛选，后续调度/评级修复均在最终树。上一轮 T26“星级已回滚、不迁移”仅对 1.91 有效，本轮明确纳入 N04–N06。老版能力提案、全量探测以及已删除的 RemoteDiagnosticReport 不因文档仍存在就自动成为产品功能。

## 验证记录

- 合并前工作区干净；远端获取成功；合并无冲突。
- `git diff --exit-code origin/android -- app` 和 `git diff --exit-code 27fba4bf HEAD -- ios` 均无差异。
- 合并初始整理时尚未构建或运行本轮测试；N01 实施后的集中验证见下节。N02 及其余任务仍未完成，不能以 N01 的通过结果代替整轮验收。

### 2026-10-07 N01 调度核心收尾

- iOS `CameraIOGate` 已改为 Android 1.93 对应的 `CameraRequestKind` 队列：P0 interactive、P1 preview、P2 transfer、P3 rating、P4 visible thumbnail、P5 background/catalog、P6 idle，以及评级阶段的后台 event poll 映射。
- 已迁移优先级选择、同级 FIFO、不可抢占事务、interactive reservation、rating phase 计数屏障、下载活动双重检查、等待/活动取消、嵌套调用保护、shutdown 闸门、快照和允许关闭事务。
- `CameraRepository`/`CameraSession` 已提供 scheduler snapshot 与 rating phase API，供后续 N02/N05 使用；连接丢失/移除路径在释放 session 前进入 scheduler shutdown。
- 新增 3 个调度器场景测试，连同旧 gate 回归共 **14/14** 通过：`/tmp/ztransfer-ios193-n02-gate-tests.log`（`** TEST SUCCEEDED **`）。生产工程构建通过：`/tmp/ztransfer-ios193-n02-wiring-build3.log`（`** BUILD SUCCEEDED **`）。
- 当前 N02 已完成 repository 全部运行期命令接入：AF、参数、监看、拍照/录像、FHD/EXIF、目录、缩略图可见/后台、下载分块、事件轮询、心跳和关闭前 shutdown 均经过统一 gate；连接握手/底层 transport CloseSession 保留为会话边界例外。PTPSession 原有取消/排空路径继续在传输事务内执行，未由 gate 提前释放。
- 既有 CameraDownloadTests 与 RemoteLifecycleTests 集中回归 **76/76** 通过，日志 `/tmp/ztransfer-ios193-n02-regression.log`（`** TEST SUCCEEDED **`）。N02 标记“复刻完成，待用户验收”。

### 2026-10-07 N03 照片加载范围收尾

- 安卓来源为 `eae2e836`（设置 1/3/5/全部范围、按实际拍摄日计数）和 `2bd59ede`（扫描越过边界后只接受最新范围、保留旧尾部快照）。调查确认范围不是简单日历过滤：无照片的日历日不计数；无效拍摄日期不形成边界；跨边界批次只发布范围内行，快照只标记已接受句柄，扩大范围继续原句柄快照；缩小范围立即隐藏行并停止范围外缩略图入队；范围扩大时旧快照失效则保留已显示目录并重枚举；新事件通过同一范围准入；全部范围保持原始批次/顺序。
- iOS 已在 `PhotoLoadingRange`、`newestCaptureDaysRange`、`PhotoFilterPersistence`、`CameraRepository`/`CameraSession`、`PhotoListViewModel`、`PhotoThumbnailFillQueue`、`PhotoListView`、`SettingsView`/`SettingsPopupOverlay` 中接线。范围选择器逐字使用安卓界面文案“照片加载范围”“全部”“1日”“3日”“5日”；展示网格使用范围内目录，传输及事件索引仍保留完整会话目录。
- 扩大范围沿用 repository 的 `PhotoScanSnapshot`，不重新请求已接受句柄；快照不存在时 `preserveExisting=true` 触发删除/新增可识别的重枚举。队列范围变化只清理未完成/失败项，保留已完成磁盘命中；范围外的新事件和缩略图不会进入工作队列。
- 新增自动化覆盖实际拍摄日计数与非法日期、持久化未知值归一化、队列缩小/扩大再准入，以及跨批次越界后尾部快照和扩大续扫：`/tmp/ztransfer-ios193-n03-final-tests.log`，**4/4 通过**。N03 相关回归（DomainModel、ScanBatchPolicy、PhotoThumbnailStore、CameraDownload、RemoteLifecycle）共 **213 项，3 项既有麦克风权限跳过，0 失败**：`/tmp/ztransfer-ios193-n03-regression.log`。生产工程构建通过：`/tmp/ztransfer-ios193-n03-build.log`（`** BUILD SUCCEEDED **`）。
- 当前 N03 标记“复刻完成，待用户验收”。评级开关/结果属于 N04–N06；范围变更对评级扫描的失效和重建将在评级生命周期任务中按安卓实现接入，不在 N03 提前添加空业务状态。

### 2026-10-07 N04 评级协议收尾

- 上一轮用户要求提交推送一次，阶段代码已由 `046423f5` 推送；本次 N04 收尾尚未提交或推送，等待后续明确提交节点。此前合并和 N01/N02 已随 `ee537a95` 推送，文档开头“尚未推送此次合并”为合并时的历史状态。
- 已对照安卓 `PhotoRating.kt`、`PhotoRatingPairs.kt`、`VideoRating.kt` 及对应测试，迁移 JPEG/Exif/XMP、TIFF/NEF、Nikon 对象属性值映射、JPG/RAW 唯一配对和视频 NCTG 结构定位。缺失或未知评级保留 nil，不转换为零星。
- 已接入 `CameraRepository`/`CameraSession` 的对象属性、RAW 头部回退、100 KiB 首读与 8 KiB 续读、Nikon/标准操作能力状态和视频窗口读取，均经过评级调度入口。`GetObjectPropValue(0x9803,0xDC8A)`、Nikon `GetPartialObjectEx(0x9431)`、标准 `GetPartialObject(0x101B)` 的参数及响应码均有脚本回放；`0x2005` 能力短路、`0x2019` 可重试的 DeviceBusy、RAW 扩展熔断、连续头部追加和视频窗口路径均覆盖。评级缓存/代次、扫描生命周期和界面仍属于后续 N05/N06，不在 N04 重复实现。
- 验证过程如实保留：首轮测试存在 Swift 6 并发/辅助函数编译问题；第二轮测试夹具将 65535 转成 Int16 导致溢出；协议接入曾出现 actor 隔离和抛错闭包编译错误，均已修复。最终 `/tmp/ztransfer-ios193-n04-protocol-tests3.log` 为 `** TEST SUCCEEDED **`，解析/配对 **14/14**，协议回放 **8/8**，共 **22/22**。集中回归 `/tmp/ztransfer-ios193-n04-regression.log` 为 **250 项、3 项既有麦克风权限跳过、0 失败**；生产构建 `/tmp/ztransfer-ios193-n04-build.log` 为 `** BUILD SUCCEEDED **`。尚未做真机验收，N04 标记“复刻完成，待用户验收”。

### 2026-10-07 N05 评级扫描生命周期收尾

- 对照安卓最终 `PhotoRatingScan.kt`、`NikonCamera` 评级缓存和 `CameraViewModel.loadFiles` 重新整理生命周期：评级开关关闭/再次打开各自创建新代次；STA 评级边界取评级日数与照片加载日数的非零交集，等待最新实际拍摄日的缩略图范围准备后再开始；开始读取后固定当前句柄快照，不因后续缩略图或目录更新重启；JPEG/RAW 唯一配对只读一个来源，但 `completed/total` 按可见评级文件计数；未知评级仍是已完成状态。
- iOS 新增 `PhotoRatingCache`，保存值和来源字符串，按插入顺序限制 8192 条；所有对象属性、照片头部、视频结构读和 EXIF 前缀被动读都在写入前检查代次，重连/新鲜目录扫描/显式关闭会清空并递增代次。`CameraSession` 暴露代次、缓存来源、失效和评级阶段接口，`PhotoListViewModel` 通过 `PhotoRatingScanController` 提供独立于网格重排的可观察扫描状态和取消入口。
- `PhotoRatingScanPolicy` 保留安卓的前八字符日期锚点语义（扫描边界不额外校验日历合法性），STA 未知日期不进入范围，AP/USB 使用对象属性并保留 RAW 头部回退，STA 使用照片头/视频结构读。每个文件读前检查取消，评级阶段在取消/异常后必定释放；旧任务的结果不能写入新代次。
- 新增 `PhotoRatingScanTests` 5 项：范围交集/零值回退、STA 边界等待、JPEG/RAW 单来源双进度、取消屏障、8192 FIFO 与代次拒写，均通过。日志 `/tmp/ztransfer-ios193-n05-scan-tests.log` 为 `** TEST SUCCEEDED **`（5/5）。评级解析、协议回放、评级生命周期与调度屏障集中回归 41 项首轮有 1 项既有并发排序断言偶发抖动，单独重跑通过；重跑日志 `/tmp/ztransfer-ios193-n05-cameragate-retry.log` 为 `** TEST SUCCEEDED **`，集中日志保留在 `/tmp/ztransfer-ios193-n05-rating-regression.log`。Release 模拟器生产构建通过，日志 `/tmp/ztransfer-ios193-n05-build-simulator.log` 为 `** BUILD SUCCEEDED **`；通用真机 Release 构建因本机未配置 development team 被 Xcode 拒绝，未改变代码编译结论。尚未做真机测试，本轮 N05 标记“复刻完成，待用户验收”。

### 2026-10-07 追加安卓同步核对

- `git fetch origin android` 成功，确认 `origin/android=8138e2de`；`git merge --no-edit origin/android` 生成 `77fde8d9`，无冲突。追加范围只有 `f40f6bbf`（诊断构建）和 `8138e2de`（按类目录前缀最终修正）；没有新增调度器行为。代理仍为 `http://127.0.0.1:7897`。
- 已阅读 [全局任务调度器权威逻辑](../技术调研/全局任务调度器权威逻辑.md)、安卓 `NikonCamera.CameraIoGate` 及当前 iOS N01/N02 接线；本次 `DownloadTrace` 只是诊断回调，不得被当作第二套调度器。
- 已逐文件调查 `TransferViewModel`、`NikonCamera`、`UsbPtpConnection`、`TransferCorruptionDiagnostic`、`TransferFingerprint`、`DownloadTrace` 以及两个安卓测试文件。新增功能路由为 N11 的 `ZT-` 类型目录最终语义和 N16 的诊断专用 R/T/F/L/C 取证；详细规则、排除边界和下一步见 [追加同步核对](iOS-1.93-追加同步核对.md)。
- 合并后已完成 iOS N11 按类型存放接线及专项回归；安卓诊断构建 N16 尚未迁移。N06 现有代码仍尚缺 N06 专项测试/集中构建证据。

### 2026-10-07 N11 按类型存放复刻收尾

- iOS 已将安卓最终 `TransferStorageMode` 三态接入设置、列表、预览、本地队列和目录索引：`UNIFIED` 保持根目录，`BY_DAY` 使用 `ZTyyyy-MM-dd`，`BY_TYPE` 使用 `ZT-` + 去空白大写扩展名；无扩展名使用 `ZT-UNKNOWN`。目录名遵守安卓同样的 `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` 校验，`ZTFrames` 不作为类型目录。
- 入队时锁定目标目录；旧 `organize_transfers_by_date` 布尔值只作为迁移/兼容投影，不会覆盖新三态值。已传识别、目录扫描、重试/批量/自动入队和预览原图查找共用目标目录解析，避免切换设置后改变已入队任务。
- 新增 `DomainModelTests` 覆盖类型前缀/未知扩展名、旧值迁移与三态持久化、排队目标目录快照和 `ZTFrames` 排除。相关回归共 **180/180** 通过，日志 `/tmp/ztransfer-ios193-n11-relevant-tests.log`；专项领域测试 **121/121** 通过，日志 `/tmp/ztransfer-ios193-n11-storage-tests3.log`。
- Release 模拟器生产构建通过，日志 `/tmp/ztransfer-ios193-n11-build-simulator.log`（`** BUILD SUCCEEDED **`）。尚未进行真机测试，N11 标记“复刻完成，待用户验收”。
