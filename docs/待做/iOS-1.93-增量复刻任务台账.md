# iOS：安卓 1.93 增量复刻任务台账

2026-10-12 范围更新：已再次同步安卓 1.94，后续入口见 [1.94 增量台账](iOS-1.94-增量复刻任务台账.md)。用户明确忽略鸿蒙部分；最新最终源码将 N16 损坏诊断限定为 Harmony 设备，因此 N16 改为范围排除，不迁移、不计作已实现功能。下文历史 16 项计数保留为当时记录，其余未完成任务继续保留。

## 范围与完成口径

2026-10-07 用户要求：拉取安卓新功能合入 ios，先形成变动文档，深入阅读通用调度器专门文档，再按原规则逐项完整复刻。首轮已从 `origin/android` 拉取并将 `2b2bf0c2802cacc909e9373562d912bce2d21175` 合入 `ios`，合并提交 `5d583d60`。旧安卓基准 `617082c3`，合并前 iOS `27fba4bf`；增量 **62 个提交、79 个净变化文件**，安卓 versionName **1.93**、versionCode **66**。本轮追加同步已确认 `origin/android=8138e2dec22aa8c8b998a7a9a7b2fa0b9f3a1ec5`，相对 `5d583d60` 新增 `f40f6bbf`、`8138e2de` 两个提交，并以 `77fde8d9` 无冲突合入；详细核对见 [追加同步核对](iOS-1.93-追加同步核对.md)。本次同步与按类型存放复刻将在本轮用户明确要求后提交并推送。

当前有效范围记录进度为 **1/15**：N04 保留开发侧完成记录，待本轮全功能复核和用户真机验收；N01、N02、N03、N05、N06、N07、N08、N09、N10、N11 未完成，N12–N15 未完成。分母15已排除用户不迁移的N16鸿蒙功能。2026-10-15先因统一提示未迁移撤回N10，随后全功能C06复核确认N03仍缺删除后快照失效、扫描中范围更新、受限扫描缓存保留，故又从9/15改为8/15，详见[全功能复核F017–F020](iOS-全功能行为复核跟进.md)。C08进一步发现评级生命周期/顺序/诊断捕获及初始范围/帮助交互缺口，撤回N05/N06，8/15改为6/15，详见全功能复核F028–F033。C09又确认飞行来源身份冲突/同源去重遗漏（F039/F042），撤回N11，6/15改为5/15。C11再确认准入取消泄漏、IDLE屏障/监看接线、关闭绕过调度及评级任务所有权缺口（F052–F055），撤回N01/N02，5/15改为3/15。C23/F147又确认对焦模式菜单写前结束追踪后漏重验，撤回N08，3/15改为2/15。C24/F149–F151确认焦框过期/交接/绘制与缩放缺口，撤回N07，2/15改为1/15。历史9/15、8/15、6/15、5/15、3/15、2/15及其他计数只表示当时记录，不覆盖这次纠正；已有实现和真实测试结果保留，但不替代遗漏分支验证。状态采用待调查→调查中→实现中→复刻完成，待用户真机验收；不能沿用上一轮26/26证明本轮完成。共享文件按差异块分别归属，任务之间允许先处理依赖，但不扩大单项边界或遗漏总范围。[来源索引](iOS-1.93-增量来源索引.json)保留首轮全部提交；追加提交与调度器核对见[追加同步来源索引](iOS-1.93-追加同步来源索引.json)。

2026-10-08 再次执行 `git fetch origin android` 并核对 `android`、`origin/android`，两者均为 `8138e2de`，与当前 `ios` 相比没有新的安卓提交；`git merge --no-edit origin/android` 返回 Already up to date。现有安卓增量仍以 `d87ee9fa`、`6767d052`、`c6227c6d`、`c85c8b37`、`424c8514`、`2bfd98ef`、`8f56ac6e`、`ea73d559` 等最终树为基准。本轮继续从未完成任务 N09 开始，不把“没有新提交”误报成“所有安卓功能已迁移”。

先读对应安卓提交、最终源码、上下游及测试，写明状态、文本、布局、动画、取消/错误/重试和保存范围，然后实施。迁移安卓测试，同时补足已识别但安卓未测的边界。每完成一大块才集中构建和必要自动化测试；真机测试与验收由用户负责。本轮功能实现不自动提交、推送或安装。

仍保留已批准的平台差异：StoreKit 权益、入队水印冻结、STA 会话内缩略图顺序加载和前台任务让路等。新日期加载范围约束可加载集合，集合内顺序规则仍保留；不能重新引入按格子出现/消失取消或重排 STA 请求。已排除的实验性全量能力扫描不能借新版诊断恢复；新版正式“完全控制”工具须按实际产品入口调查。

## 新功能与任务边界

| 编号 | 任务与必须覆盖的行为 | 主要安卓依据、测试 | 状态 |
|---|---|---|---|
| N01 | 统一调度核心：8 类请求、有效优先级/FIFO、不可抢占、评级计数屏障、预约、下载活动、取消、shutdown、嵌套拒绝及快照；不包含全部业务调用迁移 | NikonCamera.CameraIoGate；CameraIoGateTest；权威逻辑文档 | 未完成：全功能复核F052/F053确认准入取消及IDLE屏障缺口，撤回完成状态 |
| N02 | 调度生产接入：监看/AF/录像、FHD/EXIF、目录批次、缩略图、下载、事件/心跳/余量、关闭重连统一入口；PTP 排空/取消在释放前；整文件计时和照片/视频边界 | NikonCamera、RemoteLab、MonitorStorage、CameraViewModel、ThumbnailFillQueue；CameraIoGateTest、既有协议/下载测试 | 未完成：全功能复核F053/F054确认存储监看及CloseSession生产接线缺口，撤回完成状态 |
| N03 | 照片加载 1/3/5/全部拍摄日范围：持久化、旧尾部快照、扩大续扫、缩小隐藏、删除后重枚举、新事件、批次就绪信号 | PhotoDateRange、CameraViewModel、NikonCamera、TransferViewModel；安卓暂无专项范围测试，iOS 需补 | 实现中：2026-10-15全功能复核F017/F018/F020确认缺口，撤回完成状态 |
| N04 | 评级协议：STA JPG/RAW 100 KiB+8 KiB≤256 KiB 连续探测、视频结构区、AP/USB 对象属性、能力短路、JPG/NEF 唯一配对及未知值 | PhotoRating、PhotoRatingPairs、VideoRating、NikonCamera；对应三个解析/配对测试 | 复刻完成，待用户验收 |
| N05 | 评级扫描生命周期：开关刷新代次、范围交集/锚点、来源快照、逐文件/区域 P3、进度、取消屏障、8192 值缓存和来源、重连隔离 | PhotoRatingScan、RatingDiagnostics、CameraViewModel；调度/评级测试 | 未完成：全功能复核F028–F030/F032，撤回完成状态 |
| N06 | 评级筛选 UI：开关、0–5 星条件、日期拨轮、等待/进度/完成、角标/帮助、触感、固定布局、独立 UI 状态避免重播网格 | FileListScreen、TransferViewModel、三语资源；相关方案仅用于解释最终代码 | 未完成：初始范围及帮助/动画缺口F031/F033，撤回完成状态 |
| N07 | 实时多对焦框：帧头多框/坐标/颜色/显隐/有效期、照片录像差异、60 秒被动诊断/步骤标记及工具入口 | LiveViewMetadata、LiveViewFocusDiagnostic、RemoteScreen；帧头/诊断测试及专门方案 | 未完成：C24/F149–F151焦框显示生命周期与动画缺口 |
| N08 | 对焦模式与点按路径：AF/MF 固定状态、模式切换回读、坐标修正、单点/动态/宽区域路径、机型名称及不支持提示 | RemoteCameraTools、RemoteLab、RemoteCameraToolPanel；RemoteFocusModeTest、RemoteFocusTest、标签测试 | 未完成：C23/F147写前异步门控缺口 |
| N09 | 监看完全控制、工具排列与启动/模式切换：持久化/独立模式、横竖稳定槽位、启动壳保留、提示和工具名称、旧诊断删除范围 | RemoteToolPreferences、RemoteToolBar、LandscapeMonitorControls、RemoteScreen；相关标签/交互测试 | 实现中 |
| N10 | 录像规格、剩余时长和 DISP：读取来源、解码、无效值/回退、排列/统一提示、被动及开发诊断入口 | MonitorMovieFormat、MonitorStorage、LiveViewVideoDiagnostic、RemoteDispOverlay；MonitorMovieFormatTest、MonitorRemainingTest | 实现中：统一提示生命周期、横竖锚点及淡入淡出已接线；离页失败通知及全范围收尾未完成 |
| N11 | 存放方式与传输交互：统一/按天/按类、旧布尔迁移、目录/重名/已传识别/重试快照、效果图独立目录、队列飞行动画边界；追加同步必须使用 `ZT-` 大写类型目录和通用安全校验 | TransferViewModel、SettingsScreen、FileListScreen、TransferScreen、PhotoPreview；`NewMediaTransferPolicyTest` 最终前缀测试 | 未完成：飞行来源和同源去重边界缺口，见全功能复核F039/F042；存放方式历史验证保留 |
| N12 | 照片 LUT 微调：对比/饱和/高光/阴影/浓度、精确颜色顺序、预览/原图统一、收藏/快照/持久化/旧值迁移、菜单动画 | LutColorPipeline、PhotoFilterPreset/Renderer、PhotoLutStore/EditorState/Editor；LutColorPipelineTest、PhotoFilterOutputTest | 未完成：全功能C18/F101确认微调模型/控件/后处理缺失，F098–F110另列基础LUT接线 |
| N13 | 底片胶片及旧胶片细节：新增模板、编号、品牌颜色/布局、宽度/背景支持、预览/导出/收藏身份、调试预览 | PhotoFrameExporter、PhotoFrameMetadataSettings、FrameBrandLogo、SettingsScreen；边框导出/元数据测试 | 待调查 |
| N14 | STA 配对真实性与短断线目录保留：当前连接相册验证、v2 标记/旧值迁移、失败回退、重连旧目录与新评级代次区分 | NikonCamera、StaCameraProfileStore、CameraViewModel；StaPairingStateTest | 待调查 |
| N15 | 全差异收口：逐 hunk 核销、跨模块接线、三语逐字、版本、诊断裁剪/平台排除依据、最终集中构建/回归和验收表 | MainActivity、三语资源、build.gradle、全部未归属差异与文档 | 待调查 |
| N16 | 诊断构建专用的传输损坏取证：R/T/F/L/C 五阶段、整文件与 4MiB 分段指纹、有界 Wi‑Fi/USB 协议追踪、续传前缀、取消/暂停与默认构建零副作用 | `TransferCorruptionDiagnostic`、`TransferFingerprint`、`DownloadTrace`、`NikonCamera`、`UsbPtpConnection`；`TransferFingerprintTest`（15 项） | 范围排除：1.94 最终仅鸿蒙启用，用户明确不迁移 |

依赖：N01→N02；N02/N03/N04→N05→N06；N07–N10 使用 N02 的运行期事务；N11–N14 形成各自完整功能块；N16 已排除；最后 N15 审计所有源文件差异，不能只数测试通过。

### 2026-10-08 N09 调查拆分与安卓行为核对

本轮 N09 先拆成四个可核销块，均以安卓最终源码和测试为准：

1. **完全控制工具**：`RemoteTool.COMPUTER_CONTROL` 是普通工具、默认进入照片和录像布局，文案为英文 `Computer control`、简体/繁体 `完全控制`，图标文字为 `PC`；切换期间禁用自身、拍摄、录像和录制忙态，停止当前 Live View，发送 `SetControlMode(1/0)`，成功后更新状态并重启监看；失败保留原状态并记录诊断，断线清空状态。进入页时从相机连接对象恢复“普通远控 + 诊断远控”双状态，离开/隐藏工具时成对清理。
2. **启动壳与模式切换**：初次参数尚未完成时仍显示监看页面壳和占位布局，不因 `initialLoaded` 或首帧为空整页透明；模式切换/录像兼容重启必须先排空旧 Live View，再启动新会话，必要时保留上一帧直到替代会话产生首帧，模式相关控件在状态准备前不误操作。
3. **工具排列与持久化**：照片/录像分别保存顺序、隐藏集合和 Lock 起始行；隐藏工具立即关闭对应功能并写入偏好，重复隐藏仍再次关闭；横屏即使隐藏本地录制也保留停止/暂停槽位，普通隐藏工具不占槽位；Lock 从第二行默认位被移动或隐藏后不自动重新挂回。工具标签须在横屏 Dock 中按实际宽度预测换行，不能由布局回调反复改尺寸。
4. **旧诊断边界**：安卓新版删除实验性全量探测/PC 控制旧调试流程，只保留正式完全控制入口和焦点相关报告；iOS 现有开发面板还保留旧 `RemoteLiveViewFocusDiagnostic`，因此需先核对 N07 已迁移的被动诊断与 N09 的删除范围，再决定删除/保留，不能仅以“没有命令”推断已完成。

当前 iOS 已有前三类中的大部分工具布局与模式交叉淡入，但缺少 `COMPUTER_CONTROL` 工具及其连接级状态；`CameraSession` 已有普通 USB 录像控制 API，尚未分离安卓的诊断控制持有状态。下一步先实现控制状态/生命周期和工具入口，再补持久化与布局测试，最后处理旧诊断范围。

2026-10-08 N09 完成第一块“完全控制工具”实现：新增 `RemoteTool.computerControl` 及三语文案/PC 标签，分别持久化并维护普通远控与诊断远控持有状态；切换前停止 Live View、写入 `SetControlMode(1/0)`，成功后恢复监看，失败保留状态；模型停止/断线成对释放，普通录像清理不会误释放诊断持有。新增 RemoteLifecycle 诊断持有测试及工具布局/偏好回归；单项日志 `/tmp/ztransfer-ios193-n09-diagnostic.log` 为 `** TEST SUCCEEDED **`（1/1），布局/偏好此前 8 项通过。N09 仍调查中：启动壳、模式切换、完整工具排列持久化和旧诊断边界尚未闭环。

同日补齐完全控制按钮的忙态禁用与视觉反馈：写入期间禁用自身、拍摄/录像忙态或相机工具写入期间禁止重复进入；Debug 模拟器生产构建 `/tmp/ztransfer-ios193-n09-build.log` 为 `** BUILD SUCCEEDED **`。这只证明当前源码可构建，不改变 N09 尚未完成的状态。

旧诊断边界核对完成：iOS 当前 `RemoteLiveViewFocusDiagnostic` 只消费已取得的 Live View 帧和已解码元数据，按 200ms 采样、最多 60 秒、变化/标记摘要输出，不发送探测命令、不写临时属性；开发面板仅提供隐藏入口、被动报告、复制和标记。因此按安卓新版“删除实验性全量能力探测、保留焦点相关报告”的边界保留，不再删除该能力。N09 仍缺启动壳、模式切换和完整排列持久化闭环。

模式切换记录已由后续源码核对纠正：实体拨杆变化不无条件重启 Live View；录像兼容重启只在显式录像事务中执行，当前仍待跨模式回放覆盖。

工具排列持久化补测：新增完全控制工具在照片/录像两套布局中的独立显隐和恢复用例，验证隐藏照片工具不会影响录像布局。`/tmp/ztransfer-ios193-n09-layout.log` 为 `** TEST SUCCEEDED **`（6/6）。

跨模式/USB 录像回归尝试记录：`/tmp/ztransfer-ios193-n09-mode-tests.log` 中入口模式测试通过，但既有 USB 录像生命周期用例出现等待超时及 `app:off`/`control:off` 顺序断言失败（非编译错误），因此不能把模式切换块标为完成；需继续定位会话清理竞态并补专门模式回放覆盖。

### 2026-10-15 N09 当前实现与剩余边界

- 继续以当前合并的 Android 1.94 `89d78b45` 最终树为准，保留工作区既有 N10、裁切、效果及 STA 改动。本次没有重新改变安卓基准、提交或推送。
- 完全控制：基础 `SetControlMode(false)` 成功时才成对清除普通/手动持有；失败保留状态。USB 已有手动控制时开录不刷新会话、不误清持有者；停录保留手动控制；退出等待迟到命令记账，先清应用模式，再按安卓最多三次/300ms 间隔归还控制。按钮忙态、重复点击、首帧前隐藏释放、失败恢复画面、迟到成功与三次释放已有生命周期/wire 测试。诊断面板记录成功、拒绝响应和异常。
- 物理拨杆：更换照片/录像参数组与对焦回读，不为模式变化无条件重启 Live View；照片模式按安卓请求清 ApplicationMode，USB 持有者仍由底层门控保护。专门回放同时覆盖模式独立缓存、照片清理、USB 手动持有不被拆开。录制中禁止拨杆轮询的规则保持不变。
- 竖屏：普通工具/编辑槽固定 36pt，只有录制胶囊可展开；常态位置变化和退出编辑继续使用 `stiffness=520 / dampingRatio=0.88 / Offset threshold=0.5px` 的共同二维弹簧，只有拖动项直接跟手；首次布局没有飞入。固定末尾仅保留安卓最终 ROTATE，移除旧全屏入口和竖屏 DISP。
- 横屏：`RemoteLandscapeLayout` 逐式迁移安卓 Float 空间选择，比较侧边和底部能保留的图像面积，保持 8pt 图像/控制间隔、116pt 最小侧栏、1/2 列参数、46/42pt 参数高度、快门尺寸/抬升和固定 DISP/旋转/本地录制区。Dock 按持久化可见顺序显示非录制工具；英文整词/CJK 换行预测、行内统一 1–2 行、10/12pt 标签、滚动边缘渐隐。单一有符号 `280ms FastOutSlowIn` 进度经过零才替换内容，反向从当前帧继续，出场层立即阻断操作；画幅/窗口改变会关闭旧锚点菜单。
- 横屏截图核对发现旧免费余量牌仍在未旋转的根视图上，遮住返回按钮；已按安卓 `RemoteTrialTimeBadge` 改为横屏画布右下角 6/4pt、无底板紧凑倒计时，竖屏仅显示倒计时、不再使用未被安卓调用的 `remote_trial_left` 前缀。标签和图标复用同一动作，弹窗锚点保持在 36pt 图标上。
- 已确认测试：核心回归 `/tmp/ztransfer-20261015-n09-regression.log` **127 项/3 跳过/0 失败**；布局/槽位 `/tmp/ztransfer-20261015-n09-layout-tests2.log` **22/22**；集中回归 `/tmp/ztransfer-20261015-n09-final-regression.log` **145 项领域/协议（3 麦克风跳过）+2 项 UI，0 失败，TEST SUCCEEDED**。UI 实际覆盖无相机首帧页面的旋转/Dock/参考线菜单/返回、竖屏隐藏/恢复/拖拽，截图保存在对应 xcresult。后续 USB/Wi-Fi 清理与标签点击补丁有单独验证记录，不能用此旧二进制结果替代。
- 失败记录：首轮布局编译发生 Swift 初始化期间捕获 `self.lines`，已修；首轮 UI 测试试图点击被浮层遮挡的返回按钮，改为从菜单实际选项关闭并等待退场；首轮模式用例错误要求录制期间读拨杆，已按安卓忙态门控纠正。失败日志均保留，不改写成初次即成功。
- 后续收尾补丁：USB 普通录像退出连续三次拒绝后保持 Live View 停止，在 600ms 恢复轮询中再按三次/300ms 有界重试，只有确认释放后恢复画面；手动完全控制不走自动释放。Wi‑Fi 完成/中断只清 ApplicationMode，不无故重启 Live View，也不清手动控制持有。对应新增两项生命周期测试，并回归既有 USB 开停、迟到开录退出、手动持有和 Wi‑Fi 兼容恢复。首轮新增 USB 测试漏等会话 ready、旧 Wi‑Fi 断言仍要求 force=true 均已按实际安卓契约纠正；标签测试暴露可访问点击目标与图标锚点应分离，现已使用可单独点击的标签与图标内部锚点。
- 最新补丁验证 `/tmp/ztransfer-20261015-n09-standby-regression2.log` 为 **6 项生命周期 + 2 项生产 UI，共 8/8，TEST SUCCEEDED**。UI 还断言倒计时不会覆盖返回按钮、文案仅为 `m:ss`，实际点击 GRID 的标签打开菜单。截图位于 `Test-ZTransfer-Interactions-2026.10.15_14-16-54-+0800.xcresult`，已查看；真机验收未运行。
- **N09 尚未完成**：参数卡及全值表已在下述独立块继续复刻；快门/胶囊已在下述独立块继续复刻，气泡投影及计时实景收尾仍未完成。不能用布局、参数控件或可操作截图证明剩余控件已复刻。

### 2026-10-15 N09 参数卡与全值表

- 行为依据已重新完整读取：`RemoteScreen.kt` 的 `paramMetric`、`paramAnchorIdx`、`stepParam`、`sendValue`、`ParamTile` 与横竖入口；`RemoteLab.rcFormat/fmtVal`；`ControlTileFieldLabel`、`ControlTileCornerBadge`、`WheelDragHint`；`RemoteParameterPanel`、`RemoteChoicePopup` 和 `GeniePopupLayer`。安卓 `ReleaseCommitWheelTest` 的“大于三项”规则在 ParamTile 只控制提示箭头，不能误搬成短值域禁止拖动或松手才写入。
- `RemoteParameterWheel` 与生产 `RemoteExposureTile` 接线：18pt/档、按物理量确定方向/最近锚点，当前值不在枚举时仍显示真实数值；原始越界最多 ±1.5 档、显示阻尼 0.3/最多 0.45 档，反拖立即响应；值域收窄不发巨幅补差，读写/方向/AUTO 能力变化取消旧手势。模型以最新值加档位差并复用 160ms 尾值合并，避免把手指位置当成相机当前值。释放/取消重新对齐回读，差距大于 2.5 档直跳，否则 180ms FastOutSlowIn；回读在动画开始前恢复旧值也会停止旧动画。
- 五行数值、150ms 邻行淡显、逐行位移/透明度/缩放、900ms 反向加载脉动均由现有安卓方程驱动。14pt 圆角、玻璃渐变与内描边、10pt 字段标签、14/16pt 等宽数值及 16/20pt 行高、只读锁/明暗和拖动箭头按安卓最终参数实现。动画仅更新参数卡绘制子视图；最近档位及方向随描述更新缓存，避免每帧重复扫描值域。
- AUTO 视觉宽度按卡宽 32% 限制在 32–44pt、高度 17–22pt、字体 7–9pt；右上透明触区固定 44×30pt。整个卡片共用竖向输入，达到 8pt slop 仅消费超出量；角标起手拖动调整 ISO 并取消开关点击，忙态拒绝轻点，AUTO 开启后禁止手动 ISO 拨轮。当前手指抬起会交给仍按下的手指，保留累计 slop、排除两指之间的位移；规则已对照官方 Maven `foundation-1.7.6-sources.jar` 中 `DragGestureDetector.kt` 的 `TouchSlopDetector` 与 `awaitDragOrUp`。实际 UI 测试覆盖角标拖动到 800、未误触 AUTO、切换有效 ISO 640、横屏后继续切换。
- 移除旧 `ExposureValueList` 底部 Sheet，接入无标题锚定值表：15pt 等宽、选中半粗蓝字和矩形高亮、14/8pt 行内边距，按文本测量宽度并限制 64–220pt，初始滚动到当前值前三项；选值立即写入并执行关闭动画。竖屏贴卡片下方；横屏优先放左侧、空间不足放右侧、使用整个本地旋转画布高度。横向并列时按安卓 `validGenieAnchor` 走进度淡入，保留 320/350ms 公共开关时钟。共享 Genie 的既有 T24 遗留没有因此宣布完成。
- 构建/自动化证据：`/tmp/ztransfer-20261015-n09-parameter-wheel.log` **16 项单元/生命周期 + 1 项 UI，17/17**；`/tmp/ztransfer-20261015-n09-parameter-panel.log` **20 项单元/生命周期 + 3 项 UI，23/23**；补充动画取消及 64 项长值表初始定位 `/tmp/ztransfer-20261015-n09-parameter-final.log` **16 项单元 + 1 项 UI，17/17**。全部 `TEST SUCCEEDED`，包含 App 的 Debug 模拟器构建。
- 视觉检查纠正：首轮值表的选中背景受系统按钮形状影响变成圆角，已改显式矩形；`/tmp/ztransfer-20261015-n09-parameter-highlight.log` **1/1 UI、TEST SUCCEEDED**。已查看横竖值表、AUTO/只读卡片、长列表初始 1700/当前 2000 的真实页面截图；最终矩形高亮截图在 `Test-ZTransfer-Interactions-2026.10.15_14-39-03-+0800.xcresult`。未进行真机验收，未提交或推送。参数卡/值表开发侧块已接通，N09 仍未完成，总进度保持 **9/15**。
- 后续边界核对：描绘端按描述中的实际属性求锚点；`stepParam` 接收的是逻辑属性，iOS 同样先 canonical 再计算步进起点，写入仍使用实际属性。标准快门 `0x500D` 回退且当前值不在枚举时，保留安卓逻辑 `0xD100` 的起点规则，没有擅自改成不同算法。首轮新增回退测试漏把 mock 的优先 `nikonShutter` 标为不支持，故未进入回退路径并失败（`parameter-logical-key.log`）；已纠正测试前置条件，失败记录保留。锚点缓存 14/14（`parameter-cache.log`）、双指交接及生产 AUTO UI 16/16（`parameter-input-final.log`）已通过；最终阈值与逻辑属性联合回归 `/tmp/ztransfer-20261015-n09-parameter-complete.log` 为 **15 项参数输入/动画 + 2 项生命周期 + 1 项生产 UI，18/18，TEST SUCCEEDED**。本块全部测试进程已结束，`git diff --check` 通过。

### 2026-10-15 N09 快门与端侧录制胶囊

- 本块依据：完整读取 `RemoteScreen.ShutterButton/startFocus/endFocus/finishShutterGesture/shoot/toggleRecord`、横竖屏调用、`RecControlBar.kt`、`Haptics.kt`、`ProgressiveHoldTimingsTest.kt`；延用已验证的 Compose 1.7.6 标量动画方程。没有更新安卓基准、提交或推送。
- 快门改为独立 `RemoteShutterButton`：300ms 长按、未满时快拍、滑出/取消/离页释放；对焦缩放由模型实际半按状态驱动，拒绝半按不伪造对焦外观。按压 100ms/释放 spring400/0.5、焦点 120ms、圆到停止方块 160ms，76pt 比例的大小/圆角与 3pt 边框；拍摄中复用 Material3 精确转圈路径。首次横屏按实际直径初始化，没有从 76pt 意外变形。
- 模型取消“必须先获得 Live View 首帧”的快门限制，已启动会话可半按/拍摄；录像中允许半按再松手停止。长按松手捕获当时 AF 或点按 AF 任务，先等协议终态再发送快门/录像并启动拍摄确认窗口。滑出只清半按视觉，不取消已发 AF；退出仍排空 AF 并阻止迟到拍摄。确认标记使用发起时的焦点快照。
- 触感迁移安卓按累计边界缩放的 300ms 渐强波形，保留末尾留白；长按确认回调期间跨实例屏蔽同步 tick/longPress，后续异步合焦 tick 不被屏蔽。测试覆盖 300/400/500/800/1000/1500ms、禁用时取消及嵌套回调。
- 胶囊已替换旧系统动画/符号图标：36/70/88pt 宽度弹簧；暂停 150ms 淡入及 0.7→1 缩放；14pt 手绘录制/停止/暂停/继续/保存图标；保存入场 150ms+0.52 spring、出场 90/110ms；保存文字 60ms 延迟+200ms 淡入/0.82 spring；计时气泡及高级提示采用各自独立可中断过渡。Surface 与布局使用同一目标宽度的独立通道，内部免费 alpha=0.4，外部气泡不被压暗；finalizing/saved 按钮仍有按压反馈但动作无效，失权后停止仍可用。
- 高级提示已回到本地录制按钮上方，不调用旧根视图提示；1800ms 自动隐藏，重复点按重新计时，离页取消并丢弃旧提示。竖屏/横屏真实工具栏位置、保存窄胶囊和主要状态操作已通过 UI 自动化并查看截图。
- **仍未完成**：安卓两种气泡分别声明 3dp/6dp 系统投影，现有公共 iOS 阴影参数没有完整绘制来源及一致性证据；本块没有用臆定模糊半径冒充该实现，气泡投影尚未接上。还需核对计时气泡的实际录制渲染/滑入裁剪、完整调用边界后再关闭 N09。此处也揭示旧 T24 的整体完成依据不足，1.91 台账已撤回 T24 完成状态；公共阴影统一收尾，不在 N09 另造一套近似实现。N09 保持实现中，增量进度仍为 **9/15**。
- 验证：首轮 `/tmp/ztransfer-20261015-n09-shutter.log` 17 项单元/生命周期通过，生产 UI 失败；覆盖首帧前快门、录像中半按停止、已有点按 AF 等待、退出排空及 ObjectAdded。随后发现两类实际问题：测试宿主共用日额度使监看提前退出；快门引用用 `State` 持有且 onChange 未显式消费新配置，导致界面可用但控制器保留 capturing=true。已分别注入独立测试用量存储、改 `StateObject` 及显式新配置同步。真实记录确认修复前长按收到的 capturing=true，修复后取消/松手/横屏全链通过。临时诊断代码已全部删除。
- 失败历史保留于 `shutter-input.log`、`shutter-trace.log`、`shutter-isolated.log`、`shutter-isolated-trace.log`（同 `/tmp/ztransfer-20261015-n09-` 前缀）。两个诊断构建在用例已报告失败后卡于测试后处理，确认进程和测试终态后终止相应 xcodebuild；未把终止当通过。`controls.log` 首轮胶囊 UI 暴露提示垂直定位错误，改按实际 32/18pt 气泡高度与 6/5pt 间距定位。
- 最终集中回归 `/tmp/ztransfer-20261015-n09-controls-final.log` **20 项单元 + 2 项 UI，22/22，TEST SUCCEEDED**；最后 Float 比例顺序/真实工具栏补充 `/tmp/ztransfer-20261015-n09-recorder-production.log` **6 项快门 + 1 项横竖 UI，7/7，TEST SUCCEEDED**，均包含 Debug 模拟器 App 构建。结果分别为 `Test-ZTransfer-Interactions-2026.10.15_15-08-47-+0800.xcresult`、`15-10-48`；截图已导出到 `/tmp/ztransfer-n09-controls-final-ui` 与 `/tmp/ztransfer-n09-recorder-production-ui` 并查看。测试进程均已结束；未做真机验收、未提交/推送。

### 2026-10-15 N10 完成状态纠正

当前 iOS `RemoteView` 仍将四种提示按 `interactionHint ?? recordingHint ?? localRecordingHint ?? lutMonitor.failure` 放在根视图顶部 60pt 的系统材质浮层，并使用旧 move/opacity 动画。安卓最终 `RemoteScreen` 使用统一 `showHint` 生命周期、取景器 20% 位置锚点、`MonitorHintBubble` 的横竖形态及完整时序。现有 N10 测试只覆盖协议/DISP/轮询/诊断，没有覆盖这条统一提示链，因此此前“整体复刻完成”证据不足，立即撤回。统一提示实现归 N10 收尾，不在 N09 重复实现；已有规格/剩余时长/存储/详情和诊断代码继续保留。

### 2026-10-15 N09 计时气泡与真实录制补充

- 查阅官方 Maven 的 Compose animation 1.7.6 `EnterExitTransition.kt`：只有含 changeSize 的过渡才启用裁剪，timer 的 fade/scale/slide 不应裁剪。已移除 iOS 计时气泡固定高度后的 `.clipped()`，保留 18pt 高度、上移 23pt 和物理像素取整的位移；不是修改安卓动画规格。
- `RemoteView` 支持注入同一个权益存储供页面与模型消费，生产默认仍为 `.shared`。新增 DEBUG 实际录制 UI 宿主使用独立权益/额度、64×48 JPEG 和临时输出目录，执行正常模型、帧解码、AVAssetWriter 和保存路径。
- 新 UI 用例覆盖计时递增、暂停 1.5 秒不走表、暂停中横屏切换、恢复计时、停止后气泡消失及 1800ms 保存反馈。首次失败是父容器辅助标识覆盖计时文本，已修正；第二次失败是测试串行等待错过短暂保存反馈，改为同时断言退场和保存。失败日志 `n09-timer-production.log`、`n09-timer-ax.log` 保留于 `/tmp/ztransfer-20261015-` 前缀。
- 最终 `/tmp/ztransfer-20261015-n09-timer-final.log` 为 **1/1 UI，TEST SUCCEEDED**，包含 Debug 模拟器构建；首轮另有 8 项胶囊单元、3 项真实录制生命周期、2 项既有 UI 通过。已查看最终横屏暂停/保存截图，结果 `Test-ZTransfer-Interactions-2026.10.15_15-25-07-+0800.xcresult`。实际产物复制为 `/tmp/ztransfer-n09-timer-saved.mp4`：H.264、64×48、4.936667s、109 帧，ffmpeg 以原始时间基全帧解码成功；默认 null 输出时间基曾产生重采样 DTS 告警，不作为原始 MP4 错误结论。
- N09 的计时实景块已收尾；3dp/6dp 公共投影依赖仍归 T24，未实现、不标完成。不再把共享投影当作继续 N10 的前置条件；N09 保持未完成，当前计数以页首全功能复核后的记录为准。

### 2026-10-15 N10 统一提示生命周期

- 已重新读取 `RemoteScreen` 全部 showHint 调用、计时器/nonce、横竖锚点、`MonitorHintBubble` 以及 `LutMonitorState` 通知路径。明确修正上段概括：**竖屏锚点在顶栏中间的 40dp 槽位**，两侧各留 6dp；仅横屏锚点位于取景器 y + height×20%、高 40dp、横向内边距 12dp。提示层应高于页内菜单/日志，并跟随监看内容旋转。
- 当前已接通单个 `RemoteMonitorHint` 与单个取消式隐藏任务，替换旧 interaction/recording/local 三套任务和固定优先级：最新消息立即替换；同文案也递增 nonce 并重新计时；退场保留最后文本；离页取消并拒绝迟到提示。普通提示 2500ms，本地录制错误/无声提示 3000ms，相机开始/停止失败分别 12000/6000ms；高级提示按钮自己的 1800ms 气泡仍独立。
- 已接本地录制、对焦、旋转锁定、工具不可用、LUT 当前接受结果及复制日志通知。LUT 的回调在代次检查之后发送，重复失败能重启提示，不再直接展示 `read/denied` 内部字符串。录像错误提示只显示安卓文案；协议摘要保留在最多 24 行的 `recordingErrorReport`，显示于开发日志并随复制导出。
- **尚未完成**：当前仍使用旧顶部浮层/系统动画，下一块应接竖屏/横屏锚点、280dp 上限、两行省略、12dp 圆角与描边/颜色，以及 160ms 入场/200ms 退场和中断行为。退出后保存失败的跨页通知也需核对。上述生命周期接线不能代替这些视觉与离页分支，N10 不标完成。
- 后续视觉规格已查实：只有 fade，无 move/scale；tween 默认 FastOutSlowIn。竖屏为 glassSurfaceHeavy alpha=.60、glassPanelBorder、onBackground 文本、11sp/13sp 行高、横向 8dp；横屏为黑色 alpha=.42、白色边框 alpha=.15、白字 alpha=.95、12sp/16sp 行高、横向 12dp。共同为 labelMedium 字重/字距、纵向 5dp、0.5dp 边框、12dp 圆角、最多两行末尾省略、宽度上限 280dp。不能把旧系统材质/默认过渡算作该实现。
- 新增 4 项生命周期/重复同文案/迟到结果/LUT 接线/录像文案与时长测试。集中回归首次发现旧生命周期测试默认共用真实日额度，模拟器记录已达 180 秒，导致相机会话提前退出；已改为每个测试独立的额度 suite，并保留显式传入的免费到期测试存储。首次失败/取消日志 `/tmp/ztransfer-20261015-n10-hint-lifecycle.log` 保留；取消后 Xcode 日志收尾断言卡住，确认测试 App 已结束后终止该进程，未当作通过。
- 隔离后的 `/tmp/ztransfer-20261015-n10-hint-isolated.log` 完成 **80 项单元/生命周期 + 2 项 UI**，其中 **80 项通过、2 项失败**。失败只在录制到期/撤销的旧末尾断言：模型已经 stopAndWait 后再次调用 startLocalRecording，旧断言要求生成页内高级提示；已按页面退出后不再显示提示的契约改为断言提示为空且仍不能开始新录制。新提示 4 项及两条生产录制 UI 均已在集中运行通过；测试 App 完成后 Xcode 后处理未退出，终止后保留原始结果，不改写为 TEST SUCCEEDED。
- 最终定向 `/tmp/ztransfer-20261015-n10-hint-exit-final.log` **2/2、TEST SUCCEEDED**，包括完整 MP4 全帧解码和并发退出清理；结果 `Test-ZTransfer-Interactions-2026.10.15_15-37-46-+0800.xcresult`。修改后的生产代码已由集中运行的 App 构建及 UI 执行覆盖，之后只改上述测试断言。`git diff --check` 通过，所有测试进程已结束；未真机验收、未提交/推送，N09/N10 均不标完成。

## 调度器调查结论（N01/N02）

2026-10-15 证据纠正：重新检查工作树发现 `CameraIOGate.withCameraTransaction` 实际没有此前完成记录所称的嵌套标记。现已按安卓 `TransactionMarker` 补入 task-local 的同 gate 嵌套拒绝，并补测试验证立即报错、外层所有权不提前释放、不同 gate 可用以及抛错后的上下文恢复。既有优先级测试同时改为等待四个请求实际入队后再放行当前持有者，避免把任务创建顺序误当入队顺序。`/tmp/ztransfer-20261015-n09-regression.log` 为 **127 项、3 项既有麦克风权限跳过、0 失败，TEST SUCCEEDED**，其中调度器 **16/16**。旧记录的“已实现嵌套拒绝”不能作为此次修复之前的证据。

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

**2026-10-15纠正：**C11/F052–F055已撤回N01/N02完成。下文“全部运行期接入”不成立：生产关闭不经gate，不能作为握手例外豁免；IDLE下载屏障缺失、取消交接可漏释放。旧14/14及76/76仅证明所运行场景，保留历史结果但不沿用完整性结论。

- iOS `CameraIOGate` 已改为 Android 1.93 对应的 `CameraRequestKind` 队列：P0 interactive、P1 preview、P2 transfer、P3 rating、P4 visible thumbnail、P5 background/catalog、P6 idle，以及评级阶段的后台 event poll 映射。
- 已迁移优先级选择、同级 FIFO、不可抢占事务、interactive reservation、rating phase 计数屏障、下载活动双重检查、等待/活动取消、嵌套调用保护、shutdown 闸门、快照和允许关闭事务。
- `CameraRepository`/`CameraSession` 已提供 scheduler snapshot 与 rating phase API，供后续 N02/N05 使用；连接丢失/移除路径在释放 session 前进入 scheduler shutdown。
- 新增 3 个调度器场景测试，连同旧 gate 回归共 **14/14** 通过：`/tmp/ztransfer-ios193-n02-gate-tests.log`（`** TEST SUCCEEDED **`）。生产工程构建通过：`/tmp/ztransfer-ios193-n02-wiring-build3.log`（`** BUILD SUCCEEDED **`）。
- 当前 N02 已完成 repository 全部运行期命令接入：AF、参数、监看、拍照/录像、FHD/EXIF、目录、缩略图可见/后台、下载分块、事件轮询、心跳和关闭前 shutdown 均经过统一 gate；连接握手/底层 transport CloseSession 保留为会话边界例外。PTPSession 原有取消/排空路径继续在传输事务内执行，未由 gate 提前释放。
- 既有 CameraDownloadTests 与 RemoteLifecycleTests 集中回归 **76/76** 通过，日志 `/tmp/ztransfer-ios193-n02-regression.log`（`** TEST SUCCEEDED **`）。N02 标记“复刻完成，待用户验收”。

### 2026-10-07 N03 照片加载范围收尾

**2026-10-15纠正：**下列历史正常路径测试未覆盖生产中间状态。`receiveEvent(ObjectRemoved)`没有清续扫快照；扫描以开始时的范围值贯穿，途中扩大不能自动续扫、缩小仍会预取旧范围；受限扫描完成后以权威标志调用磁盘reconcile，删掉范围外仍存在的照片缓存。N03保持实现中，复现与验收详见全功能复核C06/F017/F018/F020。本次仅审查，未修业务代码、构建或运行新测试；旧日志不作废，也不证明缺失分支已正确。

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

2026-10-15纠正：C08确认配对来源complete计数、范围/外部generation重建、来源顺序与诊断捕获缺口。现有配对测试等待超时后仍未断言complete，取消测试未阻塞真实读；旧5/5不证明这些路径。N05重开，未修复/未重跑测试。

- 对照安卓最终 `PhotoRatingScan.kt`、`NikonCamera` 评级缓存和 `CameraViewModel.loadFiles` 重新整理生命周期：评级开关关闭/再次打开各自创建新代次；STA 评级边界取评级日数与照片加载日数的非零交集，等待最新实际拍摄日的缩略图范围准备后再开始；开始读取后固定当前句柄快照，不因后续缩略图或目录更新重启；JPEG/RAW 唯一配对只读一个来源，但 `completed/total` 按可见评级文件计数；未知评级仍是已完成状态。
- iOS 新增 `PhotoRatingCache`，保存值和来源字符串，按插入顺序限制 8192 条；所有对象属性、照片头部、视频结构读和 EXIF 前缀被动读都在写入前检查代次，重连/新鲜目录扫描/显式关闭会清空并递增代次。`CameraSession` 暴露代次、缓存来源、失效和评级阶段接口，`PhotoListViewModel` 通过 `PhotoRatingScanController` 提供独立于网格重排的可观察扫描状态和取消入口。
- `PhotoRatingScanPolicy` 保留安卓的前八字符日期锚点语义（扫描边界不额外校验日历合法性），STA 未知日期不进入范围，AP/USB 使用对象属性并保留 RAW 头部回退，STA 使用照片头/视频结构读。每个文件读前检查取消，评级阶段在取消/异常后必定释放；旧任务的结果不能写入新代次。
- 新增 `PhotoRatingScanTests` 5 项：范围交集/零值回退、STA 边界等待、JPEG/RAW 单来源双进度、取消屏障、8192 FIFO 与代次拒写，均通过。日志 `/tmp/ztransfer-ios193-n05-scan-tests.log` 为 `** TEST SUCCEEDED **`（5/5）。评级解析、协议回放、评级生命周期与调度屏障集中回归 41 项首轮有 1 项既有并发排序断言偶发抖动，单独重跑通过；重跑日志 `/tmp/ztransfer-ios193-n05-cameragate-retry.log` 为 `** TEST SUCCEEDED **`，集中日志保留在 `/tmp/ztransfer-ios193-n05-rating-regression.log`。Release 模拟器生产构建通过，日志 `/tmp/ztransfer-ios193-n05-build-simulator.log` 为 `** BUILD SUCCEEDED **`；通用真机 Release 构建因本机未配置 development team 被 Xcode 拒绝，未改变代码编译结论。尚未做真机测试，本轮 N05 标记“复刻完成，待用户验收”。

### 2026-10-07 追加安卓同步核对

- `git fetch origin android` 成功，确认 `origin/android=8138e2de`；`git merge --no-edit origin/android` 生成 `77fde8d9`，无冲突。追加范围只有 `f40f6bbf`（诊断构建）和 `8138e2de`（按类目录前缀最终修正）；没有新增调度器行为。代理仍为 `http://127.0.0.1:7897`。
- 已阅读 [全局任务调度器权威逻辑](../技术调研/全局任务调度器权威逻辑.md)、安卓 `NikonCamera.CameraIoGate` 及当前 iOS N01/N02 接线；本次 `DownloadTrace` 只是诊断回调，不得被当作第二套调度器。
- 已逐文件调查 `TransferViewModel`、`NikonCamera`、`UsbPtpConnection`、`TransferCorruptionDiagnostic`、`TransferFingerprint`、`DownloadTrace` 以及两个安卓测试文件。新增功能路由为 N11 的 `ZT-` 类型目录最终语义和 N16 的诊断专用 R/T/F/L/C 取证；详细规则、排除边界和下一步见 [追加同步核对](iOS-1.93-追加同步核对.md)。
- 合并后已完成 iOS N11 按类型存放接线及专项回归；安卓诊断构建 N16 尚未迁移。N06 现有代码仍尚缺 N06 专项测试/集中构建证据。

### 2026-10-15 N11完整性纠正

全功能C09确认F039/F042：合集和成员坐标注册冲突、手动同源飞行去重及无frame边界未接通。按类型目录旧验证结果保留，但不足以支持包含传输交互的N11整体完成；当前撤回，未修改实现或重跑测试。

### 2026-10-07 N11 按类型存放复刻收尾（历史）

- iOS 已将安卓最终 `TransferStorageMode` 三态接入设置、列表、预览、本地队列和目录索引：`UNIFIED` 保持根目录，`BY_DAY` 使用 `ZTyyyy-MM-dd`，`BY_TYPE` 使用 `ZT-` + 去空白大写扩展名；无扩展名使用 `ZT-UNKNOWN`。目录名遵守安卓同样的 `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` 校验，`ZTFrames` 不作为类型目录。
- 入队时锁定目标目录；旧 `organize_transfers_by_date` 布尔值只作为迁移/兼容投影，不会覆盖新三态值。已传识别、目录扫描、重试/批量/自动入队和预览原图查找共用目标目录解析，避免切换设置后改变已入队任务。
- 新增 `DomainModelTests` 覆盖类型前缀/未知扩展名、旧值迁移与三态持久化、排队目标目录快照和 `ZTFrames` 排除。相关回归共 **180/180** 通过，日志 `/tmp/ztransfer-ios193-n11-relevant-tests.log`；专项领域测试 **121/121** 通过，日志 `/tmp/ztransfer-ios193-n11-storage-tests3.log`。
- Release 模拟器生产构建通过，日志 `/tmp/ztransfer-ios193-n11-build-simulator.log`（`** BUILD SUCCEEDED **`）。尚未进行真机测试，N11 标记“复刻完成，待用户验收”。

### 2026-10-07 N06 评级筛选 UI 复刻收尾

2026-10-15纠正：C08确认无偏好键时恢复为全部而非3日，评级呼吸/交替曲线及帮助气泡Genie/外点层未对齐。旧领域回归没有验证真实首次恢复及这些交互，N06重开；历史测试保持原有效范围，本轮未修改业务或运行测试。

- 已按安卓最终 `FileListScreen.FilterOverlay` 逐项修正 iOS：固定 271pt 居中面板与顶部间距、内容滚动上限、类型/标记/卡槽/星级/日期的顺序和间距、`DetentWheel` 拨轮及材质筛选胶囊、评级开关角标与等待/进度/完成文案、0–5 星紧凑材质按钮、范围帮助气泡、日期端点摘要、动态年份边界和开始/结束联动约束。评级加载开关仍独立于具体星级筛选，切换范围不会触发网格揭示动画。
- 修正了之前 iOS 与安卓的实质差异：移除安卓没有的标题和文件类型/状态/日期分组标题；过滤面板水平居中；保留未知扩展名选项；外部清除同步面板草稿；已传日期清除使用独立 38pt 玻璃按钮；帮助气泡使用右上锚定和项目符号；筛选按钮颜色、长按诊断和星级动画复用安卓对应材质路径。
- 新增自动化覆盖评级开关未选择具体星级时不改变网格、已知星级精确匹配、未知评级不匹配、关闭状态和评级范围持久化归一化。评级/筛选集中回归 **160/160** 通过，日志 `/tmp/ztransfer-ios193-n06-rating-regression.log`；领域测试单独 **123/123** 通过，日志 `/tmp/ztransfer-ios193-n06-ui-parity5.log`。
- Debug 模拟器构建成功，日志 `/tmp/ztransfer-ios193-n06-debug-build.log`；已安装并启动 `com.ztransfer.ios` 于 iPhone 17（iOS 26.5，UDID `7BE9C1A2-4BC0-43E1-9329-E540F9C9DF9F`），`simctl launch` 返回 PID 97905。尚未进行真机测试，N06 标记“复刻完成，待用户验收”。

### 2026-10-07 N07 实时多对焦框与被动诊断复刻收尾

- 按安卓最终 `LiveViewMetadata.kt` 迁移 0x9428 帧头：未知对焦判断保留为 `.unknown`，AF 表以 512/1024 头型的 380/816 边界校验，逐框验证并去重；保留其它有效框和无效选中索引，显示区域按裁剪映射，不把画外框平移回屏幕；状态值覆盖 `none`、`invalid-table`、`invalid-area`、`no-valid-visible-frame`、`full-frame`、`display-area`。声音、姿态和录像剩余时间解析继续独立失败回退。
- `RemoteView` 增加安卓同语义的 `focus_frame` 工具与立即持久化；多框按数量/合焦状态使用白/绿/黄颜色，黑色阴影加前景描边，取景器门控覆盖工具隐藏、断连、模式切换旧帧、500ms 过期和无框；点按/半按反馈保持独立，合焦后等待 120ms 才交给新鲜相机框，淡入淡出 160ms。
- 开发者面板新增 `Focus diagnostic v2` 被动诊断：仅采样已收到帧，每 200ms 限频，60 秒自动结束，状态变化才记行，UI 状态和最多 8 个步骤标记保留，报告有界 6000 字节并按 `focus_report_v1` 持久化；新增英文、简体中文、繁体中文逐字文案。
- 自动化新增 5 项安卓契约覆盖：未知状态/多框、坏表保留音频、显示区域裁剪、60 秒限频有界报告。`/tmp/ztransfer-ios193-n07-tests3.log`：DomainModelTests **127/127**，`** TEST SUCCEEDED **`；Debug 模拟器构建 `/tmp/ztransfer-ios193-n07-build3.log`：`** BUILD SUCCEEDED **`。尚未进行真机验收，N07 标记“复刻完成，待用户验收”。

### 2026-10-08 N08 对焦模式与点按路径复刻收尾

- 已逐提交核对安卓 `d87ee9fa`、`6767d052`、`c6227c6d` 的最终实现、`RemoteFocusModeTest`、`RemoteFocusTest` 和标签测试。iOS 新增标准 `0x500A`、静态厂商 `0xD061`、尼康 `0xD161` 三候选，严格按安卓数据类型和可写值域筛选；模式标签、AF Macro、MF（固定）、手动门控、写入后回读和工具入口均使用对应安卓语义与三语文案。
- 点按前每次重新读取 AF 区域描述并按机型和值域选择路径：主体追踪使用 `StartTracking`，单点/动态/宽区域使用 `ChangeAfArea`，仅在明确 `OPERATION_NOT_SUPPORTED` 时回退；未知机型保留旧探测回退，Z 系列不支持值显示安卓原文提示并不发送 AF。两条命令都使用增强 Live View 的完整坐标域，保留 80ms 间隔、AF 驱动一次、错误/取消/跟踪状态以及确认框更新规则。
- 生产接线位于 `RemoteCameraTool`、`CameraRepository`、`CameraSession`、`RemoteViewModel`、`RemoteView` 和相机工具菜单/布局/本地化；相关测试补在 `RemoteCameraToolTests`、`RemoteLifecycleTests` 和 PTP wire replay，覆盖模式候选与数据类型、标签/手动规则、坐标边界、所有路径映射、显式路径命令顺序、非 OP 错误不回退、模式回读门控及 Z 系列不支持提示。
- 定向回归 `/tmp/ztransfer-ios193-n08-final-tests2.log`：`RemoteCameraToolTests` **9/9**、`RemoteFrameProtocolTests` **20/20**、`RemoteLifecycleTests` **50 项通过、3 项跳过**，合计 **82 项：79 项通过、3 项既有麦克风权限跳过、0 失败**，`** TEST SUCCEEDED **`。覆盖了显式路径响应透传、非 OP 错误不回退、区域拒绝/通用失败提示、Z30 动态区域 S/M/L 名称和全部支持 AF 路径点按标记。首次路径结果透传遗漏已由 wire 用例发现并修复后重跑通过。此后补齐闭环并在 `/tmp/ztransfer-ios193-n08-closure-regression.log` 重跑 `RemoteCameraToolTests` **9/9**、`RemoteFrameProtocolTests` **20/20**、`RemoteLifecycleTests` **56 项通过、3 项跳过**，合计 **85 项：82 项通过、3 项既有麦克风权限跳过、0 失败**，`** TEST SUCCEEDED **`。Debug 模拟器构建 `/tmp/ztransfer-ios193-n08-closure-build.log` 为 `** BUILD SUCCEEDED **`；已重新安装并启动 `com.ztransfer.ios` 于 iPhone 17（PID 25323）。尚未进行真机验收，交由用户验收。

- 收尾补齐：`0xD061` 属性事件刷新、照片/录像切换后的模式回读代次隔离、模式写入失败/异常后的最终回读、工具写入期间的拍摄/录像/半按/点按互斥和模式按钮加载态；成功应用时清理焦点瞬态状态并保留 AF 区域记忆。新增生命周期测试已覆盖这些边界，N08 标记“复刻完成，待用户验收”。

### 2026-10-08 N09 模式切换依据纠正

重新阅读安卓 `RemoteScreen.kt:1348` 的 `refreshMovieMode`：实体拨杆变化仅刷新焦点、对应曝光和 Auto ISO；照片模式另清 recording 与应用模式，并非无条件重启 Live View。撤销此前仅凭台账推导加入的 `restartLiveView = true`。上文“模式切换重启屏障”记录不再作为完成证据。USB 专项失败目前只证明等待超时及停止后未观察到预期重启，尚不能断定清理竞态；尤其第 961 行断言比较的是 control:off 与最后一次 start，而非 app:off/control:off 顺序。本轮未重新运行测试，下一步需定位该真实失败并按最终安卓调用链补齐照片模式清理。N09 保持未完成。

同日重新单独运行 USB 用例 `/tmp/ztransfer-n09-usb-recheck.log`，仍在录制启动等待阶段超时，且 `usb:refresh` 索引不存在；失败发生在停止清理之前。安卓对应路径要求进入 USB 录像前先 join 旧 Live View、刷新会话、开启 ControlMode、写入录像尺寸、重新启动 Live View 后再开始录制；下一步应围绕这条启动链定位 iOS mock/生产状态门控，而不是继续修改停止顺序。

2026-10-11 USB 录像专项重跑：加入临时日志确认启动链实际为 `end → usb:refresh → control:on → liveViewImageSize=3 → start → movie:prepared`，单项 `/tmp/ztransfer-n09-usb-debug.log` 为 `** TEST SUCCEEDED **`（1/1，3.08s）。此前失败属于时序抖动，未发现生产启动链缺失；临时日志已移除。N09 仍未完成，需补跨模式回放和启动壳 UI 证据。

同日 USB 启动/停止生命周期专项重复 10 次验证：`/tmp/usb-10x.log` 为 `** TEST SUCCEEDED **`，10/10 通过、总耗时 30.279s；未发现可复现的生产链缺失。`pauseLiveViewForMovieTransition` 仍以帧循环观察 `liveViewPaused`，与安卓显式 cancel-and-join 的实现细节不同，暂保留为待跨模式压力回放核对项。

为避免旧 transition 的确认标记被下一次 pause 复用，`pauseLiveViewForMovieTransition` 现在在设置新请求前清除 `liveViewPaused`；USB 生命周期 10 次重复测试在 `/tmp/usb-10x-reset.log` 通过。该改动只收紧事务屏障，不改变安卓已核对的命令顺序。

### 2026-10-11 N10 调查与协议块

安卓最终 `MonitorMovieFormat`、`MonitorStorage`、剩余时长规则已核对。iOS 新增 `RemoteMonitorTelemetry` 纯协议解码：D0A0 UINT64 录像规格只接受已验证的数据类型、标志位、帧率和 1080/4K/720 布局；GetStorageInfo 按偏移 6/14 的小端 UINT64 解析容量/剩余并拒绝截断、负数和不一致值；剩余时长按 00:00/1:00:00 规则限制在 24 小时内。`RemoteDispModeTests` 新增 4 项边界测试，`/tmp/ztransfer-ios193-n10-telemetry.log` 为 `** TEST SUCCEEDED **`（4/4）。该块尚未接入相机属性读取、DISP UI、剩余时间显示或诊断入口，N10 仍待调查/实现。

协议块在共享工作区重跑确认：`/tmp/ztransfer-ios193-n10-telemetry-rerun.log` 为 `** TEST SUCCEEDED **`（4/4）。

随后接入 N10 的第一条生产读取路径：新增 `RemoteProperty.movieFormat`（D0A0），监看启动和模式切换时读取，收到属性事件时刷新；仅在验证通过时把规格显示为状态栏徽标，未知值隐藏。Debug 模拟器构建 `/tmp/ztransfer-ios193-n10-format-build3.log` 为 `** BUILD SUCCEEDED **`。N10/N09 联合回归 `/tmp/ztransfer-ios193-n10-n09-regression.log` 为 `** TEST SUCCEEDED **`，RemoteDispMode 4 项 + USB 生命周期 3 次迭代共 15 项通过。GetStorageInfo、剩余时长 UI 及诊断入口仍未接线，N10 继续未完成。

同日补接监看剩余时长：在 DISP 的 Camera 信息状态下，从已有帧元数据读取 `remainingVideoTimeMs`，按安卓 `mm:ss`/`h:mm:ss` 规则显示带方括号的剩余时间；无效值不显示。最终 Debug 构建 `/tmp/ztransfer-ios193-n10-final-build.log` 为 `** BUILD SUCCEEDED **`。存储卡余量轮询、白平衡/电池详情、开发诊断入口及完整 DISP 布局仍未迁移，N10 保持未完成。

补充生产接线回归：`RemoteLifecycleTests.testMovieFormatIsReadOnEntryAndInvalidValueIsHidden` 验证电影模式进入读取 D0A0、有效值显示 `1080 60p`，属性事件收到未验证分辨率后清除显示；`/tmp/ztransfer-ios193-n10-format-integration.log` 为 `** TEST SUCCEEDED **`。

2026-10-11 N10 存储卡余量生产接线：新增 PTP `GetStorageInfo (0x1005)` 的 CameraRepository/CameraSession 路径，复用已发现的物理存储 ID，按安卓规则过滤无效/聚合卡、去重排序，并以 IDLE 调度请求逐卡读取。RemoteViewModel 仅在 DISP=Camera、会话就绪且拍摄/录像/相机工具空闲时启动首次读取和 30 秒轮询；有效容量以十进制 GB 显示，单卡显示 `x.x GB`，多卡使用安卓三语 `Storage n · x.x GB` 文案并合并为一行。截断/负数/超容量/零容量数据继续隐藏，瞬时错误只丢弃当前卡并在下轮重试，`0x2005` 会清空当前 DISP 的卡片并停止后续轮询；离开 Camera DISP 或断开连接会清空旧值，重新进入会重新发现能力。

新增 `RemoteLifecycleTests` 存储轮询生命周期用例：排序/去重/十进制余量发布、无效卡隐藏及 `0x2005` 停止轮询，专项 `/tmp/ztransfer-ios193-n10-storage-tests3.log` 为 **2/2**；与 D0A0/剩余时长/USB 生命周期/协议边界的 3 次迭代联合回归 `/tmp/ztransfer-ios193-n10-storage-regression.log` 为 **24/24**，`** TEST SUCCEEDED **`。生产 Debug 模拟器构建 `/tmp/ztransfer-ios193-n10-storage-build2.log` 为 `** BUILD SUCCEEDED **`。N10 仍未完成：完整 DISP 视觉布局及开发者视频诊断入口尚未迁移，白平衡/电池详情也不在本任务当前闭环内。

随后将 D0A0 首次读取门控到 initialLoaded/Camera DISP，并以 `/tmp/ztransfer-ios193-n10-final-tests.log` 重跑存储轮询与电影规格失效回归 **2/2**，`** TEST SUCCEEDED **`。

### 2026-10-11 N10 DISP、详情轮询与开发诊断收尾

- 完成监看详情轮询：白平衡描述值在相机 DISP、会话就绪且拍摄/录像/工具空闲时按 2 秒刷新；电影规格在进入 DISP/电影模式时立即读取，并在同样的空闲条件下每 10 秒重读，离开条件或停止时取消任务并清空旧值。无效描述、截断值和不支持响应均回退为空，不阻塞主监看帧循环。定向生命周期与 DISP 回归 `/tmp/ztransfer-ios193-n10-moviepoll-tests.log` 为 **6/6**，`** TEST SUCCEEDED **`。
- 按安卓 `CameraMonitorDisp` 重排 iOS DISP：横屏 Camera 模式使用无框阴影文字顶栏（存储卡、电影规格/剩余时长、电池百分比）和右上 `STBY` 门控，底部固定 MODE/WB/AF 槽；横屏 Exposure 仅保留模式摘要；竖屏保留 MODE/对焦徽标。纯布局/状态门控测试与白平衡轮询共 `/tmp/ztransfer-ios193-n10-layout-wb-tests2.log` **6/6** 通过。
- 增加开发者面板两个只读入口并接入三语文案：录像剩余时间探测严格复刻固定 `GetLiveViewImage (0x9203)` JPEG 偏移/大端字段布局，只扫描前 2048 字节；电影规格探测只读取 `D0A0/D0A7` 描述和值并输出十六进制/解析结果，禁止写属性。协议回放 `/tmp/ztransfer-ios193-n10-video-probe-tests2.log` **2/2** 通过；完整能力扫描仍按安卓新版边界排除。
- 最终 Debug 模拟器生产构建 `/tmp/ztransfer-ios193-n10-final-build3.log` 为 `** BUILD SUCCEEDED **`。N10 现标记“复刻完成，待用户验收”；本轮未安装、未提交、未推送，需在真机上由用户验收相机 DISP、详情轮询和只读诊断输出。

### 2026-10-15 N10 提示锚点、淡入淡出与文字实际绘制

本节补充页首已撤回的 N10，不恢复整体完成状态。未更新安卓基准，未提交或推送。

- 重新读取 `RemoteScreen.kt` 的顶栏/横屏锚点、最终叠放位置和 `MonitorHintBubble`，以及项目 `Type.kt`、官方 Compose 1.7.6 `EnterExitTransition`/`Transition`/`AndroidParagraph`/`LineHeightStyleSpan` 和 Material3 1.1.2 `Surface`。安卓没有该提示层的专项自动化测试，新增 iOS 用例直接约束上述源码行为；不是拿相似界面替代源码。
- 删除根视图顶部 60pt 的系统材质/滑入提示。竖屏锚点位于信号/电池与返回之间，40pt 高、左右内缩 6pt；横屏锚点位于取景器高度 20% 处，40pt 高、内缩 12pt。原点按物理像素取整；提示与开发日志都放入监看本地旋转画布，提示位于菜单和日志上方，锚点由布局偏好产生，不参加相机取帧。
- 新 `RemoteMonitorHintMotion` 只做 alpha：正常进入 160ms、退出 200ms FastOutSlowIn；中断进入转退出使用默认临界弹簧 1500，PostExit 回 Visible 使用源码默认弹簧 400，延续当前值和速度。退出结束才移除内容，同一可见状态的新文字不重启淡入，离页销毁显示时钟。
- 气泡圆角 12、边线 0.5、最大宽 280，横竖各自颜色/透明度/11或12pt 字体/13或16pt 行间距、水平8或12和垂直5pt内边距。项目自定义 labelMedium **未设置0.5sp字距**，最终解析为0；也移除 N09高级提示误加的 tracking(0.5)。Compose 默认 includeFontPadding=false、Trim.Both，因此行高是基线间距，首尾额外留白不保留；高度不足按 AndroidParagraph 减少行数并在最后一行省略。iOS 仍使用项目既有原生字体，不能将本轮布局/像素带测试描述为 Android/iOS 字形逐像素等同。
- 文字测量和绘制共用 TextKit，跨 alpha 帧缓存测量。保留 UIKit 实际接收的 bounds 和已测行数，避免 UILabel 二次计算 textRect，以及 SwiftUI 分配高度时的小数像素舍入，把两行重新裁成一行。原生透明触摸层遵循 Material3 非点击 Surface 的阻挡行为，圆角外不阻挡，不新增关闭动作。
- 验证历史如实保留：`n10-hint-presentation.log` 的 20 项中两项排版测试失败，18 项通过（含两项生产 UI）；收集失败诊断时只终止其 `simctl diagnose` 子进程，xcodebuild正常以65/TEST FAILED结束。`n10-hint-presentation-final.log` 显式段落截断造成过早单行，三项失败。之后 `n10-hint-text-layout.log` 11/11和 `n10-hint-ink-final.log` 12/12虽通过，截图仍显示宿主绘制只占一行，故未据此收口；新增宿主像素带断言并保留测量行数后，最终 `/tmp/ztransfer-20261015-n10-hint-host-ink.log` **3项排版/实际像素+1项生产UI，4/4、TEST SUCCEEDED**。此前4项动画/4项提示生命周期通过，相关代码在最终修正中未改。
- 最终 xcresult `Test-ZTransfer-Interactions-2026.10.15_16-04-26-+0800.xcresult`；截图导出 `/tmp/ztransfer-n10-hint-host-ink-ui/`，已查看竖屏两行及末尾省略的实际绘制。生产 UI 覆盖英文 MF 提示、竖屏顶栏/横屏20%锚点、随画布旋转、气泡阻挡取景器输入及其余区域可点。N09锁定提示的真实横竖工具栏 UI 在本轮前两次运行均通过。
- **N10 仍未完成**：离开页面后的录制保存失败仍被 `stopRequested` 门控吞掉；安卓在此分支使用系统短 Toast，而页面内使用3000ms统一提示。尚未接跨页面失败通知。共用字体、其他主题/语言/日志叠层及任务全范围核销不能用这一组测试代替。另在读取三态过渡来源时发现 N09 `RemoteRecorderVisibility` 的退出中重入规则尚需逐分量核对，保持未完记录，不沿用普通开关测试证明中断对齐。

### 2026-10-15 N01 准入交接取消泄漏修复（全功能复核 F052）

- 对照权威调度器文档1.4、Android `CameraIoGate.acquire/cancel/release` 及排队/active取消测试。确认 Swift `pump` 已先设 active，但 `waitForAdmission` 末尾取消检查可能在外层 admitted=true 前抛错；旧 defer 只删 pending，留下永远无法释放的 active owner。
- `withCameraTransaction` 改为所有退出路径按 ticket 身份执行 `finish`：选中者清 active，等待者从 pending 清理；取消回调仍只处理等待项，已开始的协议事务继续自行排空，不能提前交出通道。
- 新增 DEBUG 专用准入交接探针，位置在 waiter 被恢复后、`waitForAdmission` 返回前。测试真实排入第二项，等第一项释放及第二项被选中后取消它，断言业务 block 未执行、第三项能够运行、active/queued 最终归零；不是复用既有 admitted 之后的 transfer probe 冒充覆盖。
- `/tmp/ztransfer-20261015-n01-admission-cancel.log` **17/17、TEST SUCCEEDED**，含准入取消、嵌套、优先级/FIFO、shutdown及框架管理命令取消排空既有回归。xcresult `Test-ZTransfer-Interactions-2026.10.15_16-05-58-+0800.xcresult`。
- 这只关闭 F052 的实现缺口，**N01/N02 不恢复完成**。F053（IDLE 整文件下载屏障及 MONITOR_STORAGE 调用/allowed回检）、F054（生产 CloseSession 完整事务调度）、F055（评级代次任务所有权）仍未修复。当前1.93页首计数3/15，不增加完成数；真机验收未运行，未提交或推送。
