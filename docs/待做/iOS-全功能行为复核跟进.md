# iOS 全功能行为复核跟进

## 当前任务范围（用户于2026-10-16明确调整）

- 用户要求：“ui测试的可以跳过，你只负责功能逻辑完整复刻，不负责样式和动画复刻”。此最新要求优先于此前样式/动画逐项对齐要求：后续不再开发或验收纯样式、动画，也不再自动运行UI测试。
- 用户补充：样式本阶段只做到基础可用，确保功能入口、操作与必要状态反馈可用；精细样式、动画及播放效果留待后续集中处理。允许为功能可用性做必要的基础界面调整，但不继续逐帧/像素或视觉参数对齐。
- 仍须完整对照安卓的功能、业务判断、状态流转、错误、取消、重试、持久化和数据安全；可继续运行已授权范围内的模型/业务专项验证。涉及页面但影响连接、任务或数据状态的逻辑仍在范围内，不能因属于UI文件而漏掉。
- 纯视觉条目按范围排除处理，不伪记为已修复；混合条目须拆出功能要求。原30/182为历史全量台账口径，功能口径总数待逐条重分类，不推算虚假完成率。
- 用户已批准液面UUID稳定映射方案，但随后排除动画复刻，故该映射暂不实现；业务UUID保持不变。


## 最新修复状态（2026-10-17）

- 2026-10-17最新：U001当前Z30连接后约一分钟首屏等待已修复并安装，用户重新插线确认“几秒内出现”。默认版启动日志实测首批句柄0.68秒、首条照片信息0.83秒；不再调用系统全卡目录打开接口，普通启动同样生效。最终连接/握手专项30/30通过；精确计时属于应用启动，重插速度由用户确认，完整证据与限制见文末。冷启动误入照片页已修正。

- 2026-10-17 U001早期真机记录（后续处理见文末）：用户确认重新插入后已进入照片列表，但持续转圈；/tmp/ztransfer-usb-loading.png确认列表空加载态，workspace-console记录sessionOpened后首条12字节GetDeviceInfo未回调。系统10:24:19开始PTP1.0 enumeration并接收sendPTPCommand，尚无complete catalog。用户明确要求应用自主加载、不要依赖系统加载。已核对当前SDK ICDevice.h/ICCameraDevice.h及Apple ICSessionOptions/ready文档：未找到公开的关闭系统枚举选项（仅声明enumerationChronologicalOrder）；不能将移除应用ready等待误说成关闭系统枚举，也不能宣布持续转圈已修好。当前保持连接排查，没有新增构建、接口试验或自动化测试。
- 2026-10-17 U001早期诊断记录（非当前状态）：系统日志证明OpenSession前已读出Z30 DeviceInfo，随后系统全卡枚举与应用重复GetDeviceInfo排队。按用户要求，会话打开成功即发布CameraSession；移除ready等待，将补充DeviceInfo移到两条scanCatalog入口、缓存身份选择前。撤回无改善的MainActor/selector试验。/tmp/ztransfer-usb-workspace-build.log BUILD SUCCEEDED，已安装启动；/tmp/ztransfer-usb-workspace-console.txt仅授权事件，截图/tmp/ztransfer-usb-workspace.png仍为连接页，当前未收到deviceAdded；系统最后断开时间10:20:38。尚未验证新版本连入列表、照片枚举或传输，不标修复完成；未运行新增自动化/UI测试。
- 真机问题 U001早期记录（当前修复结果见上文及文末）：iPhone 15 / iOS 27.0.1 / Nikon Z30，USB-C直连停在连接页。原174/182是开发侧历史核销，不代表此真机问题已通过。实测发现`openedCamera(for:)`错误回退到opening/discovered对象，使首次连接跳过requestOpenSession；已改为只返回openedCameras并安装。修复前日志无sessionOpened，修复后出现sessionOpened，相机指示灯闪烁，但尚无ready且仍停连接页，继续排查目录枚举，不能标修复完成。日志：`/tmp/ztransfer-usb-diagnostic-console.txt`、`/tmp/ztransfer-usb-open-fix-console.txt`；真机构建`/tmp/ztransfer-usb-open-fix-build.log` BUILD SUCCEEDED。诊断仅DEBUG且环境变量ZTRANSFER_USB_DIAGNOSTICS=1开启，不记录照片数据。
- 历史编号 F001–F182：已核销 174 项，剩余 8 项均为延期视觉任务。核销表示当前功能范围的开发侧实现与所列证据，不代表全部真机或视觉验收完成。
- 历史F编号功能部分已收尾；新增真机问题U001的当前Z30连接及首屏等待已按本轮证据收尾。用户于2026-10-17明确同意 F171 保留 iOS 系统方向判断，接受与安卓角度分区的差异；保留 UIDevice 分类，不引入 CoreMotion。既有候选取消、260ms 稳定规则、最新请求保留及恢复时重新采样逻辑继续生效。
- 用户于2026-10-17明确接受两项平台差异：F142 保留无总收尾期限，不添加 8 秒截止；F177 保留 450ms，不改为 500ms。结合既有实现、专项验证与生命周期源码复核，两项功能范围核销；不声称收尾等待有界或实际手势回放已验证。
- 延期视觉任务：F003、F016、F041、F080、F083、F152、F179、F182，共 8 项，不计已修复。
- 下文早期累计数均为历史快照；逐项实现、验证限制及最新核销证据见表格和末尾续记。

## 目的与基准

2026-10-15 用户要求：按功能建立完整大纲，逐项核对安卓与 iOS 的真实行为，主动找出该复刻但遗漏的逻辑，减少依赖用户反复试用发现问题。本轮由主代理自行审查，不分派子代理。

- 安卓基准：当前工作树 `app/`，与已合入的 `89d78b451d03e50da965a46f047744aa8a34877c` 无差异；工作树 HEAD 为 `ba3196226301209cd61d8f1303f67c7647ceab99`。本地 `origin/android` 已指向 `7fcade77`，**尚未合入的远端变化不混作当前 iOS 漏项**；需要单独辨认是否影响检查结论。
- iOS 基准：当前 `ios/`，包括所有未提交和未跟踪的新实现。旧台账“完成”仅作为线索，每项结论必须回到当前生产入口、状态流和测试。
- 本轮任务是检查和记录；发现缺口后列出触发条件、影响、代码依据和最小验收场景。没有把审查授权扩成大范围业务修改、打包、安装、提交或推送。
- 代码可静态证明的接线与行为、实际运行过的测试、仍需真机验证的现象分别记录；未运行的测试不记通过。最终完成本轮审查也不等于所有发现已修复。

## 每个板块的检查维度

1. 从用户入口追踪到模型、协议/存储，再回到 UI；检查可见性、禁用条件及空状态。
2. 正常路径与边界：失败、超时、取消、重试、断线/重连、快速切换、迟到回调、后台/前台。
3. 状态所有权：会话/页面/任务身份、草稿与正式配置、独立作用域、持久化及恢复。
4. 对照文本、布局、手势和动画参数/中断规则；公共机制集中记录，但业务调用不得漏检。
5. 阅读对应安卓测试及 iOS 测试，确认测试调用的是生产路径；记录覆盖缺口，不用同名测试代替行为证据。

## 范围例外（不计作漏复刻）

- 正式版更新走 App Store，不搬安卓 APK 自更新服务器、下载和安装链；已有 B17 约定，本轮按用户问题再次核对。
- StoreKit 替代安卓激活码/设备绑定/自建授权服务；年度、永久、优惠码、退款/撤销按已确认苹果方案。
- 已入队任务冻结水印；STA 会话内缩略图按顺序加载，前台任务让路，禁止按格子显隐取消重排。
- 鸿蒙专用存储/损坏诊断不迁移；已批准排除的实验性全量能力/属性/追踪矩阵扫描不恢复。正式完全控制和有界只读诊断仍需分别审查。
- AP 信号强度是明确例外：2026-09-18 决定不读取 RSSI，不申请 Wi-Fi Information capability，在线固定四格且点击无动作；见 `docs/技术调研/iOS-AP模式信号按钮复刻.md`。已有文档另明确 AP 候选用本机子网近似网关检查，普通后台会话不具安卓前台服务语义；不伪称平台完全等价。
- 其它平台差异只有找到现有明确依据才可排除；不得凭“iOS 特性”推断豁免。

## 功能大纲与进度

状态含义：**待查**；**检查中**；**已查·有缺口**；**已查·静态一致**（仅指定范围）；**已查·平台例外**。每项还须单列测试和真机限制。

当前审查进度：**32/32 项已完成静态审查**。这不是复刻完成率。共登记 **F001–F182**；F052已有修复及另一轮17/17历史日志，F053当前已有修复代码、待该轮验证，其余记录按各自状态跟进。另有V001–V008待运行/平台证据，不混入已确认问题数。

| 编号 | 功能板块与覆盖边界 | 状态 |
|---|---|---|
| C01 | 启动、主页/工作台/照片/队列/监看导航、恢复与前后台 | 已查·有缺口 |
| C02 | AP Wi-Fi：发现、连接、错误、信号/重连、GPS 互斥 | 已查·有缺口 |
| C03 | STA：发现/配对/清配对/重试、档案持久化、迟到连接隔离 | 已查·有缺口 |
| C04 | USB：设备选择、授权、插拔、会话恢复、下载降级 | 已查·有缺口 |
| C05 | GPS：BLE 配对/恢复、位置/海拔、频率、权限与会话生命周期 | 已查·有缺口 |
| C06 | 文件扫描：单/双卡、日期范围、分页快照、增加/删除事件 | 已查·有缺口 |
| C07 | 缩略图/EXIF：缓存身份、批次、失败缓存、后台顺序与前台让路 | 已查·有缺口 |
| C08 | 评级/保护：协议、扫描、配对、未知值、范围、诊断与偏好隔离 | 已查·有缺口 |
| C09 | 照片列表：排序/筛选/连拍、选择/入队、已传识别、滚动恢复 | 已查·有缺口 |
| C10 | 照片预览：FHD/本地解码、翻页/缩放/旋转、信息、手势入队 | 已查·有缺口 |
| C11 | 全局相机调度：优先级/FIFO、预约、屏障、取消、嵌套、关闭 | 已查·有缺口 |
| C12 | 下载：照片/视频、分块/完整对象、大小与完整性、暂停/续传/重试 | 已查·有缺口 |
| C13 | 保存：目录授权、按类型命名、去重、原片/派生发布、空间与失败 | 已查·有缺口 |
| C14 | 传输/生成任务：两条生命周期、资源上限、身份/效果快照、离线重试 | 已查·有缺口 |
| C15 | 队列 UI：状态/计时/速度、暂停/移除/重试/清理、滑动和动画 | 已查·有缺口 |
| C16 | 本地照片工作台：导入、草稿、预览、批次、取消、独立配置 | 已查·有缺口 |
| C17 | 效果模块：开关约束、免费/高级联动、收藏、相机/本地作用域 | 已查·有缺口 |
| C18 | 照片滤镜/LUT：分类、解析、强度、选择、预览/导出一致及缓存 | 已查·有缺口 |
| C19 | 边框/水印：样式、尺寸、文字/图片、品牌/EXIF/GPS、布局与快照 | 已查·有缺口 |
| C20 | 无损裁切：准备、范围/比例、交互、旋转/MCU、原图保留、重试 | 已查·有缺口 |
| C21 | 监看生命周期：入口引导、准备/关闭、断连/恢复、任务互斥与额度 | 已查·有缺口 |
| C22 | 监看操作：帧流、完全控制、拍摄/半按、相机录像与本地录制 | 已查·有缺口 |
| C23 | 相机参数：曝光/ISO/WB/对焦模式区域、菜单、拨轮、写入/回读 | 已查·有缺口 |
| C24 | 取景交互：缩放/平移/反挤压、对焦坐标、参考线、水平仪 | 已查·有缺口 |
| C25 | 监看信息/分析：DISP、规格/存储、直方图/波形/斑马/曝光尺、提示 | 已查·有缺口 |
| C26 | 监看 LUT：目录访问、选择/缓存、关闭/互斥、解析与渲染生命周期 | 已查·有缺口 |
| C27 | 监看工具布局：显隐/编辑/拖动、锁定、横竖屏、槽位与状态动画 | 已查·有缺口 |
| C28 | 设置：默认值/迁移、语言/主题/皮肤/常亮、持久化作用域 | 已查·有缺口 |
| C29 | 公共 UI：按钮/弹窗/拨轮、触感、灯泡/提示、三语一致 | 已查·有缺口 |
| C30 | 免费额度与权益门控：统计/跨日、传输/监看、降级时任务保护 | 已查·静态一致（额度核心；关联缺口见下） |
| C31 | 苹果内购：商品/交易/恢复/续订/永久/撤销、优惠码和配置缺口 | 已查·平台例外（R01–R05未闭环） |
| C32 | 更新及平台排除、诊断/Release 边界、全源文件与测试覆盖核销 | 已查·有缺口（更新属于平台例外） |

## 修复进度（2026-10-15起）

用户现已要求按本文逐项修复与补齐，稳妥实现并保持可维护性；这取代本轮先前“只审查、不修改”的任务范围。继续独立推进，不分派子代理、不自动提交/推送；按既定项目规则形成完整功能块后集中构建/自动化，真机验收单列。

历史修复核销 **152项**（沿用原182项历史编号；当前功能范围总数待重分类）：F052为此前已有修复和17/17验证；本轮F056–F059完成实现并通过最终56项定向回归。F053仍是已有代码待其验证；F064派生图片重名保存已通过17项定向回归，F145录制保存及目录回退最终6/6通过，F117画廊边框完整照片保护最终5/5通过（其中24组像素配置），F132裁切JPEG完整性已通过iOS与原生故障验证，F134暂存所有权与取消开发侧21/21通过，F133旧EXIF缩略图与尺寸元数据最终7/7通过，F135裁切资源限额与串行准入、F131原图头边界及分量采样校验均已完成下述开发侧验证。F063原片重名与发布预留已通过56项回归及1项原有测试迁移验证。F060实际目录创建门控及重试回归18/18通过。F061任务目录授权持有通过25项回归及1项双路挂起补强。F062启动准备屏障与当前会话临时保护最终32/32通过。F065生成队列已完成生产就绪旁路与关闭验证；F066独立解析/身份/补读交接与F067完整性、预算、共享和缓存已完成下述109项回归及8项边界验证，开发侧核销待真机。F072三路原片发布后裁切交接已完成下述85项回归、42项路径及12项生命周期验证；F068运行期暂停/恢复及单调展示已通过下述52项验证与42项下载回归，开发侧核销；F069设置store、根页面运行期传递、设置卡片开关和180ms动画已通过25项回归与真实设置页UI验证，开发侧核销。此计数不等于32板块或旧版本台账整体完成率。

### 第一组：下载完整性与照片失败重试（F056/F058）

- 行为依据：Android DownloadIntegrity.kt/DownloadIntegrityTest、NikonCamera.downloadToFile的完整对象双尺寸校验、TransferViewModel的照片失败/取消清part及只对视频复用完整part规则；保留USB的ImageCapture有界读取平台约束。
- 生产修复：完整GetObject统一同时校验声明长度与ObjectInfo/GetObjectSize可靠大小；照片临时文件在writer关闭后无论成功/失败/取消均清理，成功时临时文件已经被发布移动；TransferDirectoryIndex.completePartial显式只接受视频，防止旧版本遗留照片part在进下载前被错误发布。未知大小流及视频续传继续按原有规则。
- 新回归经过真实Repository/PTPSession/队列：自洽短读和超长、缺失/0/sentinel声明、目录大小和查询大小、响应后继续使用session、收到整张照片后负响应→无发布/无额度扣减→重试重新下载并只扣一次；旧照片完整part不能离线发布。原“完整照片part成功捷径”用例已按安卓改为视频场景，另新增照片拒绝用例，没有删除验证来掩盖问题。
- 首轮`/tmp/ztransfer-20261015-f056-f058.log`为TEST FAILED：新增测试把同一UserDefaults实例跨actor后继续使用，触发Swift6隔离编译诊断；已改成同suite的独立实例。最终`/tmp/ztransfer-20261015-f056-f058-fixed.log`及同名xcresult为 **50/50、0跳过、TEST SUCCEEDED**（下载29、完整性5、队列15、额度1）。未做真机验收；不恢复T21整体完成，F057/F059尚在继续。

### 第一组补充：STA照片请求与USB内存边界（F057/F059）

- 已重读Android VideoTransferPolicyTest、downloadChunkSize(videoTransfer=false)及NikonCamera完整分支：STA照片强制partial仍是单个全照片请求，短响应直接失败，超过Int32.max在发文件命令前拒绝；页面吞吐只影响视频。iOS传入videoTransfer，照片保持单事务，错误文案逐字采用安卓现有`Photo exceeds single-request size limit`。USB继续使用已记录的ImageCaptureCore 4MiB回调预算，不把STA流式通道套用USB限制。
- USB在本文件策略冻结时统一判断是否必须有界读取（大小未知或大于4MiB）：首次partial不支持时明确失败，已记住不支持后的下一份大文件也在发GetObject前失败；大小不超过预算的文件仍可用完整对象读取。复用已有resumeUnavailable错误与队列清part路径，不新增用户操作或虚构相机能力。
- 新用例实际经Repository/PTPSession：24/120MiB照片在两种页面各只发一个完整请求（以多个1MiB数据包流式写盘，不在测试中分配整张120MiB缓冲）、STA短读/查询尺寸/超上限/安全完整回退；2GiB USB视频首次不支持→第二大文件→小文件成功，确认没有大对象GetObject。原视频分块/续传、未知大小、USB有界成功路径和免费额度继续回归。
- 第二阶段首轮`/tmp/ztransfer-20261015-f056-f059.log`为TEST FAILED：新增测试错误引用TransferQueue内部私有错误格式化函数，已改为检查实际LocalizedError输出。最终`/tmp/ztransfer-20261015-f056-f059-fixed.log`及同名xcresult为 **56/56、0失败、0跳过、TEST SUCCEEDED**（下载34、完整性6、队列15、额度1）；所有本轮xcodebuild进程已结束，`git diff --check`通过。
- F056–F059只核销上述实现与开发侧回归，V004的真实USB未知大小EOF语义仍待机型/平台证据，不把脚本transport当实际ImageCapture流式支持，也未做内存/OOM测量。T21保持未完成直至剩余证据闭环，旧版本总体计数保持5/26、1/15、2/3。本轮未安装真机、提交或推送。
### F064：派生图片并发发布（2026-10-15）

- 对照安卓 `PhotoFrameExporter.reservePhotoFrameName/writeRenderedBitmap` 及名称冲突测试，在 iOS 生产 renderer 接入目录级共享预留。目录身份解析符号链接，返回 URL 保留调用方路径；名称大小写不敏感，预留锁不跨编码或写盘。
- 编码结果先写本次 UUID 隐藏临时文件，取消检查后移动至预留名称；成功后由目录现存文件继续占名，失败释放预留，清理仅针对本次临时文件。无需更改 UI、动画或队列并发数量。
- 新增重叠预留/失败释放测试，以及真实 JPEG 两路并发导出测试（旧输出和原片不变、输出独立可解码、无临时残留）。加队列场景回归共 **17/17，0失败，TEST SUCCEEDED**；日志 `/tmp/ztransfer-20261015-f064.log`，结果包同名 `.xcresult`。重叠预留用嵌套同步调用确定性覆盖，真实并发导出另测；未宣称两条真实 renderer 在特定指令处同步停住。
- F064 标记已修复待真机；外部文件 Provider、真机取消/磁盘失败尚未验证，不恢复 T22 整体完成。F145 已完成下述定向验证，独立核销，不恢复整个录制板块完成。

### F145：录制输出所有权（2026-10-15，已修复待真机）

- 依据 Android `RemoteScreen.startRecorderResolved` 的 SAF 新建文档/失败回退，以及 `ViewfinderRecorder.start` 的输出生命周期；iOS 原有 ViewModel 回退已接入，保持不变。
- 录制器移除预删目标文件，创建 UUID 暂存目录并仅清理本次目录；MP4 封装完成后使用与 JPEG 共用的 `OutputFileNameReservations` 选择空闲名称并移动发布。活动或正在收尾的 writer 拒绝再次 start，避免覆盖其暂存所有权。
- 第一轮 `/tmp/ztransfer-20261015-f145.log`：真实旧 MP4 保留、两个同名录制独立发布且逐帧解码、发布失败只清本次暂存、原录制测试及 JPEG 发布回归共 **5/5，0跳过，TEST SUCCEEDED**。模拟器诊断收集等候600秒后超时，Xcode最终退出0；保留该诊断警告，不将其写成测试失败或隐去。
- 最终 `/tmp/ztransfer-20261015-f145-final.log`（同名 `.xcresult`）：在上述测试基础上补生产 ViewModel 目录创建失败→应用私有目录回退，真实 MP4 逐帧解码、原阻挡文件保持不变。**6/6，0失败/跳过，TEST SUCCEEDED**。此轮使用 `-collect-test-diagnostics never` 省去系统诊断收集，未关闭断言或运行期问题检测；日志仍有系统编解码线程优先级警告，未将其当作性能达标证据。
- F145 已修复待真机，F139–F144/F146等录制独立缺口仍保持未完成；未真机安装、提交或推送。所有本轮构建进程已结束。F117随后已完成下述修复与验证。


### F117：画廊边框保留完整照片（2026-10-15，已修复待真机）

- 对照 Android `calculateOriginalQualityEditorialFrameLayout`、`calculateMeasuredTemplateFrame`、`drawEditorialFrameBase/Decoration` 和 `editorialFramesKeepTheWholePhotoInPreviewAndOriginalQuality`。galleryMat改为在1000px照片参考空间只缩放边距，保留卡纸最小留白，再扩充较短画布边成为方形；坐标向上取整，原图照片区域尺寸不变。预览复用原图布局后统一缩放。
- 新的实际像素检查发现iOS额外给照片本体加投影和白色描边，安卓仅给外层黑色卡纸投影。已移除galleryMat照片本体这两项，其他模板不改；这使原图边缘像素不再被白色描边改变。没有新增UI/动画。
- 测试以四色四象限源图验证横1000×500、竖500×1000、方1000×1000，在60/65/100/200宽度下的原图和480px预览，共24组配置。原图严格要求完整宽高、每种颜色像素数零损失；预览要求四角保留、完整比例，插值混色只允许按象限周长计算的边缘像素误差。
- 初轮 `/tmp/ztransfer-20261015-f117.log` 有89次断言失败，定位到多余描边；修正后 `/tmp/ztransfer-20261015-f117-fixed.log` 原图全部通过，预览两处固定4%纯色面积容差不适合插值边缘。改为像素周长界限后，最终 `/tmp/ztransfer-20261015-f117-final.log`（同名`.xcresult`）**5/5、0失败/跳过、TEST SUCCEEDED**，包含上述2项/24配置、原1920布局回归1项、真实JPEG发布回归2项。失败日志保留，不改写为首轮通过。
- F117已修复待真机；F116全模板长文字/水印测量扩容仍未完成，此处仅修复照片几何和边缘完整性，不恢复T15/T16/T17完成。未提交/推送。F132随后完成下述修复；F134尚未修改。

### F132：JPEG截断与写入收尾（2026-10-15，已修复待真机）

- 对照安卓 `jpeg_crop.cpp` 的STOPONWARNING、写入长度/close检查及 `LosslessCropInstrumentation` 截断用例。iOS桥接将warning和fatal统一作为失败；检查fflush/ferror/fclose，仅完整收尾返回成功，失败清理已创建输出。输入尺寸/MCU重验，并以减法边界检查避免裁切坐标加法溢出。
- 将setjmp/longjmp使用的可变清理状态收进堆上下文，避免跳转后依赖已修改的非volatile栈变量；统一销毁codec、关闭文件和清理失败输出。未修改F133的EXIF保留策略。
- 原生测试发现非零起点裁切触发`Bogus virtual array access`：旧桥接在读取系数后申请变换工作区。按随库 `jpegtran.c:650` 的契约改为先申请工作区，再读取/实现虚拟系数数组。iOS成功重试也改用(16,16)起点，不再只测左上角。
- iOS `/tmp/ztransfer-20261015-f132.log`原起点用例2/2通过；最终 `/tmp/ztransfer-20261015-f132-offset.log`（同名`.xcresult`）**2/2、0失败/跳过、TEST SUCCEEDED**。新测试的3种截断均先确认Swift头解析仍通过，再验证真实native和processor拒绝、无临时/发布输出、源字节不变、恢复完整JPEG后裁切可解码；另回归队列失败保原片/离线重试。
- 新增 `ios/NativeTests/run_lossless_jpeg_tests.py` 和C测试，从project.yml读取应用的同一套codec源码，主机以ASan/UBSan编译生产桥接，通过仅测试编译时替换libc调用注入ENOSPC刷新失败、EIO关闭失败；这些故障开关不进入App。前两轮native日志保留非零起点失败（`f132-native.log`、`f132-native-diagnostic.log`）；最终 `/tmp/ztransfer-20261015-f132-native-fixed.log` **PASS、退出0、无sanitizer错误**，覆盖3种熵/EOI截断、2种I/O故障、恢复重试和源文件保留。这是故障注入，不声称真实设备磁盘满已实测。
- F132核销待真机，F134随后完成下述开发侧修复；F133元数据仍未解决。未真机安装、提交或推送。索引新增2个native测试文件，当前664项；原32模块审查的662项是历史范围。

### F134：裁切临时目录与取消边界（2026-10-15，已修复待运行验收）

- 对照安卓 `TransferViewModel.generateCrop` 的cropSessionName/每任务目录、ensureActive、NonCancellable发布+savedCropOutput记账，以及 `sweepAndIndexExisting` 对旧/当前crop会话的区分。iOS使用进程共享UUID和每任务UUID构成独有`.nkcrop_crop-<session>_<task>.part`目录，内部输出`cropped.jpg`；目录创建成功才持有清理权，defer仅清本次目录。最终名称复用共享预留，删除原先非原子uniqueURL扫描。
- process在入口、头部检查后、native返回后及最终移动前检查取消；processAsync将父取消传给detached任务。三条队列裁切入口统一接此路径，取消回到原WAITING分支，不转成裁切错误/继续下载。发布成功后先记入item.cropURL再检查取消；重试沿用已有裁切输出。没有持久化整个队列或新增跨进程发布日志，安卓队列/已发布记账本身也为内存状态。
- 启动清理在根目录、日期目录及类型目录识别旧crop目录，保留当前会话；仅识别两个合法UUID组成的目录或旧版精确字面文件名，未知前缀目录不动。普通目录索引排除旧版临时文件。F061照片/传输其他临时文件的既有清理竞争仍独立未修复。
- `/tmp/ztransfer-20261015-f134.log`首轮因测试fixture新增闭包参数导致旧尾随闭包匹配错误而编译失败；修正参数顺序后最终 `/tmp/ztransfer-20261015-f134-fixed.log`（同名`.xcresult`）**21/21、0失败/跳过、TEST SUCCEEDED**：4项新生命周期测试、F132完整性1项、队列16项（含新增发布交界取消/单次复用）。两路真实native裁切在返回处确定性重叠，验证独立暂存、活跃清理保护、独立可解码成品；其余覆盖预取消、native返回后取消且保原片/旧成品、旧/当前/未知目录、重复清理及发布后取消重试。
- 开发侧核销，**尚未实际杀App进程重启或真机验证**；旧进程遗留采用不同会话UUID的磁盘夹具模拟，不能称为真实杀进程测试。native运算本身不强行中断，返回后观察取消，与安卓边界一致。T19整体仍未完成；F133随后完成下述修复。未提交/推送，所有本轮测试进程已结束。

### F133：裁切EXIF白名单重建（2026-10-15，已修复待真机）

- 对照安卓 `LosslessJpeg.copiedTags/cropResolved` 和 `jpeg_crop.cpp` SAVEMARKERS=4。原生桥接只保留有ICC_PROFILE签名的APP2段，移除旧APP1/COM/其他APP2复制及不完整的原地尺寸改写；不再依赖transupp对首个marker的EXIF特判。
- Swift按安卓35项白名单重建IFD0/Exif/GPS，保留源字节序及选中值的类型/原始数据；明确写入源方向、IFD0宽高、Exif PixelX/Y尺寸。仅生成这三个目录，next-IFD均为0，不复制IFD1、MakerNote、XMP或未引用负载，因此旧缩略图不是仅断开指针，而是从输出字节中移除。嵌套偏移、类型、数量及APP1长度有界检查；源/目标相同拒绝。
- 元数据写入阶段按256KiB块复制原生裁切JPEG，检查写入/同步/关闭后替换本次暂存；不解码/重编码照片。处理器发布前也验证方向与recipe一致。源文件大小/解码内存上限仍归F135，本项不代其完成。
- 新测试覆盖大小端×SHORT/LONG尺寸×8方向共32组合，以64×48非方形裁切区分宽高；源ICC在APP1前、包含真实IFD1 JPEG及35项拍摄/GPS字段。逐字段检查保留、四个尺寸与方向；ICC字节精确保留且无其他APP2，旧JPEG/缩略图标记/MakerNote/XMP/MPF不在输出，原片字节不变。另与直接原生裁切结果比较SOS后的压缩数据完全相同，并验证越界GPS指针在有效图像头条件下拒绝且不生成输出。
- 首轮 `/tmp/ztransfer-20261015-f133.log` 因夹具同时含UIKit自带EXIF及人工EXIF而失败；移除夹具原有APP1/APP2并断言唯一Exif后，`f133-fixed.log`6/6通过；补压缩数据/越界及矩形尺寸区分，最终 `/tmp/ztransfer-20261015-f133-rectangular.log`（同名`.xcresult`）**7/7、0失败/跳过、TEST SUCCEEDED**。含F132完整性、F134生命周期及发布边界复用回归。原生 `/tmp/ztransfer-20261015-f133-native.log` **ASan/UBSan PASS、退出0**，截断/刷新/关闭失败与重试未回退。
- F133已修复待真机，T19其他缺口保持未完成。F135后续资源限额与并发准入修复见下节。未提交/推送，所有本轮测试进程已结束。


### F135：裁切资源上限与串行准入（2026-10-16，已修复待真机）

- 依据安卓 `LosslessJpeg.kt` 的 Mutex、2MiB头部读取、取消检查及 `jpeg_crop.cpp` 的256MiB压缩源、1亿像素、192MiB codec设置；同时重读JpegCropTest与LosslessCropInstrumentation，保留系数变换，不创建RGB副本。
- Swift源/输出验证及EXIF读取改为最多2MiB头部；源文件实时读取文件属性，原生打开后再次fstat，超过256MiB或1亿像素在系数分配前拒绝。libjpeg两端设置192MiB虚拟数组预算，当前无backing-store实现会在预算不足时失败；该值不是App总RSS承诺。
- 从预览既有实现提取可取消串行准入类型，预览与裁切分别持有独立实例。生产processAsync调用cropAsync，在等待期间取消可立即退出；同步桥接调用另有同一NSLock互斥。许可覆盖原生变换和EXIF写入，输出发布仍由原有独有暂存/名称预留处理，发布后先记录URL的规则不变。原生CPU调用不强行中断，返回后检查取消并清输出。
- 原生 `/tmp/ztransfer-20261015-f135-native.log` ASan/UBSan PASS：256MiB恰好边界可处理、超1字节拒绝；1亿像素极端SOF触发JERR_NO_BACKING_STORE而非无限分配、超过1亿在codec前拒绝；故障后重试及原片保护仍通过。
- 首轮 `/tmp/ztransfer-20261015-f135-limits.log` 8项中1失败：URL缓存保留缩文件前尺寸。生产读取改为实时文件属性后，`/tmp/ztransfer-20261015-f135-serial.log` **25/25、0失败/跳过、TEST SUCCEEDED**，覆盖边界、元数据、完整性、生命周期与队列回归。
- 最后补强 `/tmp/ztransfer-20261016-f135-admission.log` **3/3、0失败/跳过、TEST SUCCEEDED**：确认已入等待队列后取消且owner未释放时取消完成；24路跨挂起/异常许可互斥与释放；12路真实生产processAsync裁切均可解码、输出互不覆盖、无遗留暂存且原片逐字节不变。
- F135开发侧核销待真机；未测真机峰值RSS或系统内存压力杀进程，不替代F065/F072生成预算及T19其他缺口。所有构建已结束，未安装真机、提交或推送。



### F131：裁切原图头边界与采样校验（2026-10-16，已修复待真机）

- 重读安卓JpegCropHeader、JpegCropTest、CropSelectionTest及实际native仪器测试。F135已将处理器和桥接源/结果头读取改为2MiB有界读取；本项补每个component的H/V采样均在1…4内才接受，不能只验证最大值。循环最少剩4字节再判SOS，与安卓一致，只有FF DA两字节的截断前缀不再接受。
- 将原先压缩成单行的解析流程整理为明确的marker、segment、EXIF、SOF步骤，保留安卓C0/C1/C2、1/3分量和EXIF方向规则；无预览几何兜底。
- 更新旧单测只含两字节SOS的夹具，补所有截断前缀、逐分量0/5采样、坏EXIF字节序/魔数/offset/数量/类型/方向及截断segment。生产处理器使用真实JPEG验证SOF/SOS超过64KiB、恰好2MiB可读、超边界1字节拒绝且不进transform；另验证8万字节双段ICC位于SOF前可裁切并逐字节保留。拒绝与成功场景均检查原片未改变、无遗留暂存。
- `/tmp/ztransfer-20261016-f131.log` **13/13、0失败/跳过、TEST SUCCEEDED**：5项头解析/生产入口测试，另含资源限制、EXIF、完整性及生命周期回归。
- F131开发侧核销待真机。预览页面准备入口仍仅请求64KiB，属于F125准备/交接缺口，尚未处理，不据本项声明裁切端到端完成。未安装真机、提交或推送，所有构建已结束。



### F063：原片重名与共享发布预留（2026-10-16，已修复待真机）

- 对照安卓ExistingFileNameIndex.reserveDisplayName、suffixedName和processQueue正常发布路径，以及ExistingFileNameIndexTest并发预留测试：原片按忽略大小写的占用集合递增序号，没有99/999上限；预留后仅一次rename，失败才向同名copy，不通过不断换名字重试rename。
- 实际finalizeTransferTemporary接入原片/派生图/录像共用的目录名称预留，原片使用独立无限递增策略，派生图保留既有999后时间戳策略。命名期间加锁，写盘期间不持锁，成功/异常均释放，已完成输出由目录重新识别；保留dot-name与无扩展名规则。
- 移除旧只扫描不预留的transferUniqueOutputURL；DEBUG模拟下载同样在写入时预留并禁止覆盖。原有领域测试迁移到真实finalize发布入口，不为保旧测试留下死代码。纠正旧测试“rename失败尝试后缀”的过时预期，按安卓验证同名copy和长度检查。
- copy前重验目标不存在；若其他进程/provider抢先创建并返回fileWriteFileExists，不清理该外部文件。其他复制失败/短复制仍清理本次失败输出，源part保留给调用方按既有照片/视频策略处理。
- `/tmp/ztransfer-20261016-f063.log` **56/56、0失败/跳过、TEST SUCCEEDED**：真实相机回放下载在100个大小写混合占用后保存(100)，全部旧文件逐字节保留；命名超过1000与dot-name；第一路move挂起时第二路使用另一个预留名；copy碰撞保外部文件、释放后重试；同名copy、失败清理、派生发布和队列回归。补跑迁移的原有生产发布测试 `/tmp/ztransfer-20261016-f063-publication.log` **1/1、TEST SUCCEEDED**。
- F063开发侧核销待真机File Provider；未声称已在大小写敏感外部Provider验收。F060目录校验、F061授权生命周期、F062启动清理竞争仍未完成。未安装真机、提交或推送，所有构建已结束。



### F060：实际队列目录名校验（2026-10-16，已修复待真机）

- 对照安卓getOrCreateTransferDirectory的创建前require、isValidTransferFolderName全串匹配和NewMediaTransferPolicyTest。iOS队列每次取出待办任务后，先校验非nil destinationFolderName，再解析目标URL、查索引、创建目录或调用相机；失败文案与安卓一致。重试保留的目录名同样重新校验，不仅检查新入队输入。
- 既有正则换用绝对起止锚点，避免`$`接受末尾换行而与安卓Regex.matches不一致；规则仍为1…64个ASCII字母/数字/点/下划线/连字符，首位必须字母或数字，nil表示根目录。
- `/tmp/ztransfer-20261016-f060.log` **18/18、0失败/跳过、TEST SUCCEEDED**：实际worker拒绝含空格、斜杠、反斜杠、换行、Unicode及超长扩展目录，验证相机未被调用、未生成异常层级；同批合法ZT-JPG任务照常落盘，失败任务原位重试仍拒绝；64字符合法边界实际成功，空名/路径/首尾空白/末尾换行/65字符被拒。含原16项队列生命周期回归。
- F060开发侧核销待真机；未改动F061授权持有及F062启动清理竞争。未安装真机、提交或推送，所有构建已结束。



### F061：任务持有目录授权（2026-10-16，已修复待真机）

- 依据安卓setTransferDirUri取得新tree持久授权而不撤销旧tree、processQueue固定root及生成任务目的地持有关系。iOS保持平台API差异，以DirectoryAccessLease封装一次成功start和最后持有者销毁时一次stop；失败start不调用stop，选择器、队列和后台任务不再手动相互撤销授权。
- DirectoryAccessStore在选择/恢复时持有lease，切换/清空/销毁只释放自己的引用；恢复清理任务也持有其捕获的lease至结束。队列attach/start取得当前root授权，run在第一次挂起前捕获它，整个下载、裁切与生成准备期间保持持有；FrameJob同时保留该root lease，等待和执行均不受新选择影响，最后任务成功/失败退出后释放。新worker使用当前新目录，旧worker继续原先目录。
- 访问操作可注入，以真实生产DirectoryAccessStore、TransferQueue、受控相机/renderer及实际文件写入验证持有计数；不是仅测试独立lease。`/tmp/ztransfer-20261016-f061.log` **25/25、0失败/跳过、TEST SUCCEEDED**：下载挂起时重选并attach新目录，旧输出仍保存且新任务用新目录；生成等待/执行中clear+attach nil，成功和失败均正确收尾；store销毁平衡stop，失败start不stop；含原队列及裁切生命周期回归。
- 补强 `/tmp/ztransfer-20261016-f061-active.log` **1/1、TEST SUCCEEDED**：先确认两路renderer已挂起、第三路等待，再清空目录；旧lease存续到三路完成，最后归零且start/stop各自平衡。当前两个生成worker属于F065待改规格，此测试只验证现有所有持有者的安全，不核销F065。
- F061开发侧核销；测试注入授权操作，**未在真机外部File Provider执行权限撤销/重选验收**。F062清理与新建临时文件竞态仍未修复，恢复清理持有授权不等于解决删除竞争。未安装真机、提交或推送，所有构建已结束。



### F062：启动清理与新任务互斥（2026-10-16，已修复待真机）

- 对照安卓primeDirectoryIndexScan/getDirectoryIndex共享Deferred并await，以及PhotoFrameExporter当前会话临时文件识别。新增TransferDirectoryPreparation按规范化root记录启动清理：restore先同步注册再发布directoryURL；实际queue在读目录索引、创建任务目录、相机调用、裁切或派生交接前等待同一root清理。
- 未发生restore清理的root也由queue首次准入标记已使用，避免后来再次构造store时误清正在使用的目录；完成状态复用，不重复清理本进程生成的part。不同root互不等待。每个等待者独立支持取消，退出不会取消共享清理；清理自身持有F061的目录lease至结束，完成后不保留Task/lease。
- 实际renderer的.nkframe临时名加入进程UUID，清理排除当前进程前缀；旧随机名继续可清理。清理同时进入root/日期/类型目录下实际ZTFrames子目录，只删除旧临时前缀，保留正常成品；裁切当前会话排除沿用F134。
- 初轮 `/tmp/ztransfer-20261016-f062.log` 30/30通过，其中请求的旧清理测试名称写错，DomainModelTests实际0项，不能称其已执行。补取消时 `/tmp/ztransfer-20261016-f062-final.log` 因Swift可选Result推断编译失败，已显式标注返回类型并保留日志。
- 最终 `/tmp/ztransfer-20261016-f062-fixed.log` **32/32、0失败/跳过、TEST SUCCEEDED**：真实DirectoryAccessStore书签restore挂起清理→实际queue确认已进入等待→相机无part→释放后旧残留删除且新part正常创建；再次restore不删正在写的part，真实finalize发布成功；等待取消及时完成且共享清理继续，其他root的实际下载不受阻；当前frame及正常文件保护/旧root与子目录残留清理；原旧清理测试已按正确名称执行1项，另含队列、裁切和JPEG发布回归。
- F062开发侧核销待真机；书签/目录写入实际执行，但授权操作注入，未实际杀进程或在外部File Provider重启恢复验收。没有把确定性模拟启动时序当成真机启动验收。未安装真机、提交或推送，所有构建已结束。



### F065：生成准入与计算调度（2026-10-16，已修复待真机）

- 完整重读安卓PhotoGenerationQueue及全部对应测试、TransferViewModel的单低优先级计算线程和准入/完成分支，并读PhotoMetadataPreparation。确认F065与F066生产准备流水线耦合，不能只改并发数后声明完成。
- 已接PhotoGenerationQueueState到实际TransferQueue：默认4096容量包括准备/等待/运行；重复、满、关闭区分；入队顺序、就绪绕过、原位延后、完成释放及幂等关闭由单一状态管理。等待项只保ID/轻量配方，不为每张图片建立等待Task；生成worker使用utility优先级且计算槽位为1。
- 实际startFrameGeneration在元数据准备前准入，满队列写安卓原文`Photo generation queue capacity reached`并保留已保存原片；准备中断及生成成功/失败/单项取消均释放槽位。旧双worker测试改为当前安卓单worker要求，F061授权测试也改为确认单路运行、两路等待后清空目录；历史双路验证记录保留其当时范围。
- `/tmp/ztransfer-20261016-f065-admission.log` **36/36、0失败/跳过、TEST SUCCEEDED**：状态层实测4096容量边界、active/preparing计入、重复、未就绪头绕过、延后保序、readiness交接、幂等关闭；生产用容量2注入验证满队列、容量释放后重试、计算峰值1、取消/失败后继续，含队列及元数据身份回归。
- 第一阶段历史状态（后续生产闭环见下节）：当时F065仍未完成，核销数17/182。startFrameGeneration仍在下载worker中await相机补头；状态层能跳过未准备项，但生产首张慢准备仍阻塞后续下载/准入，尚不能证明真实就绪旁路。下一步结合F066建立独立有界准备consumer，保留现有来源身份及P3门控，并完成生产慢头/快就绪任务交错和关闭生命周期验证。F067结果状态/LRU/补读预算、F068计时仍独立未完成，不用本轮覆盖代替。
- 未安装真机、提交或推送，所有构建已结束。



### F065生产闭环／F066准备流水线第一阶段（2026-10-16）

- 已将身份快照交接给独立轻量准入consumer，将相机补头交给单个补读consumer；等待项保留配方/来源/已解析快照，不保留原始JPEG头，也不为每张等待照片创建Task。两个准备consumer与单计算槽位共享4096准入计数。已有快照任务绕过正在补头的旧任务，ready顺序仍按最初登记顺序。
- 补读执行前重验相机身份，保留CameraRepository重连后的ObjectInfo文件校验；元数据结果仍写回任务快照，单项/批量重试不得换用新机身。复核发现原补头入口使用transfer通道，与安卓readExifHeader(background=true)不符，已改为backgroundThumbnail；实际协议入口验证评级阶段阻塞、放行后activeKind/owner确为后台缩略图通道，未把下载优先级称为P3。
- 实际closePhotoGeneration关闭准入，清理等待/准备项，取消活动消费者/计算任务；活动操作保留自己目录lease到取消边界，迟到身份/元数据不能再次发布，重复close幂等。deinit亦取消各worker并关闭状态。单项失败/取消不影响后续照片。
- `/tmp/ztransfer-20261016-f066-pipeline.log` 57/57；补正确调度类别/活动计算关闭后`f065-f066-final.log`97/97；完整移交身份后最终 `/tmp/ztransfer-20261016-f065-f066-handoff.log` **97/97、0失败/跳过、TEST SUCCEEDED**。涵盖真实队列首张已有原片补头挂起、第二张下载并从捕获头生成、释放后第一张完成且无重复补读；准备中占满容量仍允许第二张原片下载、释放后生成重试；准备/等待/活动计算关闭及迟到回调；原相机快照/单条批量重试/来源身份、调度与下载回归。
- 另补身份查询本身挂起的交接验证，`/tmp/ztransfer-20261016-f066-identity.log` **32/32、0失败/跳过、TEST SUCCEEDED**：身份未返回时第二张原片已下载；身份返回后第二张先生成，第一张补头仍挂起；全部释放后顺序为2→1。该轮也回归所有队列场景。
- **F065开发侧核销，当前18/182；F066仍进行中**：相机身份/补头不再阻塞下载，但新下载的`result.headerPrefix.flatMap(PhotoFrameMetadata.cameraSnapshot)`仍在run中同步解析，没有完整独立parser交接。下一步结合F067的有界头预算/结果状态实现独立解析，禁止为解耦而把最多4096个原始头无限驻留；F067缓存/字符串/扩读和F068计时仍未完成。不能用本轮就绪旁路成功宣称所有元数据准备已复刻。
- 未运行真实相机/外部Provider/后台压力验收；未安装真机、提交或推送，所有构建已结束。


## 已确认问题与待证事项

| 编号 | 级别/归属 | 触发与实际差异 | 依据与最小验收 | 状态 |
|---|---|---|---|---|
| F001 | P2 / C01 | 本地工作台点返回，`page=0` 后 `onChange(page)` 立即恢复发现；此时 `UIPageViewController` 仍在动画。安卓按 settledPage 与 targetPage 同时判断，返回全程保持暂停。可在工作台尚未离场时开始自动连接并释放编辑页 | iOS `RootView.swift:375,386,449`、`ConnectionViewModel.swift:661`；安卓 `HomeWorkspacePager.shouldPauseConnectionDiscovery` 及同名测试。验收：按钮返回/交互返回/取消返回/快速反向时，只有上页落稳才恢复发现 | 已修复待真机：请求/落稳/进行中目标统一发现门控，程序化和交互生命周期接线；真实ConnectionViewModel迟到事件与恢复快照/已连接会话保留回放及连接状态回归共18/18通过。按用户要求不运行UI测试；未验证物理相机握手。 |
| F002 | P2 / C01 | 工作台进入/返回只交给系统分页器，没有安卓进入 50%、返回 30%、返回至少 15% 且下滑速度≥1200 的显式规则；原生动画修复记录不能证明这些后来加入的业务阈值已迁移 | iOS `RootView.VerticalWorkspacePager` 全实现；安卓 `HomeWorkspacePager.kt:42–51`、`HomeWorkspacePagerTest` 的边界断言。验收：14%/15%/20%/30%，低/高速度和反向速度，并覆盖子滚动区顶部返回 | 开发侧功能已核销：实际容器接入进入/返回规则、子滚动剩余距离及取消恢复；程序接管、尺寸变化、手势候选仲裁和发现暂停/恢复链已覆盖，最终13/13控制器专项通过。未运行UI触摸自动化、真机或动画验收。 |
| F003 | P2 / C01、C15 | 列表↔队列仍为 320ms、整屏/三分之一屏移动；队列左上控件等320ms再淡入140ms。当前安卓为24dp短位移300ms、入场延迟100ms后200ms、退场140ms，顶栏同步落稳。监看由普通 `fullScreenCover` 呈现，也未接安卓同组转场 | 安卓 `Motion.kt:19`、`MainActivity.FilesQueueWorkspace`/Remote路由；iOS `PhotoListView.swift:47,67,332,614,1089`、`RootView.swift:150`。验收：进入、退出、连续反向，检查顶栏和页面同步且无整屏硬边 | 当前范围排除：用户2026-10-16明确后续集中处理样式与动画，本阶段只做功能与基础可用界面。原实现/验证及未完成项保留在历史分项记录，不计作已修复。 |
| F004 | P2 / C02 | AP 首次握手失败后后台重试，每轮 `beginWiFiConnection` 都重新置 `.connecting` 并清 `wifiFailureKind`，失败文案被反复撤掉后再出现；安卓首次失败后保持失败分类、后续重试静默 | iOS `ConnectionViewModel.swift:264–333`、`ConnectionMethodCard.wifiFeedback`；安卓 `CameraViewModel.connectToCameraWithRetry` 只在进入整个重试循环前写 PROBING。验收：候选网段连续三次失败→成功，期间失败提示稳定且不会重新播放识别/失败反馈 | 已修复待真机：AP后台失败状态保持、成功清分类、取消重置失败计数；连续失败到成功、取消新轮与重连保持及连接回归18/18通过。验证生产1秒/3秒选择值，未实际网络/墙钟测试；按用户要求无UI测试。 |
| F005 | P2 / C02、C03 | 无线心跳失败一次就拆会话；安卓累计连续两次失败才拆会话，中间保留会话并增加1秒延迟。iOS 没有该容错状态 | iOS `WiFiConnectionService.startKeepalive`、`CameraRepository.keepalive`、`PTPSession.keepaliveIfIdle`；安卓 `CameraViewModel.startKeepalive`/`KEEPALIVE_FAILURE_LIMIT=2`。验收：可恢复失败→成功、连续两次失败、忙态跳过、取消。iOS 协议错误可能已使 session invalidated，后续处理必须区分失效与可恢复，不能机械向失效流重发 | 已修复待真机：生产无线心跳连续两败才丢线，首败额外1秒/成功及忙态清零/取消保护；失效协议不重发命令。循环与真实Repository/PTPSession回放、下载忙态回归7/7通过；未物理网络/墙钟或UI验证。 |
| F006 | P1 / C03 | STA 收到 `NK_PAIRING_RESULT OK` 即持久化“已配对”，未实现重连后的 DeviceInfo/相册验证、v2可信标记、旧标记验证失败清除和一次有界重新配对。相机还在配对界面时可留下假配对状态，后续长期复用旧标记 | iOS `STABrowsingSession.pair/open`、`STAProfileStore.isPaired/markPaired`、`STAConnectionCoordinator.tryCandidate`；安卓 `NikonCamera.initializeStaBrowsingSession/confirmPairingIfNeeded/invalidateStaPairingMarkers`、`CameraViewModel.tryConnectStaCandidate`、`StaPairingStateTest`。验收：应答成功但尚未确认、重连仅配对能力、DeviceInfo缺失、旧标记无效、重新配对成功/第二次仍失败、取消与杀进程恢复 | 开发侧已修复，待真机：移除应答早写、重连DeviceInfo/相册验证、legacy/v2证明及一次恢复；含真实四会话恢复和验证中取消，31/31通过。实际杀进程/物理配对恢复未验收。 |
| F007 | P2 / C03、C06、C09 | STA 短断线期间旧列表保留，但重连成功创建新 session 时立即驱逐旧模型并重新挂载空列表，未迁移安卓保留已有目录/卡槽/效果预览再重新枚举的行为；滚动/选择等页面状态亦有丢失风险 | iOS `RootView.swift:126,197`、`PhotoListViewModel.cached/evict/init`；安卓 `onCameraTransportLost` 设置 `staReconnectPreserveExisting`、`activateStaCamera` 原子恢复、`loadFiles(preserveExisting=true,detectNewHandles=true)`。验收：含照片的同机STA短断线→恢复，不闪空、不重播旧媒体自动入队，删除/新文件由新枚举确认；评级须新代次 | 开发侧已修复待真机：目录、生命周期和列表/页面继承已接，含真实新增/删除后副本接替、失败保留组合回放32/32通过；UI测试按用户要求跳过，不宣称界面实机验收 |
| F008 | P2 / C04、C28 | USB权限被拒后切换App语言，再去系统设置授权：恢复分支用“当前语言的错误字符串”比较旧状态，匹配失败就不回 waiting；授权已允许仍可能停在错误态且不自动连接 | `ConnectionState.swift:83–94`、`ConnectionViewModel.apply(.authorization)`；现有拒绝→允许测试未切语言。验收：简中拒绝→英文→系统允许→回前台，无拔线恢复；反向语言同测 | 开发侧已修复待真机：授权恢复使用权限状态、错误保留reducer解析；真实ViewModel语言/错误回放及回归20/20通过，未操作系统授权界面或物理相机。 |
| F009 | P2 / C04 | USB未建立session时收到空错误/权限错误，reducer刚算出的非空兜底/权限提示随后被ViewModel的原始message覆盖；与已记录“空错误不会空白”的要求不符 | `ImageCaptureUSBTransport.swift:904–906` 可发送空message；`ConnectionState.applying(.failed)`有兜底；`ConnectionViewModel.swift:835–836`再次覆盖。验收：对真实ViewModel注入同设备空错误及拒绝授权时的框架错误，最终卡片仍有正确文案 | 开发侧已修复待真机：授权恢复使用权限状态、错误保留reducer解析；真实ViewModel语言/错误回放及回归20/20通过，未操作系统授权界面或物理相机。 |
| F010 | P1 / C05 | GPS身份过期/配对拒绝只清UserDefaults，`NikonGPSBluetoothClient`仍保存旧device/nonce/外设身份；停止不会清这些字段，用户重新开GPS仍使用失效身份。且普通pairing timeout也被一并清持久化，超出安卓仅拒绝/失效清身份的条件 | `GPSCoordinator.applyBluetoothFailure:454`；`NikonGPSBluetoothClient.init/start/beginPairing/clearPairing`。验收：已有配对→相机忘记配对→identity expired→同进程关闭再开启，stage1必须使用新身份；普通握手超时保持原身份。不得靠杀进程或额外手动清除才能恢复 | 开发侧已修复待真机：拒绝/过期统一清内存及持久化，普通超时保留；真实客户端下一stage1身份回放及GPS回归5/5通过。 |
| F011 | P2 / C05 | 已订阅NOT1，却只处理PAIR characteristic的value回调；安卓在NOT1收到`01 00`会立即排队ID。iOS对应分支放在只由PAIR调用的函数内，通知不能推进握手；仅靠另一路stage4的延迟兜底不等价 | `NikonGPSBluetoothClient.didUpdateValueFor:411`/`handlePairingValue:240`；安卓`NikonGpsBleClient.handleCharacteristic:405`。验收：只送NOT1确认、不送PAIR stage4，以及两者先后到达，ID均应且仅应写一次 | 开发侧已修复待真机：NOT1路由、共享ID门控、生产串行队列及延迟兜底组合回放10/10通过；系统外设写入未验收，F013隔离剩余项独立保留。 |
| F012 | P2 / C05 | BLE失败出口缺失：无15秒扫描截止；无`didFailToConnect`处理；缺必要characteristic时静默return；排队ID后取消握手计时却无已配对ID的3秒ACK截止。可能长留搜索/连接态 | iOS `beginScan`、central/peripheral delegates、`beginPairingWhenReady`、`queueControllerID`；安卓扫描超时、连接状态失败、`onServicesDiscovered`必需项校验、`scheduleIdWriteTimeoutIfNeeded`。验收：无相机、扫描后连接失败、缺ID/GEO/NOT1、ID不回调分别能到明确状态并按原策略重试/等待用户 | 开发侧已核销：15秒扫描/3秒ID确认截止、连接与缺特征失败出口及错误分类已有验证；启用状态经真实发布订阅完成四类错误五秒恢复、stop断线隔离、配对显式重试和授权回调门控，最终GPS26/26。真实机身未验；F013旧外设会话隔离独立保留。 |
| F013 | P2 / C05 | 停止/换连接后，发现、连接、服务、通知和写回调没有运行标志/当前外设或会话代次门控；写回调无条件弹出当前队首。旧连接的迟到ACK可能确认新队列GEO。stage4的1.5秒Task也未保留取消句柄且捕获旧外设 | `NikonGPSBluetoothClient`各delegate、`handlePairingValue`及`didWriteValueFor:418`；安卓主要回调以`gatt === g`过滤。验收：stop后发现/连接回调不得重开；A断线→B写GEO时A迟到ACK不得修改B队列/lastSentAt；A stage4延迟跨重连不得写旧外设 | 功能范围开发侧已核销：运行/外设/服务/特征身份、写队首、延迟代次与旧连接终止隔离已逐回调核对，SDK终止边界已查；GPS专项34/34通过，含固定32字节ASCII身份修正。完整真实外设代理回放与相机互通未运行，不宣称真机验证。 |
| F014 | P2 / C05 | 海拔可信期只在新位置回调中计算，定时写GEO直接取旧`state.altitudeMeters`。静止且不再收到定位回调时，即使超过2分钟仍把旧海拔当可信值写入；安卓每次maybeSend都会重新校验 | `GPSCoordinator.didUpdateLocations:530`与`writeCurrentFix:595`；安卓`NikonGpsService.maybeSend:716`和`GpsAltitudePolicy`。验收：有效海拔后停止fix，5分钟频率再次写入应按过期策略写0；120秒边界、1公里边界和重新获得海拔强制补写 | 开发侧已核销：每次发送重验海拔；生产Coordinator五分钟无新fix定时发送、在途可信海拔ACK后单次最新值补写、关闭迟到ACK，以及120秒/1000米精确边界均通过，最终GPS24/24。真实定位/蓝牙硬件未验收。 |
| F015 | P2 / C05、C29 | GPS显示和复制仍用小数度（如`31.23040°N`），安卓是相机式度/十进制分（`N 31°13.824'`），方位位置、精度、空格和进位均不同 | `GPSConnectionControl.formatCoordinate:521`及两处复制路径；安卓`CoordinateFormat.kt`、`CoordinateFormatTest`。验收：北/南/东/西、59.9996分进位、零点、极点、不同locale，面板和地点查询前后剪贴板一致 | 开发侧已修复：面板/两处复制共用安卓度分格式；德语地区GPS16/16通过，含进位/方位/无效输入/查询前后复制文本。未运行UI或系统剪贴板自动化。 |
| F016 | P2 / C05、C29 | GPS内部状态动画只近似：详情用240ms统一opacity/0.98scale；状态文字出入同220ms easeInOut；按住辉光用easeInOut。安卓详情fade入180ms延45/出130并单独240尺寸，文字入220/出190且fade入150延35/出120，辉光FastOutSlowIn | `GPSConnectionControl`详情transition及statusControl；安卓`SettingsScreen.GpsConnectionControl/GpsStatusButton`。验收：连接→确认→稳定、错误→重试、快速关闭与取消长按逐阶段参数/中断核对。已批准280pt/10pt及Genie外层浮层差异不在此项 | 范围暂缓：此项记录的是内部动画参数/时序；按用户最新要求不在本阶段复刻，不计修复。GPS 业务状态与重试仍由 F012–F014 独立跟进。 |
| F017 | P2 / C06 | 收到ObjectRemoved只请求目录同步，不清旧扫描快照；FHD暂停或范围受限时相机删图，返回/扩大范围仍复用删除前handles。安卓`requestHandleCatalogSync`明确先置快照nil，随后重新枚举 | `CameraRepository.receiveEvent:2317`、`scanSnapshotForResume`与`PhotoListViewModel.resumeAfterPreview/setPhotoLoadingRange`；安卓`CameraViewModel:2757`。验收：扫描暂停→删除尚未读/已发布文件→恢复；受限范围→删图→扩大，必须重读handles并保留仍存在的行 | 开发侧已修复待真机：删除立即失效快照，版本拒绝调用方旧值和在途结果；已发布/未读删除×直接/FHD恢复四组合及枚举/metadata在途回放，目录16/16通过。 |
| F018 | P2 / C06、C07 | 范围在开始扫描时从偏好读取一次并以值传入Repository；途中更改只更新显示/后台队列，当前批次仍按旧范围接纳并预取。3日扫描尚未完成时改全部，扩大分支因`hasCompletedFileScan=false`不恢复，之后仍在3日停止；全部改1日则继续读旧范围照片 | `PhotoListViewModel.init`扫描closure、`setPhotoLoadingRange:624`、`acceptBatch:482`；`CameraRepository.scanCatalog:1913`；安卓publishBatch逐批读`thumbnailLoadingDaysFlow.value`且过滤thumbnailBatch。验收：在第1/第2批暂停后分别扩大/缩小，不必再次切设置才生效，范围外不继续GetThumb | 开发侧已修复待真机：逐批动态范围、缩略图准入复查及停止交接自动续扫；真实Repository→ViewModel组合19/19通过，只枚举一次，尾部完整。 |
| F019 | P2 / C06 | 一个ObjectInfo载荷不完整就使`catalogReady=false`，后台事件轮询、删除同步和新增解析全部被该标志挡住；列表却已显示loaded/hasCompleted=true。相机协议仍健康时新拍照片也不再出现。安卓不完整metadata只禁止权威缓存清理，不关闭后续事件 | `CameraRepository:2248`、`backgroundReadsAllowed:2325`、`maintainCatalogIfIdle`、`scheduleObjectResolver`；安卓`CameraViewModel.loadFiles`结束及`startEventPolling`。验收：首扫一个可恢复/缺字段ObjectInfo→之后新增/删除事件与空闲目录查询继续工作，缓存不可权威裁剪 | 开发侧已修复待真机：元数据完整性与目录事件就绪解耦；不限/单日范围下删除同步、轮询、新增解析与ViewModel拒绝权威缓存裁剪已验证，目录21/21通过。 |
| F020 | P2 / C06、C07 | 只扫描1/3/5日到边界后仍以`handleQueriesSucceeded && metadataComplete`调用权威缓存reconcile，将范围外仍在相机里的旧日期缩略图从内存和磁盘删除。安卓在范围边界直接返回，只有完整扫描才清理 | `PhotoListViewModel:385`→`CameraSession.reconcileThumbnailCache:229`→`PhotoThumbnailStore.reconcile:268`→`PhotoThumbnailDiskCache.reconcile:147`；安卓`CameraViewModel.loadFiles`的stopAtPhotoRange早返回。验收：先缓存全部→新会话选1日→完成受限扫描，旧日期缓存仍在；扩大范围应命中缓存 | 开发侧已修复待真机：范围停止不授权权威清理；真实ViewModel门控及旧照片memory/新store磁盘命中验证，最终22/22通过。首轮测试缺try编译失败已保留。 |
| F021 | P2 / C06、C09 | 双卡备份副本在后续批次补出时，Repository只更新内部旧行，onBatch仅发新增行；ViewModel仅append且扫描中拒绝catalogUpdates，因此已发布行的双卡归属直到整次结束才更新。安卓每批同时发布旧行replacement和新行 | `CameraRepository:2191`及onBatch、`PhotoListViewModel.acceptBatch/applyCatalogUpdate`；安卓publishBatch的`replacements`/`withBatch`。验收：首批发布卡1照片，后批读到卡2副本时、尾部尚未完成，卡2筛选立即包含该照片，且不重复入队/重取缩略图 | 开发侧已修复待真机：旧行replacement与逐批卡槽映射接线，真实双卡Repository→ViewModel扫描中卡2筛选立即显示且不重取缩略图；最终24/24通过。 |
| F022 | P2 / C06 | 从快照续扫结束后把完整knownHandles重置成“剩余handles+可见主handle”，丢失已处理且合并掉的双卡副本handle。后续差量、删除去重和自动发现依据不再是完整快照 | `CameraRepository:2245`、`PhotoScanSnapshot.remainingHandles`；安卓完整knownHandles只在成功枚举时更新，resume不缩小。验收：主副本均处理→暂停→续扫→删主保副→再删副，所有删除都能清理可见行；不额外把旧副本当新增对象重读 | 开发侧已修复：保留成功完整枚举的knownHandles，续扫不再用剩余/可见句柄覆盖；真实协议脚本及扫描回归9/9通过，见文末。 |
| F023 | P2 / C07 | 实时目录删除仅清缩略图Store，未清填充队列的pending/failed/settled。删除后相机重用句柄，新照片被旧settled跳过，STA格子只观察缓存时一直缺图 | `PhotoListViewModel.applyCatalogUpdate:213`，仅完整扫描结束379调用队列remove；安卓`removeMissingCameraHandles`调用`removeHandles`。验收：已加载H→删除事件→新文件重用H，必须重新取图；删除待办/失败项也要清理 | 开发侧已修复待真机：删除及同句柄换身份清队列，旧owner/revision不能收尾或重排新任务；settled/pending/failed/在途及合并更新验证，最终40/40通过。 |
| F024 | P2 / C07 | 缓存目录不可写时，iOS只有单项unsettled，无本连接写盘失败锁存；扫描和后台填充继续请求后续照片，每次唤醒还重试。安卓首次写盘失败即停止本连接后台填充，保留游标和已有缓存读取 | `PhotoThumbnailStore.prefetchOutcome/persistPrefetch`、`PhotoListViewModel.startThumbnailFillWorker`；安卓`thumbnailDiskWritesBlocked`、`prefetchPublishedFileBatch/fetchThumbnailToDisk`。验收：第2张写盘失败→后续不继续取图；前台缓存可用；新连接解除锁存；无图/解码失败与写盘失败分别处理 | 开发侧已修复待真机：写失败连接锁存、扫描/后台停止并保留游标、已有缓存可读、新会话解除及校验失败/共同等待区分；最终44/44通过。 |
| F025 | P2 / C07 | 普通GetThumb的NoThumbnailPresent/InvalidObjectHandle直接被PTPSession.execute抛出，未转换为已确认无图；后台将其当瞬时失败反复重试。安卓明确区分这两种响应与DeviceBusy/IO错误 | `CameraRepository.thumbnail:1454`→`PTPSession.execute:107`；安卓`NikonCamera.getThumbnail:2902`。验收：用真实协议响应分别回放无图/无效句柄/忙/IO失败，前两者settled负缓存，后两者保留重试 | 功能开发侧已修复，45/45专项通过，待真机；真实协议两种无图负缓存、忙响应重试、IO失败恢复会话后重试均已验证；直接STA独立规则保留 |
| F026 | P2 / C07 | USB的CameraSession直接用ICCameraDevice UUID或进程对象地址作缓存身份，绕过制造商/型号/PTP序列号组合；同机AP↔USB不能复用普通缩略图缓存，UUID缺失时重插还可能换目录 | `CameraSession.thumbnailCacheIdentity:176`、`ImageCaptureUSBTransport.stableID:797`；安卓`NikonCamera.thumbnailCacheIdentity:2114`。验收：同PTP序列号不同链路应落同机身目录；不同机身隔离；缺序列号才使用链路兜底 | 开发侧已修复，23/23专项通过；真实会话独立store磁盘复用/不同机身隔离已验证，连接服务接线已静态核对；实际USB握手/拔插待真机 |
| F027 | P3 / C07、C10、C19 | EXIF快门0.4≤秒数<1时iOS新增小数秒分支，安卓统一显示倒数；例如0.5秒变成0.5s而非1/2。光圈接近整数下方时舍入判定也不同，且日期/镜头未沿用安卓空白过滤 | `PhotoExifParser.formatShutter/formatAperture/parse`；安卓`CameraViewModel.parseExifImpl:4528`。验收：0.4/0.5/0.8/1秒、光圈1.98/2/2.02、空白Original+有效Digitized、空白镜头，实际照片信息与框元数据一致 | 开发侧已修复，最终18/18通过；真实JPEG 24组合与手工TIFF末级回退均经过照片信息及生成元数据消费者验证；待真机 |
| F028 | P3 / C08 | JPEG/RAW共用来源读完后，最终complete以localRatings数量比较未去重的sources.values数量，因此有配对时完成标志为false，虽completed/total已相等。安卓比较uniqueSources | `PhotoRatingScanController.startReading`末尾；安卓`PhotoRatingScan.kt`finally。验收：一组JPG/NEF及混合独立文件，读取次数去重、进度按文件、最后complete=true。当前UI主要用loading，不能夸大为界面一直转圈 | 开发侧已修复；5/5专项通过，配对与混合独立照片读取去重、行进度及complete均明确断言；待真机 |
| F029 | P2 / C08 | 控制器只在enabled从false→true重建；scanStarted后忽略输入，io.generation从未消费。扫描中/完成后修改照片加载范围，评级仍沿用旧范围快照；仓库外部失效后也未同步重建。安卓LaunchedEffect把generation、ratingDays、photoLoadingDays、模式作为键 | `PhotoRatingScanController.update`/`beginFreshGeneration`、`PhotoListViewModel.setPhotoLoadingRange/updateRatingScanFromCurrentState`；安卓`rememberPhotoRatings`。验收：开启后照片范围1→5→1、首扫/新代次、取消后的迟到结果；单纯缩略图更新不得重启。评级范围拨轮只在关闭时可见，不捏造开启时直接拖动场景 | 开发侧已修复，最终11/11专项通过；真实列表1→5→1、仓库代次流、初始化重叠及旧read/cache迟到隔离均有回放；待真机，N05其他范围不据此核销 |
| F030 | P2 / C08 | 来源映射改成Swift Dictionary后直接遍历values去重，丢失安卓associate保持的列表顺序，最新照片的评级读取和逐条结果出现次序不稳定 | `photoRatingSources`返回Dictionary、`PhotoRatingScanController.evaluate`构造uniqueSources；安卓同名函数及`distinctBy`。验收：多日期、多文件及RAW先/JPG后时，生产read记录保持列表首次来源顺序并只读一次 | 开发侧已修复；12/12专项通过，JPG先/RAW先与多日期独立照片实际read序列均明确断言，待真机 |
| F031 | P2 / C08、C28 | 新安装没有filter_rating_days键时UserDefaults.integer返回0，被当成“全部”；安卓prefs.getInt默认3，iOS结构体默认3未被真实恢复路径采用。首次开启可能等整卡缩略图并扫描全部日期 | `PhotoFilterPersistence.load:221`、`normalizedRatingDays`；安卓`TransferViewModel:1278`。验收：无键→3，显式0→全部，1/3/5保持，非法值→3；真实列表初始化也核对 | 开发侧已修复；13/13专项通过，无键/显式全部/合法非法值及真实列表初始化已验证；N06其他未完项仍保留 |
| F032 | P2 / C08 | 每次目录/范围/传输状态发布都会调用控制器update；关闭评级时反复disable→setEnabled(false)清诊断，开启时反复setEnabled(true)关闭verbose。显式Debug探测中的普通更新可抹掉前次结果或关闭详细捕获。另iOS没有PhotoRatingDiagnostics.detail调用，缺安卓RAW头的字节/分块/等待/命令/解析耗时 | `PhotoRatingScanController.update/disable`、`PhotoListViewModel.publishSections`、`CameraRepository.readPhotoRatingHeaderCommand`；安卓capture状态只在LaunchedEffect键变化时重设，头部reader写detail。验收：评级关/开两种状态连续探测，中间目录新增/传输变化，结果保留且捕获结束恢复原状态；RAW详细耗时可复制 | 开发侧已修复；最终25/25专项通过，真实探测/列表更新与捕获恢复、RAW detail字节分块及gate/command实测均通过；待真机，N05/M02其他要求不据此核销 |
| F033 | P2 / C08、C29 | 评级呼吸与控件交替使用linear，安卓tween默认FastOutSlowIn；帮助气泡仅opacity过渡、点气泡本身关闭，未接安卓AnchorPopup的按钮锚点Genie与独立外部遮罩。点帮助外区域会落到筛选层，不能保证只关闭帮助并保留筛选 | `PhotoFilterPopupOverlay`task/180ms交替及ratingHelpBubble；安卓`FileListScreen:4710–4880`、`AnchorPopup`/Genie320ms展开350ms收起。验收：900ms呼吸、180ms交替曲线；帮助展开/中途关闭/外点/气泡内点与底层滚动；既有公共组件不等于此入口已接入 | 功能范围开发侧已核销：独立帮助遮罩仅关闭帮助，内点保持、拖动消费、底层筛选禁用触摸及呈现变化清理均已对照安卓；三语文案6/6一致，历史编译成功。未做UI手势/真机验证；样式动画按用户范围延期。 |
| F034 | P2 / C09、C10、C14 | 断线后旧列表仍可点击；单张、日期组和连拍组入队仅检查目录，无本地原片也会震动/飞行并入队等待。安卓先按当前存放方式查本地原片，断线且缺原片时拒绝整次操作、强调信号并提示 | iOS `PhotoListView.enqueueFileFromList:1554/enqueueSection:1511`、`TransferQueueViewModel.enqueue`；安卓`FileListScreen:1283–1342,1549`。验收：有/无本地原片、混合批次、延后传输开/关、断线/重连；离线已有原片的自动生成另由C14核查 | 功能开发侧已补齐并复核，11/11专项通过；单/批/预览入口共享准入，真实磁盘三种存放方式及删除刷新已验证；页面手工验收待集中进行，样式动画延期 |
| F035 | P2 / C09、C10 | 连拍合集图片轻点会展开，长按先把expandedBurstIDs写入底层列表，再打开预览；安卓图片轻点无动作，仅右下按钮展开，长按构造独立预览快照直达首成员，底层列表不提前重排 | iOS `PhotoListView:489,1525–1551`；安卓`BurstCollectionCell`及`onPreviewBurst`。验收：合集图片/两个按钮各自轻点和长按，开预览前箭头/列表不闪动；关闭与预览内显式展开另核对。`617082c3`已含该约定 | 功能开发侧已修复；4/4专项通过，图片轻点无动作、长按独立预览展开与首成员定位已接；实际触摸路由待集中手工验收，T04其他缺口仍未完成 |
| F036 | P2 / C09 | 已保存类型在当前扫描结果中全部不存在时，iOS仍保留筛选并得到空列表；安卓完整扫描结束、非加载中会清无匹配/空集合选择，扫描中保留。iOS只做卡槽归一化，未接类型归一化 | iOS `PhotoListViewModel:369–388,425–482`；安卓`FileListScreen:921–937`。验收：相机A只选NEF→相机B只有JPG，扫描中不清、完成后恢复全部；含一种有效类型时保留选择 | 开发侧已修复，30/30扫描专项通过；扫描中保留、完成后全失效/空选择清理、部分匹配整组保留及持久化已验证；待真机 |
| F037 | P2 / C09 | 回顶按钮只按偏移超过360显示，没有安卓“首可见索引≥30且向上滚动才显示、向下/近顶立即隐藏、停止1.8秒隐藏、程序回顶期间抑制”的规则 | iOS `PhotoListView:574–591`；安卓`FileListScreen:744–782`。验收：2/3/4列向深处滚/反向滚/静止/点击回顶；阈值须按条目而非固定像素替换 | 功能开发侧已修复，8/8专项通过；实际条目索引/滚动状态/停止计时/回顶复位已接，真机手势待集中验收，精细回顶动画延期 |
| F038 | P2 / C09、C15 | 同handle手动多次导出后，缩略图状态优先取第一条传输中、再第一条等待，覆盖新任务状态；安卓固定取最新一条任务，包括最新完成/取消/失败 | iOS `TransferQueueViewModel.task:42`及格子调用；安卓`buildLatestTaskIndexByHandle`和`PhotoListDerivedStateTest`。验收：旧传输中+新等待、旧等待+新取消/完成，显示最新任务；完成统一目录绿勾 | 开发侧已修复，43/43队列专项通过；25种新旧状态组合及真实快照撤回/删除/清空/同步发布一致性已验证，待真机 |
| F039 | P2 / C09、C10、C15 | 连拍合集与展开后的首成员都按firstFile.id登记frame；同一Preference字典键互相覆盖，不能同时表示合集和成员，关闭预览/飞行/日期收起可误取另一格坐标。安卓以burst id和handle分别登记，并用可见key筛选 | iOS `PhotoListView:437–475`、`PhotoListCellBoundsPreferenceKey`及`preparePreviewDismissTarget`；安卓两个registry/`AutoQueueFlightSourceTest`。验收：展开合集和首成员同时可见、滚出仅一个仍可见，预览返回只指向成员，合集入队从自己的按钮出发 | 功能开发侧已修复，10/10坐标与滚动专项通过；照片/合集/按钮独立身份、成员返回及可见性过滤已接，页面手工验收待集中，精细动画延期 |
| F040 | P3 / C08、C09 | 评级尚在扫描、具体星级暂未有结果时，iOS空页已显示“没有符合筛选条件的照片”；安卓同状态刻意隐藏该句，避免把“尚未知”报作“无匹配” | iOS `PhotoListEmptyState:2122`及调用539未传评级状态；安卓`FileListScreen:1616`。验收：慢速评级/忙态暂停/最后完成且确实零匹配；未知与确认空结果区分 | 开发侧已修复，16/16评级专项通过；真实列表慢读/忙态/最终无匹配及清筛选恢复已验证，页面手工验收待集中 |
| F041 | P2 / C09、C29 | 照片/合集缺安卓各皮肤主题细边框及展开连拍成员橙边；合集叠片旋转/位移、按钮尺寸用比例近似，未接安卓30/34/36/40尺寸档、暗底/渐暗层；日期数和状态徽标直接替换，未接对应进入/退场，日期收起额外整组透明度变化 | iOS `CameraThumbnailView/BurstThumbnailView`、日期header与gridframe；安卓`ThumbnailCell/BurstCollectionCell/GroupHeader`及`ThumbnailThemeBorderTest`。验收：2–4列、四皮肤明暗、展开成员、删除前三/非前三、等待→完成→移除、日期收起/展开；按源码逐参数核对，不以近似截图通过 | 按用户最新范围延期：本项为精细样式和动画，不计已修复，留后续集中处理 |
| F042 | P2 / C09、C15 | 手动单张/整组飞行每次均生成UUID并押扣计数，缺安卓同起点在途去重；没有有效frame也伪造屏幕中心起点。连点同格会产生重叠飞行/计数暂扣，安卓无有效来源则不飞且同源只保留一摞 | iOS `startListQueueFlight:1698`及入队调用；安卓`enqueueSingleFile/onTransferGroup`中from非空和queueFlights.none判定。验收：同帧双击、飞行中再点、未布局/离屏源、切队列及取消；任务允许重复，去重仅限视觉飞行和对称计数 | 功能开发侧已修复，12/12专项通过；无效/同源飞行不押扣，完成取消按ID一次释放，路由离页清理已接；精细动画延期，页面手工验收待集中 |
| F043 | P2 / C09、C28 | 日期筛选解析/保存用Gregorian，但拨轮取年月日、范围和修改用Calendar.current；系统设佛历/其它历法时显示与相机公历不一致，闰月历的固定1…12月还无法完整表达日期 | iOS `PhotoFilterDateEditor:466–525`、`DateEndpointEditor:54–95`；安卓`DateRangeEditor/LocalDate`固定ISO公历。验收：系统公历/佛历/农历，闰日/跨月及同一相机日期，展示编辑提交统一公历；其它日期消费由C28核销 | 开发侧已修复，2/2专项通过；两个编辑入口共用公历逻辑，4历法×2时区的闰日/跨月/范围/提交验证通过；系统设置切换后的页面待手工验收 |
| F044 | P2 / C10 | AP/USB预览固定FHD→LargeThumb→GetThumb，任意失败立即走下一条；缺安卓FHD忙时2次/160ms重试和会话能力记忆。还在EXIF之前发GetThumb，绕过“当前页FHD失败且EXIF结束才远程缩略图兜底”的生产约束 | iOS `CameraRepository.preview:1467`、`CameraSession.previewAndExif`；安卓`NikonCamera.getFhdPicture:2956`及`FhdResponseDispositionTest`、`PhotoPreview.loadExifPage`后fallback门控。验收：忙→成功、三次忙、首次不支持→下一文件免请求、先成功再异常、空payload、取消/传输失败；AP/USB不可误套STA独立LargeThumb/MPF路径 | 开发侧已修复，43/43协议/调度/STA专项通过；普通FHD重试能力记忆、失败后EXIF顺序及传输失效不续发已验证；页面实际触发与真机待集中验收 |
| F045 | P2 / C10、C20 | 普通FHD用UIImage(data:)并经Image(uiImage:)显示，保留并自动消费EXIF方向；安卓普通预览明确honorExifOrientation=false，保持相机返回像素方向，由全局手动旋转控制。带非1方向的JPEG会与安卓不同，也影响后续裁切方向基准 | iOS `PhotoPreviewView.loadHighResolution/finishRemoteImageLoad`及`PreviewImage`；安卓`CameraViewModel.loadFhdPreview/loadFhdBitmap:4337`。验收：同像素、EXIF1/3/6/8及镜像2/5的FHD，初次方向/手动四转/跨页一致；设置效果预览仍应校正方向，不能把两种来源混改 | 开发侧已修复，真实JPEG EXIF1–8×四转共32组合像素比较通过（1/1专项）；当前/邻页同入口，效果预览独立；实际页面/裁切映射待各自验收 |
| F046 | P2 / C10 | iOS当前页和邻页直接解码完整响应，没有安卓1920长边上限/先采样再缩小。STA可回退较大的嵌入预览，±2页保留并不能限制单图内存；UIImage创建和直方图重算也在主线程路径，没有安卓后台解析边界 | iOS `PhotoPreviewView:789–839,669`；安卓`CameraViewModel.loadFhdBitmap:4356–4445/MAX_FHD_PREVIEW_EDGE=1920`。验收：超1920 FHD/RAW嵌入图连续翻页，检查像素尺寸、缓存峰值及主线程阻塞；不能只测普通1920夹具 | 开发侧功能与资源验证已完成：1920采样/后台解码、迟到结果隔离、独立缓存淘汰及加载生命周期已补齐；完整生产页连续翻页与资源采样、24MP连续解码、取消/生命周期集中4/4通过。按开发侧范围核销，详见2026-10-17验收；真机性能未测 |
| F047 | P2 / C10、C25、C28 | 照片直方图仍是preview_histogram_enabled布尔和单亮度曲线；缺OFF→RGB→LUMA、preview_histogram_mode及旧bool→LUMA迁移。开着直方图滑到视频时未排除视频封面；算法也没有安卓FHD JPEG≤512长边8bit/sRGB完整分析图路径 | iOS `PhotoPreviewView:180,487,660–678,1045–1127`；安卓`HistogramMode`、`TransferViewModel:1291,1495`、`SelectablePreviewHistogram`与`previewHistogramFromJpeg`。验收：三档循环/独立持久化/旧值迁移、视频隐藏、合集不改偏好、点状高光与RGB共享归一化；监看模式不能代替照片模式 | 功能开发侧已修复：三档独立偏好/旧值恢复、视频合集排除、RGB共同峰值、≤512 JPEG全像素分析与缓存复用；分阶段测试见文末，UI/真机未验收 |
| F048 | P2 / C10、C13 | 预览“已传”除目录索引外还把任一匹配队列任务completed当真，并保留打开时localOriginalURLs；选新空目录或改变按天/按类方式后，旧完成任务仍可给新目的地照片画绿勾。安卓预览直接复用当前目录索引，不另推断任务完成=存在 | iOS `PhotoPreviewView.transferredOriginal:878`、init本地URL快照；安卓`FileListScreen.hasLocalOriginal/isTransferred`→`PhotoPreviewOverlay`。验收：旧目录完成后选空目录/换存放方式→重新开预览，列表/预览绿勾一致，清队列不改变真实已传 | 功能开发侧已修复：移除打开时URL快照和completed推断，列表/预览共用当前目录索引；索引专项通过，实际UI/真机未验收 |
| F049 | P2 / C10 | 合集预览三张叠片只读一次缓存、缺图后不观察更新也不远程补图；安卓普通合集页在340ms门控后允许loadThumbnail，只有飞行影子禁止新取图。iOS还把点击关闭仅绑在叠片上，安卓整个合集舞台可点关闭 | iOS `BurstCollectionPreview/CachedBurstThumbnail:1378–1464`；安卓`BurstCollectionPreviewPage/BurstCollectionStack/BurstStackPhoto`。验收：AP/USB未缓存合集、门控前后命令顺序、随后缓存到位、舞台空白处点击关闭；STA继续遵守用户顺序后台加载例外，不为修复重排队列 | 功能开发侧已修复：合集AP/USB门控补图、缓存订阅、STA顺序例外及舞台点击；store 16/16通过，页面计时/触摸未验收 |
| F050 | P2 / C10 | 每次构造PhotoPreviewView都会遍历全部文件并逐个重新扫描目的目录来找本地原片，仅为绿勾；相同目录重复扫描，主线程成本约照片数×目录条目数，翻页/任务等父视图更新还会重复init。安卓在后台构建分页快照，已传用现成索引查询 | iOS `PhotoPreviewView.init:270–283`→`existingTransferDestination:321`→`TransferDirectoryIndex.scan`；安卓`FileListScreen.onPreview/onPreviewBurst`及ExportedOriginalIndex。验收：数千照片、同目录大量原片时打开/翻页，不同步反复enumerate目录；复用既有目的地索引且保旧会话快照 | 已随F048移除逐文件目录扫描，复用现成索引；功能开发侧核销，无大目录性能计时 |
| F051 | P2 / C10、C15 | 预览入队影子使用固定0.72屏宽×0.52屏高矩形scaledToFill和0.46屏高起点，未保当前照片适配位置/旋转；主图上抬只有位移，缺安卓最多5.5%缩小/7%透明度联动。回位及连拍收起弹簧用近似response，丢不同stiffness/damping及中断速度；缺有效target也伪造落点 | iOS `PhotoPreviewView:363–408,714,883,980,1129`；安卓`startPreviewQueueFlight/HorizontalPager.graphicsLayer/queueFlightBitmap`、回位弹簧MediumLow与Medium、收起High下0.7/0.68两路。验收：横/竖/已旋转照片和合集、拖拽/按钮两种触发、无图/无目标、连点/中途退出；用真实图层几何而非固定卡片 | 功能范围开发侧已核销：真实入队先于hold，切页/退出共用幂等清理，取消任务首轮及等待后均隔离，完成前复位再回调。队列/控制器专项6/6通过；整页触摸回放未运行，飞行几何和动画延期。 |
| F052 | P1 / C11 | ticket已由pump移出pending并设active，调用者此时取消：waitForAdmission末尾checkCancellation先抛错，外层admitted还为false，defer只cancelWaiting而无法清active；后续相机请求永久等待 | iOS `CameraIOGate.withCameraTransaction/waitForAdmission/cancelWaiting/pump`；安卓`CameraIoGate.acquire/cancel`同时清理pending和已选中active。验收：阻塞一项→下一项选中后、返回acquire前取消→第三项必须执行且snapshot归零；测试hook须放在交接窗口，现有transfer probe在admitted之后不覆盖此处 | 已修复：C32重读确认按ticket身份finish；已查另一轮17/17 TEST SUCCEEDED日志，本轮未重跑；N01/N02仍未完成 |
| F053 | P2 / C11、C25 | eligible删除了activeDownloads对IDLE的准入屏障；存储监看也误用心跳的withIdleCommand(nil)，下载期间直接清空本轮卡余量，下一次30秒轮询才可能恢复。安卓普通MONITOR_STORAGE排队等下载结束，不把忙态当作无容量 | iOS `CameraIOGate.eligible`、`CameraRepository.monitorFreeBytes`、`RemoteViewModel.refreshMonitorStorage`；安卓`CameraIoGate.eligibleLocked`和`MonitorStorage.monitorFreeBytes`。验收：下载跨多个slice/间隙、队列先后两种顺序，心跳按规则跳过，存储读等下载结束且保持旧显示；取到通道后再次核对页面allowed条件 | 功能开发侧已验证核销：整文件IDLE屏障、普通MONITOR_STORAGE等待与allowed回检；f053-storage 24/24通过，真实机身未验收 |
| F054 | P2 / C11 | 运行期无线CloseSession经retireOpenedSession直接抢PTPSession锁，没有提交allowDuringShutdown的P0 ticket；beginShutdown保留的多命令active事务可能在两个协议命令之间被CloseSession插入并使后续命令失效。仅单条PTP串行不等于完整调度事务收尾 | iOS `WiFiConnectionService.disconnect/closeConnection`→`PTPIPSocketTransport.retireOpenedSession`、`ConnectionViewModel.wifiTransportLost`；安卓`NikonCamera.close`。验收：评级头追加/目录多命令ticket执行中触发关闭，CloseSession必须在完整active收尾之后、只发一次，新业务拒绝；握手失败的pre-publication清理继续独立 | 功能开发侧已修复：service.disconnect→共享P0关闭，真实两段评级事务/重复关闭/取消回放及STA清理回归通过（20+12项）；真实socket未验收，N02其他范围独立 |
| F055 | P2 / C08、C11 | 快速关闭→开启评级，新scanTask启动后旧读才完成排空；旧startReading收尾在revision校验之前无条件scanTask=nil，抹掉新任务句柄。再次关闭无法cancel新扫描，而新循环只检查Task取消、不检查revision，仍继续读剩余文件并保持评级屏障 | iOS `PhotoRatingScanController.startReading:490–530`、`disable/beginFreshGeneration`；安卓扫描Job由LaunchedEffect拥有且finally成对endPhase。验收：阻塞旧读→关开→新读排队→放行旧读→再次关闭，后续新代读停止且屏障归零；旧完成不得覆盖新任务owner | 功能开发侧已验证核销：旧收尾先校验revision，关开关交错17/17及真实gate屏障归零1/1通过；N05其他范围保持独立 |
| F056 | P1 / C12 | 完整GetObject有declaredByteCount时只校验declared、传known=0，漏掉目录/GetObjectSize的已知大小；100B对象若只收80B且数据相位也声明80B会被发布为成功，声明0/UInt32.max时同样跳过已知大小。安卓明确拒绝这种自洽短读/超长 | iOS `CameraRepository.downloadResultImpl:1873–1882`；安卓`DownloadIntegrity.mismatchedFullObjectSize`及`rejectsSelfConsistentShortOrOversizedDataPhase`。验收：known100/declared80/received80、120/120、0/80、sentinel/80均失败，真正未知流仍可成功，失败不发布原片 | 已修复，待真机验收：第一组最终56/56通过，见修复进度；V004待证，T21整体暂不恢复完成 |
| F057 | P2 / C12、C11 | STA普通照片仍使用视频4/32/64MiB分块循环，且短响应后继续读下一块；安卓照片强制partial时仍只发一个全照片请求，短读直接失败，超过Int.MAX_VALUE拒绝。iOS chunk helper没有videoTransfer参数，页面吞吐开关也会改变STA照片请求数/可插队边界 | iOS `transferDownloadChunkSize`、`CameraRepository.downloadResultImpl:1796–1858`；安卓`downloadChunkSize(videoTransfer=false)`、`VideoTransferPolicyTest.photosNeverUseMultipleRequestsRegardlessOfPageOrTransport`。验收：STA 24/120MiB照片两种页面都单事务完整取图，视频保留分块；短数据相位和超大照片分别处理 | 已修复，待真机验收：第一组最终56/56通过，见修复进度；V004待证，T21整体暂不恢复完成 |
| F058 | P2 / C12、C14 | 照片普通失败后仍留下.nkpart，队列完整半成品捷径又没有视频门控；若失败响应已带齐known字节，下次重试可直接改名为原片且不重读相机。安卓照片在失败/重试前清半成品，只有视频允许完整part捷径与续传 | iOS `CameraRepository.downloadResultImpl`仅Task.isCancelled清照片、`TransferQueue.run`普通catch和completePartial分支、`TransferDirectoryIndex.completePartial`；安卓`TransferViewModel`videoTransfer清理及onFailure。验收：JPG/NEF收到known字节后负响应/写入失败→重试必须清理重下；MOV同样场景按视频规则保留，启动清理不替代本进程重试 | 已修复，待真机验收：第一组最终56/56通过，见修复进度；V004待证，T21整体暂不恢复完成 |
| F059 | P2 / C12、C04 | USB已知大对象首次partial不支持后仍回退完整GetObject，能力记为false后后续大对象也直接完整取图；真实ImageCapture适配器一次回调持有完整Data，4MiB限制因此失效，可能一次分配数百MiB/数GiB。只对“未知大小”拒绝回退不能保障已知大文件资源上限 | iOS `CameraRepository:1780–1830`、`PTPCommandTransport.receivePTP`默认缓冲适配器和`SelectedUSBPTPTransport`；已有bounded USB测试只覆盖partial成功/未知大小失败。验收：已知2GiB视频0x2005及第二文件，检查选用有界平台路径或明确失败、无无界回调；保留安卓安全fallback语义时必须同时满足iOS平台内存约束 | 已修复，待真机验收：第一组最终56/56通过，见修复进度；V004待证，T21整体暂不恢复完成 |
| F060 | P2 / C13 | 通用安全目录名函数只在扫描旧子目录时使用，真实入队→transferDestinationDirectory→createDirectory从未校验；BY_TYPE从相机文件扩展拼出的含斜杠/空格/超64字符目录直接创建。安卓getOrCreateTransferDirectory在实际创建前require安全规则 | iOS `TransferQueue.storageTypeFolderName/transferDestinationDirectory/run:766`；安卓`TransferViewModel.getOrCreateTransferDirectory:1917`及`NewMediaTransferPolicyTest`。验收：合法ZT-JPG成功，超长/空白/带路径成分的扩展和恢复任务目录拒绝、不创建意外层级；helper单测之外必须覆盖worker | 已修复待真机：worker创建/查索引/相机调用前校验，重试同样重验；绝对锚点与安卓全串匹配一致。非法目录拒绝、合法任务继续与64字符边界及队列回归18/18通过 |
| F061 | P2 / C13、C14 | 换目录/清目录立即stopAccessing旧URL，传输worker和已交接的生成任务仍用开始时旧root；任务没有独立持有security scope，后台读取原片/创建效果文件可在授权已释放后进行。安卓旧队列持有原tree的持久授权，换目录不撤销它 | iOS `DirectoryAccessStore.setDirectory/clear`、`TransferQueue.run/FrameJob/renderFrameFile`；安卓`setTransferDirUri/processQueue/getOrPreparePhotoFrameDestination`。验收：外部File Provider原片下载中/两路生成中重选目录，新选择生效且旧任务可完成；各任务结束才释放对应旧授权 | 已修复待真机：DirectoryAccessLease由下载/裁切准备/FrameJob持有原root，选择切换仅释放选择自身引用；生产接线与授权计数25/25、确认双路挂起补强1/1通过，外部Provider实机待验 |
| F062 | P2 / C13 | 启动restore先发布directoryURL，再启动无人等待的detached清理；队列无需等待清理即可创建同前缀.nkpart，新文件若被清理枚举到会被删。清理也没有本次任务/进程身份排除 | iOS `DirectoryAccessStore.restore`、`TransferDirectoryIndex.removeStaleTemporaryFiles`；安卓`primeDirectoryIndexScan/getDirectoryIndex`共用scan并await，生成临时文件另排除当前session。验收：人为挂起启动清理→接相机并入队→释放清理，当前文件不能消失；旧残留仍清除 | 已修复待真机：restore发布前注册共享准备，queue等待清理；当前进程frame保护、已用root不重复清理与独立取消。确定性生产竞态及回归最终32/32通过，真实杀进程/Provider重启待验 |
| F063 | P2 / C13 | 正式原片finalize只试原名及1…99，全部占用就报保存失败且删除完整part；安卓正常发布先在共享index寻找下一个任意序号，100及以后仍能保存。iOS原片碰撞查询还依赖文件系统大小写规则，没有安卓统一忽略大小写的占位表 | iOS `finalizeTransferTemporary`；安卓`ExistingFileNameIndex.reserveDisplayName`及`processQueue:2718`。验收：相同原名已占0…99且大小不同→生成(100)；大小写敏感provider上同名不同大小也按规则加后缀；不得覆盖已有文件 | 已修复待真机：原片无限递增/忽略大小写共享预留、同名rename→copy、外部目标冲突保护；真实下载100重名、并发发布和回归56/56及迁移旧测试1/1通过 |
| F064 | P2 / C13、C14 | 两个生成worker分别扫描目录后选择文件名，没有共享预留；同时生成同一preferred名称可选择同一路径，Data.write(.atomic)会替换已被另一路发布的文件。安卓在写临时文件前同步reserve，并在成功/失败后分别保留或释放占位 | iOS `TransferQueue.startWaitingFrames/renderFrameFile/uniqueFrameURL`；安卓`PhotoFrameExporter.reservePhotoFrameName/writeRenderedBitmap`与共享`photoFrameDestinations`。验收：两路在名称选择处同步阻塞后同时发布，结果要有独立有效目标或按既有完整产物规则复用，不发生覆盖；失败释放预留且原片不受影响 | 已修复待真机：共享名称预留与隐藏暂存已接生产renderer；重叠预留、失败释放及真实并发JPEG发布与队列回归17/17通过。T22其他缺口仍未完成 |
| F065 | P2 / C14 | 生成仍固定两个worker，pending/frameJobs无4096容量/满队列失败出口；安卓当前为单个低优先级计算worker，4096包括准备中/等待/运行，保序并允许就绪任务越过未准备项。旧双工测试明确期待过时规格 | iOS `TransferQueue.frameParallelism/startWaitingFrames`；安卓`PHOTO_FRAME_EXPORT_PARALLELISM=1`、`PhotoGenerationQueue`及测试。验收：超过4096、未准备头项、关闭、取消/单项失败后继续；实际并发计算≤1，资源拒绝能完成状态 | 已修复待真机：4096共享准入/单utility计算、实际准备旁路、满失败与释放重试、关闭和迟到回调隔离；状态及生产97/97、身份交接32/32通过。F066完整parser解耦另行保留 |
| F066 | P2 / C14 | startFrameGeneration在下载worker中await相机身份、补头和解析，完成后才继续下一原片；安卓交接只登记准备请求，独立parser/补读消费者推进，慢相机补头不阻塞已捕获头解析和后续下载 | iOS `TransferQueue.run/startFrameGeneration`；安卓`handoffPhotoGeneration/PhotoMetadataPreparation`。验收：首张已有原片但补头阻塞、第二张待下载/已捕获完整头，第二张仍可推进；同时保留调度器P3与取消边界 | 已修复待真机：下载仅登记有界头/recipe，独立身份、parser与补读consumer；捕获/补读解析共享串行actor，backgroundThumbnail不变。109项回归和最终8项边界验证通过，解析挂起仍能继续原片下载、关闭隔离迟到结果 |
| F067 | P2 / C14、C19 | 元数据仅固定256KiB并以“解析出任意字段”作为可用，无COMPLETE/NO_EXIF/PARTIAL/FAILED状态、部分头1MiB/2MiB有界补读、无EXIF结果复用；frameMetadataCache到下次run前无256项LRU，字符串也未套256 UTF-16单位上限 | iOS `startFrameGeneration/frameMetadataCache/PhotoFrameMetadata.cameraSnapshot`、`frameMetadataHeader`；安卓`PhotoMetadataPreparation/PhotoMetadataSnapshotBounds`及测试。验收：被截EXIF保已有字段并有界扩读；无EXIF相同来源不反复读取；大批次/超长字段受限；失败不遗留重数据 | 已修复待真机：四态/1MiB与2MiB扩读/失败保字段/256项LRU/256 UTF-16边界，2MiB内存与16MiB磁盘头预算、同键等待共享已接线；109项回归及最终8项边界验证通过。真机内存压力和真实杀进程恢复尚未验收 |
| F068 | P2 / C14、C15 | 生成开始时间在准备/排队前记录，最终elapsed包含补头和排队等待，失败/复用已有效果图也保留耗时；安卓只累计实际计算，裁切后等metadata暂停计时，未保存效果图不展示完成生成耗时 | iOS `startFrameGeneration/FrameJob.started/generateFrame.defer`；安卓`queueFrameGeneration/startFrameGeneration/pauseFrameGeneration/finishFrameGeneration`、`TransferStateTest`。验收：准备等待5秒+计算0.5秒只记0.5秒；排队/失败/已有图与裁切后等待各覆盖 | 已修复待真机：计算slot起点、未保存不留终值、单调UI展示及crop暂停累计已接线。动态关闭→crop200→开启后等待5000→effect300合计500实测，等待中关闭保留200；52项及42项下载回归通过。未实际系统校时验收 |
| F069 | P2 / C14、C17 | 缺photo_effects_enabled全局开关及运行期门控；安卓允许保留入队配方后在计算选中时关闭效果，普通任务跳过，裁切仍执行且标记仅裁切，已运行导出可完成；iOS只按入队模块配置直接生成 | iOS全树无该状态/偏好及frameGenerationSkipped/cropEffectsSkipped；安卓`setPhotoEffectsEnabled/launchPhotoFrameExport`、SettingsScreen总开关。验收：等待期间关→跳过、关后再开且尚未选中→原配方、裁切关效果仍保存crop、运行中关闭不取消 | 已修复待真机：运行期门控/跳过/裁切暂停恢复及独立准备容量通过52项；设置store独立持久化、RootView传递、180ms Oklab开关已接线，25项回归与真实设置页UI1项通过。配方/水印/本地照片作用域保留 |
| F070 | P2 / C14 | 派生失败重试仍要求当前directory，重置为WAITING并加入下载队列，丢原片下载计时/速度，受下载暂停影响；保留outputURL却不用它作为重试源，改目录后会重新找/下载。安卓直接向生成队列交接已保存root/parent/source，保留成功下载状态和指标 | iOS `retry/retryFailed/run`；安卓`TransferTask.newAttempt/dispatchRetryAttempts`、`generationRetryRetainsSuccessfulDownloadAndMetadataWithoutReenteringDownloadQueue`。验收：生成失败→清/换当前目录→暂停下载→重试，只用旧原片/目标/metadata并独立推进，单条与批量一致 | 开发侧已修复，待真机Provider；独立分派与位置/指标保留，91/91回归通过 |
| F071 | P2 / C14、C15 | 已有原片及完整part路径把failTaskOnError=true传给生成，效果失败将整卡改FAILED/error；安卓原片一旦发布保持COMPLETED，只设置frameGenerationError。iOS对新下载与已有原片呈现不同结果 | iOS `run/startFrameGenerationIfNeeded/generateFrame`；安卓本地命中与生成complete。验收：相同原片从本地命中/新下载各触发编码或metadata失败，下载状态仍成功，效果失败单独可重试 | 开发侧已修复，待真机；移除failTaskOnError分支，纠正旧测试，90/90回归通过（见下文） |
| F072 | P2 / C14、C20 | 本地命中/完整part/新下载三路都在下载worker中等待裁切；新下载还在裁切之后计算下载elapsed和MBps。安卓原片完成即交接计算队列，裁切不拖慢下一原片、不算下载耗时 | iOS `TransferQueue.run:780–941`；安卓`launchPhotoFrameExport.execute`裁切及任务计时。验收：慢裁切首张+第二张下载，原片完成即可推进第二张；下载时间不随裁切耗时增长，裁切失败仍保留原片 | 已修复待真机：三条原片路径仅发布/交接，裁切与普通效果共享单计算槽位；下载指标在裁切前冻结，裁切后效果重试复用cropURL。85项回归、42项路径和12项生命周期验证通过 |
| F073 | P2 / C14、C09、C10 | 所有手动autoStart及裁切入口均要求非nil session才调用queue.start，队列启动按钮亦如此；断线已有本地原片的任务会入队却不开始。底层start接受nil、现有测试直接调用底层，未覆盖页面/ViewModel | `TransferQueueViewModel.enqueue/enqueueCrop/start`、`PhotoListView.transferSession/queueTopRightControls`；安卓`addToQueue/startPendingTransfers`先本地原片预检且provider可空。验收：断线保留列表且已有原片，单张/组/预览/裁切、延后传输开关均能按既有规则启动 | 开发侧启动接线已修复，45/45回归通过；页面运行待验收；F034缺原片拒绝已完成功能复核，见其最新记录 |
| F074 | P2 / C14、C20 | 自动传输去重用全部items，包括cropTask；安卓只用非裁切任务建立已入队身份。已有裁切任务时，同照片的新媒体自动传输会被错误过滤 | iOS `TransferQueue.enqueueAutomatic`；安卓`addNewMediaToQueue`的cropRecipe==null。验收：仅裁切任务+同身份事件应入普通任务，已有普通任务仍去重；OFF及JPG/RAW/VIDEO模式边界保持 | 已修复待真机：仅非裁切任务建立自动身份Set；五种档位、双卡同身份/批内重复、普通与裁切两种入队顺序及既有入口回归12/12通过。T20完整运行验收仍待复核 |
| F075 | P2 / C15 | 启动/暂停显隐额外要求“已落地的等待数>0”，启动还要求defer或pause偏好；安卓isTransferring即显示暂停，未运行且有WAITING即显示启动，与飞行和defer无关。最后一张在传/首张已预约时无法预先暂停，自动模式中止后遗留WAITING也可能无启动入口 | iOS `PhotoListView.queueExecutionMode:1196`；安卓`queueExecutionControl`及QueuePillStateTest。验收：单张传输、文件交接、飞行未结束、自动模式留下WAITING、偏好改变，按钮始终按运行状态判断 | 已修复待界面/真机验收：两页共用顶栏直读snapshot.executionControl，只按isTransferring/WAITING判断；预约/交接/最后一张与生产单文件暂停、既有多文件生命周期3/3通过。F073及其他动画/准入缺口独立保留 |
| F076 | P2 / C15 | 卡片没有安卓左右侧滑移除，只额外放行内扫帚；缺横向slop后≥卡宽33%触发、180ms飞出宽+48/不足回弹、途中变忙撤销及无障碍移除动作 | iOS完整`QueueItemView`无拖动/侧滑；安卓`QueueCardSwipe`及TransferScreen接线。验收：左右32%/33%、快速短甩、垂直滚动、取消、等待期间开始传输、生成中及VoiceOver入口，不误撤回活跃任务 | 功能开发侧已闭环：侧滑与无障碍入口共用状态资格和撤回命令；最终10/10覆盖方向阈值/取消/变忙/迟到移除及生成保护，实际队列证明活跃任务不误撤回。历史真实卡片UI证据保留；VoiceOver设备操作、多指UI与逐帧样式验收按当前范围不作为开发关闭门槛，未声称已验证。 |
| F077 | P2 / C15 | 单卡/批量重试只判断session==nil和outputURL，未用实际isSessionConnected及当前本地原片索引。断线保留旧session时缺原片仍可点；恢复页无session但本地原片可用时又被禁。清空320ms窗口仅抑制全局按钮，未把clearAllInProgress传给卡片，途中新完成/失败卡仍可操作 | `TransferQueueView.queueBottomControls/QueueItemView`、PhotoListView传旧session+独立connected；安卓retryNeedsCamera及cardActionsVisible。验收：断线有/无本地原片、未下载但磁盘已存在、批量混合；清空期间新终态不闪重试/移除 | 已修复待真机：真实连接/保存原片/共享索引资格及生成/清空抑制已接；域12/12、重试UI 2/2通过，清空中新失败卡1/1通过。撤掉清空门控的负向对照确实捕获按钮闪现，恢复后1/1通过 |
| F078 | P2 / C15 | 清理/重试确认仅用pendingConfirmation挂载，资格消失/开始传输/顶栏控制动作不自动收起；使用固定右下92pt位置和0.86缩放淡入，未连接各FAB真实锚点Genie及退出期间遮罩生命周期 | `TransferQueueView.queueConfirmationOverlay/QueueConfirmationCard`；安卓hasRetryable/hasClearable、queueControlActionNonce、GenieInlinePanel/ConfirmFab。验收：弹出后新自动传输、最后可清项变生成、点顶栏控制、两种FAB独立锚点和中途反向关闭 | 功能范围开发侧已核销：资格/顶栏事件收起、互斥确认、旧确认/取消/退场回调身份门控及保留遮罩已核对；队列业务与实际弹层控制器专项6/6通过。完整UI手势与真机未验；精细视觉动画延期。 |
| F079 | P2 / C15 | 卡片信息缺裁切图标/裁切标签、仅水印标签（仍写边框模板名）、排队等待时钟及跳过状态；效果失败未加“生成失败: ”前缀且可能重复两条错误，同时仍显示效果行。未知ObjectInfo大小即使下载成功仍为“—”；长标题默认尾截断丢文件号/扩展名，取消也未降色 | iOS `QueueItemView.effectText/fileSizeText/body`；安卓`TransferTaskCardContent/TransferFileTitle/transferTaskEffectText/transferTaskFileSizeText`。验收：仅裁切/仅水印/组合/跳过、准备中/失败、未知size成功、超长文件名与取消三语；F069负责缺总开关状态 | 已修复待真机：错误优先级/前缀、裁切/水印/滤镜三语与跳过、Material图形、未知大小真实数据流及activeProgress身份隔离、长标题/取消降色已补。域测试及三组生产卡片三语UI通过，最新仅裁切/动态大小/长标题九张截图已查看；完整证据见末尾核销记录。F080动画视觉与F078仍独立未完成 |
| F080 | P2 / C15、C29 | 队列视觉仍近似：52缩略图/14圆角卡替代68/16、缺左侧色标/共享sheen/渐变边、胶囊圆形替代6圆角且缺来源收缩/分裂弹簧；行间8固定在LazyVStack，移除末帧才消失。空态无2400ms呼吸/340ms展开，顶部滚动scrim缺失、底部padding固定。顶栏生成用蓝色文字替代紫色图标，模式统一180ms替代入220延35/出160，宽度/滚数/按压弹簧近似；SmoothTransferProgress换ID额外220ms回零等待，安卓新ID从0直接追值 | iOS `TransferQueueView`及`PhotoListView.QueuePill/QueuePillRollingCount`；安卓`TransferScreen`、`QueuePill`、`TransferProgressMotion`、Motion。验收按相应源码参数分项：四皮肤明暗、状态/重试/滚出重入、清空回弹/末行、速度位数单位、换文件进度连续性；不能用helper通过代表实景一致 | 当前范围排除：用户2026-10-16明确后续集中处理样式与动画，本阶段只做功能与基础可用界面。原实现/验证及未完成项保留在历史分项记录，不计作已修复。 |
| F081 | P2 / C15 | AP/USB队列缩略图只以item.id触发一次，失败后没有安卓retryNudge=isTransferring变化补载；整个下载结束也不重试，除非行重建。STA观察缓存属于用户顺序加载例外，不要求远程补读 | iOS `QueueThumbnail.task`；安卓`QueueThumbnail`的LaunchedEffect(file.handle,retryNudge)。验收：首次DeviceBusy/瞬时异常→下载状态变化→同一可见卡恢复图；已有缓存不再读，相机改变不误用旧来源 | 功能接线开发侧已修复：isTransferring补试/成功复用/会话身份重建/STA仅观察；缓存16/16通过，实际卡片触发未UI验收 |
| F082 | P2 / C15、C14 | 整个TransferQueueView订阅progressModel，并把每次activeProgress值传给每张卡，高频进度仍使页面/全部可见行依赖变化；安卓只有活跃卡订阅。全量snapshots又用默认无界AsyncStream，慢UI会积压旧数组快照，安卓StateFlow只保最新 | iOS `TransferQueueView.progressModel/body`、`TransferQueue.snapshots`与ViewModel观察；安卓TransferScreen活跃卡分支及state/activeTransferProgress。验收：大队列200ms进度只刷新对应区域，故意阻塞消费者后不回放全部旧快照，最终状态一致 | 已修复（开发侧）：只保最新快照，生产订阅组件40行实际求值验证仅活跃行更新，切换/清除活跃行及慢消费者专项2/2通过；未测GPU绘制或设备RSS，见F082完成续记 |
| F083 | P2 / C15、C09 | 自动新媒体只入队，缺真实接纳结果→合并视觉事件→可见来源/列表上沿起飞的链路；预览/队列/监看遮挡期间也没有待显示批次和返回后一次消费。安卓该自动飞行不押扣实时队列数 | iOS `PhotoListView.setNewMediaHandler`、`TransferQueueViewModel.enqueueAutomatic`丢弃accepted结果；安卓MainActivity staged/pendingAutoQueueFiles及FileListScreen自动flight。验收：连拍合并、不可见期间多批次、回列表只飞一摞、换机丢旧视觉事件、真实入队与计数不等待动画 | 当前纯视觉范围延期：用户要求后续集中处理动画，本阶段不实现自动飞行链路、不计修复；N11保留未完成 |
| F084 | P2 / C15 | 手动飞行押扣被baseline限制：已有10项、新加2项飞行中又完成1项时iOS隐藏1仍显10，安卓actual11-held2显9；且iOS押扣作用到生成数并将heldCount纳入allDone，安卓只扣下载数，完成按真实任务。生成/瞬间本地命中会延迟Done或错显计数 | iOS `queueHiddenFlightCount/QueuePill.hiddenFlightCount/allDone`；安卓`queuePillDisplayRemaining/QueuePill`及QueuePillStateTest。验收：旧任务并行完成、重叠落袋、飞行中快速已存在跳过、下载归零但仍生成，计数按各阶段规则 | 功能开发侧已修复：去基线、只扣下载数、完成按真实任务，f084-counts 1/1；与F042/F083独立 |
| F085 | P2 / C15 | Done显示1.8秒期间加入延后传输任务，allDone变false却不清showDoneLabel；只有hasWorkingTask变true才取消旧提示。新WAITING不算working，所以仍显示旧Done并遮住等待数。安卓allDone一变false立即清提示/完成填充并取消延时 | iOS `QueuePill.onChange(allDone/hasWorkingTask)`；安卓`LaunchedEffect(allDone)`。验收：完成后100ms加入defer任务、立即本地跳过、取消任务归零和重新进入页，不重播/保留上一轮完成提示 | 功能开发侧已修复核验：allDone=false取消/清理Done；历史真实QueuePill完成→纯WAITING回归通过（f080-done-fill-r2），本轮未重跑UI，精确100ms未验 |
| F086 | P2 / C16 | 本地批次逐张错误被runner压成false，状态无失败详情，只在终态2400ms内显示总失败数；安卓保留最多5条照片序号、prepare/render/save阶段、memory/permission/space/missing/unknown原因和有界异常摘要，可复制，返回READY后仍保留到新选择/下一批 | iOS `PhotoEffectsBatchRunner/LocalPhotoBatchState/LocalPhotoBatchViewModel/batchFailureView`；安卓同名ViewModel和LocalPhotoEffectsOverlay失败区。验收：混合解码/权限/磁盘失败仍继续，详情与原序号对应、限5条、下一批清除；不吞取消 | 开发侧已补齐；F086专项12/12通过，系统文本选择复制及真机Provider失败未做UI/真机验收 |
| F087 | P2 / C16 | 本地效果预览只有长按对比，没有安卓轻点放大到SinglePhotoPreviewOverlay的入口、真实锚点和放大页对比/关闭；在小4:3区域无法按原功能检查成片细节 | iOS完整`LocalEffectPreview`及父页面；安卓`LocalPhotoPreviewPager.onOpen/PhotoEffectsRenderedPreview.onTap/expandedEffectsPreview`。验收：渲染就绪后轻点放大、带/不带滤镜、晚到对比图、关闭回真实页、滑动不误开、开前清焦点/收键盘 | 已修复（开发侧功能）：就绪入口、焦点/锚点快照、身份限定晚到对比、缩放及弹层生命周期已复核；模型/hosting专项通过，触摸UI与动画未验收，见F087完成续记 |
| F088 | P2 / C16、C18 | 相机公共编辑器与本地工作台的PhotoLUTStore都读写同一photo_lut_selected/intensity，无角色区分；本地onAppear试图用共享选中项恢复草稿，但另有F100身份不匹配，不能把这条恢复写成已可用。安卓保留共享目录/收藏，但camera/local各自保存选中digest/name/uri/strength/adjustments，切另一个编辑器不能改本地当前配方 | iOS `PhotoEffectsControls.photoLUTStore/LocalPhotoEffectsView.photoLUTStore/onAppear`、PhotoLUTStore；安卓PhotoLutStore.restore/save(role)及LocalPhotoEffectsPage的local角色。验收：相机A/本地B不同LUT与强度→各自关闭/重启恢复，不互相覆写；共享目录及收藏保留 | 开发侧已修复；双角色不同LUT/强度/微调重建、真实渲染及共享目录收藏专项4/4通过；UI未验 |
| F089 | P2 / C16、C17 | 本地页面在共用PhotoEffectsControls之外又无条件追加一个PhotoLUTChooser；因此可出现两个LUT选择器，关闭LUT模块或正在使用普通滤镜时底部入口仍可选LUT并启用。安卓只有按visibleModules及滤镜互斥控制的一处LUT编辑器 | iOS `LocalPhotoEffectsView.body:30–49`与`PhotoEffectsControls.body:126`；安卓LocalPhotoEffectsOverlay两处PhotoColorEffectGroup。验收：LUT模块关闭/免费联动/普通滤镜激活/启用LUT，各状态仅对应入口可见，隐藏模块不能通过额外入口重新启用 | 开发侧已核销：删除无条件重复入口，唯一公共入口接实际显隐规则；f089-visibility专项6/6通过。未运行UI测试，T18其他项未完成 |
| F090 | P2 / C16、C29 | 重新选图被移动为顶栏“更换图片”文字按钮，安卓在生成行左侧50方形图标并显示含数量的无障碍标签；页码/进度被与主标题居中串排，缺安卓左侧独立固定位置。就绪主文案用了带数量旧key，生成计数少分隔空格；点击生成没有清水印焦点/收键盘，批次按钮转场也用统一220ms近似 | iOS `toolbar/batchButton/LocalPhotoBatchLabel`及AndroidLocalization；安卓LocalPhotoBatchButton、LocalPhotoEffectsOverlay.onGenerate与buttonStateTextTransition。验收：空/选中/生成/三种结果/重选、长翻译/大计数、键盘显示时生成，控件位置/文案/显隐与动画逐项核对 | 功能范围开发侧已核销：清焦点、当前文本快照、生成/重选准入及三种结果已对照；批次专项3/3通过，三语文案21/21逐字一致。键盘与VoiceOver实机未验；位置、样式与动画按用户范围延期。 |
| F091 | P2 / C17 | 模块点击仅异或单个位再normalize：免费版框/水印不能成对关闭（effective又补回另一位），关闭最后一项会变成全开15；安卓点击框/水印异或12、结果为0时保持原值 | iOS PhotoEffectsControls.toggleModule；安卓togglePhotoEffectModule及穷举测试。验收：全部15种非空组合、免费/Pro四按钮；最后一项点击无变化且不触感，免费框/水印始终成对开关 | 开发侧已核销：公共按钮使用Android等价toggle规则，无变化直接返回；f091-toggle专项7/7通过，未运行UI测试 |
| F092 | P2 / C17 | 框和水印共用整个frameCard的FRAME位disabled/opacity，卡始终显示。Pro仅开水印时水印也不可编辑，仅开框时水印仍可编辑；没有安卓独立显隐分区 | iOS PhotoEffectsControls.body/frameCard末尾；安卓PhotoFrameWatermarkEditor的showFrame/showWatermark分组。验收：四种框/水印组合，水印单独启用/编辑/输出，隐藏分区不占位也不可操作 | 开发侧已核销：公共编辑器按两位分别构造控件，水印单独编辑/恢复/真实渲染双scope专项1/1通过；未运行页面UI测试 |
| F093 | P2 / C17、C18 | 生效配置和持久化一律用FILTER位门控photoFilterEnabled，未区分cube LUT；仅LUT模块时会关闭已选LUT，隐藏LUT但保留FILTER时草稿Cube仍可能参与预览 | iOS effectivePhotoEffectsSettings、PhotoEffectsStore.normalized；安卓applyModuleVisibility/setTransferPhotoEffectModules分别关闭NP3与photoLut。验收：NP3/Cube各自在FILTER/LUT四种掩码组合下预览、提交和生成，隐藏项不生效 | 开发侧已核销：effective/normalized按所属FILTER/LUT位门控，f093-matrix双scope与四掩码真实渲染专项1/1通过；完整LUT恢复另归F100 |
| F094 | P2 / C17 | 隐藏模块只改草稿mask，未按安卓立即清相应enabled；再显示可能复活旧效果。normalized先清watermark.enabled，随后又用原value.watermark覆盖，导致隐藏水印的启用状态也被保存 | iOS toggleModule、persistingEditorPreferences、normalized；安卓applyModuleVisibility及commitPhotoEffectsDraft。验收：启用→隐藏→显示/退出重开，保持关闭但参数/素材仍保留；覆盖相机草稿与本地即时保存，勿把显式隐藏与权益降级混淆 | 开发侧已核销：显式隐藏关闭及水印覆盖修复；f094-hide 10/10、f094-command 9/9通过，角色隔离与重新显示/恢复不启用已验证 |
| F095 | P2 / C17、C18 | 编辑器互斥依据selectedFilter身份而非是否启用；默认记住首个NP3但enabled=false时LUT入口已被隐藏，选择“关闭滤镜”也不清记忆身份，仍无法进入LUT。反向关闭Cube仍挡普通滤镜 | iOS PhotoEffectsControls.body、PhotoEffectsSettings.selectFilter、PhotoEffectsStore.init；安卓filterDraftEnabled/photoLutDraft.selection的互斥条件。验收：首次打开、关闭NP3、关闭Cube、恢复未启用记忆项时，两类可重新选择；本地额外入口F089不算正确补救 | 开发侧已核销：活动选择显隐规则及LUT关闭生产命令接唯一入口；f095-off专项9/9通过，未运行UI测试 |
| F096 | P2 / C17、C19 | 边框收藏只保存preset和watermark，未包含宽度/背景模糊/遮罩；Android格式解码只接受9字段，10/12字段条目被丢弃。修改/应用收藏无法恢复安卓完整配置 | iOS PhotoFrameFavorite及decode/encodeAndroidFrameFavorites、toggleFrameFavorite/updateMetadata；安卓PhotoEffectFavorites和compactWidth/backdrop/legacy测试。验收：宽度60/200、背景0/200收藏后改参数再恢复、旧9字段及10/12字段恢复；当前文字/图片继续使用当前内容，不恢复历史素材 | 开发侧已核销：完整收藏参数、9/10/12字段与旧JSON兼容、生产捕获/修改/应用接线；f096-apply专项5/5通过，未运行UI测试 |
| F097 | P2 / C17、C29 | 效果模块菜单被替换成常驻四个11pt胶囊，无安卓顶栏Tune入口、锚定弹层、关闭行为和有效变更tick；占用编辑器内容空间且交互层级不同 | iOS PhotoEffectsControls.moduleMenu及两宿主工具栏；安卓完整PhotoEffectModuleMenu。验收：相机/本地工具栏打开、外部点击/主题切换/有效及无效切换、18圆角/156宽/8锚点间距及分区过渡 | 功能开发侧已闭环：两个工具栏共用实际按钮锚点菜单，选择后保留、仅有效变更tick、外点关闭接线已审查；真实宿主主题/入口移除/离页关闭及草稿不变2/2通过，既有模块6/6及三语15条证据保留。按用户范围未运行UI手势自动化，精细样式动画延期。 |
| F098 | P1 / C18 | 选Cube后PhotoEffectsStore.normalized只用NP3的PhotoFilterCatalog.resolve，Cube必被置nil且enabled=false。本地两个入口立即经过update，选中即丢；相机可在草稿预览，退出提交后丢，后续传输无法采用该LUT | iOS PhotoEffectsStore.update/updateFromEditor/normalized、LocalPhotoEffectsView两个入口、SettingsView提交；安卓PhotoLutStore及setPhotoFilterConfiguration。验收：真实相机/本地编辑器选择Cube→预览→提交→生成→重开保持，不能只测手工构造renderer参数 | 开发侧已核销：生产选择/提交保留Cube，双scope启动恢复及真实渲染通过；f100-hosts 12/12，未做UI或实际杀进程验收，T14其他项未完成 |
| F099 | P2 / C18、C26 | PhotoLUTChooser复用RemoteLUTFolderAccess的固定remote_lut_folder_bookmark；PhotoLUTStore自己的folderBookmark只被写入却不用于扫描。选照片LUT目录会改监看目录，重开照片页也跟监看目录走 | iOS两个Store及PhotoLUTChooser完整实现；安卓PhotoLutStore使用photo_lut、监看使用monitor_lut独立偏好，仅协调共享授权。验收：照片A/监看B分别重开/换目录/撤销授权互不覆写，允许主动选同一目录 | 开发侧已核销：照片/监看访问服务书签scope隔离并接生产选择器，f099-folder真实书签专项1/1通过；Provider撤权/扫描失败生命周期另待验 |
| F100 | P2 / C18 | chooser把file.identifier（绝对路径）保存为selectedIdentifier，唯一恢复入口却要求cube:前缀再提digest，永远无法恢复正常所选文件；相机编辑器也未restoreSnapshot。选择名称还被改成LUT摘要，未保原名称 | PhotoLUTChooser.choose、LocalPhotoEffectsView.onAppear、PhotoEffectsSettings.selectFilter；安卓PhotoLutStore保存role的digest/name/uri并懒加载。验收：选择→杀进程→源文件不可枚举但私有快照有效时仍可用，原名称保留；先解决F098再独立验此项 | 开发侧已核销：角色digest/name/source/intensity与私有快照恢复接选择器及两宿主；f100-recipe 11/11、f100-hosts 12/12，实际杀进程/Provider验收仍未执行 |
| F101 | P2 / C18 | 缺完整LutAdjustments模型、四个-100…100/5微调控件与颜色后处理；强度只有全局0…100/1 Slider，不按digest/源URI记忆，实际renderer却归一成2…100偶数，显示0%仍输出2% | iOS PhotoFilterSelection/PhotoLUTStore/PhotoLUTChooser/PhotoCubeLUTMapper；安卓LutAdjustments、PhotoLutEditor、PhotoLutStore、LutColorPipeline及测试。验收：每LUT独立浓度/四项微调、旧URI值迁移、草稿/入队/重试快照及预览导出顺序一致；0用关闭表达 | 开发侧完成：模型/颜色后处理、摘要与角色记忆、基础控件、v3输出身份、旧配方恢复和真实队列重试均有专项证据；输入回调单元验证16/16。未UI/真机手势验收，样式动画排除 |
| F102 | P2 / C18、C26 | 照片LUT扫描/读文件/解析/写快照直接在UI回调同步进行，无10秒截止、单活跃+最新等待队列、取消/代次及加载态；失败静默清files或return，换目录先保存后扫描，失败已丢旧目录。read先整份Data再检查32MiB，scan在全量枚举后只数cube而非全部条目10000上限 | iOS PhotoLUTChooser、RemoteLUTFolderAccess、CubeLUTParser；安卓PhotoLutEditorState/LutIoQueue/LutFolderRepository完整链。验收：慢云Provider、连续换A/B、退出、失败/撤权/子目录不可读、非LUT海量目录及超大未知大小文件；成功前保旧状态，失败分类提示准确 | 开发侧已修复；后台队列/10秒取消、目录事务、错误分类及读取扫描上限最终8/8通过，另有选择取消2/2；未真实云Provider/UI验收 |
| F103 | P2 / C18、C29 | LUT只是一列常驻文件按钮+星+Slider，无关闭选项、分类弹窗/长按选择器、两行重名标签和当前项定位；目录/空态/强度为硬编码中文，空目录和读失败都显示未选择。更换目录/成功扫描发现选中项已删也不清当前选择 | iOS PhotoLUTChooser/PhotoLUTStore/RemoteLUTCatalog；安卓PhotoLutEditor/LutCategoryList/lutFileLabels/PhotoLutEditorState。验收：关闭LUT再选择NP3、同名根/分类、收藏排序、英文/繁中、空/加载/错误/已删来源；目录浏览按文件名排序而不是relativePath优先 | 开发侧功能已修复；名称拨轮/关闭/分类/定位/多语及待加载身份接线，最终6/6通过；UI未验，公共长按细节归F177 |
| F104 | P2 / C18 | Cube映射在强度混合后才clamp，安卓先clamp LUT输出再混合；含负值/>1的合法LUT在中间强度颜色不同。CG premultipliedLast字节又被直接当straight RGB采样，缺去/再预乘，半透明PNG非线性LUT结果错误 | iOS PhotoCubeLUTMapper；安卓PhotoCubeMapper及domainAndExtendedOutputClampBeforeStrengthMixing/alpha测试。验收：Android测试原色0xff804020、LUT(-.5,1.5,.5)、50%应0xff40a050；另测透明/半透明非恒等映射 | 开发侧完成：输出先clamp、字节域强度混合及逐轴插值均对齐；真实RGBA不透明/半透明/透明精确像素测试通过，最终10/10；未真机验收 |
| F105 | P2 / C18、C26 | Cube解析domain未拒绝range溢出或倒数下溢（只测倒数isFinite）；快照恢复更未校验domain/结尾，损坏零域/NaN/尾随数据仍注册到runtime。安卓解析和codec均有完整有限域与EOF检查 | iOS CubeLUTParser.validDomain、PhotoLUTStore.restoreSnapshot；安卓CubeLutParser/PhotoLutSnapshotCodec及brokenSnapshots测试。验收：±3e38域、微小倒数、快照zero/NaN/reversed域/尾字节/截断，拒绝且保旧选择，不进入采样整数转换 | 开发侧完成：文本及快照域有限性/正规range与倒数校验、精确长度已接；真实损坏快照不注册回归通过，最终36/36；不声称曾发生崩溃 |
| F106 | P2 / C18 | PhotoLUTRuntime静态字典永久强持所有选过表，无8MiB/16项资源淘汰与懒加载；快照放caches且无活跃配方持有/清理机制。saveSnapshot先register后写盘，写盘失败又被chooser吞掉仍接受选择，重启丢失已承诺配方 | iOS PhotoLUTRuntime、PhotoLUTStore.saveSnapshot/restoreSnapshot与choose；安卓PhotoCubeResourceCache、PhotoLutStore原子快照/弱owner/prune及cache测试。验收：多65格LUT切换、排队后删/改外部文件、内存淘汰、写盘失败、缓存清理后恢复；不能靠无限内存留表掩盖快照接线 | 开发侧完成：有界LRU/并发合并、持久快照及懒迁移、活跃配方持有与后台清理、写失败保旧均已实现；最终48/48定向回归通过，非真机峰值验收 |
| F107 | P2 / C18 | Cube像素全循环没有取消检查；快速换参数/离页后旧任务仍算完整幅或完整tile，持有全局预览render gate后新画面要等。安卓每4096/16K批次检查取消 | PhotoCubeLUTMapper.apply、LocalPhotoOutput.filteredSource/preview；安卓PhotoCubeMapper.mapRange及PhotoCubeBulkTest。验收：大图过滤中切选/退出，旧循环有界终止且不发布；边框tile之间检查不等于tile内部可取消 | 开发侧完成：4096像素取消/错误传播、演示预览取消桥及活动循环释放gate已验证；最终18/18定向回归通过，未UI手势验收 |
| F108 | P2 / C18 | 普通滤镜分类使用Swift中文preset.name，而安卓按内置英文fallbackName分类；森屿青/暮色余温/蓝调时刻等落入色彩而非风景/电影感。全列表还缺安卓顶部关闭、进入滚动到当前项、320宽与低屏高上限及点击tick | iOS PhotoFilterChooserOverlay/category、PhotoFilterCatalog；安卓PhotoFilterCategory、BuiltInPhotoFilters和SettingsScreen chooser。验收：50项逐分类核对、收藏内顺序、关闭/重新打开当前项、矮横屏和长名；类别中文标题本身安卓也硬编码，不另算翻译漏项 | 开发侧功能完成：50项分类、关闭/收藏/记忆强度/定位已接；最终2/2模型专项及生产编译通过。细样式动画排除，未UI验收 |
| F109 | P2 / C18、C16 | 本地预览先生成filteredSource，再检查完整prefetched成片命中；切到预取滤镜仍重复整次像素计算。安卓将filter计算放在成片cache miss内，相机iOS路径也先查成片缓存 | LocalEffectPreview.task的preparedSource/prefetched顺序；安卓PhotoEffectsRenderedPreview.renderPreview/getOrRender。验收：当前A已预热B→切B，无滤镜重算且立即用成片；源图/框参数变化正常失效，取消预取提升当前不丢帧 | 开发侧完成：本地当前/预取共享三项成片缓存，命中跳过滤镜，需求取消/提升、源图/装饰失效及离页关闭已接；最终10/10定向验证通过，未真机性能验收 |
| F110 | P2 / C18、C14 | 无边框/沉浸等路径对原图仍调用完整CGContext过滤，额外持一幅全尺寸滤镜缓冲；NP3导出也走concurrentPerform，未区分安卓原图单工作线程+约4M scratch与预览最多2worker。带框虽已tile，不能证明所有导出资源有界 | iOS PhotoEffectsRenderer.render/applyFilter、Np3BitmapFilter与PhotoCubeLUTMapper；安卓PhotoFilterRenderer.renderInPlace/prepareOriginalFilter/scratchPixelCount及测试。验收：高像素无框/水印-only/沉浸/带框，两图批次和传输同时进行，验证峰值/取消/原片像素；保留已实现带框tile | 开发侧功能与资源验证已完成：原图单工作线程/分块、预览最多2worker；NP3/Cube接缝、方向/透明、1200万像素四路径双导出与下载并行/取消验证通过。最终并行专项2/2，峰值及限制见2026-10-17验收；未测真机，按开发侧范围核销 |
| F111 | P2 / C19 | 城市/区域只有模型字段，无编辑按钮；renderWithResolvedPlace只有定义，实际相机/本地预览与导出均调用同步render，故有GPS也不会解析地点。缺安卓开关/有效网络/AP禁用/前后重验与预览刷新链；本地规范化又只清坐标海拔，未清城市区域 | PhotoEffectsEditorView:259、Renderer:64、PhotoFramePlaceResolver及所有render调用；安卓SettingsScreen、PhotoFrameLocationResolver、withoutLocationFields。验收：STA有网开城市/区域→预览和成片一致；切AP/断网/关闭字段清旧地点；本地作用域无地点字段；缺字段预览假值不导出 | 开发侧已修复；真实导出像素1/1、发布/持久化/复用4/4、前后门控2/2通过；预览接线源码核对，未调用真实网络服务或UI测试 |
| F112 | P2 / C19 | 未接线的地点helper本身也不完整：显式非CN仍可因汉字走中文规则，区县候选缺开发区/自治/省等排除及直辖市回退；海外把subAdmin当city。缓存无32项/语言/TTL；超时子任务等待非结构化worker.value，group取消不会结束该等待，不能兑现1秒返回，未取消Geocoder | PhotoFramePlace.swift、PhotoFramePlaceResolver.swift全实现；安卓PhotoFrameLocationResolver和PhotoFramePlaceTest。验收：北京/杭州市西湖区/开发区/日本汉字/美国County、语言切换、超过32点、超时/迟到结果/并发与取消；按原平台API实现等价生命周期 | 开发侧已修复：行政层级/缓存/排队超时取消及真实resolver语言隔离10/10通过；未访问真实地理服务，消费者验证仍归F111 |
| F113 | P2 / C19 | 展示仍是度分秒，安卓当前为方向在前的度+小数分；resolved/locationRow及JPEG相机GPS覆盖都要求两轴分别非零，合法赤道/本初子午线被丢弃。地点/坐标合为一行，缺独立地点行及去重 | Renderer.resolved/locationRow、PhotoEffectsJPEGEncoder；安卓formatDegreesMinutesLatitude/Longitude、frameLocationRows、validFrameCoordinates及测试。验收：单轴0/双轴0/±边界/分钟进位、相同城市区域、相机补头GPS写入和源EXIF保留；不把预览假值写入成片 | 开发侧已修复；全模板地点/单零轴独立输出、坐标进位/去重及JPEG GPS读回专项6/6通过；长文本完整性归F116，未UI验收 |
| F114 | P2 / C19 | 宽度/背景模糊/遮罩/Logo样式/城市区域虽写入JSON，启动优先恢复同时写入的旧12字段配置，全部新字段重置；decoder仅支持9/10/12/13，拒绝安卓14/15/16/18字段 | PhotoEffectsStore.init/update、persistAndroidTransfer/LocalSettings、decode/encodeAndroidMetadata:1276–1320；安卓PhotoFrameMetadataSettings codec与roundTrip测试。验收：两个独立作用域、各模板不同新字段保存→销毁store→重建，及各历史格式迁移；不能只测试JSONDecoder | 已修复（开发侧）：新旧兼容codec、所有模板双scope实际持久化、边界/非法输入/独立作用域专项通过；f114-persistence 3/3、f114-boundaries 5/5，未真机杀进程验收 |
| F115 | P2 / C19、C14 | 输出指纹仍编码旧12字段，两个不同的非默认宽度/背景/Logo/地点配置可得到同一身份；缺当前measured-layout/glass-panel/brand-logo/archive等版本标记及地点有效性规则。不同成片会被当相同效果查找/复用 | PhotoEffects.androidMetadataFingerprintToken/androidWatermarkFingerprint及输出名；安卓photoFrameMetadataSettingsFingerprintToken/photoFrameWatermarkFingerprint/shouldReuseExistingFrame。验收：60→200宽度、两种非默认背景、文字→Logo、城市→区域均按有效画面区分；隐藏字段不造重复名 | 已修复（开发侧）：完整字段/隐藏规则/版本摘要/图片hash规范及地点禁复用，最终8/8专项通过，结合6/6配置和5/5版本验证；不代表所有渲染样式验收 |
| F116 | P2 / C19 | 标准四模板/铭牌/参数海报布局忽略widthPercent；其余大多只是固定边距相乘，没有安卓先测全量元数据/水印/Logo再扩画布的统一布局。长内容以整体缩字代替换行、保字号及动态留白 | Renderer.makeLayout/makePreviewLayout、metadataRow.fitting、PhotoFrameTextLayout；安卓calculateMeasuredFrame/calculateMeasuredTemplateFrame及ParameterPosterFrame测量。验收：所有模板60/100/200、横竖/极端比例、全部字段/长镜头名/最大水印；预览与原图同构且照片1:1 | 开发侧功能已修复：全模板测量、独立列、宽度控制、预览同构及溢出规则已补齐；相框专项75/75通过，含180组全字段/最大水印/极端比例组合及原图像素、长文字尾部回归。按当前功能范围核销，详见2026-10-17最终验收；未做UI/真机视觉验收 |
| F117 | P1 / C19 | galleryMat把frameScale乘到整个正方形画布；60%时画布可小于原图，例如1000×500→750×750，photo.x=-125，原片左右直接超出画布被裁切。安卓只缩边距并保证完整照片 | Renderer.makeLayout.galleryMat:301–304；安卓measured模板布局/wholePhoto测试。验收：60/65/100/200横竖和方图带四角标记，源区域必须完整且原图导出不缩像素；预览同样核对 | 已修复待真机：边距缩放/方形扩充及多余照片描边修复；24组原图/预览像素配置和相关回归最终5/5通过。F116完整内容测量仍未完成 |
| F118 | P2 / C19 | 背景0仍固定192缩图并至少radius1；低模糊无384代理/0时高清背景。mask100–200全部相同，0仍保默认遮罩，50反而额外加黑，不是安卓逐层alpha乘百分比。UI所有模板都显示宽度/背景，背景步长5而安卓10，沉浸应隐藏宽度，背景只限支持模板 | Renderer.drawBackdrop/blurredBackground:474/691、Editor:282；安卓drawBackdrop/backdropPreviewLongEdge/normalizeBackdropPercent、SettingsScreen:2612。验收：5个支持模板0/10/50/100/200，其余模板无无效控件，换模板中止旧手势；宽度步长5本身正确 | 已修复（开发侧功能）：控件模板/步进/模板id、零低模糊代理、遮罩与影院合成、极端比例保护，最终8/8像素/预算专项及6/6控件模型通过；UI测试按用户要求跳过，真机峰值归F110 |
| F119 | P2 / C19 | Logo样式仅brandInset/brandGallery消费，标准、铭牌、沉浸、编辑模板和参数海报仍纯文字；缺品牌可由model识别后参与统一测量的完整presentation。UI用额外Logo拨轮，缺安卓同按钮关闭→文字→Logo→关闭循环 | Renderer中brandStyle仅两处、drawBrandInsetMetadata/drawBrandGalleryBand；安卓FrameBrandLogo/useBrandLogo及各模板绘制、nextBrandStyle测试。验收：17支持品牌/不支持品牌/缺Make/隐藏品牌，所有模板三态，长型号与水印避让 | 功能开发侧已闭环：15模板×17支持品牌及不支持品牌×4显隐/样式状态，1080次真实导出通过；三态控件、统一品牌推断、长型号与水印避让证据已核对。精细样式及真机/UI验收未包含；见2026-10-17完成记录。 |
| F120 | P2 / C19 | 参数海报在固定栏中逐字删尾至能放下，未换行或扩栏；identity已含型号还单列型号，地点也拼接已含地点的locationRow而重复。安卓用独立身份/参数/地点组一次测量后绘制，保完整描述 | Renderer.drawParameterPoster:1319；安卓ParameterPosterFrame.posterGroups/measurePosterRows/drawPosterRows及测试。验收：长品牌/型号/镜头、全部地点字段/相同city-region、横竖照片和60/200宽度；文字内容不得静默丢尾/重复 | 开发侧已修复：独立分组一次测量、长描述换行/完整曝光扩栏、原图保真和预览复用；联合横竖60/200长身份/全部地点/同名去重及边界专项通过，证据见2026-10-16 F120核销记录；细样式延期、未UI/真机验证 |
| F121 | P2 / C19 | filmNegative未绘制开启的镜头/曝光/日期/地点信息；稳定帧号用UTF8 FNV而安卓Java hashCode，filmEdge还写死“20”。底片分隔线/标签锚点与墨色沿用旧比例，缺当前测量后的元数据行 | Renderer.drawFilmNegative/stableFilmFrameNumber及filmEdge；安卓drawFilmNegativeFrame/drawFilmEdgeFrame、calculateMeasuredTemplateFrame。验收：同metadata两端帧号一致、切每字段、长文本/非ASCII与缺信息、最窄边框；核参数与像素 | 开发侧功能已修复：底片元数据、Java UTF16稳定帧号与filmEdge三位帧号、身份分隔符；十字段显隐和最窄宽度长中文Emoji/缺信息成片及预览专项通过。细样式延期，未UI/真机验证；证据见2026-10-16核销记录 |
| F122 | P2 / C19 | 照片内文字水印直接用完整排版尺寸，无安卓maxWidth安全区缩放，24个宽字符+300%可出照片被clip；阴影固定3/1/黑35%而安卓随字号和文字颜色/透明度变化，部分边框文字路径忽略outline，AUTO也非统一按照片位置解析 | Renderer.drawWatermark/drawAndroidMetadata/drawMetadataRows；安卓drawPhotoWatermark/drawWatermarkText/resolvedWatermarkEffect。验收：所有位置/字体/1–300%/1–100%/明暗色与四effect，文字墨迹在4%安全区，带框/无框及预览原图一致 | 开发侧功能已修复：限宽与墨迹定位、两条路径效果/透明度、AUTO解析和沉浸混排效果；分层专项与240带框组合通过。4%区按安卓超宽墨迹居中回退规则验收，精细样式延期，未UI/真机验证；证据见2026-10-17核销记录 |
| F123 | P2 / C19 | 已入队图片水印的私有素材缺失/损坏时，drawWatermark读取失败后继续绘制displayText，静默把图片任务变成文字成功；安卓requirePrivateCopy/解码失败应使该派生失败 | Renderer.drawWatermark:1546后fallthrough；PhotoEffectsStore.watermarkImage；安卓PhotoFrameWatermarkStore及decodeWatermarkImage。验收：冻结有效图片任务后删除/损坏私有文件，生成明确失败且原片保留，恢复素材后重试沿原快照 | 开发侧已修复：图片引用/加载失败明确抛错，不降级文字；15模板与无框专项、真实队列删除/损坏/原片保留/恢复冻结素材重试及退款回归通过。原片completed与派生frameError独立，证据见2026-10-17核销记录；未UI/真机验证 |
| F124 | P2 / C19、C14 | 原尺寸解码/扩展画布创建前无对应安卓PhotoAllocationBudget的尺寸溢出/总分配预算与可处理失败门控；tile仅限制滤镜临时缓冲，无法限制200%长文本扩框后的输出画布 | Renderer.render/renderOriginalFrameByTiles与UIGraphicsImageRenderer入口；安卓ensurePhotoAllocation在decode/renderOriginalFrameByRegions及PhotoAllocationBudgetTest。验收：极大尺寸/框宽和同时任务在分配前有界拒绝并归入失败，正常原图保持像素；按iOS可用内存语义实现 | 开发侧预算功能已修复：解码前文件头门控、溢出与64MiB余量、测量后画布预算、双生产入口拒绝恢复、1200万像素与队列冻结重试专项通过。按安卓为快照检查非预留；真机峰值/压力归F110，证据见2026-10-17核销记录 |
| F125 | P1 / C20 | 点裁切立即开sheet，64KiB原图头未返回/失败也能完成；缺头就用FHD/缩略图尺寸和8×8 MCU创建任务，真实下载后尺寸校验才失败。未等待现有FHD、未复用EXIF缓存、没有400ms准备提示/失败分类/重试与取消所有权；已写好的CropPreparationState无生产调用 | PhotoPreviewView:502–565；安卓PhotoPreview裁切LaunchedEffect及CameraViewModel.prepareCrop。验收：先缩略图后FHD、慢头/截断/断连/取消/重开，只有合法准备结果可确认；用方向信息和归一化选择延后到真实原图解析，不能猜原图尺寸 | Developer-side fixed: FHD waiting and independent retry, direction cache/bounded busy retry, 400ms preparation feedback, cancellation and generation ownership, deferred original geometry resolution. Final 17 tests passed with earlier protocol/queue evidence; all failures retry per current Android. No UI/device validation; gestures/ratios remain separate. See 2026-10-17 completion and correction record. |
| F126 | P1 / C20 | 确认时用手动rotation替换原始EXIF方向；sheet图像未套该rotation，也未调用CropPreview的黑边/规范方向/反变换。常见EXIF6照片不旋转时recipe.orientation=1，生成必因实际方向6拒绝；手动转到6又不能证明选区对应真实像素，镜像方向未明确拒绝 | PhotoPreviewView.cropSelection/source、PhotoCropEditor及CropPreview无生产构造；安卓prepareCropPreview/canonicalSelection、canonicalRotation和placement等待。验收：EXIF1/3/6/8、相机已旋转FHD/左右黑边/手动旋转、镜像2/4/5/7；四角标记选区与输出一致 | 开发侧已修复：规范方向/去黑边编辑图像及保留原EXIF的选择已接生产；6种预览组合×4象限真实JPEG无损裁切验证通过，方向变更拒绝与恢复、镜像规范方向拒绝回归通过。未UI/真机验证，触摸与比例问题保留F127/F128，证据见2026-10-17核销记录 |
| F127 | P2 / C20 | 比例在0…1归一化方形上算，未乘图片实际宽高，1:1框在3:2图片上不是正方形；导出再次按ratio裁切导致看到与保存不同。每次从上次选区内继续缩，横竖比例来回切越来越小；原比例直接存FHD宽高而安卓原比例延后采用原图；小图/高倍率可触发align中count>0的precondition，try?接不住 | CropGestureState.setRatio/zoom、PhotoCropEditor、JpegCropSource.align；安卓CropEditorGeometry稳定ratioReference、源像素最小单位及selection。验收：所有比例×横竖图、往返20次不缩小、奇数原图/非整数FHD、最小图强缩放可处理拒绝而非崩溃 | Developer-side fixed: production pixel geometry, stable ratio reference, original 0/0, flip/reset, pixel zoom limits and recoverable errors. Final 18 tests passed including 24 native crops. UI/device not tested; touch completeness remains F128. See 2026-10-17 completion record. |
| F128 | P2 / C20 | 手势只移动/缩小白框，照片本身不变；缺安卓四角28dp命中/48dp最小框、双指质心变换照片、32倍与像素边界、二指接管角拖和手势finally复位。白框按整个GeometryReader画，图片却aspectFit，letterbox区域也算选区；没有画面外58%遮罩/交互中三分线/四角标记 | PhotoCropEditor/CropOverlay完整实现；安卓CropEditor/CropEditorGeometry。验收：宽图置竖屏、角拖/中间拖/捏合/中断/转屏，选区始终对应图片且不越界；控制框与实际裁切像素一致 | Functional developer-side fixed: shared pixel geometry for image/frame/selection; corner vs multipointer transform ownership and cancellation/resize resets connected. Final 6 model tests passed with prior native crop evidence. No UI/device touch validation; mask/grid/corner styling explicitly deferred, viewport return remains F129. See 2026-10-17 record. |
| F129 | P2 / C20、C29 | 裁切新增独立sheet/NavigationStack，而安卓在原预览内编辑；缺220ms布局/180ms工具、进入收回缩放和取消恢复/600ms兜底、方向修正240ms与真实placement门控、裁切片段飞行及固定加号→确认槽。比例放顶部且无选中态/160ms颜色；取消/完成/自由/原比例硬编码中文，无tick | PhotoPreviewView.sheet、PhotoCropEditor；CropAnimationTiming仅定义和测试、无生产调用；安卓PhotoPreview/CropEditor。验收：进入中取消/快速重入/旋转、原缩放恢复、三语/两主题/底部安全区、确认飞行来源与遮罩 | Functional developer-side fixed: initial zoom/pan handoff and return-state preservation, equivalent-angle handling, input/callback retirement, localized controls and haptics. Final 19 business/model tests passed; no UI/device validation. Basic sheet retained under current scope; precise layout/animation/flight/theme styling explicitly deferred. See 2026-10-17 record. |
| F130 | P2 / C20 | 完成按钮不要求有实际裁切、准备成功或非confirming；回调是Void，先写全局store然后无条件关闭。宿主无目录/断线直接return，用户草稿消失但未入队，无安卓accepted=false保持编辑和提醒；未沿用已有本地原片离线准入 | PhotoPreviewView:558–565、PhotoListView:887–894；安卓hasCrop/cropConfirming/startPreviewQueueFlight及onCropTransfer。验收：完整图无改动禁确认、无目录/离线有无原片/队列拒绝均有一致反馈；只有实际接纳才收起且每次仅入一次 | Developer-side fixed: actual-crop/prepared/confirming gates, immutable selection handoff, real enqueue acknowledgement, duplicate suppression and rejected-draft retention. Current Android requires connection for preview crop; directory absence exits preview for setup. Final 9 tests and prior 16-test suite passed. UI/device not run; see 2026-10-17 correction/completion record. |
| F131 | P2 / C20 | 处理器源/结果只解析64KiB且先映射/读取整个压缩文件，安卓用有界2MiB前缀；多个ICC/大EXIF令SOF/SOS在64KiB后时合法JPEG被拒。Swift解析器仅验证max采样，任一component含0仍可通过，安卓逐个拒绝 | LosslessCropProcessor.process、parseJpegCropHeader；安卓LosslessJpeg.readSource/JpegCropHeader。验收：SOF/SOS在64KiB/2MiB边界、大ICC、0/5采样、截断segment/坏EXIF；真正不支持应失败，不回退预览几何 | 已修复待真机：处理器/桥接2MiB有界读头、逐分量1…4采样及安卓截断前缀规则；真实大ICC、64KiB/2MiB边界、损坏EXIF和回归13/13通过。预览准备入口仍归F125 |
| F132 | P1 / C20 | libjpeg只替换fatal error_exit，未将warning视为失败，截断熵数据可由解码器补齐继续生成；fclose返回也未检查。Swift结果只查非空和前缀尺寸，不足以阻止尾部写失败的半JPEG被发布。安卓STOPONWARNING并检查写入长度/close失败后删除 | LosslessJpegBridge.c、LosslessCropProcessor.process；安卓jpeg_crop.cpp/LosslessCropInstrumentation截断用例。验收：SOF/SOS合法但熵数据截断、磁盘满/close失败，必须失败并清临时输出，原片保留；恢复后可重试 | 已修复待真机：warning即失败、统一资源清理及写入/刷新/关闭校验；iOS有效头截断/非零起点重试2/2通过，原生ENOSPC/EIO故障注入及ASan/UBSan通过。F133/F134独立保留 |
| F133 | P2 / C20 | 桥接原样保留APP1，包括原片EXIF缩略图，裁切输出可能仍带未裁切内容；安卓只保ICC并重建选定EXIF、明确去旧缩略图。嵌套PixelX/Y更新还依赖Exif恰为首个保存marker，APP2先于APP1时transupp跳过且自写helper只遍历IFD0 | LosslessJpegBridge.update_exif_dimensions/marker循环；libjpeg src/transupp.c:2258；安卓jpeg_crop.cpp SAVEMARKERS=4与LosslessJpeg复制/重写。验收：带嵌入缩略图、ICC在前、大小端/SHORT/LONG，输出无旧缩略图且全部尺寸/原方向/GPS正确 | 已修复待真机：ICC-only原生保留+安卓35字段EXIF重建，无旧缩略图；大小端/SHORT与LONG/8方向/矩形四尺寸32组合、压缩数据不变、越界拒绝与相关回归最终7/7通过。F135资源边界仍独立未完成 |
| F134 | P2 / C20 | staging文件名是字面“.nkcrop_(UUID().uuidString).part”，没有真实UUID/进程会话隔离；启动目录清扫不识别nkcrop。处理器无取消检查，detached调用也不传取消，可能在取消后继续发布，且旧进程半成品留在目录；安卓独立session/task暂存、前后检查取消、旧会话清理及发布交界记录 | LosslessCropProcessor、TransferDirectoryIndex.cleanupTemporaryFiles、TransferQueue裁切调用；安卓generateCrop/CropSourceAccess/CropOutputPublisher。验收：裁切前/中/发布边界取消、杀进程重启、同目录多任务/新旧会话，已发布输出只复用一次，未发布清理且不误删活跃文件 | 开发侧已修复待运行验收：会话/任务独有暂存、父取消透传、发布前检查及发布后先记账、旧会话清理，21/21通过。真实杀进程重启/真机仍待验证；F061其他临时文件清理独立未修复 |
| F135 | P2 / C20 | native系数处理缺安卓256MiB压缩源/1亿像素/192MiB codec预算与串行gate；Swift先整源Data且在native读取系数前不设相应上限。巨图/大文件缺明确可处理拒绝边界 | LosslessCropProcessor、LosslessJpegBridge.c；安卓LosslessJpeg.gate及jpeg_crop.cpp三种限制。验收：阈值内外、极端SOF、并行调用/取消，不创建RGB副本，失败保原片；平台内存预算可等价实现但不能无界 | 已修复待真机：256MiB/1亿像素/192MiB预算、2MiB有界读头及独立可取消串行准入；原生ASan/UBSan PASS，iOS25/25及补强并发3/3通过。真机RSS/内存压力未测，F065/F072保持独立 |
| F136 | P2 / C21、C22 | USB取帧循环虽计算成功8帧才stable，acceptDecodedFrame随后调用reducer.frameReceived却无条件置stable=true；第一幅解码帧就提前放行事件/电量/有效ISO等依赖稳定态的轮询，后续帧又在两处来回写false/true。安卓首帧可显示和开始用量，但稳定门槛独立保持8帧 | RemoteViewModel.start/acceptDecodedFrame、RemoteState.applying(frameReceived)；安卓RemoteScreen.startSession的USB_LIVE_VIEW_STABLE_FRAMES。验收：USB第1帧成功后阻塞第2至第8帧，画面可显示但后台参数/事件不提前读；Busy不计成功帧，Wi-Fi不受8帧门槛 | Developer-side closed: first image preserves acquisition stability; USB 1/7/8-frame + Busy, polling/auto ISO and WiFi lifecycle checks passed 2/2. No UI/device validation. |
| F137 | P2 / C21 | 退出stop不取消movieFormatTask的10秒sleep，stopAndWait却await该任务后才释放remote gate/恢复照片列表；视频模式在一次格式轮询后立即返回，可空等近10秒。displayDetails及重启退避也有非协议等待尾巴。安卓页面取消会立即结束这些可取消延时，只等待必要的协议/录制清理 | RemoteViewModel.setMovieFormatMonitoring/stop/performStopAndWait、RemoteView.onDisappear及RootView.onStopped；安卓LaunchedEffect取消/finally。验收：10秒格式等待刚开始时退出，立即结束纯计时等待但实际在途PTP正常排空，列表恢复不受剩余计时拖延；试用结束同时退出只清理一次 | Developer-side closed: cancellable idle timers preserve wire drain; obsolete poll cleanup cannot clear replacement task. Final 5/5 passed, including concurrent trial/page exit. Initial 1/3 failure and correction recorded below. No UI/device validation. |
| F138 | P2 / C21、C22 | HD切换及普通LiveView重启只重置decoder/generation/state，旧frameImage/frameData仍显示到新帧；安卓普通会话切换立即清旧图，只有录像兼容恢复显式preserveFrameUntilNext才保图。失败重启期间可能持续展示上一配置的旧画面 | RemoteViewModel.setHDLiveView/start循环、RemoteFrameDecodePipeline.reset；安卓RemoteScreen.startSession(preserveFrameUntilNext)。验收：HD切换/普通错误重启阻塞新帧时清旧图，录像兼容重启按独立例外保持，旧解码不能反灌新代 | Developer-side closed with Android scope correction: HD clears; inner acquisition retry, computer control and movie compatibility retain. 4/4 plus final 2/2 passed; see evidence below. |
| F139 | P2 / C22 | 停止相机录像若抛出未触发全局断连的异常，toggleRecording通用catch仍调用releaseMovieSessionToStandby，提前清应用/控制模式；安卓停止失败保留recording和模式，等完成事件纠正。负响应分支虽正确，不能代表异常分支正确 | RemoteViewModel.toggleRecording catch；安卓RemoteScreen.toggleRecord停止失败分支。验收：在有ApplicationMode及USB控制时分别注入EndMovie负响应、普通异常、断连，前两类保留状态并允许重试，断连走全局清理 | Developer-side closed: failed stop preserves recording/modes; transport loss returns to global cleanup. USB negative/exception retry, timeout and WiFi regression passed 3/3. No UI/device validation. |
| F140 | P2 / C22 | USB准备录像把ApplicationMode成功标记先存局部变量，整段命令序列成功后才写回actor；已成功启用后下一条读取/启动异常会丢记账，clearMovieApplicationMode(force:true)仍只清已记账的模式。安卓每次启用成功立即记录 | CameraRepository.startPreparedUSBMovieRecording/clearMovieApplicationMode；安卓prepareAndStartMovieLocked。验收：操作码/属性启用成功后，下一条命令异常或取消，确认清理不漏已发生的副作用；运输失效时还须遵守连接关闭规则 | Developer-side closed: acknowledged application side effects recorded before next command; 4/4 wire tests passed, including six failure combinations and invalidated-session cleanup suppression. No real USB cancellation-race validation. |
| F141 | P2 / C22、C24 | 本地录制未接反挤压倍率，输出宽度只用原帧宽；固定canvas直接拉伸每张后续帧，HD或画幅变化会变形。麦克风授权前捕获旧image尺寸，授权后未重取当前帧。安卓按开录时当前尺寸×倍率定canvas，并按每帧倍率适配留黑边 | RemoteViewfinderRecorder.init/makePixelBuffer、RemoteViewModel.startLocalRecording；安卓ViewfinderRecorder.start/argbToYuv420及RemoteScreen.startRecorderResolved。验收：1.33/2倍、录制中改变倍率/HD/画幅、等待权限期间变帧，导出宽高比及构图一致 | Developer-side closed: current-frame permission admission, initial and per-frame desqueeze, fixed-canvas aspect fit; final 6/6 passed including within-file encoded pixel checks. No UI/device validation. |
| F142 | P2 / C22 | writer失败、像素缓冲分配失败或append返回false被静默丢弃，没有安卓连续30次真实编码失败自动停止保存的路径；UI仍保持录制/计时直到手动停止。stop的finishWriting等待也无应用侧截止策略 | RemoteMovieRecording.drainLatestVideoFrame/appendAudio/stop；安卓RemoteScreen录制循环、ViewfinderRecorder.stop。验收：区分繁忙跳帧与编码失败，故障计数/恢复/自动收尾/保存失败反馈；原有界收尾要求经2026-10-17用户明确接受平台差异后豁免 | 功能范围已核销：连续30次编码失败自动收尾、恢复重置及坏帧保存已有片段已验证；真实writer取消状态注入与清理最终4/4通过（首轮错类0项，不计证据）。writer非writing时停止不再调用finishWriting。生产自动停录/失败反馈及旧回调隔离2/2通过；append拒绝/繁忙注入3/3通过。用户明确选择“保留无总期限，接受平台差异”，因此保留finishWriting无总截止，不声称等待有界。 |
| F143 | P2 / C22 | 每次append先向串行队列提交一个持有UIImage的block，block内才更新newestPendingFrame并同步drain，其他block无法在drain期间替换它；所谓latest槽不能限制队列积压。编码慢时每帧仍排队，暂停/停止排在积压后；音频也逐块入同队列 | RemoteViewfinderRecorder.append/drainLatestVideoFrame/captureOutput；安卓单录制worker只观察最新frame。验收：人为慢编码持续输入，待处理帧数有界、旧帧被替换，暂停/停止不需逐帧消耗旧队列 | Developer-side closed: bounded producer-side video/audio admission; blocked-worker retained-buffer checks and continuous-producer pause/resume/stop passed. Final14/14. No device memory profiling; F142 finish deadline separate. |
| F144 | P2 / C22 | 录制PTS基准到第一张可写视频帧才建立，但此前暂停仍累计pausedDuration；首帧前暂停再恢复会重复减掉基准之前的暂停，后续PTS被压到0附近；首帧前音频也被直接丢弃。安卓开录即建立共用时钟基准 | RemoteMovieRecording.start/pause/resume/drainLatestVideoFrame/appendAudio；安卓ViewfinderRecorder.baseTimeNs/computeVideoPts/computeAudioPts。验收：阻塞首个append→暂停1秒→恢复，验证音视频PTS、实际时长及UI时间，使用同一单调时钟 | Developer-side closed: start epoch/shared pause clock, first-video pause and pre-video audio export verified; PCM silence bridges AAC-compacted active gaps. Final10/10 passed. No physical microphone/UI validation. |
| F145 | P1 / C22、C13 | 本地录制名精确到秒，start无条件removeItem(outputURL)；用户目标目录已有同名文件或同秒第二次开录时，会先删除旧录制，哪怕新writer随后失败。安卓普通SAF目录通过createDocument创建，名称冲突交Provider处理；不把安卓私有fallback也宣称绝无同名风险 | RemoteViewfinderRecorder.outputURL/start；安卓RemoteScreen.startRecorderResolved。验收：预置同名MP4、同秒连续启动、创建失败回退，旧文件保持且新文件有独立名称 | 已修复待真机：独有暂存目录、完成封装后共享名称预留发布；真实旧MP4/同名双录制/失败清理/生产目录回退最终6/6通过。其他录制缺口独立保留 |
| F146 | P2 / C22、C25 | 退出监看后本地MP4保存失败仍调用页面内提示，但stopRequested门控丢弃提示，无跨页面宿主；安卓退出后改用Toast告知失败，用户不会误以为已保存 | RemoteViewModel.stopLocalRecording/showMonitorHint、RootView.onStopped；安卓RemoteScreen.stopRecorder。验收：停止/退出立即触发延迟保存失败，回到列表仍收到一次失败提示，成功不重复弹窗 | Developer-side closed: departed-host save failure delivered once by root; active failure remains inline, success silent. Final2/2 production/notice tests passed. No UI/device validation. |
| F147 | P2 / C23 | 相机工具写入在await beforeWrite结束追踪后未重验active/isCurrent/canWrite/movie，也未检查取消，直接进入不可取消写入；退出/换模式/关菜单发生在这次await期间仍可能写旧选择。安卓在beforeWrite后再次检查当前相机/可写/模式并ensureActive，再进入NonCancellable | RemoteCameraToolController.select、RemoteViewModel.openCameraTool.beforeWrite；安卓RemoteCameraToolPanel。验收：阻塞EndTracking，分别退页、关菜单、改模式、撤销写权限后放行，尚未发出的属性写入不得开始；已发出的写入仍须排空 | Developer-side closed: post-beforeWrite ownership/mode/permission/cancellation gate; five suspended changes block unsent writes, existing write drains. Final3/3 passed. No UI/device validation. |
| F148 | P2 / C23 | DevicePropDesc只保留二值Range，其余Range被丢弃；安卓对照片快门D100及标准曝光时间500D按min/max/step展开最多约256档。只提供Range的机身在iOS被当成无值域，只能显示、无法用拨轮或全表调整；枚举超过256项还整份拒绝，安卓枚举路径无该截断 | RemotePropertyCodec.parseDescription、CameraRepository.remoteProperty；安卓RemoteLab.parsePropDescData/shutterRangeValues/rcGetParam。验收：D100/500D合法Range、超256档Range有界采样、普通非快门Range保持不展开、合法长枚举不整份变不可用 | Developer-side closed: D100/500D bounded step-aligned Range expansion; long enums accepted, malformed payloads rejected.7/7 plus final boundary1/1 passed. No UI/device validation. |
| F149 | P2 / C24 | 焦框过期只在View重新计算时检查age≥500ms，没有安卓独立过期任务，停帧且无其他发布时旧框不按时消失；501C/D05D/D1F8属性事件、工具写入完成、LiveView重启未统一推进focusValidAfter。只监听movieMode和focusMode.current，旧区域框或同raw不同属性的模式变化可能继续显示 | RemoteView.focusDisplayState/onChange、RemoteViewModel.handlePropertyChanged/openCameraTool/start；安卓ViewfinderImage.expiredFrameAt、RemoteScreen.focusValidAfter。验收：最后帧后静默500ms、区域事件/写入后阻塞新帧、模式编码切换、兼容保图重启，旧框失效且新帧恢复 | Developer-side closed: independent expiry, event/tool/session cutoff and semantic mode transitions verified; whiteBalance/equivalent-label exceptions preserved. No UI/device tests. |
| F150 | P2 / C24 | 成功交接只让相机框等120ms显示，独立RemoteFocusReticle仍持续到phase变idle，未同步淡出触点框，产生双框；IOSConfirmedFocusReticle又在相机框为空时从selected/cached框绘制追踪标记，绕过过期/工具关闭的相机框门控。Android单一状态统一相机框和触点框，追踪成功后的fallback不走普通3秒标记 | RemoteView.remoteViewfinder、IOSLiveViewFocusFramesOverlay、IOSConfirmedFocusReticle；安卓FocusReticleOverlay/ViewfinderImage。验收：成功后120ms交接、新请求中断、镜头遮挡/断帧、焦框工具关闭、追踪取消，分别断言层可见性，无陈旧追踪框复活 | Developer-side closed: shared handoff and visibility, ordinary-only expiring fallback; model/lifecycle tests passed, SwiftUI wiring statically reviewed and compiled. UI/animation/device validation excluded. |
| F151 | P2 / C24 | 焦框仍用旧视觉：触点half32/入场1.45/蓝色focusing/结果0.9及系统spring；安卓half22/入场1.12/白色focusing、180ms FastOutSlowIn/150ms颜色/160ms淡显。相机框角长10且无弧角，所有框缺zoom反比例线宽/角长，8倍缩放会粗大；lastFocused只在几何变化时更新，同框合焦状态改变可能不变绿 | RemoteFocusReticle、IOSLiveViewFocusFramesOverlay、focusCornerPath；安卓FocusReticleOverlay的统一Canvas与zoom参数。验收：1/2/8倍逐帧比对、边缘触点不随收缩漂移、同几何focused翻转、失败退出保色、连续点按中断 | 功能范围开发侧已核销：焦框几何与合焦结果合并快照，修复同几何状态变化及空帧同时变未合焦时的结果保留；生产组件实际渲染专项1/1通过。尺寸、线宽、缩放及动画按用户范围延期，未做真机或UI手势验收。 |
| F152 | P2 / C24 | 正常有图的取景器缺安卓图像空间的暗角层：0.72透明→边缘黑30%、半对角线半径。iOS仅画在照片后面的固定半径背景RadialGradient，不能作用于照片，亦不会随图像缩放 | RemoteView.remoteViewfinder；安卓ViewfinderImage.drawWithCache radialGradient。验收：纯色帧在横竖、反挤压和缩放下比较四周渐晕且不影响焦框/仪表 | Pure visual vignette deferred by user scope; not implemented or counted as fixed. |
| F153 | P2 / C25 | 伪色/亮度波形使用54/183/19亮度权重，安卓这两种分析明确为77/150/29；纯彩色帧进入错误伪色区间/波形高度 | RemoteExposureAnalysis.luma与安卓monitorLuma；验收用红绿蓝和阈值两侧的生产帧。直方图/斑马本来使用54/183/19，不可一并误改 | Developer-side closed: Android77/150/29 monitor luma; colored thresholds and production decode/analysis7/7 passed. Histogram/zebra weights unchanged. No UI/device validation. |
| F154 | P2 / C25 | 监看分析每路独立转换整帧RGBA，伪色/波形没有安卓共用256×192上限；直方图把二维采样步长用于一维stride，实际样本远超约24000目标。斑马的ceil步长中心亦不同于安卓缩放后取样 | RemoteFrameParser.decode/rgbaPixels/histogramBins/waveformBins/falseColorPixels/zebraMask；安卓RemoteExposureAnalysis与ViewfinderFeatures。验收1080p/非整除尺寸，比较采样位置/样本数和分配次数；本轮未实测性能 | Developer-side closed: shared bounded monitor sampling, two-axis histogram and scaled zebra; production spatial/sample-count tests passed. Allocation structure audited statically; no device RSS/performance claim. |
| F155 | P2 / C25 | 斑马刷新250ms而安卓50ms；RGB直方图每帧重新算，未与亮度直方图共用250ms节流。波形125ms周期本身已接 | RemoteFrameParser.drain/decode；安卓RemoteScreen帧解码和MonitorExposurePerformanceInstrumentation。验收固定时间序列内RGB/亮度切换及斑马逐帧变化，核算次数与展示 | Developer-side closed: shared250ms luma/RGB and50ms zebra; exact clock boundaries and mode toggles passed. F157 cache identity remains separate. |
| F156 | P2 / C25 | 页面从偏好恢复分析模式后仅onChange调用setFrameAnalysis，首次task不下发；VM重启只保存histogram/zebra，重新setAnalysis默认关掉waveform/falseColor/RGB。旧开关显示开启但无数据或重启后效果消失 | RemoteView初始化/task/onChange；RemoteViewModel.start帧循环/setFrameAnalysis。验收带已存模式首次进入、HD切换、错误恢复和录像重启，不靠再次点开关恢复 | Developer-side closed: full initial/restart selection; persisted preferences, HD, error and recording compatibility recovery verified on new frames. Final2/2 passed; no UI tests. |
| F157 | P2 / C25 | 分析选项没有独立代次：切换RGB波形清缓存后，旧模式在途解码仍可写回并发布；reset仅换frame generation不清统计缓存/时间，尺寸变化也不强制刷新 | RemoteFrameDecodePipeline.setAnalysis/reset/drain；安卓缓存含模式/尺寸身份。验收阻塞旧解码后切模式/尺寸/重启，释放旧回调，不得显示错误模式或旧会话缓存 | Developer-side closed: config/session/size cache identity and publication permit; held pipeline multi-switch/reset and cache/cadence tests3/3 passed. No UI/device tests. |
| F158 | P2 / C25 | 曝光尺只各探测D10A/D1B1一次，缺D10A三次700ms重试；不按初载/LV稳定/前台/模式重建，忙门控遗漏半按/点按/参数/AutoISO写入，却暂停整个稳定录像阶段。生产读值经通用解析，未消费严格单字节decode | RemoteViewModel.setExposureMeterVisible；安卓RemoteScreen测光effect及rcReadExposureMeter。验收首帧前、首次暂不可用、稳定录像、写入期间与多字节错误响应；只读能力不能触发控制模式修改 | Developer-side closed: strict wire decode, retry/fallback, readiness/lifecycle and busy gates; production protocol/model tests passed, final2/2. F159 late-result/expiry separate. |
| F159 | P2 / C25 | 曝光尺await后未重验代次/取消/忙状态，关闭后迟到读值仍能发布；缺3秒过期及失败终止清理，旧值可无限保留。使用墙钟判断1500ms延迟，亦不同于安卓单调时钟 | RemoteViewModel.setExposureMeterVisible；安卓meterGeneration/finally/独立3000ms过期effect。验收成功→三次失败、关开跨代次、慢响应、失连及系统时间变化 | Developer-side closed: late-result gates, monotonic freshness, independent expiry/busy extension and terminal cleanup; final3/3 lifecycle race tests passed. No UI/device tests. |
| F160 | P2 / C25 | 曝光尺实际UI只有左上数值胶囊；缺右上22×120竖尺、-3到3刻度、160ms指针、零点颜色/超界箭头及无值保留刻度 | RemoteView.remoteViewfinder；安卓ExposureMeterOverlay及固定仪表栈。验收首值/恢复不从伪零扫动、越界/失效、横竖照片录像及音量表共存 | 功能范围开发侧已核销：无值保留刻度、零点反馈及正负越界指针已通过生产组件实际绘制验证；读数边界和横竖仪表布局通过，合计7/7专项。完整真机画面/VoiceOver未验；指针动画与精细样式延期。 |
| F161 | P2 / C25 | 统计图固定150×72左右两角，缺安卓双槽自适应、音量避让、波形300ms换槽、180/130淡入退场和180ms模式交叉；缺标签/轴网格及直方图轮廓填充。波形用每帧峰值线性归一化，未消费固定对数密度，导致强度随帧峰值改变 | RemoteHistogramOverlay/RemoteWaveformOverlay及宿主；安卓RemoteMonitorScopes。验收单/双图/音量、短屏横竖、空帧退场、RGB模式与同密度不同峰值帧 | 功能范围开发侧已核销：固定密度/RGB、标签网格、等宽双槽、音量留位及CAMERA信息栏预留已接生产组件；实际绘制48组合专项1/1通过，相关计算/布局12/12通过。完整实机画面未验；填充样式、转场动画与精细布局延期。 |
| F162 | P2 / C25 | 伪色图用原图aspectRatio fit放入已反挤压的图像容器，不随画面FillBounds拉伸，开启反挤压时伪色区域与底图几何不一致 | RemoteFalseColorOverlay及RemoteViewfinderImage宿主；安卓ViewfinderImage伪色drawImage。验收带边缘色块的1×/1.33×/2×反挤压与缩放 | 已闭环（功能范围）：伪色填充反挤压显示矩形，与底图共用缩放容器；真实组件色块渲染覆盖1×/1.33×/2×、横竖容器、缩放和平移共12组合，边界误差不超过2像素。falsecolor-geometry专项2/2通过；不含手势自动化或精细样式验收。 |
| F163 | P2 / C25 | 音量表按segment≤peak整片点亮，零值也亮底格；未按当前值条带加单个peak线绘制，缺L/R及80/90ms动画。固定32×116左下还会盖住直方图，横屏未移至右侧仪表栈 | IOSSoundMeter及宿主；安卓StereoSoundMeter。验收0、current低于/高于peak、双声道差异、照片录像切换与双统计图布局 | 功能范围开发侧已核销：实际音量组件验证静音、左右声道独立及单个峰值；计算与横竖布局专项合计7/7通过，统计图留位另有48组合绘制证据。无真机/UI手势验收；80/90ms动画和精细样式延期。 |
| F164 | P2 / C25 | DISP白平衡一次scalar返回nil后丢掉原descriptor且不再重探，后续循环永久无I/O；WB/录像规格await后未验当前代次/显隐，迟到结果可回填。录像规格旧任务退出无身份校验清空新task句柄 | RemoteViewModel.setDisplayDetailsMonitoring/refreshMovieFormat/setMovieFormatMonitoring；安卓保存descriptor并refresh及LaunchedEffect生命周期。验收短暂nil后恢复、关开/模式切换时阻塞旧回读，不能被旧结果或旧清理覆盖 | 已修复，开发侧专项验证通过；见2026-10-17 F164记录，未运行UI/真机测试 |
| F165 | P1 / C26 | 监看LUT生产入口从未调用environment；available始终false，文件选择在beginSelection直接返回，GPU路径不可达。已存目录/照片录像选项也未从页面恢复 | 全部RemoteView的lutMonitor调用与RemoteLUTMonitorState；安卓frameReady/visible/movie effect。验收真实RemoteView选目录→点文件→显示结果，再重新进入和切照片/录像，不能只直接测试state.environment | 已修复，开发侧生产链路/生命周期专项验证通过；见2026-10-17记录，未运行UI/真机Provider测试 |
| F166 | P1 / C26 | 接通选择后仍会在解析结束立即presented并保存，未等GPU展示成功；旧画面直接被MTKView替换。Metal初始化force unwrap/try!可崩溃，绘制错误被空catch吞掉，无原图/旧LUT回退和一次GPU重试 | RemoteView选择Task、RemoteLUTMetalView.Coordinator及Renderer；安卓RemoteLutImage展示回调/旧层覆盖和renderFailed。验收设备/管线/纹理/颜色失败、首帧未显示、替换失败，旧有效画面保留且错误可见 | 已修复，开发侧离屏Metal/故障与展示状态验证通过；见2026-10-17记录，未运行UI/真机drawable展示验证 |
| F167 | P2 / C26 | 控制器缺完整生命周期：environment仅设置loadingIdentifier，不读恢复项；模式变更不必然清旧active，隐藏仅清内存不清该模式偏好；页面关闭/后台/菜单取消不调用失效，伪色与LUT双向互斥未接 | RemoteLUTMonitorState.environment/close/turnOff与RemoteView全调用；安卓LutMonitorState及LutStateInstrumentation。验收迟到读取、照片录像独立恢复、隐藏/后台/退出、开启伪色和LUT成功/失败交接 | 已修复，开发侧生产链路/生命周期专项验证通过；见2026-10-17记录，未运行UI/真机Provider测试 |
| F168 | P2 / C26 | 选择新目录在扫描成功前覆盖bookmark；失败不恢复旧目录。打开菜单不重扫，文件删除/修改无刷新；beginScan提前换folder，scanned不清两模式旧选择，missing/denied不清偏好，元数据没有mtime | RemoteLUTFolderAccess.save、RemoteView.fileImporter、RemoteLUTMonitorState.scan与RemoteLUTFile；安卓scan替换提交/授权释放/文件身份。验收坏新目录保旧、同目录文件删除/覆盖、重启恢复与选择隔离；关联F099/F102 | 已修复，开发侧目录/恢复/失效专项验证通过；见2026-10-17记录，未运行UI/真机Provider验证 |
| F169 | P2 / C26 | 监看目录scan直接在UI回调执行，read/parse的Task继承MainActor且首次await在解析之后；未使用RemoteLUTLoadQueue、解析缓存、取消票据或10秒截止。快速选择/慢Provider会占UI，旧页不能取消底层读取 | RemoteView.fileImporter/选择Task及RemoteLUTLoadQueue全引用；安卓LutIoQueue/ParsedLutCache/LutMonitorState。验收阻塞Provider、超限文件、快速改选和退出，不以本地小文件测试证明；共用边界另见F102/F105 | 已修复，开发侧串行队列/缓存/取消/截止专项验证通过；见2026-10-17记录，未运行UI/真机Provider测试 |
| F170 | P2 / C26 | 选择器变为系统sheet平铺路径，缺关闭LUT入口、分类/空目录/权限/扫描状态、600ms加载呼吸及成功后才关闭；空files直接再次选目录。各失败压成read，缺无帧/格式/超限/颜色/GPU等对应提示 | RemoteView.lutListPresented与工具按钮；安卓RemoteLutPanel/LutCategoryList及状态notice。验收无目录/空目录/无帧、失败重试、选中同项、关闭/分类和三语；不额外要求安卓监看并不存在的强度控件 | 功能开发侧已闭环：关闭/目录/分类/状态/错误及成功呈现后关闭接线已审查，补齐三操作触感及关闭状态标记；最终5/5专项通过，三语66条和目录至Metal集成证据保留。无UI手势/真机验收，600ms呼吸与精细弹层延期。 |
| F171 | P2 / C27 | 自动旋转收到unknown/平放/倒置时直接返回，未清候选和260ms任务，可在方向已失效时仍旋转；后台未暂停候选。切换中丢弃新目标，安卓使用conflated请求保留最新目标；Task.yield也不保证新布局经历隐藏帧 | RemoteView.applyDeviceOrientation/requestLayoutOrientation/scenePhase；安卓RemoteOrientationSession、rotationRequests及withFrameNanos。验收无效方向/后台取消候选、切换期间保留最新目标和锁定/解锁；2026-10-17用户明确接受UIDevice分类与安卓角度分区的平台差异 | 功能范围已核销：无效方向/后台清候选，260ms代次复核，切换保留最新目标及锁定清理；恢复前台、解锁、结束编辑时重新采样。f171-state 3/3及orientation-resume 3/3通过，生产接线已编译并源码核查。用户明确选择保留iOS系统方向判断，不引入CoreMotion。物理传感器/后台回放未验证；隐藏布局帧与渐变时序按用户范围延期，不声称视觉复刻完成。 |
| F172 | P2 / C27 | 相机录像红框加在整个监看页面外沿且即时出现/消失，安卓仅取景器边框并用280ms颜色动画，还要求connected | RemoteView.body.overlay；安卓ViewfinderCard.recordingBorder。验收横竖拍摄中/停止失败/断线，边框不围住工具区，并核中断颜色过渡 | 功能开发侧已闭环：红框移至真实取景器容器，不再围住工具区；与计时共用连接有效/录像模式/正在录像门控。录像状态专项最终8/8通过；布局归属经代码审查，未运行UI手势/视觉测试，280ms颜色动画按范围延期。 |
| F173 | P2 / C28 | 常亮由多个入口直接写同一全局isIdleTimerDisabled：Root因全屏路由消失时无条件关闭，监看没有接管；本地批次完成/析构恢复启动前快照，可能覆盖期间新偏好或前后台状态。安卓全局窗口flag与批次view常亮分别持有 | RootView.onDisappear/onAppear/scenePhase及LocalPhotoBatchViewModel.restoreIdleTimer/deinit；安卓MainActivity常亮effect和LocalPhotoEffectsOverlay。验收常亮开→进入监看、批次中改偏好/切后台再完成、两个持有者交接；全屏实际回调顺序待运行确认 | 已修复，应用级所有权及真实批次模型专项验证通过；见2026-10-17记录，未运行真机锁屏/UI测试 |
| F174 | P2 / C28、C29 | 自动语言手写为英文→繁体→其余全部简体，法/德等非支持系统语言下resource/text强制中文，安卓默认values为英文；可能与SwiftUI系统文本选用语言混杂 | RootView.AppLocalized.text/resource及locale；安卓AppLocale和values/strings.xml。验收三种支持语言及法语系统的自动模式、切回系统、错误/通知与界面一致 | 已修复，统一语言解析与错误提示专项验证通过；见2026-10-17记录，未运行系统设置/UI切换测试 |
| F175 | P2 / C29 | 公共拨轮拖动期间options/enabled/readOnly变化没有使手势失效，sync在dragging时直接返回；可按旧起始索引向新选项列表提交，临时禁用再启用亦可延续旧拖动。安卓pointerInput以这些值为键取消并finally回滚 | DetentWheel.dragGesture/sync/onChange；安卓ReleaseCommitWheel.pointerInput。验收拖动中收藏重排/删选项/切只读/禁用再启用，不能写入新列表错误项 | 开发侧已修复；五类配置变化/恢复与旧回调拒绝专项2/2通过；UI测试未运行 |
| F176 | P2 / C29 | 拨轮静止显示依赖本地动画position，外部选择/收藏重排后会暂显旧索引；松手请求未被业务接纳时position仍留目标，安卓静止始终显示accepted selectedIndex。缺220ms强调过渡、渐变表面/描边；邻档改小字号且暗色alpha0.5，安卓同字号/0.38 | DetentWheel.wheelRows/sync/onEnded与ReleaseCommitWheel.displayPosition/绘制；验收拒绝提交、外部重排、按下/强调/主题切换和邻档，不能以常量计算测试代替生产视图 | 功能开发侧已闭环：真实同实例拨轮外部选择/重排后渲染与新建已接受值一致，最终渲染+拖动状态3/3通过；拒绝提交时松手回到已接受selectedIndex的生产路径已审查。未做手势自动化，强调/材质/邻档样式动画延期。 |
| F177 | P2 / C29 | 带长按操作的公共拨轮固定450ms且不消费统一长按反馈，使用800ms计时清suppressNextTap；长按后下一次独立点击可能被吞，旧计时也可能清掉新长按保护 | DetentWheel.longPressGesture/activate；安卓combinedClickable及rememberLongPressFeedback。验收按住→松手→立即独立点按、连续长按、取消/离页与触感关闭；平台阈值按2026-10-17用户决定保留450ms | 功能范围已核销：已移除800ms吞点击计时器并改互斥手势；新增控件独立按住反馈与取消/去重，7/7专项通过。手势接线、配置变化/拖动/离页清理已作源码复核。用户明确选择“保留450ms，接受平台差异”。实际SwiftUI手势回放及物理振动未验证，不将源码复核记为UI测试通过。 |
| F178 | P2 / C29 | 资源键存在但内容仍旧：效果标题漏LUT、坐标/水印类型/强度等标签改写、工作台重新选择缺数量/生成文案不同；英文字符串保留Android转义的反斜杠撇号，AppLocalized仅解码换行。加载范围动态“n日”等还有硬编码语言 | AndroidLocalization/RootView.AppLocalized、SettingsView.listCard、PhotoEffectsEditor及LocalPhotoEffectsView实际引用；安卓values*。验收逐字/标点/占位格式三语对照；更新/激活旧文案不计功能缺口 | 开发侧已修复；584资源语言项对照、解码与三语专项4/4；加载范围/生成旧差异已按当前安卓纠正，UI未验 |
| F179 | P2 / C29 | 公共实体材质/胶囊仍用SwiftUI旧投影半径/偏移/透明度乘高度比例，没有安卓Surface系统投影模型；对应Surface分支的indication亦未证明等价。灯泡等调用也未传安卓固定textureSeed，生成纹理一致不等于调用身份一致 | ZTransferButtonMaterialSurface.shadow、ZTransferButtonElevation明确遗留注释、TipLightbulbButton；安卓GlassButton.Surface与TIP_LIGHTBULB_TEXTURE_SEED。验收各实体材质/状态/调用纹理身份和系统效果；毛玻璃/raised的无indication分支及已批准Liquid Glass不误算 | 范围拆分待核查：投影模型、纹理身份及 indication 视觉效果按用户要求暂缓，不计修复；若存在输入接纳/取消问题须另按功能处理，不能以材质相似替代验证。 |
| F180 | P2 / C27、C29 | 工具模式交叉仅给退场层allowsHitTesting(false)，触摸可落入下方新层；安卓退场层在Initial阶段消费全部手势，防止仍显示旧工具时触发另一控件 | RemoteToolModeCrossfade；安卓RemoteToolBar Crossfade.pointerInput。验收照片→录像→照片快速反向，在仍可见旧层的工具位置点击/拖动，不能误触下层新动作 | 开发侧已修复；真实Hosting命中路径专项1/1，快速反向屏蔽及结束恢复通过；未注入物理触摸 |
| F181 | P2 / C32 | 明确批准的AP方案要求不申请Wi-Fi Information；当前project.yml与ZTransfer.entitlements却重新配置com.apple.developer.networking.wifi-info=true，生成的App真机Debug/Release均引用此entitlements，代码无NetworkExtension/SSID读取用途。与既有范围决定冲突，增加签名配置依赖 | docs/技术调研/iOS-AP模式信号按钮复刻.md的2026-09-18决定；ios/project.yml:194、ZTransfer.entitlements:5及project.pbxproj的CODE_SIGN_ENTITLEMENTS。验收统一工程源配置与生成工程、检查真机和Release签名权限；本轮未构建，不声称已发生签名失败 | 开发侧已修复；工程源及两份权限文件一致，Debug/Release配置与模拟器签名已核对；未构建真机 |
| F182 | P2 / C29 | 高级版烟花主火花、核心和星尘的向白混色用sRGB分量线性插值，安卓Fireworks调用Compose Color.lerp的Oklab路径；同seed/时刻颜色演变不同。现有8张参考PNG来自优化前iOS自身，不能证明安卓色彩对齐 | PremiumFireworkDrawing.tint/draw、Android Fireworks.kt的三处lerp；项目已有ZTransferAndroidColor记录Compose1.7.6算法；FireworkReferenceFrames/README明确自身回归范围。验收同seed/分量的安卓参考及起爆/展开/消散，不覆盖旧PNG掩盖差异 | 范围暂缓：此项为烟花色彩插值与动画视觉对齐，不在当前功能范围；旧 PNG 仅为 iOS 自身回归，不计跨端完成。 |

F005 补充：`ConnectionViewModel.startUSBKeepalive` 也在首次失败即拆会话，安卓共用两次失败门槛覆盖USB。USB框架明确断线可以立即处理，不能把这个例外扩成所有空闲探测失败。

常亮所有权的源码缺口已计入F173；全屏路由实际是否触发RootView.onDisappear及锁屏表现仍需运行确认，不能把源码风险写成已实测现象。

| 待证编号 | 归属 | 尚需确认的内容 | 状态 |
|---|---|---|---|
| V001 | C09 | 队列返回时网格首项与像素偏移是否恢复 | 待生产UI验证 |
| V002 | C09 | 同次发布的displayedFiles/sections回调次序是否破坏删除动画旧身份 | 待生产UI验证 |
| V003 | C10 | 预览取消手势/外部切页的拖动复位；当前无目录分支会关页，不能据此断言卡死 | 待生产手势验证 |
| V004 | C12 | USB未知大小对象的短partial/空响应是否为可靠EOF | 待机型/协议回放 |
| V005 | C14 | 最后原片已完成、派生仍忙时的有限后台执行生命周期；不要求安卓前台服务语义 | 待后台验证 |
| V006 | C15 | 确认遮罩输入、行收合测量和滚动恢复的实际表现 | 待生产UI验证 |
| V007 | C22 | USB录像Android重开PTP会话、iOS复用ImageCaptureCore会话的差异；尚缺明确批准/兼容证据，不直接照搬原始USB命令 | 待平台依据及真机验证 |
| V008 | C31 | StoreKit历史R01：同进程自动恢复及年转永久刷新恢复尚未闭环。需观察App自身恢复，不能用测试主动重查替代；用户已接受约一秒短暂延迟，不外推为苹果线上缺陷 | 本轮未运行；外部配置R02–R04见高级版清单 |

## 逐项证据

### C01 启动与导航（已查·有缺口）

- 安卓依据：`MainActivity` 启动/路由/FilesQueueWorkspace/前后台常亮；`HomeWorkspacePager` 全实现；`MainNavigationPolicyTest`、`HomeWorkspacePagerTest`。
- iOS 依据：`ZTransferApp`、`RootView` 全实现；`PhotoListView` 队列展示/切换和顶栏；`ConnectionViewModel.setConnectionDiscoveryPaused`；`RestoredCameraWorkspaceTests` 及 `DomainModelTests.testGPSBlocksOnlyEntryIntoWorkspaceAndPanelOwnsConnectionPageGesture`。
- 已接通：应用级 StoreKit 监听；会话丢失保留工作区，替换会话重新绑定列表和队列；恢复工作区可持有无相机占位而不假装指令成功；GPS 阻止进入工作台、允许返回；连接时释放工作台；手势开始进入工作台立即暂停发现，取消后回到上页恢复。
- 确认缺口 F001–F003。现有 iOS 测试覆盖 GPS 入口与断线占位，没有验证分页距离/速度阈值和按钮返回的发现暂停时序；不能用 `TransferQueueScenarioTests` 证明工作台交互全部对齐。
- 路由对应的下载吞吐策略另在 C12 核查；新媒体后台事件在 C06/C14 核查。常亮全屏生命周期风险移交 C28 运行核对。
- Android 系统返回键二次退出和通知权限属于平台 API；iOS 没有同样系统返回键，不要求制造退出按钮。其它动作的返回优先级仍按各实际页面检查。
- 本轮只做静态对照，**未运行测试、未构建、未验收实际动画**。

### C02 AP Wi-Fi（已查·有缺口）

- 安卓依据：`CameraViewModel` 候选网络、watcher、GPS/工作台暂停、`connectToCameraWithRetry`、失败分类、心跳；`WifiConnectionStatusTest`。
- iOS 依据：`ConnectionViewModel` 初始化、网络监视、AP watcher、连接/取消/代次、失败分类、GPS 暂停；`WiFiConnectionService.connectAP/startKeepalive/disconnect`；`PTPIPDiscoveryService.isOnCameraHotspot`；连接卡失败文案与 `ConnectionState`；`ConnectionStateTests.testAPFailureClassificationMatchesAndroid`。
- 已接通：默认 STA；AP 候选只触发尝试而不伪造成功；固定地址握手、OpenSession、DeviceInfo 流失效检查；取消等待旧连接清理后再开新会话；USB/GPS/工作台互斥；代次隔离；离开候选网段清重试状态但不直接杀已接纳连接；断线留工作区；重连不重播庆祝。
- 确认 F004/F005；错误类型映射本身与已读安卓测试一致。现有分类测试不覆盖真实重复握手的 UI 状态，也不覆盖心跳失败计数。
- AP 信号静态四格、子网候选替代网关、普通会话后台寿命按既有平台记录区分，不作为新缺口。
- 未运行测试；无线握手/系统网络切换仍需协议回放和真机验证。未以文档旧 C14 的“一致”标签代替当前失败分支检查。

### C03 STA（已查·有缺口）

- 安卓依据：`PtpIpDiscovery` 全实现；`StaCameraProfileStore` 路由/迁移/重置；`NikonCamera` 配对与相册验证；`CameraViewModel` 候选/双identity/恢复/重试；`StaPairingStateTest`、`StaConnectionIsolationTest`、`StaCameraProfileSelectionTest`。
- iOS 依据：`PTPIPDiscoveryService`/`PTPIPDiscoveryPolicy`、`STAConnectionCoordinator`、`STABrowsingSession`、`STAProfileStore`；`ConnectionViewModel` STA阶段/重试/重置；`RootView` 会话替换；`STAResetPairingOverlay`。已读 `PTPIPDiscoveryTests`、`STABrowsingSessionTests`、`STAConnectionCoordinatorTests`、`STAProfileTests`。
- 已接通：保存地址须在真实路由内且端口通；mDNS与有界/24并行，48批次/24并发/450ms探测，两个服务依次最多1.5s；GUID优先、其他机身延后；握手串行，取消关闭旧socket；首/中/尾ObjectInfo或正大小+Partial验证相册；5秒初始化→60秒常规超时；单次ready重试1.2s、配对后6.6s、备选identity0.9s；重连3/8/15/30秒；清配对取消→清理→清两identity和全部机身资料，保留模式。
- 关键缺口 F006/F007；F005的无线心跳容错同样适用。配对UI阶段和旧路由隔离不能弥补缺少新可信验证。
- **测试覆盖存在反向证据**：`STABrowsingSessionTests.testFirstPairingMustFinishBeforeAlbumAndMarkerPrecedesOptionalEvent` 明确要求事件前已写marker；`STAConnectionCoordinatorTests` 把配对应答前后的 `markPaired` 当 fixture 前提。这些测试即使绿色，也会保护旧行为，必须随 N14 更新，不应只追加一个纯helper测试。
- 本轮未运行测试/构建；网络发现真实接口、相机固件配对确认及短断线视觉仍待回放/真机验证。没有把底层parse测试当作真实配对闭环。

### C04 USB（已查·有缺口）

- 安卓依据：`CameraViewModel` USB识别/权限/三次重试/插拔/互斥/恢复；相关协议测试中USB行为归C12/C21。iOS平台依据为 `docs/测试与验证/iOS-USB-授权链修复记录.md`，未把raw USB API机械当作漏项。
- iOS依据：`ConnectionViewModel` USB全生命周期；`ConnectionState` reducer；`CameraConnectionService`；`SelectedUSBPTPTransport`；`ImageCaptureUSBTransport` 浏览、双授权、Open→ready、会话token/对象身份、事件、挂起恢复及错误分类。已读`ConnectionStateTests`、`ImageCaptureErrorMappingTests`，协议/分块相关测试转C12核验。
- 已接通：内容与控制双授权顺序申请、前台重读；Wi-Fi已接纳时忽略USB；USB发现立即暂停无线；三次/1秒重试，失败后等重新插线；同对象重复add不伪装插线，替换对象先remove后add；旧token/旧对象不覆盖新session；Open后等ready再发DeviceInfo；框架后台挂起时不强加wall-clock超时；已发送命令排空、不主动关闭相机；取消/断线保留工作区。
- F008/F009为当前明确接线/状态缺陷；F005也涉及USB探测门槛。
- 文案另有确定线索：`usbErrorMessage`超时直接返回硬编码简中（`ConnectionViewModel.swift:844`），未在三语资源中找到对应项；C29统一核销与平台文案规范，不重复计为本模块全部本地化已验收。
- 未构建、未运行测试，也未做USB实机连接；纯reducer测试不证明真实ViewModel事件处理。下载和框架fallback上限在C12继续覆盖。

### C05 GPS（已查·有缺口）

- 安卓依据：`NikonGpsService`定位/写入/恢复/开关全链、`NikonGpsBleClient`扫描/GATT/Classic/队列/超时，`GpsViewModel`与地点LRU，协议/海拔/频率策略；`SettingsScreen`GPS状态/详情/倒计时/长按。已读`GpsRecoveryPolicyTest`、`GpsUpdateFrequencyTest`、`GpsAltitudePolicyTest`、`GpsPlaceLookupTest`、`NikonGpsProtocolTest`、`GeoPayloadEncoderTest`、`CoordinateFormatTest`及`GpsConnectionPresentationTest`对应断言。
- iOS依据：`GPSCoordinator`、`NikonGPSBluetoothClient`、`GPSState`、`GPSProtocol`、`GPSConnectionControl`全实现；`GPSTests/GPSProtocolTests`、`DomainModelTests`GPS权限/后台配置/缓存定位/状态与工作台门控测试。
- 已接通：独立GPS偏好和开关冷启动恢复；关闭时停BLE/定位；AP互斥；只有BLE ready才开始定位；7秒保存外设直连后回扫描；7秒配对阶段等待；800ms普通断线恢复与5秒传输失败恢复；四档频率、GEO带响应串行写及10秒超时；首个GEO成功才验证相机，650/700ms状态交接；写入失败不假报成功，期间只留最新定位；地点单次查询、8格LRU与请求代次、复制成功/失败气泡延迟；稳定会话长按800ms关闭；频率/清配对仅关闭时可操作。
- 确认 F010–F016。尤其NOT1、ID ACK超时、真实失效重试和旧连接ACK没有被现有协议向量/helper测试覆盖。现有测试未发现BLE客户端可注入假central/peripheral的回放层，不能将旧75项通过解释为这些回调已验证。
- 既有平台依据：`docs/iOS-AP-STA-全链路行为与安卓对照.html` G07/G08/D01记录卫星数0、CoreLocation精度代替provider采样、BLE身份+首个GEO ACK代替Android Classic bond及iOS后台恢复；真实机身首次配对确认仍需真机证据，不新增未经确认的系统bond操作。`GPS流程审查与优化方案.md`第八节确认外层Genie、280pt面板/10pt间距，这些不算视觉缺口。
- 旧总对照G03/G06/G08/G12等“已对齐”声明不足以覆盖本轮发现，已在该文档顶部加当前复核警示。坐标地点语言是否跟随App语言而非系统语言移交C28/C29核销；未把尚未追完的locale差异计作确定问题。
- **未运行测试、未构建、未实际BLE/后台/照片EXIF验收**。本项完成的是静态审查和问题登记，绝非GPS已修复或真机可用确认。

### C06 文件扫描与相机事件（已查·有缺口）

- 安卓依据：`CameraViewModel`加载范围更新、FHD/监看抢占、`loadFiles`全实现、事件轮询/handle目录同步/新增解析；`NikonCamera.streamFileInfo/streamMergedFileInfo/streamStaDirectMergedFileInfo`；Storage/handle快照/批次与日期策略。
- iOS依据：`PhotoListViewModel`扫描/发布/续扫/范围/事件接收；`CameraRepository`storage/handles/ObjectInfo/多卡归并/快照/范围与事件解析完整链；`CameraSession`接线和Wi-Fi/USB的2秒维护入口；读取`PhotoThumbnailStore`及磁盘reconcile以确认删除副作用。STA直读具体头解析和索引回退在C07继续逐条核对。
- 已接通：每卡相机自然顺序反转而非handle数值排序；跨卡按日期head稳定归并，无日期优先释放；同名称/大小/日期去重并合并卡归属；直接STA跨物理卡handle重叠时关闭不可靠卡筛选；1→3→12批次、缓存命中后24/48且中断回12；三次750ms STA忙重试；续扫保留已接受批次；监看后重枚举，STA前台让路保留游标；ObjectAdded90ms聚合、16个一批、180/360/720/1400ms重试，2秒事件/10秒handle差量与前台门控；逻辑副本替换不作为新媒体自动传输。
- 确认 F017–F022；C03的F007同机短断线目录保留仍适用。新增与自动传输入口在C14继续审查额度/快照/取消，不凭此处逻辑身份过滤宣布整条自动传输完成。
- 已读测试：安卓`CameraStorageTest`、`FileScanHandleSnapshotTest`、`MultiStorageFileOrderTest`、`FileScanBatchSizeTest`、`CachedThumbnailBatchPolicyTest`、`PhotoDateRangeTest`；iOS完整`ScanBatchPolicyTests`，`DomainModelTests`双卡/删除/快照/范围及工作区抢占相关用例。它们覆盖多数纯策略和正常回放，但未覆盖“扫描进行中改范围”“受限扫描后的真实磁盘保留”“不完整metadata后的事件”“跨批旧行归属”和“含已合并副本的续扫基线”。
- N03明确要求的删除重枚举/范围变化/缓存边界缺失，已撤回1.93 N03完成状态，记录进度9/15→8/15。其余旧完成项未因本模块静态检查而重新背书。
- 未运行测试、未构建；本轮未改业务源码。跨卡实体拍摄/删除和时序仍需生产回放与真机验证，不能用测试名称推断真实链路通过。

### C07 缩略图与EXIF（已查·有缺口）

- 安卓依据：`CameraViewModel`扫描预取/补漏队列/共乘/负缓存/解码与黑边裁切/EXIF，`ThumbnailFillQueue`、`ThumbnailDiskCache`；`NikonCamera`普通GetThumb、STA索引/头读取、JPG单候选增强、RAW提示/分段探测及视频封面；`StaJpegThumbnail`和对应元数据解析。
- iOS依据：`PhotoThumbnailFillQueue/Store/DiskCache`、`CameraSession`取图/预取/EXIF接线、`PhotoListViewModel`队列与范围门控、`AndroidThumbnailProcessor`、`PhotoExifStore/Parser`、`STAObjectReader`、`STAMediaMetadata`、`NEFExifThumbnail`；实际STA格子只有缓存观察，不因显隐取消相机任务，遵守用户已确认例外。
- 已接通：会话隔离/90天保留/临时文件清理与旧键迁移；STA JPG新键隔离旧低清图；同图请求共乘；扫描落盘后再发布完成；有界RAW探测失败可重试；RAW提示失败回退、IFD/marker/ExifInterface选择；JPEG≤256KiB单候选、640长边/90质量且不放大；黑边裁剪和视频回退；失败待外部唤醒、前台抢占后续接当前工作。前台所有权/调度原子性还由C11核验。
- 确认F023–F027；C06的F018/F020同时影响本模块。缓存身份和磁盘失败门控在安卓1.91已存在，`git show 617082c3`确认后撤回T03整体完成，1.91记录24/26→23/26。此处没有把修复领域helper等同于生产接线。
- 已读安卓`ThumbnailFillQueueTest/ThumbnailDiskCacheTest/StaDirectObjectMetadataTest/StaJpegThumbnailTest`；iOS`PhotoThumbnailStoreTests/PhotoThumbnailDiskCacheTests/AndroidThumbnailProcessorTests/STAJpegThumbnailTests/STAProfileAndMetadataTests/NEFExifParityTests`及扫描相关用例。无图空Data、坏写入、删除负缓存和身份helper均有局部测试，但漏实际PTP响应→会话→列表队列的异常接线；NEF的AndroidX差分用例需外部oracle配置，不能默认它已运行。
- 本轮未执行测试或构建；字节/图像/内存性能和真实相机的验证不由静态对照替代。照片预览方向/原图解码归C10，效果和边框元数据消费归C18/C19。

### C08 评级与保护（已查·有缺口）

- 已完整对照安卓/iOS `PhotoRating`、`PhotoRatingPairs`、`VideoRating`，评级扫描主循环/控制器，Repository对象属性/RAW头/视频窗口/能力门控和Cache代次；读取列表范围接线、筛选持久化、评级行与帮助、Debug探测生产入口，及安卓`RatingDiagnostics`、`AnchorPopup`。
- 静态已接通：精确0/1/25/50/75/99映射、XMP命名空间与TIFF字段、未知不当0；JPG/RAW唯一配对且卡槽/日期歧义独立；AP/USB对象属性及RAW扩展回退；STA 100KiB+8KiB最多256KiB，视频32×8KiB跳过mdat；能力拒绝锁存、DeviceBusy停止本次扫描；8192值FIFO、开关新快照、每文件进度、阶段释放与本地revision拒旧结果；普通新媒体不自动扩展已经锁定的评级快照。
- 确认F028–F033；N05/N06从已完成改为未完成，1.93当前有效记录8/15→6/15；N04只保留已读协议范围的历史开发侧结果，不把它当作新运行证据。1.94 M02因连续诊断捕获缺口重开，记录3/3→2/3。
- M01的STA保护门控已接ObjectInfo解析、按钮显示/激活、过滤及普通其它筛选编辑；iOS保存完整filter副本，所以其它项修改保留隐藏保护偏好。**原1.94文档将“清空整套筛选也保留”写入要求不符合当前安卓**：Android空结果按钮直接`clearFilters()`→`PhotoFilterCriteria.Default`，iOS同样恢复默认，两者都清保护偏好。这是文档纠正，不作为新漏项。
- M02头探测仅直读STA、最多4文件/256KiB，前后SHA与12个差异候选；0xDC03单属性只读，结果不改真实保护状态；AP/USB RAW独立读属性和头；Release空入口。上述界限静态可见。未找到保护头/属性的真实PTP回放测试，已有DomainModel只覆盖过滤纯函数和独立日志store；不能用134/805历史总数证明所有探测异常已测。
- 已读安卓三组评级/配对/视频测试及iOS对应三组、`RatingProtocolReplayTests`、`PhotoRatingScanTests`和DomainModel评级范围/STA保护用例。本轮未运行测试、构建或真机操作；扫描取消交叠的调度屏障仍在C11统一核销。当前取消测试未阻塞真实读并等待排空，覆盖强度有限。

### C09 照片列表（已查·有缺口）

- 已对照安卓`FileListScreen`列表派生/排序/筛选归一化/日期草稿、连拍模型/展开收起、目录已传标记、入队门控、格子/合集/空态/回顶及预览开闭入口；iOS`PhotoCatalog/PhotoFilter/TransferDirectoryIndex`、`PhotoListViewModel`发布/已传索引、`PhotoListView`对应入口和`PhotoFilterPopupOverlay/Components`。飞行曲线与队列计数完整生命周期继续归C15，预览内部归C10。
- 静态已接通：未知日期桶在前、日期降序且同时间保相机顺序；连拍同类型/编号连续且0–1秒、至少3张；筛选沿用完整目录连拍身份，合集展开保留合集项并插成员；删除首成员后按逻辑身份迁移展开状态；日期折叠不因临时筛选丢失；卡槽扫完归一化，日期草稿进入时固定、首尾相互夹紧、完成再提交；已传按目的文件夹/标准化名称/大小统一判定，不靠handle/队列完成状态，派生失败仍保原片绿勾；未传输筛选仅新完成的队列原片播放200ms退场。
- 确认F034–F043；F007的STA重挂空列表也影响滚动恢复。T04因真实连拍预览入口改动底层状态而撤回，1.91记录23/26→22/26；N11因飞行来源/重复边界缺口撤回，1.93记录6/15→5/15。保留对应历史构建和局部测试结果，不把它们误写成本轮证明。
- 已读安卓`BurstGroupingTest/BurstGridItemsTest/FileListPresentationTest/PhotoListDerivedStateTest/TransferredThumbnailStateTest/ThumbnailThemeBorderTest/AutoQueueFlightSourceTest/CameraRemovalPresentationTest/StorageSlotFilterTest`，iOS DomainModel排序/日期/卡槽/连拍/删除/已传身份/退场用例。多个测试仅调用helper：没有真正点击断线入队、合集长按、滚动回顶，亦没有检查frame注册和最新任务的生产映射。本轮未运行测试/构建。
- 待运行证据V001：iOS队列显示时移除ScrollView，未见显式滚动位置恢复；Android保持saveable gridState。需滚到中段→队列→返回，记录首项和像素偏移，不能仅凭SwiftUI结构断言实际一定归零。
- 待运行证据V002：`onChange(model.displayedFiles)`与`onChange(model.sections)`都写presentedCameraFiles；若前者先执行，删除动画失去旧身份基线。需要生产View中同次发布删除回放确认回调次序，现不计为已确认缺陷。
- 250ms预览长按与40pt顶栏分别有`docs/技术调研/iOS-照片预览长按与布局复刻.md`及`iOS-照片筛选与设置弹窗动画.md:138`的用户反馈依据；不机械按系统Android默认长按/36dp重开。其它布局参数差异未发现批准依据的按F041记录。所有实际动画和系统历法交互仍需后续集中验证。

### C10 照片预览（已查·有缺口）

- 已读安卓`PhotoPreviewOverlay/PreviewPage/ZoomablePreviewViewport`、合集页与控件/队列飞行、FHD普通/STA两路、CameraViewModel解码/EXIF/直方图来源；iOS完整`PhotoPreviewView`、`PreviewPinchObserver`、列表真实开闭/入队接线、CameraSession/Repository/STAObjectReader及EXIF store。单张效果对比和本地原图分页归C16；裁切内嵌准备/失败/确认已定位生产差异，集中归C20，不在这里把同名helper当作已接线。
- 静态已接通：预览会话独立分页快照；340ms延后不依赖动画帧钟；当前页FHD→EXIF同预约，只有忙→闲触发邻页补取而不以忙状态取消当前读；前后邻页、±2页缓存；300ms/16ms时钟FHD叠加淡入；视频不下载原片/不查额外大小，ObjectInfo文案和时间回退；连续逆时针90°、220ms旋转，翻页重置缩放但保旋转偏好；2.5倍/240ms触点双击、最大4或1:1、偏移夹紧、半页信息交接；原生双指窗口识别器拆装；预览返回重新找当前筛选中的成员，找不到淡出。
- 确认F044–F051；F034实际也覆盖预览两个入队闭包，F035/F039/F038继续影响开闭和状态。普通相机预览用FHD、不读取本地原片是安卓当前要求，不作为遗漏；本地工作台预览在C16单独核验。T04保持未完成，N11保持未完成；其它任务不因本项自动改成通过。
- 已读安卓`PhotoPreviewItemsTest/PhotoPreviewQueueGestureTest/PreviewGestureGeometryTest/PreviewCropPlacementTest/ThumbnailPreviewPriorityTest/FhdResponseDispositionTest`；iOS DomainModel对应分页/几何/方向/门控/黑白直方图用例、`CameraIOGateTests.testCurrentPreviewPublishesBeforeExifAndCachedReadsStaySkipped`、`PhotoPreviewInteractionUITests`及真实fixture。现有UI用例覆盖普通翻页/双指/恢复/重开，不覆盖连拍、拒绝入队、RGB、方向JPEG和协议失败；成功的伪payload顺序测试也不证明失败fallback顺序。
- 待运行证据V003：上滑取消/外部页面变化缺少安卓finally和currentItem变化时的拖动复位；iOS拒绝入队分支也不settle。**当前“无目录”真实闭包会直接关预览**，因此不能仅由拒绝分支推断用户会看到卡死。需生产取消手势、前后台中断以及补齐F034后“离线拒绝但保留预览”的回放验证。
- 旧技术文档`iOS-照片预览长按与布局复刻`增加当前复核提示，保留250ms已批准差异和历史测试事实；旧布尔直方图/布局记录不能覆盖当前安卓RGB与新布局。未执行测试、构建、安装、截图或性能测量。

### C11 全局相机调度（已查·有缺口）

- 对照安卓完整`CameraIoGate`及`CameraIoGateTest`的优先级、预约、下载计数、取消和关闭用例，`MonitorStorage`、`NikonCamera.close`、评级生产生命周期与权威调度文档；iOS完整`CameraIOGate`、`CameraIOGateTests`、Repository各类调度调用及`PTPSession`串行/取消边界、无线关闭真实调用链、评级控制器。协议包的完整性和下载发布另在C12/C13核验。
- 已接通：有效优先级/FIFO、前台事件P0与后台事件P2/评级屏障区分、按计数持有评级和整文件下载活动、FHD→EXIF预约、同一调度器TaskLocal嵌套拒绝；缓存本地工作不必排相机队列。STA顺序加载例外仍保留。正常进入operation后，defer会在协议返回/排空后释放，不因取消调用者直接放行下一业务请求。
- 确认F052–F055。撤回N01/N02完成声明，1.93当前记录由5/15改为3/15；N05此前已未完成。旧协议取消排空、嵌套测试是真实的局部证据，不能证明准入交接或生产CloseSession已正确接线。
- `testIdleCommandRechecksActivityAfterWaitingForSlice`与安卓同类测试不是等价场景：安卓先占的是内部protocol mutex，IDLE已选为active后才开始下载；iOS先占调度ticket，IDLE尚在pending。因此不能为使此测试立即返回而删除所有IDLE下载屏障。应分别测试“尚未选中”和“已选中未执行”。
- iOS评级取消测试只有立即返回的stub、等待loading后关闭，未阻塞旧读到新代开始后再释放；没有覆盖F055。调度测试也缺F052确定交接窗口、真实CloseSession跨多命令ticket、普通IDLE等完整下载及两重评级屏障生产接线。未运行测试、构建或相机操作。

### C12 下载与续传（已查·有缺口）

- 阅读安卓`downloadToFile`完整策略/收包/异常Cancel排空、`DownloadIntegrity`、`VideoTransferPolicy`及其测试、`CameraIoGateTest`下载策略；iOS`CameraRepository.downloadResultImpl`全实现、`CameraDownloadWriter`、PTP session/socket流式与框架适配器、`PTPIPDownloadPhase`、worker续传/完整part入口及失败处理。队列按钮和任务重试身份另在C14/C15，保存授权和碰撞在C13继续。
- 已接通：视频扩展集合mov/mp4/nev/avi、4MiB续传对齐和裁尾、未知大小先取64位size、普通视频实际收到多少推进多少、零字节防循环、显式unsupported且首块无字节才可fallback、会话能力记忆、同文件吞吐策略快照、进度200ms/端到端时钟/不计旧续传字节、有界256KiB元数据头和1MiB输出缓冲。PTP/IP等待CMD_RESPONSE而非END_DATA便释放、负响应不毒化通道；异常持锁Cancel、3秒无活动和32MiB排空预算、失败退役及迟到回调隔离已有代码和回放依据。
- 确认F056–F059；撤回T21完成，1.91记录22/26→21/26。旧“双来源完整校验接线完成”与当前生产入口不符；旧测试日志仍保留，但期待接受stale ObjectInfo的测试不能证明安卓完整性策略。T22相关任务捷径在C14继续复核，不以本项替代两条生命周期审查。
- 已读iOS`CameraDownloadTests`下载/保存/计时/writer场景和脚本fixture、`DownloadIntegrityTests`、`PTPSessionTests`生产测试/fixture、`PTPIPTransferRecoveryTests`下载、超时、Cancel、写错和下一请求回放。没有执行测试或构建。真实USB与测试DownloadReplay不同：前者采用整Data回调，后者直接sink写入，不可据其成功推断USB内存边界已验收。
- 待验证V004：USB未知大小时把第一次短partial或零字节响应视为EOF，并以当时written作为完整size；需要机型/协议回放证明该路径的EOF约定，不能仅以“已知大小视频允许短块继续”推断未知大小短块一定完整。框架下载取消在不可取消回调完成后才收尾的队列归属，交C14核对实际session替换与worker句柄。

### C13 目录与保存（已查·有缺口）

- 阅读安卓保存目录/授权、目录单飞索引/扫描/临时文件清理、日期/类型路由、原片双索引/命名预留、正常非Harmony原片rename/copy及派生共享destination发布；iOS完整`DirectoryAccessStore/TransferDirectoryIndex`、存放偏好/入队目录快照、worker目录和本地命中路径、finalize与真实两路派生落盘、设置选择和列表刷新接线。裁切内核/临时文件规则在C20单独核销，照片库导出在C16。
- 已接通：bookmark保存/恢复/陈旧刷新/失效清除；三种存放方式及旧布尔迁移正常值；公历日期兜底、ZT-大写扩展名/UNKNOWN；每个task保留子目录快照，重试不套后来存放方式；列表按当前目录/模式重建已传索引；AP/STA数字尾缀对齐但类型/大小/目录独立；原片优先精确名、完整复制校验长度/失败删副本，派生位于相应目录的ZTFrames且失败不删原片。
- 确认F060–F064；N11保持未完成，T21保持未完成；T22因真实并发发布无预留撤回完成，1.91记录21/26→20/26。现有安全命名helper及纯occupied集合测试，不能证明真实保存边界已接入。F048预览绿勾仍独立错误推断，不能因目录索引本身已接通而关闭。
- 已读`NewMediaTransferPolicyTest`目录/类型/快照、`ExistingFileNameIndexTest`（含并发预留）、iOS`ExportedOriginalIdentityTests`、DomainModel目录/存放/清理/重选/迟到旧目录输出、CameraDownload rename/copy校验用例。未运行；真实Files授权生命周期、目录变更、磁盘满和Provider拒绝需对应运行验证。
- Android普通保存没有通用“先查可用空间再入队”的要求，本轮不自行添加；写盘失败应保留原片/按照片视频规则处理part并显示已有错误。Harmony journal/hash发布排除继续有效，不混入普通iOS要求。
- 额外对照边界：旧目录有效性检查返回前改选新目录，当前iOS和安卓都有可能清当前选择；这是两端共有的时序风险，不计作iOS漏复刻。iOS裁切staging当前为字面字符串`.nkcrop_(UUID().uuidString).part`且启动清理未扫nkcrop，交C20核对生命周期/并发实际入口后判定，不据字符串单独宣称已损坏用户文件。

### C14 传输与生成任务（已查·有缺口）

- 阅读完整生成/元数据准备队列及其测试，TransferTask生成/重试状态、TransferViewModel原片命中/交接/裁切/总开关/计时/重试分流；iOS TransferQueue所有入队、执行、准备、生成、暂停/移除/重试及ViewModel真实入口。逐条确认F065–F074，关联F034/F058/F061/F064。
- 已接通的有限范围：手动允许重复、自动按名称/大小/日期去重；批量保存同一效果和目录模式快照；任务不持久化；活跃原片不允许用户撤回，暂停在文件边界，终态卡原位替换新ID但执行排队在末尾；清理保护等待/运行效果；入队水印不随后续权益改动；metadata已具机身/会话身份与重连ObjectInfo核对，重试不向另一机身误读。自动裁切排除及派生重试仍有上述缺口，不把局部正确写成整体完成。
- 已阅读PhotoGenerationQueueTest、PhotoMetadataPreparationTest、PhotoMetadataIdentityTest/Swift对应、AutoTransferModeTest、TransferStateTest相关状态/重试/计时；iOS DomainModel的TransferQueueScenarioTests及CameraDownloadTests元数据四组回放。未运行任何测试/构建。现有“双工”“已有原片生成失败整卡failed”和“JPG完整part直接跳过”期待过时或错误规则，后续修复应更新生产场景而非只补helper。
- T22保持未完成；F074证明T20原已补裁切自动去重声明不成立，撤回T20，1.91记录20/26→19/26。1.93保持3/15、1.94保持2/3。C20还需独立核裁切内核/UI，不能用此处生命周期审查替代。
- 待验证V005：iOS有界后台assertion在下载worker退出时结束，即使生成仍在运行；普通后台会话无Android前台服务语义属于已批准差异，但派生是否应共享有限assertion及实际后台完成行为尚无运行证据，需在最后原片已完成、生成仍忙时回后台验证。不可据此宣称支持长期后台运行。
- 框架下载取消：不可取消回调返回前worker仍持有执行句柄，不会因detach直接开启第二个worker。取消恰与最后成功响应相交时，发布原片还是回WAITING的运行顺序仍需回放；当前没有足够证据再登记独立丢数据问题。任务全量快照AsyncStream未合流的UI负载风险交C15核对订阅端。

### C15 队列页面与反馈（已查·有缺口）

- 完整阅读安卓TransferScreen、QueueCardSwipe、TransferProgressMotion、LiquidProgressFill及QueuePill/自动飞行宿主链路；iOS完整TransferQueueView、QueuePill/rolling/catch/progress组件、顶栏执行控件、newMedia入口及订阅模型。确认F075–F085，关联F003/F038/F039/F042/F051/F068/F071/F073；旧T23/N11仍未完成，台账计数不再降低。
- 正常局部已接：倒序卡片、低频状态/高频进度分流、成功补满而失败保留最后真实进度、280ms收合/320ms批量兜底、生成保护、移除中任务不参与全局重试、实时速度零值保留、下载优先于生成的胶囊主阶段、已完成页进入不重播Done、有取消记录不庆祝、catch的1.18/110ms与物理弹簧。不能据这些局部断言覆盖F075–F085。
- 阅读TransferQueueActionVisibilityTest、QueuePillStateTest、AutoQueueFlightSourceTest、TransferProgressMotionTest及iOS相应进度helper/actor场景/AutoTransferMode生产入口测试。未找到覆盖实际队列卡滑动、执行控件显隐、Done期间追加等待和自动飞行宿主的iOS UI用例；PhotoPreviewInteractionUITests也未覆盖这些页面行为。未运行测试或构建。
- F068补充：生成中的展示用Date差值而安卓用elapsedRealtime；用户/系统校时会改变显示，终值却用ContinuousClock，可能跳变。验收应包括生成期间系统时钟改变，不能只核最终elapsed。时长单位格式本身与安卓一致。
- 待运行V006：确认遮罩拖动拦截、行收合测量回馈和滚动恢复需实景验证；静态已确认固定行距不会随高度一起收合，但不凭SwiftUI布局推断具体闪跳幅度。高频刷新成本仅记结构差异，不报告未经测量的耗时。

### C16 本地照片工作台（已查·有缺口）

- 完整读取LocalPhotoEffectsOverlay/PreviewPager/BatchButton/BatchViewModel、LocalPhotoEffectsPreferences及PhotoEffectsBatch；iOS LocalPhotoEffectsView/LocalEffectPreview、BatchViewModel/Output、BatchState/Runner和PhotoEffectsStore本地作用域。确认F086–F090；本地返回手势另受C01/F001/F002影响，公共编辑器细部/渲染归C17–C19。
- 已对齐的有限范围：取消选图不清旧选择、顺序去重、批次中拒绝换选择/重复生成、无停止按钮；源引用快照、最多2个并行工作、单项失败继续/计数单调、取消不计失败、2400ms后仅未变化结果返回READY；水印在权限提示前冻结。普通效果偏好及旧收藏迁移独立于相机，已禁本地经纬度/海拔开关；LUT角色独立性仍是F088。
- 预览已有1280长边、可见/进入页才解码、首张选择回第一页、文字独改140ms防抖、滤镜中间图与边框重绘分开、对比延后500ms、当前页且非生成时预取最多两份；没有批量保留原图UIImage。预取命中是否仍多算滤镜、位置字段完整规范化及公共动画/原始EXIF覆盖，交C18/C19继续逐实现核对，不视为已完成。
- 已读PhotoEffectsBatchTest、LocalPhotoEffectsPreferencesTest、iOS EffectsTests/PhotoEffectsBatchTests及PremiumBusinessTests真实model+renderer的授权期间权益变化用例。未运行。本轮不复用历史系统相册2/2和双图1/1结果作为当前大批次/其它格式/iCloud来源已验收证据。
- 系统Photos选图/添加授权/写入JPEG及iOS保存提示是现有长期平台实现，商业化文档已记录实际相册输出验证；本轮不要求照搬MediaStore URI或Android文件夹API。仍需实际验证系统写入期间后台/权限变化，已接受写入无法由Task取消回滚，不能伪称未落任何文件。应用退出后的模型任务释放/常亮所有权也需生命周期验证，未据deinit文字单独认定已取消。
- F088撤回T14，F089撤回T18，1.91记录19/26→17/26；T23已未完成。1.93保持3/15、1.94保持2/3。下一项检查模块联动与收藏，避免把通用模型复用误当独立配置/真实入口一致。

### C17 效果模块与收藏（已查·有缺口）

- 完整对照PhotoEffectModules/PhotoEffectModuleMenu/PhotoEffectFavorites及安卓测试，SettingsScreen相机草稿commit/module变化、TransferViewModel正式配置、本地独立偏好；iOS PhotoEffectsControls生产按钮/分区、PhotoEffectsSettings有效配置和PhotoEffectsStore归一化/恢复/持久化、两个宿主draft接线。确认F091–F097，继续关联F088/F089。
- 有限正确范围：有效掩码恢复时去未知位/空值回15；免费有效mask补齐框/水印；普通相机与本地偏好有不同键；滤镜收藏去重/排序和强度记忆；边框收藏应用保留当前文字/图片、图片缺身份拒绝。不能据这些helper与局部测试证明生产点击/显隐/提交符合安卓。
- 已读安卓模块穷举与收藏9/10/12字段/宽度/背景测试；iOS PhotoEffectModulesTests及DomainModelTests收藏/current-content、prefs-only不立即应用活动效果用例。未运行测试/构建。缺真实菜单切换、隐藏清启用再显示、独立水印编辑、LUT掩码和完整收藏几何往返测试；下次修复须覆盖生产宿主，不能只新增纯位运算测试。
- F096撤回T17，1.91记录17/26→16/26；T14/T18已未完成，1.93仍3/15、1.94仍2/3。已入队水印冻结和降级保留用户素材/偏好继续优先；本项隐藏清启用仅指用户显式关闭模块，不能借修复覆盖批准的权益规则。

### C18 照片滤镜与LUT（已查·有缺口）

- 对照安卓PhotoLutEditor/EditorState/Store/Codec、LutIoQueue/FolderRepository、CubeLutParser、PhotoCubeMapper/ResourceCache、LutColorPipeline、PhotoFilterRenderer原图/预览及SettingsScreen实际选择/缓存；iOS PhotoLUTChooser/Store/Runtime/FolderAccess/Catalog/Parser/Mapper、PhotoEffectsStore所有保存恢复入口、Renderer与LocalPhotoOutput、两个预览宿主和普通滤镜chooser。确认F098–F110，关联F088/F089/F093/F095；T14保持未完成，N12继续未完成，计数16/26、3/15、2/3不变。
- NP3目录作只读源码数据核对：两端50项源SHA/转换ID、六个数值控制、24字节色带和可选曲线逐项比较，0差异；这是静态源比较，**不是执行Swift/Kotlin测试**。NP3 Float运算、灰度保护、色相分段、curve/tonal分支、先量化后混合与straight/premultiplied适配已对照；不要求搬未被产品入口使用的NCP类型。历史golden文件覆盖50项×24颜色×4强度，当前未重新运行。
- 阅读安卓CubeParser、PhotoLutSnapshotCodec、PhotoCubeMapper、PhotoCubeBulk、PhotoCubeResourceCache、LutColorPipeline、PhotoFilterRenderer测试，以及iOS CubeLUTTests/PhotoCubeLUTMapperTests/PhotoLUTStoreTests、NP3 Engine/Bitmap/Golden测试。iOS现有Cube图像测试只有尺寸断言、Store只有选择/强度/收藏两项，缺生产提交、重启、范围/半透明像素、损坏快照、Provider失败和取消。不能把这些历史绿色当完整LUT验收。
- 正常有限范围：根目录+一级后缀cube、2…65格和32MiB/8KiB名义限制、R最快、SHA内容身份、三线性采样、原子文件写、普通NP3强度偶数与每项记忆、当前滤镜后两邻项预热及500ms后对比已存在。实际边界/目录角色/缓存所有权/提交入口仍有上述缺口。
- 本轮未构建、未执行测试、未渲染或测性能。不会因已发现严重接线而自行大改业务；将最小生产场景作为后续集中验证入口。照片和监看共用解析/目录缺陷由C26继续核所有调用端，避免用一处修改推断另一处已闭环。

### C19 边框与水印（已查·有缺口）

- 对照安卓PhotoFrameMetadataSettings/Width、地点解析/行政层级、FrameBrandLogo、ParameterPosterFrame、WatermarkStore、Exporter布局/绘制/指纹/EXIF/分区渲染/分配门控，以及SettingsScreen实际编辑/预览；iOS对应模型、Store全恢复/保存链、Renderer各模板/图片水印/元数据呈现、JPEGEncoder及两个实际导出入口。确认F111–F124，关联F096/F101/F110；不是把未运行的渲染当像素验收。
- 有限已接：15模板持久ID、宽度60–200/5归一化、字体素材和17品牌资源、文字24 Unicode标量上限、图片20MiB/128KiB块摘要/原子私有副本/2048解码与3项缓存、图片水印位置转照片、入队快照、JPEG最高质量及EXIF/GPS子集复制/新尺寸方向。品牌资源与图片边界不证明所有模板正确使用；坐标单轴0缺口见F113。
- 阅读PhotoFrameMetadataSettingsTest的品牌循环/codec/隐藏字段穷举/预览假值与输出身份，PhotoFramePlaceTest、ParameterPosterFrameTest、PhotoAllocationBudgetTest；ExporterTest中原图区域/布局/位置安全区/透明度/尺寸/坐标/身份等相关断言，以及Swift FrameMetadataSettings/Place/CoordinateFormat/Brand/BrandLogoCatalog/TextLayout和既有DomainModel效果用例。现有Swift主要是helper，坐标还期待旧DMS；缺真实store重启、全部模板Logo、低宽度完整照片和地点生产接线测试。未执行测试、构建、图片渲染或联网地理编码。
- 撤回T15/T16；C18共用Cube/目录的F102/F105也已足以撤回T12，不等C26才纠正旧完成声明。1.91当前16/26→13/26；1.93保持3/15、1.94保持2/3。旧T15“统一生成入口已完成”实际上仅新增未调用方法，旧海报/Logo/全模板排版完成声明无生产覆盖依据，历史测试结果仍保留。

### C20 无损裁切（已查·有缺口）

- 完整阅读两端Crop/JpegCrop/Preview/Bounds/Geometry/Editor/Preparation、源访问与输出发布、Swift任务存储及处理器、实际PhotoPreview→PhotoList→Queue调用；对照Android native JPEG桥接与Swift C桥接、libjpeg transupp的EXIF更新条件。确认F125–F135，关联F070/F072/F073/F074；撤回T19，1.91记录13/26→12/26，T20仍未完成。
- 有限已接：JpegCropSource八方向几何、左上MCU对齐且右下不强制整块、整比/互质原比例内核、下载原片保留、裁切后才生成效果、源几何不符拒绝、效果失败不重做已保存同目录crop、缺源/坏头失败保留任务重试、libjpeg系数路径不用RGB重编码。正常错误和成功清理局部存在，不代表准备/交互/发布完整性正确。
- 完整阅读Android JpegCropTest/CropSelectionTest/CropEditorGeometryTest、三组Crop Native/Output/Editor instrumentation，以及Swift全部独立Crop测试和DomainModel裁切失败保原片/离线重试。Swift现有测试大多只测孤立helper，CropPreparation/Preview/Viewport/Animation未接实际UI；唯一processor测试只查输出名，DomainModel坏字节在头解析就退出。旧文档若称已覆盖原生截断/全部EXIF/实际裁切触摸，则当前保留测试不足以证明。
- 未构建、未运行测试或故障注入、未操作相机/系统文件Provider。F132是可由错误策略静态确认的风险，不声称已生成过损坏文件。不会要求直接搬Android SAF或/proc路径，但保留完整照片、失败/取消/半成品清理及有界资源是共同业务要求。
- 旧T19把新增helper、sheet构建和常量测试累计成整体完成，现已明确纠正；原文“方向失败不可重试”也不是当前安卓UI规则，安卓失败面板允许重试。后续修复必须以当前Android实际入口和状态为准。

### C21 监看进入、退出与会话生命周期（已查·有缺口）

- 对照Android FileList入口/引导、MainActivity路由、RemoteScreen准备/startSession/断连/清理与CameraViewModel远程门控；iOS RootView/PhotoList实际入口、IntroController、PhotoListViewModel暂停恢复、RemoteView宿主、RemoteViewModel启动/关闭/全局失连回调及CameraRepository门控。确认F136–F138，已有页面转场缺口仍见F003；操作/录像细节继续C22、额度精算继续C30。
- 有限已接：V2独立键/800ms后开始计次/最多20次/保持4秒、延迟期间点击取消后续、真实滚动收起、队列/监看隐藏时取消；目录→传输忙→剩余额度入口顺序、缩进入口先展开；远程门控先于参数、先拨杆再对应曝光/对焦/电量、USB旧控制清理、普通忙40ms/3次普通错误重启/启动失败3秒重试、切HD先关旧LV；失效会话一次通知全局连接器，恢复后以新session重建；无真实session只显示恢复页且不执行协议。
- 退出已有单一cleanupTask汇合、在途半按/点按/写参数/完全控制/录像命令等排空后归还通道，普通列表随后补扫，STA按批准规则继续既有顺序队列；录制保存与退出并发的专门测试入口存在，完整读写行为在C22核销。没有把普通后台能力说成Android前台服务；scenePhase目前只影响用量，系统挂起/回来、常亮所有权和重连跨清理仍需集中运行。
- 阅读RemoteEntryIntroPolicyTest与Swift Policy/Lifecycle/ScrollActivity相关测试，RemoteLifecycleTests中进入顺序、HD、帧失败重启、全局失连、停止无后续轮询，以及DomainModel远程暂停/恢复/STA顺序场景。未运行；既有测试多测model，不覆盖真实RootView重连/退出计时尾巴和USB单首帧稳定门槛。未用其他线程刚运行的测试替本轮未查场景核销。
- 1.91仍12/26，1.93仍3/15，1.94仍2/3；本项不把领域门控局部正确当成N09/监看整体验收，也不因平台对象重建本身就推断重连功能缺失。继续C22实际相机动作、解码/录制资源和权限边界。

### C22 监看操作、相机录像与本地录制（已查·有缺口）

- 对照RemoteScreen拍摄/半按/完全控制/录像及录制循环、RemoteLab取帧/动作/应用模式、ViewfinderRecorder，追踪iOS RemoteViewModel、CameraRepository、帧解码管线及RemoteViewfinderRecorder实际调用；确认F139–F146，USB会话平台语义另列V007。
- 静态已接路径：增强取帧仅按缓存DeviceInfo选择、明确不支持立即降级/两次无效帧降级、Busy/NotLiveView不误降级；半按/点按事务在退出时排空，拍摄成功与12秒事件等待分开；相机录像根据禁止位决定一次兼容恢复，完成/中断后才清模式，手动完全控制持有与USB自动控制有区分。异常分支和副作用记账仍有上述缺口。
- 阅读RemoteMovieTest、RemoteMovieRulesTests和RemoteLifecycleTests中的准备/重试/事件/控制/半按/真实MP4测试及RemoteRecorderTests。当前真实MP4用例只证明有限帧/普通暂停可写容器，未覆盖反挤压、名称冲突、慢编码、首帧前暂停、编码故障和离页保存失败；未运行任何测试或录制。
- 本地录制权限拒绝可降级无声、授权返回重验可见性/权益、隐藏/降级停止、保存结束才成功反馈已有接线；这些正确路径不抵消F141–F146。录制胶囊/提示的最新其他线程实现保留，动画完整核销归C27/C29。
- 旧N09/N10本已未完成，未改写其他线程的测试记录；1.91仍12/26、1.93仍3/15、1.94仍2/3。继续C23参数和相机工具。

### C23 相机参数、工具菜单与拨轮（已查·有缺口）

- 对照RemoteCameraTools/RemoteCameraToolPanel、RemoteLab参数解析和写后验证、RemoteScreen参数缓存/合并/Auto ISO及ParamTile；阅读iOS RemotePropertyCodec、RemoteExposureParameters、RemoteCameraTool/Controller、RemoteViewModel对应入口、真实菜单/全值表/参数输入及拨轮绘制。确认F147/F148。
- 候选属性、AF/MF独立编码、Z30名称、未知数值fallback、对焦区域排序和点按标识已接；菜单5秒首次读超时/1200ms轮询、写前重读模式和值域、Busy两次120/240ms与回读40/90/160ms及单次重发规则对应；已开始的写入排空与尚未开始的过期写入必须区别，F147漏了后一门控。
- 拨轮18pt档距、±1.5原始越界/0.3阻尼/0.45显示上限、真实值最近锚点、五行深度、180ms归位/150ms相邻淡显、AUTO 44×30触区及域变化取消已有实现。全表测宽、选中项前3行定位和即时写后关闭已接。具体字体/系统涟漪及公共弹窗留C29，不凭相似截图闭环。
- 阅读Android RemoteAutoIsoTest/RemoteFocusModeTest/RemoteCameraToolLabelTest和iOS对应规则、RemoteParameterWheelTests、RemoteLifecycleTests菜单变域/模式/退页/写后验证用例。已有测试未阻塞beforeWrite窗口，参数测试也未提供真实快门Range包；本轮未运行测试、未操作相机。
- 撤回T06及N08完成声明，保留已有成功测试的原有效范围。当前历史记录变为1.91 11/26、1.93 2/15、1.94 2/3；N09原已未完成。继续C24取景交互及焦框/水平仪。

### C24 取景交互、焦框、参考线与水平仪（已查·有缺口）

- 阅读双端ViewfinderViewport/取景触摸、RemoteScreen.ViewfinderImage与FocusReticleOverlay、iOS实际三层焦框、LiveViewMetadata/RemoteFrameParser、参考线和水平仪源码；确认F149–F152。录制不应用反挤压见F141，显示LUT路线另在C26检查。
- 缩放1–8倍、质心/平移裁边、固定图像窗口、黑边拒绝对焦、双击复位、尺寸/倍率变化重置及完整LiveView命令坐标已接；网格10档几何/首帧前显示/反挤压适配对应，未新发现核心计算漏项。焦框metadata逐条校验、显示区域裁切和未知头型拒绝对应，但解析正确不等于显示资格/动画正确。
- 双轴来源优先≤1500ms有效头，D067回退/3次失败停属性查询而继续等头、250ms刷新及0.7/1.2滞回、100ms姿态/160ms颜色/最短角路线均已接；iOS有实际颜色向量参考和渲染测试。未发现需要撤回T07/T08范围内核心实现的新增证据，真机及本轮运行验证仍未做。
- 阅读Android ViewfinderViewportTest、FramingGridTest全部几何矩阵、LiveViewAttitudeTest五组及Swift对应测试、输入身份/焦框解析用例；64组颜色测试读取现有参考文件，不是本轮重新执行。缺生产焦框过期、同几何变色、120ms两层交接和放大线宽的断言。未构建/运行测试。
- N07旧完成声明撤回；1.91保持11/26，1.93变为1/15（仅N04保留历史记录），1.94保持2/3。继续C25信息/分析和提示。

### C25 监看信息、分析与曝光辅助（已查·有缺口）

- 对照双端曝光分析、帧解码与缓存、Histogram/Zebra/FalseColor/Waveform实际绘制、DISP详情/规格/存储轮询、曝光尺协议/状态/绘制及音量表，确认F153–F164。统一提示归C29核销最新实现；存储调度正在其他线程修复，不能以旧快照作最终结论。
- 有限已接：三档DISP、CAMERA首帧前壳体及12/10/100/16/400布局参数、只读属性候选/值域helper、500ms测光频率、波形125ms和亮度直方图250ms、伪色区间颜色、分析独立于录制原帧。正确helper没有替代生产生命周期验证。
- 阅读Android RemoteExposureAnalysis、RemoteExposureMeter及MonitorExposurePerformanceInstrumentation和Swift对应算法/曝光尺/DISP/帧管线测试；独立Swift算法测试还使用错误权重，生产测试主要小图/普通reset。缺偏好首次恢复、模式/尺寸切换在途解码、真实测光失败/迟到、统计图/曝光尺/音量表布局与时序验证。本轮未运行测试或做性能测量。
- T09/T10/T11旧整体完成声明撤回，1.91历史记录11/26→8/26；1.93仍1/15，1.94仍2/3。T11原有限布局回归保留，不把通过的几何常量测试扩张成全部DISP与Dock正确。继续C26。

### C26 监看 LUT（已查·有缺口）

- 读取全部八个RemoteLUT Swift文件、实际页面选择/渲染/生命周期调用，对照完整Android LutMonitorState、RemoteLutImage/Panel及Folder/GL/Texture关键链；确认F165–F170。最严重的是environment从未被生产页面调用，available默认false，因此现有页面文件选择无效，不能把孤立状态模型测试当功能完成。
- Cube基础解析及照片共用目录/数学边界已在C18记录F099/F102/F104/F105，本项补核监看消费者，不重复登记。GPU shader有三维纹理/DOMAIN/中心采样等实现，不能据其存在推断实际画面接入或失败策略正确。录制仍消费原始解码图，没有因显示LUT而改写录制输入。
- 完整阅读Android LutStateInstrumentation的真实协调器用例（展示才提交、互斥、迟到/取消、模式/隐藏、扫描失败、GPU一次重试、换目录），以及Swift Catalog/Preferences/State/MonitorState/LoadQueue测试。Swift仅手动调用environment/presented和未被生产消费的队列，缺页面端到端及GPU失败回放；本轮未运行测试/渲染/构建。
- 撤回T13，1.91历史记录8/26→7/26；1.93仍1/15、1.94仍2/3。大纲删除误加的监看强度要求，按安卓实际关闭/互斥行为审查；照片强度属于C18。继续C27工具布局。

### C27 监看工具配置、横竖屏与 Dock（已查·有缺口）

- 对照双端ToolPreferences/Layout/Toolbar、Orientation策略、LandscapeMonitorLayout/Controls及iOS实际RemoteView接线，确认F171/F172；隐藏LUT未清状态与选择等F167也属于T05完整工具接线缺口，不能仅以工具按钮都存在认定完成。
- 有限一致：工具声明顺序/未知重复ID归一化、照片排除音量、照片录像独立顺序显隐、锁槽脱离/持久化、隐藏不恢复旧激活；槽位弹簧为520/0.88，抬升120ms、图标180ms、摇摆160ms和55ms交错、高度220ms；模式160ms交叉及中断弹簧、固定录制停止入口均已接。横屏最大图像侧/底布局Float公式、176列门槛和48–74快门规则对应，Dock280ms有符号过渡/输入门控及先测文字后布局已有生产实现。
- 阅读Android方向边界测试和Swift布局、偏好、拖动、模式过渡、槽位动画、横屏布局/Dock用例；现有测试不能覆盖真实传感器未知方向、后台及新方向排队，也没有证明红框宿主正确。本轮未运行测试、未查看新增截图或做触摸/旋转实测。
- 撤回T05（完整隐藏副作用仍缺F167），T11已在C25撤回；1.91历史记录7/26→6/26，1.93仍1/15、1.94仍2/3。公共系统触摸/阴影仍集中C29，不另造已批准平台例外。继续C28设置。

### C28 设置、默认值与持久化（已查·有缺口）

- 对照SettingsView实际入口、RootView语言/主题/常亮、TransferStorageMode/AutoTransfer等已查消费者及安卓SettingsScreen/TransferViewModel恢复写入、AppLocale；新增F173/F174。照片加载范围/评级失效、效果草稿和独立目录已有F018/F029/F088–F105，不重复登记。
- 默认3列、连拍合并开、轻点传输、触感/常亮开、系统主题语言、缺省毛玻璃/废旧皮肤迁移钛合金、存储三档与实时传输五档旧值迁移已有接线；Liquid Glass为既有明确iOS选择，不按安卓缺失判漏项。反馈复制号码仍有入口，提示形式在公共UI核对；检查更新按B17排除。
- 阅读DomainModel皮肤/列数恢复断言及既有AutoTransfer/存储策略测试；没有以偏好helper证明真实页面生命周期。全局常亮与语言回退缺生产场景测试；本轮未运行测试、未操作系统设置或文件目录。主题/三语逐字核对继续C29。
- 当前记录仍1.91 6/26、1.93 1/15、1.94 2/3；C29将统一纠正T25的资源键覆盖即完成声明。

### C29 公共 UI、触感与三语（已查·有缺口）

- 对照公共拨轮实际事件/绘制、按钮材质/按压/投影、Genie几何及捕获宿主、灯泡/提示和资源实际调用，确认F175–F180。T24旧系统投影遗留已有明确注释及N09证据，本轮正式登记；不因纹理/数学模型有参考测试宣布系统绘制一致。
- 只读脚本以当前Android XML逐键比较AndroidLocalization.byResource（按iOS实际解码换行，Android正常解码撇号）：简中673键/17处文本不同，英文673/25处，繁中669/17处；每种2个缺键均为已排除损坏诊断transfer_temp_source_error、transfer_final_verification_error，不记普通功能缺口。差异总数含更新/激活排除项，不直接当问题数；已抽取生产仍引用的F178例子。此为源数据比较，不是执行App测试，未声称完整像素或全部动态文案通过。
- 有限已接：按钮90ms最短反馈/滚动容器延迟/取消和独立帧模型、Genie320/350ms与12绘制带/48几何及上下反射、灯泡900ms往复和红点、触感全局偏好及开关自身确认例外、渐强脉冲缩放/取消/完成避免双确认。新统一监看提示已有单nonce/计时器、160/200ms与中断规则、横竖锚点/两行测绘/触摸挡层；保留其他线程原测试记录，不将其说成本轮运行。离页录制失败提示F146仍未修复。
- 阅读ReleaseCommitWheelTest与Swift Haptics、模式过渡、现有Genie断言定位和RemoteMonitorHint规则/生命周期用例。没有把逐行读取helper等同真实手势/绘制验证；公共系统阴影/触感基准和三语全场景仍需集中验收。本轮未运行测试/截图/构建。
- 撤回T25整体收口声明，1.91历史记录6/26→5/26（T01/T02/T07/T08/T26保留限定历史范围）；1.93仍1/15、1.94仍2/3。当前审查29/32，继续C30额度。

### C30 免费额度与权益门控（已查·静态一致，仅额度核心）

- 对照安卓LicenseManager、TransferViewModel唯一完成计数点和RemoteScreen的ready计时，与iOS FreeUsageStore、RemoteUsageMeter、PremiumAccess、TransferQueue、RemoteViewModel和PhotoListView的生产调用。每日25次、单文件400 MiB（大于才拦）、180秒、剩余5/1提示、原片成功才计数、已有原片/完整临时文件捷径不计数、失败不计数、跨日持久化和重复完成防重均有接线；不把F058错误重用失败part另算额度问题。
- iOS按单调时钟计时、午夜分摊、前后台停计、权益失效截止及续期重排已有实现；首次就绪前不扣时间。失权触发录制停止保存；达到试用额度等待停止后退出。所有已入队任务使用原水印快照，重试不重新计算，新任务使用当前权益，遵守用户优先规则。
- 阅读PremiumEntitlementTests的跨日/幂等/5与1边界及PremiumBusinessTests的失败/跳过/400 MiB/快照/迟到授权、到期/恢复/后台/午夜用例；仅静态核对，本轮没有运行。真实录制错误和输出安全仍有F141–F146，效果编辑器免费/高级联动仍有F091–F097，不能由额度核心一致推断全部权益相关行为正常。
- 未新增已确认缺陷；StoreKit自动同步的历史待证独立归C31/R01，真机前后台/跨日/失权录制仍应集中验证。台账计数保持1.91 5/26、1.93 1/15、1.94 2/3。

### C31 苹果内购（已查·平台例外，交付遗留保持未完成）

- 完整追踪StoreKitPurchaseStore、PremiumEntitlement、PremiumPurchaseView和App启动：商品类型/年度周期校验、苹果本地化价格及月均价、交易和续订签名验证、先交付后finish、pending/取消/失败、unfinished补交付、恢复购买、优惠码、订阅管理、退款/撤销/到期、实际宽限截止与永久优先均有实现。未引入安卓激活码、设备指纹或授权服务器；查询失败不凭空延长旧权益。
- 年费转永久有购买前提醒及购买后管理入口；没有自动替用户取消年费。当前年度是否已取消未知时仍保留管理，不以未知当已取消。不把16天商业配置硬编码成App本地赠送期。购买页继续使用年度总价/每年收费说明与月均价，符合用户决定。
- 阅读StoreKitPurchaseTests实际的恢复、取消续订、商品/恢复网络错误、状态空集合、年转永久及宽限/扣款重试用例，结合既有进度清单保留R01：同进程重建10秒仍未自动恢复、年转永久刷新暂时回退的历史失败尚未闭环。用户接受约一秒同步延迟；这两条观察不是两个已证实生产缺陷，也不能因模型有代码就写成通过。登记V008，后续应验证App自己恢复而非测试主动重查替它恢复。
- R02正式签名/商品后台、R03隐私与条款HTTPS地址、R04实际优惠活动仍未确认；project.yml的Team为空，Info.plist/project.yml没有两个法律URL，代码只在有效地址时显示链接。本轮未访问账户、购买、兑换、修改配置或运行测试。R05旧文档“没有模块模型”已过时，改成C17的真实联动缺口；不是重写支付模块。
- 普通App scheme没有本地.storekit引用，专用StoreKit/StoreKitUI scheme才有；测试夹具存在不能当真实苹果沙盒/正式购买已验证。保留原验收状态及1.91/1.93/1.94计数。

### C32 更新、诊断/Release与源码核销（已查·有缺口）

- 用户询问更新是否无需复刻：依据高级版迁移台账B17，安卓自有更新查询、软/强制提示、APK下载/校验/安装与安装统计均不移植；iOS正式版使用App Store。App内版本提示/商店跳转若以后需要，另行设计，不把当前缺少入口算成漏复刻。
- 已检查安卓AppUpdateManager状态机及LicenseManager的/v1/app/latest、download-url、install-trigger，与iOS启动、SettingsView.footer和StoreKit入口对照：iOS无这些更新类/端点/调用；设置页为版本铭牌与反馈。AndroidLocalization及三语strings仍有更新文案，但未找到对应业务引用，不能据文案宣称已实现更新功能。
- DEBUG宿主和参数路由均有编译条件，普通Release进入RootView；模拟相机和交接测试探针亦隔离。评级/保护只读探测的UI位于DEBUG，STA限定最多4文件、256KiB头、最多12处差异及32字节属性摘要，不把内部函数存在当Release可达入口。PTP传输诊断环境开关在Release恒false。正常监看隐藏开发面板的60秒被动焦点报告及两项只读视频探测对照安卓仍保留；它们不是已排除的全量属性/能力扫描，不擅自删掉。未找到APK更新、鸿蒙专用损坏流程或自有激活服务器接线。
- 确认F181：AP信号的既有批准范围与当前签名权限配置冲突；已纠正旧AP技术文档的“当前不含权限”含义，保留当时验证为历史。源码清单末尾补核烟花，确认F182混色路径；现有截图只证明iOS优化前后保持，不是安卓对齐证据。
- 并行工作复查：F052已改为任何退出路径按ticket身份finish，已读取`/tmp/ztransfer-20261015-n01-admission-cancel.log`终态17/17、TEST SUCCEEDED，属于另一轮历史结果。F053已接整文件IDLE门槛、MONITOR_STORAGE普通排队、入场allowed回检及旧代回调隔离；读到新增MonitorStorageSchedulingTests真实两段下载、CameraIOGate等待顺序/交接、RemoteLifecycle存储等待/取消/迟到失败用例，但本轮未执行，状态记“已有修复代码，待验证”。F054真实CloseSession仍绕gate、F055评级旧owner仍无条件清新句柄，保持未完成；N01/N02不恢复完成。
- [源码与测试归属索引](iOS-全功能行为复核覆盖索引.json)记录当前693个文件及SHA-256：Android生产185（183 Kotlin+2项目C++）、测试157；iOS生产220（含项目原生裁切桥接、元数据准备、计时及开关组件）、测试126（含原生故障、元数据生命周期及设置主开关测试）、隔离StoreKit诊断2、工程配置3。逐项归入C01–C32，无未归属文件；混合大文件归多个模块。资源/三语/字体/Logo按C19/C29已有证据核对，第三方libjpeg不作逐文件业务复刻声明。**此索引是范围核销，不是逐行覆盖、测试一一迁移或测试已通过的证明**；索引生成之后的源码变化须重新核对。
- 再查`app/`相对已合入89d78b451d03e50da965a46f047744aa8a34877c无差异，未拉取或把未合入origin/android混入。32/32完成的是本轮分板块静态审查；未构建、测试、安装、提交、推送或修业务代码。1.91记录5/26、1.93记录1/15、1.94记录2/3；保留历史测试真实结果，同时撤回其不能证明的完整性声明。

## 修复与集中验证顺序

| 优先组 | 已确认问题 | 最小闭环场景 |
|---|---|---|
| 输出安全 | F056/F058、F064、F117、F132/F134、F145 | 已知大小短文件不得发布；失败part不得重用；并发重名和同秒录制保旧文件；窄边框保完整照片；截断JPEG/尾部写失败不发布且原片保留 |
| 入口不可用 | F098、F165/F166 | 实际编辑器选Cube→保存→重开→输出；监看选LUT→真实GPU展示后提交→失败回原图，禁止只测状态模型 |
| 配对与连接恢复 | F006、F010–F014、F004/F005 | 假配对/旧身份失效/丢ACK/迟到回调/连续心跳异常，恢复不依赖杀进程，写GPS时重验有效期 |
| 调度与取消 | F052/F053已有改动，F054/F055仍待修 | 准入交接取消、下载段间IDLE、真实关闭入口、评级连续关开关；验证没有遗留active/屏障及旧任务覆盖 |
| 裁切与派生 | F065–F074、F125–F135 | 原图头未准备禁止确认；EXIF方向/反复改比例/取消/离线重试；独立任务状态与水印快照、资源上限 |
| 目录与浏览 | F017–F051、F060–F063 | 扫描中改范围/删图/短断线；缓存/评级/已传/合集身份；FHD失败路径、授权变更与旧目录保留 |
| 监看及界面 | F139–F180、F182 | 拍摄录像副作用、失权保存失败、参数写前门控、焦框时效、分析开关恢复、LUT/伪色互斥、旋转中断、三语/手势/动画真实宿主 |
| 交付配置与待证 | F181、V001–V008、R01–R04 | 签名权限一致、StoreKit自动恢复、实际苹果沙盒与合法地址；平台差异必须有依据，不用静态结果代替真机表现 |

每组修复先补能暴露生产接线缺陷的最小回归，再集中构建验证；不能仅给未接入的helper增加测试。当前用户已授权按本文逐项修复，继续按项目既定规则集中构建/验证；不自动提交、推送或发布。

## 后续维护规则

- F编号固定，修复时更新状态和证据，不删除原始问题；同一问题跨模块引用，不重复计数。
- 有修复代码、测试已通过、真机已验收分别记录；未运行保持明确，已批准例外不再当漏复刻。
- 新安卓合并或iOS工作树变化后重核受影响模块及覆盖索引；本次662文件归属不代表后续版本自动通过。

### F067快照文本边界（2026-10-16）

- 对照安卓`PhotoMetadataSnapshotBounds.kt`及全部两项测试，在`PhotoFrameMetadata.boundedForQueue`实现每字段256 UTF-16单位边界；边界高代理项移除，避免截断emoji。机身、镜头、焦距、曝光文本、日期及城市/地区均覆盖，坐标/海拔保持；曝光补偿沿用安卓不截断的字段规则，iOS没有address字段。
- `cameraSnapshot`在产生任务快照前应用边界，`makeFrameReady`再统一约束缓存、任务保留值和计算recipe，覆盖非相机快照输入。
- `/tmp/ztransfer-20261016-f067-bounds.log`为72/72、TEST SUCCEEDED（文本边界2、下载38、队列32）；真实ImageIO JPEG超长机型经过生产下载/交接后，渲染与任务保留值均为255个a、无二次相机读取，`/tmp/ztransfer-20261016-f067-bounds-production.log`为1/1、TEST SUCCEEDED。
- F067仍未完成：完整性状态、有界扩读、无EXIF缓存、256项LRU及原始头预算尚待实现；F066独立parser仍未完成。修复核销数保持18/182，未真机验证、未提交/推送。

### F067完整性、扩读及结果缓存（2026-10-16）

- 对照`JpegMetadataHeader.kt`、`PhotoMetadataPreparation.kt`及其全部测试、`TransferViewModel.parseCameraFrameMetadata`及merge规则，新增结构判定和COMPLETE／NO_EXIF／PARTIAL／FAILED结果。XMP不冒充EXIF；缺字段不代表截断；段长度/扫描边界/坏标记及Data非零索引均验证。
- 捕获头不完整时从1MiB开始补读，无捕获头从256KiB开始，最多升至2MiB；每次保持来源身份校验及backgroundThumbnail准入。`TransferDownloading`→`CameraSession`→`CameraRepository`的maxBytes已贯通，仓库限制上限2MiB。较大读取失败/空返回保留已有字段但结果标FAILED；纯函数合并覆盖空白字段和坐标保留。
- 结果缓存按访问顺序限制256项，缓存NO_EXIF及最终PARTIAL，FAILED不入缓存；不再每次下载run清空，关闭生成时清空。任务自己的来源快照仍独立保留，缓存不会改绑新相机。
- `/tmp/ztransfer-20261016-f067-expansion.log`为102/102、TEST SUCCEEDED（下载41、调度19、身份5、文本2、结构/缓存/合并3、生产队列32）。真实JPEG在5段APP2之后才出现EXIF，下载捕获头不完整后实际请求1MiB并成功生成；无EXIF实际首次读取后重试不再请求。
- `/tmp/ztransfer-20261016-f067-expansion-cap.log`为1/1、TEST SUCCEEDED：真实生产相机通路依次请求256KiB/1MiB/2MiB，始终不完整后结束；重试复用最终PARTIAL，没有第4次读取，原片保留。ImageIO对截断fixture输出解码诊断属于预期，测试无失败。
- **F066／F067均不核销，保持18/182**：捕获头当前仍在run内`PreparedPhotoMetadata.parse`同步解析，独立parser、2MiB内存/16MiB磁盘spool预算及同键pending请求共享未完成。当前补读仅保留小结果跨下一次await；并未验证真机内存压力、进程退出或所有异常清理。未提交/推送。

### F066／F067独立解析与有界准备闭环（2026-10-16）

- 新增`PhotoMetadataPreparation.swift`集中结构解析、结果合并/LRU与头文件所有权；`run`只传捕获头给交接入口，不再同步解析。身份、捕获头parser和相机补读各用一个consumer；两种来源的实际解析共用`PhotoMetadataParser`串行actor。等待任务持有轻量recipe/已解析快照，容量继续沿用4096共享准入，不为每份等待数据创建挂起Task。
- `PhotoMetadataHeaderStore`默认2MiB内存、16MiB磁盘暂存；溢出只允许等待实际spool写入，预算耗尽以FAILED结束准备，原片保留。ticket最后引用释放时扣回预算并删自己的文件；关闭拒绝新ticket、立即释放等待项，活动parser/写入保留文件到自身结束，迟到结果不再发布。此预算是待解析头保留量，**不是全进程RSS上限**；解析器当前输入及相机正在接收的响应另有有界生命周期。
- 专用目录按进程UUID及队列UUID分层；后台清理只删除旧进程目录，不删同进程另一个队列的活跃文件。目录删除使用空目录`rmdir`，避免递归删除活动文件。失败写入会撤销预留，修复文件系统障碍后可重试。
- 同一来源key共享准备及失败结果；后续独立重试仍可重读FAILED。cache/pending命中优先于本次头预算失败；每个等待者持有独立任务/输出目录授权，某一生成失败不会吞掉其他等待者。
- 第一轮生产接线回归`/tmp/ztransfer-20261016-f066-parser.log`103/103通过。最终集中`/tmp/ztransfer-20261016-f066-parser-serial-fixed.log`109/109、TEST SUCCEEDED：包括既有慢补读/快捕获、来源身份、真实下载扩读、重试缓存、后台通道以及新预算/关闭测试。
- 必须保留失败与证据修正：`parser-ownership.log`共享重试夹具没有稳定来源身份导致1失败；`parser-ownership-fixed.log`夹具未覆盖带身份重载导致3失败；`parser-serial.log`新增夹具漏await编译失败。补强`parser-boundaries.log`2失败发现单批入队去重，使早先共享测试实际只有一个任务；因此109项中的旧共享测试**不作为双等待者证据**。现改为两次独立入队并断言2个任务，最终`/tmp/ztransfer-20261016-f066-parser-boundaries-fixed.log`8/8、TEST SUCCEEDED，覆盖真实双等待共享失败/失败不缓存、一个渲染失败另一个成功、默认2MiB+16MiB预算、超额拒绝、写入失败释放/恢复、旧目录与同进程保护、解析阻塞时后续下载、关闭活动/等待spool释放及迟到隔离。
- **F066／F067开发侧核销，当前20/182**。新源/测试纳入索引，共666文件；XcodeGen相对调用前工程仅增加新源/测试引用，保留既有未提交修改。未实际杀进程、未测真机内存压力/外部Provider，未提交/推送；F068计时及其他未完项继续保留，不恢复旧版本整项完成记录。上文18/182及F066/F067未完成描述均为各阶段历史。

### F068计时第一阶段：普通生成与单调展示（2026-10-16）

- 已对照安卓TransferTask的queue/start/pause/finish及TransferStateTest计时测试、launchPhotoFrameExport的实际计算/完成和TransferScreen的200ms显示。新增`PhotoGenerationTiming.swift`，以ContinuousClock进程内起点提供同一毫秒域；准备与排队仅设busy、不启动计时，计算worker取得槽位后才启动。任务快照不再保存Date起点。
- 普通效果生成只有本次render成功返回保存结果才保留完成耗时；失败、取消未保存、复用已有派生图均不展示完成耗时。保持原有独立失败行为，本阶段没有借机改F071整卡状态。UI刷新仍200ms，但不再用Timeline提供的墙钟日期计算时长。
- queue/start/pause/finish与显示规则移植为集中任务状态方法：暂停累计已运行片段但隐藏运行秒表，再次开始保留累计；无活动任务的finish不覆盖已记录耗时。**暂停累计目前只验证状态模型，裁切生产接线尚未完成**。
- `/tmp/ztransfer-20261016-f068-clock.log`85/85、0失败、TEST SUCCEEDED：下载42、生产队列32、准备流水线7、计时状态4。实际生产注入单调时钟：元数据准备推进5000ms而生成500ms，终值500ms；第一计算占5000ms、第二等待后计算500ms，终值分别5000/500；生成失败及worker时发现已有图均无完成耗时。单位模型覆盖裁切200ms→等待3800ms→生成300ms累计500ms与重复完成保护。
- **F068仍未核销，保持20/182**：安卓裁切与效果属于同一计算任务，iOS三条裁切路径仍在下载worker内（F072）；不能只给当前裁切调用包计时而将准入等待误算进去。下一步结合F072完成原片发布即交接、裁切计算与metadata等待暂停，再核F068。未实际修改系统时间/真机验收，墙钟独立性由UI实际调用链和注入单调值验证；不可宣称已做真机校时测试。索引新增源/测试至668项，未提交/推送。

### F072裁切交接／F068裁切累计阶段（2026-10-16）

- 再读安卓`launchPhotoFrameExport.execute`与`submit(ready, runWhilePreparing)`确认：效果总开关开启时先等metadata，再计算裁切与效果；只有总开关关闭允许未准备任务执行，若裁切过程中重新开启且metadata仍未就绪，才pause/defer/resume。不能把所有裁切提前到metadata之前。F069尚未实现，因此F068该动态边界保留未完成。
- iOS本地原片、完整part恢复、新下载三条路径现在先记COMPLETED/outputURL/下载指标，再交给已有4096容量、单utility生成worker；`run`不再调用`processCrop`。新下载elapsed/MBps在任何裁切前计算；原片发布后额度记录仍只发生一次。无需相机metadata的裁切/普通效果直接就绪，不额外等待相机身份查询。
- 生成worker统一处理原片→裁切（或复用已保存cropURL）→效果，效果名和输入均基于裁片。裁切与普通效果共享同一计算名额；目录lease由FrameJob持有。保存裁片先记录URL再检查取消，重试不重复裁切；清理crop草稿在成功后执行。裁切失败或效果失败保留原片；普通无裁切本地效果的旧failTaskOnError行为仍归F071，不在本项宣称已修复。
- F068正常路径现在累计裁切与效果时间；只有实际保存派生结果才保留完成耗时。即使效果失败，只要本次裁切已保存仍有生成耗时，与安卓frameExportSaved一致。
- `/tmp/ztransfer-20261016-f072-handoff.log`85/85、TEST SUCCEEDED；更新原真实native裁切发布后取消测试：原片现在已完成，不能再期待WAITING或重启下载，仍验证发布URL/原片完整且不重复启动。`/tmp/ztransfer-20261016-f072-routes.log`42/42、TEST SUCCEEDED，覆盖三路首张裁切挂起时第二张原片已完成、下载指标前后不变、metadata等待5000后裁切200+效果300只记500、效果失败后重试只裁一次。
- 完整part分支只允许视频，这是F058既有安全规则；本轮该分支测试使用MOV对象与注入crop renderer作生命周期夹具，**不代表真实视频可裁成JPEG**，没有放宽照片resume规则。实际native JPEG发布/取消回归仍单独经过原有测试。
- `/tmp/ztransfer-20261016-f072-lifecycle.log`12/12、TEST SUCCEEDED：补强混合crop/普通效果确实串行（后者等待期间不计时），关闭只允许活动裁切完成自己的发布/URL记录，等待裁切不运行，两份原片均保留。以上集中批次有重叠，不相加宣称独立测试总数。
- **F072开发侧核销，当前21/182；F068保持进行中，下一步结合F069的运行期总开关验证裁切后pause/defer/resume**。未真机/外部Provider/系统校时验收，未提交/推送，索引仍668。上节“F068等待F072”的说明为当时阶段，当前剩余依赖按本节。

### F069运行期核心／F068暂停计时闭环（2026-10-16）

- 对照安卓`setPhotoEffectsEnabled`、`PhotoGenerationQueue.runWhilePreparing`、`launchPhotoFrameExport`及TransferScreen标记规则。队列默认从`photo_effects_enabled`读取（缺省true），运行期setter只更新门控并重审等待项；后续设置store负责写偏好，避免把非Sendable UserDefaults长期持有到actor。
- 新增`frameGenerationSkipped/cropEffectsSkipped`：普通任务在被选中时关闭则跳过；计算槽位取得前关后再开仍用原recipe；已经开始的普通导出继续。裁切不因关闭而取消，裁切完成时再次看总开关，关闭则标仅跳过效果。队列卡片使用安卓现有“跳过”“裁切”“照片效果已跳过”资源，纯裁切也有生成耗时入口。
- 准备中任务允许在总开关关闭时选中。裁切时重新开启且metadata仍未返回，暂停累计、释放计算slot、保留原入队顺序；metadata就绪恢复时复用cropURL并继续效果，不重裁。关闭等待队列时，已保存裁片保留已有累计耗时，不将等待时间写入。
- 独立`preparingFrameIDs`容量与生成容量同为默认4096：生成跳过释放了计算准入，尚未完成的相机准备仍占准备容量；新任务不会绕过该上限形成无界补读队列。已跳过任务的准备结束仍可写入结果缓存，但不能重新启动任务。
- `/tmp/ztransfer-20261016-f069-runtime-isolated.log`52/52、TEST SUCCEEDED（计时4、准备/门控16、队列32）：普通活动/等待切换、重新开启保留recipe、禁用后仅裁切、crop200→开启后metadata等待5000→effect300总500、等待中关闭总200且迟到结果隔离、准备容量独立限制均覆盖。`/tmp/ztransfer-20261016-f069-download-regression.log`42/42、TEST SUCCEEDED，验证新准备生命周期未破坏真实下载/来源/扩读/缓存。
- 保留中间失败：`f069-runtime.log`及`f069-runtime-fixed.log`均为测试默认值对象从MainActor传入actor初始化的Swift6隔离编译失败；除移除queue持有UserDefaults外，最终将测试helper改为返回suite名称、在调用处创建独立实例，才完成验证。未修改用户standard偏好来跑门控测试。
- **F068开发侧核销，当前22/182。F069仍未完成**：`PhotoEffectsStore`独立总开关偏好、RootView到queue的变化传递、SettingsView卡片开关（48×32触区、36×20轨道、14直径thumb、180ms FastOutSlowIn位置/Oklab颜色动画与RTL）、入口手势和持久化测试尚未接线。不能据backend API测试宣称设置页已可用。下一轮从此处继续，编辑草稿与本地照片作用域不可被总开关改写；未真机/系统校时/提交/推送。索引仍668。

### F069设置端与交互闭环（2026-10-16）

- `PhotoEffectsStore.isEnabled/setEnabled`单独读写安卓同名`photo_effects_enabled`（缺省true），不混进PhotoEffectsSettings编码、编辑草稿或模块配置。仅cameraTransfer作用域可写，本地照片store始终保持独立；关闭/重启/重新开启不会清空原recipe或水印。RootView用`.task(id: effectsStore.isEnabled)`把最新状态传给队列，旧任务取消由队列setter检查，不让迟到旧值覆盖新值。
- SettingsView效果卡片新增独立开关与保留的编辑入口，避免嵌套Button；关闭仅改变总门控及卡片边框强度（启用且存在效果0.56，否则0.30），摘要仍展示原配置。标题/摘要/箭头继续进入编辑，开关点击仅切换并tick。开关用Toggle的accessibilityRepresentation提供Switch语义；布局48×32触区、36×20轨道、14直径thumb、RTL反向，按安卓180ms默认tween移动/变色。
- 将原RemoteHorizonColorAnimation抽成`ZTransferColorAnimation`，默认160ms保持水平仪行为，主开关使用180ms；四分量Oklab向量、打断时从已显示打包颜色继续的规则不变。位移沿用ZTransferScalarAnimation的Compose FastOutSlowIn及打断语义，不使用系统默认开关动画。首次显示直接落在当前值，离开页面停止display link。
- `/tmp/ztransfer-20261016-f069-settings-fixed.log`25/25、TEST SUCCEEDED：偏好缺省/恢复、recipe编码未被重写、本地作用域不改全局、180ms端点/中点、RTL、动画中断及换色、既有水平仪参考（含64组颜色向量参考）与运行期流水线回归。首次`f069-settings.log`因一个旧测试引用抽取前类型名而编译失败，已更新为共用类型，失败日志保留。
- `/tmp/ztransfer-20261016-f069-settings-ui.log`1/1、TEST SUCCEEDED，真实SettingsView＋PhotoEffectsStore的DEBUG隔离宿主验证Switch存在、48×32可点击框、点击开关不进入编辑、设置传递后配方仍开启、编辑返回不改变总开关、重启后仍关闭且配方保留。生产RootView传递代码已静态核对；此UI测试使用同样传递方式的隔离宿主，不声称真实相机工作区端到端验收。
- 已导出并查看关闭态截图`/tmp/ztransfer-20261016-f069-settings-ui-attachments/A5C9B5A1-729A-408F-BC0E-B2CA51569050.png`：开关与右侧箭头、标题和两列摘要无重叠；现有照片加载范围英文页中文标签属于其他文案复核范围，本项未改写。没有新增Release页面；隔离宿主及路由均在DEBUG条件内。
- **F069开发侧核销，当前23/182，索引673项**。本轮新增共用颜色动画、开关、DEBUG设置宿主及两类测试文件；未真机验证，未提交/推送。下一步按文档继续F070派生独立重试及F071本地原片效果失败状态，不能据这一组通过宣布整体完成。


### F071 原片成功与派生失败隔离（2026-10-16）

- 安卓依据：TransferViewModel.kt 的 FrameExportOutcome.Failed 和生成 complete 异常回调仅设置 frameGenerationError，已发布原片保持 COMPLETED。
- iOS 删除 FrameJob、两层生成入口和本地命中／完整part调用中的 failTaskOnError 参数及整卡失败分支；统一保留原片下载状态、error和速度记录，仅写 frameError。没有新增UI或动画。
- 纠正 CameraDownloadTests 中元数据缺失、不同相机重试、保留来源快照，以及 TransferQueueScenarioTests 中已有原片编码失败的旧错误断言；明确验证 COMPLETED、原片存在、下载error为空和派生错误独立。已有新下载失败测试继续通过。
- 验证：`/tmp/ztransfer-20261016-f071.log`／同名xcresult，CameraDownloadTests 42、PhotoMetadataPipelineTests 16、TransferQueueScenarioTests 32，共90/90、0失败，TEST SUCCEEDED；git diff --check通过。未真机验证，未提交／推送。
- F071开发侧核销，当前24/182。F070仍未修复：当前retry仍依赖当前目录并经过下载队列；不能以同目录离线重试通过当作独立重试完成。下一步保存原始root/parent/source及授权生命周期并对照安卓newAttempt分派。


### F070 独立派生重试（2026-10-16）

- 对照安卓canRetry/newAttempt/dispatchRetryAttempts：保存生成source/parent/root URL，每次重试重新获取旧root授权，生成新ID并直接进入生成队列；保留COMPLETED、下载指标、metadata和裁片，清空生成错误和计时。单条批量共用规则，运行中不可重试，移除卡片清理位置记录。
- 新测试覆盖单条/批量 × 清空/切换当前目录四组：真实队列下载至ZT-JPG子目录，下载中暂停并留下第二个WAITING任务，离线重试仍输出原目录，下载指标不变，等待任务不启动，新目录无文件。注入scope验证生成中授权有效及结束释放；metadata跨不同相机测试改当前目录nil，仍不查询新相机。
- f070-fixed.log及同名xcresult：下载42、metadata16、队列33，共91/91，TEST SUCCEEDED。f070.log测试误在空闲时暂停导致四次断言失败；f070-boundaries.log测试参数顺序编译失败，均保留。最终diff检查通过。
- 开发侧核销25/182，未真机Provider、未提交/推送。F073页面离线启动及F077重试按钮资格仍未完成，下一步继续F073。


### F073 手动离线启动接线（2026-10-16）

- 安卓依据TransferViewModel.addToQueue/startPendingTransfers允许cameraProvider返回空，worker先查本地原片；addNewMediaToQueue仍明确要求连接。
- iOS手动单张/批量及裁切ViewModel入口仅需目录即可启动，显式start接受可空session；PhotoListView队列启动按钮传transferSession可空，裁切回调移除额外isSessionConnected要求。延后裁切仍通过nil目录仅入队，明确启动时释放暂停。自动新增入口连接限制保留。
- 新测试从实际TransferQueueViewModel发起单张/批量×立即/延后四组，已有本地原片离线完成；另两组使用真实JPEG及生产裁切器，验证立即/延后启动均保存裁片且原片字节不变。页面单张、组、预览、裁切与启动按钮调用静态核对，未运行实际页面UI交互，不声称全页面端到端通过。
- `/tmp/ztransfer-20261016-f073.log`及同名xcresult：TransferQueueScenarioTests35、AutoTransferModeTests10，共45/45，TEST SUCCEEDED；diff检查通过。开发侧核销26/182，待真机，未提交/推送。
- F034离线缺原片的整批拒绝、F130裁切accepted反馈、F075启动按钮显隐仍未修复；不能将本项当完整离线体验核销。下一步处理F034及关联准入。


### F034 准入与信号强调第一阶段（2026-10-16，未核销）

- 安卓依据FileListScreen.kt:1274–1342、1549起：当前existingExportIndex和storageMode判断原片，断线且批次任意缺失则整批拒绝，signalPulse及camera_not_connected提示。
- PhotoListViewModel新增当前目录/存放方式的整批原片索引检查，不以handle或已传ID代替来源身份。页面单张、日期组、预览单张/连拍组统一在入队/震动/飞行之前检查；连接恢复可正常准入，缺目录仍路由设置。裁切accepted协议留F130。
- 信号强调使用现有Compose标量引擎：1→1.15，120ms FastOutSlowIn，再400/0.5弹簧回1，独立乘在呼吸上；连续触发从显示值中断，离页停止并复位。未新增文件。
- 首轮f034-admission.log共41项，队列35通过，身份6中1失败：测试typed原片遗漏destinationFolderName，被既有索引正确拒绝。补测试任务ZT-JPG后f034-admission-fixed.log为6/6 TEST SUCCEEDED，含原片身份/大小/存放目录/混合批次/断线重连/空目录/清目录及动画时序中断。首轮失败保留，不能称41项单轮全绿。
- 新发现反馈仍未完整：现有remoteEntryHint位于监看入口、在previewOverlay下，会被预览遮住；安卓底部通用提示在预览上方，bottom28、padding20/10、圆角22、阴影6及fade+半高slide。下一步独立实现该提示并接拒绝反馈，检查保留文本退场与1800ms最新消息计时，补真实页面交互/截图。F034保持未完成，计数26/182不变。

F034第一阶段Debug模拟器构建：/tmp/ztransfer-20261016-f034-build.log BUILD SUCCEEDED；simctl install与launch成功。仅启动主App，不作为信号动画或预览提示的页面验收；F034保持未完成。


### F034 底部拒绝提示（2026-10-16，仍未核销）

- 新PhotoListHint独立放在previewOverlay及queueFlightOverlay之后，拒绝提示不再使用监看入口旁的remoteEntryHint。没有改其他提示来源。
- 对照FileListScreen.kt:2227起：bottom28、安全区内底部居中、圆角22、padding20/10、labelLarge14/20 medium、深浅glassSurfaceHeavy及1dp边框。文本保留到退出完成；默认1800ms消息计时，重复消息重启deadline，后消息替换前消息，离页取消。
- fade与半高slide使用共用Compose计算器spring400，alpha阈值.01、IntOffset阈值1；物理像素半高整数截断与offset取整，进退场中断保留值/速度；首次测量或首帧前换行高度变化按实际高度更新。默认动画参考[AndroidX EnterExitTransition源码](https://raw.githubusercontent.com/androidx/androidx/androidx-main/compose/animation/animation/src/commonMain/kotlin/androidx/compose/animation/EnterExitTransition.kt)，未使用SwiftUI默认动画代替。
- f034-hint.log及补高度边界后的f034-hint-height.log均8/8 TEST SUCCEEDED；f034-hint-ui.log1/1 TEST SUCCEEDED。UI使用真实PhotoPreviewView与新提示host，DEBUG拒绝回调模拟离线拒绝，验证上滑后提示存在、自动退场且预览仍开；不把模拟回调说成完整PhotoListView准入验证。截图已查看：/tmp/ztransfer-20261016-f034-hint-ui-attachments/B6DAEF5F-1240-49CF-A465-71E18CFD2891.png，提示确实在预览按钮上方绘制。最后高度细化后未重复UI，已跑8项单测。
- 明确未完成：Surface6dp安卓投影尚未实现，不用近似阴影冒充；完整列表单/组/预览混合批次与拒绝不飞行/不入队尚缺真实页面验证。F034继续未核销，26/182不变。覆盖索引新增生产文件后674项。

F034提示阶段最终Debug构建f034-hint-build.log BUILD SUCCEEDED，simctl install/launch成功；构建已结束，未真机/提交/推送。


### F034 真实列表准入交互（2026-10-16，未核销）

- 新DEBUG PhotoListAdmissionHarness使用真实PhotoListView/ViewModel/queue/提示与预览回调，仅注入两张目录数据、debug相机会话和权限操作。一张本地原片、一张缺失，suite隔离AppStorage；未调用会写用户filter偏好的setFilter。PhotoListView新增可选模型注入与无障碍ID，Release默认路径保持原模型构造。
- f034-list-ui.log首次因StateObject autoclosure捕获初始化self编译失败；改用局部queue后f034-list-ui-fixed.log2/2通过。补飞行计数和真实预览后最终`/tmp/ztransfer-20261016-f034-real-list.log`及同名xcresult为3/3 TEST SUCCEEDED。
- 实际触摸验证：断线缺原片单张拒绝、混合日期组整批拒绝，count=0且flights=0/held=0；已有原片离线立即完成；重连后缺原片按延后偏好WAITING；从真实列表打开预览并上滑拒绝，提示可见、队列/飞行无残留、预览仍开。截图已看：/tmp/ztransfer-20261016-f034-real-list-attachments/93D56802-01B5-4F2B-A021-B418DFB6CA07.png。
- 此测试未覆盖真实相机/Provider，也未覆盖折叠连拍合集交互；下一步补合集准入，Surface6dp投影需与F179/T24公共系统投影一起处理。F034保持未完成，26/182不变；新增DEBUG生产宿主后索引675。未提交/推送，所有xcodebuild进程结束。


### F034 连拍合集交互与公共投影依据（2026-10-16）

- DEBUG目录扩为真正可分组三张（同秒、连续编号），支持只存一张／全部本地。真实折叠合集列表plus，以及长按进入预览→收起为合集→传输整组，四组合验证部分缺失整批拒绝且count/flight/held为0，全部原片存在时3张完成。
- f034-burst-ui.log首次找不到按钮：外层photo-cell ID传播覆盖了内部plus ID。已将普通照片ID下移到照片，连拍图片和plus各用独立ID。f034-burst-ui-fixed.log为1/1（内部四组）TEST SUCCEEDED；标识调整后的普通列表、重连、预览回归f034-cell-id-regression.log为3/3 TEST SUCCEEDED。失败日志保留。没有改连拍分组算法或操作语义。
- 这批页面交互已提供F034各入口证据；未真机Provider/相机，仍不能把整项核销：提示Surface6dp投影尚缺。接下来处理F179/T24公共投影，再回来核销F034，当前26/182不变，索引675。未提交/推送，所有构建结束。
- 投影调查入口已确认：应用Theme.Material.NoActionBar，target/compile SDK35。AOSP [Android15 ThreadedRenderer](https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/android-15.0.0_r1/core/java/android/view/ThreadedRenderer.java)从主题获取光源，X按显示宽度/窗口位置，Z按最小屏幕尺寸加权；[默认dimens](https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/android-15.0.0_r1/core/res/res/values/dimens.xml)为Y0dp、Z500dp、radius800dp，ambient .039、spot .19。这些是AOSP默认，尚未核对Material覆写和厂商资源，不能当成所有设备固定值。
- [HWUI ReorderBarrierDrawables](https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/master/libs/hwui/pipeline/skia/ReorderBarrierDrawables.cpp)把轮廓、变换、Z、光源及两类alpha传给SkShadowUtils；[Skia ShadowUtils](https://raw.githubusercontent.com/google/skia/main/src/utils/SkShadowUtils.cpp)的常规路径是顶点网格+Gaussian颜色过滤，blur仅回退。不能把高斯模糊回退当作全部Surface实际模型。此两份为main/master调查入口，实施前仍需固定Android15对应Skia版本，核对GPU圆角快捷路径、opaque/transparent occluder、像素密度与颜色alpha量化，并建立原始实现参考输出。此处仅调查，未新增投影实现或声称像素一致。


### F179 公共投影参数与原始参考（2026-10-16，未核销）

- 固定平台源码为android-15.0.0_r1，不再用Skia main作为实施参考。已下载/阅读SkDrawShadowInfo.h、SurfaceDrawContext.cpp drawFastShadow、ShadowRRectOp.cpp；Material主题文件未发现lighting覆写。临时源码在/tmp/ztransfer-shadow-android15；不把版本选择当所有厂商渲染一致。
- 新ZTransferAndroidShadowMetrics用Float设备像素计算ambient outset/blurWidth、spot outset/blurWidth/scale/translation及128项A8 falloff。明确blurWidth是Skia参数，不是CALayer模糊半径。生产绘制尚未消费这些参数，旧按钮投影仍未替换，提示6dp阴影仍缺。
- 新NativeTests/generate_shadow_reference.py固定[Skia头文件](https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/core/SkDrawShadowInfo.h)SHA a297b6bbdb464a51a18a1343f0978bee1663e9df1340bc3a3ffa666c71badee3、[ShadowRRectOp](https://android.googlesource.com/platform/external/skia/+/android-15.0.0_r1/src/gpu/ganesh/ops/ShadowRRectOp.cpp)SHA 197766680a70cf54dfb2ad05beeb8ffb0c28a9b2f1b91838be46f400b9b97215。提取未经改写的metrics namespace函数体及falloff循环，C++标量/type shim编译执行，生成Fixtures/android15-shadow-metrics.json；不是从Swift实现反推期望值。附Skia BSD许可证。
- `/tmp/ztransfer-20261016-f179-metrics.log`及xcresult：2/2 TEST SUCCEEDED，24组projection及128字节全部一致。falloff生成器随后由逐行转录改为原循环直接提取，重新生成并与已通过的测试bundle数据逐值比较，24行和128字节相同；之后源码只补许可证注释，未重复无关回归。未验证最终GPU/CPU绘制像素。
- drawFastShadow有矩阵/轮廓前置条件：非倾斜Z、保持矩形且相似变换、矩形/圆/简单圆角；环境和点光分别构造outset轮廓，opaque/transparent改变inset，圆角op还分fill/stroke/overstroke。这些几何/插值/纹理采样及非快捷路径尚未实现。下一步按固定源码补圆角网格及falloff采样参考，再接公共渲染和6dp提示，不能用一次blur替代。
- 新增生产1、单测1、原生参考脚本1，索引678；fixture与许可证作为资源不计源码数。F179/F034均未核销，当前26/182。未真机/提交/推送，所有构建结束。

### F179 圆角投影网格（2026-10-16，未核销）

按固定 `android-15.0.0_r1` 的 `ShadowRRectOp.cpp` 补充非圆形圆角矩形网格：保留 fill/stroke/overstroke 分类先于 umbra 尺寸限制的顺序、每角六顶点、加厚描边四个内顶点，以及原始三角形索引。所有坐标和阴影参数仍为 Float 设备像素。无效/空几何返回 nil；圆形采用独立八边形路径，尚未实现，不能调用本路径冒充圆形。

原生参考生成器从已校验 SHA 的 Skia 文件直接提取原构造计算块、顶点函数和索引表，用最小类型适配编译执行。54 组覆盖半径 0/4/20、blur 2/12/60、inset 2/16/36/40/41/100，含半高边界、超过半高、umbra 超出半高及非零坐标；Swift 对照全部顶点位置、offset、distanceCorrection、分支及索引。`/tmp/ztransfer-20261016-f179-mesh.log`：3/3、0 失败、TEST SUCCEEDED，包含已有参数与 128 字节 falloff 回归。

另已核对同版本 `GrShadowGeoProc.cpp`：插值参数计算 length，再以 correction*(1-length) 作为横向纹理坐标，A8 LUT 使用线性采样。尚未实现采样及实际渲染，不将几何一致当作像素验收。圆形、非快捷路径、生产 Surface/提示接线及 UI 验证仍待完成；F179/F034 保持未核销，开发侧仍 26/182。未真机、提交或推送。

### F179 圆形投影网格（2026-10-16，未核销）

补齐固定 Skia 的圆形独立路径：填充为八边形加中心点，描边为双八边形；保留上游 `0.923579533`／`0.382683432` 内环常量，不改成重新计算的三角函数值。原生生成器直接提取原始 circle 顶点函数、构造分类及索引表，60 组半径/blur/inset 包含内半径正数、零和负数，非零中心坐标，逐顶点五分量、类型和完整索引对照。`/tmp/ztransfer-20261016-f179-circle.log` 4/4、TEST SUCCEEDED，含前阶段参数、LUT、54组圆角网格回归。

另取得 Android 15 固定版 `libs/hwui/pipeline/skia/ReorderBarrierDrawables.cpp`，SHA256 `8b88d7d771e0afb0d04c41fbc1c3fc7c67e10d6fa85e72521ed589f0706a0fb1`，路径 `/tmp/ztransfer-shadow-android15/ReorderBarrierDrawables.cpp`；后续 alpha 及透明遮挡标志实现以此替代早期 master 调研依据。当前仅网格基础，仍缺实际 GPU 采样、合成/投影接线、非快捷形状及像素/UI验证；不声称页面投影已改善。F034/F179未核销，26/182。未真机、提交、推送。

### F179 Metal 覆盖率绘制（2026-10-16，未核销）

新增 `ZTransferAndroidShadowRenderer`，复用 pipeline 与 128×1 R8 LUT（对应 Skia A8），以半精度插值参数计算 length/覆盖率、归一化线性采样和 clamp-to-edge，向 BGRA8 透明目标按预乘 source-over 顺序绘制黑色阴影层。主机持有目标纹理与 command buffer；encode 不同步等待 GPU、不读回像素。顶点/索引校验和分配在开启 encoder 前完成，避免异常留下未关闭的 encoder。目前尚未从生产页面调用。

依据固定 Android15 `GrShadowGeoProc.cpp`，SHA256 `1c81bc4852f278579c2d5b122b5face5e94e474a1ec0fd67dbca7217e5fe1768`；源码暂存 `/tmp/ztransfer-shadow-android15/GrShadowGeoProc.cpp`。GPU测试直接读取渲染结果：128×8 单层/双层 LUT ramp 逐像素（量化容差2/255，跨对角线检查接缝），另验证真实圆形fill/stroke中心、边缘、外部。此为shader/网格局部验证，不是完整Android屏幕像素对照。

首轮 `/tmp/ztransfer-20261016-f179-metal.log` 6项中2项因Metal mixed float/half3构造编译失败，保留；显式转换后 `/tmp/ztransfer-20261016-f179-metal-fixed.log` **6/6、TEST SUCCEEDED**。新增生产文件，覆盖索引679，xcodegen已更新工程。仍需HWUI投影组装（坐标/光源/alpha/遮挡）、非快捷路径、页面接线及完整像素/UI验证，F034/F179不核销，26/182。未真机、提交、推送。

### F179 环境/光源投影组装（2026-10-16，未核销）

`ZTransferAndroidShadowMetrics.shadowGeometry` 已按固定 `SurfaceDrawContext.drawFastShadow` 的正向等比缩放/平移路径，组合 ambient outset/blur/inset 与 spot scale/offset/outset/inset。caster 使用本地坐标，light 明确要求设备坐标，spot 平移按原 CTM 逆变换次序处理；保留原 ambient device inset 进入 Make 后再次乘 scale 的行为。透明遮挡强制填充，不透明矩形按轴向最大偏移、圆角按角中心距离确定覆盖范围。显式保留 circle 类型，避免浮点宽高差影响八边形选择。所得几何可生成前述已验证网格。

定向测试覆盖已知 ambient 数值、光源右移90px→spot左移10px/ambient不变、透明/不透明拓扑、scale2+非零平移、circle 与零高度/退化scale。`/tmp/ztransfer-20261016-f179-projection.log` **8/8、TEST SUCCEEDED**，含原6项几何/LUT/GPU回归。此新增组装测试为边界/数值测试，尚未独立提取完整 SurfaceDrawContext 原函数对照，也未证明完整屏幕像素一致。

当前未处理负scale/直角旋转/任意路径/透视，不把它们静默近似为正向路径；还需HWUI灯光/alpha接线、页面宿主和完整像素/UI验证。F034/F179保持未核销，26/182，索引679。未真机/提交/推送，测试进程结束。

### F179 HWUI 光源与透明度（2026-10-16，未核销）

已按固定Android15 `ThreadedRenderer.setLightCenter`补AOSP Material光源：物理屏幕中心x、窗口原点扣减、min屏幕边/(450*density)的z加权、500dp高度/800dp半径。明确设备像素与density，不推断OEM或debug覆写。补`HardwareRenderer`→JNI的主题alpha字节截断及`ReorderBarrierDrawables`的caster/outline alpha乘法再截断；默认ambient为9/255、spot为48/255。outline alpha是RenderNode属性，不能直接用背景填充色的0.92/0.95代替。

依据文件位于`/tmp/ztransfer-shadow-android15/`：ThreadedRenderer.java、HardwareRenderer.java、android_view_ThreadedRenderer.cpp（来自`libs/hwui/jni/android_graphics_HardwareRenderer.cpp`）、Lighting.h/LightingInfo.h及已固定ReorderBarrierDrawables.cpp。新增AOSP-shadow-NOTICE并复用Apache-2.0许可证，xcodegen已纳入资源。

`/tmp/ztransfer-20261016-f179-lighting.log` **10/10、TEST SUCCEEDED**：横竖屏/非零窗口/密度/z缩放、主题字节9/48、node与outline各0.5→2/12、隐藏0以及无效输入拒绝；包含原投影/几何/GPU回归。仍未页面接入，需正确区分视图opacity/outline/background并避免重复衰减，验证提示位移动画的光源坐标与退出绘制。非快捷路径、完整像素/UI验收尚未完；F034/F179未核销，26/182，源码索引679。未真机/提交/推送，测试结束。

### F179 有界绘制场景（2026-10-16，未核销）

`ZTransferAndroidShadowRenderer.scene` 已串联光源/opacity、ambient/spot投影、网格和层顺序，返回窗口物理像素origin、整数画布大小及局部网格。先完成窗口坐标投影，再按两层实际顶点边界向外取整并平移；不得先把caster移到纹理原点再计算光源。零高度或零有效alpha返回无阴影，不支持/无效几何明确报错，不生成近似替代。

新GPU测试使用分数位置圆角caster、opaque与nodeAlpha0.5，分别在200×180完整窗口和实际裁切画布渲染，按origin还原后逐像素比较alpha（最大允许1/255），同时比较裁切范围之外应为0。覆盖72,000个像素位置且确保有实际非零阴影；测试另检查裁切面积小于整窗口、零高度/隐藏不绘制、负scale拒绝。`/tmp/ztransfer-20261016-f179-scene.log` **11/11、TEST SUCCEEDED**，包含前10项回归。

这是同一Metal实现的完整/裁切一致性证据，不是独立Android屏幕参考。当前尚未替换PhotoListHint或公共Surface；下一步实际宿主需按窗口origin摆放、跟随动画并避免opacity重复衰减，随后集中构建/页面UI验证。非快捷路径仍未完，F034/F179未核销，26/182，索引679；未真机/提交/推送，所有测试结束。

### F034/F179 首个页面投影宿主（2026-10-16，未核销）

新增 `AndroidShadowView/AndroidShadowHost`，底部 `PhotoListHint` 接6dp/22dp圆角投影。窗口/屏幕坐标在layout中采集，scene裁切画布以窗口origin换算回宿主局部位置；UIView不裁切外溢，MTKView仅覆盖完整阴影范围，按需绘制。pipeline/LUT/command queue跨宿主共享，无同步GPU等待。当前宿主明确仅接无缩放旋转的提示；检测不支持的祖先变换时保留错误并隐藏，不伪造近似。公共材质Surface尚未改用该宿主。

重新对照 `FileListScreen.kt:2231`：fade/slide属于AnimatedVisibility父层，Surface节点本身alpha保持1。因此阴影background放在SwiftUI `.opacity` 之前，随内容一起淡出一次；**前阶段“将提示动画alpha作为shadow nodeAlpha”的设想不适用于此结构，未采用**。Surface背景色的alpha也不替代outline alpha。

首轮 `f179-host-build.log` 因convert(.zero) CGPoint/CGRect歧义编译失败；已明确CGPoint.zero。`/tmp/ztransfer-20261016-f179-host.log` **12/12、TEST SUCCEEDED**，新增真实UIWindow宿主验证画布外扩、屏幕位置改变后spot范围更新、零高度隐藏。`/tmp/ztransfer-20261016-f179-host-ui.log` **2/2、TEST SUCCEEDED**，真实列表预览拒绝后无队列/飞行残留，以及预览上方提示出现/退场仍保留预览。

截图已查看：`/tmp/ztransfer-20261016-f179-host-ui-attachments/234C56EB-3AF0-402C-983E-BCE931BF806B.png`。截图证明页面提示正常可见，不作为独立Android像素一致性证据。最终 `f179-host-build-fixed.log` **BUILD SUCCEEDED**，simctl install成功、launch PID41082。未真机/提交/推送。新增生产文件索引680；F034的6dp已接线，但完整动画阴影像素参考及公共投影剩余范围仍待验证，F034/F179保持未核销26/182，不能将页面可见当完整完成。

### F179 宿主等比缩放（2026-10-16，未核销）

按安卓GlassButton的graphicsLayer等比pressScale，宿主从窗口基向量读取正向等比scale，传入投影组装，裁切scene的origin和size除以该scale放回UIKit局部坐标；drawable仍使用实际设备像素，避免祖先缩放重复作用于纹理尺寸。非等比/旋转/镜像仍明确拒绝，不把本阶段当通用变换完成。

真实UIWindow宿主用0.8缩放验证drawable尺寸与物理尺寸一致、窗口origin对齐整数像素；非等比0.8/0.7拒绝，恢复identity+零高度隐藏并清掉旧错误。首轮f179-host-scale.log为12项/5断言失败：额外的radius<=halfMinimum校验拒绝了映射后浮点半径边界。临时夹紧半径版本f179-host-scale-fixed 12/12通过，但进一步核对原ShadowRRectOp（设备映射后无该限制）后撤掉夹紧、仅移除额外拒绝条件，保留原radius/umbra公式；最终 **f179-host-scale-source.log 12/12 TEST SUCCEEDED**。`SkRRect.cpp`固定版本另已取证于同tmp目录，不能把source空间圆角规范化误移到device网格入口。

最终`/tmp/ztransfer-20261016-f179-scale-build.log` **BUILD SUCCEEDED**，simctl install/launch PID41610成功；本阶段未重跑页面UI，已有提示UI2项证据仅针对此前无缩放状态。公共Surface尚未替换：仍须旋转/非快捷路径及完整像素验证。F034/F179不核销26/182，索引680不变；未真机/提交/推送，所有构建结束。

### F179 直角旋转快速路径（2026-10-16，未核销）

实际调用核对：RemoteView的横屏工具区域整体±90°，RemoteEntryReveal和RemoteConfiguredToolbar编辑态存在任意小角度，故不能直接整体替换公共Surface。已新增QuarterTurn四态，按inverse CTM处理spotOffset、按旋转后轴向bounds生成ambient/spot，保留设备blur及scale规则。renderer.scene贯通该参数；UIKit宿主识别轴保持等比基向量，用逆基变换Metal子画布，以bounds/center而非旋转下未定义的frame设置，保证纹理在窗口中仍水平/垂直对齐。

`f179-quarter.log`与最终`f179-quarter-host.log`均 **13/13 TEST SUCCEEDED**：四方向光源/投影协变、非零平移数值、±90/180°叠0.8scale真实窗口宿主的横纵像素尺寸/轴对齐及既有回归。`f179-quarter-ui.log` **1/1 TEST SUCCEEDED**，真实预览拒绝无入队/飞行且提示可见；截图 `/tmp/ztransfer-20261016-f179-quarter-ui-attachments/8F683279-721E-491E-9639-0729A451EEF0.png` 已看。此UI仅验证当前竖屏提示，不能宣称横屏公共Surface已接线/验收。

最终`f179-quarter-build.log` BUILD SUCCEEDED，simctl install/launch PID42070成功。任意角度、透视/非等比通用路径和独立Android像素对照仍未完成，公共Surface未替换，F034/F179保持未核销26/182；索引680。未真机/提交/推送，所有构建结束。

### F179 通用路径 Gaussian 绘制（2026-10-16，未核销）

固定android-15.0.0_r1通用路径进一步取证：SkShadowUtils通过SkShadowTessellator生成带alpha的三角网格，Ganesh GrFragmentProcessors的Gaussian色彩滤镜计算 `factor=1-inColor.a; factor=exp(-factor*factor*4)-0.018`，与圆角快速路径128字节LUT不同。CPU SkRasterPipeline另用四次近似，不误拿其结果作为GPU公式。SkShadowTessellator还要求轮廓曲线细分、convex内环/外环、umbra塌缩修正及spot遮挡裁切，不能只旋转现有圆角网格代替。

renderer新增独立TessellatedVertex/Layer与encodeTessellated、Gaussian fragment pipeline；缓冲校验/分配、render encoder和黑色source-over与快速路径共用，保留两种片元算法。新GPU测试对256×8插值alpha ramp×255/48两种层alpha，共4096像素，和独立Double公式比较（half/UNORM容差1/255）。`/tmp/ztransfer-20261016-f179-gaussian.log` **14/14、TEST SUCCEEDED**，含原快速路径及宿主回归。

源文件在`/tmp/ztransfer-shadow-android15/`，SHA256：SkShadowTessellator.cpp=`8a59de918ebaff6c4651b445b0843253e4185ca64718afbb9bfa660bcf9b4436`；SkShadowUtils.cpp=`58d7691fce89d9bf0753221be45a329e2186c263d913b4b103b8c097f99421cd`；GrFragmentProcessors.cpp=`dc01e118a8319340e80dba70ee1de885d8a48ea7fffd1e2d09c7e34453a082ec`。

当前通用绘制分支只验证输入网格的着色，没有生产通用网格生成/页面调用。任意角度和公共Surface仍未完，F034/F179不核销26/182，索引680；本阶段无页面视觉改动，未额外安装/启动，未真机/提交/推送，测试结束。

### F179 通用轮廓准备（2026-10-16，未核销）

新增ZTransferShadowPolygon，按SkShadowTessellator的sanitize_point/handleLine/accumulateCentroid/checkConvexity/finishPathPolygon处理已变换到设备坐标的线段轮廓。保留1/16像素量化、严格小于1/16的重复距离、NearlyZero=1/4096共线判断、闭合首点替换顺序、带符号面积/重心和凸性/方向。SkScalarRoundToScalar在float乘16后转double再floor(x+.5)，负半值不能用Swift默认round代替。退化/自交结果保留原始几何状态，非有限输入在边界拒绝；调用方仍需决定无面积/无有效umbra的处理。

扩展原生generator，从已固定SHA的SkShadowTessellator直接提取上述原方法/辅助函数，通过最小SkPoint/容器/数学shim编译运行，输出android15-shadow-polygons.json。14组含空/单点/两点、共线、顺逆序矩形、重复闭合、负数半值、近邻/阈值点、凹形、自交及偏移，全部points/area/centroid/convex/direction与Swift一致。`/tmp/ztransfer-20261016-f179-polygon.log` **15/15、TEST SUCCEEDED**，包括原14项回归。

这只是通用网格的输入准备，尚缺quad/conic/cubic细分、inset polygon、内外环/塌缩和spot裁切，未接公共Surface。新增生产文件/fixture已xcodegen，索引681；F034/F179未核销26/182。无页面视觉改动，未额外安装/真机/提交/推送，测试结束。

### F179 二次/三次曲线细分（2026-10-16，未核销）

ZTransferShadowCurve按固定Ganesh GrPathUtils补quadratic/cubic递归细分：设备空间0.2像素距离阈值、Wang fourth-power/nextlog16点数和最多10次chop（1024点）、先左后右顺序，输出不含起点。保留quad退化时不追加端点的SkShadowTessellator行为，点到线段距离按原det/length再乘det及非有限回退顺序。极大有限坐标导致cross为NaN时，不能把`if nearlyZero`改成`guard greaterThan`的互补判断。

原生generator扩展固定源码提取：GrPathUtils递归函数与max count、WangsFormula的p4/nextlog函数、SkPoint距离函数，使用最小点/向量/identity xform适配编译；首轮float4组合构造适配失败，改适配类型后通过，原始函数体未改。10组曲线含普通/回折/全重合/collinear/阈值/大曲率1024上限和1e30坐标，Swift每个输出点精确相等，输出顺序/数量一致。

常规9组`f179-curves.log`16/16通过；补NaN条件与第10组后最终 **`/tmp/ztransfer-20261016-f179-curves-final.log`16/16 TEST SUCCEEDED**。原生生成最终日志`f179-curve-generator-final.log`成功。新增资源android15-shadow-curves.json已xcodegen，源码索引681不变。

固定原文件SHA256：GrPathUtils.cpp `1c0a78961e1866181d5f3b58f21e9766b76d6dfd9c7ae32e67f94c04ed892825`；WangsFormula.h `8168ab499d47d0a8e213608d0a305fa31bf51ac5eb2e01ec3082714f60289a1c`；SkPoint.cpp `5534efdc0a13f3e8c69d510ca2d308339673715ef5cd2bbb75ed165aaff6df2b`。仍缺圆角conic转quad、完整轮廓接线和阴影内外环/spot裁切；通用路径未完成，公共Surface未替换，F034/F179不核销26/182。本阶段无页面视觉变更，未额外安装/真机/提交/推送，所有测试结束。

### F179 conic 转换与参考编译选项纠正（2026-10-16，未核销）

新增ZTransferShadowConic：固定SkGeometry非legacy chop，0.25px误差、最多32个quad、权重sqrt((1+w)/2)、防溢出的控制点计算、Y单调修正、最大细分下双直线退化与非有限中间点回退。polyline按原handleConic逐quad调用Ganesh quadratic，最后端点保留原conic端点。尚未涉及透视权重转换。

原生generator直接提取固定SkGeometry的computeQuadPOW2/chop/subdivide/chopIntoQuadsPOW2和误差宏，19组半径0.1/1/22/1000×权重0/√0.5/1/2，以及非单调/极端权重/退化点；所有quad控制点和最终折线精确对照。

首轮`f179-conic.log`17项1失败（极端权重多一个折线点），定位为参考程序误用本机Clang默认FMA，并非Swift conic控制点错误。固定Android15 Soong `cc/config/global.go:125`明确`-ffp-contract=off`（注释Turn off FMA）。generator所有原生编译均已改此选项，重新生成全部既有metrics/mesh/polygon/curve/conic参考。**此前参考生成使用host默认浮点收缩，不足以声称已对齐Android编译选项；以本次重生成和全回归证据取代该部分依据，历史失败/通过记录保留。**

最终`/tmp/ztransfer-20261016-f179-conic-fixed.log` **17/17 TEST SUCCEEDED**；`f179-conic-generator-fixed.log`成功。SkGeometry.cpp SHA256 `df602fce642f871af2207297577baa21551307bea15c7a549fb6cc2c1ccf2da7`；Soong global.go SHA256 `de4c200e66ba0e75aa237cf90fec64a3f3924fd029790e921bb2034f6491891e`，均固定android-15.0.0_r1，暂存同tmp目录。这仍是原函数最小类型适配参考，不是完整Android二进制/截图验证。

新增生产/fixture已xcodegen，索引682。通用轮廓组装、inset/内外环/spot裁切和公共Surface接线尚未完；F034/F179不核销26/182。本阶段无页面视觉变更，未额外安装/真机/提交/推送，所有测试结束。

### F179 凸轮廓内环塌缩修正（2026-10-16）

- `ZTransferShadowUmbra.prepare` 按 Android15 `SkBaseShadowTessellator::computeConvexShadow` 计算质心到各边的最小距离，在内环将塌缩时将 inset 退至 `sqrt(minDistSq)-0.01`，并按 SkPMLerp 的 0…256 整数权重和字节截断降低顶点 alpha。复用原有线段距离实现；非凸、退化质心及非法输入拒绝，供后续网格生成器选择失败处理。
- 原生生成器提取固定 Tessellator 原调整代码块、SkPoint 原距离函数和 SkColorData 原 64 位打包颜色插值函数；只移除未参与计算的 bounds/内环容器声明，使用既定 `-ffp-contract=off`。SkColorData SHA256 为 `891d30482d4e9c3cbec207c9a320cf918d5169b50d0be931ee73f32f8aac3564`。91 组参考覆盖零值、NearlyZero 门槛、不同轮廓及大 inset，其中34组发生 alpha 衰减；Swift inset/alpha 逐项精确一致。
- `/tmp/ztransfer-20261016-f179-umbra-generator.log` 生成成功；`/tmp/ztransfer-20261016-f179-umbra.log` **18/18、0失败、TEST SUCCEEDED**，包括既有 GPU、宿主和曲线回归。测试宿主仍输出 appearance transitions 警告，不将其作为视觉验收证据。新增 fixture 已由 xcodegen 纳入工程。
- 本块尚未连接通用生产网格。完整路径组装、SkInsetConvexPolygon 的边删除/收尾、内外环连接及 spot 裁切仍未完成；公共 Surface 未替换，F034/F179 均未核销，开发侧仍26/182。没有新增页面视觉变更，未额外安装、真机验证、提交或推送。

### F179 凸轮廓内环生成（2026-10-16）

- `ZTransferShadowInset` 按 Android15 `SkInsetConvexPolygon` 实现完整内环算法：绕向/凸性检查、偏移线段交点（含平行/重合/零长）、无效边删除和向前回退、迭代上限、0.01重合点清理及结果凸性复查。用连续数组的整数链接保存节点关系，删除后保留旧邻接信息供回退，不引入对象循环引用。失败结果保留原算法产生的退化点列，调用方必须检查 `isValid`。
- `SkPoint::setLength` 的中间计算使用Double，交点和其它几何仍为Float；不擅自改为Float归一化。近零 inset 的原样返回位于凸性检查之前，保留负 NearlyZero 容差和 UInt16 顶点数上限。
- 原生生成器提取固定 SkPolyUtils 原函数/OffsetEdge、SkPoint 原归一化、SkPointPriv 原比较函数，类型与存储仅作适配；`-ffp-contract=off`。SkPolyUtils SHA256 `85ab2e03b19b24d0cb94b4a8ce501fd04d13739cbcc7918542c31233fddb6451`，SkPointPriv `337cdbde10fc08d9238dc19b97ea0a3e9af0ff57f038c72377f2817ab4195e04`。
- 667组逐点/有效性精确对照通过：顺逆时针、细长形状、削角多边形、旋转椭圆采样、重复点、共线/非凸/自交、近零及大inset，以及上一步91组umbra调整值直接传入。357组有效、310组无效，40组有效且顶点减少；另测非有限输入和65535/65536顶点边界。
- `/tmp/ztransfer-20261016-f179-inset-generator.log`生成成功；`/tmp/ztransfer-20261016-f179-inset.log` **19/19、0失败、TEST SUCCEEDED**。新增生产文件和fixture已xcodegen；索引683。这证明内环算法及既有回归，不证明通用阴影已接入页面或独立Android像素一致。
- 下一步仍需路径组装、内外环连接/圆弧、spot裁切及公共Surface接入；F034/F179未核销，26/182不变。本阶段无页面视觉变更，未额外安装、真机验证、提交或推送，测试进程已结束。

### F179 凸轮廓网格与遮挡裁切（2026-10-16）

- 新增 `ZTransferShadowConvexMesh`，串接已有umbra修正与内环生成，按固定 `SkBaseShadowTessellator` 实现最近内环点行走、近点合并、失败内环向质心0.95回退、外环圆弧扇形、三角形连接及闭合首尾修正。保留 `SkComputeRadialSteps` 的0.25弧长步数、整数取整、三角函数精度不足时不加弧的回退；顶点数不能由UInt16索引时安全拒绝，未另造近似网格。
- 同一生成器已实现凸遮挡轮廓裁切：预计算边向量和质心遮挡，质心露出时改为填中心扇形，否则连接露出umbra与裁切交点。顶点、alpha和三角形索引顺序均对照原实现。内环是否尝试生成以原始inset判断，环点选择以修正后inset判断；修正后为负仍可触发失败内环回退，不能把两个判断合并。
- 原生参考复用固定SkPolyUtils/SkPoint/SkColorData，并提取Tessellator的原computeConvexShadow、clip、addInner/addEdge/addArc/appendTriangle等函数，保留Android `-ffp-contract=off`。首轮generator遗漏浮点除法适配函数而编译失败（`f179-convex-generator.log`）已修；fixed生成720组。初轮 `f179-convex.log` 20/20通过后，审查覆盖补入缩小遮挡轮廓和极细三角形，避免只用同形/整体移出遮挡证明裁切；最终1,056组顶点、alpha、索引逐项精确一致，测试显式确认存在内环失败回退样本。
- 最终 `/tmp/ztransfer-20261016-f179-convex-generator-final.log` 生成成功，`/tmp/ztransfer-20261016-f179-convex-final.log` **20/20、0失败、TEST SUCCEEDED**。模拟器仍有 `IOSurfaceClientSetSurfaceNotify failed e00002c7` 日志，不能把本轮几何对照当作页面视觉验收。新增生产文件和fixture已xcodegen，索引684。
- 本实现输入为已准备的设备坐标凸轮廓及裁切轮廓；完整路径组装、spot投影/高度接线、凹轮廓及一般变换处理、渲染与宿主接入和独立Android像素验收仍未完成。公共Surface未替换，F034/F179未核销，仍26/182。无页面视觉变更，未额外安装、真机验证、提交或推送，所有测试进程结束。

### F179 路径组装与设备坐标变换（2026-10-16）

- 新增 `ZTransferShadowPath`，按 `SkPath::Iter(forceClose=true)` 的语义组装单轮廓：move本身不加入点列，隐式/显式闭合按需补起点直线；尾部move被忽略，多轮廓及闭合后继续绘制拒绝。quad/cubic/conic先变换控制点再细分，之后统一执行既有1/16量化/去重/凸性与质心计算。保留退化quad不输出端点的原行为，不将其替换为直线。
- 同文件 `ZTransferShadowTransform` 保留Float矩阵运算及透视z为0时乘0的SkMatrix行为；圆锥曲线权重先按齐次坐标映射，再以Double计算权重比值的平方根。clipTransform与shadow transform独立：spot遮挡轮廓的quad/conic取中点、cubic取5/16和11/16，clip只合并连续近点，不套shadow点列的量化和共线清理；conic clip采样仍用原路径权重。
- 原生参考提取固定SkPath原autoClose/next、Tessellator原ambient/spot路径函数及全部handle函数、SkMatrix原映射/齐次映射、SkConic原TransformW，使用既有曲线和polygon原函数。类型/容器/矩阵类型派发及SkAutoConicToQuads封装为适配；未声称完整链接Android二进制。SkMatrix SHA256 `83eece5b45e4090b053dbc7829d6c3df86fb4b9624379972d7dd0d5c8c4965f8`，SkPath `fdb522e724ba6af95b1dc572be742cc2956be44a48b8b35c8de2cc2a25555fd4`。
- 144组路径参考覆盖空/仅move、隐式和显式闭合、尾move、多轮廓/闭合后绘制拒绝、四类线段、退化quad，以及identity/平移/旋转/非等比剪切/透视/常量齐次尺度；ambient和独立clip两路的点列、clip点列、area、centroid、convex、direction逐项精确一致。另测透视零分母和非法坐标拒绝。
- `/tmp/ztransfer-20261016-f179-path-generator.log`生成成功；`/tmp/ztransfer-20261016-f179-path.log` **21/21、0失败、TEST SUCCEEDED**。IOSurface通知警告仍保留，未将本轮作为页面视觉验收。生产文件和fixture已xcodegen；索引685。
- 后续仍需圆角路径构造、光源与高度生成spot投影、将路径/网格接入renderer及宿主、凹轮廓处理与独立Android像素验证。公共Surface未替换，F034/F179未核销，26/182不变。本轮无页面视觉变更，未额外安装、真机验证、提交或推送，测试结束。

### F179 光源投影与矩阵拼接（2026-10-16）

- 新增 `ZTransferShadowProjection.spot`，按固定 `GetSpotShadowTransform` 处理普通/方向光、带透视的四角3D投影、倾斜高度平面、光源低于/等于角点和退化边界拒绝；保留原h0/h1方向修正中复用w的顺序，不擅自“纠正”原数学实现。输出设备坐标变换和outset，尚未直接绘制页面。
- `ZTransferShadowTransform.concatenating` 对照SkMatrix的identity/仅缩放平移/affine/perspective分支；affine两乘积和用Double中间值，透视rowcol3与简单缩放保持Float。常规半径复用此前已验证的metrics，不复制第二套公式。
- 复核SkRect.h发现centerX/Y实际使用 `sk_float_midpoint` 的Double求和，已同步修正Swift和参考类型适配，并加入2e38…3e38坐标与极小高度梯度用例。初版243组参考仅生成，未作为通过证据；最终245组才用于iOS验证。
- 原生生成器提取固定SkDrawShadowInfo.cpp原函数及SkMatrix原muladdmul/rowcol3/setConcat/preConcat，继续使用Android `-ffp-contract=off`。SkDrawShadowInfo.cpp SHA256 `959f431fb27027b7f558ef845618ba14408604adbc5f6d021d6a1ba43a4b8d36`。245组中228组有效、17组按原规则拒绝；完整9元素矩阵、outset和有效性逐项精确一致，覆盖平移/旋转/剪切/透视、不同高度和倾斜、方向光与光源高度边界。
- `/tmp/ztransfer-20261016-f179-spot-generator-final.log`生成成功；`/tmp/ztransfer-20261016-f179-spot.log` **22/22、0失败、TEST SUCCEEDED**。新增生产文件和fixture已xcodegen，索引686。本轮日志仍有appearance transitions警告；还出现 `No symbol named 'link.slash'`，定位 `GPSConnectionControl.swift:598`，需在C05界面复核时对照安卓处理，尚未修复，不据本次通过声称图标/页面已验收。
- 下一步圆角path构造、ambient高度与投影/网格整合、renderer/host接线，凹轮廓和独立Android像素验收仍未完成。公共Surface未替换，F034/F179未核销，26/182不变。本轮无页面视觉变更，未额外安装、真机验证、提交或推送，测试进程结束。

### F179 圆角路径构造（2026-10-16）

- 在 `ZTransferShadowPath` 补 `roundedRect`：对照SkRRect::setRectXY排序边界、空/方角处理和超大半径按两轴最小比例缩放；对照SkPath::addRRect的矩形/椭圆/普通圆角分流。保留默认CW起点6、CCW起点7，以及0…7起点、方向、首段conic/line选择、末段交由close的区别，不用看似相同的任意起点轮廓替代原指令序列。
- 圆锥权重使用原字面量 `0.707106781f`；椭圆中心沿用SkRect的Double midpoint。几何返回既有Element序列供路径准备器使用，尚未接入公共Surface。
- 参考生成器提取原SkRRect::initializeRect/setRectXY、SkPathMakers完整点迭代器、SkPath原addRect/addOval/addRRect函数；容器、路径元数据标记与reserve/RAII等不参与几何的部分为适配。SkPathMakers SHA256 `b05e7f3c35e5a41f9ca956cc668cf3ac5c559337f61510e9156bc535071b2605`，SkRRect.cpp `d4a7560885b9b609e70b3a4734f186ebc1bf5d17a8f91f35001f925437af0c07`。
- 504组覆盖普通/方形/反向/零宽边界，零/负/单轴零/普通/椭圆/超大半径，两种方向及默认和全部8个起点；所有verbs、控制点及weights逐项精确一致。`/tmp/ztransfer-20261016-f179-rrect-path-generator.log`生成成功；`/tmp/ztransfer-20261016-f179-rrect-path.log` **23/23、0失败、TEST SUCCEEDED**。fixture已xcodegen，索引686不变。
- 下一步需要圆角→ambient/spot投影→路径→凸网格的完整几何入口及组合参考验证，再接renderer/host；凹路径处理和独立Android像素验收仍未完成。本轮原函数对照不能当页面运行验收。公共Surface未替换，F034/F179未核销，26/182不变；无页面视觉变更，未额外安装、真机验证、提交或推送，测试进程结束。

### F179 圆角双层几何组合（2026-10-16）

- 新增 `ZTransferShadowGeometry.roundedRect`，串接圆角path、ambient中心高度/blur/inset、spot光源投影、两路路径准备与凸网格。ambient与spot分别返回可选mesh：空mesh表示退化轮廓成功、不绘制；nil表示该层生成失败、后续调用方需要回退，不把两者混为一谈。spot光源不合法或透视角点过高时保留独立ambient结果。
- 原生generator将之前分别验证的原SkRRect/SkPath构造、SkPath迭代/曲线处理、GetSpotShadowTransform/SkMatrix、SkPolyUtils和凸网格函数装入同一可执行程序。构造器调度用小适配器保留原baseZ/outset/inset、退化和凸性门控；不是完整Skia链接，**不包含凹轮廓分支**。没有用Swift的中间输出作为参考输入。
- 123组完整双层几何覆盖方角、普通圆角、胶囊、圆和椭圆；identity、任意旋转、非等比剪切、透视；低高度、普通高度、倾斜平面、透明/不透明及失败/空结果。123组ambient有效（1空），121组spot有效（1空），另2组spot失败而ambient保留；所有有效层的顶点、alpha与索引逐项精确一致。
- `/tmp/ztransfer-20261016-f179-integrated-generator.log`生成成功；`/tmp/ztransfer-20261016-f179-integrated.log` **24/24、0失败、TEST SUCCEEDED**。生产文件和fixture已xcodegen，索引687。此为组合几何证据，尚非GPU整体像素或页面验收。
- 下一步renderer有界场景应接这个入口并过滤空层、显式处理失败层，沿用既有Gaussian管线，验证完整窗口与裁切纹理一致，再接宿主的一般变换。凹路径/失败回退、透视边界裁切和独立Android像素验收仍待补；公共Surface未换，F034/F179未核销，26/182不变。无页面视觉变更，未额外安装、真机验证、提交或推送，测试结束。

### F179 通用 Metal 场景与有界纹理（2026-10-16）

- `ZTransferAndroidShadowRenderer.tessellatedScene` 已接完整圆角几何与HWUI alpha，按ambient/spot顺序生成Gaussian管线使用的TessellatedLayer。统一提取 `textureBounds` 给原快速路径和通用路径复用，先完成设备坐标投影，再向外取整得到窗口origin/整数纹理尺寸，最后平移顶点到局部纹理坐标。
- 新返回 `TessellatedPreparation(scene, failedComponents)`：成功的空mesh不分配纹理，失败的可见层显式登记ambient/spot，成功的同伴层保留。调用方必须处理这些失败标记后才能作为完整阴影显示，当前没有把失败层静默略过后声明成功；页面宿主尚未调用新入口。
- GPU对照覆盖任意旋转、非等比剪切和透视各自opaque/0.5 nodeAlpha，共6场景、240,000像素位置。比较完整200×200窗口绘制与裁切纹理按窗口origin还原的alpha，最大允许差1，全部通过；每场景有实质可见像素且裁切面积小于窗口。另验证spot投影失败时保留一层ambient与`.spot`失败标记、零宽空结果、零高/隐藏无scene。
- `/tmp/ztransfer-20261016-f179-general-scene.log` **25/25、0失败、TEST SUCCEEDED**，包括原快速路径裁切/GPU/宿主回归；IOSurface通知警告保留，不作为页面验证证据。索引687不变。
- 下一步宿主选择快速/通用场景并反变换纹理，失败层仍需对应fallback，之后才能替换公共Surface并做实际UI/独立Android像素验收；凹路径和透视边界处理仍待完成。F034/F179未核销，26/182不变。本阶段未改变页面采用的阴影路线，无额外安装、真机验证、提交或推送，测试结束。

### F179 静态仿射宿主接线（2026-10-16）

- `AndroidShadowHost` 用Scene枚举承载快速/通用场景，分别调用LUT和Gaussian编码。任意角度、非等比缩放、剪切和非等比镜像已走通用几何；通过逆仿射变换摆放Metal子视图，使窗口中的纹理保持设备像素对齐。坐标采样改以bounds.origin为基准，子视图中心相应补回bounds.origin，避免滚动型非零bounds时移位。
- 明确检查祖先layer是否为仿射、宿主是否有独立sublayerTransform及基向量行列式；透视/奇异变换不再用三个点冒充仿射。失败时清除旧scene并隐藏绘制，保留renderingError；通用准备返回失败组件时不得把部分场景当完整阴影。真正的失败回退仍未实现，因此公共Surface尚不能替换。
- 源码复查 `SurfaceDrawContext::drawFastShadow` / `SkMatrix::isSimilarity` 发现轴对齐等比镜像也属于快速路线，已补metrics/renderer的reflected参数：光源偏移逆变换先逆旋转再反射，设备bounds按反射再旋转。四种quarter-turn镜像协变测试通过；不能把所有镜像都归通用Gaussian。
- 宿主验证含±90/180度、0.17/0.0001弧度、非等比缩放/镜像/剪切、非零bounds origin，窗口像素轴向/尺寸保持一致；奇异和透视拒绝后恢复正常。初轮 `f179-affine-host.log`25/25，镜像快速补齐后最终 `/tmp/ztransfer-20261016-f179-affine-host-final.log` **25/25、TEST SUCCEEDED**。
- `/tmp/ztransfer-20261016-f179-affine-host-ui.log`真实照片预览1/1、TEST SUCCEEDED；截图 `/tmp/ztransfer-20261016-f179-affine-host-ui-attachments/C32AA648-5B70-4F07-AACB-055C60A80FE2.png` 已查看，离线提示覆盖预览、count/waiting/done保持0。UI验证发生在镜像快速参数补充前；补充默认false不改变该无镜像场景，最终领域/宿主回归另已通过。此截图不是独立Android阴影像素对照。
- 最终 `/tmp/ztransfer-20261016-f179-affine-host-build.log` **BUILD SUCCEEDED**，模拟器install/launch成功，PID50906；未真机、提交或推送，索引687不变。
- 尚未完成：宿主当前按layout更新，不足证明父层动画每帧的presentation坐标/光源联动；快速选择现按采样基向量严格相等，需继续复核SkMatrix近等比容差及UIKit采样误差，不能宣称完整路线等价；凹轮廓/失败fallback、透视宿主及边界、公共Surface接入、完整UI和独立像素仍待验证。F034/F179未核销，26/182保持。


### F179 矩阵快速路径判定与求逆基础（2026-10-16）

- 对照固定 Android 15 SkMatrix::isSimilarity、invertNonIdentity、ComputeInv，补齐 rectStaysRect 联合门控及矩阵求逆。近等比轴保留原始值；简单缩放使用 Float 倒数，普通仿射使用 Double 行列式/余子式，透视按原实现先计算 Float 余子式。退化与非有限结果拒绝。
- 参考生成器直接抽取固定版本原函数，以 `-ffp-contract=off` 编译；235 组覆盖容差边界、负缩放/反射、交换轴、近奇异、奇异及透视。Swift 对判定、可逆性及九个逆矩阵分量精确比较。
- `/tmp/ztransfer-20261016-f179-inverse.log`：26/26、0失败，`TEST SUCCEEDED`，包含上述235组及既有阴影回归；`git diff --check`通过。未运行UI测试或真机验证，本轮未改变页面接线。
- 尚未将新判定接入宿主：必须先让快速几何保留实际两轴矩阵和安卓 spot 求逆运算顺序，不能放宽判定后继续归并成单一 scale。公共 materialSurface、失败回退及动画期间宿主跟随仍未完成。F179不核销，总计仍26/182。


### F179 快速几何保留原矩阵（2026-10-16）

- 对照 SurfaceDrawContext::drawFastShadow、ShadowRRectOp::Make、SkRRect::transform，将快速几何统一为矩阵入口；既有 scale/quarterTurn/reflected 入口构造矩阵后复用，保留原来的正 scale 参数契约。源/设备换算使用原矩阵第一行，spot偏移先加缩放平移再以原逆矩阵map，圆形源半径先按MakeOval半宽建立、再乘matrixFactor，不再从设备边界反推半径。
- 新增近等比圆形用例：两轴边界独立保留、源半径不被设备宽高替换、spot原顺序结果、网格有效及超容差拒绝。既有全窗口/裁切GPU、四方向/反射及固定参考回归仍执行。
- 首轮 `f179-matrix-geometry.log` 26项1失败：重构漏保留旧scale负值拒绝；裁切像素对照本身通过。补回guard后 `/tmp/ztransfer-20261016-f179-matrix-geometry-fixed.log` 27/27、TEST SUCCEEDED。最终 `f179-matrix-geometry-build.log` BUILD SUCCEEDED，已安装并启动模拟器PID52273。未运行本轮UI自动化或真机验证，未提交/推送。
- 新矩阵入口尚未接入renderer/host的近等比判定；还需原Skia完整快速几何组合参考覆盖边界归一化及圆角类型变化，当前不能以分段参考和新增手算用例宣称完整像素对齐。下一步补此参考后接线，动画/失败fallback/公共Surface仍待完成。F179保持未核销，总计26/182。


### F179 完整快速几何参考与近等比宿主（2026-10-16）

- 新增612组固定Android15快速几何组合参考：直接截取SurfaceDrawContext::drawFastShadow的ambient/spot算术及ShadowRRectOp::Make的矩阵计算，结合原SkRRect的setRectXY/setOval/transform/scaleRadii/computeType、SkScaleToSides和SkMatrix求逆。仅容器/矩阵类型分派、轴对齐mapRect及GPU提交改为适配/输出；不是完整Android运行截图。覆盖矩形、圆角、圆、临界半径、大原点、三种高度、透明/不透明、17个轴矩阵（近等比、交换轴、反射）；每层bounds/radius/blur/inset/type精确比较。
- 参考揭示68组投影或外扩后的圆角类型变化。生产补AnalyticRRect：保留原类型、原精度半径归一化、AdjustRadii逐ULP收缩及computeType；圆网格中心改为SkRect的Double中点。移除旧Caster圆形判定，避免把输入类型沿用至两层输出。
- 渲染器新增原矩阵入口，旧便利入口复用。宿主以完整bounds边向量采样减少相近坐标相减误差，按已验证的rectStaysRect/isSimilarity选择快速/通用路径；快速路径保留两轴，不再归并scale。纹理反变换继续沿原矩阵。
- 验证：`f179-fast-generator.log`首轮编译失败（适配层函数重复/缺operator==）；修正后生成成功，但`f179-fast-composition.log`有529断言失败，其中306个源于生成器漏截透明ambient填充分支，其余揭示生产归一化/类型差异。两者均纠正，历史失败保留。`f179-fast-generator-final.log`612组生成成功；`f179-fast-normalized.log`28/28、`/tmp/ztransfer-20261016-f179-fast-host.log`29/29，均TEST SUCCEEDED。新增近等比/反射×alpha1/.5的192000窗口像素与裁切GPU对照容差1，以及真实UIView宿主原点、纹理尺寸及反变换检查。
- `f179-fast-host-ui.log`真实预览拒绝入队场景1/1、TEST SUCCEEDED；已查看附件04A6DE97-7266-4CC5-A3B5-8C7784CF16C2.png，预览保留、queue0、Camera not connected提示可见。这不是Android独立像素验收。`f179-fast-host-build.log`BUILD SUCCEEDED，安装启动模拟器PID53406。git diff --check通过；未真机、提交或推送。
- F179仍未核销，26/182不变，覆盖索引仍687。后续：父层动画presentation逐帧跟随、失败/凹路径fallback、透视host/边界、公共materialSurface接入及独立Android像素验证。当前静态仿射/快速组合验证不代表完整阴影完成。


### F179 父层显示几何跟随（2026-10-16）

- 安卓依据仍为FileListScreen底部AnimatedVisibility包裹Surface（6dp、22dp圆角），父层淡入/滑动时投影使用显示位置；未改PhotoListHintMotion既有时序和父层透明度。原宿主仅layout时读取模型坐标，祖先独立CA动画不会必然触发layout。
- AndroidShadowHost新增共享CADisplayLink弱成员时钟，离窗注销、空集合停钟；读取同一presentation树的bounds/坐标及祖先仿射变换，尚无presentation时回退同一model树。layout发现祖先动画也使用presentation，避免纹理子视图布局把投影改回最终model位置。纹理摆放禁用隐式动画。Geometry缓存跳过不变帧的几何重建/主动重绘；移除或无效几何清场景。透视仍明确拒绝，不冒充已支持。
- 真正窗口场景的确定性动画验证：父层position+scale固定25%和75%，model保持原值，不向host请求布局；共享帧回调驱动后，按独立读取的presentation坐标计算期望scene，校验纹理原点/尺寸及反变换位置；移除动画恢复原尺寸/中心，离窗隐藏。另一测试确认移除后的host可释放。
- 首轮`f179-presentation.log`30项4失败：测试窗口未绑定UIWindowScene，不能代表真实presentation；第二轮`f179-presentation-scene.log`位置检查通过但2个“尺寸必须改变”断言错误（移动可只改变投影位置），修正为位置/尺寸整体检查并加入缩放。最终`/tmp/ztransfer-20261016-f179-presentation-final.log`31/31、TEST SUCCEEDED。历史失败日志保留。
- `f179-presentation-ui.log`真实预览提示1/1、TEST SUCCEEDED，附件C8AE15B2-BF00-4BA8-867C-BE71F454E45E.png已查看，提示/预览/queue0正常。`f179-presentation-build.log`BUILD SUCCEEDED，已安装启动模拟器PID54172；git diff --check通过，未真机、提交或推送。
- 当前证据证明固定presentation进度、变化/移除及生命周期，不证明连续播放的每一显示帧与安卓像素相同。连续播放/中断的逐帧像素和帧时延、失败/凹fallback、透视host/边界及公共Surface仍未完成；F179保持未核销，进度26/182、索引687不变。


### F179 回退参数与失败层分类（2026-10-16）

- 对照SkShadowUtils::DrawShadow的两段最后回退：ambient先将path变到设备空间，按高度z（不是倾斜平面中心）计算描边并转sigma；spot再次GetSpotShadowTransform失败即返回，已绘ambient不撤销。修正Renderer把这种spot标为skippedComponents，而不是令宿主隐藏整个场景；待模糊层继续由failedComponents明确阻止误报完整。
- 新增BlurFallback配方，保存变换、设备空间sigma与fill/strokeAndFill样式。SkPaint默认宽度0且忽略负输入，故高高度ambient负stroke按0保留；并非拿系统shadowRadius近似。ambient公共常量提取复用，维持原Float算术顺序。pending blur层字典为failedComponents唯一来源，避免两份失败状态不同步；零alpha/空成功仍不产生回退。
- 原生generator加入固定SkShadowUtils算术、SkBlurMask::ConvertRadiusToSigma与SkPaint::setStrokeWidth，55组（含负/零/128/129/300/1000高度及零sigma）精确验证；`f179-fallback-generator.log`成功。新增测试区分透视spot无法投影时保留ambient，及零光源半径使tessellation失败但仍存在fill/sigma0回退的情况，不能把后者直接跳过。
- `/tmp/ztransfer-20261016-f179-fallback-plan.log`32/32、TEST SUCCEEDED，包含现有固定几何/GPU/宿主/presentation与释放回归；`f179-fallback-plan-build.log`BUILD SUCCEEDED，模拟器安装启动PID54791。git diff --check通过。本轮未另跑UI截图或真机，未提交/推送。
- 模糊配方的path栅格化、设备空间描边和Skia模糊核仍未实现，存在pending blur时宿主仍明确失败，不把配方等同像素完成。还需凹路径、透视宿主及连续帧像素、公共Surface。另源码复查发现快速入口light.z==height提前拒绝与GetSpotParams的钳位行为可能不符，应补等高参考后修正，不能沿用旧guard作为完成依据。F179不核销，总计26/182，索引687不变。


### F179 光源等高边界（2026-10-16）

- 原SkDrawShadowInfo::GetSpotParams在正高度等于light.z时，把除法正无穷分别钳位到0.95/1.95；SurfaceDrawContext快速路径没有等高拒绝。移除Swift快速几何的light.z!=height guard，保留有限输入及正高度校验。
- 完整快速参考由612扩展至1224组，加入light.z=500时499.999969482421875/500/500.000030517578125（三个相邻Float）×原有全部形状/矩阵/透明度；`f179-light-height-generator.log`成功，`/tmp/ztransfer-20261016-f179-light-height.log`32/32、TEST SUCCEEDED。另实际等高scene保留ambient/spot两个层并完成GPU绘制，`f179-equal-height-gpu.log`1/1、TEST SUCCEEDED。此追加用例之后未重复整套32项。
- `f179-light-height-build.log`BUILD SUCCEEDED，已安装启动模拟器PID55372。git diff --check通过；未另跑UI截图、真机或提交/推送。高于光源时spot blur可为0，本轮参考仅证明几何参数一致，不代表现有mesh的blur>0门控已完成对应零模糊绘制，需要后续核对。
- 模糊回退进一步定位：Android15 GrBlurUtils有矩形/圆/圆角专用路径，通用create_mask_GPU使用GrAA::kYes；不能直接以单个系统高斯滤镜替代。src/gpu/ganesh/GrBlurUtils.cpp SHA256=91d4ca8c0e88f95752c436813d780dcd9123ec4a002dce5e3f54f3e530079579；src/gpu/BlurUtils.cpp=08786ab58c87383689fd52b216512d1377c155d1a64903048577b459c05acdca；BlurUtils.h=8a5f1a7481e616f191b18574b9b9a24e250283e115ad4fc29be2015c5029c7f6；src/core/SkBlurMaskFilterImpl.cpp=9f4eebabe99dc82bab8450fcba21c365fe8afa929cfc68d40caf50ba109efe05。源文件保存在/tmp/ztransfer-shadow-android15，核函数实际委托src/core/SkBlurEngine.h中的SkShaderBlurAlgorithm，待继续读实现并验证。首次猜测ganesh/GrGaussianBlurUtils.cpp与effects/SkBlurMaskFilterImpl.cpp返回404，随后按include定位正确路径，不存在未结束下载进程。
- 模糊栅格/专用分支、零模糊边界、连续帧像素、透视宿主与公共Surface仍未完；F179不核销，26/182、索引687不变。


### F179 Skia模糊核（2026-10-16）

- 新增ZTransferShadowBlur：按Android15 SkShaderBlurAlgorithm计算单次核，保持x外/y内的Float累加、归一化顺序；双线性采样按原奇/偶半径合并中心/相邻权重，镜像偏移，28项尾部复用最后偏移并清零权重。σ≤0.03为identity；单次σ上限4，2D完整核最多28样本。更大的请求显式拒绝，尚需调用方降采样，不能悄悄钳成4。
- 行为依据src/core/SkBlurEngine.h SHA256 f434d3d99fd524f83a40612a1d7fa8a520bad998c6f745ae511cd43eb7b5cbda；SkBlurEngine.cpp 16c64f15c3595fa6bbe4f9fd2a7d6476758be38e143aadccad509c32bf94f707。generator直接编译原Compute2DBlurKernel和Compute1DBlurLinearKernel，仍用-ffp-contract=off；覆盖identity阈值及ceil半径边界相邻Float、奇偶半径和最大σ。
- 首轮f179-blur-kernel-generator.log因SkSpan适配类缺int长度构造触发C++窄化编译失败，补构造后f179-blur-kernel-generator-fixed.log生成12线性/77完整核。生产与参考每个权重/偏移精确一致，并检查权重和与非法/超限拒绝。`/tmp/ztransfer-20261016-f179-blur-kernel.log`34/34、TEST SUCCEEDED。git diff --check通过，新增源/fixture已xcodegen。
- 当前只是核计算基础，未接GPU blur、未修改页面视觉；本轮未单独构建安装、UI截图或真机，也未提交/推送。后续按GrBlurUtils::GaussianBlur核对1D/2D选择、掩码抗锯齿、tile/裁切边界、σ>4降采样和形状专用路径，再接回退层。不能以核相等宣称模糊像素完成；F179不核销，26/182不变。索引新增C29生产文件，共688（iOS生产218）。


### F179 小σ GPU掩码滤波（2026-10-16）

- 新增ZTransferShadowBlurRenderer，以已验证的原生核实现r8Unorm完整纹理clamp滤波。对应GrBlurUtils::GaussianBlur：σ≤4且双轴核面积≤28走一次2D，其余双轴走X/Y两次、保留A8中间量化，单轴和identity走一次；线程不做CPU等待/读回。拒绝超限sigma及输入输出同一存储（包括纹理视图别名），大σ不隐式截断。
- 对照SkKnownRuntimeEffects.cpp的1D/2D源码，offset/weight/sample/累加用half，采样中心+0.5，shader循环样本数按4上取整并补零。固定Android15源SHA256 a32e7f6c2f873d398b36ed25c389902195bb806ac4c2f86d0c6d624597b39386，存/tmp/ztransfer-shadow-android15/SkKnownRuntimeEffects.cpp。
- GPU读回仅测试中使用：19×13混合边缘/渐变/离散掩码×8个sigma组合，对照从原生fixture读取的权重/偏移及独立CPU双线性采样、Float16累加、每pass A8量化，1976个像素最大容差2/255；identity逐字节一致。此为Metal与原生核CPU参考对照，不是Android GPU截图。`/tmp/ztransfer-20261016-f179-blur-gpu.log`35/35、TEST SUCCEEDED。追加别名保护首轮blur-gpu-alias.log编译失败（Swift API名称parent而非parentTexture），修正后blur-gpu-alias-fixed.log 1/1、TEST SUCCEEDED，含全部8组像素和别名/超限拒绝；未再次重复其余34项。
- 新源已xcodegen，git diff --check通过。尚未接页面/回退绘制，本轮未单独构建安装、UI截图、真机、提交或推送。接下来实现大σ降采样/边界、path抗锯齿掩码、形状专用分支与回退合成；当前只支持完整同尺寸掩码的clamp，不声称任意src/dst裁切、decal等路径完成。F179不核销，26/182；索引689/iOS生产219。


### F179 大σ降采样计划（2026-10-16）

- ZTransferShadowBlur新增单层RescalePlan：按GrBlurUtils::GaussianBlur先floor目标尺寸并至少保留1像素，再用实际尺寸重算scale/sigma；clamp两轴各补1像素，记录RepeatedLinear逐级ceil-half尺寸、递归blur整数边界和回放大浮点范围。保留超限sigma供递归，不把一像素大sigma静默截为4。
- 原生生成器截取固定Android15 GrBlurUtils及SurfaceContext::rescaleInto尺寸计算，120组覆盖五种尺寸、六组sigma、偏移/扩展目标和两种SK_USE_PADDED_BLUR_UPSCALE分支。SurfaceContext.cpp SHA256为2d0c19fc79e3e1f57eba149c762b9231b24ae9799f1f8b41a9e01ef65b253b40。当前尚未确认目标Android构建是否定义该宏，因此参数显式保留两种策略，不猜测默认值。
- 首轮`/tmp/ztransfer-20261016-f179-rescale-generator.log`因适配层缺srcRect别名编译失败；增加指向srcBounds的别名后，`f179-rescale-generator-fixed.log`生成成功，未改原生算术。新fixture已xcodegen加入工程。
- `/tmp/ztransfer-20261016-f179-rescale.log`为36/36、0失败、TEST SUCCEEDED，新增120组逐字段精确比较，包含一像素递归及非法输入拒绝；既有小sigma GPU/几何/宿主测试同轮通过。git diff --check通过。
- 这一步只验证降采样计划，未实现大sigma GPU缩放、原图四边/四角补入、递归裁切/放大采样，也未接回退掩码。公共Surface、连续帧像素等既有缺口仍在，F179不核销，总进度26/182、索引689不变。未修改页面视觉，未另行构建安装、UI截图、真机、提交或推送。


### F179 GPU逐级降采样及原图边框（2026-10-16）

- ZTransferShadowBlurRenderer新增encodeDownsample，目标纹理包含一像素边框。按SurfaceContext::rescaleInto重复线性缩小，奇数尺寸ceil-half且不越过目标，各中间纹理为private r8Unorm；无尺寸变化时直接读取源像素。原图四边使用单次双线性缩小，四角取原图角点；内部不能用来延伸边框。对应GrBlurUtils.cpp clamp cheapDownscale八个绘制分支，未修改既有模糊核。
- 两个Metal compute kernel分别处理逐级缩放和边框组装，无生产CPU等待/读回；目标尺寸、格式、采样数、用途和源/目标根纹理别名均校验。此接口供后续递归模糊使用，当前尚未接入页面。
- 新测试以独立CPU双线性/Float16/A8每级量化参考核对7种尺寸组合×普通/透明边框共14种情况，覆盖19×13奇数尺寸、单轴不缩、多级缩小、identity、1×7及1×1；像素容差2/255，透明外圈逐字节必须为0，别名拒绝。参考是依据源码构造的CPU采样器，不是Android GPU截图。
- `/tmp/ztransfer-20261016-f179-downsample.log`37/37、0失败、TEST SUCCEEDED，包含现有原生参数参考/小sigma GPU/宿主回归；git diff --check通过。未新增源文件，覆盖索引仍689，更新两条sha256/证据。测试后只改类说明注释，无行为变化。
- 仍需把降采样、递归目标裁切、小sigma滤波及重放大连成完整大sigma路径，核定SK_USE_PADDED_BLUR_UPSCALE策略，再补路径掩码/回退合成和公共Surface。F179不核销，总计26/182。未单独构建安装、UI截图、真机、提交或推送。


### F179 单像素轴门控及入口复查（2026-10-16）

- GrBlurUtils::GaussianBlur在降采样/核选择之前先用目标reach裁剪源范围，随后将非decal的一像素宽/高轴sigma及radius置零。此前仅截取rescale阶段，文档“一像素需要递归”的说法缺少此前置条件：原始一像素clamp源应先变为identity轴；非单像素源降到一像素后加边框的递归是另一情况。旧120组仍只证明原始rescale阶段算术，不代表完整GaussianBlur入口；对应测试说明已纠正。
- 当前小sigma完整纹理clamp入口补一像素轴归零，避免不必要half/A8卷积量化。新增1×1、1×256、256×1×四种sigma，完整覆盖256个A8值的长单列/单行必须逐字节不变；1×1使用非零97。`/tmp/ztransfer-20261016-f179-single-axis.log`38/38、0失败、TEST SUCCEEDED，包含既有14组降采样/全部原生参数及GPU回归。git diff --check通过。
- Android.bp的android目标local/export include目录实际包含android，故配置入口是android/include/config/SkUserConfig.h，而非此前404的include/config/SkUserConfig.h。固定Android15该文件SHA256=916acabeea63a1551f4ba220f7d64c0b72b11c1bf0ba55cd5922a3fed7059940；它包含include/config/SkUserConfigManual.h，SHA256=5b0f321d8620f91fd71f17c2b99ae974bc4aa82ec6d9b3e38cfa608112460046。已下载/tmp/ztransfer-shadow-android15/AndroidSkUserConfig.h及SkUserConfigManual.h。这两个配置头和已读Android.bp/SkFeatures未定义SK_USE_PADDED_BLUR_UPSCALE；尚未完成整个编译单元预处理验证，当前不据此改写全平台默认策略。
- 下一步完整递归入口必须先保留srcBounds裁切/offset及单轴归零，再处理目标偏移的双pass中间范围，最后接重放大subset边界。现有small-sigma同尺寸方法和downsample仍不是完整GaussianBlur替代。F179保持未核销，26/182、索引689不变。未页面接线、单独构建安装、UI截图、真机、提交或推送。


### F179 带偏移目标的clamp滤波（2026-10-16）

- ZTransferShadowBlur新增小sigma ClampPlan，按GrBlurUtils::GaussianBlur裁剪source与destination outset(radius)的交集；完全不相交时仅缩到对应边列/行，再执行一像素轴归零。双轴大核按two_pass_gaussian裁剪X中间范围（Y扩radius后限源行，X按源外radius-1限制），保留原纹理坐标。整数输入先限制在Float可精确表示的范围内，防止Int极值outset溢出。
- Renderer新增显式sourceBounds/destinationBounds入口，原完整纹理入口复用。shader逐tap限制到有效subset像素中心；X中间纹理按计划尺寸分配，Y使用destination原点减X原点的偏移。目标可位于源范围内部、部分外部或完全外部，输出始终从纹理零点开始。仍仅sigma≤4/clamp，未冒充完整大sigma递归。
- 新测试用固定原生kernel fixture与独立CPU Float16/A8参考，对照4个源subset×6个目标偏移×5个sigma共120组、3600像素，容差2/255。CPU刻意保留完整源行，不复用生产reach/中间裁切算法；覆盖内部子集隔离、单行/列、四侧远离、identity、2D核、单轴和双pass。另检查Int.min/max输入安全拒绝。
- 首轮clamp-offset.log因整数SIMD要求&+ / &-编译失败；有界输入下纠正运算符。第二轮clamp-offset-fixed.log测试输入生成表达式Swift类型推断超时，拆开并显式Int/UInt8后通过。最终`/tmp/ztransfer-20261016-f179-clamp-offset-typed.log`39/39、0失败、TEST SUCCEEDED；历史两轮失败保留。git diff --check通过。
- 当前完成小sigma带偏移subset滤波基础，下一步需把大sigma入口裁切/归零、源subset抽取、降采样及递归重放大串联，并确认fractional subset边界；path栅格化/回退合成/公共Surface与独立Android像素验收仍待做。F179不核销，总计26/182，索引689。无页面视觉接线，未单独构建安装、UI截图、真机、提交或推送。


### F179 小数边界重放大（2026-10-16）

- 读取固定Android15 GrTextureEffect::Sampling及Span::makeInset：线性subset内缩0.5，反转区间合到内缩端点的中点；完整内容边界可用硬件clamp。GrBlurUtils::reexpand历史分支使用小数srcBounds作为subset/domain，SK_USE_PADDED_BLUR_UPSCALE分支使用整个模糊结果内容范围。两者不能混用。
- 新固定源src/gpu/ganesh/effects/GrTextureEffect.cpp SHA256=0a8b15fb1db54dc332022db7e1017d037e95cf9646d65d1c5873e1ec6ba473d6；GrTextureEffect.h=6e3e903b32706547191ebc57e8f0fc834e875b32deca8e6915c3b2447882f0c7。已存/tmp/ztransfer-shadow-android15。头文件kInsetEpsilon默认0，另有SK_USE_SAFE_INSET_FOR_TEXTURE_SAMPLING控制0.0001；当前实现采用已读Android配置未开启的默认0，未声称设备自定义Skia配置均相同。
- Renderer新增encodeReexpand及Metal kernel：原始小数范围映射到输出中心，按显式paddedUpscale策略钳位，亚像素跨度按原算术收缩到中点。验证有限/有效/包含范围、A8/2D/单采样/用途及别名；无生产CPU等待/读回。
- 新测试五种范围×两种策略共10组、3910像素，包含完整范围、非整数边界、不足一像素、恰一像素、贴边极小范围。独立CPU双线性/Float16/A8参考容差2/255，另断言fixture实际区分两种策略、无效范围与别名拒绝。不是Android GPU截图。
- `/tmp/ztransfer-20261016-f179-reexpand.log`40/40、0失败、TEST SUCCEEDED，既有降采样/偏移clamp/全部阴影回归同轮通过。git diff --check通过；索引更新renderer/tests两项，仍689。
- 大sigma递归还未接线：需扩展GaussianBlur入口reach半径到大sigma，裁剪归零后提取source subset，按计划降采样、递归滤波、重放大；目前重放大只是验证过的组成步骤。path栅格/回退合成/公共Surface及连续像素仍未完成，F179保持未核销，总计26/182。未页面改动、单独构建安装、UI截图、真机、提交或推送。


### F179 大sigma递归clamp链路（2026-10-16）

- ClampPlan扩展入口reach半径到大sigma，拒绝非有限/负值及超Int32半径；只有小sigma才生成双pass中间范围，避免把大核面积用于分支计算。原单次encode仍明确限制sigma≤4。
- Renderer新增encodeGaussian，先验证纹理/范围并按原入口裁剪、单像素轴归零。小sigma复用既有滤波；大sigma按保留的源subset提取A8纹理（完整源直接复用），以相对目标坐标生成缩小计划，逐级缩小并补原边框，递归滤波后按显式paddedUpscale策略重放大。所有中间纹理private、无CPU等待或读回；不会把超限sigma截为4。
- 新ShadowBlurRecursiveTests的独立CPU参考不调用生产plan/kernel/shader，使用Double归一化Gaussian权重、half累加、A8中间量化与完整源行计算。16×16、sigma8/16/单轴8/800+1200、两种策略及原图/嵌入外部255干扰边框共16组4096像素，对照容差3/255。高sigma实际经过多级递归。
- 追加64×64源取中央4×4：sigma8的reach独立写明[6,58)，以及目标完全在X外时只保留第63列、Y仍保整源的分支；两种策略共4组64像素。另验证inf/负/极大sigma拒绝。该参考仅用于这些单轴/可分离末级核，tiny2D核仍由既有原生fixture测试覆盖；不是Android GPU截图。
- `/tmp/ztransfer-20261016-f179-recursive.log`41/41、TEST SUCCEEDED（40项既有+首项递归）；追加边界后`f179-recursive-reach.log`2/2、TEST SUCCEEDED，没有重跑其余40项。测试后只补参考范围注释。git diff --check通过。新增测试已xcodegen，索引690/iOS测试124。
- 大sigma clamp像素链路已完成此开发步骤，F179仍未核销：尚未接path抗锯齿/描边掩码、形状专用模糊分支和最终阴影回退合成、公共Surface、连续帧与独立Android像素验证。两种放大策略依然显式传入，不据未完成的全编译宏审计默选。总计26/182，未页面视觉改动、单独构建安装、UI截图、真机、提交或推送。


### F179 通用掩码选择与有效sigma（2026-10-16）

- 接线前复查GrBlurUtils::can_filter_mask发现不能把所有回退送入GPU：shape device bounds宽高均≤64且有效sigma≤32时，普通路径优先软件模糊；identity先与clip直接求交。其他模糊的maskRect把shape和clip分别外扩3*sigma再求交，SkIRect参数转换为int时截断，不是BlurSigmaRadius的ceil。
- 新MaskPlan显式区分empty/identity/software/gpu，保留掩码bounds。此判断只对应形状专用filter尝试之后的通用mask路线，不能据此跳过圆/矩形/圆角专用路径。测试覆盖64/65和32相邻Float、identity阈值、非identity但整数外扩0、小数sigma、clip外扩求交、空范围、非法/Int极值。
- `/tmp/ztransfer-20261016-f179-mask-route.log`43/43、0失败、TEST SUCCEEDED，包含新路由和既有递归/全部阴影测试。随后BlurFallback新增filterSigma=min(原始sigma,128)，对应SkBlurMaskFilterImpl::computeXformedSigma且阴影paint respectCTM=false；原始配方sigma不改，55组原生配方测试追加有效值断言。`f179-filter-sigma.log`1/1、TEST SUCCEEDED；没有重复整套43项。git diff --check通过。
- create_mask_GPU的实际源是GetApproxSize(maskRect.size())且先透明清空、只在maskRect尺寸内绘制；filter_mask以整个源尺寸为srcBounds、maskRect尺寸为dstBounds。这一背板尺寸及AA绘制尚未复刻，不能拿仅贴合path的掩码直接调用现有Gaussian。
- 软件路径由SkBlurMask::BoxBlur委托SkMaskBlurFilter，sigma<2另走small_blur，不能默认用GPU高斯替代。固定Android15新源SkMaskBlurFilter.h SHA256=1a2ac459c0a31e6cd2e76ec12eca4604731fa5918da72d11ad827e10e7988c26，cpp=92e765db1c237502f95f2f5457a2861d37153b72bf7646f842dd0ca2efd1aa53，下载至/tmp/ztransfer-shadow-android15，尚未实现或验证软件像素。
- 下一步按这些真实分支补掩码栅格化/软件滤波/专用形状，再接回退合成。当前只新增选择计划和有效sigma，没有页面接线，不将其算作完整回退。F179保持未核销，26/182、索引690不变。未单独构建安装、UI截图、真机、提交或推送。


### F179 常规软件A8三窗口滤波（2026-10-16）

- 新ZTransferShadowBoxBlur移植SkMaskBlurFilter::PlanGauss的sigma≥2路径：Double窗口取整，奇/偶第三窗口差异及border，32位三个滚动和、64位定点weight及半值舍入；先正向/补零，再反向收尾，水平滤波转置后垂直滤波转置回。原图外为零，保持两轴之间A8量化。仅支持普通A8、等轴sigma2…135；其他范围明确拒绝，不近似小sigma。
- 输出携带宽高、border及像素，调用方必须提供maximumWorkingBytes，尺寸/输入长度/有限sigma检查后，在分配大中间和结果数组前校验其合计及ring工作区。小ring在预算检查之前建立，未宣称零分配拒绝。尚未接页面或最终掩码回退。
- 新NativeTests/generate_shadow_box_reference.py固定下载并校验SkMaskBlurFilter.cpp SHA256（92e765db1c237502f95f2f5457a2861d37153b72bf7646f842dd0ca2efd1aa53），直接截取原PlanGauss类（含原Scan::blur/finalScale）以-ffp-contract=off编译；仅A8行列循环适配为独立runner，输出完整字节SHA256。8个sigma（2/2.1/3/4/8/32/128/135）×3种尺寸（1×1/2×7/19×13）×实心/单点/混合图共72组，生成成功。
- 新ShadowBoxBlurTests对全部10406562个输出字节的SHA256精确比较，同时比较尺寸/border；另测sigma非法/小sigma拒绝、输入尺寸错误和工作集超限。`/tmp/ztransfer-20261016-f179-box-blur.log`2/2、0失败、TEST SUCCEEDED。不使用像素容差，不是Android设备截图。未修改既有GPU滤波，本轮未重复其43项。新源/fixture已xcodegen，git diff --check通过。
- 小sigma路径由SkGaussFilter生成16位系数，先垂直再水平；SkMaskBlurFilter::hasNoBlur使用3*sigma≤1，与GPU identity≤0.03不同，后续必须保留。软件小sigma、AA/描边栅格、专用形状滤波、最终合成/公共Surface及独立Android像素仍未完，F179不核销、26/182。索引新增生产1/测试2，共693（iOS生产220、测试126）。未单独构建安装、UI截图、真机、提交或推送。


### F179 小sigma软件核及统一入口（2026-10-16）

- ZTransferShadowBoxBlur新增smallFactors，按SkGaussFilter的Double Bessel级数、1%尾部截断、从小到大归一化及中心余量修正生成0.16系数。filterSmall逐乘积mulhi截断、8.8累加+128舍入，先垂直再水平并保留中间A8；边界零填充，半径1…4。未用连续Gaussian或GPU核近似。
- 固定Android15 SkGaussFilter.h SHA256=22de968d64263a591fc132d5dae1d6c4d3c664948116dc23f91aa19577117a8e、cpp=455ebbdefb5bbe55c8f4f3d6e8e6d252055f66bdb41370c8ad40046a3ebbfbfa，已存/tmp/ztransfer-shadow-android15。原生generator扩展直接编译原SkGaussFilter和SkMaskBlurFilter的blur_x/y_radius、行列扫描及store函数，仅用8个标量槽适配skvx向量容器/运算（保留uint16和mulhi语义）；不是把Swift算法翻译成参考。
- 9个sigma×6种尺寸（含7/8/9向量边界及1像素/非方形）×3种图案共162组，系数和全部24381输出字节SHA256精确相等。`/tmp/ztransfer-20261016-f179-small-generator.log`生成成功，`f179-small-blur.log`1/1 TEST SUCCEEDED；新fixture已xcodegen。
- 新filterNormal统一正常A8软件入口，严格按3*sigma≤1返回原mask/border0，sigma<2进小核，其他进三窗口；保留独立底层方法的明确范围及工作集检查。已用于两套参考测试，覆盖234组原生像素，而非只测试分支代理调用。
- `f179-software-normal.log`4项中3通过/1失败：72组大核和162组小核均通过，identity测试误以为(1/3).nextUp一定跨过3*sigma阈值；实际乘法仍舍入为1。保留生产原式，将该邻值加入identity验证，第二个nextUp验证>1且border>0。`/tmp/ztransfer-20261016-f179-software-boundary-fixed.log`1/1、TEST SUCCEEDED；修正仅测试，未重复另外3项，不能把原运行改记全绿。git diff --check通过。
- 软件正常A8滤波已具备统一入口，但仍未与AA/描边掩码、专用形状滤波、最终回退合成/公共Surface接线；独立Android像素/连续帧仍待验证。F179保持未核销，26/182、索引693不变。未页面视觉改动、单独构建安装、UI截图、真机、提交或推送。


### F179 GPU掩码背板及透明清场（2026-10-16）

- 固定Android15 src/gpu/SkBackingFit.cpp SHA256=3cc185993e639a9f2c09051bbcb0be4661677d967a8b7f77bb3ccf5968ac85ec，h=2d02ad773ad4852a35e55b2ea74d7ca8d323bb985d2aa740d668070f9d1e8e74，已下载/tmp/ztransfer-shadow-android15。GetApproxSize：每轴最小16，≤1024上取2的幂，大于1024允许floorPow2的1.5倍中点；原为2的幂保持。非空尺寸才创建掩码。
- ZTransferShadowBlur新增maskBackingSize；Renderer新增MaskSurface/makeMaskSurface，按近似尺寸创建exact private r8Unorm可绘制/采样纹理，render pass整纹理clear透明并store。显式保存contentBounds供后续AA绘制裁剪，以及deviceOrigin供路径平移；滤波应读整个texture尺寸而非contentBounds。预算以真实背板尺寸检查，不以轮廓面积低估。
- 测试按源码规则核对15个边界尺寸×横纵两轴，含1024/1025、1536/1537、2048/2049、3072/3073；三种偏移/非方形/跨1024尺寸实际GPU分配clear后blit读回，完整内容及填充区逐字节为0，检查origin/content/usage/storage。另验证仅足够内容却不足背板的预算和极值输入拒绝。
- `/tmp/ztransfer-20261016-f179-mask-surface.log`44/44、0失败、TEST SUCCEEDED（42项阴影基础+2项递归）。尺寸期望为源码规则表，不声称本轮编译了原GetApproxSize。git diff --check通过；未改软件滤波，本轮未重复其234组。索引仍693，更新三条sha256/证据。
- 此步完成实际背板分配和清空，尚未向surface绘制任何形状。AA/path描边、MSAA/格式fallback及Skia路径渲染选择、专用形状滤波、阴影回退合成/公共Surface仍未接，不把透明空纹理当作阴影完成。F179未核销，26/182。未页面视觉改动、单独构建安装、UI截图、真机、提交或推送。


### F179 零inset层跳过（2026-10-16）

- 复查SurfaceDrawContext::drawFastShadow：ShadowRRectOp::Make在scaledInsetWidth≤0时返回nullptr，调用方仅跳过该op，最终仍return true，不撤销已经提交的ambient。物体高于光源、opaque、identity矩阵时spot投影scale=1/offset=0/blur=0，inset也为0。原iOS scene把该层mesh失败当整场景失败，会丢失ambient。
- Renderer现按原条件在mesh生成前跳过inset≤0的单层，其余mesh错误仍显式失败。仅有被跳过spot且ambientAlpha0时返回nil；不把透明物体的inset>0/blur0情况一并当作已解决。
- 新测试矩形/圆角/圆×height500.nextUp/501/1000共9种场景，校验spot参数0、只保ambient层、与直接从ambient几何组装的单层GPU结果逐字节相同；光源边界附近要求可见，spot-only要求nil。
- 首轮`/tmp/ztransfer-20261016-f179-zero-inset.log`45项中其余44项通过，新测试有3个“每个高度必须可见”断言失败。诊断`f179-zero-inset-diagnostic.log`定位均为height1000（alpha9在当前目标量化为0），不是层丢失；不能据此声称Android独立像素一致。测试改为全部场景比较独立ambient层输出，边界附近另要求非零。`f179-zero-inset-fixed.log`1/1、TEST SUCCEEDED；未重跑其余44项。历史失败保留，git diff --check通过。
- 本次复核长期规则时再次确认2026-10-01“每完成一大块功能后集中构建及自动化”已覆盖旧“每个视觉小改动构建安装”。本步完成测试验证，不额外安装模拟器；待完整回退块集中验证。未UI自动化截图、真机、提交或推送。
- F179仍未核销，26/182、索引693不变；透明或因矩阵舍入产生正inset的零blur路径、AA/描边掩码、专用形状滤波、最终回退合成/公共Surface和独立Android像素仍待完成。


### F179 掩码覆盖合成及混合层保留（2026-10-16）

- 对照GrBlurUtils::draw_mask：滤波结果已包含几何覆盖，按整数maskBounds绘制矩形，纹理平移到mask左上角；默认GrTextureEffect最近邻读取覆盖率，paint继续source-over。Renderer新增MaskLayer（texture/有效size/整数origin/alpha）和encodeMasks，采用float纹理坐标、half覆盖率×既有HWUI字节alpha，沿用同一premultiplied black source-over pipeline配置，不再给掩码套Gaussian/LUT。
- 有效size可小于纹理背板，避免把填充区画出；输入在开encoder前完成验证。encodeMasks、原快速mesh和tessellated入口统一支持preserveContents（默认false，保持旧调用行为），以便ambient/spot来自不同路径时按顺序追加而不清掉前层。未修改宿主Scene选择或将未完成掩码标作成功。
- GPU测试覆盖负原点裁切、故意填为255的背板、9/48及128/255透明度、透明清场及保留彩色半透明目标、两层合成与拆分两次pass逐字节相等；独立CPU source-over参考BGRA每通道容差1。非法尺寸后同一command可继续清场/完成，证明未遗留encoder。混合用例先mask再tessellated，检查前mask像素保留、后网格像素存在且空区透明。
- `/tmp/ztransfer-20261016-f179-mask-composition.log`46/46、TEST SUCCEEDED；追加混合层与旧入口保留支持后`/tmp/ztransfer-20261016-f179-mixed-composition.log`47/47、0失败、TEST SUCCEEDED。git diff --check通过，索引693不变。未改软件滤波，未重复其234组原生参考。
- 这一步是实际合成能力，不是完整阴影fallback：AA/path描边掩码和专用形状滤波仍未接，Scene/host尚未编排成功层+回退层；透明零blur、公共Surface和独立Android像素/连续帧仍未闭环。F179不核销，26/182。未页面视觉接线、单独构建安装、UI截图、真机、提交或推送。


### F179 矩形AA绘制依据复核（2026-10-16）

- 接续掩码合成后，检查固定Android15 FillRectOp.cpp，确认实际引用的是src/gpu/ganesh/ops/QuadPerEdgeAA.h；之前尝试geometry/GrQuadPerEdgeAA.cpp返回404，不能把该路径当实现依据。
- 已读取原QuadPerEdgeAA::Tessellator::append及GrQuadUtils::TessellationHelper::inset/adjustDegenerateVertices/EdgeEquations::estimateCoverage。coverage AA先写内圈，再写覆盖率0的外圈，各AA边通常内缩/外扩0.5px；内圈退化为线或点时，按原边距离计算clamp(d0+d3,0,1)*clamp(d1+d2,0,1)的顶点覆盖率。四点覆盖率均<1且所有边AA时，外扩距离再乘max(1,2-maxWH)，使窄轴外圈达到2px，稳定平移动画。最终覆盖通过三角形顶点插值；不能把整条矩形路径替换成像素面积相交算法。
- 新下载并校验SHA256：ops/QuadPerEdgeAA.cpp=3dfba7feecba929ec8c06d4479ffcbda7627df1e8afc4088c31c2631a4a2fdbe；ops/QuadPerEdgeAA.h=76e1f8e46d322ecbd680a0333292280eef77575d310f111d6053be92848f00b6；geometry/GrQuadUtils.cpp=fa87407562f91cfc7ae09a05189ab6e12f800a391758304b6cae3aa4adc9ce38。源缓存/tmp/ztransfer-shadow-android15，tag android-15.0.0_r1。
- 此证据收窄下一步实现方式：需保持原内外圈及索引顺序，覆盖亚像素宽高、整数边与平移；还须确认调用方coverage/MSAA选择，不能声称所有GPU设备都走同一路径。本轮仅完成源码依据复核，未改生产代码、未运行测试或构建安装；AA掩码和完整fallback仍未实现，F179未核销，26/182、索引693不变。


### F179 轴对齐矩形coverage AA掩码（2026-10-16）

- ZTransferShadowBlurRenderer新增encodeCoverageRectangle：只处理全边coverage AA的轴对齐填充矩形，实际向既有MaskSurface的R8背板绘制，load保留已清场背板、scissor限制contentBounds、减deviceOrigin。显式限制sampleCount=1，不冒充MSAA/圆角/描边/任意路径；输入或几何非有限在创建encoder前拒绝。
- 使用原TL/BL/TR/BR内外圈与GrResourceProvider的30索引；原源SHA256=fc40de39f788448221b87c254e0af0e511bd2555b0b7215c01c29e28df6a6da4。轴对齐专用几何保留GrQuadUtils的边向量归一化、倒数、safeInset、moveAlong、边方程覆盖及hairline外扩顺序，未保留首稿直接width/height简式。顶点Float覆盖插值，fragment转换half写入R8，不做CPU像素回读或等待。
- 新GPU测试6种形状×2原点，逐像素检查完整16×16背板共3072像素：整数/小数矩形、横纵半像素条、双轴窄矩形、越过内容边界的大矩形；参考为显式边平面和峰值表，字节容差1。另测空/倒置/NaN拒绝后同command仍可绘制。不是原Skia编译输出或Android设备像素，任意Float几何的逐位原生参考仍待补。
- 首稿定向测试/tmp/ztransfer-20261016-f179-rect-aa.log 1/1 TEST SUCCEEDED；改为原运算顺序后的/tmp/ztransfer-20261016-f179-rect-aa-final.log 48/48、0失败、TEST SUCCEEDED，含46项阴影基础及2项递归滤波。未修改软件滤波，未重复其234组原生参考；无单独构建安装、UI截图、真机、提交或推送。
- 此入口尚未接Scene/host，也不能绕过Skia专用形状filter选择。接下来仍需原生几何参考、一般路径/圆角/描边AA、coverage/MSAA选择、软件掩码及形状专用滤波，最后编排回退层和公共Surface。F179未核销，26/182、索引693不变。


### F179 专用形状分支及积分表（2026-10-16）

- 复查GrBlurUtils::draw_shape_with_mask_filter/direct_filter_mask：先applyStyle，再尝试专用绘制，失败后才进入通用mask。normal/simpleFill在有效sigma≤0.03时直接AA绘形；矩形且变换保直角、圆且相似变换或变换后成圆各有直接滤波；圆角要求scaleTranslate及变换后四角圆形。不能将当前矩形AA入口+Gaussian无条件接作矩形模糊。
- 新ZTransferShadowBlur.integralTable按固定Android15 BlurUtils::ComputeIntegralTableWidth/CreateIntegralTable生成A8积分LUT：2*ceil(6*sigma)上取2的幂且最少32、Float erf及原常量0.707106781f、四舍五入到byte，首尾强制255/0。调用接受已经mask-filter限幅的有效sigma，限定(0.03,128]，分配前按maximumWorkingBytes检查。
- 新NativeTests/generate_shadow_integral_reference.py校验BlurUtils.cpp SHA256=08786ab58c87383689fd52b216512d1377c155d1a64903048577b459c05acdca，截取两段原函数，以bitmap存储/标量helper适配、-ffp-contract=off编译；生成12组sigma的4256个完整字节，包含32→64表宽阈值两侧及最大2048表。Swift逐字节精确相等，预算少1字节、负预算及非有限/identity/越限输入拒绝。
- 首轮/tmp/ztransfer-20261016-f179-integral.log因测试128.nextUp被推断Double而编译失败；仅改测试为Float(128).nextUp，最终/tmp/ztransfer-20261016-f179-integral-fixed.log 1/1、TEST SUCCEEDED，生产公式未为测试放宽。未重复未修改的GPU/软件滤波测试；新fixture已xcodegen。此参考为本机编译固定源，不冒充Android设备运行。
- 积分表是矩形/圆角专用滤波的共用基础，尚未接纹理采样和direct_filter绘制，也未完成一般路径/描边及Scene/host回退。F179未核销，26/182；索引新增原生参考generator，共694（iOS测试127，其他不变），资源fixture不单列。无单独构建安装、UI截图、真机、提交或推送。


### F179 矩形专用积分滤波直接绘制（2026-10-16）

- ZTransferAndroidShadowRenderer新增BlurredRectangleLayer/encodeBlurredRectangles，实现GrBlurUtils::make_rect_blur的设备坐标轴对齐分支：以3sigma外扩无AA代理矩形，积分LUT线性clamp采样；原矩形内缩3sigma后仍sorted走最近边fast，两轴任一不sorted则分别1-left-right/1-top-bottom。保留half距离/覆盖率/paint alpha运算，直接写premultiplied black source-over，不先写A8中间掩码而额外量化。
- 同批相同表宽复用积分纹理；所有输入验证/纹理创建先于encoder，支持preserveContents与清场。此API明确只接已限幅有效sigma和轴对齐设备矩形，不擅自用于旋转、剪切、stroke或identity。Metal关闭fastMath以保留运算顺序；已有快速mesh/通用tessellation/mask合成同轮回归，未只验证新入口。
- 新测试以此前原生Skia积分表fixture为LUT、独立CPU线性采样/Float16覆盖/source-over作参考：4形状（小数宽矩形、窄条、双轴窄矩形、越界矩形）×sigma1/4/16×清场/保留彩色半透明目标，24配置、24576像素/98304通道，byte容差2。覆盖fast与双边分支，不是Android设备渲染或完整页面截图。
- /tmp/ztransfer-20261016-f179-direct-rect.log 50/50、0失败、TEST SUCCEEDED（48项阴影基础+2项递归）。git diff --check通过；索引694不变。未改软件滤波，未重复其234组；未单独构建安装、UI截图、真机、提交或推送。
- 专用矩形滤波已具备实际GPU绘制，但尚未接Scene/host分支编排；旋转矩形逆变换、圆/圆角专用滤波、一般路径/描边掩码、最终公共Surface和独立Android像素/连续帧仍未闭环。F179未核销，总计26/182，不将单一路径通过当完整阴影完成。


### F179 圆形/半平面覆盖率表（2026-10-16）

- ZTransferShadowBlur新增circleProfile，按GrBlurUtils::create_profile_effect保持sigma/radius≤0.1半平面分支；其他分支ratio上限8、转16.16定点后清低8位，以量化ratio重算sigma。返回原key、solidRadius、textureRadius和512字节profile；调用限制有效sigma(0.03,128]、radius≥1/4096，分配前检查kernel/sum/vertical/output工作集。
- 两种表均按BlurUtils原函数生成：Float半像素采样的半Gaussian核，半平面从右到左两段归一化累计；圆形先计算垂直半核积分，再按左右核顺序横向累加，尾字节强制0。SkUnitScalarClampToByte保持Float乘255后Double加0.5再转整数；不使用矩形积分表替代圆形profile。
- generate_shadow_integral_reference.py追加编译原CreateCircleProfile/CreateHalfPlaneProfile及其helper，直接截取create_profile_effect的比例/定点分支，bitmap/数组/标量转换仅作适配。12组覆盖0.1两侧、量化桶两侧、ratio1/8/超8、最小有效半径和大半径半平面；全部6144字节及key/两半径与Swift精确相等。补读SkColorPriv.h SHA256=a854daa9a74423529c6fe29ff0f4685906d738e2e7bce6408fa58041e0920ed0、SkFixed.h=dbb3aed7b717ac59d9513f5286d0fc0ed3f278208697397a8a06fa8413f8a039，固定Android15。
- /tmp/ztransfer-20261016-f179-circle-profile.log 2/2、TEST SUCCEEDED，含新圆表参考与原积分表回归；预算/非法参数拒绝同测。新fixture已xcodegen，git diff --check通过。未改GPU/软件模糊算法，未重复此前50项及234组；无单独构建安装、UI截图、真机、提交或推送。
- 下一步应按make_circle_blur的half circleData、缩放length及最近邻profile查表接实际绘制；当前仅完成表/参数，并未接圆形GPU层、Scene/host或圆角/一般path回退。F179保持未核销，26/182、索引694不变。


### F179 圆形profile直接绘制与精度边界（2026-10-16）

- Renderer新增BlurredCircleLayer/encodeBlurredCircles，按make_circle_blur传half circleData（center/solidRadius/1÷textureRadius），先缩放再length避免大向量溢出，最近邻查512点profile；代理矩形仍按原始sigma外扩3sigma，不能用量化sigma改变代理范围。覆盖直接乘paint alpha并source-over，未多一次A8中间量化。
- 矩形和圆形共用ProfileLayer、makeProfileTexture及encodeProfiles，统一目标检查、encoder生命周期、清场/保留和提交，保留各自参数/采样/生成规则。圆形目前仍逐调用生成profile，跨帧缓存/性能尚未闭环，不能据绘制通过声称可直接用于逐帧宿主。
- 新测试读原生circle fixture，10参数组×2中心×清场/保留40配置，40960像素/163840通道；覆盖半平面阈值/量化桶、ratio上限、最小圆、边界裁剪和彩色半透明背景。CPU参考Float16运算和最近邻查表，最终允许一个half ULP的坐标区间可能采到的表项，区间外不放宽，source-over byte容差2。
- 首轮direct-circle.log因测试flatMap重载产生错误背景数组而大量失败，显式改[UInt8]；该轮已INT中断并在TEST INTERRUPTED后TERM结束滞留xcodebuild，终态143，未并行启动第二构建。direct-circle-fixed.log实际52项中51通过，新项有2处3byte差异；circle-length.log尝试Float中间length造成8处失败，已撤销。定位原CPU坐标恰为412.0、相邻profile[411]=85/[412]=82；不是放宽全图byte容差，最终以一个half ULP的坐标误差区间检查nearest边界。circle-boundary.log 1/1、TEST SUCCEEDED，生产shader未为通过测试改动；其余51项未重复，不将历次运行改写为单次52全绿。
- 此为本机GPU对CPU参考的有界精度验证，不是原Android设备像素。新入口未接Scene/host；圆角/一般path/描边、旋转矩形、缓存及公共Surface仍未完成。F179未核销，26/182、索引694不变；git diff --check通过。未单独构建安装、UI截图、真机、提交或推送。


### F179 圆角九宫格参数及回退边界（2026-10-16）

- 新RoundedRectanglePlan对应ComputeBlurredRRectParams的simple circular分支。保留sigmaKey=ceil(sigma-1/6)、blurRadius=3*sigmaKey、四角ceil半径、严格内部不相交检查（相等也拒绝）、奇数纹理尺寸及圆角矩形在纹理内的位置；比较保持原bounds加减运算顺序，不化简成宽高比较。
- shaderCorner保留原小数半径，mask圆角用ceil(radius)；不可强行统一，原find_or_create_rrect_blur_mask_fp明确纹理dimensions与shader proxyDims不同。矩形和圆形由较早专用分支处理，本入口拒绝；不支持的九宫格返回nil留给通用mask，不近似绘制。
- 原生generator扩展直接编译固定Android15 ComputeBlurredRRectParams，SkRRect/SkRect/SkISize只作简单圆角存储适配，未重写参数算法；99组覆盖sigma1/6与1+1/6邻值、小数圆角、偏移/非方形及大sigma不满足内部空间。Swift逐字段/接纳结果全部一致；另测内部边界恰相等拒绝及Float.nextUp接受，圆/矩形/非法输入拒绝。
- /tmp/ztransfer-20261016-f179-rrect-plan.log 1/1、TEST SUCCEEDED。新fixture已xcodegen，git diff --check通过。索引694、26/182不变；未改其他滤波，不重复已有测试；无单独构建安装、UI截图、真机、提交或推送。
- 进一步确认rrect GPU缓存填充并不调用CreateRRectBlurMask：DirectContext优先在exact A8、sampleCount1表面clear并AA drawRRect，再GaussianBlur clamp；只有recording CPU分支用CreateRRectBlurMask，原注释仅称接近GPU。因此不能以CPU表近似替代默认GPU路线。下一步补drawRRect实际AA选择（SurfaceDrawContext引用ops/FillRRectOp.h）及九宫格采样，当前只有参数/门控，未实际生成圆角mask或接Scene/host，F179未核销。


### F179 CircularRRect覆盖AA实际掩码（2026-10-16）

- 复查SurfaceDrawContext::drawRRect，纠正只追FillRRectOp的路线：非OPTIMIZE_SIZE、coverage AA、非dynamicMSAA、非reducedShaderMode、simple等圆角及rectStaysRect/similarity时优先MakeCircularRRectOp；fill半径<0.5会拒绝再走后续op。九宫格mask的ceil圆角≥1符合半径门控，但平台能力选择仍需显式处理，不宣称所有设备统一走此分支。
- 固定Android15 GrOvalOpFactory.cpp SHA256=628a133434b28d3e72bdce42702c5a7e1e57c844d7b2d1b29e4398d086cf1de0。新增encodeCoverageRoundedRectangle采用原fill16顶点/54索引；bounds与radius都外扩0.5，offset网格[-1,0,0,1]，Float插值和length后half(radius*(1-d))再saturate写R8。支持MaskSurface平移与content scissor，不加系统圆角/默认模糊；仅coverage fill、轴对齐、radius≥0.5，其他情况明确拒绝。
- GPU测试5半径（0.5/1/5/5.25/7.5）×2原点，共10240像素，对独立边距离公式byte容差1；含最小半径、半高内圈退化、小数坐标、负设备原点、越内容边界和整背板透明。非法radius拒绝后同command仍能继续绘制。不是原Skia网格编译参考或Android设备截图。
- /tmp/ztransfer-20261016-f179-rrect-aa.log 54/54、0失败、TEST SUCCEEDED（52项阴影基础+2项递归）；包括前轮圆形nearest边界测试和矩形/混合合成完整回归，本轮可记单次全绿但不抹去前轮失败。git diff --check通过，索引694不变；未改软件滤波、未重复其234组。
- 实际圆角AA入口已具备，尚未串起exact九宫格纹理+GaussianBlur+采样，也未接平台能力分支、Scene/host、一般path/描边或公共Surface。F179未核销，26/182。未单独构建安装、UI截图、真机、提交或推送。


### F179 exact圆角mask及九宫格GPU采样（2026-10-16）

- makeMaskSurface新增显式MaskBacking.exact，默认仍approximate；先验证非空bounds再选择尺寸，按实际纹理尺寸检查分配预算，继续整纹理透明清场。九宫格缓存必须exact，不能沿用GetApproxSize背板改变纹理坐标。该预算仅负责这一张纹理，不宣称涵盖Gaussian递归全部scratch。
- Renderer新增RoundedRectangleMaskLayer/encodeRoundedRectangleMasks，接收已过滤的exact A8纹理，严格检查计划尺寸/类型/采样能力，使用共用ProfileLayer提交。shader按make_rrect_blur：Float减proxy中心、half符号与edgeSize、半精度裁掉中间段再恢复符号/归一化，最近邻查mask；edgeSize保留原小数shaderCorner，实际mask角保持ceil值，直接乘alpha source-over。
- 集成测试在同command依次分配exact源/结果→CircularRRect AA→GaussianBlur clamp→九宫格合成；sigma0.04/1/8×radius1/5.25共6配置，包含blurRadius0、小sigma与递归大sigma，验证实际尺寸、非空mask、46080个目标像素及黑色输出。CPU独立half坐标warp/最近邻参考使用GPU滤波结果，byte容差2；它验证接线及采样，不冒充完整独立Android最终像素，AA与Gaussian本体由既有独立测试覆盖。
- /tmp/ztransfer-20261016-f179-nine-patch.log 55/55、0失败、TEST SUCCEEDED（53项阴影基础+2项递归）；默认approximate背板、矩形/圆形/混合合成均回归。git diff --check通过，索引694不变；软件滤波未修改、不重复234组。
- 各GPU阶段现可完整串行绘制九宫格圆角，实际Scene/host尚未编排调用；capability分支、圆角缓存/工作集整体预算、旋转矩形、一般path/描边、公共Surface及Android独立像素/连续帧仍未闭环。F179未核销，26/182。未单独构建安装、UI截图、真机、提交或推送。


### F179 回退编排的有序组件记录（2026-10-16）

- 接线审查发现旧TessellatedPreparation只给成功mesh的局部scene和失败recipe字典：成功层没有组件身份、回退层没有已量化alpha，无法直接安全编排混合层。新增PreparedComponent（component/alpha/content）与orderedComponents，按原循环ambient→spot同时保留world-space mesh或blur recipe；零alpha/空mesh省略，投影失败spot只列skipped，已有ambient保留。
- blurFallbacks/failedComponents改由有序记录派生，避免独立字典和顺序状态分叉。旧mesh-only scene暂保留给现有宿主，world mesh保留未减crop的坐标，以便后续把回退bounds纳入同一整体裁剪；不把旧mesh-only crop误用于整个混合阴影。
- 扩展实际tessellated scene/GPU裁剪测试：仿射/非等比/透视×alpha1/0.5验证组件顺序、9/48或4/24透明度、world→local顶点/索引一致及原GPU像素；ambient mesh+sigma0 spot fallback要求有序mesh/blur；spot投影无效仅保ambient、nodeAlpha0记录为空。/tmp/ztransfer-20261016-f179-ordered-components.log 1/1 TEST SUCCEEDED。未改shader/滤波，不重复其55项；git diff --check通过。
- 本步仅补齐生产准备阶段用于混合绘制的数据，不声称宿主已画出fallback。现有host失败门控保持，下一步仍需形状/样式路由与联合bounds、资源缓存/整体预算、一般path/描边、公共Surface及完整像素验证。F179未核销，26/182、索引694不变。未单独构建安装、UI截图、真机、提交或推送。


### F179 ambient/spot回退变换阶段纠正（2026-10-16）

- 对照SkShadowUtils::DrawShadow最后回退：ambient先path.transform(viewMatrix)形成devSpacePath，再应用设备空间strokeAndFill；spot通过SkAutoDeviceTransformRestore(shadowMatrix)绘制原path，未先烘焙路径。原BlurFallback统一注释“transform the path first”不符合spot，已纠正，不能继续作为后续路由依据。
- BlurFallback新增显式TransformApplication/pathTransform/drawingTransform，ambient=.pathBeforeStyle且drawing identity，spot=.drawingMatrix且path identity；原transform和sigma/style保留，filterSigma依旧respectCTM=false的限幅值。后续形状识别/样式处理须据此区分，避免非等比矩阵放大ambient描边或提前丢掉spot原始rrect分类。
- 新测试非等比+剪切+平移下的两阶段矩阵分配，ambient与identity配方的stroke/有效sigma相同，spot保留投影矩阵和fill；原55组配方参考及有序component/GPU裁剪回归同轮运行。/tmp/ztransfer-20261016-f179-transform-stage.log 3/3 TEST SUCCEEDED，git diff --check通过。
- 这是实际配方模型的纠正，尚未有fallback绘制调用消费该阶段信息，不能宣称描边栅格或混合宿主已完成。后续继续形状/样式路由、联合bounds、缓存/预算、一般path/描边与公共Surface。F179未核销，26/182、索引694不变；未单独构建安装、UI截图、真机、提交或推送。


### F179 默认miter矩形回退简化（2026-10-16）

- 固定Android15 GrStyledShape.cpp SHA256=d0ebdc642de03e2e0e1f54d353d3bffdda3e9a6f555aeb193c41b5d5803f1425：simplifyStroke仅对无pathEffect的strokeAndFill矩形作join判定，默认miter且miterLimit≥sqrt2时按width/2外扩并变SimpleFill。SkPaint默认join=miter，SkPaintDefaults_MiterLimit=4。尝试geometry/GrStyle.cpp返回404，本轮结论不依赖该缺失路径。
- BlurFallback新增axisAlignedRectangle：只接原始radius0、非退化且映射后保持轴对齐的矩形（含非等比、镜像、90°交换轴），先映射/排序bounds，ambient按设备空间strokeWidth/2外扩；spot纯填充保原映射bounds，结果携带有效sigma。剪切、透视、奇异、圆角或错误阶段的stroke不伪装成矩形，返回nil交后续路由。
- 新测试已知坐标的非等比/镜像/四分之一旋转，4px stroke始终仅各边外扩2px（不随矩阵放大）；sigma200限幅128、spot sigma0保留，并检查圆角/剪切/透视/奇异/错误stage拒绝。原55配方和变换阶段测试同轮；/tmp/ztransfer-20261016-f179-styled-rect.log 3/3 TEST SUCCEEDED，git diff --check通过。
- 这是后续形状路由的一条有依据的生产判定，尚未由Scene/host调用；其他形状的描边/变换识别、联合bounds、缓存/预算和完整回退仍未完成。F179未核销，26/182、索引694不变。未单独构建安装、UI截图、真机、提交或推送。


### F179 圆形profile有界跨帧缓存（2026-10-16）

- 将circleProfilePlan的标量几何/量化key计算与昂贵profile数组生成分离；原circleProfile入口仍委托相同算法，原生6144字节参考保持不变。Renderer圆形入口先按当前半径/sigma计算plan，命中同key只复用纹理，不再生成kernel/vertical/pixels数组或上传。
- 新renderer实例内LRU最多64张不可变512点R8纹理，按原create_profile_effect定点key（halfPlane=0）复用。每次绘制的solidRadius/textureRadius/center/alpha独立，未把几何参数缓存成第一次的值。淘汰只移除renderer引用，已保留/已编码的texture不改内容；使用既有host串行draw调度，不声明新增线程安全或全局GPU预算。64×512是像素载荷，未声称包含驱动对齐/在途命令的全部显存。
- 实际texture identity测试：不同半径同halfPlane/ratio共用纹理但几何不同；非法请求不取新纹理；63键填充后命中刷新再插入保留热点，64新键后旧texture淘汰；重建与旧保留纹理逐字节相同。原生profile参考和40配置实际GPU圆形像素回归同轮。/tmp/ztransfer-20261016-f179-circle-cache.log 3/3、TEST SUCCEEDED；没有把运行耗时当正式性能基准。
- git diff --check通过，索引694不变。圆角缓存、整体工作集、Scene/host回退编排、一般path/描边与公共Surface仍未完成；F179未核销，26/182。未单独构建安装、UI截图、真机、提交或推送。


### F179 矩形积分表跨帧缓存（2026-10-16）

- 将ComputeIntegralTableWidth独立为廉价参数计算，实际矩形绘制按表宽复用renderer实例内R8纹理；命中后不再逐帧计算erff数组或重复上传。每层sigma、bounds、alpha及采样尺度仍独立计算，不随缓存合并。
- 有效sigma范围(0.03,128]只产生32至2048的七种二次幂宽度，缓存天然有界，像素载荷总计4064字节；不将此数当驱动对齐、在途命令或整个滤波工作集的显存上限。沿用宿主串行调度。
- 已检查实际测试终态：/tmp/ztransfer-20261016-f179-integral-cache.log为3/3、0失败、TEST SUCCEEDED，xcodebuild已结束。覆盖同宽不同sigma的texture identity、七档宽度与上传字节、非法输入拒绝、原生积分表字节参考及实际GPU矩形/保留背景合成回归。
- 本轮补齐该改动验证记录和三项源码索引hash，未重复构建。Scene/host回退编排、圆角缓存、整体工作集、一般path/描边和公共Surface仍未完成；F179未核销，修复进度26/182，索引694不变。


### F179 圆角掩码生产生成入口（2026-10-16）

- 再读固定Android15 GrBlurUtils的make_blurred_rrect_key/fillin_view_on_gpu：缓存键是ceil(sigma-1/6)和整数圆角，首次实际GaussianBlur仍用原sigma。RoundedRectanglePlan现明确保留实际sigma，不能拿sigmaKey替代滤波参数。
- 将此前仅在测试中串联的exact源/结果A8分配、CircularRRect覆盖AA、Gaussian clamp过滤抽为生产encodeRoundedRectangleMask。入口预检两张保留表面的合计像素预算，超预算在编码前拒绝；不声称包含递归scratch、驱动对齐和全部在途资源。调用方仍须显式选择CircularRRect能力路线。
- 原九宫格集成测试改为调用生产入口，6组sigma/圆角、46080目标像素及实际mask读回继续验证，同时测试差1字节预算拒绝和精确预算接受。首轮rrect-production.log因测试纹理变量与读回数组同名而编译失败；改名后/tmp/ztransfer-20261016-f179-rrect-production-fixed.log为1/1、TEST SUCCEEDED，git diff --check通过。
- 尚未加入跨命令缓存或宿主调用；未提交/失败命令的资源不能直接作为后续有效缓存。下一步需处理缓存发布/失效和预算，再接Scene/host。F179未核销，26/182、索引694不变；无真机、提交或推送。


### F179 圆角掩码有界缓存及命令生命周期（2026-10-16）

- BlurRenderer新增roundedRectangleMask入口，按原make_blurred_rrect_key的sigmaKey/整数圆角缓存；仅simple circular路线所以四角八个相同分量可约为单corner。每次调用的proxy位置/原小数shaderCorner仍由调用方plan提供，不缓存为第一帧几何。生成仍用首次请求实际sigma。
- 同一producer command内命中复用，跨command只接受已completed纹理；未提交/尚在途producer不作为跨命令可读缓存，独立生成替代条目。每次访问整理completed并释放producer引用，error条目移除。没有后台回调和CPU等待，沿用renderer串行访问要求；未注入真实GPU失败，error清理分支仅静态核对。
- LRU默认最多64条及4MiB像素载荷，可注入较小预算；超大单纹理正常生成但不驻留，淘汰不改已编码/外部持有纹理。该上限不含驱动对齐、command保留资源和Gaussian scratch，整体工作集仍待独立收敛。缓存命中不消耗生成表面预算。
- rrect-cache.log 3/3 TEST SUCCEEDED，覆盖未提交command隔离、同command同key不同sigma/位置复用、completed跨命令复用、600byte预算淘汰与重新生成，以及原99组参数参考、九宫格回归。随后九宫格像素测试改走实际缓存入口，并增加淘汰旧纹理/重建纹理GPU读回逐字节一致；rrect-cache-pixels.log 2/2 TEST SUCCEEDED。没有故障注入或64条上限专项测试，不将预算测试扩大成所有资源压力验证。
- git diff --check通过；更新renderer/tests索引sha256，694不变。缓存入口已存在，但Scene/host仍未调用圆角fallback；capability选择、完整形状路由/联合bounds、整体预算、公共Surface和独立Android像素仍未完成。F179不核销，26/182；无真机、提交、推送。


### F179 混合回退场景及宿主首条接线（2026-10-16）

- 新ResolvedScene按orderedComponents逐层解析，保留ambient/spot身份和顺序；成功tessellated mesh与已实现的axisAlignedRectangle模糊回退合并world bounds，矩形外扩3*sigma后统一向外取整，再统一平移成纹理局部坐标。不会沿用旧mesh-only crop裁掉回退。
- encodeResolved第一层清透明背景，后续层load/source-over，调用原网格/矩形shader；目标尺寸必须匹配scene。AndroidShadowHost一般变换分支已由failedComponents全拒绝改为resolve并实际编码ResolvedScene；analytic路径继续原入口。不支持的圆角/一般path及sigma<=0.03仍在resolve显式抛错，不发布残缺场景。
- 新构造mesh+spot矩形回退测试验证联合origin/size、组件顺序、完整96×96画布与裁剪输出alpha差<=1、非空像素、空scene及未支持路线拒绝。此为构造的回退配方与GPU合成证据，不宣称已在真实UI触发同一回退。现有一般网格裁剪回归和真实UIWindow宿主多种仿射变换/显隐/布局回归同轮通过；宿主测试主要验证布局，未扩大为连续帧像素验收。
- /tmp/ztransfer-20261016-f179-resolved-scene.log 3/3、TEST SUCCEEDED，git diff --check通过。更新renderer/host/tests索引sha256，694不变。圆形/圆角缓存尚未接此路由，零模糊直接AA、一般路径/描边、capability、整体预算和公共Surface仍待补齐。F179未核销，26/182；未真机、提交或推送。


### F179 矩形identity滤波直接AA回退（2026-10-16）

- 对照固定Android15 GrBlurUtils direct_filter_mask：BlurIsEffectivelyIdentity时AA drawShape，不应先写A8再复合。ResolvedScene现将sigma<=0.03轴对齐矩形归FilledRectangleLayer，专用BGRA coverage shader直接half覆盖乘paint alpha/source-over，不额外A8量化。
- 将既有QuadPerEdgeAA轴对齐顶点算法与30索引移到ZTransferShadowBlur供掩码和直接绘制共用，原normalize/reciprocal/边方程及退化外扩运算顺序不变。identity场景裁剪取实际8顶点bounds，覆盖内圈塌缩时的额外外扩，不仅用固定0.5。
- 新测试普通矩形/细长0.25px/0.25px小方形×sigma0/0.03，共6组实际GPU整图与裁剪alpha差<=1；普通矩形另对独立边距离公式及half alpha乘法byte容差1。原混合回退测试由拒绝identity改为要求filledRectangle路线；共享AA掩码回归同轮运行。/tmp/ztransfer-20261016-f179-identity-rectangle.log 3/3、TEST SUCCEEDED；这不是独立Android设备像素验收。
- git diff --check通过，更新blur/blurRenderer/shadowRenderer/tests四项索引sha256，694不变。宿主通过ResolvedScene消费新路线，但真实UI极端回退触发、圆角/圆形分类接线、一般path/描边、平台AA选择、整体预算和公共Surface仍待完成。F179未核销，26/182；未真机、提交或推送。


### F179 轴保持圆形模糊回退接线（2026-10-16）

- 重读GrBlurUtils direct_filter_mask：圆形判定允许srcCircle+similarity或devCircle，但实际drawRect仍画变换后的srcProxyRect。任意旋转不能直接换成轴对齐代理；本次只接轴保持的设备圆分支，不冒充全旋转支持。
- BlurFallback新增axisAlignedCircle，仅simple fill、原圆、有效非透视轴保持矩阵、映射后等宽高以及sigma>0.03可进入；沿用矩形映射验证和128限幅，描边/椭圆/任意旋转/透视/identity圆仍留给后续路线。中心使用SkRect式Double平均、半径取设备宽度一半。
- ResolvedScene新增circle层，按radius+3原sigma合入联合裁剪，平移中心后调用已有encodeBlurredCircles及有界profile缓存。宿主现可通过统一resolve/encode入口消费该分支，未新增单独场景或重复圆形shader。
- /tmp/ztransfer-20261016-f179-circle-route.log 3/3、TEST SUCCEEDED：缩放/镜像/四分之一转的已知中心半径、完整100×100与52×52裁剪GPU alpha差<=1、未支持矩阵/描边/identity拒绝，以及矩形identity和混合场景回归。属于构造配方和本机GPU裁剪验证，不声称真实UI已触发圆形fallback或独立Android设备像素通过。
- git diff --check通过，更新geometry/renderer/tests索引sha256，694不变。任意旋转代理、近相似容差/圆角转换完整分类、圆角缓存接路由、一般path/描边、平台AA和整体预算仍未完成；F179不核销，26/182。未真机、提交或推送。


### F179 圆角代理绘制整数外扩纠正（2026-10-16）

- 继续核对圆角接线时发现既有encodeRoundedRectangleMasks遗漏direct_filter_mask的ignoreXform分支：Android先devRRect.outset(3*ceil(sigma-1/6)).roundOut，再fillPixelsWithLocalMatrix；实际绘制范围必须整数外扩。此前直接用小数proxy画quad，边缘像素可能被截断，旧九宫格CPU参考也采用同一错误inside规则，不能沿用其通过结论覆盖这一边界。
- RoundedRectanglePlan新增drawRectangle，向外取整供代理绘制；原proxyRectangle保持小数，继续作为ninepatch shader采样参数。Renderer只改quad范围，未改圆角、sigma、缓存键或采样坐标。
- 新实际GPU测试使用全255合成mask隔离代理覆盖，bounds=(4.75,4.75,20.25,24.25)要求整数[4,21)×[4,25)全部像素被绘制，原小数范围外的边缘也必须存在。旧6组真实AA+Gaussian+九宫格测试更新inside为源码roundOut，仍验证原小数warp。/tmp/ztransfer-20261016-f179-rrect-proxy.log 2/2、TEST SUCCEEDED。
- git diff --check通过，更新blur/renderer/tests索引sha256，694不变。圆角尚未接ResolvedScene；本步修正了后续接线前的既有实现偏差，不算F179完成。剩余分类/平台AA/一般path/预算/公共Surface仍保持未完，26/182；未真机、提交或推送。


### F179 简单圆角九宫格回退接入统一场景（2026-10-16）

- BlurFallback新增roundedRectanglePlan，对照SkRRect::transform绝对轴缩放圆角和direct_filter_mask：仅simple fill、轴保持且设备两轴圆角相等、符合九宫格内部条件进入；spot的drawingMatrix必须scale/translate，pathBeforeStyle可先变换四分之一转再以identity绘制。描边、椭圆角、透视/剪切、identity模糊或不可九宫格形状仍不伪装成支持。
- ResolvedScene新增roundedRectangle层，联合裁剪使用整数drawRectangle；translated仅平移proxy，保留实际sigma、小数shaderCorner、整数mask圆角/尺寸。encodeResolved按需创建并保留BlurRenderer，使用既有命令安全LRU生成/复用mask再九宫格合成，ambient/spot顺序不变。当前实现仍是明确的CircularRRect coverage-AA参考路线，其他Skia能力选择未验证，不宣称所有Android设备统一分支。
- 每次miss的源/结果表面预算16MiB，缓存已有4MiB像素载荷/64条上限；不包含递归scratch、驱动及所有在途资源。整体工作集仍未闭环。
- /tmp/ztransfer-20261016-f179-rounded-route.log 3/3、TEST SUCCEEDED：2.625源圆角×2得到5.25采样/6mask圆角、原点17/27和67×47联合裁剪、非空GPU输出与100×100完整目标alpha差<=1、四分之一转的两阶段差异/椭圆角/描边拒绝；混合场景和缓存生命周期回归同轮。此前圆角失败断言已改为要求新roundedRectangle路线。仅构造配方及本机GPU证据，未真实UI触发fallback或独立Android截图验收。
- git diff --check通过，更新geometry/blur/renderer/tests四项索引sha256，694不变。圆角缓存已接宿主统一入口；剩余一般path/描边、任意旋转代理、identity圆角、平台能力、整体预算、公共Surface及完整像素仍未完成。F179不核销，26/182；未真机、提交或推送。


### F179 新场景入口集中回归（2026-10-16）

- 既有testTessellatedSceneCropMatchesFullWindowOnGPU现在同时绘制旧mesh-only crop与生产ResolvedScene，仿射/非等比/透视×alpha1/0.5六组要求origin/size相同、完整BGRA逐字节一致，再对完整窗口保留原alpha裁剪差<=1检查。此前此项只覆盖旧入口，现补齐宿主切换后的实际合成验证。
- 在多条回退接线完成节点集中运行AndroidShadowMetricsTests及ShadowBlurRecursiveTests：/tmp/ztransfer-20261016-f179-routes-regression.log为63+2=65/65、0失败、TEST SUCCEEDED。包含已有源参数/网格/AA/滤波、缓存生命周期、矩形identity、圆形/圆角路由、九宫格、UIWindow/presentation和递归回归。软件box滤波未修改，本轮不重复其独立234组；没有将本轮测试扩大为Android独立像素或真机性能验收。
- git diff --check通过，更新tests索引sha256，694不变。F179剩余一般path/描边、任意旋转代理、identity圆角、平台能力、整体工作集、公共Surface及完整运行验证仍未完成，26/182不变。未真机、提交或推送。


### F179 非圆形圆角identity直接覆盖AA（2026-10-16）

- 将轴保持simple circular设备形状判定从九宫格计划分离；identity drawShape不受九宫格内部空间和spot scale/translate门控限制。ResolvedScene对sigma<=0.03、设备圆角>=0.5、非圆形填充走CircularRRect覆盖AA，仍拒绝描边/椭圆角/未支持变换；圆形identity需要独立Oval/CircleOp路线，未混用本分支。
- 共用原16顶点/54索引grid供A8和直接BGRA绘制，新shader保持Float offset/length、half覆盖及paint alpha乘法，直接source-over，无中间A8量化。场景取网格实际bounds统一裁剪。PackedLayer增加默认0的coverageRadius，通过同一float2绘制参数传alpha/radius；原shader继续读取第一个float。
- 新GPU测试radius0.5/1/5.25/10×sigma0/0.03八组，含胶囊、最小及小数圆角；完整48×48与裁剪alpha差<=1，并逐像素对独立标量边距/half乘法参考byte容差1、验证非空。因改动共享网格和绘制参数，本轮重跑整个阴影组：/tmp/ztransfer-20261016-f179-identity-rounded.log 66/66、0失败、TEST SUCCEEDED（64项阴影+2递归）。
- git diff --check通过，更新geometry/blur/blurRenderer/shadowRenderer/tests五项索引sha256，694不变。CircularRRect能力路线以现有参考实现为限，不替代其他AA能力；identity圆、小圆角<0.5、一般path/描边、任意旋转、整体预算、公共Surface及完整Android运行验证仍未完成。F179不核销，26/182；未真机、提交或推送。


### F179 CircleOp填充identity回退（2026-10-16）

- 对照固定Android15 GrOvalOpFactory.cpp CircleOp/GeometryProcessor与SkMatrix::mapRadius：fill采用kOctOffset=0.41421356237、外接8顶点加中心、24索引；outerRadius=r+0.5，顶点center/halfWidth由外扩bounds重算；Float length后half外缘覆盖。不是CircularRRect16顶点替代。
- 新identityCircle仅接轴保持、simple fill、原圆和sigma<=0.03；drawingMatrix映射源中心并按两向量长度几何平均mapRadius，pathBeforeStyle使用预变换设备圆+identity。ResolvedScene新增filledCircle，实际网格范围参与联合crop；独立CircleOp网格复用与CircularRRect相同的fill边缘shader方程，直接BGRA/source-over，无A8量化。
- 新实际GPU测试半径1/4096、0.25、0.5、5.25、12×sigma0/0.03十组，验证9顶点/24索引、非空、48×48完整与裁剪alpha差<=1，并对独立标量圆距离/half alpha参考byte容差1。圆角identity和原圆形模糊路由回归同轮。/tmp/ztransfer-20261016-f179-identity-circle.log 3/3、TEST SUCCEEDED。新像素组合使用identity矩阵，不能据此宣称已验证所有mapRadius/两阶段矩阵精度。
- git diff --check通过，更新blur/geometry/renderer/tests四项索引sha256，694不变。任意旋转/近相似变换、一般path/描边、小圆角<0.5、其他平台AA、整体预算、公共Surface及独立Android运行验证仍未完成。F179不核销，26/182；未真机、提交或推送。


### F179 identity圆形相似矩阵扩展（2026-10-16）

- 按固定Android15 SkMatrix.cpp isSimilarity默认1/4096容差补独立判定：无skew比较绝对轴尺度且排除近零x；affine先按原Float行列式检查1/4096²退化，再判旋转/反射两种基关系；拒绝非有限和透视。未把rectStaysRect要求强加给CircleOp，旧analytic判定保持不变。
- identityCircle的drawingMatrix路线现接受该相似矩阵、继续映射原中心与mapRadius，不再要求轴对齐设备rrect；pathBeforeStyle仍只接受已支持的轴保持设备圆，不把旋转后的路径元数据假定为circle。带模糊的旋转proxy没有随本步放宽。
- /tmp/ztransfer-20261016-f179-circle-similarity.log 3/3、TEST SUCCEEDED：旋转/反射/临界近相似接纳、中心/半径与实际非空GPU场景、超容差/近零/退化/透视拒绝、pretransformed旋转继续拒绝；原10组identity圆像素及235组analytic/inverse参考回归。新增相似判定用源码边界期望，未声称新增原生C++随机矩阵对照；旋转场景本轮非空验证不是独立像素匹配。
- git diff --check通过，更新path/geometry/tests索引sha256，694不变。带模糊旋转代理、预变换路径分类、一般path/描边、小圆角、其他平台AA、整体预算和公共Surface等仍未完成；F179不核销，26/182。未真机、提交或推送。


### F179 带模糊圆形旋转代理保留（2026-10-16）

- 对照GrBlurUtils direct_filter_mask和SkMatrix::decomposeScale：原圆+similarity时，中心映射后半径取mapVector(0,sourceRadius).length（不同于identity CircleOp的mapRadius）；代理先按3*effectiveSigma/两轴长度外扩原bounds，再映射原四顶点。新增rotatedBlurredCircle用于保留drawingMatrix的simple fill源圆，拒绝pathBeforeStyle未经确认的路径分类。
- DeviceCircle/BlurredCircleLayer可携带四边形proxy；ResolvedScene按四顶点求联合bounds并逐点平移。ProfileLayer改用显式四顶点顶点入口，默认矩形仍生成同序四角；circle真实绘制不以轴对齐bbox替换旋转proxy。所有quad数量/有限性在encoder前检查；mask纹理合成仍用原独立maskVertex。
- 新测试0.8/0.6旋转的四个已知proxy坐标、中心/半径、origin27/37和46×46裁剪、local顶点精确保留、非空GPU输出与100×100完整画布alpha差<=1、预变换路线拒绝。因共用profile顶点入口改变，集中回归阴影和递归组：/tmp/ztransfer-20261016-f179-circle-proxy.log 69/69、0失败、TEST SUCCEEDED，覆盖原矩形/圆形/圆角像素及缓存。
- git diff --check通过，更新geometry/renderer/tests索引sha256，694不变。该新旋转用已知参数和本机GPU裁剪验证，尚非原Android独立截图；预变换路径元数据、任意旋转矩形、一般path/描边、小圆角、平台AA、整体预算和公共Surface等仍未完成。F179不核销，26/182；未真机、提交或推送。


### F179 非等比旋转矩形模糊回退（2026-10-16）

- 对照GrBlurUtils::make_rect_blur：非rectStaysRect时decomposeScale把两轴尺度乘入源矩形，再只反转rotation/translation到fragment坐标，不能把device sigma随逆矩阵一起缩放。新增preservesRightAngles按原Float点积/行列式及1/4096²容差判断，rotatedBlurredRectangle只接保留drawingMatrix的simple fill矩形，拒绝剪切、透视、未支持的预变换/描边。
- BlurredRectangleLayer增加可选inverse/proxy，Scene保留scaled-space bounds，仅将逆矩阵的输入平移和四顶点proxy调整到crop局部。rectangle shader在原half距离计算之前用Float映射fragment pos；原轴对齐入口不启用该分支。代理沿原源bounds按3sigma/两轴尺度外扩并映射，继续共享积分表缓存/四顶点绘制。
- 新测试2×0.5非等比+0.8/0.6旋转，验证非similarity却保持直角、scaled bounds(-20,-5,20,5)、device sigma2、已知中心/角点逆映射、origin22/35和56×50联合裁剪、proxy局部精确保留、非空GPU与100×100整图alpha差<=1、剪切和描边拒绝。
- 因矩形shader/统一路线改变，阴影及递归组回归/tmp/ztransfer-20261016-f179-rotated-rectangle.log 70/70、0失败、TEST SUCCEEDED；git diff --check通过。更新path/geometry/renderer/tests索引sha256，694不变。新路线是源码已知参数和本机GPU裁剪证据，不代表独立Android像素。旋转identity矩形/预变换路径/一般path/描边、小圆角、平台AA、整体预算、公共Surface及完整运行验证仍未完成，F179不核销，26/182；未真机、提交或推送。


### F179 矩阵判定原生参考补强（2026-10-16）

- 新generate_shadow_matrix_reference.py固定Android15 SkMatrix.cpp SHA256=83eece5b45e4090b053dbc7829d6c3df86fb4b9624379972d7dd0d5c8c4965f8，直接抽取并编译is_degenerate_2x2/isSimilarity/preservesRightAngles函数体；shim仅提供矩阵存储/有限输入type flags、标量与vector操作。不是链接完整Skia；本fixture不覆盖NaN/Inf、mapRadius或decomposeScale本体。
- clang++ -O0 -ffp-contract=off，stdin用Float位模式避免十进制二次舍入。固定种子179的2480组包含近零/1/4096边界、两倍容差、任意角度/反射、非等比、随机剪切/透视；生成原始bool结果，Swift逐项对比两属性无差异。
- /tmp/ztransfer-20261016-f179-matrix-native.log 3/3、TEST SUCCEEDED，含2480组两项原生判定、既有identity圆旋转容差和非等比旋转矩形GPU裁剪。未修改生产实现，本步加强接纳边界证据；不是所有变换绘制像素已验证。
- 新fixture已xcodegen，git diff --check通过；新增NativeTests generator索引项并更新Swift测试hash，源码索引695（iOS test128）。F179剩余旋转identity矩形、预变换路径/一般path/描边、小圆角、平台AA、整体预算和公共Surface等仍未完成，26/182不变。未真机、提交或推送。


### F179 GrQuad代理映射运算顺序纠正（2026-10-16）

- 核对旋转identity矩形前补读固定Android15 geometry/GrQuad.cpp，SHA256=e07e27970db9d915750c6ce444bbc711ec568700016f57e99a93d5f958516280。MakeFromRect/map_quad_general实际为a*x+(b*y+t)，不同于此前两条旋转模糊代理复用的SkMatrix.mapPoints分组(a*x+b*y)+t；旧已知参数/GPU裁剪通过不能证明此舍入边界一致。
- 新rectangleQuad提供affine MakeFromRect映射，保TL/BL/TR/BR顺序及scale/translate快速分支；旋转圆形和旋转矩形模糊的proxy均改用它。普通path/control-point map不改，因为对应SkMatrix的运算顺序本来不同。透视/非法bounds明确拒绝。
- 新测试用浮点抵消案例证明旧map结果1与GrQuad结果0的差异，另验证镜像缩放/平移的四角顺序、非法/透视拒绝；两条实际旋转模糊GPU裁剪回归同轮。/tmp/ztransfer-20261016-f179-proxy-map-order.log 3/3、TEST SUCCEEDED；该数值示例不是大坐标实际绘制性能测试。
- git diff --check通过，更新path/geometry/tests索引sha256，695不变。旋转identity AA仍待补：源GrQuad将preservesRightAngles分类为rectilinear，EdgeVectors固定cos0/invSin1，但EdgeEquations还需坏边修正与朝内法线，不能直接套当前轴对齐helper全部假设。F179其他剩余项不变，26/182；未真机、提交或推送。


### F179 旋转identity矩形rectilinear覆盖AA（2026-10-16）

- 将轴对齐coverageRectangleVertices委托共用coverageRectilinearVertices，按GrQuad::kRectilinear保cosTheta0/invSin1及原moveAlong/退化安全内缩/两像素hairline外扩；EdgeEquations补齐invLength>=100时负对边修正及test<-0.01朝内法线翻转，保Float运算分组。仅调用方已确认rectilinear/axisAligned时使用，不作为一般四边形栅格器。
- rotatedIdentityRectangle只接drawingMatrix、simple fill、radius0、sigma<=0.03与preservesRightAngles，使用前轮GrQuad四角映射。ResolvedScene新增线性CoverageLayer，world网格与覆盖值先生成，再仅平移xy参与联合crop，复用直接coverage shader，不误用Gaussian tessellated mesh alpha。
- /tmp/ztransfer-20261016-f179-rectilinear-aa.log 3/3、TEST SUCCEEDED：旋转/镜像×20/0.25/0.005宽六组，GPU完整64×64与裁剪alpha差<=1；普通宽度另对逆旋转标量边距/half alpha参考byte容差1，20/0.25宽验证非空（极细条允许量化为0）。既有轴对齐identity及A8覆盖/裁剪回归同轮。
- git diff --check通过，更新blur/geometry/renderer/tests四项索引sha256，695不变。新网格未新增原生C++顶点fixture或独立Android截图；一般剪切/透视、预变换path元数据/描边、小圆角、平台AA、整体预算和公共Surface仍未完成。F179不核销，26/182；未真机、提交或推送。


### F179 透明遮挡物零模糊快捷路径边界复核（2026-10-16）

- 重新顺序核对Android15的SurfaceDrawContext::drawFastShadow→SkDrawShadowMetrics::GetSpotParams→ShadowRRectOp::Make→fillVertices→GrRRectShadowGeoProc。此路径不是GrBlurUtils的sigma<=0.03 identity filter，不能直接复用新增identity覆盖AA作为等价实现。
- 可复现参数：identity矩阵、非空80×40矩形/圆角矩形、height=601、lightZ=600、lightRadius=800、透明遮挡物且spot alpha>0。GetSpotParams的比例夹到0、scale夹到1、translation为0，因此spot blurWidth=0；transparent分支却把投影宽80加入inset。Make只以scaledInsetWidth<=0拒绝，此例仍创建op。height恰等于600时除法为正Inf后夹到上限，不能将此边界写成height>=lightZ。
- 原生rrect网格的distanceCorrection=umbraInset/blurRadius：圆角半径>0时为Inf，矩形半径0时为NaN，后者diagVal也为0/0；圆形为outerRadius/blurRadius得到Inf。shader把参数降为half并计算z*(1-length(xy))后采样LUT。这里只证明非有限参数可达，未运行原生顶点程序、Android GPU或独立像素测试，不能声称实际必定透明、实心或应跳过。
- 当前Swift网格要求blurWidth>0；Scene对正inset的mesh失败抛invalidMesh，连已准备ambient也不返回。此差异仍未修复，不能通过吞掉spot失败或改成identity填充核销。后续需原生顶点夹具和对应Android渲染证据，再决定非有限shader输入的忠实处理；正常已支持路线仍可继续补齐，不构成整个任务阻塞。
- 核对缓存源码SHA256：SkDrawShadowInfo.h=a297b6bbdb464a51a18a1343f0978bee1663e9df1340bc3a3ffa666c71badee3；SurfaceDrawContext.cpp=f8b319b537800f70f5bb8e091a696facbdbccc80d37fa50c39954e5035bbd11b；GrShadowRRectOp.cpp=197766680a70cf54dfb2ad05beeb8ffb0c28a9b2f1b91838be46f400b9b97215；GrShadowGeoProc.cpp=1c81bc4852f278579c2d5b122b5face5e94e474a1ec0fd67dbca7217e5fe1768。
- 本轮仅源码取证及台账补充，无生产代码修改，未构建/运行测试；源码覆盖索引695不变。F179仍未完成，核销26/182不变。下一块可继续一般路径/描边或小圆角AA路线，不能把此边界当作全部剩余工作。


### F179 零模糊原生顶点诊断（2026-10-16）

- 新增ios/NativeTests/probe_shadow_zero_blur.py，校验固定Android15源码SHA256，直接抽取constructor计算、fillInRRectVerts和fillInCircleVerts，用clang++ -O0 -ffp-contract=off执行。另直接抽取SkPoint::normalize/setLength/set_point_length原函数（SkPoint.cpp SHA256=5534efdc0a13f3e8c69d510ca2d308339673715ef5cd2bbb75ed165aaff6df2b），避免旧普通参考生成器的简化float normalize在零向量上引入假NaN。其余shim只提供存储/类型/算术适配；不是完整Skia或GPU。
- 覆盖矩形r0、圆角r4/20、圆形r4/20，每种blur0/2×inset1/80，共20组。全部position有限；10组blur2控制全字段有限；零模糊矩形全部distanceCorrection为NaN且恰4顶点offset含非有限值；圆角/圆形全部distanceCorrection正Inf，offset有限。报告将非有限数编码为字符串，严格JSON不写NaN常量。
- 运行python3 ios/NativeTests/probe_shadow_zero_blur.py --output /tmp/ztransfer-20261016-f179-zero-blur-native.json；日志/tmp/ztransfer-20261016-f179-zero-blur-native.log为PASS、退出0。此验证确认CPU顶点行为，不验证完整dispatch、half插值、纹理采样、最终Android像素或Swift渲染等价性。零模糊生产拒绝问题仍未修复，不能核销。
- 未改生产代码、未运行Xcode构建/测试，未安装/提交/推送。新增诊断测试索引后源码范围696项；F179未完成、总核销26/182不变。独立Android输出证据仍缺，后续继续其他未完成绘制路线，不把该证据缺口扩大为全任务阻塞。


### F074 裁切任务排除自动去重（2026-10-16）

- 对照安卓TransferViewModel.addNewMediaToQueue的cropRecipe==null过滤和AutoTransferModeTest/NewMediaTransferPolicyTest，TransferQueue.enqueueAutomatic现在仅从cropTask==nil任务构建身份Set。保留原身份规则、输入顺序及批内去重；裁切任务本身和已有普通任务不变。
- AutoTransferModeTests新增生产actor入口验证：仅裁切任务+双卡同身份/同批重复事件，在OFF/ALL/JPG/RAW/VIDEO五档按预期入普通任务，原裁切快照保持，随后同事件不再入队；已有普通与裁切任务两种入队顺序均继续过滤原片。既有相机/目录门控、手动重复、模式切换、目录新增事件和三语回归同轮通过。
- 首轮/tmp/ztransfer-20261016-f074.log因lazy map闭包调用缺少显式self编译失败，未执行测试；修正后/tmp/ztransfer-20261016-f074-fixed.log及对应xcresult为12/12、0失败、TEST SUCCEEDED。git diff --check通过。未真机、提交或推送。
- F074开发侧核销待真机，总核销27/182。T20此前记录的F072/F074两处缺口已修复，但不凭本组自动去重测试恢复整个裁切/保存流程的完成状态；完整运行验收仍待复核。F179及其他未完成项保持开放。源码索引696不变，更新生产queue和测试hash。


### F075 队列执行按钮只按运行态显隐（2026-10-16）

- 对照Android FileListScreen.queueExecutionControl、MainActivity实际waitingCount/控制入口及QueuePillStateTest，新增TransferQueueSnapshot.executionControl：isTransferring优先返回pause，否则存在WAITING返回start，其余nil。PhotoListView两页共用顶栏直接消费该属性，删除原独立VisualMode和已预约首项/飞行隐藏数/延后传输偏好门控。胶囊自己的飞行计数不变。
- 新增状态边界覆盖：尚未认领、交接瞬间空数组、最后一张、等待、完成、失败、取消、仅效果生成及pauseAfterCurrent两值；真实生产queue+ControlledTransferCamera验证单文件无WAITING仍可请求暂停，当前文件正常完成后控件消失。既有多文件暂停/重试不能解除暂停的生命周期回归同轮。
- /tmp/ztransfer-20261016-f075.log及对应xcresult：3/3、0失败、TEST SUCCEEDED；git diff --check通过。UI生产编译通过、显隐直接接此属性；本轮未跑界面点击/截图，飞行和偏好独立性由移除依赖及状态测试证明，不声称完整动画/真机验收。按钮动画、离线准入及其他C15缺口分别保留原范围。
- F075开发侧核销待界面/真机验收，总核销28/182；T23及F179仍未完成。不新增源码文件，索引696不变，更新TransferQueue/PhotoListView/DomainModelTests的hash与证据。未提交或推送。


### F076 队列侧滑状态与动画基础（2026-10-16，未接UI）

- 完整阅读安卓QueueCardSwipe.kt、TransferScreen侧滑/withdraw/remove/收合接线和TransferQueueActionVisibilityTest，新增QueueCardSwipeState接收已越过touch slop的水平delta；调用方统一坐标单位并传48dp对应exitMargin。Float夹到±卡宽，绝对位移达到width*0.33才飞出，速度不参与；飞出及恢复共用已对照Compose的180ms FastOutSlowIn scalar。
- 状态保留flying和单次完成请求；新拖动取消回弹并从当前显示值接续，飞出中忽略新拖动，同配置更新不重启动画。enabled/removing变化按安卓LaunchedEffect恢复规则，结束再次检查最新enabled；变忙/批量清理不发送旧移除请求。isEnabled按卡片非移除、非clearAll、非传输、非生成判断。
- QueueCardSwipeTests五项：左右32%/33%/100%/超宽钳位、179ms不早删/180ms单次完成、取消/回弹中重新拖动、飞出变忙恢复与迟到请求隔离、removing时完成重验、所有任务状态×生成及clearAll资格。/tmp/ztransfer-20261016-f076-state.log及xcresult为5/5、0失败、TEST SUCCEEDED；xcodegen已更新，git diff --check通过。
- 这是未接生产卡片的状态基础，不是侧滑功能已完成；水平触摸slop/与竖向ScrollView竞争、取消/多指交接、UI帧驱动、VoiceOver自定义动作及withdraw→280ms收合→remove仍需接线/运行验证。不得用本组测试声称竖滚不会误删或真实卡片动画已验证。F076未核销，总进度28/182不变。
- 新增状态源码与测试各一项，覆盖索引698（相对696增加2）；未真机、提交或推送。下一步优先接手势宿主，保持卡片现有按钮点击与竖向滚动，并验证卡片变忙的竞态。


### F076 生产卡片侧滑输入接线（2026-10-16，运行验收未完）

- 新增QueueCardSwipeInput/Modifier：沿用项目非hit-testing marker方案，将recognizer挂在最近UIScrollView，触摸起点必须同时落在本卡与滚动视口；scroll pan等待此识别器判定。固定window坐标防止卡片offset反过来放大拖量。8pt水平slop仅发送超出部分；竖向先越过且占优时failed让行，跟踪指针抬起后交接另一指针且不引入位置跳变。
- Marker用CADisplayLink驱动前轮state，复用180ms FastOutSlowIn；配置更新保持最新enabled/onRemove。detach先移除recognizer再invalidate显示链接，避免同步cancel回调重新开启链接留住离屏卡片。新增UIKit UIWindow/UIScrollView实际宿主测试验证附着、marker不参与hit-test、动画中detach后弱引用释放。
- TransferQueueView将clearAllInProgress传给卡片，按统一isEnabled接侧滑及SwiftUI accessibilityActions，飞出后调用onWithdraw→既有280ms收合→actor remove重验。移除卡片外层clipped以允许横向飞出（安卓collapseHeight clip=false）；保留内容自身圆角裁剪。原按钮及撤回后卡片身份保持。
- /tmp/ztransfer-20261016-f076-input.log及xcresult：9/9、0失败、TEST SUCCEEDED（8项输入/状态/宿主与1项生产队列撤回/重试排除回归）。覆盖8pt边界、超出delta、竖向拒绝、等待slop和已拖动两阶段多指交接、资源释放及前轮状态；git diff --check通过。
- 尚未执行真实生产卡片的UI侧滑/竖滚/按钮竞争、VoiceOver操作和视觉动画验收，因此不能声称UIKit竞争和SwiftUI布局已端到端通过。原卡片收合仍使用easeInOut 280ms，安卓为FastOutSlowIn且恢复200ms，此处后续一起修正/验证；本轮没有将F076核销，总28/182不变。下步优先真实卡片交互测试并检查收合恢复。
- 新增输入源码1项，索引699；更新TransferQueueView、QueueCardSwipeTests hash。xcodegen已执行，未真机、提交或推送。


### F076 生产队列UI侧滑与竖滚验证（2026-10-16）

- 新DEBUG QueueSwipeInteractionHarness直接使用TransferQueueView/真实actor队列/撤回收合移除链，12条等待任务，不用手势替身。ZTransferApp增加仅DEBUG测试参数入口；卡片原有移除按钮增加测试identifier。生产收合按安卓改FastOutSlowIn 280ms、失败恢复200ms（原easeInOut 280ms），不改变actor最终资格重验。
- 新QueueSwipeUITests实际拖动：70pt短拖保持数量并回到原x，左/右180pt飞出后分别减少1，随后原卡片按钮点击再减少1；增加显式向上/向下竖滚，断言卡片y确实变化/还原且count保持12后才进入侧滑检查。首版后置条件滚动循环因末项已可点击而未执行swipe，虽通过不当竖滚证据；已补强后重新运行。
- 首轮f076-ui.log因测试宿主同一个UserDefaults跨actor后又使用的Swift6隔离错误编译失败，未执行UI。隔离实例后/tmp/ztransfer-20261016-f076-ui-fixed.log 1/1 TEST SUCCEEDED；补强真实滚动后/tmp/ztransfer-20261016-f076-ui-scroll.log及xcresult 1/1、0失败、TEST SUCCEEDED。这两次均使用生产卡片和UIKit手势。已查看fixed结果保存的截图，卡片移除后列表保持；它不证明动画逐帧曲线或无障碍功能完整。
- F076仍未核销、总28/182不变：手势/飞出途中变忙的真实UI恢复、VoiceOver自定义动作实际触发、多指真实事件与动画逐帧验收尚未跑；此前状态/宿主测试范围仍明确。下一步优先补这两类真实交互，不重复将已有侧滑成功当全功能完成。未真机、提交或推送。
- 索引新增DEBUG宿主与InteractionUITest两项到701；更新App/TransferQueueView hash，xcodegen及git diff --check通过。


### F076 真实拖动变忙验证与无障碍探测边界（2026-10-16）

- DEBUG队列宿主增加单任务忙碌场景：测试按Arm后观察真实QueueCardSwipeInput.Marker的window坐标，只有卡片已实际移动>=30pt才调用真实queue.start；测试相机持下载worker忙碌，不依赖固定延迟碰巧抢到时机。UI测试验证drag=true/busy=true、count=1、卡片x恢复原位、移除按钮消失，再次反向拖动仍保留任务和位置。
- /tmp/ztransfer-20261016-f076-ui-busy.log及xcresult：1/1、0失败、TEST SUCCEEDED。已查看Busy card restored and protected附件，卡片回到正常位置且仍为传输状态。这证明拖动阶段变忙；180ms飞出阶段恰逢变忙仍主要由前轮状态测试覆盖，不扩大为所有时序UI验证。
- 尝试在普通单元测试UIHostingController窗口中递归遍历UIKit accessibilityCustomActions，首次未找到生产卡片动作；加入独立Text.accessibilityAction已知对照后同样找不到。日志f076-accessibility.log和f076-accessibility-control.log均为1项断言失败，不能据此判断生产动作没有发布，也不能记通过。探测源码保存在/tmp/ztransfer-f076-accessibility-probe.swift；无效探测已从正式测试移除，QueueCardSwipeTests SHA256精确恢复到上一轮8项通过版本，没有改生产代码掩盖缺陷。
- VoiceOver实际操作仍未验证，下一步需支持SwiftUI无障碍树的验证方式或真机验收，不能继续重复该无效UIKit遍历法。F076保持未核销、总28/182；其他任务可继续，不把这项验收限制扩成全目标阻塞。多指真实事件及动画逐帧验收范围不变。
- 本轮保留的改动仅DEBUG宿主与InteractionUITest，更新两项索引hash；索引701不变。git diff --check通过，未真机、提交或推送。


### F077 重试资格与共享原片索引接线（2026-10-16，UI验收未完）

- 对照TransferTask.canRetry、TransferScreen.retryNeedsCamera/TransferRetryButton及TransferQueueActionVisibilityTest，TransferQueueItem增加统一canRetry与retryNeedsCamera；actor单项retry亦复用canRetry。单卡仍不显示CANCELLED重试，批量允许；生成中即使有旧错误也不显示重试。
- TransferQueueView单卡与批量改用真实isSessionConnected，而非session对象是否残留；已保存outputURL或当前目录原片索引可离线重试。PhotoListView传共享PhotoListViewModel.hasTransferredOriginal，按任务捕获的destinationFolderName查diskOriginals/queueOriginals，不随当前存储偏好改查另一目录，也不在每张卡片body做磁盘扫描。
- 索引增加transferOriginalIndexRevision发布：磁盘扫描完成/目录更新/队列原片加入时即使当前catalog为空或transferredIDs无变化，重试页面仍会刷新。手动离线准入复用同一查找方法，保留目录代次隔离。clearAllInProgress此前已传卡片，现在重试/撤回/移除按钮统一以cardActionsVisible抑制，生成中的等待卡也不露撤回入口。
- 新真实磁盘用例：没有照片catalog、无outputURL但已存在ZT-JPG原片，异步扫描后修订号增长并可命中；验证AP/STA前缀、大小、captured folder、错误目录与清目录失效、保存outputURL旁路。状态用例验证各状态/旧错误×生成排除，既有原片身份/离线批次与暂停/退出任务重试回归同轮。
- 首轮/tmp/ztransfer-20261016-f077-index.log因测试读取private transferredIDs编译失败，未执行；改为公开availableFiles验证无catalog后，f077-index-fixed.log及xcresult为12/12、0失败、TEST SUCCEEDED。git diff --check通过。实际单卡/批量按钮在旧session断线、有/无本地原片和clearAll中新终态下的UI尚未运行，不据域测试核销F077；总28/182不变。
- 索引701不变，更新TransferQueue/PhotoListViewModel/TransferQueueView/PhotoListView/ExportedOriginalIdentityTests hash；未真机、提交或推送。下一步优先补F077实际按钮资格和清空窗口UI验证；F076无障碍与其他运行缺口仍保留。


### F077 生产重试按钮与本地原片UI验证（2026-10-16）

- 新DEBUG QueueRetryInteractionHarness使用真实TransferQueue失败任务、TransferQueueView卡片、PhotoListViewModel异步磁盘索引及DirectoryAccessStore；故障下载器只抛unavailable，不返回假成功。通过写入真实10字节原片再刷新索引，验证无outputURL的磁盘命中。生产App增加DEBUG路由，单卡/全局重试按钮增加identifier，未改重试业务。
- QueueRetryUITests第一项保留非nil CameraSession但connected=false：两卡及重试全部都禁用；切connected=true全部启用，再断开全部禁用；仅写第一张原片时第一张启用、第二张与批量禁用；写齐后全部启用。此处连接状态由DEBUG宿主驱动，不是物理断线测试。
- 第二项页面session=nil且connected=false：缺原片时禁用；实际磁盘索引到位后启用，点击生产单卡重试后真实queue变为1完成/1失败，剩余缺原片卡和批量仍禁用。队列创建失败任务时使用故障下载器；成功来自本地原片命中，不据本用例声称完整相机断线恢复验收。
- /tmp/ztransfer-20261016-f077-ui.log及xcresult：2/2、0失败、TEST SUCCEEDED。此前域/索引12/12结果保留。尚未运行clearAll 320ms窗口中新出现终态卡的UI瞬态断言，F077保持未核销，总28/182不变；下一步补该窗口，不能用稳定态按钮结果代替瞬态验证。
- 索引新增DEBUG宿主及UI测试两项到703，更新App/TransferQueueView hash；xcodegen及git diff --check通过。未真机、提交或推送。


### F077 清空窗口真实UI竞态及负向对照（2026-10-16）

- DEBUG宿主增加真实队列的一失败/一在传场景；点击生产清空确认后，在clearAllInProgress实际生效时放行等待的故障下载器（60ms后失败）。不改变生产280ms收合或320ms批量清理时间。DEBUG事件记录器观察新失败任务的snapshot与真实按钮onAppear，捕捉清空窗口里出现的新操作；Release不包含这些探针。
- UI测试确认新失败任务确实在窗口内发布（late=true），没有新按钮出现（leaked=false），最终批量清理完成（finished=true）且两张卡移除。初轮/tmp/ztransfer-20261016-f077-clear.log为1/1、TEST SUCCEEDED。
- 为排除只测稳定空列表的假通过，临时仅撤掉cardActionsVisible中的!isClearing做负向对照。f077-clear-negative.log按预期1项失败，xcresult导出942B653E-0602-4302-AD00-1498761CF333.txt明确显示late=true;leaked=true;finished=true。修复文件逐字恢复到临时备份后，f077-clear-restored.log及xcresult再次1/1、0失败、TEST SUCCEEDED。负向改动未保留；失败日志保留，不能记为全轮始终通过。
- 结合前轮域/索引12/12及两项真实重试按钮UI，本项已验证旧session断线、混合本地原片/批量资格、无session页面本地原片重试完成，以及清空中新失败卡不暴露操作。F077开发侧核销待真机，总29/182；F076无障碍/多指与F179等仍未完成，不恢复整个C15/T23完成状态。
- 索引703不变，更新TransferQueueView/QueueRetryInteractionHarness/QueueRetryUITests hash；git diff --check通过。未真机、提交或推送。


### F078 确认资格与顶栏事件接线（2026-10-16）

- 对照安卓transferQueueActionVisibility、资格LaunchedEffect及queueControlActionNonce，增加Snapshot.ActionVisibility；FAB与确认关闭共用资格，排除正在收合卡和clearAll窗口。运行中禁重试但仍可清其他非传输/非生成任务，不能无条件关闭清理确认。
- PhotoListView实际共享开始/暂停动作在通过原门控后递增独立nonce，TransferQueueView接收并关闭确认；资格消失关闭对应确认。没有把普通snapshot变化当控制事件。
- /tmp/ztransfer-20261016-f078-eligibility.log及xcresult：1/1、TEST SUCCEEDED，覆盖运行、生成、取消、离场排除与清空抑制。/tmp/ztransfer-20261016-f078-confirmation.log及xcresult：真实生产弹层UI 1/1、TEST SUCCEEDED，分别打开重试/清理确认并从宿主发控制nonce，另在清理确认展开时由真实actor移除最后失败任务，确认消失且FAB移除。宿主事件验证接收链，不等同实际PhotoListView顶栏点击验收。
- F078仅状态部分已接线；新自动传输的实际UI关闭、最后可清项变生成、各FAB真实锚点Genie、退出遮罩挂载/输入与中途反向动画仍待补齐。保持未核销，总29/182。未真机、提交或推送。


### F078 独立Genie锚点与退场挂载（2026-10-16）

- 对照TransferScreen ConfirmFab、GenieVisibility.kt与GeniePopupLayer.kt：两个确认卡改为各自FAB上方的行内布局，保留12pt间隔；下方清理卡展开会推动上方重试FAB。按钮按26pt图标+16pt内边距，传入实际完整button bounds，由公共mesh限制mouth宽度，不套用其他弹层的圆角缩窄锚点。
- GeniePopupPanel新增可选onProgress，以真实绘制帧和终点输出进度，异步离开布局再交付，丢弃已被新帧替代的通知。卡片与遮罩共享同一时钟；两卡独立mounted直到各自零终点，防旧关闭回调移除重开卡。遮罩按深/浅主题0.4/0.32乘两卡最大进度，退出期间继续挂载并接入拖动消费。删固定bottom92位置与旧0.86 scale/fade，FAB可再次点击关闭。
- f078-genie-progress.log/xcresult 2/2 TEST SUCCEEDED：实际UIWindow/CADisplayLink中间帧、关闭后立即重开无迟到零值、最终关闭零值及既有首帧前关闭测试。f078-inline.log/xcresult生产队列UI回归4/4通过，含前轮资格/nonce及F077三场景。随后将anchor从圆角缩窄改为安卓完整按钮bounds；最终f078-anchors.log/xcresult新增布局UI 1/1通过：两种确认各在自身按钮之上，清理展开推高重试按钮，按钮再次点击关闭后位置恢复。
- 已导出并查看/tmp/ztransfer-f078-anchors-attachments/ABAE7594-14A0-4155-BF05-D611148A343D.png，清理卡位于清理按钮上方、重试按钮在其上方，没有相互覆盖。截图只证明稳定布局，不是与安卓逐帧像素比较。
- F078仍未核销、总29/182：实际新传输/生成资格切换、实际共享顶栏点击、队列退出瞬态遮罩防滚动与真实快速反向仍待UI验证；FAB显隐动画、确认卡文字/按钮度量及公共F179投影还需对照，不能把接入公共Genie当完整动画验收。未真机、提交或推送。


### F078 实际遮罩滚动与运行资格变化（2026-10-16）

- DEBUG重试宿主增加12个真实失败任务场景；UI在清理确认展开后从遮罩区域竖拖，断言确认保持、首卡y不变；轻点遮罩关闭后用完全相同的起终点拖动，断言首卡离开或y变化>10pt，排除列表本来不可滚的假通过。/tmp/ztransfer-20261016-f078-scrim.log及xcresult：1/1、TEST SUCCEEDED。
- 增加真实队列新任务启动场景：原2个失败任务保持，另入队第3个任务，受控下载器令真实worker保持运行，不直接改snapshot。分别在重试确认/清理确认已打开时启动；前者关闭且重试FAB消失，后者保持。两路随后执行生产清理确认，失败任务移除而第3个在传任务保留、isTransferring仍true。/tmp/ztransfer-20261016-f078-activity.log及xcresult：1/1（两次独立启动场景）、TEST SUCCEEDED。
- 本轮仅增加DEBUG宿主和UI测试，无生产行为改动。结果证明稳定展开遮罩的滚动拦截及关闭后恢复，不证明350ms退场中的新手势拦截或中途快速反向；新任务由测试按钮触发真实queue.start，不当作自动入队来源或实际共享顶栏点击已验收。最后可清项变生成、退场/快速反向、FAB显隐与卡片视觉细节仍待补；F078不核销，总29/182。
- 索引703项不变，更新两文件hash。git diff --check通过；未真机、提交或推送。


### F078 遮罩订阅隔离、确认卡度量与快速开关（2026-10-16）

- 将每帧confirmationProgress从父View值State改为引用State持有的ObservableObject，只有QueueConfirmationScrim订阅Published值；父队列不订阅帧更新，挂载/资格仍由原状态驱动。未改Genie时钟、曲线或零终点规则。此为订阅范围结构修正，未测真机FPS或宣称性能量化提升。
- 按app/build.gradle.kts BOM2023.10.01，从Google官方Maven读取POM确认material3=1.1.2，再读取该版sources.jar Button/TypeScaleTokens/InteractiveComponentSize/Surface，缓存/tmp/ztransfer-f078-material3-1.1.2。官方来源https://dl.google.com/dl/android/maven2/androidx/compose/material3/material3/1.1.2/material3-1.1.2-sources.jar。确认卡标题改titleSmall14/20、字距0.1；副文案bodySmall12/16常规字重；标题后4pt、按钮前12pt；按钮labelLarge使用项目已覆写token，视觉最小58x40、垂直8/水平24或12、触区高48。新增公共titleSmall token，未更改其他现有token。
- /tmp/ztransfer-20261016-f078-scrim-isolation.log及xcresult 2/2通过（滚动遮罩、独立行内锚点）；完成全部度量后f078-card-metrics.log及xcresult 2/2通过（锚点/开关、清空窗口新失败），均TEST SUCCEEDED。导出并查看/tmp/ztransfer-f078-card-metrics-attachments/B9C112F8-E3BE-4C76-B620-C2ABAE9BE7C0.png，文案/按钮无截断重叠。
- 首次真实doubleTap反向测试f078-reversal.log 1项失败：DEBUG实际帧报告closing=false;reversed=false;zero=false，未观察到退出中间帧，因此不能证明从已绘制中间帧反向。失败xcresult与/tmp/ztransfer-f078-reversal-attachments完整保留。不改动画时长以迁就测试。
- 将该UI测试明确改为真实快速关闭/重开可用性：DEBUG仅计数生产onToggle动作，确认初次打开+双击共3次动作，再点生产确认实际清空队列。最终f078-fast-toggle.log/xcresult 1/1 TEST SUCCEEDED。它不替代中间帧反向验收；公共host此前2项真实帧测试范围亦不扩大。DEBUG帧记录器保留用于后续定位，不进Release。
- F078仍未核销，总29/182：退出瞬态拖动拦截、生产弹层已绘制中间帧的反向、最后可清项变生成、实际共享顶栏、FAB显隐和自然宽度/公共投影等细节继续跟进。本轮没有以快速双击可用性重定义完整目标。索引703项，更新4文件hash；git diff --check通过，未真机/提交/推送。


### F078 普通退出帧与自然宽度/多行测量（2026-10-16）

- 新生产UI用例普通点击关闭，DEBUG真实进度必须先出现0<p<1且expanded=false，再到零；f078-close-frames.log/xcresult 1/1 TEST SUCCEEDED，报告closing=true;reversed=false;zero=true。证明普通关闭有实际退出帧，不将上轮双击未观察到中间帧误判为所有关闭都直接隐藏。
- 安卓ConfirmCard为widthIn(max=260)而非固定260。GeniePopupPanel新增默认关闭的fitsContentWidth，队列启用自然宽度；其他调用保持原行为。测量锚点放在实际host上，外层仅负责最多260与右对齐。
- 初次fixedSize方案f078-natural-width.log：重试收窄/清理更宽断言通过，右对齐断言把UIKit AX边界当布局边界，382与383.6差1.6pt失败。改按规定右侧20pt检查后natural-width-inset 1/1虽通过，但查看05B44CA1截图发现副文案单行截断，因此该绿色不算布局完成；失败/不充分验证记录均保留。
- 移除fixedSize试法，增加小型QueueConfirmationContentLayout：先取未约束自然宽度，限制内部228（两侧各16后最大260），再按最终宽度重测全部子视图高度；文字左对齐、按钮右对齐，间距4/12保持。初轮natural-layout 1/1及01210FA6截图证明多行恢复，随后自然宽度计算改为先测unspecified再限制，避免以已换行最长行宽二次过度收窄长说明。
- 最终/tmp/ztransfer-20261016-f078-natural-layout-final.log/xcresult 2/2、TEST SUCCEEDED：短重试宽<260、长说明宽=260、说明高度>20（不是单行）、右边距20、各自锚点/行内布局和开关恢复，以及普通退出帧再回归。已查看/tmp/ztransfer-f078-natural-layout-final-attachments/9DC99D26-9B65-4D00-B294-4CB909D79745.png，完整两行说明、按钮无遮挡。
- F078仍未核销，总29/182。退出瞬态新手势拦截、实际生产中间帧反向、最后可清项变生成、共享顶栏点击、FAB显隐/公共投影仍待完成；自然宽度与普通退出验证不替代这些要求。索引703项，更新GeniePopupPanel/TransferQueueView/QueueRetryUITests hash；git diff --check通过。未真机/提交/推送。


### F078 FAB显隐弹簧与双通道中断时钟（2026-10-16）

- 对照TransferScreen两个AnimatedVisibility及本地Compose1.7.6 EnterExitTransition.kt的fadeIn/out、scaleIn/out默认spring(StiffnessMediumLow)：增加QueueFabVisibilityMotion，透明度0↔1与缩放0.6↔1独立Float临界阻尼spring400、默认阈值0.01、中心缩放。初始visible直接为终点，与初始组合不播放进入动画一致；后续显隐保留至两通道都结束，中断延续值/速度。
- 生产两个FAB用常驻可见性包装接线，目标仍是资格或确认mounted；确认Genie未退出完成前不提前退FAB。CADisplayLink只发布包装自身状态，完成/离页停止，离页归位，避免持有无用动画。没有用SwiftUI默认spring替代安卓方程。
- 初轮f078-fab-spring.log/xcresult 1/1通过：100ms解析值(1+20t)e^-20t、初始显示、出入反向值/速度连续和最终卸载。f078-fab-ui.log/xcresult 3/3通过：实际新任务资格切换、自然宽度/独立锚点/切换恢复、顶栏nonce与最后资格移除。两者均TEST SUCCEEDED。
- 再补边界：scale幅度0.4可能先达到阈值，alpha仍在退出；此时反向，两通道仍需共享上一实际帧。ZTransferScalarAnimation.retarget新增可选atFrameNanos，默认保留旧行为，只有FAB组合在任一通道运行时传共同帧；全闲置后新动画不沿用过期时刻。新增300ms scale已结束但alpha未结束、310ms scale必须已前进的解析值断言，防新通道晚一帧。
- 最终f078-fab-clock.log/xcresult 16/16、0失败、TEST SUCCEEDED：两个FAB状态用例、3项Compose参考数学（含90规格/1001曲线采样）、11项原有ButtonMotionController回归。3项UI在共享时钟边界补强前运行；不把它们写成补强后的逐帧UI验收。
- F078仍未核销，总29/182：退出瞬态手势、实际生产中间帧反向、最后可清项变生成、真实共享顶栏及公共投影还待闭环，FAB逐帧与安卓实际画面比较未做。索引703项，更新TransferQueueView/ZTransferScalarAnimation/DomainModelTests hash；git diff --check通过。未真机/提交/推送。


### F078 生产弹层已绘制中间帧反向验证（2026-10-16）

- 将原按钮closure中的开关动作整理为toggleConfirmation，语义不变。DEBUG frame-reversal模式仅在真实Genie退出回调0<p<0.8时调用同一生产开关动作，不修改时钟/时长/曲线，也不替换队列/卡片。首次两次打开/关闭来自UI点击，第三次重开由帧回调确定性触发。
- 新UI用例同时要求closing=true、reversed=true、zero=false（不能先退到零再出现），生产onToggle计数3、Genie panel onAppear仅1次；重新展开后再点击生产确认，真实队列失败任务清空且确认消失。/tmp/ztransfer-20261016-f078-frame-reversal.log及xcresult：1/1、0失败、TEST SUCCEEDED。
- 该证据覆盖生产确认卡与mounted/迟到关闭回调之间的真实渲染中断，不再仅依赖孤立GeniePopupHostView测试；但第三次动作不是实际触屏事件，不能据此声称真机快速手势测试通过。前轮真实doubleTap只证明三次动作和最终可用性，两项证据各自范围保留。
- F078仍未核销，总29/182：退出瞬态新手势拦截、最后可清项变生成、实际共享顶栏、公共投影等仍待闭环。索引703项，更新TransferQueueView/QueueRetryInteractionHarness/QueueRetryUITests hash。git diff --check通过，未真机/提交/推送。


### F079 卡片错误优先级、仅水印名称与当前缺口纠正（2026-10-16）

- F078保留未完成验收项，同时推进可独立修复的F079。重新读取当前代码发现裁切标签/cropEffectsSkipped与frameGenerationSkipped文案已经存在（早先其他生成流程修复带入）；不能继续把原审查时的缺失当当前事实，亦不能因此认定整项完成。
- 对照TransferTaskCardContent/transferTaskEffectText，抽出TransferQueueCardText供生产卡片使用：仅status.failed或frameError非nil展示错误；生成错误优先且加local_photo_batch_failed+ASCII冒号空格，再是传输错误/transfer_failed回退，只渲染一行错误并隐藏效果行。保留安卓nil和空串的区别；已完成任务遗留error不单独展示。
- 仅水印（photoFrameEnabled但无border）显示photo_frame_watermark_short，不再冒充边框模板名。效果skip只在本来有可显示效果时替换，空效果不凭skip标志新增效果行。新增裁切scissors图标和crop_task无障碍文案，标题用bodyMedium并在取消时降为secondary；未声称SF符号逐像素对齐或标题截断已修复。
- /tmp/ztransfer-20261016-f079-card-text.log/xcresult 1/1 TEST SUCCEEDED：水印名称、双错误优先级/前缀、无错误回退、失败隐藏效果、skip有无效果、已完成旧error与空frameError边界。三语资源键已有原文，本轮没有跑三语UI、生成等待/裁切/水印实际卡片截图。
- F079未核销，总29/182：未知ObjectInfo大小与实际下载字节、保留扩展名的长标题截断、生成等待时钟及实景组合验收仍待补齐。F078未完成事项不变。索引703项，更新TransferQueueView/DomainModelTests hash；git diff --check通过，未真机/提交/推送。


### F079 未知文件大小的实际字节数据流（2026-10-16）

- 对照安卓transferTaskFileSizeText：已知ObjectInfo大小优先；未知大小使用task.downloaded，尚无正字节数才显示破折号。iOS TransferDownloadProgress本来已有真实downloaded，但队列此前只用fraction/speed，现新增item/activeProgress.downloadedBytes并接实际回调；完成用CameraDownloadResult.bytes，已完整part发布用其已校验大小，本地原片命中在queue actor读取文件大小。新下载开始清零，卡片绘制不访问磁盘。
- TransferQueueCardText统一大小格式；QueueItemView只接同taskID的高频activeProgress，否则用持久snapshot字节。原已知size优先规则和B/KB/MB/GB格式保留，不从未知size哨兵乘fraction推导假字节。
- /tmp/ztransfer-20261016-f079-size.log/xcresult 2/2、TEST SUCCEEDED。新增真实队列受控下载器用unknownsize/total0发送downloaded1024并挂起，actor中状态仍transferring且显示1KB；实际写2048字节后完成，item与磁盘计数一致并显示2KB；再次session=nil入队同原片，离线命中也记录实际大小。额外检查无字节显示破折号、匹配activeProgress展示及不匹配taskID忽略；另回归前轮错误/水印用例。
- 本轮是actor数据流与呈现helper验证，没有运行未知大小卡片真实UI/真机PTP。F079仍未核销，总29/182：长文件名截断、生成等待时钟与实景组合仍待补齐；F078其他验收不变。索引703项，更新TransferQueue/TransferQueueView/DomainModelTests hash；git diff --check通过。未真机/提交/推送。


### F079 生成等待时钟与跳过时长门控（2026-10-16）

- 对照TransferTaskCardContent.generationWaiting/generationDuration与TransferInfoPill：等待为isGeneratingFrame且startedAt为空且未skip；等待时显示16pt静态Schedule图标，不引入旋转/脉冲。开始计算后恢复已有时长，skip禁止展示残留时长；效果错误仍由前轮错误行优先门控。
- 使用Google官方material-design-icons/src/action/schedule/materialicons/24px.svg原路径转为SwiftUI Shape，包括圆环与指针，缓存/tmp/ztransfer-material-schedule.svg；不是SF clock近似。无障碍使用已有status_waiting。胶囊高度按安卓max(labelSmall行高14,16)+4统一20pt；现有胶囊圆角/渐变/入退场仍归未完F080，不声称整体视觉完成。
- /tmp/ztransfer-20261016-f079-waiting.log/xcresult 2/2 TEST SUCCEEDED：准备等待、已开始、暂停后startedAt为空且保留累计时间、skip、已结束，以及前轮错误/水印回归。最终20pt高度修改后f079-pill-regression.log/xcresult实际卡片离线原片重试UI 1/1 TEST SUCCEEDED。该UI没有生成等待夹具，不当作等待图标截图或生成切换UI已验收。
- F079仍未核销，总29/182：长文件名保留扩展名/文件号的截断以及生成/裁切/水印等实景组合和三语验证待补；F078其他验收保留。索引703项，更新TransferQueueView/DomainModelTests hash；git diff --check通过，未真机/提交/推送。


### F079 长文件名测量与扩展名保留（2026-10-16）

- 新TransferFileTitle组件对照安卓TransferFileTitle：最后一个非首位点号分离扩展名；按实际字重测量，二分最大可容纳UTF-16主名字符数，前半向上取整/后半向下取整，中间省略，扩展名不参与主名压缩。极窄到连省略号+扩展名也放不下时保留安卓最后尾省略的fallback。
- UIKit UILabel以实际宽度/屏幕像素测量并绘制，主名14pt semibold、扩展名14pt regular/secondary，取消主名也secondary；名称/颜色/宽度变化重新拟合，稳定布局缓存宽度。无障碍标签保留完整文件名。生产QueueItemView接入；新文件已xcodegen注册。
- f079-title.log/xcresult 1/1 TEST SUCCEEDED：完整/中间截断、隐藏文件无扩展名、多个点号、中文+文件号、真实字体尺寸/扩展名字重颜色及140→500宽度恢复。f079-title-ui.log/xcresult生产长文件名卡1/1通过，含完整AX名称与写原片后实际离线重试完成。
- 首轮截图814B0B7C确认文件号和.JPG可见，但同时发现错误说明只显示一行；给错误Text明确纵向自然高度并保留lineLimit2，避免布局压缩。最终f079-title-lines.log/xcresult UI1/1 TEST SUCCEEDED；已查看/tmp/ztransfer-f079-title-lines-attachments/5742A1E1-1490-49A3-8224-5334E2FF52C0.png，主名两端/文件号/扩展名保留，错误说明两行，按钮无遮挡。
- F079仍未核销，总29/182：生成等待/跳过/错误、裁切/仅水印/组合的实景三语验收及未知大小UI还待补齐，不能用本次长标题成功代表整项完成。F078遗留验收不变。索引新增组件到704项，更新相关源码/测试hash；xcodegen及git diff --check通过。未真机/提交/推送。


### F079 卡片内容间距复核（2026-10-16）

- 对照安卓TransferScreen.kt的TransferTaskCardContent（rowGap=5.dp，两行胶囊Arrangement.spacedBy(5.dp)），将iOS QueueItemView内容纵向间距、文件信息胶囊间距、效果胶囊间距从6改为5pt；标题图标间距按安卓保留6pt。
- 本次仅静态核对和git diff --check，未构建、未运行测试或截图验收；不增加核销数。F079生成等待/跳过/错误、裁切/水印组合的三语实景与未知大小UI仍待验证，F078遗留项保持未完成。


### F079 generation card presentation validation (2026-10-16)

- DEBUG QueueCardPresentationHarness renders the production QueueItemView with a stable task ID and controlled waiting/skipped/error snapshots. Old timing and transfer-error values are retained to exercise precedence. Unknown ObjectInfo size uses downloadedBytes=2048. This tests presentation, not the actor lifecycle or real PTP.
- UI test launches en/zh-Hans/zh-Hant separately using the app_language argument domain. Initial f079-states failed because the test queried the clock Shape as Image; the corrected query matches its exact accessibility label across element types. Production clock code was unchanged.
- /tmp/ztransfer-20261016-f079-states-ax.log and xcresult: 1/1, zero failures, TEST SUCCEEDED. All nine PNGs in /tmp/ztransfer-f079-states-ax-attachments were visually inspected: clock visible while waiting, skipped hides old timing, generation error replaces effects and transfer error, two-line error remains clear of buttons, filename number/extension survive narrower width.
- F079 remains open, closure count 29/182. Crop/filter combinations, cropEffectsSkipped, cancellation and dynamic unknown-size UI still need verification. F078/F080 remain separate. No physical-device validation, commit or push.


### F079 裁切组合与滤镜名称三语修复（2026-10-16）

- 复读安卓transferTaskEffectText/photoFilterDisplayName，发现iOS直接显示preset.name导致内置滤镜始终中文。现按Np3FilterCatalog身份查photo_filter_builtin资源，非内置保持原名；静态核对50项资源键无缺失。未扩大到其他编辑器的名称显示。
- 扩展现有DEBUG生产卡片夹具为有效16x16裁切配水印/内置滤镜、cropEffectsSkipped、cancelled三态。UI分别启动英文/简中/繁中，验证组合名称/跳过替换/取消无重试。首轮f079-crop-localization失败：测试误写63%，而两端归一化规则均为64%；只修测试预期。
- 最终/tmp/ztransfer-20261016-f079-crop-localization-fixed.log/xcresult为1/1、0失败、TEST SUCCEEDED（三次启动、九张截图）。已查看英文组合、繁中effects-skipped、简中cancelled三张：英文长效果行单行省略且操作按钮无遮挡，跳过行正确，取消标题降色；完整效果文案在AX断言验证。其余六张未逐张查看，不宣称全部视觉验收。
- F079仍未核销，总29/182：仅裁切、动态未知大小、裁切Material图形（当前SF scissors近似）及剩余验收仍需补齐；F080动画/胶囊视觉保持独立。更新两处源码/测试索引hash，git diff --check通过。未真机/提交/推送。


### F079 裁切图形对齐（2026-10-16）

- QueueItemView裁切标记由SF scissors替换为QueueCropIcon Shape，按Google Material ContentCut 24px官方SVG的直线/三次贝塞尔路径转换，保留14pt尺寸、蓝色和crop_task无障碍标签。来源https://raw.githubusercontent.com/google/material-design-icons/master/src/content/content_cut/materialicons/24px.svg，下载留/tmp/ztransfer-material-content-cut.svg；源码注明来源。不以SF近似图形宣称对齐。
- 最终/tmp/ztransfer-20261016-f079-cut-icon.log/xcresult：三语裁切组合UI1/1、0失败、TEST SUCCEEDED。已查看英文组合截图/tmp/ztransfer-f079-cut-icon-attachments/E25A2A22-888F-4781-A3FA-06B128FFA308.png，图形清晰且标题/操作按钮无遮挡。未做安卓与iOS逐像素截图比较，其余八张本轮未逐张检查。
- F079仍未核销，总29/182；仅裁切、动态未知大小和剩余三语长标题验收继续待补。F078/F080保留各自范围。更新TransferQueueView索引hash，git diff --check通过；未真机/提交/推送。


### F079 最后场景验证与开发侧核销（2026-10-16）

- DEBUG生产卡片夹具增加仅裁切模式：同任务等待0字节→下载中item仍0但activeProgress=1024→完成item=2048且传入另一任务9216字节；UI要求依次显示破折号/1 KB/2 KB，禁止串用另一任务9 KB。同时用超长文件名，三语每阶段均保留完整AX标题和仅裁切标签。
- /tmp/ztransfer-20261016-f079-crop-download.log/xcresult为1/1、0失败、TEST SUCCEEDED（三种语言各三阶段）。已逐张查看/tmp/ztransfer-f079-crop-download-attachments全部九张截图：裁切图形/标签、文件号123456与.JPG可见，等待/下载/完成操作空间变化后重新拟合，无文字/按钮覆盖。此为真实生产视图受控快照测试，不冒充实际相机下载；实际queue未知大小回调→真实文件完成→离线命中由此前f079-size的actor用例覆盖。
- 核销逐项证据：仅水印/等待/跳过/生成错误三语见f079-states-ax；裁切+水印+内置滤镜本地化、cropEffectsSkipped、取消三语见f079-crop-localization-fixed及图形替换后f079-cut-icon；未知大小真实数据流见f079-size，动态呈现见本轮；长标题字体/二分测量/扩展名/宽度恢复见f079-title，真实队列失败两行与离线重试见f079-title-lines，三语长标题见本轮；错误nil/空串/双错误优先级及等待/暂停/skip门控见f079-card-text和f079-waiting。上述日志本轮重新核验成功标志，失败历史保留。
- F079开发侧已修复待真机，总30/182。尚未实际相机/真机三语验收或跨平台逐像素比较；不据此恢复C15/T23整体完成。F078确认控件验收、F080胶囊/卡片动画视觉等继续独立未完成。未提交/推送。


### F080 信息胶囊静态外观与文字颜色（2026-10-16）

- 对照安卓TransferInfoPill：由Capsule/纯色填充描边改6pt圆角、垂直三段填充与三段内描边；顶段使用现有Compose Oklab插值。glassSheen在安卓随后copy alpha=0.15/0.32，两个主题最终都是相同白色端点，不能重复乘原sheen透明度。颜色mix方法从文件private改模块内共享，未复制算法。
- 修复zTransferText内部primaryText覆盖外部foregroundStyle的问题：胶囊改labelSmall typography后再设语义色，恢复大小灰色/效果紫色等。20pt高度、水平7pt、等待16pt保留。
- 首轮f080-pill-surface编译失败因原mix是文件私有；调整访问级别后/tmp/ztransfer-20261016-f080-pill-surface-fixed.log/xcresult三语状态UI1/1、0失败、TEST SUCCEEDED。已查看英文等待截图/tmp/ztransfer-f080-pill-surface-attachments/4C54A76E-8266-4E8F-81B2-C443D3BD71F5.png，圆角、紫色文字与等待时钟无遮挡；未做暗色/四皮肤或逐像素验证。
- F080仍未核销，总30/182；来源X收缩/分裂弹簧、宽度变化、卡片/空态/顶部胶囊等原条目仍待补齐。F079内容核销不等于F080外观完成。更新TransferQueueView/ZTransferColors索引hash，git diff --check通过。未真机/提交/推送。


### F080 进度换任务取消归零等待（2026-10-16）

- 对照TransferProgressMotion.kt及Motion.progress：每个resetKey独立从0起步、同任务只接受向前目标，临界阻尼stiffness180/threshold0.0005。删除旧220ms反向归零动画、resetTask和resetting/pending等待状态。新增SmoothTransferProgressMotion复用ZTransferScalarAnimation，身份切换原子重置值/速度/接受上限，新目标立即准备下一帧追值；同身份更新保留速度，空闲后重新追值不沿用旧帧时间。
- SmoothTransferProgress通过局部StateObject/CADisplayLink发布实际值，结束停钟，离页释放并重置；卡片波浪/照片状态圆环继续复用同一组件。没有给上层队列新增全局帧订阅。
- /tmp/ztransfer-20261016-f080-progress.log/xcresult单元1/1、TEST SUCCEEDED：100ms临界弹簧解析值、连续目标速度保留、回退/NaN门控、新身份值/速度归零且100ms已前进、Infinity归零及上限归一化。/tmp/ztransfer-20261016-f080-progress-ui.log/xcresult真实队列长标题/写本地原片/离线重试UI1/1、TEST SUCCEEDED。该UI验证接入回归，不是逐帧录制或真实相机连续换文件证明。
- F080仍未核销，总30/182：胶囊分裂/回弹/宽度、卡片/空态/顶栏等遗留项和实际换任务画面仍需补齐。更新TransferQueueView/DomainModelTests索引hash，git diff --check通过。未真机/提交/推送。


### F080 来源胶囊收缩与回弹（2026-10-16）

- 对照TransferInfoPill LaunchedEffect(respond)：初次respond=true不播放，仅false→true从1 snap起步，105ms FastOutSlowIn收缩到0.94，再以Motion.bouncy（本轮当时误用stiffness200/damping0.5；实际应为400，见后文更正；默认Float阈值0.01）回到1；false取消在当前值，无额外恢复动画。新增TransferPillResponseMotion复用标量动画，局部CADisplayLink完结停钟/离页释放，重新出现按当前respond静止1初始化。
- 生产接线：大小respond=transferring且speed非空；速度respond=elapsedMs非nil；效果respond=isGeneratingFrame且未skip且显示生成时长非nil。仅X缩放，leading锚点保持左缘；不把整个胶囊或文字做XY缩小。
- /tmp/ztransfer-20261016-f080-response.log/xcresult单元1/1 TEST SUCCEEDED：初次true安静、105ms端点、回弹前进、false取消保持值、再次true归1及重复true不重置速度。补挂载初始化后f080-response-ui.log/xcresult三语等待/跳过/错误回归UI1/1 TEST SUCCEEDED。该UI检查接线回归，未触发并逐帧量测false→true收缩；实际滚出重入、取消中断的渲染证据仍待补，不当作完整动画验收。
- F080仍未核销，总30/182。新胶囊分裂/退场、内容宽度140ms、卡片/空态/顶栏等原范围继续待补；F078未完成项保留。更新TransferQueueView/DomainModelTests索引hash，git diff --check通过。未真机/提交/推送。


### F080 卡片主体尺寸与色标（2026-10-16）

- 对照TransferScreen Row/QueueThumbnail：图片52→68pt、图片圆角8→10pt，外层56→72pt并让缩略图居中、状态徽标对齐72pt容器右下角；卡片及进度裁剪14→16pt，横12/纵12改横12/纵10。补非测量overlay状态色标，宽2.5/高32/左偏5/alpha0.65，居中绘制且隐藏无障碍/禁用命中。
- /tmp/ztransfer-20261016-f080-card-geometry.log/xcresult为2/2、0失败、TEST SUCCEEDED：三语等待/跳过/错误及仅裁切/未知大小/长标题。已查看英文错误67BCA919及下载中AD586CB2截图（/tmp/ztransfer-f080-card-geometry-attachments）：放大缩略图后错误仍两行、按钮无遮挡，长标题重新拟合且扩展名和文件号尾部可见。未逐张检查其余16图，不声称全主题视觉验收。
- F080仍未核销，总30/182；后续需统一卡片与徽标的安卓状态优先级、语义红绿颜色及300ms颜色插值；当前标记使用既有stateColor，不能宣称颜色完整对齐。底色/渐变边/sheen、内容高度动画和其余原范围继续待补。更新TransferQueueView索引hash，git diff --check通过。未真机/提交/推送。


### F080 共享卡片视觉状态（2026-10-16）

- 抽出TransferCardVisualState供QueueItemView和QueueTaskStatusBadge共用，按安卓transferCardVisualState顺序：generating→waiting→transferring→failed/非nil生成错误→completed→cancelled。修复旧frameError抢在waiting/transferring之前的问题；卡片完成/失败由系统green/red改项目statusConnected/statusError，与徽标一致。保留现有SF状态符号，图形/弹出动画另行对照，未冒充完成。
- /tmp/ztransfer-20261016-f080-visual-state.log/xcresult：1/1、0失败、TEST SUCCEEDED，五种传输状态分别覆盖普通/残留生成错误/生成中三组合（15项状态断言）。生产两处直接消费同一enum，去掉重复判断。仅状态单元验证，本轮未运行新UI或截图。
- F080仍未核销，总30/182。下一步需300ms颜色动画、共享sheen/渐变边，以及徽标图形/弹出和此前胶囊/空态/顶栏等剩余范围。更新TransferQueueView/DomainModelTests索引hash，git diff --check通过；未真机/提交/推送。


### F080 卡片底色、sheen与渐变边（2026-10-16）

- 对照TransferScreen cardContainerColor/cardSheen/cardBorder：底色改surface与状态色Compose插值0.09；原secondarySystemGroupedBackground叠0.055透明状态色移除。sheen位于液面进度上/文字下，明0.10暗0.08白到透明；边框1pt内描边为白0.32→明黑0.06/暗透明→黑0.08。surface明白/暗1E1E1E与安卓一致，复用既有mix实现。
- DEBUG呈现宿主新增明确明暗开关，测试分别启动两主题、等待与失败。/tmp/ztransfer-20261016-f080-card-surface.log/xcresult为1/1、0失败、TEST SUCCEEDED；已查看/tmp/ztransfer-f080-card-surface-attachments四张截图（193DC65E/09EC38FF/FAA07A28/CB27BC2D），状态色/边框高光/文字可见且无遮挡。未跨平台逐像素比较或四皮肤遍历，不把明暗四图当全部视觉完成。
- F080仍未核销，总30/182；300ms颜色过渡、徽标图形/弹出、胶囊进退场/宽度、空态/顶栏等仍待补齐。更新TransferQueueView/QueueRetryUITests索引hash，git diff --check通过。未真机/提交/推送。


### F080 卡片状态色300ms过渡（2026-10-16）

- QueueCardAccentAnimator用现有ZTransferColorAnimation(duration300)复刻animateColorAsState的FastOutSlowIn/Oklab路径，底色9%混色与左侧marker共用同一显示值。首次挂载直接采用真实颜色，状态/明暗变化重定向，完成/离页停CADisplayLink，重入重新静止初始化；局部卡片持有，不给整个队列增加帧订阅。底色/色标禁用外层隐式动画，避免已经逐帧计算的颜色再被系统动画二次插值。
- f080-card-color.log/xcresult 2/2、0失败、TEST SUCCEEDED：新增300ms中途非端点/150ms重定向/450ms到新终点/同色不重启，以及既有Android颜色参考fixture回归。f080-card-color-ui.log/xcresult明暗等待→跳过→失败回归1/1 TEST SUCCEEDED。该UI验证生产接入和最终内容，不是300ms中间帧像素对照；逐帧实际颜色与中断渲染仍待补。
- F080仍未核销，总30/182；徽标图形/弹出、胶囊分裂/宽度、空态/顶栏和四皮肤等剩余范围继续跟进。更新TransferQueueView/DomainModelTests索引hash，git diff --check通过。未真机/提交/推送。


### F080 徽标前景与内边框（2026-10-16）

- 对照TransferScreen.kt TaskStatusBadge的22dp Surface、2dp border及Color.kt onAccent：新增共享onAccent色（明FFFFFF/暗121212），徽标不再固定白图标；边框由页面background改surface，stroke改strokeBorder，保持外径22且向内描边。
- 本轮仅静态对照与git diff --check，未运行构建、测试或模拟器，颜色实际渲染尚待验证。SF图形/13dp图标、0.62起步400 stiffness/0.5 damping回弹（原记录误写200，后续已纠正）、180ms交叉淡入尚未修正，不把本次静态修正当作完整徽标完成。
- F080仍未核销，总30/182；其余胶囊/空态/顶栏及原范围保持开放。未真机、提交或推送。


### F080 徽标原始图形、回弹与交叉淡入（2026-10-16）

- 新增QueueTaskStatusBadge独立组件，移除原SF徽标与近似SwiftUI spring/transition；QueueBadgeMotion复用现有标量动画，首次挂载/换任务/重入静止1，每次visualState改变snap 0.62、零速度，当时误以stiffness200/damping0.5回到1（实际应为400，见后文更正）。背景直接采用目标状态色；只让图标交叉淡入，整枚徽标共同缩放，禁用外部隐式动画叠加。弱引用显示时钟代理、完成/离页停钟，owner消失时回调自行失效。
- 依据Google Maven Compose animation与animation-core 1.7.6 sources.jar中的Crossfade.kt/Transition.kt/VisibilityThresholds.kt：正常alpha tween180 FastOutSlowIn；当时误认为中断只重建数字目标改变的通道（后续已纠正：Transition切换segment强制重建所有通道，见后文更正）；新状态从0进入，旧图层保持原顺序并在全部alpha结束后清理。缩放与alpha生命周期独立。
- QueueBadgeIcon逐路径移植同版本material-icons-core/extended的Filled Schedule/Downloading/AutoAwesome/Check/PriorityHigh/Close，24×24 viewport缩到13pt；包含相对坐标和反射曲线展开，PriorityHigh圆点采用相同圆心/半径圆形，保留来源及Apache许可注释。图标使用onAccent、22pt底圆及surface内描边沿用前轮修复；去掉旧enum SF icon映射。
- 首轮f080-badge-motion编译失败（代理缺MainActor）；第二轮f080-badge-motion-fixed编译失败（nonisolated deinit访问CADisplayLink）。均保留日志；代理显式MainActor、移除非法deinit并在owner消失时invalidate后，最终/tmp/ztransfer-20261016-f080-badge-motion-isolation.log/xcresult **2/2、TEST SUCCEEDED**。验证100ms独立解析弹簧值、180ms淡入终点先于回弹结束、三状态中断默认弹簧值/速度、复用旧图层及静止重置；非实际渲染逐帧证据。
- 新增DEBUG六状态循环，使用真实QueueItemView；f080-badge-icons-ui.log/xcresult **1/1、TEST SUCCEEDED**，明暗各六状态并循环回等待。已查看/tmp/ztransfer-f080-badge-icons-attachments中六张代表截图：明等待D1C6F8C8、传输D335089B、生成427F2285、完成8EBCB320，暗失败AF3D6654、取消44F6CC74；图形可辨、颜色/边框与布局无明显遮挡。其余六图已导出但未逐张检查；未做安卓独立像素/动画中断帧、滚动重入或四皮肤验收，不把本次视图回归当完整F080完成。
- xcodegen已更新，覆盖索引新增两个生产文件到706项；git diff --check通过。F080仍未核销，总30/182。胶囊进退场/140ms宽度、卡片布局动画、空态/顶栏等原范围继续待补；未真机、提交或推送。


### F080 胶囊内容宽度140ms（2026-10-16）

- 对照TransferInfoPill的animateContentSize(tween140 FastOutSlowIn)及Compose 1.7.6 AnimationModifier.kt：新增QueuePillWidthMotion，初次测量静止，按displayScale转换IntSize宽度像素；中断从已显示整数像素起步，再用140ms曲线到目标。固定20pt高度沿用原规则，因此仅宽度需要动画；密度变化重建测量，不沿用旧密度像素。
- QueuePillWidthLayout按父proposal测量目标内容，仅报告动画中的占位宽度；HStack最小/最大探测仍使用内容尺寸，子内容TopStart放置并保持目标宽度，避免用动画宽度反过来截短文字、反复改目标。内容视口先clip，外层再画现有渐变shell和内边框。GeometryReader只观察实际子布局，不复制一份文字作测量。复用TransferPillResponseAnimator现有显示时钟，宽度和响应回弹任一活动时运行，离页清宽度，禁用外层隐式动画二次插值。
- 首轮f080-pill-width编译失败（可选animation同时读写触发Swift独占访问），改为先保存显示像素再retarget，保留失败日志。最终/tmp/ztransfer-20261016-f080-pill-width-fixed.log/xcresult **单元2/2+UI1/1、TEST SUCCEEDED**：140ms重定向端点/整数像素/同目标静止/无效输入与密度切换，已有来源胶囊响应回归，三语真实队列卡大小—→1KB→2KB。已查看英文等待3FF52E64、传输E31979BD、繁中完成C44B7CC8三张截图；其余六图仅导出，未逐张检查。
- 新增DEBUG受限120pt胶囊宿主；f080-pill-width-layout.log/xcresult **UI1/1、TEST SUCCEEDED**。实际检查短文本→超长文本≤120pt→等待图标30pt→原短宽度，左缘固定、高度20；三张截图F0E62559/4BDC0C63/EC8796B8均已查看，长文本正确省略、外壳随尺寸收缩。此测试是最终布局与运行接线证据，未捕获真实140ms中间帧/中断渲染、滚动重入或多胶囊同时争用行宽，不作为完整动画验收。
- xcodegen已更新，索引新增QueuePillWidthLayout到707项，git diff --check通过；测试结束后只整理DEBUG宿主缩进。F080仍未核销，总30/182；进退场的delay/宽度spring/slide/scale与卡片、空态、顶栏剩余范围仍待补齐。未真机、提交或推送。


### F080／顶栏接住回弹：MediumLow常量纠错（2026-10-16）

- 在准备胶囊进退场时重新核对Compose 1.7.6 animation-core sources.jar的VectorizedAnimationSpec.kt，确认Spring.StiffnessMediumLow=400、StiffnessLow=200、DampingRatioMediumBouncy=0.5。此前把Motion.kt的MediumLow映射为200是实现/文档错误，旧徽标测试也使用200计算期望；之前绿灯不能证明安卓参数正确。上文历史记录已就地标注错误，保留当时测试结果，不伪装为此前已正确。
- ZTransferAndroidMotion集中定义bouncyStiffness400/bouncyDampingRatio0.5及Float bouncy spec；QueueBadgeMotion与TransferPillResponseMotion改用该spec。MainActivity.kt:446–453另证实顶栏catchScale同用Motion.bouncy，故PhotoListView QueueControlsCatchEffect的SwiftUI物理spring也改用共享常量，阻尼系数=2×0.5×sqrt400。只纠正该弹簧参数，未宣称既有SwiftUI接住动画的时序/中断/重入完整复刻。
- 已纠正两份技术文档（iOS-队列速度胶囊复刻、iOS-照片列表入队动画修复）的错误200，并明确历史静态截图/构建证据局限。源码/测试中误用的stiffness200已清除；不据此认定其他近似SwiftUI动画全部对齐。
- /tmp/ztransfer-20261016-f080-bouncy-correction.log/xcresult **3/3、0失败、TEST SUCCEEDED**：徽标100ms解析公式期望改为源码400（不引用生产常量），胶囊新增105ms收缩后50ms回弹的独立解析值，徽标交叉淡入中断回归通过。新生产参数已编译；本轮未新增UI截图、实际接住触发或逐帧跨平台对照。
- F080仍未核销，总30/182；胶囊进退场仍未接入。后续实现须注意源码slideInHorizontally的-minOf(it,8)单位是原始像素，不是8dp；默认尺寸/alpha/scale回退spring也应读具体Compose常量，不能沿用先前200推断。速度/传输时长的内容闭包使用当前nullable值，退出时内容本身可能清空，不能擅自保留旧文案替代安卓行为。
- 覆盖索引仍707项，更新5个生产/测试文件hash；git diff --check通过。未真机、提交或推送，测试进程已结束。


### F080 Transition重建纠错与延迟tween参考（2026-10-16）

- 进一步读取Compose 1.7.6 Transition.updateTarget→resetAnimations→TransitionAnimationState.resetAnimation/updateTargetValue，发现此前“数字目标不变则不重启”不适用于整个Transition切换segment：resetSnapValue强制所有通道重建。QueueBadgeMotion现对所有保留图层force retarget；未结束的tween统一切换critical1500，包括旧图层仍然target0的情况。新增同目标旧层在三态切换后20ms的独立解析值断言。f080-badge-reset.log/xcresult 2/2 TEST SUCCEEDED；上文错误说明已就地标注，不把之前未覆盖该分支的绿灯当等价证据。
- 为后续胶囊进退场扩展ZTransferAndroidMotion.tween的delayMilliseconds（默认0，原调用保持原行为）。直接按FloatTweenSpec 1.7.6实现总时长、延迟钳位和速度：该版本速度有限差分会把已减过delay的时间再传入getValueFromNanos，因此实际再次减delay；不能用理想曲线导数替代其源行为。零时长+延迟也按库结果处理。
- ZTransferScalarAnimation新增显式retainsEndVelocity开关，默认false仍对应Animatable.endAnimation清零；徽标alpha使用true对应Transition保存TargetBasedAnimation结束速度。reset保留该模式，回弹scale继续默认清零。其他既有Transition组件未在本轮统一迁移，不宣称它们已经完整对齐。
- 扩展ios/scripts/generate-android-motion-fixtures.py，直接运行本机缓存的Compose 1.7.6 AAR类，新增200ms×60/80/150ms延迟与0ms+60ms延迟，保留原100组。首轮运行因脚本旧数量校验100而失败，未覆盖fixture；修正后f080-delayed-tween-oracle-fixed.log成功生成140组和1001缓动点，AndroidMotion.json保留依赖sha256来源。失败日志同名不带fixed保留。
- /tmp/ztransfer-20261016-f080-delayed-tween.log/xcresult **13/13、0失败、TEST SUCCEEDED**：140组原库值/速度/时长对照（含原零延迟组）、1001缓动点、默认结束清零/显式保留及reset模式、延迟边界、整数重定向和两项徽标回归。未运行新UI、退出反向真实逐帧或真机验证。
- 后续胶囊实现还须遵守：PreEnter→Visible才用延迟tween/bouncy400，PostExit→Visible走默认400弹簧；slide为8个物理像素；全部通道共用Transition帧基准。速度/传输时长nullable内容退出可能变空，IntSize高度也可能变化，不能只建宽度动画或保留旧文案代替。该进退场组件仍未实现/接线，F080不核销，总30/182。
- 索引仍707项，更新6个已索引Swift源码/测试hash；生成脚本与JSON参考资源按既有索引范围不新增条目，证据在此记录。git diff --check通过。未真机、提交或推送，测试进程已结束。


### F080 胶囊进退场生产接线（2026-10-16）

- 新增QueuePillVisibility及独立状态/双轴尺寸模型，接速度delay60、传输时长delay150、生成等待/时长delay80；删除原0.86近似transition和效果整行额外0.82入退场（安卓只对行内生成时长胶囊做该动画）。速度/传输时长闭包仍使用当前nullable值，不保留旧文本；生成胶囊按原源码保留当前空字符串/等待标记直至退出结束。
- 首次visible=true静止；PreEnter→Visible alpha/scale分别200ms FastOutSlowIn+对应delay，scale从0.78、leading锚点；尺寸Motion.bouncy400/0.5，slide360/0.62从-min(fullWidthPixels,8)，clip=false。正常退出alpha100ms、IntSize默认critical400；PostExit反向Visible走默认400，无重新delay/0.78。Transition切segment强制重建各通道，未完成tween中断换critical1500，保留结束速度；共同帧基准，宽高IntSize共用最大持续时间且从显示整数像素重定向。
- 结束阈值重新核对AnimationSpec.SpringSpec.vectorize及VectorizedSpringSpec.createSpringAnimations：显式Motion.bouncy/slide spring未设置visibilityThreshold，向量每轴使用默认0.01，不因IntSize/IntOffset converter自动变成1；默认退出/反向size/offset才显式为1。初稿误用1已在本轮修正，加入300px展开800ms仍在运行的断言。
- 首轮f080-pill-visibility.log/xcresult 3项中1失败：空闲后新退出尺寸错误使用上一段lastFrame，造成占位提前结束；清除空闲帧基准后f080-pill-visibility-clock为3/3 TEST SUCCEEDED。另区分首次尚未appear与已离屏，避免初始隐藏Group首次变可见时被当成静态重挂载。时钟弱代理、结束/离页停钟。
- 初稿接线UI：f080-pill-visibility-ui.log/xcresult 2/2 TEST SUCCEEDED，包含三语生成等待→跳过→错误和三胶囊进出。已查看英文等待2302F186/跳过98BE590F截图，其余七张三语图仅导出。阈值修正后最终/tmp/ztransfer-20261016-f080-pill-visibility-threshold.log/xcresult **单元3/3+UI1/1、TEST SUCCEEDED**；状态覆盖三延迟/8物理像素、首次静止、nullable内容宽高退出、独立解析反向值、尺寸向量短轴不提前snap、退出全通道结束后移除和再入场。
- 新DEBUG专用Probe只在真实CADisplayLink回调记录0<alpha<1的入/出阶段，且每阶段只发布一次。UI实际得到entered=60,80,150及exited=60,80,150，验证最终三文本移除、基础大小胶囊保留。最终进入3CF5D4DF/退出E7DDCC89两图已查看（/tmp/ztransfer-f080-pill-visibility-threshold-attachments），无明显重叠/残影；该Probe证明真实回调经过中间值，不是逐帧像素对照，也未实测退出中反向的生产渲染。
- 剩余验证：真实滚动离屏/重入、多胶囊受限行宽、内容140ms宽度与进退场同时变化、反向实际帧、四皮肤/明暗及安卓独立像素。卡片高度/移位、空态/顶栏等F080原范围仍未完成，不核销，总30/182。xcodegen已更新，索引新增生产组件/测试两项到709；git diff --check通过。未真机、提交或推送，测试进程已结束。


### F080 胶囊真实回调退出反向验证（2026-10-16）

- 扩展DEBUG QueuePillVisibilityProbe和专用宿主：用户测试步骤先点击进入、再点击退出；仅在三个生产CADisplayLink均观察到0<alpha<1的退出回调后，宿主响应reverseRequested把phase切回显示。非固定sleep，也不是仅调用纯状态模型；这次反向由宿主回调触发，不能称为实际第三次用户点击或手势连点验收。
- 记录每个delay对应的控制器ObjectIdentifier；在实际update(false→true)边界检查before.retained、alpha仍在(0,1)、前后alpha/速度连续、scale不重置、尺寸显示整数像素不跳，并在反向后再次观察到显示回调中间alpha。Probe仅专用启动参数启用，正常生产无该反向行为；本轮未修改Release动画算法。
- /tmp/ztransfer-20261016-f080-pill-reversal-ui.log/xcresult **UI1/1、TEST SUCCEEDED**。实际结果reversed=60,80,150;resumed=60,80,150;continuous=true;stable=true，三文本均恢复可见。已查看/tmp/ztransfer-f080-pill-reversal-attachments/D475DCFE-80D3-4DFF-9BCB-9808F1E441F8.png：最终三胶囊并排、没有残留旧层或明显遮挡，诊断文字仅DEBUG宿主显示。
- 该证据证明真实显示回调/控制器接续与最终画面，未捕获反向每一帧的渲染像素，也未比较安卓录屏。滚动离屏/重入、受限行宽、宽度与进退场同变、四皮肤/明暗仍待验证；F080其他卡片/空态/顶栏范围保持未完，不核销，总30/182。
- 索引709项不变，更新组件、宿主和UI测试hash；git diff --check通过。未真机、提交或推送，测试进程已结束。


### F080 卡片间距纳入收合（2026-10-16）

- 对照安卓TransferScreen.kt的LazyColumn无spacedBy及animateItemPlacement→collapseHeight(clip=false)→padding(bottom=8.dp)：iOS LazyVStack间距改0，卡片底部8pt移入QueueItemView，在卡片绘制/侧滑之后、GeometryReader高度测量和折叠frame之前。正常间距保留，末行也有8pt，移除时随卡片高度一起收合，不再留下列表层固定空隙。
- 本轮只完成源码顺序对照和git diff --check，未构建、未运行测试或模拟器；实际移除/拒绝后恢复、末行及清空动画仍需在明确验证节点检查。现有280/200ms实现未据此声明完整等价，内容高度250ms和itemPlacement仍待补。F080保持未核销，总30/182；未真机、提交或推送。


### F080 direct collapse measurement (2026-10-16)

- Matched FileListScreen.kt collapseHeight: measure full content each layout pass, round the scaled height to physical pixels, place at top, fade with progress, no clipping. Replaced GeometryReader/PreferenceKey/state-cached height with private QueueCardCollapse/Layout; includes the 8pt bottom spacing and never feeds collapsed bounds into child measurement.
- Existing 280/200ms SwiftUI timing and opacity remain; clock/interruption fidelity, itemPlacement and 250ms content animation remain pending. swiftc -frontend -parse passed (syntax only, not type checking/build); git diff --check passed. No build, tests, simulator, device, commit or push. Runtime removal/restoration and concurrent content resizing still require verification. F080 OPEN; closure count 30/182.


### F080 队列空态展开与呼吸（2026-10-16）

- 对照TransferScreen.kt空态分支、Motion.overlayExpand和ZMark.kt：新增局部QueueEmptyMark/弱代理显示时钟及纯采样模型；从首帧开始340ms FastOutSlowIn淡入，同时2400ms每程往返透明度0.42→0.54、缩放0.985→1.015，返程反转播放时间。呼吸透明度乘展开值，不增加退场。空态分支重建重新展开，普通刷新不重启；离页停钟，代理不强持有owner。禁用外部隐式动画二次插值。
- 双Z尺寸改58×既有aspectRatio宽、58高；旧74宽导致Canvas受宽约束压低实际高度。颜色沿用secondaryText，经Color.kt核对等于onSurfaceVariant明6E6E73/暗B0B0B0。
- 新增testQueueEmptyMarkRevealAndReverseBreathing，覆盖初态、展开中间值、峰谷、返程与重复周期；本轮未运行该测试。swiftc -frontend -parse两文件成功，仅语法解析，不代表类型检查/编译或UI验证。git diff --check通过；无构建、安装、真机、提交或推送。实际首帧/离页重入、四皮肤明暗与跨平台录屏仍待验证。
- F080保持未核销，30/182；卡片250ms内容尺寸、itemPlacement、滚动scrim、动态底部间距、顶栏等剩余项继续开放。


### F080 队列底部动态留白（2026-10-16）

- 对照TransferScreen.listPadding/fabCount，列表底部固定112pt改为基于actionVisibility的12/96/168pt（零/一/两个可用操作）。按安卓只计算hasClearable/hasRetryable，不因确认弹层mounted而继续算入；移除中的任务和clearAll抑制规则复用现有actionVisibility。当前只有两个操作，不引入不可达的第三按钮分支。
- 静态检查PhotoListView队列宿主：仅背景ignoresSafeArea，队列内容和底部按钮仍在系统安全区内，故不重复加navigationBar/safeArea高度。实际不同设备/横竖屏安全区及最后卡片可见范围尚待运行验证。
- swiftc -frontend -parse与git diff --check通过，仅语法/差异检查。未构建、运行测试、安装、提交或推送；此简单布局映射未增加镜像实现的单元测试。F080仍未核销，总30/182，顶部滚动scrim和其余既定缺口继续开放。


### F080 顶部滚动渐变遮罩（2026-10-16）

- 对照TransferScreen.listAtTop及顶部scrim：新增列表内容在滚动坐标系中的位置观察，复用既有物理像素8px边界判断；不使用仅报告用户拖动/惯性的PhotoListScrollActivity观察器，避免遗漏删除/布局导致的偏移变化。清空时重置listAtTop，空队列不显示遮罩。
- 非顶部且非空时绘制backgroundTop的0.85→0.5→0渐变，停点0/0.45/1，高度顶部安全区+56，向安全区顶部偏移；位于卡片上方、按钮与确认遮罩下方，不接收触摸/无障碍、不增加显隐动画。新增backgroundTop颜色，按Color.kt明F8F8FB/暗181818。
- swiftc -frontend -parse两文件及git diff --check通过，仅语法/差异检查；未构建或运行测试。真实UIScrollView坐标原点/安全区、滚动返回顶部、删除后位移、清空再入队及主题截图仍待验证，不能据静态接线宣称实景一致。F080未核销，总30/182；未安装、真机、提交或推送。


### F080 顶栏生成态图标（2026-10-16）

- 对照FileListScreen.QueuePill的PillMode.GENERATING：移除蓝色“生成中”可见文本，改16pt accentPurple Material AutoAwesome，保留6pt图标/数量间距。复用QueueBadgeIcon已有原始Material路径；本地化queue_pill_generating仅作为图标无障碍描述。呈现与measurementContent共用generationIcon，避免显示图标但仍按长文本测量。
- swiftc -frontend -parse与git diff --check通过，仅语法/差异检查；未构建、测试、安装或真机验证。三语实际宽度、VoiceOver、生成数量滚动/模式切换和四皮肤仍待验证；原有滚数/内容转场/宽度动画尚未完整修正。本次不因此核销F080，总30/182；未提交或推送。


### F080 顶栏文字角色与滚数差异复核（2026-10-16）

- 对照FileListScreen.QueuePill/AnimatedQueuePillCount与Type.kt：Done和数量采用labelLarge Bold（14/20），速度labelMedium Bold（12/16），所有指定文字tnum。显示和measurementContent统一使用现有zTransferTypography角色，Done补monospacedDigit；滚数countText同用labelLarge，保持现有20pt裁剪槽。颜色/8pt下载间距已一致，不改。共享typography的实际字体leading仍需UI验证，不能据角色接线声称逐像素等价。
- 已确认后续滚数必须整体修复：安卓slideIn/OutVertically默认spring，偏移是内容物理像素高度整数除2，fadeIn160/fadeOut120，SizeTransform snap且clip=true；现有iOS固定10pt、统一easeOut160、额外16ms sleep和单旧层保留不等价。本轮未改这些动画，不能将字体修复算作滚数完成。
- swiftc -frontend -parse和git diff --check通过；未构建、测试、安装、真机、提交或推送。F080仍未核销，总30/182，当前新增静态修复及空态/遮罩均待集中运行验证。


### F080 顶栏胶囊按压标量动画（2026-10-16）

- 对照FileListScreen.QueuePill手写Surface：按下target0.95、tween80 FastOutSlowIn，释放Motion.bouncy400/0.5，graphicsLayer默认中心锚点。QueuePillButtonStyle移除右锚点/easeOut80/response0.34 damping0.72，改局部QueuePillPressEffect与弱代理显示时钟，复用ZTransferScalarAnimation保留重定向值/速度；空闲/离页停钟，离页重置，主题切入Liquid Glass立即取消自定义缩放。已批准Liquid Glass特例保持。
- 该按钮样式仍覆盖收起图标态；安卓图标态走GlassButton，其他皮肤的专属图标态反馈尚须单独复核，不宣称全部皮肤按压等价。真实手势取消/连点、父层动画事务、离页重入和主题切换仍待运行验证。
- swiftc -frontend -parse和git diff --check通过，仅语法/差异检查；未构建、测试、安装、真机、提交或推送。F080保持未核销，总30/182；内容转场、宽度及滚数仍未完整修复。


### F080 顶栏宽度类别与最大值作用域（2026-10-16）

- 已阅读安卓queuePillWidthKey/activeQueueMaxWidthPx及QueuePillStateTest对应测试。iOS以QueuePillWidthKey替换仅按mode的测量字典键：计数/暂停记录速度单位、速度整数位数、非负数量位数；其他模式清空这些类别字段。测量回调只消费当前key，计数态同key保持最大值，换单位/位数/速度显隐/模式则重建最大值；非计数不保宽。新内容测量前保留上次实际测量宽度，不再取其他模式历史最大值。
- 新增testQueuePillWidthCategoriesReleasePreviousMaximum：覆盖同类别共享、单位/位数/速度显隐/模式不同、同类别保持、换类别释放、非法测量拒绝及暂停不保宽；本轮未运行。当前测量仍为SwiftUI自然内容，尚非Compose新旧层AnimatedContent实际容器；首次锁定、物理像素宽度弹簧及退场内容快照仍待补，不宣称完整宽度等价。
- swiftc -frontend -parse两文件及git diff --check通过，仅语法/差异检查；未构建、测试、安装、真机、提交或推送。F080仍未核销，总30/182。


### F080 顶栏宽度物理像素弹簧（2026-10-16）

- QueuePill宽度移除SwiftUI response0.42/damping0.72，新增QueuePillWidthMotion/局部弱代理时钟复用标量动画：测量目标转整数物理像素，首个有效目标直接静止，后续Motion.bouncy400/0.5，重定向保留浮点显示值和速度，不套IntSize显示取整规则；渲染除displayScale，空闲/离页停钟。密度变化重新初始化，避免旧像素单位串用。
- 首次非图标态尚未获得测量的一个布局阶段仍用原40pt占位，未实现安卓完全自然宽度首帧；新旧内容容器测量、模式转场及外部隐式动画事务仍待整体核对，不宣称全部宽度对齐。已有40pt占位不作为正式等价方案，后续需结合内容层布局修正。
- 新增testQueuePillWidthFirstMeasureAndInterruptedSpring，独立400/0.5解析公式验证50ms宽度、重定向值连续/向外速度保留及终点；本轮未运行。swiftc -frontend -parse两文件与git diff --check通过，仅语法/差异检查；未构建、测试、安装、真机、提交或推送。F080仍未核销，总30/182。


### F080 首次测量前自然宽度布局（2026-10-16）

- 新增私有QueuePillSizingLayout：可见胶囊和已有隐藏测量内容成为两个明确子视图，布局直接无约束测量当前内容；widthClock尚无值时报告自然宽度，之后报告动画宽度。删除widthClock.width ?? 40占位，图标仍由自身40pt自然宽度决定。可见surface只接受动画视口尺寸，隐藏测量层始终自然宽度、靠右放置、不命中/不暴露无障碍。
- 修复前轮记录的首帧硬编码占位路径；当前仍未复刻AnimatedContent新旧内容快照及其容器宽度，不能将自然测量布局视为完整内容转场完成。语法解析swiftc -frontend -parse及git diff --check通过，未运行UI或首次布局测量验证，尚不能声称实际首帧画面验收通过。
- F080仍未核销，总30/182；未构建、测试、安装、真机、提交或推送。


### F080 顶栏退场内容数据快照（2026-10-16）

- 对照FileListScreen.QueuePill AnimatedContent targetState Triple(mode,remaining,speed)/contentKey mode：新增QueuePillPresentation及按模式记录最后呈现值的History。当前层直接读取当前presentation，同模式更新原地刷新；非当前层读取自己最后的数量/速度，进入Done/生成态不再把旧计数层改为0或清掉旧速度。onAppear/onChange记录当前值，复用同模式时立即采用新值。
- 新增testQueuePillOutgoingPresentationRetainsCountAndSpeed，覆盖计数→Done保旧值、返回计数采用新值、随后生成态保更新后的计数及Done独立快照；未运行。当前仍永久挂载各模式、统一180ms交叉淡化，尚未接入220ms延35/退出160与Transition图层清理，历史值存储不代表完整AnimatedContent生命周期复刻。实际同帧切换/退场画面待验证。
- swiftc -frontend -parse两文件和git diff --check通过，仅语法/差异检查；未构建、测试、安装、真机、提交或推送。F080仍未核销，总30/182。


### F080 顶栏淡化状态模型（2026-10-16，尚未生产接线）

- 读取本机Compose1.7.6源码EnterExitTransition.kt与AnimatedVisibility.kt：PreEnter→Visible使用入场220ms延35，Visible→PostExit使用退场160，PostExit→Visible默认critical400；未完成动画被tween重定向使用critical1500。退出清理由childTransition达到current/target均PostExit判定，不能固定160ms删层。
- 新增QueuePillFadeMotion三阶段模型，复用标量动画并保留Transition结束速度，首次可见静止；新增testQueuePillFadeDelayExitAndReverseSpring覆盖35ms边界、255ms入场终点、160ms退场终点及退出反向20ms独立解析公式。模型尚未接入QueuePill；现有统一180ms视图仍存在，下一步必须实现图层持有/清理与当前内容更新，再接入，不得将该模型记为已修复生产转场。
- 两文件swiftc -frontend -parse、git diff --check通过；未运行新增测试、构建或UI。F080未核销，总30/182；未安装、真机、提交或推送。


### F080 顶栏内容淡化生产接线（2026-10-16）

- QueuePill接入QueuePillContentTransition及局部弱代理时钟，删除永久五模式层/统一180ms淡化。QueuePillContentMotion仅持当前与退场层，以mode作身份；当前模式数量/速度更新不重启淡化，旧层持自己的presentation；返回仍保留的模式复用层，退出完成按fade状态移除，不用固定sleep。首次挂载静止，离页停钟，重入按当前值初始化。共用上一帧作为重定向基准。
- 上轮History被图层自身快照替代并删除。替换测试为testQueuePillContentRetainsOutgoingSnapshotAndCleansFinishedLayers，覆盖旧计数/速度不归零、160ms旧层清理与255ms入场终点、同模式更新不重播、退场反向复用。该测试尚未运行；多段中断的父/子Transition时钟、全局段重建、子动画未完时的实际清理时点仍须与原库进一步验证，不据纯模型宣称完全一致。
- 内容视口仍右对齐并外层裁剪；隐藏测量仍取当前内容，尚未复刻AnimatedContent新旧内容容器实际尺寸，滚数内部仍旧实现。这些缺口保持开放。swiftc -frontend -parse及git diff --check通过，仅语法/差异检查；未构建、测试、安装、真机、提交或推送。F080未核销，总30/182。


### F080 内容层自然宽度与裁剪依据纠正（2026-10-16）

- 继续读取Compose1.7.6 AnimatedContent.kt SizeModifier.measure及AnimatedContentMeasurePolicy：内层测量新旧层最大值用于放置，外层SizeTransform返回sizeAnimation当前值；项目使用snap，因此对外目标尺寸取targetSizeMap的当前目标层。旧层CenterEnd对齐且clip=false，可以超出目标尺寸。此前笼统记录“必须按新旧最大容器宽度修复外部测量”证据不足，现明确：当前内容自然测量方向正确，不应盲目把外部宽度改为新旧最大值；子层滚数尺寸仍须单独对照。
- QueuePillContentTransition每层加fixedSize(horizontal:true)，避免胶囊缩窄时先压缩/省略退场文本；移除内容组件外的额外clipped，保留胶囊外壳clipShape。图层仍各自trailing对齐。对应FileListScreen wrapContentWidth(End,unbounded=true)、SizeTransform(clip=false,snap)与Surface形状裁剪。
- swiftc -frontend -parse和git diff --check通过，仅语法/差异检查；实际新旧长短文本右缘/退场越界裁剪、首帧与滚数行宽尚未运行验证。无构建、测试、安装、真机、提交或推送。F080仍未核销，总30/182。


### F080 集中验证准备（2026-10-16，尚未获构建授权）

- 已核对AGENTS.md第26行“未获用户要求时不自动构建、安装、提交或推送”，本轮通过异步问题请求专项模拟器构建/测试授权，未启动构建或安装。此前多轮parse仅语法验证，不能替代Swift类型检查和运行。
- 新增testQueuePillInterruptedEntryUsesDefaultFloatSpring：从145ms入场中间值/速度改退场，20ms后以独立critical1500公式断言，并检查退出最终清理资格；未运行。连同现有FadeDelayExitAndReverseSpring、ContentRetainsOutgoingSnapshotAndCleansFinishedLayers、WidthFirstMeasureAndInterruptedSpring、WidthCategoriesReleasePreviousMaximum、EmptyMarkRevealAndReverseBreathing构成首组6项DomainModelTests最小验证。
- 第二组优先生产QueueSwipeUITests两项、QueueRetryUITests.testGenerationCardWaitingSkippedAndErrorInThreeLanguages、testQueuePillsReverseFromActualExitFrameWithoutResetOrRemount、testNewFailureDuringRealClearWindowDoesNotExposeCardActions。这些既有UI仍不覆盖新顶栏实际转场/空态/滚动scrim，后续需专门宿主与截图，不能用旧测试通过冒充覆盖。
- 新增测试swiftc -frontend -parse及git diff --check通过。F080未核销，总30/182；未构建、测试运行、安装、真机、提交或推送。


### F080 顶栏专用UI验证宿主准备（2026-10-16）

- 新增DEBUG --queue-top-pill-test入口，QueueTopPillPresentationHarness使用真实QueuePill和QueuePillButtonStyle，固定身份快照在暂停9项→下载3项/10.0MB每秒→生成2项循环，独立于卡片TransferInfoPill宿主。无相机/下载副作用，不进入Release入口。
- 新增testTopQueuePillUsesProductionPausedDownloadAndGenerationStates，检查三状态文本出现/旧文本撤下/回到暂停，并保存生成态截图。该测试只覆盖最终内容和基本接线；不宣称中间帧、实际像素图标、右缘几何、按压或快速反向覆盖。尚未运行。
- 三文件swiftc -frontend -parse、git diff --check通过；构建授权问题仍待用户答复，未构建、安装或测试运行。F080未核销，总30/182；未真机、提交或推送。


### F080 滚数单层运动模型（2026-10-16，未接入视图）

- 阅读AnimatedQueuePillCount及Compose1.7.6 slideInVertically/slideOutVertically默认参数：位移critical400、IntOffset阈值1，位移为整数像素高度/2再乘方向；fadeIn160、fadeOut120。新增QueuePillCountLayerMotion，复用可配置入退时长的QueuePillFadeMotion，位移与淡化分离，保留小数速度/显示整数像素重定向，必须两者结束才允许退出清理。顶栏模式淡化默认220+35/160不变。
- 新增testQueuePillCountSlideUsesIntegerHalfHeightAndOutlivesFade：61px高度取30px、增减方向、50ms独立critical400公式、120ms透明度已0但位移未结束、最终清理。未运行。模型尚未用于QueuePillRollingCount，旧固定10pt/160ms/sleep仍在，下一步需多数字层/真实测量/重定向与视图接线，不得记作生产滚数已修复。
- swiftc -frontend -parse和git diff --check通过；未构建、测试运行、安装、真机、提交或推送。构建授权仍待回复，F080未核销，总30/182。


### F080 滚数多层持有模型（2026-10-16，未接入视图）

- 阅读Compose1.7.6 AnimatedContent.kt currentlyVisible/contentKey及remember(segment.targetState==stateForContent)退出规格：新增QueuePillCountMotion，以数字作身份保留所有未退出层；新数追加，返回旧数复用原层/顺序，已在退出的更旧数字保持原退出方向，不随第三次计数变化重新改方向。共同帧基准，等位移和淡化完成才移除。
- 新增testQueuePillCountRetainsIntermediateNumbersAndReusesReversal：10→9→8→9→12覆盖中间层保留、反向复用、显示整数像素起步及旧层退出方向保留、最终清理。未运行。真实高度测量、滚数容器snap尺寸、嵌套父转场生命周期及生产QueuePillRollingCount接线仍待完成，本模型不算生产滚数修复。
- swiftc -frontend -parse和git diff --check通过；未构建、测试运行、安装、真机、提交或推送。构建授权仍待答复，F080未核销，总30/182。


### F080 滚数生产接线（2026-10-16）

- QueuePillRollingCount接入QueuePillCountMotion及弱代理局部显示时钟，移除固定10pt偏移、16ms sleep、统一easeOut160和单旧层状态。隐藏当前数字提供自然宽高/实际像素高度；overlay保留数字层居中绘制，按像素偏移除displayScale，目标内容尺寸立即生效并clip，对应AnimatedContent默认Center与SizeTransform(snap,clip=true)。只当前数字参与无障碍。
- 首次测量前直接静止显示当前数字；有效高度测量后初始化，数字更新驱动独立弹簧/淡化。动画结束/离页停钟，离页清模型；重入从当前数字静止。密度/实测行高变化目前重置模型，动态字体中途高度变化的保留动画语义仍待核对；父模式转场与内部滚数生命周期协调仍待验证，不能据接线宣布全部中断等价。
- swiftc -frontend -parse与git diff --check通过，仅语法/差异检查；既有模型和新顶栏UI测试均未运行，构建授权仍待答复。未构建、安装、真机、提交或推送，F080未核销，总30/182。


### F080 图标态不参与内部内容淡化（2026-10-16）

- 再读FileListScreen.QueuePill collapsedToIcon分支：GlassButton后直接return，内部AnimatedContent并不包含icon。修正此前五模式通用淡化接线：iOS图标态直接呈现图标并销毁活跃内容转场，重新进入非图标态静止初始化当前内容；外部宽度时钟保持，不重置宽度弹簧。图标材质/尺寸既有iOS特例不在本步改动，图标态主题按压仍独立待复核。
- 顶栏专用宿主增加取消终态→图标→暂停路径；UI用例增加旧生成数量消失、无Done、入口仍存在及回到9断言。测试尚未运行；未实测图标切换当帧、宽度连续性或真实取消生命周期，不声称已验收。
- swiftc -frontend -parse两文件与git diff --check通过；未构建、测试运行、安装、真机、提交或推送。构建授权仍待答复，F080未核销，总30/182。


### F080 图标态液面绘制门控（2026-10-16）

- 安卓collapsedToIcon分支在Surface/LiquidProgressFill之前return；iOS原液面条件只排除Done，导致有未完成任务但数字仍延迟/押扣成图标时仍可挂载液面。现增加visualMode != .icon，图标态仅绘制按钮材质与图形。既有Done门控不在本步改动。
- 注意安卓rememberSmoothTransferProgress在图标早返回之前，iOS当前进度动画仍由液面组件持有；隐藏后再显示的动画状态连续性需独立复核，此门控只对齐绘制资格，不据此声明进度生命周期完全一致。
- swiftc -frontend -parse及git diff --check通过；未构建、运行测试、截图、安装或真机验证。构建授权仍待答复，F080未核销，总30/182；未提交或推送。


### F080 顶栏平滑进度与液面绘制分离（2026-10-16）

- 对照QueuePill中位于collapsedToIcon早返回前的rememberSmoothTransferProgress，以及TransferProgressMotion按resetKey记忆的单调目标：抽出LiquidTransferProgressSurface为纯绘制，原LiquidTransferProgressFill仍封装平滑+绘制供其他调用复用。顶栏改常驻SmoothTransferProgress与常驻ZStack，只在允许状态内绘制Surface，避免图标/Done隐藏绘制时连带销毁平滑状态；无二次平滑。
- 目标值/进度身份及波形参数本步保持既有实现；完成后同身份单调值、下一文件resetKey及隐藏前后实际重入仍需运行验证，不能据结构调整声明全生命周期验收。共享纯绘制组件保留既有颜色/幅度/周期，这些参数尚需另项对照。
- swiftc -frontend -parse两文件及git diff --check通过，仅语法/差异检查；未构建、测试运行、安装、真机、提交或推送。构建授权仍待答复，F080未核销，总30/182。


### F080 液面透明度与直边门控（2026-10-16）

- 对照LiquidProgressFill.kt默认参数与FileListScreen顶栏调用：顶栏alpha改0.22→0.35；卡片0.14及2/3pt幅度、2200/2600ms周期、8/12段、1/0.55空间比例经静态对照保持。抽出共享liquidProgressWaveEnvelope，Timeline暂停与Shape直边判断同用>0.001门限；waveEligible=false传0幅度，绘制矩形而不是phase0的静态波形。
- 新增testLiquidProgressDisabledWaveIsRectangularAndEnvelopeHasQuietEdges，覆盖NaN、包络边界、禁用波动在三相位下的矩形边界/内外点；未运行。波浪时钟仍用全局时间而非可见时从0开始，seed仍为UUID字符串hash，均未在本轮解决，不能声称波形完全等价。
- swiftc -frontend -parse与git diff --check通过；未构建、测试运行、安装、截图或真机。构建授权仍待答复，F080未核销，总30/182；未提交或推送。


### F080 波浪局部相位时钟（2026-10-16）

- 按LiquidProgressFill.kt waveVisible分支创建/移除rememberInfiniteTransition：Surface只在eligible且包络>0.001时挂载LiquidTransferWave，否则静态矩形。移除全局Date相位，新增局部单调CADisplayLink相位时钟，首个回调为零，2200/2600ms线性循环；弱代理，退出分支/离页停钟重置。普通progress/seed更新不重建时钟。
- 新增testLiquidWavePhaseStartsOnFirstFrameAndRestartsAfterRemount，覆盖非零绝对时刻首帧0、半程、整周期边界、下一周期及重建/2600ms。未运行，亦未生成原Compose浮点相位参考fixture；真实可见性跨阈值/滚动重入仍需UI验证。seed映射及数值Float/CGFloat差异仍未全面对齐。
- swiftc -frontend -parse与git diff --check通过，仅语法/差异检查；未构建、测试运行、安装、真机、提交或推送。构建授权仍待答复，F080未核销，总30/182。


### F080 波浪Restart整周期边界纠错（2026-10-16）

- 读取Compose1.7.6 VectorizedInfiniteRepeatableSpec.repetitionPlayTimeNanos及FloatTweenSpec.getValueFromNanos后发现上一轮整周期phase=1处理错误：Restart以elapsed/duration整除后减去整周期，精确边界应为0。修正为余数/周期，并按源码使用Float比例再转CGFloat。此前测试期望1是错误断言，已改为0并补非整数纳秒比例；不声称上一轮已验证正确。
- swiftc -frontend -parse及git diff --check通过；新增/修订测试均未运行，尚无原库执行fixture或实际像素对照。未构建、安装、真机、提交或推送；构建授权仍待答复。F080未核销，总30/182。


### F080 平滑进度时钟弱代理（2026-10-16）

- 检查常驻SmoothTransferProgress宿主时确认旧SmoothTransferProgressAnimator直接作为CADisplayLink target，形成owner→link→owner。改为MainActor弱代理；正常完成/离页仍按原路径停钟，owner已释放时代理回调自行invalidate。去掉owner不再需要的NSObject继承，保留原进度目标、重定向和stop清理语义。
- swiftc -frontend -parse与git diff --check通过；未执行对象释放/实际显示回调测试，不声称运行时生命周期已验收。未构建、安装、真机、提交或推送；构建授权仍待答复。F080未核销，总30/182。


### F080 顶栏宽度模型重名纠错（2026-10-16）

- 跨文件静态检查发现本轮新增顶栏QueuePillWidthMotion与既有UI/Components/QueuePillWidthLayout.swift的140ms卡片胶囊模型同名，会造成模块类型重定义；此前单文件parse不能发现该问题，不能沿用为编译通过证据。顶栏模型改名QueueTopPillWidthMotion，时钟及testQueuePillWidthFirstMeasureAndInterruptedSpring同步；既有testQueuePillWidthUsesPixelRoundingAnd140msRetargeting继续引用原140ms模型。
- 对ios/ZTransfer全目录顶层非private类型名做正则辅助重复检查，未输出其他重复；该检查不解析条件编译/嵌套作用域，不替代Swift类型检查。三相关文件swiftc -frontend -parse与git diff --check通过，尚未构建/运行测试。
- 构建授权仍待答复，F080未核销，总30/182；未安装、真机、提交或推送。


### F080 顶栏纯状态模型归档（2026-10-16）

- 从PhotoListView.swift抽出9个顶栏纯模型到UI/Components/QueueTopPillMotion.swift：模式、淡化、单数字层/多数字层、呈现快照、内容层、宽度key/测量/弹簧。脚本逐声明原样移动，未修改模型声明正文；显示时钟、视图和DEBUG宿主留原文件。卡片胶囊140ms模型仍独立，避免职责混淆。
- xcodegen generate --spec ios/project.yml已更新工程引用（仅项目生成，不是构建/安装）；两文件swiftc -frontend -parse与git diff --check通过。索引新增生产文件到710项，未运行测试。
- 构建授权仍待答复，F080未核销，总30/182；未构建、安装、真机、提交或推送。


### F080 父段切换时旧退出层重建纠错（2026-10-16）

- 读取Compose1.7.6 Transition.updateTarget/resetAnimations递归子Transition及resetSnapValue强制重建规则，确认当前顶栏模型只更新进退目标改变的层仍有遗漏。FadeMotion保留原segmentSpec，force时目标未变仍从当前值/速度重建；未完tween改critical1500。ContentMotion模式切换对各层force；CountMotion更旧退出层保留原方向/目标但重新建立alpha与offset动画，显示整数像素起步，不能把“保方向”等同于“不重建”。
- 新增testQueuePillParentSegmentRebuildsUnchangedExitTarget，以退出50ms后同target重建、20ms独立critical1500公式断言。未运行。父Triple同mode但count/speed变化的重建行为仍需进一步对照，当前仅修模式/数字目标切换，不宣称全局中断已完整。
- swiftc -frontend -parse两文件及git diff --check通过；未构建、测试运行、安装、真机、提交或推送。构建授权仍待答复，F080未核销，总30/182。


### F080 同模式数据变化的Transition接续（2026-10-16）

- FileListScreen的AnimatedContent目标是Triple(mode,count,speed)，contentKey仅mode；Compose AnimatedContent会替换同key的目标内容，父Transition目标变化仍递归resetAnimations。ContentMotion改保存完整targetPresentation，完全相同输入不处理；同mode数据变化更新原层且force重建现存alpha，不新增层/不归零。此前“同模式不重播”仅指身份与起始值不重置，不能解释成跳过进行中动画重建。
- 新增testQueuePillSameModeDataChangeRetargetsWithoutRemounting：暂停→计数100ms后改数量速度，验证层身份/alpha连续、20ms critical1500独立公式及最新数据。未运行；该推导尚需原库执行参考与实际视图中断帧证实，不作为完整Compose等价证据。
- swiftc -frontend -parse与git diff --check通过；未构建、测试运行、安装、真机、提交或推送。构建授权仍待答复，F080未核销，总30/182。


### F080当前验证清单（2026-10-16）

- 已确认QueueTopPillMotion.swift存在工程Sources引用；本组7个相关生产/测试文件sha256与覆盖索引一致，索引710项。DomainModelTests顶部实际新增12个测试方法，不再沿用早期“6项”作为当前总数；均未运行。顶栏专用UI用例亦未运行。主表F080已更新，仍未核销，总30/182。
- 下一验证节点：先类型检查/构建并运行12项模型测试，再运行生产顶栏四状态UI与已有卡片/侧滑/清空回归；必须如实记录失败并修复，不能将既有旧测试绿灯延伸到本组。构建授权问题仍待用户答复，未启动构建。
- 当前代码仍需补齐/复核：卡片250ms内容高度与itemPlacement；收合中断及真实尺寸；顶栏图标态主题按压、全局/子Transition中断和动态行高变化；液面UUID种子映射与Float数值对照；Done/完成液面既有平台行为依据。
- UI验收仍缺：顶栏实际宽度/固定右缘/长短内容退场/滚数快速反向/按压取消，空态与遮罩安全区/清空再入队，滚动离屏重入，四皮肤明暗，安卓独立逐帧/像素及真机。上述均不能用纯模型或最终AX文本存在代替。
- 本轮仅台账汇总/静态引用与哈希检查，未修改业务算法；git diff --check通过。未构建、运行测试、安装、真机、提交或推送。


### F080授权后的专项验证与取消完成态修复（2026-10-16）

- 用户已明确授权“允许，运行专项验证”；本轮在 ZTransfer-iOS191-Tests 模拟器执行构建与专项测试，没有操作真机、提交或推送。
- 模型首轮 /tmp/ztransfer-f080-authorized-models.log：12项中1项失败，同模式重定向即时alpha相差一个Float ULP（0.35487676/0.35487673）。Scalar在重定向时执行零时刻弹簧采样，浮点减加产生舍入；只把该精确相等断言改为一个ULP容差，保留20ms独立公式校验。复跑 /tmp/ztransfer-f080-authorized-models-r2.log：12/12，TEST SUCCEEDED。
- UI首轮 /tmp/ztransfer-f080-authorized-ui.log：6项中5项通过，顶栏生成→取消错误显示Done，录屏11秒画面确认真实渲染错误。PhotoListView完成回调改为同时观察CompletionInput(allDone,hasCancelled)，使用回调新值判断取消，避免allDone单值回调捕获旧View数据；新任务开始时取消Done任务并清空显示/液面，依据Android FileListScreen.QueuePill的LaunchedEffect(allDone)逻辑。修复后 /tmp/ztransfer-f080-authorized-top-r2.log：顶栏1/1通过。
- 补充正常完成对照用例，确认正常完成仍显示Done、重新入队清除Done；最终 /tmp/ztransfer-f080-authorized-top-final.log：取消四状态与正常完成两项均通过，TEST SUCCEEDED。另5项UI回归在首轮已通过：生成等待/跳过/错误三语言、清空期间新失败、卡片信息胶囊退场反转、拖动中变忙回位、双向侧滑/短拖恢复/滚动与按钮。合计7个不同UI用例最终通过；未把卡片胶囊用例算作顶栏中断帧验证。
- 已导出 /tmp/ztransfer-f080-authorized-ui-attachments 并查看生成态、英文生成错误、侧滑后截图及失败录屏帧。侧滑夹具含count覆盖层且滚动内容进入状态栏区域，不能据此验收正式页面安全区/遮罩。顶栏宽度固定右缘/快速反向/按压取消、动态行高、四皮肤明暗、安卓逐帧/像素和真机仍未完成，原剩余清单继续有效。
- 本次仅完成该集中验证节点；F080仍未核销，文档进度保持30/182。


### F080完成液面与进度订阅新值修复（2026-10-16）

- 安卓FileListScreen.QueuePill在Done期间仍按finishProgressVisible/completionPending绘制LiquidProgressFill；未找到批准隐藏Done液面的平台例外。移除iOS visualMode != .done额外门控，保留图标早返回对应的隐藏规则。
- 第一轮 /tmp/ztransfer-f080-done-fill.log 两项顶栏UI通过，但导出Done截图仍无蓝色填充，证明AX文本通过不能证明液面正确。继续修复SmoothTransferProgress：原target/resetKey两条onChange忽略新参数并捕获旧View输入，改为Equatable Input一次携带新target/key，在回调中使用next，避免目标和归属错配。未改弹簧模型或单调进度规则。
- 第二轮 /tmp/ztransfer-f080-done-fill-r2.log：正常完成→重新入队、生成→取消→暂停2/2，TEST SUCCEEDED；已查看 /tmp/ztransfer-f080-done-fill-r2-attachments/0D86C251-2247-4AD9-AD43-899995F6E3CF.png，Done背景蓝色完整填充，与首轮无填充截图形成直接对照。测试新增保留完成态截图；当前自动断言仍只覆盖状态文字，视觉由本轮人工检查，未声明自动像素回归。
- 同步纠正主表F080仍标记“未授权/未构建”的过期现状，保留历史记录。尚未验证下载中连续进度、逐帧补满时序、跨任务重置真实画面及完整皮肤/真机；F080仍未核销，总30/182。无真机操作、提交或推送。


### F080进度归属与数字宽限期键（2026-10-16）

- 继续对照FileListScreen.QueuePill：LaunchedEffect(activeProgressTaskId)只保留新非空ID；iOS progressOwner.onChange改直接使用回调传入的新ID，移除再次读取View捕获值，防止任务切换后终态错误保留旧归属。
- 安卓数字显现effect键为(remaining > 0,hasActive,paused)，iOS原字符串键包含具体数量与allDone，纯等待任务持续增减时会反复重置350ms宽限期。改为具名Equatable CountVisibilityInput，仅含hasRemaining/hasWorkingTask/paused，task内用同份输入判断，保留原取消检查及350ms时长。
- 本轮swiftc -frontend -parse、git diff --check通过；未运行新的构建或测试，不能沿用上一轮UI通过作为本次时序/跨任务证据。下一步需生产宿主覆盖等待中连续数量变化的350ms窗口与不同任务ID→终态进度归属；F080仍未核销，30/182。


### F080连续等待数量变化的生产宽限期验证（2026-10-16）

- 新增Debug-only QueuePillObservation偏好，旁路读取生产countingVisible/displayRemainingCount，不改变状态流转。QueuePillGraceHarness从空队列开始，在运行但未开始下载时每100ms增加一个waiting任务，共10次更新；记录首次显示数字的单调时钟时间和当时生产计数。
- testWaitingCountChangesDoNotRestartProductionGracePeriod断言首次显示在300–850ms窗口，且数量大于1、小于最终11，验证仍在连续变更期间出现且未立即跳过350ms宽限期。该测试验证effect重启资格，容差窗口不作为精确350ms或逐帧动画证据。
- /tmp/ztransfer-f080-grace.log：上述用例与正常完成→新批次、生成→取消→暂停两个生产顶栏回归，共3/3，TEST SUCCEEDED。本轮构建已覆盖上一轮CountVisibilityInput与progressOwner新值接线，但不同任务ID切换到终态的归属行为仍缺专项断言，不以构建或完成用例代替。
- git diff --check通过。F080仍未核销，进度30/182；未操作真机、提交或推送。


### F080裁切生成摘要与进度归属优先级（2026-10-16）

- 阅读安卓summarizeQueuePillTasks与QueuePillStateTest：裁切生成可能仍为TRANSFERING，但必须排除下载计数/activeDownload。iOS原downloadRemaining与activeItem只看status，导致生成模式误判且并行下载可能拿错进度归属。
- 新增QueuePillTaskSummary，单次遍历统计下载/生成/取消，按下载→生成→等待选择progressOwner；QueuePill初始化时保存当前snapshot摘要，复用到计数、activeItem、hasActive与取消判断。不会合并队列业务任务或改变持久化。
- /tmp/ztransfer-f080-summary.log：testQueuePillSummarySeparatesCropGenerationAndProgressOwnership 1/1 TEST SUCCEEDED，覆盖裁切生成单任务、等待+裁切+实际下载+取消混合队列、完成后生成、等待及取消终态。对应安卓QueuePillStateTest中的摘要边界。
- 生产顶栏夹具生成阶段改为transferring+isGeneratingFrame，增加生成图标可访问性标识与存在断言，避免只看数字无法识别counting/generating误判。/tmp/ztransfer-f080-crop-summary-ui.log：生成→取消→暂停及正常完成→重新入队2/2 TEST SUCCEEDED。
- 本轮证明摘要选主与生成模式接线，不等于不同任务ID动态切换后的平滑进度重置/终态补满已验收，后者继续待验证。git diff --check通过；F080未核销，总30/182；无真机操作、提交或推送。


### F080生产动画器动态任务归属验证（2026-10-16）

- 新增Debug-only SmoothTransferProgressObservation，读取实际animator.motion.key/animation.value，不回显请求输入；生产顶栏宿主观察该偏好，夹具等待/下载/生成使用不同稳定UUID，下载目标0.25，生成目标1，终态保留生成归属，重新入队回到等待ID。
- testTopPillAnimatorSwitchesTaskAndRetainsLastOwnerThroughCompletion逐步断言实际动画器：等待ID1/0 → 下载ID1001/0.25 → 生成ID2001/1 → Done仍ID2001/1 → 新等待ID1/0。这补充了此前progressOwner新值回调与平滑输入更新的动态接线证据。
- /tmp/ztransfer-f080-task-progress.log：上述专项与生成→取消→暂停回归2/2 TEST SUCCEEDED。三位小数进度终值不代表中途每帧精度；重置瞬间/跨任务闪动/逐帧连续性仍待帧序列验证。观察器与夹具只在Debug构建，未修改本轮生产业务判断。
- git diff --check通过；F080未核销，30/182。未操作真机、提交或推送。


### F080顶栏实际布局宽度与右缘专项（2026-10-16）

- 新增testTopPillKeepsRightEdgeAndReleasesWidthAcrossModes，验证暂停→下载→生成→图标→暂停宽度释放与固定右缘。首轮及r2使用按钮AX frame，图标测得43.2×43.2而失败；录屏可见视觉已收缩，不能将AX区域等同布局矩形，未据此修改生产尺寸。
- r3/r4尝试从生产视图传递GeometryReader偏好但读到空矩形；曾推测默认值覆盖，过滤空值后仍失败，该推测未获证实。已删除这段无效偏好实现，改为Debug测试宿主在QueuePill边界直接用GeometryReader的onAppear/onChange记录global frame，不改布局算法。
- /tmp/ztransfer-f080-pill-geometry-r5.log：1/1 TEST SUCCEEDED。导出并读取 /tmp/ztransfer-f080-pill-geometry-r5-attachments/23DEB693-47CA-4A5B-854C-E7D3812E23BC.txt：暂停(x309.667,w41.333)、下载(x240,w111)、生成(x287.667,w63.333)、图标(x311,w40)，均y347.667/h40/maxX351；返回暂停宽度也通过0.5pt容差，右缘断言容差1pt。高度40遵循现有iOS控件尺寸特例，本轮未修改。
- 该测试证明各状态采样布局与宽度释放，不代表过渡每帧右缘、长短内容退场位置、快速反向或全部皮肤验证。AX图标区域比布局大及其来源仍为独立观察，未解释为完整触摸验收。
- 首轮至r4失败日志均保留。git diff --check通过；仅新增Debug测量和UI测试，F080未核销，30/182；无真机操作、提交或推送。


### F080液面包络Float精度（2026-10-16）

- 重读LiquidProgressFill.kt和LiquidProgressWaveTest.kt，以及TransferScreen常量：顶栏2dp/2200ms/8段/空间1/alpha.35、卡片3dp/2600ms/12段/空间.55/alpha.14与iOS现值一致。仍有UUID种子映射、谐波/路径Float运算及像素对照待处理。
- 安卓smoothStep与envelope每步为Float，iOS原CGFloat为Double精度；现将标准化进度及两个smoothStep中间值按Float计算，最后转换为CGFloat，保留非法值归零规则。该函数也决定是否挂载无限波浪时钟。
- 独立C参考 /tmp/ztransfer-liquid-envelope-reference.c 以clang -O0 -ffp-contract=off执行（非Android/JVM原库运行），按t=clamp((p-a)/(b-a)), s=t*t*(3-2*t), envelope=s(.05,.14)*(1-s(.90,.98))逐步Float计算。11个输入与预期bitPattern已固定在testLiquidEnvelopeUsesAndroidFloatRounding，覆盖进入/退出区间与端点，并断言NaN/±Infinity归零。
- /tmp/ztransfer-f080-envelope-float.log：Float参考、禁波直边/静默边缘、首帧相位/重挂载共3/3，TEST SUCCEEDED。未据此声明谐波、种子或整条路径数值等价，未跑新的UI/像素专项。
- git diff --check通过；F080未核销，总30/182；未操作真机、提交或推送。


### F080单位谐波与呼吸因子Float计算（2026-10-16）

- 对照LiquidProgressFill.kt液面单位偏移，提取liquidProgressWaveUnitOffset并接入生产Shape：使用Float常量6.2831855、三路谐波的安卓运算顺序，normalizedY限制0...1、spatialScale限制非负。sin输入先按Float算出角度，再Double求sin后收窄Float；呼吸因子也改为Float角度及运算。路径坐标/幅度缩放仍有CGFloat运算，未宣称整条路径Float一致。
- 独立参考 /tmp/ztransfer-liquid-harmonic-reference.c，clang -O0 -ffp-contract=off，使用(float)sin((double)angle)，七组普通/越界输入的结果bitPattern写入testLiquidHarmonicsFloatReferenceClampsAndCycleContinuity。参考是独立C实现，非Android/JVM原库执行。
- 迁入安卓LiquidProgressWaveTest的两种空间比例、4种种子、41个纵向采样、21个相位扫描，验证6888次幅度范围及328组周期首尾误差<=0.0001；另7组参考值逐位比较。/tmp/ztransfer-f080-harmonics.log：谐波、包络与禁波直边共3/3 TEST SUCCEEDED。
- git diff --check通过；种子映射、像素坐标舍入、完整路径和UI逐帧仍待补齐，F080未核销，30/182；无真机操作、提交或推送。


### F080液面像素空间路径（2026-10-16）

- LiquidTransferProgressSurface与LiquidTransferWave传入Environment.displayScale；Shape将尺寸/进度/波幅/分段高度/曲线中点置于物理像素Float空间，保持安卓先height/segmentCount再乘index的运算顺序，最后仅在交给Path时转回点坐标。直边分支同用Float fillWidth，支持非零rect原点；异常比例回退1。
- 独立C参考 /tmp/ztransfer-liquid-path-reference.c（clang -O0 -ffp-contract=off，非Android渲染器）生成123.4×37.7pt、scale3、进度.43、相位.19、种子.63、波幅2pt、8段的21个控制/端点；固定在testLiquidPathUsesFloatPixelControlPoints并验证封闭及曲线类型。
- 首轮 /tmp/ztransfer-f080-liquid-path.log：路径3个底部纵坐标回转像素时差1 ULP，其他两项通过。独立最小SwiftUI Path实验确认输入点y=34.199999491373696存储为34.20000076293945（等于Float输入），回转像素变113.100006；是Path点空间存储舍入，不能要求双重转换后像素位相等。
- 测试改在Path实际点坐标边界精确比较CGFloat(Float(origin+referencePixel/scale))，未放宽容差。/tmp/ztransfer-f080-liquid-path-r2.log：路径、谐波、禁波直边3/3 TEST SUCCEEDED。SwiftUI栅格化与Android像素对照仍待验证，种子映射亦未完。
- git diff --check通过；F080未核销，30/182；无真机操作、提交或推送。


### F080图标态复用共享材质按钮（2026-10-16）

- 对照Android QueuePill图标早返回GlassButton以及GlassButton按皮肤缩放/材质光照/物理位移逻辑，iOS原图标虽然画共享静态材质，却仍统一使用QueuePillPressClock的.95缩放。现QueuePill自己持有点击动作，图标分支使用ZTransferGlassButtonStyle（固定纹理种子0x2A71E001），活动分支保留独立QueuePillButtonStyle。移除外部嵌套Button及图标态重复材质/描边，LiveQueuePill传递真实presentQueuePage动作。
- WidthClock保留在共同父层，SmoothTransferProgress及稳定ZStack在两按钮分支外，避免模式变更销毁平滑宿主。保留已有LiquidGlass平台特例，未重写共享按钮动画模型。
- 首轮 /tmp/ztransfer-f080-themed-icon.log：四皮肤动作/取消与几何通过，Done StaticText查询失败。导出AX树证实Button label=Done，文本被按钮合并而非Done状态消失；测试改按queue-top-pill按钮label断言Done及取消非Done，不放宽状态语义。
- /tmp/ztransfer-f080-themed-icon-r2.log：5/5 TEST SUCCEEDED，包含FROSTED_GLASS/TITANIUM/WOOD/CAMERA_CONTROLS四皮肤逐一验证活动点击→图标拖出取消不触发→图标点击→返回活动点击，以及固定右缘、跨ID进度与完成保留、正常完成新批次、生成取消回归。此轮未新增原生LiquidGlass专项，也未证明四皮肤明暗像素/每帧按压参数完全验收。
- git diff --check通过；F080仍未核销，30/182；无真机操作、提交或推送。


### F080原生LiquidGlass交互补验与种子映射待决（2026-10-16）

- 扩展testTopPillThemedIconActivatesAndCancelsAcrossSkins，除四个非原生皮肤外增加LIQUID_GLASS。/tmp/ztransfer-f080-native-icon.log：单个参数循环用例1/1，五种皮肤全部执行活动点击→切图标→拖出取消不触发→图标点击→回活动点击，TEST SUCCEEDED（88.203秒）。运行于已有iOS26.5模拟器，未验证旧系统回退/明暗像素/逐帧手感。
- 种子来源已核对：安卓TransferTask.taskId来自递增Long；iOS创建和重试使用UUID，当前液面仍是UUID字符串31哈希。未发现批准的映射约定。按AGENTS平台差异先讨论要求，已询问保留UUID稳定折叠后使用安卓混合算法，或另设递增动画种子；未收到答复前不修改映射，也不改业务任务身份。其他F080工作可继续，不视为全目标阻塞。
- 下一独立差异已定位：TransferScreen内容animateContentSize(250ms FastOutSlowIn)与animateItemPlacement(Motion.itemPlacement)，iOS仍有整个snapshot/item状态的standard通用动画，需继续拆分核对。
- git diff --check通过；F080未核销，30/182；无真机操作、提交或推送。


### F080卡片内容尺寸250ms动画（2026-10-16）

- 对照TransferScreen Column.animateContentSize(tween(250, FastOutSlowInEasing))，新增QueueCardContentSizeMotion/Clock/Layout/Modifier：首次尺寸直接采用，后续宽高IntSize一起重定向；物理像素四舍五入，中断从显示整数尺寸接续，target不变不重启。自然高度在未施加动画高度的子视图上测量，内容TopLeading摆放并裁剪，避免测量反馈循环。
- 接入QueueItemView带12/10padding的内容层，外侧sheen/marker仍随卡片尺寸绘制；移除item.status/bytesPerSecond/elapsedMs触发的三条standard通用动画，尺寸由真实测量驱动。Modifier禁用继承的隐式内容动画，显式时钟仍工作；列表snapshot层standard及itemPlacement仍待独立替换，行内动作自身显隐动画也需后续精确核对，未宣称整体完成。
- 首轮 /tmp/ztransfer-f080-card-size.log因Target代理缺MainActor编译失败，修正后 /tmp/ztransfer-f080-card-size-r2.log：250ms半程、整数舍入中断和终点域测试1/1 TEST SUCCEEDED。
- /tmp/ztransfer-f080-card-size-ui.log：生成等待/跳过/错误三语言、清空期间新增失败、真实双向侧滑/短拖恢复/滚动与按钮3/3 TEST SUCCEEDED。查看英文错误截图 /tmp/ztransfer-f080-card-size-ui-attachments/EE438751-0A38-485D-A4D8-D8620F2D34BE.png，错误两行未被裁掉。UI未测量250ms真实中间高度，离屏重入/宽度变化/与列表位置弹簧组合仍待验。
- 已xcodegen更新Sources，新文件纳入索引，索引711项。git diff --check通过；F080未核销，30/182；无真机操作、提交或推送。


### F080卡片尺寸动画保留节点重挂载（2026-10-16）

- 复核Compose 1.7.6 AnimationModifier.kt：onReset清除AnimData，但保留节点重新attach后animateTo会对未到目标且已停止的动画重新启动。iOS原onDisappear直接reset丢失已显示尺寸，且没有onAppear测量，尺寸偏好不变时可能无法恢复。现离屏停止display link并保留四舍五入的物理像素尺寸、清除旧帧时间；重新出现显式测量缓存自然尺寸。离屏期间偏好可缓存但不启动时钟；新节点仍首次直接采用自然尺寸。
- /tmp/ztransfer-f080-size-lifecycle.log：250ms中断和新增保留节点重挂载模型测试2/2，TEST SUCCEEDED。验证离屏期间不推进、同自然目标重新启动、20秒后重挂载不继承旧时间、125ms中间尺寸与250ms终点、已完成重挂载不重播。
- /tmp/ztransfer-f080-size-lifecycle-ui.log：生产卡片双向侧滑/短拖回位/上下滚动/按钮回归1/1，TEST SUCCEEDED。该用例未强制捕获动画半途离屏和保留实例身份，不作为真实离屏中断帧验收；仍需专项宿主与逐帧证据。列表itemPlacement、行内动作和其余F080缺口保持待办。
- git diff --check通过；索引711项，更新两个文件hash。F080未核销，总30/182；未操作真机、提交或推送。


### F080队列条目位置弹簧与真实插入采样（2026-10-16）

- 对照TransferScreen.animateItemPlacement(Motion.itemPlacement)、Motion.kt的critical500/IntOffset阈值1，以及本机Compose1.7.6 LazyLayoutItemAnimation.animatePlacementDelta：新增QueueItemPlacementMotion/Clock/Modifier，布局位置转物理像素；从当前显示补偿减去新布局位移，保留运行弹簧速度并同时重定向两个坐标通道。采用共同帧时间，初始布局直接定位；弱代理时钟闲置停止，离屏清理。
- 已接到每个生产QueueItemView外侧，使用LazyVStack内容坐标（不含普通滚动位移）测量未偏移布局目标，绘制层施加补偿。删除ScrollView按整个snapshot.items触发的standard隐式动画，避免任务进度/状态变化牵动全树通用动画。
- /tmp/ztransfer-f080-placement.log：模型专项1/1 TEST SUCCEEDED，独立critical公式核对100ms物理像素值、同坐标不重启、两个轴连续改位瞬间显示位置不跳、最终归零与重置。不是Android原库逐帧执行参考。
- DEBUG队列宿主新增插入按钮，使用生产卡片已有UIView手势marker采样窗口坐标；插入第13个真实队列任务，保留同一个原有marker，100次约10ms采样，若脱离window则失败。/tmp/ztransfer-f080-placement-ui.log：实际插入中间位置、双向侧滑/短拖/滚动/按钮、清空期间新增失败共3/3 TEST SUCCEEDED。附件0FE79B6E-A4A5-4F1A-B933-EA7AA0E5BECC.txt实际为done;distance=100;intermediate=24，证明原有卡片下移100pt且观察到24个中间位置，不仅是模型值回显。
- 尚未完成Compose LazyLayoutItemAnimator的视口外保留/边界目标管理：新进入或被布局推出视口的条目、连续反向实际帧、尺寸变化与collapse组合、滚动中插入等仍需专项。不得将当前可见条目补偿宣称为完整Lazy条目动画等价；F080未核销，总30/182。
- xcodegen和git diff --check通过；新文件纳入覆盖索引，712项。未操作真机、提交或推送。


### F080收尾记录与功能范围切换（2026-10-16）

- 在用户调整范围前，核对Compose VectorizedAnimationSpec.getDurationNanos取各轴最大值、TargetBasedAnimation统一结束后，修正QueueItemPlacementMotion为共同时间轴/结束条件，较短轴持续采样并保留速度。/tmp/ztransfer-f080-placement-vector.log模型2/2 TEST SUCCEEDED，含x=10/y=300物理像素、200ms短轴仍为-1px及再次改位50ms为-7px（错误清零速度会为-8px）。保留这项已通过模型验证的修改。
- /tmp/ztransfer-f080-placement-reverse-ui.log：普通插入通过，反向失败（触发36pt、峰值36pt）；诊断复跑placement-reverse-r2.log仍失败（38pt/38pt）。控制台导出报告No console log available，临时print没有取得可用证据。真实界面反向原因尚未查明，未宣称通过。
- 用户随后明确不再要求样式/动画及UI测试：停止本项继续诊断，移除本轮临时print与未通过的新增反向UI夹具/用例，保留此前已经验证的普通插入UI用例与生产接线。历史失败日志保留；没有通过删除失败用例宣称验收成功。两次xcodebuild均已终止，无运行中的测试被遗留。
- F080纯视觉/动画剩余项退出当前工作范围，不核销为修复完成。后续从台账功能缺口继续，优先审查F001工作台返回期间发现/自动连接的生命周期门控，F002手势业务阈值另行辨别功能范围。git diff --check通过；未真机、提交或推送。


### F001工作台发现生命周期门控（2026-10-16）

- 按最新功能优先范围继续F001；依据Android HomeWorkspacePager.shouldPauseConnectionDiscovery及同名测试：settled或target在工作台时均须暂停。RootView新增WorkspaceDiscoveryState，区分请求页、落稳页及实际进行中目标；按钮请求先更新发现门控，返回请求不再直接恢复发现。交互开始/取消/落稳均接入同一状态。
- VerticalWorkspacePager现在程序化与交互路径都通知开始；程序化的开始通知与setViewControllers一起移至主队列下一轮，避免updateUIViewController内发布SwiftUI状态且保证先暂停后启动。开始前请求已撤回则取消该次原生切换并报告实际落稳页；失败完成亦报告原落稳页。保留进行中目标，避免快速反向只看最新请求提前恢复发现。
- /tmp/ztransfer-f001-discovery.log首轮模型2/2通过；补开始前撤回处理后，最终/tmp/ztransfer-f001-discovery-final.log模型2/2、0失败，TEST SUCCEEDED。覆盖完整往返、进入取消、返回取消、启动前撤回和进行中快速反向。构建包含最终生产接线；未运行UI测试（遵循用户要求），尚未做真实ConnectionViewModel服务事件的集成回放，不能把纯状态用例当作发现命令端到端证据。
- F001标记已补实现/状态验证，待服务层集成验证后核销；历史核销数仍30，功能范围总数待重分类。F003/F080纯转场动画主表已改本阶段排除，不记为修复。覆盖索引712项，更新RootView与DomainModelTests；git diff --check通过。无真机、提交或推送。


### F001发现服务回放与开发侧核销（2026-10-16）

- 为ConnectionViewModel抽取窄接口ConnectionUSBDiscoverySource（当前授权、刷新授权、已连接设备快照），默认仍委托原ImageCaptureUSBTransport；构造注入只替换该边界，不替换业务判断。USB事件处理apply作为模块内事件入口，生产异步事件与恢复快照沿用同一处理链。
- 新增真实ViewModel回放：工作台返回未落稳时投递authorized/deviceAdded/ready/sessionOpened，均不能选择设备、改变等待状态或接受session；取消返回再重试仍不查询服务。落稳后依次读取authorization→refresh→devices，重建暂停期间忽略的设备快照；重复落稳不重复查询。使用denied授权停在权限边界，不访问物理相机。另验证已有debug模拟相机会话在暂停/恢复时身份保持不变且不触发发现快照。
- /tmp/ztransfer-f001-service-replay.log：ConnectionStateTests全部16项与工作台状态2项，共18/18、0失败，TEST SUCCEEDED。包括新增两项服务回放；不是纯helper复述。未验证真实USB权限弹窗/PTP握手、原生分页手势或真机；UI测试按用户要求跳过。
- F001已完成本阶段功能实现及开发侧验证，核销待真机功能验收。历史已核销增至31项，当前功能范围分母待重分类，不用31/182冒充新范围完成率。覆盖索引仍712项，更新ConnectionViewModel和ConnectionStateTests；git diff --check通过，无真机操作、提交或推送。下一功能项继续按台账处理，纯视觉条目保持排除。


### F004 AP后台重试保留失败状态（2026-10-16）

- 核对Android CameraViewModel.connectToCameraWithRetry：仅循环入口写PROBING，后续失败按当轮异常更新分类，不在每次握手前重写PROBING；RECONNECTING保持。iOS beginWiFiConnection现对AP既有failed保留phase与failureKind，首次/新轮仍进入connecting，STA仍使用discovering；连接成功明确清除旧failureKind。
- 抽取WiFiConnectionServicing作为原WiFiConnectionService的接口，默认实例不变；允许真实ViewModel回放协议边界。测试服务依次返回timeout、cameraRefused、invalidated、debug repository，订阅全部state发布，断言仅首轮包含connecting，后续失败阶段不会出现空failureKind，分类依次notFound/refused/failed，第四次成功且清分类。测试恢复原无线偏好，配置独立STA profile store，不访问相机或网络。
- /tmp/ztransfer-f004-ap-retry.log：ConnectionStateTests 17/17、0失败，TEST SUCCEEDED，含新连续三次失败→成功用例及F001服务回放。没有运行UI测试、物理网络或真实握手，不声明触觉/渲染验收。
- F004尚待取消/新候选网络重启及reconnecting专项后核销。另静态检查发现apFailedAttempts在cancelWiFiConnection内未归零（部分外部路径另行归零），Android循环局部计数每轮重置；下一步需核对工作台暂停/恢复后的首轮重试间隔，不沿用本轮状态测试当作该边界已验证。F002手势业务门槛仍保留待办，F003纯视觉已排除；本轮先处理连接状态可靠性，不视为F002完成。
- 历史已核销31项不变，覆盖索引712项，更新三个文件hash；git diff --check通过。未真机、提交或推送。


### F004取消重开、重连与退避核销（2026-10-16）

- 对照Android connectToCameraWithRetry局部failedAttempts与retryDelay分支：cancelWiFiConnection结束候选网络轮次时清零apFailedAttempts，修复工作台暂停/模式切换后新轮沿用旧3秒退避。保留既有代次递增和串行cleanup，旧尝试迟到失败受generation门控。
- 把原watcher内1秒/3秒选择提取为生产实际使用的apRetryDelayNanoseconds，只读，不新增测试专属分支。首败/重连1秒、后续failed为3秒保持安卓语义。
- 新真实ViewModel回放先失败两次验证1秒→3秒，取消后确认idle/分类清除，再发起新尝试确认重新connecting且首败1秒；再次取消后连续3次reconnect失败，均保持reconnecting/无失败分类/1秒，不经过connecting或failed。
- /tmp/ztransfer-f004-ap-lifecycle.log：全部ConnectionStateTests 18/18、0失败，TEST SUCCEEDED，含此前三次失败→成功及F001回归。验证生产选用的延迟值，不是实际等待墙钟间隔或物理网络；无UI测试、真机、提交、推送。
- F004本阶段功能修复开发侧核销待真机；历史核销32项，当前功能范围分母待重分类。F002仍待处理，纯视觉F003/F080保持排除。覆盖索引712项，更新ConnectionViewModel/ConnectionStateTests，git diff --check通过。下一连接可靠性缺口F005为心跳连续失败策略，需结合协议失效边界处理。


### F005无线心跳连续失败容错（2026-10-16）

- 对照Android CameraViewModel.startKeepalive/KEEPALIVE_FAILURE_LIMIT=2/INTERVAL=10000/RETRY_DELAY=1000：新增WiFiKeepaliveLoop并接入WiFiConnectionService生产任务。成功或忙态跳过清零；首败额外等待1秒再进入下一轮10秒等待，第二次连续失败才调用onLost且退出。不是“首败后1秒立即重试”。取消计时或探测后Task取消均不报告掉线。
- CameraRepository与PTPSession.keepaliveIfIdle在忙态跳过前先拒绝已失效会话；不放松现有命令超时/失步使协议失效的保护。第二次心跳可返回false推动掉线计数，但不会往失效流重发命令。
- /tmp/ztransfer-f005-keepalive.log：新心跳5项+MonitorStorageSchedulingTests两项，共7/7、0失败，TEST SUCCEEDED。循环回放false→true→false→false验证清零、精确请求sleep序列与单次onLost；取消额外等待、探测挂起后取消并释放验证无迟到丢线。真实Repository/PTPSession/传输替身回放首条timeout：cancelPTP确认恢复时同session第二次成功（2命令）；无法恢复时失效，生产循环计满两败仅1条命令。既有真实分块下载+存储排队回归证明忙态心跳不插队。
- F005功能开发侧核销待真机，历史核销33项；未进行物理Wi-Fi路由切换/休眠、墙钟10/1秒测量或UI测试，不宣称真实网络验收完成。原UI/动画范围排除继续生效，F002与后续功能缺口保留。
- xcodegen与git diff --check通过，新增生产/测试文件各1，覆盖索引714项；无真机、提交或推送。


### F006配对可信标记持久化基础（2026-10-16）

- 已完整阅读NikonCamera.initializeStaBrowsingSession/confirmPairingIfNeeded/invalidateStaPairingMarkers和StaPairingStateTest，以及iOS BrowsingSession/Coordinator/Store与旧测试。确认iOS pair()仍在NK_PAIRING_RESULT OK后立即markPaired，旧testFirstPairingMustFinishBeforeAlbumAndMarkerPrecedesOptionalEvent甚至断言事件前已标记；它是错误行为的保护测试，不是本项完成证据。
- 本轮先扩展STAProfileStore：isPaired认可legacy或sta_pairing_verified_v2_；hasTrustedPairing只认v2；requiresPairingVerification=有任一标记且无v2；confirmVerifiedPairing一次写两代标记并同步；invalidatePairing只移除指定GUID两代证明，保留路由、initiator ID及其他相机。GUID发现/迁移能识别v2-only，但不会把legacy静默升级。markPaired仍是legacy兼容写入，生产确认调用点尚未替换。
- /tmp/ztransfer-f006-pairing-proof.log：STAProfileTests 9/9、0失败，TEST SUCCEEDED，包含4项新增：legacy必须验证/可信重载、v2-only发现与多相机迁移不升级、单相机失效/身份路由保护/全量reset、非法GUID拒绝。未进行真实进程终止或相机配对，仅store实例重建与持久偏好回放；无UI测试。
- F006仍未核销，总已核销33项不变。下一步必须接verifyPairingCompletion到Coordinator.connect/open及BrowsingSession；移除pair()早写，重连验证DeviceInfo非空/非pairing-only并通过相册才confirm；验证失败按安卓清标记、报告pairingNotConfirmed并仅允许一次有界重新配对。effectiveVerify在Android为显式请求或legacy待验证（不只pairedComputer身份）。应同步改掉旧错误测试，不能仅增加新helper。
- xcodebuild通过；索引714项，更新Store和协议测试hash；git diff --check通过，无真机、提交或推送。


### F006重连验证接线（2026-10-16）

- 对照Android NikonCamera.initializeStaBrowsingSession/confirmPairingIfNeeded与CameraViewModel.tryConnectStaCandidate，移除配对应答后的提前markPaired。显式重连或legacy标记触发验证：DeviceInfo失败、缺失、空能力或精确配对专用能力集均清除当前机身两种标记；相册访问验证成功才写legacy/v2。其他相册失败不自动清除标记。Coordinator传递验证标志，配对未确认仅允许一次6.6秒恢复，保留就绪重试及备用身份尝试，错误复用重新配对文案。
- 首轮/tmp/ztransfer-f006-verification.log执行29项、2个旧断言失败：配对应答即保存，以及新机身未确认就覆盖旧机身已确认路由。核对Android preferredStaIdentityForCandidate仅选择已确认profile后修正断言。最终/tmp/ztransfer-f006-verification-r2.log为29/29、0失败、TEST SUCCEEDED。
- F006仍待完整多会话恢复成功与验证中取消集成回放，不标完成；历史核销数保持33。用户最新范围继续生效：界面只做到功能可用，样式/动画及播放效果留待后续集中处理。本轮没有UI测试、真机操作、提交或推送。


### F006多会话恢复与取消开发侧核销（2026-10-16）

- 新增Coordinator→真实BrowsingSession→PTPSession→脚本传输的四次会话回放：首次应答、配对专用能力拒绝、重新配对、完整DeviceInfo及ObjectInfo验证成功。各次连接开始、配对事件与三次6.6秒等待均断言无标记；最终相册handle=7且legacy/v2证明可由新Store实例读回。请求验证标志严格为false/true/false/true，各会话命令全部消费。
- 新增旧标记验证读取DeviceInfo后取消真实Task，检查只执行OpenSession/compat/storage/DeviceInfo四条命令，无相册命令、无可信证明，legacy仍要求后续验证。结合既有配对等待取消、第二次未确认仅一次恢复及备用身份、缺失/空/配对专用能力清除、持久化隔离用例，完成本项开发侧功能验证。
- /tmp/ztransfer-f006-recovery.log：31/31、0失败、TEST SUCCEEDED；git diff --check通过。未运行UI测试，没有真机配对、实际杀进程恢复或网络时序验收；进程恢复仅验证偏好Store重建，不冒充真实进程终止。
- F006开发侧核销待真机，历史修复计数34项，功能范围分母仍待重分类。覆盖索引714项，更新两份协议测试。下一项F007：已确认RootView重连evict旧模型并以新session身份重建列表，需补同机STA目录/选择状态继承与新代次重新枚举，不能只去掉.id而保留旧失效repository。


### F007恢复链审查及前置F022句柄基线修复（2026-10-16）

- 对照Android onCameraTransportLost/activateStaCamera/loadFiles：短断线保留目录、卡槽和效果预览；连接成功与loading/未完成状态一起发布，再preserveExisting+detectNewHandles枚举。iOS RootView先evict旧模型再按session的ObjectIdentifier重建PhotoListView；模型闭包和评级控制器绑定旧session，不能仅删除.id。后续须切换新模型/新协议依赖同时保留页面状态，并迁移完整目录及indexed别名/knownHandles基线，旧评级状态不能继承。当前仅审查，F007仍未修复。
- 发现台账F022会破坏恢复所需基线，先修该依赖。Android loadFiles在完整rawHandlesByStorage枚举成功时设置knownHandles，续扫不按剩余列表收缩。iOS CameraRepository.scanCatalog尾部原用groups剩余句柄与existingHandles可见行重建，丢失已处理的双卡别名；移除这次覆盖，保留前面成功枚举建立的全量基线。失败枚举不重建基线，评级/游标生命周期不做合并。行为依据包括NewMediaTransferPolicyTest的句柄差量与备份主句柄替换测试。
- 新增真实Repository/PTPSession脚本测试：六句柄合并为三行→已消费全句柄snapshot续扫→重新枚举六句柄并读取备份元数据；added/removed均为空、仍三行、命令全部消费。旧尾部赋值会把1/3/5误报为新增。snapshot由测试构造，非实际进程恢复，不宣称F007跨连接已验证。
- /tmp/ztransfer-f022-baseline.log：ScanBatchPolicyTests 9/9、0失败、TEST SUCCEEDED，含范围停止/扩大、取消双卡续扫、批量策略等回归；git diff --check通过。F022开发侧核销，历史修复35项，F007仍待接线；当前功能范围总数待重分类。未UI测试、真机、提交或推送。覆盖索引714项，更新Repository及ScanBatchPolicyTests。


### F007跨连接目录数据边界（2026-10-16）

- 新增STACatalogRecovery值类型及Repository导出/恢复入口，只携带发布行、完整句柄、双卡原始索引与存储ID，不携带任务/连接/评级/扫描游标。仅STA且规范化GUID相同、目标未扫描/无目录时接受，拒绝AP、无GUID、不同机身及覆盖已有目录；恢复清除握手预读，强制下一轮完整枚举，并开启目标自身的新评级代次。
- 新增两个独立PTPSession/Repository的真实协议回放：旧连接扫描六句柄合并三行并shutdown→导出→同GUID新连接恢复→重新StorageIDs/Handles枚举与别名读取，断言没有旧媒体added/removed、双卡归属保留、评级代次推进、无旧游标；同时验证不同GUID/缺GUID/AP/重复覆盖拒绝。所有脚本命令消费完毕。
- /tmp/ztransfer-f007-catalog.log：ScanBatchPolicyTests 10/10、0失败、TEST SUCCEEDED；git diff --check通过。当前只是已验证的数据交接基础，ConnectionViewModel断线捕获/发布前导入、PhotoListViewModel继承、RootView与页面持有关系尚未接入，F007仍未完成，核销35项不变。没有UI测试、真机、提交或推送。索引714项，更新Repository及ScanBatchPolicyTests。
- 下一步应在失效旧session关闭边界捕获此数据，在STA新连接发布前导入并以代次检查保护取消/模式切换；保存恢复来源身份供RootView只复用正确旧模型的页面状态。页面使用新session的闭包和评级控制器；列表继承后首次load不得清空，且应preserveExisting+detectNewHandles。重置配对/换机须清除恢复来源，不能把保留工作台误当自动恢复许可。


### F007连接生命周期交接（2026-10-16）

- ConnectionViewModel在STA掉线关闭旧会话后捕获目录与来源身份，actor等待后复查wifi代次及旧session身份；新STA连接发布前导入同GUID目录，导入后再次检查取消/代次/模式与当前session。CameraSession新增不可变recoveredFromSessionID，只有成功导入才携带，供后续列表层确认来源。
- 暂停/取消发现保留恢复数据供同机重试；重置配对、切换无线模式、开始USB连接清除。任何成功新连接消费恢复状态，GUID不匹配无法导入；旧session迟到掉线继续由现有身份门控拒绝。
- 新真实ConnectionViewModel回放使用两个Repository：首连后扫描→handleTransportLost→取消发现→重新连接，断言替代session来源及发布时已有目录。另一分支插入resetSTAPairing后确认无继承；两分支均投递旧session迟到掉线确保新session不被拆除。
- 首轮/tmp/ztransfer-f007-lifecycle.log因测试漏onBatch参数编译失败；改为直接通过旧Repository准备目录，最终/tmp/ztransfer-f007-lifecycle-r2.log专项通过，涵盖ConnectionStateTests与ScanBatchPolicyTests。未UI、真机、提交或推送；git diff --check通过。
- F007仍未完成，历史核销35项不变。必须接RootView与PhotoListViewModel：目前新列表load仍清空并以preserve=false扫描，会抹掉已导入目录，不能把连接层测试当作整项完成。接线需保留模型展示快照/过滤/卡槽及页面状态，业务闭包切换新session，首次加载preserve=true且新评级控制器，旧模型任务停止。


### F007列表与页面恢复接线（2026-10-16）

- PhotoListViewModel.cached按新session的recoveredFromSessionID查旧模型，复制目录、筛选、卡槽及原片索引值；不复制扫描/填充任务、业务闭包或评级控制器。首次load保留继承目录，以preserveExisting/detectNewHandles重新枚举，完成前hasCompletedFileScan=false。来源模型随后由RootView.evict停止任务。
- RootView为同机恢复保留workspaceViewID，非恢复替换重建页面；PhotoListView改观察由缓存持有的新模型，保留本页滚动/选择/展开及效果预览@State。连接任务、忙态同步和缩略图观察任务加入session身份；内部监看页以新session重建，效果预览请求代次在session切换时递增，保留已显示图片并拒绝旧请求回写。
- 新模型用例验证继承后与load同步返回时仍有旧行、卡槽保持、首次扫描preserve+detect且无旧游标；扫描结果故意把旧/新handle都标added，自动传输仍只收到新增8、不重播旧7。首轮与r2失败来自测试替身canFill默认false，STA按生产规则等待后台通道；最初以为等待太短、增加等待仍失败，随后定位并让成功场景明确放行且返回缩略图settled结果。未放松生产等待逻辑。最终/tmp/ztransfer-f007-list-r3.log为30/30、0失败、TEST SUCCEEDED（连接18+扫描12）。
- 最后补缩略图观察session键后，/tmp/ztransfer-f007-list-final.log最小恢复用例1/1、TEST SUCCEEDED，最终生产接线构建通过。F007暂不核销，仍需同机新增/删除/双卡替换与列表失败保留的组合回放。页面状态保留为代码接线证据，未运行UI测试或真机验收，不宣称滚动/选择/预览已实机验证。历史核销35项不变；无提交或推送。


### F007恢复差量与失败保留开发侧核销（2026-10-16）

- 新增真实Repository/PTPSession与列表模型组合回放：旧双卡同照片句柄2/1合并→同机新Repository恢复完整目录→重新StorageIDs/Handles发现主句柄2删除、备份1仍在及新增3→新模型继承旧行后加载，最终句柄为1/3，备份1仅归属原卡2，自动传输仅收到3，旧照片副本切换不重播。完整脚本消费完毕。
- 新增恢复模型transportLost回放：继承旧照片后新扫描失败，旧目录与卡槽仍保留、hasCompletedFileScan=false、loadState=loaded、掉线回调恰好一次，不执行权威缓存清理或上报新媒体。RootView监看入口创建缓存模型时补上掉线回调，避免其先于列表创建时遗漏恢复通知。
- 首轮/tmp/ztransfer-f007-delta.log两处断言错误地按内部目录顺序定位照片；内部目录保留既有行后追加，PhotoCatalogGrouping.byCaptureDay才负责展示排序。改为按句柄集合与指定句柄卡槽断言，未改生产排序。最终/tmp/ztransfer-f007-delta-r2.log：32/32、0失败、TEST SUCCEEDED（连接18+扫描14），包含最终RootView接线。git diff --check通过。
- 结合此前同GUID目录/别名与评级隔离、未知/异机/AP拒绝、取消发现恢复/重置配对清除/旧会话迟到失败、列表保留及旧媒体不重播测试，F007本阶段功能开发侧核销待真机。历史核销36项，当前功能范围分母待重分类；UI测试按用户要求跳过，滚动/选择/效果预览保留及订阅切换以代码接线为证，未宣称真实界面或物理Wi-Fi验收。
- 索引714项，更新RootView与ScanBatchPolicyTests，无真机、提交或推送。下一项F008/F009为USB权限语言切换及ViewModel错误覆盖，F002功能手势阈值仍保留待办；纯样式动画继续排除。


### F008/F009 USB权限恢复及错误接线（2026-10-16）

- Android usbReceiver以usbManager.hasPermission为事实，onUsbPermissionUnavailable单独保存本地化错误；HomeConnectionPresentationTest验证USB失败状态。iOS沿用既有app级授权平台差异，ConnectionState授权恢复改用事件前usbAuthorization的denied/restricted状态，不再将新语言文本与旧failed文本相等作为恢复前提；重复authorized不清除无关协议错误。原ViewModel授权后waiting+已选设备会排队连接的入口保持不变。
- 删除ConnectionViewModel.failed分支对usbPhase的原始message二次覆盖，保留reducer给出的空错误兜底/拒绝或受限权限提示及errorMessage一致性；已有session的失效回收和无关设备隔离仍保留。
- 新真实ViewModel回放：简中↔英文、繁中↔英文共4方向，各denied/restricted两种状态，携带已发现设备后切语言再authorized，确认waiting、错误清空、设备不丢；另确认已授权情况下无关协议失败不被重复授权清除。同步回放在排队物理USB打开前结束并析构取消任务，只验证状态及既有调度接线，不宣称物理自动连接成功。
- 新真实ViewModel错误回放覆盖未决定/拒绝/受限权限×空/非空框架错误，最终phase/errorMessage均为解析后的文本；其他设备错误不改当前状态。/tmp/ztransfer-f008-f009-usb.log：ConnectionStateTests 20/20、0失败、TEST SUCCEEDED，含既有AP、工作台发现回归；git diff --check通过。无UI测试、系统设置操作或物理USB验收，无提交/推送。
- F008/F009开发侧核销待真机，历史核销38项，当前功能范围分母待重分类。索引714项，更新ConnectionState/ConnectionViewModel/ConnectionStateTests。其余功能缺口继续按台账处理，F002手势阈值未被当作视觉项核销。


### F010 GPS失效身份一致性（2026-10-16）

- 对照NikonGpsService错误分支：仅pairing rejected/identity expired清身份，普通pairing timeout/not found不清。阅读GpsRecoveryPolicyTest与NikonGpsProtocolTest；GPSCoordinator现对上述两类调用同一BluetoothClient.clearPairing，删除原宽泛配对分支中的直接UserDefaults清除。其他错误的既有状态映射未在本项擅自扩展。
- clearPairing同时清device/nonce、savedPeripheralIdentifier及公开peripheralIdentifier，然后按既有stop终止连接；持久化与旧迁移键同步清除。避免同进程重新开启继续复用失效缓存。抽出生产beginPairing实际调用的preparePairingIdentity，返回stage1并同步内存/偏好，取消原stage1强制解包；这是实际身份准备路径，不是测试复刻算法。
- 新Coordinator→真实BluetoothClient回放四种错误：identity expired、大小写PAIRING REJECTED、普通握手timeout、not found；验证内存/三项持久化清除条件，stop后再次调用生产stage1准备路径，失效身份换新，其余严格保留123/456并正确持久化。测试使用独立preferences并恢复旧迁移键，不启动CoreBluetooth或物理定位；失败停止位置更新改为仅停止已存在manager，避免无定位会话时惰性创建系统对象。
- /tmp/ztransfer-f010-identity.log：GPSProtocolTests 5/5、0失败、TEST SUCCEEDED，含安卓捕获配对向量与GPS数据策略回归；git diff --check通过。未验证真实开关GPS/GATT发送、后台恢复或相机忘记配对的真机流程，不宣称硬件验收。
- F010开发侧核销待真机，历史核销39项；功能范围分母待重分类。索引714项更新Coordinator/BluetoothClient/GPSProtocolTests。无UI测试、真机、提交或推送。下一项F011处理NOT1确认通知路由与ID只写一次，F012/F013超时和跨连接隔离仍未修复。


### F011 NOT1通知路由与单次ID排队（2026-10-16）

- 对照Android NikonGpsBleClient.handleCharacteristic/queueControllerIdIfNeeded与已有NikonGpsProtocolTest：NOT1精确01 00应立即排ID，PAIR必须解码完整包，stage4延迟1.5秒兜底，两路共用idQueued。iOS didUpdateValueFor现按特征路由NOT1确认、PAIR配对值、其他忽略；删除误放在PAIR处理器内的两字节确认分支。没有给NOT1臆加cameraConfirm状态回调。
- 把queueControllerID原有单次判断/计时取消/载荷生成收为takeControllerIDPayload；生产先确认ID characteristic存在，再经同一门控入现有串行写队列。NOT1和stage4兜底均沿用该入口，不因重复通知生成第二次ID。stop仍重置idQueued。
- /tmp/ztransfer-f011-notification.log：GPSProtocolTests 6/6、0失败、TEST SUCCEEDED。新增测试覆盖精确NOT1确认、短/长无效值、其他特征忽略、PAIR两字节不能解码、NOT1/兜底两种先后顺序及重复通知只取得一次32字节ID，stop后新轮可重新取得。保留F010与配对捕获向量回归；git diff --check通过。
- 验证边界：本轮运行生产路由和真实client排队门控，未实例化CBPeripheral/GATT写回调，1.5秒任务与delegate到写队列的组合回放未做；因此F011先记已接实现/局部验证，不核销完整验收，历史39项不变。下一步结合F013可回放的会话/写入边界补齐NOT1仅通知、延迟兜底与旧连接ACK隔离，不以这些局部测试宣称整条BLE握手完成。F012超时出口亦仍待补。
- 覆盖索引714项，更新BluetoothClient与GPSProtocolTests；无UI测试、真机、提交或推送。


### F013 BLE回调隔离第一阶段（2026-10-16）

- 对照Android NikonGpsBleClient以gatt===g隔离回调：iOS发现只在shouldRun、当前central且尚未持有外设时接受；连接/断线要求当前central及同一CBPeripheral对象；服务、特征、订阅、值和写入回调先检查运行状态/外设对象，旧错误也不能改变当前状态。写回调还要求writeInFlight及队首CBCharacteristic对象完全匹配后才出队，避免其他特征ACK确认当前GEO。
- clearConnectionState递增connectionGeneration，取消配对计时与保存的controllerIDFallbackTask；stage4延迟任务捕获代次并检查当前外设。NOT1成功取得ID载荷也取消兜底任务。重复stage4保留首次1.5秒截止、不重新延后；idQueued之后stage4直接忽略，避免成功后又退回cameraConfirm。
- /tmp/ztransfer-f013-callback-guards.log原有GPS专项6/6、0失败、TEST SUCCEEDED；随后修正重复stage4不推迟截止及已排ID不改状态，最终构建另记结果。这6项仅证明既有协议/身份/ID门控未回归，不是迟到回调场景验证。没有用编译或局部门控测试核销F013。
- 尚待可回放的BLE队列/会话边界测试：stop后回调、A→B旧ACK、同对象重连的特征实例变化、1.5秒跨连接任务，以及willRestoreState在显式停止后的接纳规则。当前willRestoreState仍按enabled恢复，不能声称已覆盖所有停止后回调。F011 delegate到写队列组合回放与F012超时出口亦待补。历史核销39项不变；无UI测试、真机、提交或推送。

- 最终/tmp/ztransfer-f013-callback-final-r2-build.log为BUILD SUCCEEDED；仅构建验证最后两处stage4条件，未补跑迟到回调测试。git diff --check通过，覆盖索引714项更新BluetoothClient。


### F013显式停止与CoreBluetooth恢复入口（2026-10-16）

- willRestoreState不能仅依赖GPSPreferences.enabled：等待用户处理配对错误时stop并不关闭持久化enabled，旧恢复回调会重新绑定外设。新增同一manager启动的一次性restorationPending，stop或进入主动扫描使其失效；takeRestorationPermission只有首次、enabled且无已绑定外设才接受，拒绝或接受均消费该次资格，之后开启GPS不重放旧恢复。新client可重新获得首次资格。
- delegate重复报告当前外设直接忽略，不取消已接受的连接；其他不合格恢复取消其外设但不再将当前state覆盖为disconnected。同时要求当前central身份（初始化期间central字段尚未设置除外）。这些门控保留初始系统恢复路径，没有移除既有iOS恢复功能。
- 新真实client生命周期测试覆盖初始接纳一次、重复拒绝、enabled仍为true但stop后拒绝、关闭状态首次拒绝后再开启也不接受旧恢复、新实例允许初始恢复。/tmp/ztransfer-f013-restoration.log：GPSProtocolTests 7/7、0失败、TEST SUCCEEDED；git diff --check通过。测试只调用生产恢复资格入口和真实stop，不伪造系统CBPeripheral回调或启动蓝牙硬件。
- F013仍未核销：A→B迟到ACK及实际写队列、stage4跨代次1.5秒回放仍待补，F011通知到串行队列亦待组合验证，F012失败出口未实现。历史39项不变，索引714项更新BluetoothClient/GPSProtocolTests；无UI测试、真机、提交或推送。下一步优先让现有串行写队列以可回放的特征身份边界验证，复用生产出队逻辑，避免继续只增加旁路helper断言。


### F013生产串行写队列回放（2026-10-16）

- 按Android当前gatt身份门控及iOS原有串行写规则，将原数组/writeInFlight抽为MainActor NikonGPSWriteQueue，生产enqueue/drain/didWrite全部接入同一组件；条目保存外设owner、特征对象、载荷与completion，ACK只有当前已发送队首且owner/特征引用均一致才出队。清队列先移除全部状态再以false结算，已完成项不重复结算。
- enqueue/drain增加当前外设运行门控；completion可能同步触发stop，因此didWrite在回调完成后再次确认当前外设，避免后续ready/drain对已结束会话继续操作。不同错误特征或重复ACK不能弹当前队首。
- 新测试运行实际生产队列：A的GEO写入后取消，A回调恰好false一次；B使用同一特征对象排GEO及ID，发送前ACK、A迟到ACK、错误ID ACK和重复GEO ACK均不推进；B匹配确认后按序发送ID，结算geo:true/id:true且清空不重复回调。这不是测试副本算法；NSObject仅代替CoreBluetooth对象身份，没有物理GATT。
- /tmp/ztransfer-f013-write-queue.log：GPSProtocolTests 8/8、0失败、TEST SUCCEEDED；git diff --check通过。覆盖索引714项更新BluetoothClient/GPSProtocolTests，无UI测试、真机、提交或推送。
- F011/F013仍待通知→ID门控→该生产队列及真实延迟任务组合回放；同一外设/特征对象跨重连的系统回调边界尚未验收。F012超时出口尚未修复。历史核销39项不变，不把这8项扩大为整条BLE链已验收。


### F011/F013通知与延迟写入组合回放（2026-10-16）

- 将生产stage4的1.5秒Task收为MainActor NikonGPSDeferredAction，默认仍Task.sleep(1500000000ns)。已有任务不重排截止；cancel递增内部代次并取消/释放任务，晚返回的旧sleep不能执行动作或清空新任务。client保留外层连接代次/当前外设检查，stop/clear/NOT1排ID继续取消同一生产兜底组件。
- 新回放用可控sleep让A等待忽略取消直到显式释放：取消后排B，再放A，检查A/B队列均未被旧动作写入、新任务仍占位；放B才出现B写入，记录延迟精确为两次1.5秒，重复stage4不会新增等待。另组合生产NOT1路由、真实client ID门控、同一延迟组件与生产串行队列，NOT1两次只排一次32字节ID，ACK后释放兜底仍无第二次写入。
- /tmp/ztransfer-f011-f013-combined.log：GPSProtocolTests 10/10、0失败、TEST SUCCEEDED；含此前NOT1/PAIR两种先后顺序门控、恢复资格及A→B ACK隔离回归。测试替换等待与系统对象身份，不替换生产排队/取消逻辑；未测真实墙钟抖动或CoreBluetooth外设写入。git diff --check通过。
- F011生产通知路由与单次ID排队开发侧核销待真机，历史核销40项。F013仍保留未完成：系统delegate的同外设/同特征对象重用跨连接边界及启动/停止回调组合回放尚未完整验证，不能把组件组合测试扩张成所有系统回调通过。F012超时出口仍待实现。
- 索引714项更新BluetoothClient/GPSProtocolTests，无UI测试、真机、提交或推送。


### F012 BLE失败出口与期限接线（2026-10-16）

- 阅读Android beginScan/SCAN_TIMEOUT_MS、onConnectionStateChange、onServicesDiscovered及scheduleIdWriteTimeoutIfNeeded：扫描15秒，必要PAIR/NOT1/ID/GEO缺失报服务不可用，保存身份的ID实际发送后3秒未确认报GPS connection confirmation timeout；首次配对不套这条3秒限制。iOS复用已验证NikonGPSDeferredAction补scanDeadline/idWriteDeadline，可注入等待但生产仍使用相同时长。
- beginScan启动截止，发现外设及stop/clear取消；超时stopScan后报Camera not found。didFailToConnect增加当前central/外设门控，保存地址直连失败转扫描，普通失败报告Bluetooth connection failed。发现特征前完整检查四个必需UUID，缺失不再静默卡住。ID计时在writeValue实际派发后启动，ACK取消；检查当前owner/特征仍是生产队首才失败并清理队列，停止/新代次取消。freshPairingAttempt不启动保存身份的3秒计时。
- 新真实client期限回放：15秒扫描报错并stop一次、3秒保存身份ID未确认报错、stop后的扫描等待晚返回无效果、ID已不在等待时无误报、新配对不启动保存身份截止；记录请求延迟[15,3,15,3]秒。特征测试逐一删除PAIR/NOT1/ID/GEO均拒绝，完整集合接受。/tmp/ztransfer-f012-deadlines.log：GPSProtocolTests 12/12、0失败、TEST SUCCEEDED；git diff --check通过。未实例化系统外设或实际等待墙钟15/3秒，不把该结果当作真实GATT连接失败回调验收。
- F012仍未核销：复查Coordinator发现既有applyBluetoothFailure把not found及所有pairing文本一起设awaitingPairingAction并停下；Android not found显示needsCamera但仍按5秒重试，普通pairing handshake timeout是原始error并等待用户。必须继续修正错误分类/恢复策略并回放，才能证明新失败出口遵循安卓策略。F013系统回调复用边界也仍待验证。历史核销40项不变。
- 索引714项更新BluetoothClient/GPSProtocolTests；无UI测试、真机、提交或推送。


### F012 错误分类与恢复策略（2026-10-16）

- 对照安卓 NikonGpsService.onError，将显示状态与重试条件独立计算：Camera not found显示配对提示但5秒后重试；pairing handshake timeout保留原错误并等待用户；权限与Bluetooth unavailable不自动重试；scan failed显示打开蓝牙提示并允许重试。只有配对拒绝/身份过期清除身份。
- Coordinator统一取消旧写入、定位和恢复任务；失败策略接管恢复期间，迟到disconnected不另开800ms重连。恢复等待注入仅用于测试，生产仍为5秒；代次与取消检查拒绝旧等待结果覆盖新错误。
- /tmp/ztransfer-f012-recovery.log为GPS 13/13、TEST SUCCEEDED；最终停止与恢复归属门控修改后，/tmp/ztransfer-f012-recovery-final.log为2/2、0失败、TEST SUCCEEDED。覆盖8类生产错误映射、是否安排重试、5秒请求和旧等待返回不覆盖新错误，以及身份清理回归。未运行UI测试或操作真机。
- 测试协调器保持disabled以避免系统蓝牙/定位启动，因此尚未证明enabled运行下5秒后实际重启及迟到系统disconnected组合；F012继续进行中，不核销。F013真实系统对象重用边界也仍待验，历史核销40项不变。


### F012 系统蓝牙终止状态清理（2026-10-16）

- 复查发现unauthorized/unavailable直接显示错误，绕过统一失败清理，可能遗留旧5秒恢复任务。现均接applyBluetoothFailure，沿用安卓onError的取消写入、恢复与定位规则；unavailable仍清除缓存定位。显示文案统一为“需要蓝牙权限”/“请打开手机蓝牙”。
- 新增testAdapterTerminalStatesCancelPendingRecovery：真实Coordinator处于enabled，AP阻断用于避免启动系统蓝牙/定位；经生产applyBluetoothState注入Camera not found，确认5秒等待，然后分别注入unauthorized/unavailable，确认任务取消，释放旧等待后错误不被覆盖。此测试不证明AP未阻断下的实际重启，也不证明系统delegate对象复用边界。
- /tmp/ztransfer-f012-adapter.log：GPSProtocolTests 14/14、0失败、TEST SUCCEEDED，进程退出0；git diff --check通过。F012/F013仍进行中，历史核销40项不变。未运行UI测试、真机、提交或推送。


### F014 发送前海拔有效期校验（2026-10-16）

- 已读安卓NikonGpsService.maybeSend/resolveAltitude、GpsAltitudePolicy及其测试。writeCurrentFix不再直接编码state.altitudeMeters，统一调用Coordinator.prepareGeoPayload；该生产入口每次按当前时间与坐标重验可信海拔，更新可信fix缓存后生成GEO；无可信海拔回退0米。保持安卓显示状态与发送校验的职责，不以显示值作为发送缓存。
- 新增真实Coordinator数据包验证：同一CLLocation在0秒/120秒编码83米，120.001秒/300秒编码0米；301秒新fix编码92米，附近无海拔fix复用92米，远处超过1公里编码0米。读取GEO字节14/15验实际编码值，未只测纯策略函数。
- /tmp/ztransfer-f014-altitude.log：GPSProtocolTests 15/15、0失败、TEST SUCCEEDED，进程退出0；git diff --check通过。未运行真实五分钟ticker/BLE写入、恰好1公里边界与重新获取海拔强制补写完整链，故F014进行中、不核销。F012/F013运行回调剩余项继续保留，历史核销40项不变。无UI测试、真机、提交或推送。


### F015 GPS坐标显示与复制统一（2026-10-16）

- 对照Android CoordinateFormat.kt及CoordinateFormatTest，GPSCoordinateFormat按总千分之一分先四舍五入，再分解度/分/小数，固定en_US_POSIX；方位前置，分钟两位、小数三位，支持跨度进位，负零按N/E。无效范围/非有限值返回nil，面板沿用缺值“--”。
- GPSConnectionControl两处面板坐标均调用该formatter，初次复制与地点查询成功后复制均调用同一clipboard入口；成功文本保留地点名+换行+坐标，未改地点查找生命周期。未改照片边框的独立坐标格式。
- /tmp/ztransfer-f015-coordinates.log：以-testLanguage de -testRegion DE运行GPSProtocolTests，16/16、0失败、TEST SUCCEEDED。新测试覆盖北南东西、59.9996分进位、零/负零、极点、无效输入，以及地点查询前后实际待复制字符串。静态确认面板及两个UIPasteboard入口共用该实现；未运行UI/系统剪贴板自动化。
- F015功能开发侧核销；当前历史核销41项，功能分母待重分类。F012/F013/F014剩余验证不因此关闭。git diff --check通过，无真机、提交或推送。


### F017 删除事件立即废弃恢复快照（2026-10-16）

- 对照Android CameraViewModel.requestHandleCatalogSync：删除先撤pending，再按已知目录去重，接着立即清fileScanHandleSnapshot，最后请求目录同步。iOS receiveEvent(0x4003)现按相同顺序清scanSnapshot，避免FHD/范围限制阻止空闲同步时继续提供旧游标。
- 新testDeletionInvalidatesBoundedScanBeforeWideningScope使用真实CameraRepository/PTPSession与脚本传输，分别删未读handle1及已发布handle5：三日扫描保留尾部→删除事件→恢复快照nil→扩大范围，实际重新GetStorageIDs/GetObjectHandles，仅补读缺失metadata，最终移除删除项且其他行完整保留。协议脚本全部耗尽。
- /tmp/ztransfer-f017-deletion.log：ScanBatchPolicyTests 15/15、0失败、TEST SUCCEEDED，进程退出0；git diff --check通过。F017进行中：FHD暂停/恢复及调用方已取出快照后再收到删除的竞争尚待回放，不能据范围扫描用例核销全部条件。历史核销41项不变；无UI测试、真机、提交或推送。


### F017 调用方旧快照的删除代次隔离（2026-10-16）

- scanSnapshot清空仍不能撤回页面已取出的值。现PhotoScanSnapshot带catalogRevision，仓库在接受删除事件时递增版本；scanCatalog入口及waitForForegroundPreview返回后都检查调用方快照版本，不匹配走重新枚举。新快照记录当前版本，正常同版本续扫不变。
- 将前轮两条删除回归强化为故意传入删除前保存的before快照（而非nil）：删除未读handle1或已发布handle5后都必须重新GetStorageIDs/GetObjectHandles，保留存活行。/tmp/ztransfer-f017-revision.log：ScanBatchPolicyTests 15/15、0失败、TEST SUCCEEDED，退出0；git diff --check通过。
- F017仍进行中：实际FHD等待期间删除的组合、枚举/metadata处理中删除是否能重建旧内容需继续验证；本轮仅证明调用方已取值后删除再恢复的竞争。历史核销41项不变；无UI测试、真机、提交或推送。


### F017 枚举在途删除不能重建快照（2026-10-16）

- 本轮确认旧请求返回时若直接使用最新scanCatalogRevision，会让删除前的handles重新得到有效版本。现枚举开始保存enumerationRevision，结果返回后仅当版本未变才生成恢复快照，否则保持nil。删除期间的普通目录同步请求仍保留。
- STAScriptTransport新增单次指定操作返回前的async hook；testDeletionDuringEnumerationCannotRepublishResumeSnapshot在真实GetObjectHandles返回前注入删除未读handle1，返回仍含1的旧列表，完成三日范围扫描后断言快照nil、可见5/4/3保留、脚本耗尽。验证生产仓库的actor重入窗口，而非仅直接修改状态。
- /tmp/ztransfer-f017-inflight.log：ScanBatchPolicyTests 16/16、0失败、TEST SUCCEEDED，进程退出0；git diff --check通过。F017仍进行中：实际FHD等待/恢复和metadata处理中删除的组合尚待验证，当前修复不宣称所有旧行发布竞争均解决。历史核销41项不变。无UI测试、真机、提交或推送。


### F017 FHD恢复与metadata在途删除回放（2026-10-16）

- 扩展删除回归为已发布handle5/未读handle1 × 直接恢复/FHD等待中恢复四组合。FHD用生产setFHDActive阻断，等待真实catalogLoading为true并确认无新增协议命令，再删除、确认快照nil、释放FHD；调用方仍传删除前快照，必须重新枚举目录并保留全部存活行。catalogLoading只读可见性开放给模块测试，无另设模拟恢复入口。
- 在途删除测试分别于GetObjectHandles及GetObjectInfo返回前注入删除；三日范围扫描结束后快照均保持nil。与前轮一起覆盖已取快照、枚举在途、metadata在途的恢复快照失效，不声称所有并发目录更新问题均已解决。
- /tmp/ztransfer-f017-preview.log：ScanBatchPolicyTests 16/16、0失败、TEST SUCCEEDED，进程退出0；协议脚本均耗尽，git diff --check通过。F017恢复快照失效功能开发侧核销待真机，累计42项；F018及后续目录范围/发布问题仍独立待修。未运行UI测试或实际相机FHD，无提交/推送。


### F018 扫描期间动态范围接线（2026-10-16）

- 已读Android publishBatch逐批thumbnailLoadingDaysFlow和thumbnailBatch过滤。Repository/CameraSession新增可选currentLoadingRange异步读取入口；默认调用仍使用传入值，生产PhotoListViewModel从持久化设置读取最新值，逐批接纳边界不再锁定首扫范围。
- acceptBatch在等待顺序通道后、prefetchBatch前按当前allFiles/范围复查，范围外已知日期不再请求缩略图；未知日期沿用安卓保留规则。
- 新真实Repository协议测试在首批发布后将3日改全部、或全部改1日：前者继续读全部5张，后者第二批识别边界仅保留首日并停止，脚本耗尽。/tmp/ztransfer-f018-range.log：ScanBatchPolicyTests 17/17、0失败、TEST SUCCEEDED，进程退出0；git diff --check通过。
- F018进行中：第二批边界内切范围、生产ViewModel等通道时范围变化后的GetThumb准入尚待专项回放，不能以Repository测试核销整个条目。历史核销42项不变；无UI测试、真机、提交或推送。


### F018 ViewModel缩略图等待期间缩范围（2026-10-16）

- 新testShrinkingRangeWhileThumbnailAdmissionWaitsSkipsOlderFiles运行真实PhotoListViewModel.load/acceptBatch，先以全部范围发布两日照片，在canFill生产依赖边界用continuation确认已挂起，调用setPhotoLoadingRange(.one)后释放；实际prefetchBatch仅收到最新handle5，旧handle4不进入请求。配置键原值在测试后恢复，未操作UI。
- /tmp/ztransfer-f018-admission.log：ScanBatchPolicyTests 18/18、0失败、TEST SUCCEEDED，进程退出0；git diff --check通过。该证据验证ViewModel准入，不宣称真实相机GetThumb传输或UI通过。
- F018继续进行中：第二批已经算出boundaryReached、随后await onBatch期间扩大范围的交接窗口仍待验证；现首批动态范围与等待中的缩略图缩范围已覆盖。历史核销42项不变；无真机、提交或推送。


### F018 批次停止结果交接时扩大范围（2026-10-16）

- PhotoScanResult新增loadingRangeAtStop，Repository在实际范围边界记录batchRange。ViewModel完成该批结果交接时对照最新范围，若已经扩大则保持已有行、取得恢复游标并启动下一扫描代次；generation和取消检查阻止旧交接覆盖新任务。避免设置变更发生在hasCompletedFileScan=false期间被漏掉。
- testWideningDuringFinalBatchAutomaticallyResumesRetainedCursor运行真实ViewModel，在prefetch依赖挂起时改全部，首个扫描返回三日停止结果，断言自动第二次扫描preserve=true且使用原processedHandles，最终5/4/3/2/1完整。该用例扫描closure为受控fixture，前轮真实Repository逐批范围测试同轮回归，但未把两者合成真实协议端到端。
- /tmp/ztransfer-f018-boundary.log：ScanBatchPolicyTests 19/19、0失败、TEST SUCCEEDED，进程退出0；git diff --check通过。F018尚待真实Repository→ViewModel边界组合验证，历史核销42项不变。无UI测试、真机、提交或推送。


### F018真实组合闭环与F019事件门控（2026-10-16）

- F018原fixture续扫测试已改为真实Repository/PTPSession→ViewModel：第二批handle4缩略图依赖挂起时改全部，真实三日停止结果自动续扫，只补读未接纳的2/1；断言最终5张、processedHandles为5/4/3、GetStorageIDs/GetObjectHandles各一次、脚本耗尽。/tmp/ztransfer-f018-integrated.log为19/19、TEST SUCCEEDED，已核实退出0。结合前轮首批扩大/缩小与ViewModel等待中缩范围，F018功能开发侧核销待真机，累计43项。
- F019对照Android扫描结束：metadata不完整只禁止权威缓存清理，不关闭事件。iOS两处catalogReady现在仅要求handleQueriesSucceeded；PhotoScanResult.metadataComplete仍保持false，原缓存清理调用仍要求两个条件都true。
- 新testIncompleteMetadataDoesNotDisableDeletionSyncOrNewObjectResolution使用真实仓库：首扫ObjectInfo截断但可显示handle1→删除事件→实际目录同步返回handle2→事件轮询→90ms解析新增2→catalogUpdates最终[2]，完整协议脚本耗尽。/tmp/ztransfer-f019-events.log：目录20/20、0失败、TEST SUCCEEDED、退出0；git diff --check通过。
- F019暂记进行中，需再覆盖范围受限且metadata不完整时的事件恢复，以及缓存清理调用端仍拒绝权威裁剪；未据单个事件用例核销。无UI测试、真机、提交或推送。
- 初次组合编辑命令被自动审批以可能截断测试文件为由拒绝，未执行；经读取确认后改用保留原测试的局部apply_patch，成功验证，无工作丢失或待批准操作。


### F019 受限不完整扫描的事件与缓存门控闭环（2026-10-16）

- 新testBoundedIncompleteCatalogKeepsEventsAliveWithoutAuthoritativeCachePruning运行真实Repository/PTPSession与PhotoListViewModel：三张照片中ObjectInfo截断，单日范围停止，断言实际结果metadataComplete=false且stoppedAtLoadingRange=true，真实reconcileCache依赖收到authoritative=false。
- 随后删除已显示handle3，真实空闲目录同步返回1/2/4，执行事件轮询并解析新handle4；catalogUpdates包含4且不含3，协议脚本耗尽。与前轮不限范围事件回放共同覆盖两处catalogReady接线，缓存完整性判断未被放宽。
- /tmp/ztransfer-f019-bounded.log：ScanBatchPolicyTests 21/21、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F019功能开发侧核销待真机，累计44项；不声称所有目录/缓存缺口完成，F020等独立保留。无UI测试、真机、提交或推送。


### F020 受限扫描不裁剪范围外缩略图（2026-10-16）

- 对照Android stopAtPhotoRange在reconcileThumbnailCache之前返回，PhotoListViewModel的权威清理条件新增!result.stoppedAtLoadingRange。完整性与句柄成功条件均保留，只有完整且未范围截断的扫描才授权清理。
- 新testBoundedScanPreservesOlderMemoryAndDiskThumbnails：真实PhotoThumbnailStore/临时磁盘预存新旧两张；真实ViewModel接受完整metadata但受限停止的扫描结果后，reconcile依赖实际收到false。旧照片在原store命中memory，新store读取同目录命中disk，fetch闭包均不得执行。扫描结果由fixture提供，清理门控和缓存实际读写使用生产实现；未操作系统UI或相机。
- 首轮/tmp/ztransfer-f020-cache.log因新增测试三处可抛出调用缺try而编译失败，已修正；最终/tmp/ztransfer-f020-cache-fixed.log：ScanBatchPolicyTests 22/22、0失败、TEST SUCCEEDED、退出0；git diff --check通过。
- F020功能开发侧核销待真机，累计45项；本轮只改变缓存裁剪授权，不触及用户原片。无UI测试、真机、提交或推送。


### F021 跨批双卡归属替换（2026-10-16）

- 对照Android publishBatch的replacements/withBatch：Repository在旧主行新增卡归属且不在当前batch时将merged行加入onBatch；ViewModel按已有id替换allFiles对应项，只有首次出现的id计入additions，因此替换不进入缩略图预取。
- 真实双卡脚本原批次[[6],[4],[2]]现为[[6],[6,4],[2]]，第二批携带首批6的双卡替换，最终逻辑照片仍3张。新增真实ViewModel回放在接受替换后挂起扫描，确认isLoadingFiles=true时主行已含两卡、行数1且缩略图请求仅[6]。
- /tmp/ztransfer-f021-membership.log：ScanBatchPolicyTests 23/23、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F021暂记进行中，仍需真实Repository→ViewModel组合及卡2筛选即时接纳验证，不能把两个独立测试当作该组合已验收。历史核销45项不变。无UI测试、真机、提交或推送。


### F021 真实双卡扫描中筛选与替换闭环（2026-10-16）

- 组合复核另发现storageIDsBySlot只在扫描结束赋值。对照Android在publishBatch前发布activeSnapshot.filterStorageIds，acceptBatch现读取生产恢复快照中的filterStorageIDs，逐批发布前更新卡槽映射；await后无论快照是否存在都回检取消/代次，旧任务不能更新新列表。
- 新真实Repository/PTPSession→ViewModel双卡回放使用0x10001/0x20001：首批主行6，第二批补副本归属后挂起尾部，isLoadingFiles仍true且卡2筛选立即显示6/4；缩略图请求仅6/4，释放后显示6/4/2，脚本耗尽。没有只检查最终result。
- /tmp/ztransfer-f021-filter.log为24/24、TEST SUCCEEDED；最终完善nil快照取消检查后/tmp/ztransfer-f021-filter-final.log为24/24、0失败、TEST SUCCEEDED、退出0。git diff --check通过。F021功能开发侧核销待真机，累计46项。无UI测试、真机、提交或推送。


### F023 实时删除清理缩略图填充状态（2026-10-16）

- 对照Android removeMissingCameraHandles→thumbnailFillQueue.removeHandles，applyCatalogUpdate现在先调用队列remove清pending/failed/settled与文件映射，再失效图片缓存、接纳新增。目录订阅await该方法，避免原先每次另起无序Task造成删除清理落后于后续新增；异步边界检查取消与loadGeneration。
- 新真实ViewModel回放：旧handle7/old.JPG首扫预取settled→空目录删除→new.JPG复用7，实际prefetch请求顺序old.JPG/new.JPG，旧状态失效收到7。/tmp/ztransfer-f023-reuse.log：ScanBatchPolicyTests 25/25、0失败、TEST SUCCEEDED、退出0；git diff --check通过。
- F023进行中：失败/待办状态与正在取图的旧任务迟到收尾、目录流合并导致同句柄直接换身份的情况仍需验证，不以settled回放核销全部。历史核销46项不变。无UI测试、真机、提交或推送。


### F023 在途填充任务身份隔离（2026-10-16）

- PhotoThumbnailFillQueue为每个句柄记录owner UUID，poll带出owner及扫描revision；删除清owner，新入队重新分配。finish在队列actor内同时核对owner/revision后才标settled/failed；worker两条模式都使用该入口，returnToFront也核对owner。防止旧请求迟到结果删除或完成同句柄新任务。
- 新真实ViewModel/后台worker回放：扫描返回旧handle7但不预取，后台取old.JPG挂起→删除→new.JPG复用7入队→旧请求成功返回，实际请求仍为old.JPG/new.JPG。保留既有settled复用验证。
- /tmp/ztransfer-f023-inflight.log：目录26项+PhotoThumbnailStoreTests13项共39/39、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F023仍进行中：失败/待办具体回放及目录流合并同句柄直接换身份仍待补，历史核销46项不变。无UI测试、真机、提交或推送。


### F023 合并目录更新及失败/待办清理闭环（2026-10-16）

- applyCatalogUpdate现在对同句柄比较PublishedPhotoIdentity，目录流省略中间删除时也把旧身份列入removals，清队列owner及缓存后接纳新照片。双卡仅改变storageIDs不被当作新照片删除重取。
- 原settled复用ViewModel测试强化为直接从old.JPG目录变为new.JPG目录，无空快照；实际请求old/new各一次且旧缓存失效。新增生产队列测试分别删除pending/failed，断言三类状态清空且句柄可重新poll；相同元数据删除重入仍生成不同owner，旧finish和returnToFront无效，新owner可正常完成。
- /tmp/ztransfer-f023-coalesced.log：目录26项+缩略图14项共40/40、0失败、TEST SUCCEEDED、退出0。与前轮真实worker在途成功晚返回组合覆盖F023开发侧要求；git diff --check通过。F023开发侧核销待真机，累计47项。无UI测试、真机、提交或推送。


### F024 缓存层写盘失败锁存（2026-10-16）

- 已读安卓thumbnailDiskWritesBlocked、fetchThumbnailToDisk及前台缓存写入路径。PhotoThumbnailStore新增连接所属diskWritesBlocked；writeCache统一处理前台/后台实际写失败，prefetch先允许已有磁盘命中，缺缓存才检查锁存；进入远程许可后再次回检，防止已等待任务继续fetch。resetForScan不清锁存，新store/切相机会话解除。
- 将InvalidPrefetchBytes与PrefetchCacheWriteError分开：图片校验失败保持unsettled但不锁写盘，真正write失败锁存。使用真实文件占据缓存根路径制造IO失败，修复路径后同连接重新扫描仍不得fetch，新store可成功写入。
- /tmp/ztransfer-f024-write-latch.log：缩略图15项+目录26项共41/41、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F024仍进行中：锁存尚需向批次/后台worker传播停止结果并保留游标、验证失败后已有缓存读取和实际第二张失败→后续不发请求；当前只完成缓存层，历史核销47项不变。无UI测试、真机、提交或推送。


### F024 扫描预取与后台停止接线（2026-10-16）

- CameraSession暴露缓存写失败状态；生产prefetchBatch在等待/取图前及结果后读取并通过ThumbnailBatchResult.diskWritesBlocked传播。ViewModel连接内锁存该状态：扫描继续接纳metadata但不再预取；后台两模式将当前owner/revision项放回队首后退出；后续start/wake不启动worker，新ViewModel才重置。
- 新真实ViewModel测试分别从扫描批次、后台队列进入，第二张返回写失败，确认请求只有1/2、第三张仍在目录中且无取图。初轮/tmp/ztransfer-f024-scheduler.log共42/42、TEST SUCCEEDED；复核发现测试load()不会重新扫描，改用真实reload()+wakeThumbnailFill，/tmp/ztransfer-f024-rescan.log最终1/1、TEST SUCCEEDED、退出0。初轮不能作为实际重扫证据，最终测试才覆盖此条件。
- git diff --check通过。F024仍进行中：需组合真实缓存第二张写失败与生产调度，并验证已有缓存读取、待办游标及共同等待者写失败出口；当前调度测试注入失败结果，不冒充真实磁盘到调度全链路。历史核销47项不变。无UI测试、真机、提交或推送。


### F024 真实写失败到worker停止及缓存读取（2026-10-16）

- 新真实PhotoThumbnailStore→ViewModel后台worker组合：第一张正常写入，第二张fetch时将测试专用camera目录设为0555，真实write失败触发锁存，实际fetch只有1/2，第三张未请求。恢复0755后第一张仍cached，reload/wake后请求仍为1/2；defer恢复权限并清理测试目录。
- 首轮/tmp/ztransfer-f024-real-disk.log共43项中1失败：移走整个root的故障夹具触发ensureDirectoryLocked清索引，不能证明单纯磁盘写失败的缓存读取要求。改为仅只读权限后/tmp/ztransfer-f024-real-disk-fixed.log组合1/1、0失败、TEST SUCCEEDED、退出0；首轮失败记录保留。
- prefetch共同等待分支补接InvalidPrefetchBytes/PrefetchCacheWriteError为unsettled，与发起者一致，取消与协议错误仍向上抛；共同等待并发窗口尚需单独回放。git diff --check通过。
- F024仍进行中，后台游标保留和共同等待者确定性验证待补；真实缓存失败→调度停止和既有磁盘命中已获证据。历史核销47项不变；无UI测试、真机、提交或推送。


### F024 共同等待者与停止游标闭环（2026-10-16）

- 新共同等待者测试通过生产store.activeWaiterCount确认两个调用者已共用同一flight，再释放fetch；真实不可写路径和校验拒绝两组都返回unsettled，无第二次fetch，前者锁存而后者不锁存，收尾waiter归零。
- 真实第二张写失败→worker停止测试新增生产队列状态断言：pending仍2/3、settled仅1、failed为空，证明失败项放回并保留后续游标。仅开放既有队列及等待数量的模块内可读入口用于验证，没有替代生产调度。
- /tmp/ztransfer-f024-waiters.log：缩略图16项+目录28项共44/44、0失败、TEST SUCCEEDED、退出0；git diff --check通过。结合真实0555写失败、已有缓存读取、扫描/后台停止、reload/wake不复活、新会话解除和校验失败区分，F024功能开发侧核销待真机，累计48项。此前root移动夹具失败保留，不改写为全程一次通过。无UI测试、真机、提交或推送。


### F025 普通缩略图无图响应与瞬时失败区分（2026-10-16）

- 对照Android NikonCamera.getThumbnail，Repository普通GetThumb使用executeResponse，仅NoThumbnailPresent/InvalidObjectHandle转换为空结果，其他响应与传输错误继续抛出；直接STA分支保持独立。缓存对普通确认无图在validator存在时仍保留negative/settled，避免校验器把无图重新变成待重试。
- 真实PTPSession/Repository→PhotoThumbnailStore回放两种无图、DeviceBusy及URLError连接中断：无图再次预取不发请求，忙响应同会话重试成功，连接中断恢复协议会话但保留同一store后重新发GetThumb成功。该测试注入恢复会话，不证明自动重连全链路。
- 初轮/tmp/ztransfer-f025-responses.log 45/45通过；新增IO测试/tmp/ztransfer-f025-io.log失败，原因是夹具复用已失效PTP会话。保留生产会话失效保护、修正恢复夹具后，/tmp/ztransfer-f025-reconnect.log最终45/45、0失败、TEST SUCCEEDED、退出0。直接STA既有重试回归同轮通过。
- F025功能开发侧核销待真机，累计49项；无UI测试、真机、提交或推送。


### F026 USB缓存机身身份接线（2026-10-16）

- 对照Android NikonCamera.thumbnailCacheIdentity的序列号优先规则，CameraSession移除USB deviceID直接返回，统一使用Repository身份；CameraConnectionService创建USB仓库时传入deviceID作无有效PTP序列号时的链路兜底。连接恢复用transportDeviceID保持独立。
- 新测试实际构造USB及无线CameraSession，覆盖同序列号跨链路一致、不同机身隔离、空串/全零序列号链路兜底。未启动USB浏览或真机通信。/tmp/ztransfer-f026-identity.log专项TEST SUCCEEDED、退出0；git diff --check通过。
- F026仍进行中：实际磁盘跨会话复用及连接服务接线的进一步验证待补，不能以身份相等测试声称全链路完成。累计核销49项不变；无UI测试、真机、提交或推送。


### F026 USB到无线磁盘复用闭环（2026-10-16）

- CameraSession允许注入独立PhotoThumbnailStore，默认行为不变。新增真实USB CameraSession→Repository/PTPSession脚本GetThumb写盘，再由独立无线CameraSession和新store重开同一临时根目录：同PTP序列号返回cached且零协议请求；不同序列号发一次GetThumb并独立写入。没有共享内存缓存，也没有只比较身份字符串。
- 结合前轮空/全零序列号兜底、不同机身、跨链路身份测试，F026开发侧核销待真机，累计50项。静态复核CameraConnectionService将选中设备ID传至仓库，ConnectionViewModel使用该仓库创建USB会话；未模拟ImageCaptureCore实际握手/拔插，不能声称真机连接验收。
- /tmp/ztransfer-f026-disk.log专项23/23、0失败、TEST SUCCEEDED、退出0；git diff --check通过。无UI测试、真机、提交或推送。


### F027 EXIF格式与空白字段首轮修复（2026-10-16）

- 对照Android CameraViewModel.parseExifImpl：移除0.4≤快门<1的小数秒特例，统一倒数；光圈按小数余数而非距最近整数判定；日期依次跳过空白Original/Digitized/TIFF，镜头trim后空串转nil。
- 新真实JPEG测试覆盖快门0.4/0.5/0.8/1 × 光圈1.98/2/2.02共12组合，空白Original回退有效Digitized、空白镜头nil，并断言PhotoFrameMetadata继承结果。/tmp/ztransfer-f027-exif.log专项TEST SUCCEEDED、退出0；git diff --check通过。
- F027仍进行中：TIFF末级回退及非空镜头trim、实际信息store/生成元数据管线消费仍需补强。累计核销50项不变；无UI测试、真机、提交或推送。


### F027 消费链路补强与TIFF日期待查（2026-10-16）

- 格式测试扩展为24组（12快门/光圈组合×Original/Digitized来源），包括非空镜头trim和空白nil；同一真实JPEG经过PhotoExifStore和PreparedPhotoMetadata，断言两条实际生产消费者。该用例在最终运行通过。
- TIFF末级回退新增手工EXIF IFD0 0x0132及空白Exif 0x9003/0x9004夹具；ImageIO属性读取未提供TIFF字典，测试失败。去除UIKit旧APP1后仍失败，不能归因于重复EXIF。原ImageIO写出夹具也缺该属性，但仅凭读回属性不能证明writer丢字段；先前此解释撤回，需直接验证原始字节与ImageIO读取规则。
- /tmp/ztransfer-f027-consumers.log、f027-fields.log、f027-tiff.log及f027-single-exif.log均保留失败。最终专项18项中TIFF回退1项失败；不宣称全通过。当前失败定位在夹具属性前置断言，尚未证明生产TIFF回退正确。
- F027保持进行中，累计核销50项不变；下一步核查原始EXIF及ImageIO是否规范化日期，再决定修正夹具或生产读取。git diff --check通过；无UI测试、真机、提交或推送。


### F027 TIFF日期映射与消费验证闭环（2026-10-16）

- /tmp/ztransfer-f027-tags.log诊断确认：原始IFD0日期字节正确，ImageIO属性无TIFF字典，但CGImageMetadata标签含xmp:ModifyDate=2026-10-15T12:00:00。此前writer丢字段或重复APP1解释均不能作为结论；实际缺口为属性字典未暴露已读取的日期。
- PhotoExifParser在Original/Digitized/TIFF属性均无非空日期时，延迟调用CGImageMetadataCopyTagMatchingImageProperty读取TIFF DateTime对应标签，将规范化ISO前19字符转换为安卓EXIF格式。正常日期路径不额外解析元数据。
- 真实JPEG24组快门/光圈/两级日期/镜头trim，经PhotoExifStore和PreparedPhotoMetadata一致；手工EXIF保留有效IFD0日期与空白Original/Digitized，经两条生产消费者均回退成功。手工夹具断言原始日期，不强求ImageIO字典形式。
- /tmp/ztransfer-f027-metadata-date.log本项两测试通过，但既有预算测试在异步元数据准入尚未报告失败时过早断言；补等待第三项frameError后，最终/tmp/ztransfer-f027-final.log 18/18、0失败、TEST SUCCEEDED、退出0。所有前轮失败日志保留。git diff --check通过。
- F027功能开发侧核销待真机，累计51项；不包含其他EXIF/GPS未完条目。无UI测试、真机、提交或推送。


### F028 配对评级扫描完成判定（2026-10-16）

- 对照Android PhotoRatingScan的uniqueSources完成计数及PhotoRatingPairsTest：iOS收尾不再将去重后的localRatings数量与重复sources.values行数比较，改为所有来源都有结果且来源非空。unknown仍是已读取结果；显示completed/total仍按照片行计数。
- 强化真实PhotoRatingScanController测试，分别配对JPG/NEF和配对加独立JPG：来源读取1/2次、可见进度2/3、两个配对行unknown、complete=true、loading=false、评级phase开始结束各一次。旧测试只有waitUntil而无complete断言的证据不足已纠正；没有断言无序Dictionary的读取次序，F030独立保留。
- /tmp/ztransfer-f028-rating.log：PhotoRatingScanTests 5/5、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F028功能开发侧核销待真机，累计52项；F029代次/范围重建及F030来源顺序仍未完成。无UI测试、真机、提交或推送。


### F029 评级范围变化重建首轮（2026-10-16）

- 对照Android rememberPhotoRatings的LaunchedEffect键及enteringEnabled：Controller比较ratingDays/photoLoadingDays/useObjectRating/staConnection，变化时重建本地扫描快照；仅false→true调用invalidate，范围/模式重建读取当前io.generation并保留相机缓存。旧scan收尾先核对revision，再清scanTask/phase状态，防止迟到清掉新任务引用。
- 新真实Controller测试在开启中照片范围1→5→1，三次完成分别1/5/1，累计读取7、phase开始/结束各3，相机generation仅1；随后缩略图readyDays变化不新增读取。/tmp/ztransfer-f029-range.log 6/6、0失败、TEST SUCCEEDED、退出0；git diff --check通过。
- F029仍进行中：外部仓库generation变化尚未主动接收，取消后迟到结果、扫描进行中范围变化及真实PhotoListViewModel接线仍需补验。当前测试覆盖完成后范围变化，不冒充所有代次场景。累计52项不变；无UI测试、真机、提交或推送。


### F029 外部评级代次订阅（2026-10-16）

- Repository新增bufferingNewest(1)评级代次流，订阅立即提供当前值，每次invalidate发布新代次；终止移除监听。CameraSession与PhotoRatingScanIO连接该流，Controller跟随新代次重建但不二次invalidate；自发开启失效与初始化期间通知通过generationReady/observedGeneration协调。deinit取消订阅，旧evaluate defer仅在revision一致时清自身引用。
- 新真实Repository→CameraSession→Controller测试：一次完成后直接repository.invalidatePhotoRatings，不再update输入，自动第二次读取、phase各两次、generation仅2且再次complete。读操作用stub，代次发布与订阅使用生产实现。
- /tmp/ztransfer-f029-generation.log 7/7、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F029仍进行中：在途read/cache await迟到、初始化重叠通知、真实PhotoListViewModel组合仍待补验。特别需复核evaluate内await cached后写localRatings是否缺代次检查，不能据完成后通知测试核销全部。
- 累计52项不变；无UI测试、真机、提交或推送。


### F029 旧缓存查询迟到隔离（2026-10-16）

- evaluate等待io.cached后新增取消/revision/enabled检查，再写localRatings，避免旧查询的缓存结果污染新范围；beginPhase返回后的phaseStarted赋值也核对revision与enabled。
- 新测试将旧/新两次缓存查询分别挂起，范围变化重建后释放旧5星，20ms让旧评估消费迟到结果，再释放新查询nil，断言新扫描实际read一次、结果unknown且complete。该回放使用短调度让步，尚非旧evaluate完成的显式握手，后续可强化；不能据此宣称全部取消竞态已覆盖。
- /tmp/ztransfer-f029-late-cache.log：8/8、0失败、TEST SUCCEEDED、退出0；git diff --check通过。测试过程一次只读确认原xcodebuild仍在运行，未重复启动；最终已结束。
- F029仍进行中：read迟到、初始化重叠通知、真实PhotoListViewModel范围切换组合待补，累计52项不变。无UI测试、真机、提交或推送。


### F029 已取消评级读取晚返回回放（2026-10-16）

- 新Controller回放：旧read挂起，开启状态修改photoDays重建并挂起新read；先释放新2星，断言complete；再释放不响应取消的旧5星，等待两个endPhase回调，确认仍2星、complete且非loading，phase开始/结束各2。使用生产控制器取消检查与revision防护，读取由gate控制。
- /tmp/ztransfer-f029-late-read.log 9/9、0失败、TEST SUCCEEDED、退出0；git diff --check通过。原控制器已有读取后取消检查，本轮未改业务实现，仅补此前缺失的在途证据。
- F029仍进行中：真实PhotoListViewModel.setPhotoLoadingRange入口组合、初始化重叠代次以及旧缓存回放的显式完成握手待补。已读取ViewModel测试构造器与入口：目前测试构造器固定noop评级IO，下一步可复用现有依赖注入边界补组合。累计52项不变；无UI测试、真机、提交或推送。


### F029 真实列表范围入口组合（2026-10-16）

- 在PhotoListViewModel既有依赖测试构造器添加默认noop的ratingIO注入，生产session构造器不变。新测试使用真实列表reload、setFilter、setPhotoLoadingRange与订阅传播；目录fixture提供五个日期，评级IO记录读取，范围1→5→1分别显示完成1/5/1，读取7次、phase开始结束各3。
- 测试恢复PhotoFilterPersistence原范围/筛选，结束取消评级。/tmp/ztransfer-f029-list.log 10/10、0失败、TEST SUCCEEDED、退出0；git diff --check通过。没有绕过列表入口直接调用controller更新，也未运行UI测试。
- F029仍进行中：初始化期间重叠代次通知以及旧缓存回放显式完成握手仍待补强；累计52项不变。无真机、提交或推送。


### F029 初始化代次与取消闭环（2026-10-16）

- 新测试实际Repository代次流：初次invalidate已推进1但返回挂起，再由外部invalidate推进2，释放旧返回1后，Controller重新读取generation=2并完成，最终仓库仍2，未再次失效形成循环。
- Controller提供模块内只读activeEvaluationCount，evaluate入/退成对计数；旧缓存测试释放旧5星后等待活动评估仅剩新任务，再释放新缓存nil。替代此前20ms时间让步，确认旧evaluate已退出后实际新read仍执行。
- /tmp/ztransfer-f029-initialization.log 11/11、0失败、TEST SUCCEEDED、退出0；git diff --check通过。结合真实列表1→5→1、外部代次无需输入通知、旧read晚返回、旧cached晚返回和普通缩略图更新不重扫，F029功能开发侧核销待真机，累计53项。F030来源顺序仍未修复。
- 读/缓存通过可控依赖回放；仓库代次流、控制器与ViewModel使用生产实现，不声称真实相机通信验证。无UI测试、真机、提交或推送。


### F030 评级来源读取顺序（2026-10-16）

- 对照Android PhotoRatingPairs.files.associate与PhotoRatingScan.distinctBy：iOS从eligible列表逐行查sources映射后按来源handle去重，替代Dictionary.values无序遍历。配对规则不变，缓存查询与pending读取均沿用该有序数组。
- 新真实Controller测试分别JPG先/RAW先，配对两行之间夹入独立照片，另含更旧日期照片；实际read顺序均20/30/40，配对来源20只读一次，四个可见文件均完成。不是仅比较集合或总数。
- /tmp/ztransfer-f030-order.log：12/12、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F030功能开发侧核销待真机，累计54项。无UI测试、真机、提交或推送。


### F031 无评级范围偏好时默认3天（2026-10-16）

- 对照Android TransferViewModel prefs.getInt默认3：PhotoFilterPersistence先读取可选Int，无键才用3，然后沿用normalizedRatingDays；显式0仍为全部，1/3/5保持，非法值仍归3。
- 独立UserDefaults suite验证无键、0/1/3/5、-1/2/999；真实PhotoListViewModel(session:)初始化验证无键→3、显式0→全部、5→5，ratingEnabled仍false。测试恢复原有standard键值，未连接相机或运行UI。
- /tmp/ztransfer-f031-default.log：13/13、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F031功能开发侧核销，累计55项；不据此核销N06其他未完功能。无真机、提交或推送。


### F032 普通更新不重置诊断捕获（2026-10-16）

- 对照Android LaunchedEffect键：Controller只有初次输入、enabled或范围/模式改变时更新诊断开关，新代次开始重设；普通目录/readyDays/暂停状态更新不再调用setEnabled。disable移除无条件诊断清空，诊断store语义保持安卓实现。
- 新实际Controller测试分别评级关闭/开启：beginProbe→detail第一条→目录增加及paused变化→detail第二条，二者均保留；restore(preserveEntries:true)后再次普通更新，详细记录关闭，摘要是否记录与原enabled一致，原结果保留。
- /tmp/ztransfer-f032-capture.log 14/14、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F032仍进行中：真实Debug探测/列表组合及RAW头字节/分块/等待/命令/解析耗时detail接线尚未补齐。下一步对应CameraRepository.readPhotoRatingHeaderCommand与Android NikonCamera 1949/1995行。
- 累计55项不变；无UI测试、真机、提交或推送。


### F032 RAW头详细计时首轮接线（2026-10-16）

- 对照Android readPhotoRatingHeaderInternal的detail：生产头读取累计bytes、成功chunks、gate/command/parse/other毫秒与result；readRatingChunkResult区分成功空数据和失败，尼康不支持后标准回退仅计一次成功块，命令耗时包含回退。采用ContinuousClock及既有毫秒工具，摘要之外的detail仍受显式probe开关保护。
- 首轮/tmp/ztransfer-f032-timing.log因Swift并发隔离拒绝异步局部函数捕获可变计数而编译失败；改为actor方法返回不可变计时结果，由调用方汇总。最终/tmp/ztransfer-f032-timing-fixed.log专项TEST SUCCEEDED、退出0；git diff --check通过。
- 强化真实PTPSession/Repository回退测试：尼康unsupported→标准成功，report包含精确bytes/chunks=1、全部耗时字段及result=4，协议脚本耗尽。现有评级协议/控制器回归同轮通过。
- F032仍进行中：多块/空块/错误计时边界、实际Debug探测与列表更新组合及耗时数值验证仍待补；本轮只核对单次回退的字段存在和计数，不宣称完整诊断已验收。累计55项不变；无UI测试、真机、提交或推送。


### F032 多块及错误诊断验证（2026-10-16）

- 强化真实协议连续头测试：首块8字节+尾块拼接解析评级2，detail记录完整bytes/chunks=2；首回复前显式等待15ms，断言command毫秒≥10，证明耗时来自实际协议等待。
- 新边界回放：3字节首块后成功空尾块计chunks=2/result=unknown；第二块DeviceBusy抛ratingReadDeferred，不发布伪完成read日志；所有脚本耗尽。原标准命令回退与控制器捕获保持回归。
- /tmp/ztransfer-f032-chunks.log专项23/23、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F032仍进行中：真实CameraSession.probeRawRating与列表更新组合及gate等待值验证待补。已核对PhotoListView.runRawProbe使用beginProbe→session.probeRawRating→restore(preserveEntries:true)，该入口逻辑需在无UI测试的功能组合中覆盖。
- 累计55项不变；无UI测试、真机、提交或推送。


### F032 RAW真实探测与列表更新组合（2026-10-16）

- 新功能组合运行CameraSession.probeRawRating→真实Repository/PTPSession脚本，同时PhotoListViewModel使用生产PhotoRatingScanIO(session:)；目录初始fixture提供JPG。评级开/关两种模式，在RAW头回复前调用实际applyCatalogUpdate新增RAW及setTransferBusy开关，完成后再次切换传输状态。
- 报告保留对象属性3星、RAW头detail、header4星和probe complete；恢复后详细记录关闭，摘要开关与原评级状态一致；协议脚本耗尽。没有替代session探测实现，仅目录枚举使用fixture，无UI操作。
- /tmp/ztransfer-f032-probe-list.log 24/24、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F032仍进行中：gate等待的实际数值验证待补；其余已验证项不等于该项全部完成。累计55项不变；无UI测试、真机、提交或推送。


### F032 调度等待计时闭环（2026-10-16）

- 新真实Repository/CameraIOGate/PTPSession测试：挂住GetDeviceInfo交互事务，启动RAW头评级，等待生产scheduler snapshot.queued=1并确认仅一个命令已发；继续阻塞20ms再释放，最终评级4且报告gate≥15ms，协议脚本耗尽。与前轮command延迟测量共同证明两类耗时实际计量。
- /tmp/ztransfer-f032-gate.log 25/25、0失败、TEST SUCCEEDED、退出0；git diff --check通过。结合开/关状态真实RAW探测和列表目录/传输更新、恢复捕获、尼康→标准回退、多块/成功空块/Busy、字段与数值验证，F032功能开发侧核销待真机，累计56项。
- 未执行UI剪贴板操作或真机测时；验证的是生产报告字符串与功能链路。既有失败编译日志保留。无UI测试、真机、提交或推送。


### F033 范围拆分及帮助输入隔离（2026-10-16）

- 按用户最新范围，呼吸/交替曲线、Genie时序及样式不在本阶段开发或验收范围，不记成已修复。保留功能要求：外点仅关闭帮助、气泡内点不关闭、阻断下层筛选和列表拖动。
- 对照Android FileListScreen帮助AnchorPopup及AnchorPopup透明tap/drag消费层：iOS帮助显示时新增独立全屏透明输入层，外点只设showRatingTip=false；筛选panel禁用hit testing；气泡自身消费tap/drag，不再关闭；筛选呈现状态变化统一清帮助标记，防止关闭后残留。
- /tmp/ztransfer-f033-help-build.log BUILD SUCCEEDED、退出0；git diff --check通过。按用户要求未运行UI测试，也未以模型镜像测试冒充触摸路由验证。功能代码已补，真实点击/拖动命中仍待集中手工验收；F033不计核销，累计56项不变。
- 后续可继续F034等功能逻辑，不为等待界面验收停住全部工作。无真机、提交或推送。


### F034 离线入队功能复核（2026-10-16，按最新范围核销）

- 重新读取安卓FileListScreen单张/连拍/日期组准入及TransferViewModel.isTransferredOriginal、ExistingFileNameIndexTest。安卓使用当前目标文件夹的原片索引；不增加点击时同步磁盘扫描，也不把手动重复导出当错误。
- 当前iOS已有canEnqueueManually与admitManualTransfer，列表单张、日期组、预览单张/连拍均在震动、飞行和入队之前调用；无目录转目录选择，离线缺任一原片拒绝整批并显示camera_not_connected。提示位于预览上层。此次未重复改写已有生产逻辑。
- 新增真实临时目录测试：统一/按天/按类型三种方式，真实扫描命中不同前缀副本、缺原片与混合批次拒绝、重连放行、补齐后放行、删除并刷新后重新拒绝。既有测试覆盖目录切换、尺寸/类型隔离与内存新导出索引；真实TransferQueueViewModel验证单/批×立即/延后四组合离线完成。
- 本轮/tmp/ztransfer-f034-admission.log及同名xcresult：11/11、0失败、TEST SUCCEEDED、退出0；包含同测试类两项既有提示状态/运动模型回归，不是UI测试。git diff --check通过。此路径为本轮结果，旧同名日志历史结论以此前记录为限。
- 旧F034长期挂起包含Surface投影与页面视觉验收，按用户最新范围延期。功能开发侧核销，累计57项；页面实际触摸/相机断线重连仍待集中手工验收，模型connected切换不宣称真实无线重连验收。F130裁切接纳反馈、V003预览拒绝后的手势恢复仍独立未完成。未真机、提交或推送。下一项F035连拍合集操作及预览快照。


### F035 连拍合集打开预览的状态隔离（2026-10-16）

- 依据安卓FileListScreen.onPreviewBurst、BurstCollectionCell及PhotoPreviewItemsTest：图片轻点无动作；长按只在预览快照加入目标合集成员，选中第一张；两个按钮各自负责入队/展开，打开前不改变底层列表。预览集合页持续保留，关闭成员时由返回定位准备展开底层。
- PhotoListView移除合集轻点toggle与长按直接insert。openPreview每次复制列表expandedBurstIDs到独立previewExpandedBurstIDs，只给长按目标增加预览展开状态。普通打开同样重置快照，避免上次目标残留。BurstThumbnailView把图片长按放在按钮下方独立图片区域，父层长按只处理普通照片；两个操作按钮接线保持独立。
- PhotoPreviewOpeningSnapshot从真实PhotoPreviewView初始化逻辑抽出，生产直接消费其entries/index；覆盖已有展开组、目标组、另一个保持收起组、普通成员打开与关闭分组后的逐张分页。测试明确目标首成员、持久合集页、收起仅删除目标成员，且快照不可变。不是用测试中的复制实现证明生产行为。
- 预览内部onBurstChanged显式展开/收起继续同步列表；startClose在关闭前调用preparePreviewDismissTarget，现有返回成员定位负责展开底层。本轮仅静态核对接线，未宣称真实触摸/关闭动画验收通过。
- /tmp/ztransfer-f035-opening-20261016.log首轮4/4；图片手势分离后的/tmp/ztransfer-f035-input-20261016.log最终4/4、0失败、TEST SUCCEEDED、退出0；git diff --check通过。未运行UI测试，实际按钮/图片触摸路由留集中手工验收；精细样式动画延期。F035功能开发侧核销，累计58项，T04及F039/F051/V003其他缺口不因此完成。下一项F036扫描结束后的类型选择归一化。无真机、提交或推送。


### F036 类型筛选归一化（2026-10-16）

- 依据安卓FileListScreen:921–937的LaunchedEffect：空选择立即归回全部；非空选择在未完成扫描或仍加载时保留；完成且不加载时，若与当前展示范围availableExts无交集才清空，有一种匹配则保留整组选项，不裁掉暂不存在的类型。
- PhotoListViewModel.publishSections在计算未过滤展示范围的类型后执行同一规则，清理时调用PhotoFilterPersistence.save；真实setFilter、扫描批次、加载范围调整与目录变化均复用该入口。最终扫描发布移到isLoadingFiles=false/hasCompletedFileScan=true之后，使本次完成立即生效。未把缓存清理的authoritative条件混作类型归一化条件。
- 新增真实ViewModel扫描测试，暂停批次后断言扫描中选择保留；缺NEF/部分JPG匹配/空集合×JPG目录/空目录六组合，完成后检查筛选、实际sections和持久化恢复；完成后的失效类型编辑也立即归一化。已有扫描回归一并运行。
- /tmp/ztransfer-f036-types-20261016.log与同名xcresult：30/30、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F036功能开发侧核销，累计59项；未运行UI测试或真机换相机验证，未提交/推送。下一项F037回顶按钮功能规则，动画仍延期。


### F037 回顶显隐规则第一阶段（2026-10-16，未核销）

- 已读安卓FileListScreen:744–782、1847–1905及日期header/合集items构造。阈值是LazyGrid首可见索引30，包含日期标题和合集卡；同索引比较整数物理像素offset，超过4px才判方向。停止后1800ms隐藏，恢复滚动取消旧计时，程序回顶期间抑制，结束/取消释放抑制。
- 新增PhotoListBackTopState值类型，独立接收位置、滚动态和时钟，保存显隐/截止时间/回顶状态。两个规则测试覆盖方向、深度、死区、跨行、旧计时失效、回顶完成/取消后的再次触发；同轮保留真实UIScrollView观察器的两项原有测试。
- /tmp/ztransfer-f037-policy-20261016.log及xcresult为4/4、0失败、TEST SUCCEEDED、退出0；git diff --check通过。这仅验证规则和既有观察器，尚未把新状态接到页面。当前PhotoListView仍使用-360偏移门槛，F037明确未完成，累计59项不变。
- 下一步：按当前实际显示的日期头/照片/合集构建稳定索引，结合可见边界计算首条索引及物理像素offset；补观察器滚动停止/减速结束事件，接1800ms计时与离页清理、回顶结束及取消复位。不得用像素距离或照片计数冒充安卓条目索引。用户已要求跳过UI测试，页面触摸集中手工验收，精细动画不在本轮范围。无真机、提交或推送。


### F037 滚动停止事件（2026-10-16，仍未核销）

- PhotoListScrollActivity增加可选onActivityChanged回调，保持已有onScroll调用约定；拖动或减速首个事件报告true，活动期间以16ms轻量任务观察UIScrollView.isDragging/isDecelerating，实际停止才报告false。没有替换SwiftUI的scroll delegate，也不以偏移暂时静止猜测停止；闲置不轮询。
- detach取消任务并清理观察，避免离页后迟到false。真实ObserverView+UIScrollView测试覆盖拖动去重、无新offset仍减速、停止单次通知、静态布局不启动以及解绑后的回调隔离。
- /tmp/ztransfer-f037-activity-20261016.log及xcresult：5/5、0失败、TEST SUCCEEDED、退出0；git diff --check通过。这是XCTest功能测试，不是UI自动化；未真机、提交或推送。
- F037仍未完成、累计59项：页面尚未消费新活动回调，首可见条目映射、1800ms计时/离页清理和程序回顶复位仍待接。注意iOS最低部署16.0，不能无条件使用iOS17动画完成API。后续应复用当前列表的日期头/展开或收起的合集及成员顺序，缓存索引避免每个滚动事件扫描整份目录；像素阈值-360必须最终移除。


### F037 页面接线与最终功能验证（2026-10-16）

- PhotoListScrollLayout按当前presentedSections和photoGridEntries的真实顺序建索引：日期头占一项，合集占一项，展开成员分别占项；收起日期不包含成员，收合中仅包含当前保留项。索引仅在目录/展开状态变化时重建，不随每次滚动全量遍历目录。
- 日期头和实际格子分别发布有身份的global bounds，PhotoListBackTopController在有效视口内选择最低索引，按displayScale转整数物理像素offset。处理2/3/4列同一行、部分露出日期头及已离屏/未注册项。原PhotoListView的value < -360门槛已移除。
- 页面消费PhotoListScrollActivity活动回调，控制器连接既有PhotoListBackTopState、可取消1800ms任务，仅显隐变更发布ObservableObject状态。继续滚动取消旧截止时间；空目录/离页reset清计时和方向基线。点击beginReturn先隐藏并抑制；到顶finishReturn，用户新拖动可中断，离页reset兜底。
- 按用户本阶段仅基础可用界面要求，回顶使用无动画scrollTo顶标记；安卓精细滚动曲线/距离/时长明确延期，未用iOS17 API，保持iOS16兼容。
- 新增真实生产layout索引和controller测试，覆盖日期头/合集/展开成员/收合、2/3/4列物理像素及首条边界、真实1800ms计时、回顶抑制与恢复、离页重置。连此前规则与真实ObserverView测试，/tmp/ztransfer-f037-page-20261016.log及xcresult最终8/8、0失败、TEST SUCCEEDED、退出0；git diff --check通过。
- F037功能开发侧核销，累计60项。尚未运行UI测试/真机滚动，不把模型和UIKit观察器测试冒充页面手势验收；集中手工验收仍保留。无提交/推送。下一项F038同handle多任务显示最新任务状态。


### F038 最新任务映射（2026-10-16）

- 依据安卓FileListScreen.buildLatestTaskIndexByHandle及PhotoListDerivedStateTest：按队列顺序后项覆盖前项，无状态优先级，不按taskId/UUID大小排序。
- TransferQueueViewModel.task(for:)改为使用latestTaskIndices直接读取当前快照；每次结构快照赋值后在didSet重建，独立高频progress流不触发索引重建。删除最新项后自然回退至仍在队列的前一项，清空时索引也清空。没有改变手动重复入队或任务生命周期。
- 特别核对@Published在赋值前通知订阅者：索引必须保持旧值直至新snapshot赋值完成，避免同步查询用新索引访问旧数组。新增真实objectWillChange订阅断言，覆盖发布期间task查询与当前snapshot一致。
- 新增25种新旧waiting/transferring/completed/failed/cancelled组合，UUID逆序仍由后项获胜；真实TransferQueue→ViewModel快照验证双任务、新任务撤回不被旧等待遮住、删除回退、清空及未知handle。格子仍使用生产task(for:)，最新completed继续走已有transferred原片索引绿勾分支，未把任务完成冒充当前目录已有原片。
- 首轮/tmp/ztransfer-f038-latest-20261016.log 43/43；发布一致性收紧后最终/tmp/ztransfer-f038-publication-20261016.log及xcresult 43/43、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F038功能开发侧核销，累计61项；未UI/真机验收、提交或推送。下一项F039合集与首成员坐标身份冲突（仅功能相关部分，精细飞行动画延期）。


### F039 合集、成员和按钮坐标身份（2026-10-16）

- 依据安卓FileListScreen独立cellBoundsRegistry/burstBoundsRegistry、BurstCollectionCell的plusBoundsRef及AutoQueueFlightSourceTest：合集与首成员不能共享handle键；仍被组合但不在视口内的格子不能充当可见来源。
- PhotoListCellID拆为photo(handle)、burst(id)、burstEnqueue(id)，真实格子Preference按entry.cellID发布，合集按钮单独测量自己的global frame。onPreferenceChange继续整份替换当前快照，不累计已卸载项。合集长按用合集卡片，普通预览与返回始终用photo；日期收起按实际entry身份取末个可见格子，预览返回的可见索引也不再以firstFile.id代替合集。
- 新增visiblePhotoListCellBounds过滤非正尺寸/无效/视口外frame；打开锚点、合集入队按钮、普通入队来源及批量可见成员使用它。日期收起和打包可见性改用实际列表视口而非整个屏幕，避免把顶栏下方或底部被遮挡的预加载格子当可见来源。
- 生产Preference reducer测试覆盖相同数字照片/合集/按钮三项同时存在、删除成员不借用合集、仅成员存在时不借作合集/按钮；可见来源测试覆盖离屏仍组合、zero/null/infinite拒绝和部分可见可用但不能作为完整预览返回位置。页面调用链静态逐处核对，未把这些测试声称为真实触摸验收。
- /tmp/ztransfer-f039-identity-20261016.log及xcresult最终10/10、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F039功能开发侧核销累计62项；精细飞行/返回动画仍按用户要求延期，F041/F051等完整飞行边界不据此核销。未UI测试、真机、提交或推送。下一项F040评级空态判定。


### F040 评级未知阶段的空提示（2026-10-16）

- 依据安卓FileListScreen:1616的精确条件：filterRatingEnabled && filterRating != null && ratingScan.loading时仅隐藏no_photos_match_filter句子，图标/清筛选按钮保留；不以complete、completed/total或忙态单独代替loading。
- PhotoFilterState.showsNoMatchMessage封装条件，真实PhotoListView把filter与ratingScan.loading结果传给PhotoListEmptyState；非筛选空目录文本和USB提示不受影响，没有增添“读取中”等安卓未提供文案。
- 测试采用独立预期案例表，覆盖关闭评级、只开加载未选星、零星/五星读取中及结束；真实PhotoListViewModel注入受控评级读取，五星筛选无行时先隐藏，传输忙态开关期间保持，读取完成得到两星后仍无行但显示无匹配，清筛选恢复照片。
- 首轮/tmp/ztransfer-f040-empty-20261016.log因测试将async actor条件传同步等待助手编译失败，保留记录；修正后empty-fixed为16/16。边界用例改为独立预期表后最终/tmp/ztransfer-f040-final-20261016.log及xcresult为16/16、0失败、TEST SUCCEEDED、退出0；git diff --check通过。
- F040功能开发侧核销，累计63项；未UI测试/真机慢相机验证、提交或推送。F041核对为边框、叠片布局、按钮尺寸/皮肤、徽标/日期动画等纯视觉要求，按用户最新指示延期，不计已修复。下一项F042，需先区分纯飞行效果与押扣计数/取消清理的功能状态，后者继续处理。


### F042 飞行准入与暂扣计数（2026-10-16）

- 依据安卓FileListScreen单/组入队from非空与同源queueFlights.none门控、onQueueFlightStarted仅在创建后执行、DisposableEffect离页按holdsQueueCount合计取消及onDone完成回调。传输重复入队本身仍允许，去重仅限制显示飞行。
- PhotoListFlightAdmissions按有效视口内source准入，同源在途拒绝；接真实startListQueueFlight，移除屏幕中心伪造起点。单/组调用不再预先押扣，只有准入成功创建飞行才beginQueueFlightHold。批次来源为空不会退借首张照片坐标。
- 每次准入分配UUID和count；finish消费ID后返回待释放计数，再删除显示项并取消任务。重复完成、取消后迟到完成、同起点新飞行均不会重复释放或影响新计数。列表结束任务按ID保存；切队列、进入监看和根离页统一调用cancelListQueueFlights，仅释放列表自己的暂扣，不直接清零共享预览计数。
- 新增生产准入模型测试覆盖nil/zero/null/infinite/离屏/零计数拒绝、同源重复、不同源批次、完成一次消费、取消总数、重入及旧回调隔离；原坐标和回顶回归一并通过。真实任务入队调用仍位于startListQueueFlight返回后执行，未因视觉准入失败拒绝任务。
- /tmp/ztransfer-f042-admission-20261016.log及xcresult：12/12、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F042功能开发侧核销，累计64项；真实页面连点/导航待集中手工验收，精细轨迹时序按范围延期，F051/F084其他状态不据此核销。未UI测试、真机、提交或推送。下一项F043日期编辑器统一公历。


### F043 日期编辑全程固定公历（2026-10-16）

- 依据安卓DateRangeEditor/DateEndpointWheels：LocalDate/YearMonth固定ISO公历，年份范围覆盖1990、起止年及当年+1；修改年/月时将日裁至新月末，提交按起止日期排序。相机日期不能随系统佛历或农历显示成另一套年月日。
- 抽出PhotoFilterDates统一calendar、解析、短文本、日期键、月末裁切、年份列表和提交范围；显式Gregorian，仅继承系统时区以保持本地“今天”。PhotoFilterDateEditor初始化/年份/提交与DateEndpointEditor年月日、天数、短文本/拨轮提交全部使用该实现，移除两处UI中的Calendar.current和重复私有日期实现。
- 生产共用逻辑测试注入Gregorian/Buddhist/Chinese/IslamicCivil×上海/洛杉矶8配置，验证2024-02-29的组件/29天/短文本/日期键、改2023年→2月28日、31日改4月→30日、颠倒端点提交排序、1990至当年+1及1980–2030越界端点年份范围。既有非法公历日期拒绝测试同轮通过。未通过修改系统全局设置模拟UI，不夸大为真实编辑器触摸/系统切换验收。
- /tmp/ztransfer-f043-calendar-20261016.log及xcresult：2/2、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F043功能开发侧核销，累计65项；未UI测试/真机、提交或推送。下一项F044普通AP/USB预览FHD重试、能力记忆和EXIF后缩略图fallback顺序。


### F044 普通预览FHD请求第一阶段（2026-10-16，未核销）

- 已读安卓NikonCamera.getFhdPicture/classifyFhdResponse/updateFhdSupport及FhdResponseDispositionTest：仅OK且非空为成功；未知状态下明确unsupported才熔断，已成功会话不被单对象unsupported推翻；DeviceBusy最多2次重试、间隔160ms。取消必须传播，传输异常不能继续同连接fallback。
- CameraRepository普通AP/USB preview改为仅FHD，不再在同方法内连续请求LargeThumb/GetThumb；directReader的STA独立分支保持。新增会话级fhdSupported和readFHDPreview，完整负响应返回空Data表示无FHD，底层PTPSession错误继续抛出并沿用其通道失效保护；CameraSession误写的统一fallback注释已纠正。
- 新增PreviewProtocolReplayTests（放在已有RatingProtocolReplayTests.swift目标内）：忙→忙→成功实测至少300ms总等待、三次忙结束且下个文件仍请求、空payload不熔断、首次unsupported免下一请求、先成功再unsupported仍可请求、取消忙态等待不继续重试且新文件可继续。连现有CameraIOGateTests真实预览/EXIF优先级回归，/tmp/ztransfer-f044-fhd-20261016.log及xcresult 23/23、0失败、TEST SUCCEEDED、退出0；git diff --check通过。
- F044仍未核销，累计65项。下一步必须补真实CameraSession.previewAndExif失败FHD→EXIF结束→可允许GetThumb的命令顺序回放，运输错误/会话失效后不继续命令，以及STA独立路径回归；页面现有fhdUnavailable/exifFinished门控仅静态可见，不能把helper存在当实际路径验证。未UI测试、真机、提交或推送。


### F044 预览顺序、传输失效和STA回归（2026-10-16）

- 在第一阶段修复之上补真实CameraSession.previewAndExif回放。FHD明确不支持后先发布空图结果，再执行真实PhotoExifStore的128KiB getPartialObjectEx；头部正常空数据和DeviceBusy错误两种情形均验证FHD→EXIF，返回后通过真实session.thumbnail触发GetThumb，线上记录严格为三条操作且无LargeThumb。
- 该测试证明真实会话方法不会提前请求GetThumb，以及EXIF失败不会阻断后续缩略图命令；测试显式调用thumbnail，不冒充SwiftUI自动触发E2E。另逐处核对PhotoPreviewView：当前页通过previewAndExif，finishRemoteExifLoad只在返回后标exifFinished，PreviewImage任务的allowRemote参数来自isCurrent && fhdUnavailable && exifFinished；邻页高分辨率仅走preview，不触发此缩略图回退。
- 传输失败回放在FHD响应前抛networkConnectionLost：仓库向上传播，随后preview和readPrefix均被真实PTPSession.invalidated拒绝，线上只有第一条FHD，没有重试/EXIF/fallback残包风险。此前忙态等待取消回放仍通过。
- STA独立能力/MPF/缩略图回归STAMetadataTests 18项通过；普通FHD回放6项和IOGate19项同轮通过。最终/tmp/ztransfer-f044-order-20261016.log及xcresult 43/43、0失败、TEST SUCCEEDED、退出0；git diff --check通过。
- F044功能开发侧核销，累计66项；未实际AP/USB/STA真机或UI触摸验收，未提交/推送。F045方向、F046解码预算及其他预览问题不因此核销。下一项F045。


### F045 普通预览保留相机像素方向（2026-10-16）

- 依据安卓CameraViewModel.loadFhdPreview明确honorExifOrientation=false，设置效果预览单独校正方向。不是把全局图片读取都改为忽略EXIF。
- PhotoPreviewView新增decodeCameraPhotoPreview：ImageIO读取原始CGImage，构造orientation.up的UIImage，不附带EXIF旋转/镜像。当前页finishRemoteImageLoad和邻页loadHighResolution都调用该入口；共享手动rotationDegrees及跨页状态保持原逻辑。PhotoListView效果演示仍直接UIImage(data: previewData)，没有替换其方向语义。
- 新增非对称四色48×32真实JPEG EXIF1–8夹具，先读取源属性确认方向标签确实存在，再验证生产解码尺寸48×32、orientation.up。每个方向做0/90/180/270度UIKit手动旋转渲染，PNG像素输出与EXIF1基准逐一相等，共32组合；普通UIImage路径仍保留非1方向，空数据返回nil。
- /tmp/ztransfer-f045-orientation-20261016.log及xcresult为1/1测试、0失败、TEST SUCCEEDED、退出0；git diff --check通过。该测试是生产解码与UIKit像素渲染，不宣称SwiftUI实际跨页手势或裁切映射验收；C20仍独立核对。F045功能开发侧核销累计67项，未UI测试/真机、提交或推送。F046解码1920边界与后台处理仍未实现，下一项继续F046。

### F046 第一阶段：预览尺寸与后台解码（2026-10-16）

- 对照安卓 CameraViewModel.loadFhdBitmap 的 Dispatchers.Default、2幂采样和1920长边边界，共用 ImageIO 解码入口不放大小图、不应用EXIF方向；当前页和邻页接入独立后台任务。ImageIO同步调用不可中断，但父任务取消会传递并在结果返回前再次检查，防止取消结果写入页面缓存。
- CameraSession.previewAndExif 回调改为可等待异步回调，维持预览解码/发布后再读取EXIF的交互优先级范围；当前页的loading所有权保持到处理结束，避免后台解码期间重复请求。
- 尺寸/方向原专项 /tmp/ztransfer-f046-bounds-20261016.log 为2/2、TEST SUCCEEDED；后台接线后 /tmp/ztransfer-f046-background-20261016.log 为7/7、TEST SUCCEEDED、退出0（5种真实JPEG尺寸及6项FHD协议回归）。这些测试未证明真实翻页取消交错或主线程耗时。
- ImageIO输出使用原生像素格式，未声明与安卓RGB_565内存等价；直方图仍同步，真实缓存峰值和卡顿未测。本项继续进行中，累计开发侧核销仍67项；无UI测试、真机、提交或推送。

F046补充专项 /tmp/ztransfer-f046-cancel-20261016.log 为1/1、TEST SUCCEEDED、退出0：从MainActor调用真实后台入口，确认2560×1440输出1920×1080、坏数据返回nil、预先取消抛CancellationError。尚未覆盖解码中途取消的确定性交错；git diff --check通过。

### F046 直方图后台化（2026-10-16）

- 对照安卓PhotoPreview.kt:545–559，新增PhotoPreviewHistogramModel后台计算现有亮度算法。来源替换（含同文件新图）使用独立请求UUID，取消及身份双重检查；关闭、无图、切页、离页清理。没有新增相机请求。
- 可控挂起计算覆盖新结果先返回、同文件旧结果不覆盖、clear后迟到不恢复。为模型测试，不代表实际SwiftUI切页验收。同步CoreGraphics调用不可中断，取消后丢弃结果。
- /tmp/ztransfer-f046-histogram-20261016.log：DomainModelTests 173/173、0失败、TEST SUCCEEDED、退出0，含尺寸/方向/后台入口回归；git diff --check通过。无UI测试、真机、提交、推送。
- F046真实翻页取消、缓存峰值和主线程耗时仍待验，不核销，累计67项。F047模式/RGB/JPEG来源/视频隐藏仍独立待补。

### F047 视频封面与合集排除（2026-10-16，进行中）

- 安卓PhotoPreview.kt:125,545–559,1276–1279规定MOV/MP4视频无照片直方图，合集没有currentFile，不改变保存模式。iOS共用photoPreviewHistogramCanAnalyze，接入图片回调、当前页重新计算及显隐三处；切页仍通过F046清理旧计算。仅判定资格，不写偏好。
- /tmp/ztransfer-f047-video-20261016.log及xcresult：2/2、TEST SUCCEEDED、退出0，覆盖MOV/MP4大小写、合集nil、照片启用/禁用，另回归迟到结果隔离。无UI/真机验收；git diff --check通过。
- 已读HistogramMode.kt及RemoteToolsInstrumentation模式循环断言，确认OFF→RGB→LUMA→OFF；restore优先合法字符串，否则按旧bool回退LUMA/OFF。RemoteViewfinderFeatures.kt:132–197要求RGB共用峰值、FHD JPEG先2幂采样至≤512、sRGB8位并逐像素统计。模式/迁移/RGB和JPEG分析尚未接入，F047不核销，累计仍67项。

### F047 模式与RGB第一阶段（2026-10-16）

- 对照HistogramMode.kt、TransferViewModel:1291/1495及RemoteToolsInstrumentation:192，复用RemoteHistogramMode的枚举格式，新增next/restore。照片UI独立AppStorage preview_histogram_mode，合法新值优先，无效/缺失按旧preview_histogram_enabled恢复LUMA/OFF；点击仅写新键，监看偏好不合并。
- 照片直方图模型发布亮度与RGB结果，基本Canvas显示三个通道；RGB/LUMA切换直接选择已有分析结果。显示图分析由缩放平均改为安卓ceil(sqrt(pixelCount/24000))网格取点，Rec.709整数权重、亮度独立峰值与RGB共同峰值；sRGB8位解码。细节样式不在本阶段范围。
- /tmp/ztransfer-f047-rgb-20261016.log及xcresult：DomainModelTests 176/176、0失败、TEST SUCCEEDED、退出0。新增模式循环/合法与无效存储值×旧布尔恢复、真实四色图RGB相对2:1:1和亮度计数；包含取消隔离/视频/尺寸方向回归。实际AppStorage重启持久化仅静态接线，未声称运行重启验收。git diff --check通过。
- FHD JPEG独立≤512采样分析/逐像素路径及缓存接线仍待补；当前按显示图计算不等于安卓FHD分析完成。分析临时RGBA缓冲仍为显示图尺寸，受F046显示图边界约束，真实峰值未测。F047不核销，累计67项，无UI测试/真机/提交/推送。

### F047 FHD JPEG小图分析与缓存（2026-10-16）

- 对照RemoteViewfinderFeatures.previewHistogramFromJpeg及PhotoPreview:887–897/933，后台共用响应入口返回CameraPhotoPreviewContent（显示图+统计值）。先按2幂采样长边≤512，8位sRGB上下文逐像素计数，再解码显示图；分析失败不影响显示，不保留JPEG字节。当前页、邻页均接入，统计结果按同一retainedPhotoPreviewIDs范围淘汰。
- 已有FHD统计优先直接发布；开启直方图或切换RGB/LUMA不再重解FHD，不增加相机读取。无FHD统计时继续后台分析已显示缩略图。show(cached:)会取消旧缩略图计算并失效请求ID。
- 首轮 /tmp/ztransfer-f047-jpeg-20261016.log 共183项，2个断言失败均为新增513奇数尺寸夹具错误假设ceil预算必然等于输出：ImageIO实际256而非257；其余包括6项协议回归通过。修正为奇数256…257采样预算、偶数精确检查后 /tmp/ztransfer-f047-jpeg-bounds-20261016.log 为1/1、TEST SUCCEEDED、退出0。覆盖256/512/513/1920/4096真实JPEG及小图孤立亮点完整统计；不宣称与安卓解码器逐像素相同。
- git diff --check通过。缓存优先/淘汰和AppStorage独立持久化接线静态已核对，仍需补更直接的运行证据；F047继续不核销，累计67项。F046真实翻页取消/峰值/耗时仍待验。无UI测试/真机/提交/推送。

### F047 功能开发侧核销（2026-10-16）

- PhotoPreviewHistogramPreferences为页面实际使用的DynamicProperty，保留独立AppStorage新/旧键。真实隔离UserDefaults suite测试从旧true恢复LUMA、写OFF优先于旧true，循环RGB/LUMA/OFF后重新创建组件恢复，remote_histogram_mode始终不变；不宣称杀进程重启验收。
- 缓存测试挂起缩略图分析，show(cached:)发布同文件FHD统计后再释放旧结果，验证亮度/RGB不被覆盖；clear后重显缓存不增加分析次数。页面当前/邻页写入及同retainedPhotoPreviewIDs淘汰已静态核对，未跑UI翻页。
- /tmp/ztransfer-f047-cache-prefs-20261016.log及xcresult：2/2、0失败、TEST SUCCEEDED、退出0；git diff --check通过。结合前述三档/迁移/RGB共同峰值/视频合集门控/≤512 JPEG与孤立亮点验证，F047功能开发侧核销，累计68项；细节样式不在当前范围。首轮JPEG奇数尺寸夹具失败保留，不改写为183项全绿。
- F046仍待实际翻页取消/峰值/耗时验收，不核销。无UI测试/真机/提交/推送。下一项F048。

### F048 当前目录已传状态统一（2026-10-16）

- 对照安卓FileListScreen:1274–1281/2175，预览已传标记直接复用当前目录索引。删除PhotoPreviewView初始化遍历文件系统的localOriginalURLs快照及队列completed兜底；transferredOriginal现在只读父页面传入的transferredFileIDs，与列表单片同源。
- 静态复核PhotoListView的目录切换、storageModeRaw变化均调用refreshTransferredIDs；队列变化仅recordTransferredOriginals按当前root/folder记录。预览不再持有打开时目录状态，队列清空也不再独立推断已传。
- /tmp/ztransfer-f048-index-20261016.log及xcresult：ExportedOriginalIdentityTests 11/11、0失败、TEST SUCCEEDED、退出0，覆盖目录/存放方式/名称与尺寸身份、三种存放方式真实文件增删刷新、离线准入等既有回归。未新增镜像布尔表达式测试；预览实际换目录和绿勾展示是静态接线核对，未UI/真机验收。git diff --check通过。
- F048功能开发侧核销，累计69项；F046运行性能验收仍未完成。无提交/推送，下一项F049。

### F049 合集预览补图与舞台关闭（2026-10-16）

- 对照PhotoPreview.kt:1796–1885、FileListScreen.BurstStackPhoto:4000，普通合集页允许门控后加载，飞行影子才禁止新增读取。iOS合集接deferredLoadsEnabled与连接状态；BurstPreviewThumbnail保持内存初值，订阅thumbnailUpdates读取缓存，AP/USB门控后缺图调用thumbnailImage(allowRemote:true)，STA仅观察既有顺序管线，不发起独立读取。两个task都在取消后阻止写回。飞行影子未改。
- 合集舞台背景增加全尺寸contentShape点击关闭，叠片原有点击保留；传输/展开按钮仍在背景之上独立处理。此项是功能命中范围修复，不做样式对齐。
- /tmp/ztransfer-f049-thumbnails-20261016.log及xcresult：PhotoThumbnailStoreTests 16/16、0失败、TEST SUCCEEDED、退出0。覆盖cache-only无请求及放行后加载、观察者离开不取消顺序管线、重新订阅初始事件、顺序队列追加不重启、共享请求/失败清理等。生产SwiftUI门控和舞台接线静态核对；未运行实际340ms页面命令计时或触摸验收，不以store测试冒充UI端到端。git diff --check通过。
- F049功能开发侧核销，累计70项；F046性能/实际翻页取消仍待验，无UI测试/真机/提交/推送。下一项F050。

### F050 核销与F051范围拆分（2026-10-16）

- F050与F048共用根因。当前PhotoPreviewView已没有localOriginalURLs、existingTransferDestination或TransferDirectoryIndex.scan引用；构造只保存传入目录和索引，不再为每张照片枚举目的地。列表已有后台索引继续复用，原PhotoPreviewOpeningSnapshot与会话分页状态未改变。F048构建及11/11索引回归是该删除变更的验证依据，本轮未为同一删除重复构建。未测数千文件实际耗时，不报告性能数值；F050功能开发侧核销，累计71项。
- F051几何、缩放、透明度、旋转、弹簧和虚构落点均属纯视觉范围，依用户当前要求延期，不计完成。核对安卓startPreviewQueueFlight:607发现独立功能差异：安卓先enqueue成功再调用onQueueFlightStarted；iOS先占用再失败释放。现调整为入队拒绝直接返回，成功后才发布hold，避免拒绝路径瞬时修改队列展示计数。
- 此顺序调整仅静态对照，git diff --check通过；本轮未运行新构建/测试，不据此前F048测试宣称覆盖此次顺序改动。F051不核销。F052此前已完成；下一项核对F053既有代码与运行证据。无UI/真机/提交/推送。

### F053 既有修复运行核销（2026-10-16）

- 重读安卓NikonCamera.kt:392–417、MonitorStorage.kt及CameraIoGateTest，核对当前CameraIOGate整文件activeDownloads屏障、heartbeat准入前后双检查，CameraRepository.monitorFreeBytes普通IDLE/MONITOR_STORAGE ticket与allowed回检，RemoteViewModel等待/取消期间保留已有值及代次隔离。既有实现符合本项，不重复改代码。
- /tmp/ztransfer-f053-storage-20261016.log及xcresult：24/24、0失败、TEST SUCCEEDED、退出0，包含CameraIOGateTests 19项、MonitorStorageSchedulingTests 2项、RemoteLifecycleTests定向3项。真实repository/session协议夹具验证下载两段之间不插入GetStorageInfo、heartbeat不发命令、下载完才读取；撤销页面许可后不发存储命令，结束后队列/activeDownloads归零。
- gate测试还覆盖IDLE先排队而下载后注册的顺序、选中heartbeat后重检和下载取消恢复；生命周期模型验证等待/取消保留111旧值、录制后准入回检阻止读取、旧代失败不禁用新代。生命周期使用注入相机，不能替代真实机身。
- F053功能开发侧核销，累计72项。git diff --check通过，无UI/真机/提交/推送。此次构建也编译了F051顺序调整，但未执行其页面交互验证。下一项F054运行期CloseSession事务顺序。

### F054 运行期关闭调度第一阶段（2026-10-16）

- 对照安卓NikonCamera.close:5083的beginShutdown→allowDuringShutdown P0 CLOSE_SESSION，新增CameraRepository.retireConnection共享一次detached清理任务。先关闭业务准入，再等待active完整事务后调用底层close；调用方取消不取消清理。CameraIOGate.beginShutdown改幂等，重复通知不再清掉排队中的关闭ticket。
- 已发布AP/STA的WiFiConnectionService关闭闭包及析构兜底均接入repo.retireConnection；握手未发布失败、候选拒绝路径继续直接retireOpenedSession。当前service.disconnect消费closeConnection仍保证本地所有权只取一次。
- /tmp/ztransfer-f054-close-20261016.log及xcresult：20/20、0失败、TEST SUCCEEDED、退出0（19项gate+1项真实repository/PTPSession评级追加读取回放）。命令顺序为评级头→评级追加→唯一CloseSession；重复通知/重复关闭/调用者取消不破坏active事务，新增preview被拒绝，最后session失效。git diff --check通过。
- 新测试调用repository关闭入口并注入真实PTPSession close，尚未直接经过WiFiConnectionService.disconnect，也未真实socket关闭；不能据此标整个F054完成。累计仍72项，下一步补service入口与握手清理回归。无UI/真机/提交/推送。

### F054 service断开入口核销（2026-10-16）

- AP/STA成功发布共用acceptConnection登记关闭所有权；该方法仅在握手成功/代次确认后调用，统一将关闭交给repo.retireConnection。失败/取消/候选拒绝仍由握手attempt直接清理。
- 新增真实WiFiConnectionService.disconnect回放：两段评级读取期间断开，调用方取消、重复disconnect、重复beginShutdown后，仍先完成完整评级事务，再唯一CloseSession并失效session；新业务拒绝。同一回放另直接验证repository入口。测试注入PTPCommandTransport，未使用真实TCP/socket。
- /tmp/ztransfer-f054-service-20261016.log及xcresult：12/12、0失败、TEST SUCCEEDED、退出0（2项关闭入口+10项STAConnectionCoordinator既有回归，含候选拒绝清理/配对取消/恢复会话）。配合前轮20/20 gate回归，F054功能开发侧核销，累计73项。git diff --check通过。
- 未真实机身断开/真实网络socket验收，未UI/提交/推送。N02其他范围不随本项自动核销。下一项F055评级扫描任务所有权。

### F055 评级扫描所有权交错核销（2026-10-16）

- 重读安卓PhotoRatingScan.kt:215–270与iOS startReading/disable/beginFreshGeneration。当前实现已在旧任务收尾清空scanTask前校验revision；disable取消当前句柄，循环每次读取前后检查取消，io.endPhase始终配对执行。该修复此前已随代次逻辑引入，不再重复改业务代码。
- 新增确定性回放：旧读挂起→关闭/重开→新读挂起→释放旧读使其收尾→再次关闭→释放新读；断言仅2次读取（第二张不会继续）、状态为空且不loading、两代各begin/end一次。旧读故意不响应取消，覆盖真正的迟到收尾窗口。
- /tmp/ztransfer-f055-owner-20261016.log为PhotoRatingScanTests 17/17、TEST SUCCEEDED、退出0。随后同一交错接真实CameraIOGate，验证最终ratingPhaseCount=0；/tmp/ztransfer-f055-phase-20261016.log为1/1、TEST SUCCEEDED、退出0。git diff --check通过。测试使用受控IO而非相机传输；前述F054另已验证实际PTPSession多命令事务排空。
- F055功能开发侧核销，累计74项；N05其他范围不随本项自动完成，无UI/真机/提交/推送。后续继续按台账未核销功能项推进。

### F081 队列缩略图状态变化补试（2026-10-16）

- 对照安卓TransferScreen.QueueThumbnail:1230–1245的LaunchedEffect(file.handle,retryNudge)，父队列将snapshot.isTransferring传至QueueItemView再到QueueThumbnail，task以该值重启。失败后image仍nil，下一次开始/结束传输补试；成功已存在图直接返回，不重复读。
- 缩略图子视图以CameraSession对象身份重建，防止同一任务行换相机仍保留旧图；异步加载返回后检查取消再写回。STA保持thumbnailUpdates观察/allowRemote:false，不增加顺序管线外的补读。
- /tmp/ztransfer-f081-retry-20261016.log及xcresult：PhotoThumbnailStoreTests 16/16、0失败、TEST SUCCEEDED、退出0，覆盖缓存复用/共享请求/失败清理/门控放行/STA观察与顺序队列。retryNudge传递与会话identity重建经生产接线静态复核；未运行可见卡DeviceBusy后状态切换的UI端到端，不冒称已有store测试覆盖页面触发。git diff --check通过。
- F081功能接线开发侧核销，累计75项，待运行页面/真机验收。F076/F078仍保留交互待验，纯视觉内容后续集中处理，不因跳过UI测试自动核销。F046性能等待项亦保留；下一项F082。无UI测试/真机/提交/推送。

### F082 快照合并与活跃卡片订阅（2026-10-16，进行中）

- 对照安卓TransferViewModel的StateFlow及TransferScreen活跃卡分支，TransferQueue.snapshots改bufferingNewest(1)，与已有progressSnapshots一致。快照是当前状态，不作为事件日志；慢消费者不会累积过时完整数组。
- TransferQueueView移除progressModel的ObservedObject，QueueProgressScope仅在item.status为transferring时挂载ActiveQueueProgressScope订阅；非活跃卡收到nil并使用自身任务指标。生产卡片的activeProgress身份判定保留。
- 新增两个慢订阅者测试：连续100次真实enqueue后，已读过初始值与从未读取的消费者都直接得到100项；下一次enqueue二者立即得到101项，没有旧快照积压。
- 首轮f082-conflation和第二轮f082-conflation-fixed因新增测试UserDefaults跨actor/XCTUnwrap隔离诊断编译失败，日志保留。改为既有测试直接构造独占实例方式后，/tmp/ztransfer-f082-conflation-isolated-20261016.log及xcresult为TransferQueueScenarioTests 44/44、0失败、TEST SUCCEEDED、退出0。未改生产隔离约束以迎合测试。
- git diff --check通过；实际SwiftUI活跃卡重绘次数/大队列内存峰值未测，当前只证明流缓冲语义及订阅结构静态接线。F082暂不核销，累计75项；无UI测试/真机/提交/推送。

### F083范围与F084计数修复（2026-10-16）

- F083为自动入队视觉事件/合并飞行链路，真实入队功能已有独立测试；按当前只做功能、样式动画后续集中处理的要求延期该视觉链路，不记为修复。
- 对照安卓FileListScreen.queuePillDisplayRemaining:405及QueuePill:2513–2521、QueuePillStateTest，移除heldFlightBaselineRemaining及相关重复计数路径。QueuePillTaskSummary统一displayRemaining：下载存在时actual-held截零，否则直接返回生成数量；allDone只看真实下载/生成是否归零，不受heldCount影响。页面及测试harness均接新接口。
- /tmp/ztransfer-f084-counts-20261016.log及xcresult：1/1、TEST SUCCEEDED、退出0。以真实TransferQueueItem数组验证12项扣2为10、并行完成1项后11扣2为9、释放一份hold为10、过量hold截零但未完成、生成阶段不扣hold、实际完成不延迟。git diff --check通过。F084功能开发侧核销，累计76项；未UI/真机/提交/推送。
- F085当前代码已在completionInput的allDone=false分支取消旧Done任务并清理显示，需继续核对运行证据，不因静态发现自动核销。F082及F046性能待验项保留。

### F085 既有完成提示修复证据核销（2026-10-16）

- 当前QueuePill.completionInput包含allDone与hasCancelled；allDone=false直接取消doneTask并清showDoneLabel/finishProgressVisible，不依赖hasWorkingTask。onAppear将previousAllDone初始化为当前值，不对已有完成列表重播提示；延迟结束前检查Task取消。该修复此前F080过程中已接入，本轮不重复改代码。
- 本轮重新读取真实保存日志 /tmp/ztransfer-f080-done-fill-r2.log：testTopQueuePillCompletionStillShowsDoneAndNewBatchClearsIt及取消状态用例共2/2、TEST SUCCEEDED。其生产QueueTopPillPresentationHarness由phase3完成→phase0共9个WAITING、isTransferring=false、无isGeneratingFrame，证明并非靠hasWorkingTask=true清理旧Done。日志在Done确认/截图后立即点击Next，并检查9与非Done；这是此前已获授权运行的UI证据，本轮未重跑UI。
- 该历史测试未精确控制完成后100ms，也未单独确定性交错旧计时回调；当前取消检查与同份completionInput经静态复核。F084只改变真实任务计数判定，heldCount=0的此路径未变。F085核心缺口已有实现及真实页面证据，功能开发侧核销，累计77项；不扩展成所有时序/真机均通过。
- 无新构建/安装/提交/推送；F046/F082性能待验、F076/F078其余交互待验仍保留。下一项F086本地批次失败诊断。

### F086 失败诊断数据链第一阶段（2026-10-16）

- 对照安卓LocalPhotoBatchViewModel的LocalPhotoFailure、最多8层cause/末2层摘要/最多5条保留，新增本地失败值及stage错误封装。runner从丢弃异常bool改为返回保存结果+失败信息；保留原选择序号、prepare/render/save阶段、memory/permission/space/missing/unknown类型，详情每层信息200字、域名80字有界，最多5条。不吞CancellationError，真实生成入口标注阶段，授权拒绝记save/permission。
- 错误类型用iOS Cocoa/POSIX等价分类，不能提供Android异常类名；摘要使用真实domain/code，明确是平台诊断。统计随progress进入state，returnToReady保留，新选择/新批次清空。当前详情UI/复制尚未接入。
- /tmp/ztransfer-f086-details-20261016.log为11项1失败，旧测试全值断言假定failures为空；新增详情/分类测试通过。旧测试改明确验证原有12/12/8计数及4条失败后，/tmp/ztransfer-f086-details-fixed-20261016.log及xcresult为11/11、0失败、TEST SUCCEEDED、退出0。覆盖两并发/失败继续/取消既有回归，新增序号、5条上限、有界摘要、5类错误、READY保留和新批次清理。git diff --check通过。
- F086进行中不核销，累计77项；下一步接入可见详情及复制，补真实ViewModel授权失败和状态展示验证。无UI测试/真机/提交/推送。


### F086 详情呈现与真实ViewModel验证（2026-10-16）

- 基础失败详情区按有失败记录显示，返回READY仍保留；总数取实际失败数与保留记录数最大值。逐条使用安卓既有三语序号/阶段/原因文案及诊断摘要，启用系统文本选择供复制，不新增按钮。
- 实际LocalPhotoBatchViewModel注入拒绝保存权限，6张均失败且保留5条；等待真实2.4秒终态返回READY后仍保留，重新选择清空。测试同时逐字验证英文、简体和繁体格式。最终 `/tmp/ztransfer-f086-presentation-20261016.log`及同名xcresult为12/12、0失败、TEST SUCCEEDED（11项批次回归及1项ViewModel测试）。
- F086开发侧核销，累计78项。文本选择/复制仅静态接线检查，未运行UI测试；真实Photos写入失败和外部Provider错误未真机验证，不把注入测试当作设备验收。无提交/推送。样式仅基础可用，动画和播放表现继续留待后续集中处理。


### F087 本地效果放大入口（2026-10-16，进行中）

- 对照LocalPhotoPreviewPager、SettingsScreen.PhotoEffectsRenderedPreview的onOpen及PhotoPreview.SinglePhotoPreviewOverlay：只允许已有渲染图打开，清除水印输入焦点，记录当前预览全局锚点；复用PhotoEffectsExpandedPreview已有缩放/旋转/轻点关闭，不另造页面。
- 共用大图增加长按对比；打开时冻结成片与已有对比图，同一UIImage身份的晚到对比图可更新；底层换图时仍保留原对比图。关闭释放快照，TabView选择不变。无滤镜时对比为空仍可打开。只补功能，未调整视觉参数。
- 安卓PreviewGestureGeometryTest涉及捏合焦点与平移边界；当前共用大图沿用既有缩放手势，尚未证明全部手势一致。首轮 `/tmp/ztransfer-f087-build-20261016.log` 编译退出0；最终快照保留变更另跑build-for-testing，结果续记。未运行UI测试，轻点与长按/滑动冲突、弹层期间底层异步任务是否持续及键盘实际收起仍待验证。F087不核销，累计仍78项。

- F087最终 `/tmp/ztransfer-f087-build-final-20261016.log` 为 **TEST BUILD SUCCEEDED**、退出0；仅编译测试目标，没有执行测试。git diff --check通过。上述运行期限制保留，不核销。


### F088 LUT角色隔离第一阶段（2026-10-16，进行中）

- 对照安卓PhotoLutStore.restore/save(role)及LocalPhotoEffectsOverlay的local角色持久化：PhotoLUTStore新增camera/local角色，仅选择和强度键按角色分开，目录/收藏/快照目录继续共享。camera沿用旧键保留已有配置；local不从来源无法区分的旧共享选择自动复制配方。
- SettingsView持有camera Store，LocalPhotoEffectsView持有local Store，公共PhotoEffectsControls改由宿主注入。工作台两个现有LUT入口现在使用同一个local实例，避免同一角色内重复实例状态不同步；重复入口本身仍归F089，未删除。
- 新增PhotoLUTStoreTests生产Store重建测试：旧camera配置不进入local，两角色A/B选择与强度分别恢复，清local不清camera，共享目录/收藏仍可恢复。专项运行日志 `/tmp/ztransfer-f088-roles-20261016.log`，结果续记。
- F088尚未核销：当前仍把来源路径作为选中身份，完整digest/name/URI快照恢复归F100，微调归F101；现存多个Store共享收藏的实时一致性也需继续检查。未把配置键隔离等同完整配方重启可用。累计78项不变；F087手势/弹层生命周期疑点保留。

- F088本阶段最终专项3/3、0失败、TEST SUCCEEDED、退出0；未运行UI测试或实际杀进程重启，重建Store验证不等同整条LUT恢复链通过。git diff --check通过。


### F088 共享目录与收藏的活跃实例一致性（2026-10-16）

- 安卓PhotoLutStore.toggleFavorite每次从共享preferences读取再修改。iOS之前从各Store初始化快照修改，camera先收藏A、local再收藏B会把A覆盖。现在写前重读共享键，写完由MainActor内同步信号通知活跃Store各自重读；仅更新目录/收藏，不触碰角色配方。订阅弱引用，避免共享信号持有页面Store。
- 新增真实Store交错测试：两个不同UserDefaults实例共用suite，A/B收藏添加与删除即时互见、顺序保留、目录设置/清除即时互见、camera/local选择仍独立、另一suite不串数据，最后新建Store验证持久化。日志 `/tmp/ztransfer-f088-shared-20261016.log`，结果续记。
- 目录访问服务自身仍使用监看目录键的F099、F100完整配方恢复及F101微调未修。共享Store字段同步不等于扫描/授权链完成。F088仍不核销，累计78项。

- 最终F088共享状态专项4/4、0失败、TEST SUCCEEDED、退出0。没有执行UI测试；未验证外部进程改偏好，应用内Store写入同步已由生产实例验证。


### F098 Cube提交保留第一阶段（2026-10-16）

- 对照安卓TransferViewModel.setPhotoFilterConfiguration：NP3有效ID与独立lut配方分别处理；LocalPhotoEffectsOverlay选中lut优先并按LUT模块控制。iOS normalized现在识别已加载的Cube表，保留选择原名及归一化强度，不将其送入NP3目录解析；缺表仍拒绝，避免把无法渲染的选择当作成功。
- PhotoEffectsSettings.colorEffectModule集中决定当前颜色效果所属模块，normalized与effectivePhotoEffectsSettings均使用；只有LUT模块时Cube不会被普通FILTER模块误关，关闭LUT模块仍禁用。公共编辑器使用chooser提供的原名构造选择，停止selectFilter生成摘要名。
- 新增生产PhotoEffectsStore双scope测试：updateFromEditor→effective→update保留Cube名称/强度/启用，LUT-only生效、FILTER-only禁用、缺表拒绝，连同角色/共享配置回归运行 `/tmp/ztransfer-f098-commit-20261016.log`，结果续记。
- F098仍进行中：本轮没有文件选择器→实际像素输出及完整重启恢复验证，F100身份/私有快照恢复仍未补。F088/F098不核销，累计78项。相关模块完整互斥仍归F093/F095，不能据此认定全部完成。

- F098本阶段最终5/5、0失败、TEST SUCCEEDED；未运行UI测试，不能作为文件选择/像素输出/重启恢复验收。


### F098 提交后真实像素验证（2026-10-16）

- 在双scope生产提交测试中补实际PhotoEffectsRenderer.render：2×2白图、真实解析的全黑Cube、64%强度，预期RGBA为92/92/92/255；禁用LUT模块后白图保持255/255/255/255；随后再次渲染此前捕获的effective配方仍为92，验证后续编辑未修改已取出的配置值。
- 本轮只运行这项新增像素断言，日志 `/tmp/ztransfer-f098-pixels-20261016.log`，结果续记。没有用UI截图代替像素验证；本测试不包含Photos保存、文件选择器或进程重启。F100完整快照恢复仍须继续补齐。

- F098像素专项最终1/1、0失败、TEST SUCCEEDED，两个scope均通过成片/禁用/旧配方断言。日志包含IOSurface通知警告，不影响测试结果。完整文件选择与F100重启恢复仍未覆盖，累计78项不变。


### F089 唯一LUT入口与F095活动选择显隐（2026-10-16）

- 对照安卓LocalPhotoEffectsOverlay的两处PhotoColorEffectGroup条件：删除工作台共用控件之外的无条件PhotoLUTChooser。静态全仓UI引用现仅PhotoEffectsEditorView一处；两个宿主仍分别注入各自角色Store。
- PhotoColorEffectEditorVisibility集中控制模块可见与活动配方互斥。仅开启的Cube挡普通滤镜，仅开启且在NP3目录中的选择挡LUT；未启用的记忆项不挡另一类。公共编辑器两入口实际使用该规则，无独立旁路。
- 新增生产规则矩阵：免费/付费×15种非零模块掩码×NP3/Cube×关闭/启用/调用selectFilter(nil)关闭；专项连同既有Cube提交像素/角色/共享状态运行 `/tmp/ztransfer-f089-visibility-20261016.log`，结果续记。
- F095尚未整体核销：LUTChooser缺关闭入口仍归F103，需要后续补实际关闭/重开链。本轮不做UI手势测试，不将显隐矩阵扩展为完整页面验收。

- F089专项最终6/6、0失败、TEST SUCCEEDED、退出0；静态检查UI仅余一处PhotoLUTChooser并受生产规则控制。F089开发侧核销，累计79项；F095实际关闭入口及F088/F098/F100完整恢复仍未核销。git diff --check通过。


### F090 本阶段功能部分（2026-10-16）

- 对照LocalPhotoBatchButton及LocalPhotoEffectsOverlay.onGenerate，生成前清watermarkTextFocused；就绪已选图主文案改用local_photo_generate，生成计数分隔改为“ / ”。复查安卓三语XML发现既有翻译表的generate/reselect是旧值，已逐字更新为生成/Generate/產生及含%1$d数量的重选提示。
- 顶栏现有重选操作增加含真实照片数量的无障碍标签，保留生成中禁用和空选择隐藏；位置/50方形外观/页码布局/动画均按用户范围暂缓，不标为复刻完成。
- 本次简单入口/文案改动仅编译验证 `/tmp/ztransfer-f090-functional-20261016.log`，未新增镜像实现测试、未运行UI测试；实际键盘收起和VoiceOver朗读未验。F090暂不核销，累计79项。


- F090最终编译日志为TEST BUILD SUCCEEDED、退出0；仅编译，没有执行UI测试，上述运行期限制保留。

### F091 模块点击规则（2026-10-16）

- 完整对照Android PhotoEffectModules.kt与PhotoEffectModulesTest。新增生产togglePhotoEffectModule：先求effective掩码，免费FRAME/WATERMARK异或12，其他异或单个位，结果0则返回原effective值。
- 公共PhotoEffectsControls.toggleModule接入该规则；next等于current时直接返回，不写草稿、不新增触感。原代码将最后一位关掉后normalize成15及免费框/水印无法成对关闭的问题已消除。
- 新增全部15掩码×4模块的Pro/免费穷举，并覆盖12最后组合、13去水印为1、1开边框为13、最后FILTER保持及非法0恢复后点击。连同LUT提交像素/隔离/显隐回归日志 `/tmp/ztransfer-f091-toggle-20261016.log`，结果续记。未运行UI测试。

- F091最终专项7/7、0失败、TEST SUCCEEDED、退出0（1项穷举与6项LUT回归）；开发侧核销，累计80项。F090实际键盘/无障碍运行未验，F092分区、F094隐藏清启用仍待修，未扩大核销范围。


### F092 边框与水印独立控件（2026-10-16）

- 完整对照SettingsScreen.PhotoFrameWatermarkEditor的showFrame/showWatermark分组及选择收藏时showWatermark条件。公共编辑器提取frameControls/watermarkControls，按两个effective位分别构造；都隐藏时不构造外卡，删除整卡依FRAME禁用/变淡。
- frameEnabled/watermarkEnabled同时考虑对应模块可见性，水印单独显示时不误以隐藏的边框旧开关作为当前边框状态；既有onChange会关闭隐藏模块的展开内容。选择框收藏仅在水印区可见时应用其水印配方，与安卓一致。
- 构建日志 `/tmp/ztransfer-f092-sections-20261016.log`，结果续记。未运行UI测试；真实水印单独编辑/导出链仍需专项补证，F094显式隐藏清持久化开关独立未修，不因条件构造就标记完成。累计80项不变。

- F092最终编译TEST BUILD SUCCEEDED、退出0；随后仅整理提取区块缩进，git diff --check通过。未执行UI或输出测试，暂不核销。


### F092 水印独立输出专项（2026-10-16）

- 新增真实PhotoEffectsStore cameraTransfer/localPhotos双scope：仅WATERMARK模块、故意带旧border=true、启用文字水印，updateFromEditor后effective应保水印而关边框。实际PhotoEffectsRenderer输出尺寸等于512×384原图，PNG内容不同于无水印输出。
- 更改文字再次提交并重建Store，检查文字/启用/无边框恢复；实际新图与旧图内容不同且尺寸仍不变。该验证不依赖截图，不覆盖Photos写入或实际页面点击。专项日志 `/tmp/ztransfer-f092-output-20261016.log`，结果续记。

- F092最终专项1/1、0失败、TEST SUCCEEDED、退出0，两个scope的配置编辑/重建与实际输出均通过。结合生产控件条件接线及编译证据，F092开发侧核销，累计81项。未验证实际页面点击、VoiceOver或Photos保存；F094隐藏后清启用仍独立未修。


### F093 FILTER/LUT四种掩码完整门控验证（2026-10-16）

- 当前生产门控已在F098修复：PhotoEffectsSettings.colorEffectModule区分Cube与NP3，effectivePhotoEffectsSettings及PhotoEffectsStore.normalized均按所属位判断；本轮未重复改生产实现。
- 对照安卓LocalPhotoEffectsOverlay.applyModuleVisibility及TransferViewModel独立NP3/lut配置，新增双scope×NP3/真实解析Cube×FILTER/LUT四种组合。用FRAME位避免“全零归一化为全开”影响双隐藏场景，装饰总开关始终关闭。
- 免费/Pro预览effective与真实PhotoEffectsRenderer输出均对比同配方独立启用/禁用基准；updateFromEditor后的启用状态、选择参数及实际输出再次验证。日志 `/tmp/ztransfer-f093-matrix-20261016.log`，结果续记。测试不宣称覆盖文件选择器或F100快照重启恢复。

- F093矩阵专项最终1/1、0失败、TEST SUCCEEDED、退出0。生产门控及两类效果四掩码的预览/提交/渲染证据完整，开发侧核销，累计82项。未运行UI测试，F094显式隐藏清草稿、F098/F100完整选择与恢复仍独立未完成。


### F094 显式隐藏清启用第一阶段（2026-10-16）

- 对照SettingsScreen.applyModuleVisibility，新增PhotoEffectsSettings.applyModuleVisibility：隐藏相应颜色效果/边框/水印时关闭启用，装饰总开关随有效子效果关闭；参数与素材字段不清。生产模块按钮接该方法，隐藏LUT时同步清角色Store选中项，防本地旧onAppear路径重新启用。
- persistingEditorPreferences同步清当前正式配置的隐藏项，覆盖相机草稿尚未完整提交的窗口；normalized共用该规则，并从result.watermark继续归一化，修复此前用value.watermark覆盖刚清掉的enabled。权限降级的effective渲染策略未改，显式隐藏与仅降级保持区别。
- 新增双scope×免费/Pro：先保存付费参数，显式只保LUT模块→即时偏好保存→重新显示全部→完整提交→重建Store，检查NP3/框/水印均保持关闭，文字/框预设/NP3身份保留。连同免费收藏偏好保留、水印独立输出与LUT回归日志 `/tmp/ztransfer-f094-hide-20261016.log`，结果续记。
- 仍须补Cube角色清理与实际入口交接证据，未执行UI测试，不先核销，累计82项。

- F094本阶段最终10/10、0失败、TEST SUCCEEDED、退出0。显式隐藏后NP3/框/水印不复活、参数保留以及既有权益/像素回归通过；Cube角色关闭与草稿真实入口交接仍待补证，暂不核销。


### F094 Cube角色与生产模块命令验证（2026-10-16）

- 将公共编辑器原有模块点击状态变更提取为togglePhotoEffectModuleDraft，实际按钮唯一调用此同步命令：计算下一掩码、拒绝最后模块关闭、更新草稿并清对应LUT角色选择。无变化时不写草稿或角色存储。
- 新增camera/local两角色实际Store测试：仅LUT时点击关闭无变化；打开FILTER后隐藏LUT，同时关闭草稿效果/清本角色持久选择；另一角色配方不变，强度和草稿参数保留。重新显示LUT不启用，再经PhotoEffectsStore完整提交/重建仍关闭。此为生产命令测试，不是UI点击模拟。
- 连同LUT矩阵/像素/共享配置及原显式隐藏恢复测试运行 `/tmp/ztransfer-f094-command-20261016.log`，结果续记。F100正常启用Cube的完整重启恢复独立未修，不据此声称已完成。

- F094命令专项最终9/9、0失败、TEST SUCCEEDED、退出0。结合前轮10/10，覆盖模块规则、生产命令、NP3/框/水印/Cube关闭、两角色持久化与重新显示/重建、权益保留，F094开发侧核销，累计83项。未运行UI测试；F100正常Cube恢复仍未修。


### F095 LUT关闭与两类编辑器恢复入口（2026-10-16）

- 对照PhotoLutEditorState.off清selection/selectedUri以及PhotoLutEditor的lut_off，唯一公共PhotoLUTChooser增加“关闭/Off/關閉”操作，回调调用生产disablePhotoLUTDraft，同步清Cube草稿和本角色选择；不清强度、其他角色或记忆中的NP3配方。当前没有异步加载任务，F102引入加载时仍须将取消纳入off。
- LUT标题按实际enabled显示LUT/关闭，避免已停用的Cube记忆显示为开启。F089阶段已接PhotoColorEffectEditorVisibility，停用记忆不再阻挡另一类。
- 新增双角色生产命令测试：启用Cube→关闭→两类入口恢复→选NP3→关闭NP3→LUT入口恢复；重建本角色无选中，另一角色未改、强度保留、重复关闭LUT不清NP3记忆。日志 `/tmp/ztransfer-f095-off-20261016.log`，结果续记。
- F103仅关闭入口在本轮补齐，分类/扫描/错误/文案其余问题仍未修；F100正常选中恢复仍未修，不能据关闭路径扩大核销。未运行UI测试。

- F095最终专项9/9、0失败、TEST SUCCEEDED、退出0；结合前轮显隐矩阵和唯一入口接线，F095开发侧核销，累计84项。F103仅关闭入口补齐，其他分类/扫描/错误/翻译工作仍未完成；F100完整正常恢复仍独立未修。


### F096 收藏完整参数与格式第一阶段（2026-10-16）

- 完整读取安卓PhotoEffectFavorites与compactWidth/backdrop/legacy测试。PhotoFrameFavorite增加frameWidthPercent/backgroundBlurPercent/backgroundMaskPercent，构造时按安卓归一化；自定义Codable解码缺字段默认100，兼容旧iOS JSON。
- Android格式解码支持9/10/12字段：旧9字段三参数100、10字段宽度、12字段附加背景参数，数字无效拒绝。按安卓先登记preset去重；编码默认背景输出10字段，非默认背景输出12字段，宽度/背景写前归一化。旧9字段输出断言同步改为安卓当前10字段格式。
- 新增真实PhotoEffectsStore偏好迁移/重建，覆盖宽60/200、背景0/200及140/0/180，验证精确编码和旧JSON默认值；并跑既有水印范围归一化/当前内容保护。日志 `/tmp/ztransfer-f096-codec-20261016.log`，结果续记。
- 当前仅模型/编解码，编辑器收藏捕获/修改/应用尚未传入新字段，不能标完整恢复完成。F096进行中，累计84项。

- 首轮f096-codec测试构建失败：新增DomainModelTests方法未标@MainActor，无法同步读取PhotoEffectsStore；生产文件无编译错误。已仅为新增方法补隔离标注，重跑日志 `/tmp/ztransfer-f096-codec-fixed-20261016.log`，首轮失败保留。

- F096格式阶段最终3/3、0失败、TEST SUCCEEDED、退出0；git diff --check通过。收藏捕获/应用入口尚未接新参数，保持进行中，累计84项。


### F096 收藏捕获/修改/应用接线（2026-10-16）

- 对照安卓SettingsScreen.onPresetChanged及FavoriteFrameWatermarkEffect.capture：PhotoFrameFavorite新增metadata捕获、updateFrameMetadata和metadata应用方法，只处理宽度/模糊/遮罩，不覆盖日期格式等无关元数据。
- 公共编辑器toggleFrameFavorite传入activeMetadata；updateMetadata同步更新该模板已有收藏的三参数；选择模板时应用收藏三参数并写回metadataByPreset。水印沿用当前文字/图片的既有applying方法和隐藏区门控。
- 新增双scope实际Store：60/0/200捕获→200/180/0修改→保存重建→应用，验证三参数恢复，当前日期显示/格式、当前文字和图片hash保留。与格式兼容、旧水印范围、缺素材保护及免费收藏偏好回归运行 `/tmp/ztransfer-f096-apply-20261016.log`，结果续记。未运行UI测试。

- F096最终应用阶段5/5、0失败、TEST SUCCEEDED、退出0，结合前轮格式3/3与生产入口接线，开发侧核销，累计85项。首轮缺MainActor的失败记录保留；未运行UI测试或实际触屏收藏操作。git diff --check通过。


### F097当前范围与F099目录作用域（2026-10-16）

- F097菜单精细外观、锚点和动画按用户当前范围暂缓，现有基础模块入口仍可用；不把未实现的弹层交互/触感标为完成，本项不核销。F098正常选择与F100恢复仍有依赖，继续处理独立F099。
- 对照安卓PhotoLutStore的photo_lut偏好与LutPreferences按所属偏好实例保存目录。RemoteLUTFolderAccess新增monitor/photo作用域，默认monitor保留现有监看消费者；照片唯一选择器显式photo，扫描/读取/恢复均经同一scope键。
- 选择器不再重新生成URL书签，而是将access.bookmarkData发布到PhotoLUTStore共享字段。照片原有photo_lut_folder_bookmark现在真正参与访问服务恢复，监看remote_lut_folder_bookmark不被修改。
- 新增真实临时目录书签保存/解析/新实例恢复测试，覆盖A/B隔离、PhotoLUTStore读取同一书签、主动共用同一目录、移除照片书签不影响监看。日志 `/tmp/ztransfer-f099-folder-20261016.log`，结果续记。此轮不模拟实际Provider撤权或扫描失败，F102/F168成功前提交目录等生命周期缺口仍未修。

- F099最终1/1、0失败、TEST SUCCEEDED、退出0，真实书签保存/恢复/清除隔离通过；生产扫描与读取均使用对应scope.resolve，开发侧核销，累计86项。未运行UI测试或外部Provider撤权验收，F102/F168仍未完成。git diff --check通过。


### F100 角色配方身份与快照恢复第一阶段（2026-10-16）

- 对照安卓PhotoLutStore.restore/save(role)，新增selectLUT：先成功saveSnapshot，再以角色独立字典保存digest/name/source/intensity。selectedIdentifier仍是来源路径供选择器匹配，不再承担内容摘要身份；restoreSelection从配方digest实际读取私有快照后返回原名和强度。
- setIntensity同步当前角色配方，select(nil)或切换来源清旧配方；正常旧路径记录无digest/原名，不能凭空迁移为有效Cube。现存快照格式/缓存目录及读取资源界限尚归后续条目，未在本阶段宣称解决。
- 新增真实文件测试：两角色相同快照不同名称/强度→删除原Cube→重建Store恢复→关闭camera不影响local→删除快照即使runtime仍有表也返回nil。连同已有LUT回归运行 `/tmp/ztransfer-f100-recipe-20261016.log`，结果续记。
- 本阶段新增API尚未接选择器和两宿主启动恢复，不能核销F100或F098。后续须统一实际选择/关闭/普通滤镜切换及恢复接线，避免已关闭配方被旧onAppear恢复。累计86项。

- F100存储阶段最终11/11、0失败、TEST SUCCEEDED、退出0；实际源文件删除/快照恢复及关闭角色隔离通过，宿主接线尚未完成，继续不核销。git diff --check通过。


### F100 选择器与两宿主启动接线（2026-10-16）

- PhotoLUTChooser.choose使用selectLUT，只有私有快照成功才发布实际选择回调，保留原name与内容digest。移除LocalPhotoEffectsView旧的selectedIdentifier必须以cube:开头且拼摘要名的onAppear恢复。
- PhotoEffectsStore两scope初始化结束时从对应角色恢复配方，LUT模块可见才启用；生产使用原始defaults作为共享照片LUT偏好域，本地效果自身suite保持独立。支持注入role Store验证临时快照目录。恢复在配置建立时完成，供后续相机/本地生成使用，而非依赖先打开某个编辑器。
- 公共编辑器监听selectedFilter覆盖普通轮盘和类别选择器，切到NP3时清角色Cube配方。关闭及隐藏LUT沿用生产命令清配方，不再被旧页面onAppear重新启用。
- 新增两宿主真实Store启动恢复原名/64强度→实际渲染与不启用滤镜输出不同→关闭提交→新Store保持关闭；使用不可访问的源路径，仅私有快照提供表。连同全部LUT回归 `/tmp/ztransfer-f100-hosts-20261016.log`，结果续记。
- 此处仍沿用同步快照读写和现有缓存目录，后台加载/资源限额等归F102/F105/F106，未宣称完整性能或实际杀进程验收。未运行UI测试。

- F100宿主阶段最终12/12、0失败、TEST SUCCEEDED、退出0；结合前轮真实源删除/快照读取11/11、F098提交/像素与生产选择器接线，F098/F100开发侧核销，累计88项。证据为Store重建与实际渲染，不是实际杀进程、UI点击或Photos保存验收；F088完整微调、F101–F106其他缺口仍未完成。git diff --check通过。


### F101 微调模型与颜色后处理第一阶段（2026-10-16）

- 对照PhotoFilterPreset.LutAdjustments、LutColorPipeline及其测试，新增四项-100…100微调值，PhotoFilterSelection存储lutAdjustments并兼容旧JSON缺字段为中性；构造/恢复归一化，Cube配置normalized保留微调。
- 新增LUTColorPipeline按安卓sRGB字节域执行：阴影符号反向、smoothStep权重、0.28色调偏移，随后0.75对比度系数和饱和度，最后+0.5取整；中性与全透明保持原值。当前尚未接PhotoCubeLUTMapper，不能声称已影响实际成片。
- 新增安卓对应的中性/灰色/透明/极值语义、红色降饱和精确灰值及旧JSON/越界归一化测试，连同Cube解析回归 `/tmp/ztransfer-f101-model-20261016.log`，结果续记。
- F101进行中：实际渲染顺序/Alpha、每digest记忆、角色配方微调、控件及输出身份仍待补。累计88项不变。

- F101模型阶段最终8/8、0失败、TEST SUCCEEDED、退出0；生产mapper/Store/UI/输出身份尚未接线，不核销。git diff --check通过。


### F101 实际渲染与Alpha接线（2026-10-16）

- 对照Android PhotoFilterRenderer.filterPixel先cubeMapper.map再LutColorPipeline.apply，生产PhotoEffectsRenderer将selection.lutAdjustments传入PhotoCubeLUTMapper；普通/分块/预览既有共用applyFilter入口因此使用同一后处理。
- CGContext明确RGBA字节序。因CoreGraphics输入为预乘Alpha，先恢复straight颜色做LUT/强度混合并量化成字节，再做微调，最后按原Alpha预乘输出；全透明跳过，Alpha不改。避免半透明颜色按错误暗色参与映射。
- 新增实际PhotoEffectsRenderer三像素输入：红色全不透明、半透明和全透明；50%黑Cube后降饱和，精确期望RGBA27/27/27/255、14/14/14/128及全0。并跑既有中性/颜色/解析及提交像素回归，日志 `/tmp/ztransfer-f101-render-20261016.log`，结果续记。
- F101仍未完成：每digest和角色微调持久化、控件、输出身份/重试快照仍需接线。未UI测试，累计88项。

- F101渲染阶段最终10/10、0失败、TEST SUCCEEDED、退出0，真实RGBA顺序/Alpha及中性旧配方通过。每digest/角色记忆、UI、输出身份仍未补，继续不核销；git diff --check通过。

### F101 摘要记忆与基础编辑控件（2026-10-16）

- 对照安卓 PhotoLutStore.kt 与 PhotoLutEditor.kt：强度按内容摘要保存，缺失时从来源强度迁移；同内容换路径仍使用摘要记忆。相机、本地的当前配方保留独立强度和四项微调，共享记忆的更新不覆盖另一个角色正在使用的配方。
- 持久化专项 /tmp/ztransfer-f101-memory-20261016.log 最终13/13、0失败、TEST SUCCEEDED，覆盖来源迁移、同摘要换路径、角色隔离和重建。
- 基础控件增加对比度、饱和度、高光、阴影（-100…100，步长5），强度2…100、步长2；选择回调传递完整 PhotoFilterSelection，避免重建时丢失微调。只做可用界面，不复刻样式和动画。
- 控件接线正在运行模型/渲染回归；未运行UI测试。输出身份、重试快照和旧角色配方缺少微调字段的初始化回退仍需继续核对；F101不核销，累计88项不变。

- 接线回归最终 /tmp/ztransfer-f101-controls-20261016.log：22/22、0失败、TEST SUCCEEDED、退出0。包括13项Store和9项Cube模型/真实像素测试；验证编译和领域行为，不代表实际控件交互已测试。

### F101 输出身份补齐（2026-10-16）

- 安卓 PhotoFrameExporter.kt 的 PHOTO_FILTER_RENDER_VERSION 已为3，滤镜摘要包含强度和四项微调；iOS原来仍用v2且只含preset.id，会让不同微调配置落到相同导出名称。现逐字段对齐安卓v3，包含NUL分隔和SHA-256前4字节。
- 更新旧版NP3文件名断言，新增四项微调分别改变输出身份、值快照不反向变更、JSON恢复后保持参数和文件名的专项验证。
- 验证运行中；这只验证输出命名与配方序列化，不代替真实队列失败重试测试。F101继续未完成，累计88项不变。

- 输出身份专项最终 /tmp/ztransfer-f101-identity-20261016.log：15/15、0失败、TEST SUCCEEDED、退出0；未运行UI测试。git diff --check通过。

### F101 旧角色配方恢复一致性（2026-10-16）

- 对照安卓 PhotoLutStore.restore：角色强度缺失时回退摘要强度，再回退80；角色微调以contrast字段存在为已保存标记，否则回退摘要微调。iOS初始化控件与恢复渲染选择现共用解析方法，修复旧配方控件显示中性而实际渲染非中性的问题。
- 新测试构造缺少强度/微调字段的旧角色配方和冲突的旧全局强度，验证控件与恢复选择一致；另验证显式零微调和角色强度优先于摘要记忆。
- 专项验证运行中，未运行UI测试；真实队列重试仍待补证，F101不核销，累计88项不变。

- 最终 /tmp/ztransfer-f101-legacy-20261016.log：15/15、0失败、TEST SUCCEEDED、退出0。git diff --check通过。

### F101 实际队列微调快照重试（2026-10-16）

- 对照安卓retrySingleTask/newAttempt及iOS TransferQueue.retry：生成失败重试应继承原任务effects，不读取当前编辑器。
- 新增真实TransferQueue专项：真实JPEG和Cube私有快照入队，首次renderer边界注入写失败；随后修改Store和草稿的强度/微调，再离线重试。断言两次执行参数都等于入队值，重试实际渲染JPEG等于锁定配方且不同于新编辑配方。
- 这次只在首次失败边界注入故障，重试使用生产PhotoEffectsRenderer；不把它描述成真实磁盘故障或完整发布器验证。运行中，未UI测试；F101保留进行中，累计88项不变。

- 首轮 /tmp/ztransfer-f101-retry-20261016.log 的新测试等待超时：夹具声明原片10字节但实际为JPEG，未进入预期生成路径。改为真实文件字节数后 /tmp/ztransfer-f101-retry-fixed-20261016.log 最终2/2、0失败、TEST SUCCEEDED、退出0。原片离线重试、锁定微调和实际JPEG输出一致性通过；保留首轮失败记录。
- 后续收尾仍需核对基础Slider实时写入与安卓ReleaseCommitWheel松手提交的功能时机差异；不将控件可编译等同完整交互逻辑一致。F101保持进行中，累计88项不变。

### F101 基础控件提交与取消（2026-10-16）

- 对照ReleaseCommitWheel.kt正常结束提交、取消恢复规则，移除SwiftUI Slider绑定直接写Store的行为。使用基础UISlider桥接，valueChanged仅更新本地显示，endTracking提交变化值一次，cancelTracking恢复保存值且不写偏好。
- 浓度和四项微调复用同一控件，分别保持2…100/2与-100…100/5；辅助功能增减按一档提交，切换来源重建控件以清理本地预览。不增加精细样式/动画。
- /tmp/ztransfer-f101-release-20261016.log 为TEST BUILD SUCCEEDED、退出0；git diff --check通过。此次只编译，未运行UI测试或实际拖动/父滚动取消，因此不能把编译当作手势验证。F101保持进行中，累计88项不变。

### F101 输入边界验证与开发侧核销（2026-10-16）

- 发现控件提交后等待SwiftUI刷新才能更新savedValue，连续辅助功能增减可能重复基于旧值。现提交前同步更新已保存值和控件值；重复endTracking不重复提交。
- 直接调用生产UISlider子类的valueChanged/endTracking/cancelTracking和辅助功能输入，验证拖动只预览、取消不提交、取整、结束一次提交、连续增减和上下边界。不是XCUITest或真实触摸分发测试。
- /tmp/ztransfer-f101-input-20261016.log：16/16、0失败、TEST SUCCEEDED、退出0。此前模型8/8、实际RGBA渲染10/10、记忆13/13、接线22/22、输出身份15/15、旧配方15/15及实际队列重试2/2证据共同覆盖F101功能验收；各轮包含重叠测试，不相加虚报数量。
- F101开发侧核销，累计89项；UI测试按用户范围跳过，真实手势/真机体验未验收。F102加载生命周期、F104–F106其他资源问题独立未关闭，F088整项仍待独立收尾复核。下一项继续F102。

### F102 有界文件读取第一阶段（2026-10-16）

- 对照LutFolderRepository.read和CubeLutParser流读取：读取前查询当前大小，超32MiB拒绝；不能只信扫描元数据或整份Data读取后才检查。
- RemoteLUTFolderAccess.read已接分块FileHandle读取，每次最多64KiB，剩余预算最多多读1字节用于判断溢出；块前后检查取消，所有退出路径关闭句柄。取消保留CancellationError，不转成普通读取错误。
- 新增真实临时文件专项：多块读取内容一致、块间取消、32MiB+1稀疏文件拒绝。尚未验证未知元数据、读取中增长、阻塞的Provider；FileHandle单次阻塞读取尚不能由当前检查打断。
- F102仍未完成：目录总条目上限、异步单活跃/最新等待、10秒截止、代次、加载态、目录事务和错误文案均待补；累计89项不变。

- 第一阶段专项 /tmp/ztransfer-f102-read-20261016.log 最终1/1、0失败、TEST SUCCEEDED、退出0；git diff --check通过。未UI/云Provider验证，F102不核销。

### F102 增量目录枚举与总条目预算（2026-10-16）

- 对照LutFolderRepository.scan：total在过滤扩展名/目录前递增，根与一层分类共用10000预算。iOS移除contentsOfDirectory全量数组和最终仅LUT计数，改用浅层DirectoryEnumerator逐条检查预算/取消；隐藏项同样计数，不递归第二层。
- 枚举错误或元数据读取失败抛read，不返回局部结果；成功后才形成排序列表。此保证是扫描函数边界，现有UI失败清空列表仍需后续修复，不能声称整条目录事务完成。
- 新测试用6条含普通/隐藏/目录的真实目录：6成功、5失败；两层之外LUT不收集；取消和不存在目录失败。生产默认10000，测试注入小预算覆盖同一边界逻辑。正在专项验证。
- F102继续未完成：异步队列/10秒截止/Provider阻塞/目录授权事务/错误反馈仍待补，累计89项不变。

- 扫描阶段最终 /tmp/ztransfer-f102-scan-20261016.log：2/2、0失败、TEST SUCCEEDED、退出0（含读取回归）；git diff --check通过。未UI/云Provider验证，F102不核销。

### F102 目录准备/提交与失败保留（2026-10-16）

- 对照PhotoLutEditorState.scan：新目录成功扫描后才替换；替换失败保持旧目录/列表/配方；新目录不同或选中项消失时off；刷新missing/denied才清列表并off，普通read保留列表。
- RemoteLUTFolderAccess新增prepareFolder/commit分离，准备在临时security scope内完成书签和完整扫描，成功前不写UserDefaults，退出释放临时scope。照片选择器接入该事务及安卓目录错误文案，移除失败无条件清列表。
- 新测试验证准备成功尚未接受、扫描失败、授权拒绝均不覆盖旧书签，明确commit后可恢复新目录。测试注入scope授权以独立于模拟器沙箱授权；真实Provider授权/撤权尚未验证。
- 当前仍同步执行准备，后续必须接单活跃/最新等待与10秒截止、代次和离页取消；不能因目录事务修好就核销F102。累计89项不变。

- 最终 /tmp/ztransfer-f102-folder-20261016.log：19/19、0失败、TEST SUCCEEDED、退出0；git diff --check通过。未UI/真实Provider测试，F102继续未完成。

### F102 单活跃最新等待队列基础（2026-10-16）

- 对照安卓LutIoQueue：新增MainActor管理状态、utility detached执行同步IO的LUTIOQueue，共享实例供后续生产入口使用。active未结束时只替换pending并取消被替换ticket；取消本身只设锁保护标志，不等待IO，也不提前释放active。
- 完成结果切回MainActor后重验ticket，取消后不deliver；任务返回后才释放active并运行最新pending。Ticket的unchecked Sendable仅用于由NSLock保护的取消标志。
- 新增队列专项验证最新pending替换、取消ticket和结果丢弃。当前测试允许首任务在实际执行前即取消，尚不能单独证明不合作Provider已经阻塞时的行为，后续须用启动屏障补强。
- 尚未接入PhotoLUTChooser、10秒计时/页面代次/离页取消，生产仍同步。F102保持未完成，累计89项不变。

- 基础队列专项 /tmp/ztransfer-f102-queue-20261016.log：1/1、0失败、TEST SUCCEEDED、退出0；git diff --check通过。验证范围限制如上，不据此核销F102。

### F102 异步目录请求与10秒生命周期（2026-10-16）

- 新增LUTRequestController，MainActor持有loading/代次/ticket/10秒计时，成功/失败取消计时并结束loading；取消同步清UI状态和ticket，超时取消后提示lut_read_timeout，迟到结果经ticket与代次两层拒绝。
- PhotoLUTChooser的首次刷新和换目录准备已接共享LUTIOQueue，完整扫描在utility任务执行，只有接受结果后主线程commit书签与列表。关闭LUT、选择另一LUT、离页取消目录请求。
- prepareFolder支持ticket取消检查，prepareBookmark在后台解析并准备保存目录。换目录比较旧URL仍有一次主线程bookmark解析；选择LUT的read/parse/saveSnapshot仍同步，后续必须迁移，不能称整条LUT加载已异步。
- 领域回归运行中；Controller超时/已阻塞active场景还需专门测试，不用旧队列基础测试替代。F102未核销，累计89项不变。

- 目录请求接线回归 /tmp/ztransfer-f102-request-20261016.log：20/20、0失败、TEST SUCCEEDED、退出0。
- 另补已启动worker屏障与不合作阻塞、100ms测试超时、UI解除loading、连续请求只保留最新及旧结果丢弃测试（生产默认仍10秒）。首轮f102-timeout因Swift6禁止async方法内直接调用Semaphore.wait编译失败；改为同步辅助方法只做deadline=now的非阻塞查询，async轮询仍用Task.sleep，正在重跑。worker故意阻塞用于模拟Provider，不在MainActor阻塞。

- 超时/阻塞启动屏障最终 /tmp/ztransfer-f102-timeout-fixed-20261016.log：1/1、0失败、TEST SUCCEEDED、退出0。测试确认旧worker释放前最新请求不启动，释放后只接受最新结果。git diff --check通过；未UI/真实Provider测试，文件选择读取解析与快照写入仍同步，F102不核销。

### F102 LUT文件选择后台准备与接受分离（2026-10-16）

- 对照PhotoLutEditorState.choose：读取、解析、私有表写入在单活跃队列完成；仅当前请求的成功结果进入主线程接受。PhotoLUTStore拆出Sendable PreparedSelection及nonisolated prepareSelection/writeSnapshot；acceptSelection只注册表、解析偏好并保存角色配方，不写表文件。
- 选择器已改为捕获bookmark/目标目录值，在utility worker解析bookmark、获取scope、有界读取、按行取消解析、按1024值取消检查编码并原子写快照。选择结果仍经过ticket与代次检查，超时/离页取消不会调用acceptSelection。
- 错误按安卓lut_invalid/lut_unsupported/lut_too_large/lut_read_failed提示并保留原配方；超时沿用lut_read_timeout。已存在快照仍直接复用，校验/修复与清理属于后续资源缺口；取消后已写成但未接受的私有快照也待统一清理。
- 回归运行中；真实Provider阻塞/撤权、异步准备取消不改角色的专门测试、换目录时旧bookmark主线程解析仍待补。F102保持未完成，累计89项不变。

- 后台选择接线最终 /tmp/ztransfer-f102-selection-20261016.log：30/30、0失败、TEST SUCCEEDED、退出0（21 Store/请求、9 Cube）；git diff --check通过。仅现有领域回归，尚不替代新增后台准备取消专测或真实Provider验证。F102未核销。

### F102 后台准备不发布与旧目录解析迁移（2026-10-16）

- 换目录时旧bookmark解析已移入同一后台队列，worker返回prepared与previousURL，主线程只比较返回值；选择器不再同步解析旧目录。
- 新增真实后台快照准备测试：先建立旧角色配方；已取消ticket准备新LUT应抛CancellationError且无新快照；正常后台准备写成新快照但旧角色/选中来源不变，只有acceptSelection才替换。与既有超时迟到结果丢弃测试互补，不声称覆盖写盘过程中任意时刻取消。
- Store/队列回归运行中；读取中增长/未知元数据、Provider撤权/慢读、加载态输入和完整错误分类仍需逐项复核。F102不核销，累计89项不变。

- 后台准备最终 /tmp/ztransfer-f102-prepare-20261016.log：22/22、0失败、TEST SUCCEEDED、退出0；git diff --check通过。包含真实detached快照准备与角色接受边界，未UI/真实Provider验证；F102保持未完成。

### F102 读取增长边界与加载态参数禁用（2026-10-16）

- 对照PhotoLutEditor的active=selection!=null&&!loading：强度和四项微调加载中禁用，提交回调另查loading拒绝迟到输入；UIViewRepresentable传递environment.isEnabled，禁用时取消tracking，禁止结束/辅助功能提交。
- 新增真实文件在metadata检查后扩为32MiB+1的测试，验证按实际读取拒绝；随后截为恰好32MiB，验证允许完整读取。补生产控件禁用后endTracking及辅助功能不提交的单元断言。
- /tmp/ztransfer-f102-boundaries-20261016.log：23/23、0失败、TEST SUCCEEDED、退出0。后续源码复查发现强度重复disabled而四项微调未接disabled（提交回调已有loading保护）；已修正这两处接线并进行最终编译，不把之前测试当成最终UI接线验证。
- 未UI/真实Provider验证；未知大小和读取失败分类、加载期间收藏等剩余细节仍需复核，F102保持未完成，累计89项不变。

- 最终控件接线 /tmp/ztransfer-f102-disabled-final-20261016.log：TEST BUILD SUCCEEDED、退出0；git diff --check通过。未实际手势测试。

### F102 根目录与子目录错误分类（2026-10-16）

- 对照LutFolderRepository：根目录不存在/不是目录为MISSING，权限为DENIED；子目录缺失或权限失败统一READ，不能误清根目录授权与有效配方。
- scanContents先验证根目录类型；prepareFolder书签错误、根枚举错误按Cocoa/POSIX分类，最多沿8层underlying error查找。子目录枚举错误始终read，继续不发布局部列表。
- 新增分类测试含包装的EACCES、根/子缺失、未知读取错误、真实普通文件作为目录；原缺失根目录测试从read纠正为missing。回归运行中，未真实Provider撤权验收。
- F102保持进行中，累计89项不变；主表已更新为当前已实现范围，撤销过时“未修复”的现状描述，历史审查记录保留。

- 错误分类阶段最终 /tmp/ztransfer-f102-errors-20261016.log：24/24、0失败、TEST SUCCEEDED、退出0；git diff --check通过。未UI/真实Provider撤权验证，F102继续未核销。

### F102 快照写成后的取消交付窗口（2026-10-16）

- 扩展后台准备测试：实际worker完成新LUT快照后用屏障延迟返回；主线程cancel关闭loading，随后放行worker，并用后继队列任务确认收尾已发生。旧角色选中/配方必须保持不变，取消结果若进入accept则明确失败。
- 保留准备前取消不写文件、成功准备不发布、明确accept后恢复新配方的原断言；结合不合作worker超时验证，覆盖准备前、准备后交付前两个取消窗口。
- 这不验证单次系统写盘内部强制中断，也不要求删除已成功写成的内容寻址快照；快照清理/持有归F106。专项运行中，累计89项不变。

- 取消交付窗口最终 /tmp/ztransfer-f102-late-20261016.log：2/2、0失败、TEST SUCCEEDED、退出0；git diff --check通过。真实Provider/界面交互仍未验收，F102保留进行中。

### F103 基础目录状态与浏览顺序（2026-10-16）

- 对照PhotoLutEditor.emptyLabel及LutFolderRepository排序：未配置目录显示photo_lut_set_folder，读取显示lut_reading_folder，成功空列表显示lut_folder_empty，错误单独显示且不再叠加“未选择”。
- 选择器标题/选目录按钮移除硬编码中文，复用photo_effect_module_lut和lut_choose_folder/lut_change_folder三语资源。没有已存目录时首次刷新不报missing、不清仍保留的私有配方。
- RemoteLUTCatalog改为文件名忽略大小写优先，再原始名、identifier稳定排序，不再relativePath优先。新增状态优先级及跨分类/同名排序测试；当前case-insensitive采用固定en_US_POSIX比较，非ASCII与Java比较器极端差异仍需核对，未据此宣称完整分类选择器完成。
- F102保留进行中；本轮推进相邻F103，分类入口/同名标签/当前定位等尚未补齐，F103不核销。累计89项不变。

- 首轮f103-status 2项中1项失败：en_US_POSIX的caseInsensitive比较实际把B排在a前，旧基础目录测试捕获。已改为显式lowercased后按UTF16比较，未改旧正确断言；非ASCII简单大小写映射与Java极端差异仍待单独收尾，正在重跑。

- 修正后 /tmp/ztransfer-f103-status-fixed-20261016.log：2/2、0失败、TEST SUCCEEDED、退出0；git diff --check通过。首轮失败保留；未UI测试，F103整体仍未完成。

### F103 同名LUT标签与稳定编号（2026-10-16）

- 对照LutFolderRepository.lutFileLabels：基础名称去掉末尾.cube；按忽略大小写名称分组，同名显示分类，根目录用lut_uncategorized；同分类仍同名时追加整个同名组中的位置。编号在收藏重排前生成，不随收藏顺序跳动。
- 选择器改用两行标签；选中后保存的配方名称使用不含后缀的label，空label回退文件名。未增添视觉动画。
- 新增根/分类同名、同分类大小写重复、唯一名称、空basename回退、繁中未分类及收藏重排保持标签测试。分类弹窗/定位和完整特殊Unicode排序仍未补齐，不核销F103；累计89项不变。

- 标签专项 /tmp/ztransfer-f103-labels-20261016.log：3/3、0失败、TEST SUCCEEDED、退出0；git diff --check通过。未UI测试，F103保持未完成。

### F103 分类选择与刷新位置保持（2026-10-16）

- 对照LutCategoryList：分类去重、根未分类优先；选中来源变化时定位该分类，后台列表刷新不强行跳回选中项分类；用户所看分类消失才回退首项。
- 新增PhotoLUTCategorySelection并接基础菜单筛选文件行，异步首次加载后可定位已恢复选中项。保留独立状态，不在每次body计算中重置分类。
- 专项覆盖空列表后加载、当前B定位、用户浏览A后反序刷新仍在A、选中根项转未分类、分类消失回退和空列表。尚未接独立弹窗/长按入口与当前行滚动定位；非ASCII分类比较仍沿前轮待核问题，不核销F103。
- 当前只做可用控件，无样式/动画复刻，累计89项不变。

- 分类专项 /tmp/ztransfer-f103-category-20261016.log：4/4、0失败、TEST SUCCEEDED、退出0；git diff --check通过。未UI测试，F103继续未完成。

### F103 独立选择器基础接线（2026-10-16）

- 主编辑器改为当前名称入口，点击/长按打开基础sheet；未设置有效来源且列表为空时点击进入目录选择。打开时刷新目录并按当前选中项定位分类。
- sheet提供固定关闭/更换目录操作，复用分类状态和稳定标签；列表用LazyVStack+ScrollViewReader，分类变化重建滚动区域，定位当前项或首项。更换目录等sheet关闭后再打开文件选择，避免同时呈现两个面板。
- 读取私有配方名称只取UserDefaults元数据，不读快照；来源暂时无法枚举仍显示已保存名称，保持关闭入口。
- 此次为基础可用界面，未复刻安卓双列样式/动画；编译验证中，未UI/实际长按及滚动定位验收。sheet内加载/失败状态展示仍需复核，F103不核销，累计89项不变。

- sheet自身已补加载、失败和空态反馈，避免错误藏在底层编辑器。首轮chooser和最终chooser-final日志均TEST BUILD SUCCEEDED、退出0；git diff --check通过。此次只编译，不记为实际呈现/滚动/长按测试通过，F103保持未完成。

### F104 扩展LUT输出混合顺序（2026-10-16）

- 对照PhotoCubeMapperTest.domainAndExtendedOutputClampBeforeStrengthMixing及生产mapper：合法负值/>1的LUT输出须先clamp再与原色按强度混合。iOS原来仅在混合后clamp，已改为前置输出clamp。
- 新增真实CGImage像素测试：domain0.25…0.75，恒定输出(-0.5,1.5,0.5)，原色0xff804020；50%精确要求RGBA(64,160,80,255)，100%要求(0,255,128,255)。同轮包含alpha128的预乘输入及全透明像素精确输出，补证此前F101去/再预乘接线。
- Cube全组回归运行中；此处验证像素转换，不是样式/动画或UI测试，累计89项暂不变。

- 首轮f104-clamp 10项中1项失败：100%蓝通道127而安卓要求128。继续对照生产PhotoCubeMapper.channel，发现安卓先将clamp结果乘255再在字节域混合；已对齐该运算次序，保留精确断言不增加容差，正在重跑。

- 第二轮f104-clamp-fixed仍10项中1项失败，同一蓝通道差1；继续定位CubeLUT.sample的八顶点一次加权求和与安卓逐轴插值顺序不同。已按PhotoCubeMapper.channel同步R/G/B逐轴乘加，精确断言不变，第三轮interpolation运行中。两轮失败日志均保留。

- 最终 /tmp/ztransfer-f104-interpolation-20261016.log：10/10、0失败、TEST SUCCEEDED、退出0；git diff --check通过。安卓指定两档精确像素、半透明预乘/全透明及已有颜色微调渲染回归通过。F104开发侧核销，累计90项；两轮中间失败保留，未UI/真机验收。F102/F103及其他LUT资源条目仍未完成。

### F105 域范围与损坏快照校验（2026-10-16）

- 对照CubeLutParser最终域检查及PhotoLutSnapshotCodec.read，抽取CubeLUT.validDomain共享有限域/有限range/正规range及倒数验证。文本解析额外保持安卓端点非次正规要求，快照仅使用codec对应规则，未混同两种输入契约。
- 修复原文本只检查倒数finite导致range溢出或倒数下溢仍接受；快照恢复在读取颜色前验证域，按size要求精确字节数，拒绝截断和尾随内容，失败不register到runtime。
- 新增文本±3e38范围溢出、0…3e38倒数下溢；真实快照覆盖零域/反向域/NaN/范围溢出/倒数下溢/无限颜色/尾字节/截断，断言不恢复、不覆盖已注册有效表、不改来源标识，恢复原文件后正常恢复配方。
- 回归运行中；累计90项暂不变，F105待验证后核销；既有快照修复和资源清理仍属F106后续范围。

- F105最终 /tmp/ztransfer-f105-domain-20261016.log：36/36、0失败、TEST SUCCEEDED、退出0（11 Cube+25 Store/请求）；git diff --check通过。F105开发侧核销，累计91项；F102/F103/F106继续未完成，未UI/真机验收。

### F106 持久快照目录与旧缓存迁移（2026-10-16）

- 对照安卓PhotoLutStore使用app.filesDir，iOS默认快照目录改为Application Support/photo-lut-snapshots，避免将已承诺的私有配方只放系统可清理Caches。
- 新目录缺少目标时可从旧Caches恢复；先完整校验域/颜色/长度，再原子复制到持久目录，复制失败不发布恢复结果。新目录已存在的坏文件不回退旧缓存掩盖错误；旧缓存不在本次迁移中删除，后续清理归资源生命周期统一处理。
- 安卓snapshot也跳过已存在文件，因此本轮未引入额外“自动修复已有损坏快照”的行为；上一轮记录中的待修复表述仅是待调查，不算已确定复刻要求。
- 新增迁移后删除旧缓存仍恢复、坏旧快照不复制、默认目录位置测试。迁移仍在现有同步restore路径，懒加载/有界缓存/活动配方持有/清理尚待补齐，F106不核销，累计91项不变。

- 持久目录迁移最终 /tmp/ztransfer-f106-durable-20261016.log：26/26、0失败、TEST SUCCEEDED、退出0；git diff --check通过。未UI/真机缓存清理验证，F106仍未完成。

### F106 后台快照读取基础与解码边界（2026-10-16）

- 梳理PhotoLUTRuntime取表入口：效果选择/归一化/实际渲染目前均依赖全局强字典，不能在未接私有快照重载前直接淘汰，否则排队配方可能失效。
- 从PhotoLUTStore.restoreSnapshot抽取nonisolated readSnapshot(at:digest:)，共用F105全部校验且不注册runtime；读取最多最大合法65格快照字节数+1，拒绝超限，不再无界Data(contentsOf:)。
- 既有角色恢复和旧Caches迁移复用该读取器；迁移改为经已校验表原子写持久快照，成功后才发布runtime。新增真实detached准备/读取、读取不发布以及稀疏超大快照拒绝测试。
- 尚未引入LRU/16项/8MiB预算或生产缓存未命中重载，原全局字典仍未改变；此为后续安全淘汰的基础，F106不核销，累计91项不变。

- 后台读取基础最终 /tmp/ztransfer-f106-reader-20261016.log：27/27、0失败、TEST SUCCEEDED、退出0；git diff --check通过。缓存淘汰与懒加载仍未实现，F106保持未完成。

### F106 有界LRU与私有快照重载第一阶段（2026-10-16）

- 对照PhotoCubeResourceCache预算8MiB/最多16项/LRU；iOS新增锁保护PhotoLUTResourceCache，仅计实际保留Float表字节（iOS没有安卓direct mapper副本），超预算单表不缓存，访问刷新LRU。
- PhotoLUTRuntime注册持久快照URL，缓存未命中在缓存/索引锁外调用有界快照读取，成功后重新缓存。PhotoLUTStore成功接受/写入/恢复均注册URL；编辑器selectFilter/normalized改为metadata-only contains，避免校验触发磁盘加载。
- 新增小预算精确淘汰顺序、字节数/项数及超大不缓存；真实私有快照接受后清内存，验证contains仍有效且table从文件恢复、外部来源不参与。
- 第一阶段尚无同key并发读取合并、URL索引/快照owner与清理、启动角色懒恢复；purgeMemoryCache尚未接系统内存警告。不能把缓存容量有限等同F106全部完成，累计91项不变。

- LRU/重载第一阶段最终 /tmp/ztransfer-f106-cache-20261016.log：39/39、0失败、TEST SUCCEEDED、退出0（28 Store/请求+11 Cube）；git diff --check通过。未实际大批任务峰值/并发同key复用验证，F106保持未完成。

### F106 同标识快照读取合并（2026-10-16）

- 对照安卓 PhotoCubeResourceCache.acquire 及 sameSnapshotLoadsOnceAndUnrelatedHitsDoNotWaitForDiskRead：iOS 按 digest 共享进行中的读取，磁盘读取及条件等待均不持有 LRU 锁；成功后复用已有缓存或纳入预算，失败不缓存，后续可重试。生产 PhotoLUTRuntime.table 已接入。
- 新增模型测试覆盖阻塞读取期间另一个 LUT 命中、重复请求结果一致且不得重复读取、失败后的重新读取；与已有 Store 测试一起运行。并发测试与安卓同样使用读取进入/释放屏障，未强制观察第二请求已进入等待分支，不能据此声称所有交错或并发失败广播均已穷举。
- /tmp/ztransfer-f106-coalesce-20261016.log：TEST SUCCEEDED、退出0；未运行 UI 测试。启动角色懒恢复、快照 owner/清理、内存警告接线等仍未完成，F106 不核销，累计91项不变。

### F106 启动恢复只读元数据（2026-10-16）

- 对照安卓 PhotoLutStore.restore：合法digest、名称和私有快照为文件即可恢复配方；通过 PhotoLUTRuntime.registerSnapshot 只注册URL，LUT内容到现有渲染worker缓存未命中时解码。缺失文件及同名目录均拒绝，即使缓存仍有旧表也不掩盖文件缺失。
- 纠正F105此前过强的恢复阶段断言：损坏快照仍由readSnapshot拒绝，但restoreSelection本身不应解码、也不应因此返回nil。此前“restoreSelection损坏返回nil”的记录为历史实现，现按安卓懒恢复规则替代；不能将此改动解释为放宽二进制校验。
- 新测试在恢复后把真实私有文件改坏，首次runtime读取返回nil，证明恢复未预热表；恢复合法字节后读取成功，删除文件或换成目录则角色恢复失败。旧缓存目录兼容迁移仍同步验证和复制，尚未解决这条首次迁移路径；owner/清理仍未完成。

- 最终 /tmp/ztransfer-f106-lazy-20261016.log：30/30、0失败、TEST SUCCEEDED、退出0；git diff --check通过。未UI测试，F106保持未完成，累计91项不变。

### F106 活跃配方快照持有基础（2026-10-16）

- 对照安卓PhotoLutStore的WeakHashMap及snapshot写入前强owner：新增不可变PhotoLUTSnapshotOwner，仅保存digest/URL，不持有LUT数组；准备选择在写盘前持有owner，PhotoFilterSelection复制自然保留引用，runtime登记为弱引用并回收失效项。
- 恢复/接受选择后构造配方取得owner；归一化修改配方值时保留原owner，不从全局digest索引重建。渲染优先使用配方自身路径，兼容原无owner的临时表。owner不参与JSON和业务相等判断。
- 新模型测试覆盖编辑器引用释放后配方副本仍持有、全局URL改变后原配方从自身路径重载、JSON不泄漏运行时引用、归一化保持同一owner、末份配方释放后弱引用为空。另运行真实队列失败重试测试。
- 初轮f106-owner-20261016.log为32/32、TEST SUCCEEDED、退出0；随后补归一化保留及断言，最终验证另记。此阶段未启用磁盘删除，也未声称真实队列与prune竞争已通过；持久角色保留集合、清理与写入互斥、URL索引清理仍待接线，F106不核销。

- 最终f106-owner-final-20261016.log：32/32、0失败、TEST SUCCEEDED、退出0（31 Store模型+1真实队列重试），含归一化引用身份断言；git diff --check通过。F106保持未完成，累计91项不变，未UI测试。

### F106 后台快照清理及双角色保留（2026-10-16）

- 对照安卓TransferViewModel启动prune、PhotoLutEditorState成功选择后清理、PhotoLutStore.prune活跃owner+transfer/local持久角色集合：iOS启动及acceptSelection后串行后台清理私有目录的普通.bin文件，保留两角色当前digest和活跃owner。非.bin文件和目录不删除。
- 目录枚举不持有owner锁；逐文件删除前在owner锁下重读当前UserDefaults角色集合并检查弱owner，防止排队前捕获的旧角色集合误删后来保存的配方。准备选择、兼容迁移和直接快照写入都先取得owner；删除成功才移除相应URL登记。
- 新测试覆盖双角色文件、已复制的旧配方、prepare完成但尚未accept的快照保留，释放旧配方/准备结果后的删除、无关文件保留、旧配方淘汰后从文件重载、删除后URL索引清除。仍未穷举OS写入阻塞、实际队列与清理同时交接或进程终止等边界；F106不核销。

- 最终f106-prune-20261016.log：33/33、0失败、TEST SUCCEEDED、退出0（32 Store模型+1真实队列重试）；git diff --check通过。累计91项不变，F106继续保留未完成，未UI测试。

### F106 写入发布与取消清理的确定性交接（2026-10-16）

- 新增testPruneDuringWriteHandoffRetainsFileUntilCancelledWriterReleasesOwner，使用prepareSelection现有取消检查点与双信号屏障，不以固定延迟猜测时序。工作线程真实编码并原子写入后，在返回PreparedSelection之前阻塞；主线程请求真实串行清理，确认文件仍可完整解码且当前角色未被接受。
- 放行时抛CancellationError，等待writer真正结束，再运行清理确认文件删除且角色仍未改变。覆盖已发布文件但未交付结果的所有权窗口；不声称覆盖Foundation内部原子写系统调用挂起、进程被杀或全部并发交错。此次无生产逻辑修改，验证上一轮提前owner持有的实际作用。

- 最终f106-write-handoff-20261016.log：33/33 Store模型、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F106仍未核销，累计91项不变；旧缓存迁移同步路径、多65格预算与实际队列清理交接仍待补证。未UI测试。

### F106 最大65格LUT预算及活跃值验证（2026-10-16）

- 对照安卓PhotoCubeResourceCacheTest的淘汰后活跃渲染持有与超预算不驻留规则，新增testMaximumSizeLUTsRespectDefaultBudgetAndActiveValuesSurviveEviction。连续创建20张65³×3 Float实数组，默认8MiB仅保留最后两张（每张3,295,500字节）；逐次检查预算和项数，旧表被淘汰后活跃值仍完整可读，清空缓存也不使其失效。
- 同一测试还覆盖比一张表少1字节的预算：两次acquire都返回完整值且分别读取，缓存始终为空；另以20张小表确认默认16项上限及最旧项淘汰。
- 此为实际数组的缓存计量和所有权验证，不是整个进程RSS/渲染峰值或OOM测试；不据此消除旧目录首次迁移及实际队列清理交接的待办。

- 最终f106-large-20261016.log：1/1专项、0失败、TEST SUCCEEDED、退出0；git diff --check通过。未重复全套测试，本轮只增加此预算测试；F106未核销、累计91项不变。

### F106 真实队列独占旧配方与清理交接（2026-10-16）

- 新增testQueuedLUTSurvivesEditorReplacementPruneAndCacheEviction：临时作用域构造旧配方并入真实TransferQueue，返回后测试仅保留弱owner引用；编辑器切到新LUT、运行prune并清空内存缓存，旧文件仍在。任务使用真实PhotoEffectsRenderer生成JPEG并验证旧LUT像素，随后移除任务，等待弱owner释放，再prune确认旧文件删除、新角色仍可恢复。
- 本例不使用会记录完整settings的假renderer，也不在测试外层保留旧effects/selection/任务snapshot，以免其他强引用掩盖队列持有缺失。任务输出是旧黑LUT的100%强度，新编辑器LUT为白色。
- 初轮f106-queue-prune-20261016.log编译失败：测试读取可选effects未解包；已改可选链，并显式设定旧任务100%强度。保留失败记录，最终验证另记。

- 最终f106-queue-prune-fixed-20261016.log：2/2（真实队列独占旧配方清理交接+原失败重试）、0失败、TEST SUCCEEDED、退出0；git diff --check通过。仅验证本例交接，不声称全部并发交错；旧缓存迁移等仍待补，F106未核销、91项不变。

### F106 旧缓存目录懒迁移（2026-10-16）

- 对照安卓PhotoLutStore.restore仅元数据/渲染worker懒加载规则，移除iOS restoreSelection旧目录分支的同步全表解码与复制。该分支只验证旧路径为文件并登记primary/legacy路径；轻量owner保留迁移来源，实际table(owner:)在调用者渲染worker校验旧数据、原子写入持久目录。
- 迁移按目标路径合并正在进行的读取，使用不保留表的独立合并器；迁移失败不缓存，不能让已有同digest热表掩盖失败。成功后正常资源缓存复用；已有目标优先读取目标，不回退旧文件掩盖目标损坏。删除旧缓存后新Store仍可恢复持久配方。
- 初轮f106-migration-20261016.log为34/34、TEST SUCCEEDED、退出0；后续强化迁移测试为后台调用，并增加目标目录被普通文件占据时失败、移除阻挡后重试成功的断言，最终专项另记。坏旧文件允许元数据恢复但读取失败且不生成持久文件，与此前懒恢复规则一致。
- 不声明整个进程峰值或所有迁移/清理并发交错已验证；F106本轮仍不核销，累计91项不变。

- 强化最终f106-migration-retry-20261016.log：1/1、0失败、TEST SUCCEEDED、退出0，后台迁移、目标阻挡失败和解除后重试均通过；git diff --check通过。无UI测试。

### F106 最终功能要求核验（2026-10-16）

| 原验收要求 | 当前实现与直接证据 |
| --- | --- |
| 8MiB/16项与多65格切换 | PhotoLUTResourceCache LRU；large专项20张65格实数组、超预算不驻留、默认16项及活跃值跨淘汰保持 |
| 排队后外部来源失效仍用原配方 | 私有原子快照+PhotoFilterSelection轻量owner；role重建/来源缺失模型及queue-prune真实队列独占旧配方生成像素 |
| 内存淘汰后重载 | runtime缓存未命中读私有文件；lazy、cache及真实队列测试均清空内存后读取 |
| 写盘失败不得接受新选择 | prepare成功后才accept，chooser失败仅显示错误；新增真实目标目录被文件占据测试验证旧来源、强度、微调、配方及runtime均不接受新LUT，解除阻挡后重试 |
| 清理与恢复 | 持久目录、双角色实时保留+弱owner、启动/成功选择后台prune；write-handoff证明原子发布未交付时保留，取消后释放删除；queue-prune证明任务移除后清理 |
| 启动懒恢复及旧缓存 | restore仅元数据；worker校验/迁移，旧目录删除后重建仍恢复；migration-retry覆盖后台写失败与重试 |

- 这是功能/业务开发侧验收，不宣称实际设备进程RSS峰值、系统杀进程或全部文件系统故障均已覆盖；UI测试按用户范围跳过。此前“内存警告接线待办”为扩展建议，安卓基准与F106原验收没有该要求，不能以此无限延后核销；现有有界缓存及主动purge重载已经验证。其他未完成F项保持原状态。

- 最终f106-final-20261016.log：48/48、0失败、TEST SUCCEEDED、退出0（35 Store/请求+11 Cube+2真实队列）。写失败保旧及解除后重试通过，git diff --check通过。F106按上述功能证据开发侧核销，累计92项；整体目标、F102/F103/F107等仍未完成。

### F107 Cube像素循环分批取消第一阶段（2026-10-16）

- 对照安卓PhotoCubeMapper.mapRange非native路径4096像素批次及PhotoCubeBulkTest.cancellationStopsBetweenBatchesAndDoesNotTouchTheRemainder：PhotoCubeLUTMapper.apply改为throws，入口、每4096像素批次（含透明像素）及输出前执行取消检查，默认Task.checkCancellation；生产renderer以try传播CancellationError，不降级为unknownFilter或返回部分图片。
- 新增模型验证129×65像素的3批（含短尾），不透明/透明两种输入，每个检查点取消均中断抛错，正常路径检查次数一致；原颜色精确像素测试一并回归。
- 复查发现PhotoEffectsEditorView无来源演示图分支直接await Task.detached.value，尚未向子任务传递取消；LocalPhotoOutput.filteredSource已有withTaskCancellationHandler。下一步需补演示图分支并验证生产任务取消释放gate，不能只凭此循环测试核销F107。

- 最终f107-cancel-20261016.log：13/13、0失败、TEST SUCCEEDED、退出0（12 Cube+1 Mapper）；git diff --check通过。F107仍未核销，累计92项不变。

### F107 演示图预览取消向后台传递（2026-10-16）

- 原PhotoEffectsEditorView fallback直接等待detached.value，父任务取消只抑制末端发布，子任务仍可能等待/占用共享gate。现使用PhotoEffectsPreviewRenderGate.render，显式保存worker并以withTaskCancellationHandler传递cancel，worker进入/返回和父任务接收结果时均检查取消；保留utility优先级、autoreleasepool、1920预览和原演示图设置。
- 新增testFallbackPreviewCancellationReachesDetachedWaiter：真实shared gate被另一个任务持有，确认fallback子任务已排队再取消父任务；旧任务应在许可仍占用时退出且不进入绘制，随后许可释放、新任务正常运行。该测试证明排队阶段取消传递，不单凭它声称绘制中CPU取消已闭环；F107继续等待活动渲染中断验证。

- 最终f107-fallback-20261016.log：16/16、0失败、TEST SUCCEEDED、退出0（4 gate/取消+12 Cube）；git diff --check通过。F107未核销、92项不变，未UI测试。

### F107 活动像素取消与许可交接验证（2026-10-16）

- testActiveMappingCancellationReleasesPreviewPermitForNextRender将真实256×256非透明CGImage交给生产PhotoCubeLUTMapper，在第三次检查（入口、首批、第二批）暂停，确保已经处理4096像素；父任务取消经生产PhotoEffectsPreviewRenderGate.render桥传入worker，放行后真实Task.checkCancellation抛CancellationError，旧任务没有返回图像。
- 新任务使用同一共享gate和真实mapper，能返回256×256图像，结束时pendingCount为0；结合既有排队取消测试证明取消不泄漏许可。此前每个检查点、透明/不透明与尾批测试继续回归，不把初始已取消测试替代活动循环测试。
- 静态复核LocalPhotoOutput.filteredSource/preview的取消handler均取消detached worker；PhotoEffectsEditorView普通/演示结果写入前均检查父任务取消。实际UI快速换选/离页未运行，按用户限定以业务取消链及发布门控核验，不宣称CoreGraphics内部draw调用可中断。

- 最终f107-active-20261016.log：18/18、0失败、TEST SUCCEEDED、退出0（13 Cube+4 gate/取消+1 Mapper）；git diff --check通过。F107按功能范围开发侧核销，累计93项。下一步F108普通滤镜分类与选择器功能；整体目标仍未完成。

### F108 普通滤镜分类元数据修正（2026-10-16）

- 对照BuiltInPhotoFilters以definition.fallbackName构造preset.name及PhotoFilterCategory分类顺序，iOS PhotoFilterPreset.category现通过目录解析canonical ID/catalogKey/legacy ID并使用fallbackName；未命中目录的自定义preset保留其自身名称分类。中文/英文显示名称不再影响内置分类。
- 将分类枚举及扩展从UI文件移至PhotoEffects领域模型，保留安卓分类标题、优先级和名称匹配规则。实际显示仍走原资源文案。
- 新增PhotoFilterCategoryParityTests，以安卓CuratedNp3Filters与分类规则导出固定50项分组，逐项检验3种ID×3种显示名称，包含森屿青/蓝调时刻/暮色余温等原错项；没有用iOS分类结果生成期望。
- SettingsScreen 1722起仍要求顶部photo_filter_turn_off按钮、分类切换重新定位当前启用项、收藏顺序以及低屏可操作范围；iOS这部分尚待补齐。F108未核销，累计93项不变。

- 最终f108-category-20261016.log：1/1专项（50项×3种ID×3种显示名称）、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F108保持未完成，未UI测试。

### F108 选择器关闭、排序与定位（2026-10-16）

- 对照SettingsScreen的LutChooserHeader/onDisabled、orderForCategory、key(category)初始当前项与记忆强度：新增领域PhotoFilterChooserState.items/initialItemID/select，生产overlay共享同一列表与定位规则。当前启用项在分类内则定位该项，否则首项；收藏按既有favoriteFilterIDs顺序，空列表无目标。
- 顶部使用photo_filter_turn_off原资源，关闭停用滤镜并保留原配方；选中恢复该滤镜记忆强度，二者关闭弹层并调用既有tick。ScrollViewReader每分类重新建立，以模型目标滚到顶部。弹层按屏幕高度减120限制到120…440，宽度不超过320及可用宽度，解决原最小360高度对矮屏的可用性问题；细样式/动画仍排除。
- 模型测试覆盖收藏两项顺序、分类过滤、当前启用项/停用后首项/空收藏定位，关闭保配方、重选记忆强度及关闭弹层；与50项分类专项合跑。未运行UI测试，不声称真实触摸/滚动落点已截图验收。

- 最终f108-chooser-20261016.log：2/2、0失败、TEST SUCCEEDED、退出0，含50项分类及选择器状态；git diff --check通过。F108按当前功能范围开发侧核销，累计94项；仅另做缩进整理，无行为变化。整体任务仍未完成。

### F109 本地成片缓存先于滤镜计算（2026-10-16）

- 对照SettingsScreen.renderPreview 3046起：filteredSource位于outputCache.getOrRender的渲染闭包内。LocalEffectPreview当前任务现先从prefetched取完整settingsKey成片，命中直接使用；只有miss才解析filterKey、复用/生成中间滤镜图并合成。保留输出前Task取消检查及原比较图流程。
- 当前缓存仍是页面局部、消费式字典；settingsKey包含像素设置，页面源图随batch.state.photos身份重建。此次未改变缓存身份或新增缓存，不将旧中间图标记成新滤镜结果。
- 安卓getOrRender 3490起还复用缓存拥有的running任务，await取消不取消预取本身；iOS prefetchedPreviews仍逐次新建工作，预取提升当前时无法加入同一running任务。此项需继续抽取共享缓存任务/需求管理并做计数与取消验证，F109暂不核销。
- 本轮为条件顺序修正，未新增照抄实现的测试；仅编译验证，不声称运行时计算次数或预热提升测试已通过。

- 最终f109-cache-order-20261016.log：TEST BUILD SUCCEEDED、退出0；git diff --check通过。未运行测试，F109未核销，累计94项不变。

### F109 单目标共享预览任务基础（2026-10-16）

- 对照SettingsScreen.PhotoEffectsPreviewCache的completed/running及缓存拥有任务：新增PhotoPreviewFrameCache<Value> actor，同一目标至多一份后台渲染，成功结果保留，失败清running允许后续重试。各调用者通过独立continuation等待，取消只移除该等待者，不撤销共享工作；close取消worker、清结果并立即唤醒全部等待者，迟到结果按任务id及closed门控丢弃。
- 模型测试在真实挂起的render内取消预取等待者，然后当前调用接入同一工作；重复render闭包一旦执行即失败，完成后再次命中亦不得重算。另覆盖失败后可开始新工作、close在忽略取消的worker返回前结束等待、关闭缓存不可重新接纳请求。
- 此为单目标共享工作基础，尚未接入LocalEffectPreview；还需外层3项有界缓存、源图/画布身份、当前+相邻需求集合、预取提升及离页close接线。不能将这些模型通过宣称生产预取复用完成，F109未核销、94项不变。

- 最终f109-shared-20261016.log：2/2、0失败、TEST SUCCEEDED、退出0；git diff --check通过。生产预览尚未消费新模型，F109保持未完成。

### F109 三项访问序缓存与淘汰生命周期（2026-10-16）

- 对照BoundedAccessCache.kt及PHOTO_EFFECTS_RECENT_PREVIEW_CACHE_SIZE=3：新增PhotoPreviewCacheSet<Key,Value>，仅请求时创建单目标共享缓存，命中更新访问顺序，超容量删除最旧项并close其worker/等待者；close清空全部条目并拒绝新请求。单次get返回后检查调用者取消。
- 测试覆盖A/B/C→访问A→D时淘汰B、B重新计算、容量保持3、关闭后不可复用、新缓存同key不继承旧结果；容量1时活动旧工作被淘汰，旧等待者立即取消，新结果正常可复用。与单目标共享任务测试合跑。
- 生产LocalEffectPreview仍未消费这两层模型，源图/装饰身份重建及当前+两邻需求更新仍需接线；本步不把模型隔离测试当页面缓存失效运行证据。F109未核销，94项不变。

- 最终f109-bounded-20261016.log：4/4、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F109未完成，生产接线仍待继续。

### F109 本地页面共享预览接线（2026-10-16）

- 新增页面拥有的LocalPhotoPreviewCache，生产LocalEffectPreview当前渲染与相邻预取均走同一PhotoPreviewCacheSet；删除旧prefetched字典及重复过滤路径。成片命中直接返回共享结果，miss内才计算滤镜/合成。保留单份当前滤镜中间图供装饰变化复用，预取不会无限持有中间图。
- cache scope按UIImage身份、元数据和去掉滤镜后的像素装饰设置重建；frame key使用sortedKeys JSON像素设置。当前滤镜切换共享三项成片；源/装饰变化关闭旧scope并用代次拒绝迟到结果，离页close清图像引用与缓存。
- 此处仍缺安卓current+两邻需求更新对未淘汰但已过期worker的主动取消；共享worker最多受三项缓存约束，不能据生产接线声称F109完整。后续需补需求替换/透明重试及验证实际预取提升交接。

- 生产接线回归f109-integrate-20261016.log 4/4；真实NP3图像缓存f109-real-cache-20261016.log 1/1，均TEST SUCCEEDED、退出0。真实测试验证同key返回同一UIImage、强度变化新图、回访旧key命中、换UIImage来源失效及close拒绝；未UI测试，需求主动取消仍待补。git diff --check通过，F109未核销、94项不变。

### F109 当前与两邻预取需求管理（2026-10-16）

- 对照SettingsScreen.previewDemand.replaceRequested：LocalPhotoPreviewCache.configure现更新当前+允许预取时的两邻设置key；当前任务及prefetch条件变化都更新需求，禁用预取也会收缩为当前项。过期worker取消并立即结束等待，但已完成帧仍由三项LRU保留。
- PhotoPreviewFrameCache区分调用者取消、关闭与需求过期；外层只对需求过期且该key再次被请求、同entry仍有效的情况重新接续，其他错误正常传播。需求更新有revision避免旧替换在await后继续覆盖新集合；循环及登记continuation时复检关闭/需求状态。
- 新测试覆盖挂起旧需求被移除立即取消、非需求不能启动、重新请求可生成新结果、已完成帧在需求来回切换后保持命中；与共享任务、三项淘汰及真实NP3失效测试合跑。仍需最终核对预取提升交接与参数失效的完整证据，F109暂不核销，94项不变。

- 初轮demand 6/6通过；登记状态补强后最终f109-demand-final-20261016.log：6/6、0失败、TEST SUCCEEDED、退出0；git diff --check通过。F109暂未核销，下一步最终场景核验，未UI测试。

### F109 最终功能场景核验（2026-10-16）

- 已预热B→切B：真实NP3渲染测试先按A的相邻需求生成B，再configure为B；返回同一UIImage对象，证明直接复用成片而非先重新滤镜计算。不同强度仍生成不同图，回访近期项复用。
- 源/框变化：真实测试更换UIImage身份失效；minimal→mist重建装饰scope，旧装饰render被拒绝，新框生成新图；离页close拒绝旧页面请求。
- 预取取消提升：单目标测试先取消预取等待者，再由当前请求加入同一挂起worker，闭包重跑即失败；外层需求测试覆盖过期取消/再次请求、completed保留，gate测试覆盖排队/活动取消后的后续工作。
- 生产LocalEffectPreview当前与预取共享同一StateObject缓存；源/装饰scope、三项LRU、当前+两邻需求、代次发布门控和离页close已接。nextPhotoFilterSelections移到PhotoEffects领域模型，消除缓存对UI文件的倒向依赖。
- 本轮不运行UI测试，不宣称真机帧时间/峰值；核验范围为原F109重复像素工作与取消/失效业务要求。最终结果通过后按开发侧功能口径核销。

- 最终f109-final-20261016.log：10/10、0失败、TEST SUCCEEDED、退出0；包含真实成片预热提升/装饰失效与共享任务/需求/gate验证。git diff --check通过，F109开发侧核销，累计95项。下一步F110原图导出资源与执行策略，整体目标继续。


2026-10-16 F110第一阶段：原图NP3在调用worker顺序计算，预览按安卓阈值512×512最多两个任务；renderer默认original，两个实际预览入口显式preview。f110-workers-20261016.log 5/5 TEST SUCCEEDED、退出0，覆盖线程策略、513行真实像素串并行一致、透明/半透明、源数据保持及取消入口。尚未消除无框/沉浸整图缓冲，未验证高像素并发峰值，F110不核销，累计95项不变。


2026-10-16 F110第二阶段：无框原图与仅水印合并到drawFlatPhoto最终画布，沉浸纳入已有drawFilteredPhotoTiles；逐块autoreleasepool限制临时对象寿命，原图不再预先创建整幅过滤结果。1024×4101跨4Mi像素边界，对照整图预过滤后合成，无框/水印-only/沉浸逐字节相同。f110-flat-fixed-20261016.log 6/6 TEST SUCCEEDED、退出0；首轮f110-flat测试漏写settings引用导致编译失败已保留。尚待Cube/方向/透明图与高像素批次并发资源验证，未测RSS/OOM，解码及最终画布仍有全图存储；F110未核销，累计95项。


2026-10-16 F110方向/透明专项：NP3与Cube两种过滤×全部8种UIImage方向，含透明/半透明区域，原图分块对照整图预览逐字节相同；跨4Mi像素边界三合成路径回归同时通过。f110-orientation-20261016.log 2/2 TEST SUCCEEDED；未UI测试。新增发现：Android PhotoAllocationBudget.kt在解码/画布前校验饱和尺寸、系统可用内存及Java scratch预算，iOS尚缺对应预检；需按平台内存模型处理，不能将分块即视为资源安全。仍待高像素批次/传输并发、活动取消及预算验证，F110不核销、累计95项。


2026-10-16 F110预算模型：PhotoAllocationBudget按安卓实现饱和尺寸/份数/额外内存计算及native最低64MiB余量判断。f110-budget-model-20261016.log 2/2 TEST SUCCEEDED、退出0，覆盖溢出、非法值、阈值精确边界。模型尚未接生产分配入口，不声称已保护导出。已通过异步问题请求平台差异确认：iOS os_proc_available_memory替代安卓系统/Java堆检查，预算不足沿用失败/重试且不降采样；尚待用户答复。SDK os/proc.h确认接口是当前进程dirty上限余量即时快照，不应缓存。F110未核销、累计95项不变。


2026-10-16 F110补Cube跨块证据：非恒定RGB轮换LUT、60%强度，1024×4101越过4Mi像素边界，无框/水印-only/沉浸逐字节对照整图预过滤合成；同轮NP3大图和两类全部方向/透明回归通过。f110-cube-seam-20261016.log 3/3 TEST SUCCEEDED、退出0。用户已认可iOS进程可用内存平台方案，下一步接生产预算预检；当前仅模型，不误报保护已接。F110未核销、累计95项。


2026-10-16 F110生产预算接线：原图render在像素处理/最终画布分配前估算惰性源解码、UIKit最多8字节画布、1/4尺寸阴影代理、两份约4Mi像素tile及8MiB其他工作区；饱和计算，默认每次调用os_proc_available_memory，至少64MiB余量，不足抛PhotoAllocationRejected进入既有失败链，不降采样。预览不使用此原图预检。首轮f110-budget-live 4项1失败发现模拟器接口返回0，已用targetEnvironment(simulator)独立适配无iOS额度，真机0仍拒绝；有限预算由测试注入。最终f110-budget-simulator-20261016.log 4/4 TEST SUCCEEDED、退出0，含低预算拒绝→重新读取预算→成功、原图字节/尺寸保持和方向透明回归。不是实际真机压力或队列重试专项，后续仍须完善并发峰值/活动取消、画布格式估算核验；F110未核销，累计95项。


2026-10-16 F110真实队列预算失败/重试专项通过：实际PhotoEffectsRenderer首次有限预算拒绝，frameError出现且无派生文件，原片字节保持；编辑器改强度后queue.retry仍用入队锁定配方，预算恢复生成真实JPEG，尺寸不降、像素编码与锁定配方基准一致。f110-budget-queue-20261016.log 1/1 TEST SUCCEEDED、退出0。未真机压力/并发RSS验收；F110活动取消和资源峰值仍待，未核销，累计95项。


2026-10-16 F112地点规则第一阶段：photoFramePlace逐项按Android PhotoFrameLocationResolver.framePlace，国家码明确非CN不再按汉字回退；省/自治/开发区/社区排除，直辖市多语言回退、海外subAdmin保留为区域而不提升城市、大小写去重。PhotoFramePlaceTests含17组安卓行政层级案例及原有坐标/区县测试，f112-place-20261016.log 3/3 TEST SUCCEEDED、退出0。实际CLGeocoder尚未接调用，超时取消/32项语言TTL缓存及F111入口网络门控仍未修；F112不核销，F110资源专项仍未完成，累计95项。


2026-10-16 F112缓存阶段：PhotoFramePlaceCache以Entry区分nil失败命中和缺失，32项访问序LRU，成功86400秒/失败60秒，单调systemUptime；key含locale及固定POSIX四位坐标，CLGeocoder传preferredLocale，空city/region归失败缓存。f112-cache-20261016.log 5/5 TEST SUCCEEDED、退出0，覆盖第33项淘汰、访问提升、TTL精确边界、负缓存重试更新、语言隔离及17组行政层级回归。旧timeout/group等待问题与串行查询仍未修；F111网络门控/实际入口仍未接，未调用外部地理服务。F112未核销、累计95项。


2026-10-16 F112查询生命周期：移除TaskGroup等待worker.value，改actor串行请求/独立continuation与计时器，0…1秒预算包含排队，排队超时不查询/不缓存，已尝试超时或取消记负缓存，出队复查缓存，命中不等其他请求。请求UUID丢弃迟到结果；主线程CLGeocoder回调适配，取消调用cancelGeocode且启动前复检。首轮f112-lifecycle Swift6 coder隔离编译失败保留；fixed 8/8，最终f112-lifecycle-final-20261016.log 8/8 TEST SUCCEEDED、退出0。注入忽略取消的后端验证超时及时返回、活动取消释放、排队时限/重试、缓存旁路和迟到隔离；未访问真实地理服务，系统Geocoder取消只有接线与编译证据。F111门控/入口/刷新仍未接，F112完整核销与F111联动，累计95项。


2026-10-16 F111第一阶段：enriching改显式settings+allowed异步门控，字段未启用不查网络，允许前/查询后复检，旧city/region先清空而保留原EXIF；renderWithResolvedPlace默认拒绝，防未接网络时隐式联网。localPhotos normalized补清showAddress/showCity/showRegion（本轮仅编译，持久化专项待补）。f111-gating-20261016.log 5/5 TEST SUCCEEDED、退出0，含禁止/关闭不调用后端、查询中断网丢弃、禁止时缓存不泄漏及3项生命周期回归。仍缺排队出队前allowed复检、实际AP/互联网状态绑定、入口/控件/刷新，F111/F112均不核销，累计95项。


2026-10-16 F111出队复检：每个resolver Request保留allowed闭包，取到串行槽后、启动backend前重新检查；仅attempted请求完成/超时/取消写缓存，排队期间变为禁止不写负缓存。f111-dequeue-20261016.log 7/7 TEST SUCCEEDED、退出0：确定性两请求排队→block→前项释放，后项不调用backend且恢复重试成功；既有门控/取消回归通过。本地Store全部模板五个地点开关在update/重建均false，相机作用域当前配置不受影响。尚缺真实网络状态绑定、控件/入口与预览刷新，F111/F112未核销，累计95项。


2026-10-16 F111基础控件：PhotoEffectsEditorView在showLocationFields分支内新增城市/区域按钮，使用安卓现有三语资源，updateMetadata更新当前模板草稿；本地沿用隐藏。f111-controls-20261016.log TEST BUILD SUCCEEDED、退出0，仅编译未UI测试，不代表联网成片完成。已发起平台差异讨论：iOS NWPath无安卓VALIDATED直接等价，建议默认路径可用+AP严格禁止+Geocoder一秒失败处理、不增加探测；等待用户答复。还发现安卓预览城市/区域有三语假值、导出禁假值，现iOS resolved仍缺此规则，下一步可独立补；F111/F112不核销，累计95项。


2026-10-16 F111地点预览规则：photoFramePlaceLocale统一读取应用语言/系统回退供resolver及presentation；按安卓withPresentation提供非中文Light & Shadow City/Blue Hour District、简体光影市/蓝调区、Hant及TW/HK/MO光影市/藍調區。真实city/region trim优先，缺失时仅preview填充，两开关独立，导出不填假值。f111-preview-place-20261016.log 4/4 TEST SUCCEEDED、退出0，含7语言地区×开关组合、真实/空白混合及缓存回归；未UI/真实联网验证。网络平台方案仍等待回复，F111/F112未核销，累计95项。


2026-10-16 F113格式/呈现第一阶段：locationRow改安卓CoordinateFormat方向前置、度+三位小数分、总千分分钟先四舍五入进位；resolved/locationRow复用validPhotoFrameCoordinates，保留赤道/本初子午线单轴0，排除双零/非法。纠正旧测试期待DMS。f113-coordinates-20261016.log 4/4 TEST SUCCEEDED、退出0，含多城市/负值/进位/极值/零轴/非法及地点预览回归。JPEG相机GPS覆盖PhotoEffects.swift仍有双轴非零判断待修，地点独立行/去重未完成，F113不核销；用户已认可F111默认NWPath+超时平台方案，下一步可接网络，无须再问，累计95项。


2026-10-16 F111网络生产接线：PhotoFramePlaceAvailability应用级默认NWPathMonitor、初始禁止、路径/模式去重发布及stop代次隔离；ConnectionViewModel的state/cameraSession变化同步门控，按安卓CameraViewModel实际USB覆盖记忆AP规则，非USB AP禁止。ZTransferApp启动监听。TransferQueue.renderFrameFile在有边框及metadata时先共享resolver.enriching并读实时allowed，再渲染，JPEG仍使用原相机EXIF快照。f111-network-20261016.log 7/7 TEST SUCCEEDED、退出0，含默认阻止/AP/STA/USB/断网/stop模型及门控生命周期回归。真实NWPath回调/地理服务和队列成片未专项验收，预览接线/网络变化刷新/旧成片复用仍待处理；F111/F112不核销，累计95项。


2026-10-16 F111相机设置预览接线：对照Android SettingsScreen.kt 2969–3080及PhotoEffectsPreviewPrefetchTest，真实主预览/相邻滤镜预取接共享resolver，主图与对比图使用同份地点结果。可用性（仅地点开关启用）及应用语言加入完成图请求身份，变化清空预取/对比，不使纯滤镜中间图失效；元数据身份补city/region。保留安卓旧主图等待新图的行为，取消任务发布前复检。f111-preview-wiring-20261016.log 8/8 TEST SUCCEEDED、退出0，门控/排队取消迟到/多语言模型回归与生产编译通过；未UI、真实网络/Geocoder及实际页面刷新验收，不能据此声称全部链路验证。旧队列成片复用仍待，F111/F112未核销，累计95项。


2026-10-16 F111/F115地点成片复用：按Android PhotoFrameDestination.hasFrameFor，TransferQueue两处共用existingFrameURL在边框启用且城市/区域任一选中时拒绝文件名复用，允许离线成片后重新导出补地点；不删除或覆盖旧文件。f111-reuse-20261016.log 3/3 TEST SUCCEEDED、退出0，真实临时文件覆盖边框×城市×区域8种组合及旧文件保持，另含2项地点门控回归。未跑UI/真实Geocoder或队列完整端到端；F111和F115其他身份差异未核销，累计95项。


2026-10-16 F113 JPEG坐标链：PhotoEffectsJPEGEncoder按Android PhotoFrameExporter preserve EXIF的hasValidCoordinates规则复用validPhotoFrameCoordinates，保留单轴0、拒绝双0/越界/非有限相机覆盖。新增真实JPEG编码再ImageIO读回8组坐标/方向检查；f113-jpeg-gps-fixed-20261016.log 3/3 TEST SUCCEEDED、退出0，含原坐标格式/呈现回归。首轮f113-jpeg-gps新增测试误用JPEGEncoder类型名编译失败已修复并保留日志。未UI/真机验证，地点独立行/去重仍待，F113不核销，累计95项。


2026-10-16 F113通用地点行：locationRows按安卓frameLocationRows将trim/精确去重后的city·region与坐标+海拔独立，海拔固定POSIX格式；主要模板描述数组/通用metadata rows/editorial rows改接数组，不再将地点挤入坐标行。参数海报移除重复拼接地点，但其独立纬度/经度/海拔行仍待实现（Android ParameterPosterFrame.kt 83–96），不误报完整。f113-location-rows-20261016.log 6/6 TEST SUCCEEDED、退出0，覆盖地点去重/空白/独立行、坐标格式、真实JPEG及预览语言回归；未UI/各模板实际文本完整性验收。F113未核销，累计95项。


2026-10-16 F113参数海报地点行：对照Android ParameterPosterFrame.kt 83–96，新增parameterPosterLocationRows，地点/纬度/经度/海拔独立，海拔用空格m；抽取共用coordinateRows/placeRow/altitudeText避免两套格式器。横竖版drawParameterPoster都遍历独立行，竖版曝光起点避让上方文字、横版按剩余行区分配。f113-poster-rows-20261016.log 5/5 TEST SUCCEEDED、退出0，含单零轴/无效坐标/负海拔/缺失值及此前真实JPEG与通用行回归；仅模型测试与生产编译，不是所有模板长文本完整性或像素验收。动态画布测量归F116仍待，F113整体输出审计未结束，累计95项。


2026-10-16 F114新字段持久化接线：PhotoEffectsStore安卓兼容codec支持14/15/16/18字段，严格城市区域布尔/大写TEXT或LOGO/Int32数字，宽度背景归一化，保留旧9/10/12/13并跳过废弃address。encoder按新字段需求输出对应版本，修复JSON已保存但启动旧串覆盖导致新字段丢失。f114-persistence-20261016.log 3/3 TEST SUCCEEDED、退出0：全部模板双scope实际update→新Store恢复、相机地点与本地禁地点隔离、4种新格式及畸形输入拒绝。旧历史格式专项与默认值/重复条目/范围归一化全面回归待补，不直接核销F114；累计95项。

2026-10-16 F114开发侧核销：Store normalized统一宽度60…200/5步进、背景0…200及永久禁address；兼容decoder先归一日期时间再判默认，保持安卓重复条目规则。f114-boundaries-20261016.log 5/5 TEST SUCCEEDED、退出0，实际覆盖旧9/10/13迁移、新14/15/16/18、畸形新字段、重复非默认条目优先、Int32极值、内存与重建一致、全部模板双scope保存恢复和本地地点隔离；基础12字段是新格式共用路径及既有正常保存格式。此前f114-persistence 3/3亦通过。F114的生产保存/恢复闭环完成，累计96项；未实际杀进程/真机验收，F110–F113及F115等仍未核销，整体目标未完成。


2026-10-16 F115元数据身份阶段：androidMetadataFingerprintToken复用完整兼容codec，纳入宽度/背景/Logo/城市区域，并按安卓忽略沉浸宽度、非支持模板背景及隐藏日期时间格式。发现F114归一化漏背景10点步进，已纠正normalizePhotoFrameBackdropPercent并补73→70/75→80/极值测试；此前F114仅范围归一的证据不涵盖步进，现补正。f115-metadata首轮6项5断言失败为新增测试未写metadataByPreset，修正真实配方作用域后f115-metadata-fixed-20261016.log 6/6 TEST SUCCEEDED、退出0，身份区分/隐藏字段/步进与双scope持久化回归通过。F115布局/Logo/地点版本标记仍待，未核销，累计96项。


2026-10-16 F115版本身份：按Android PhotoFrameExporter添加archive-layout-v=2、location-v=2（含城市区域）、非沉浸measured-layout-v=6、毛玻璃glass-panel-v=2、Logo brand-logo-v=3，顺序与安卓一致。精确基准覆盖无水印mist/glass/color_archive及默认水印mist，更新过期旧文件名期望；配置差异与地点禁复用回归同轮通过。f115-versions首轮编辑缺换行编译失败；fixed轮4断言因测试默认水印开启却按off算摘要失败，明确fixture并独立Python SHA核算后final日志5/5 TEST SUCCEEDED、退出0。图片水印/无边框隐藏配置及真实旧成片不复用综合回归待收尾，F115未核销，累计96项。

2026-10-16 F115开发侧核销：图片哈希摘要按安卓规范小写/严格64hex，非法值用nullable join的null标记，隐藏文字参数不入图片身份。f115-final-20261016.log 8/8 TEST SUCCEEDED、退出0，含图片hash大小写/不同图片/末尾换行拒绝、无边框隐藏元数据、位置归一、磁盘旧版本文件拒绝与当前重名副本命中/原文件保持、地点禁止复用、精确版本名及配置差异。结合f115-metadata-fixed 6/6、versions-final 5/5，完整新字段与版本身份及复用规则开发侧闭环；未UI/真机输出像素验收（渲染完整性归其他项）。当前累计97项，整体目标未完成。


2026-10-16 F118控件功能阶段：PhotoFramePreset统一supportsWidthControl/supportsBackdropControls，沉浸隐藏宽度，背景只对mist/frosted/cinema/filmGallery/parameterPoster开放，背景滚轮步进10，宽度保留5；滚轮子树id按模板重建，对照Android key(preset)。成片身份复用同一模板规则。f118-controls-20261016.log 6/6 TEST SUCCEEDED、退出0，全部模板适用性及身份回归、生产界面编译通过；未UI手势取消验收。背景0高清代理/低模糊代理与遮罩强度实际渲染仍未修，F118不核销，累计97项。


2026-10-16 F118模糊阶段：背景代理按安卓0→1024、10…40→384、50…200→192，0跳过box blur，低强度半径按代理长边/192缩放，两轮盒式处理。photoFrameBackdropPreviewLongEdge穷举全部模板及0…200步进；真实1024黑白边界零模糊逐字节保持，10%存在中间过渡值且三个代理尺寸正确。f118-blur-20261016.log 2/2 TEST SUCCEEDED、退出0。仅装饰背景变化，未改原图尺寸；未UI/真机RSS和全部比例验收。遮罩仍是旧错误额外加黑逻辑待修，F118不核销，累计97项。


2026-10-16 F118遮罩阶段：按Android drawBackdrop/mask与drawCinemaBackdropTreatment，缩放62/66/92/132/150各可调alpha、round/clamp0…255，移除低于100额外加黑；filmGallery补影院基础层，parameterPoster复用影院分支。纠正开场假设：mist/影院/海报底部固定文字可读性暗化不随mask消失，保持安卓规则。f118-mask-20261016.log 4/4 TEST SUCCEEDED、退出0，包含alpha边界/50/100/200、三个深色模板真实输出0/50/100/200逐级变化，以及既有清晰零模糊/低强度回归。尚缺mist/frosted完整强度实际像素、代理合成阶段/长宽比与资源预算审计，F118未核销，累计97项；未UI/真机验收。


2026-10-16 F118/F110背景预算补强：原图分配预检按Android extraBackdropBytes增加>192背景代理两份4-byte预算，零模糊额外8MiB、低模糊384²×8；关闭边框不增加。零模糊路径延后像素数组分配，直接返回清晰proxy，避免无用4MiB数组。f118-budget-20261016.log 5/5 TEST SUCCEEDED、退出0，实际render有限预算拒绝所报required精确差额/无框不变，原真实清晰边界、低模糊与深色三模板遮罩回归通过。不是实际RSS测量，浅色两模板及合成阶段/比例仍待，F118和F110未核销，累计97项。


2026-10-16 F118全部背景模板输出证据：扩展真实render遮罩0/50/100/200覆盖五种支持模板，mist/frosted在黑底逐级提亮，cinema/filmGallery/parameterPoster在白底逐级变暗；三档代理在横/竖/全景9组合中长边及最小短边96符合安卓。f118-all-presets-20261016.log 6/6 TEST SUCCEEDED、退出0，包含原零模糊逐字节保持、低模糊过渡及预算回归。未像素对照安卓完整渐变、代理合成阶段及实际峰值；F118未核销，累计97项。下一步影院底层处理应在非零模糊proxy上先合成再放大，当前在最终画布处理，需继续核对。


2026-10-16 F118影院合成阶段：提取drawCinemaBackdropTreatment及cinemaBackdropProxy，非零模糊影院/胶片画廊/参数海报在小proxy上先合成再一次放大，零模糊在目标背景上处理；影院固定渐变按安卓0.62起点/0.60裁剪。f118-composition-20261016.log 7/7 TEST SUCCEEDED、退出0，proxy尺寸/源PNG不变/0遮罩保固定渐变、全部模板强度及尺寸预算回归通过。发现剩余边界：零模糊仍用最小短边96，安卓零模糊直接centerCrop不适用此限制，超宽/高图需修并验；未真实峰值/所有模板像素同一性，F118不核销，累计97项。

2026-10-16 F118开发侧核销：零模糊代理取消96最小短边，保持目标比例；96限制仅用于有模糊的安卓盒式路径。f118-aspect-20261016.log 8/8 TEST SUCCEEDED、退出0，64:1及1:64两端双色真实像素逐字节保持，横竖/全景/极端15档代理尺寸，以及全部五模板遮罩强度、清晰/低模糊、影院proxy合成源保持、预算差额回归。结合controls 6/6模板适用性与步进，完成F118功能侧实现与验证。用户明确跳过UI测试，模板切换滚轮取消有id重建接线但未实测手势；未精细视觉对齐及真机峰值，资源压力仍归F110未完成。累计98项，整体目标未完成。


2026-10-16 F119品牌控件阶段：PhotoFrameMetadataSettings.cycleBrandStyle按安卓关闭→文字→Logo→关闭，关闭重置TEXT，关闭状态旧LOGO再次点击回文字；brandControlLabelKey按未选中品牌/选中文字/Logo使用安卓资源。PhotoEffectsControls原品牌按钮接三态，移除额外Logo拨轮。f119-brand-control-20261016.log 4/4 TEST SUCCEEDED、退出0，遍历全部模板×两种旧样式，每次比对完整metadata保持其他字段，另含双scope新旧持久化回归；未UI测试。各模板Logo绘制/缺Make从model识别仍未补齐，F119不核销，累计98项。


2026-10-16 F119品牌推断阶段：对照安卓PhotoFrameMetadataSettings.withPresentation及PhotoFrameExporter.normalizeCameraMake，导出Logo模式在Make缺失时使用型号推断品牌；文字模式保留原行为，隐藏品牌仍清空。补Nokia/DJI精确或空格前缀规范化。f119-inference-final-20261016.log 4/4 TEST SUCCEEDED、退出0，含推断/隐藏/文字模式、型号去重、Nokia/DJI边界及既有Logo回退；首轮测试误写let字段编译失败已修正，未UI测试。所有模板Logo接入仍待补齐，F119不核销，累计98项。


2026-10-16 F119身份阶段：对照安卓useBrandLogo及normalizeCameraMake/Model，photoFrameBrandIdentity改为按已应用presentation的规范厂商判定Logo并去除型号重复厂商；无Make/未知/不支持厂商不可从型号复活Logo。品牌画廊传递已解析身份，不再解析显示文本。f119-identity-20261016.log 6/6 TEST SUCCEEDED、退出0，遍历17品牌及重复型号、隐藏/未知/Canon、先前推断和回退。未UI测试；各模板统一Logo绘制、画廊Logo模式型号与水印布局仍待补齐，F119不核销，累计98项。


2026-10-16 F119标准模板测量阶段：依据安卓FrameBrandLogo.identityLogo及标准FrameTextRun，将向量前缀加入PhotoFrameTextRow，同一bounds/width/fitting/baseline变换绘制Logo与后续型号。Renderer.frameIdentityRow共享厂商资格、路径与测量，标准drawAndroidMetadata接入设置，Logo参与水印行布局。f119-measured-20261016.log 7/7 TEST SUCCEEDED、退出0；新增17品牌真实离屏PNG与文字模式差异及长型号缩放边界，保留身份/推断回归。未UI测试，未验证各完整模板端到端输出；其他模板仍需接入，F119不核销，累计98项。


2026-10-16 F119铭牌/沉浸阶段：铭牌主厂商行使用公共Logo测量，保留型号/镜头副行；沉浸标题将品牌Logo、型号、分隔符和自动水印纳入同一行测量与缩放，采用安卓1.30 Logo比例。f119-template-20261016.log 8/8 TEST SUCCEEDED、退出0；新增完整render的mist/cinema/minimal/frosted/plaque/immersive六模板×Nikon/Sony/Canon，带水印，验证支持品牌文字/Logo差异、不支持品牌相等、隐藏品牌两模式相等；另保留17品牌行绘制和长型号边界回归。未UI测试，其他编辑模板及品牌画廊仍待补齐，F119不核销，累计98项。


2026-10-16 F119经典签名/胶片底片阶段：cameraIdentityRow复用既有向量行，文字/不支持品牌保留文本回退；经典签名接1.55比例，底片接1.20比例及0.46列宽缩放，型号与Logo共同测量。f119-editorial-20261016.log 8/8 TEST SUCCEEDED、退出0，完整渲染扩大至八模板×Nikon/Sony/Canon，含水印、隐藏品牌两样式相等，另17品牌行回归。批量脚本曾被自动审批以疑似截断文件拒绝，确认文件完整后改逐段apply_patch成功，未执行被拒脚本。未UI测试；galleryMat/colorArchive/filmGallery/filmEdge/parameterPoster及品牌模板布局仍待接入或补齐，F119不核销，累计98项。


2026-10-16 F119画廊阶段：galleryMat首身份行接公共Logo行与同区水印布局；filmGallery窄条接1.15比例，按安卓580/30设计宽高阈值判断，放不下则移到下方信息区，不继续缩小窄条型号。f119-mat 8/8、f119-film-gallery 8/8、最终f119-film-fallback-20261016.log 9/9 TEST SUCCEEDED、退出0。完整渲染覆盖十模板×Nikon/Sony/Canon含水印与隐藏品牌，另长短型号文字/Logo分流验证。未UI测试；日志系统字体转CTFont存在回退提示，留F116核查；filmGallery日期分流尚待完整布局核查。F119的colorArchive/filmEdge/parameterPoster与品牌模板仍待补，累计98项未变。


2026-10-16 F119色彩档案阶段：colorArchive身份行接公共Logo测量，1.30比例，与型号、镜头、参数、日期地点共同布局；对照安卓identity仅品牌大写，修复型号也被强转大写。f119-archive-20261016.log 9/9 TEST SUCCEEDED、退出0，完整render扩大至十一模板×Nikon/Sony/Canon，带水印，隐藏品牌和不支持品牌相等回退，另17品牌行与长型号分流回归。未UI测试；F119 filmEdge/parameterPoster及品牌模板布局尚未完成，F116字体回退与统一测量待核查，累计98项。


2026-10-16 F119胶片边框阶段：依据安卓FILM_EDGE caption按品牌+型号/参数尾部组成公共Logo行，超过列宽拆身份行与参数行，地点保持独立行，不删字段。f119-film-edge-20261016.log 10/10 TEST SUCCEEDED、退出0，新增两种样式长短标题分流/宽度检查，完整render覆盖十二模板×Nikon/Sony/Canon、带水印与隐藏品牌。未UI测试；长文本统一换行及动态画布仍F116未完成，F119参数海报/品牌模板尚待补，累计98项。


2026-10-16 F119/F120参数海报阶段：对照ParameterPosterFrame.posterGroups，品牌行改normalizedMake，与型号行独立不重复；共用draw取消逐字符删尾，改完整CTLine测量/缩放；品牌行接公共Logo1.65比例，横竖版共用。f119-poster-20261016.log 10/10 TEST SUCCEEDED、退出0，完整横版render覆盖十三模板×Nikon/Sony/Canon含水印/隐藏品牌回退，另既有17品牌行与长标题分流。未UI测试；本轮未专项验证竖版完整输出，动态分组与画布扩展仍F120未完成、字体回退及长文换行仍F116未完成，品牌两模板尚待收尾，F119不核销，累计98项。


2026-10-16 F119品牌画廊阶段：drawBrandGalleryBand移除独立固定位置Logo，改品牌+型号公共行（1.55）与水印一起测量/缩放/布局，补回Logo模式遗漏型号。f119-brand-gallery-20261016.log 10/10 TEST SUCCEEDED、退出0，完整render扩大十四模板×Nikon/Sony/Canon，带水印与隐藏品牌两模式相等；未UI测试。品牌内嵌独立Logo避让、品牌画廊文字品牌大写及型号变化独立输出断言、竖版与长文仍待收尾验证，F119不核销，累计98项。


2026-10-16 F119品牌内嵌阶段：依据安卓品牌测量plan，将品牌Logo与型号公共行传入drawBrandRows，与镜头参数共同计入区域高度/宽度及placeBrandMetadataBlock水印避让，删除独立固定位置Logo绘制。f119-inset-20261016.log 10/10 TEST SUCCEEDED、退出0；完整render改遍历PhotoFramePreset.allCases，全部十五模板×Nikon/Sony/Canon，带水印及隐藏品牌回退。未UI测试；横竖版专项、型号变化独立输出、品牌画廊文字品牌大写、长文真实避让及安卓逐行换行仍待收尾，F119不核销，累计98项。


2026-10-16 F119型号/大小写阶段：经典签名与品牌画廊的文字回退仅品牌大写，型号保留原文，对照安卓identity。f119-orientation-20261016.log 11/11 TEST SUCCEEDED、退出0；新增参数海报/品牌内嵌/品牌画廊横竖版、Logo+水印开启、A7/A9型号变化真实PNG差异验证，另全部十五模板Nikon/Sony/Canon隐藏与Logo回归。未UI测试；长文换行/动态画布及实际避让仍F116/F120和F119关联未完成，累计98项。


2026-10-16 F116字体阶段：metadataText保留UIFont对象供CoreText排版，不按fontName重建CTFont，修复.SFUI等系统内部名称查找回退TimesNewRoman导致测量失真。f116-font-20261016.log 12/12 TEST SUCCEEDED、退出0；新增正常/黑体/斜体/等宽系统字体实际CTLine宽度及字形高度对照，全部十五模板品牌回归及三模板横竖型号变化通过；完整日志不再出现Client requested name警告。未UI测试，动态画布/长文换行/实际避让仍待完成，F116/F119/F120不核销，累计98项。


2026-10-16 F116换行阶段：对照安卓FrameTextWrapping，新增PhotoFrameTextRow.wrappedDescriptions，CoreText测量后按完整Character边界截取、至少半行时优先自然换行，trim/跳空段，保留属性；品牌模板镜头/参数行接入，所有行参与总高度布局。f116-wrap-20261016.log 13/13 TEST SUCCEEDED、退出0，新增极窄宽度中文/组合音标/ZWJ家庭/旗帜/肤色表情/英文完整字素保留、CRLF空段trim，保留全模板及横竖型号回归。未UI测试；其余模板换行、身份长行拆分、动态画布/长文水印避让仍未完成，F116/F119不核销，累计98项。


2026-10-16 F116标准描述换行阶段：字符边界二分查询+Set资格判断，短段落测量后直接返回，保留属性；标准模板镜头/参数/地点接公共换行，取消按最宽描述统一压缩。对照安卓标准addDescription。f116-standard-wrap-20261016.log 14项中13通过，唯一失败为新增测试把每组4字素误计3，实际1024完整字素且拼接保真；修正测试期望后f116-wrap-count-20261016.log单项1/1 TEST SUCCEEDED、退出0，生产代码未再修改。含长Unicode、短路径属性、全模板和横竖型号回归，未UI测试。身份/水印换行及动态画布仍待实现，F116/F119不核销，累计98项。


2026-10-16 F116标准身份阶段：frameIdentityRows按安卓标题列宽判断，短身份合并，长身份拆品牌与型号；Logo独立，文字/型号按完整字素换行，标准模板调用。f116-identity-wrap-20261016.log 15/15 TEST SUCCEEDED、退出0，新增文字/Logo长型号拆行、原字号CTLine宽高一致性验证，保留长Unicode与全模板/横竖型号回归。未UI测试；最终绘制仍受旧固定信息区高度限制，测量画布扩展与水印换行待补，F116/F119不核销，累计98项。


2026-10-16 F116标准水印阶段：对照安卓bandWatermark addDescription，标准模板文字水印接公共换行，起始索引之后所有行保持左右对齐及阴影，不仅首行。f116-watermark-wrap-20261016.log 16/16 TEST SUCCEEDED、退出0，新增四标准模板300%粗体长水印真实输出左右位置差异、尾部ABC/XYZ变化不丢失，保留全部模板及换行回归。未UI测试；固定信息区高度仍会整体缩放，下一步共享测量plan驱动画布尺寸，F116/F119仍未核销，累计98项。


2026-10-16 F116共享测量阶段：抽StandardMetadataPlan(rows/watermarkIndex/inkHeight)，实际drawAndroidMetadata由共享plan绘制，供后续预算与画布尺寸使用，未提前改变输出尺寸。f116-plan-20261016.log 17/17 TEST SUCCEEDED、退出0，新增长型号+300%水印的测量行数/真实墨迹高度超过固定区域及多行水印索引检查，保留全模板与长文回归。未UI测试；预算目前仍固定makeLayout，下一步必须同份可见metadata和测量plan同时驱动画布/预算，F116/F119不核销，累计98项。


2026-10-16 F116标准画布阶段：render一次解析可见metadata并准备布局，四标准模板expandedStandardLayout根据共享plan墨迹与行距增加底部信息区，照片rect不变；预算与drawDecoration读取同一preparedLayout，避免扩大后漏算canvas。f116-canvas-20261016.log 26/26 TEST SUCCEEDED、退出0（18品牌/布局+8背景），新增四模板长短型号真实输出宽度相同、高度增加、availableMemory=0拒绝所需预算同步增大，保留背景预算/像素与全部模板。未UI测试；当前高度按既有iOS行距/6%padding，安卓精确padding与宽扩展、previewLongEdge约束、极端尺寸及其他模板动态布局仍待核对，F116/F119不核销，累计98项。


2026-10-16 F116预览尺寸阶段：对照安卓renderFrame calculateMeasuredFrame.fitPreview，非沉浸模板先makeLayout+内容扩展再统一缩放canvas/photo/metadataTop到目标长边，允许放大；沉浸保持专用preview路径。f116-preview-fit-20261016.log 19/19 TEST SUCCEEDED、退出0，新增四标准+参数海报长型号128/512实际预览长边、导出画布比例检查，保留所有模板及预算回归。未UI测试；绘制当前仍重算缩放后文字plan，须复用原测量避免换行边界漂移；旧makePreviewLayout非沉浸分支待清理，精确测量/其他模板动态画布仍未完成，累计98项。


2026-10-16 F116测量复用阶段：Layout携带StandardMetadataPlan，expandedStandardLayout保存实际行对象，fitPreviewLayout同步缩放plan的行尺寸，标准drawAndroidMetadata直接消费preparedPlan，避免预览按缩放字体重新换行。对照安卓fitPreview textLayoutScale。f116-plan-scale-20261016.log 20/20 TEST SUCCEEDED、退出0，新增0.128/0.512/2倍行数/水印边界/墨迹高度/行宽基线线性缩放检查，保留全模板、实际预览长边比例、动态画布预算。未UI测试；安卓精确间距/宽度扩展、极端长文与其他模板动态布局仍未完成，累计98项。


2026-10-16 F116预览清理：删除makePreviewLayout已不可达的非沉浸固定画布分支，只保留makeImmersivePreviewLayout原有不放大逻辑，非沉浸统一测量后fitPreviewLayout。f116-preview-cleanup-20261016.log专项1/1 TEST SUCCEEDED、退出0，四标准+参数海报128/512长内容实际预览长边及导出比例通过。未UI测试，未增加核销项，累计98项。


2026-10-16 F116胶片日期阶段：依据安卓FILM_GALLERY stripDate的720/30设计宽高限制，filmStripDateRow共享测量用于窄条绘制及bandRows分流，过长日期进入信息区，空日期不补造。f116-film-date-20261016.log 2/2 TEST SUCCEEDED、退出0，含160/1000宽度短长日期/空值及全部十五模板品牌实际render回归。未UI测试，日期分流下方信息区动态高度与换行仍待补齐，F116/F119未核销，累计98项。


2026-10-16 F116编辑描述阶段：drawMetadataRows普通描述与文字水印接公共换行，水印起始索引后全部行继承对齐和阴影，作用于画廊卡纸/胶片画廊/经典签名共用信息区。对照安卓descriptions.wrapFrameDescription。f116-editorial-wrap-20261016.log 2/2 TEST SUCCEEDED、退出0，新增三个模板长镜头末尾AAA/ZZZ变化真实输出差异（同时300%水印），及全部十五模板品牌完整render回归。未UI测试；此组信息区仍固定高度导致必要时整体压缩，下一步需共享plan及动态画布，F116/F119未核销，累计98项。


2026-10-16 F116编辑测量阶段：抽editorialMetadataPlan，drawMetadataRows消费共享结果；StandardMetadataPlan更名MetadataRowsPlan供标准/编辑复用，保持行对象/水印索引/缩放能力。f116-editorial-plan-20261016.log 2/2 TEST SUCCEEDED、退出0，三个编辑模板零高度区域先测长描述+水印真实高度与行数、缩放边界，及长镜头末尾实际输出通过。未UI测试，本轮尚未接编辑画布扩展，F116/F119未核销，累计98项。


2026-10-16 F116画廊扩展阶段：galleryMat预先editorialPlan、固定按photo宽度计算gap、增加底部区域，layout携带plan/gap并随预览缩放，预算共用preparedLayout。编辑Logo身份改公共超宽拆行，保留模板Logo比例。首轮及第二轮3项中预览/长镜头输出通过，尺寸预算项因40次型号仍可放进画廊原留白失败；改160次溢出样本后f116-mat-overflow-20261016.log单项1/1 TEST SUCCEEDED、退出0，生产代码未再修改。未UI测试；当前仅纵向扩展，安卓galleryMat最终保持方形及水平留白重排仍需补齐，不能视作画廊完成；累计98项，F116/F119未核销。


2026-10-16 F116画廊方形扩展：对照安卓PhotoFrameExporter画廊布局，内容增长后canvas取宽高最大值，横向新增留白均分，纵向新增留白按45%/55%分配；照片矩形只平移，缓存测量plan随预览缩放。f116-mat-square-20261016.log三项3/3 TEST SUCCEEDED、退出0，覆盖方形尺寸与内存预算增长、预览长边及导出比例、长描述尾部输出差异。未运行UI测试；照片原像素保持尚无专项像素证据，其他模板动态布局及画廊测量宽度仍待核对。F116/F119不核销，累计98项。


2026-10-16 F116经典签名描述区：对照Android PhotoFrameExporter.kt CLASSIC_SIGNATURE描述测量及共用contentHeight扩展底部逻辑，iOS抽出共用描述行与区域，导出前缓存editorialPlan并按内容扩展底部，预览缩放同一plan。f116-classic-expand-20261016.log 2/2 TEST SUCCEEDED、退出0，验证160次长镜头描述扩展及512预览比例，三个编辑模板长描述尾部输出回归通过。未UI测试；经典签名顶部身份仍固定区域，完整测量布局尚未完成，F116/F119未核销，累计98项。


2026-10-16 F116经典签名标题：对照安卓measuredTemplate identity超宽拆行及top按header高度扩展，新增classicHeaderPlan缓存并随预览缩放；品牌文字保持大写、型号保留原大小写，超宽拆品牌和型号行，增加顶部空间并平移照片/metadataTop，照片尺寸不变。f116-classic-header-20261016.log 3/3 TEST SUCCEEDED、退出0，覆盖文字/Logo长标题的多行与画布增长、预览比例，底部长描述及十五模板品牌显隐回归。未UI测试；原图逐点像素保持、超长标题内存预算专项及其他模板测量仍待补齐，F116/F119未核销，累计98项。


2026-10-16 F116胶片画廊扩展：对照Android FILM_GALLERY窄条身份/日期溢出进入信息区及共用contentHeight逻辑，抽filmGalleryPlan/区域，导出前缓存完整信息行和水印行，按实测高度扩展底部，预览缩放同一plan，内存预算使用扩展画布。f116-film-expand-20261016.log 3/3 TEST SUCCEEDED、退出0，胶片画廊新增长型号画布/预算增长与预览长边/比例覆盖，三个编辑模板长描述尾部回归通过。未UI测试；窄条品牌/日期绘制仍重新测量，需缓存以严格保持预览显隐判断；其他模板和原像素验证仍未完成，F116/F119未核销，累计98项。


2026-10-16 F116胶片窄条预览一致性：新增FilmStripPlan，在原图布局阶段测量身份/日期并保存可选行；信息区回退和窄条绘制共用同一决策，预览仅缩放已测行，避免不同字体尺寸重新测量导致重复或缺失。依据安卓FILM_GALLERY stripIdentity/stripDate一次测量及textLayoutScale。f116-film-strip-plan-20261016.log 3/3 TEST SUCCEEDED、退出0，四种长短品牌/日期组合在0.01/0.128/0.512/2缩放下保持位置决策与墨迹比例，实际预览比例及十五模板品牌显隐回归通过。未UI测试，F116其余模板完整测量/原像素证据仍待补齐，F116/F119未核销，累计98项。


2026-10-16 F116胶片边缘长信息：对照Android FILM_EDGE短caption单行、超宽identity+descriptions及location换行路径，iOS移除超宽整行缩小，复用身份拆行/描述换行；原图布局缓存editorialPlan并按内容增加底部，预览缩放同一plan。f116-film-edge-expand-20261016.log 3/3 TEST SUCCEEDED、退出0，胶片边缘加入长型号画布/预算增长、预览长边/比例和长镜头尾部输出覆盖。未UI测试；其他模板测量和原像素专项仍未完成，F116/F119未核销，累计98项。


2026-10-16 F116胶片底片信息缺失修复：对照Android FILM_NEGATIVE first描述列表及170参考单位底部留白，补绘此前遗漏的镜头/参数/日期/地点，文字水印并入共享换行plan（不再单行限字号），原图测量后扩展底部，预览复用缩放plan。f116-negative-info-20261016.log 3/3 TEST SUCCEEDED、退出0，底片新增160次长镜头画布增长及预览比例，描述变化输出与十五模板品牌显隐回归通过。输出差异测试受稳定帧号影响，不能单独证明每个字符已绘制；顶部品牌固定区域、逐字段渲染证据/原像素证据及其他模板仍待补齐。未UI测试，F116/F119未核销，累计98项。


2026-10-16 F116底片逐字段证据补强：新增实际render后裁取下半画布测试，排除顶部身份及稳定帧号hash变化，逐项验证镜头/焦距/光圈/日期/坐标/海拔/城市/地区八类字段开启时底部输出变化、关闭时输出相同。f116-negative-fields-20261016.log 1/1 TEST SUCCEEDED、退出0（八类字段×显隐），补足此前全图差异可能由帧号引起的证据不足。未UI测试；此测试不证明任意长文本每个字形均完整或原照片像素保持，顶部标题与其他模板待补齐，F116/F119未核销，累计98项。


2026-10-16 F116共用测量整理及待办纠正：抽expandingEditorialBand统一五个编辑模板的缓存行/间距/底部高度扩展，保留各模板contentTop、画廊方形和经典顶部独立逻辑。f116-shared-band-20261016.log 3/3 TEST SUCCEEDED、退出0，尺寸预算增长、经典/底片长描述与预览比例回归通过。重新阅读Android drawFilmNegativeDecoration（4090起）确认顶部身份本就fittedEditorialPaint固定0.46宽度，因此撤销此前“底片顶部应改动态标题”的待办推断；仍需核对文本分隔符等实际行为差异，不擅自改为换行。未UI测试，其他模板/原像素等未完成，F116/F119未核销，累计98项。


2026-10-16 F116彩色档案测量：对照Android COLOR_ARCHIVE身份/镜头/参数/日期地点独立字体与描述换行逻辑，抽colorArchivePlan，普通长信息换行、Logo身份超宽拆行，测量后按文字区0.76高度比例扩展底部，缓存plan随预览缩放，文字区保持在色板左侧。f116-archive-expand-20261016.log 2/2 TEST SUCCEEDED、退出0，长型号画布/预算增长及预览比例通过。未UI测试；文字品牌身份目前整段换行而非安卓分品牌/型号行，精确列宽及逐字段输出仍待核对，F116/F119未核销，累计98项。


2026-10-16 F116彩色档案身份拆行：公共frameIdentityRow/Rows增加默认false的uppercaseBrand，彩色档案所有身份（文字/已知Logo/未知品牌回退）复用同一组合行→超宽拆品牌与型号路径，品牌大写、型号原样，其他调用默认不变。依据Android measuredTemplate identity。f116-archive-identity-20261016.log 2/2 TEST SUCCEEDED、退出0，长型号尺寸预算增长和十五模板品牌显隐回归通过；未新增逐字形大小写输出断言，不将此回归夸大为全部文本证明。未UI测试，精确列宽及逐字段/原像素等仍待补齐，F116/F119未核销，累计98项。


2026-10-16 F116品牌画廊扩展：对照Android BRAND_GALLERY identity拆行、显式band签名优先和contentHeight扩展，新增BrandGalleryPlan保存行及前置水印行数，长身份拆行、底部文字水印换行且使用sizePercent（此前固定0.019忽略字号），每行继承对齐/透明度/阴影，动态底部及预览复用plan。f116-brand-gallery-expand-20261016.log 3/3 TEST SUCCEEDED、退出0，长型号尺寸预算增长、预览比例及十五模板品牌显隐回归。水印字号与多行对齐专项输出仍待补证，不宣称全部完成；未UI测试，F116/F119未核销，累计98项。


2026-10-16 F116品牌画廊水印专项：大字号长水印实际输出加入brandGallery，左右对齐及尾部ABC/XYZ差异通过。新增100/300字号、预览比例和关闭水印不变性测试；前两轮错误假设字号增加必然扩展画布，实测普通/窄边框均容纳24字符限长后的文本，故改用实际PNG变化验证字号，不修改生产代码来迎合断言。首轮brand-watermark中对齐尾部项通过；最终f116-brand-watermark-output-20261016.log 1/1 TEST SUCCEEDED、退出0，字号输出/预览/关闭不变性通过。不将两次失败记为成功，不声称水印必然扩展或全部字形证明。未UI测试，F116/F119未核销，累计98项。


2026-10-16 F116铭牌AUTO文字水印：对照Android resolvedWatermarkPosition(PLAQUE,AUTO)=LEFT及bandWatermark，修复iOS直接排除AUTO导致水印消失；自动映射左侧后进入已有band绘制。f116-plaque-auto-20261016.log 1/1 TEST SUCCEEDED、退出0，真实输出AUTO==LEFT且不同于关闭水印。审查期间关于右栏第四行丢失的初步判断已撤回：当前locationRows最多两行，加参数日期共三行；临时动态slots改动已还原。铭牌左右列独立测量、左签名归属左列及长内容扩展仍未完成，未UI测试，F116/F119未核销，累计98项。


2026-10-16 F116铭牌身份规则：抽plaqueIdentityLabels对照Android PLAQUE primary/secondary，使用当前可见metadata原始型号而非再次normalizedModel，主标题brand大写→model→lens；副标题仅brand存在且model不与brand忽略大小写相等时加入model，lens与primary严格比较去重。f116-plaque-labels-20261016.log 2/2 TEST SUCCEEDED、退出0，六组原始EXIF/空白/大小写去重/回退样本与十五模板实际品牌显隐回归通过。铭牌独立列测量和长内容扩展尚未完成，未UI测试，F116/F119未核销，累计98项。


2026-10-16 F116铭牌独立列：对照Android PLAQUE rightAvailable/combined拆分、primary-secondary与plaqueLeftSignature，新增PlaquePlan两列及下方签名独立测量，左签名归左列，参数日期按宽度合并或分行，各描述换行，按max列高+下签名扩展画布；预览缩放缓存plan。移除旧三slot配对缩小绘制。f116-plaque-plan-20261016.log 3/3 TEST SUCCEEDED、退出0，铭牌长型号画布/预算增长、预览比例、AUTO==LEFT且可关闭通过。左右列高不同时签名归属、超宽单字/Logo水平扩展及原像素验证仍需专项，未UI测试，F116/F119未核销，累计98项。


2026-10-16 F116铭牌列高签名专项：新增右栏60次长参数高于左栏的测量样本，断言左签名归left且无footer、contentHeight由右列决定；右签名转footer并增加总高，0.128/0.512/2缩放保持列行数/签名索引/高度/右列位置。f116-plaque-columns-20261016.log 2/2 TEST SUCCEEDED、退出0，模型专项及十五模板品牌实际render回归通过。这是列结构/测量验证，不等同于逐像素签名区域定位证明；超宽单字/Logo水平扩展与原像素等仍待补齐。未UI测试，F116/F119未核销，累计98项。


2026-10-16 F116原图内部像素：新增80x60逐像素标记图，真实导出九模板后查找48x28原始内部RGBA完整子矩阵。首轮整图匹配五模板失败（边线/圆角/照片文字），改无叠加内部区域后仅MINIMAL失败。审查修复标准模板照片圆角误用扩展信息区高度，改用基础布局高度并按预览比例缩放；该修复后内部仍失败，进一步修复standardLayout照片原点小数坐标导致插值，原尺寸原点floor到整数像素。最终f116-aligned-photo-pixels-20261016.log 2/2 TEST SUCCEEDED、退出0，九模板内部像素精确相等及预览比例通过。前述失败均保留，不以内部样本冒充完整边缘/任意尺寸证明；奇偶尺寸/方向/更多模板仍需验证。未UI测试，F116/F119未核销，累计98项。


2026-10-16 F116奇偶尺寸像素：内部原图样本扩为80x60/81x61/61x81九模板共27次导出，首轮仅GALLERY_MAT81x61失败，定位方形扩展extraWidth/2导致半像素平移。画廊最终照片原点ceil到整数并按实际纵向增量更新metadataTop，保持方形和原图尺寸，奇数留白两侧最多差1像素。f116-mat-pixel-alignment-20261016.log 2/2 TEST SUCCEEDED、退出0，27组内部RGBA精确匹配及长内容方形/预算回归通过。该证据不涵盖EXIF方向/完整边缘/全部模板，未UI测试，F116/F119未核销，累计98项。


2026-10-16 F116宽度设置：再次核对台账，修复标准四模板和铭牌makeLayout忽略widthPercent。铭牌缩放底部基础留白；标准模板按基础照片四侧留白缩放并ceil到整数，原图宽高不变，内容扩展仍按测量下限。依据Android measuredFrame的percent边距及measuredTemplate bottom。f116-standard-width-20261016.log 3/3 TEST SUCCEEDED、退出0，五模板60/100/200尺寸单调、九模板27组原图内部像素及预览比例回归。标准字体当前仍依赖扩宽后canvasWidth，需继续对齐安卓固定reference.designWidth；参数海报宽度/测量仍未完成，不据局部通过核销F116。未UI测试，累计98项。


2026-10-16 F116标准字号基准：对照Android reference.designWidth独立于边框percent，标准四模板预先用standardLayout(photo.size)基础宽度测字并保存standardReferenceWidth；绘制行间距复用该宽度，预览按最终scale缩放，避免边框扩大同时放大字体。f116-reference-font-20261016.log 3/3 TEST SUCCEEDED、退出0，边框档位/长内容画布预算/预览比例回归通过；尚未新增逐字形跨档位墨迹相等专项，窄边框gap系数/玻璃区宽度/完整参考几何仍待对照。未UI测试，F116未核销，累计98项。


2026-10-16 F120曝光参数规则：完整阅读ParameterPosterFrame.kt groups/measure/composition及对应测试，抽parameterPosterExposure共用FL/F/ISO/S顺序、空白过滤和锚定前缀正则^f/?、^ISO\s*，修复F2.8未去F及全局replace误删中间f/和ISO。f120-exposure-prefix-20261016.log 2/2 TEST SUCCEEDED、退出0，正常/嵌入前缀/空字段模型样本及海报品牌模板横竖渲染回归通过。海报独立语义组一次测量、宽度percent、长内容扩栏仍未实现，F120/F116未核销；未UI测试，累计98项。


2026-10-16 F120海报测量接入：对照ParameterPosterFrame.kt semantic groups/minimumWidth/measure/composition，新增PosterSpec/MeasuredRow/Column；身份、曝光、地点分组，竖版identity→exposure→location侧栏，横版identity+location与exposure双列。文本换行、曝光标签值不截断并参与最小列宽，percent缩放留白/间隔，内容决定横向扩栏或上下/底部扩容，原图整数原点与原尺寸，预览只缩放缓存行列。删除旧逐段固定区域绘制；基础标签可用，装饰框细样式按用户范围不复刻。f120-measured-poster-20261016.log 3/3 TEST SUCCEEDED、退出0，长型号画布预算增长、预览比例、横竖品牌型号实际输出通过。空组窄边框/长曝光值水平扩展/极端比例和海报原像素尚需专项，不核销F120/F116；未UI测试，累计98项。


2026-10-16 F120海报边界专项：新增横160x120/竖120x160/极宽240x40/极高40x240×60/100/200共12组长曝光值检查，验证完整值驱动横向扩栏和256预览比例；原图内部RGBA测试纳入海报，十模板×三尺寸共30组。f120-poster-boundaries-20261016.log 2/2 TEST SUCCEEDED、退出0。此处证明宽度扩展和内部保真，不冒充所有尾部字符已绘制；空组侧栏收缩/全字段尾部与取消预算链仍需核对。未UI测试，F120/F116未核销，累计98项。


2026-10-16 F120空组与尾部专项：空竖图120x160按Android空栏渐进释放公式核对60/65/95/100/200五个输出宽度152/169/264/279/332；型号/镜头/曝光值/城市四类长字段分别改变末尾AAA/ZZZ，横竖八组实际输出不同。f120-empty-tail-20261016.log 2/2 TEST SUCCEEDED、退出0。复核F120验收尚需长品牌、全部地点与相同city-region不重复的联合60/200覆盖，不能以当前八组代替全部要求；未UI测试，F120/F116未核销，累计98项。

2026-10-16 F120开发侧核销：f120-full-fields-20261016.log 1/1 TEST SUCCEEDED、退出0；横竖×60/200四组合，每组合长品牌/型号/镜头/城市/地区尾部与纬度/经度/海拔八字段输出变化，同名city-region与仅city输出精确相同。完成审计：生产仅一次PosterSpec分组→measure→缓存列绘制，无旧删尾/固定槽位，品牌与型号各一处、地点独立；此前measured-poster3/3、poster-boundaries2/2（12组长曝光+30组内部像素）、empty-tail2/2（五空栏宽度+八长尾输出）、exposure-prefix2/2共同覆盖验收。F120内容功能开发侧已修复，累计99项；精细样式/动画按用户范围延期，未UI/真机验收。F116全模板布局与F119品牌整体仍未核销，不能由F120推定完成。


2026-10-16 F121稳定帧号：对照Android filmFrameNumber按date/make/model/lens/focal/iso/shutter非nil以NUL连接、Java UTF16 hashCode溢出、&Int.MAX_VALUE、%999+1，替换iOS UTF8 FNV；filmEdge移除固定20，使用同一三位帧号。f121-frame-number-20261016.log 2/2 TEST SUCCEEDED、退出0，空1/SONY-A7=986/中文Emoji整组340/单Emoji674/Aa与BB碰撞115六向量，以及底片八字段显隐回归通过。F121最窄宽度联合长文本/缺信息及标签规则仍需核对，细样式按当前范围延期，不核销；累计99项。


2026-10-16 F121标签内容：对照Android drawFilmNegativeDecoration与FrameBrandLogo.identityLogo，品牌/型号以“ · ”连接且Logo替换品牌后保留完整后缀。iOS cameraIdentityRow增加默认空格的separator参数，仅底片传中点；缺品牌/型号不加孤立分隔符。f121-identity-separator-20261016.log 2/2 TEST SUCCEEDED、退出0，覆盖文字/Logo、缺字段、未知中文品牌Emoji及既有UTF16帧号向量。git diff --check通过；最窄宽度联合长文本/缺信息输出验证仍待完成，F121不核销，累计99项。未运行UI或真机测试。

2026-10-16 F121开发侧功能核销：对照calculateMeasuredTemplateFrame底片字段清单，补齐快门/ISO后十字段显隐均在下半成片验证，排除顶部帧号干扰；f121-exposure-fields-20261016.log 1/1 TEST SUCCEEDED、退出0。f121-narrow-unicode-20261016.log 2/2 TEST SUCCEEDED、退出0：filmNegative/filmEdge宽度60、缺全部信息、长中文Emoji镜头尾部AAA/ZZZ只比较底部中央区域且输出不同，扩高及预览完整比例通过；同时回归原八字段显隐。结合frame-number2/2的Java UTF16六向量与identity-separator2/2的文字/Logo/缺字段证据，F121功能已修复，累计100项。分隔线/标签锚点/墨色等精细样式按用户范围延期，不声称视觉复刻；全模板测量归F116、品牌完整矩阵归F119，均不因此核销。未运行UI或真机验证，git diff --check通过。


2026-10-16 F122照片文字布局阶段：对照Android createWatermarkPaint/layoutPhotoWatermark/calculatePhotoWatermarkPlacement，新增共享测量结果，先完整advance限宽后按实际墨迹定位，照片内绘制接该字号/基线；越过安全区的墨迹按Android居中回退。首次text-safe-area专项失败，原无条件安全区断言忽略安卓回退；第二次placement-fallback仍失败，确认UIFont重排后advance302.64超过294.4，改最多8次重新测量收敛。最终f122-font-refit-20261016.log 1/1 TEST SUCCEEDED、退出0，5字体×1/100/300×7位置共105组合通过。前两失败日志均保留，不以纯模型验证冒充真实成片覆盖；实际绘制尾部/横竖预览、AUTO与效果路径仍待验证，F122不核销，累计100项。


2026-10-16 F122实际绘制补证：新增无边框300%字号、100%不透明黑色/NONE水印，横竖×5字体×左上/居中/右下×导出/128预览共60配置，每配置比较24字符长文字AAA/ZZZ尾部输出不同，扫描可见墨迹非空且不触照片最外边界。首轮f122-rendered-text日志测试编译失败（Int?传CGFloat?），修正后f122-rendered-text-fixed-20261016.log 1/1 TEST SUCCEEDED、退出0，git diff --check通过。此证据不等于逐字墨迹比对、不覆盖带框/所有透明度与效果；AUTO及效果路径仍待核对，F122不核销，累计100项。


2026-10-16 F122 AUTO规则：按Android resolvedWatermarkEffect提取显式解析，照片内AUTO→SHADOW，信息栏AUTO→NONE，其余保持用户选择；drawWatermark消费解析结果。f122-auto-effect-20261016.log 1/1 TEST SUCCEEDED：15模板照片中心AUTO/SHADOW成片相等，6个信息栏模板左侧AUTO/NONE成片相等，所有位置的三种显式效果不变。此相等性回归不单独证明各效果可见差异，后续需补；静态确认drawMetadataRow多个信息栏入口仅接shadowOpacity，outline仍被忽略，F122未完成，累计100项。git diff --check通过，未运行UI/真机测试。


2026-10-16 F122信息栏描边接线：对照Android drawWatermarkText两遍stroke/fill，PhotoFrameTextRow保留原属性文字并在同一缩放/基线先描边再填充，drawMetadataRow新增outline，标准/铭牌/品牌画廊/编辑模板/沉浸独立水印接入。描边按字体百分比换算且使用对比色与原alpha。f122-band-outline-20261016.log 2/2 TEST SUCCEEDED、退出0：11模板×黑白两色，NONE/SHADOW/OUTLINE成片两两不同，并回归15模板照片AUTO与6信息栏AUTO。git diff --check通过。照片内描边的既有百分比换算、阴影实际字号/颜色/透明度、带框水印长尾与低透明度仍需核对，F122不核销，累计100项；未UI/真机验证。


2026-10-16 F122效果公共参数：PhotoWatermarkInk集中Android对比色、alpha保留、描边点数转字体百分比、阴影字号比例；照片内描边修复原点数直接填百分比，照片内阴影由固定黑35%改随水印颜色/透明度。信息栏描边复用该公共逻辑，metadataText使用UIKit UIColor属性，移除CGColor强制转换。f122-shared-ink-20261016.log 3/3 TEST SUCCEEDED、退出0，18组字号/透明度/黑白参数验证、11模板效果差异及AUTO回归通过。信息栏阴影仍固定shadowOpacity，需继续统一；带框长尾/低透明度实际绘制尚未完整覆盖，F122不核销，累计100项。git diff --check通过，未UI/真机验证。


2026-10-16 F122信息栏阴影透明度：PhotoFrameTextRow按实际font/color和行缩放调用公共水印阴影参数，Renderer各信息栏水印入口移除固定35%黑色shadowOpacity，普通相机信息的阴影仍独立。f122-band-opacity-20261016.log 3/3 TEST SUCCEEDED、退出0：透明底黑白×描边/阴影的1%与100%实测Alpha，低透明度非空且最大Alpha≤8，高透明度>200；11模板效果成片差异和AUTO回归通过。git diff --check通过。F122带框长水印与照片内全部效果实际组合仍待验证，不核销，累计100项；未UI/真机验证。


2026-10-17 F122带框组合补证：f122-framed-matrix-20261016.log 1/1 TEST SUCCEEDED、退出0，15模板×4效果×1/100透明度×导出/256预览共240配置，300%字号24字符长水印AAA/ZZZ输出不同且尺寸一致、预览长边正确。git diff --check通过。继续审计发现drawImmersive的position AUTO inlineWatermark拼入titleRuns，未单独消费显式效果且继承普通标题阴影；Android3192–3225对inlineWatermark独立drawWatermarkText。此路径不在photoBottomRight矩阵内，F122仍不能核销，下一步修复混排行水印效果；累计100项，未UI/真机验证。

2026-10-17 F122开发侧功能核销：沉浸AUTO位置的inline水印用显式片段效果属性，在原测量/缩放/基线上独立绘制并清除继承的标题阴影，普通身份片段仍独立。f122-inline-effects-20261017.log 3/3 TEST SUCCEEDED、退出0；有无metadata×文字/Logo×导出/预览8组合AUTO=NONE、三显式效果两两不同，并回归11模板信息栏效果与1% Alpha。完成审计：照片内全宽限缩/墨迹定位、照片与信息栏两遍描边、共同对比色与透明度、AUTO规则以及沉浸混排均已生产接线；先前105布局组合、60无框成片、240带框效果/透明度/预览组合及公共参数/低alpha专项提供分层证据。原“墨迹必在4%区”验收修正为安卓实际规则：advance按4%可用宽度限缩，若字形墨迹仍超区则居中回退，不擅自追加缩放规则。F122功能开发侧已修复，累计101项；精细样式/像素级效果对齐延期，未UI/真机验收，不外推F116/F119完成。git diff --check通过。


2026-10-17 F123失败传播阶段：对照Android layoutPhotoImageWatermark/loadWatermarkImage的私有hash与解码失败规则，iOS drawWatermark图片分支验证64位小写hex且读取失败抛invalidWatermarkImage，不再fallthrough文字；所有相关模板函数throws传递至已有renderer错误收集/生成调用。f123-missing-image-20261017.log 1/1 TEST SUCCEEDED、退出0：15模板×空hash/非法hash/缺失文件共45失败场景，以及无框失败、关闭水印不受影响。git diff --check通过。损坏文件/恢复重试/队列原片保留及冻结快照尚待验收，F123不核销，累计101项；未UI/真机验证。

2026-10-17 F123开发侧核销：真实TransferQueue入队有效图片后删除/损坏私有素材、清空缓存，生成记录frameError且无frameURL，原片字节保持；恢复原素材并修改当前偏好后重试，输出JPEG与冻结settings直接生成精确一致，旧hash保持。首轮f123-queue-retry两测试因status旧断言失败；对照Android TransferViewModel3631–3634和iOS catch确认原片已完成时仅派生错误，修正新测试及旧退款重试测试为completed+frameError。f123-queue-state-20261017.log最终2/2 TEST SUCCEEDED、退出0，含图片替换/退款后冻结快照回归；结合上轮15模板45失效场景/无框失败/关闭水印通过，F123功能已修复，累计102项。安卓与iOS都允许有效内存图片缓存复用，本次删除/损坏验收明确清空缓存以验证磁盘失败，不将缓存命中误报降级。git diff --check通过，未UI/真机验证。


2026-10-17 F124解码前门控：新增PhotoAllocationBudget.loadOriginalImage，ImageIO shouldCache=false只读尺寸，按8字节像素及8MiB附加预算/64MiB余量预检后才加载UIImage；TransferQueue与LocalPhotoBatchViewModel原图入口均接入，后续保留测量画布预算。f124-predecode-budget-20261017.log 4/4 TEST SUCCEEDED、退出0，算术溢出/余量边界、文件低预算拒绝/81×63原尺寸与文件字节保留、真实队列素材失败恢复回归通过。多任务并发预算与高像素实际峰值尚待审计，F124不核销，累计102项（历史182项剩80，纯功能分母待重分类）。git diff --check通过，未UI/真机验证。


2026-10-17 F124边界补证：审查Android ensurePhotoAllocation明确为快照检查非内存预留，未擅自增加全局并发限制。新增PNG改IHDR尺寸并修CRC的损坏头拒绝测试；首轮一万亿像素、第二轮一亿像素均由ImageIO尺寸/文件数据一致性预检先拒绝，不能冒称命中预算，分别保留header-boundary/readable-header失败日志。改为精确断言Cocoa fileReadCorruptFile，预算路径由已有真实有效PNG低可用内存用例覆盖。f124-invalid-header-20261017.log最终5/5 TEST SUCCEEDED、退出0，含四预算/文件测试及长元数据扩画布预算回归。git diff --check通过。多任务内存快照压力/高像素实测仍未验证，F124不核销，累计102项；未UI/真机验证。


2026-10-17 F124高像素/重试补证：f124-large-retry-20261017.log 2/2 TEST SUCCEEDED、退出0。新1200万像素4000×3000真实位图，64MiB可用预算先拒绝，恢复预算后铭牌200%输出4000×3960，原照片内部64×64红蓝棋盘逐字节一致；回归真实队列预算失败保原片/无输出并按冻结recipe重试成功。此测试未采集RSS，不证明真机峰值；多入口同时预算快照仍待专项，F124不核销，累计102项，F110保持未完成。git diff --check通过，未UI/真机验证。

2026-10-17 F124开发侧核销：TransferQueue.renderFrameFile与LocalPhotoOutput.render可注入Sendable内存快照，默认系统接口不变，解码前与画布前分别查询。f124-concurrent-entry-20261017.log 2/2 TEST SUCCEEDED、退出0：task group并发调用两生产入口低预算均PhotoAllocationRejected，原片字节保留且无ZTFrames半成品；恢复预算并发两路均输出可解码同尺寸图片；队列冻结配方重试回归通过。结合predecode4/4、invalid-header5/5、large-retry2/2，已覆盖文件头/算术溢出/64MiB余量、测量扩框预算、1200万像素拒绝恢复与内部像素、原片与重试。F124分配前预算功能开发侧已修复，累计103项；与Android一样仅快照早拒绝，不是内存预留或所有OOM保证，未测真机RSS/极端并发压力，这些性能验收归F110且仍未完成。未UI/真机验证，git diff --check通过。


2026-10-17 F125基准复核与错误分类：阅读Android CameraViewModel4308及PhotoPreview467–528，准备复用已加载FHD/EXIF orientation，缺方向才读取头；并非先获取原图完整几何，原图尺寸/MCU留到生成阶段，不应用缩略图猜测。iOS当前PhotoPreview651仍立即sheet+异步64KiB头、完成时猜尺寸/8MCU，F125/F126待生产修复。先修CropPreparationError.canRetry以统一分类函数判断，避免orientation携带detail后误可重试；f125-retry-classification-20261017.log 4/4 TEST SUCCEEDED、退出0，四种detail×三错误类型的属性/helper/state一致及旧状态回归通过。git diff --check通过。下一步以FHD+方向准备模型接线并移除提前recipe回退，累计103项不变；未UI/真机验证。


2026-10-17 F125/F126准备模型：对照Android prepareCropPreview与PhotoPreview规范方向copy，新增prepareCropPreview(width/height/pixel)以有效内容黑边边界构造编辑几何，source MCU=1仅用于预览，canonicalized采用规范方向尺寸；选择保留originalOrientation供原图阶段解析。空预览/非法rotation及不支持canonical方向可处理失败。f125-prepared-model-20261017.log 7/7 TEST SUCCEEDED、退出0，含左右黑边、EXIF1/3/6/8与手动-90、规范后尺寸/原方向、镜像及非法规范方向拒绝、旧selection与错误分类。git diff --check通过。模型尚未接PhotoPreview页面，未声称真实裁切链路完成；F125/F126不核销，累计103项，未UI/真机验证。

2026-10-17 F125/F126方向缓存：对照Android parseJpegCropOrientation、CameraViewModel.prepareCrop及PhotoPreview FHD方向读取，新增可在APP1处完成的独立方向解析；PhotoExif保存方向，FHD解码结果与页面缓存同步保留方向并随页面清理，UIImage仍保持up以避免重复旋转。f125-orientation-cache-20261017.log实际3/3 TEST SUCCEEDED、退出0（PhotoMetadataPreparationTests不是实际测试类名，未执行该类，不计入验证）；f125-preview-orientation-20261017.log 1/1 TEST SUCCEEDED、退出0，覆盖EXIF1–8方向保存及手动旋转像素不变。git diff --check通过。裁切准备页面尚未接线，F125/F126仍未核销，累计103项；未UI/真机验证。

2026-10-17 F125/F126编辑图像准备：对照Android prepareCropPreview与PhotoPreview规范方向流程，新增preparePhotoCrop，将已解码FHD转换为有界sRGB像素用于黑边识别，裁去预览黑边并按规范方向生成编辑图像；保留原方向及原预览，不读取或猜测原图MCU。入口限定既有1920预览上限，前后检查取消。f125-editor-image-20261017.log 6/6 TEST SUCCEEDED、退出0，新增真实UIImage黑边/EXIF1、3、6、8输出尺寸/up方向/源PNG不变/空图和镜像拒绝，连同既有选择模型回归；不是非对称像素旋转或页面生命周期全覆盖。git diff --check通过。尚待PhotoPreview入口接线、错误与重试及取消闭环，F125/F126不核销，累计103项。未UI/真机验证。

2026-10-17 F125/F126页面与延后解析接线：PhotoPreview裁切sheet等待现有FHD，400ms后展示准备状态；仅显式重试补FHD，复用缓存方向或128KiB独立方向头，后台preparePhotoCrop；结构化task随照片/FHD/失败/连接/重试切换取消，关闭及切页阻止旧结果回写，准备成功才确认并规范方向。删除预览尺寸/8MCU猜测及提前LosslessCropTaskStore写入。发现PhotoList旧回调依赖该store，已一并新增队列cropSelection入口，保持hasCrop分支/重试选择，原片就绪后读取真实头并resolve；旧recipe入口继续兼容。f125-page-queue-20261017.log 9/9 TEST SUCCEEDED、退出0：6项模型与真实图像准备、旧离线裁切、旧失败重试、新selection立即/延后启动，原片不变及输出存在。随后队列裁切标签改用hasCrop、新文案统一AppLocalized，三语取Android crop.xml与camera_not_connected；这两项小型显示修改尚未重编。git diff --check通过。待补页面任务取消/重试交错、非对称旋转像素、新selection方向变化及失败恢复验证；F125/F126仍不核销，累计103项。未UI/真机验证。

2026-10-17 F125/F126延后方向验证：f125-direction-retry-20261017.log 2/2 TEST SUCCEEDED、退出0，新selection方向不匹配拒绝派生且保留原片，恢复匹配EXIF后重试保留bounds/ratio并核对输出尺寸/方向，立即/延后启动回归通过；亦重新编译上轮文案/标签。随后对照Android TransferViewModel3128先复用savedCropOutput，修正新路径先解析原图的问题，新增裁切成功/效果失败/原片损坏后复用既有裁切文件测试。f125-published-retry-20261017正在运行（exec session61012），尚无结果，不计通过。git diff --check通过，F125/F126未核销、累计103项。下一轮先轮询该进程，不重复启动构建。

2026-10-17 F125/F126补强：上一轮f125-published-retry-20261017.log最终2/2 TEST SUCCEEDED、退出0，裁切已发布/效果失败后原片损坏仍复用原裁切文件，保留selection且派生重试成功；方向变化与恢复回归通过。f126-pixels-cancel-20261017.log最终7/7 TEST SUCCEEDED、退出0，新增四色非对称UIImage在EXIF1/3/6/8的四角像素排列与预取消不产出结果验证，既有黑边/选择模型回归通过。另对照Android CropEditor的400ms提示生命周期，重试/错误/ready变化重置提示计时，最后这项页面修改尚未重新编译。git diff --check通过。F125/F126表格改为进行中，未核销，累计103项；页面慢头/断连/关闭重开交错和实际选择到输出像素仍待，未UI/真机验证。

2026-10-17 F125重试所有权修正：发现prepareCrop内await loadHighResolution清除fhdUnavailable，会改变自身task id而取消刚发起的下载；对照Android PhotoPreview1590–1620的独立previewScope重试，将显式FHD重试移到仅随file/retry变化的独立结构化task，准备观察仍随可用性/连接变化。抽出生产cropPreparationOrientation，缓存先于连接判断、相机头返回后再次检查取消；页面接用，避免不响应取消的旧读取继续图像处理。f125-cancel-header-20261017.log 12/12 TEST SUCCEEDED、退出0，含离线缓存不读相机/离线缺方向/截断头分类、受控慢头取消后迟到返回保持CancellationError及7项真实图像/模型回归；重新编译400ms提示修正。git diff --check通过。仍待完整页面交错及裁切读取DeviceBusy重试基准核对，不以辅助测试宣称完整页面验证；F125/F126不核销，累计103项，未UI/真机验证。

2026-10-17 F125方向头DeviceBusy：对照Android NikonCamera.readExifHeader3153–3198及常量2221–2222，CameraRepository.readPrefix新增默认关闭的retryDeviceBusy，经CameraSession传递，仅裁切方向读取启用；在同一PREVIEW_EXIF事务内对PTPSessionError.responseCode(0x2019)最多重试2次、每次可取消160ms等待，其他错误不重试。兼容既有directReader前缀缓存路径；默认EXIF调用行为不变。f125-busy-header-20261017.log 8/8 TEST SUCCEEDED、退出0，协议回放覆盖busy/busy/成功、3次busy耗尽、默认不开重试、非busy错误、等待中取消及后续读取通道可用，含旧FHD回归；未单独覆盖STA directReader缓存重试及真机响应。git diff --check通过。F125/F126继续进行中，页面交错及选区到原图像素验收未闭环，累计103项不变。

2026-10-17 F126开发侧核销：对照Android CropPreview.canonicalSelection、prepareCropPreview及PhotoPreview规范方向准备，生产PhotoPreview已调用preparePhotoCrop，去对称黑边后显示规范方向编辑图像，canonicalSelection保留原始EXIF并由TransferQueue在真实原片上resolve；不再拿手动rotation覆盖原EXIF。f126-native-selection-20261017.log 1/1 TEST SUCCEEDED、退出0：真实256×192四色JPEG，EXIF1/3/6/8原始FHD及EXIF6/8已旋转纵向FHD，共6组合×4象限=24次原生无损裁切，均带左右16像素黑边、手动-90进入，输出中心RGB与所选预览象限误差<=4且原片字节不变。结合f126-pixels-cancel 7/7四角像素/取消与先前镜像canonical拒绝/方向变更失败恢复证据，F126方向与坐标链开发侧核销；未做UI/真机验证，触摸框与比例数学归F127/F128，准备流程交错仍归F125，不以本项覆盖。累计104项，历史182项余78；功能分母仍待重分类。git diff --check通过。

2026-10-17 F125 developer-side completion: PhotoCropPreparation now owns prepared/failure publication, rejects late successes and failures with per-attempt generations, and resets on close/page change/reopen. Structured task cancellation remains enforced after uncooperative reads. Correction: current Android CropEditor lines 120-140 allows retry for ALL preparation failures; previous claims/tests that orientation failures cannot retry are withdrawn. Unknown errors now use crop_unavailable; header failures map to orientation, cancellation stays cancellation. f125-owner first run: 15/15 passed. Final f125-owner-retry-parity-20261017.log: 17/17 TEST SUCCEEDED, exit 0; four late success/failure vs replacement/reopen combinations, cancelled late failure, waiting/failure/retry, cached/offline/truncated/slow header and native pixel regressions (24 crops). Together with earlier 8 protocol tests and queue original-preservation/retry checks, F125 business logic is closed on developer evidence. UI/device tests were not run; gestures, ratios and viewport behavior remain F127/F128/F129. Historical count is now 105/182, 77 unclosed; functional denominator still pending reclassification. git diff --check passed.

2026-10-17 F127小选区安全：对照Android JpegCrop.align的可抛出require及CropEditorGeometry像素最小单位，iOS align改为throws，非法bounds/ratio及不足一个完整比例单位分别返回JpegCropError，不再用precondition使进程崩溃；生产selection.resolve传递错误到既有派生失败路径，整理selection定义以保持可读。f127-small-selection-20261017.log 5/5 TEST SUCCEEDED、退出0：EXIF1/3/6/8的8×8原图选择16:9拒绝但自由全图有效、4000×3000微小3:2选区、NaN边界/残缺比例及旧对齐回归；同时真实方向/黑边/FHD的24次原生裁切通过。git diff --check通过。比例参考稳定性、实际宽高、原比例/横竖互换及缩放下限仍待，F127不核销，累计105项，未UI/真机验证。

2026-10-17 F127像素几何模型：完整阅读Android CropEditorGeometry及对应5项测试，在CropGestureState.swift加入CropEditorGeometry，frame/image分别按视口像素维护，ratioReference稳定参考；原比例导出ratio=0/0，固定比例明确横竖互换，比例切换不移动图片；移植pan/zoom源像素下限/32倍限制、对齐后可见性、角拖建立新参考、resize保留选区。f127-pixel-geometry-20261017.log 7/7 TEST SUCCEEDED、退出0：横/竖/奇数尺寸×20轮全比例切换无累计缩小，横竖互换与手动参考20轮，EXIF1–8大位移缩放/对齐边界/转屏原选区误差≤MCU及旧模型回归。git diff --check通过。模型尚未替换PhotoCropEditor旧归一化手势，缺初始预览placement接入和触摸命中等F128逻辑；F127/F128不核销，累计105项，下一步接生产编辑器并删除旧状态实现，未UI/真机验证。

2026-10-17 F127 developer-side completion: PhotoCropEditor now uses CropEditorGeometry for both image/frame display and exported selection; removed old normalized-square CropGestureState and its four obsolete algorithm tests. Ratios use pixel geometry and stable references, original exports 0/0, flip/reset are connected, zoom respects pixel aspect units, invalid tiny operations retain the last valid editor state. A single UIKit touch stream now routes corners vs centroid/pan/zoom and releases corner ownership on a second finger; full touch lifecycle evidence remains F128. f127-editor-integration-20261017.log: 18/18 TEST SUCCEEDED, exit 0. Four geometry tests cover all ratios on portrait/landscape/odd dimensions over 20 switches, manual reference/flip, EXIF1-8 resize and large pan, four corners and 32x24 source with repeated 1000x zoom; ten preparation/pixel/ownership tests include 24 native crops, plus four safe alignment tests. F127 ratio behavior is developer-side closed; F128 touch completeness and F129 viewport return remain open. No UI/device tests. Count 106/182, 76 unclosed; functional denominator pending reclassification. git diff --check passed.

2026-10-17 F128 functional developer-side completion: PhotoCropEditor now draws image placement and crop frame from the same pixel geometry and exports that geometry, replacing whole-container normalized overlay coordinates. Corner hits use 28pt and corner minimum 48pt; a single production CropTouchState stream retains pointer identities, clears corner ownership after the second pointer, keeps transform ownership after one pointer leaves, and resets on cancellation/end/dismantle. Surface size changes reset the recognizer to prevent stale coordinates after rotation. f128-touch-state-20261017.log: 6/6 TEST SUCCEEDED, exit 0. New deterministic pointer sequences cover corner drag, two-finger centroid/pan/zoom, one-finger continuation, next gesture, cancellation, incomplete/invalid events; four geometry regressions include corner hits, bounded tiny-image zoom, 20 ratio switches, EXIF1-8 large pan and resize. Earlier native-crop evidence verifies exported normalized selections. Functional F128 is closed on model/production-code evidence; UI gesture injection and physical-device touch were not run. Pure visual mask/grid/corner decoration remains deferred under the user scope exclusion, not claimed reproduced. Initial/return preview viewport behavior stays F129. Count 107/182, 75 unclosed; functional denominator pending reclassification. git diff --check passed.

2026-10-17 F129 return-viewport direction: Android only resets crop return scale/offset when canonical rotation actually changes. Added CropPreview.correctedRotation using nearest equivalent angle; PhotoPreview no longer unconditionally sets currentZoomed=false or rewrites 360-degree equivalents to zero. Existing PreviewImage rotation observer resets actual scale/pan only on a real angle change. f129-return-rotation-20261017.log: 11/11 TEST SUCCEEDED, exit 0; four EXIF directions across -5...5 whole turns and seven quarter offsets preserve equivalent angles and bound corrections to 180 degrees, plus prior native crop/preparation tests. Further Android CropEditor inspection found no standalone reset/flip UI: removed the previously added buttons (model operations remain for parity/tests); this corrects earlier records claiming those controls should be exposed. Added existing configurable haptic ticks to crop entry, ratio choices, retry and cancel matching Android. These final small UI edits have not been recompiled yet. git diff --check passed. F129 remains open for full initial/return viewport behavior; no animation/style or UI/device validation claimed. Count remains 107.

2026-10-17 F129 initial visible viewport: added CropPreview.visibleBounds to project viewport through rotated FHD content excluding black bars, and CropEditorGeometry.initialize to preserve normalized visible selection across editor layout sizes; reset returns to captured initial placement. PreviewImage publishes actual viewport size/scale/offset/angle/info clearance; crop entry captures it, unchanged direction computes initial content bounds, actual canonical rotation change starts from reset full-content bounds. PhotoCropEditor initializes from these bounds instead of always fitting the full image. f129-visible-bounds-20261017.log and final f129-viewport-entry-20261017.log each 18/18 TEST SUCCEEDED, exit 0; new four-direction rotated-black-bar viewport normalization and initialize/reset tests plus geometry/native crop regressions. Production snapshot wiring compiled; previous button removal/haptics also recompiled. Pending: direct snapshot/zoom bridge tests and freezing an in-progress preview zoom animation at crop entry, then return/reopen interaction audit. F129 is not closed; count stays 107. No UI/device or animation/style verification. git diff --check passed.

2026-10-17 F129 functional developer-side completion: PreviewImage disables input during crop and cancels stale double-tap completion tasks while preserving logical scale/offset; its viewport remains separate from editor mutations, so close/cancel retains the entry viewport. Canonical direction changes still reset the underlying viewport through the existing rotation observer; equivalent whole-turn angles preserve it. Production snapshot handoff maps scaled/panned FHD content (including rotated black bars) into initial editor bounds, preserving the same selection in a differently sized basic editor. Localized controls and Android haptic entry/ratio/retry/cancel behavior are connected; previously invented reset/flip controls were removed. f129-snapshot-handoff-20261017.log: 19/19 TEST SUCCEEDED, exit 0; new four-direction x two-offset x two-editor-size snapshot tests verify normalized selection and equivalent-angle invariance, alongside preparation ownership, native pixel/crop and touch geometry regressions. These are model/business tests plus production compilation, not UI/device input evidence. The sheet/basic layout remains the temporary functional interface; detailed in-preview layout, 220/180/240ms transitions, flight effects, color/theme styling remain explicitly deferred by user scope, not claimed reproduced. Functional F129 closed; count 108/182, 74 unclosed, functional denominator still pending classification. git diff --check passed.

2026-10-17 F130 confirmation integration: JpegCropSelection.hasCrop matches Android relative 1e-5 visible-bounds tolerance. PhotoCropPreparation owns confirming state, ignores unprepared/full/duplicate submissions, keeps the draft on rejection and latches accepted submissions until close/reset. PhotoPreview awaits Bool acceptance, disables editing/dismissal while confirming and closes only on accepted current-owner result. PhotoList awaits TransferQueueViewModel.acceptCrop actual enqueue acknowledgement; effects are captured as values before enqueue. Corrected old ledger scope against current FileListScreen2183: no directory closes preview and opens directory setup, disconnected preview rejects even with a local original, accepted shows crop_added. Offline existing-original queue generation remains separately supported, not exposed as disconnected preview admission. f130-confirmation-20261017.log: 16/16 TEST SUCCEEDED, exit 0; new delayed rejection/duplicate/accepted-latch/no-change tolerance tests plus preparation/native crop and existing offline queue regression. New acceptCrop acknowledgement path and host admission combinations still need dedicated verification; F130 not closed, count 108. No UI/device tests. git diff --check passed.

2026-10-17 F130 developer-side completion: production CropPreviewAdmission preserves Android directory-before-connection ordering; missing directory closes preview and requests settings, disconnected preview rejects even if local original exists, otherwise host awaits actual queue acceptance. acceptCrop returns true only after enqueue is visible, and selection enqueue checks cancellation on the queue actor before mutation. Confirming latch prevents duplicate/full/unprepared submissions, rejection preserves draft, accepted result closes only its current owner; effect settings and selection cross as immutable values. f130-ack-admission-20261017.log: 9/9 TEST SUCCEEDED, exit 0; all four directory/connection combinations, real immediate/deferred acknowledgement plus original crop publication, pre-cancelled view-model and actor requests with empty queue, and delayed rejection/duplicate/accepted-latch regression. Combined with prior 16-test confirmation/native-crop suite, F130 functional developer evidence is complete. Old ledger offline-preview admission requirement is withdrawn against current Android FileListScreen2183; lower-level offline original generation remains supported separately. No UI/device validation. Count 109/182, 73 unclosed; functional denominator pending reclassification. git diff --check passed.

2026-10-17 F136 developer-side completion: RemoteState.frameReceived now updates display readiness only, preserving stability owned by the acquisition loop. Android RemoteScreen.kt234,1164-1179 requires eight successful USB packets; Busy is excluded and WiFi becomes stable immediately. Production lifecycle tests hold successful packet counts at 1 and 7 with repeated Busy across polling intervals: first image is visible/ready, events and periodic battery refresh remain blocked, enabled auto ISO never refreshes early. Packet 8 releases stability, events and effective ISO refresh; stop clears stability. WiFi first-image behavior is verified separately. Final /tmp/ztransfer-f136-polling-20261017.log: 2/2 tests, TEST SUCCEEDED, exit 0 (initial stability suite also 2/2). No UI or physical-device tests. Count 110/182, 72 unclosed; functional denominator pending classification.

2026-10-17 F137 developer-side completion: waitForPolling owns separately cancellable idle delays for live-view startup/recovery and polling (including 10-second movie-format, display-details and effective-ISO waits). stop cancels these timers only, while stopAndWait drains owning tasks and their in-flight camera requests before gate release. A post-USB-warmup stop guard prevents restoring stability after exit. Movie-format reads suppress late publication after stop. Generation-checked task cleanup prevents an obsolete movie-format task from clearing the replacement handle. Android basis: RemoteDispOverlay.rememberMonitorMovieFormat cancels 10s/250ms delays on disposal; RemoteScreen session finally handles cleanup. First f137-exit run failed 1/3: replacement read was not drained because old task cleared its handle; corrected rather than weakening assertion. Final /tmp/ztransfer-f137-drain-20261017.log: 5/5 TEST SUCCEEDED, exit 0. Checks idle 10s wait exits within 2s, 350ms in-flight format read drains without cancellation and completes within 2s, duplicate exit releases gate once, trial/page concurrent cleanup, non-Busy frame recovery, and USB eight-frame stability regression. No UI/device tests. Count 111/182, 71 unclosed; functional denominator pending classification.

2026-10-17 F138 developer-side completion and audit correction: current Android RemoteScreen.startSession1025 clears frames on a new HD session; inner acquisition-error retries1195-1207 do NOT clear, and computer-control1251 as well as movie-compatibility2435 explicitly preserve. The old ledger expectation that every ordinary error retry clears frames is withdrawn. iOS now clears displayed image/data/metadata/time and all derived analysis when the HD replacement session begins, after old wire work ends and decode generation advances. Internal error retries, computer-control and movie-compatibility restarts preserve until a replacement arrives. Shared clearDisplayedFrame also clears derived outputs on disposal. /tmp/ztransfer-f138-frames-20261017.log: 4/4 TEST SUCCEEDED exit 0, covering HD Busy replacement, acquisition-error retention, computer-control and movie recovery. Final /tmp/ztransfer-f138-preservation-20261017.log: 2/2 TEST SUCCEEDED exit 0, explicitly freezing movie replacement frames to assert image identity retention then replacement, plus HD clearing/republication. No UI/device tests; existing decode-generation rejection remains in place, no new artificially suspended decoder test. Count 112/182, 70 unclosed; functional denominator pending classification.

2026-10-17 F139 developer-side completion: toggleRecording catch releases application/control modes only for failed start; failed stop retains recording and modes for retry or subsequent completion events. Transport failures notify global disconnect and return without a late stop-failure hint/standby restart. Android basis: RemoteScreen2486-2518 EndMovie failure retains recording and application mode. /tmp/ztransfer-f139-stop-20261017.log: 3/3 TEST SUCCEEDED, exit 0. USB negative response and thrown non-transport response error both preserve recording/application/control with no release calls; a second stop succeeds and completion event releases modes. Timeout reports global loss exactly once without late stop hint, followed by teardown. Existing WiFi compatibility/start-stop-completion regression also passed. No UI/device tests. Count 113/182, 69 unclosed; functional denominator pending classification.

2026-10-17 F140 developer-side completion: startPreparedUSBMovieRecording records each acknowledged application-mode operation/property immediately on CameraRepository before any subsequent fallible command, while retaining the uninterrupted PTP command-sequence gate. Removed final tuple writeback that lost successful side effects on throw. Android basis: RemoteLab.prepareAndStartMovieLocked records remoteMovieApplicationOpSet/PropSet immediately after OK. Final /tmp/ztransfer-f140-wire-20261017.log: 4/4 TEST SUCCEEDED, exit 0. New wire test covers both enable paths x subsequent response error, injected CancellationError (pre-dispatch cancellation contract), and timeout: reusable sessions send matching disable and clear ownership; invalidated timeout sessions send no further cleanup command and retain ownership rather than falsely clear. Three existing preparation success/fallback tests also passed. Initial f140-ownership build failed only because heterogeneous Swift ternary test errors needed an explicit switch; no tests ran in that attempt. No UI/device or real USB cancellation-race test. Count 114/182, 68 unclosed; functional denominator pending classification.

2026-10-17 F141 in progress, NOT closed: connected effective UI desqueeze to recording model; capture canvas rounds current width x valid multiplier to even pixels, each pending frame carries its multiplier and fits into fixed black canvas. Re-read frame after microphone permission instead of using captured pre-permission size. Android basis ViewfinderRecorder71/719 and RemoteScreen.startRecorderResolved2595. /tmp/ztransfer-f141-geometry-20261017.log: recorder suite 4/4 TEST SUCCEEDED, exit 0, covering geometry model plus existing decodable recordings/publication protections. Still required: encoded pixel/aspect verification for 1.33/2x and changing source geometry, controlled permission suspension with changing or missing current frame. No UI/device tests. Count remains 114/182, 68 unclosed.

2026-10-17 F141 exported-pixel verification: final /tmp/ztransfer-f141-pixel-export-20261017.log 1/1 TEST SUCCEEDED exit 0, exercising five real MP4 files (1.33x, 2x, reduced current multiplier, portrait source, wider source), decoding every frame and checking fixed even canvas dimensions, bright center and expected side/top black bars. Initial f141-pixels attempt did not compile due to async load inside XCTest autoclosure; separated await and unwrap before successful rerun. Still open: permission-suspension/current-frame production-path test, and within-one-file geometry transition evidence (current cases encode changed geometry against the initial canvas but use one frame geometry per file). Do not close F141 or change count: 114/182, 68 unclosed.

2026-10-17 F141 developer-side completion: permission provider injection defaults to the real AVAudioSession path; controlled suspension tests verify current 96x64 frame plus current 2x multiplier produces 192x64 video, and missing frame after HD restart rejects without creating a file. Final encoded geometry test now changes frame size/multiplier WITHIN each file, decodes all four frames per case, and checks fixed dimensions and before/after black-bar placement across five 1.33x/2x/wide/portrait cases. Final /tmp/ztransfer-f141-final-20261017.log: 6/6 TEST SUCCEEDED exit 0 (recorder suite5 plus permission-path1, which exercises both outcomes). Earlier permission-only run1/1 passed. Production RemoteView passes effective multiplier initially and on changes; queued frames carry individual multipliers; fixed canvas uses Android rounded-even width and aspect-fit black fill. No UI/device or actual system permission dialog tests. All prior pending F141 verification items now covered at model/business/encoded-output level. Count 115/182, 67 unclosed; functional denominator pending classification.

2026-10-17 F142 in progress NOT closed: Android RemoteScreen2670-2694 retries the same failed frame every5ms, stops at30 genuine failures, resets streak on successful encode or busy skip. Recorder now classifies writer/pixel-buffer/append failures separately from backpressure, retries retained failed image with replaceable newest slot, and delivers one threshold callback. RemoteViewModel routes callback through recording UUID to existing stop/save flow. /tmp/ztransfer-f142-failures-20261017.log: 6/6 TEST SUCCEEDED exit0; actual missing-CGImage input reaches auto-finalization callback without later frames, saved earlier frames remain decodable, geometry/publication regressions pass. Pending: recovery/reset and injected writer/backpressure evidence, production automatic-stop feedback, finishWriting deadline. Asked user platform agreement for8s overall deadline (Android phased bounds versus AVAssetWriter); no answer yet, deadline not implemented. F143 queue admission/backlog remains separate. Count unchanged115/182,67 unclosed.

2026-10-17 F142 recovery evidence, still NOT closed: extracted production RemoteRecordingFailureStreak to verify exact30-failure boundary, repeated29-failure runs reset on success, and one-shot terminal notification. Real encoder test replaces an unencodable retained image with valid frame before threshold, waits beyond retry window, continues recording and decodes saved file without failure callback. /tmp/ztransfer-f142-recovery-20261017.log: 8/8 TEST SUCCEEDED exit0. Pending deadline agreement remains unanswered; timeout not implemented. Writer-status/append refusal/backpressure injection and production automatic-stop/failed-save feedback still require evidence. Count115/182,67 unclosed.

2026-10-17 F144 in progress NOT closed: recorder establishes baseUptime at successful start before audio capture; pause/resume and epoch use one injected monotonic clock (production systemUptime). Removed first-video-frame epoch assignment, so pre-first-frame pause is not subtracted from an already-shifted origin. Existing recorder tests now explicitly use their synthetic100 epoch. Initial9-test run passed8 and failed new sample-count assumption; compressed reader includes empty edit samples. Second focused run showed media PTS0/.25; MP4 stores start gap via segment timeMapping. Final /tmp/ztransfer-f144-timeline-20261017.log1/1 TEST SUCCEEDED exit0 validates nonempty samples mapped through source/target timeline at0.5/.75 after pause100.25->101.25, incoming101.5/101.75. No production rollback or weakened timing target. Pending audio-before-video/common-clock/timing-duration evidence and UI timer alignment. F142 deadline agreement still pending; F143 backlog still open. Count115/182,67 unclosed.

2026-10-17 F144 audio verification remains FAILING, not closed: added injectable capture-session factory (production defaults to microphone configuration) and shared appendAudioSample path for synthesized PCM. Start-epoch fix remains; real export test feeds audio before first video, pauses1s, then feeds audio/video. UI timer matches Android RemoteScreen2733-2740 one-second increment/unpaused policy by static comparison. First audio run failed count because compressed reader groups AAC samples; pacing and per-sample timing corrected count. Subsequent per-segment media-to-target mapping still yields final audio~0.2807256 rather than expected>0.55; do NOT claim audio alignment verified or weaken assertion. Latest /tmp/ztransfer-f144-av-timeline-20261017.log:10 tests,9 pass1 fail,TEST FAILED exit65. Need inspect encoded AAC discontinuity/timing and synthetic fixture before choosing production correction. Earlier audio-only logs f144-audio and f144-audio-samples also failed. No live build remains. Count115/182,67 unclosed.

2026-10-17 F144 root-cause evidence, still open: temporary traces showed ALL10 PCM appends accepted with correct adjusted/outputPTS .05-.14288 and .5-.59288; ffprobe of retained audio-epoch.mp4 independently shows AAC packets only .002086-.280726 and one nonempty segment. This is writer AAC discontinuity compaction, not remaining sample-count/segment-reading error. Apple startSession docs confirm initial empty edit semantics (https://developer.apple.com/documentation/avfoundation/avassetwriter/startsession(atsourcetime:)); SDK CMSampleBuffer.h1651 documents FillDiscontinuitiesWithSilence. Tried this attachment, corrected Swift constant after initial compile failure, but /tmp/ztransfer-f144-av-final-20261017.log again9/10 passed1 failed exit65 with identical audio endpoint. Removed ineffective attachment and all temporary prints; restored fixture cleanup. Next investigate explicit bounded PCM silence bridging or encoder-level timestamp preservation; do not declare gap fixed. Trace log /tmp/ztransfer-f144-trace-20261017.log and retained fixture path in it support diagnosis. No live build remains. Count unchanged115/182,67 unclosed.

2026-10-17 F144 developer-side completion: recording epoch is established at start before audio capture; pause/resume use the same injected monotonic clock and video no longer reanchors at first frame. Audio and video subtract the shared pause accumulation. Real AAC export exposed compaction of PCM timestamp gaps despite accepted retimed buffers; ineffective CoreMedia attachment was removed. fillAudioGap now feeds zeroed PCM matching incoming format in <=4096-frame buffers, stopping on backpressure, retaining last accepted audio end. This preserves elapsed active gaps without retaining paused duration. Final /tmp/ztransfer-f144-silence-20261017.log:10/10 TEST SUCCEEDED exit0, including first-frame pause mapped videoPTS .5/.75, pre-video audio retained and post-pause encoded audio timeline >.55/<.75, prior geometry/failure/recovery/publication tests. Test source is synthetic audio through production append/mux path, not physical microphone. UI one-second unpaused increment matches Android RemoteScreen2733-2740 by code comparison. Prior failing audio logs remain documented; no relaxed time assertion. F142 timeout/writer fault evidence and F143 bounded admission remain separately open. Count116/182,66 unclosed; functional denominator pending classification.

2026-10-17 F143 preparation ONLY, not fixed/closed: confirmed append captures each UIImage in a queued block before updating latest slot, unlike Android single worker observing latest frame. Added lock-protected RemoteRecordingLatestInput with offer/take/finish retry/discard semantics: one retained pending value and one reserved consumer; newest producer wins over failed-frame retry. /tmp/ztransfer-f143-mailbox-20261017.log2/2 TEST SUCCEEDED exit0 covers20k serial offers plus1000 concurrent producers and retry/discard. NOT YET connected to production video/audio admission; does not prove recorder backlog is bounded. Next integrate producer-side mailbox, schedule one encode turn per queue block (control-operation fairness), handle pause/stop and failed-frame retry, adapt test producers to explicit async queue barriers, then test slow real encoder admission/audio bounds. Count116/182,66 unclosed. F1428s deadline question still unanswered.

2026-10-17 F143 video admission integrated, still NOT closed: append now offers UIImage/time/multiplier into producer-side locked latest slot before queue submission; queue blocks capture only recorder, each drain handles one frame and yields, retries preserve newer arrivals. Pause/stop discard pending input; invalid/inactive drain atomically discards/resets scheduling. Added asynchronous submitted-work barrier for deterministic fixtures, not a wait for future retries. Blocked real recorder worker while offering1000 distinct UIImages: weak references prove only1 pending retained, old queued images released, previously encoded file decodes after stop. Final /tmp/ztransfer-f143-video-regression-20261017.log13/13 TEST SUCCEEDED exit0. Earlier f143-video failed4 geometry fixture assertions because pause/resume used as a fake barrier; bounded run failed2 after overly broad fixture replacement removed actual audio pause and failed to wait for video resume. Restored actual pause and explicit control barrier; timing targets unchanged. Pending F143 audio admission bounds, slow-encode control fairness and rapid control/interleaving audit. Do not close task; count116/182,66 unclosed.

2026-10-17 F143 developer-side completion: producer-side latest slots now bound BOTH video UIImage and audio CMSampleBuffer admission, one reserved consumer each; queue blocks capture recorder only. Each turn handles one value then yields, failed video retries retain newest preference, pause/stop discard pending slots. Android RemoteScreen2670 worker observes latest frame; ViewfinderRecorder.audioLoop410-444 reads/discards paused audio and skips busy encoder input while wall-clock timestamps preserve gaps. Saturated iOS admission replaces obsolete pending samples; existing PCM gap bridge retains A/V time. Blocked real recorder worker with1000 images+1000 audio buffers retained exactly1 of each by weak-reference checks and released all after stop. Continuous producers running through pause/resume/stop complete control and healthy finalization within2s, playable prior content retained. Final /tmp/ztransfer-f143-fairness-20261017.log14/14 TEST SUCCEEDED exit0; preceding audio-bounded13/13 also passed. Includes audio/video timelines, exported geometry, failure/recovery, concurrent mailbox and publication regressions. This is application-owned backlog evidence, not physical-device memory/codec profiling; F142 hung-finish deadline remains separate pending user agreement. Count117/182,65 unclosed; functional denominator pending classification.

2026-10-17 F146 developer-side completion: recording save failures use inline monitor hint while host active, otherwise one-shot root-owned RemoteRecordingSaveNotice; RemoteView marks hint host inactive synchronously on disappearance before async cleanup. Root receives scoped notice, defers while root monitor cover is active, consumes on dismissal/appearance, and displays existing localized cd_remote_rec_toast_failed through reusable basic hint. Success emits no cross-page notice. Both root/internal monitor routes inherit model default shared delivery. Android basis RemoteScreen.stopRecorder2546-2595 active hint versus post-exit Toast. Final /tmp/ztransfer-f146-host-20261017.log2/2 TEST SUCCEEDED exit0: production recording+forced staging-loss failures inline or after immediate exit, successful exit no notice, concurrent/idempotent cleanup delivers once, isolated notice persists without host and takes once. Initial save-notice run production test passed but singleton test failed because mounted real root consumed it; instance-scoped store/notification isolates tests without weakening once-only semantics. No UI test/physical-device validation. Count118/182,64 unclosed; functional denominator pending classification.

2026-10-17 F147 developer-side completion: RemoteCameraToolController rechecks Task cancellation, active/closeRequested, current camera, write permission and current movie mode after awaiting beforeWrite, before entering verified property write. Existing in-flight write/readback drain ownership unchanged. Android basis RemoteCameraToolPanel270-280 post-beforeWrite checks and ensureActive. /tmp/ztransfer-f147-write-admission-20261017.log3/3 TEST SUCCEEDED exit0: deterministic suspension at beforeWrite covers dismissal, close request, camera replacement, mode change and permission revocation; no property write/onApplied, busy/pending released. Existing already-started write drains after monitor exit, and focus-area tracking-release failure/success regression pass. No UI/device tests. Count119/182,63 unclosed; functional denominator pending classification.

2026-10-17 F148 developer-side completion: RemotePropertyCodec expands only D100/500D nonbinary Range using Android shutterRangeValues min/max/step and ceil(count/256) stride; all values remain camera-step aligned and <=256. Binary0..1 remains expanded for any property; other ranges remain empty. Valid UInt16-count enum is no longer rejected above256; truncated enum/range rejected, overflow/invalid ranges safely empty. Android basis RemoteLab559-604 and rcGetParam705-715; no dedicated Android range tests found in current test tree. Production wire replay traverses PTPSession/CameraRepository for both shutter properties and600-value enum, plus malformed and ordinary-range checks. /tmp/ztransfer-f148-range-20261017.log7/7 TEST SUCCEEDED exit0 includes6 shutter regressions; final f148-boundary1/1 passed small stepped range,256/257 cutoff and generic binary compatibility. No UI/device validation. Count120/182,62 unclosed; functional denominator pending classification.

2026-10-17 F149 in progress NOT closed: moved focus cutoff into RemoteViewModel, added one expiry task following latest arrival and publishing500ms stale status even with quiet frame stream; RemoteView consumes published expiry/cutoff rather than local movie/current-only observers. Wired501C/D05D/D1F8 events, descriptor property-or-value changes, movie-mode change, new cleared session, compatibility resume and camera-tool completion to invalidation. Android references RemoteScreen4141-4156 expiry,1649 property events,3466 onApplied,1026 session start. /tmp/ztransfer-f149-expiry-20261017.log3/3 TEST SUCCEEDED exit0 verifies quiet stream expiry/new-frame recovery, all3 actual queued property events invalidate retained image then next frame recovers, and existing focus-area write regression. Still required: explicit same-raw/different-property descriptor transition, successful tool-write cutoff with blocked frames, compatibility preservation restart boundary, and ordinary inner retry parity audit (Android inner retry does not call startSession). No UI/device tests. Count120/182,62 unclosed.

2026-10-17 F149 restart boundary verification: extended production model tests with focus cutoff assertions. Compatibility movie restart retains old image but advances cutoff beyond its receive time; replacement frame is newer than cutoff. Ordinary acquisition-error inner retry preserves both image and cutoff, matching Android startSession versus inner retry distinction. /tmp/ztransfer-f149-restart-20261017.log: 2/2 passed, TEST SUCCEEDED, exit0. Still open pending same-raw/different-property transition and successful tool-write cutoff evidence. Count remains120/182,62 unclosed. No UI/device tests.

2026-10-17 F149 source correction: Android RemoteScreen3464-3473 explicitly excludes WHITE_BALANCE from onApplied focus invalidation. Earlier F149 note claiming all camera tools invalidate is incorrect and withdrawn. Restored the whiteBalance guard in RemoteViewModel. Added real model/controller write-readback test with held frames: focusArea advances cutoff and invalidates retained frame, whiteBalance preserves cutoff; both confirmed writes succeed. Existing tracking-release failure/success regression retained. /tmp/ztransfer-f149-tools-20261017.log TEST SUCCEEDED exit0 (2 selected tests). F149 remains open pending descriptor transition evidence; count120/182,62 unclosed.

2026-10-17 F149 developer-side completion: independent 500ms expiry publication, area-event invalidation, semantic focus-mode label changes, non-whiteBalance successful tool writes and session restarts now invalidate old focus frames. Android RemoteScreen718 keys mode invalidation to label: same raw across properties with different meaning invalidates, equivalent AF-S encodings preserve cutoff. Final /tmp/ztransfer-f149-label-20261017.log2/2 TEST SUCCEEDED exit0 covers both via actual queued property events with frames held. Earlier expiry3/3, restart2/2, tools2/2 cover quiet expiry/recovery, all three area events, compatibility restart versus ordinary inner retry, whiteBalance exception and tracking release. View consumes model expiry/cutoff; no UI/device tests. Earlier property-or-value comparison claim superseded by semantic label comparison. Count121/182,61 unclosed; functional denominator pending classification.

2026-10-17 F150 partial, NOT closed: Android RemoteScreen4160 fallback explicitly excludes subjectTracking and uses original fallbackPoint for <3 seconds. Added shared marker eligibility method, wired actual RemoteView fallback admission; removed selected/cached camera geometry from IOSConfirmedFocusReticle so blocked camera frames cannot return through a separate tracking overlay. /tmp/ztransfer-f150-fallback-20261017.log1/1 TEST SUCCEEDED exit0 validates normal marker timing at0/120ms/500ms/2.999s/3s/4s and tracking exclusion. Actual UI wiring compiled, UI tests not run. Still requires unified120ms handoff state and nonce/interruption/quiet-time expiry validation; current fallback predicate alone does not prove an independent3s publication. Count121/182,61 unclosed.

2026-10-17 F150 unified handoff implemented, NOT closed: RemoteFocusHandoff now owns shared tap/camera visibility, resets by nonce or focusing transition, rejects obsolete completion, preserves completed latch through packet gaps. RemoteFocusLayers wires both actual layers to this state and120ms cancellable task, folds ordinary fallback into same tap layer, removes separate IOSConfirmedFocusReticle, and publishes marker expiry via independent3s task. Android basis FocusReticleOverlay4739-4755. /tmp/ztransfer-f150-handoff-20261017.log TEST SUCCEEDED exit0, two selected tests cover shared visibility/new-request immediate reset/obsolete completion/blocked pre-confirmation frames/gap retention plus fallback eligibility. Actual view compiled; no UI tests. Still audit half-press feedback selection and lifecycle transitions, and validate timer cancellation/quiet expiry behavior beyond pure-state tests before closure. Count121/182,61 unclosed.

2026-10-17 F150 developer-side completion: unified RemoteFocusLayers consumes one RemoteFocusHandoff for tap and camera visibility, cancellable120ms handoff keyed by input/nonce, persistent latch across packet gaps, synchronous new-request reset and obsolete-result rejection. Ordinary fallback uses original tap point for<3s with independent expiry task; tracking has no fallback/cached geometry bypass. Existing focusDisplayState supplies gated camera frames, so stale/tool-hidden frames cannot reappear via the removed separate marker. Half-press uses production focusing/locked state while held, idle plus ordinary fallback after release; no alternate half-press state required. Final /tmp/ztransfer-f150-halfpress-20261017.log3/3 TEST SUCCEEDED exit0: held old image cannot take over fresh AF, real3s fallback eligibility expires, new half-press clears marker/nonce, late AF release and exit-drain regressions. Earlier handoff2/2 and fallback1/1 verify shared visibility, interruption, gaps and tracking exclusion. SwiftUI task sleep/cancellation and layer wiring statically reviewed and compiled; no UI clock-render/animation/device tests, per current scope. Count122/182,60 unclosed; functional denominator pending classification.

2026-10-17 F151/F152 scope and F153 partial: same-geometry focus judgement now updates cached feedback color independently of frame geometry, matching Android lastFocused update; visual parameters and vignette deferred, not counted closed. F153 monitor luma corrected to77/150/29; histogram/zebra54/183/19 unchanged. Android RemoteExposureAnalysis30-31 and waveform path reviewed; no matching dedicated Android exposure-analysis test file found. Corrected old Swift expected RGB luma76/149/28 and waveform rows90/53/114. /tmp/ztransfer-f153-luma-20261017.log TEST SUCCEEDED exit0, RemoteExposureAnalysisTests5/5. Still need production decoded-frame and colored threshold-edge evidence before F153 closure. Count122/182,60 unclosed.

2026-10-17 F153 developer-side completion: monitor false-color/luma-waveform uses Android77/150/29 integer weights; RGB waveform and histogram/zebra weights unchanged. Final /tmp/ztransfer-f153-pipeline-20261017.log7/7 TEST SUCCEEDED exit0 covers all colored threshold edges, RGB/luma waveform and production RemoteFrameDecodePipeline primary-color decode/publication. Lossless PNG fixture deliberately isolates exact analysis values from JPEG quantization; verifies all64 pixels false-color, waveform row/count/columns, and unchanged histogram bins53/182/18. This is production decoder/analysis evidence, not camera JPEG color calibration or UI/device validation. F154 sampling/allocation remains separate. Count123/182,59 unclosed; F151 visual remainder and F152 deferred, not counted fixed.

2026-10-17 F154 partial NOT closed: histogram sampling now applies Android ceil(sqrt(width*height/24000)) independently to x/y. Luma and RGB use one conversion/traversal instead of separate full-frame conversions; weights unchanged. Android RemoteViewfinderFeatures135-163 reviewed; no dedicated histogram/zebra test file found. Production pipeline verifies1920x1080=>20736 and319x241=>19360 samples in luma and all RGB channels, plus prior primary-color waveform/false-color regression. /tmp/ztransfer-f154-histogram-20261017.log2/2 TEST SUCCEEDED exit0. Remaining: shared bounded256x192 monitor analysis, zebra nearest-scale sampling positions, nonuniform spatial fixtures and allocation evidence. Full-frame histogram RGBA conversion still exists; no physical memory/performance claim. Count123/182,59 unclosed.

2026-10-17 F154 monitor sampling partial: waveform and false-color share one nearest-neighbor CGContext conversion capped independently at256x192 and one packed pixel buffer; no full-frame conversion per monitor tool. Actual sampled dimensions accompany false-color buffer, original UIImage remains full resolution. Android analyzeMonitorFrame83-100 basis. /tmp/ztransfer-f154-monitor-20261017.log2/2 TEST SUCCEEDED exit0: production decode1080p,319x241,17x300 checks bounded sample counts, output dimensions, color and original dimensions; primary-color regression passes. Static call graph confirms one monitor conversion, no physical allocation profiling. Still open: nonuniform sample-position fixtures and zebra scaling alignment. Count123/182,59 unclosed.

2026-10-17 F154 developer-side completion: luma/RGB histogram share one conversion and two-axis sampling; waveform/false-color share one<=256x192 conversion/packed buffer with actual output dimensions; zebra converts directly to Android ceil-derived grid using nearest scaling instead of old cell-step centers. Final /tmp/ztransfer-f154-spatial-20261017.log1/1 TEST SUCCEEDED exit0 validates319x241 nonuniform black/white source against pixel-center reference: every zebra cell, every false-color pixel, every waveform column and exact histogram bins. Earlier histogram2/2 and monitor2/2 cover1080p, nondivisible/narrow dimensions, sample bounds and unchanged source dimensions. Static allocation audit: one full-sized histogram RGBA buffer only when requested, one bounded monitor RGBA/packed pair shared by both tools, one bounded zebra RGBA buffer; not runtime allocator/RSS profiling. Android RemoteViewfinderFeatures135-163/209-238 and RemoteExposureAnalysis83-110 basis. No UI/device validation. Count124/182,58 unclosed.

2026-10-17 F155 partial NOT closed: zebra refresh50ms instead of250ms; RGB histogram now cached with luma and computed only on shared250ms refresh, immediate refresh if RGB requested but missing. Disabled histogram clears both caches. Android RemoteScreen780-811 and MonitorExposurePerformanceInstrumentation read. /tmp/ztransfer-f155-cadence-20261017.log1/1 TEST SUCCEEDED exit0: black->white after70ms updates zebra while both histograms remain black; after260ms both become white. Test uses real elapsed time; exact threshold boundaries and mode toggles still need deterministic validation. F157 in-flight analysis generation/reset cache issues remain separate. Count124/182,58 unclosed.

2026-10-17 F155 developer-side completion: shared luma/RGB250ms cache, missing-RGB immediate recomputation, zebra50ms refresh. Production default uses ContinuousClock; injected clock permits exact49/50 and249/250ms pixel-result validation with no sleeps. /tmp/ztransfer-f155-boundary-20261017.log1/1 TEST SUCCEEDED exit0 covers boundaries, RGB->luma hiding, off/on clearing and luma->missingRGB immediate refresh of both channels; earlier real-time cadence1/1 passed. Read Android RemoteScreen780-811 and MonitorExposurePerformanceInstrumentation. F157 in-flight configuration/reset/size cache identity remains separate. No UI/device performance testing. Count125/182,57 unclosed.

2026-10-17 F156 partial NOT closed: RemoteView startup now calls shared configureFrameAnalysis before model.start; three preference-change handlers reuse it. Model retains waveform mode/falseColor/histogramRGB alongside histogram/zebra and reapplies full selection at LiveView loop start through one helper; queued updates read current model selection. Android current-mode capture770-815 basis. /tmp/ztransfer-f156-start-20261017.log1/1 TEST SUCCEEDED exit0 verifies all analysis outputs initially and after HD restart without toggling. Still pending persisted-preference initial route, acquisition-error and recording-compatibility recovery verification; F157 in-flight cache/configuration races separate. Count125/182,57 unclosed.

2026-10-17 F156 developer-side completion: startup view calls shared analysis configurator before start; model stores/reapplies complete waveform/falseColor/histogramRGB/histogram/zebra selection on every loop restart. Final /tmp/ztransfer-f156-recovery-20261017.log2/2 TEST SUCCEEDED exit0 covers initial/HD plus preferences saved then reconstructed before acquisition-error and recording-compatibility recovery. Recovery assertions wait for replacement image, verify RGB histogram/waveform and false-color present without retoggling, zebra off preserved. Actual SwiftUI initial wiring statically reviewed and compiled, no UI tests. F157 in-flight mode/cache identity remains separate. Count126/182,56 unclosed.

2026-10-17 F157 partial NOT closed: analysis configuration generation prevents obsolete decode cache writes/publication. If no newer request exists, the latest request is reprocessed with current options so a quiet stream can recover. Reset clears statistics caches and timestamps. /tmp/ztransfer-f157-generation-20261017.log1/1 TEST SUCCEEDED exit0: delayed in-flight luma decode switched toRGB publishes exactly one3-channel result without another packet. Still required: image-size identity/invalidation, reset cached-data verification, off/on and multiple in-flight changes, publication-boundary audit. Count126/182,56 unclosed.

2026-10-17 F157 partial: shared clearAnalysisCache on session reset and image-size identity change; ImageIO header properties identify dimensions before throttle decisions without another image decode. Android MonitorAnalysisThrottle size identity basis. /tmp/ztransfer-f157-size-20261017.log2/2 TEST SUCCEEDED exit0: fixed clock8x8black->12x12white refreshes luma/RGB/waveform/zebra immediately; same-size new session black invalidates all old white caches, cadence regression passes. Still open: queued main-actor publish boundary can outlive actor-side generation check; off/on/multiple in-flight switches and boundary protection require verification. Count126/182,56 unclosed.

2026-10-17 F157 publication boundary partial: per-configuration/session RemoteFramePublicationPermit atomically orders invalidation versus synchronous MainActor delivery; obsolete queued publication is rejected and newest request reprocessed when session still current. /tmp/ztransfer-f157-publication2-20261017.log2/2 TEST SUCCEEDED exit0 covers deterministically queued permit invalidation and in-flight waveform switch. First publication build failed due missing MainActor annotation on callback type; corrected, no tests ran on failed build. Still pending multi-switch/off-on and actual pipeline queued-publication integration evidence, plus final review. Count126/182,56 unclosed.

2026-10-17 F157 developer-side completion: configuration generation rejects obsolete decode/cache results; invalidatable publication permit orders main-actor delivery against mode/session changes; newest frame reprocessed if needed without new packet. Session and header-size changes clear all statistic caches/timestamps. Final /tmp/ztransfer-f157-final-20261017.log3/3 TEST SUCCEEDED exit0: actual pipeline held before delivery through off/on, RGB/luma/RGB and optional reset publishes only one final-mode/current-session frame; fixed-time size/reset and cadence regressions pass. Optional beforePublication barrier defaults nil in production. Earlier generation1/1 and publication2/2 validate in-flight decode and queued permit rejection. Android MonitorAnalysisThrottle mode/size identity basis; iOS actor/main-actor crossing guarded explicitly. No UI/device tests. Count127/182,55 unclosed.

2026-10-17 F158 partial NOT closed: CameraRepository.refreshRemoteProperty routes D10A/D1B1 through RemoteExposureMeter.decode strict signed INT8 scalar validation; other properties retain generic parser. session.execute already rejects negative response before decoding. Android rcReadExposureMeter/rcDecodeExposureMeterValue reviewed. /tmp/ztransfer-f158-wire-20261017.log TEST SUCCEEDED exit0: production PTPSession wire replay both properties with -3 byte, empty,2-byte and4-byte payloads plus existing4 meter tests (5 selected tests total). No control-mode operations issued. Still pending3x700ms capability probing, lifecycle readiness/restart and busy gates; F159 late-response/freshness/expiry separate. Count127/182,55 unclosed.

2026-10-17 F158 probing partial: missing D10A descriptor now retried3 times with700ms after each unavailable result, then D1B1 fallback; present but wrong type/writable descriptor falls back immediately. Cancellation/session generation rechecked between reads and cancellable polling delays. Android RemoteScreen1985-2006 basis. /tmp/ztransfer-f158-probe-20261017.log1/1 TEST SUCCEEDED exit0 verifies missing-primary3 reads and>=2100ms before fallback, invalid-primary1 read, one fallback and signed -1EV. Readiness/lifecycle restart and busy gates still pending; F158 not closed. Count127/182,55 unclosed.

2026-10-17 F158 busy gate partial: shared exposureMeterBusy covers capture, recording operations, AutoISO, held/in-flight half press, tap focus and pending parameter sets; stable recording no longer blocks reads. Capability probes wait in cancellable250ms intervals; polling pauses500ms while busy. Android RemoteScreen busy1989-2013 basis. /tmp/ztransfer-f158-busy-20261017.log2/2 TEST SUCCEEDED exit0: held successful half press blocks probe for550ms and release resumes; stable movie recording produces1EV; retry/fallback regression passes. Still pending lifecycle/readiness restart and additional write-busy evidence; F159 post-await busy/expiry cleanup separate. Count127/182,55 unclosed.

2026-10-17 F158 lifecycle partial: retained meter preference separate from foreground/readiness; initialLoaded, liveViewStable and movieMode transitions restart probe, foreground changes clear/restart, startup RemoteView sends saved meter toggle and scene state. /tmp/ztransfer-f158-lifecycle-20261017.log2/2 TEST SUCCEEDED exit0: USB first frame does not probe before8 successes, stability starts meter, foreground off clears and on reprobes; held-halfpress/stable-recording regression passes. Still verify mode/HD recovery and parameter/AutoISO write gates. F159 late read publication and expiration not yet fixed. Count127/182,55 unclosed.

2026-10-17 F158 developer-side completion: strict signed-byte production meter reads; D10A3x700ms unavailable retry then D1B1 fallback; readiness/foreground/movie/stability lifecycle restarts and busy gates for AF/parameter/AutoISO/recording operations, stable recording allowed. Final /tmp/ztransfer-f158-final2-20261017.log2/2 TEST SUCCEEDED exit0 verifies mode and HD reprobe counts, delayed exposure/AutoISO writes block probes until completion. First final build failed because test camera movie was immutable; changed fixture to simulate physical selector, no tests ran then. Earlier wire5, probe1, busy2, lifecycle2 selected tests passed as documented. Startup saved toggle wired; no UI/device tests. F159 late read publication, monotonic freshness and expiry remain open. Count128/182,54 unclosed.

2026-10-17 F159 partial NOT closed: meter read completion rechecks cancellation/generation/stop and busy before publishing; freshness uses ContinuousClock <1500ms instead of wall time. Nil responses count toward3 failures, successful but out-of-range/stale samples reset failure count like Android; thrown reads terminate. Current-generation defer clears stale reading on termination without erasing newer-generation data. /tmp/ztransfer-f159-cleanup-20261017.log2/2 TEST SUCCEEDED exit0 validates successful sample then exactly3 nil reads clears, USB/foreground regression passes. Pending independent3s expiry with busy refresh, explicit suspended late-response/slow-response/close-open tests. Count128/182,54 unclosed.

2026-10-17 F159 expiry partial: independent cancellable ContinuousClock deadline at request-start+3s clears stale meter even while a camera read remains suspended. Busy polls re-date existing sample like Android; new samples replace timer; disable/stop/terminal cleanup cancel expiry, deinit cancels too. /tmp/ztransfer-f159-expiry-20261017.log2/2 TEST SUCCEEDED exit0: suspended read cannot prevent expiry, disable then released late result stays nil; three-nil failure cleanup regression passes. Test camera now supports one-shot held meter refresh returning captured value despite cancellation. Still pending rapid close/open old-read versus new-generation data, slow-but-successful response and busy-state late-return tests. Count128/182,54 unclosed.

2026-10-17 F159 developer-side completion: post-read cancellation/generation/stop/busy checks, monotonic<1500ms freshness, independent request-start+3s expiry, busy sample extension and current-generation terminal cleanup. Final /tmp/ztransfer-f159-final-20261017.log3/3 TEST SUCCEEDED exit0 covers held response across close/open (new2EV survives old1EV and old cleanup),1600ms successful stale response rejected then fresh read recovers, new half-press blocks late result, held focus retains sample>3s without extra reads, suspended read expires independently and close rejects completion. Earlier cleanup2/2 validates exactly3nil failures and lifecycle. No wall-clock dependency remains in meter loop; no OS clock mutation/UI/device test. Count129/182,53 unclosed.

2026-10-17 F162 implementation updated: removed inner native-buffer aspect fit from RemoteFalseColorOverlay. Resizable image fills outer display-aspect rectangle (effective desqueeze) and remains inside same RemoteZoomableViewfinder as base image. Android FalseColorOverlay uses fitCenterRect(displayAspect) then drawImage into full destination. /tmp/ztransfer-f162-build-20261017.log TEST SUCCEEDED exit0,6 exposure-analysis tests; these verify algorithm regression and compile wiring, NOT rendered geometry. Edge-pattern geometry evidence remains unverified; F162 not closed and count remains129/182,53 unclosed. F160/F161/F163 still require separating basic functional feedback from deferred layout/animation; no visual parity claim.

2026-10-17 F161 functional-density portion fixed: RemoteWaveformOverlay consumes shared waveformPixels using fixed sampled height(min source height,192), logarithmic alpha lookup and Android max-alpha/unpremultiplied RGB combination, replacing per-frame peak normalization and separate overlaid color draws. Android RemoteExposureAnalysis112-126 basis. /tmp/ztransfer-f161-density-20261017.log7/7 TEST SUCCEEDED exit0 includes same-density/different-peak invariance and exact RGB blend0x807FFF00. Actual rendering wiring compiled, not screenshot-tested. Remaining scope/layout/labels and deferred animation not claimed complete; F161 not fully closed. Count129/182,53 unclosed.

2026-10-17 F163 functional portion: RemoteSoundMeterChannel maps current0...14 to rounded0...15 active segments and positive peak to one0...14 index. IOSSoundMeter consumes current bar plus single peak, zero lights nothing, adds L/R. Android SoundMeterChannel3930-3990 basis. /tmp/ztransfer-f163-meter-20261017.log8/8 TEST SUCCEEDED exit0 includes silence,current below/above peak,clamping; rendering wiring compiled, no UI test. Layout overlap/position still to classify for basic usability;80/90ms animation deferred. F163 not fully closed. Count129/182,53 unclosed.

2026-10-17 F164 partial: DISP white-balance retains resolved descriptor independently of nullable scalar refresh, allowing recovery after one missing read. Read and device-model awaits now recheck cancellation/generation/enabled/movie/stop; catch cannot clear newer generation. Android RemoteDispOverlay29-78 basis retains descriptors and omits failed values. /tmp/ztransfer-f164-recovery-20261017.log2/2 TEST SUCCEEDED exit0 verifies initial label->nil scalar->changed recovered label without toggle, existing disable clears. Pending suspended old white-balance/device-model replies and movie-format generation/visibility audit; not closed. Count129/182,53 unclosed.

2026-10-17 F164 movie-format partial: refreshMovieFormat now rejects cancelled, hidden, stopped, non-movie, old-monitor-generation and superseded-read results after the camera await; monitor loop also checks its generation. Android RemoteDispOverlay rememberMonitorMovieFormat lifecycle basis. /tmp/ztransfer-f164-format-20261017.log: 3/3 TEST SUCCEEDED, exit0; uncancellable captured response across hide/reopen cannot resurrect/overwrite label, existing entry/event behavior and stop wire-drain regression pass. Pending WB suspended scalar/device-model and mode-switch evidence; descriptor/scalar polling parity still to audit. F164 remains open; count129/182,53 unclosed. No UI/device tests.

2026-10-17 F164 details lifecycle partial: movieMode changes now restart white-balance monitoring in RemoteViewModel, removing duplicate view callback; new monitoring session clears old label, movie-format read generation invalidates on mode transition. Added uncancellable scalar and device-model read barriers; reopen preserves new label after old responses return. /tmp/ztransfer-f164-details-20261017.log: 3 passed,1 failed because mode test configured still WB rather than independent movieWhiteBalance. Corrected fixture; /tmp/ztransfer-f164-mode-20261017.log:1/1 TEST SUCCEEDED exit0 proves mode transition resolves movie property and discards old scalar without a view callback. Nil-scalar recovery and format reopen regressions passed in details run. Pending movie-format mode-transition held-response evidence and descriptor/scalar polling parity. F164 remains open;129/182,53 unclosed. No UI/device tests.

2026-10-17 F164 developer-side completion: WB retains descriptor after nil scalar, validates ownership after scalar/device-model awaits, clears/restarts on mode transitions in model. Movie-format monitor resolves descriptor once per session, refreshes scalar thereafter, retains descriptor after transient nil and invalidates pending reads on mode change/hide/reopen. Generation-owned task cleanup preserved. Android RemoteDispOverlay29-78,128-153 and RemoteScreen3143 enabled(movieMode) are behavior basis. /tmp/ztransfer-f164-polling-20261017.log5/5 TEST SUCCEEDED exit0: missing scalar recovery without descriptor reread, held old read across photo/movie round trip, hide/reopen, entry/invalid event and stop draining issued wire request. WB suspended scalar/device-model reopen and nil recovery passed details log; corrected independent movie-WB fixture mode test passed mode log1/1. Original details run had1 fixture failure, not claimed wholly green. Ten-second periodic delay statically retained; runtime recovery exercised through property events. No UI/device tests. Count130/182,52 unclosed.

2026-10-17 F165/F167 prerequisite partial: audited production RemoteView and Android LutMonitorState52-65,251-252. Environment was never called; enabling immediately also exposes F166 unsafe Metal initialization/early commit. First corrected monitor state lifecycle: mode/availability changes invalidate candidate and active, unchanged environment preserves pending candidate, hidden tool clears only current mode preference, suspend preserves preference, disposed state cannot reopen or commit. /tmp/ztransfer-f167-lifecycle-20261017.log3/3 TEST SUCCEEDED exit0 (model tests only). Production restoration/loading, environment wiring, GPU presentation acknowledgment and false-color handoff remain incomplete. F165/F166/F167 remain open; count130/182,52 unclosed. No UI/device tests.

2026-10-17 F166 state prerequisite partial: RemoteLUTLayer now carries request/retry identity; renderFailed accepts only active/current candidate identity, grants one page-lifetime GPU retry, skips retry for input color, preserves old active on candidate failure and saved preference on active failure; suppresses automatic failed-choice restoration. Loading remains pending until presented. Android LutMonitorState108-139,220-249 basis. /tmp/ztransfer-f166-state-20261017.log5/5 TEST SUCCEEDED exit0 covers retry identity, duplicate old failures, prior-layer preservation, saved selection and color failure plus lifecycle regressions. Production Metal callback wiring, safe initialization, actual presented-frame acknowledgment and original-image fallback remain unimplemented; existing RemoteView still commits immediately after parse, so F165/F166/F167 stay open. Count130/182,52 unclosed; no UI/device tests.

2026-10-17 F166 production rendering partial: RemoteView no longer calls presented after parse. RemoteLUTImage renders identity-preserved candidate beneath active/source and commits via matching layer presentation callback. Coordinator removes forced device/queue/renderer initialization, reports initialization/encoding/command failures, classifies unsupported input color, ignores disposed callbacks, serializes in-flight frame and routes failures to state retry. Device path requires both command completion and drawable presentation. Initial simulator compile failed because simulator MTLDrawable header omits addPresentedHandler; device header exposes it. Explicit simulator-only fallback accepts command completion, so simulation does not prove actual presentation. /tmp/ztransfer-f166-render2-20261017.log5/5 TEST SUCCEEDED exit0: existing model regression plus production simulator compilation, not device/render fault-injection evidence. F165 environment/restoration still disconnected; F166 remains open pending callback/race/fault verification and render availability handling; F167 false-color handoff still pending. Count130/182,52 unclosed; no UI/device tests.

2026-10-17 F166 presentation ownership partial: production Coordinator uses RemoteLUTPresentationGate to join completion/presentation in either order, reject duplicate/stale frame signals and revoke confirmation on drawable loss/size change. RemoteLUTImage restores source overlay on unavailable; deferred unavailable cannot hide an already re-confirmed surface. GPU failures also require current frame identity. Matching layer request+retry required before candidate commit. /tmp/ztransfer-f166-presentation-20261017.log7/7 and final /tmp/ztransfer-f166-callbacks-20261017.log7/7 TEST SUCCEEDED exit0 cover both signal orders, incomplete frames, invalidation/recovery, old failure eligibility and old-surface presentation after retry. Production simulator wiring compiled; real Metal failure injection and device presentation are not proved by these state tests. F165/F166/F167 remain open,130/182,52 unclosed. Existing LUTIOQueue/PreparedFolder helpers located for subsequent production IO integration.

2026-10-17 F169 load-path partial: RemoteView selection calls RemoteLUTMonitorState.select; byte reads and Cube parsing execute on shared LUTIOQueue detached worker using cancellation tickets and bounded bookmark reads. State owns10s deadline through GPU presentation; invalidation/close cancels ticket and deadline, accepted failures map parser reason, presentation cancels deadline. /tmp/ztransfer-f169-queue-20261017.log9/9 TEST SUCCEEDED exit0: production queue off-main execution, parsed-but-unpresented timeout, presented cancellation of deadline, late uncooperative read rejection, prior lifecycle/render-state regression. Test deadline shortened only via injected timeout. Directory scan remains synchronous in RemoteView; saved restoration/environment not yet wired; parsed cache and further slow-provider/quick-switch tests pending. F165/F166/F167/F168/F169 remain open;130/182,52 unclosed. No UI/device tests.

2026-10-17 F168/F165 scan/restoration partial: RemoteView folder callback now queues transactional prepareFolder instead of saving before synchronous scan. RemoteLUTMonitorState commits bookmark/list/root only after current-generation success; failed replacement preserves old folder/active/selections; same-folder scans remove missing selections, missing/denied existing root clears both preferences. Environment now queues saved mode selection after metadata is available; automatic restore respects GPU suppression. Shared queue and10s deadline used for scan too. /tmp/ztransfer-f168-folder-20261017.log TEST SUCCEEDED exit0 covers detached scan, failed replacement preservation, independent photo/movie restore through actual queue and existing model/hint regressions. Production environment still not connected; missing/modified file refresh, real provider failures and page entry integration still pending. F165/F168/F169 not closed;130/182,52 unclosed. No UI/device tests.

2026-10-17 F165/F167 production entry partial: RemoteView keyed LUT environment now supplies movie, initialLoaded, frame presence, foreground, picker and tool visibility; initialLoaded exposed as published read-only readiness. Picker results defer until foreground and environment update before queued replacement. Background suspends, exit closes/clears callbacks. Successful presentation alone commits false-color off and closes manual menu; enabling false color turns LUT off, menu dismissal invalidates manual candidate, same active selection closes without read/reparse. Opening existing-folder menu rescans. /tmp/ztransfer-f165-entry-20261017.log15/15 TEST SUCCEEDED exit0 includes menu cancellation, presented-only false-color handoff, same-selection reuse and automatic-restore menu behavior, prior folder/load/render-state and hint regressions; production SwiftUI wiring compiled. No UI/device tests; no claim that real document-provider-to-visible-GPU flow was run. Remaining file metadata refresh/cache, provider and renderer fault validation/basic selector states keep F165-F170 open. Count130/182,52 unclosed.

2026-10-17 F168 metadata refresh partial: RemoteLUTFile carries optional modification date, shared folder scanner obtains it, monitor same-folder refresh compares known modification/size and queues changed active LUT while retaining old layer until presentation. Real temporary .cube fixture verifies same-name/same-size overwrite with changed mtime reparses to different digest, old layer retained, subsequent deletion clears photo/movie preferences and active. /tmp/ztransfer-f168-rescan-20261017.log TEST SUCCEEDED exit0 with monitor and catalog regressions. Security-scoped provider access not exercised by local fixture; missing/denied root, queued scan cancellation and restart restoration evidence still to complete before F168 closure. Count130/182,52 unclosed; no UI/device tests.

2026-10-17 F168 developer-side completion: transactional folder prepare/commit, menu rescanning, optional mtime and size reload, missing selection cleanup for both modes, distinct existing-root missing/denied versus transient read, old-generation scan rejection, persisted bookmark/selection restoration through new controller. Android LutMonitorState148-217 basis. /tmp/ztransfer-f168-lifetime-20261017.log14/14 TEST SUCCEEDED exit0 adds injected root errors, blocked old scan versus new folder, recreated-controller mode restoration. /tmp/ztransfer-f168-rescan-20261017.log16/16 proves actual local file same-size overwrite/delete. Scan deadline now marks existing folder read failure only; /tmp/ztransfer-f168-timeout2-20261017.log1/1 TEST SUCCEEDED exit0 covers existing/replacement timeout and late result rejection. First timeout log failed during100ms fixture setup; expanded test deadline1s/slow1.5s, production remains10s. Provider errors are injected at source boundary; real security-scoped provider/device/UI tests not run. F165/F166/F167/F169/F170 remain open for independent entry/render/cache/selector work. Count131/182,51 unclosed.

2026-10-17 F169 parsed-cache partial: shared ParsedLUTCache matches Android8MiB/16-entry LRU and size+mtime validation; missing/changed metadata evicts, overbudget/unknown metadata not retained. Monitor and photo chooser call parseBookmark with scoped access; parseFile refreshes provider metadata even on cache hit, enforces size before hit, caches only unchanged post-read stamp. Tests use real local file/cache read count, mid-read mtime edit and delete plus budget/entry/unknown metadata cases. First two builds failed Swift higher-order nonescaping cancellation exclusivity; simplified optional test read hook, production bounded cancellation unchanged. cache3:18 tests,2 assertions failed in one old40ms timing test; all cache tests passed. Replaced fixed delay with blocked-reader latch and wait for timeout state. /tmp/ztransfer-f169-cache4-20261017.log4/4 TEST SUCCEEDED exit0. Pending rapid selection/queue ownership and scope-denial cache-eviction audit before F169 closure. Count131/182,51 unclosed; no UI/device tests.

2026-10-17 F169 developer-side completion: scan/read/parse now use production shared LUTIOQueue (one active+latest pending), cancellation tickets, generation checks and10s deadline through presentation. Parsed cache shared photo/monitor8MiB/16 entries, provider metadata revalidated each hit, missing/changed/denied metadata evicts, changed-during-read bypasses store; selection state stays independent. Final /tmp/ztransfer-f169-final-20261017.log5/5 TEST SUCCEEDED exit0 verifies revoked scope invalidates cached table and blocked old-page A plus rapid B/C uses only A,C with no second worker/late old publication, plus cache regressions. /tmp/ztransfer-f169-size-20261017.log1/1 passes real sparse32MiB+1 file rejection before cache hit/read. Earlier queue9/9 and corrected cache4 4/4 cover off-main reads, presentation deadline and late uncooperative result. Scope denial injected using production scoped-file boundary; real document-provider syscall cancellation/UI/device not run, blocking IO retains sole worker until return. Count132/182,50 unclosed. F165/F166/F167/F170 independent completion remains pending.

2026-10-17 F170 functional selector partial: RemoteView LUT sheet now provides localized off/folder actions, no-folder guidance/monitor-only text, existing-folder failure/scanning/empty status, category selector with current-selection positioning and retained category, active checkmark and basic pending indicator. Off calls state.chooseOff; no-folder tool opens chooser rather than immediately reopening picker; picker waits for sheet dismissal. Accepted notices retained in model for visible sheet errors and still routed to monitor hint. Android RemoteLutPanel/LutCategoryList basis. Python compared all66 LUT translations across en/zh/hant to Android XML exactly. panel log25 tests had1 failure in old100ms blocked-read test before worker start; increased only test deadline2s/latch10s. /tmp/ztransfer-f170-panel2-20261017.log TEST SUCCEEDED exit0 covers corrected blocker plus panel status/category/hints. No UI tests; popup geometry and600ms breathing intentionally deferred by user. F170 stays open in mixed historical denominator; functional portion implemented, rendered usability not claimed inspected. Count132/182,50 unclosed.

2026-10-17 F166 developer-side completion: parse no longer commits; candidate/active identity-preserved layers keep source/old image until matched presentation; gate requires GPU completion+drawable presentation on device, rejects disposed/stale callbacks, handles surface unavailability. Initialization/encoding errors route to one bounded GPU retry, color failure skips retry; candidate failure preserves old active and saved choice. Renderer resource factories enable fault testing; removed unused duplicate command queue. /tmp/ztransfer-f166-metal-20261017.log2/2 TEST SUCCEEDED exit0 exercises real offscreen Metal shader via texture and sRGB CGImage inputs with exact pixel readback after replacement texture failure, plus nil device, injected pipeline failure and unsupported color. Earlier callbacks7/7/state5/5 prove acknowledgment order, retry identity, failure retention and late callbacks. Production SwiftUI/Coordinator wiring compiled under simulator. Device drawable callback path and rendered layer visibility not exercised; simulator completion fallback explicitly does not prove real display. UI tests skipped per user. Count133/182,49 unclosed. F165 entry integration and F167 full lifecycle evidence remain independent.

2026-10-17 F165/F167 developer-side completion under user functional-only/no-UI-test scope: production RemoteView environment keyed by mode/readiness/frame/foreground/picker/tool visibility, queued folder result, model restoration, close/suspend/menu invalidation, independent mode persistence and presented-only false-color/menu handoff are wired and compiled. /tmp/ztransfer-f165-integration-20261017.log1/1 TEST SUCCEEDED exit0 exercises actual temporary .cube files -> production bookmark creation/resolution -> directory scan -> queue -> bounded read/parser/shared cache -> real offscreen Metal pixel output -> presentation gate/state commit -> controller recreation/movie restore -> background restore -> hidden movie preference removal -> photo restore. Scope admission injected for local fixture and presentation signal modeled; no real document-provider grant, SwiftUI click sequence or drawable display tested. Earlier state/menu/retry/blocked-read tests prove stale completions, failed candidate retains old effect and false-color changes only on accepted presentation. Original F165 UI interaction acceptance remains unrun per user exclusion, not represented as UI validation. Count135/182,47 unclosed; F170 remains mixed visual/basic selector record.

2026-10-17 F171 functional partial: RemoteView now clears/cancels orientation candidate on invalid device directions/background/frozen controls and rechecks foreground/lock/edit state after260ms. During transition latest target retained (including return to previous layout); completion drains pending target; lock/edit clear pending. Android RemoteScreen orientationSession251-270/listener435-480 and conflated channel411-434 basis. /tmp/ztransfer-f171-compile-20261017.log TEST SUCCEEDED exit0 confirms production compile plus unrelated catalog smoke tests; these are NOT orientation behavior evidence. Candidate timing and latest-target state tests still required. Existing80/140ms fade and Task.yield hidden-frame issue not changed; visual timing excluded by user. F171 remains open;135/182,47 unclosed. No UI/device orientation tests.

2026-10-17 F171 functional state verified: RemoteOrientationSession generic value model owns candidate generation/manual suppression/latest pending target and is consumed by RemoteView timers/transition drain. /tmp/ztransfer-f171-state-20261017.log3/3 TEST SUCCEEDED exit0 covers invalid input/pause rejects old ticket even after same direction returns, unchanged direction does not restart stability, manual suppression persists across pause until another valid direction, latest queued return target and frozen discard. Android ON_PAUSE only clears candidate; already queued requests retained consistently. Production260ms task rechecks generation, foreground and lock/edit state. No UI timing/device angle tests; hidden-layout frame/animation remains deferred. F171 mixed record remains open;135/182,47 unclosed.

2026-10-17 F173 developer-side completion: single ScreenAwakeCoordinator owns UIApplication idle-timer writes; application preference and scene activity are wired at ZTransferApp scope, independent of RootView full-screen disappearance. Temporary batch UUID holds OR with latest preference only while foreground. Batch completion/cancel/deinit releases own hold instead of restoring pre-batch snapshot; generation guard preserved. Android MainActivity805 window flag plus LocalPhotoEffectsOverlay268 view hold basis. /tmp/ztransfer-f173-ownership-20261017.log2/2 and /tmp/ztransfer-f173-batch-20261017.log2/2 TEST SUCCEEDED exit0: multiple holders, late releases, preference changes both ways, background completion/foreground return, actual LocalPhotoBatchViewModel authorization-held batch and denied-authorization regression. Source audit confirms only coordinator writes system flag and root navigation no longer owns it. No UI callback ordering or device auto-lock observation claimed. Count136/182,46 unclosed.

2026-10-17 F174 developer-side completion: AppLocalized.resourceLanguage resolves explicit supported choice or preferred-system language list then English default, replacing non-English=>Simplified Chinese. Legacy text, named resource and Root SwiftUI locale share resolver; system locale never mutated, so returning to system re-evaluates preference. Android AppLocale.wrap/forComposition plus default values English basis. /tmp/ztransfer-f174-language2-20261017.log6/6 TEST SUCCEEDED exit0 covers fr/de fallback, en, Hans, Hant/TW/HK, secondary supported locale, explicit choices/system return, legacy Settings mapping and named error resources, monitor hint regression. First language run failed because test incorrectly expected legacy-text mapping for LUT literal only present by resource key; corrected fixture to existing Settings mapping, LUT error resource assertion retained. No OS-language setting mutation/UI tests. Count137/182,45 unclosed.


2026-10-17 F175 partial: DetentWheel now keys its drag surface identity by options, rowHeight, enabled and readOnly, matching Android ReleaseCommitWheel.pointerInput keys (lines226–271). Changes invalidate callback revision and roll preview back to accepted selection; release requires an active drag. Preview row-range construction clamps against the current option count before onChange, preventing invalid ranges when a list shrinks during dragging. Android ReleaseCommitWheelTest read for short-list and release rules. /tmp/ztransfer-f175-compile-20261017.log reports TEST BUILD SUCCEEDED, exit0 (build-for-testing only; no tests executed). Mid-drag reorder/delete, readOnly and disable/re-enable cancellation behavior still needs targeted evidence; F175 remains unclosed. Count137/182,45 unclosed. No UI tests.


2026-10-17 F175 state verification: production DetentWheel uses DetentWheelDragSession for start, preview, release and invalidation. /tmp/ztransfer-f175-state-20261017.log reports TEST SUCCEEDED exit0,2/2: stale revision cannot begin/release after cancellation and another invalidation (ABA), fresh drag works, duplicate release rejected, release requires start, preview clamps, short lists do not produce drag output. The cancellation test repeats the same abstract invalidation path; it does not independently simulate SwiftUI configuration-key changes or gesture callback ordering. Those wiring cases remain source-reviewed only; F175 stays open pending stronger configuration transition evidence. Count137/182,45 unclosed. No UI tests.


2026-10-17 F175 developer-side completion: DetentWheelConfiguration owns the Android pointerInput keys (options/order, row height, enabled, readOnly), shared by recognizer identity and DetentWheelDragSession.update. Each changed configuration invalidates start/revision; returning to original configuration cannot revive old callbacks. Unchanged configuration preserves preview. Session denies disabled/readOnly/short-list admission and duplicate release. View rolls back to accepted selection on configuration change/cancellation and clamps row ranges before onChange can run. /tmp/ztransfer-f175-config-20261017.log TEST SUCCEEDED exit0,2/2: five distinct real configuration transitions (reorder, shrink, height, disabled, readOnly), ABA restoration, fresh drag recovery, duplicate/no-start release, clamp/round and explicit cancellation. Replaces the prior repeated abstract-invalidation fixture. Source review confirms the tested update/begin/preview/release methods are used by production callbacks; short-list click unchanged. Android ReleaseCommitWheel226–271 and its tests are the behavior basis. UI callback scheduling/physical touches not tested per user exclusion, no visual parity claim. F175 developer-side closed;138/182,44 unclosed.


2026-10-17 F176 functional partial: production DetentWheel.wheelRows now derives displayPosition from accepted selectedIndex whenever not actively dragging with matching configuration. Row identity, active state and offset all use that same display position. Rejected/deferred onCommit therefore leaves accepted identity visible; reordered options render its new index immediately, and configuration mismatch hides stale preview before onChange. Android ReleaseCommitWheel348–360 is the behavior basis. /tmp/ztransfer-f176-compile-regression-20261017.log TEST SUCCEEDED exit0,2/2 existing drag-session regressions; this confirms compilation and cancellation state regression, NOT rendered-view evidence. No UI tests or constant-only display tests used as a substitute. F176 remains mixed/unclosed: source-level functional fix recorded, requested visual/animation matching deferred and rendered interaction acceptance unrun. Count138/182,44 unclosed.


2026-10-17 F177 partial: DetentWheel removed suppressNextTap and its uncancelled800ms DispatchQueue task. Controls with long-click now use LongPressGesture.exclusively(before:TapGesture), selecting one action per touch; controls without long-click retain plain TapGesture. Android combinedClickable consumes long-press release and LongPressFeedback supplies feedback only. /tmp/ztransfer-f177-exclusive-20261017.log TEST BUILD SUCCEEDED exit0, build-for-testing only; no tests executed and no physical/SwiftUI gesture scheduling acceptance claimed. Existing450ms threshold intentionally not yet altered: Android uses LocalViewConfiguration.longPressTimeoutMillis, mapping still to establish; progressive hold/cancel/confirmation wiring still pending. F177 remains unclosed;138/182,44 unclosed.


2026-10-17 F181 developer-side completion: removed networking.wifi-info from project.yml entitlement properties, app ZTransfer.entitlements and additionally discovered StoreKit/SimulatorDebug.entitlements (retaining get-task-allow there). Generated pbxproj already points Debug/Release device configurations to app entitlements, Debug simulator override to simulator file; no project regeneration or unrelated changes required. plutil lint both entitlement files and pbxproj passed; rg finds no networking.wifi-info under ios. xcodebuild -showBuildSettings Debug/Release iphoneos confirms CODE_SIGN_ENTITLEMENTS=ZTransfer/ZTransfer.entitlements (/tmp/ztransfer-f181-debug-settings-20261017.log and release-settings log); Release read-only query emitted sandbox CoreSimulator service warnings but returned settings/exit0. /tmp/ztransfer-f181-simulator-20261017.log TEST BUILD SUCCEEDED exit0; codesign -d --entitlements :- on resulting Debug simulator app returns empty entitlement dictionary, no Wi-Fi Information. This verifies simulator artifact only, no device signing/build/install performed and no tests run. Restores explicit2026-09-18 platform decision; no SSID/NEHotspotNetwork calls found. Count139/182,43 unclosed.


2026-10-17 F178 partial: refreshed10 named photo_/local_photo_ resource keys against current Android XML, including LUT-bearing entry titles, intensity/summary, frame settings, coordinates, exposure/lens, mask concentration and watermark type. Independent XML comparison verifies584 existing resource-language pairs; this does not prove all call sites or missing keys. AppLocalized Android escape decoding now single-pass for newline/tab/CR, quoted apostrophe/double quote and backslash; no recursive decoding of literal escaped backslashes. /tmp/ztransfer-f178-resources-20261017.log TEST SUCCEEDED exit0,2/2 existing AppLanguageResolutionTests (locale routing regressions, not new decoder boundary coverage). More call-site/decoder checks pending; F178 unclosed. Correction to original finding: current Android SettingsScreen1116–1121 itself hardcodes loading-range label and n日; iOS matches that baseline, so this is not independently an iOS parity gap. Local reselect/generate call sites still to inspect against current LocalPhotoBatchButton. Count139/182,43 unclosed.


2026-10-17 F178 developer-side completion: current LocalPhotoBatchButton.kt fully read; generation/complete/partial/failure labels already match current Android resource keys, superseding older mismatch claim. Reselect visible text now uses local_photo_reselect with count, same resource/count as Android icon accessibility and existing iOS accessibility; basic text button retained under deferred styling scope. Existing renamed photo labels have no stale literal call sites outside unused legacy lookup entries. Previous584 photo/local resource-language pair XML comparison plus10 corrected keys retained. /tmp/ztransfer-f178-boundaries-20261017.log TEST SUCCEEDED exit0,4/4: all three language routes, LUT entry titles/coordinates/intensity/type, escaped apostrophe/quotes/newline/tab/CR, literal escaped backslash-n, trailing slash and unknown escape preservation. Decoder remains single-pass. Loading-range hardcoded Chinese matches current Android and is not an iOS-only gap. No UI screenshot validation; Android update/license text remains excluded. F178 developer-side closed;140/182,42 unclosed.


2026-10-17 F180 partial: RemoteToolModeCrossfade now overlays each outgoing mode with a transparent UIControl input shield in that mode's bounds, outside opacity. Retained mode ordering unchanged, outgoing content remains noninteractive, incoming content can only receive touches when above an outgoing shield or outside its bounds; no animation changes. Android RemoteToolBar85–95 consumes outgoing pointer events at Initial pass. /tmp/ztransfer-f180-shield-20261017.log TEST BUILD SUCCEEDED exit0, build-for-testing only, no tests executed. Actual hit testing across retained layer order/rapid reversal and parent gesture arbitration remain to verify; no claim of full Initial-pass parity from compilation. F180 stays unclosed;140/182,42 unclosed.


2026-10-17 F180 real hosting verification FAILED: added RemoteToolInputRoutingTests using UIHostingController with real RemoteToolModeCrossfade and UIButton content, checking hitTest through photo->movie->photo and rest. /tmp/ztransfer-f180-routing-20261017.log TEST FAILED exit65,1 test/2 assertions:40ms after movie switch still hit photo-action,30ms after reversal did not hit shield; initial/rest photo assertions pass. Must diagnose hosting window/update delivery versus production routing before accepting shield. Simulator test uses UIView hitTest only, not physical event injection or UI automation. RemoteToolInputShieldView now concrete UIControl subclass for type-level observation. F180 remains incomplete;140/182,42 unclosed.


2026-10-17 F180 developer-side completion: actual UIHostingController hitTest verification now mounts in a real UIWindowScene and converts the rendered UIButton bounds center into host coordinates rather than assuming host center equals safe-area content center. /tmp/ztransfer-f180-coordinates-20261017.log TEST SUCCEEDED exit0,1/1 covering initial photo, incoming movie above old photo, rapid reverse where outgoing movie shield intercepts above incoming photo, and settled photo recovery. Earlier unattached-window run2 failures and scene-only/fixed-coordinate run4 failures retained as invalid fixture evidence, resolved without changing production shield to satisfy assertions. Production overlay outside alpha and original layer ordering match Android outgoing toolbar input ownership; normal target layer remains usable where topmost. No physical pointer injection, gesture recognizer arbitration or UI automation run; evidence is real hosting/hit routing, not alpha-only math. F180 developer-side closed;141/182,41 unclosed.


2026-10-17 F088 developer-side completion after dependency re-audit: SettingsView owns camera PhotoLUTStore, LocalPhotoEffectsView owns local; both inject into controls, PhotoEffectsStore maps scope to role and restores saved recipe before rendering. Android PhotoLutStore64–100 preserves role digest/name/uri/strength/adjustments while folder/favorites remain shared. Strengthened private-snapshot test to use different black/white LUT digests and full local adjustment set, reconstruct both stores after original source deletion, verify exact recipes and disabling camera leaves local intact. /tmp/ztransfer-f088-final-20261017.log TEST SUCCEEDED exit0,4/4 includes actual effects-store restoration/rendering, digest memory independence and live folder/favorite sharing across separate defaults instances. F100/F101 dependencies already implemented; stale F088 waiting status superseded. No UI/device test. Count142/182,40 unclosed.


2026-10-17 F112 developer-side completion: re-audited PhotoFramePlaceResolver and current Android PhotoFrameLocationResolver115–210. Administrative hierarchy,32-entry access-order cache, language/4-decimal coordinate key,60s negative/24h positive TTL, combined queue/backend<=1s deadline, cancellation release and late-result isolation are implemented. Production CLGeocoder wrapper cancellation invokes cancelGeocode on MainActor; callback converts immutable administrative result. Added actual resolver test for same-coordinate en/zh queries and subsequent separate zero-budget cache hits. /tmp/ztransfer-f112-final-20261017.log TEST SUCCEEDED exit0,10/10 across hierarchy, cache boundaries/eviction, active/queued timeout, connectivity loss before dequeue, parent cancellation and language routing. No live Geocoder/NWPath calls exercised; F111 consumer gating/export/page-refresh validation remains independently unclosed, not a reason to misstate resolver implementation as unfinished. Count143/182,39 unclosed.


2026-10-17 F111 production export evidence: TransferQueue.renderFrameFile accepts injectable placeResolver/placeAllowed, defaulting to unchanged shared resolver and live availability closure. Added real source-image/export test for offline->online->offline with a warmed resolver; actual backend call counts0/1/1, all three generated files decode and source bytes remain unchanged. /tmp/ztransfer-f111-export-20261017.log TEST SUCCEEDED exit0,1/1. This proves entrypoint wiring and query suppression, not absence of cached place pixels in final image; strengthen output comparison next. Main/neighbor preview source review confirms shared resolver, live pre/post gate and placeContextKey includes availability only when fields enabled plus app language. Local workbench intentionally disables location fields via scope normalization, so lack of geocoder there is correct. F111 remains unclosed pending remaining consumer/output verification;143/182,39 unclosed. No live network/Geocoder/UI tests.


2026-10-17 F111 export pixels verified: strengthened actual TransferQueue.renderFrameFile test by decoding each exported JPEG and comparing re-encoded image PNG data (excluding source file metadata). Offline before query and offline after warm cache are identical; online result differs, confirming the place contributes actual rendered output while blocked cached place does not leak. Backend counts remain0/1/1 and original bytes unchanged. /tmp/ztransfer-f111-pixels-20261017.log TEST SUCCEEDED exit0,1/1. This is one production export fixture, not every template/UI/network-service coverage. Preview availability refresh and actual callback wiring evidence still to consolidate; F111 stays open,143/182,39 unclosed.


2026-10-17 F111 developer-side completion: actual availability publisher test confirms only effective transitions publish (initialfalse,STA route true,AP false,USB override true,stop false), duplicate path/mode/stop notifications suppressed. /tmp/ztransfer-f111-consumers-20261017.log4/4 TEST SUCCEEDED exit0 includes local all-preset location flags persistence and existing-output bypass. That command mistakenly selected nonexistent PhotoFramePlaceEnrichmentTests; no claim those ran. Corrected /tmp/ztransfer-f111-gating-final-20261017.log2/2 TEST EXECUTE SUCCEEDED exit0 covers pre/post query loss, blocked cache and disabled fields clearing old place while preserving EXIF. Prior real export pixel1/1 and resolver queue checks retained. Source audit: app starts shared monitor; ConnectionViewModel state/session didSet updates AP/USB gate; actual preview observes shared publisher, includes placeContextKey in task/prefetch identity, clears complete/precomparison caches but keeps filteredSource and rejects cancelled publications. Local location fields disabled by scope per Android. Approved default-path+timeout platform difference preserved. No live NWPath/Geocoder or UI scheduling test; these limits are not claimed as verified. Count144/182,38 unclosed.


2026-10-17 F113 developer-side completion: reviewed actual template consumers of locationRows/parameterPosterLocationRows and Android frameLocationRows5701 onward (trim/exact dedup, separate place versus coordinates/altitude). Added actual render matrix for every PhotoFramePreset using no location, city+region only, and single-zero-axis coordinates only; all outputs differ appropriately, proving independent controls reach each renderer. /tmp/ztransfer-f113-templates-20261017.log TEST SUCCEEDED exit0,6/6 including decimal minutes/carry/bounds, coordinate presentation, real JPEG GPS encoding+ImageIO readback, place dedup and parameter-poster row separation. Matrix does not prove long-text glyph completeness or exact visual parity; those remain F116/deferred styling. Existing source-EXIF preservation regressions retained; no live camera/UI test. F113 developer-side closed;145/182,37 unclosed.


2026-10-17 F102 picker cancellation fix: compared Android PhotoLutEditor openFolder/cancelPending and folderPicker cancellation refresh. Both iOS folder-entry buttons now cancel LUTRequestController before opening importer (including chooser-sheet handoff); cancelled/empty importer completion refreshes existing folder. Closing ordinary LUT chooser intentionally does NOT cancel selection: current Android dialog closes immediately after choose while loading continues. /tmp/ztransfer-f102-picker-20261017.log TEST SUCCEEDED exit0,2/2 production request prepared-snapshot cancellation and folder transaction regressions, plus chooser compilation. No document-provider/UI callback simulation. F102 remains open for final remaining edge-case review;145/182,37 unclosed.


2026-10-17 F102 developer-side completion: final source audit confirms PhotoLUTChooser scanning/read/parse/snapshot work runs via shared LUTIOQueue background action; default10s LUTRequestController budget clears state, invalidates generation/ticket and drops late delivery, leaving blocked worker serialized and only latest pending request. Folder prepare precedes commit; failed replacement keeps previous bookmark/files/selection, existing missing/denied root clears current selection; error resources distinguish folder missing/denied/tooMany/read and Cube invalid/unsupported/tooLarge/read. Bounded read guards metadata and actual streamed bytes, scan counts all entries and one category depth. Picker cancel-before-launch/refresh-on-cancel correction retained. /tmp/ztransfer-f102-final-20261017.log TEST SUCCEEDED exit0,8/8 covering snapshot write failure preserves old recipe, uncooperative worker timeout, latest pending/cancel, folder transaction and root-vs-child errors, scan limit/depth/cancel,32MiB exact limit/growth/cancel. Prior picker2/2 covers prepared selection cancelled before acceptance. No real cloud-provider grant/UI simulation; monitor consumers separately verified inF165–F169. Count146/182,36 unclosed.


2026-10-17 F103 functional partial: replaced photo LUT name button with existing DetentWheel, matching Android PhotoLutEditor options=Off+favorite-ordered files+orphan restored current; name labels use duplicate-category mapping and private snapshot fallback, empty activation opens folder, long press opens category chooser, value release chooses LUT or disables. Loading uses wheel's own readOnly state (not just SwiftUI disabled, which does not own custom gesture guards). /tmp/ztransfer-f103-wheel-20261017.log6/6 TEST SUCCEEDED exit0 catalog and drag-session regressions; final readOnly wiring /tmp/ztransfer-f103-readonly-20261017.log TEST BUILD SUCCEEDED exit0 (no tests executed after that single wiring edit). Production entrypoint selection/off and missing-source scan decisions still to consolidate; F103 stays unclosed,146/182,36 unclosed. No UI gesture test; basic layout only.


2026-10-17 F103 pending selection feedback: audited parameter callbacks retain loading guards. PhotoLUTChooser now tracks pendingIdentifier for the name wheel, matching Android pendingUri precedence; success/failure/timeout clears it, scan clears it, shared cancelPending clears both request and pending identity for Off/folder/leave paths. Old generation delivery remains rejected by LUTRequestController. /tmp/ztransfer-f103-pending-20261017.log TEST BUILD SUCCEEDED exit0 (no tests run). Specific host feedback/cancellation interaction still needs verification, so F103 remains open;146/182,36 unclosed.


2026-10-17 F103 developer-side completion: pending selection moved from duplicate view state into LUTRequestController.pendingIdentifier, set with submit(selectionIdentifier:), cleared by common cancel/timeout and accepted delivery before callback. Photo chooser uses shared wheel Off+ordered files+restored orphan option, pending name while readOnly, long-press category sheet/current scroll, localized duplicate labels/status, role Off callback and scan membership clearing. /tmp/ztransfer-f103-state-20261017.log TEST SUCCEEDED exit0,6/6: blocked worker timeout clears pending; superseded waiting request cannot run; latest pending identity survives until result then clears; prepared cancelled selection cannot publish; category/current selection, labels/name ordering and folder status regressions. Test-only timeout500ms improves startup tolerance; production remains10s. Combined existing F095 Off/NP3, F088 role restoration, F102 directory lifecycle and F178 resource evidence covers functional requirements. Final whitespace cleanup only after tests. No UI gesture/provider tests or fine styling claim; shared long-press threshold/feedback issue remains F177 independently. Count147/182,35 unclosed.


2026-10-17 F012/F013 coordinator shutdown evidence: added real GPSCoordinator test with AP block to avoid system BLE/location startup; schedule recovery from Camera not found, disable GPS, release held recovery sleep and deliver late scanning/connecting/ready/disconnected/failed events. State stays disabled/off, preference false, no pending recovery. /tmp/ztransfer-f012-disabled-20261017.log TEST SUCCEEDED exit0,1/1. Does not prove enabled reconnect/current-peripheral delegate races; F012/F013 remain open. F110 audit found previously verified Cube/NP3 eight orientations/transparency and budget now implemented throughF124; remaining high-pixel concurrent peak metrics not rerun or claimed. Count147/182,35 unclosed.


2026-10-17 F012/F013 recovery replacement evidence: enabled GPSCoordinator under AP block schedules two five-second recovery tasks; releasing the cancelled old sleep cannot clear the newer recovery handle or replace its failure message; releasing the current sleep clears its own handle without starting BLE under AP block. Added testSupersededRecoveryCannotClearCurrentRecovery. Host simulator /tmp/ztransfer-gps-recovery-replacement-host-20261017.log TEST SUCCEEDED exit0,3/3 including shutdown late-event rejection and adapter terminal-state cancellation. Initial sandbox invocation exited70 because CoreSimulator was unavailable; no tests executed there. Actual BLE restart/current-peripheral callback races remain unverified; F012/F013 stay open. Count147/182,35 unclosed.


2026-10-17 F012/F013 direct reconnect correction: compared NikonGpsBleClient DIRECT_CONNECT_TIMEOUT_MS=4500 and onConnectionStateChange cancellation/scan fallback. iOS used7000ms and inferred direct ownership from saved UUID plus connecting presentation, incorrectly treating post-connect service-discovery disconnect as direct failure. Reused NikonGPSDeferredAction for a4500ms cancellable deadline; connected clears it, disconnect selects scan fallback only while deadline remains scheduled, connection cleanup cancels it. Deadline callback checks current peripheral object identity and running state. Added production deadline replacement/late-cancel test; /tmp/ztransfer-gps-direct-deadline-20261017.log TEST SUCCEEDED exit0,19/19 GPSProtocolTests. No CoreBluetooth hardware delegate replay; same-peripheral reuse across connections and actual restart remain unverified. F012/F013 stay open;147/182,35 unclosed.


2026-10-17 F012/F013 handshake deadline consolidation: Android enableNextDescriptor and stage2 handling both use7000ms, with saved-identity expiration only for initial response and handshake timeout for stage4. Replaced duplicated raw Tasks with existing NikonGPSDeferredAction, using injected sleep and common cancellation from stop/connection cleanup/stage transition/ID queue. Added production handshake test for initial identity expiry, stage4 error, superseded old timer and ID cancellation. /tmp/ztransfer-gps-handshake-deadline-20261017.log TEST SUCCEEDED exit0,20/20 GPSProtocolTests. Does not exercise physical peripheral callbacks or prove same-CBPeripheral reuse isolation; F012/F013 remain open. Count147/182,35 unclosed.


2026-10-17 remaining-scope ledger correction: reviewed current RemoteView overlays, waveformPixels use, false-color display rectangle, IOSSoundMeter channel mapping, LUT category and RemoteOrientationSession callsites against existing evidence. Updated stale F160–F163/F170–F172 table states instead of leaving “new/unfixed” despite partial implementation. Marked F016/F182 visual-only deferred and F179 material/indication scope explicitly; no fixes or tests claimed by this documentation change. Confirmed actionable basic-usability gaps: sound meter overlaps histogram (F163), recording border lacks connection validity (F172). Mixed cases retain outstanding functional/geometry evidence and deferred visual requirements separately. This is a partial scope reconciliation, not a complete recount:147/182 closed,35 unclosed remains historical count.


2026-10-17 F172/F163 connection validity: Android RemoteScreen ViewfinderCard3701/3706/3773 gates recording border, recording timer and sound meter with connected and movieMode. RemoteView now applies isSessionConnected to all three, and movieMode to timer, preventing stale capture/metadata presentation after disconnect. Final /tmp/ztransfer-monitor-connection-gates-final-20261017.log TEST BUILD SUCCEEDED exit0. No runtime or UI tests executed for these direct conditional edits; no animation/geometry claim. Audio/histogram overlap remains F163; F172 mixed visual placement/timing deferred. Count147/182,35 unclosed.


2026-10-17 F161/F163 basic scope coexistence: read Android MonitorAnalysisOverlays and ViewfinderCard scopeStartInset. RemoteView replaces independent fixed150x72 opposite-corner scopes with shared equal-width slots: leading48 when connected movie audio enabled else8, trailing8,gap6,width clamp1...138,height29% clamp28...76. Histogram only occupies slot with actual data; waveform uses first free slot, matching Android presence rule. Embedded meter occupies x10...42, leaving6pt to scope lane. Common GeometryReader uses actual available bounds; analysis overlay rejects touch interception. /tmp/ztransfer-monitor-scope-lanes-20261017.log TEST BUILD SUCCEEDED exit0. No UI/runtime geometry test; labels/axes, landscape external meter placement and deferred animation remain unclaimed. Count147/182,35 unclosed.


2026-10-17 F161 monitor labels: added shared monitor-only RemoteScopeCard consumed by histogram and waveform. Labels derive from selected mode (RGB/Y′), not available fallback channel count; exact Android ranges0–255 and0–100%. Android ScopeCard height<42 compact rule retained, avoiding labels consuming the short plot. Existing plot algorithms and photo-preview histogram remain unchanged. /tmp/ztransfer-monitor-scope-labels-20261017.log TEST BUILD SUCCEEDED exit0; no UI/runtime rendering tests. Waveform axis labels/grid and histogram drawing parity still require scope review; animations deferred. F161 remains open;147/182,35 unclosed.


2026-10-17 F014 write lifecycle correction: Android delayed altitude refresh checks enabled/cameraReady and maybeSend checks enabled. iOS scheduleWriteIfDue lacked admission gates; late50ms refresh could enqueue after disable and writeCurrentFix changed disabled state to waitingFix. Added enabled/AP/ready admission, separated disabled early return from missing-location presentation, and guarded delayed altitude refresh by captured writeGeneration. Production scheduling test covers disabled normal/forced/failure paths and enabled AP-blocked force; /tmp/ztransfer-gps-write-lifetime-20261017.log TEST SUCCEEDED exit0,21/21 GPSProtocolTests. Ready-peripheral forced-write/ticker end-to-end still unverified; F014 remains open. Count147/182,35 unclosed.


2026-10-17 F014 production coordinator ticker evidence: introduced minimal GPSBluetoothTransport implemented by existing Nikon client (state publisher, identity presence, start/stop/clear/write), plus optional location manager, now and writeSleep dependencies. Production defaults remain CoreBluetooth/CoreLocation/Date/Task.sleep. Test drives enabled coordinator through ready, actual location delegate, GEO bytes83m, controlled ACK, scheduled300s delay with no new fix, advanced clock and actual second payload0m, then disable and late ACK rejection. /tmp/ztransfer-gps-write-pipeline-final-20261017.log TEST SUCCEEDED exit0,22/22 GPSProtocolTests. Initial build failed because old identity test accessed concrete preparePairingIdentity through the new interface; test now retains injected concrete client, no production-only API added. Hardware transport/location are controlled test doubles; real camera not exercised. Forced altitude refresh in-flight path and exact1km boundary remain; F014 unclosed. Count147/182,35 unclosed.


2026-10-17 F014 developer-side completion: Android canReuseGpsAltitude requires positive fix timestamp plus inclusive120s/1000m bounds. Extracted same pure cache policy consumed by resolvedGPSAltitude and added missing timestamp validity; tests cover999.999/1000/1000.001,nonfinite distance,120/120.001 and invalid cached epoch through resolver. Production Coordinator test starts fallback0m write, receives83m then92m while ACK held, proves no concurrent write, then ACK triggers exactly one92m follow-up before five-minute cadence; subsequent ACK produces no duplicate. Combined prior real Coordinator300s ticker/expired0m/late ACK plus actual payload time/near-far tests completes F014 functional acceptance. /tmp/ztransfer-gps-altitude-final-20261017.log TEST SUCCEEDED exit0,24/24 GPSProtocolTests. Hardware Bluetooth/location replaced at boundary; no real camera or UI test claim. Count148/182,34 unclosed; F012/F013 remain independently open.


2026-10-17 F012 developer-side completion: controlled transport now publishes stop-disconnected through actual Combine subscription. Enabled Coordinator tests cover camera-not-found, connect failure, missing-service and ID-confirmation timeout: stop once, preserve policy during late disconnect, exact5s recovery and one restart. Pairing timeout waits for explicit retry. Initial test26 suite failed14 assertions because fake CLLocationManager still registered a system delegate and delivered unsolicited authorization; fake delegate is now controlled, corrected run26/26 passed. Explicitly replaying authorization exposed a real recovery bypass, fixed beginRunning admission to require enabled, no awaiting pairing action and no owned recovery task. Final /tmp/ztransfer-gps-recovery-authorization-20261017.log TEST SUCCEEDED exit0,26/26 including explicit authorization during both waits. Prior scan15s/ID3s/required-characteristic/delegate code evidence and direct4.5s deadline tests retained. Hardware central/peripheral delegates not replayed; same-peripheral/session ownership remains F013, no claim that this closes it. Count149/182,33 unclosed.


2026-10-17 F013 discovery object isolation: Android callbacks gate on current GATT. iOS peripheral identity alone allowed old-service characteristic discovery and same-UUID old PAIR/NOT1 notification objects. Added NikonGPSDiscoveryOwnership consumed by service discovery, characteristic discovery and both notification callbacks; connection cleanup clears it. Current service must match by object identity, notifications must be the registered objects, stale discovery cannot replace registration. Test uses real CBMutableService/CBMutableCharacteristic objects with identical UUIDs across two discoveries and validates replacement/clear rejection. /tmp/ztransfer-gps-discovery-ownership-final-20261017.log TEST SUCCEEDED exit0,27/27 GPSProtocolTests. Initial compile referenced private constants; independent literal UUID fixtures corrected test without changing production access. Not a physical delegate replay: same CoreBluetooth service/characteristic object reuse or late central callbacks still unproven. F013 stays open;149/182,33 unclosed.


2026-10-17 F002 renewed implementation audit: current RootView.VerticalWorkspacePager459–625 delegates gesture settlement entirely to UIPageViewController; no custom scroll delegate/velocity decision exists. Read complete Android HomeWorkspacePager return/nested-scroll logic and HomeWorkspacePagerTest: return distance>=0.30 or(distance>=0.15 and downward velocity>=1200dp/s), reverse velocity rejected; child scroll only hands off unconsumed downward delta after reaching top, and consumes fling before settlement. Entry uses PagerDefaults0.50 positional threshold but retains initialVelocity, so entry is NOT a universal distance-only50% rule. Production replacement must preserve onTransitionBegan/onTransitionSettled discovery ownership, GPS entry block/return allowance and programmatic connection-driven return, and must cover nested scroll handoff. Do not replace UIPageViewController internal scroll delegate without retaining its own implementation, or claim a standalone threshold helper fixes F002. No code/test change or completion in this audit;149/182,33 unclosed. F086 independently rechecked existing12/12 actual ViewModel evidence and remains closed; no redundant edits.


2026-10-17 F002 container implementation partial: replaced UIPageViewController-owned settlement with WorkspacePagingController owning UIScrollView delegate and existing hosting pages. Return uses Android distance>=0.30 or>=0.15 with downward pan velocity>=1200pt/s; entry uses native projected offset with50% threshold (native projection not claimed identical to Compose fling). Shared nested observer tracks initial child offset and forwards remaining downward distance after top, restoring child scrolling on end/cancel. Preserved begin/settle lifecycle and SwiftUI deferred programmatic request coalescing, equal-size layout and GPS scroll admission. /tmp/ztransfer-workspace-pager-tests-20261017.log TEST SUCCEEDED exit0,2/2 covers six Android threshold vectors plus actual UIKit container delegate30%/20% settlement, programmatic page change and duplicate finish suppression. This is controlled controller validation, not UI touch automation. Nested gesture arbitration, connection-driven interruption during drag, lock/cancel and rotation-mid-transition remain unverified; must continue before F002 closure. Initial container build passed; final whitespace-only cleanup after tests. Count149/182,33 unclosed.


2026-10-17 F002 interruption correction: added explicit paging motion ownership (drag/nested/settling/programmatic/interrupted). Programmatic request now takes over active gesture even when its target equals tentative destination; invalidates callbacks before cancelling recognizers, restores child scroll and settles once. Gesture disable marks interruption immediately and defers rollback outside SwiftUI update; a newer programmatic request wins over queued rollback. Late drag-end cannot replace target, and finish requires actual destination offset. /tmp/ztransfer-workspace-interruption-20261017.log TEST SUCCEEDED exit0,4/4 WorkspacePagingTests: prior thresholds/lifecycle plus real controller programmatic takeover/late callbacks and disable rollback/new-request precedence. No UI touch automation. Nested touch arbitration and resize-mid-motion remain unverified; F002 stays open,149/182,33 unclosed.


2026-10-17 F002 resize settlement: WorkspacePagingController already preserves normalized offset during height changes but UIKit pending target remained in old points. After layout, re-anchor pending settle/programmatic movement using new bounds; guard current size, moving state, destination and motion so a later drag/request wins. Final finish rejects callbacks before actual destination reached. /tmp/ztransfer-workspace-resize-20261017.log TEST SUCCEEDED exit0,6/6 WorkspacePagingTests. New real-container tests resize during20% return drag then during pending rollback, verify preserved fraction/new700pt destination/single settlement, and queued resize cannot override programmatic return. No rotation gesture UI automation; nested-pan arbitration and nested drag resize remain unverified. F002 unclosed;149/182,33 unclosed.


2026-10-17 F002 nested handoff/controller evidence: actual recognizer now captures child offset in shouldReceive before recognition slop, avoiding counting child-consumed distance twice. Extracted begin/update/endNestedDrag methods consumed by recognizer; retains100pt child consumption before150pt fast-return distance, restores child on cancel/return/programmatic takeover, rebases translation on bounds changes to preserve fraction. New initial touch discards candidate left by an unrecognized tap; additional touches preserve active candidate. /tmp/ztransfer-workspace-nested-final-20261017.log TEST SUCCEEDED exit0,8/8 WorkspacePagingTests; controlled real scroll-view tests cover child distance, cancel and return, resize then same translation, programmatic takeover and late cancellation. Earlier nested8/8 also passed before stale-touch cleanup. No UI touch automation: UIKit recognizer arbitration and native entry fling equivalence remain unproven. F002 remains open;149/182,33 unclosed.


2026-10-17 F002 entry snap correction: app/build.gradle.kts pins foundation1.7.6. Official source fetch unavailable (web open failed, Google Maven TLS failed); inspected installed foundation-android1.7.6 AAR classes with javap instead. classes.jar SHA25691909bdd0c60559c526733a36b1468dd1ed0cac3be876c7a056c23c1e077890f; PagerDefaults default atMost(1), PagerSnapLayoutInfoProvider calculateFinalSnappingBound uses strict fraction>threshold for closest, LazyListSnapLayoutInfoProvider calculateFinalSnappingItem selects direction at abs velocity>=MinFlingVelocityDp, SnapFlingBehavior static value400. Two-page zero-spacing settled entry therefore uses strict>0.50 at low velocity, direction at>=400; exact endpoint bounds remain on endpoint. Replaced UIKit projected-offset decision with this explicit entry policy using pan velocity in points/sec. /tmp/ztransfer-workspace-entry-20261017.log TEST SUCCEEDED exit0,10/10 WorkspacePagingTests includes eight boundary/direction fixtures and actual container rejects conflicting native projected targets. Disassembly logs /tmp/pager-defaults-1.7.6.txt,/tmp/pager-snap-1.7.6.txt,/tmp/list-snap-1.7.6.txt. No UI touch automation or interrupted-entry equivalence claim; UIKit recognizer arbitration remains F002 open. Count149/182,33 unclosed.


2026-10-17 F002 recognizer arbitration wiring: outer UIScrollView pan explicitly requires nested observer failure; valid child gestures are observed with only the selected inner pan simultaneously, preventing outer native paging competition while child consumes distance. Actual shouldReceive uses prepareNestedDrag(from:) to traverse touched-view ancestors; actual shouldBegin consumes shared direction admission. /tmp/ztransfer-workspace-arbitration-20261017.log TEST SUCCEEDED exit0,11/11 WorkspacePagingTests. New real-recognizer delegate test validates vertical vs horizontal/equal-axis admission, exact inner-pan simultaneous identity, candidate replacement, non-scroll touch cleanup, disable and connection-page rejection. Failure-order call statically inspected; no synthetic physical touch/UI automation performed. Interrupted-entry Compose semantics and final lifecycle integration review remain; F002 stays open,149/182,33 unclosed.


2026-10-17 F002 developer-side functional completion: inspected installed Compose1.7.6 PagerState bytecode positionThresholdFraction=min(56dp,pageSize/2)/pageSize and final snap branches. Entry now uses new gesture translation, not inherited offset, with fractional50%/direction branch,56dp small-travel opposite-bound branch and nearest-bound fallback; actual delegate reads live pan velocity/translation then invokes endPageDrag. Added six interrupted-drag vectors and actual container callbacks into WorkspaceDiscoveryState proving cancelled return stays paused and final connection-page settlement resumes. Initial lifecycle run13 tests had1 failure because setTranslation on inactive native recognizer did not set test input; split gesture reading from production settlement and test the latter directly. Final /tmp/ztransfer-workspace-lifecycle-final-20261017.log TEST SUCCEEDED exit0,13/13. Combined entry/return boundaries, real-container lifecycle, nested distance/restore/cancel/resize, program takeover/late callbacks and delegate admission tests cover current functional scope. No synthetic touch/UI automation, device gesture or animation parity claim; recognizer dependency wiring statically reviewed. User excludes UI tests and fine animation; no such gate falsely recorded as passed. Count150/182,32 unclosed.


2026-10-17 F087 opening snapshot correction: Android LocalPhotoEffectsOverlay captures bitmap/anchor/comparison provider, SettingsScreen3304–3306 uses current comparison only for identical opened bitmap else opening comparison. Existing iOS image identity rule matched, but anchor was live previewAnchor. Added LocalExpandedPreviewSnapshot holding image, initialComparison and anchor; LocalEffectPreview opens this snapshot, fullScreenCover uses its frozen anchor and comparison policy, onDismiss releases it. Clarification to prior notes: late comparison is used while render identity matches, not permanently cached beyond replacement; fallback remains opening comparison, as Android. /tmp/ztransfer-local-expanded-snapshot-final-20261017.log TEST SUCCEEDED exit0,2/2 identity/fallback/anchor tests. Initial compile used nil in LocalPhotoPreviewImages.unfiltered, which is nonoptional; corrected fixture to absent current preview. Production uses rendered-image placeholder until comparison completes; optional snapshot cases are model coverage, not proof of a nil provider path. Full-screen gesture/keyboard and underlying-task lifecycle still unverified; F087 stays open,150/182,32 unclosed.


2026-10-17 F087 expanded-preview geometry: Android PhotoPreview.kt ZoomablePreviewViewport uses 2.5x position-aware double tap, max(4, one-to-one) zoom, centroid-preserving pinch and rotation-fit bounds. PhotoEffectsExpandedPreview now reuses shared placement/zoom/clamp helpers and PreviewPinchObserver; pan offset is applied after rotation, global tap coordinates are converted to viewport coordinates, and single-finger drag is gated while the multi-touch observer owns the gesture. Removed unused gestureStartScale. /tmp/ztransfer-expanded-geometry-final-20261017.log TEST SUCCEEDED exit0,7/7 selected geometry/observer/snapshot tests. These validate shared mathematics and observer lifecycle, not physical gesture arbitration or full-screen keyboard/task lifecycle. F087 remains open; count150/182,32 unclosed. No UI automation or fine animation validation.


2026-10-17 F087 lifecycle evidence: inspected Android LocalPhotoEffectsOverlay onOpen (clearFocus/hide keyboard before snapshot) and iOS LocalPhotoEffectsView onWillOpen (watermarkTextFocused=false before snapshot). LocalPhotoBatchViewModel generation is model-owned, and LocalEffectPreview.onDisappear only closes its preview cache; no batch cancellation is wired to opening/dismissing the preview. This is static ownership evidence, not runtime modal lifecycle proof. Added real-filter/render test closing LocalPhotoPreviewCache then immediately configuring the same source/settings: a fresh frame is rendered and reused, while the opening snapshot and fallback comparison remain unchanged. /tmp/ztransfer-local-preview-reopen-20261017.log TEST SUCCEEDED exit0,4/4 cache/snapshot tests. Modal task cancellation/restart and physical keyboard/gesture behavior remain unverified; do not equate cache reopen coverage to modal behavior. F087 remains open;150/182,32 unclosed. No UI automation.


2026-10-17 F087 developer-side functional completion: added ExpandedPreviewPresentationLifecycleTests using an actual UIHostingController/fullScreenCover with production PhotoEffectsExpandedPreview content. The representative underlying task starts once, is not cancelled on presentation/dismissal, onDisappear remains uncalled (the production cache-cleanup hook), and a released comparison task completes while the cover is present. It is a hosting lifecycle harness, not direct PhotosPicker/LocalEffectPreview UI execution. Initial lifecycle run1/1 passed; final /tmp/ztransfer-preview-modal-comparison-20261017.log TEST SUCCEEDED exit0,5/5 hosting/cache/snapshot tests. Prior geometry/observer/snapshot run7/7 covers the shared zoom mathematics. Production wiring inspected against Android LocalPhotoEffectsOverlay/SinglePhotoPreviewOverlay: ready-image-only tap, focus cleared before snapshot, frozen image/anchor, identity-gated late comparison, dismiss releases snapshot without changing pager selection, model-owned batch unaffected. Current user scope excludes touch UI automation and fine animation; physical keyboard hiding/gesture arbitration and device behavior are not claimed tested. These are validation limits rather than additional implementation gates under the agreed developer functional scope. F087 closed; count151/182,31 unclosed.


2026-10-17 F160 basic exposure feedback: replaced value-only capsule with static right-side exposure scale based on Android ExposureMeterOverlay.kt. Missing/invalid EV retains 19 ticks without a pointer; valid EV maps positive upward across -3...3; beyond-range arrows indicate the overflow direction while accessibility retains actual signed EV (POSIX formatting and normalized negative zero). Zero emphasis uses strict abs(EV)<1/12. Production Canvas consumes RemoteExposureMeterReading, view remains present while tools.meter is enabled, top10/end8 placement separates it from lower scopes/audio. No160ms pointer animation added under user scope. /tmp/ztransfer-exposure-meter-feedback-20261017.log TEST SUCCEEDED exit0,3/3 tests cover missing/nonfinite, positions/endpoints/overflow, actual labels and strict zero boundary. Android protocol RemoteExposureMeterTest reviewed; protocol/lifecycle unchanged. Actual rendered coexistence/short-screen readability remains unverified; F160 mixed entry stays open,151/182,31 unclosed. No UI automation.


2026-10-17 F082 developer-side completion: QueueProgressScope is now module-visible so tests host the exact production subscription component (no behavior change). QueueProgressInvalidationTests hosts40 scopes and sends five actual ObservableObject invalidations per phase: only active row0 updates, subscription moves to17, and with no active row no rows update; parent page does not reevaluate on progress. This measures SwiftUI content evaluation, not GPU drawing or device RSS. Production TransferQueueView uses this component for each item and only structural queue snapshots drive the page; QueueItemView checks task identity before consuming progress. Existing two-subscriber slow-consumer test pauses consumption across100 enqueues, receives100 then101 without replaying old arrays; both streams are bufferingNewest(1), structurally bounding retained queued samples. Android TransferScreen active-only collection and TransferStateTest matching-task merge inspected. /tmp/ztransfer-queue-progress-scope-20261017.log TEST SUCCEEDED exit0,2/2 targeted tests. No UI touch automation or device memory benchmark. F082 closed in developer functional/resource scope;152/182,30 unclosed.


2026-10-17 F046 mid-decode cancellation evidence: extracted synchronous decodeCameraPhotoPreviewContent behind an injectable Sendable codec boundary; production remains the same detached worker/autoreleasepool with cancellation checks before and after codec work and before return. New deterministic test holds an already-entered synchronous codec, cancels it, completes replacement decode first, then releases the old codec returning pixels: old caller throws CancellationError and replacement remains valid. Both codec closures assert non-main-thread execution. This injects the codec to control ordering, not a claim that synchronous ImageIO can be interrupted. /tmp/ztransfer-preview-decode-cancellation-20261017.log TEST SUCCEEDED exit0,3/3 including real JPEG decode bounds (640/1920/2560/4096 landscape and portrait, no upscale/manual orientation) and pre-cancel regression. Android CameraViewModel loadFhdBitmap sampling/background implementation reviewed. Actual sustained paging peak memory/latency still unmeasured; F046 remains open,152/182,30 unclosed. No UI automation.


2026-10-17 F013 adapter callback ownership: centralManagerDidUpdateState now requires self.central identity, consistent with other central connection/discovery callbacks. An unrelated manager can no longer alter state or invoke start. New actual-delegate regression uses an unowned CBCentralManager and checks pending scan state is preserved and stopped state remains disconnected. This is an ownership guard test without a physical camera connection; the pending scan is established through the existing deadline seam. /tmp/ztransfer-gps-central-ownership-20261017.log TEST SUCCEEDED exit0,28/28 GPSProtocolTests. Android NikonGpsBleClient callback GATT identity guards reviewed. Same-object peripheral/service/characteristic reuse across connections remains unresolved evidence; F013 stays open,152/182,30 unclosed.


2026-10-17 F013 retirement fence: inspected installed iPhoneSimulator27.1 CoreBluetooth CBCentralManager.h lines222–224 (cancel is nonblocking, pending commands may complete),343–345 (no more peripheral delegate calls after disconnect),263–267 (adapter loss disconnects/invalidates peripherals). Added NikonGPSConnectionRetirement: explicit stop/direct-connect timeout retire old peripheral before clearing active state; start/scan waits for its terminal didDisconnect/didFail callback, keeps newest deferred request, stop cancels deferred work, unrelated terminal callbacks cannot release fence. Late didConnect for retired peripheral cancels again; discovery cannot bypass retirement. Adapter-state loss invalidates fence. Do not use peripheral.state==disconnected as proof its terminal callback has already run. Also avoid cancelling an existing direct-reconnect deadline merely on repeated start. Existing Android GATT identity behavior remains functional reference; this serializes CoreBluetooth reuse against its documented terminal boundary. Final /tmp/ztransfer-gps-retirement-final-20261017.log TEST SUCCEEDED exit0,29/29 GPSProtocolTests; new ownership model regression covers exact owner, latest request, stop retaining fence and adapter invalidation. Earlier /tmp/ztransfer-gps-retirement-20261017.log passed before final discovery/disconnected-state guards; final run includes those changes. Actual client callback integration across a reused peripheral still needs evidence, so F013 stays open,152/182,30 unclosed. No camera/device connection or UI automation.


2026-10-17 F013 synchronous-publication reentry: retirement test proves a completion may immediately start/stop the same owner and cannot clear its newly-created fence. Audited client publications: connect/scan/discovery commands and handshake/deadline registration now precede state notifications, so a synchronous subscriber stop cancels registered work instead of later code recreating it. Added publishConnecting with identity recheck between identifier/state; restoration stores its manager before notifying. Business statePublisher now uses CurrentValueSubject emitted from state.didSet (UI @Published retained), preventing willSet notification from overwriting a nested stop with the older scanning state. Actual client scan-state subscription calls stop synchronously; regression proves observers see committed state, registered deadline task is cancelled, released late sleep cannot execute its action, and final state remains disconnected. First publication-final and committed-publication runs failed the fixture assumption that a cancelled injected sleep is never entered; GPSDeferredClock deliberately ignores cancellation. Corrected test inspects Task.isCancelled after releasing the clock and checks final state/action, without relaxing behavior. Final /tmp/ztransfer-gps-publication-verified-20261017.log TEST SUCCEEDED exit0,31/31 GPSProtocolTests. /tmp/ztransfer-gps-retirement-reentry-20261017.log2/2 also passed earlier. Full actual peripheral callback integration remains pending; F013 open,152/182,30 unclosed. Also corrected stale F116 table status from unimplemented to in progress based on existing renderer/plaque/reference-width code and detailed historical evidence; no count change. No device/UI automation.


2026-10-17 F116 plaque horizontal measurement: Android PhotoFrameExporter measured-template firstExtra/secondExtra/pairedColumns/extraWidth and fixed text offsets inspected, plus PhotoFrameWidthTest. PlaquePlan now retains reference left offset and footer width, independently expands paired columns while preserving their gap, expands canvas width and shifts original-size photo to integer x; preview scaling carries all plan fields. Found metadataDescriptionRows previously fitted oversized graphemes before measuring, hiding required expansion. Added opt-in preserveUnbreakableWidth used only by plaque descriptions; existing other-template paths unchanged. First /tmp/ztransfer-plaque-width-overflow-20261017.log failed new overflow assertion (extraWidth0), exposing early fitting; final fixture uses an unbounded metadata identity grapheme (watermark text has its own length cap). /tmp/ztransfer-plaque-width-final-20261017.log TEST SUCCEEDED exit0,4/4: long indivisible Devanagari identity drives actual export width, column gap and scaled-plan widths; existing tall-right-column signature ownership,60/100/200 margins and30 original-interior pixel configurations pass. Pixel configurations cover existing long descriptions, not the new extreme-grapheme export; actual preview/full glyph-tail and overflow image-pixel matrix still pending. F116 remains open,152/182,30 unclosed. No UI/animation validation.


2026-10-17 F116 plaque overflow pixel/preview evidence: added actual export matrix with both model identity and exposure field containing an indivisible80-consonant Devanagari grapheme. For81x61 and61x81 photos at60/100/200 frame widths, output expands horizontally; cropping the expected integer-shifted photo interior returns exactly the original RGBA bytes, and actual128px preview dimensions equal rounded scaling of final output canvas. /tmp/ztransfer-plaque-overflow-pixels-20261017.log TEST SUCCEEDED exit0,2/2 including earlier column expansion test; new test covers six actual exports/previews. This proves interior photo preservation and preview proportions under overflow, not full text-tail visibility, all templates, or device performance. F116 remains open,152/182,30 unclosed. No UI automation or style/animation work.


2026-10-17 F116 standard non-glass horizontal measurement: Android calculateMeasuredFrame2080+ uses reference-font widths, actual available column minus fixed reference inset, and expands side margins for unbreakable rows; frosted explicitly does not expand. Mist/cinema/minimal now preserve unbreakable identity/description widths, wrap against actual widthPercent-dependent space, expand canvas by measured maximum plus reference insets, and shift original photo by integer pixels. Left/right watermark placement uses the same reference inset. frameIdentityRows gained opt-in preservation (default unchanged elsewhere); frosted retains its separate existing path pending independent audit. /tmp/ztransfer-standard-width-overflow-20261017.log TEST SUCCEEDED exit0,4/4: new three-template×60/100/200 actual export/preview matrix expands for a long indivisible identity; existing no-font-shrink identity split, standard/plaque margin, and30 internal photo pixel configurations pass. No claim of complete extreme-glyph tails or frosted parity; F116 open,152/182,30 unclosed. No UI automation or fine styling.


2026-10-17 F116 frosted fixed-column behavior: Android calculateMeasuredFrame uses photo-width column880/1000 with60/1000 inset, frostedMetadataPanelBounds uses photoLeft/photoRight, and MeasuredFrameText.positionFrameRows rejects oversized rows instead of shrinking or expanding glass. iOS panel now follows photo bounds, all glass description/identity rows measure against88% photo width, watermark side inset is6%, unbreakable rows retain measured width, and render rejects an oversized glass column with PhotoFrameColumnOverflow before preview scaling/output allocation. Error description mirrors Android Frame information exceeds its column. /tmp/ztransfer-frosted-column-20261017.log TEST SUCCEEDED exit0,4/4: normal long glass text expands height but not width across60/100/200; indivisible oversized identity fails both export and128px preview; prior non-glass expansion/margin and long-content allocation tests pass. This is measurement/failure parity and basic panel geometry, not glass material/style validation. F116 remains open for other template/full-tail matrices;152/182,30 unclosed. No UI automation.


2026-10-17 F116 horizontal ink: compared Android MeasuredFrameText FrameTextRun.width/positionFrameRows with iOS row width (typographic advance only). Added PhotoFrameTextRow.layoutWidth including outer ink overhang; fitting reuses equivalent extent. Standard/plaque maximum column measurement and glass rejection now use layoutWidth, and their text alignment compensates negative left ink before drawing. Other template positioning remains unchanged; this does not establish per-run mixed-font spacing parity. /tmp/ztransfer-frame-ink-width-20261017.log TEST SUCCEEDED exit0,5/5: italic f/j/Af/ffj/Áf includes actual overhang, scaled/fitted extent invariant, plus glass fixed-width failure and standard/plaque extreme export/preview/photo-interior regressions. Entire F116 template/tail matrix not yet complete;152/182,30 unclosed. No UI automation or fine styling.


2026-10-17 F116 standard/plaque tail evidence: new actual-render matrix uses identical long camera-model prefix and changes only terminalAAA/ZZZ. Across mist/cinema/minimal/frosted/plaque,240x160 and160x240,60/100/200 width settings, export and512px preview (60 paired comparisons/120 renders), paired dimensions remain identical and encoded raster output changes. This establishes tail influence with stable geometry, not OCR-level glyph completeness or cross-platform font pixels. /tmp/ztransfer-frame-identity-tail-20261017.log TEST SUCCEEDED exit0,1/1 matrix test. Other editorial templates retain independent measured-column/font rules and are not covered by this completion evidence. F116 remains open,152/182,30 unclosed. No UI automation or animation work.


2026-10-17 F116 GalleryMat measured-column audit: inspected Android PhotoFrameExporter.calculateMeasuredTemplateFrame2198–2475 and current iOS expandedStandardLayout/galleryMetadataArea/editorialMetadataPlan. Android uses a fixed1000-photo-width reference: identity28, details20, information column900 at offset50, signature column884 at offset58; an unbreakable row expands side margins before square completion. Gallery identity is regular weight, combined identity run gap12; general gap10*clamp(percent/100,0.65,1), combined identity gap1.5x. Clearance=min(1000,photoHeight)*0.045+12 and padding20*clamp(percent/100,0.65,1); minimum side/top margins include clearance+padding. Square surplus is divided equally horizontally and45/55 vertically, after measured horizontal and vertical expansion. iOS currently derives typography/wrapping from84% of the already-sized canvas (font2.4%, text column90%, signature48%), fits indivisible rows before measuring, and only expands height before square completion. Thus an arbitrary horizontal-expansion-only patch would retain incorrect font/wrap reference and can hide data by shrinking. Existing testLongStandardMetadataExpandsCanvasAndBudgetTogether proves square expansion for breakable words and budget growth, not preservation of indivisible rows or fixed reference fonts. Next implementation must use a dedicated GalleryMat measured plan with distinct information/signature columns and preserved row widths, plus explicit unbreakable-row export/preview and photo-pixel checks; do not generalize these constants to other editorial presets. Static source audit only; no build/test run in this audit. F116 remains open;152/182 closed,30 unclosed. Styles/animation and UI automation remain outside this phase.


2026-10-17 F116 GalleryMat measured layout implementation: replaced generic canvas-relative editorial fitting with a dedicated fixed1000-photo-width measurement/positioning path. Identity28/detail20, information900/signature884, reference-font watermark, original margin scaling/minimum clearance/padding, measured overflow side expansion then square completion45/55 follow Android calculateMeasuredTemplateFrame. Stores positioned rows and scales those exact rows/coordinates for previews, avoiding rewrapping or refitting after expansion; negative outer ink compensated at draw. Combined identity half-gap only applies to a row fitting the original column. /tmp/ztransfer-gallery-measured-final-20261017.log TEST SUCCEEDED exit0,2/2: new six-configuration actual export/128preview test (161x121/121x161 at60/100/200) shows indivisible80-consonant identity expands square beyond normal identity, and existing long-standard metadata square/height/allocation-budget regression passes. Earlier initial run also2/2; final run follows identity-gap edge correction. Does not yet prove GalleryMat original-photo pixels, complete glyph tails, logo/per-run spacing or signature placement matrix; other editorial templates remain independent and F116 stays open. Count152/182,30 unclosed. No UI automation/style/animation validation. Automatic review rejected the initial combined test-edit/build command as potentially deleting following tests; replaced with an explicit insertion patch preserving existing methods, then ran build separately successfully. No approval remains blocked.


2026-10-17 F116 GalleryMat raster preservation/tail evidence: expanded testExpandedFramesKeepOriginalPhotoInteriorPixels to use an indivisible80-consonant identity plus long lens metadata for GalleryMat, three source sizes80x60/81x61/61x81 and60/100/200 widths. Exact RGBA search finds the original16px-inset photo interior intact in all nine gallery exports; existing27 other-template pixel cases remain passing. Expanded/renamed testStandardPlaqueAndGalleryLongIdentityTailReachesExportAndPreview adds GalleryMat to the long-model terminalAAA/ZZZ comparison: six templates×two orientations×three widths×export/512preview =72 pairs/144 renders, equal geometry and different raster output. /tmp/ztransfer-gallery-pixels-tail-20261017.log TEST SUCCEEDED exit0,2/2. This proves original interior preservation under gallery horizontal overflow and tail influence in export/preview, not OCR completeness, edge decoration pixels, all-field watermark/Logo combinations or cross-platform font pixels. Only indentation cleanup after the passing run. F116 remains open;152/182 closed,30 unclosed. No UI automation or animation validation.


2026-10-17 F116 GalleryMat Logo/signature functional matrix: added testGalleryLogoAndSignaturePositionsPreserveTailAndDisableState with Nikon Logo and long model, maximum-size text watermark,240x160/160x240 photos,60/100/200 borders, original export/512preview. Twelve configurations assert AUTO raster equals CENTER, LEFT/RIGHT differ at equal geometry, terminalAAA/ZZZ affects raster at equal geometry, disabled watermark differs from enabled and ignores changed text/position, and output remains square. /tmp/ztransfer-gallery-signature-20261017.log TEST SUCCEEDED exit0,1/1 matrix (84 renders). Tests exercise a logo-bearing configuration but do not independently prove vector appearance or all brand per-run metrics; these are not visual approval. GalleryMat measured overflow/photo interior/identity-tail/signature controls now have targeted evidence. Other editorial templates still use independent fitting/height-only plans (filmGallery, filmNegative, filmEdge, classicSignature, colorArchive, brandGallery); continue auditing these against their Android measured columns, not by inheriting GalleryMat constants. F116 remains open;152/182 closed,30 unclosed. No UI automation/animation validation.


2026-10-17 F116 FilmGallery measured information: Android calculateMeasuredTemplateFrame2334+ moves non-fitting strip identity/date into900-reference-width information column, identity bold21/details21, separate884 signature, clearance110, fixed90 film bars with only160/340 outer margins scaled by width percent. Reused GalleryMat measured rows/positioning with explicit FilmGallery branches for typography, field order, strip ownership, margins, rectangular canvas and reference watermark size; removed obsolete canvas-relative filmGalleryPlan/area. Long indivisible text now expands side margins before output; preview scales stored rows and strip plan. /tmp/ztransfer-film-gallery-measured-20261017.log TEST SUCCEEDED exit0,5/5: expanded two-gallery×two-orientation×60/100/200 overflow/export-preview test; strip-preview decisions/ink-size; long-content canvas/budget; existing36 photo-interior pixel cases; GalleryMat84-render signature controls. FilmGallery extreme-overflow photo pixels/tail/signature combinations still need dedicated coverage; existing strip run spacing/placement not independently corrected by this change. Only comments/indentation adjusted after tests. F116 remains open;152/182 closed,30 unclosed. No UI automation/style/animation verification.


2026-10-17 F116 FilmGallery extreme-content matrix: extended existing real-render tests to FilmGallery rather than duplicating test bodies. Photo-interior test now covers both galleries with indivisible80-consonant identity and long lens data,80x60/81x61/61x81 at60/100/200 (18 gallery cases plus24 other-template cases): exact original16px-inset RGBA region is retained. Long identity terminalAAA/ZZZ export/512preview comparison now covers seven templates×two orientations×three widths×two output modes=84 pairs/168 renders with identical pair geometry and changed raster. Logo/signature controls now cover both galleries, Nikon Logo/long model/maximum text watermark,24 configurations/168 renders: auto=center, left/right difference, tail influence and disabled text/position independence. /tmp/ztransfer-film-gallery-matrix-20261017.log TEST SUCCEEDED exit0,3/3. Confirms sampled original interior preservation and functional output, not OCR completeness, edge decoration, all brands or Android/iOS font-pixel equivalence. Remaining F116 work includes other editorial presets and strip per-run metric/placement audit. Count152/182 closed,30 unclosed; no UI automation or animation validation.


2026-10-17 F116 FilmGallery strip capacity: Android stripTitle uses distinct brand/model runs with6/1000-photo-width gap and full measured row width. Replaced iOS space-concatenated cameraIdentityRow with existing frameIdentityRow and explicit0.006 gap; identity/date capacity checks now include outer ink through layoutWidth. This affects strip-vs-information-band decisions, not just styling. /tmp/ztransfer-film-strip-metrics-20261017.log TEST SUCCEEDED exit0,4/4: new independent brand-only/model-only/combined width relation for text and Logo at160/1000 references; long identity exits strip; stored preview decisions/ink size; date width/missing date. No claim of all mixed-run ink spacing or decorative strip baseline pixel parity. F116 remains open for other editorial templates;152/182 closed,30 unclosed. No UI automation or animation validation.


2026-10-17 F116 FilmNegative measured caption: Android calculateMeasuredTemplateFrame2369+ keeps identity in decoration and uses only lens/exposure/date/location in900-wide information column, fixed18 reference font, clearance42, minimum bottom=max(base160*p,170*p+informationHeight+2*padding), independent884 signature. Integrated negative into shared measuredCaptionLayout/PositionedCaptionRow (renamed from gallery-specific names), with explicit per-preset margin switch; negative identity never added to caption, negative ink/font and original1052×(photoHeight+220) watermark reference preserved. Removed generic canvas-relative negative fitting/area helpers; stored row positions drive export and preview. /tmp/ztransfer-negative-measured-20261017.log TEST SUCCEEDED exit0,5/5: three measured presets×two orientations×60/100/200 unbreakable-content expansion/preview; negative field visibility; Unicode lower-band tail and preview; classic/negative long-description growth;42 existing original-interior pixel cases. Negative maximum-watermark/extreme-aspect matrices still pending; no claim of all-template completion or font-pixel equivalence. F116 open,152/182 closed,30 unclosed. No UI automation or animation validation.


2026-10-17 F116 measured-caption extreme aspect/signatures: expanded the GalleryMat/FilmGallery/FilmNegative unbreakable identity-or-lens export/preview matrix to161x121/121x161/320x40/40x320 at60/100/200 (36 configurations). Normal proportions require strictly wider canvas; extreme proportions require nondecreasing width because existing margins/square completion can absorb extra measured width; all validate final-preview proportion. Expanded renamed testMeasuredCaptionSignaturesPreserveTailAndDisableState to all three presets at240x160/160x240/320x40/40x320, three widths, export/512preview (72 configurations/504 renders), maximum-size text, Logo-bearing identity: auto=center, left/right output differences, terminalAAA/ZZZ influence at equal geometry, disabled text/position independence. Initial captions-extreme-signatures log failed three strict-width assertions on unchanged760/369/46px canvases while signature matrix passed; this was an overstrong fixture expectation, corrected to Android max/space-absorption rule rather than altering production layout. /tmp/ztransfer-captions-extreme-signatures-final-20261017.log TEST SUCCEEDED exit0,2/2. Does not independently establish OCR/glyph completeness or prove font size through raster measurements; no production edits this turn. Other editorial presets remain open. F116 unclosed;152/182 closed,30 unclosed. No UI automation/animation validation.


2026-10-17 F116 FilmEdge measured compact caption: Android2353+ uses900 reference column,16pt condensed caption with brand/tail gap12*p, then bold identity fallback plus regular combined details and location rows; width overflow expands margins, no band signature. iOS filmEdgePlan now returns rows plus fallback identity extra gap, preserves unbreakable widths and outer ink, and uses900 instead of940 column. Shared measuredCaptionLayout now has FilmEdge margin rules(left>=42,top35*p,bottom>=85*p and content+padding), fixed-reference positions and preview scaling; removed old fitted drawFilmEdgeInformation. Photo-placed watermark path unchanged. /tmp/ztransfer-film-edge-measured-final-20261017.log TEST SUCCEEDED exit0,5/5: four templates×four aspects×three widths unbreakable export/preview; compact caption fallback; Logo/missing fields; Unicode lower-band tail;42 existing photo-interior pixel cases. Initial film-edge-measured log failed old exactly-two-row expectation(actual5 after font/column correction) and six80-consonant fixtures that did not exceed the smaller16pt column. Updated breakable-row expectation to multiple rows each<=900 and strengthened indivisible fixture to160 consonants; retained strict ordinary-aspect expansion. Does not prove all glyphs/brands or FilmEdge extreme photo-pixel/signature combinations; remaining colorArchive/brandGallery/classicSignature measured audit still pending. F116 open,152/182 closed,30 unclosed. No UI automation/animation validation.


2026-10-17 F116 ClassicSignature independent header/caption: Android measured-template header uses900 photo-reference column at1060*0.034 font, body900 at1060*0.024; header height expands top, maximum header/body/signature width expands side margins, original photo preserved. Routed classic through shared measuredCaptionLayout with separate header rows,30/95/150 reference margins, header+padding top minimum, header width included in horizontal expansion, centered positioned header independent of bottom caption. classicHeaderPlan now preserves unbreakable width, uppercases only brand and uses explicit12 reference run gap; removed obsolete headerPlan/fitted classic draw/area path. AUTO watermark remains photo placement; explicit non-photo text signature is measured below. /tmp/ztransfer-classic-measured-20261017.log TEST SUCCEEDED exit0,4/4: five presets×four aspects×three widths unbreakable-content/preview matrix; long text/Logo header expansion; long bottom-description growth;42 existing original-photo-interior pixel cases. Dedicated classic maximum signature/combined huge header+body output still pending; does not establish all-brand ink/visual parity. F116 remains open;152/182 closed,30 unclosed. No UI automation/animation validation.


2026-10-17 F116 ClassicSignature combined output evidence: added testClassicCombinedHeaderBodyAndSignatureTailsReachExportAndPreview with Nikon Logo, simultaneous long model/long lens and maximum-size right signature;240x160/160x240,60/100/200,original/512preview (12 configurations48 renders). Individually changing only model/lens/signature terminalAAA toZZZ changes raster with unchanged geometry; preview longest edge stays512. /tmp/ztransfer-classic-combined-tails-20261017.log TEST SUCCEEDED exit0,1/1. Establishes each content tail contributes to actual output under combined layout, not OCR-level completeness or exact platform font pixels. No production changes. Remaining F116 measured work includes ColorArchive and BrandGallery and audit of unsupported/legacy fit paths.152/182 closed,30 unclosed; no UI automation/animation validation.


2026-10-17 F116 BrandGallery measured identity/signature: integrated into measuredCaptionLayout with original1064 reference design, identity bold1064*0.052/900 column/uppercase brand, margins32/32/160 scaled by width, independent884 signature positioned before identity, adaptive signature coerced black; AUTO remains photoBottomRight. Removed obsolete BrandGalleryPlan fitted renderer. /tmp/ztransfer-brand-gallery-measured-20261017.log TEST SUCCEEDED exit0,5/5: six presets unbreakable matrix, brand signature size/preview, standard+brand signature alignment/tail, long-content budget,42 original interior pixel cases. Found direct-render widthPercent was not normalized in new shared path although makeLayout normalizes; now measuredCaptionLayout and filmEdgePlan reuse normalizePhotoFrameWidthPercent. /tmp/ztransfer-caption-width-normalization-20261017.log TEST SUCCEEDED exit0,2/2: six presets actual PNG equality for-100/20 vs60 and300 vs200, plus brand signature regression. This is parameter normalization parity, not new UI validation. Brand signature-first order follows Android code but dedicated spatial order fixture still pending; ColorArchive measurement remains unfinished. F116 open,152/182 closed,30 unclosed. No UI automation/animation validation.


2026-10-17 F116 ColorArchive fixed column: Android measured-template2326+ uses680 reference information column at offset0, identity27/lens19.5/detail22/date+location18.5, gap170*0.055*min(p,1), left alignment and minimum palette-height38+2*padding. Integrated colorArchivePlan into measuredCaptionLayout with explicit40/40/170 margin rules, measured overflow, no band signature, stored left-aligned rows; removed fitted drawColorArchiveInformation. Plan now preserves indivisible widths and uses680 instead of707. Palette stays anchored to photo.right as Android colorArchivePaletteRect4318 dictates; no alternate collision policy invented. /tmp/ztransfer-color-archive-measured-20261017.log TEST SUCCEEDED exit0,4/4: seven presets×four aspects×three widths overflow/export-preview; width boundary normalization including ColorArchive; long-content budget;42 existing original interior pixel cases. ColorArchive complete tail/field/Logo/palette spatial matrix and remaining shared-layout audit still pending, so F116 remains open.152/182 closed,30 unclosed. No UI automation or fine-style/animation validation.


2026-10-17 F116 obsolete editorial fitting cleanup: repository call-site search confirmed expandingEditorialBand/drawMetadataRows no production callers after template migration; editorialMetadataPlan had only its obsolete helper/test callers. Removed these methods and Layout.editorialPlan/editorialGap. Replaced testEditorialPlanMeasuresBeyondExistingBandHeight (only tested unused implementation) with actual testColorArchiveLongFieldsReachExportAndPreview: Nikon Logo+simultaneous long model/lens/city,240x160/160x240,60/100/200,export/512preview (12 configurations48 renders); each terminalAAA/ZZZ change influences output independently at identical geometry. /tmp/ztransfer-caption-cleanup-color-tails-20261017.log TEST SUCCEEDED exit0,2/2 including seven-preset unbreakable/export-preview matrix. This strengthens production-path coverage; does not claim OCR/full ink or palette spatial proof. Remaining fitting calls belong to in-photo brand/immersive or film decoration paths and require separate Android policy audit before F116 closure.152/182 closed,30 unclosed; no UI automation/animation verification.


2026-10-17 F116 brand photo-space behavior: inspected Android measured brand metadata2488–2542 and placer5280+. Unlike outer bands, in-photo rows wrap at780 reference width with short-edge-clamped fonts and never use the legacy overlapping fallback: height beyond photo rejects, width beyond clamped area rejects, watermark overlap rejects. iOS drawBrandInsetMetadata now uses separately wrapped brand/model at fixed gap and short-edge-clamped43/19/21 fonts; BrandGallery details use matching short-edge caps. drawBrandRows removed row fitting and fallback inset shrink, measures layoutWidth, throws PhotoFrameBrandLayoutError.insufficientHeight (Android default Failed requirement.), PhotoFrameColumnOverflow, or watermarkOverlap exact Android message, propagating through existing renderError. /tmp/ztransfer-brand-photo-overflow-20261017.log TEST SUCCEEDED exit0,3/3: both brand presets normal/300-word too-tall/160-consonant too-wide actual export+512preview, plus42 photo-interior cases and seven-template measured expansion matrix. Watermark bounds currently still use existing approximate text-only brandWatermarkBounds; image watermark geometry and fitted text bounds must be audited before collision parity can be claimed. In-photo preview remeasurement and immersive policy audit also pending. F116 open,152/182 closed,30 unclosed. No UI automation/animation verification.


2026-10-17 F116 brand watermark occupied geometry: Android layoutPhotoWatermark2733+ uses fitted glyph ink plus shadow18%font/outline max(1,7.5%font) padding and image bounds. Replaced approximate text-only brandWatermarkBounds with throwing photoWatermarkOccupiedBounds: text reuses production photoWatermarkTextLayout, effects expand ink bounds; image reuses shared validated cached image loader and photoWatermarkImageRect also consumed by drawWatermark. drawBrand now obtains both content kinds' occupied bounds and propagates invalid-image errors. /tmp/ztransfer-watermark-occupied-20261017.log TEST SUCCEEDED exit0,3/3: fitted24W text safe-right/bottom geometry, NONE/SHADOW/OUTLINE/AUTO occupied containment, disabled nil; actual imported400x2 image clamps width preserving200:1 aspect and margins, invalid hash throws; brand normal/height/width failure regression. Actual crowded text/image render displacement/overlap matrix still pending; no claim of full watermark reference-size parity or all effect raster extents. F116 open,152/182 closed,30 unclosed. No UI automation/animation validation.


2026-10-17 F116 brand crowded watermark actual-render evidence: added testBrandPhotoWatermarkCollisionFailsAndCanRecoverByMovingWatermark with14-line lens metadata, SONY/A7, gray160x120 source, maximum24W text or real imported400x60 image watermark. Across BrandInset/BrandGallery × text/image × original/512preview (8 configurations24 render attempts), disabled watermark succeeds, centered watermark throws the specific PhotoFrameBrandLayoutError.watermarkOverlap, moving the same watermark bottom-right succeeds. /tmp/ztransfer-brand-watermark-collision-20261017.log TEST SUCCEEDED exit0,1/1. Establishes production render collision rejection and recovery (not merely helper dimensions); does not prove every placement, exact Android font metrics or preview boundary equivalence at near-threshold sizes. No production changes. F116 remains open for immersive adaptation/reference-size/remaining completeness audit;152/182 closed,30 unclosed. No UI automation/animation validation.


2026-10-17 F116 immersive adaptation policy: Android drawImmersiveFrame3118–3190 permits single-row horizontal fitting, uses ONE detail Paint scaled by maximum detail-line advance, anchors full measured block above safeBottom, and explicitly does not darken photo. iOS previously fitted each detail independently, capped overall block height (vertical rescale) and drew a gradient veil. Added immersiveDetailRows shared scaling by widest advance, retained full blockHeight and removed extra veil. /tmp/ztransfer-immersive-adaptation-20261017.log TEST SUCCEEDED exit0,3/3: short and long detail rows retain identical scale ratio and widest300px cap; real immersive output with empty/short identity preserves full-height left-strip original RGBA exactly at original dimensions; inline-watermark independent effects regression. This validates sampled photo pixels, not all areas/visual styling. Remaining immersive first-row identity/separator/inline watermark initial fit and watermark reference-size audit still pending. F116 remains open;152/182 closed,30 unclosed. No UI automation/animation validation.


2026-10-17 F116 immersive title composition: Android creates inline signature Paint fitted to38%photo width, multiplies size1.35, then scales camera/divider/signature jointly to86% width. Replaced iOS single final-fit path with immersiveTitleRow implementing that order and cameraIdentityRow as a complete component; added PhotoFrameTextRow leadingRow initializer preserving prefix internal spacing/ink/drawing while attaching divider+signature with component gaps. Camera name no longer receives extra generic brand/model component gaps. /tmp/ztransfer-immersive-title-20261017.log TEST SUCCEEDED exit0,4/4: standalone maximum24W signature reaches about513/1000 width, short camera text/Logo stays below860, long camera fits860, absent content nil; actual inline independent effects for export/preview; shared detail scale; unmodified edge pixels. Does not claim perfect CoreText/Android optical metric parity. Remaining F116 reference-size/preview boundary/all-template completion audit pending.152/182 closed,30 unclosed; no UI automation/animation validation.


2026-10-17 F116 photo-text watermark design reference: Android measured layouts preserve base.designWidth/designHeight independently of added text margins and pass min(design) into photo-watermark paint and brand collision layout. iOS previously always used photo short edge. Layout now stores photoWatermarkReference computed from1000-photo-width/unmodified100% design and scales it in fitPreviewLayout. Standard/plaque/brand/editorial photo watermark rendering and brand occupied bounds pass that reference into shared photoWatermarkTextLayout. Image watermarks retain photo-relative dimensions; immersive/flat paths retain their own photo-sized default. /tmp/ztransfer-photo-watermark-reference-20261017.log TEST SUCCEEDED exit0,3/3: fixed-photo explicit300/450 reference changes font1.5x while maintaining safe edge position; occupied matches ink and half preview reference gives half font; actual brand collision/recovery; long framed watermark across effects/opacity regression. Full rendered border-width invariance and near-threshold in-photo preview ownership remain to audit; no all-platform font-pixel claim. F116 open,152/182 closed,30 unclosed. No UI automation/animation validation.


2026-10-17 F116 actual photo-watermark border-width invariance: added testPhotoWatermarkInkSizeDoesNotChangeWithFrameWidth. For all15 PhotoFramePreset cases at60/100/200 with identical320x240 gray source, empty metadata and centered white Test watermark, compare enabled/disabled normalized RGBA and derive changed-pixel bounding dimensions. All45 configurations (90 renders) contain watermark pixels and produce identical watermark dimensions across widths within each preset; enabled/disabled canvas dimensions also match. /tmp/ztransfer-watermark-width-invariance-20261017.log TEST SUCCEEDED exit0,1/1. This is actual render-path evidence for fixed reference sizing, not merely inspecting stored font sizes. It does not prove all text/effects/positions or preview threshold parity. F116 still open for remaining full-scope audit;152/182 closed,30 unclosed. No UI automation/animation validation.


2026-10-17 F116 brand in-photo stored measurement: Android measureBrandPhotoText measures at fixed photo width1000 and stores positioned rows. iOS now builds brandPhotoRows before preview fitting, using the same fixed1000 reference, watermark collision bounds and overflow rejection; export translates/scales that plan to the photo and preview scales the stored rows without rewrapping or repeating collision decisions. Extracted shared brandPhotoWatermark conversion so measuring and drawing use identical eligibility/position rules. Removed draw-time brand metadata measurement. /tmp/ztransfer-brand-stored-plan-20261017.log TEST SUCCEEDED exit0,3/3: actual brand overflow rejection, text/image collision rejection and recovery for export/preview, and expanded-frame original-photo interior pixel preservation. Existing cases cover export and512preview, not an exhaustive near-threshold size sweep; all-template completion audit still pending. F116 remains open;152/182 closed,30 unclosed. No UI automation/style/animation validation.


2026-10-17 F116 concentrated frame regression: added testBrandPhotoLayoutDecisionIsIndependentOfPreviewSize, covering two brand presets, portrait/landscape,60/100/200 widths and1/6/12/18/24 explicit lens lines with maximum centered text watermark.60 configurations each compare original export with32/127/512 previews (240 render attempts); assert both accepted and rejected cases occur and exact brand-layout error outcome is invariant. Entire PhotoFrameBrandTests class passed71/71, zero failures, TEST SUCCEEDED exit0 in /tmp/ztransfer-frame-completeness-20261017.log. This reruns existing logo/long-text/tail/pixel-preservation/poster/width/watermark tests after shared measurement changes. Requirement audit: existing extreme-aspect matrix covers seven measured-caption presets with indivisible identity/lens; it does not yet combine every enabled metadata field plus maximum watermark across all15 presets and extreme ratios. That explicit F116 matrix remains outstanding; CoreText/Android font pixel matching is not claimed and visual polish stays deferred. F116 remains open;152/182 closed,30 unclosed. No UI automation.


2026-10-17 F116 full-content/aspect matrix: added testAllTemplatesCombineFullMetadataAndMaximumWatermarkAcrossAspectRatios. All15 presets x portrait/landscape/8:1/1:8 x60/100/200 (180 configurations) enable all metadata fields, Nikon logo, long lens and maximum24-W auto watermark; each renders original/128preview, checks canvas does not shrink original dimensions and preview aspect follows original. Only brand in-photo layout errors are accepted, and preview must return identical error. /tmp/ztransfer-frame-full-matrix-20261017.log TEST SUCCEEDED exit0,1/1. This closes the missing combined-input geometry/error matrix but does not independently prove every glyph or source pixel. Further source audit found a concrete remaining measurement mismatch: Android MeasuredFrameText.FrameTextRow sums each run full ink-aware width and offsets each run by its negative ink left; iOS PhotoFrameTextRow.init(runs:gap:) advances each CTLine by typographic advance and layoutWidth only compensates outer row ink. Internal italic/mixed-run overhang can therefore underestimate column width. Address measured multi-run composition while preserving immersive advance-based fitting; this is remaining functional overflow work, not typography styling. F116 remains open;152/182 closed,30 unclosed. No UI automation.


2026-10-17 F116 per-run horizontal ink repair: PhotoFrameTextRow supports includeRunInk, advancing by max(advance,ink.right)-min(0,ink.left) for each run and drawing at x-min(0,ink.left), matching Android FrameTextRun/positionFrameRows. Measured frameIdentityRow uses this for text fallback and vector-logo trailing runs; cameraIdentityRow explicitly retains advance composition used by immersive titles. New mixed Times italic f/j/Wf test verifies sum of individual extents, containment, quarter-scale preservation and distinct advance-only behavior. Entire PhotoFrameBrandTests passed73/73, TEST SUCCEEDED exit0 in /tmp/ztransfer-frame-run-ink-20261017.log, including180-configuration full-input matrix, original-pixel/tail checks and immersive title regressions. Remaining F116 source-audit item: Android non-brand measured rows add vertical safety/effect padding (FrameTextRun.bounds); iOS still uses raw glyph bounds, so band/signature ink containment needs reconciliation before closure. This affects measured band allocation, not deferred stylistic matching. F116 open;152/182 closed,30 unclosed. No UI automation.


2026-10-17 F116 band-signature vertical measurement: added shared watermarkDescriptionRows and PhotoFrameTextRow.addingVerticalPadding. Standard four templates, plaque left/footer signatures and measured editorial/brand-gallery signatures now reserve max(1,fontSize*0.2) above/below glyph bounds before calculating band/canvas size, matching Android FrameTextRun watermark bounds. Horizontal extent and drawing font stay unchanged; preview scales the stored padding. /tmp/ztransfer-signature-padding-20261017.log TEST SUCCEEDED exit0,4/4: small/normal/large font bounds and one-tenth preview scaling; all15-template180-configuration full-content matrix; actual large standard watermark alignment/tail; plaque signature with taller opposite column. Remaining vertical audit concerns ordinary metadata runs (Android fontSize*0.035) and vector-logo bounds; brand in-photo measureInkOnly must remain unpadded. F116 not closed;152/182 closed,30 unclosed. No UI automation.


2026-10-17 F116 standard metadata vertical bounds: Android FrameTextRun adds fontSize*0.035 per ordinary run; calculateMeasuredTemplateFrame explicitly excludes ColorArchive, and brand-photo measurement is also ink-only. Added optional per-run verticalPaddingRatio to PhotoFrameTextRow, preserving glyph drawing/origins and unioning each run with its own font allowance; vector prefixes receive separate leadingVerticalPadding. Threaded option through identity helpers, including split brand/model rows. Standard four templates now opt into0.035 for identities and descriptions; signatures retain independent0.2/min1 rule. /tmp/ztransfer-standard-run-padding-20261017.log TEST SUCCEEDED exit0,4/4: mixed40/20-font bounds, text/Logo height and horizontal invariance,180-config all-template matrix, standard/plaque/gallery long-identity tail export/preview, signature scaling. Remaining work: apply ordinary-run rule to remaining measured non-ColorArchive templates and film-strip thresholds, respecting distinct poster/immersive/brand-photo paths. F116 open;152/182 closed,30 unclosed. No UI automation.


2026-10-17 F116 developer functional completion: remaining classic-header, measured-caption identity/details, plaque columns, FilmEdge combined/fallback/location rows and FilmGallery strip identity/date now include ordinary fontSize*0.035 vertical allowance before expansion or strip-height eligibility. ColorArchive, brand in-photo and immersive remain ink-only/own-policy as Android requires; poster remains its independently audited F120 implementation. Full PhotoFrameBrandTests passed75/75, zero failures, TEST SUCCEEDED and exit0 in /tmp/ztransfer-measured-padding-final-20261017.log.

F116 requirement audit (current functional scope):
- All15 templates,60/100/200,landscape/portrait/8:1/1:8,all enabled fields,long lens and maximum text watermark: testAllTemplatesCombineFullMetadataAndMaximumWatermarkAcrossAspectRatios covers180 configurations and original/128preview geometry or matching explicit brand rejection.
- Measured full content instead of blanket shrinking: standard/plaque/caption unbreakable-width tests, measured rows/font/ink tests, long-content budget expansion, and original implementation audit cover fixed design references, independent columns and canvas growth. Frosted in-photo column overflow is explicitly rejected; brand insufficient-height/collision errors are preserved; immersive retains Android horizontal-fitting exception.
- Text completeness/Logo/watermark: full suite includes long-identity tail output comparisons, classic combined header/body/signature tails, ColorArchive per-field tails, negative/edge Unicode tails, measured caption signature alignment/disable state, all-brand fallback/hidden-brand behavior, mixed-run ink bounds and signature padding.
- Preview equivalence: stored measured rows scale without rewrap for standard/plaque/caption/brand paths; preview plan and FilmStrip tests plus60 brand decision configurations at32/127/512 prove covered decision invariance. Poster orientation/long-field/empty-column tests rerun in this suite.
- Original photo1:1: production expansion changes margins/canvas while preserving source-sized photo rect, passed expanded-frame interior-pixel comparisons (including odd dimensions), plaque exact-pixel/preview tests and immersive edge preservation; prior F117 complete-source geometry evidence retained. This does not claim UI/device/font-pixel equivalence.
F116 is closed in developer functional scope. Styles/animations and physical-device visual review remain deferred under user instructions; no UI automation, installation, commit or push. Count153/182 closed,29 unclosed. Overall goal remains active.


2026-10-17 F046 sustained decode evidence: added testLargeCameraPreviewSequentialDecodeWithFiveRetainedPages. A real6000x4000 JPEG goes through production loadCameraPhotoPreviewContent24 times, retaining the latest5 image+histogram results. Every decode is1920x1280 with histogram; retained CGImage bytes stay within49,152,000 bytes (5x1920x1280x4). Simulator task_vm_info phys_footprint sampled after each decode: baseline78,907,768 bytes, maximum78,907,768, measured delta0; maximum single decode+histogram duration0.234253 seconds. Fixture generation precedes baseline and can leave allocator high-water capacity, so zero delta does NOT mean zero allocation or bound transient decoder peak. /tmp/ztransfer-preview-retained-pages-20261017.log TEST SUCCEEDED exit0, targeted test passed. Android loadFhdBitmap4356+ inspected: background analysis/display decode and1920 cap. This is real codec sustained-load evidence, not production pager/cache integration, main-actor responsiveness, in-flight peak sampling or device latency proof. Those F046 requirements remain open. No production change/UI automation. Count153/182 closed,29 unclosed.


2026-10-17 F046 cache publication boundary: inspected Android PhotoPreview.kt872–938 (serial FHD load, finally ownership cleanup and independent immediate +/-2-page eviction), iOS loadCurrentThenNeighbors/loadHighResolution/finishRemoteImageLoad/trimPreviewState. Added live retainedPhotoPreviewIDs check immediately before both decoded-image publication sites, after asynchronous decode and cancellation checks. A result whose file is outside the current retention window cannot repopulate highResolutionImages/displayedImages/histogram/orientation caches or trigger current-load haptic. Existing trim and loading ownership remain unchanged. /tmp/ztransfer-preview-retention-publication-20261017.log TEST SUCCEEDED exit0,2/2: retention-window/collection policy and24MP24-decode five-page resource regression. These tests validate policy/codec and compile the production guards; they do not drive actual pager callback interleaving. Full pager integration, in-flight peak and main-actor latency evidence remain outstanding, F046 stays open. Count153/182 closed,29 unclosed. No UI automation.


2026-10-17 F046 in-flight memory sampling: extended existing24x24MP/five-retained-page production-codec test with independent detached utility sampler requesting2ms interval, cancellation/awaited completion and >24 sample assertion. /tmp/ztransfer-preview-inflight-memory-20261017.log TEST SUCCEEDED exit0. Observed1308 in-flight samples; baseline74,991,968 bytes, peak139,348,416 bytes (about132.9MiB), growth64,356,448 bytes (about61.4MiB); slowest decode+histogram0.195704 seconds. Every image remains1920x1280 with histogram and retained image buffers <=49,152,000 bytes. Unlike previous after-decode-only samples, this run captures transient growth; earlier delta0 must not be used as peak-memory evidence. Sampling can miss shorter spikes and includes simulator app/runtime/fixture allocator effects, so this is an observed peak for the stated workload, not a hard budget or physical-device result. F046 still requires production pager/cache interaction and main-actor responsiveness validation. Count153/182 closed,29 unclosed. No production change/UI automation.


2026-10-17 F046 main-thread responsiveness probe: extended real24MP24-decode/five-page retention workload with @MainActor probe requesting5ms intervals and asserting Thread.isMainThread on every tick, cancellation and awaited completion. /tmp/ztransfer-preview-main-responsiveness-20261017.log TEST SUCCEEDED exit0. Probe executed626 times during workload, maximum observed interval20.4395ms; memory sampler988 samples, baseline74,418,504 bytes, sampled peak134,760,896, growth60,342,392; slowest decode+histogram245.634ms. Confirms main-thread execution continued during this actual detached decoder workload; does not establish UI frame rate, per-frame deadline or real pager callback/cache integration. Results remain simulator observations, not physical-device performance guarantees. F046 remains open for production pager integration evidence;153/182 closed,29 unclosed. No production change/UI automation.


2026-10-17 F046 burst-list retention trigger: Android PhotoPreview.kt immediate eviction effect keys include previewItems as well as current page/handle. iOS now observes previewEntries.map(id) and calls trimPreviewState independently of index changes/loading. This handles expansion/collapse near the current photo when its index and load identity stay unchanged. Added production-list-transform regression: same current index/photo retains[1,2,6] before expansion, [1,2,3] after, and[1,2,6] after collapse. Initial3-test run had one bad test expectation[1,2,3,4]; inspection confirmed collection page is retained at index2, so only first member enters +/-2 window. Corrected expectation, no further production change; /tmp/ztransfer-preview-burst-retention-final-20261017.log TEST SUCCEEDED exit0,3/3 incl collection exclusion and previous-then-next prefetch order. Tests cover actual list transforms/retention policy and production compilation, not a hosted SwiftUI callback/eviction observation. F046 remains open for production pager integration.153/182 closed,29 unclosed. No UI automation.


2026-10-17 F046 production retention observer lifecycle: extracted PhotoPreviewRetentionObserver ViewModifier used by PhotoPreviewView. It trims on appearance and changes to actual retained ID set, replacing separate index/list triggers; invalid index now clears retained caches as well. Production load-start trim and post-decode retention gates remain. PhotoPreviewRetentionLifecycleTests hosts that exact modifier in a real UIWindow/UIHostingController and changes ObservableObject page/list state: appearance->{1,2,6}, unchanged-index burst expansion->{1,2,3}, page5->{3,4,5,6,7}, collapse/page1->{1,2,6}, invalidpage->empty. Assert >=5 eviction callbacks. /tmp/ztransfer-preview-retention-lifecycle-20261017.log TEST SUCCEEDED exit0,1/1. This proves SwiftUI production-observer triggering and eviction-set integration, not the full PhotoPreviewView camera/decode/cache pipeline or a UI gesture test. Remaining F046 integration: drive real session preview callback and asynchronous publication together with page lifecycle, including late results.153/182 closed,29 unclosed. No UI automation.


2026-10-17 F046 session/decode integration: PreviewTimingTransport test fixture now optionally supplies real JPEG bytes while retaining existing default. New test runs4096x3072 JPEG through actual PTPSession/CameraRepository/CameraSession.previewAndExif and production loadCameraPhotoPreviewContent in onPreviewLoaded. Verifies1920x1440+histogram, wire/event order fhd->decoded->exif, and cancellation while callback is suspended after decoding prevents EXIF. A subsequent actual camera.preview request succeeds in both branches, proving interactive reservation release. /tmp/ztransfer-preview-session-decode-20261017.log TEST SUCCEEDED exit0,2/2 including cached-read skip/order regression. Fake transport replaces camera hardware only; JPEG codec/session/gate are production. Does not invoke private PhotoPreviewView publication methods or full page lifecycle concurrently; remaining F046 gap is that final integration, not decoder resource measurements already recorded.153/182 closed,29 unclosed. No production change/UI automation.


2026-10-17 F046 loading lifecycle parity: Android PhotoPreview.kt340–365 only enables deferred loading when not closing; main FHD/EXIF/neighbor effect940+ keys include previewItems/currentPage/currentHandle/connection/deferred gate and exclude transfer activity. iOS now uses typed PhotoPreviewLoadIdentity containing complete entry IDs,index,connection,deferred state instead of only current-entry string. Burst membership changes at unchanged current entry therefore invalidate the load task and recompute neighbors. Deferred340ms gate now checks !closing, matching Android. /tmp/ztransfer-preview-load-lifecycle-20261017.log TEST SUCCEEDED exit0,2/2 production retention-observer lifecycle and real session/decode/cancel-release regression. Those tests plus compilation do not directly observe the new task identity restart or early-close gate; behavioral source comparison is recorded, full-page asynchronous integration remains outstanding. F046 open;153/182 closed,29 unclosed. No UI automation.


2026-10-17 F046 full production page integration: added testFullPhotoPreviewPageLoadsNeighborsAndReusesCachedPage using actual PhotoPreviewView in UIWindow/UIHostingController, actual TransferQueueViewModel, CameraSession/CameraRepository/PTPSession,4096x3072 JPEG and replay wire. Drives the actual paging UIScrollView programmatically. Verifies initial current+neighbor FHD requests, selection binding advances to2 and requests3, return to1 performs no second FHD read, then2->3->4->3->2->1 crosses +/-2 window and requires file1 to be fetched again. /tmp/ztransfer-full-preview-page-paging-20261017.log TEST SUCCEEDED exit0,1/1 in5.158s. Earlier basic full-page run also passed; first two compile attempts failed due test UserDefaults MainActor-to-actor isolation, fixed by constructing isolated queue config inside detached task (no production changes). Test has bounded waits, dedicated defaults suite and restored prior window. This is actual page loading/decoder/cache/pager integration, not just a helper host; fake camera replaces hardware only. Existing decoder resource/probe evidence remains separate: full hosted-page peak memory sampling has not yet been combined with this test. F046 remains open for that resource-validation completion check.153/182 closed,29 unclosed. No UI gesture automation/install/commit/push.


2026-10-17 F046 developer functional completion: shared test-only previewTestPhysicalFootprint helper now supports both codec and complete production-page sampling. Full hosted PhotoPreviewView/real4096x3072 JPEG/session/repository/codec/pager test samples process phys_footprint during setup and continuous paging: baseline88,820,112 bytes, observed peak196,184,560 (about187.1MiB), growth107,364,448 (about102.4MiB),506 samples at requested2ms interval. Requests[1,2,2,3,3,4,1] include cancelled-prefetch/retry transitions; cached first-page return makes no new read, crossing retention window later reloads1. This does not claim every wire handle is fetched only once. Combined /tmp/ztransfer-preview-final-resource-20261017.log TEST SUCCEEDED exit0,4/4: full-page integration/resource sampling;24x24MP five-retained-page codec test; synchronous-decode cancellation/discard; actual SwiftUI retention observer lifecycle.

F046 requirement audit:
- Larger-than1920 inputs: actual JPEG dimensions640/1920/2560/4096 landscape+portrait tests and24MP repeated production decode establish1920 cap/no upscale/manual orientation policy. ImageIO thumbnail decoding avoids an explicit source-sized UIImage; histogram uses its own bounded analysis decode.
- Continuous paging/cache: complete production page uses real session and codec with hardware replaced by replay transport; proves neighbor loading, accepted page changes, cache reuse and eviction/reload. Live publication guards reject out-of-window results; independent retained-ID lifecycle handles page/list/invalid-page transitions.
- Resource/response evidence: full-page observed memory above; retained5x1920x1280 CGImage buffers <=49,152,000 bytes. Combined codec run sampled147,606,024-byte peak, max decode221.549ms, main-thread probe321 ticks/max observed50.746ms (scheduler observation, not a frame-time guarantee). Earlier isolated run20.4ms is not presented as universal. Polling cannot establish absolute transient maximum and simulator footprint includes runtime/renderer/fixture effects.
- Cancellation: deterministic entered-codec cancellation discards old output and replacement succeeds; real session callback cancellation skips EXIF and releases interactive gate for subsequent read. Load identity matches Android page/list/connection/deferred keys; closing suppresses not-yet-enabled deferred loads.
F046 closed in developer functional/resource scope; physical camera/RAW source retrieval and device profiling remain platform validation limits, not claims of this simulator test. No UI gesture automation. Count154/182 closed,28 unclosed; overall goal remains active.


2026-10-17 F110 high-pixel dual-entry resource evidence: added testTwelveMegapixelConcurrentExportEntrypointsAcrossFrameModes. Real4000x3000 two-color PNG, enabled first bundled filter at80%, concurrently invokes actual LocalPhotoOutput.render and TransferQueue.renderFrameFile for filter-only/watermark-only-border-off/immersive/minimal-frame modes. Two outputs decode with equal dimensions, first3 remain4000x3000, framed dimensions >=source; original file bytes unchanged after each mode. Memory snapshot injection .max isolates render resource sampling from early-budget rejection already covered byF124. Detached2ms process sampler observed peaks237,750,840 /291,244,624 /262,916,664 /313,854,592 bytes (about227/278/251/299MiB), respective increases163,184,856 /221,757,680 /192,790,744 /243,237,152; each pair about9.5–9.8sec. /tmp/ztransfer-highpixel-concurrent-final-20261017.log TEST SUCCEEDED exit0. Initial compile failed for capturing mutable settings in two async lets; fixed test by freezing recipe before dispatch. Android PhotoFilterRenderer.scratchPixelCount/renderInPlace fixed4M-pixel stripe source inspected. This proves sampled dual production-entry workload, not a hard memory bound, physical-device result, active download coexistence, or exhaustive image/preset content fidelity. F110 remains open for two-image batch plus concurrent transfer/cancellation resource integration; earlier tile/seam/alpha/orientation proofs retained.154/182 closed,28 unclosed. No production change/UI automation.


2026-10-17 F110 export/download overlap: extended DownloadReplay test fixture with optional per-chunk async delay and first/last chunk timestamps (default zero preserves existing replay behavior). New test concurrently runs actual local export of first.png and queued export of second.png (independent4000x3000 source files, bundled filter80%,minimal frame) plus actual CameraRepository/PTPSession streaming64MiB AP whole-object download.64x1MiB delayed chunks are verified byte-for-byte after publication, EOF checked, both original PNGs unchanged and two derived outputs decode at equal source-preserving dimensions. Chunk interval intersects export interval by asserted timestamps. /tmp/ztransfer-export-download-overlap-final-20261017.log TEST SUCCEEDED exit0,2/2 incl existing USB/workspace whole-object regression. Sampled baseline75,139,448 bytes, peak321,391,256 (~306.5MiB), growth246,251,808,4748 samples at requested2ms; exports16.037s. Initial run failed with replay command mismatch because test selected USB, which correctly uses bounded partial reads for64MiB; switched test to intended AP whole-object mode, no production changes. Hardware wire is replayed; sink/gate/landing/export are production. Remaining F110 requirement: cancellation/resource behavior during overlapping work; no device/hard-memory-bound claim.154/182 closed,28 unclosed.


2026-10-17 F110 developer functional/resource completion: refactored high-pixel overlap test into shared normal/cancel scenarios. Cancellation fixture pauses actual queued export at its second available-memory query (after source loading, before canvas allocation), waits for actual download first chunk, cancels export and releases checkpoint. Cancelled export throws CancellationError and creates noZTFrames directory; concurrent local export and64MiB AP streaming download complete with dimensions/content intact; both4000x3000 originals remain byte-identical. /tmp/ztransfer-export-cancel-overlap-final-20261017.log TEST SUCCEEDED exit0,2/2. Observed cancel baseline87,968,096/peak228,985,328 bytes; normal baseline71,764,320/peak320,031,360;4378/5553 samples at requested2ms. First combined run had a test-only unwaited XCTest expectation in normal scenario; fixed awaited fulfillment, no production change.

F110 requirement audit: PhotoFilterExecution returns1 worker for original and caps preview at2; original composed paths use bounded stripe/filter work (existing tile-budget and actual NP3/Cube seam tests). Existing all-eight-orientation/alpha and source-pixel tests remain evidence of fidelity. New1200万像素 dual production-entry tests cover filter-only,watermark-only,immersive,and framed modes with source bytes/dimensions preserved and sampled peaks; two independent source files plus real streaming sink/download publication establish overlapping export/download progress. Deterministic active-export cancellation verifies isolation/cleanup at the stated checkpoint; generation/cancellation regressions and per-stripe cancellation checks retained. F124 already owns early-budget/retry behavior; injected unlimited budget in resource tests deliberately measures successful work and is not a production memory policy.
F110 closed in developer functional/resource scope. Observed simulator process peaks are workload measurements, not device guarantees or a proof against all OOMs; no exact pixel-loop interruption timing or exhaustive filter calibration is claimed. Physical-device profiling remains unperformed. Count155/182 closed,27 unclosed; overall goal active. No UI automation/install/commit/push.


2026-10-17 F162 几何功能验证闭环：RemoteViewfinderRenderingTests.testFalseColorMatchesSourceGeometryWithDesqueezeAndSharedZoom 使用真实 RemoteViewfinderImage 与 RemoteFalseColorOverlay，300×200 红/白/绿三条带，1×/1.33×/2×反挤压 × 240×400/400×240容器 × 1/1.5倍缩放（放大时横移13）共12组合，逐色比较实际渲染矩形位置和尺寸，误差≤2像素。原底图条带测试同时回归。/tmp/ztransfer-falsecolor-geometry-20261017.log 明确 TEST SUCCEEDED，2/2通过；恢复时原构建进程38431仍在运行，未重复启动，随后读取终态日志确认。原命令句柄因上下文丢失，未另行声称取得退出码。RemoteView.swift 中两组件位于同一个 RemoteZoomableViewfinder 内容ZStack；该容器统一scale/offset/mask，源代码支持共同裁剪和变换。测试实际渲染组件并施加相同变换，未驱动生产手势，也不声称动画、真机或精细样式验收。本轮生产代码仅将伪色组件访问级别改为internal以便@testable验证；此前去掉第二次原始比例fit的修复获此几何证据。F162按功能范围关闭；156/182已闭环，26项未闭环（包含延后视觉项）。


2026-10-17 F177 feedback ownership audit (未闭环): Android ReleaseCommitWheel.kt:142,275–297 gives each long-click wheel rememberLongPressFeedback.interactions; LongPressFeedback.kt starts on Press, cancels on Release/Cancel and disposal, and trigger wraps the business action in completeLongPress. iOS DetentWheel.swift:296–315 currently calls onLongClick directly; its separate pressing GestureState only drives prominentPressFeedback visuals and does not drive progressive haptics. Confirmed affected production callers: GPSConnectionControl diagnostic copy; PhotoEffectsEditorView filter category chooser; PhotoLUTChooser category chooser; PhotoFilterComponents forwarding onLongPress. GPS diagnostic-copy callback contains no compensating haptic call. Existing HapticsTests validate the haptic service, not wheel press/cancel/lifecycle integration; cannot use them to close this task. Integration must own the active hold, avoid cancelling a different control's hold, cancel on gesture/configuration/disappearance, and pass action through completion suppression without swallowing a subsequent independent tap. Threshold platform choice (current450ms versus proposed500ms) asked separately; no response yet, unchanged. No production edit or new test run this audit. Progress remains156/182 closed,26 unclosed.


2026-10-17 F013 adapter-loss cleanup: Android NikonGpsService.handleBluetoothOff cancels work and stops BLE client; NikonGpsBleClient clears operation state on disconnection. iOS owned central-state callback previously only invalidated retirement when adapter left poweredOn, retaining peripheral/characteristics and pending scan/connect/pairing/ID deadlines until another callback. Added invalidateAdapterConnection to invalidate retirement and invoke common clearConnectionState immediately, preserving saved pairing. New actual-client test schedules four deadlines, invalidates twice, releases cancellation-ignoring waits and checks zero reconnect/scan-stop/pending-check callbacks, unchanged post-invalidation state and retained pairing. /tmp/ztransfer-gps-adapter-loss-20261017.log TEST SUCCEEDED exit0; GPSProtocolTests regression passed. Test exercises production cleanup method invoked by owned adapter callback; it does not replay a reused CoreBluetooth peripheral or prove all physical callback orderings. F013 remains open for that integration evidence.156/182 closed,26 unclosed. No UI automation/device/install/commit/push.


2026-10-17 F013 cancellation reentry ordering: clearConnectionState now clears notification readiness and discovery ownership before writeQueue.cancelAll invokes external completion callbacks. This prevents the trailing old-session cleanup from clearing discovery state established by a synchronous replacement operation. Android clearGattOperationState clears all operation state together; iOS completion callbacks add a reentry boundary. Added testWriteCancellationCanSynchronouslyStartReplacementWrite against production queue: cancelled in-flight callback enqueues and starts a replacement using the same owner/characteristic; second abandoned queued entry receives false once, replacement remains in flight and acknowledges successfully, repeated cancel does not redeliver completions. /tmp/ztransfer-gps-cancel-reentry-20261017.log TEST SUCCEEDED exit0,33/33 GPSProtocolTests. This verifies queue reentry plus source ordering; it is not full peripheral delegate replay, so F013 remains open. Count156/182 closed,26 unclosed. No UI/device tests.


2026-10-17 F119 functional completion audit: extended testConnectedTemplatesConsumeLogoAndRespectHiddenBrand from Nikon/Sony/Canon to all17 PhotoFrameBrand cases + unsupported Canon. Across all15 presets, real320×240 source with enabled watermark, each case renders visible TEXT/LOGO and hidden TEXT/LOGO (1080 total exports); supported styles differ, unsupported styles match, hidden styles match. /tmp/ztransfer-all-brand-templates-20261017.log TEST SUCCEEDED exit0,4/4 in68.65s including all-brand measured long-model rows, missing-Make presentation inference and real brand-frame watermark collision/reposition recovery. Re-read Android FrameBrandLogo.identityLogo, PhotoFrameMetadataSettings.nextBrandStyle and its persistence test. Production brand button at PhotoEffectsEditorView:302 calls cycleBrandStyle; existing /tmp/ztransfer-f119-brand-control-20261016.log4/4 confirms all-template Off→Text→Logo→Off and persistence, and /tmp/ztransfer-measured-padding-final-20261017.log75/75 supplies final shared measurement/template-content regressions. Renderer source shows all template identity paths use brand visibility/style and common presentation, not only two brand frames. These combined proofs satisfy F119 functional requirements; no claim of exact Android visual logo metrics, exhaustive cross-product of every long model/watermark placement or UI/device validation. Corrected stale table label “未修复” to functional completion. Count157/182 closed,25 unclosed (still includes deferred visual items).


2026-10-17 F097 shared module-menu implementation: read Android PhotoEffectModuleMenu.kt. Replaced PhotoEffectsControls permanent chips with PhotoEffectModuleMenuButton in SettingsView.effectsHeader and LocalPhotoEffectsView.toolbar; common PhotoEffectModuleMenuOverlay consumes real button anchor, clear outside dismissal layer, four module actions retaining open state, theme/disappearance close, internal blank-area tap consumption. Action reuses togglePhotoEffectModuleDraft, emits shared preference-gated tick only for accepted changes, and writes the host binding. Uses Android exact photo_effect_modules and four module label resource keys; all15 strings across en/zh-Hans/zh-Hant verified against Android XML. Basic156pt anchored panel/8pt offset/18pt corner implemented; no fine animation styling claim. /tmp/ztransfer-module-menu-20261017.log TEST SUCCEEDED exit0: module normalization/free coupling/draft preservation, exhaustive mask toggle and role-owned LUT command regressions; both hosts compile. Tests do not exercise production popup touch routing, external dismissal, or actual theme/host lifecycle. F097 remains open for functional integration evidence,157/182 closed,25 unclosed. No UI automation/device/install/commit/push.


2026-10-17 F142 terminal writer guard: recorder stop previously invoked markAsFinished/finishWriting regardless of writer.status. Now terminal/nonwriting writer releases staging and returns nil without invalid finishing calls. Writer creation is injected through a default AVAssetWriter factory, preserving production configuration. Added testTerminalWriterRequestsStopAndDiscardsUnpublishableRecording using a real AVAssetWriter: first encode valid frames, cancel the captured writer after submitted-work barrier, append more frames, await one30-failure stop request, stop returns nil, output absent, staging directory empty and repeated stop nil. Correction: /tmp/ztransfer-terminal-writer-20261017.log TEST SUCCEEDED exit0 but executed ZERO tests due to wrong class selector; no test success claimed. Correct-class rerun pending for four tests incl bad-image automatic stop with playable prior content, recovery by good image and normal playable export. Cancellation exercises a real terminal writer status; it does not claim injected .failed status, append rejection/backpressure, physical codec failures or complete ViewModel failure feedback. Pending finishWriting deadline platform agreement remains unanswered, unchanged. Corrected stale F142 table to in-progress;157/182 closed,25 unclosed. No UI automation/device/install/commit/push.


2026-10-17 F142 corrected-selector validation: /tmp/ztransfer-terminal-writer-final-20261017.log TEST SUCCEEDED exit0, actual RemoteViewfinderRecorderTests4/4 executed with0 failures in2.49s. Includes real cancelled-writer one-shot failure request and empty-staging/nil-output/repeated-stop checks, bad-frame playable earlier content, recovery and normal playable export. Initial wrong-class run executed0 tests and remains explicitly not evidence. F142 still open for remaining writer/backpressure/feedback/finish-deadline requirements;157/182 closed,25 unclosed.


2026-10-17 F142 production model failure integration: introduced recorder Configuration and defaulted makeLocalRecorder dependency in RemoteViewModel, using the same factory for preferred-directory and fallback creation; default still builds the unchanged real recorder. New test uses real RemoteViewModel/live-frame replay/AVAssetWriter: cancel first writer, await automatic idle via existing30-failure callback and stop flow, verify timer zero, exact cd_remote_rec_toast_failed hint and no staged/published files. Start replacement recording, invoke retained old callback, verify recording continues, then normal stop reaches saved. /tmp/ztransfer-recording-failure-model-20261017.log TEST SUCCEEDED exit0,2/2 incl existing active/departed-host save failure exactly-once integration. This closes model automatic-stop/failed-save feedback and old recording UUID isolation evidence; .failed writer status/append rejection/backpressure injection and finishWriting deadline remain unproven/pending, so F142 stays open.157/182 closed,25 unclosed. No UI/device testing.


2026-10-17 F142 busy/append fault integration: inspected Android ViewfinderRecorder.encodeFrame224–259: busy input returns true; exception/refused encode returns false; RemoteScreen counts30 false attempts and resets on true. Added default VideoOperations boundary for AVAssetWriterInput readiness and pixel adaptor append, default directly delegates platform calls. Production-recorder test first writes real frames, then60 sequential offered frames receive forced busy readiness without reaching append/failure threshold, then one retained frame receives30 forced append false results and triggers exactly one stop request. Post-threshold input is discarded; normal stop publishes a decodable earlier segment. /tmp/ztransfer-video-backpressure-20261017.log TEST SUCCEEDED,3/3 incl valid-frame recovery and exact failure-streak reset/terminal guard. Busy/refusal are injected API outcomes through actual recorder worker/retry/mailbox/pixel conversion and finalization, not a physical hardware codec fault. Real cancelled writer and actual ViewModel feedback evidence remain separate. F142 still open for finishWriting bounded deadline (platform question unanswered); .failed status itself not separately forced.157/182 closed,25 unclosed. No UI/device automation.


2026-10-17 F097 functional completion audit: added PhotoEffectModuleMenuLifecycleTests hosting actual production button+modifier in UIHostingController/UIWindow. Light→dark→light changes, anchor removal and replacing hosted root each close bound presentation; draft remains exactly unchanged. /tmp/ztransfer-module-menu-lifecycle-20261017.log TEST SUCCEEDED exit0,2/2 incl independent camera/local LUT command persistence regression. Prior /tmp/ztransfer-module-menu-20261017.log6/6 covers masks/free coupling/last-module rejection and both hosts compile;15 exact localized strings checked. Source review: Settings.effectsHeader binds effectsDraft/camera store; Local.toolbar binds effectsBinding/local store; anchor measured on actual button; sibling full-area clear dismissal layer handles outside tap, panel consumes internal blank tap, option action neither closes menu nor bypasses shared command, tick only inside accepted-change branch and shared haptic preference gate. Theme/disappearance actually exercised; outside tap and button routing are code evidence, not automated physical touch evidence. User explicitly excludes UI automation and fine styling/animations, so these are not retained as mandatory completion gates for this functional-only task. F097 developer functional scope closed; no claim of pixel parity, animation timing or device touch testing. Count158/182 closed,24 unclosed, including deferred visual entries.


2026-10-17 F172 functional completion: Android ViewfinderCard3701–3711 places border on viewfinder only and gates connected&&movieMode&&recording. Moved iOS root RemoteView recording overlay onto remoteViewfinder card after its clip; existing card corner22 retained as basic usable geometry, no new animation. Extracted showCameraRecording shared by border and timer; audio gate remains connected/movie/audio. /tmp/ztransfer-recording-indicator-final-20261017.log TEST SUCCEEDED exit0,8/8 RemoteRecordingTests (pending/failed start noREC, stop failure preservesREC, adopted camera recording, leaving generation, retries/cancellation, message durations). First indicator run failed3 old assertions requiring diagnostic codes inside user messages; confirmed Android RemoteScreen2467–2468/2517–2518 logs diagnostics separately and shows plain hint, matching current production and existing RemoteMonitorHintTests. Updated old test to separately assert exact message and diagnostic; did not change production error text to satisfy it. This verifies state logic and compiles shared gate; border ownership and disconnect/photo gate are source evidence, not rendered/UI/device tests. F172 closed for user's functional/basic-interface scope;280ms animation and fine visual parameters deferred. Count159/182 closed,23 unclosed.


2026-10-17 F170 functional completion audit: re-read Android RemoteLutPanel and RemoteScreen onFeedback=services.haptics.tick. Found iOS Off/folder/file buttons missing equivalent feedback; added preference-gated shared tick to each and an Off-active checkmark when active=nil. Production sheet otherwise has Off/folder actions, exact status/notice resources, category picker, scrollable files, active check/pending spinner, entry reconciliation and selected-file positioning; folder picker is deferred until sheet dismissal. Existing state callbacks close on accepted presentation/same selection/Off, not no-frame/failure; dismissal cancels stale manual candidates. /tmp/ztransfer-lut-panel-feedback-20261017.log TEST SUCCEEDED exit0,5/5 covering close/mutual exclusion/same selection, no-folder/scanning/empty/failure status and visible notice, category retention, duplicate labels, haptic preference gate. Rechecked /tmp/ztransfer-f165-integration-20261017.log1/1 successful real folder/parse/Metal/presentation/persistence integration; prior f170-panel2 and66 exact resources remain evidence. Source wiring is the evidence for actual button actions and basic usable list; no physical/UI-gesture or screenshot acceptance claimed. User excludes UI automation/fine styling, so600ms breathing and exact popup geometry remain deferred rather than a functional gate. F170 closed in developer functional scope;160/182 closed,22 unclosed.


2026-10-17 F177 control-owned hold feedback: read Android LongPressFeedback press/release/cancel/disposal and completeLongPress behavior. Added ZTransferLongPressFeedback with per-control ZTransferHaptics instance and idle/holding/finished lifecycle; repeated press updates do not restart, drag cancellation stays finished until release, completion runs once with synchronous duplicate tick/long-press suppression, end resets for next touch. DetentWheel begins via simultaneous zero-distance press, routes recognized exclusive long press through completion, cancels on drag ownership, ends on GestureState reset/configuration change/disappearance. Existing450ms threshold preserved pending user's platform decision; progressive pattern uses same450ms constant, not the800ms default. /tmp/ztransfer-wheel-hold-feedback-20261017.log TEST SUCCEEDED exit0,7/7 HapticsTests. New controller test covers two independent holds, one cancellation not affecting other, cancelled/repeated trigger rejection, next independent tick, disabled haptics still executing action, and nested feedback suppression. Production gesture wiring compiled and reviewed; test does not replay SwiftUI recognizer arbitration or physical vibration. F177 remains open for threshold agreement and any final gesture-lifecycle audit;160/182 closed,22 unclosed. No UI/device automation.


2026-10-17 F176 actual accepted-value rendering: hosted production DetentWheel in UIHostingController/UIWindow with observable external options/selection and rejecting onCommit. Capture initial then external selected0→2 after30ms, assert different; reorder options[0,1,2,3]→[2,3,0,1] while selected2 remains, assert rendered PNG unchanged; replace host with fresh selected2 wheel and assert same output. No helper-only constant result substituted. /tmp/ztransfer-wheel-accepted-render-final-20261017.log TEST SUCCEEDED exit0,3/3 incl two drag-session configuration/cancel/late-release regressions. First run used200×50 UIWindow and captures were all identical (invalid short host under safe-area layout); changed only fixture window to390×844, retaining200×50 wheel and exact assertions. First failed log retained. Android ReleaseCommitWheel346–365 uses dragging?position:selectedIndex; production iOS same gate drives row identity/color/offset, so rejected/deferred commit after dragging=false renders accepted value; configuration mismatch suppresses stale preview immediately. Rendering test covers external selection/reorder; rejection path is source+drag-state evidence, not physical drag replay. F176 functional scope closed;220ms emphasis, material/neighbor styling excluded per user, no cross-platform visual equality claim.161/182 closed,21 unclosed.


2026-10-17 F161 plot references: Android RemoteMonitorScopes waveform uses horizontal0/25/50/75/100% guides and100/50/0 labels when plot height>=34, with15dp label gutter; histogram has quarter-scale vertical guides. Added corresponding basic references to production iOS Canvas, waveform labels use height>=34 and15pt gutter, pixel mapping uses remaining plot width. Fixed-density calculation itself unchanged. /tmp/ztransfer-scope-reference-lines-final-20261017.log TEST SUCCEEDED exit0,8/8 RemoteExposureAnalysisTests; initial compile failed because Text.foregroundStyle used in Canvas requiresiOS17, corrected to iOS16-compatible foregroundColor (initial failure preserved). Tests verify analysis regressions and compile wiring, not visible short-screen coexistence. F160/F161/F163 still require final basic readout coexistence audit; fine positioning/animation stays excluded.161/182 closed,21 unclosed. No UI/device automation.


2026-10-17 F160/F163 Android meter placement correction: read RemoteScreen landscape meterTop/audioTop/audioHeight and ViewfinderSoundMeterOverlay3839–3987. Existing iOS always used left-bottom32×116 and fixed5pt segments, unlike Android right22pt landscape stack and bounded meter height. Added production RemoteMonitorMeterLayout: exposure top34 movie/10 photo, landscape audio container below exposure120+gap6 when enabled, max88 available container, meter target24% clamped56...72 then limited by containerHeight-16; portrait left8/bottom8. Scope leading reserve48 only for enabled portrait audio,8 otherwise. RemoteView consumes calculated audio frame and exposure top; sound segments now Canvas with15 rows,1pt gaps and height derived from available area, L/R7pt text, clipped to allocation. /tmp/ztransfer-adaptive-meter-stack-20261017.log TEST SUCCEEDED exit0,11/11 layout tests incl new16 combinations of short/large height, orientation and exposure toggle plus disabled audio/photo mode. Confirms geometry invariants and compile wiring, not full co-rendered short-screen visual readout. F160/F161/F163 remain open for remaining basic coexistence validation; style/animation excluded.161/182 closed,21 unclosed.


2026-10-17 F076 functional completion audit: Android QueueCardSwipe custom accessibility action and iOS QueueCardSwipeModifier both expose remove only when enabled. iOS card computes eligibility from item/removing/clearing; swipe and accessibility call same onWithdraw→beginRemoval→model.withdraw, then terminal remove. Actor withdraw admits waiting only, remove rejects transferring and generating independently of potentially stale UI. New actual TransferQueue/TransferQueueViewModel/controlled-camera test delivers late removal after waiting→transferring, verifies active removal false, other waiting item cancelled/removed, active download completes and only that file was requested, then terminal removal succeeds. /tmp/ztransfer-card-removal-admission-20261017.log TEST SUCCEEDED exit0,10/10:8 current swipe state/input tests plus late command and active/waiting frame protection. Existing historical real card swipe/button/vertical-scroll/busy-interruption evidence retained. This is meaningful command/lifecycle evidence beyond static accessibility declaration, but does not claim VoiceOver physical activation or multi-touch device operation. Earlier docs retained those UI/animation gates; under user's later no-UI-test/functional-only scope, these are excluded from developer closure rather than reported tested. F076 functional scope closed;162/182 closed,20 unclosed.


2026-10-17 F078 confirmation dispatch admission: production TransferQueueView now rechecks pendingConfirmation identity and current hasClearable/hasRetryable before dispatch, rejecting callbacks after dismissal/switch or lost task eligibility. FAB and opening share confirmationIsEnabled. Android TransferScreen 253-267,616-663 and ConfirmFab/ConfirmCard distinguish connectivity (open FAB only) from task eligibility; existing open confirmation remains usable on disconnect, preserved in final code. Final /tmp/ztransfer-confirmation-final-20261017.log actual 2/2 tests, TEST SUCCEEDED, exit0 (activity/generation/departing eligibility and withdraw/retry exclusions). This verifies compilation and business regression, not actual stale UI callback replay. F078 remains open;162/182 closed,20 unclosed. No UI automation/device/commit/push.


2026-10-17 F078 input lifecycle evidence: strengthened existing production GeniePopupHostView reversal test with synchronous assertions that closing and immediate reopen keep touch disabled and accessibility elements hidden; only fully open restores both, fully closed stays hidden. /tmp/ztransfer-confirmation-input-20261017.log actual 2/2 TEST SUCCEEDED exit0 (reversal and close-before-first-frame). This is UIKit controller lifecycle validation, not UI gesture automation. Source audit: PhotoListView queueTopRightControls increments queueControlActionNonce before both valid start/pause commands; TransferQueueView receives it and clears pendingConfirmation. Scrim remains while mountedConfirmations is nonempty and consumes tap/drag; each onClosed removes only a noncurrent action, preserving a reopened owner. Task eligibility changes independently close matching pending confirmation. Actual transient gesture interception and queue-level event integration are not newly replayed; F078 remains open,162/182 closed,20 unclosed. Fine animation/style remains outside current scope. No device/commit/push.


2026-10-17 F090 functional completion audit: compared Android LocalPhotoEffectsOverlay onGenerate (clear focus/hide keyboard then snapshot requested watermark) and LocalPhotoBatchButton with production LocalPhotoEffectsView. Generate clears the same FocusState bound to the watermark TextField before reading previewSettings; text binding updates the local settings immediately. Empty choose, nonempty reselect, generation-time disabled replacement, cancelled picker preservation, READY/effect admission and COMPLETE/PARTIAL/FAILED labels are wired to LocalPhotoBatchState. Compared all seven label keys against Android values/values-zh/values-b+zh+Hant:21/21 exact matches including punctuation/placeholders. /tmp/ztransfer-f090-functional-final-20261017.log actual3/3 TEST SUCCEEDED exit0: ordered/cancelled/rejected replacement, partial/stale result isolation, all terminal outcomes/lifecycle cancellation. Source evidence establishes FocusState and accessibility-label wiring; actual keyboard presentation/VoiceOver activation was not run and is not claimed. Earlier task retained these manual UI gates plus placement/animation requirements; under user's later functional/basic-usable scope, fine placement and transition requirements are deferred rather than reported fixed. F090 functional scope closed;163/182 closed,19 unclosed. No production edit needed in this audit; no UI automation/device/install/commit/push. F013 remains open: direct same-peripheral CoreBluetooth callback integration is still not established by its ownership/queue tests.


2026-10-17 F151 functional completion: Android RemoteScreen SideEffect retains camera frames and focus judgement together only for nonempty camera frames. Added actual hosted production IOSLiveViewFocusFramesOverlay render test: unchanged geometry false->true produces green pixels, simultaneous empty frames/unfocused retains last green result, next nonempty/unfocused returns white. Initial /tmp/ztransfer-focus-feedback-20261017.log failed retained-result assertion (0 green vs168): independent frames/focused observation could overwrite retained judgement across simultaneous changes. Replaced separate lastFrames/lastFocused with one Equatable Snapshot; draw current snapshot when nonempty and update retained snapshot in one onChange, retaining complete prior packet on empty. Component made internal for test, no alternate renderer. Same unrelaxed test in /tmp/ztransfer-focus-feedback-final-20261017.log passed1/1 TEST SUCCEEDED exit0. Root view passes metadata.focusJudgement through RemoteFocusLayers independently of geometry. Fixture intentionally keeps overlay visible to inspect retained content; does not claim actual disappearance timing, camera hardware or UI gesture replay. Functional feedback requirement closed; zoom line widths, shape, scale and animation remain deferred per user.164/182 closed,18 unclosed. No device/install/commit/push.


2026-10-17 F051 preview cleanup correction: Android PhotoPreview.startPreviewQueueFlight validates enqueue before hold and clears queueAnimating/offset/job in finally before parent completion/cancellation. iOS already validates admission first, but onDisappear cancelled the Task and released count without resetting queueFlightActive or queueDragOffset, leaving retained view state unable to admit again. Now disappearance captures cancelled count, clears local count/active/offset/images/job first, then notifies parent; normal completion likewise clears count/job before callback. Production PhotoListView single/burst callbacks both perform manual admission and real enqueue before returning true; parent hold release clamps counts and cancellation does not increment queue impact. /tmp/ztransfer-preview-flight-cleanup-20261017.log actual3/3 TEST SUCCEEDED exit0: display holds do not delay real completion, actual view-model single/batch/deferred offline enqueue, whole-batch destination admission. This verifies compilation and underlying business regressions, not a hosted disappear/reappear callback replay. F051 remains open pending that lifecycle evidence; visual flight geometry/animation remains deferred.164/182 closed,18 unclosed. No UI automation/device/install/commit/push.


2026-10-17 F051 current-entry cancellation: Android PhotoPreview LaunchedEffect(currentItem.key) cancels old motion and resets offset/images/active. iOS previously only changed preview content. Added currentEntryID (photo or burst identity, not numeric index) observer calling shared cancelQueueFlight, also consumed by onDisappear. Cleanup cancels Task, clears hold count/active/offset/image state before parent cancellation; second cleanup has zero count and cannot release twice. /tmp/ztransfer-preview-page-flight-20261017.log actual2/2 TEST SUCCEEDED exit0: production retention observer paging/burst/invalid-page lifecycle plus display-hold accounting. Tests establish compilation and adjacent lifecycle/count regression, not actual flight command/disappearance replay; F051 remains open. No UI gestures/device/install/commit/push.

2026-10-17 remaining-task scope reconciliation:164/182 closed,18 unclosed. Ten retain functional/platform/validation work: F013,F033,F051,F078,F142,F160,F161,F163,F171,F177. Eight are deferred visual tasks: F003,F016,F041,F080,F083,F152,F179,F182 (F179 records no concrete input bug; any discovered input issue remains functional scope). This classifies remaining tasks only, does not invent a reclassified whole-project denominator, and does not count deferred tasks as fixed.


2026-10-17 F033 functional completion audit: read Android FileListScreen rating AnchorPopup and AnchorPopup transparent tap/drag layer, compared actual PhotoFilterPopupOverlay. Help overlay zIndex1 covers filter/list, outside tap only sets showRatingTip=false, drag consumed; help bubble zIndex2 consumes tap/drag without closing; filter panel hit testing disabled while help is presented. Root presentation changes reset help, so reopening cannot resurrect it. Help does not mutate working filter or invoke onChange. Title/description compared to Android three locales:6/6 exact matches. Rechecked historical /tmp/ztransfer-f033-help-build.log BUILD SUCCEEDED; no new build or test necessary for this source-only audit, and no gesture/VoiceOver/device verification is claimed. Earlier table retained manual touch-routing and animation acceptance; user's later no-UI-test/functional-only scope excludes those developer gates, while source audit verifies the functional event wiring. F033 functional scope closed; breathing/transition/Genie/style fidelity remains deferred.165/182 closed,17 unclosed:9 functional/platform/validation items (F013,F051,F078,F142,F160,F161,F163,F171,F177),8 deferred visual tasks unchanged. No production edit/install/commit/push.


2026-10-17 F160/F161/F163 combined readout audit found a remaining F161 functional overlap: Android RemoteScreen landscape ViewfinderCard passes MonitorDispInformationInset=32 only when CAMERA DISP and connected; ViewfinderImage applies it outside MonitorAnalysisOverlays, reducing chart height and lifting scopes above MODE/WB/AF. iOS omitted this reservation. Added shared RemoteDispLayout.informationInset=32 and matching outer bottom padding on the production scope GeometryReader, gated by landscape/CAMERA/connected. Exposure/audio stack and portrait behavior unchanged. Compared equal-slot sizing, portrait audio lane48/landscape8, mode/data gates, shared RGB normalization, waveform density, single-peak/current audio and missing/overflow EV feedback. /tmp/ztransfer-monitor-readouts-inset-20261017.log actual12/12 TEST SUCCEEDED exit0 (3 EV reading,8 analysis,1 meter geometry test across16 configurations). Earlier readouts-final run also12/12 before inset fix; final evidence is inset log. No combined screen render or UI gesture validation claimed; functional coexistence audit continues, F160/F161/F163 remain open.165/182 closed,17 unclosed (9 functional/platform/validation,8 deferred visual). No device/install/commit/push.


2026-10-17 F161 functional completion: extracted existing production scope GeometryReader/card/data gates into RemoteMonitorScopesOverlay, directly used by RemoteView with original model inputs and CAMERA informationInset condition. No alternate test-only layout. Added actual ImageRenderer test across48 combinations (3 sizes x2 information insets x2 audio lanes x4 histogram/waveform enabled states); verifies rendered bounds, equal single/double slots, waveform relocation, bottom information reservation and all-off absence. Initial transparent render and diagnostic runs failed12 all-off assertions with previous single-chart bounds; fixed-background rendering removes ambiguous empty transparent surface reuse. Assertions remain: no pixels differing from background when both modes off, and same slot/bottom/height bounds when enabled. /tmp/ztransfer-monitor-scope-render-background-20261017.log actual1/1 TEST SUCCEEDED exit0, all48 combinations; earlier failed logs retained. Combined prior12/12 readout math and meter-layout tests plus actual source/data gates closes F161 functional/basic usable scope. This tests actual scope component, not complete camera screen, hardware, gesture or animation fidelity. Histogram fill styling, transition/fade timing and fine typography remain deferred; not claimed reproduced.166/182 closed,16 unclosed:8 functional/platform/validation (F013,F051,F078,F142,F160,F163,F171,F177),8 deferred visual tasks. No device/install/commit/push.


2026-10-17 F160/F163 functional completion: exposed existing production RemoteExposureMeterOverlay and IOSSoundMeter internally for actual rendering tests (no alternate UI). EV rendering proves missing sample leaves dim scale/no pointer, zero renders balanced feedback, positive/negative overflow pointers appear at correct ends. Audio rendering proves silence has no bright segments, left/right full-current inputs affect only their channel, a peak-only input illuminates a small isolated region rather than the full bar. /tmp/ztransfer-meter-feedback-render-20261017.log actual7/7 TEST SUCCEEDED exit0 (2 actual-render tests,3 EV boundary tests,1 current/peak test,1 adaptive meter layout test across16 configurations). Root source retains connected/movie/audio gate, optional levels gate, independent EV enabled gate and metadata-driven readings; landscape right stack/portrait left lane use tested RemoteMonitorMeterLayout. Combined F161 actual48 scope bounds cases establishes reserved lanes/information row; no complete camera-screen screenshot or hardware/VoiceOver/gesture claim. Current basic usable functional feedback is closed; exact 160ms pointer/80-90ms audio animation and fine styling remain deferred by user.168/182 closed,14 unclosed:6 functional/platform/validation (F013,F051,F078,F142,F171,F177),8 deferred visual tasks. No device/install/commit/push.


2026-10-17 F171 orientation resume admission: Android re-enables OrientationEventListener on resume and unfreezing. iOS paused/cleared candidates on background/lock/editing, but never resampled on return; UIDevice may emit no new event while stationary. Added refreshOrientationCandidate gated by active notification ownership and !stopCleanupStarted; invoked when scene becomes active, lock is released, and tool editing ends. It routes through existing valid-direction/foreground/unlocked gate and260ms generation check, preserving manual suppression and conflated pending semantics. applyDeviceOrientation now also rejects teardown. /tmp/ztransfer-orientation-resume-20261017.log actual3/3 TEST SUCCEEDED exit0 for invalid/pause tickets, manual suppression across pause and latest pending request/discard; compile verifies production wiring. No physical sensor/background replay claimed. Asked platform choice via async question: CoreMotion gravity mapped to Android angle bands vs retaining UIDevice classification; NO answer yet, source unchanged. Android bands read from RemoteScreen and RemoteOrientationPolicyTest:0...30/330...359 portrait,60...120 rotation2,240...300 rotation1; invalid/gaps/upside-down ignored. F171 remains open.168/182 closed,14 unclosed (6 functional/platform/validation,8 deferred visual). No UI/device/install/commit/push.


2026-10-17 F051/F078 functional completion audit: found/fixed two final source boundaries. PhotoPreviewView flight Task checks cancellation before its first actor-turn image writes (a cancelled task can still begin); existing await-boundary checks prevent old completion. Shared page/disappearance cleanup cancels task and clears active/count/images before releasing parent hold once; normal completion clears count/task first; real enqueue admission precedes hold. TransferQueueView panel-specific dismiss now clears pending only if it still matches that action, matching Android separate showRetryConfirm/showClearConfirm flags; old cancel no longer dismisses the other panel. Confirm already rechecks identity and task eligibility, and onClosed preserves a reopened owner. Eligibility/nonce observers, shared top controls and retained scrim source checked. /tmp/ztransfer-queue-lifecycle-final-20261017.log actual6/6 TEST SUCCEEDED exit0: actual view-model offline single/batch/deferred admission, queue qualification/excluded retiring items, hold accounting and actual UIKit popup close/reversal/input lifecycle. Tests do not invoke the entire preview flight entry or every queued SwiftUI callback; those command wiring/ordering requirements are supported by source audit, not mislabeled as UI replay. Earlier retained physical gesture/full-page disappearance gates are excluded under user's later no-UI-test/functional-only scope, not reported passed. Functional scope F051 and F078 closed; image flight geometry, springs, anchors' visual fidelity and detailed transitions deferred.170/182 closed,12 unclosed:4 functional/platform/validation (F013,F142,F171,F177),8 deferred visual tasks. No device/install/commit/push.


2026-10-17 F013 functional completion audit: read every NikonGPSBluetoothClient central/peripheral callback plus Android NikonGpsBleClient GATT identity gates. Client stop clears running/current ownership and pending work; discovery/notification callbacks require current peripheral plus service/characteristic identity; ACK requires current peripheral and the exact in-flight characteristic; completion rechecks current ownership before continuation. Retirement blocks scan/direct reuse until matching terminal callback, cancelling late connect again. Verified local iPhoneSimulator27.1 SDK CoreBluetooth/CBCentralManager.h lines337-348: after didDisconnectPeripheral no further CBPeripheralDelegate methods are invoked for that old connection. This platform contract plus ownership/deadline/retirement regressions supports same-object reuse boundary; not an invented physical callback replay. Stage4 fallback checks cancellation/generation/current owner, ID confirmation gate is once-only, Coordinator GEO completion checks its write generation before lastSentAt. Found adjacent controller-ID wire mismatch: Android uses US_ASCII.copyOf(32), iOS previously UTF-8 after32 Characters. Now ASCII scalars with '?' replacement,32-byte truncation and zero padding; actual client payload test covers default,empty,CJK,emoji,combining and long names plus once-only gate. /tmp/ztransfer-gps-final-audit-20261017.log actual34/34 TEST SUCCEEDED exit0. Tests include real client deadline/publication/adapter cleanup plus production queue/retirement components and Coordinator late ACK/recovery; complete physical peripheral delegate integration remains unrun, no hardware claim. Earlier document made physical/reused-object callback replay an outstanding developer gate; source+SDK contract+boundary regressions establish functional implementation without requiring unauthorized camera/device testing. F013 functional scope closed; physical interoperability remains hardware validation.171/182 closed,11 unclosed:3 platform decisions/work (F142,F171,F177),8 deferred visual tasks. No device/install/commit/push.


2026-10-17 remaining-platform audit: re-read F177 production exclusive long-press/tap gesture, hold tracker, configuration/disappearance cleanup and Android feedback interaction/disposal contract. No new independent functional defect established; existing7/7 feedback evidence retained, actual gesture replay not claimed. F142 current writer stop still has no total finish deadline; F171 still uses UIDevice categories; F177 remains450ms. Async questions for F142/F177 consolidated, F171 question already pending; no user answer. Updated front-of-ledger latest count to171/182 with3 unresolved platform items and8 deferred visual tasks, correcting misleading historical152 heading. No new production edit/build/test this audit. Required platform decisions remain outstanding; do not infer approval from elapsed time or automatic goal continuations.


2026-10-17 U001: header diagnostic proves GetDeviceInfo local transaction 1 returns success with wire transaction 1831, then 1838. Log /tmp/ztransfer-usb-header-console.txt. PTPSession mismatches invalidate the session and trigger reconnect loops. Added ImageCaptureUSBTransport.correlatedPTPResult to normalize ONLY framework per-request completion transaction IDs after current camera/token validation, preserving response type/code/parameters/data validation; raw transports unchanged. Added two tests, NOT RUN yet. Device build currently live exec session98929, /tmp/ztransfer-usb-correlation-build.log. Next finish build/install/launch diagnostics, verify real list loading, run targeted tests. Header app console still session26840. System initial enumeration itself remains unresolved; full goal remains active, do not mark complete for correlation alone.


2026-10-17 U001 progress: correlation fix built/installed and real screenshot /tmp/ztransfer-usb-correlation-loaded.png proves photos and thumbnails load; user confirms but slow. /tmp/ztransfer-usb-correlation-tests.log TEST SUCCEEDED 6/6, exit0 (two new correlation tests). Repository line2226 reverses Nikon handles and publishes batches; visible dates newest first. System preflight metadata reads 512KiB per file before our requests proceed, still unresolved. User requested diagnostic button bottom center: fixed DebugPhotoProtectionPanel full GeometryReader frame; /tmp/ztransfer-usb-bottom-button.png verifies bottom center. Current installed probe build /tmp/ztransfer-usb-metadata-probe-build.log BUILD SUCCEEDED: DEBUG env ZTRANSFER_USB_SKIP_METADATA_PROBE=1 makes shouldGetMetadataOf return false with callback trace; hypothesis only, not proven to affect initial enumeration. Current LIVE console exec session56730, /tmp/ztransfer-usb-metadata-probe-console.txt. Next inspect whether veto callbacks occur and whether initial wait improves; remove ineffective experimental hook if not. Full goal remains active.


2026-10-17 U001 metadata-veto experiment completed: /tmp/ztransfer-usb-metadata-probe-console.txt reached ready and hundreds of successful object/thumbnail commands; ZERO metadata queue veto callbacks in complete cycle. Thus this public delegate does not intercept this Z30 initial enumeration. Removed DEBUG experimental callback from source; installed binary still contains inert probe until next authorized build, no further reinstall merely for cleanup. Session56730 live, photos load after initial wait. Full objective remains open. Next investigate public session options or other supported transport mechanisms; do not repeat veto experiment. Correlation tests 6/6 remain valid; no claim that initial occupation fixed.


2026-10-17 U001 public-API blocker audit (first explicit platform-blocker turn after completed veto experiment): Apple DTS https://developer.apple.com/forums/thread/802640 explicitly states raw USB userspace APIs are not available on iOS; DriverKit is iPadOS-only and IOKit driver support macOS-only. ExternalAccessory requires appropriate MFi hardware, so it is not a generic replacement for current Z30 USB-C PTP. Current iPhoneOS SDK ICSessionOptions declares only ICEnumerationChronologicalOrder; official Markdown https://developer.apple.com/documentation/imagecapturecore/icsessionoptions/enumerationchronologicalorder.md provides no documented skip-enumeration behavior. Do not infer that setting false disables enumeration, and do not claim impossibility beyond supported/documented APIs.
Reproduction for Apple investigation: iPhone15 iOS27.0.1 + Nikon Z30 direct USB-C, contents/control authorization granted; requestOpenSession succeeds; immediately submit PTP GetDeviceInfo; ptpcamerad starts PTP1.0 enumeration and reads 524288-byte prefixes for basic metadata; app per-request completion waits until deviceReady. shouldGetMetadataOf callback implemented to return false is never invoked during that cycle. After readiness GetDeviceInfo and own newest-first catalog/thumbnail commands work. Physical transaction IDs differ from app IDs, now correctly adapted at framework callback boundary; do not mix this fixed issue with initial enumeration delay. Evidence: /tmp/ztransfer-usb-header-console.txt, /tmp/ztransfer-usb-correlation-console.txt, /tmp/ztransfer-usb-metadata-probe-console.txt; 6/6 tests /tmp/ztransfer-usb-correlation-tests.log; photos shown /tmp/ztransfer-usb-correlation-loaded.png; bottom debug button /tmp/ztransfer-usb-bottom-button.png. No report sent externally, no camera content uploaded. Remaining full objective: avoid system initial occupation, not merely eventually display photos. Need a supported Apple mechanism or new evidence; goal remains active, not complete.


2026-10-17 U001 blocker revalidation #2: inspected full ICDevice/ICCameraDevice public declarations. requestYield is explicitly IC_UNAVAILABLE(ios) and deprecated even on macOS; requestSendMessage is also unavailable on iOS. Catalog progress/contents/mediaFiles are readonly. Thus no additional supported yield/cancel-initial-enumeration entry found; same platform blocker persists. No speculative KVC/private selector injected, no destructive camera workaround. Need Apple-supported mechanism/new external evidence to meet full direct-cable objective. Not complete.


2026-10-17 U001 additional physical probes (still NOT fixed):
- Chronological enumeration false: /tmp/ztransfer-usb-chronology-console.txt, OpenSession t=2442.758364; first GetDeviceInfo submitted t=2443.062556, returned t=2502.063246 (59.000690 seconds). Device ready t=2502.048542. This option does not skip initial enumeration. Earlier commentary saying the request was still pending after 90 seconds was an observation error; the timestamped log is authoritative.
- Immediate submission inside OpenSession completion, default options: /tmp/ztransfer-usb-early-console.txt, diagnostic GetDeviceInfo t=2669.457852 -> t=2728.327844 (58.869992 seconds), ready t=2728.316059. First didAdd catalog batch at t=2728.385397, AFTER readiness. Thus neither earlier app submission nor incremental catalog callbacks bypassed the initial wait in this run. Both experiments returned the first physical response transaction 1831. No photo count inferred from that ID.
- Both device builds succeeded and were installed. Removed both DEBUG experimental request/option branches after evidence; kept environment-gated monotonic timestamps and catalog batch diagnostics. No private API or authorization reset used. Source continues to own newest-first PTP scan (Android CameraViewModel handle-order basis; iOS CameraRepository reverses per-storage handles). No new automated tests for diagnostic-only edits; earlier correlation tests remain 6/6, not proof of initial-enumeration performance.
- Public implementation research: https://github.com/jongan69/expo-sony-camera/blob/main/ios/SonyCameraController.swift opens a normal ImageCaptureCore session, not a demonstrated Z30 enumeration bypass. https://github.com/elfmz/far2l/blob/master/mtp/README.md bypasses macOS daemon ownership using preferences/process termination; not an iPhone solution. Apple DTS https://developer.apple.com/forums/thread/802640 confirms no public raw USB userspace API on iPhone. No verified public direct-cable solution found. Do not mark U001 complete or substitute cached stale rows as a fix. Remaining unknown: an Apple-supported enumeration suppression/prioritization mechanism or reproducible third-party iPhone/Z30 behavior demonstrating a different route.

2026-10-17 U001 probe cleanup: /tmp/ztransfer-usb-probe-cleanup-build.log BUILD SUCCEEDED, cleanup binary installed successfully on the authorized iPhone. No early-request or chronology probe remains; no new performance fix claimed. git diff --check passed.


2026-10-17 U001 competitor research (no production changes/build/install this turn):
- Cascable Studio is the best ordinary USB/PTP comparator. Official https://cascable.se/help/wired-cameras/ says detection/connection should take a few seconds, supports Nikon USB control/import, and requires PTP/MTP (Sony PC Remote is a separate case). This is not a measured first-photo guarantee for this Z30/card/iOS combination.
- Official SDK guide https://github.com/Cascable/cascablecore-demo/blob/master/Getting%20Started%20With%20CascableCore.md describes lazy per-folder loadChildren, deferred per-file metadata, and camera-initiated image transfers independent of browsing the full filesystem. Those are application-level strategies; they do not prove suppression of ImageCaptureCore's own enumeration. The guide recommends stopping discovery after finding a camera. Our browser remains running; a DEBUG-only browser-stop-after-successful-open experiment is a new candidate, NOT implemented or validated. Must retain camera/session ownership and distinguish browser removal notifications from physical disconnect; do not adopt production behavior that breaks replug discovery.
- CascableCore changelog CORE-725 slow discovery fix was network/firewall discovery blocking other discovery types; our current delay is after OpenSession so do not conflate. CORE-1172 concerns Sony events with discovery left running, not evidence of a Nikon fix. https://github.com/Cascable/cascablecore-distribution/blob/main/CHANGELOG.md
- Nikon NX MobileAir's current official guide https://nikonimglib.com/nxmoba/onlinehelp/en/03_connect_01.html explicitly lists USB-C to USB-C and iPhone USB mode. Important correction to older blanket assumptions: Z30 has an iPhone mode; we have not established its transport/protocol authorization, so cannot declare the camera incapable of any accessory path. No publicly documented reusable third-party interface found. Do not switch user camera mode or claim this is a drop-in MTP/PTP fix.
- Capture One mobile official tethering guide describes capture workflow; no documented initial enumeration suppression method found. ShutterSnitch references found primarily concern network/FTP reception; not evidence of bypassing this direct USB issue.
- Read-only devicectl inventory confirmed no Cascable/NX MobileAir/Capture One installed (among targeted matches only ZTransfer). Asked user for one same-iPhone, same-Z30, same-card, same-cable Cascable Studio comparison in MTP/PTP, no subscription purchase. Need cold-connection first-photo timing, not merely connected status; beware cross-app warm system catalog. Awaiting response. Cannot install App Store app via devicectl; SDK demo requires a trial license. No external messages or license requests sent. U001 remains open.


2026-10-17 U001 further diagnostics (not resolved): User reports Cascable also did not react on plug-in; no measured connected-to-first-photo comparison, so this does NOT demonstrate a one-minute wait in Cascable.
- DEBUG browser.stop() immediately after successful open: built and installed successfully (/tmp/ztransfer-usb-stop-browser-build.log). /tmp/ztransfer-usb-stop-browser-console.txt shows stop at t=3546.004155, device delegate removal at3546.004192 and3546.017248, then GetDeviceInfo submitted3546.054896 without callback before next diagnostic relaunch. Keeping the local camera reference/hasOpenSession=true did not preserve a usable discovery session. Removed probe; not a valid production fix.
- Historical runtime header https://github.com/LeoNatan/Apple-Runtime-Headers/blob/master/iOS/Frameworks/ImageCaptureCore.framework/ICCameraDevice.h lists preheatMetadata. DEBUG capability-checked test on current iPhone: /tmp/ztransfer-usb-preheat-console.txt reports selector available=false at3607.924045. No private setter was actually invoked. Probe removed from source.
- New read-only local system inspection: strings /usr/libexec/ptpcamerad (macOS binary, NOT iPhone proof) contains ICEnumerationPrioritizeSpeed, Enum-Priority, Set Prioritize Speed/Fidelity, prioritizeSpeed. Public SDK headers do not establish this as a supported API. Added DEBUG/env-only ZTRANSFER_USB_SPEED_PROBE option in requestOpenSession to test, not approved/adopted for production. /tmp/ztransfer-usb-speed-priority-build.log BUILD SUCCEEDED and installed. First two launches exited0 before device discovery; /tmp/ztransfer-usb-speed-priority-state.png shows Home screen. Therefore NO speed result yet. Requested user keep camera on/connected and ZTransfer foreground; no response yet. Console /tmp/ztransfer-usb-speed-priority-retry-console.txt session79287 terminated. Installed binary also contains inactive guarded preheat probe, removed in source. Need finish experiment and clean up; do not claim success or failure for speed flag until actual session opens and request returns. No new automated tests.


2026-10-17 U001冷启动入口纠正：用户连续反馈手势结束后重开直接进入照片页。真机截图/tmp/ztransfer-usb-speed-priority-current.png为“有线连接已断开”的列表壳，/tmp/ztransfer-usb-speed-priority-measured-console.txt仅授权事件、无设备发现；不能解释成自动重连或应用杀不死。RootView的camera_workspace_entered与camera_workspace_monitor使用SceneStorage，错误跨冷启动恢复。对照Android MainActivity NavHost startDestination=Home及MainNavigationPolicyTest（无冷启动专项），改为本次运行的State；保留establishedSession和同次运行的断线工作区。旧1.91台账SceneStorage恢复结论已更正，RestoredCameraWorkspaceTests仅验证离线模型，不能证明启动导航。/tmp/ztransfer-cold-start-route-build.log BUILD SUCCEEDED，修复版安装成功并明确启动一次；/tmp/ztransfer-cold-start-route.png实际画面为连接页，控制台/tmp/ztransfer-cold-start-route-console.txt启动后无会话事件。本轮未运行自动化/UI测试，未重放本次运行内断线/重连；未提交/推送。USB约59秒初始枚举等待仍未解决；DEBUG环境门控speed probe随后已收到真实接入，等待首条命令测量，不计生产修复。


2026-10-17 U001速度选项实测失败：用户回复“刚插上”后，/tmp/ztransfer-cold-start-route-console.txt记录真实deviceAdded t3910.140503、speed选项请求t3910.150557、sessionOpened t3910.150723、首条GetDeviceInfo提交t3910.457974、ready t3969.449709、首条完成t3969.455248，等待58.997274秒，响应物理事务仍为1831。无加速证据，DEBUG speed选项已从源代码移除；手机已装的诊断版仍含环境门控代码，本轮暂不为移除探针打断现有相机会话。无新测试。不能由接近59秒推断是固定超时，继续查系统时间线。冷启动修正已真实验证，初始目录占用仍未解决。


2026-10-17 U001系统时间线取证受阻：Console窗口原有本轮ptpcamerad日志，筛选/选择后UI连续30/45秒无响应，未导出成功；不得称已审完完整系统时间线。log collect --device-udid要求root；sudo -n未获现有凭据。devicectl diagnose同样要求Password，已Ctrl-C退出，两个zip仅失败诊断记录，不是完整设备日志；未输入密码/改权限/上传。现有idevicesyslog支持archive，但--network找不到仅通过CoreDevice配对的iPhone。已请用户暂将iPhone改接电脑并解锁/信任以获取刚才记录，不要求重新复现。等待硬件连接后用idevicesyslog archive，start-time=1792206288（2026-10-17 11:04:48+0800），仅本地分析ptpcamerad。启动路由已验证修好；完整USB性能目标仍未解决。主代理独立工作，无子代理。


2026-10-17 U001完整设备日志到手，重要纠正：用户把iPhone改接Mac后，idevicesyslog archive退出0，/tmp/ztransfer-usb-speed-system.tar（228MiB）已本地解压到/tmp/ztransfer-usb-speed-system.logarchive。log show限定ptpcamerad与11:04:48–11:06:00，/tmp/ztransfer-ptpcamerad-speed-timeline.txt共508行。11:04:56.289明确Set Prioritize Speed，证明选项在当前iPhone被接受；不是忽略了参数。11:04:56.309开始PTP1.0枚举，11:05:55.566/.568返回2目录、1825文件，.587报告1827 Preflighted/ready。首条512KiB readStream/fetchBasicMetadata在11:05:55.749，发生于ready之后。此前“系统512KiB预读造成前59秒”等因果结论证据不足，至少本轮已被时间线否定；不能沿用。前59秒落在PTP1.0全对象预扫描，日志未记录逐对象命令，不宣称已证实每条时延或固定timer。
新线索：requestStartUsingDevice、DeviceInfo与session properties在应用OpenSession之前已有；用户OpenSession才触发enumerateContent。当前SDK requestSendPTPCommand说明限制为相机PTP能力，未明确要求先OpenSession。新增DEBUG/env ZTRANSFER_USB_PREOPEN_PTP_PROBE，只在正常open前发送只读GetDeviceInfo并记录响应，然后仍走原open流程；不伪造hasOpenSession、不提前发布业务会话。/tmp/ztransfer-usb-preopen-ptp-build.log BUILD SUCCEEDED，等待安装/接相机实测。其作用仅验证公开接口是否能在目录枚举前工作，不是已完成修复。未运行新自动化/UI测试，未提交/推送。


2026-10-17 U001关键新实测：/tmp/ztransfer-usb-preopen-ptp-console.txt真实重插，t4522.811903在camera.hasOpenSession=false时调用公开requestSendPTPCommand(GetDeviceInfo)，t4522.829239成功返回531字节、PTP2001/transaction1，耗时17.337ms；随后仍调用旧requestOpenSession，应用正常首读再排队。这推翻“必须先建立ImageCaptureCore目录会话才可发送PTP”的既有假设，但GetDeviceInfo本身不充分证明需会话的存储/照片命令可用。
下一步DEBUG/env ZTRANSFER_USB_PTP_ONLY_PROBE先验证GetDeviceInfo与GetStorageIDs的成功响应/存储数据集，并检查相机对象与生命周期身份，才发布应用业务通道，不调用requestOpenSession目录API。后续沿用原PTP目录/缩略图流程。/tmp/ztransfer-usb-ptp-only-build.log BUILD SUCCEEDED，已安装并启动，控制台/tmp/ztransfer-usb-ptp-only-console.txt，等待该轮完整结果。当前为诊断路径，尚未默认生产启用或宣称性能问题已修复。


2026-10-17 U001直通诊断路径跑通：/tmp/ztransfer-usb-ptp-only-console.txt中，t4649.063371 deviceAdded；GetDeviceInfo t4649.075161→.087440，GetStorageIDs t4649.087540→.094552，两者在hasOpenSession=false成功，随后发布业务session。首批句柄t4649.766838（接入后0.703秒）、首条ObjectInfo t4649.925589（0.862秒）来自真实相机。/tmp/ztransfer-usb-ptp-only-loaded.png显示日期分组和照片；此轮无系统ready/catalog batch。缩略图可能命中原磁盘缓存，尚不声称所有图都是当轮新下载；不是完整新插拔验收。
已将相同公开PTP通道方式整理为默认实现，移除诊断环境分支与所有requestOpenSession调用（注释保留原因）。公共requestPTP桥接同时服务握手与正常命令，回调先检查相机/代次或已建立token，再做事务相关处理。握手真实GetDeviceInfo+GetStorageIDs响应/数据集校验，任务取消不发布；物理didRemove同步移除应用session/token以释放旧引用。ConnectionService说明同步更正。新增4项握手单测（空/非空存储、坏DeviceInfo、session-not-open/截断存储、首读后取消），与既有连接状态/6项映射相关测试一起运行，/tmp/ztransfer-usb-ptp-only-tests.log；未完成前不记通过。生产默认版本尚未安装，仍需冷插拔与新缩略图验证。无UI测试、提交或推送。


2026-10-17 U001冷重插反馈仍慢，不能核销：用户回复“仍然要等很久”。/tmp/ztransfer-usb-ptp-only-console.txt只记录t4957.109874移除与进程exit0，没有后续deviceAdded；之后设备进程列表仍有ZTransfer，/tmp/ztransfer-cold-replug-reported-slow.png最终已有照片。旧诊断二进制直通路径依赖启动环境，普通重新启动仍走系统目录；不能把这次无新接入日志误算直通重插失败，也不能断言用户如何结束进程。此为诊断版本交付不完整，已明确说明，需安装默认实现后重新取证。
默认实现复核Android NikonCamera.connectUsb（2504–2580）：仅要求GetDeviceInfo成功响应，可选DeviceInfo数据为空/解析失败不阻断；存储查询属于后续扫描，不作为新增连接门槛。撤掉草稿中必须通过GetStorageIDs/数据集解析的握手门控，保留取消、响应类型/返回码与相机身份校验。四项单测改为可选数据容错、相机失败响应、坏响应包、取消后拒绝成功。
前一草稿测试/tmp/ztransfer-usb-ptp-only-tests.log实际30/30、TEST SUCCEEDED，包含20连接状态与10映射/握手测试，但其三项握手断言已按安卓容错修订，不能作为最终源代码通过证据。最终版本专项/tmp/ztransfer-usb-direct-final-tests.log正在运行；真机构建/tmp/ztransfer-usb-direct-final-build.log正在运行，尚未安装。无UI测试、子代理、提交或推送。


2026-10-17 U001默认版本安装与用户重插确认：/tmp/ztransfer-usb-direct-final-build.log BUILD SUCCEEDED，已安装到iPhone（bundle路径53A6D47E-214C-4A50-B9D2-998EDB4E9E2E）。仅以ZTRANSFER_USB_DIAGNOSTICS=1启动日志，不含任何直通实验开关；源代码没有requestOpenSession调用或PROBE分支，普通启动同样使用公开PTP通道。
/tmp/ztransfer-usb-direct-default-console.txt本次启动deviceAdded t5242.342460，通道成功t5242.380983，GetObjectHandles返回t5243.021929（0.679469秒），首条GetObjectInfo返回t5243.172900（0.830440秒），返回码2001；无system ready/catalog batch。/tmp/ztransfer-usb-direct-default-loaded.png实际显示最新日期照片。随后请用户仅拔插相机端一次，用户明确回复“几秒内出现”。这构成用户重插验收反馈；上述0.68/0.83秒属于本次应用启动的日志，当前控制台尚无另一次remove/add，不把这些精确秒数冒充冷重插测量。缩略图可能命中原缓存，不声称所有文件/全尺寸传输均本轮重新验证。最终修订的30项模型专项仍在收尾，完成前不记录测试通过。


2026-10-17 U001本次修复收尾：最终/tmp/ztransfer-usb-direct-final-tests.log为30/30、0失败、TEST SUCCEEDED、exit0（20项ConnectionStateTests、10项ImageCaptureErrorMappingTests，含4项最终握手测试：可选DeviceInfo容错、失败响应、坏响应容器、取消后拒绝成功）。与/tmp/ztransfer-usb-direct-final-build.log BUILD SUCCEEDED、默认版安装/启动真实PTP响应及用户重新插线“几秒内出现”共同确认：当前iPhone 15 / iOS27.0.1 / Z30的连接后约一分钟首屏等待问题已修复，U001此次连接与初始加载范围核销。系统全卡目录不再由应用打开；公开PTP渠道握手后由现有Repository按新到旧扫描并增量显示。不是只取消等待状态或用缓存假装成功。
证据范围：0.679/0.830秒为默认版启动后真实句柄/首条信息返回；重插速度由用户确认，本次控制台未捕获第二组remove/add，不能将启动计时写成独立冷插拔计时。截图缩略图可能来自原缓存，未据此宣称全部缩略图/全尺寸传输或其他机型已重测。专项是模型/协议测试，不含UI自动化。历史F001–F182计数仍174项核销、8项延期视觉，不为U001改分母。git diff --check通过；未提交/推送，未使用子代理。


2026-10-17 用户请求速度胶囊和进度动画优化：新增局部视觉授权，未扩成全面样式复刻。已对照Android FileListScreen QueuePill、TransferProgressMotion/LiquidProgressFill及对应测试。顶栏与卡片共享240ms数字滚动过渡（iOS16淡化，减弱动态效果直接更新），原始速度/单位格式不改；顶栏的progress对象由State持有跨分支生命周期，只在TransferProgressContent绘制叶节点观察帧更新，避免每帧重建整组文字/玻璃/布局。模式稳定时数字采样不再重启模式透明度时钟，进行中转场保留原中断规则。现有180临界阻尼弹簧、同任务只前进、新任务从0起步、完成/失败/取消进度语义保留。/tmp/ztransfer-queue-readout-smoothing-tests.log实际8/8、TEST SUCCEEDED、exit0（7既有边界回归+1稳定模式更新回归）；无UI自动化或实测FPS证据。真机优化版正在按既有同机验证安装授权构建，/tmp/ztransfer-queue-readout-smoothing-build.log；安装前截图为桌面，旧诊断进程已exit0。未提交/推送；不据此核销整项F080/F083或其他延期视觉任务。完整说明见docs/技术调研/iOS-队列速度胶囊复刻.md。


2026-10-17 速度/进度优化交付：/tmp/ztransfer-queue-readout-smoothing-build.log BUILD SUCCEEDED、exit0；已覆盖安装到同一iPhone（应用目录663AF847-710C-42C3-B3AA-FA8207257ACB），devicectl普通启动成功，未附加诊断/实验启动参数。8/8专项通过证据保持。未自动发起相机下载、未运行UI自动化；真实传输主观手感及FPS未测，不宣称已完成视觉验收。git diff --check通过。当前修改尚未提交/推送。


2026-10-17 U002 有线首批传输偶发低速：用户补充首次队列见1.x/3 MB/s，后一批恢复；免费25次已用完。采用仅开发启动启用的同机自动读图测试，不改FreeUsageStore/会员、不进入用户保存队列、不扣额度；在独有临时子目录写入后删除。全部使用同一iPhone 15/iOS27.0.1/Z30和同一张10,504,207字节JPEG。临时测速实现已从生产源码移除，备份/tmp/ztransfer-usb-read-benchmark-source.swift，仅保留显式环境启用的有界协议/写盘诊断。
- 实测/tmp/ztransfer-usb-throughput-benchmark-console.txt：4MiB分块两轮30.63/29.16 MiB/s，GetObject两轮37.51/37.69 MiB/s，单范围partial 37.68 MiB/s，五次SHA256一致。说明分块有固定开销，但不是个位数的充分原因；最终保持4MiB内存上限，没有以无界整文件回调换速度。
- /tmp/ztransfer-usb-throughput-repository-console.txt：正式Repository下载到临时目录/用户选择目录分别373.84/375.19ms（26.80/26.70 MiB/s），写盘约8ms、发布约4ms。旧适配器在整块回调后才sink.started，重置200ms节流，紧接着received不再发布；实测4MiB旧字节被除以第二块完成后的时间，读数仅约14.6MiB/s，低于真实端到端速度。
- /tmp/ztransfer-usb-first-transfer-console.txt在修正读数后捕获真实扫描争用：同样10,504,207字节，第二次探测1042.26ms、9.61MiB/s；三块gate_acquired分别456.554/127.232/138.767ms，合计722.553ms，而框架等待118.441/121.760/74.190ms、总写盘1.942ms。说明后台ObjectInfo批次既拖住首块，又在4MiB分块间取得通道。用户所说1.x/3的原始那轮未捕获，不将9.61谎报为同一轮；这是同类首次扫描期间争用的直接证据。
- 修复依据：Android NikonCamera.downloadToFile的USB照片用单GetObject，后台不会在同一照片数据中插入。iOS仍采用有界分块，但CameraIOGate新增仅USB照片启用的整文件后台准入屏障，覆盖正常、失败、取消释放；预览/交互保留优先，视频/AP/STA策略不变。USB目录在每条完整ObjectInfo后归还通道，合并游标、跨卡排序、发布批次、错误及续扫规则保留。PTP默认回调适配器在发起读取前sink.started，已收字节用真实时间正常发布，不修改端到端速度公式。没有重新打开系统目录或引入预热要求。
- /tmp/ztransfer-usb-photo-priority-console.txt修复后在列表扫描运行时，不预读照片数据：用户选择目录322.32ms/31.08MiB/s，临时目录343.46ms/29.17MiB/s；首轮首块等当前命令7.388ms，后两块0.077/0.051ms，第二轮三块0.049/0.084/0.300ms。测量是同相机保持连接、应用重启后的首次下载/后续扫描争用，不是每轮物理冷拔插，也非所有机型保证。原诊断字段receive_wait/wire_bytes对USB只代表框架回调等待/有效载荷，最终改为framework_wait_ms/framework_payload_bytes以免误称USB线速。
- 验证：/tmp/ztransfer-usb-progress-callback-tests.log 10/10 TEST SUCCEEDED；/tmp/ztransfer-usb-photo-priority-tests.log 61/61 TEST SUCCEEDED、exit0（22调度、31扫描、2下载、6完整性）。新增默认框架适配器延迟回调真实进度、分块间后台阻挡/前台预览放行/取消释放、真实Repository半批扫描让下载且续扫不丢句柄三项回归。临时测速入口移除后/tmp/ztransfer-usb-throughput-final-build.log BUILD SUCCEEDED、exit0。无UI测试、子代理、提交或推送；台账仍174/182、8项延期视觉，不改变分母。

2026-10-17 U002最终交付：移除自动测速入口后的日常版已安装到同一iPhone，应用目录2C439E41-DDA7-4D31-B58F-470AD7D8A54D；最终构建exit0。git diff --check通过，保留上一轮未提交的速度/进度动画优化，无提交/推送。


2026-10-17 U003–U005 用户本轮三项修正（开发中，验证结果待补）：
- U003：用户明确 USB/STA 信号按钮不响应点击，优先于 Android FileListScreen.SignalPill 旧有“USB 展开/STA 离线重连”行为。列表顶栏、列表内队列顶栏、独立队列和监看共用 CameraSignalControl；禁用点击/按压反馈且保持材质颜色，移除 USB 展开状态和 STA 点击重连。AP 原有离线设置入口保留，无新增 RSSI 能力。
- U004：Android AnchorPopup 先完成最终尺寸测量、下一帧开始动画，Surface 边框随整层变形。iOS 旧实现 layoutSubviews 立即 CALayer.render，首轮高度 preference 后到时不更新快照；Settings 额外居中描边还有半线宽溢出截图范围。改为下一显示帧在布局完成后整体取图，尺寸改变整张重捕获，描边改为内描边，原 320/350ms 曲线/反转语义保持。取图耗时不扣减可见动画时长。新增真实 SettingsView 截图边缘/高度交接测试，不是端到端 UI 自动化或真机肉眼验收。
- U005：之前普通真机 devicectl 安装未激活 Xcode .storekit 会话，因此不能用假支付。用户明确授权仅开发版模拟购买；新增 DEBUG 年度/永久模拟权益和可见说明，不扣款、不用 Apple 账户、重启持久化，真实 StoreKit 刷新不会覆盖活动模拟，退出恢复最新真实权益。独立存储键 debug.simulatedPremiumPurchase.v1，不清 FreeUsageStore。Release 不编译模拟类型、入口、读取或启动参数；不是 Apple 沙盒支付验收，不改变真实购买/恢复/退款流程。日常测试可从设置“解锁高级版/测试权益”管理。
- 首轮 /tmp/ztransfer-settings-payment-tests.log 编译失败：新增测试用 CGImage 条件转换，Swift 6 不允许；已修正，不记测试通过。当前 /tmp/ztransfer-settings-payment-fixed-tests.log 运行中。主代理独立处理，不运行 UI 自动化、未提交/推送；历史 F001–F182 仍 174/182，8 项延期视觉，不借本轮改分母。

2026-10-17 U004/U005 中间验证：/tmp/ztransfer-settings-payment-fixed-tests.log 执行22项，支付/额度18项通过，弹窗4项中2项失败、3处断言失败。依据 [Apple 完整视图截图说明](https://developer.apple.com/library/archive/qa/qa1817/index.html) 试用 drawHierarchy(afterScreenUpdates:true)，但实测当前隐藏宿主返回透明图，即使接口报告完整；已撤回该截图方式，继续使用已有 snapshot-stable 面板图层，只修布局时机、尺寸重捕获和内描边。此失败保留，不据文档推断本工程可用。新加正式 TransferQueue 免费25次耗尽→模拟购买→失败任务重试成功→退出模拟恢复限制的业务测试，最终 /tmp/ztransfer-settings-payment-final-tests.log 运行中。此前 device-build 构建成功但包含已撤回试验，未安装；最终构建为 /tmp/ztransfer-settings-payment-final-build.log。

2026-10-17 U003–U005 最终专项：/tmp/ztransfer-settings-payment-isolated-tests.log 为23/23、0失败、TEST SUCCEEDED、exit0（17权益模型、2正式队列、4弹窗宿主渲染/反转）。真实 SettingsView 动画快照在高度400→520后按最终尺寸重取，边缘像素与展开后的真实面板一致性通过；含首帧非透明、关开反转、交互禁用/恢复。免费25次耗尽的真实 TransferQueue 在模拟购买后重试成功、实际测试文件发布，结束模拟恢复限制，次数始终25。未运行端到端 UI 自动化或宣称真机肉眼闪烁验收完成。前两份 final-tests/verified-tests 日志分别因新增队列夹具共享 UserDefaults、XCTUnwrap 主 actor 捕获编译失败，均已修正并保留。
真机构建 /tmp/ztransfer-settings-payment-final-build.log BUILD SUCCEEDED。完整手机偏好 plist 导出被自动审批拒绝（可能夹带其他敏感状态），未执行/未导出；改为 DEBUG 显式 --report-development-premium 参数只打印模拟商品 ID、isPro 和传输次数三个状态，不读取/输出其他偏好。追加这个定向日志入口后交付构建 /tmp/ztransfer-settings-payment-delivery-build.log 运行中；业务与渲染代码未变，23项证据对应最终行为，手机安装和重开验证待补。

2026-10-17 U003–U005 交付完成：/tmp/ztransfer-settings-payment-delivery-build.log BUILD SUCCEEDED、exit0；安装到同一 iPhone 15，应用目录50A589D4-C845-4EB0-B72E-A9F11307D227。手机定向诊断工具输出：启用前 simulated_product=none/is_pro=false/transfers=25；用户授权的 --simulate-premium-lifetime 启用后 lifetime/true/25；结束进程后仅带 --report-development-premium（不带购买参数）重开，/tmp/ztransfer-premium-restored-console.txt 再次 lifetime/true/25，证明模拟权益已持久化，未清免费次数。最终结束诊断进程并无参数普通启动成功，无残留控制台会话。整份偏好导出未执行，定向状态读取获准完成，无剩余审批阻塞。
23/23 专项证据保持；最终多出的仅是显式 DEBUG 定向日志，无业务/渲染变更，未为日志入口重复跑测试。USB/STA 点击逻辑完成源码收口；设置窗真实宿主边缘/高度交接回归通过，尚未由用户确认真机主观闪烁观感，无 UI 手势自动化或 FPS 测量。U003–U005 完成开发侧修复及当前手机交付，旧延期视觉分母不变。覆盖索引相关11份源码哈希一致，git diff --check通过。未提交/推送、未使用子代理；既有U002和速度动画未提交修改全部保留。


2026-10-17 U004用户复测撤回收尾：用户报告“设置窗弹出后有高度跳变”，并指出“外皮框+内部可滚动内容”和安卓不同。之前23项仅验证固定尺寸宿主的快照/描边交接，没有覆盖SettingsPopupOverlay的真实高度偏好回传；不能据此前通过宣称整个设置窗结构/高度已验收。已重新完整对照Android SettingsScreen.SettingsOverlay 511–633：标题/卡片/页脚在同一个verticalScroll Column，Surface自然包裹、超高整体滚动，初次布局确定后再展开。iOS原先header在ScrollView外，且使用availableHeight临时高度直接展开、随后contentHeight回传改框，再由Genie.sizeThatFits二次推算高度。
本轮修正：主设置与效果页各自整列ScrollView（含标题），单次测量整列高度；弹出先等待当次presentation内容测量、拒绝上一代迟到回调；明确外层指定最终frame，Genie不再二次计算已确定的设置视口。新加完整生产SettingsPopupOverlay宿主测试，采样首个可见帧到完全展开的高度、短内容包裹/小屏整列滚动/两处入口/换视口重开，而非只有固定frame测试。/tmp/ztransfer-settings-whole-column-tests.log运行中，未完成前不记通过。保留此前内描边/整图捕获和DEBUG模拟会员，未安装本轮代码，未提交/推送、无子代理及端到端UI自动化。


2026-10-17 U004整列结构与高度修复交付：最终 /tmp/ztransfer-settings-whole-column-isolated-tests.log 为6/6、0失败、TEST SUCCEEDED、exit0（4项原宿主快照/反转回归，2项完整生产SettingsPopupOverlay布局生命周期测试）。覆盖两个入口393×852、393×450超高内容整列滚动、关闭后换高重开；在每轮首次可见帧到完全展开连续采样，高度极差≤0.5pt，滚动视口从面板顶部开始且覆盖整个面板，短内容按自身高度包裹。关闭/重开、快照到实时视图交接后的交互恢复亦通过。首轮 /tmp/ztransfer-settings-whole-column-tests.log 因测试辅助闭包缺少MainActor标注编译失败，已修复，保留失败日志，不记为通过。
真机构建 /tmp/ztransfer-settings-whole-column-build.log BUILD SUCCEEDED、exit0；安装到同一iPhone 15，应用目录475079BE-11C5-48EB-9BBB-B2BB3DAE5920，并无参数普通启动成功。安装前截图 /tmp/ztransfer-settings-height-before-install.png 已确认无进行中传输。此前USB/STA信号禁点、DEBUG模拟永久权益和有线速度修复保持；未重置免费次数。本次是生产宿主布局/渲染专项，不是端到端UI手势自动化，也不宣称用户真机观感已确认。四份本轮源码覆盖索引更新，未使用子代理、未提交/推送；F001–F182仍174/182、8项延期视觉，不改变历史分母。


2026-10-17 U004再次用户复测失败：用户确认外框内内容回弹分层与展开结束跳高/闪边同时存在，提供安卓1.97-debug截图，追加“顶部标题栏更白，安卓一体，希望和安卓看起来一样”。本次局部视觉对齐已明确获授权，不扩大全应用视觉范围。上一轮6项布局检查不代表实际变形画面交接正确，撤回整体问题已解决的含义。新生产宿主测试 /tmp/ztransfer-settings-render-before.log 为1项2断言失败、TEST FAILED：视口/contentSize均369×682.333但bounces/alwaysBounceVertical均true；实际CALayer网格画面与实时视图平均每通道差14.0569（之前测试只重拼源截图，未绘制变形三角形）。xcresult两张截图已导出并查看，标题/底边在源截图留白被压缩后变形。真机截图 /tmp/ztransfer-settings-still-broken.png 确认设置打开且背景未压暗；devicectl录屏明确返回此设备不支持，未伪称已录到动画。
依据：Android AnchorPopup Surface圆角20、唯一glassPanelBorder边框和整层glassSheen；SettingsOverlay整列16dp内边距、标题后14dp、目录后16dp、其余8dp、页脚前14dp，SettingsCard仅onBackground 4%内嵌底。Color.kt浅色scrim .32/深色 .40。iOS本次移除额外叠加描边/按钮材质卡片，整层背景与标题共用；恢复按实际进度绘制的遮罩，只让遮罩订阅帧；当前设置列关闭独立橡皮筋回弹及iOS26自动滚动边缘材质（Apple https://developer.apple.com/documentation/swiftui/view/scrolledgeeffecthidden(_:for:)）。网格按实际裁片像素边界构造，并保留上下12pt越界纹理空间，正文几何曲线/时长不变。正在运行 /tmp/ztransfer-settings-render-fixed.log，未通过前不记完成；未提交/推送。

U004实际画面验证补充（仍在收敛）：settings-render-fixed为7项中6通过，实际画面比较1项失败，连续同步截图在主线程占用时间造成最后采样仍停在展开途中；导出图显示宽度尚未到终点，不把此误差全部归于生产缺陷。将绘制与显示时钟拆开，测试调用同一个生产renderFrame(at:1)而非推算最后一帧。settings-render-endpoint仍1项失败（平均差4.3254），端点截图已显示上下位置一致，细看分片边界有采样/透明度误差。发现纹理为屏幕scale而CAShapeLayer遮罩仍默认scale1，已统一遮罩scale；测试截图也从scale1改为屏幕原生scale，阈值保持3不放宽。settings-render-retina验证中，尚未安装中间构建。

U004最终专项结果：/tmp/ztransfer-settings-render-retina.log 1/1 TEST SUCCEEDED，精确p=1的原生像素网格→实时视图平均差0.30265/255；导出两张1107×2107图片检查，标题/页脚位置一致，独立图像统计标题区域平均差1.268、页脚0.210。最终集中回归 /tmp/ztransfer-settings-render-final.log 为7/7、0失败、TEST SUCCEEDED、exit0（4宿主开合/反转/描边，3完整设置布局/小屏/重开/实际渲染）；当轮终点全图差0.24969/255，bounces=false且alwaysBounceVertical=false，视口/内容均369×702.333。保留3次失败：before复现、fixed连续截帧漏终点、endpoint低分辨率遮罩/采样；不改写为首次全绿，也不放宽像素门限。最终真机构建 /tmp/ztransfer-settings-render-final-device-build.log BUILD SUCCEEDED、exit0，安装前真机截图仍在旧设置窗、队列闲置。正在安装最终版，用户实际动画观感仍待确认；没有录屏成功、没有全应用视觉验收或UI手势自动化。

U004本轮交付：最终版已安装到同一iPhone 15，应用目录1B7FB203-1716-488D-8AEF-6975CD473D86，devicectl无参数启动成功。保留模拟永久会员与原有设置，没有再模拟购买、清次数或自动下载。7/7专项通过和git diff --check通过；四份源码索引哈希已同步。已请求用户打开/拖动/关开设置窗确认实际观感，尚未收到确认，不标真机视觉验收完成。未提交/推送、无子代理；174/182功能台账与8项延期视觉分母保持。

U004交付后截图限制：/tmp/ztransfer-settings-render-device-after.png 与 /tmp/ztransfer-settings-render-device-review.png 均为新版本正常照片列表，尚未采到用户打开后的新设置窗；它们仅证明普通启动/相机列表正常，不能用作新设置窗真机外观验收。当前无运行中构建或诊断会话，等待用户实际反馈。

2026-10-17 U004用户真机验收：在安装目录1B7FB203-1716-488D-8AEF-6975CD473D86的最终版上，用户回复打开一次设置窗、拖动空白处、关开后是否仍有标题独立白块/跳高/闪边的询问：“这次正常了”。据此本轮设置窗问题收尾，证据为用户明确真机反馈与此前7/7专项，非新截图或录屏；不扩展为其他页面、全部样式/动画均验收。本次仅更新记录，未新增构建、测试、安装、提交或推送，既有未提交修改保留。
