# iOS 传图版最终交接与验收包

这是 W41—W50 的交付索引，接续先读[主任务表](../技术调研/iOS剩余任务进度表.md)。Windows 完成不代表 Swift/Native 已编译，更不代表商店可发布。正式范围：AP/STA 原片传输、浏览、预览、队列、保存；USB、无限后台、效果、会员、遥控监看、GPS 发送不纳入本轮。

## 1. 检查点与启动顺序

- 分支 research/ios；W21—W30 已推送 8594187，W31—W40 提交 f993e8e。W41—W50 以最终 git log / status 和主表为准。不要覆盖文件或切旧 master。
- 先按[首次 Mac 操作指南](./iOS首次Mac操作指南.md)装 JDK17、SDK35 和匹配仓库 Kotlin 的 Xcode，创建本机 local.properties，不复制 Windows SDK 路径。
- 仓库根目录执行 python3 iosApp/scripts/verify_on_mac.py --preflight-only；通过后执行 python3 iosApp/scripts/verify_on_mac.py。
- 脚本串行：结构 → Simulator Arm64 Native 测试 → Debug 模拟器 XCTest → Release 真机架构 → Debug 真机架构 → Release 模拟器架构。保留 iosApp/build/verification/ 下报告、日志和 Tests.xcresult；报告记录实际 commit/dirty。任何失败回开对应 W 项。
- 不同时点 Xcode Build 又启动脚本。不把 Windows common metadata 当成 ObjC 导出名、UIKit/Swift 并发或实际 Compose 渲染的验证。

## 2. W43 逐功能对照矩阵

“共用”指规则/组件是同一份；平台 IO、系统授权和视觉实测仍是 Mac 门槛。USB 列仅保护 Android，iOS 不新增入口。下表加上暂缓表覆盖本轮边界，不称完整全功能 1:1。

| 能力 | Android USB | Android AP | Android STA | iOS AP / STA 对应与边界 | 代码/证据入口 |
|---|---|---|---|---|---|
| 连接准入/取消/断开 | 原 USB 权限/服务 | 原热点连接 | 原局域网连接 | 正式首页单一会话，显式 AP/STA；无 USB | NativeConnectionHome、CameraWorkspace、CameraWiFiConnection；ConnectionHomeTest |
| 发现和手工地址 | 不适用 | 默认热点 IP | 发现/历史 | 系统加入 Wi-Fi；规范化地址，Bonjour 候选；不后台扫描网段 | CameraDiscoveryCoordinator、NativeCameraEndpointAddress |
| STA 身份/配对 | 不适用 | 不冒充配对 | 原 ACK/配置策略 | 同源配对规则、稳定 PC 身份、ACK 后标记；更换 responder 不信旧地址 | NikonStaBridge、StationProfileStore（Network/StationProfileStore.swift） |
| 路由/权限失败 | USB 原实现 | Wi-Fi 路由 | Wi-Fi 路由 | Apple NWPath；显式拒权证据与超时区分，手动设置重试 | CameraTCPStream、CameraNetworkPathPolicy、TransferFailureMessage |
| 兼容 STA-direct | 不适用 | 不启用 | NikonCamera 原规则 | 仅实际能力证据启用，标准命令失败不盲退 direct | NativeStaDirectMetadata、NikonStaBridgeTest、CameraNetworkTests |
| 打开会话/命令顺序 | 原 USB 帧 IO | 原 PTP/IP | 原 PTP/IP | 相同共享 codec；控制锁/事务号/事件通道由 Swift 持有 | PtpIpProtocolCodecTest、PtpIPCommandSession |
| 全目录/空卡/双卡 | 原共享扫描 | 同左 | 标准/direct 同源 | 共用扫描/别名归并/卡槽策略；不把未知存储当可靠卡槽 | NativeCameraCatalogScan/Test |
| 删除/属性/卡变化 | 原刷新规则 | 同左 | 同左 | 同目录所有者对账；迟到 ObjectInfo/旧扫描不能复活删除条目 | CameraCatalog、NativeCameraCatalogReconciliationTest |
| 高速新增/缺口追赶 | 原事件准入 | 同左 | 同左 | 一个事件观察者，完整基线后按共享准入；自动旧片不入队 | CameraAutomaticTransferCoordinator、6 项 automaticLoop XCTest |
| 自动传输开关 | 原偏好 | 同左 | 同左 | 同共享准入/FIFO；默认按实际偏好，不恢复已暂停任务 | NativeAutomaticTransferSettingsTest、NewCameraObjectPolicy |
| 手动单张/日期/连拍组 | 原网格行为 | 同左 | 同左 | 复用原网格批量身份、真实入队回执；无另造相机全选模式 | SharedThumbnailGrid、NativeFilesPageModel |
| 筛选/日期/保护/未传 | 原筛选 | 同左 | 同左 | 共用过滤与退场；原片索引就绪后才可判断未传输 | SharedFilterOverlay、NativeFilesPageModelTest |
| 列数/合并/点击默认值 | 原偏好 | 同左 | 同左 | 2～4 列默认3、合并开启、点击预览旧文档默认关闭；同源验证 | NativeBrowsePreferences、BrowsePreferencesStore |
| 缩略图与后台补图 | 原加载器 | 同左 | direct 头/RAW 路径 | 同裁切/填充规则；Apple 解码/缓存；无相机随机额外 IO | CameraPreviewStore、NativeGridImages、ThumbnailFillQueueTest |
| FHD/RAW/MPF/视频日期 | 原预览 | 同左 | 原 direct 兼容 | 共享解析/选择；本地原片优先，RAW 是嵌入图而非新 RAW 显影器；不新增视频播放器 | NativePreviewSessionSource、NativeStaDirectMetadata、3213 EXIF oracle |
| EXIF/方向/直方图 | 原共用规则 | 同左 | 同左 | 复用解析/格式化/绘制；ImageIO、像素方向色彩实测 M05 | PreviewExif*、Native bitmap tests |
| 放大/旋转/翻页/返回 | 原完整 overlay | 同左 | 同左 | 同一 overlay、同连接浏览快照；系统 sheet 返回另验 | SharedPhotoPreviewOverlay、NativeBrowseSession |
| 胶囊/飞入/空间转场 | 原实现 | 同左 | 同左 | 纯 UI 原样提取；飞行动画等真实接受回执才触发 | queue_workspace_extraction、workspace_transition_extraction |
| 排队/暂停/撤回/重试 | 原 FIFO | 同左 | 同左 | 同 Shared 队列与历史；撤回不抹正在传的原片；重试新任务 ID | NativeOriginalTransferQueue、TransferGoldenJourneyTest |
| 进度/完成/速度/耗时 | 原展示 | 同左 | 同左 | 实际字节/完成结果驱动，无虚构 ETA；200ms进度不重写整页历史 | NativeQueuePageModelTest、CameraOriginalQueue |
| 取消帧排空 | USB 保持原行为 | 原 Cancel/drain | 原 Cancel/drain | 同 TID 排空持锁，32MiB；iOS 3秒绝对上限是明确差异，超限关闭 | 生命周期验收说明、取消 XCTest |
| 沙盒/自选目录/按天 | 原 Android 文件 IO | 同左 | 同左 | Shared命名/匹配，Apple安全目录授权/协调发布；本次临时文件所有权独立 | SandboxTransferFile、ProviderOriginalStore |
| 同名复用/安全发布 | 原共享判定 | 同左 | 同左 | 完整原片后才索引/完成；已有原片跳过；provider失败保留源原片重试 | ExistingFileNameIndexCore、自动循环逐字节 XCTest |
| 图库/分享/Files | Android 系统接口 | 同左 | 同左 | 仅已存原片，PhotoKit add-only；批量回执/取消可解释；分享不承诺接收方已持久保存 | OriginalActionPresenter、OriginalActionCopies、NativeOriginalActionsTest |
| 来源移动/撤权/云未下载 | 原平台处理 | 同左 | 同左 | 冻结授权来源、重读校验、字节分块复制；失败不删除源原片 | IndexedOriginalReader、ProviderOriginalStore tests |
| 重连/重启恢复 | 原进程内队列 | 同左 | 同左 | 新会话重新验证身份和目录；新增解释性记录，不自动套旧 handle 或 part | TransferRecoveryJournal、CameraWorkspaceTests |
| 后台/常亮 | 原 Android 服务 | 同左 | 同左 | 有限 UIKit 清理，不无限锁屏传图；前台返回不自动开始，常亮成对释放 | SessionBackgroundLease、AppAppearanceSettings |
| 内存压力/关闭释放 | 原生命周期 | 同左 | 同左 | 两个顶层页及文件页内嵌队列图片 epoch；关闭 owner 取消异步回调 | NativeFilesPageModel、NativeQueuePageModel、NativeGridImages |
| 设置/皮肤/触感/三语 | 原控件/资源 | 同左 | 同左 | 原卡片/拨轮；偏好分域备份恢复，错误按当前语言渲染 | NativeAppearanceModel、NativeTransferMessages |
| 安全区/键盘/大字号/朗读 | 原 Android 页面 | 同左 | 同左 | Native 宿主适配、FlowRow、滚动帮助、可达按钮/标签；M08 实际朗读与截图 | 生命周期验收 W37/W38 |
| 诊断/隐私 | 原 Android 不动 | 同左 | 同左 | 新增本次运行256条白名单记录，首页查看/清理，分享冻结预览；不自动上传 | TransferDiagnosticLog、NativeDiagnosticsDialog |

暂缓效果/水印/相框、会员支付、监看遥控及 GPS 对应 Android 功能都继续保留。iOS不开放这些入口、不改 Android 权益或服务端。

## 3. W44—W47 跨模块证据与所有权

- 新增 TransferGoldenJourneyTest：固定 ObjectInfo 字节经解析 → JPG/Unicode NEF/MOV（0xFFFFFFFF 大小）→ 两卡同图归并 → 真实共享队列失败/新ID重试/完成 → 已存副本名称和大小匹配；另验空卡无虚假任务。
- 现有 CameraNetworkTests 六项 automaticPublicationLoop 使用真实 Swift 连接/流式下载/队列/沙盒/provider/索引回调，并逐字节比对原片；源码已注册，未在 Windows 执行。不能把公共金样叫作已成功传完4GB真机文件。
- 真实 AndroidX1.3.7 解码器与 shared 对照：3213 TIFF/JPEG 样本通过；它不证明 ImageIO、所有相机 RAW 或任意坏文件一致。
- 最终所有者关系：

    ContentView → CameraWorkspaceBridge → 单一 CameraHandshakeProbe
      → CameraWiFiConnection / PtpIPCommandSession（唯一 IO 锁/事件流）
      → CameraCatalog / CameraAutomaticTransferCoordinator（同目录/新增准入）
      → CameraOriginalQueue → Shared NativeOriginalTransferQueue（单份 FIFO/历史）
      → 原片 store / provider（单次操作只清自己的临时文件）
      → 唯一 queue.updates 观察 → 文件页、顶层队列页、低频诊断/恢复记录

- commonMain 不引用 android/java/platform Apple 对象；纯业务规则不另复制。Native* UI 是平台状态适配，组件仍共用原网格、预览、队列与控件。Debug探针保留但不替代正式导航，不存在为了演示而模拟正式完成状态。
- 控制权：页面关闭不停止连接级下载；会话结束取消目录/补图/队列并关闭通道；迟到回调检查 owner/generation/request；预览与原片分享持有冻结来源；后台额度和安全目录访问有独立释放职责。
- 终审回查并修复 W34/W36/W37/W39：Int32恢复计数越界、内嵌队列图片释放、帮助长文滚动、配对消息当前语言渲染。诊断导出固定为用户已查看的快照。这些修复均包含在最终检查，不以已提交40为由跳过。
- W45 Windows：1085 单测（768 shared +317 app）零失败/错误/跳过；common metadata、Debug/Release Kotlin及完整 compileDebugSources/compileReleaseSources通过；Debug Lint 0错误、179 Warning、8 Hint。最终完整Python 366项通过，完整结果见主表。
- 三套解析依赖对照本机共享化后快照均0变化：Debug compile108、Debug runtime131、Release runtime120模块。输入Gradle/Manifest/打包脚本与f993e8e、8594187无变化。历史快照是本机产物，不假称旧master依赖从未升级；新机器可重新快照，比对本节边界。
- 原UI完整提取/变异拒绝链全部保持；final_completion_wiring仅追加精确新层，旧指纹未刷新。新文件在提交后也纳入白名单检查。

## 4. W42 发布材料源码草稿与隐私清单

| 材料 | 已准备 | 外部门槛（未完成） |
|---|---|---|
| 名称/版本 | Z传 / ZTransfer；Android与iOS均1.81(54)，未擅加版本 | 上架前用户决定最终版本与可用Bundle ID |
| AppIcon | 复用docs/品牌素材/ztransfer_icon_1024.png；RGB、1024、无透明；Windows逐像素SHA256等价；asset注册Debug/Release | Mac actool与真实安装图标验收 |
| 启动 | 使用现有UILaunchScreen生成配置；不造虚假的启动进度 | 冷启动/深色模式/尺寸截图 |
| 权限 | InfoPlist.strings简中/繁中/英文；LocalNetwork和Photos add-only；Bonjour两类；无额外entitlement和暂缓能力入口 | 签名后检查实际合并Info.plist及拒权/撤权 |
| 隐私 | 无跟踪/自动采集；应用私有UserDefaults CA92.1；私有文件C617.1；用户选定目录3B52.1；仅时长/计时SystemBootTime 35F9.1 | Xcode归档生成聚合Privacy Report，检查Compose/Skiko及实际最终二进制，不宣称App声明覆盖全部SDK |
| 链接 | 源码https://github.com/yuui226/nk_send；现有反馈QQ953000922由用户点击复制 | 尚无真实iOS App Store/TestFlight更新链接、公开隐私政策/支持URL；需用户配置，不伪造、不开空按钮 |
| 签名分发 | archive_on_mac.py默认只显示参数；验证Team/bundle/输出路径，实际执行仅Mac；不自动申请profile或上传 | 真实Apple账号、Team、证书/profile、App Store Connect记录、分发与审核授权 |
| 截图 | M08明确截图路径与场景 | 必须用最终iPhone运行画面，不能用探针或Android截图充数 |

[Apple required-reason API说明](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons?language=objc)对应源码声明；这是用途核对，不是法律意见或审核通过保证。代码未读取磁盘剩余量API，只处理写盘错误，因此不随意增加DiskSpace理由。导出的原片仍保留原始EXIF/GPS；**诊断**不带照片这些元数据，二者不要混淆。

商店描述草稿（需在M03/M04确认实际支持机型后定稿）：

> Z传帮助你通过相机热点或同一局域网，将兼容尼康相机中的原片保存到iPhone。浏览、筛选与预览照片，手动或自动加入传输队列，将已保存原片添加到照片图库或通过系统分享导出。本版本专注原片传图；不包含USB连接、照片效果编辑、会员购买、遥控监看或GPS发送。传输时请保持应用在前台。

英文草稿：

> Transfer original photos from compatible Nikon cameras over a camera hotspot or local Wi-Fi. Browse, filter and preview photos, manage transfers, and add saved originals to Photos or export through the system share sheet. This edition focuses on original-file transfer. USB, effects editing, purchases, live view and GPS sending are not included. Keep the app in the foreground while transferring.

支持机型列表留待M03/M04：写实际相机型号、固件、AP/STA标准/direct通过情况，不把日志机型白名单当兼容认证。隐私政策公开地址和版权/商标声明由项目负责人确认。

## 5. W48 打包流程保护

- 本轮未运行APK/IPA打包或上传。Android Debug仍只用dist-debug/build-debug.bat，交付其最新时间戳APK；正式发布仍用dist/build.bat，Release脚本校验签名/版本后输出dist，aab参数保持原意。Gradle配置、脚本、manifest、包名未改：Debug com.ztransfer.debug / Release com.ztransfer。
- 不拿app/build/outputs下产物手改名交付，不触碰dist里的旧包/映射/证书。以后用户说“打包”再按AGENTS.md走Debug脚本，不重复跑整套构建。
- Mac实际归档前：先M01—M08通过并在Xcode选真实Team。只看计划：python3 iosApp/scripts/archive_on_mac.py --team 你的10位TeamID。改用真实已注册Bundle ID时加 --bundle-id。
- 得到用户归档授权后才加 --execute；输出固定在iosApp/build/archives/独立时间戳目录，要求ARCHIVE SUCCEEDED和xcarchive/dSYMs存在。脚本不执行exportArchive、上传或自动provisioning更新。缺签名就返回失败，不改成debug签名掩盖问题。
- Archive在Organizer核对实际Bundle、版本、权限、聚合隐私报告和dSYM；导出/上传TestFlight需要另行确认。不要执行Android Release脚本来构建iOS。

## 6. W49 十二项 Mac/真机验收包

通用夹具：M1 Mac、iPhone+iOS版本记录、至少一台已确认支持AP和STA的尼康相机（记录固件）；同Wi-Fi路由器；双卡与空卡；JPG/NEF/MOV、含方向/EXIF/Unicode文件名样本及一个大文件；Files本地目录和可撤权/离线的云provider；Android手机及USB线。原始样本从相机卡只读备份，不用私人照片当公开日志。

每条证据建在iosApp/build/acceptance/提交号/Mxx/（不提交私人原片）。文件清单记录basename、长度、SHA256：Mac用 shasum -a 256；Windows用 Get-FileHash -Algorithm SHA256。对“成功”的原片逐字节长度+SHA256一致；另行保存的照片资产导出原资源再对比，不用系统压缩分享副本冒充无损。

| 门槛 | 操作/夹具 | 必须满足的期望与证据 |
|---|---|---|
| M01 | 执行第1节preflight及完整串行脚本；记录Xcode/JDK/SDK/commit | Native framework/Swift/资源注册、两架构Debug/Release真实成功；保留6段日志；错误回开所属W项 |
| M02 | 脚本执行全部XCTest与Native tests | 核对实际执行数量/跳过/失败，保留xcresult及Native XML；当前449个XCTest方法/17项Native图片源码只是待跑目录 |
| M03 | AP：首次允许网络→连接→目录→拍新图自动传→手动/组入队→保存→分享；断开再连 | 相机卡/沙盒/目标原片哈希一致；无旧片自动入队/漏片/重复任务；诊断阶段与实际一致 |
| M04 | STA：发现候选/手输/配对确认/取消/历史；标准与确有证据的direct，双卡/空卡/大文件 | 配对身份稳定、换相机不复用旧信任；正确卡槽/去重与顺序；direct支持边界机型单列 |
| M05 | 原片与本地RAW、MPF、JPG方向、MOV日期，筛选/连拍/跨卡；扫描期间连拍/删除/换卡 | 元数据/预览方向色彩与Android同源规则对照；无旧扫描覆盖/删除复活；保存完整原片哈希不变 |
| M06 | Files本地/云目录选择、取消、撤权、移走、同名竞争；单/批量PhotoKit、Share/Files部分返回 | 只有本次临时文件可清理；源原片保留；成功/失败/取消逐项真实，不把系统关闭当全成功 |
| M07 | 下载中切网/后台/锁屏/终止、磁盘不足、相机断电/换卡；恢复记录损坏及未知版本 | 32MiB/3秒绝对排空保护，安全关闭；旧回调/旧handle不污染；完整原片保留，partial不续写；没有假拒权/无限后台 |
| M08 | 正式页面三语/深浅皮肤/触感/常亮；小屏/旋转/最大字号/VoiceOver；大量事件、长期下载与预览 | 截图比对原布局/控件，重要操作可达；朗读文件名/动作，返回焦点；Instruments记录内存峰值/泄漏/主线程停顿/温度；告警后图片释放且传输不丢 |
| M09 | 真Team签名装机；诊断预览/冻结分享/清空；归档并查看实际用途/聚合隐私/dSYMs，覆盖安装升级 | 导出日志不含IP/GUID/序列号/照片名/路径/EXIF；清理不动照片/身份；记录真实签名/版本与升级偏好保留 |
| M10 | 用户要求打包后走Debug脚本；Android USB/AP/STA各完成传图/预览/队列/暂停重试/保存/原设置 | 本次最终Android包实际对照，不把此前用户有线/STA试包记作本次三模式已通过；哈希、截图及设置行为记录 |
| M11 | 归总所有失败，修复后重跑受影响案例；逐行核对本矩阵 | 所有返工关闭、任务表与证据一致；用户确认平台差异及传图版范围，不叫完整全功能1:1 |
| M12 | 提供真实公开支持/隐私URL、商店记录/截图/分发授权；按Apple实际提交流程验证 | 未授权不上传；TestFlight安装/反馈与商店材料真实，外部账号/链接缺失保持未完成 |

W31—W40更细的事件时序见[生命周期与恢复验收说明](../技术调研/iOS生命周期与恢复验收说明.md)；W21—W30系统保存回执见[工作区与原片交付验收说明](../技术调研/iOS工作区与原片交付验收说明.md)。不要在Mac重新盘点任务，先按M01/M02让编译和测试暴露真实问题，然后顺序跑设备案例。

## 7. W50 收口原则

最终主表必须恰好50项各1分；Windows测试和源码索引一致，Android差异边界明确；M01—M12保持0/12直至真实执行。新缺陷回开对应W项并扣回分数。保存Git提交与实际测试产物，不将“代码写完/源码有test函数/系统share打开了”代替可运行、测试通过或原片已成功保存。
