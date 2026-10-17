# iOS：安卓 1.94 增量复刻任务台账

## 授权、基准与范围

2026-10-12 用户要求再次拉取安卓分支到 ios，忽略鸿蒙代码，先把新功能记入文档，再按既有规则逐项复刻。已执行 `git fetch origin android` 与 `git merge --no-edit origin/android`；新基准 `89d78b451d03e50da965a46f047744aa8a34877c`，合并 `ba3196226301209cd61d8f1303f67c7647ceab99`。安卓版本为 **1.94 / 67**；相对原基准 `8138e2de` 新增 **6 个提交、17 个净变化文件**，完整来源见 [增量来源索引](iOS-1.94-增量来源索引.json)。

合并无冲突，`app/` 与安卓目标提交一致，合并提交未改动 `ios/`。合并前已有 35 个修改文件，逐文件 SHA-256 复核全部保留；补丁备份位于 `/tmp/ztransfer-ios-android-sync-20261012/`。本次创建用户要求的基准合并记录；随后完成 iOS 增量复刻、验证及 Debug 模拟器安装启动，不推送。

鸿蒙代码保留在安卓来源树，**不在 iOS 引入设备识别、SAF 发布兼容、待发布 journal 或鸿蒙损坏诊断**。最终源码是依据，不能因为中间提交叫“给安卓也加上诊断”而移植后来已收窄为鸿蒙专用的路径。

沿用 [长期项目记忆](../项目记忆-iOS复刻规则.md) 与 [调度器权威逻辑](../技术调研/全局任务调度器权威逻辑.md)：先读源码、上下游和测试；用户可见文字逐字、状态与动画逐项对照；大块集中验证；真机验收由用户执行。既有 StoreKit、入队水印冻结、STA 顺序缩略图等已批准差异不变。

## 任务与进度

当前记录进度 **2/3**；2026-10-15 C08发现普通状态更新会清除/降级显式探测捕获，且缺RAW头详细耗时，撤回M02整体完成，见[全功能复核F032](iOS-全功能行为复核跟进.md)。历史3/3与测试日志保留其原范围，本次未修复或重跑。范围排除不计功能完成，用户验收尚未完成。旧 [1.93 台账](iOS-1.93-增量复刻任务台账.md) 中未完成任务保留，不因拉取新版本或历史全量测试通过而自动关闭。

| 编号 | 必须复刻的行为 | 安卓依据 | 状态 |
|---|---|---|---|
| M01 | STA 不使用保护字段，不显示保护筛选、不影响筛选激活或列表；STA 内修改/归一化其它筛选时保留 AP/USB 的保护偏好，返回 AP/USB 后恢复生效；显式清空整套筛选按安卓恢复默认 | NikonCamera 的 STA session 门控；FileListScreen 的 showProtectionFilter / criteriaForPersistence / FilterOverlay | 复刻完成，待用户验收 |
| M02 | Debug 照片页评级与保护诊断：AP/USB 保留 RAW 评级探测；STA 最多 4 个受支持文件的有界头比较与 0xDC03 单属性读取；保持候选结论、不可写回保护/评级；连续记录、恢复捕获状态、复制/清空及忙态；Release 无入口 | NikonCamera 两项 probe；RatingDiagnostics；DebugPhotoGenerationProbePanel / release 空实现；FileListScreen 接线 | 未完成：诊断捕获生命周期/详细耗时缺口，见全功能复核F032 |
| M03 | 全差异核销、三语/版本一致、必要回归及平台排除证据；检查真实生产接线，不能以纯 helper 测试证明 UI/协议闭环 | 本轮 17 文件逐 hunk；最终 Android versionName=1.94；受影响 iOS 入口 | 复刻完成，待用户验收 |

2026-10-15 M01范围文字纠正：当前安卓空结果页直接调用`clearFilters()`恢复完整默认，包含清保护偏好；旧表将清空也列为保留场景不符合源码，现纠正，不要求iOS制造额外差异。

M02 是用户显式触发的两项有界只读实验，不等于此前排除的全量能力/属性扫描。不得扩展命令范围或自动运行，也不得根据头字节差异设置真实保护标记。

## 鸿蒙排除清单

| 来源 | 最终用途与不迁移理由 |
|---|---|
| HarmonyStorageCompatibility.kt | 华为/鸿蒙反射识别及已知机型 fallback，用户明确排除 |
| PendingPublicationJournal.kt 及测试 | 鸿蒙私有 staging、SAF 发布校验、跨启动恢复，iOS 不引入此平台分支 |
| TransferViewModel 的 Harmony 分支 | 私有临时源、发布前后指纹、重名/覆盖保护、恢复 journal 等全部按平台排除；共用文件仍需逐 hunk 检查 |
| TransferCorruptionDiagnostic、构建标志与诊断文档 | 最终入口要求 build flag 且 Harmony detection=true；R/T/F/L/C、公共 Downloads TXT fallback、每 8 文件/队列末持久化均属被排除诊断 |
| NikonCamera strictBytesObserver | 鸿蒙完整性校验使用的严格观察器；普通路径仍吞掉诊断回调错误，不为 iOS 添加鸿蒙观察器 |

原 1.93 N16 的迁移要求已被本次“忽略鸿蒙”及最终运行期门控覆盖，记录为范围排除，不计作已实现的 iOS 功能。

## 验证记录

- 同步：fetch 成功、merge 无冲突；`git diff --quiet origin/android -- app` 通过，合并前后 `ios/` 提交树无差异，35 个已有修改文件哈希相同。
- M01：`PhotoFilterState`/`PhotoFilter.apply` 增加 STA protectionAvailable 门控，`PhotoListViewModel`、筛选弹层和空列表/按钮激活态同步隐藏保护筛选；AP/USB 偏好仍由既有持久化保存。模型回归包含 `testSTAProtectionFilterIsUnavailableButPreferenceSurvives`。
- M02：`CameraRepository`/`CameraSession` 保留 AP/USB RAW 评级探测，并新增 STA-only 保护头与 0xDC03 只读探测；STA 头探测要求直读能力已验证，绕过普通前缀缓存，候选按输入顺序去重并最多 4 个、最多 256 KiB，按 handle 保留 SHA-256 基线并记录最多 12 个差异候选及评级/耗时；属性探测记录响应码、前 32 字节和小端值，不改变 `CameraFile.isProtected` 或评级缓存。STA ObjectInfo 不消费不可靠的保护位。`PhotoRatingDiagnostics` 支持 `keepExisting/preserveEntries`，Debug `PhotoListView` 按安卓接线显示“评级与保护诊断”面板，包含副标题、不同探测忙态、复制提示及日志颜色，Release 为空实现。
- 文案/版本：同步安卓 `photo_interaction` 为“Photo actions/照片操作/照片操作”；iOS `MARKETING_VERSION`、工程回退版本更新为 `1.94`。安卓资源比对共 673 个键，剩余 2 个仅鸿蒙完整性错误文案（`transfer_temp_source_error`、`transfer_final_verification_error`），按范围排除；鸿蒙设备识别、SAF journal 和 R/T/F/L/C 诊断未引入。
- M01/M02 审查后的领域回归：`/tmp/ztransfer-ios194-audit-domain3.log`，`DomainModelTests` **134/134**、0 失败，终态 `** TEST SUCCEEDED **`。
- 最终全量 XCTest：`/tmp/ztransfer-ios194-audit-full2.log`，`ZTransferTests.xctest` **805 项、4 项跳过、0 失败**，终态 `** TEST SUCCEEDED **`。跳过项为 AndroidX macOS oracle 1 项及麦克风权限门控 3 项。
- Debug 模拟器：`/tmp/ztransfer-ios194-audit-debug-build2.log` 终态 `** BUILD SUCCEEDED **`；已将最新 `ZTransfer.app` 安装到已启动的 iPhone 17 模拟器（`/tmp/ztransfer-ios194-audit-sim-install2.log`）并成功启动 `com.ztransfer.ios`（`/tmp/ztransfer-ios194-audit-sim-launch2.log`）。未进行真机验收、提交或推送。
