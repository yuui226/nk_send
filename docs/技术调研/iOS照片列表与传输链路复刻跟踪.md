# iOS「照片列表 → 预览 → 传输」核心链路复刻跟踪

> 本文是照片传输核心场景的专用执行文档。它不替代 [iOS 原生复刻总进度表](./iOS原生复刻进度表.md)，总表只保存任务编号和全局状态；本文件保存这一条链路的完整调用链、安卓事实、iOS 对照、差异、验证和关闭条件。

## 目标与执行边界

目标是把安卓已经验证过的照片链路在 iOS 上逐项复刻，用户可观察结果必须一致：

- 相机文件扫描、批次发布、日期/连拍分组、筛选和滚动；
- 缩略图缓存、预取、失败重试、磁盘清扫和前台/后台切换；
- 点击/长按入口、单张/连拍预览、原片/FHD/缩略图回退、EXIF 和直方图；
- 预览翻页、缩放、旋转、关闭、上滑入队和队列胶囊联动；
- 入队快照、目录恢复、已存在文件判断、半成品断点续传、整包/分块下载；
- 下载进度、速度、派生效果图、暂停/继续、重试、清空、断线恢复和错误文案；
- 不增加“取消当前下载”功能。安卓 `TransferViewModel.requestPauseAfterCurrent`（1873）让当前文件传完后再暂停；`withdrawPending/withdrawTask`（3150/3167）只撤下等待中的任务，正在传输的文件继续完成；`TransferScreen`（516–546）隐藏正在传输/生成任务的移除按钮。协议 Cancel 仅是 `transferTransaction` 捕获异常后的内部收尾，不能用于实现界面上的暂停、清空或撤下，也不能从协议能力推导页面切换会中断下载。
- 所有显隐条件、状态转换、手势门限、动画时序、持久化键和值和安卓资源文案。

本场景关闭前，不切换到设置、工作台、监看或 GPS。平台 API 可以不同，但不能借机增加安卓没有的业务分支、文本、按钮、缓存层或“更智能”的回退策略。安卓源码和测试是唯一行为依据；截图只用于几何核对。

## 进度口径

一个条目只有在以下条件全部满足后才能标记“已完成”：安卓依据已定位；iOS 正常路径已实现；边界、错误、取消、重试、恢复和持久化（适用时）已实现；动画/手势规则已对照；定向自动化或模拟器证据已记录。真机 USB/Wi‑Fi 回归统一留给总表任务 19、60、61，不得用“安装成功”替代代码闭环。

状态含义：

- **待审查**：尚未把安卓调用链追到最后一个出口，不假定 iOS 一致。
- **进行中**：已有代码或测试，但仍有明确差异。
- **已落地待验收**：本轮代码和定向测试完成，仍有用户可观察或平台回归证据未闭环。
- **已完成**：满足上述全部关闭条件，并在总表同步状态和证据。

## 安卓事实链（实现前必须逐段对照）

### 1. 扫描和发布

入口是 `CameraViewModel.loadFiles`，文件元数据由 `NikonCamera.streamMergedFileInfo`（STA 使用 `streamStaDirectMergedFileInfo`）按批次产生。每一批先发布到可见列表，再按安卓规定的批次节奏预取缩略图；扫描代次用于丢弃旧任务的迟到结果。刷新、回到前台、FHD/大图占用通道或相机断线时，按 `setFhdActive`、`onCameraTransportLost` 的规则暂停或取消，并用同一代次快照恢复，不能把旧扫描结果插回新列表。

日期分组和连拍合集在 `FileListScreen.groupFilesByDate`、`computeBurstGroups` 及其派生状态中完成。筛选必须基于未筛选的完整文件集；筛选条件改变只改变展示集合，不能改变扫描缓存、原片索引或连拍归属。点击合集封面先按安卓规则展开，预览和入队使用稳定的合集成员顺序。

### 2. 缩略图缓存与预取

入口是 `CameraViewModel.loadThumbnail`、`prefetchThumbnail`、`fetchThumbnailToDisk` 和 `fetchAndDecodeThumb`，磁盘规则在 `ThumbnailDiskCache`。需要逐项记录：

1. 内存命中、磁盘命中、相机请求的优先级；
2. 可见请求与后台预取的合并、接管和取消边界；
3. FHD、LargeThumb、标准缩略图和视频/RAW 的顺序；
4. 解码尺寸、近黑边裁切、负缓存、内存预算和磁盘写入阻断；
5. 90 天清扫、目录重建、扫描代次和重连后的重新排队。

可见缩略图不能因为后台预取已经失败而直接失败；安卓在可见请求重新取得优先权后会再次检查缓存并按需要接管请求。预取不能提前做工作台的滤镜/边框渲染，也不能把压缩字节缓存当作已解码位图使用。

### 3. 预览

入口为 `LocalPhotoPreviewPager`、`PhotoPreview` 及 `CameraViewModel.loadFhdPreview/loadExif`。预览打开时固定展示模型和原片来源快照，避免后台传输或筛选变化导致当前下标漂移。首帧顺序是本地原片可解码内容优先，其次使用已缓存缩略图，再按安卓延迟和通道所有权请求 FHD/高清原图；视频显示安卓占位信息，不擅自请求不支持的播放能力。

预览状态必须区分：首次加载、高清加载、回退、加载失败、直方图开启/关闭、连拍合集/成员、缩放、旋转、翻页和关闭。翻页不能触发重复 EXIF/直方图相机请求；已经显示的位图是直方图输入。长按对比、横向分页、纵向返回、缩放后拖动和上滑入队要有明确的手势优先级与中断恢复规则。

### 4. 入队和任务生命周期

`TransferViewModel.createQueueTasks` 创建入队快照，`PendingTransferQueue` 保存执行 FIFO；`processQueue` 执行，`retrySingleTask/retryFailed` 重试，`withdrawPending/withdrawTask/removeTask/removeCleared` 负责撤下和清理，`launchPhotoFrameExport` 负责派生图。安卓规则如下：

- 同一次批量操作按 handle 去重，不同批次产生独立任务 ID；
- 展示顺序与执行 FIFO 分离；重试保留卡片位置但新尝试排到 FIFO 尾部；
- 入队时冻结相机文件、目标目录、照片效果和组织日期设置；后续页面切换不改变当前任务；
- 任务仅存内存；原片索引 `ExportedOriginalIndex` 与任务卡片独立，清空队列不能抹掉已传标记；
- 已有原片按规范化文件名和大小匹配直接跳过下载；缺失原片才进入下载；
- 派生任务保护原片和正在/等待生成的任务，清空只能撤下可撤下项；
- 暂停只在当前文件完整结束后生效；重试不能绕过暂停；显式继续才恢复 FIFO；
- 断线后的后续任务不能使用旧会话，重试必须绑定新会话。

### 5. 下载、保存和派生

安卓下载实现集中在 `NikonCamera.downloadToFile`，策略函数是 `shouldUsePartialObjectDownload`、`downloadChunkSize`；页面吞吐快照来自 `MainActivity.shouldPreferHighThroughputTransfers`。执行顺序固定为：

1. 解析 `ObjectInfo` 大小；未知/0/`SIZE_UNKNOWN` 时按安卓规则尝试 `GetObjectSize`；
2. 根据连接类型、大小、续传偏移、设备能力和页面吞吐快照选择 `GetObject` 或 `GetPartialObjectEx`；
3. 分块路径每个完整 PTP 事务结束后才能让 FHD/EXIF 插入；按实收字节推进，声明长度不一致、零推进或最终总量不符立即失败；
4. 首个分块为零字节且响应为“不支持操作”时，记录能力并从零字节全量回退；忙、超时或已有字节后的失败不得擅自回退；
5. 新文件最多保留 256 KiB 头部供照片效果派生使用；续传不把旧文件内容伪装成新头部；
6. 下载完成后先尝试原名/后缀改名，再按安卓保存回退复制并校验字节数；复制失败保留半成品源，完整半成品改名失败按安卓规则清理后重下；
7. 原片保存成功后才启动派生 worker；派生读取同一份相机头快照，信息缺失时执行安卓对应失败分支，不用本地 EXIF 自行兜底；
8. 下载速度使用安卓的单调时钟和实际新增字节；跨零采样保留最后有效速度，完成时记录端到端平均速度。

数据相位异常时（包含写盘失败、协程取消和读超时），安卓 `NikonCamera.kt:3944–3978` 在持锁范围内完成收尾：IP 发送当前事务的 12 字节 Cancel，读到最终 `COMMAND_RESPONSE` 后保留会话；读取失败或累计排空超过 32 MiB 则关闭。`drainCmdResponse(maxBytes)` 计入非 PING/响应包的完整 payload，包括事务号和 START_DATA；3 秒是 `SO_TIMEOUT` 连续无数据超时，不能改成整个排空只准持续 3 秒。USB 分支直接关闭会话，不发送 PTP/IP Cancel。iOS 还需隔离 ImageCaptureCore 迟到回调。

### 6. 通道锁与让路边界

| 安卓入口 | 持锁/预约范围 | iOS 对照要求 |
|---|---|---|
| `getStorageIds/getObjectHandlesWithStatus/getThumbnail` | 普通 `ioMutex.withLock`，不登记交互优先级 | `CameraIOGate.withCommand`；缩略图不能被改成优先下载的交互请求 |
| `getFhdPicture/readExifHeader` | 先登记交互预约，再按 FIFO 取同一锁 | `withInteractive` 必须包含预约，不能只取锁 |
| `PhotoPreview.kt:911` 当前页 FHD → EXIF | 外层 `withInteractivePreviewPriority` 覆盖两项及中间解码；中间释放锁 | 只有下载下一分块让路；普通命令仍可按 FIFO 执行 |
| `downloadToFile/transferTransaction` | 整次下载登记；每个事务独立 `withTransferSlice`，异常收尾也持锁 | 取消排空结束前不能运行下一条命令 |
| `keepalive` | 下载活动锁外检查一次，拿到普通锁后再检查一次 | 跳过值为 true；单纯交互预约不阻断空闲命令 |
| `streamMergedFileInfo/streamStaDirectMergedFileInfo` | 按批次持普通锁，批内逐条检查取消，批外发布/预取 | iOS 当前逐对象持锁仍是确定差异；需按请求预算和头缓存成组修正 |

## 状态机和数据契约

以下是这条链路的最小状态边界。名称是语义名称，实际枚举必须与各端已有模型对照；新增状态前先确认安卓是否存在对应状态。

```text
扫描: idle → loading → publishing(batch) → ready
                       ↘ cancelled / failed → idle（保留上一份有效快照）

预览: closed → opening(anchor) → showing → loadingDetail → showing
                         ↘ failed/fallback                 ↘ closing(anchor) → closed

任务: absent → waiting → transferring → completed
                   ↘ withdrawn    ↘ failed → retry(waiting)
        completed + effects → generating → generated | failed
```

必须保持的契约：

- 扫描代次、预览快照代次、相机连接代次和任务 ID 是四个独立身份，不能用数组下标、文件名或“当前相机”互相替代；
- `CameraFile.handle` 只标识相机对象，续传半成品还必须同时校验安卓规定的文件身份令牌（大小和拍摄时间）；
- 入队任务保存创建时的文件、目录、效果和组织日期快照；执行期间页面切换、筛选变化和新相机连接不能改写这些字段；
- 原片索引、半成品索引、队列展示顺序和执行 FIFO 是四个独立集合；清理其中一个集合不得隐式清理另外三个；
- 每个下载回调只允许当前任务 ID 更新进度；取消、重试和会话替换后的迟到回调必须被丢弃；
- 派生图只能在原片已完整保存后启动，派生失败不能删除或标记原片失败；
- 任何“跳过下载”路径都必须先给出与安卓相同的原片存在判定，再发布完成状态，不能短暂发布 transferring 再回滚。

## 缓存、并发和清理不变量

这些不变量是审查代码和写测试时的硬检查项：

1. 同一 handle 的可见缩略图请求最多产生一次相机读取；后台预取不能阻塞可见请求，也不能覆盖可见请求的成功结果。
2. 预取只负责安卓规定的缩略图尺寸和格式；不得在预取阶段解码成工作台效果图、读取 EXIF 或触发 FHD。
3. 传输页/照片列表的吞吐策略在每个文件开始时冻结；文件进行中切换页面只影响下一文件。
4. PTP 通道在一个数据事务未收到最终响应前不可开始另一事务；分块之间的让路必须经过安卓同义的 IO 门控。
5. 半成品只在完整性确认后改成正式文件名；异常、取消、短读和声明长度冲突不能留下看似完整的正式文件。
6. 应用启动清扫只删除安卓定义的临时半成品；不能清扫正式原片、派生图或用户手动文件。
7. 清空队列只撤下可撤下任务；活动下载、等待派生和派生中的原片保护规则必须与安卓一致。
8. 所有内存、磁盘和任务订阅在取消、断线、页面离开和会话替换时释放；释放后迟到结果不能重新创建已取消的缓存项。

## 每组实现的固定记录模板

完成一组时，在本文“专用任务表”和总进度表同时追加以下五项，避免只写“已修”：

1. **关闭条目**：列出精确 ID；仍有一个异常/取消/动画分支就保持进行中。
2. **安卓证据**：文件、函数、资源名和相关测试；写明关键判断顺序。
3. **iOS 对照**：实际文件、入口、状态字段和平台适配点；不得只写同名接口。
4. **验证证据**：定向测试命令、通过数量、覆盖的正常/异常/取消/恢复分支；未运行项明确写出。
5. **剩余阻塞**：只写能够阻止关闭的具体差异和下一步，不用真机未插或“看起来不一致”代替代码结论。

## 专用任务表

编号与总表的 L/P/T/U 编号对应；本表按执行依赖排序。`下一步` 必须是可执行的代码或验证动作，不写泛泛的“继续完善”。

| ID | 子链路 | 安卓依据 | 当前 iOS 状态 | 关闭前必须补齐 | 下一步 |
|---|---|---|---|---|---|
| L01 | 扫描批次与代次 | `CameraViewModel.loadFiles`, `streamMergedFileInfo` | 进行中 | 批次发布、暂停、取消、迟到结果和会话替换回放 | 补扫描命令回放与代次断线用例 |
| L02 | 扫描取消/刷新/断线恢复 | `CameraViewModel.loadFiles/setFhdActive/onCameraTransportLost` | 进行中 | 代次、部分成功、迟到结果、快照恢复、宿主重连 | 与 L01 完整扫描协议回放一起核对 |
| P01 | 日期/连拍/筛选模型 | `FileListScreen.groupFilesByDate`, `computeBurstGroups` | 进行中 | 筛选完整数据源、合集成员顺序、展开状态和刷新恢复 | 对照 Android 派生测试逐项补证据 |
| L03 | 可见缩略图与后台预取仲裁 | `loadThumbnail`, `prefetchThumbnail` | 进行中（已补共乘计数/预取写盘完成点） | 分离 inflight 表、可见请求接管预取、取消/失败边界 | 重做 iOS flight/等待者模型并加竞态测试 |
| L04 | 缩略图解码与负缓存 | `fetchAndDecodeThumb` | 进行中（已恢复原始字节落盘、移除预取 transform） | 解码位图缓存、预算、负缓存、RAW/视频回退 | 先固定 Android 输入样本和内存计数口径 |
| L05 | 磁盘缓存清扫/阻断 | `ThumbnailDiskCache` | 进行中 | 90 天清扫、对账、写入阻断后的停止/唤醒 | 补调用方生命周期回放 |
| L06 | 新照片事件/双卡对账/自动入队 | `CameraViewModel` 新媒体流、`TransferViewModel.addFiles` | 进行中 | 扫描期间事件、相同逻辑照片合并、失败枚举、自动入队去重 | 将事件时间轴加入 L01/L02 回放 |
| P02 | 点击/长按/目录预检 | `FileListScreen` 文件格入口 | 待审查 | 普通文件、连拍封面/成员、长按触感和目录缺失 | UI 收口时按安卓列表操作设置逐分支迁移 |
| P03 | 预览快照与原片/FHD/EXIF 顺序 | `PhotoPreview.kt:911`, `loadFhdPreview` | 进行中（已补组合窗口，待完整验收） | 当前页 FHD→EXIF 同一个优先窗口；RAW/TIFF/视频和邻页预取边界 | 补组合窗口错误/取消/邻页预取回放，核对当前页所有权 |
| P04 | 预览手势/分页/缩放/旋转 | `LocalPhotoPreviewPager`, `ZoomablePreviewViewport` | 进行中（确定差异） | 锚点、分页、长按对比、纵向返回、取消恢复 | 建立预览状态机测试和手势参数表 |
| P05 | 预览入队飞行 | `previewQueueDragDirection`, `QueuePill` | 已落地待验收 | 方向门限、真实胶囊坐标、多片残影、接住弹簧、取消 | 与队列胶囊状态一起回放 |
| T01 | 入队快照/FIFO/暂停/重试 | `createQueueTasks`, `PendingTransferQueue`, `processQueue` | 已落地待验收 | 继续检查与协议门控不互相改变顺序 | 保留现有 13 项队列场景测试 |
| T02 | 目录索引/已有原片/半成品 | `ExistingFileNameIndex`, `ExportedOriginalIndex` | 已落地待验收 | 书签失效、重启清扫、命名冲突和半成品身份 | 补目录权限失败回放 |
| T03 | 下载命令策略/大小/续传 | `downloadToFile`, `shouldUsePartialObjectDownload` | 已落地待验收 | 所有设备能力和未知大小分支均有协议回放 | 保留 19 项 CameraDownloadTests |
| T04 | 流式写盘/声明长度/保存回退 | `writeChunk`, `DownloadStats` | 已落地待验收 | `renameBroken` 会话记忆、USB 数据相位等价物 | 先补保存策略状态测试 |
| T05 | 内部异常收尾/Cancel/排空 | `transferTransaction`, `abortActiveTransaction`, `drainCmdResponse` | 进行中 | 真实 PTP/IP socket 回放覆盖调用方协程被取消、写盘异常、PING/数据排空、持续进数超过 3 秒和无数据超时；GetObjectSize 超时也会 Cancel/排空后复用会话；USB 已接关闭；此处不代表用户有取消当前下载的功能 | 关闭重连与半成品组合回放；USB 实机迟到回调回归 |
| T06 | 普通锁/交互预约/下载活动/空闲命令 | `CameraIOGate`, 普通 `ioMutex` 调用方 | 进行中 | 普通目录/缩略图和优先 FHD/EXIF 已分开；`scanCatalog` 普通与 STA direct 元数据按安卓请求预算批量持锁；当前页 FHD/EXIF 已共用预约 | 补扫描取消/断线和组合窗口边界回放；核对邻页预取不穿透预约 |
| T07 | 头快照→元数据→派生 worker | `parseCameraFrameMetadata`, `launchPhotoFrameExport` | 已落地待验收 | 续传/重试/取消/重复任务的快照复用 | 补跨状态回放 |
| T08 | 速度保留/完成平均值 | `endToEndBytesPerSecond`, `retainLastValidTransferSpeed` | 进行中 | 已加入最后有效速度保留、文件完成平均 MB/s，以及队列胶囊对 retained speed 的展示；仍需和 U03/U04 的完成态动画联合回放 | 补完成态卡片/胶囊联合回放与异常边界 |
| U01 | 列表顶栏/筛选/滚动 | `FileListScreen` | 进行中 | 几何、显隐、文案和动画逐项测量 | 本场景逻辑闭环后再做 UI 收口 |
| U02 | 队列执行入口 | `QueueExecutionButton` | 进行中 | 开始/暂停材质、按压、提示、预览显隐 | 与 U03/U04 成组实现 |
| U03 | 队列胶囊/飞行联动 | `QueuePill` | 进行中 | 计数时机、Done 宽限、接住回弹和派生态 | 与 P05/T08 联合回放 |
| U04 | 队列卡片内容 | `TransferTaskCardContent` | 进行中 | 速度、错误/效果互斥、字号/行距/颜色 | 从 Android token 表逐项迁移 |
| U05 | 卡片收合/中断/恢复动画 | `TransferProgressMotion` | 进行中 | 0.78 缩放、spring 参数、60/150/80ms 交错及中断 | 做状态转换截图测试 |

## iOS 当前实现索引

| 能力 | 代码位置 | 说明 |
|---|---|---|
| 列表扫描/筛选/合集 | `ios/ZTransfer/Domain/PhotoListViewModel.swift`, `ios/ZTransfer/UI/PhotoListView.swift` | 已有代次、日期、连拍、筛选和可取消 reload；仍按 L01/P01 对照 |
| 缩略图 | `ios/ZTransfer/Domain/PhotoThumbnailStore.swift`, `PhotoThumbnailFillQueue.swift`, `PhotoThumbnailDiskCache.swift` | 已有内存/磁盘/队列；L03/L04 明确存在模型和解码差异 |
| PTP 会话与流式接收 | `ios/ZTransfer/Transport/PTP/PTPSession.swift`, `PTPIPCodec.swift`, `PTPIPSocketTransport.swift` | 已有数据相位、声明长度和 sink；T05/T06 尚未闭环 |
| 下载和保存 | `ios/ZTransfer/Domain/CameraRepository.swift`, `CameraDownload.swift`, `TransferDirectoryIndex.swift` | 已有整包/分块、续传、头快照、改名/复制校验；T04 仍缺运行期 renameBroken |
| 队列和派生 | `ios/ZTransfer/Domain/TransferQueue.swift`, `TransferQueueViewModel.swift` | 已有 FIFO、双 worker、暂停/重试/清空和元数据快照；T08/UI 仍有缺口 |
| 预览 | `ios/ZTransfer/UI/PhotoPreviewView.swift`, `PhotoListView.swift` | 已有分页、缩放、旋转和入队入口；P04/P05 待完整对照 |

## 验证矩阵

每个小组完成后只运行与本组相关的最小验证，避免频繁打包。记录命令、日期、通过数量和覆盖的安卓分支；没有执行的项目写“未运行”。

| 组 | 必须覆盖 | 当前证据 |
|---|---|---|
| 加载/缓存 | 批次、刷新取消、代次、可见/预取竞态、负缓存、清扫 | 现有模型/缓存测试；完整扫描回放未闭环 |
| 预览 | 原片/FHD/缩略图顺序、文件类型回退、快照、分页/缩放/长按/旋转 | 现有 iOS 预览代码；手势和文件类型回放未闭环 |
| 下载/保存 | GetObject/GetPartialObjectEx、未知大小、短读、零推进、Cancel、续传、改名/复制 | `CameraDownloadTests` 19 项；Cancel/排空和 USB 等价物未闭环 |
| 队列 | FIFO、暂停、重试、撤下、清空、断线替换、派生并发 | `TransferQueueScenarioTests` 13 项；速度完成统计未闭环 |
| UI/动画 | 胶囊摘要、卡片内容、飞行、收合/恢复、中断 | 尚未形成 Android 参数对照测试 |

历史证据：17:20 组合回归为 87 项（下载 19、模型 40、编码 6、会话 9、队列 13），随后独立协议包为 62 项。后续新增测试单独记入执行记录，不修改历史通过数量，也不把局部回归说成整组重新通过。

## 分组执行顺序

1. 先完成 T03/T04/T07 的剩余保存、快照和回退细节；
2. 成组实现 T05 Cancel/排空/取消恢复；
3. 成组实现 T06 `CameraIoGate` 交互优先级、下载活动和空闲命令；
4. 完成 T08 速度模型，再收口 U02/U03/U04/U05 与 P05 的状态展示；
5. 回到 L01–L05，闭合扫描和缓存；
6. 最后闭合 P03/P04、U01，并做整条链路的模拟器回归；
7. 代码闭环后才进入总表规定的真机和发布验证。

每次更新本文件只写：本次关闭的条目、安卓依据、iOS 文件、验证证据、剩余阻塞。若发现新差异，先登记到本表再实现，禁止跨场景随手修改。

## 执行记录（2026-09-14，T08 速度语义对账）

- **本次关闭的任务**：未关闭任务；T08 的速度模型缺口已补齐一部分，仍与队列展示动画联合验收。
- **安卓依据**：`NikonCamera.kt:281` 的 `endToEndBytesPerSecond`；`TransferViewModel.kt:488` 的 `retainLastValidTransferSpeed`；传输循环 `2272–2290`、完成写回 `2390–2401`；`FileListScreen.kt:2342` 的队列胶囊 retained speed；`TransferScreen.kt:817–823` 的完成态 MB/s。
- **iOS 改动**：`TransferQueue.swift` 增加同义速度计算/保留函数、活动进度的 retained 字段和任务完成平均 MB/s；传输开始、200ms 进度采样、完成写回分别沿安卓时机更新。`PhotoListView.swift` 与 `TransferQueueView.swift` 将队列胶囊绑定活动进度并显示 retained speed；等待中撤下接口继续保持仅作用于 WAITING 项。
- **验证证据**：`xcodebuild -project ios/ZTransfer.xcodeproj -scheme ZTransfer -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO -only-testing:ZTransferTests/DomainModelTests test`，41 项、0 失败；新增测试覆盖零字节/零时长、有效平均值和零采样保留。
- **剩余阻塞**：队列卡片完成态速度胶囊、暂停/派生/Done 交错动画尚未与安卓参数联合回放；T08 和 U03/U04 保持进行中。

## 执行记录（2026-09-14，T05/T06 再审计）

- **状态**：T05/T06 保持进行中。前一版门控把缩略图也当优先交互、让普通命令受预约阻挡；前一版取消测试仅覆盖 fake transport 和包解析，不能证明真实 socket 排空。已纠正实现及记录，未增加完成数。
- **安卓依据**：`NikonCamera.kt:194–248`、`1957/2062/2141/2191/2387` 的锁类型，`3944–3978` 的异常边界，`4655–4690` 的排空和 Cancel；`PhotoPreview.kt:911` 的 FHD→EXIF 优先窗口。
- **iOS 改动**：`CameraIOGate.withCommand` 对应普通 FIFO，`withInteractive` 同时登记预约；缩略图、目录和 STA direct 入口改走普通锁。`PTPSession` 对所有数据相位异常执行不受调用方取消影响的收尾；`PTPIPSocketTransport` 在读线程仍活跃时继续丢弃数据，写盘异常使读线程退出时由收尾接管，排空后保留原始错误并复用会话。预算计完整 payload，读活动重置 3 秒超时。USB 选择器接入现有有界 closeSession；缓冲适配器在 SDK 迟到返回后先检查取消，再调用写盘 sink。`CameraSession.previewAndExif` 将当前页远端 FHD 与 EXIF 放入同一交互预约，保持安卓 FHD→EXIF 顺序；不改变安卓“当前下载不可由用户取消”的队列语义。
- **扫描批次改动**：`CameraRepository.readCatalogMetadataBatch` 让普通 ObjectInfo 与 STA direct 元数据在同一次 `CameraIOGate.withCommand` 内按安卓请求预算读取；`scanCatalog` 将多余响应缓存在卡片分组中，锁外完成双卡日期归并、批次回调和快照提交。普通模式每批最多 12 个请求，STA direct 使用“卡数 + 发布批次 - 1”的预算及 1→3→12 首屏节奏。
- **协议验证**：本机 `ZTRANSFER_PROTOCOL_ONLY=1 swift test --package-path ios` 于 19:41 通过 73 项、0 失败；其中真实 `NWConnection` 命令/事件双 socket 回放覆盖取消后 PING/PONG、剩余数据排空、写盘异常保留原错误、排空超 3 秒仍保活、静默相机 3 秒后关闭、GetObjectSize 超时后复用会话，以及 DATA 包分片持续有字节时只按连续无数据计时。`PTPSessionTests` 覆盖迟到缓冲回调隔离。此前模拟器门控/下载/会话定向测试于 19:22 通过 38 项、0 失败；SDK 真实相机回调未由 loopback 回放替代。
- **验证**：本次批次重构后 Xcode Simulator 定向测试通过 67 项、0 失败（CameraDownload、CameraIOGate、DomainModel）；此前本机协议测试仍为 73 项、0 失败。Xcode Simulator app build 通过；均未替代真实相机 USB 回归。
- **剩余具体差异**：GetObjectSize 异常收尾与正常下载 60 秒连续无数据超时已补齐；关闭重连、半成品组合和真实 USB 回调仍需验证。预览当前页已改为 `CameraSession.previewAndExif` 在同一预约内按 FHD→EXIF 执行，仍需错误/取消/邻页边界回放。扫描普通与 STA direct 元数据已改为单批请求预算内持普通锁，仍需扫描取消/断线回放。先闭合这些同链路项，再进入速度/UI 与缩略图缓存分组。
