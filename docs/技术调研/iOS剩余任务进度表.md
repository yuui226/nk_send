# iOS 剩余任务进度表

> **状态纠正（2026-09-12，优先于下方历史记录）**：撤回此前“Windows 剩余 0 项 / 已完成”的结论。`9d33a2e` 的文件注册检查只验证工程引用，不能证明 Swift 类型正确、功能接通或两端能力一致。已确认可选闭包错误标注 `@escaping`、Swift 调用参数顺序错误、一个 XCTest 文件漏导入应用模块，现已修正，Apple 编译仍未运行。还发现选图临时文件名写成字面量、批量异常未登记失败资产、异步进度可覆盖最终状态、成片容器随 View 重建及语言更新未接入等问题，均属 Windows 可继续修复内容。原 50/50 为历史传图版范围，不计作此次全功能完成率。

### 重新核验的当前工作（2026-09-12）

以下按可交付功能分组，修复与验收门槛齐备后才结项。**当前已识别 9 组工作：7 组 Windows 侧源码/账本修正完成、2 组未完成；更大范围的总剩余数量仍需审计，不能据此称只剩 2 项。** 这里的源码修正完成不代表 Swift 编译或 XCTest 通过。详情补入各行，后续若发现新缺口增加记录，不用文档“0”替代证据。

| 项目 | 状态 | 当前证据 / 下一步 |
|---|---|---|
| C01 Swift 已知声明、调用与测试导入修正 | 源码已修正 / Apple 待编译 | 两个可选闭包移除非法 `@escaping`；`openPhotoEffects` 移到初始化参数末尾；成片容器测试补 `@testable import ZTransfer`；只改 iOS |
| C02 批量状态与失败重试 | 源码已修正 / Apple 待编译、测试 | 固定批次快照与两路上限；等待进度发布后再完成；异常与 false 均登记失败，重试只处理失败项且累计成功；禁止生成中换图/重复启动；代次拒收迟到回调；两路渲染共用串行 Photos 发布者，取消等待不取消已提交事务；14 项批次/会话/发布者 XCTest 已登记但未运行 |
| C03 系统选图和输入/成片文件所有权 | 源码已修正 / Apple 待编译、测试 | 系统多选保留选择顺序；每次选择独立目录、每张唯一文件名；在 provider 回调内复制，取消只回调一次且丢弃旧代次；取消/全失败保留旧选择；源图由资产持有，成片由 session/工作线程/系统面板持有，最后释放清理，不在子 sheet 的 onDisappear 删除；8 项新增生命周期/系统选图样本待 Mac |
| C04 预览与原尺寸输出 | 源码已修正 / Apple 待编译、测试 | 预览改用后台方向校正缩略图，缓存键包含源路径/滤镜/强度且最多 6 项；导出改为 256 行分块、保持源尺寸并沿用方向元数据，私有成片通过所有权回收；4 项预览/尺寸/坏文件样本待 Mac |
| C05 分类、收藏、拨轮及动态语言 | 源码已修正 / Apple 待编译、测试 | 生产目录使用 shared 稳定分类 ID 与收藏排序索引；“全部/收藏/分类”筛选和收藏置顶由同一 common 策略决定；帮助观察 app 有效语言并保留完整语言标签；Swift 分类显示仍待 Mac 对照拨轮长按、拖动及空收藏态 |
| C06 正式本地入口与相机设置效果 | 源码已修正 / Apple 待编译、UI 待验 | 首页在无相机连接时也提供正式照片效果入口；设置浮层复用同一 presentation 路由；相机/文件队列所有者仍不复制，连接态文件页入口保留；Mac 需验证首页、设置浮层、文件页三处的 sheet 互斥和返回行为 |
| C07 全部边框、水印及队列效果处理 | 未完成 | 按扩展表 E05—E12 核实真实执行链；不得把共享算法存在当作功能完成 |
| C08 Windows 回归与证据修复 | 未完成 | 之前 Python 全套出现失败，原因未完整归档；旧守卫不得直接刷新指纹或删断言 |
| C09 扩展范围与任务账本一致性 | Windows 已完成 / Apple 待验 | 已将扩展任务表从旧的“全部暂停”状态对齐到当前代码：E01/E03/E04/E10 标为进行中，其余 E/G/R/X 保持 TODO；34 项完成数仍为 0，未把部分接线计入完成；Mac 专属验收继续单列 |

每完成一组在本节更新状态、验证和提交，并播报本表剩余组数；本表不替代 E/G/R/X 功能验收。Mac M01—M12 仍全部待验。此前已推送文档中的“0 项”保留为错误历史记录，不能继续引用为当前状态。

**C02 检查记录（2026-09-12）**：`check_structure.py` 通过，58 个 App Swift / 17 个测试文件各注册一次，480 个 XCTest 方法仅存在、未运行；`git diff --check` 通过。测试覆盖并发上限/独立游标、异常与返回失败重试、生成中换图拒绝、旧代次/取消回调、进度终态、会话释放，以及图库串行回执、权限复用、取消等待、失败后继续。此批相对 `836eaed` 只改 iOS 源码、工程登记、测试与本进度文档，未改 Android/shared、原片 PhotoLibraryImporter 或打包脚本，不需 Android 行为复测；Mac 需运行上述样本及多选批量保存/部分失败重试。未重跑历史全套源码守卫，已有 `383 tests / 88 failures` 待 C08 归档修复，不能称全套通过。

**C03 检查记录（2026-09-12）**：`check_structure.py` 通过，58 个 App Swift / 16 个测试文件，477 个 XCTest 方法仅登记、未运行；`git diff --check` 通过。输入目录只包含应用自己的副本，不按猜测的前缀删除外部文件；生成文件接管所有权时明确使用 `ownedURL`，部分生成文件失败也随引用释放回收。原片导出器和图库导入器未改，新增的 Files/分享协调器保留成片快照至面板释放。相对 `411dea5` 只改 iOS 与本文档，Android/shared 无改动；Mac 需验证 iCloud 载入中取消/重选、全失败与部分失败、生成期间离开、结果重选、Files/分享回执前后的文件存在性。C04 的原尺寸渲染/预览和 C08 的历史全套失败仍未关闭。

**C04 检查记录（2026-09-12）**：`check_structure.py` 通过，58 个 App Swift / 17 个测试文件，481 个 XCTest 方法仅登记、未运行；`git diff --check` 通过。预览解码器以 ImageIO thumbnail transform 应用 EXIF 方向并限制最大边，预览缓存按源路径、稳定滤镜 ID 和强度区分且有 LRU 上限；导出不再使用 32MP 的全图拒绝门槛，而是保持源像素尺寸、按 256 行处理滤镜并在每条错误/取消路径释放私有成片。新增 `PhotoEffectsPreviewTests` 的方向/尺寸/坏文件/原尺寸样本待 Mac；原有 `MediaPreviewCompatibilityTests` 仍须运行。相对 `696cb48` 只改 iOS、工程登记、测试与本文档，Android/shared/原片导入器无改动；C04 仍不能称 Apple 编译或真机通过。

**C05 检查记录（2026-09-12）**：`check_structure.py` 通过，58 个 App Swift / 17 个测试文件，481 个 XCTest 方法仅登记、未运行；`git diff --check` 通过。新增 `NativePhotoFilterCatalog.categoryId` 与 `orderedIndexCsv`，以稳定枚举 ID 和标量 CSV 复用 common 的分类/收藏排序，避免 iOS 按中文标题推断（Android 调用语义不变）；`PhotoFilterCatalogStore` 的注入目录只用于单元测试，生产初始化统一走 shared。`PhotoEffectsHelpModel` 改用完整系统语言标签并观察 `AppAppearanceSettings.languageTag`。新增 common 分类测试定向运行成功：`BUILD SUCCESSFUL`；同一次完整 shared 单元测试为 797 项中既有 `DesqueezePolicyTest.kt:13` 失败 1 项，不能称 Android 全套通过。相对 `0849f79` 改动 common/iOS、工程测试登记和本文档，未改 Android 宿主、协议、打包脚本；Mac 需编译生成新 Native 桥后运行 `PhotoFilterCatalogTests`、帮助测试并对照两处拨轮。

**C06 检查记录（2026-09-12）**：`check_structure.py` 通过；新增首页 platform 可选 local photo-effects 路由，iOS `CameraWorkspaceBridge` 将其转发到已有 `PhotoEffectsPresentation`，因此未连接相机时也能打开工作台，关闭 workspace 后回调被拒绝。新增 common `NativeConnectionHomeTest` 路由样本与 iOS `CameraWorkspaceTests` 路由样本；定向 shared 编译测试（`NativeConnectionHomeTest`、`NativePhotoFilterTest`）`BUILD SUCCESSFUL`。相对 `1afda54` 只改 shared/iOS 入口、测试与本文档，未改 Android 宿主/协议/打包脚本；Mac 仍需验证真实 Compose 首页、设置浮层和文件页的 sheet 互斥、返回以及横竖屏表现。C07—C09 未完成。

**C08 检查记录（2026-09-12）**：实际运行 `python -B -m unittest discover -s iosApp/scripts -p 'test_*.py'`，结果为 `Ran 384 tests`、`FAILED (failures=94)`；完整失败名见 [Windows 回归记录](../测试与验证/ios_windows_regression_20260912.md)。失败项全部来自历史整文件/抽取守卫链，主要涉及旧检查点之后已经审阅过的 Android UI、shared UI 和 iOS 生命周期文件；当前输出未显示 Python 异常退出或新增照片效果测试失败。不能通过刷新 SHA-256、删除断言或跳过测试来修复，仍需把后续已审阅批次逐层加入可审计逆转换，并保留旧检查点保护。另修正了共享 UI 检查器对“波轮→拨轮”和末尾空行的精确机械变换；`check_shared_ui_migration.py` 前 18 个主体通过，队列主体仍因旧检查点与当前架构不一致而停止。新增当前分支门禁及其标准测试 `python -B iosApp/scripts/check_current_ios_scope.py`、`python -B -m unittest iosApp/scripts/test_current_ios_scope.py` 均通过：Android/build 相对 master 无改动，iOS 效果生产文件和唯一 presentation owner 存在；该门禁不替代历史守卫，也不替代 Apple 编译。本记录只归档事实，不将 C08 标记为完成。

**C09 检查记录（2026-09-12）**：核对 [iOS扩展功能任务表](./iOS扩展功能任务表.md) 与本表及当前 `research/ios` 文件。旧的 2026-09-08“照片效果全部暂停”已保留为历史说明；当前 E01/E03/E04/E10 的 DOING 均明确指向 C01—C06，并注明相框/水印、完整组合和 Apple 验证缺口；E02/E05—E09/E11—E12、G01—G08、R01—R10、X01—X04 仍为 TODO，分组计数和 34 项完成数没有虚增。C09 的 Windows 账本同步完成，Apple 编译、真机和外部决策项不在 Windows 结项范围。

**追加验证（2026-09-12）**：`swiftc` 与 `xcodebuild` 在当前 Windows 环境均不存在；可执行的 shared 定向回归 `:shared:testDebugUnitTest --tests com.ztransfer.ui.NativeConnectionHomeTest --tests com.ztransfer.filter.NativePhotoFilterTest` 输出 `BUILD SUCCESSFUL in 20s`。这只证明 shared/Android 编译测试，不替代 Apple 编译。

**账本一致性验证（2026-09-12）**：新增 `python -B -m unittest iosApp/scripts/test_progress_ledger.py`，2 项通过；测试锁定 C01—C09 明细顺序、当前 7/9 与 C07/C08 剩余项，以及扩展表 E/G/R/X 的行数和 0/34 完成计数。

**C07 核对记录（2026-09-12）**：共享层已存在 `PhotoFrameLayouts.kt`、`PhotoFrameWatermarkPolicy.kt`、`PhotoFrameMetadataSettings.kt` 和 `PhotoFrameOutputIdentity.kt`，但实际绘制/编码调用仅见于 Android `app/src/main/java/com/ztransfer/frame/PhotoFrameExporter.kt`；iOS 当前 `PhotoEffectsExportService.swift` 只调用 shared 滤镜内核，未接入相框布局、水印内容/资源、元数据绘制或效果队列。iOS 资源目录也没有对应水印资源和持久化适配。C07 保持未完成，下一步必须建立真实的 Apple 绘制/资源/配置链并接入现有批量导出，不能用空入口或单独演示组件代替。

> **最新决定（2026-09-08）**：用户已叫停本次照片效果实现，先跳过并保留 [iOS扩展功能任务表](./iOS扩展功能任务表.md)。新增计划仍 0/34，E01—E12 再次暂缓，本次没有业务代码修改；不自动继续其他扩展任务，会员/支付仍排除。本表 W01—W50 的 50/50 仅指传图版 Windows 范围，Mac 仍 0/12。`4874a0b` 已提交并推送，后续接手核实实际 Git 和用户新指令。

> **当前覆盖（2026-09-12）**：照片效果已按新指令恢复 Windows 侧 iOS 代码填充；滤镜目录/分类选择、拨轮长按入口、批量多选/横向预览、两路并发、真实 shared 内核导出、PhotoKit/Files/分享承载、失败项重试和结果状态均已加入 `research/ios`。上面的 2026-09-08 文字保留为历史决定，不覆盖当前实现状态；正式设置浮层宿主入口已接线，并在跳转前关闭原文件页；Apple 编译/真机验证仍未完成。

> 后续执行和报进度优先读本文件。原[实现任务清单](./iOS实现任务清单.md)保留功能总账和历史证据，不再凭批次数估算百分比。
> 基准：2026-09-06，`research/ios`，`42abf5b`（第59批结束）。本表是该检查点之后的剩余工作，不要求重写已经完成的代码。

## 新会话接手入口（先读，2026-09-12更新）

本文件是项目接续的唯一进度入口。新会话在同一仓库收到“按此文档继续”后，应核实代码状态并继续实现，不必让用户重述历史，不要仅重新列计划。以下是已确认的项目要求；新的用户指令及仓库AGENTS.md优先。不要把文档里的历史“已授权”当作跳过当前工具权限或擅自发布的许可。

### 我们在做什么

- 为现有Android应用“Z传”实现同仓库iOS传图版。核心目标是复用已有业务规则与可共享UI，减少两套逻辑的重复维护，保持Android已有功能和体验不变。
- Android业务共享化已完成；当前做的是iOS实现及完整传图流程接线，不是重新迁移Android，也不是另做一个只有相似外观的演示App。
- 本轮目标：在Windows完成所有能做的代码、接线、测试样本与适用验证，再交给Mac完成Apple编译及真机验收。用户有MacBook Air M1，但当前不要求启动Mac。Windows还有实质工作，不能把尚能实现的内容一概归为“等Mac”。
- 两处照片效果、会员/支付、遥控监看、GPS发送暂缓；照片已有GPS元数据读取、相机已有视频文件传输不随之暂缓。iOS不新增USB Host入口，不承诺无限后台传输。按Android实际已有能力对照，不擅增视频播放器或相机删除能力。

### 先确认仓库，不要切回旧master

- 本机仓库：`D:\code\nk_send`；当前开发分支：`research/ios`；远端：`origin`，`https://github.com/yuui226/nk_send.git`。
- 已推送检查点：`6ab3302`（W06），此前`3cc239d`（交接）、`7dd094d`（审计）、`8503823`（实现）。W07—W10已提交并推送为e5dbadb；W11—W20已提交并推送为ad101d5；W21—W30已推送8594187，W31—W40已提交f993e8e，W41—W50待提交，接续以实际Git状态为准，保留全部未提交工作。
- 旧master基线为`a6b679a`，未纳入本分支共享化迁移；具体提交差距以Git为准。用户未要求合并/变基/挑拣/切分支，不自动执行。
- 先运行下列只读检查。若当前分支、HEAD或工作区与本记录不同，先辨认后续提交和用户修改，不能重置、覆盖或重复应用本批代码。`origin/...`是本地远端跟踪引用，不等于新会话已联网检查远端。

```powershell
git status --short
git branch --show-current
git log -5 --oneline
git rev-list --left-right --count HEAD...origin/research/ios
```

### 进度口径：严禁再次混淆两个“50”

- 用户所说“完成50个任务”指本文件W01—W50的**主任务**。此前agent误拆了P01—P50子项并汇报“50/50”，造成错误预期；[并行批次](./iOS并行实现批次.md)只作历史实现索引，绝不代表主任务完成。
- W01—W50全部WIN-DONE：50/50，Windows本轮传图范围100%（历史刻度100%）。W21—W30已推送8594187，W31—W40已提交f993e8e，W41—W50本次最终提交；实际HEAD/是否推送以git状态为准。1085项Kotlin/Android（768+317）、366项Python、3213个AndroidX EXIF金样、common metadata、Android Debug/Release完整源码编译、Debug Lint与原UI守卫通过；三套依赖快照0变化。相对8594187无Android宿主/平台/版本/打包改动。449项XCTest和17项Native图片样本未运行；Mac仍0/12，下一步M01/M02。Windows实现和检查结束，不继续加功能、不称Swift已编译或可发布；Mac发现问题回开对应W项。
- 延续历史刻度100%仅兼容旧记录，不能据此推算剩余工作量。优先报主任务完成数、W编号与待验内容。
- Windows的WIN-DONE要求真实代码/接线、适用Windows检查通过、Apple专属样本已写并登记；不等于Swift已编译或真机通过。Mac仍0/12，449项XCTest仅是源码方法数，另有17项Native图片测试待Mac；发现缺陷必须重开对应项。

### 代码地图与架构边界

以下路径相对仓库根目录，用于快速定位，不要求一开始通读整个项目。

| 职责 | 现有入口 | 接续时不可破坏的约束 |
|---|---|---|
| Android宿主 | `app/`、`shared/src/androidMain/` | 本轮默认不改宿主/服务/协议平台适配、版本及打包脚本；若确有必要，先说明原因和验证范围 |
| 共用规则/页面 | `shared/src/commonMain/kotlin/com/ztransfer/` | 业务判定只保留一份；原Android共享调用语义不变，common不持有Apple对象 |
| 正式iOS入口/会话 | `iosApp/ZTransfer/ContentView.swift`、`UI/CameraWorkspace.swift`、`Diagnostics/CameraHandshakeProbe.swift` | Probe名称是历史遗留，现已是Release和Debug共用的单一连接所有者，不要因位于Diagnostics就另造一套会话 |
| 相机目录/自动接纳 | `Network/CameraWiFiConnection.swift`、`CameraCatalog.swift`、`CameraAutomaticTransferCoordinator.swift` | 复用同一事件观察流、目录基线、命令准入及实际原片队列；不额外订阅抢走事件，不复制队列 |
| 原片队列/页面/保存 | `Network/CameraOriginalQueue.swift`、`UI/OriginalFilesPage.swift`、`UI/OriginalQueuePage.swift`、`Storage/ProviderOriginalStore.swift` | 真实完成/跳过/失败决定界面状态，页面不模拟成功；保存目标和原片所有权保持单一 |
| 共用新增/队列规则 | `shared/.../viewmodel/NewCameraObjectPolicy.kt`、`NativeOriginalTransferQueue.kt`、`TransferQueuePolicy.kt` | 不为iOS另写去重、双卡身份、入队、重试规则；这里的省略号指commonMain/kotlin/com/ztransfer |
| Apple桥接/测试 | `shared/src/iosMain/`、`iosApp/ZTransferTests/`、`iosApp/ZTransfer.xcodeproj/project.pbxproj` | 新Swift文件和测试要注册；common metadata检查不等于Native导出和Swift类型检查 |

“Android没改”必须说清比较基线：`ca00994..7dd094d`这一批未改Android宿主/平台/打包脚本；**整个iOS分支相对旧master包含Android共享化改造**，不能把局部无差异说成整个分支从未改Android。

### 历史W06收口（6ab3302）

- 已核对真实链路：连接事件→CameraCatalog新增媒体→CameraAutomaticTransferCoordinator→CameraOriginalQueue/共享队列→原片保存发布→唯一队列订阅→文件页/队列页。原订阅已覆盖自动入队反馈，不增加通知回调、第二队列或第二订阅；本次仅在会话发布快照前补连接ID/序号保护。
- 新增6项CameraNetworkTests组合样本：首次旧片不入队并连拍/重复事件/双卡去重；扫描补漏；延后并切换真实provider目录；手动暂停后显式开始；发布失败保留完整原片、重试不再下载；已有原片跳过。复用真实PTP下载、队列、沙盒和provider保存/索引，逐字节核对目标文件；相机线缆/目录数据和系统目录授权使用fixture，失败注入使用已有目标探针。
- 页面原片索引必须由实时队列订阅触发刷新，测试不得直接塞最终成功快照。Apple样本验证实际索引输入；徽标谓词复用NativeFilesPageModelTest覆盖的shared规则，不为测试新增公开业务API。新增testAutomaticLoop*六项尚未编译/运行，Mac需执行并真机核对连拍、暂停、切目录、重试和徽标。
- W06只验收自动传图数据/状态闭环。完整飞入动画、胶囊/空间转场、触感及工作区布局仍属W24，不宣称1:1视觉效果已完成，不重复计分。
- 上述W06后续已推进W07—W10，当前证据见下方；下一项改为W11，不重造连接所有者，保留7dd094d与6ab3302审计修复。

### 历史W07—W10收口（已推送e5dbadb；后续见下一节）

- 历史实现基线6ab3302；W07—W10已提交并推送为e5dbadb。完整实现、存储职责、恢复路径及Mac场景见 [连接与相机档案验收说明](./iOS连接与相机档案验收说明.md)。
- Android本轮**不是零源码变化**：仅HomeScreen原连接卡片/WifiModeTabs提取到shared，Android保留窗口/时钟/资源适配及所有原调用。home_card_extraction.py验证整个Android文件和整个公共卡片；未改Android协议/服务、版本或打包脚本。
- W07正式首页接同一卡片、三语静态文案、AP/STA模式记忆及配对完成非ready反馈；W08补热点/权限/默认地址恢复；W09补实际Wi-Fi/指定接口与ready远端地址历史；W10收口独立档案、部分失败、损坏恢复和版本职责。
- 最终串行Gradle：BUILD SUCCESSFUL in 3m15s；common metadata、shared/app Debug测试、Android Release Kotlin编译、shared/app Debug Lint通过。716项shared+317项app=1033项测试零失败/错误；shared Lint0问题，app0错误/179 Warning（保留既有提示）。
- 325项Python、工程结构、原UI守卫、卡片精确提取、git diff --check通过。42个App Swift/8个测试文件；410项XCTest源码已注册但未运行，17项Native图片样本仍待Mac。此前本轮W07及W08的两次Gradle已结束，未并行构建，未打包APK。
- 下一项W11：复用现有home状态与会话所有者，补完整连接时间线、成功动画、取消/失败/断开/重试反馈及互斥；不要重新造发现、档案、队列。W12—W15 STA-direct、W24队列动画、W39跨页错误三语仍未完成，不能因W07—W10结项顺带计分。


### 历史W11—W20（基线e5dbadb，已提交推送ad101d5）

- W11—W20均达到Windows门槛，本轮目标20/50已完成，下一项W21等待后续指令。最新串行Gradle BUILD SUCCESSFUL in 2m50s：744项shared+317项app=1061项测试零失败/错误，common metadata、Android Release Kotlin编译及shared/app Debug Lint通过；shared Lint0问题，app0错误/179 Warning。未打包APK。
- 340项Python、工程结构、原UI及完整提取守卫、git diff --check通过。AndroidX 1.3.7实际解码器与共享实现3213个TIFF/JPEG对照样本通过。42个App Swift/8个测试文件、430项XCTest已登记但未运行，另有17项Native图片测试待Mac；这些结果不代表Swift或Native编译通过。
- Android本轮有三处受控提取：HomeScreen原纯时间函数/常量；NikonCamera原JPEG头/MPF/RAW探针/QuickTime日期纯解析；CameraViewModel原缩略图裁黑边算法。home_card_extraction.py、sta_media_extraction.py、thumbnail_crop_extraction.py对照完整宿主/公共文件；原平台IO与调用语义保留。未改Android网络收发、服务、版本或打包脚本；共享填充队列新增API不改变Android旧调用。
- W12—W14接实际能力证据、direct目录和既有下载执行器；W15—W19接FHD/MPF/RAW/视频缩略图、EXIF对照及有界解码；W20接每20项临时扫描批次、边扫边填、事件失效和失败回滚，完整目录基线仍最后提交。实现边界及8组Mac场景见[传图预览与扫描验收说明](./iOS传图预览与扫描验收说明.md)。多选/工作区等W21之后的余项不顺带计分。

### 历史W21—W30（已推送8594187）

- 此历史检查点达到30/50，现已推进40。任务描述已按Android真实代码纠正：W21没有独立相机复选框全选模式，实际是单张/日期/连拍组入队；W23不自增相机预览分享/删除按钮；W25显示实际速度/耗时，不自造ETA。50项分母不变，详见[工作区与原片交付验收说明](./iOS工作区与原片交付验收说明.md)。
- W21—W25接同连接浏览恢复、真实批量身份/回执、共享完整预览、原胶囊/飞入/空间转场和速度/断线反馈；W26—W30接实际设置/帮助/版本/源码/隐私、目录名称与显式修复、分域偏好备份恢复、单项/批量PhotoKit及Share/Files原片导出。系统回执不冒充接收方持久保存，部分Files回执不虚构逐项成功，不自动重试或删原片。
- Android本批不是零源码修改：仅FileListScreen原胶囊/飞入、MainActivity原FilesQueueWorkspace完整纯UI提取。queue_workspace_extraction.py、workspace_transition_extraction.py严格验证整个宿主及公共文件；Android原调用/资源/lifecycle/服务/协议/平台IO不变，版本和发布脚本未改。新增固定指纹守卫不替代历史守卫；今后修改需精确接续，不能任意刷新旧指纹。
- 最终串行Gradle BUILD SUCCESSFUL in4m31s：756 shared+317 app=1073项测试零失败/错误/跳过；common metadata、Android Release Kotlin编译和两模块Debug Lint通过。shared Lint0问题，app0错误/179 Warning/8 Hint。346项Python、工程结构及原UI守卫通过，未打包APK。
- 42个App Swift/8个测试文件、437项XCTest方法存在但未执行，17项Native图片测试仍待Mac；本批新增7项XCTest。不能据此称Swift/Native编译、系统授权或1:1视觉效果已通过。验收说明按W21—W30列出Mac操作场景；缺陷需重开对应W项。

### 工作方式与验证边界

- 最新用户要求已完成：40提交后继续到50；40已提交f993e8e，W41—W50本次最终提交。下一步是Mac验收，不再推进额外Windows功能。
- 早前多agent授权不作为默认方式；当前优先单agent节省额度。以后若重新明确使用多agent，按实际并发上限和文件所有权分工，不各自运行Gradle或提交推送。
- 最新构建要求是“允许构建验证，但不能同时起多个构建”。先前“不要构建/等20或50项再构建”已被替代，不应继续套用。按风险做适用验证，不必仅因换窗口重复一遍相同全量构建。
- 遵守根目录AGENTS.md：Gradle从可访问用户缓存/镜像的主机环境运行，至少预留240秒、只允许一个构建；超时先检查原进程，不能直接再起一轮。以BUILD SUCCESSFUL/FAILED为准。上次工具链为`D:\dev\jdk-17`和`D:\dev\android-sdk`，使用前确认存在；不提交本机路径配置或擅自升级依赖。
- 可用源码检查：`python -B -m unittest discover -s iosApp/scripts -p 'test_*.py'`、`python -B iosApp/scripts/check_structure.py`、`python -B iosApp/scripts/check_shared_ui_migration.py`、`git diff --check`。旧源码守卫的精确逆转换是历史基线保护，不得用宽泛替换/跳过断言来“修绿”；新接线必须另有当前契约和行为样本。
- 最近验证基线7dd094d：709项shared+317项app=1026项测试通过；314项Python、工程结构和原UI守卫通过；shared/app Debug Lint均0错误（app有179 Warning/11 Hint）；42个App Swift、8个XCTest文件、393个方法存在但未执行，另有17项Native图片测试待Mac。新改动需新证据，不套用历史PASS。
- 历史W06（6ab3302）：318项Python及结构/原UI守卫通过，399项XCTest未运行；当批未改Android/shared/打包脚本且未重跑Gradle。不能将此局部无改动说明套用于本轮W07卡片提取。
- 不自动打包APK。用户明确要Debug包时只用`dist-debug/build-debug.bat`，正式Release才用`dist/build.bat`；本轮不擅改版本、签名、发布脚本、服务器或上传商店。
- 之前确认的推送已完成，不能把一次确认解读为今后无条件推送。后续按当前用户请求与工具权限执行提交/推送，提交说明写清实现、检查和未验边界；不强推、不自动合回master。
- 不用“完美/绝对不影响/一次上Mac必成功”作交付结论。用户曾真机测试Android有线和STA无异常，是历史证据，不能代替未来最终三连接回归。Apple编译、系统授权和真机传图依据[Mac首次操作指南](../测试与验证/iOS首次Mac操作指南.md)及M01—M12另行验收。

每次交接结束前更新本入口的代码基线/下一项、主表及已有拆分表的一致状态、测试数量与是否执行、未提交内容和具体阻塞。文档修订本身不增加功能进度。旧[实现任务清单](./iOS实现任务清单.md)中的批次说明仅按需追溯，不要把旧TODO或旧百分比覆盖当前事实。

## 进度口径与当前数值

> 2026-09-08审计完成：实现检查点`8503823`和审计修复`7dd094d`均已提交并推送至`origin/research/ios`。唯一一轮Gradle串行BUILD SUCCESSFUL，1026项Kotlin/Android测试、314项Python、结构/原UI守卫通过；393项XCTest未运行。P01—P50只是历史实现子项，不能当成用户要求的W01—W50主项，详见[批次](./iOS并行实现批次.md)及[审计记录](./iOS并行50项审计记录.md)。

- **Windows 剩余任务：50 / 50 个主项完成，已得50 / 50分，收尾进度100%。** Windows实现/检查结束；Mac仍0/12。
- **延续此前口径的总计划进度：100%。** 固定公式80 + 20 × 已完成分 / 50；不能按历史百分比推算剩余工作量。
- 80%是此前的粗估，不是重新审计得到的精确完成率；它仅作为冻结的历史计划刻度，不能据此推算剩余工时或风险。今后可核对的主指标是上面的完成项数/总分。
- 第58批自动入队接收、第59批事件记录已包含在历史基准，不重复计分。它们各自完成了真实子步骤，但没有完成自动传输闭环；此前进度没变是没有建立计分表，并不是这些工作没价值。
- Mac/真机另计 **0 / 12 项**；暂缓功能另表。它们不混进Windows分母，也不能在Windows完成时被标成已验收。
- 建表不计分；现已完成W01—W50。Windows的100%仍只表示本轮传图范围在Windows能做的实现和检查完成，不等于iOS已编译、可发布或与Android真机完全等价。

### 2026-09-12 Android 基线同步与 iOS 未完成项

本次按实际仓库状态重新核对：`master` 当前为 `12e3c4e`（已合并并推送 iOS 研究分支），`origin/master` 与之同步；`research/ios` 当前为 `09f647b`，工作区干净。下面的 Android 功能已经进入共同产品基线，但 iOS 尚未实现或验收，不计入 W01—W50 的 Windows 分数。

| Android 已提交能力 | Android 证据 | iOS 同步缺口（当前仍未完成） |
|---|---|---|
| 两处滤镜拨轮长按打开分类选择 | `dcc84f7`；共享分类包含全部、收藏、风景、人像、黑白、胶片/复古、电影感、色彩等；分类内收藏置顶，收藏分类只显示收藏；选中后同步拨轮、强度和预览 | iOS 原生滤镜拨轮长按入口、分类列表、收藏持久化/置顶、筛选后选择回写、强度与预览同步、设置和照片工作台两处复用同一套规则均未完成；帮助文案也要同步为“长按照片滤镜拨轮：按分类选择滤镜”，并统一使用“拨轮” |
| 手机照片工作台批量照片效果 | `e8e429b`；沿用原选择器并支持多选，横向滑动预览；生成/保存按钮显示选中数量或“生成中 3/12”；两个并发 worker；失败继续、原片保留、完成后状态回收；复用队列数量动画和 STA 按钮文字转场 | iOS 需要 PHPicker 多选、横向预览分页、统一效果参数、批量导出与 PhotoKit/Files 回执、固定两路并发、失败继续和原片安全策略、按钮状态/数量动画；不增加停止按钮；未完成 |
| 监看取景器反挤压 | `e25a31e`、`1a12d60`、`c07159a`、`e84ed51`、`4be616f`、`7f76531`、`cb296f5`、`ff2188d`；按钮点击循环 1.0/1.3/1.5/1.8/2.0，默认显示图标；按钮位于斑马纹右侧且尺寸稳定；画面和网格/斑马纹/对焦标记按真实横向缩放对齐 | iOS 需要对应的取景器控件、点击循环与默认图标、真实画面横向缩放、网格/斑马纹/对焦标记对齐、横竖屏布局和真机验证；未完成 |
| 术语与帮助提示 | `dcc84f7` 及后续字符串修订；应用内“波轮”统一为“拨轮”，两处灯泡均说明长按分类选择 | iOS 本地化资源、设置/工作台灯泡入口和无障碍标签尚未逐项同步；未完成 |

除上述新增同步项外，原 iOS 主线剩余工作仍包括：M01—M02 的 Mac 工程编译、模拟器测试和全部 XCTest/Native 图片测试；M03—M07 的 AP/STA 真机传输、预览、系统 Photos/Files、后台/断网/断电等异常验收；M08 的正式工作区、旋转、安全区、转场、大字号、VoiceOver 与性能验收；M09—M12 的签名、隐私、归档、TestFlight、发布资料和最终平台差异确认。GPS（IOS-G01—G04）、会员/支付（IOS-L01—L03）、更新与发布（IOS-L04—L05）、测试收口（IOS-Q01—Q06）以及原先暂缓的完整照片效果（IOS-E01—E04、IOS-U08）仍不能标成完成。

这次记录只更新事实和待办，不把 Android 的提交号当成 iOS 已实现证据，也不把 Windows 的源码检查当成 Apple 编译或真机通过。后续 iOS 实现应优先复用并补齐 common 中已有的滤镜分类/收藏与批量效果策略，再把反挤压的数值与显示规则整理为可复用规则，分别接入 SwiftUI/CMP 原生界面，并为每一项补 Mac/真机证据。

#### 本次 Windows 可完成子任务（2026-09-12）

| 子任务 | 已完成内容 | 证据 | 剩余 |
|---|---|---|---|
| iOS 滤镜目录原生适配 | `NativePhotoFilterCatalog` 增加供 Swift 使用的稳定标量元数据接口；新增 `PhotoFilterCatalogStore`，统一分类、收藏顺序、收藏分类、强度归一化和 UserDefaults 持久化；新增 Xcode 源码与 XCTest 注册 | `NativePhotoFilterTest` 新增目录元数据覆盖；共享测试目标编译通过；`iosApp/scripts/check_structure.py` 通过，当前 XCTest 已登记并明确待 Mac 实际执行 | iOS 两处实际拨轮长按 UI、滤镜选中回写、强度/预览接线和 Apple 编译/真机证据仍待完成；因此 IOS-E02/IOS-U08 不计完成 |
| iOS 共享滤镜选择面板 | 新增 `PhotoFilterWheelLauncher` 与 `PhotoFilterPickerView`：长按拨轮打开，左侧分类、右侧滤镜卡片；收藏置顶、黄色星标、选中高亮；选择一次性回传滤镜身份与当前强度；已注册 Xcode 主目标 | `iosApp/scripts/check_structure.py` 通过；`PhotoFilterCatalogTests` 增加身份/强度原子回传覆盖；共享 `NativePhotoFilterTest` 定向测试 `BUILD SUCCESSFUL`；Swift/XCTest 仍待 Mac 实际编译运行 | 设置窗口和照片工作台的真实拨轮宿主、预览渲染回写及两处无障碍/动态语言接线仍待完成；本项只完成共享 UI 面板，不计完整照片效果项 |
| 反挤压共享策略 | 新增 `DesqueezePolicy`，统一 1.0/1.33/1.5/1.8/2.0 循环、默认图标态、1.33 显示为 1.3、比例计算和非法值归一化，供 iOS 接入 | `DesqueezePolicyTest` 针对性测试 `BUILD SUCCESSFUL`；未改 Android 页面和取景器实现 | iOS 取景器按钮、真实画面缩放、覆盖层对齐、横竖屏布局和真机证据仍待完成 |
| iOS 反挤压控件适配 | 新增 `IOSDesqueezeControlModel` 与固定尺寸 `IOSDesqueezeButton`；点击循环复用 shared policy，默认显示图标，激活后只显示紧凑数值，提供无障碍名称/值 | 新增 `DesqueezeControlTests` 覆盖循环、1.33 显示、非法值归一化和回到默认；`iosApp/scripts/check_structure.py` 通过；Swift/取景器真实画面接线待 Mac | 正式 iOS 取景器页面接入、真实画面横向缩放、网格/斑马纹/对焦标记对齐和横竖屏布局仍待完成 |
| iOS 批量效果并发协调 | 新增 `PhotoEffectsBatchCoordinator`，固定选择快照、最多两路 worker、完成/成功/失败计数和失败继续；渲染与保存通过闭包注入，后续接共享滤镜内核与 PhotoKit | 新增 XCTest 覆盖空选择、失败继续、每项只处理一次和并发峰值不超过 2；`iosApp/scripts/check_structure.py` 通过，当前 XCTest 已登记并明确待 Mac 实际执行 | iOS PHPicker 多选、横向预览、按钮状态动画、实际渲染/导出/PhotoKit 回执仍待完成 |
| iOS 工作台批量状态模型 | 新增 `PhotoEffectsBatchSession`，固定选择快照、去重并保留选择数量；横向预览索引循环；生成中显示 completed/total，完成后显示 saved/failed；复用两路并发协调器且不提供停止按钮 | 新增 XCTest 覆盖选择去重、首尾循环、固定分母、失败继续和最终统计；`iosApp/scripts/check_structure.py` 通过，当前 XCTest 已登记并明确待 Mac 实际执行 | PHPicker 多选桥接、真实缩略图分页、滤镜参数/预览接线、导出与 PhotoKit/Files 回执仍待完成 |
| iOS 工作台系统选图与预览容器 | 新增 `PhotoEffectsPicker`：系统 `PHPicker` 图片多选、不限数量、保留顺序并复制临时文件；新增 `PhotoEffectsPreviewPager`，横向分页绑定同一预览索引；生成按钮文案复用 session 的“生成中 x/y”状态 | `iosApp/scripts/check_structure.py` 通过，新增 Swift 文件已注册；Apple PhotosUI 编译、真实授权和大批量内存行为待 Mac | 工作台正式页面接线、渲染结果展示、PhotoKit/Files 保存回执和错误提示仍待完成 |
| iOS 灯泡帮助接线 | 新增 `PhotoEffectsHelpModel`、`PhotoEffectsHelpButton` 与 `PhotoEffectsHelpCard`，两处宿主共用 shared 三语文案，统一无障碍提示和毛玻璃按钮样式 | `iosApp/scripts/check_structure.py` 通过，Swift 文件已注册；shared 文案测试已通过；Swift 本地化/页面接线待 Mac | 设置窗口和照片工作台正式入口接入、动态语言刷新场景仍待完成 |
| iOS 工作台预览与滤镜同步容器 | 新增 `PhotoEffectsPreviewStore` 与 `PhotoEffectsWorkbench`：多选后横向预览，滤镜身份/强度变更取消旧渲染并刷新当前图片，批量状态按钮与统一帮助/拨轮入口复用；保存逻辑通过闭包注入，不伪造成功 | `iosApp/scripts/check_structure.py` 通过，54 个 App Swift 文件已注册；渲染任务竞态和 PhotosUI/SwiftUI 编译待 Mac | 正式入口挂接现有 iOS 导航、真实保存实现、设置窗口第二处宿主接线及真机视觉验收仍待完成 |
| iOS 批量滤镜导出与图库保存 | 新增 `PhotoEffectsExportService`，从原图读取、调用 shared 内核导出至私有 JPEG，保留源属性并通过 `PhotoLibraryImporter` add-only 写入；导出像素上限 32MP，超限明确失败；同时暴露可交给 Files/分享的临时成片句柄 | `iosApp/scripts/check_structure.py` 通过；导出服务已注册；Apple ImageIO/Photos 回执、真实权限和大图内存行为待 Mac | Apple ImageIO/Photos 回执、真实权限和大图内存行为待 Mac |
| iOS 批量 Files/分享承载 | 新增 `PhotoEffectsDocumentExporter` 与 `PhotoEffectsShareSheet`，系统一次接收多个成片并按复制语义导出/分享；工作台在批量完成后保留每张成片句柄并显示导出到 Files/分享按钮；回调仅使用系统实际回执 | `iosApp/scripts/check_structure.py` 通过；Xcode 主目标已注册；结果句柄替换/清理测试通过；UIDocumentPicker/ActivityController 真机回执待 Mac | UIDocumentPicker/ActivityController 真机回执待 Mac |
| iOS 批量失败项重试 | `PhotoEffectsBatchSession` 记录具体失败资产，完成后只重试失败项，不重复成功项；工作台显示“重试失败 n 张” | 新增 XCTest 覆盖失败资产记录和仅失败项重试；`iosApp/scripts/check_structure.py` 通过；Swift 并发和 UI 待 Mac | 保存结果列表、失败成片分享和正式导航接线仍待完成 |
| iOS 批量结果状态展示 | session 记录成功资产并按原选择顺序发布；工作台显示已保存资产胶囊，重试成功后合并结果；成片句柄按 assetID 替换并在换图/离开时清理 | XCTest 覆盖成功顺序、重试合并及句柄生命周期；`iosApp/scripts/check_structure.py` 通过 | Apple 并发/文件系统回执待 Mac |
| iOS 照片效果统一路由 | 新增 `PhotoEffectsPresentation`、`PhotoEffectsPresentationModifier` 和 `PhotoEffectsEntryButton`；设置页与工作台可共用同一个 sheet 生命周期和生成闭包；默认路由使用工作台内置导出服务以保留成片句柄 | 新增 XCTest 覆盖打开/关闭；`iosApp/scripts/check_structure.py` 通过，ContentView 已挂载路由 | 正式设置浮层已通过 iOS 平台回调调用 `present()`；真机导航验证仍待 Mac |
| iOS 滤镜帮助文案 | 新增 `NativePhotoEffectsText`，为简体中文、繁体中文和英文统一提供“拨轮快速调节”和“长按照片滤镜拨轮：按分类选择滤镜”两条文案 | 新增 `NativePhotoEffectsTextTest` 覆盖三语；未改 Android 资源和页面 | iOS 两处灯泡实际 UI 接线、动态语言刷新和无障碍朗读标签仍待完成 |
| iOS 工作台成片句柄与出口 | 新增线程安全 `PhotoEffectsArtifactSink`，默认批量生成保留每张成片 URL；工作台提供导出到 Files/分享，换图和离开页面自动清理，失败重试替换同一资产旧文件 | `PhotoEffectsArtifactSinkTests` 覆盖替换/清理；`iosApp/scripts/check_structure.py` 通过；本次提交 `a4e0b33` | UIDocumentPicker/ActivityController 真机回执和正式设置宿主导航待 Mac |

本次完成 1 个可独立验收的 Windows 源码子任务：iOS 工作台成片句柄与 Files/分享出口。Android 同步主线仍有 4 个产品项待 iOS 完整接入（滤镜 UI、批量照片效果、反挤压、术语/帮助）；其中滤镜和批量项的 Windows 可实现主体已具备，当前 Windows 可继续内容剩余 0 项；正式设置浮层入口、工作台统一路由和两处帮助组件均已有代码接线，剩余为 Mac/真机编译、授权、动态语言和视觉验收。反挤压的真实画面缩放仍需 Mac/真机验证。共享专项测试已分别通过 `:shared:testDebugUnitTest --tests com.ztransfer.filter.NativePhotoFilterTest`、`:shared:testDebugUnitTest --tests com.ztransfer.protocol.DesqueezePolicyTest` 与 `--tests com.ztransfer.ui.NativePhotoEffectsTextTest`。官方 Mac/真机验收仍为 **12 / 12 项待验（M01—M12）**，本次没有减少该数量。

## 更新规则

1. Windows状态只用 `TODO`、`DOING`、`WIN-DONE`。未拆分主项完成分只能是0或1；保留已有W02/W03拆分记录，主表只累计一次。开工不计分，写完但缺本项检查不计分。后续按原W01—W50主项结项；内部步骤可以细列，但不再另造“50项完成率”或未经确认改分母。
2. 每项WIN-DONE要求：本行全部剩余交付点有实现/真实接线；复用已有shared规则；适用的Windows验证通过；Apple专属测试已写并登记待Mac；证据栏填写代码入口、验证结果、提交号或待提交文件。纯源码检查不能记成Swift编译或真机通过。
3. 每完成一项，**同批更新状态、得分、证据、顶部两个百分比、变更记录**，并向用户报“本次完成Wxx，+0.4，总计划xx.x%，剩余清单n/50”。完成多项累加；子项按所占分数报告（0.5分对应总计划+0.2），同步报告完整主项数与得分；不得等大功能全部完成才给已经独立验收的子项计分。
4. 本项针对性检查包含在本项1分内；W43—W50是跨模块/收口验收，不重复为同一次测试计分。已有实现只补剩余接线/证据，不为复制代码、增加文件或增加测试数量计分。
5. 发现漏项/新回归：登记具体缺口并重新打开所属项（撤回对应分数）。同范围拆分保持原总分；确属新范围则明示变更与重新计算，不能暗改分母、删未完成项凑100%。涉及新能力/外部服务/平台差异的决定先请用户确认。
6. Mac发现返工时，重开对应Windows项；不能因先前达到过100%而隐去缺陷。暂缓不等于完成，恢复暂缓功能须另立范围版本。
7. 本表关联旧ID用于追溯，不改变旧总账“DONE须实际验收”的定义。W50已完成；下一步M01/M02实际Mac编译测试。保留本轮暂缓范围，发现返工回开所属W项。

## Windows 剩余实现及检查（总分50）

每行1分。表中完成条件均指**尚缺的部分**，并共同受上述WIN-DONE证据门槛约束；不得以临时Debug按钮、模拟数据或只返回成功占位。

| ID | 关联旧ID | 剩余交付点与完成条件 | 主要依赖 | 状态 | 得分 | 证据 |
|---|---|---|---|---|---|---|
| W01 | IOS-D01、IOS-D04、IOS-N06 | 首次扫描基线与后续差量：首次旧照片不自动入队；成功的handle枚举成为下一基线；空卡/部分元数据失败按原规则处理，锁定样本 | 已有目录/事件记录 | WIN-DONE | 1 | 第60批：NativeCameraHandleBaseline.kt、CameraCatalog.swift；6项common+4项XCTest源码；966项Kotlin/Android、279项Python及结构/原UI守卫PASS；Apple待验；8484b35 |
| W02 | IOS-D04、IOS-N06 | 新增事件消费：真实读取对象信息，处理Busy/重复/迟到事件，与扫描去重；只报告真正新增媒体，复用原发布规则 | W01 | WIN-DONE | 1 | W02-A/B各0.5均完成；第62批真实AP/标准STA观察者→目录解析→共享发布→同一文件页/缓存；当批977项Kotlin/Android、290项Python及结构/原UI守卫PASS，12项新增XCTest待Mac。后续W03/W04/W05已在7dd094d达Windows门槛，不能套用当批未完成状态 |
| W03 | IOS-D04、IOS-D01 | 删除/属性/存储卡变化：旧页、索引、双卡合并归属、预览缓存正确失效或更新；不把读取失败当删除 | W01 | WIN-DONE | 1 | W03-B补齐CameraCatalog删除/属性/卡槽核对、索引/缓存/页面更新；25项目录XCTest源码（含6项审计竞态）待Mac。1026项Kotlin/Android、314项Python及结构/原UI守卫通过；8503823实现及7dd094d审计修复均已提交推送。 |
| W04 | IOS-D04、IOS-N06 | 事件缺口及扫描竞争：消费已有游标记录；溢出重扫、扫描期间事件追赶、关闭取消、同代校验有完整调度与竞态样本，不另抢通知流 | W01—W03 | WIN-DONE | 1 | 复用唯一事件游标与目录扫描；缺口恢复、稳定版本门控、关闭取消、删除打断补扫与副卡资格转交已接线。25项目录XCTest源码待Mac，现行Windows检查通过；不宣称Swift竞态已运行。 |
| W05 | IOS-T01、IOS-U06、IOS-D04 | 自动传输真实开关：保存/恢复选项并绑定事件到已有入队入口；目录/日期/延后参数取同一有效快照；关闭选项不误补传旧目录 | W02、W04 | WIN-DONE | 1 | 同一偏好文档/共享设置开关→连接所有者→既有自动入队；关闭写失败仍停止本会话。16项自动XCTest待Mac、6项设置common测试已通过；整链路后续W06已完成，视觉转场仍W24。 |
| W06 | IOS-T01、IOS-D04 | 自动传图闭环回归：首次连接→连拍→事件/扫描→原片入队→目标发布→徽标；重复、暂停、切目录、失败重试场景有集成接线与测试 | W03—W05 | WIN-DONE | 1 | 唯一队列订阅接真实入队/终态和原片索引，补会话/序号保护；6项真实队列→provider→页面索引组合XCTest待Mac，徽标谓词复用shared既有测试。318项Python、结构/原UI守卫PASS；视觉动画仍W24。 |
| W07 | IOS-U01、IOS-U03、IOS-U04 | 正式共享首页/连接/文件/队列导航：复用CMP原页面，连接级状态单一所有者；普通用户无需进入Debug探针使用传图 | 既有共享页 | WIN-DONE | 1 | 原ConnectionMethodCard/WifiModeTabs完整提取为shared，Android保留时钟/窗口/资源适配与原调用；严格全文对照PASS。iOS接同卡片、三语、模式记忆和配对完成非ready反馈。1032项Kotlin/Android、322项Python、结构/原UI守卫PASS；401项XCTest待Mac。连接时间线仍W11、完整队列工作区仍W24。 |
| W08 | IOS-N03、IOS-U03、IOS-B03 | AP连接产品流程：热点/系统设置引导、地址与输入校验、权限提示及失败返回；iOS不展示不可用USB入口，Android入口保持 | W07 | WIN-DONE | 1 | 正式AP引导、无互联网说明、权限设置/手动Wi-Fi区别、默认地址恢复和ASCII输入；实际NWPath仅明确localNetworkDenied才报拒权，Wi-Fi不可用不假装ready。新增common/Apple样本；shared串行BUILD SUCCESSFUL，325项Python/工程结构PASS，Apple仍待Mac。 |
| W09 | IOS-N05、IOS-U03 | STA发现补全：历史IP、接口/路由校验、同机多服务去重、显式受控的发现回退、停止/超时/迟到结果；不在开发机擅自扫网段 | W07 | WIN-DONE | 1 | Bonjour按广播实例/域/接口分组，非相机认证；已有显式备用服务及停止/迟到样本保留。连接约束Wi-Fi及指定接口、核对实际路径；真实ready连接提供数字远端地址，核对身份/取消后才存历史。新增地址来源/生命周期XCTest待Mac，325项Python PASS；无自动网段扫描或鉴权回退。 |
| W10 | IOS-N04、IOS-S05、IOS-U03 | 历史相机/配对档案：多身份选择、记忆地址、删除/重新配对、授权身份隔离及版本迁移；明确UserDefaults/Keychain职责，复用既有STA身份 | W07、W09 | WIN-DONE | 1 | 保留既有v1安装身份与单机标记，明确UserDefaults/身份JSON/地址JSON/Keychain职责；启动时历史损坏仍能展示健康配对档案，部分忘记刷新真实信任状态，身份拒绝符号链接。5项新增XCTest待Mac，版本/备份/旧身份隔离原样本保留；325项Python及最终串行检查PASS，详见连接与档案验收说明。 |
| W11 | IOS-N03、IOS-N04、IOS-U03 | 连接全过程页面：发现/配对/连接中/成功动画/失败/主动断开/重试与按钮互斥；取消不会留下假成功或旧连接回写 | W08—W10 | WIN-DONE | 1 | 原Android时间函数/常量原样提取并复用；iOS接真实ready帧时钟、导航幂等、取消/断开/重连与手动打开护栏、发现停止和配对过程反馈。1038项Kotlin/Android、330项Python分别通过，common metadata/结构/原UI与精确提取守卫PASS；414项XCTest待Mac。 |
| W12 | IOS-N04、IOS-D01 | STA-direct能力与模式判定：按Android实际握手/能力证据选择标准或专用路径，明确不可用与回退；不默认所有STA都支持 | 既有标准STA | WIN-DONE | 1 | 显式explore兼容入口；复用STA配对规则；首/中/尾ObjectInfo与64KiB直接读取证据、应用模式失败回退、单卡预取，正常标准入口不变。3项wire样本待Mac；当前共享检查与整文件回归PASS。 |
| W13 | IOS-D01、IOS-N04 | STA-direct目录：对象枚举/读取、跨卡handle重叠和归属映射接共享规则，标准路径不回归，兼容失败保留有效列表 | W12 | WIN-DONE | 1 | NativeCameraCatalogScan显式direct选项复用analyzeStaDirectStorageLayout；公共Nikon索引/文件名/MakerNote/RAW解析接对象头，跨卡别名禁用假筛选，缓存/事件代次保护及失败保留原目录。公共规则10项新增与原Android解析测试PASS，真实STA目录wire样本待Mac。 |
| W14 | IOS-T02、IOS-N04 | STA-direct原片下载：已验证对象读法、大小/偏移/分块/回退与原片完整性接现有执行器，覆盖不支持和异常响应 | W12、W13 | WIN-DONE | 1 | 同一download/命令gate/原片队列，无第二执行器；direct启用共享forcePartial，保持大小查询/64位偏移/分块/首块不支持回退/续传规则，direct返回超请求长度拒绝成功。4项字节与异常wire样本待Mac。 |
| W15 | IOS-D03、IOS-D05 | STA预览专用路径：MPF/部分读取/FHD选择与降级，接现有预览源/优先窗口，不另写共享解析算法 | W12、W13 | WIN-DONE | 1 | 原通道/优先窗口接FHD、LargeThumb及独立MPF范围、EXIF内嵌缩略图；Busy/不支持锁存不同，绝不为预览读整张原片。Apple线包与图片fixture待Mac。 |
| W16 | IOS-D03、IOS-D05 | RAW预览余项：相机/本地嵌入图、选图和降级、裁黑边、坏/缺索引与取消的实际路由完整；原片字节不被修改 | W15 | WIN-DONE | 1 | 相机最小索引缩略图/会话偏移提示/16MiB前缀降级，FHD独立选图，本地复用原索引/描述符读取；裁黑边纯算法全文提取，Android位图IO原位保留。 |
| W17 | IOS-D03、IOS-D05、IOS-S02 | 已有视频文件体验：MOV等缩略图/信息/原片保存分享和预览或系统打开，按Android已有能力对照；不实现遥控录像 | 既有文件/预览源 | WIN-DONE | 1 | 同一预览源接128KiB/8MiB内嵌JPEG与有界AVFoundation首帧；共享QuickTime日期解析，必要时读尾256KiB，保留原片流式保存/分享/系统打开。日期/取消/坏前缀/重试样本已登记；平台解码效果待Mac。 |
| W18 | IOS-E01、IOS-D05 | EXIF剩余兼容：目录占用/RAW嵌入元数据/其它ImageIO字段、非拉丁回退名/日期与区域差异逐项对照；含已有GPS元数据，不含GPS发送 | 既有EXIF共享规则 | WIN-DONE | 1 | 有界RAW内嵌JPEG路由与DateTimeOriginal回退按固定AndroidX 1.3.7实际行为实现，不误读任意MakerNote。3213个实际AndroidX数值/文本/日期/大小端/RAW对照PASS；Apple描述符/ImageIO及真实相机样本待Mac。 |
| W19 | IOS-E01、IOS-D03、IOS-D05 | 图片解码余项：色彩/透明/方向/旋转、坏图与大图限额、缓存身份和跨页来源切换有样本；不重做已完成的基础解码或照片效果 | W16、W18 | WIN-DONE | 1 | 相机网格/原图/FHD保持Android原像素方向，诊断解码单独归一化；裁原尺寸后缩小并保留色彩/透明。有界256MiB图片数据、96M原图像素/32M缩略图像素准入，原片复制仍流式。17项媒体XCTest已登记；真实P3/内存峰值/跨页效果待Mac，不宣称已实测。 |
| W20 | IOS-D03、IOS-D01 | 扫描批次与缩略图填充：扫描中分批可用、日期优先、事件失效/重试、传输及预览让路、页面/连接关闭释放，不等整目录完成才可填充 | W01—W04 | WIN-DONE | 1 | 同一目录每20项发布临时批次，文件页直接展示并增量填充；不提前提交自动接纳基线、不删旧磁盘条目，失败回滚，事件暂停旧批次填充。沿用日期优先/传输预览准入与代次关闭保护。公共回滚/优先级测试PASS，45项真实目录与磁盘填充组合XCTest待Mac；本轮1061项Kotlin/Android、340项Python及结构/守卫PASS。 |
| W21 | IOS-D02、IOS-U04 | 批量准入对照真实网格：单张/日期/连拍组按当前卡槽及筛选入队，保持顺序并防止目录变化或handle重用传错文件；Android无独立相机复选框全选模式 | 既有网格/筛选 | WIN-DONE | 1 | NativeFilesPageModelTest锁定过滤/双卡/组顺序、真实回执与handle重用拒绝；继续复用原网格/共享准入，不造新选择模式；1073项Kotlin/Android通过，Mac场景登记，未提交 |
| W22 | IOS-D02、IOS-S05、IOS-U04 | 跨页浏览状态：同连接卡槽/筛选、日期折叠、连拍展开、滚动和预览返回位置绑定工作区；断开换机不串状态，不把卡槽写成全局偏好 | W07、W21 | WIN-DONE | 1 | NativeBrowseSession + bridge关闭捕获/Probe同connectionId恢复；卡槽不持久化；common同连接/异连接测试通过，新增Apple重建页面样本待Mac，未提交 |
| W23 | IOS-D05、IOS-U04 | 预览正式操作：复用已有导航/返回、原片传输、连拍/旋转/直方图与冻结来源；原Android无预览分享/删除按钮，系统保存分享接W29/W30，不自增相机删除 | W07、W21、W30 | WIN-DONE | 1 | 继续复用完整PreviewOverlay/来源快照/返回和Burst/FHD/EXIF控制，切队列/返回关闭源；原UI/预览守卫和既有规则测试通过，正式Mac场景登记；不造相机删除，未提交 |
| W24 | IOS-U04、IOS-U05 | 队列工作区整合：正式顶栏/胶囊/空间转场/接收动画、触感和暂停提示、预览飞行落点接真实队列；不依赖临时目录按钮 | W07、W22 | WIN-DONE | 1 | 原胶囊/QueueFlightGhost/FilesQueueWorkspace完整提取共用；真实手动回执+唯一队列订阅驱动自动飞入，预览落点/触感同源；全文提取与意图/实际任务测试PASS，视觉待Mac，未提交 |
| W25 | IOS-T04、IOS-U05 | 队列显示余项：按原Android显示速度/字节/耗时（无预测ETA）、错误/跳过/完成/暂停反馈、操作可用性和重试提示；断线后不显示过期运行进度 | W24 | WIN-DONE | 1 | NativeQueuePageModel保留有效速度、准备间隙及断线迟到快照隔离；原卡片/重试/清理规则复用；common速度和断线样本PASS，Mac回前台场景登记，未提交 |
| W26 | IOS-U06、IOS-L04 | 完整共享设置壳：帮助/反馈/版本/源码/隐私入口和页脚；保留已接的外观及照片控件，只接真实入口，不挂Android更新/支付流程 | W07 | WIN-DONE | 1 | NativeProductInformation及首页通用设置：实际Bundle版本、帮助/隐私、仓库链接/既有QQ、共用外观；无Android更新/支付；编译/接线守卫PASS，三语/系统链接待Mac，未提交 |
| W27 | IOS-S01、IOS-T03、IOS-U06 | 正式保存目录卡片收口：真实名称/路径摘要、目标状态/撤权反馈、显式修复或重置未知偏好；复用已完成的安全切换/重连恢复/已有原片复用 | W05、W26 | WIN-DONE | 1 | 真实provider名称及恢复错误、确认沙盒修复走既有idle fence，备份未知偏好且保留授权/原片；common请求/迟到回执PASS，Apple修复样本待Mac，未提交 |
| W28 | IOS-S05、IOS-U06 | 其余传图偏好与迁移：跨页/重启恢复、默认值、未知版本/损坏数据显式恢复、资源/授权身份分工；统一入口，不另存一套同义状态 | W10、W22、W26、W27 | WIN-DONE | 1 | 浏览/外观/模式/传输/目标偏好各自显式备份恢复，正常读不覆盖未来版本；实时外观和请求测试PASS，Apple分域备份/模式恢复样本待Mac，未提交 |
| W29 | IOS-S02 | 正式图库保存：单项/批量PhotoKit导入反馈，RAW/视频不支持时可安全导出原片，拒绝或失败保留原文件；不擅增读图库授权或管理相册能力 | W21、W23 | WIN-DONE | 1 | 已存原片面板按实际索引名/64位大小复制，PhotoLibraryImporter逐项add-only回执；common回执/副本身份PASS，正式批量PhotoKit适配器部分成功XCTest待Mac，原片保留，未提交 |
| W30 | IOS-S03、IOS-S01 | 正式系统分享/Files导出：单项/批量接真实文件，provider副本安全物化，取消/部分成功/失败回执准确；不涉及暂缓的水印资源导入 | W07、W21 | WIN-DONE | 1 | 同面板接单项/最多500项UIActivity/Files(asCopy)，流式私有副本与冻结provider读取、取消和部分回执不假成功；common+源码守卫PASS，逐字节/正式Files部分回执XCTest待Mac，未提交 |
| W31 | IOS-N01、IOS-N06、IOS-T02 | 取消和排空边界：逐条对照Android，能安全排空的事务保持帧同步；必须断开的情况安全关闭并走恢复，不能以无说明的行为差异结项 | 已有命令/下载执行器 | WIN-DONE | 1 | 共享Cancel/同TID排空/32MiB/3秒绝对上限；[逐项证据与Mac场景](./iOS生命周期与恢复验收说明.md)，Windows通过/Apple待验 |
| W32 | IOS-N01、IOS-N06、IOS-S04 | 断线/切网恢复编排：关闭旧代、释放读写、确认路由及相机身份后重建，旧回调不能污染新队列；不擅自重启用户已暂停的传输 | W10、W11、W31 | WIN-DONE | 1 | 代际与最终ready核对，显式重连不自动开始；[逐项证据与Mac场景](./iOS生命周期与恢复验收说明.md)，Windows通过/Apple待验 |
| W33 | IOS-S04、IOS-U10 | 前后台与宽限：scene变化、有限后台任务/expiration、安全停机/回前台提示与恢复、常亮释放；不能承诺锁屏无限传输 | W31、W32 | WIN-DONE | 1 | 有限后台额度/expiration安全关停/成对释放；[逐项证据与Mac场景](./iOS生命周期与恢复验收说明.md)，Windows通过/Apple待验 |
| W34 | IOS-T05、IOS-T03、IOS-S05 | 恢复检查点：待传/完整原片/未完成片段的身份及保留清理规则、相机/卡/文件变化校验、崩溃后可解释恢复；新增iOS能力与Android原行为分开记录 | W31—W33 | WIN-DONE | 1 | 512KiB/500行解释性记录，未知数据保留，无旧句柄续写；[逐项证据与Mac场景](./iOS生命周期与恢复验收说明.md)，Windows通过/Apple待验 |
| W35 | IOS-T03、IOS-S01、IOS-Q04 | 存储异常闭环：磁盘不足/同名竞争/provider移动或撤权/云端文件不可用/复制中取消，错误可恢复且只清理本次临时文件，不丢原片 | W27、W29、W30、W34 | WIN-DONE | 1 | 磁盘/权限/来源/发布错误分类与原片保留；[逐项证据与Mac场景](./iOS生命周期与恢复验收说明.md)，Windows通过/Apple待验 |
| W36 | IOS-U10、IOS-D03、IOS-Q03 | 性能及所有权收口：长列表/大量事件/大图/连续传输、内存压力、缓存上限、后台任务与订阅释放；Windows可测规则及压力样本落地，Apple指标待M08 | W06、W20、W24、W33 | WIN-DONE | 1 | 两页图片epoch/内存释放，不动队列目录；[逐项证据与Mac场景](./iOS生命周期与恢复验收说明.md)，Windows通过/Apple待验 |
| W37 | IOS-U10 | 适配交互：安全区、键盘遮挡、系统返回、横竖屏/尺寸变化、空列表/无相机/拒绝权限的布局与恢复路径；源码和场景齐备 | W07、W23—W27 | WIN-DONE | 1 | safeDrawing/IME/FlowRow/长列表滚动与适配场景；[逐项证据与Mac场景](./iOS生命周期与恢复验收说明.md)，Windows通过/Apple待验 |
| W38 | IOS-U10 | 无障碍：动态字号、VoiceOver标签/焦点/动作、触控可达性及状态可读性接正式页面，准备实际朗读/大字号验收 | W37 | WIN-DONE | 1 | 文件名标签/低频播报/48dp与VoiceOver场景；[逐项证据与Mac场景](./iOS生命周期与恢复验收说明.md)，Windows通过/Apple待验 |
| W39 | IOS-U02、IOS-U06 | 跨页资源与设置一致性：剩余三语文本/帮助/错误、原控件/触感开关、默认值与语言切换全面接线；不翻译另一套业务含义 | W11、W23—W28、W37 | WIN-DONE | 1 | 当前语言稳定错误码与原设置源三语接线；[逐项证据与Mac场景](./iOS生命周期与恢复验收说明.md)，Windows通过/Apple待验 |
| W40 | IOS-B03、IOS-L05 | 传图版权限与隐私源码：Info.plist/entitlement/使用说明与实际网络/照片用途一致，拒绝/撤销/设置返回可用；暂缓能力无误触发，不把超时当拒权 | W08、W29、W33 | WIN-DONE | 1 | 网络/add-only相册三语用途，无暂缓权限入口；[逐项证据与Mac场景](./iOS生命周期与恢复验收说明.md)，Windows通过/Apple待验 |
| W41 | IOS-B04 | 诊断日志与导出：阶段/机型/错误有界记录、脱敏、清理和显式分享；不暴露照片GPS、身份凭据或完整敏感路径 | W11、W25、W32、W35 | WIN-DONE | 1 | TransferDiagnosticLog正式首页256条白名单/查看/清理/冻结分享；Common及Swift脱敏样本；[最终交接包](../测试与验证/iOS传图版最终交接与验收包.md) |
| W42 | IOS-L04、IOS-L05 | 传图版发布材料源码准备：已有AppIcon/启动/版本核对、PrivacyInfo和实际API声明、真实更新/反馈链接及商店材料草稿；无真实链接则登记外部待配置，不伪造 | W26、W39、W40 | WIN-DONE | 1 | 品牌RGB AppIcon像素等价、三类真实隐私理由、版本1.81(54)/启动/反馈核对，公开URL待用户配置；[最终交接包](../测试与验证/iOS传图版最终交接与验收包.md) |
| W43 | IOS-Q03、IOS-Q05 | 逐功能对照矩阵：覆盖当前Android USB/AP/STA可见行为及iOS AP/STA对应入口/默认值/错误；平台已确认差异与本轮暂缓项明确列出，发现缺口回开所属项 | W01—W42 | WIN-DONE | 1 | 31项功能矩阵覆盖Android USB/AP/STA及iOS标准/direct入口、默认值/错误/暂缓差异；[最终交接包](../测试与验证/iOS传图版最终交接与验收包.md) |
| W44 | IOS-N02、IOS-Q02、IOS-Q03 | 跨模块金样回归：协议顺序、扫描/事件、过滤/选择、队列/重试、JPG/NEF/MOV/大文件/双卡/空卡的向量与原片哈希断言；Windows可执行部分实际通过 | W43 | WIN-DONE | 1 | 真实ObjectInfo→双卡归并→FIFO失败重试→原片匹配金样；3213 AndroidX样本通过，文件字节样本待Mac；[最终交接包](../测试与验证/iOS传图版最终交接与验收包.md) |
| W45 | IOS-Q03 | Android保护总回归：按最终差异运行必要common/Android测试、Debug/Release编译、Lint、Manifest与依赖/原UI守卫，记录相对基线结论；不冒充三连接真机已验 | W44 | WIN-DONE | 1 | 1085单测、两配置完整源码编译/Lint及原UI守卫通过；108/131/120模块0变化，Manifest/平台未改；[最终交接包](../测试与验证/iOS传图版最终交接与验收包.md) |
| W46 | IOS-B01、IOS-B02、IOS-Q01 | Apple首次验收工程准备：所有新源码/资源/测试注册、Swift/Native边界样本、串行Mac脚本/命令/产物记录齐备，Windows结构检查通过；实际编译归M01/M02 | W01—W42 | WIN-DONE | 1 | 45 App Swift/8测试文件/449 XCTest注册，串行脚本补两架构Debug/Release，报告记录commit/dirty；[最终交接包](../测试与验证/iOS传图版最终交接与验收包.md) |
| W47 | IOS-Q05 | 架构终审：共享规则单实现、平台对象不进common、所有者/取消关系清楚，无第二套产品UI/模拟成功/死按钮/泄漏；每项映射入口和证据 | W43、W46 | WIN-DONE | 1 | 唯一会话/事件/队列观察，common无平台对象；终审修复内嵌队列图片、Int32计数、帮助滚动与配对三语；[最终交接包](../测试与验证/iOS传图版最终交接与验收包.md) |
| W48 | IOS-L05、IOS-Q01、IOS-Q03 | 打包流程保护：核对Android debug/release脚本、产物路径及版本未被iOS改造破坏，补iOS归档/签名变量检查和可复现说明；不擅自打包或发布 | W42、W45、W46 | WIN-DONE | 1 | Android Debug/Release脚本及路径/版本不变；Mac归档参数校验/默认只计划/禁止上传，源码测试通过；[最终交接包](../测试与验证/iOS传图版最终交接与验收包.md) |
| W49 | IOS-Q02、IOS-Q04、IOS-Q06 | Mac/真机交接包：12项验收所需设备/夹具/操作/期望/日志和已知差异齐全；剩余外部配置单列，证据入口可查，任务不会到Mac再重新盘点 | W43—W48 | WIN-DONE | 1 | 十二项M验收设备/夹具/操作/期望/日志/哈希和外部账号URL要求写入独立交接包；[最终交接包](../测试与验证/iOS传图版最终交接与验收包.md) |
| W50 | IOS-Q05、IOS-Q06 | Windows最终收口：核查W01—W49全部完成、最终差异与测试证据一致、无本轮隐藏TODO/未接线；更新交接结论并按授权提交，仍明确Mac待验 | W01—W49 | WIN-DONE | 1 | 50项计分/链接/提交范围核对通过；1085单测+366Python+3213EXIF金样，最终Android保护及45Swift/449XCTest注册通过；本次提交，Mac0/12 |

## W03拆分跟进（原1分拆为0.5+0.5，不增加总分）

历史拆分原因：当时iOS完整扫描只把合并后主行的ObjectInfo带出，删除核对需要保留被合并的备份别名；先完成可独立测试的全索引与原Android共享核对接口，再接Apple事件、IO和缓存更新。现A/B均已达Windows门槛，主表只累计子项得分一次。

| 子项 | 剩余交付点/完成条件 | 分值 | 状态 | 已得分 | 证据 |
|---|---|---|---|---|---|
| W03-A | 完整扫描和新增发布保留所有别名及稳定读取顺序；提供复用原删除/双卡重建与idle handle基线规则的Native入口，失败枚举不代表空卡；共享测试、真实Apple扫描用例源码和Windows检查通过 | 0.5 | WIN-DONE | 0.5 | 第63批：NativeCameraCatalogScan/NativeCameraHandleBaseline/NativeCameraCatalogReconciliation、CameraCatalog；10项新增common、3项新增XCTest源码；987项Kotlin/Android、298项Python及结构/原UI守卫PASS；本次提交，Apple待验 |
| W03-B | 删除/对象属性/存储卡事件接真实核对及对应页面/索引/缓存更新；移除主卡保留副卡、失败保留旧数据、同代取消和门控有样本；对照Android原属性处理并记录平台适配边界，Windows检查通过 | 0.5 | WIN-DONE | 0.5 | 8503823实现、7dd094d审计修复，均已推送；25项目录XCTest样本待Mac。1026项Kotlin/Android、314项Python、结构/原UI守卫通过；本行计入W03的1分，不再额外累加 |

## W02拆分跟进（原1分拆为0.5+0.5，不增加总分）

拆分原因：事件接入需要复用的新增判定/双卡发布/重试常量原在Android ViewModel内部，先做有Android实际调用与基线对照的共享提取，再做Apple IO/调度接线；两者可独立验收。W02主表得分等于下表已得分之和，统计总分只加主表一次。

| 子项 | 剩余交付点/完成条件 | 分值 | 状态 | 已得分 | 证据 |
|---|---|---|---|---|---|
| W02-A | 提取并由Android实际调用原新增handle准入、逻辑去重/双卡合并发布、原批量/合并等待/重试节奏；组合对照旧算法与完整旧主体守卫通过 | 0.5 | WIN-DONE | 0.5 | 第61批：NewCameraObjectPolicy.kt、CameraViewModel.kt；7项common覆盖399组发布/1197组准入；973项Kotlin/Android、283项Python、结构/原UI守卫PASS；9a65a60 |
| W02-B | Apple真实事件消费接上述shared入口：同代对象读取、Busy有界重试、重复/迟到/扫描和预览互斥、读取期间移除失效，只有真实新增媒体报告；实际调用链与XCTest场景齐备，Windows检查通过 | 0.5 | WIN-DONE | 0.5 | 第62批：CameraCatalog/CameraWiFiConnection/CameraHandshakeProbe、OriginalFilesPage/CameraPreviewStore；4项新增common实跑，12项新增XCTest待Mac；当批977项Kotlin/Android、290项Python及结构/原UI守卫PASS。该批未计W05/W06；后续W05/W06已WIN-DONE，见各自主项证据 |

## Mac / 真机 / 外部配置剩余验收（独立计数12）

每项完成计1项，当前0/12；只有实际执行及证据齐全才算通过。Windows只准备这些验收的代码/场景（W46/W49），不能拿准备工作替代下表通过。

| ID | 关联旧ID | 验收交付点 | 状态 | 得分 | 证据 |
|---|---|---|---|---|---|
| M01 | IOS-B01、IOS-U01、IOS-L05、IOS-Q01 | M1 Mac首次环境/依赖、Native framework、Swift桥接与并发、资源链接、Debug/Release两架构实际编译；错误回开Windows对应项 | 待验 | 0 | — |
| M02 | IOS-B02、IOS-Q01 | iOS simulator commonTest、Native预览/位图、全部XCTest实际执行；7dd094d有393项XCTest及17项Native图片测试待验，后续按源码实际数量更新；保留日志/xcresult，不只统计方法数 | 待验 | 0 | — |
| M03 | IOS-N01、IOS-N02、IOS-N03、IOS-D01、IOS-T01、IOS-Q02 | iPhone+相机AP从授权/连接/浏览/拍照自动传输到保存分享全流程及异常响应，记录机型固件和原片哈希 | 待验 | 0 | — |
| M04 | IOS-N04、IOS-N05、IOS-N06、IOS-Q02 | iPhone+相机STA发现/配对/历史/重连、标准与STA-direct兼容、双卡/空卡/大文件传输；明确支持机型边界 | 待验 | 0 | — |
| M05 | IOS-D02、IOS-D03、IOS-D04、IOS-D05、IOS-E01、IOS-U04 | JPG/NEF/RAW/MOV预览、MPF/EXIF/方向色彩、筛选/连拍/跨卡选择、扫描竞态和高速新增，图像与元数据对照 | 待验 | 0 | — |
| M06 | IOS-T03、IOS-S01、IOS-S02、IOS-S03 | 真正系统picker/Files本地及云provider/PhotoKit/Share：授权平衡、撤权/改目录/同名/错误/取消、原片无损与无误删 | 待验 | 0 | — |
| M07 | IOS-B03、IOS-T02、IOS-T05、IOS-S04、IOS-Q04 | 拒权/撤销、切网、来电、后台/锁屏/终止、断电/换卡/删除、磁盘不足；检查点/安全恢复及原文件完整性 | 待验 | 0 | — |
| M08 | IOS-U01、IOS-U02、IOS-U03、IOS-U05、IOS-U06、IOS-U10、IOS-S05 | 正式工作区和设置截图/手势/转场/大字号/VoiceOver、旋转/常亮/三语；长时传输+预览的内存/线程/温度与性能 | 待验 | 0 | — |
| M09 | IOS-B04、IOS-L04、IOS-L05 | 真实Team/签名/用途及隐私声明核验、日志脱敏、归档/dSYM、安装升级；缺账号/链接/证书须用户提供，不虚填 | 待验 | 0 | — |
| M10 | IOS-Q03 | 最新Android包USB/AP/STA真机回归及原界面/设置/原片哈希对照；历史用户试包不能代替本次最终包验证 | 待验 | 0 | — |
| M11 | IOS-Q05、IOS-Q06 | 回归关闭所有返工项、复核两端需求矩阵、用户确认平台差异与本轮传图版验收；Windows和Mac证据一致 | 待验 | 0 | — |
| M12 | IOS-L04、IOS-L05、IOS-Q06 | TestFlight/商店资料、账号和实际分发/提交前检查，用户明确授权后才上传发布；首个传图版不称完整全功能1:1版 | 待外部配置/授权 | 0 | — |

## 已暂缓 / 已确认不做的范围（不计本轮，不能标完成）

| 范围 | 关联旧ID | 后续跟进边界 |
|---|---|---|
| 两处照片效果 | IOS-U08、IOS-E02、IOS-E03、IOS-E04；IOS-E01/IOS-T01/IOS-S03的效果子项 | iOS 仍暂缓完整效果编辑与导出。Android 已新增的滤镜分类/收藏排序/长按拨轮入口，以及工作台多选、横向预览、两路并发批量生成和状态动画，均需在 iOS 复用共同策略后分别接入；原片/RAW预览、元数据和保存仍在W16—W19/W29—W30 |
| 会员/限额权益/支付 | IOS-U09、IOS-L01、IOS-L02、IOS-L03 | Apple方案重新设计后恢复；不移植微信支付，不改Android/shared现有策略，不擅自解锁或部署服务端 |
| 遥控/监看/相关录像 | IOS-U07、IOS-R01、IOS-R02、IOS-R03、IOS-R04、IOS-R05、IOS-R06、IOS-R07 | 全部对应状态/权限/录制/辅助显示后续；已有相机视频文件传输与保存不随之暂缓 |
| GPS功能 | IOS-G01、IOS-G02、IOS-G03、IOS-G04；IOS-U03的GPS入口子项 | BLE认证、定位/GEO发送、GPS页面/恢复后续；照片原有EXIF含GPS的读取继续 |
| iOS USB Host入口及无限后台运行 | 已确认平台差异，见旧总账 | 本轮不新增USB传图或承诺锁屏无限传输；能力提示和有限后台安全恢复仍须完成，Android对应能力保留 |

## 执行顺序和证据记录

- 优先W01→W02/W03→W04→W05→W06，完成自动传图闭环。
- 随后正式工作区/连接W07—W11，兼容预览W12—W20，浏览/队列/设置/保存W21—W30，恢复与工程余项W31—W42；独立项可提前。
- W43—W50收口；遇到新缺口回开相关项，不用“Apple待验”掩盖Windows尚能实现的内容。
- 旧账本中S01/T03/U06等有滞后的“目录恢复/已有原片复用/日期设置未接”文字：以第53—57批实接证据为准，本表只要求剩余正式入口和异常体验，不把已做内容又列一次开发任务。

| 日期/提交 | 本次完成或重开ID | 得分变化 | 完成分/50 | Windows收尾进度 | 总计划刻度 | 证据/说明 |
|---|---|---|---|---|---|---|
| 2026-09-06 / 基准42abf5b之后建表 | 无 | +0 | 0/50 | 0.0% | 80.0% | 只盘点与冻结计分；已有第58/59批计入历史基准，不重复计分 |

| 2026-09-06 / 第60批（本次提交） | W01 | +1 | 1/50 | 2.0% | 80.4% | 首次旧目录不报告新增，空卡基线及成功枚举先于元数据提交；966项Kotlin/Android、279项Python PASS；4项新增XCTest待Mac，下一项W02 |

| 2026-09-06 / 第61批（本次提交） | W02-A；W02仍进行中 | +0.5 | 1.5/50 | 3.0% | 80.6% | 原1分拆为两个半分子项，总分不变；共享准入/双卡发布/重试节奏由Android实际调用；973项Kotlin/Android、283项Python PASS；Apple事件调度接线继续W02-B |

| 2026-09-06 / 第62批（本次提交） | W02-B；W02完整完成 | +0.5 | 2/50 | 4.0% | 80.8% | 新增事件真实读取/有界重试/共享双卡发布及列表/缓存接线；977项Kotlin/Android、290项Python PASS；累计296项XCTest待Mac。移除只撤销待发布对象并标记重扫，完整删除/缺口编排继续W03/W04，自动开关W05未接 |

| 2026-09-06 / 第63批（本次提交） | W03-A；W03仍进行中 | +0.5 | 2.5/50 | 5.0% | 81.0% | 原W03一分拆两个半分，总分不变；完整别名索引接实际扫描/新增发布，共享删除核对/idle基线入口就绪；987项Kotlin/Android、298项Python PASS，299项XCTest待Mac；下一项W03-B。Mac操作指南一并提交，不另计分 |

| 2026-09-08 / 检查点8503823及工作区审计修复 | W03-B、W04、W05 | +2.5 | 5/50 | 10.0% | 82.0% | 1026项Kotlin/Android、314项Python、结构/原UI守卫及Debug Lint通过；393项XCTest待Mac。50子项不等于50主项，修复和剩余缺口见并行50项审计记录；下一项W06 |
| 2026-09-08 / W06单任务收口（本次提交） | W06 | +1 | 6/50 | 12.0% | 82.4% | 318项Python、结构/原UI守卫及diff检查PASS；新增6项组合XCTest，总399项待Mac。未改Android/shared/打包脚本，未重跑Gradle；下一项W07，本轮在此停止。 |
| 2026-09-08 / W07（未提交） | W07 | +1 | 7/50 | 14.0% | 82.8% | 1032项Kotlin/Android、322项Python、结构/原UI守卫PASS；原卡片精确提取已验证，Android仅纯UI委托适配。401项XCTest待Mac，下一项W08。 |
| 2026-09-08 / W08—W09（未提交） | W08、W09 | +2 | 9/50 | 18.0% | 83.6% | shared串行BUILD SUCCESSFUL in32s，325项Python及结构检查PASS；实际权限/路由与地址来源样本登记，下一项W10。 |
| 2026-09-08 / W10及本轮最终核对（未提交） | W10 | +1 | 10/50 | 20.0% | 84.0% | 1033项Kotlin/Android、325项Python、common metadata、Release Kotlin编译、两模块Debug Lint与原UI/卡片/结构守卫PASS。410项XCTest未运行；达到用户目标停止，下一项W11。 |

| 2026-09-08 / W11（本次提交） | W11 | +1 | 11/50 | 22.0% | 84.4% | 真实连接时间线、单次导航、发现取消、配对阶段反馈。1038项Kotlin/Android与330项Python通过；414项XCTest待Mac。继续W12—W20。 |

| 2026-09-08 / W12—W14（本次提交） | W12、W13、W14 | +3 | 14/50 | 28.0% | 85.6% | 1048项Kotlin/Android、333项Python与结构/全文提取守卫PASS；419项XCTest待Mac。继续W15—W20。 |
| 2026-09-08 / W15—W16（本次提交） | W15、W16 | +2 | 16/50 | 32.0% | 86.4% | STA专用预览、RAW分层降级与原裁剪提取；当批336项Python及串行Kotlin/Android检查PASS，Apple待Mac。 |
| 2026-09-08 / W17（本次提交） | W17 | +1 | 17/50 | 34.0% | 86.8% | 视频缩略图/首帧/共享日期与已有原片交付接线；适用验证计入本轮最终结果，平台样本待Mac。 |
| 2026-09-08 / W18（本次提交） | W18 | +1 | 18/50 | 36.0% | 87.2% | RAW嵌入EXIF与日期/文本对照，实际AndroidX 3213样本PASS；不把ImageIO源码当实测。 |
| 2026-09-08 / W19（本次提交） | W19 | +1 | 19/50 | 38.0% | 87.6% | 解码方向/颜色/透明/有界像素与原图字节保护；17项媒体XCTest待Mac。 |
| 2026-09-08 / W20及本轮最终核对（本次提交） | W20 | +1 | 20/50 | 40.0% | 88.0% | 1061项Kotlin/Android、340项Python、common metadata、Release Kotlin编译、shared/app Debug Lint及源码守卫PASS。430项XCTest和17项Native图片样本待Mac；达到目标停止。已推送e5dbadb，本批随本次提交归档，下一项W21。 |
| 2026-09-08 / W21（未提交） | W21 | +1 | 21/50 | 42.0% | 88.4% | NativeFilesPageModelTest锁定过滤/双卡/组顺序、真实回执与handle重用拒绝；继续复用原网格/共享准入，不造新选择模式；1073项Kotlin/Android通过，Mac场景登记，未提交 |
| 2026-09-08 / W22（未提交） | W22 | +1 | 22/50 | 44.0% | 88.8% | NativeBrowseSession + bridge关闭捕获/Probe同connectionId恢复；卡槽不持久化；common同连接/异连接测试通过，新增Apple重建页面样本待Mac，未提交 |
| 2026-09-08 / W23（未提交） | W23 | +1 | 23/50 | 46.0% | 89.2% | 继续复用完整PreviewOverlay/来源快照/返回和Burst/FHD/EXIF控制，切队列/返回关闭源；原UI/预览守卫和既有规则测试通过，正式Mac场景登记；不造相机删除，未提交 |
| 2026-09-08 / W24（未提交） | W24 | +1 | 24/50 | 48.0% | 89.6% | 原胶囊/QueueFlightGhost/FilesQueueWorkspace完整提取共用；真实手动回执+唯一队列订阅驱动自动飞入，预览落点/触感同源；全文提取与意图/实际任务测试PASS，视觉待Mac，未提交 |
| 2026-09-08 / W25（未提交） | W25 | +1 | 25/50 | 50.0% | 90.0% | NativeQueuePageModel保留有效速度、准备间隙及断线迟到快照隔离；原卡片/重试/清理规则复用；common速度和断线样本PASS，Mac回前台场景登记，未提交 |
| 2026-09-08 / W26（未提交） | W26 | +1 | 26/50 | 52.0% | 90.4% | NativeProductInformation及首页通用设置：实际Bundle版本、帮助/隐私、仓库链接/既有QQ、共用外观；无Android更新/支付；编译/接线守卫PASS，三语/系统链接待Mac，未提交 |
| 2026-09-08 / W27（未提交） | W27 | +1 | 27/50 | 54.0% | 90.8% | 真实provider名称及恢复错误、确认沙盒修复走既有idle fence，备份未知偏好且保留授权/原片；common请求/迟到回执PASS，Apple修复样本待Mac，未提交 |
| 2026-09-08 / W28（未提交） | W28 | +1 | 28/50 | 56.0% | 91.2% | 浏览/外观/模式/传输/目标偏好各自显式备份恢复，正常读不覆盖未来版本；实时外观和请求测试PASS，Apple分域备份/模式恢复样本待Mac，未提交 |
| 2026-09-08 / W29（未提交） | W29 | +1 | 29/50 | 58.0% | 91.6% | 已存原片面板按实际索引名/64位大小复制，PhotoLibraryImporter逐项add-only回执；common回执/副本身份PASS，正式批量PhotoKit适配器部分成功XCTest待Mac，原片保留，未提交 |
| 2026-09-08 / W30（未提交） | W30 | +1 | 30/50 | 60.0% | 92.0% | 同面板接单项/最多500项UIActivity/Files(asCopy)，流式私有副本与冻结provider读取、取消和部分回执不假成功；common+源码守卫PASS，逐字节/正式Files部分回执XCTest待Mac，未提交 |

| 2026-09-12 / iOS照片效果出口接线（a4e0b33） | Windows iOS子任务 | +0 | 50/50 | 100.0% | 100.0% | 完成成片句柄生命周期、批量Files/分享按钮与结果状态接线；Windows可继续内容剩余0项，Mac/真机仍12项待验 |
| 2026-09-12 / iOS设置浮层宿主接线（09f647b） | Windows iOS子任务 | +0 | 50/50 | 100.0% | 100.0% | 共享设置浮层仅在 iOS 注入时显示照片效果入口；跳转前关闭原文件页后调用统一 presentation，安卓默认能力关闭，Windows可继续内容剩余0项，Mac/真机仍12项待验 |
### 历史W31—W40检查点（f993e8e，以下是该时点记录）

W01—W40已WIN-DONE，40/50（80%，历史刻度96%）。W21—W30已推送8594187，W31—W40本次提交；最新指令是提交40后直接继续50，下一项W41。1082项Kotlin/Android、354项Python、common metadata、Android Debug/Release Kotlin及Debug Lint通过。相对8594187无Android宿主/平台/打包改动。446项XCTest与17项Native图片样本待Mac，Swift/Native未编译。当前证据以主任务表和生命周期与恢复验收说明为准，旧阶段描述仅为历史。

- Debug Lint：0 errors、179 warnings、8 hints；44个App Swift和8个测试文件注册；相对8594187Android平台/打包无差异。

| 主项 | 加分 | 完成 | 清单进度 | 历史刻度 | 证据 |
|---|---|---|---|---|---|
| W31 | +1 | 31/50 | 62.0% | 92.4% | 共享Cancel/同TID排空/32MiB/3秒绝对上限；Windows通过/Apple待验 |
| W32 | +1 | 32/50 | 64.0% | 92.8% | 代际与最终ready核对，显式重连不自动开始；Windows通过/Apple待验 |
| W33 | +1 | 33/50 | 66.0% | 93.2% | 有限后台额度/expiration安全关停/成对释放；Windows通过/Apple待验 |
| W34 | +1 | 34/50 | 68.0% | 93.6% | 512KiB/500行解释性记录，未知数据保留，无旧句柄续写；Windows通过/Apple待验 |
| W35 | +1 | 35/50 | 70.0% | 94.0% | 磁盘/权限/来源/发布错误分类与原片保留；Windows通过/Apple待验 |
| W36 | +1 | 36/50 | 72.0% | 94.4% | 两页图片epoch/内存释放，不动队列目录；Windows通过/Apple待验 |
| W37 | +1 | 37/50 | 74.0% | 94.8% | safeDrawing/IME/FlowRow/长列表滚动与适配场景；Windows通过/Apple待验 |
| W38 | +1 | 38/50 | 76.0% | 95.2% | 文件名标签/低频播报/48dp与VoiceOver场景；Windows通过/Apple待验 |
| W39 | +1 | 39/50 | 78.0% | 95.6% | 当前语言稳定错误码与原设置源三语接线；Windows通过/Apple待验 |
| W40 | +1 | 40/50 | 80.0% | 96.0% | 网络/add-only相册三语用途，无暂缓权限入口；Windows通过/Apple待验 |

### 历史W41—W49检查点（W50核对前的中间记录）

W01—W49已WIN-DONE，49/50（98%，历史刻度99.6%），W50正在最终核对与提交。W21—W30已推送8594187，W31—W40已提交f993e8e；W41—W49本次待提交。1085项Kotlin/Android（768+317）、364项Python、3213个AndroidX EXIF金样、common metadata、Android Debug/Release完整源码编译、Debug Lint及原UI守卫通过。三套依赖快照0变化；相对8594187无Android宿主/平台/打包改动。449项XCTest和17项Native图片样本待Mac，Swift/Native未编译。下一门槛M01/M02，不称全功能1:1或可发布。

- 实现、架构、功能矩阵、发布草稿及十二项Mac操作/期望/证据见[最终交接包](../测试与验证/iOS传图版最终交接与验收包.md)。W50尚未计分；最终提交前复核总表和文档链接。

| 主项 | 加分 | 完成 | 清单进度 | 历史刻度 | 证据 |
|---|---|---|---|---|---|
| W41 | +1 | 41/50 | 82.0% | 96.4% | TransferDiagnosticLog正式首页256条白名单/查看/清理/冻结分享；Common及Swift脱敏样本 |
| W42 | +1 | 42/50 | 84.0% | 96.8% | 品牌RGB AppIcon像素等价、三类真实隐私理由、版本1.81(54)/启动/反馈核对，公开URL待用户配置 |
| W43 | +1 | 43/50 | 86.0% | 97.2% | 31项功能矩阵覆盖Android USB/AP/STA及iOS标准/direct入口、默认值/错误/暂缓差异 |
| W44 | +1 | 44/50 | 88.0% | 97.6% | 真实ObjectInfo→双卡归并→FIFO失败重试→原片匹配金样；3213 AndroidX样本通过，文件字节样本待Mac |
| W45 | +1 | 45/50 | 90.0% | 98.0% | 1085单测、两配置完整源码编译/Lint及原UI守卫通过；108/131/120模块0变化，Manifest/平台未改 |
| W46 | +1 | 46/50 | 92.0% | 98.4% | 45 App Swift/8测试文件/449 XCTest注册，串行脚本补两架构Debug/Release，报告记录commit/dirty |
| W47 | +1 | 47/50 | 94.0% | 98.8% | 唯一会话/事件/队列观察，common无平台对象；终审修复内嵌队列图片、Int32计数、帮助滚动与配对三语 |
| W48 | +1 | 48/50 | 96.0% | 99.2% | Android Debug/Release脚本及路径/版本不变；Mac归档参数校验/默认只计划/禁止上传，源码测试通过 |
| W49 | +1 | 49/50 | 98.0% | 99.6% | 十二项M验收设备/夹具/操作/期望/日志/哈希和外部账号URL要求写入独立交接包 |

### W50 最终收口（本次提交）

W01—W50全部WIN-DONE：50/50，Windows本轮传图范围100%（历史刻度100%）。W21—W30已推送8594187，W31—W40已提交f993e8e，W41—W50本次最终提交；实际HEAD/是否推送以git状态为准。1085项Kotlin/Android（768+317）、366项Python、3213个AndroidX EXIF金样、common metadata、Android Debug/Release完整源码编译、Debug Lint与原UI守卫通过；三套依赖快照0变化。相对8594187无Android宿主/平台/版本/打包改动。449项XCTest和17项Native图片样本未运行；Mac仍0/12，下一步M01/M02。Windows实现和检查结束，不继续加功能、不称Swift已编译或可发布；Mac发现问题回开对应W项。

- 最终交付入口：[传图版最终交接与验收包](../测试与验证/iOS传图版最终交接与验收包.md)；初次操作仍按[Mac指南](../测试与验证/iOS首次Mac操作指南.md)。
- 先串行运行verify_on_mac.py，实际产物保留commit/dirty、log/xcresult。Apple编译、449个XCTest、17项Native图片、相机/系统授权/像素/性能均未在Windows冒充通过。
- Windows验证：Gradle主回归BUILD SUCCESSFUL in2m14s；完整Debug/Release源码与依赖快照BUILD SUCCESSFUL in19s。Lint 0 errors /179 Warning /8 Hint。108/131/120解析模块与共享化后本机快照全部0变化。
- 新增final_completion_wiring追加精确逆向层，不改旧指纹；诊断/图标像素/隐私/归档不上传、计分及交接链接均有源码守卫。主表50项全各1分，Mac12项全0分，暂缓项不偷算完成。

| 主项 | 加分 | 完成 | 清单进度 | 历史刻度 | 证据 |
|---|---|---|---|---|---|
| W50 | +1 | 50/50 | 100% | 100% | 最终代码/计分/链接/回归与提交检查；Mac仍待验 |
