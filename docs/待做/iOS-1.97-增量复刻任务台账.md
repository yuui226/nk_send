# iOS：安卓 1.97 增量复刻任务台账

## 基线与范围

2026-10-17 用户要求拉取安卓新改动、先整理文档任务再逐项复刻，并明确包含本地 android 最新改动。已fetch origin；远端3提交，本地另19提交，总22提交、172变化文件。旧基线89d78b45，新基线9c8c1216e4a7bafbbc906f8ea47b851b14a3078d（1.97/70），合并a36b339c无冲突，合并前后ios树一致。来源树保留鸿蒙文件，但不移植鸿蒙专属实现。

延续本线程范围：优先功能/状态/错误/取消/重试/持久化及逐字文案，纯视觉与动画单独列为延期，不借功能迁移宣称视觉验收；用户此前指定液态玻璃默认、USB/STA信号禁点、450ms长按、系统方向、录制无总期限、公开PTP直通等差异继续有效。主代理独立处理。真机验证集中进行，不因同步覆盖已验证的USB连接/传输实现。

## 任务

当前 **18/18 开发侧完成**；真机验证待集中进行，纯视觉与精细动画按用户要求延期。此计数表示本轮功能组完成实现、源码对照和模型/业务专项，不表示真机验收完成。

|编号|行为与验收范围|安卓依据|状态|
|---|---|---|---|
|D01|Zf v2.1/1024帧头、完整坐标点击对焦、姿态/AF兼容|LiveViewMetadata、ZfLiveViewFocusTest|开发侧完成；15项专项通过，待真机|
|D02|录像剩余时长独立于AF几何；0x9203旧帧Zf/Z30回退、未知头拒绝|LiveViewMetadata、MonitorRemainingTest、LiveViewVideoDiagnostic|开发侧完成；帧解析及当前/旧协议只读诊断专项通过，待真机|
|D03|PC开关持久化、进入/退出恢复相机控制、应用模式串行收尾与Busy重试|RemoteComputerControlState、RemoteMovieApplicationState、RemoteScreen|开发侧完成；52项边界回归通过，待真机|
|D04|退出PC后再刷新目录；存储查询失败保留已有卡和照片缓存|CameraStorageResponse、CameraViewModel、TransferViewModel|开发侧完成；失败保留与列表刷新专项通过，待真机|
|D05|监看回看目录、JPG/NEF合并、拍摄新增文件追踪与分页|RemoteReviewCatalog、RemoteActivityTracker及测试|开发侧完成；9项目录边界及实际新句柄/别名去重通过|
|D06|监看回看入口、横竖屏大图、加载取消、帧门控和关闭恢复监看|RemotePhotoReview、RemoteReviewFrameGate、RemoteEntryInstrumentation|开发侧完成；回看模型/真实帧暂停/断线收尾专项通过，待真机|
|D07|优化校准NP3解析（未知/不支持格式拒绝）、编码、柔性颜色识别和能力校验|NikonPictureControlData/File/Encoder及fixture|格式层开发完成；74条真实读回/6份导出对照通过，写入入口属D08/D09/D13|
|D08|优化校准九槽探测、选择、U档切换与写入规则|NikonPictureControlProbe/Selection、RemoteExposureProgramTest|开发侧完成；实际九槽/U档/照片视频银行协议测试通过，待真机|
|D09|优化校准写入、备份、替换、失败恢复和取消|NikonPictureControlWriter、PictureControlBackupStore/Replacement及测试|开发侧完成；首备份、读回、激活、失败回滚、跨槽取消串行专项通过，待真机|
|D10|内置优化校准资源、目录与来源许可|BuiltInPictureControls、assets/picture_controls、fixture来源|资源层完成；实际应用Bundle20项及SHA/编码验证通过，选择入口属D13|
|D11|预设文件夹共享授权与串行I/O队列；LUT迁移保持独立配置|PresetFolderRepository/Grants、SerialPresetQueue、LutFolderRepository|开发侧完成；独立书签、FIFO/取消/清理/异常及既有LUT回归通过|
|D12|优化校准文件夹持久化、重扫、异常恢复|PictureControlFolderState/Preferences、FolderInstrumentation|开发侧完成；目录事务/重启/失败保留/超时取消专项通过，Provider真机待验|
|D13|预设分类合并、选择面板、九槽替换交互及灵活颜色提示|PictureControlPresetChooser/ToolState/Reports、RemotePictureControlPanel|开发侧完成；面板准入/取消/异常专项通过，分类和日志分享接线完成，待真机|
|D14|大图预览编辑照片效果、独立草稿、关闭提交、加载取消、免费水印语义|PhotoPreview、PhotoLutEditor、PhotoPreviewEffectsTest|开发侧完成；JPEG/总开关/非回看门控、草稿和空选择回退专项通过|
|D15|预览效果缓存、取消/过期结果隔离、缩放与拖动几何|PhotoEffectsPreviewCache、PreviewGestureGeometry及测试|开发侧完成；缓存/淘汰/取消、串行保留最新结果和几何专项通过；实际手势待真机|
|D16|监看工具/参数弹窗交互、触控层级、预设与LUT开关联动|RemoteCameraToolPanel、RemoteParameterPanel、RemoteToolPreferences|开发侧完成；固定工具/排序/隐藏/独立模式专项通过，视觉延期|
|D17|设置/列表/拨轮公共控件新增行为逐hunk核对，保留已批准iOS差异|SettingsScreen、FileListScreen、ReleaseCommitWheel、AnchorPopup|功能hunk核对完成；多行提示时长已接入，拨轮颜色/连接光效延期|
|D18|三语新增文案、1.97版本与生产接线总核对|strings.xml三语、工程版本、172文件来源索引|开发侧完成；817资源可重复生成、三语实际查找和Bundle版本通过，172来源逐项归类/哈希核验|

## 范围排除与保留

- 鸿蒙发布重试、JPG回读验证、SAF兼容、诊断清理：仅记录来源，不引入iOS。混合文件中的普通路径另查。
- 安卓授权服务器应急保Pro/域名迁移、APK更新失败安装及运营脚本：沿用既有StoreKit/App Store平台差异，不复制到iOS。
- 原生USB Bulk诊断移除不等于删除iOS本机排障日志；此次USB数据协议主流程无对应强制替换。
- 连接光效、预设弹窗动画/图标等纯视觉改动延期；其中触控、可见性、关闭、层级与阻塞逻辑仍纳入D16/D17。

## 验证记录

- fetch成功；用户确认本地19提交也纳入。
- git merge android成功，无冲突；git diff --quiet HEAD^ HEAD -- ios通过；未推送。
- 合并时尚未运行构建或测试；后续专项记录如下，合并成功不代表iOS复刻完成。

D01/D02：RemoteFrameParser新增共有v1.0/v2.1布局门控，后者仅允许1024头；既有focus命令已用完整坐标域，未改成预览尺寸。packetVideoTime独立解析增强/旧帧，旧帧仅Zf/Z30，长度/JPEG/录制标志/上限/零值严格对照；RemoteViewModel保存会话型号并发布独立时长，RemoteView实际读取，清帧同步清时长。每帧只复制≤1027字节而非整帧作时长解析。/tmp/ztransfer-197-frames-tests.log实际15/15、0失败、TEST SUCCEEDED（新增4项边界+6显示+5姿态）。未真机Zf验证，不宣称完整相机兼容。

D03/D04中间验证：/tmp/ztransfer-197-storage-tests.log为33/33、TEST SUCCEEDED，证明失败存储查询保留已建照片基线、DeviceBusy两次后成功、有效空数组才删除；/tmp/ztransfer-197-pc-tests.log为124项、4跳过、0失败、TEST SUCCEEDED（跳过为既有模拟器麦克风权限前置）。后续又补页面/会话独立前台占用、同相机会话可取消串行准入、旧清理完成才新监看入场、应用模式清除单飞及Busy200ms重试，不能将上述旧测试结果冒充这些后续改动已通过；新session-review专项进行中。

D05进行中：RemoteReviewCatalog及CameraRepository/CameraSession接入新鲜句柄快照、每页读取、完整时间组后发布、JPG/NEF/备份配对、坏响应重试。新增4项模型测试，尚未接监看回看UI，不标完成。通过xcodegen把新模型/测试纳入工程。

D03/D04最终开发侧核销：final-boundaries首轮主动中止，静态发现排队监看stop没有取消准入等待，随后仅在未持有相机会话时取消frameTask，保护已接受命令。最终`/tmp/ztransfer-197-final-boundaries-fixed.log`为52/52、0失败、TEST SUCCEEDED，含最新帧门控测试；`/tmp/ztransfer-197-review-lifecycle.log`为8/8、TEST SUCCEEDED，其中4项列表暂停、新句柄刷新、断线不扫旧会话、预览后延迟刷新，另4项新增回看模型测试。PC偏好生产入口、隐藏清偏好、进入恢复与退出释放、应用模式非取消单飞与Busy重试、页面和会话独立所有权、失败存储保缓存已核对。未真机验证，未提交/推送。

D05/D06后续接线：新增RemotePhotoReviewModel，独立代次、200ms登记等待、目录失败或空结果单次EndLiveView回退，分页与预览共享兼容状态；关闭等待已接受加载与兼容命令后重启或恢复帧读取。复用PhotoPreviewView，回看禁用传输/裁切，新增分页、配对标题、失败重试与断线文本；三语逐字对照remote_review四项。实际按钮/页面接线验证中，尚未核销；无UI自动化或真机安装。最新接线后的标题/重试补丁仍需再次编译验证。

D05/D06最终接线阶段：`review-final`12/12通过，包含实际Repository在监看占用下读取新句柄、双卡别名去重；后续发现安卓回看还暂停事件/电量/ISO/水平/测光/隐藏显示轮询，已补保持开关偏好不变的暂停及1秒保活，`np3-fixed`中实际生命周期测试通过。分页前缀、迟到RAW配对键与缺日期双卡补充测试正在`presets-backup`运行，暂不核销。

D07：NikonPictureControl.swift分离NP3容器/相机36或614字节数据集/578字节曲线，严格拒绝损坏、未知版本或ID，不把未知格式猜成灵活颜色；编码保留明确基础ID映射、手动锐化与能力限制。测试资源原样复制安卓Z30读回、六份导出与Flexible Color来源/许可。`/tmp/ztransfer-197-np3.log`11项1失败：测试错误要求两份未展示研究样本可编码，生产拒绝未知0x0486是正确结果；修正只对目录20项要求可编码，保留22项解析/曲线核验。`/tmp/ztransfer-197-np3-fixed.log`15/15、TEST SUCCEEDED，其中格式7项覆盖74条成功读回、6份独立导出逐字节、22文件和所有截断/能力/流取消，九槽/U档3项，回看4项及轮询1项。D08只有描述符和U档基础模型，尚未接实际写入。

D09/D10进行中：新增首份不可覆盖的PCB v1/v2备份、Java modified UTF-8身份兼容、校验/持久发布和跨实例锁；新增Replacement取消后完成读回/激活/回滚的实现，尚未编译或接相机。22份NP3/catalog原样置于ios/PictureControls，实际Bundle目录20项及完整性测试、备份并发/损坏专项正在运行。未把模型存在当完整写入功能，D09/D10仍待核销。

D05/D10后续核销：`/tmp/ztransfer-197-presets-backup.log`13项中12通过、1失败，失败为工程未复制PictureControls目录；备份3项和回看9项通过。已改为XcodeGen sources显式folder资源阶段，`/tmp/ztransfer-197-writer.log`7/7、TEST SUCCEEDED，含实际Bundle20项逐个SHA/大小/名称/编码校验和6项Replacement备份/回滚/取消/断线测试。D05目录与D10资源核销，D06断线关闭的最后补丁尚待重验。D08/D09已补NikonPictureControlAccess与Repository/Session协议接线：整体写入保留focus/IO/PTP序列所有权，单条已接受命令独立完成，5秒命令期限；只读九槽逐命令让出帧通道。`picture-protocol`正在验证实际仓库读写，不把尚未完成的页面选择/导入/恢复界面标完成。

D03–D05阶段回归：/tmp/ztransfer-197-session-review-tests.log为191项、4跳过、0失败、TEST SUCCEEDED；跳过仍为既有麦克风权限前置。此轮编译后又补取消等待者不释放活跃会话、回看分页等待取消、帧事务边界门控，故最终边界验证另记/tmp/ztransfer-197-final-boundaries.log，当前运行中，不据旧结果核销。首次启动最终验证的自动审批超时，命令未启动；按工具许可重试一次后已启动。回看帧门控已接取景读取，不取消已接受帧；回看UI尚未接入。

D06/D08/D11阶段验证：`picture-protocol`8项中7通过、1失败，为测试设备描述符遗漏实际首个预设基础项3；修正夹具后，`/tmp/ztransfer-197-shared-presets.log`61/61、TEST SUCCEEDED，含实际Repository写入/U档、独立队列FIFO/取消丢弃/回调异常、两种LUT与回看断线关闭。D06开发侧核销，详细视觉/手势几何另属D15；未做UI自动化或真机验收。D11目录泛化、D12独立NP3书签/十秒超时正在folder专项验证；D13面板接线尚未编译验证，不能标完成。

后续验证（覆盖上述进行中记录）：

- `folder`39/39通过（NP3目录和既有LUT）；`editors`16/16通过（独立草稿、目录恢复、面板准入、工具布局）；`preview-cache`9/9通过（共享任务/等待者取消、依赖取消后恢复、草稿和面板）。日志均为`/tmp/ztransfer-197-<名称>.log`，均TEST SUCCEEDED。
- `panel`首轮因构建期间异步读辅助类型API调整导致编译失败，未运行测试；后续`editors`完成验证。`tools-final`发现初始化闭包过早捕获self，改为局部availableIDs后，`tools-fixed`49/49、0失败、TEST SUCCEEDED。该轮覆盖实际Repository九槽/两种U档银行、面板关闭等待已接受写入、跨槽串行取消、缓存、LUT和固定锁定/旋转、真实三语查找及1.97 Bundle版本。
- 九槽探测依据是生产`readPictureControlSlots`，C1–C9逐槽返回占用/空/不可读/不支持；`NikonPictureControlProbe`仅是安卓未被产品调用的研究读取计划（全仓调用检查只有定义及测试），不增加iOS隐藏探测按钮。U1–U3只在U档读取有效曝光模式，写入允许P/S/A/M及对应U档，照片/视频银行独立。
- 写入整体持有相机串行门，首份PCB备份不可覆盖；已接受写入在离页面后仍完成验证/激活/失败回滚，回滚使用本次操作前的内容。页面失效阻止新操作，真实会话断开或银行变化阻止继续写入；离页面本身不能提前放开相机通道。
- D11/D12保留三组独立书签（监看LUT、照片LUT、优化校准），共享有界FIFO和授权引用；根目录+一级分类、大小/数量有界、成功扫描才替换旧快照、失败/超时不丢旧目录，取消等待者不抢占文件Provider已接受工作。真机外部Provider尚未验收。
- D14复用设置草稿，明确当前照片和旋转，从已有FHD/EXIF升级，不另请求最新照片；仅总开关开启且非监看回看的JPEG提供入口，关闭提交到全局效果。安卓没有新增“取消草稿”按钮，任务标题里的“应用/取消”指提交与加载取消，不另造撤销语义。纯样式与动画仍延期。
- D16锁定与旋转成为固定按钮，不受旧隐藏/排序数据影响；优化校准仅初次插入默认位置，后续用户排序保留。横屏工具面板打开时底层返回不穿透。工具、目录分类与LUT文本按安卓实际资源查找。
- D18原先只补`.strings`不足以覆盖AppLocalized运行路径；已生成实际AndroidLocalization资源字典并保留7个仍由iOS使用的平台文案，新增三语查找测试已通过。新增同步脚本只改资源映射，不覆盖iOS平台override。版本1.97，iOS构建号仍独立。

最后混合hunk检查发现D02旧录像诊断尚未更新为“当前协议+旧协议”，正在补齐验证；此前D02完成结论仅覆盖帧解析与展示，不包括该遗漏。D15的动画参数延期，但过期画布隔离及并发过渡不能丢失最后一帧仍属功能核对范围，继续处理后核销。

## 最终开发侧收尾（2026-10-17）

- `/tmp/ztransfer-197-final-audit.log` **11/11、0失败、TEST SUCCEEDED**：新增诊断只读取当前/旧协议、只导出已知帧头片段、不包含JPEG；现有真实Repository调用回归、三容量LRU复用/淘汰/上下文变化及缩放/拖动/裁切布局几何通过。D02遗漏已补，不再沿用旧“分钟/秒”猜测。
- `/tmp/ztransfer-197-preview-final.log` **14/14、0失败、TEST SUCCEEDED**：预览更新队列完成当前工作后仅接续最后一个待处理结果；离开取消、丢弃旧生命周期并允许重入；缓存5项、效果草稿3项和预设面板4项回归通过。生产画布在替换前复检最新方向/边框，失败恢复旧图，原图失败回退保持完整比例和当前旋转。仅修功能状态，未做动画参数或逐帧视觉验收。
- D13调试报告保留每次独立追加文件、恢复最近非空报告、分享不可变快照，包含iOS应用版本/构建号和照片/视频银行；开发日志合并预设报告，超过180000 UTF-8字节提示改用分享，防止直接塞入剪贴板。槽位按钮、清除确认、取消准入、写后验证与错误优先级已接实际Repository。
- D14空选择时草稿回退第一个滤镜并读取其保存强度，不启用滤镜、不修改未提交的全局配方；效果专用页也接提示浮层。关闭提交沿用安卓，免费水印仍走既有统一生成规则。
- D17混合hunk逐项确认：FileList传递全局效果开关；ReleaseCommitWheel新增仅标签颜色；Home仅连接光效收尾；Settings新增草稿/FHD/缓存行为已归D14/D15，提示单行1800ms、多行3600ms；APK更新按钮逻辑按平台约定排除。AnchorPopup的精细动画延期，原生模态承载隔离底层操作；回看使用原生单/双击识别与翻页/捏合门控，并拒绝非当前页面迟到点击。未宣称实际触摸或截屏验收。
- [来源索引](iOS-1.97-增量来源索引.json)保留172个真实Git路径和目标提交SHA256，所有非删除文件按目标提交重算一致，未用本地已调整的AGENTS.md冒充目标版本。每项明确任务归属/排除理由；研究Probe没有生产调用，不增加多余入口。817个三语资源重新生成后内容哈希一致；`git diff --check`通过。
- 最后三组验证分别为49、11、14项，存在回归重叠，不将74次执行冒充74个不同测试。前述失败/中止记录保留。未运行UI自动化、安卓APK构建、真机安装或相机实际写入；未提交或推送本轮iOS改动。

### 尚待真机验证（不计作已经通过）

1. Z30/Zf实际帧头、PC开关进退、监看回看与拍摄后新文件，以及USB重连/首次传输回归。
2. C1–C9读取、照片/视频银行、P/S/A/M与U档、真实写入/清除/读回；异常/断连后相机恢复。模型协议重放不替代相机固件行为。
3. 系统文件选择器及外部Provider的安全作用域、重开、权限撤销、超时；分享报告的系统弹窗。
4. 大图效果入口、旋转/捏合/翻页和设置关闭提交的实际操作；精细样式及动画另行集中处理。

真机未自动打包或安装，保留用户约定的集中验证节点；iOS公开PTP直通和已验证吞吐修复不回退。

### 完成审查

续轮重新读取当前工作树和实际日志，确认分支为ios，目标安卓9c8c1216是当前HEAD祖先；来源索引与Git真实变化文件集合完全一致（172项），没有遗漏本地android增量。逐项对应D01–D18的生产接线及验证记录，重新检查上述15份阶段日志：14份成功，`presets-backup`的历史1项失败仍原样保留，且对应Bundle缺失已由`writer`实际应用资源测试及后续协议测试验证修复；不将历史失败写成成功。最终49/11/14项成功标记与实际日志一致，当前`git diff --check`通过。

本轮用户要求的功能迁移及文档/任务交付完成。未将开发侧完成扩张为真机固件兼容、外部Provider或触摸验收；这些是后续集中验证事项。用户明确排除的UI自动化、鸿蒙和精细视觉不作为本轮未实现功能；未擅自执行安装、提交、推送。

## 用户追加功能检查（2026-10-17，开发侧复核完成）

### 2026-10-18 新手机首次启动授权阻塞

用户在新iPhone 15 Plus首次启动后反馈开屏结束、全部动画停住且无法操作，并明确确认“出现权限提示，同意后恢复”。旧版诊断日志`/tmp/ztransfer-firstlaunch-console.log`记录browser.start仅约6ms返回；控制权限notDetermined到authorized约8.78秒。源码RootView.task→ConnectionViewModel.startUSBDiscovery/refreshUSBAuthorization在主线程同步执行ICDeviceBrowser授权查询和请求；回调形式不代表请求入口不会同步等待。现场线程采样未成功（xctrace等待超时、LLDB未获得暂停栈），因此不冒称取得阻塞栈或精确主线程卡顿时长。

修复：只将授权状态查询、内容/控制授权请求及其完成处理放到专用串行队列；主线程及PTP准入读取锁保护的缓存，不执行授权IPC。发现浏览器仍保留原运行循环线程，内容→控制权限顺序、双授权准入、拒绝/受限处理、重复请求抑制、停止后的代次隔离保持；未恢复requestOpenSession或全卡枚举，也没有添加延迟掩盖冻结。安卓CameraViewModel.requestUsbPermission依据仍为异步等待授权、授权前不连接，相应iOS权限范围约定未改。

`/tmp/ztransfer-firstlaunch-fix-tests.log`：38/38、0失败/跳过、TEST SUCCEEDED。新增真实生产授权入口的可控同步阻塞测试：控制请求阻塞期间主运行循环仍响应且多次刷新不重复请求；状态查询阻塞期间缓存读取/停止可返回且迟到结果被忽略；内容拒绝时不请求控制授权。原USB直通握手、错误映射及连接状态一起回归。未运行UI自动化。

交付：`/tmp/ztransfer-firstlaunch-fix-device-build.log` BUILD SUCCEEDED、exit0；已覆盖安装新iPhone 15 Plus，目录88E6DC02-10B5-4124-ACB9-970554A62836，普通无参数启动成功。该机已获授权，未重置权限/清数据，因此此次启动不是修复版首次授权真机重演。git diff --check通过，未提交/推送；用户实际观感待反馈。

后续真机确认：用户要求完整卸载后重新安装，devicectl卸载与安装均成功，新目录A56C36AE-A0D4-4FC5-B0DB-B7448DE5D9C1；保留首次启动给用户操作。用户明确反馈“这次首次启动不卡了”，据此本轮卡顿问题收尾，并按用户要求提交代码、测试及记录。不推断系统卸载后所有权限均被重置，也不扩大为所有机型已验收。本次未新增构建/测试或推送。

### 安装后第二轮复核（2026-10-17）

用户要求提交后的a53e1c6d已完成真机Debug构建（`/tmp/ztransfer-197-device-delivery.log`，BUILD SUCCEEDED），覆盖安装至iPhone 15，安装目录DDA22E75-A80C-4880-ACAB-93F31DAD3BD6，普通启动成功。用户随后再次要求检查。第二轮复查USB直通入口、预设写入取消后的验证/回滚、回看关闭隔离、目录书签恢复及共享预览缓存生命周期；未发现新的确定性功能缺陷，无生产代码修改。

补充上一轮27类集中回归之外的CameraConnectionPresentationTests、CameraDownloadTests、MonitorStorageSchedulingTests和RemoteLUTLoadQueueTests；复用现有构建运行，`/tmp/ztransfer-197-second-audit.log`为57/57、0失败/跳过，TEST EXECUTE SUCCEEDED、exit0。涵盖USB/STA连接呈现、64MiB流式下载与大图导出并行及取消、下载完整性/重试/重名保护、存储查询排队后的权限重查、LUT文件变更和权限撤销后的缓存失效。

只读查询真机进程时CoreDevice返回4016（当前不满足设备服务连接条件），未取得新运行状态证据，不据此推断应用异常；没有重启手机、操作相机或再次安装。本轮检查不能代替真实拔插、固件兼容与外部Provider验收。git diff --check通过，仅补充检查记录，未再次提交或推送。

不能把此前18/18开发侧核销理解为“绝无异常”。用户追加检查后，对生产入口和失败恢复进行复核，发现以下缺口并修复，集中回归结果随后补记：

1. **预览缓存键不稳定（D15）**：实际`PhotoEffectsSettingsPreview.makeRenderKey`用无排序JSON编码，重复相同参数会生成不同键，导致重复渲染/缓存丢失。此前缓存测试使用人工字符串键，未覆盖真实生成入口。新增实际入口测试在旧实现复现2个断言失败，日志`/tmp/ztransfer-197-audit-reproduction.log`（6项、2失败）；现已对完整预览及中间滤镜键固定JSON字段顺序。
2. **预设目录暂时不可解析后无法恢复（D12）**：启动时folder为nil就不再刷新，忽略仍保存的书签。改为按持久书签允许重试，成功后提交刷新书签和目录；失败不丢授权。新增失败→恢复→重开测试，连同原4项在上述复现轮5/5通过。
3. **回看页面丢失拍摄身份（D06）**：目录在RAW后补JPEG时保持首句柄身份，但实际TabView使用优选文件句柄，造成页面被重建。现将页面身份与实际读取句柄分开：保留拍摄/手势身份，读取升级为JPEG；普通预览身份不变。已有迟到配对测试扩展到生产使用的分页模型。

另外新增实际CameraRepository/PTP序列的“相机改槽后返回GeneralError”测试：必须读回、恢复本次写前数据、验证并还原激活项，首份备份仍不覆盖；不只在抽象SlotAccess模型上验证回滚。该测试已在27个相关功能测试类集中回归中通过，未运行UI自动化或真机安装。

4. **旧预设面板迟到失败影响新页面（D13）**：初次读取失败未检查closed/cancellation/current，可能调用旧notice/dismiss回调。已对关闭、取消及旧会话加隔离；新增关闭后迟到失败和换相机后迟到失败测试。另按安卓当前固定锁定按钮规则纠正RemoteToolPreferencesTests的旧断言，保持锁定状态，不回退生产功能。

集中回归 `/tmp/ztransfer-197-functional-audit.log`：417项，413通过、4项因模拟器麦克风权限前置条件跳过、0失败，TEST SUCCEEDED。最后修改后的面板6项及工具偏好3项专项 `/tmp/ztransfer-197-audit-final.log`：9/9通过，0失败/跳过，TEST SUCCEEDED。设置专用模拟器麦克风拒绝权限后，录制4项单独复验 `/tmp/ztransfer-197-audit-recording.log`：4/4通过，0失败/跳过，TEST EXECUTE SUCCEEDED；使用已有构建，未重复编译。覆盖权益过期/撤销及并发退出收尾、隐藏工具与横屏固定录制差异、目录不可写回退和最终视频可解码。

本次发现的4处功能缺陷已修复，原417项均获得通过证据，最后修改另有9项通过；不是417+9个互不重复用例。git diff --check通过。保留缓存旧实现复现失败和初轮权限跳过记录；未将模拟器协议测试当成真机固件、USB冷连接、外部Provider或触摸验收。开发侧复核完成，未安装、提交或推送。
