# iOS：安卓 1.93 增量复刻任务台账

## 范围与完成口径

2026-10-07 用户要求：拉取安卓新功能合入 ios，先形成变动文档，深入阅读通用调度器专门文档，再按原规则逐项完整复刻。已从 `origin/android` 拉取并将 `2b2bf0c2802cacc909e9373562d912bce2d21175` 合入 `ios`，合并提交 `5d583d60`。旧安卓基准 `617082c3`，合并前 iOS `27fba4bf`；增量 **62 个提交、79 个净变化文件**，安卓 versionName **1.93**、versionCode **66**。合并无冲突，`app/` 与远端基准一致，合并未改变 `ios/`。尚未推送此次合并。

新轮进度 **2/15**（N01–N02 已完成开发侧复刻，待用户真机验收）。状态采用待调查→调查中→实现中→复刻完成，待用户真机验收；不能沿用上一轮 26/26 证明本轮完成。共享文件按差异块分别归属，任务之间允许先处理依赖，但不扩大单项边界或遗漏总范围。[来源索引](iOS-1.93-增量来源索引.json)保留全部提交、文件、差异块位置及初始路由；路由不代表已经调查或迁移。

先读对应安卓提交、最终源码、上下游及测试，写明状态、文本、布局、动画、取消/错误/重试和保存范围，然后实施。迁移安卓测试，同时补足已识别但安卓未测的边界。每完成一大块才集中构建和必要自动化测试；真机测试与验收由用户负责。本轮功能实现不自动提交、推送或安装。

仍保留已批准的平台差异：StoreKit 权益、入队水印冻结、STA 会话内缩略图顺序加载和前台任务让路等。新日期加载范围约束可加载集合，集合内顺序规则仍保留；不能重新引入按格子出现/消失取消或重排 STA 请求。已排除的实验性全量能力扫描不能借新版诊断恢复；新版正式“完全控制”工具须按实际产品入口调查。

## 新功能与任务边界

| 编号 | 任务与必须覆盖的行为 | 主要安卓依据、测试 | 状态 |
|---|---|---|---|
| N01 | 统一调度核心：8 类请求、有效优先级/FIFO、不可抢占、评级计数屏障、预约、下载活动、取消、shutdown、嵌套拒绝及快照；不包含全部业务调用迁移 | NikonCamera.CameraIoGate；CameraIoGateTest；权威逻辑文档 | 复刻完成，待用户验收 |
| N02 | 调度生产接入：监看/AF/录像、FHD/EXIF、目录批次、缩略图、下载、事件/心跳/余量、关闭重连统一入口；PTP 排空/取消在释放前；整文件计时和照片/视频边界 | NikonCamera、RemoteLab、MonitorStorage、CameraViewModel、ThumbnailFillQueue；CameraIoGateTest、既有协议/下载测试 | 复刻完成，待用户验收 |
| N03 | 照片加载 1/3/5/全部拍摄日范围：持久化、旧尾部快照、扩大续扫、缩小隐藏、删除后重枚举、新事件、批次就绪信号 | PhotoDateRange、CameraViewModel、NikonCamera、TransferViewModel；安卓暂无专项范围测试，iOS 需补 | 待调查 |
| N04 | 评级协议：STA JPG/RAW 100 KiB+8 KiB≤256 KiB 连续探测、视频结构区、AP/USB 对象属性、能力短路、JPG/NEF 唯一配对及未知值 | PhotoRating、PhotoRatingPairs、VideoRating、NikonCamera；对应三个解析/配对测试 | 待调查 |
| N05 | 评级扫描生命周期：开关刷新代次、范围交集/锚点、来源快照、逐文件/区域 P3、进度、取消屏障、8192 值缓存和来源、重连隔离 | PhotoRatingScan、RatingDiagnostics、CameraViewModel；调度/评级测试 | 待调查 |
| N06 | 评级筛选 UI：开关、0–5 星条件、日期拨轮、等待/进度/完成、角标/帮助、触感、固定布局、独立 UI 状态避免重播网格 | FileListScreen、TransferViewModel、三语资源；相关方案仅用于解释最终代码 | 待调查 |
| N07 | 实时多对焦框：帧头多框/坐标/颜色/显隐/有效期、照片录像差异、60 秒被动诊断/步骤标记及工具入口 | LiveViewMetadata、LiveViewFocusDiagnostic、RemoteScreen；帧头/诊断测试及专门方案 | 待调查 |
| N08 | 对焦模式与点按路径：AF/MF 固定状态、模式切换回读、坐标修正、单点/动态/宽区域路径、机型名称及不支持提示 | RemoteCameraTools、RemoteLab、RemoteCameraToolPanel；RemoteFocusModeTest、RemoteFocusTest、标签测试 | 待调查 |
| N09 | 监看完全控制、工具排列与启动/模式切换：持久化/独立模式、横竖稳定槽位、启动壳保留、提示和工具名称、旧诊断删除范围 | RemoteToolPreferences、RemoteToolBar、LandscapeMonitorControls、RemoteScreen；相关标签/交互测试 | 待调查 |
| N10 | 录像规格、剩余时长和 DISP：读取来源、解码、无效值/回退、排列/统一提示、被动及开发诊断入口 | MonitorMovieFormat、MonitorStorage、LiveViewVideoDiagnostic、RemoteDispOverlay；MonitorMovieFormatTest、MonitorRemainingTest | 待调查 |
| N11 | 存放方式与传输交互：统一/按天/按类、旧布尔迁移、目录/重名/已传识别/重试快照、效果图独立目录、队列飞行动画边界 | TransferViewModel、SettingsScreen、FileListScreen、TransferScreen、PhotoPreview；相关原有传输测试 | 待调查 |
| N12 | 照片 LUT 微调：对比/饱和/高光/阴影/浓度、精确颜色顺序、预览/原图统一、收藏/快照/持久化/旧值迁移、菜单动画 | LutColorPipeline、PhotoFilterPreset/Renderer、PhotoLutStore/EditorState/Editor；LutColorPipelineTest、PhotoFilterOutputTest | 待调查 |
| N13 | 底片胶片及旧胶片细节：新增模板、编号、品牌颜色/布局、宽度/背景支持、预览/导出/收藏身份、调试预览 | PhotoFrameExporter、PhotoFrameMetadataSettings、FrameBrandLogo、SettingsScreen；边框导出/元数据测试 | 待调查 |
| N14 | STA 配对真实性与短断线目录保留：当前连接相册验证、v2 标记/旧值迁移、失败回退、重连旧目录与新评级代次区分 | NikonCamera、StaCameraProfileStore、CameraViewModel；StaPairingStateTest | 待调查 |
| N15 | 全差异收口：逐 hunk 核销、跨模块接线、三语逐字、版本、诊断裁剪/平台排除依据、最终集中构建/回归和验收表 | MainActivity、三语资源、build.gradle、全部未归属差异与文档 | 待调查 |

依赖：N01→N02；N02/N03/N04→N05→N06；N07–N10 使用 N02 的运行期事务；N11–N14 形成各自完整功能块；最后 N15 审计所有源文件差异，不能只数测试通过。

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
