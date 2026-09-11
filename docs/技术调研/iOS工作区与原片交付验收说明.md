# iOS 工作区与原片交付验收说明（W21—W30）

基线：已推送的 ad101d5；本批未提交，分支 research/ios。只计 Windows 实现门槛，不代表 Apple 编译或真机验收。当前入口见 [剩余任务进度表](./iOS剩余任务进度表.md)，下一项 W31。

## 对照实际 Android，而不是误写的任务名

- W21：Android 原网格是单张、日期组和连拍组入队，配合卡槽/日期/类型/保护/未传筛选；没有独立的复选框全选/跨卡选择模式。本批锁定实际批量规则及文件身份，不新造相机选择交互。“已存原片”的勾选仅用于 iOS 系统导出。
- W23：原相机预览支持导航、返回、连拍、旋转、直方图、原片传输；没有预览内分享/删除按钮。不新增相机删除指令。复用既有完整共享预览和冻结来源，系统保存/分享统一从已存原片面板进入。
- W25：Android 原队列显示速度、大小、耗时和状态，而非预测剩余时间。本批修复 iOS 速度保持与断线迟到进度；不新造 ETA 算法。
- 上述是源代码核对后的描述纠正，不是把实际未做的 Android 功能删出范围；50 项分母和每项 1 分不变。视觉效果只能在 Mac/真机最终确认。

## 入口与职责

相对路径均从仓库根目录起算。没有第二套连接、下载队列或事件订阅。

| 项目 | 实现入口与关键约束 |
|---|---|
| W21 批量准入 | NativeFilesPageModel + 原 SharedThumbnailGrid；冻结当前过滤组、保持原排序、入队前验证完整文件身份和真实回执，handle 重用不能传错文件 |
| W22 浏览恢复 | NativeBrowseSession 保存同一 connectionId 的卡槽/筛选、折叠、连拍展开与滚动锚点；OriginalFilesPageBridge 关闭时捕获，Probe 同连接恢复。卡槽不写全局偏好，断开清空，预览来源仍冻结 |
| W23 正式预览 | NativeOriginalFilesPage 继续用完整共享 PreviewOverlay 及既有来源快照、返回定位、Burst/FHD/EXIF/直方图/旋转；切队列或返回关闭预览读取和构建任务，不新增相机删除 |
| W24 工作区 | SharedQueueWorkspace、SharedFilesQueueWorkspace：原胶囊宽度/计数/速度/完成态、群体飞入、空间转场提取共用；iOS 用真实入队回执和唯一队列订阅驱动，手动与自动不双播，既有预览飞行落点接胶囊，触感遵循同一开关 |
| W25 队列反馈 | NativeQueuePageModel 保留最后有效速度、准备间隙保持；断线清除高频进度，迟到快照不复活运行态；原共享任务卡片/暂停/重试/清理规则不另写 |
| W26 设置壳 | NativeProductInformation、NativeGeneralSettingsDialog；首页与照片设置共用实际外观模型，帮助/隐私本地弹窗、版本来自 Bundle、源码 URL 与现有 QQ 反馈入口，不挂 Android 更新/支付 |
| W27 目录 | 原目录选择和 configureDestination 安全切换继续；显示已验证 provider 名称，恢复失败提示修复；确认恢复沙盒前沿用 idle fence，旧授权/原片保留，未知偏好备份 |
| W28 偏好 | 浏览、外观、AP/STA 模式、传输与目标偏好各自原存储增加显式恢复备份；正常读取不覆盖损坏/未来版本。外观恢复实时生效，浏览不清目录/索引，自动传输恢复继续先停止当前会话自动接纳 |
| W29 图库 | NativeOriginalActions + OriginalActionPresenter → 原 PhotoLibraryImporter；单项/批量串行真实复制、PhotoKit add-only 提交，按实际完成逐项回执。不支持/拒绝/失败仍保留原片，可改用 Files/分享 |
| W30 系统导出 | 同一已存原片面板 → 原片索引的实际名称/大小/locator → OriginalActionCopies → UIActivityViewController 或 UIDocumentPicker(asCopy:true)；唯一私有批次目录、流式复制，不把 provider 授权 URL 直接外传 |

系统动作一次最多 500 项，选择只属于冻结面板快照；不为缺失本地原片自动下载，不删除原片或相机照片。复制使用实际本地索引名（包括重名副本后缀）和真实 64 位大小，而不是相机未知大小哨兵。系统回执不代表接收方持久保存或云端同步；Files 部分回执无可靠逐源映射时不虚构成功项，显示 N/M、让用户核对，不自动重试。取消后若 PhotoKit 已提交，等待真实结果再清私有副本。

## Android 保护及验证结果

相对 ad101d5，Android 只改两处受控纯 UI 委托：

- app/src/main/java/com/ztransfer/ui/screen/FileListScreen.kt：胶囊、群体飞入 UI 提取；Android 保留原 lifecycle Flow 收集、资源、格式化、触感和所有原调用。
- app/src/main/java/com/ztransfer/MainActivity.kt：原 FilesQueueWorkspace 完整提取，原导航/连接/队列所有者仍在宿主。
- queue_workspace_extraction.py、workspace_transition_extraction.py 同时严格对照完整 Android 文件和新公共文件；旧历史守卫先经受控精确逆转换，新固定全文指纹及变异测试拒绝无关变化。不能通过刷新历史指纹/宽泛替换来掩盖未来改动。
- 未修改 Android 协议收发、服务、平台 IO、版本、Gradle 配置、dist/dist-debug 或发布脚本。未生成 APK。

最终串行 Gradle：BUILD SUCCESSFUL in 4m31s；common metadata、shared/app Debug 单元测试、Android Release Kotlin 编译、shared/app Debug Lint 通过。756 shared + 317 app = 1073 项测试，0 失败/错误/跳过；shared Lint 0 问题，app 0 错误/179 Warning/8 Hint。构建期间没有并行 Gradle。

346 项 Python 检查、工程结构、原 UI 精确提取和 git diff --check 通过。新增 common 行为样本覆盖真实过滤批量准入、handle 重用、同连接浏览恢复、自动意图+实际任务发布、大小/重名副本、迟到速度、显式目录/外观恢复、导出回执与关闭；源码接线测试不是业务执行或 Swift 类型检查。

Apple 侧目前 42 个 App Swift / 8 个测试文件，437 个 XCTest 方法已登记但未执行；另有 17 项 Native 图片测试未执行。本批新增 7 项 XCTest（6 个 CameraNetworkTests、1 个 CameraWorkspaceTests），测试真实复制和正式适配器，PhotoKit 授权/导入回执用已有 fake 注入。UIWindow/系统窗口、Kotlin 导出名字及真实 PhotoKit 必须在 Mac 验证。

## Mac 必做场景（本批不计已通过）

先按 [Mac 首次操作指南](../测试与验证/iOS首次Mac操作指南.md) 构建 framework、Xcode Debug/Release 并运行 XCTest。以下属于主表 M 项；发现代码缺陷重开对应 W 项。

| 对应项 | 操作与核对 |
|---|---|
| W21 | AP/STA 下双卡、日期/保护/RAW/未传筛选，逐张和日期/连拍组入队；验证数量/顺序/取消/重复点击，刷新期间 handle 重用不能传错文件 |
| W22 | 滚到中段、折叠日期/展开连拍、选卡槽后进出队列/文件页；重建同连接页保留状态；断开换机不保留旧卡槽/旧滚动状态；目录缩短不崩溃 |
| W23 | 原片已存/未存/离线预览，快速换页及返回、旋转/直方图、连拍展开、过滤完成退出；来源变动不切错图，返回定位和源读取释放正确 |
| W24 | 单张/日期/连拍/自动入队飞入和实际计数、预览飞行落点、暂停/继续、快速切文件/队列；对照 Android 胶囊计时与空间转场，检查实际安全区和触感开关，不宣称像素/帧时序已等价 |
| W25 | 首包准备、连续传输、完成/跳过/失败、重试和暂停；断线/回前台无旧速度假运行，耗时/字节不跳错任务 |
| W26 | 未连接首页设置与文件页设置、三种语言/主题/触感/常亮；帮助/隐私/真实版本/复制 QQ/打开仓库链接；不出现 Android 支付或升级流程 |
| W27 | 真实 Files provider 名称、同名目录、重启恢复、撤权/移动、传输中拒绝切换、确认恢复沙盒；旧目录原片及授权不被删除 |
| W28 | 损坏/未来版本分别注入浏览、外观、传输、模式、目录偏好；读取不覆盖，用户确认才备份/重置；身份、其他偏好、照片和队列不被连带清空 |
| W29 | JPG/HEIF/NEF/已有视频的单项和批量加入图库；首次授权/拒绝/系统不支持/提交中取消/关闭页面；真实提交数量和原片字节保留 |
| W30 | 沙盒/provider、同名副本/中文名/大文件批量分享及 Files；取消/部分回执/重复回调/复制中关闭；接收方核对字节，私有副本只在系统完成后清理，原目录不变 |

W31—W50（取消排空、恢复/前后台、检查点、存储/性能/适配/跨页三语/权限/发布材料及跨模块最终验收）仍未结项，不因本批局部实现而重复计分。

系统回执边界参考 Apple 官方：[分享完成回调](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller/completionwithitemshandler-swift.property)、[Files 副本导出](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(forexporting:ascopy:))。
