# iOS 实现任务清单

> 2026-09-08：检查点8503823已提交，50子项源码审计及串行Windows检查已完成；1026项Kotlin/Android、314项Python、结构/原UI守卫通过。393项XCTest未运行，iOS完整1:1仍有明确缺口。后续修复待提交，详见[审计记录](./iOS并行50项审计记录.md)；历史PASS仍只适用于原检查点。

> **当前执行/进度唯一入口：** [iOS剩余任务进度表](./iOS剩余任务进度表.md)。第59批后剩余50项固定计分，每完成1项总计划增加0.4个百分点；实时完成数和百分比只维护在该表。旧百分比仅保留为历史估计，不再继续粗估。Mac/真机另计12项，暂缓功能另表。

> 执行账本；关联 [总迁移清单](./iOS迁移任务清单.md) 和 [方案](./iOS版本1比1复刻方案.md)。Android 共享化已结束，本表跟踪 iOS 成品实现，不重置已完成工作。

## 当前范围调整（2026-09-06）

- 用户当前优先目标：先把iOS传图的流程和体验完整复刻。阶段进度仅衡量本轮传图版在Windows能完成的实现/检查，不代表Apple编译或真机通过；此前80%/91%/70%均为历史估计；今后按上方剩余任务表固定计分。
- 照片效果两处暂缓：传输时应用滤镜/相框/水印，以及本地效果编辑/成片导出。IOS-U08、IOS-E02/E03/E04、IOS-T01效果子项及IOS-E01的效果导出/相框部分留以后；不删代码、不标DONE、不影响Android。
- iOS会员/限额权益接入、购买/支付、验证/恢复暂缓（IOS-U09、IOS-L01/L02/L03及其它会员子项）。苹果端后续单独重设计，本轮不移植Android微信支付入口；保留Android/shared既有规则，不擅自解锁、删除或决定最终收费策略。
- 用户本次明确再暂缓遥控/实时监看及相关录像功能（IOS-U07、IOS-R01至R07），留以后，不删除共享或Android实现。已有相机照片/视频的浏览与传输、原片/RAW预览、EXIF、缩放/直方图、保存/分享仍属传图范围，不随遥控录像或照片效果一起删减。
- 用户已明确GPS也暂缓：IOS-G01至G04的定位/GATT认证/坐标发送/状态页面/恢复及其它GPS入口子项留以后，不计本轮传图完成门槛，不标DONE、不删除既有代码。照片原有EXIF（含已有GPS元数据）读取不受影响。
- 本轮剩余重点：完整连接/历史相机/正式共享工作区与设置；多选/全选及浏览预览交互；新增/删除事件与自动入队；STA-direct及媒体/EXIF兼容边界；取消/断线/切网/后台安全停止和恢复；原片保存/分享/目录错误的完整体验及针对性回归。非会员的隐私/权限/工程打包事项继续，Mac实际验收仍单列。
- 本轮100%门槛按上述传图范围执行。暂缓任务不算DONE；历史批次中继续效果/会员/遥控监看/GPS的NEXT不再执行。保留原任务和源码以便后续恢复，不按文件数/测试数量换算进度。

## 当前检查点

- 最新第63批：W03-A完成Windows门槛，真实扫描/新增快照保留隐藏备份别名与稳定索引顺序，Native核对接口复用原删除重建及idle基线规则；987项Kotlin/Android（670+317）、298项Python及结构/原UI守卫PASS。本批Android app源码未改，299项XCTest/17项Native预览位图待Mac；得分2.5/50、总计划81.0%，完整主项仍2/50。W03-B删除/属性/卡变化实际调度未接，下一项W03-B；W04/W05仍开放。Mac首次操作指南及索引链接一并提交，不计实现分。

- 最新第62批：W02-B新增事件真实读取/有界重试/共享发布接线完成Windows门槛，现有连接观察者转发、同一文件页/预览缓存接收；977项Kotlin/Android（660+317）、290项Python与结构/原UI守卫PASS。本批Android app源码未改；W01/W02共2/50分、总计划80.8%，下一项W03。296项XCTest与17项Native预览/位图仍Mac待验；删除/属性/存储变化与事件缺口追赶W03/W04、自动开关W05、正式入口W07仍待完成。以下第60/61批为历史检查点，不再表示当前缺口。

- 最新第61批：W02-A共享规则提取完成，Android实际委托NewCameraObjectPolicy，原新增准入/双卡发布/重试值保持；973项Kotlin/Android（656+317）、283项Python与结构/原UI守卫PASS。W02拆成两个半分子项，当前1.5/50分、总计划80.6%；Apple新增事件调度W02-B未接，284项XCTest与17项Native预览/位图仍Mac待验。

- 最新第60批：W01完成Windows门槛；真实目录扫描接shared首次基线/后续差量，成功枚举先于元数据提交，首次旧照片不报告新增。966项Kotlin/Android（649+317）、279项Python、结构/原UI守卫PASS；284项XCTest与17项Native预览/位图仍Mac待验。新增/删除事件消费与自动开关继续W02—W06，进度只更新剩余任务表。

- 第59批已把有界事件记录接到真实AP/STA事件接收入口：同代游标、顺序记录、256条上限、缺口要求重扫；不增加通知流消费者，不改变网络命令。275项Python与结构/原UI守卫通过，新增4项XCTest，累计280项待Mac。真实新增/删除消费、首次扫描基线和自动开关仍未接；960项Kotlin/Android证据为上一批，本批未改Android/shared，不重复Gradle。

- Android 功能基线：`55876fa`，1.81 / 54；用户已验证此前包的 USB、STA。
- 已有：共享协议/模型/规则、Xcode薄壳及Apple侧标准连接→目录→原片下载→沙盒保存/系统分享/图库导入的源码链路；不是已运行的成品。
- 已有网络/传输/保存/GPS/照片适配源码；CMP原组件/完整队列正文/完整缩略图网格已共享，Android真实接入；iOS真实原片队列已接同一正文，完整标准目录/缩略图/入队已接同一网格，可从Debug连接页打开验收；沙盒真实原片索引/已保存徽标已接，原筛选结果/日期/存储卡及未传输退场已接；列数/连拍合并和持久筛选已接；完整共享预览已接真实目录入口，Apple待验；Files provider索引/已保存与本地预览已按固定页面来源接线；原片队列可显式选择provider并在发布后完成；目标已有原片复用/跳过显示/按需安全分享已接（Mac待验），正式设置仍待接。真实机身隔离的缩略图磁盘缓存/完整目录清理和连接级后台填充/日期优先/传输让路已接。原单图预览/缩放手势/旋转按钮已共享且Android实际调用，iOS真实图片探针已接；分页/连拍/来源快照和上滑意图纯规则已共享；原单页/FHD渐显/连拍堆叠/EXIF信息条和操作按钮已共享；原预览/遥控共用直方图统计、绘制、图标及预览开关已共享；完整分页/FHD/EXIF/邻页预取与取消/连拍切换/入队飞行协调器已迁SharedPhotoPreviewOverlay并由Android调用；Native真实FHD独立读取/取消/整页占用及保留原方向的1920解码已写；原协调器已提供可选异步真实入队确认（Android同步默认不变）；本地普通图片原尺寸读取/来源冻结/离线及统一取消已写；Native实际位图解码/网格预览共用缓存及只读磁盘缩略图适配已写；RAW索引纯解析已提为两端单实现且Android委托；Native本地RAW安全分段读取/按原像素规则选图及独立取消已写；原预览EXIF纯解析/格式化已共享并由Android调用，Native值载体与数字适配已写；Native本地EXIF随机读取/真实ImageIO属性及取消已写；原始RATIONAL数值源已接并通过真实AndroidX字节样本对照；多段EXIF/跨段字节序与SubIFD/GPS/互操作指针已补；其余目录边界及Apple运行仍待补验；相机EXIF读头命令与部分头解析已写；跨重连正负缓存及Native EXIF读取会话已接；当前页FHD+EXIF优先窗口/传输分块让路及取消释放已写；完整NativePreviewSessionSource及三语原文适配已写，本地路由已两端共用；旋转/直方图已接现有浏览偏好和模型、旧v1数据可兼容恢复；视频日期格式、原目录快照/返回定位/偏好控件和真实预览源已接同一共享overlay，正式工作区导航仍待接。原目录/照片列表/外观设置卡片及四个基础控件已共享；Native照片列表设置已用原拨轮接线、点击/长按行为可保存恢复，Native外观五项已接独立应用偏好、统一主题/纹理/语言和前台常亮生命周期，完整设置外壳/其余绑定仍待接。Files provider协调发布、绑定授权快照、根/日期桶索引及增量更新已写并接手动验收；provider普通原片/RAW/EXIF读取已复用从沙盒提取的唯一IndexedOriginalReader，索引与三种读取已按固定来源接同一共享文件页；原片队列的显式provider目标/完整下载后发布与保留原片重试已接；已有目标复用与按需安全分享已接，按天保存/选完再传偏好及其真实入队参数已接；正式目录提交/恢复和系统选择已接；自动入队接收边界及标准新增事件解析/发布已接；自动开关/删除与缺口编排仍待接。共38个App Swift文件、299个XCTest场景，全部Apple源码仍待首次Mac编译。
- 第58批历史实跑：643项shared +317项Android =960项测试，0失败/错误/跳过；common metadata/Android Debug编译，BUILD SUCCESSFUL in 12s（49 tasks：3 executed/46 up-to-date；首次55s编译通过但新增测试前提错误，修正后重跑）。271项脚本、原UI整文件守卫及结构检查通过。Release/Lint/Manifest全套仍是第46批，app Lint 0 errors/179 warnings/11 hints、shared无issue；本批未重跑Release/Lint。
- 第54批接通按天保存/选完再传的原共享控件、独立偏好保存恢复、入队前参数快照与文件页同源日期桶识别。新增4项commonTest实际通过、3项XCTest待Mac。38个App Swift、280项XCTest和17项Native预览/位图用例仍Mac待验；第55批目录提交边界已接Debug改选；第56批显式目标保存/重连恢复和不可用目标错误已接，新增6项XCTest待验；第57批原目录标题/真实选择按钮已接共享设置，自动入队及完整目录卡片仍未完成，不显示无效自动开关；无APK/无推送。
- 用户进度口径：100%仅表示本轮传图范围内Windows可做工作完成；2026-09-06暂缓效果、会员、遥控监看及GPS后，当前完成数与总计划刻度见剩余任务表，不另行粗估。GPS不计该比例；Apple编译/真机验收独立记录，此前91%不再沿用。
- Mac验收入口仍是 `python3 iosApp/scripts/verify_on_mac.py`，但按用户要求不再作为继续写Windows源码的停止条件。本轮共享产品UI、STA-direct/MPF与RAW预览、自动事件/恢复等仍未完成；遥控/GPS/效果/权益按顶部范围暂缓，不能将本批写完当作Windows工作全部完成。
- Windows 可以编写/静态检查 iOS 文件、运行 common/Android 回归；不能将这些结果记作 Swift 编译、模拟器、真机通过。
- 本表不计算代码行数进度。仅“实现完成 + 所需验收通过”计完成；能握手不等于能浏览/传输，首个传输闭环不等于全功能完成。
- 2026-09-05用户已明确允许受控共享UI迁移：可以调整Android页面/引用及构建依赖，以保持Android功能、逐批回归为前提。不再以“Android文件零改动”为本阶段门槛；相机协议、服务、打包和版本仍不顺带修改，不复制第二套SwiftUI产品页面。
- U01/U02已接共享主题/图标/进度/材质纹理/GlassButton/连接卡片/拨轮/帮助/烟花/水印位置约束与触感接口。Android直接引用共享组件，位图/锁/触感平台实现保留原行为，系统栏仍在app；正式首页/列表/设置尚未迁完。

## 约束

1. 单仓库、`app + shared + iosApp`；不新增大型架构层，不复制整份 NikonCamera/Android ViewModel 到 Swift。
2. 协议、排序、重试、限额、滤镜等只调用 shared。确有缺失的跨端编排，按真实调用点提取、先由 Android 接入并回归，禁止另写第二套算法。
3. 产品页面沿用既定 Compose Multiplatform 路线：从 Android 原页面逐步迁入 shared，让两端使用同一组件。SwiftUI 仅作入口、系统界面及临时 Debug 探针。
4. 现有 shared 主要提供纯规则，尚不等于完整的可直接运行的跨平台相机服务；网络/会话所有权、生命周期、I/O 锁及任务取消必须逐项接入。
5. 启用共享 UI 会改变 Compose 依赖，需要单独比较 Android 解析依赖、编译、截图、交互和三连接回归；不得默认为“与 Android 无关”。
6. 新增 Apple 独占文件无需重复打 Android 包；更改 shared、Android 或 Gradle 后按实际风险执行项目约定检查。
7. Native 源码未编译前只标“已写/待验”。账户、证书、商品 ID、服务端校验密钥和审核资格不得编造，不提交凭据。
8. 协议操作顺序、TID、AP/STA 不同初始化、错误分支和取消排空必须有基线证据；UI 功能不足时不得用模拟数据伪装完成。

## 平台差异（沿用已确认方案）

| Android 能力 | iOS 目标 | 验收方式 |
|---|---|---|
| USB Host PTP | 首版不提供入口；不声称与 Wi-Fi 等价 | 能力控制 + 文案检查 |
| AP/STA | Wi-Fi PTP/IP；网络授权、热点引导、发现与重连按 Apple API 适配 | iPhone + 相机，两种模式分别验收 |
| 长期前台服务/锁屏传输 | 前台稳定传输、有限后台宽限、安全保存检查点、前台恢复 | 真机挂起/锁屏/杀进程矩阵；明确哪些恢复能力已实现 |
| SAF/MediaStore | PhotoKit / Files；RAW/视频不可入图库时可导出原文件 | 仅添加/受限/完整授权、拒绝、目录撤权 |
| 外部付费/激活、APK 更新 | StoreKit + 已确认的服务器权益对接；App Store/TestFlight | 沙盒购买恢复、服务器配置、发布验收 |

除这些明确差异外，以 Android 基线的可见功能、交互、数据结果为对照目标。任何新发现的不等价点先登记，不静默删减功能。

## 状态与执行顺序

- 实现：`TODO` / `NEXT` / `WRITTEN` / `DONE`。`WRITTEN` 只表示已有源码，不等于任务完成。
- 验收：`待验` / `Mac待验` / `真机待验` / `外部配置待验` / `PASS`。多项门槛必须全部通过。
- 顺序：B/N 网络基础 → AP/STA 会话 → D/T/S 浏览传输保存 → U 共享界面 → R/G/E 遥控与效果 → L 购买与发布 → Q 全功能验收。
- 每批记录代码入口、复用入口、测试命令/结果和未解决问题。用户2026-09-05明确要求继续Windows可写部分，首次Mac编译不再作为源码实现的停止条件；所有未编译Apple源码持续标记待验，不能视为可靠运行结果或进度100%。

### B：工程、接口与诊断（关联 F03/M01/M02）

| ID | 实现 | 验收 | 范围 / 完成点 |
|---|---|---|---|
| IOS-B01 | NEXT | Mac待验 | 已写 Apple Silicon 一键验收脚本及环境/模拟器选择；framework 真机/模拟器导出、Swift 类型/集合/异常桥接、取消与持有关系仍须实际编译检查 |
| IOS-B02 | WRITTEN | Mac待验 | XCTest target/Scheme已有254个网络/会话/流式传输/目录/队列/保存/预览/Files/定位/蓝牙/元数据/滤镜/Compose控制器场景待执行；Mac脚本串行执行Native commonTest/XCTest/Release编译并保留日志与xcresult |
| IOS-B03 | TODO | 真机待验 | Info.plist/entitlement 按真实使用声明；本地网络、照片、蓝牙、定位、麦克风允许/拒绝/撤销、设置恢复 |
| IOS-B04 | TODO | 待验 | 诊断日志/导出/隐私脱敏；记录阶段/错误/机型；不得把超时直接等同于拒绝授权 |

### N：相机会话（关联 I01）

| ID | 实现 | 验收 | 范围 / 完成点 |
|---|---|---|---|
| IOS-N01 | WRITTEN | Mac待验/真机待验 | CameraTCPStream：Wi-Fi 路由、TCP_NODELAY、短读、EOF、写完成、单读单写、超时/取消/关闭、迟到回调隔离 |
| IOS-N02 | WRITTEN | Mac待验/真机待验 | PtpIPChannel：复用 shared 包头/长度校验/legacy与standard Init/Event codec、整包期限、64KiB 流式载荷；已增加普通命令/PONG/响应字段及机型桥接 |
| IOS-N03 | NEXT | Mac待验/真机待验 | CameraWiFiConnection单代持有、AP ACK会话号/首TID1/AlreadyOpen/DeviceInfo容错、事件/CloseSession/取消释放已接Debug；待热点授权引导、正式共享UI及真机验收 |
| IOS-N04 | NEXT | Mac待验/真机待验 | 已写稳定identity、预期responder、TID0/OpenSession(1)/0x941C/Storage成功直达、显式配对及权威ACK落盘；待完整历史档案/删除、多身份与STA-direct兼容 |
| IOS-N05 | NEXT | Mac待验/真机待验 | 已写两类Bonjour服务候选、8秒有界扫描/停止/迟到回调隔离、选中服务接现有STA连接；待历史IP、真实接口路由/受控子网回退、跨服务物理机身去重；未执行任何Windows网络扫描 |
| IOS-N06 | NEXT | Mac待验/真机待验 | 已写串行控制/data-out/原片流式事务、限额/TID匹配、双通道PING、下载全程抑制保活、单代事件revision；新增预览优先窗口只暂停下一传输事务，不打断在途数据。取消采用关闭流而非可恢复排空；完整事件消费/重连/切网尚未实现 |

### D：浏览与预览（关联 V01/U04）

| ID | 实现 | 验收 | 范围 / 完成点 |
|---|---|---|---|
| IOS-D01 | NEXT | Mac待验/真机待验 | 已接完整标准目录：shared存储筛选/逐卡倒序/逐头时间归并/备份去重合并归属；事件期间标失效，失败保留旧快照。已接共享原片网格，完整/无事件竞争结果原子发布，失败/部分读取保留原列表；待增量调度、STA-direct及完整工作区；非拉丁locale回退名差异见第三批 |
| IOS-D02 | NEXT | Mac待验/真机待验 | 原网格/连拍稳定键已共享并接iOS真实目录。原筛选弹层/日期编辑/多条件控件已共享且Android调用，Native日历与三语言适配已写；沙盒真实原片索引/原网格已保存徽标已接；真实类型/保护/连拍/存储卡/日期/未传输筛选及原退场已接；列数/连拍及筛选持久偏好已接；待选择/全选/跨卡选择；首次索引未就绪禁用未传输选项 |
| IOS-D03 | NEXT | Mac待验/真机待验 | 已写标准GetThumb/AP FHD共享能力/Busy策略、同键合并、32MiB/256项会话缓存、内存释放、方向/尺寸有界解码；已接共享网格可见项读取/有界重试和32MiB解码缓存；已接真实机身隔离磁盘缓存/90天过期与完整目录清理，系统清缓存可重建；完整扫描后已接共享ThumbnailFillQueue后台补图/日期优先/执行态让路/失败事件唤醒；待扫描批次交错填充、完整预览/遥控页生命周期门控、裁黑边、STA MPF/RAW/视频嵌入预览 |
| IOS-D04 | NEXT | Mac待验/真机待验 | 第58批已接原shared媒体过滤/历史去重的自动入队边界；第59批真实AP/STA接收已保留有界有序事件及单代游标，溢出明确要求重扫。第60批首次扫描基线/枚举差量已接；新增/删除/属性事件消费、列表发布和自动开关仍待接；继续复用 FileScanHandle/CameraFilePublication/CameraCatalogPolicy，不算自动传输闭环完成 |
| IOS-D05 | NEXT | Mac待验/真机待验 | 原单图/缩放/旋转和单页/连拍/EXIF信息条已共享，Native真实单图探针已接；直方图统计/绘制/图标/预览开关已共享，Native位图读取待验。完整分页/FHD/EXIF/邻页预取取消/连拍返回/入队飞行协调器已共享且Android接入；Native FHD独立读取/取消与前台令牌已写，借用原相机所有者；异步接受确认/取消/部分接受接点已写并通过真实模型测试；普通本地原片原尺寸/离线读取与真实索引归属已写；Native真实位图与同一网格缓存适配已写；RAW索引及原候选/选图规则已共享并由Android调用，Native本地RAW安全分段读取/真实选图/取消适配已写；原预览EXIF Float/GPS/字段回退与格式化已共享，Native值载体/数字适配已写；Native本地EXIF已接安全随机读取/实际属性/取消；原始RATIONAL覆盖已写，单EXIF目录金样与真实AndroidX对照通过；多段EXIF/跨段字节序与目录别名已通过实际库对照；相机读头命令/截断头部分数值已写；跨重连正负缓存/本地共用/远程会话已接；整段FHD+EXIF交互优先窗口、分块让路和页面取消释放已写；完整NativePreviewSessionSource/三语原文及两端同源本地路由已写；旋转/直方图偏好存储与模型已写；视频日期文本已两端共用；真实目录入口/冻结快照/偏好控件/返回定位已接同一overlay。NEXT正式工作区导航/队列胶囊、RAW降级、横屏和已有选择/分享/删除能力；EXIF目录占用/RAW嵌入元数据/其它ImageIO字段继续对照；不将探针算成完整产品预览 |

### T/S：传输、持久化与后台（关联 I02/I03/V02）

| ID | 实现 | 验收 | 范围 / 完成点 |
|---|---|---|---|
| IOS-T01 | NEXT | Mac待验/真机待验 | 原片手动入队/FIFO/待传/暂停继续/单个及全部撤回/终态安全移除/清理/带排除集的批量新ID重试已接shared队列与reducer；已写自动入队接收边界，待真实事件消费、正式UI及检查点；效果/权益按顶部范围暂缓，不把原片诊断队列当完整产品队列 |
| IOS-T02 | NEXT | Mac待验/真机待验 | 原字节流式传输、未知大小查询、64位偏移、PartialObject/全量回退、短读/长度校验已接共享策略；取消现在关闭连接，不等价Android可恢复Cancel/排空，仍待恢复路径 |
| IOS-T03 | NEXT | Mac待验/真机待验 | 沙盒唯一临时文件、共享同名候选/日期目录、fsync/关闭后move不覆盖、SHA256、失败只清理本次临时文件已写；已有沙盒原片索引按共享文件名/大小/根与日期桶识别，完成后增量记录；Files provider已写完整原片的独占临时副本/逐块复制/源与回读SHA256/不覆盖命名发布（手动Debug入口），provider已复用原扫描/增量索引并绑定授权快照；provider已有原片/RAW/EXIF读取已复用唯一Apple读取器；索引与普通/RAW/EXIF读取已接单页固定来源；原片队列可配置provider、按任务原名/日期桶发布、失败保留完整沙盒原片并在新taskId重试复用；目标已有原片已接同一shared命中/跳过状态及原页面skipped字段；provider/沙盒均按需经唯一安全读取器分块生成app-owned分享副本（Mac待验）；日期/延后开始偏好已接且入队后不重写任务；目录原子切换及持久断点仍待接 |
| IOS-T04 | NEXT | Mac待验 | 已接真实已写字节/总长/共享进度与速度、200ms节流及完成/失败后迟到隔离；补完整原片元数据/耗时/完成速度、低频history与独立activeProgress读取和Swift historyRevision；MainActor真实共享页面已接，待剩余时间/后台/错误分类 |
| IOS-T05 | TODO | 真机待验 | 断点身份/机身/存储卡变化校验、失败保留/丢弃、恢复流程；区分 Android 现有进程内重试与新增 iOS 挂起/进程恢复，不虚报已有持久化能力 |
| IOS-S01 | NEXT | Mac待验/真机待验 | 沙盒及Files目录选择/最小书签/过期刷新/作用域平衡/撤权保留已写；ProviderOriginalStore已接授权内NSFileCoordinator双URL协调、64KiB复制与回读、取消/同名/校验/链接边界及按shared日期命名手动验收；已写同一授权绑定的provider元数据扫描/增量索引、改授权拒绝旧对象、缓存核对实际根路径与重定位重扫；provider内容读取已在授权与单文件协调内复用原安全描述符、RAW分段与EXIF读取，旧locator不重定向；索引/三种读取已按单页固定来源接真实共享页，换目录关闭旧页并由新页重扫；原片队列可显式启用同一provider，先下载沙盒再校验发布到目标，worker活跃时拒绝更改目标；正式目录设置、跨连接偏好恢复及目标已有原片复用仍须接入 |
| IOS-S02 | NEXT | Mac待验/真机待验 | PhotoKit addOnly照片/视频导入已接；拒绝/不支持/失败均保留沙盒原片，提交后等真实结果不误报取消；不声明已管理Z传相册，不自动请求读图库 |
| IOS-S03 | NEXT | Mac待验/真机待验 | Debug ShareLink及系统asCopy文件导出已接，保留沙盒源文件、只报告picker实际结果；相框水印资源导入/正式共享入口仍待实现 |
| IOS-S04 | TODO | 真机待验 | scene 生命周期、后台宽限/expiration、网络安全停机、断点落盘、返回恢复、常亮策略；不假设后台任务能无限执行 |
| IOS-S05 | NEXT | Mac待验 | 已接UserDefaults应用私有版本化浏览偏好（列数/连拍/类型/保护/连拍/未传输/日期），复用shared校验，未知版本/损坏数据保留；卡槽不落盘。预览旋转/直方图及点击预览偏好已用可选字段兼容旧v1数据并接入当前文件模型；旧八/十参数构造器保留。待其余设置、进程内跨页卡槽、相机档案/检查点/授权身份与Keychain职责及升级迁移；不拷贝Android私有存储格式 |

### U：共享产品 UI（关联 U01–U05）

| ID | 实现 | 验收 | 范围 / 完成点 |
|---|---|---|---|
| IOS-U01 | NEXT | Mac待验/Android真机待验 | 已启用CMP 1.8.2/资源插件与ComposeUIViewController组件入口、iOS帧时长声明；实际依赖前后快照/差异工具/两模块回归已跑。待Apple编译/资源打包/实际渲染及完整产品页面接线 |
| IOS-U02 | NEXT | 双端真机待验 | 已迁颜色/字体/动画/图标/进度/纹理/按钮/卡片/拨轮/帮助/烟花/水印位置规则；Android触感原实现移androidMain，iOS UIKit语义反馈已写。17组件源码/波形对照及80纹理摘要PASS；待语言资源/剩余控件与平台截图交互对照 |
| IOS-U03 | TODO | 双端待验 | 首页/连接工作区、AP/STA 模式、历史相机/扫描/配对/连接成功动画、GPS 入口与错误状态；平台能力控制 USB 入口 |
| IOS-U04 | NEXT | 双端待验 | SharedThumbnailGrid完整原网格已由Android使用：列数/日期收合/连拍重排/角标/进度/手势/坐标/退场。iOS标准AP/STA真实目录/缩略图/单张及整组入队已接同一网格（Debug入口）；原筛选/日期编辑/弹层组件已共享且Android调用，Native日历/三语言已备；真实沙盒原片索引与已保存徽标已接；真实筛选结果/原退场已接；浏览偏好已接；原单图预览/缩放手势/旋转按钮已共享，Native真实图片探针已接；分页模型/连拍展开返回/来源冻结/上滑意图规则已共享；原预览单页/FHD渐显/连拍堆叠/EXIF信息条/导航及入队按钮已共享并由Android实际调用；原直方图分析/绘制/图标及预览开关已共享；完整分页/FHD/EXIF/预取取消/连拍返回/入队飞行已共享并由Android调用，Native已接真实预览源/本地EXIF/异步入队确认及返回定位（待Mac），当前飞行落点是临时目录页实际队列按钮。待其余设置/选择/完整工作区、队列空间转场/正式胶囊及接收动画，以及截图和快速新增列表验收 |
| IOS-U05 | NEXT | 双端待验 | SharedTransferScreen正文已由Android和iOS原片队列入口使用；真实快照/进度、异步删除/撤回/重试、缓存缩略图、原文案/格式规则、开始/暂停/返回已接。SignalPill及原版开始/暂停按钮已共享接入；待完整工作区顶栏/触感与暂停提示、全量效果/已有文件索引、自动传输/预览遥控协调、截图与生命周期真机验收 |
| IOS-U06 | NEXT | 双端待验 | 原目录/照片列表/外观三卡及SettingsCard/Divider/SectionLabel/BooleanWheel已共享且Android调用，旧GPS紧凑尺寸引用同一shared值；iOS照片列表设置已接原拨轮/列数/连拍/点击行为并保存恢复，三语原文及两行标签已对照。完整设置外壳/帮助/页脚仍待迁入；主题/语言/材质/触感/常亮已接Native应用级单一owner及独立UserDefaults，文件/队列动态主题与三语、原纹理、文件/预览/筛选触感开关及前后台常亮释放已写，Apple待验。剩余：目录/按日期整理/自动传输/延后开始、完整设置外壳/帮助/反馈/版本/源码入口及平台验收；队列操作触感仍按U05继续 |
| IOS-U07 | TODO | 双端待验 | 【用户暂缓；不计本轮传图版完成门槛】遥控和实时监看全页面/横屏/录制状态/权限提示、曝光拨轮和点按对焦；共享原有布局/交互 |
| IOS-U08 | TODO | 双端待验 | 【用户暂缓；不计入本轮Windows完成门槛】本地照片效果页、滤镜/相框/文字及图片水印编辑、元数据设置、收藏、重置/预览/导出 |
| IOS-U09 | TODO | 双端待验 | 【用户暂缓；苹果端会员/支付后续重设计，不计入本轮】会员状态、限额提示、购买/恢复/错误/待批准状态；商店流程使用原生系统接口 |
| IOS-U10 | TODO | 双端待验 | 安全区/键盘/系统返回手势、旋转、字号/VoiceOver、无相机/空列表/拒绝权限、屏幕常亮恢复、长列表性能；截图和操作录像对照 |

### R：遥控与录像（关联 P07/R01/R02/I04）

| ID | 实现 | 验收 | 范围 / 完成点 |
|---|---|---|---|
| IOS-R01 | TODO | 真机待验 | 【用户暂缓；不计本轮传图版完成门槛】相机能力/属性描述/当前值、曝光/ISO/快门/光圈/补偿、Auto ISO、拨轮与兼容回退；复用 RemoteExposurePolicy/属性解析 |
| IOS-R02 | TODO | 真机待验 | 【用户暂缓；不计本轮传图版完成门槛】对焦模式/点按对焦/主体追踪/AF轮询、拍摄/连拍/确认、Busy重试；复用 RemoteFocus/共享顺序规则 |
| IOS-R03 | TODO | 真机待验 | 【用户暂缓；不计本轮传图版完成门槛】Live View 启停/预热/取帧/恢复、元数据/对焦框/水平仪/声音、图像解码与横屏；复用 LiveViewMetadata/RemoteLiveViewPolicy |
| IOS-R04 | TODO | 真机待验 | 【用户暂缓；不计本轮传图版完成门槛】相机录像开始/停止、应用模式、禁止原因、迟到事件、录制期间浏览/下载互斥；复用 RemoteMoviePolicy |
| IOS-R05 | TODO | 真机待验 | 【用户暂缓；不计本轮传图版完成门槛】手机端监看录像：AVFoundation/编码/帧时间戳/音频、暂停继续/计时/收尾反馈、麦克风拒绝、来电/中断、文件收尾/保存失败；复用许可和调度规则 |
| IOS-R06 | TODO | 真机待验 | 【用户暂缓；不计本轮传图版完成门槛】免费监看限额、计时/会话切换、长时帧率/温度/内存、电量/断线、切后台安全停止 |
| IOS-R07 | TODO | 双端待验 | 【用户暂缓；不计本轮传图版完成门槛】监看辅助：FPS显隐、高清XGA、直方图、三分/四分网格、过曝斑马线、水平仪、音量电平/偏好、沉浸全屏、诊断入口；`RemoteViewfinderFeatures.kt` 的像素统计/坐标规则目前仍与 Android Bitmap/Compose 耦合，在 U07 中按金样本拆出共用，禁止 Swift 重抄算法 |

### G：BLE GPS（关联 I03/G01–G05）

| ID | 实现 | 验收 | 范围 / 完成点 |
|---|---|---|---|
| IOS-G01 | NEXT | Mac待验/真机待验 | 【用户暂缓；不计本轮传图版完成门槛】已写显式扫描/选择、单代连接、四特征发现、PAIR→NOT1顺序订阅、withResponse串行写入/限额、超时取消/断线/迟到隔离；Debug只验证GATT、不发送身份或坐标，完整GPS流程待接 |
| IOS-G02 | NEXT | Mac待验/真机待验 | 【用户暂缓；不计本轮传图版完成门槛】已写共享17B codec/熵映射/四阶段的Swift actor、SecRandom及CommonCrypto Blowfish固定向量测试；认证调度/身份保存/OS配对/重试恢复未接，不假设Android Classic bond API存在 |
| IOS-G03 | NEXT | Mac待验/真机待验 | 【用户暂缓；不计本轮传图版完成门槛】已写前台CoreLocation/精度提示/共享采样频率、新鲜度及41B GEO编码、当前UTC/有效海拔/后台停止；没有向相机写坐标，地名/强制新海拔/完整恢复仍待实现 |
| IOS-G04 | TODO | 真机待验 | 【用户暂缓；不计本轮传图版完成门槛】GPS 状态 UI/日志、与 Wi-Fi 会话互斥协调、蓝牙断线重连、后台可用性；仅声明实际支持的后台模式 |

### E：相框、滤镜与水印（关联 E01/E02/I02）

| ID | 实现 | 验收 | 范围 / 完成点 |
|---|---|---|---|
| IOS-E01 | NEXT | Mac待验/真机待验 | 已写ImageIO无全图解码的元数据读取，复用EXIF/APEX/ISO/GPS/日期和显示规则，诊断不回显GPS；方向预览已有。待导出EXIF/完整色彩与RAW降级/相框流程 |
| IOS-E02 | NEXT | Mac待验/双端待验 | 【用户暂缓；不计入本轮Windows完成门槛】已写4MP sRGB预览→ARGB/alpha系统转换→4096像素块调用原共享内核→CGImage，诊断首个真实预设80%；全部预设内核桥接有Windows回归。待正式选择/组合、原尺寸导出/性能缓存及跨端色彩透明边缘对照 |
| IOS-E03 | TODO | 双端待验 | 【用户暂缓；不计入本轮Windows完成门槛】全部13类相框布局、品牌/元数据文本/字体/尺寸、文字与图片水印/免费水印、Logo资产；共享布局/水印规则，端侧绘制以固定图验收 |
| IOS-E04 | TODO | 双端待验 | 【用户暂缓；不计入本轮Windows完成门槛】效果配置/收藏/图片水印持久化、成片身份/SHA256、原片副本/效果目录、预览与成片一致、导出到图库/Files |

### L：权益、更新与发布（关联 L01/I04）

| ID | 实现 | 验收 | 范围 / 完成点 |
|---|---|---|---|
| IOS-L01 | TODO | 待验 | 【用户暂缓；苹果端会员/支付后续重设计，不计入本轮】复用每日25个/400MiB/监看3分钟规则；端侧日账/日期适配、跨入口防绕过、会员即时更新/离线状态 |
| IOS-L02 | TODO | 外部配置待验 | 【用户暂缓；苹果端会员/支付后续重设计，不计入本轮】StoreKit 商品展示/购买/取消/pending/验证/事务监听/恢复/撤销；确切商品ID、类型与已有会员权益对应后实现 |
| IOS-L03 | TODO | 外部配置待验 | 【用户暂缓；苹果端会员/支付后续重设计，不计入本轮】现有服务器账户/设备身份与 Apple 交易校验/幂等绑定/跨端权益恢复；以真实服务端契约为准，服务端修改单独验收，不自动部署 |
| IOS-L04 | TODO | 外部配置待验 | App Store/TestFlight 更新入口、公告/反馈/隐私说明；无自行安装 IPA 或 Android 外部支付入口 |
| IOS-L05 | TODO | Mac待验/外部配置待验 | AppIcon/启动/版本、Team/签名/entitlement、PrivacyInfo.xcprivacy/使用API声明、归档/dSYM、TestFlight、商店截图/说明/审核账号及提交前验收 |

### Q：整体验收（关联 Q01/Q02/Q03b）

| ID | 实现 | 验收 | 范围 / 完成点 |
|---|---|---|---|
| IOS-Q01 | TODO | Mac待验 | commonTest 在 iOS simulator 执行、Swift/Native 桥接测试、Debug/Release 真机架构编译、Xcode 测试与归档 |
| IOS-Q02 | TODO | 真机待验 | AP/STA 分别覆盖从连接到传输/遥控/GPS/效果全链路，JPG/NEF/MOV、大文件/双卡/空卡/异常响应；机型/固件和实际测试结果逐项记录 |
| IOS-Q03 | TODO | 双端待验 | Android USB/AP/STA 回归；UI截图/设置默认值/协议向量/输出文件哈希与媒体效果对照；性能/内存/线程/异常路径 |
| IOS-Q04 | TODO | 真机待验 | 权限拒绝/撤销、网络切换、来电/后台/锁屏/进程终止、磁盘不足、相机断电/卡更换/文件删除、长时间传输与预览 |
| IOS-Q05 | TODO | 待验 | 无重复业务规则、平台对象不进入 common、无模拟成功/未接线按钮/未说明的删减；每项功能有实现入口和测试证据 |
| IOS-Q06 | TODO | 外部配置待验 | 所有全功能任务验收收口、平台差异确认、安装/升级/购买恢复/正式包签名，用户确认后交付/发布；不得把首个传输版本标成最终1:1版本 |

## Android 对照入口（每批细化到具体函数）

| 功能 | Android 来源 | 已有共享来源 |
|---|---|---|
| 连接/配对/会话/发现 | `protocol/NikonCamera.kt`、`PtpIpDiscovery.kt`、`viewmodel/CameraViewModel.kt` | `protocol/PtpIp*`、`connection/*` |
| 文件/缩略图/预览 | `CameraViewModel.kt`、`FileListScreen.kt`、`PhotoPreview.kt` | `catalog/*`、`CameraFilePublicationPolicy`、对象与元数据解析 |
| 队列/传输/设置 | `TransferViewModel.kt`、`TransferScreen.kt`、`SettingsScreen.kt` | `viewmodel/Transfer*`、`protocol/TransferDownloadPolicy`、`format/*` |
| 遥控/监看/录像 | `RemoteLab.kt`、`RemoteScreen.kt`、`recorder/ViewfinderRecorder.kt` | `Remote*Policy`、`LiveViewMetadata` |
| GPS | `gps/NikonGpsBleClient.kt`、`NikonGpsService.kt`、`GpsViewModel.kt` | `gps/*` |
| 效果 | `frame/PhotoFrameExporter.kt`、`filter/PhotoFilterRenderer.kt`、`LocalPhotoEffectsOverlay.kt` | `frame/*`、`filter/*`、`PhotoFrameEffectPolicy` |
| 权益/更新 | `license/LicenseManager.kt`、`update/*`、购买/授权弹窗 | `license/FreeEntitlementPolicy.kt` |
| 导航/跨页状态/常亮 | `MainActivity.kt`、`HomeWorkspacePager.kt`、`ui/theme/*` | 最小 presentation 规则；完整共享UI待实现 |

## 第一批记录：网络基础与任务盘点

- 2026-09-05：核对 Android 页面、设置项、共享源码和既定方案。原 I01–I04 只有总分类，遗漏完整会话/事件接入、媒体绘制、设置持久化、共享UI细分、购买服务端、权限/后台异常矩阵和发布验收；本表补齐可执行子项。
- 首批新增源码：`iosApp/ZTransfer/Network/CameraTCPStream.swift`、`PtpIPChannel.swift`、`Diagnostics/CameraHandshakeProbe.swift`。
- Xcode target + Scheme 已加入 `ZTransferTests/CameraNetworkTests.swift`；12 个场景覆盖短读/EOF/超时/取消/迟到回调/并发读/共享握手金向量/畸形ACK/包长与限额/分块载荷。当前是“测试已写”，不是“测试通过”。
- 本批不修改 Android、shared 生产算法或 Gradle 依赖，Android 功能基线仍为 `55876fa`。iOS ObjC 导出名称、Swift 编译/并发检查、链接和真实相机行为必须由 M01/M02 验证。
- Windows 静态验收：`python iosApp/scripts/check_structure.py` 通过，5 个 App Swift 文件/1 个测试文件各入编一次，Xcode 引用、framework 构建顺序、Scheme 测试引用及 61 个任务 ID 检查通过；`git diff --check` 通过。12 个 XCTest 未执行，无 iOS 编译/真机结果。
- API 依据：[Apple Network receive](https://developer.apple.com/documentation/network/nwconnection/receive(minimumincompletelength:maximumlength:completion:))、[Apple 本地网络隐私](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)、[Kotlin Swift/ObjC 互操作](https://kotlinlang.org/docs/native-objc-interop.html)。

## 第二批记录：AP 会话诊断与串行事务

- 2026-09-05：新增 `PtpIPCommandSession.swift`，显式 FIFO 覆盖完整事务（不能只依赖 actor 单个片段串行）；支持有界控制数据、PING/PONG、事务号匹配和排队取消。活动事务取消/错误关闭流，排队取消不影响其他活动事务。
- shared 新增 `PtpIpOperationCodec.kt`：响应码仍调用已有 codec、事务ID使用已有小端读取；Native安全 DeviceInfo 入口调用已有解析器并将畸形数据转为空，未改 Android 原异常语义或调用路径。
- AP Debug 探针使用基线首事务1与ACK会话号，打开/读取机型/关闭；两通道共同取消与释放，正常 CloseSession 的事件EOF不会抢先误报失败。STA诊断仍不执行配对/激活；没有照片传输或完整产品界面。
- 新增9个 XCTest，总数21：AP三条命令金向量、STA事务0、命令PING、事务错配、累计数据限额、跨await串行、排队取消、共享DeviceInfo端到端探针、事件提前关闭失败。仅已写，Mac未执行。
- Windows实跑：`:shared:compileCommonMainKotlinMetadata` + 三个定向测试类15项（新4 + 已有11），`BUILD SUCCESSFUL`，0失败/错误；`:app:compileDebugKotlin :shared:lintDebug`，`BUILD SUCCESSFUL`，shared Lint 0 issue。
- `python iosApp/scripts/check_structure.py` 通过：6个App源码/1个测试源码各入编一次、21个测试方法、61个任务ID；`git diff --check` 通过。Android源码、Gradle依赖和打包脚本未修改，本轮没有生成APK，也没有iOS编译/真机通过证据。
- 后续重点：先验证首批Swift导出与并发编译，再完成生产会话、事件发布、基础文件枚举和STA完整激活。网络异常分支采用iOS明确的整流关闭；畸形事务额外拒绝及iOS整操作期限不能当作Android异常行为完全等价的证据。
- 并发依据：[Swift actor reentrancy](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)、[Apple TaskGroup cancellation](https://developer.apple.com/documentation/swift/taskgroup)。

## 第三批记录：AP 持续会话、原始文件枚举与 Mac 验收入口

- 2026-09-05：`APCameraConnection.swift` 持有单代命令/事件连接与串行事务；重连必须新建owner，旧通知携带旧connectionID。Debug探针增加可选持续模式：机型、原始存储ID数量、通配枚举、前20个对象抽样；不传输、不代表完整/实时照片目录，不新建第二套产品UI。
- `CameraTCPStream/PtpIPChannel` 允许事件包首字节无期限等待；收到第一字节后，剩余包头和数据有共同期限。取消关闭连接，不能将无事件错误地等同掉线。
- 保活对照 Android `CameraViewModel.KEEPALIVE_INTERVAL_MS=10000`、`NikonCamera.keepalive`：10秒、原子空闲检查、忙则跳过、非OK完整响应仍算存活。未来下载必须再接下载全程抑制（包括分块空窗），现阶段没有下载功能。
- 事件只发布有界最新状态和revision，消费者须按失效重扫；不承诺逐事件不丢、不接自动入队。事件EOF/命令IO失败关闭整组连接；正常关闭期间事件先EOF允许等待CloseSession响应；事务忙时断开直接终止而不排队CloseSession。
- shared `PtpIpOperationCodec` 增加IntArray/ObjectInfo窄入口，调用已有 `parsePtpUInt32Array/parsePtpObjectInfo`。保留ID顺序/位模式、空与畸形区别、未知大小、文件夹及不完整身份标记，不修改Android调用路径。
- 已知待对照点：Android畸形ObjectInfo回退名使用默认FORMAT locale数字回调；当前Native窄入口使用shared默认ASCII回退名。诊断明确显示identityComplete=false，不得把这类样本作为完整缓存身份。正式目录接入前需验证并对齐非拉丁数字locale，不能宣称此边界跨端1:1。Android AP旧getStorageIds将失败降为空；iOS底层保留明确失败，产品空状态映射仍待接入。
- Windows实际验收：`:shared:compileCommonMainKotlinMetadata :shared:testDebugUnitTest --tests 'com.ztransfer.protocol.PtpIpOperationCodecTest' --tests 'com.ztransfer.protocol.PtpIpProtocolCodecTest' --tests 'com.ztransfer.protocol.NikonDatasetParserTest' --tests 'com.ztransfer.protocol.PtpObjectInfoParserTest' --tests 'com.ztransfer.protocol.PtpArrayDatasetParserTest' :app:compileDebugKotlin :shared:lintDebug --no-daemon --console=plain`，`BUILD SUCCESSFUL in 54s`；5类25项测试全通过，shared Lint 0 issue。
- XCTest新增13项，总34项：事件空闲/半包期限、空闲命令不排队、完整AP枚举金向量、畸形不等于空、Busy保活、PING与事件revision、事件断线/拒绝打开/取消握手、排队取消、忙时断开、关闭事件EOF。均未执行，不能记PASS。
- 新增 `iosApp/scripts/verify_on_mac.py`：仅Apple Silicon原生Mac执行；检测Xcode/JDK17/SDK35/可用iPhone模拟器，串行Native测试→Debug XCTest→无签名Release真机架构编译，首次失败停止；独立目录保存日志/Tests.xcresult/report.json。不自动签名、安装到真机、上传或修改工程/本机配置，不覆盖既有产物。
- `python -m unittest discover -s iosApp/scripts -p 'test_*.py' -v`：7项脚本测试通过；Windows `--preflight-only` 如预期拒绝执行Apple步骤。自动选择/成功标记检查得到Windows验证，但Mac构建步骤本身仍未运行。
- 静态结构：7个App Swift文件/1个XCTest文件各入编一次、34测试方法、61任务ID；Android源码/Gradle/打包脚本保持不变，无新APK或iOS真机结果。此处是首批Mac编译验收门槛，先验证再批量扩大Apple代码，避免未编译桥接成为大规模功能的前置依赖。
- 验收命令依据：[Apple命令行测试](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)、[Kotlin Direct integration](https://kotlinlang.org/docs/multiplatform/multiplatform-direct-integration.html)、[Apple AsyncStream](https://developer.apple.com/documentation/swift/asyncstream)。

## 第四批记录：标准传输链路、STA、目录/预览及图库

- 2026-09-05用户明确要求继续Windows可写部分。第三批的“首次Mac编译前不扩展”停止安排已被替代；历史记录保留，但不把它当当前执行门槛。
- `APCameraConnection`改名为`CameraWiFiConnection`；同一owner处理AP和标准STA。STA用持久16字节ASCII initiator，OpenSession(1)/TID0、0x941C、Storage顺序；Storage成功不无条件加DeviceInfo；预期GUID和配对分支调用`NikonStaBridge`→既有策略。只在用户显式开启配对后提交0x952B/0x935A，OK即持久标记，缺失节拍事件不撤销配对；请求重新连接，不伪报相册就绪。历史档案/STA-direct尚未实现。
- `executeStreaming`在同一事务FIFO中按64KiB流式接收，校验数据与响应TID/累计限额/最终响应，文件字节不进入Kotlin；data-out复用既有三包codec，空Data也保留data-out语义。`PtpTransferBridge`复用TransferDownloadPolicy/TransferFilePolicy：未知大小、64位偏移、PartialObject与限定回退、实际读取长度推进和总长校验。下载占用跨chunk抑制保活。当前取消/写入失败关闭流，尚非Android可恢复Cancel/排空；持久断点恢复不得标完成。
- `SandboxTransferFile`每次独占创建唯一临时文件，只在创建成功后拥有清理权；写入计数/SHA256、fsync与关闭后同目录无覆盖move，现有同名文件保留；共享最终命名/日期目录。失败只丢弃本次part，不删除旧文件。UTF-8片段有字节上限。`CameraOriginalQueue`复用既有TransferTaskQueue/ExecutionState/reducer，原片FIFO、暂停当前后继续、撤回/清理/新ID重试；固定connectionID、不复用旧机身句柄。尚无效果/权益/断点/完整进度管线。
- `NativeCameraCatalogScan`是已有共享目录规则的单owner薄适配：usableStorageIds、queryStorageId、newestFirstHandleOrders、selectNewestCameraFileHeadIndex、mergeStorageMembership；按每卡head请求元数据，不能全局排序opaque handle。`CameraCatalog`失败不发布空目录，部分元数据不覆盖最后完整快照，相机事件发生在扫描中则标需重扫；不是增量事件/自动入队实现。
- 标准GetThumb仅确定无图/无对象/OK空响应可作miss；Busy抛可重试。AP FHD用既有分类/支持锁存，2次Busy重试/160ms。`CameraPreviewStore`同键合并、32MiB/256项LRU与内存压力代次控制，FHD临时失败不负缓存。`PreviewImageDecoder`使用ImageIO方向变换与最大4096像素输出（默认2048），本地文件按URL解码。STA目前降级标准缩略图，MPF/RAW/视频预览未接。
- PhotoKit仅addOnly；照片/视频由系统接受，unsupported/拒绝/失败保留沙盒原文件；提交后等待真实完成，不因取消误报“没保存”诱发重复导入，不自动重试，不宣称管理“Z传”相册。权限声明已在两种构建配置中检查。
- Bonjour只浏览`_ptp._tcp`和`_nikon._tcp`，8秒/最多60秒有界、Wi-Fi限定、stop/restart代次隔离。服务候选接现有标准STA会话、仍需responder验证；未进行Windows网络扫描。显式Info.plist数组合并两种配置。NWEndpoint保留系统解析服务/接口，不持久化为物理身份；不同serviceType代表同一机身的进一步去重、历史IP/受控子网仍待实现。系统服务连接使用广告端口，与Android解析IP后固定15740的边界需真机对照。
- 测试：shared完整375项，0失败/错误；`:shared:compileCommonMainKotlinMetadata :shared:testDebugUnitTest :app:compileDebugKotlin :shared:lintDebug --no-daemon --console=plain`最近`BUILD SUCCESSFUL in 44s`。新增桥接测试包含目录opaque顺序/跨卡备份/文件夹与不完整、STA策略、队列、64位传输和FHD锁存矩阵。
- Swift共63个XCTest方法（未执行），新增流式TID/响应/写入失败、64位Partial和回退、无覆盖文件/SHA256、FIFO真实临时文件、STA序列/ACK持久、PhotoKit授权/失败/提交后取消、data-out金向量、目录失败保留/事件失效、缓存重试/清空、EXIF方向和尺寸。不能将“已写63项”写成测试通过。
- Windows结构检查16个App源/1个测试源各入编一次、63测试方法、61任务ID、Bonjour与照片权限检查通过；7项Mac验收脚本单测通过。没有执行Xcode、Swift/Kotlin Native编译、XCTest或真机验证。Android app源码、Gradle依赖/配置、dist和dist-debug不修改，本批未生成APK或提交推送。
- 后续还可在Windows继续：完整进度/Files导出与书签/系统适配、STA专用读取、共享呈现/其他平台端口。遥控写后确认编排仍在Android RemoteLab，完整共享UI也需Compose依赖迁移；若要共享这些残留编排，应明确受控Android集成阶段，不通过Swift抄一套来满足表面“不改Android”。
- 官方API依据：[ImageIO方向](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailwithtransform)、[PhotoKit](https://developer.apple.com/documentation/photos/phphotolibrary)、[NWBrowser](https://developer.apple.com/documentation/network/nwbrowser)、[本地网络隐私](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。

## 第五批记录：Files、进度及GPS平台基础（Windows约34%）

- Files：`SystemDocumentPicker`以asCopy导出已保存的原文件；目录选择保存最小安全作用域书签。`ScopedDirectoryStore`平衡start/stop访问、在有效授权范围内刷新stale书签，撤权/损坏不覆盖旧书签，忘记目录只删除本地书签。尚无provider协调写入，不能说下载目的地已切到外部目录。
- 传输：连接层以已实际写入字节报告进度，200ms节流、成功结果强制一次；队列的active进度调用shared比例/保留最后有效速度规则，任务ID隔离和单调字节约束拒绝迟到进度，失败保留实际进度。文件成功仍以关闭后发布结果为准。
- 定位：`CameraLocationProvider`仅显式开启前台WhenInUse；新manager隔离旧回调，120秒新鲜度、有效horizontal/verticalAccuracy、当前UTC、共享频率和GEO编码；CoreLocation不暴露卫星数，填0不编造。后台停止并清空坐标。iOS融合海拔与Android GPS-provider来源并非已验证等价。
- 配对：`NikonGpsPairing`调用现有共享握手，不复制盐/哈希/阶段规则；端侧仅SecRandom与固定8字节Blowfish primitive。非抛出Kotlin加密回调若失败，通过外部错误标记拒绝提交状态/发送结果。captured stage1/2→stage3固定向量已写XCTest，未执行。`NativeGpsBridge.beginPairing`覆盖无符号位模式、保存身份/新身份两条入口，与既有共享返回值逐字段一致。
- 蓝牙：`AppleNikonGpsGattDriver`只在显式操作后创建CBCentralManager；限定Nikon服务、8秒扫描/64候选，选择后15秒有界连接与发现。PAIR与NOT1顺序订阅成功后才GATT ready；CoreBluetooth管理CCCD，不手动写0x2902。iOS peripheral UUID不当作Android MAC或Nikon身份。NOTIFY/INDICATE双属性时系统选择、初次Classic配对差异必须真机验证。
- `NikonGpsGattConnection`通过可注入driver保持整次写入FIFO；只接withResponse ACK，不把提交写调用当成功。PAIR/ID/GEO分别17/32/41字节，按系统maximumWriteValueLength拒绝超限，不随意拆Nikon协议包。队列16项、通知32项；协议通知溢出显式失败，不静默丢包。活动写取消/超时关闭整代，排队取消不影响当前写；关闭/旧回调不能完成新写。Debug蓝牙页仅连接订阅，不做认证/身份/GEO写入，也不标记GPS可用。
- Windows验收：完整380项shared测试0失败/错误；common metadata、Android编译、shared Lint同次`BUILD SUCCESSFUL in 46s`。结构检查24 App Swift/1 XCTest源全部入编一次；76 XCTest方法仅已写（比第四批增加Files/进度/定位/加密/GATT场景13个），7项Mac验收脚本测试PASS。`git diff --check`通过，Android源码/Gradle/打包脚本改动列表为空，无APK、提交或推送。
- 持续未验收：所有Swift编译/ObjC导出、Apple API回调/权限、系统文件提供方、CommonCrypto向量及蓝牙/定位实机。Windows进度34%只反映源码覆盖的粗估，不提升这些项目为PASS。下一批继续可写的平台适配及共享规则接线，正式UI依赖迁移和残留Android编排仍按既有约束处理。
- 官方接口依据：[Files目录访问](https://developer.apple.com/documentation/uikit/providing-access-to-directories)、[CoreLocation前台授权](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization())、[Apple CommonCrypto头文件](https://github.com/apple-oss-distributions/CommonCrypto/blob/main/include/CommonCryptor.h)、[CoreBluetooth写入](https://developer.apple.com/documentation/corebluetooth/cbperipheral/writevalue(_:for:type:))。

## 第六批记录：元数据与共享滤镜预览（Windows约35%→36%）

- `PhotoMetadataReader`按URL读取ImageIO第一个图像属性，不展开全图、不修改文件；TIFF/EXIF/GPS映射到已有`PhotoFrameExifValues`。数字/rational、APEX回退、ISO第一值、GPS符号/范围/零值、日期及镜头清理继续调用shared，未接地名服务或修改原片GPS。`NativePhotoMetadataBridge`仅把既有EXIF与格式函数聚合给Swift；Apple固定小数采用POSIX/halfUp，边界XCTest未跑，不能默认Foundation/Java格式化完全一致。
- Debug已保存文件可读取元数据；只显示相机/镜头/曝光/日期，不回显坐标。任务取消/文件URL变化后不发布旧结果。新增4个XCTest覆盖正常字段、无效值/APEX、多ISO、舍入及实际JPEG文件字节不变；Windows只验证新增2项shared桥接测试与已有规则，不把Apple映射记PASS。
- `NativePhotoFilter`每块最多4096像素，只编译一次`compilePhotoFilter`、逐块调用`renderPhotoFilterArgbRange`；不复制内核或使用近似Core Image LUT。commonTest对全部内置预设×有/无alpha×强度2/80/100与既有入口逐像素相等，另覆盖非法范围/末块尾部/目录顺序/强度归一化。
- `PhotoFilterPreviewRenderer`只接方向已处理CGImage，限定4MP（诊断先解码至2048边长）；CoreGraphics显式sRGB、Accelerate去预乘/重新预乘、块间取消，字节ARGB↔KotlinIntArray位模式显式转换。输出provider持有独立不可变副本，释放scratch不会悬空；原片不改。每像素Swift/Native桥接成本、透明边缘舍入及宽色域转换尚需Mac性能/对照，不宣称原尺寸导出完成。
- Debug新增真实首个内置预设80%预览；没有保存为效果成片、相框水印或正式滤镜选择页。内存警告同时清图与取消在途预览，避免清理后再填回。新增3个XCTest覆盖ARGB位序/源数据不变、2×2图像行序、预取消/畸形缓冲；未执行。
- 验收：完整385项shared测试（71类）0失败/错误；common metadata、Android编译与shared Lint `BUILD SUCCESSFUL in 1m 12s`；26个App Swift源/1个XCTest源、83方法、61任务ID结构检查PASS，7项Mac脚本测试PASS。Android源码、Gradle配置/依赖、dist/dist-debug差异仍为空，没有APK、提交或推送。所有Apple编译/运行/效果对照继续待验。
- 官方接口依据：[ImageIO GPS字段](https://developer.apple.com/documentation/imageio/gps-dictionary-keys)、[ImageIO ISO](https://developer.apple.com/documentation/imageio/kcgimagepropertyexifisospeedratings)、[Apple vImage工作流及原位alpha转换](https://developer.apple.com/documentation/accelerate/building-a-basic-image-processing-workflow)。

## 第七批记录：获授权后的共享UI基础（Windows约38%）

- 2026-09-05用户“允许，继续”：授权调整Android原页面/引用和构建依赖，仍要求功能稳定、逐批回归。保持app/shared/iosApp三部分，不增另一套产品UI或应用模块；版本1.81/54不变。
- CMP选固定1.8.2（稳定iOS支持），Kotlin2.2.21/AGP8.10.1/Wrapper不动。app/shared共用插件版本与依赖DSL，Android通过Gradle metadata解析Google AndroidX产物；移除旧BOM混配。Debug tooling隐式Material1.0.0回退被依赖快照抓到，显式debugImplementation(compose.material)对齐1.8.2，Release不加此调试依赖。
- 依赖快照：`snapshot-ui-dependencies.init.gradle.kts`读取解析模块图而非Android多产物集合，失败不输出成功快照；保存build/ios-ui-dependencies/{before,shared-compose}-{debugCompileClasspath,debugRuntimeClasspath,releaseRuntimeClasspath}.txt。首次脚本用resolvedArtifacts触发多variant歧义，已改成resolutionResult并重新取得完整基线。`compare_ui_dependencies.py`报告新增/升级/删除，不只过滤Compose。
- 主要变化：Runtime/UI/Foundation/Animation 1.7.6→1.8.2；Material3 1.1.2→1.3.2；icons 1.5.4→1.7.6（CMP图标工件1.7.3）；Lifecycle实际2.8.3→2.8.7；Coroutines1.7.3→1.8.0；另有annotation/collection/emoji/profileinstaller及CMP桥接模块。最终Debug runtime模块102→131，Release95→120；模块数包含metadata桥接，不等于APK新增同等数量实现。ZXing/EXIF/相机协议源码未改，依赖升级仍须系统级回归，不能声称运行时绝对无影响。
- 原10个UI文件搬入commonMain：Color/Type/Motion、ZMark/BroomMark/Marks、TransferStatusIcons、ControlTileFieldLabel、TransferProgressMotion、LiquidProgressFill。保留包名/调用方式/几何和数值；跨模块调用的原internal函数开放为public。SkinPreset仅去Android R绑定，名称/顺序不变；app同包extension继续给原SettingsScreen提供原资源ID，未更换翻译。
- SharedTheme保留原两套显式Material配色/字号/LocalAppColors；app ZTransferTheme保留原系统栏副作用和原纹理provider，委托共享主题。纹理/触感未迁移，iOS探针不伪造已具备这些材质效果。Material3新版本未显式设置的默认样式、字体在不同OS的落地、手势/重组性能仍需截图与实机验证。
- 升级唯一现有页面兼容改动：TransferScreen.animateItemPlacement改animateItem，保留Motion.itemPlacement，fadeInSpec/fadeOutSpec均null；原自定义移除高度动画、队列行为不变。没有修改连接/协议/服务/ViewModel/GPS/发布脚本。
- `check_shared_ui_migration.py`以55876fa逐文件比较：除明确允许的资源解绑/可见性变化，10个组件主体完全一致；两套Material配色、Android系统栏副作用及TransferScreen整文件仅允许上述API替换。检查不会消除数值/几何差异，也不冒充视觉回归。
- 原Android进度/波形7项金样本迁入commonTest（仅切kotlin.test），新增3项皮肤名称/四token边界/字体动画默认测试。实跑395 shared +311 app共706项，0失败/错误；两模块Lint与common metadata/Debug编译同次BUILD SUCCESSFUL in 3m35s。Python14项通过，结构检查27 Swift源/84 XCTest方法（未运行）/61任务ID。
- iOS侧SharedUiController.componentProbe→ComposeUIViewController→SharedUiComponentProbe；Swift仅UIViewControllerRepresentable容器，Debug弹出同一套组件。Info.plist显式CADisableMinimumFrameDurationOnPhone=true并纳入检查；新增实际UIKit factory loadView smoke XCTest待Mac。不是正式首页/浏览器，不制造相机或购买成功状态。
- 下一批：继续U02材质纹理/按钮/触感的窄平台适配与金样本，再迁正式页面；iOS Native/Swift编译、Android真实交互/三连接与截图、R8/资源包/Release签名等不能由本批单测代替。没有打包APK或提交推送。
- 第七批收尾结果：Debug工具Material显式对齐后，Android全部测试/Lint、Release Kotlin编译和依赖快照BUILD SUCCESSFUL in 3m18s。

## 第八批记录：共享按钮与材质（Windows约40%）

- 原SkinTexture/GlassButton/ConnectionCardMaterial迁入commonMain，Android原调用点不改；缓存键/变体数/懒加载/生成Mutex/着色/按压/禁用参数保持原样。位图转换与同步锁仅两个窄平台接口，不新建模块或业务层。
- Android仍使用Bitmap.createBitmap ARGB_8888与synchronized；iOS使用显式RGBA/straight-alpha/sRGB、Skia复制后释放临时Image、NSRecursiveLock。已核对CMP 1.8.2 Maven官方源码的toBitmap复制行为，但iOS实现尚未编译执行。
- 迁移前独立实跑SkinTextureBaselineTest取得全部80变体SHA-256（每张65536个ARGB像素），固定在app/src/test/resources/ui/texture-baseline-55876fa.sha256；迁移后对照全部一致，非用新算法生成新期望值。
- 5项公共测试覆盖负seed/整数边界floorMod、RGBA通道/透明度、非法尺寸/溢出、锁重入/异常返回。另写2项iosTest检查原生位图通道/半透明和临时图像关闭后可读，随Mac Native测试执行，Windows未运行。
- iOS共享组件探针加入原GlassButton激活/禁用、连接卡片及材质徽标；Android仍在原Theme位置注入同一纹理palette，未改变窗口副作用。
- 13文件对照guard仅允许可见性/平台端口机械替换，全部PASS；16脚本测试PASS；400 shared+312 app=712项测试通过，common metadata/Debug/Release编译及双模块Lint通过，协议/ViewModel/GPS/dist/dist-debug零差异。
- 边界：这些验证证明Android CPU像素和受检源码不变，不证明升级Compose后的截图/手势/字体完全相同；默认compositionKey所选纹理需真机对照，显式textureSeed不变。iOS浮点、Skia透明度/低alpha量化、原生锁和缓存内存占用均待Mac/iPhone验收。没有APK、提交或推送。

## 第九批记录：通用交互控件与触感接口（Windows约42%）

- ReleaseCommitWheel、TipLightbulbButton、Fireworks、WatermarkPlacementPreference迁commonMain。只调整跨模块所需可见性，拨轮预览/松手提交/取消恢复、帮助展开/无障碍、烟花时序/随机种子、水印偏好保留均原样。原Android专项测试继续直接验证共享实现。
- Haptics抽成七方法语义接口及rememberHaptics平台factory。Android原代码移androidMain，仅类名/override/factory与常量归属变化；SDK分支、enabled门控、65ms失败二次tick/attached检查、Vibrator调用、remember(view, enabled)不变。
- 原800ms波形/10级振幅/63ms静默尾段/18ms确认与220振幅迁公共单一来源。iOS采用UIKit selection/impact/notification生成器，将原波形映射为十次渐强脉冲；关闭不初始化生成器，退出/切换enabled取消Job，后台不播放，超时50ms丢弃陈旧脉冲，不自动发成功确认。物理触感不宣称等同Android振子，待iPhone验收。
- 共享模块Lint最初检出6个VIBRATE缺声明；已在shared/androidMain/AndroidManifest.xml声明App原已有权限，不屏蔽Lint。Debug合并Manifest SHA256仍为DF0F0F7CE221B04D9A65EC81300ACD7D993894B66B0635F3265361417A075EEB，Release仍为6EA659D889883DFC1BCB57895C391B914CBAFEC45F9B730A9738A7B5C02FF8EC；与补声明前逐字节一致。
- 新增2项波形/时间/强度共享测试；402 shared+312 app共714项0失败/错误，common metadata、Debug/Release编译、双模块Lint BUILD SUCCESSFUL in 2m27s。17脚本测试/17组件对照/Android触感完整源码与波形对照PASS。27 Swift源/84 XCTest/2项iOS位图Native测试仍未在Mac编译运行。
- 下一步U02/U05：先准备共享文字资源与Android R兼容入口，再拆队列页状态/回调与图片加载接口；SignalPill/格式化/滤镜名称和返回处理仍有Android依赖，不把整份ViewModel挪入公共模块。iOS必须连接真实队列/相机状态，不能用静态示例冒充正式页面。后续还有U03/U04/U06等正式页面及N/D/T/R/G/E/L任务，Windows工作远未100%。
- 本批未改Android协议/ViewModel/GPS/服务/打包脚本，未打APK、未提交推送。新UIKit源码只有静态检查；不将Windows JVM回归记为iOS运行通过。

## 第十批记录：队列展示共享化（Windows约43%）

- 从Android TransferScreen提取TransferCardComponents：卡片正文/状态徽标/状态颜色/信息胶囊及动画、重试按钮、FAB确认卡、缩略图显示。Android原页面真实引用，不保留第二份绘制逻辑；没有迁移TransferViewModel或相机服务。
- 文字边界采用一个不可变TransferTaskCardText，Android继续执行原formatSpeed/formatDuration/formatFileSize及Java默认locale的完成速度格式；相框/滤镜名称、错误默认文案、取消/重试文案继续读取原R资源。本批不复制翻译表、不升级依赖；统一资源仍待后续处理。
- Android页面主体与队列操作原样：独立高频进度订阅、生成时钟、移除280ms/清理320ms、撤回先于删除、相机重试与excludedTaskIds、现有文件判断、确认互斥/遮罩均保留。QueueThumbnail原remember(file.handle)、LaunchedEffect(file.handle,retryNudge)、loadThumbnail条件原样，仅把Bitmap/占位图显示交给共享函数。
- transfer_card_extraction.py是只读验证规则，不是运行时依赖；check_shared_ui_migration.py从55876fa计算明确允许的提取结果，同时比较整个Android文件和完整共享绘制文件。新增5项脚本测试确认页面业务体逐字不变、原格式化表达式/加载键保留、平台资源/相机I/O未进入组件、异常锚点拒绝及数值变更不能被对照消除。22项脚本测试全部通过。
- 新增2项commonTest覆盖四皮肤×深浅色×全部任务状态的原颜色，以及生成标记优先于失败/取消的既有分支；不趁机修正旧边界。404 shared+312 app=716项测试0失败/错误，common metadata/Android Debug+Release编译/双模块Lint BUILD SUCCESSFUL in 3m44s；app Lint 0 errors/180 warnings/12 hints，shared无issue。
- TransferCardComponentProbe接现有UIKit组件入口，明确标注“非真实传输”，可切状态/生成态、检查徽标/胶囊/禁用重试/确认回调；不访问网络、不清真实队列，不计为完整iOS队列页。Apple编译/界面效果/交互仍待Mac与真机；27 Swift源、84 XCTest、2 iOS位图Native测试均未执行。
- Debug/Release合并Manifest哈希仍为第九批记录值；本批未改原文字资源、Gradle、协议/ViewModel/GPS/服务/dist/dist-debug；未打包、提交、推送。
- 下一步：继续U05完整列表及操作接线，最小状态为tasks/isTransferring/existingExportIndex（需保留revision发布语义）、独立activeTransferProgress、单调时钟、缩略图loader和原队列操作回调。先保留Android订阅粒度/调用顺序，再由iOS真实队列供值；还需补齐iOS当前snapshot缺少的元数据、时间/完整操作能力，不能把原片诊断队列说成全功能队列。统一文字资源、顶栏SignalPill/返回处理及其余正式页面也未完成。
- 官方依据：[CMP 1.8.2依赖](https://kotlinlang.org/docs/multiplatform/whats-new-compose-180.html)、[版本兼容](https://kotlinlang.org/docs/multiplatform/compose-compatibility-and-versioning.html)、[UIKit集成](https://kotlinlang.org/docs/multiplatform/compose-uikit-integration.html)、[LazyItemScope动画参数](https://developer.android.com/reference/kotlin/androidx/compose/foundation/lazy/LazyItemScope)。

## 第十一批记录：完整队列正文共享（Windows约44%）

- SharedTransferScreen承接原TransferScreen完整正文：空队列呼吸、倒序列表、局部进度订阅、生成时钟、移除/回弹、液态进度、遮罩、二次确认、批量重试及清空收尾。不是复制第二个产品页面；Android现在直接调用这一份正文。
- TransferQueueUiContract仅包含低频tasks/isTransferring/existingExportRevision、操作回调和九个本地化文本。已有文件索引仍由Android持有，通过isOriginalTransferred查询；显式保留revision使索引原地更新不被页面快照相等吞掉。独立activeTransferProgress只在TRANSFERING卡片内订阅。
- Android保留原state/connected订阅、SystemClock单调时钟、缩略图remember/LaunchedEffect及加载、速度/耗时/相框滤镜名称格式化、BackHandler与SignalPill顶栏。业务调用仍进入原TransferViewModel和同一CameraViewModel::getCamera，不迁ViewModel，也不更改传输服务。
- 清空顺序仍是withdrawPending→标记非活动任务→320ms→removeCleared→读取最新state.value.tasks回收标记；单项动画仍280ms，删除拒绝时200ms回弹。retryFailed仍传正在移除任务的排除集。文本仅从原R读取后作为参数传入，读取时机变为页面组合时，不改内容/locale规则。
- FileListScreen仅移出它与队列共用的collapseHeight函数到shared，函数体原样、可见性internal→public，其余整个列表文件逐字对照55876fa。未改列表业务逻辑或动画数值。
- 新增transfer_page_extraction.py只读规则，串联上一批卡片提取，从55876fa生成允许的完整Android文件/共享正文/布局结果逐字比较；不归一化动画常量或业务顺序。新增7项脚本测试，全部29项PASS。
- 本批404 shared+312 app=716项测试0失败/错误，common metadata、Debug/Release编译、双模块Lint BUILD SUCCESSFUL in 3m8s。UI布局、Compose升级后的实际重组/截图/手势仍须真机验收，源码对照不等同于已验收。

## 第十二批记录：iOS原片队列页面接口（Windows约45%）

- NativeOriginalTransferQueue增加低频taskSnapshotAt和独立progressSnapshot读取；补withdrawPending/removeTask/retryFailed，全部委托原withdrawWaitingTransferTasks/removeTransferTaskIfTerminal/retryableTransferTaskIds/newAttempt等规则。批量重试按原历史顺序入FIFO，排除集只作筛选，不按Set迭代顺序排队。
- 原片完成速度补齐为共享endToEndBytesPerSecond / 1024²；目前iOS原片路径没有断点续传，bytes就是本次原片字节。未来接续传时必须改用真正本次传输量，不把总文件大小误作本次速度分子。Android现有统计代码未改。
- CameraOriginalQueue继续由单一actor持有core/worker，不移动到MainActor。Swift Sendable快照增加handle/size/captureDate/保护标志/storageIDs/目标目录/耗时/完成速度，只跨线程传Swift值，不给Kotlin队列对象加unchecked Sendable。historyRevision区分低频变更和200ms进度发布。
- Swift增加批量撤回、安全移除、带排除集的批量重试接口。removeTask只删除队列记录和savedFiles查询引用，绝不删除磁盘原片；等待/活动任务拒绝移除，旧动画ID不能误删重试后的新ID。
- 新增5项common测试覆盖低/高频分离、撤回/删除竞态、屏外清空不残留待传项、重试排除与FIFO、完成速度/零耗时。409 shared+312 app=721项0失败/错误；common metadata、Android Debug/Release编译、双模块Lint BUILD SUCCESSFUL in 3m15s；Android Lint 0 errors/180 warnings/12 hints，shared无issue。
- 新增2个XCTest方法检查Swift元数据/集合桥接、等待项保护、撤回/删除/排除及不触碰文件；原FIFO保存测试增加完成统计与删除记录后文件仍在断言。现86个XCTest、2个iOS位图Native测试全部仍待Mac，不能将结构检查当Swift编译。桥接采用[Kotlin官方映射](https://kotlinlang.org/docs/native-objc-interop.html)，导出名/nullable数字/Set转换仍以实际framework编译为准。
- 整页/17组件/触感/布局对照、29脚本测试和Xcode结构检查PASS。Debug/Release合并Manifest哈希与第九批完全相同。未改Android协议/ViewModel/GPS/服务/打包脚本和版本，未打APK、未提交推送。
- 下一步U05真实接线：现有AsyncStream只有一个消费者（CameraHandshakeProbe），必须由同一owner转发到共享页面，不能再起一个订阅竞争消息。Compose主线程只接不可变快照；删除/撤回必须收到actor执行结果，不能在异步提交时假装已成功、也不能阻塞主线程等actor。需要完成实际队列页面控制器、原文案/格式化与缩略图适配、连接代隔离和销毁取消，再接顶部开始/暂停/返回。
- 当前仍是原片执行链路，不包含效果/权益/已导出文件索引/自动事件/断点与后台恢复；不能将SharedTransferScreen已经迁好说成iOS完整产品队列已经可用。其余N/D/U/R/G/E/L任务仍可在Windows继续写，不是Windows100%。

## 第十三批记录：iOS真实原片队列接入共享页面（Windows约47%）

- NativeQueuePageModel是单页主线程状态桥，不是第二个传输引擎；Swift actor仍独占NativeOriginalTransferQueue。NativeQueuePageSnapshot先构造/校验完整批次再原子发布，携带connectionId、递增sequence和historyRevision；拒绝旧连接、迟到序号、重复ID、未知状态、多活动任务及非有限进度。高频进度不替换低频任务列表。
- OriginalQueuePageBridge由现有CameraHandshakeProbe.queueObserver转发，未新建第二个AsyncStream消费者。命令先await真实actor执行，再读取并发布操作后快照，最后回传结果；清空后的currentTasks不再依赖观察者是否赶上。晚到的旧观察快照被sequence拒绝。
- TransferQueueUiActions六种操作改为suspend，点击路径用CoroutineStart.UNDISPATCHED立即进入：Android原方法仍在点击返回前执行；iOS等实际结果之后才标记移除/开始清空动画。删除原有280ms/拒绝200ms回弹、清理320ms及排除集规则保留。清空try/finally扩展覆盖异步撤回等待，取消时复位页面状态。不使用主线程阻塞等待actor。
- NativeOriginalQueuePage调用同一个SharedTransferScreen，真实任务/进度/重试/撤回/清理/开始暂停可从Debug持续连接页“打开共享队列（真实任务）”进入；SwiftUI只包UIViewController，不重写任务卡片。开始/暂停/返回是真实操作，但完整SignalPill/工作区顶栏仍待共享，不声称整页外观已经完全验收。
- 缩略图复用CameraPreviewStore及相机串行命令，ImageIO在后台actor统一方向并缩到最长128px后编码PNG；跨语言载荷限1MiB，Compose关闭临时Skia Image。页面按model/handle/传输边界/连接就绪补载；关闭页面取消自己的请求，不停止真实传输worker，合并缓存请求由原连接owner管理。
- 原片卡片的大小/实时速度/耗时继续复用TextFormatPolicy。完成速度单独按系统地区格式（与Android原默认locale路径一致），其它小数沿用现有ApplePhotoDecimalFormatter的POSIX模式；浮点/舍入等价仍需Mac边界样本验收。
- NativeQueueTextCatalog从Android原英语/简中/繁中文案表生成，脚本逐字对照，未另译一套文案。当前是iOS队列文字入口，不代表全App资源已统一；未来改原表必须同步生成值并过对照测试。
- 页面close幂等，取消所有等待结果、忽略重复/迟到回调，释放Swift owner→Kotlin model→owner持有链。单操作等待有15s上限；回调关闭后不能重新打开状态。连接owner结束时关闭页面，跨连接恢复/持久化队列仍属后续任务。
- Kotlin专用actions/StateFlow/页面函数不进入Swift使用面；suspend回调类及SharedTransferScreen用HiddenFromObjC隔离。参考[Kotlin官方互操作与回调映射](https://kotlinlang.org/docs/native-objc-interop.html)、[HiddenFromObjC](https://kotlinlang.org/api/core/kotlin-stdlib/kotlin.native/-hidden-from-obj-c/)。Windows只验证common/Android编译，实际导出名、Swift actor隔离、UIKit/Skia仍待Mac。
- 新增8项common测试：原子/元数据/连接与序号隔离、高低频分离、非法快照、实际删除确认、失败撤回不标记、排除集、页面关闭与重复回调、Android立即执行顺序、缩略图身份/语言选择。417 shared+312 app=729项0失败/错误；31脚本测试、完整页面/17组件/布局/触感源码对照PASS。最终构建/Lint结果见顶部检查点。
- 新增2个XCTest：真实共享UIKit控制器不会启动待传任务、actor删除结果先发布后确认且关闭后拒绝晚到消息；扩充ImageIO测试覆盖队列PNG方向/尺寸。88个XCTest及2个iOS位图Native测试全部待Mac执行；28 Swift源/Xcode编译登记和61任务ID结构检查PASS。
- 清掉Android已无调用的TransferRetryButton/ConfirmFab包装，实际格式化/资源/图片加载/返回/顶栏仍保留。未改Android协议/ViewModel/GPS/服务/打包脚本/版本和Gradle依赖；合并Manifest哈希仍为第九批值。没有APK、提交或推送。
- 下一步：继续U02连接状态控件与U04实际文件浏览/选择接线，继而N/D增量事件与自动入队、效果/遥控/GPS、存储恢复和权益等。当前原片页面不支持效果任务/已有文件离线重试，不把false索引适配当成这些功能完成。Release仍是入口占位壳；Windows任务显然未100%，继续写，不因Mac未开而停工。

## 第十四批记录：AP/STA真实状态连接胶囊（Windows约48%）

- 原SignalPill/信号配色/STA与USB图形迁SharedSignalPill；Android原RSSI订阅、设置Intent、STA重连回调仍留原处。整个FileListScreen对照55876fa，只允许收合布局/信号控件的显式提取；不改原阈值、动画时长和图形路径。
- iOS通过单一连接owner传实际stationMode/ready状态。平台明确开启allowUnknownRssi，AP已连接但没有RSSI时显示连接图标，不画虚假信号格、不显示-999 dBm、不误落入离线设置动作；Android默认false，仍完全按原条件判定。2项common测试覆盖全部模式组合/边界。
- iOS离线点击接三语言重连说明和公开应用设置入口：AP需系统设置加入相机Wi-Fi，STA需同网络；应用设置仅管理权限，不冒充Wi-Fi选择器。UIKit presenter弱引用，页面关闭释放引用；没有新增连接/队列观察者。
- 平台差异依据：[Apple fetchCurrent](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent%28completionhandler%3A%29)只填SSID/BSSID/安全类型，不提供可直接用于原Android RSSI格的值；[signalStrength](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/signalstrength)为0–1量，不是dBm。本批不申请额外位置权限来假造强度。
- 419 shared+312 app=731项测试0失败/错误/跳过；34辅助脚本PASS，common metadata/Android Debug+Release编译/双模块Lint BUILD SUCCESSFUL in 3m 17s。app Lint 0 errors/180 warnings/12 hints，shared无issue；两种合并Manifest摘要保持原值。
- 增加1项Swift真队列STA参数/控制器测试，目前89个XCTest、2个iOS位图Native测试全部待Mac。28个Swift源码及61任务结构检查PASS不等于Apple编译。未修改Android协议/服务/ViewModel/GPS/打包脚本/版本，未打包或提交推送。

## 第十五批记录：复用原开始/暂停操作按钮（Windows约49%）

- SharedQueueExecutionButton承接原32dp圆形材质、按压0.92缩放、原180ms配色/高亮及图标切换动画；Android只传原R文本和原回调，MainActivity的状态订阅/启停逻辑/触感/暂停提示没有修改。
- iOS原片页移除临时GlassButton播放/暂停写法，使用同一按钮及已共享queueExecutionControl：空队列隐藏、待传显示开始、活动传输显示暂停。保留按钮退场时的上次状态与原显隐动画；已经请求暂停不重复发命令。原片任务全部需要相机；效果离线重试未实现，不假定startEnabled可离线。
- 新增只读queue_execution_extraction规则和3项脚本测试，对比完整Android列表文件与共享按钮正文；尺寸/时长/图标更改不能被归一化掩盖。37辅助脚本及源文案对照PASS；已有common测试覆盖按钮状态选择。419 shared+312 app=731项测试0失败/错误/跳过；common metadata、Android Debug/Release编译和双模块Lint BUILD SUCCESSFUL in 3m 13s。app Lint仍为0 errors/180 warnings/12 hints，shared无issue；Debug/Release合并Manifest摘要不变。
- 本批未增加架构模块、Swift产品页面或第二个传输引擎。完整顶栏的队列胶囊/入队飞行/触感偏好/暂停提示尚待后续工作区接入；实际截图、手势、资源和Apple桥接仍须Mac与真机。
- 下一步U04：从原FileListScreen按日期分组头、缩略图单元/连拍网格和筛选选择逐步提取；原文件列表的CameraViewModel/加载节流/边界坐标/动画回调要保留Android适配，再接iOS真实目录快照。不得以第二套SwiftUI网格或诊断20行列表替代产品浏览页。

## 第十六批记录：完整原文件网格共享（Windows约51%）

- SharedThumbnailGrid迁入完整原LazyVerticalGrid、日期GroupHeader、普通ThumbnailCell、连拍合集/堆叠缩略图、加载提示、已传输徽标及活动进度角标。Android ThumbnailGrid仍用原签名，原页面协调器/回调/调用处不改；同一份网格将承接iOS真实目录，不写第二套SwiftUI照片墙。
- 日期收合仍仅保留当前可见格子+一行缓冲、300ms高度收合；展开及筛选仍600ms窗口/原级联参数。连拍重排仍等待一帧后一次更新成员，保持原Lazy key/contentType、隐藏连拍成员的退场结算、受影响日期局部重排和资源清理。全部数值、图形、回调顺序以55876fa整段源码为准，不借迁移修正旧行为。
- 仅四类平台边界：ThumbnailGridImageSource的photo/stack读取、ThumbnailGridText原位置文本读取、isTransferred组合查询、活动进度组合读取。接口只供Kotlin UI使用，不扩大Swift公开接口；Swift仍从UIKit控制器进入。未添加新模块或生命周期依赖。
- Android图片加载仍使用原remember(file.handle)、普通图3个LaunchedEffect键/堆叠图4个键、cachedThumbnail和loadThumbnail(file, allowRemoteThumbnail)。图片读取仍发生在原格子组合位置，不在网格顶层预加载。关闭预览只读缓存的门控、按loadEnabled启停保留；不是让shared持有CameraViewModel或相机服务。
- 已保存查询保留file/index/revision/日期整理四个remember键。活动进度只在TRANSFERING分支调用Android collectAsStateWithLifecycle，且仍按taskId匹配；未改成网格顶层订阅，不把StateFlow.value偷读当订阅。
- 数字徽标文本在AnimatedContent旧/新计数各自的组合里读取，日期/无日期/保护/展开/收合/整组传输继续原R文本。筛选面板与照片预览继续用同一BurstGlyph/徽标，Android薄包装保留。界面结构及重组边界有新增平台函数调用，实际截图/手势/性能必须真机核验，源码逐字对照不是运行等价证明。
- FileGroup/BurstPhotoGroup/ThumbnailGridItem、buildThumbnailGridItems/reconciledExpandedBurstIds、边框颜色及状态规则一并共享；常量只保留共享定义，Android删除事件协调器直接引用同一个280ms重排时长。未改排序/连拍检测/备份归并算法。
- 新增8项脚本测试，现45项PASS：完整页面协调器不变、原加载键与导出revision、仅活动分支订阅、坐标清理/手势/回调、动画文本、常量单一来源、数值/算法变更可检出及整个Android/共享文件逐字对照。新增4项commonTest覆盖混合格位稳定键、跨卡handle切换仍按逻辑身份继承展开、过期展开ID清理、筛选只剩一张时保留保护与跨卡元数据。Android既有连拍/边框/状态测试仍测试同一共享实现。
- 首轮完整构建为BUILD SUCCESSFUL in 4m 20s；统一常量与4项新增测试后的最终版本为423 shared+312 app=735项测试0失败/错误/跳过，common metadata/Android Debug+Release编译/双模块Lint BUILD SUCCESSFUL in 3m 10s。app Lint仍0 errors/180 warnings/12 hints，shared无issue；两种合并Manifest摘要与第九批相同。未改Android协议/ViewModel/服务/GPS/打包脚本/版本，未打APK或提交推送。Swift文件未增加；28个App Swift、89个XCTest及2项iOS位图测试仍全部待Mac，结构检查PASS仅说明工程登记完整。
- 下一步：Native目录页面接线应复用CameraCatalog真实扫描与当前唯一queueObserver，不能另外竞争AsyncStream消息；目录快照要隔离连接代与扫描序号，失败/不完整扫描不能误清已有列表或自动判定删除。使用shared filterCameraFiles/groupCameraFilesByDate/detectCameraBurstGroups，不另写Swift规则。现Release产品导航/筛选选择/预览/效果/遥控/GPS/存储恢复/权益仍未完成，不是Windows100%。

## 第十七批记录：iOS真实目录接入原网格（Windows约54%）

- Debug持续连接新增“打开共享文件浏览（真实目录）”；使用SharedUiController.originalFiles→NativeOriginalFilesPage→原SharedThumbnailGrid，而不是第二套SwiftUI网格。入口不再依赖queueSnapshot非空，无待传任务也能打开。初次进入及刷新调用真实CameraCatalog全量扫描，不用诊断页的前20行样本。
- NativeFilesPageModel只接目录页状态/平台命令，并引用既有NativeQueuePageModel。CameraHandshakeProbe原有唯一queueObserver向文件页转发，同一Compose控制器可切共享队列正文再返回；没有第二个队列消费者/执行器。连接owner结束时关闭页面；页面退出只取消本页扫描/图像/未执行命令，不停止已启动传输。
- scanSequence由页面单调分配、connectionId绑定相机代次；拒绝重复/迟到扫描、错误连接、重复handle、空名字和断线后结果。只有metadataComplete且扫描期间无事件竞争才替换列表；失败/部分元数据/目录变化保留旧列表并提示刷新，不将不完整扫描用于删除判断。发布复制builder集合，UI不观察actor持有的可变扫描对象。
- 目录分组/排序/连拍全部调用现有groupCameraFilesByDate/detectCameraBurstGroups/reconciledExpandedBurstIds。默认3列、不合并连拍、轻触传输，关闭连拍合并按原设置语义清掉展开记录。完整选择/筛选、持久设置仍未接入，不能将临时列数和连拍开关当完整设置页面。
- 单张/日期整组/连拍整组入队带当前scanSequence；先核对每个选择仍属于该快照，然后在现有CameraOriginalQueue actor一次接纳该批，按传入顺序建立任务、发布一次并按原shouldRunQueueAfterEnqueue决定启动。使用Android默认日期整理false/延后启动false，保存到既有沙盒。已取消且尚未进入actor的请求拒绝；已接纳任务不因关闭页面回滚。
- NativeOriginalTransferQueue提取已有任务构造为单一私有入口，新增enqueueCatalog检查handle/name/size/date/protection与ObjectInfo匹配，再保留目录合并后的storageIds。旧单文件入口仍走同一构造和目的目录规则；手动重复导出语义不改。批量回传实际接纳数量，部分接纳提示先查看队列；先发布actor操作后快照再确认，不假装异步提交就是成功。
- 可见缩略图仍走CameraPreviewStore同键合并/共享PTP事务，ImageIO在后台actor方向归一化并限最长512px，PNG桥接限4MiB；队列保留128px/1MiB，两种规格复用同一编码方法。页面解码缓存上限32MiB/128项，按完整文件身份隔离，离开释放；瞬态忙至多8次有界延迟重试。尚未复刻Android裁黑边/视频兜底与全部后台填充策略，不能声称图像完全等价已验收。
- 原网格文字从Android三语言表生成并逐字检查；容器的刷新/队列/临时接线及错误提示独立标注。页内一直显示“完整预览、筛选和设置尚未接入”，长按明确提示预览待接，不偷偷以另一套系统预览代替原PhotoPreview。既有原片文件索引仍未接，isTransferred=false不是“已传输”功能完成；顶部也尚未包含原入队飞行/提示/触感完整工作区。
- 新增7项commonTest验证目录分组/元数据及builder隔离、失败/部分/事件竞争保留、扫描序号/重复/断线、真实入队确认/部分接纳、旧行与重复选择、关闭/迟到回调、图片上限/重试；现有队列测试新增1项检验双卡归属、无效元数据不耗ID及先后顺序。首轮完整构建BUILD SUCCESSFUL in 4m 1s；补交互反馈后的最终版本为431 shared+312 app=743项测试0失败/错误/跳过，common metadata/Android Debug+Release编译/双模块Lint BUILD SUCCESSFUL in 3m 11s。app Lint仍0 errors/180 warnings/12 hints，shared无issue；Debug/Release合并Manifest摘要仍为第九批值。
- 新增3个XCTest：真实文件UIKit控制器不启动空队列/不写文件、重复目录/过期入队安全拒绝、批量順序/延后启动/取消前未执行不入队；扩展ImageIO方向/尺寸断言覆盖网格PNG。现在29个App Swift、92个XCTest和2项iOS位图Native测试均待Mac，不能用结构检查冒充编译。50项脚本检查及整页/网格/触感来源对照PASS；单观察者/空队列入口/原默认值有专门静态检查。
- 未修改Android页面或业务控制层、协议/服务/GPS、打包脚本、版本及Gradle依赖；没有APK、提交或推送。接线只推进iOS原片路径，不包含效果/权益/自动事件/断点恢复，也不是Release正式首页完成。
- 下一步：共享原筛选/日期选择及预览部件，再接完整目录工作区、已有文件索引和设置。优先复用原PhotoPreview及预览快照策略，不把此临时浏览容器扩成一份永久的简化产品UI。继续其余N/D/U/R/G/E/L任务；Mac待验不会成为Windows源码工作的停止条件。

## 第十八批记录：完整原筛选、日期编辑与弹层共享（Windows约55%）

- 将原FilterOverlay、DateRangeEditor、DateEndpointWheels、筛选胶囊/分隔/清除及“未传”图形整体迁入SharedFilterOverlay；不是第二套SwiftUI筛选页。安卓原FileListScreen协调器、筛选持久化、文件过滤/存储卡归并、缩略图优先范围与所有调用点不变，仅FilterOverlay薄包装转换同一组字段。
- 原360dp面板/12dp屏边距/8dp按钮间距、150/100ms切换、38dp胶囊、50dp松手提交拨轮及全部布局数值保留。类型全不选/凑齐全部归位null、标记AND叠加、双卡切换继续原逻辑；外部current改变重置工作草稿，日期编辑进入仅快照一次，拨动不提交，清除/完成才提交，开始与结束越界时同步另一端。
- 原AnchorPopup完整绘制/开合/关闭防重入/下一帧入场/遮罩手势拦截迁入SharedAnchorPopup，安卓AnchorPopup为原签名薄包装，SettingsScreen所有调用不变；Android BackHandler仍登记同一关闭回调。共享组件默认不登记平台返回键，iOS宿主后续按平台能力接入，不伪造硬件返回键。
- 边界只包含日历操作、原位置文字读取、实际屏宽和返回键；没有新模块、服务层或第二份ViewModel。FilterCalendar允许Android继续用原LocalDate/YearMonth/PhotoDateRange及原裁月末和摘要方法，未将Android改为新日期算法；接口、泛型界面值和共享绘制函数均HiddenFromObjC，只给Kotlin UI用。日历适配仅内部可见，便于直接测试，不扩大Swift接口。
- NativeFilterCalendar使用现有CaptureDayRange/captureDayKey/compactCaptureDayRangeLabel，月天数直接复用共享日期校验而不复制闰年规则；相机日期是yyyyMMdd，不经UTC/epoch换算。今日值由宿主延迟提供，仍待真实Apple本地Gregorian日期接线。NativeFilterTextCatalog按Android三语言21项原文生成，保留卡槽占位和语言回退；这是准备完成，不是iOS筛选已可用。
- 新增6项shared测试覆盖日期/范围、月末与世纪闰年、边界标签/无日期、非法值、跨日今日读取、三语言/占位回退；新增4项Android测试通过真实泛型接口核对旧Java日历（11组年份×12个月）、默认参数、范围访问、标签与本地今日。首个新增测试因表达式返回异常对象被JUnit拒绝初始化，已明确Unit并重跑通过；不是产品功能失败，不隐去该轮失败。
- 新增8项脚本检查：完整Android及shared文件按55876fa显式转换逐字对照，原整个FileListScreen协调器和日期helper一致，草稿/归一化/提交、完整弹层正文/返回回调、数值/输入改动能检出、common无Android API、三语言文案及枚举顺序覆盖。累计58项脚本PASS，437 shared+316 app=753项单元测试0失败/错误/跳过。修正测试签名后的最终common metadata、Android Debug/Release编译与双模块Lint为BUILD SUCCESSFUL in 2m 13s（112 tasks，8 executed/104 up-to-date）；app Lint 0 errors/179 warnings/12 hints，shared无issue。
- Debug/Release合并Manifest SHA256仍为第九批值。未改MainActivity、Android ViewModel/协议/服务/GPS、dist/dist-debug、版本或Gradle依赖；未打包、提交或推送。Android UI从app转入shared涉及组合边界变化，源码和单测不能替代实际截图、手势/帧率验证。Java日历成员扩展有预期shadow提示，直接泛型调用测试已覆盖，不修改原Java行为消除提示。
- 29个App Swift、92个XCTest和2个iOS位图Native测试仍全部待Mac。原片文件页仍明确显示预览/筛选/设置接线未完成；本批没有把“未传”筛选绑到恒空索引，也没有把单一队列历史当持久已保存索引。完整iOS产品页面尚未完成，非Windows100%。
- 下一步先补真实原片已有文件索引（CameraOriginalStore沙盒原片根目录及日期桶，复用ExistingFileNameIndexCore/transferDirectoryLookupKey/matchesExistingFileSize；平台IO与增量revision单owner），再把原筛选、日期优先范围和设置偏好接入Native文件工作区。索引扫描失败不得误清旧数据，不把临时文件/派生图误认原片；核对Android根/日期桶与未知大小语义。继续原PhotoPreview/完整工作区及其余N/D/U/R/G/E/L任务。

## 第十九批记录：真实沙盒原片索引与网格已保存状态（Windows约57%）

- CameraOriginalStore持有OriginalFileIndexCache，沿用既有store actor单owner；没有新增服务、数据库、第二个队列执行器或AsyncStream消费者。读取真实Originals根目录及shared isDatedTransferFolderName认可的一层日期桶，不扫描相框/效果目录或更深层目录；日期桶仍是原shape-only判断，未趁机排除ZT2026-99-99这类旧规则认可的名字。
- 平台只提供真实名称/字节数/桶/本地URL。NativeOriginalFileIndex调用ExistingFileNameIndexCore、transferDestinationLookupKey及其底层transferDirectoryLookupKey/matchesExistingFileSize；大小写、拷贝后缀、未知相机大小、根与日期桶隔离继续共享同一内核，不写Swift匹配算法。Native当前默认按天保存false，徽标查询根桶，与实际入队目的地一致；按日期保存偏好仍待S05接线。
- 索引首次/手动刷新全量扫描，只有全扫描成功才替换；缺失根目录确认后可发布空索引，但不为索引扫描创建目录。读取失败/非法根/属性缺失/取消保留上次结果，页面独立三语言提示，不混作相机目录扫描失败。完整后续扫描可反映真实文件删除；不影响Android现有扫描/缓存逻辑。
- 仅排除应用自己的.nkpart_及实际.UUID_.nkpart_临时文件，不把所有点开头文件一刀切排除；合法.HIDDEN.JPG也可索引。先读取链接自身属性再读取文件属性，跳过含断链在内的符号链接，不跟随根链接或任意目录链接；断开的根链接不误作缺失根目录。规范化路径还必须落在固定根边界内。读取的只是目录元数据，不读取原片内容、不删除任何文件。
- 真实下载必须完成长度验证、fsync/关闭和无覆盖move后才record；原片数据仍由同一SandboxTransferFile保存。队列仅在保存完成后递增completedOriginalRevision，200ms进度/暂停/清理不递增。文件页经现有唯一queueObserver感知此计数，再从既有store拿增量；不是对每帧进度重扫整库。
- store保留最多1024条变更日志，落后的页面改取完整快照；不重写一份跨进程索引数据库，重新打开store可从真实文件重建。共享发布有baseRevision/单调revision与整批合法性校验，同版本完整快照重放、迟到/错base或无版本变化却携带新条目的结果拒绝；builder后续修改不会改变已发布索引。清空任务历史只清队列映射，磁盘文件与store索引保留。
- NativeFilesPageModel新增独立低频originals状态，原网格isTransferred不再固定false，使用文件身份和索引revision作为remember键。页面退出释放自身Kotlin索引并取消索引读取；不停止已启动的相机传输或删除store文件。索引回调使用原MainActor边界，不增加另一个相机观察者。
- 新增5项shared索引测试、2项真实页面状态测试；覆盖复制后缀/大小写/大小/未知大小、日期桶、增量顺序/原子拒绝、重放、builder隔离、完整扫描删除、日期shape、失败/关闭保留与队列历史独立。62项脚本检查PASS（新增原片索引3项接线守卫与三语言独立失败提示1项）；444 shared+316 app=760项测试0失败/错误/跳过。最终common metadata、Android Debug/Release编译及双模块Lint BUILD SUCCESSFUL in 3m 40s（112 tasks，34 executed/78 up-to-date）；app Lint 0 errors/179 warnings/12 hints，shared无issue。
- 新增5项XCTest（未运行）：真实目录/日期桶/私有临时文件与合法点文件/符号链接、扫描失败保留与真实移除、真实模拟相机下载后增量和重新建store、1024日志溢出回退、取消扫描保留；扩展原FIFO真实模拟传输用例，检查完成计数、清空任务后原片索引不变。现30个App Swift、97个XCTest及2项iOS位图Native测试全部仍待Mac编译/执行；结构检查PASS不等于这些IO用例已通过。
- Android业务/UI文件、Gradle依赖、版本、dist/dist-debug本批均未改；Android完整原界面/触感源码守卫PASS，Debug/Release合并Manifest摘要仍与第九批一致。未打包、提交或推送。本批不是Files provider索引、PhotoKit读库、断点恢复或完整预览/筛选已完成。
- 下一步接原SharedFilterOverlay到真实目录结果，补catalog原始storageIDs（不能只从有照片的卡推导空卡）、共享filterCameraFiles/日期/连拍/已传判定、原600ms筛选重排窗口与日期优先读取。真实已保存标记与“未传输”筛选必须共用当前索引和日期整理规则；初次索引未就绪/失败时不得误当全部未传。继续原PhotoPreview、完整工作区和其余未完N/D/U/R/G/E/L任务。


## 第二十批记录：真实筛选接线与原未传输退场（Windows约60%）

- Native文件页使用原SharedFilterOverlay及现有filterCameraFiles：类型、保护、连拍、未传输、卡槽与日期组合按Android同一字段映射；连拍身份来自未过滤完整目录，筛选后只剩一张仍保留身份。原始storageIDs由真实catalog传入，空第二卡仍可选且结果为空，不从照片反推卡列表；只有完整扫描成功才归一化失效卡槽。
- 未传输筛选与已保存徽标查询同一个NativeOriginalFileIndex；首次索引未就绪禁用未传输选项并显示独立提示，不将未知状态冒充空索引。后续索引读取失败保留旧结果。SharedFilterOverlay新增enabled边界默认true，Android原调用保持原值；其余筛选无需等待索引。
- 原FileListScreen未传输完成退场协调器整体迁入rememberExportExitState，Android薄调用与Native共用。历史文件同步隐藏、当前完成任务保留单格退场、原remember/Effect键与320ms重排未改；整个Android文件与共享正文仍按55876fa显式转换逐字检查。Native显示队列时卸载文件页退场状态，返回后历史完成项不会重播退场。
- Native筛选变更与600ms展开窗口同步设置，比较实时criteria而不是上一帧捕获值；清空会关闭日期草稿。日历使用Apple宿主真实本地Gregorian日期，相机拍摄日期仍为原yyyyMMdd而非UTC换算。关闭页释放宿主后仅保留最后真实今日值供退场帧使用。
- 新增7项common测试：192组筛选组合、空卡/不存在卡、完整目录连拍、快速改筛选/集合复制、完整与部分扫描卡槽处理、索引门控/同源徽标、关闭释放。451 shared+316 app=767项测试0失败/错误/跳过。68项脚本PASS，新增完整退场抽取/数值变更检出及本地日期/空卡接线守卫。common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 32s；app Lint 0 errors/179 warnings/11 hints，shared无issue。
- 新增2项XCTest源码：跨时区真实Gregorian日、真实空第二卡与空原片目录共享控制器；现30个App Swift、99个XCTest和2项iOS位图Native测试全部仍待Mac，未声称运行通过。Debug/Release合并Manifest摘要不变；本批只对Android列表退场作共享薄接线，业务、服务、协议、GPS、打包脚本、依赖和版本未改。未打包、提交或推送。
- 尚未接持久浏览偏好、原后台缩略图填充/日期优先队列、完整PhotoPreview、原顶栏/导航/队列飞行等工作区；临时宿主不是完整成品页面。下一步补偏好保存恢复，再继续原工作区及其余任务，不能将可见网格读取当后台填充已完成。


## 第二十一批记录：浏览偏好保存恢复（Windows约62%）

- NativeBrowsePreferences是小型平台边界，列数调用现有normalizeThumbnailColumns，日期恢复调用CaptureDayRange.between的校验/端点归序；不新增依赖、序列化框架或第二套过滤算法。Swift BrowsePreferencesStore只保存应用私有UserDefaults中的一个版本化值（schema 1），不夹带身份、书签、任务或凭据。
- 保存列数、连拍合并、类型/保护/连拍/未传输/日期筛选；卡槽不落盘，清空筛选原子清掉全部持久筛选但保留布局。输入列表复制，null与显式空类型集不混淆。当前Native卡槽仍随页面/连接代次，未来完整工作区接入时需补Android进程内跨页生命周期对照，不能宣称该点已完全等价。
- 核对TransferViewModel实际prefs恢复发现：启动后的连拍合并默认true（瞬时TransferUiState为false），列数限2～4。Native此前临时宿主false/1～4现在改为真实恢复默认与共享归一化；Android没有改。纠正此前批次将临时值称作原默认的表述，不借此改变Android行为。
- NativeFilesPageModel启动读取、状态更新与偏好写入同在UI线程，关页不落盘清空值。读写失败独立三语言提示，本页仍可操作；损坏、类型错误、超过64KiB和未来schema保留原存储数据，不自动重置。UserDefaults回读确认仅表示默认值存储接纳，不声称同步fsync或保证突然断电持久性。
- 恢复“未传输”true时保留真实选择，但索引未就绪不展示误判为全部未传的网格；可以清空筛选，索引失败保持提示。原退场协调器等索引就绪才启用，首个真实快照中的历史完成项直接过滤，不重播旧传输动画。新手动开启仍需真实索引，Android默认可用性不变。
- 本批所用UserDefaults按Apple应用自身数据用途声明CA92.1，并将PrivacyInfo.xcprivacy登记到app Resources。依据[Apple所需理由API文档](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)；这里只补本批偏好API声明，不代替发布前完整依赖/文件元数据等隐私审计。
- 新增7项common测试（默认/列数/日期/集合、恢复索引等待、布局与筛选完整快照、卡槽不落盘、错误保护、关闭不写）；458 shared+316 app=774项0失败/错误/跳过。72项辅助脚本PASS（新增4项偏好/默认/门控/资源检查）；Android原UI完整抽取/三语言/触感和Xcode结构守卫PASS。
- 首轮编译33s失败：误用了原日期文件私有校验函数；已改走公开CaptureDayRange入口，没有扩大原内核可见性。一个旧接线字符串断言未含新增索引就绪门控，已按明确的新Native条件更新，Android对照条件未放宽。最终common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 10s（112 tasks，34 executed/78 up-to-date）。app Lint 0 errors/179 warnings/11 hints，shared无issue。
- 新增3项XCTest源码，覆盖独立UserDefaults测试域的无写入默认读取/重开恢复、损坏/未来版本/错误类型/过大数据保护、空类型与非法日期；31个App Swift、102个XCTest及2项iOS位图Native测试仍全部待Mac编译/执行。Windows结构检查不是Apple运行通过。本批不修改Android UI/业务、Gradle依赖、Manifest、版本和打包脚本；Debug/Release合并Manifest摘要与前批一致，无遗留Gradle进程，未打包、提交或推送。
- 下一步：完整按日期整理/延后开始等设置仍未接，实际写入与徽标仍共同使用根桶；继续原后台缩略图填充/日期优先调度、原PhotoPreview及完整工作区。tapToPreview固定false仍是未接预览入口，不能把本批局部偏好当完整设置页完成，更不是Windows100%。


## 第二十二批记录：真实缩略图磁盘缓存（Windows约64%）

- 为后台全库填充补真正可复用的磁盘结果，避免仅反复冲刷32MiB内存缓存。CameraThumbnailDiskCache由现有CameraPreviewStore actor独占，网格/队列/诊断预览都经过原thumbnail读取入口；没有新增相机会话、消费者、数据库或额外缓存actor。关闭页面不销毁连接级缓存。
- NativePreviewPolicy新增薄方法调用原cameraThumbnailCacheIdentity/normalizedCameraIdentifier/thumbnailCacheKeyMaterial/isThumbnailCameraCacheExpired。AP复用现成DeviceInfo序列号，STA复用已收到的responder GUID，保持序列号优先；没有新增相机命令。无有效机身标识时用连接UUID限定缓存桶，不将不同未知机身永久混到unknown-device桶；因此未知机身重连不承诺命中。标准STA依旧存储成功直接返回，仅原失败回退读取DeviceInfo。
- 文件在应用Caches/ZTransferThumbs/camera_SHA256中，键为原名称/NUL/大小/NUL/日期的SHA256；不将handle或用户文件名直接用于路径。只缓存GetThumb真实字节，FHD和确认无缩略图的nil不落盘；元数据身份不完整也不落盘。缓存扩展名.jpg是缓存命名约定，内容保持相机原编码，不代替后续Android裁黑边/压缩语义对照。
- 单个缓存读写最多4MiB，读循环有界，ImageIO最多512px解码验证；坏/空图片不写入，损坏缓存移除后重新从相机读取。独占UUID.tmp写完检查长度后move，不覆盖现有完整命中；缓存无需冒充原片fsync保证。系统清理Caches后重新创建且不保留陈旧文件索引；长存URL每次清除资源属性缓存再查链接/文件属性。
- 根目录/机身目录/条目逐级验证真实目录与普通文件，先查符号链接（含断链），不跟随链接。过期依据shared严格超过90天规则，当前机身不清理；只处理命名受控且全为已知普通缓存文件的直系相机目录，未知文件、子目录或链接保留，不递归删除任意内容。只会删除派生缓存，不接触Originals/Files provider或用户原片；iOS没有Android历史扁平缓存，不编造其迁移路径。
- 现有CameraCatalog在完整且无事件竞争扫描后直接调用同一previews.reconcile，无新增消息流。复核连接代和每行真实ObjectInfo后才建立有效键集/清理孤立图片；不完整、事件竞争、错误连接不清理。内存及磁盘发布都检查有效身份，旧请求迟到不能写回已移除对象。连接退出路径await previews.close后才释放running门控，重连不能复用旧owner写回；不会在该方法中取消共享PTP事务，仍由原连接owner关闭套接字。
- 磁盘配置/写入不可用时仍允许可见项内存读取，Debug连接状态明确说明仅内存缓存，diskWritesBlocked给后续后台填充停机使用。资源新增应用容器文件元数据C617.1理由声明（[Apple文档](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)）；完整发布隐私审计仍未完成。
- 新增3项shared测试验证序列号/GUID/占位/连接隔离和90天严格边界；461 shared+316 app=777项0失败/错误/跳过。76项辅助脚本PASS，原UI/三语言/触感源码守卫与结构检查PASS；新源码检查最初将DeviceInfo次数误写1，复查确认既有AP和STA存储失败回退共2处，已明确断言存储成功在第2处前返回，不宽松掩盖新增查询。
- common metadata、Android Debug/Release编译及双模块Lint BUILD SUCCESSFUL in 4m 29s（112 tasks，34 executed/78 up-to-date）；app Lint 0 errors/179 warnings/11 hints，shared无issue，Debug/Release合并Manifest摘要不变。本批未改Android UI/业务、Gradle依赖、版本和dist/dist-debug；未打包、提交或推送。
- 新增8项XCTest源码：真实有效图像/多机身/重开缓存、坏图与长度限制、根/条目/断链保护、90天/未知文件/系统清缓存、内存释放后磁盘命中、部分/事件/错连接拒绝清理、扫描后迟到写回拒绝、旧连接owner关闭后禁止写入重连目录。32个App Swift、110个XCTest和2项iOS位图Native测试仍全部待Mac编译/执行；这些IO/ImageIO场景未在Windows运行，不能算运行通过。
- 下一步接真正的ThumbnailFillQueue：连接级而非页面级，完整扫描后按新到旧/日期范围补漏；传输（含等待）、交互FHD/遥控/效果预览让路，失败仅真实状态变化重试，磁盘写不可用停止。还须补扫描批次填充、裁黑边/STA-direct MPF/RAW/视频和原PhotoPreview/完整工作区。本批只完成填充必需的磁盘层，未把缓存接线当全量后台调度完成。


## 第二十三批记录：连接级后台填充与通道准入（Windows约67%）

- NativeThumbnailFillQueue只薄接原ThumbnailFillQueue：排序、优先队列、失败重试及回队仍调用原内核，Swift不抄算法。完整目录原子校验/复制，旧请求用对象身份与revision拒绝迟到结算；重扫重新核对磁盘，系统清Caches后不把内存“已完成”当落盘证明。
- 同一CameraPreviewStore连接级唯一worker，真实握手启用、关页不停止；扫描代次拒绝旧完成，扫描中/失败/部分或事件竞争快照不恢复填充。当前只完成完整扫描后的补图，扫描批次交错填充仍待接。日期来自同一浏览偏好、递增更新号拒绝迟到Task；范围不变不触发重试。
- 核对Android MainActivity实际门控为transferState.isTransferring，纠正上一批“传输（含等待）”的过宽表述：延后/暂停的等待项不独立阻挡填充。iOS仍只有一个queue.updates消费者，转发snapshot.running；前台FHD/诊断下载使用成对占用令牌，多个占用全部退出才能恢复。
- 后台在原完整事务FIFO拿锁后再次检查ready/downloadActive及worker门控；拒绝在TID/发包前且位于终止连接catch之外，不消耗事务号、不关连接。已发出的单张正常排空后让路，不中途取消，不能承诺零延迟硬打断。完整PhotoPreview/遥控/效果页仍待接整页占用，现有请求级门控不冒充全页面完成。
- 无空闲重试定时器；失败等真实连接/执行态/前台占用/日期/完整目录变化唤醒，worker收尾比较唤醒号避免丢恢复。无磁盘或写失败停止后台，不只冲刷内存；当前项保留，手动完整重扫可恢复，可见项仍能读取。
- 新增7项common测试覆盖原排序/范围、处理中变更、真实重试、回队/重复完成、扫描换代、非法快照原子拒绝/复制和伪造请求/清空。468 shared+316 app=784项0失败/错误/跳过；80项辅助脚本PASS，原UI/三语言/触感整段守卫及结构检查PASS。
- common metadata、Android Debug/Release编译、双模块Lint BUILD SUCCESSFUL in 3m 16s（112 tasks，34 executed/78 up-to-date）；app Lint 0 errors/179 warnings/11 hints，shared无issue。Debug/Release合并Manifest摘要不变；Android业务/协议/ViewModel/服务/GPS及dist/dist-debug与55876fa无差异。本批不改Android UI/依赖/版本，未打包、提交或推送。
- 新增10项XCTest源码：唯一worker与落盘、内存释放后命中、多占用/传输门控、失败不空转、排空后恢复、扫描换代/部分拒绝、磁盘失败/重扫恢复、无磁盘无投机、日期迟到拒绝、空闲与排队后的准入/TID验证。32个App Swift、120个XCTest及2项iOS位图Native测试全部待Mac编译/执行；Windows结构通过不是Apple并发/IO用例通过。
- 下一步：扫描批次填充、裁黑边/STA-direct MPF/RAW/视频、原照片预览和完整工作区，以及其余N/D/U/R/G/E/L任务。保留Mac编译、双端截图/手势/性能与相机真机门槛，67%仅为Windows可做工作粗估。


## 第二十四批记录：原单图预览/缩放/旋转共享（Windows约69%）

- 完整SinglePhotoPreviewOverlay、ZoomablePreviewViewport和旋转按钮迁入shared；Android单图入口与完整PhotoPreview列表都调用同一个共享viewport。PhotoPreview剩余分页/高清/本地原片/EXIF/入队协调器保持原位，未重写SwiftUI手势或另设页面架构。旋转按钮仍在原Icon组合位置读取Android stringResource，硬件返回仍调用BackHandler。
- 保留remember/stateKey、当前页离开/旋转重置、1.01缩放判定、至少双指或已放大才消费、原触点锚定/拖动限位、最大4倍与1:1像素上限取大、双击2.5倍、220ms旋转/240ms缩放、横图旋转8%留白。单图原锚点变换/遮罩0.74/展开关闭动画/穿透阻断和每次逆时针90度不改。Math.toRadians保留Android原intrinsic，Native使用弧度换算；跨端浮点/手势/绘制实际观感仍待真机。
- 新增显式抽取脚本，对完整Android剩余PhotoPreview文件、Android旋转包装及三个共享正文逐字检查；不归一化数字或手势键。新增6项脚本测试，含timing/手势阈值变异、原Back/文本/Math接线和唯一Native组件。固定常量变异会被抽取入口直接拒绝，测试明确接受这种失败，不放宽迁移对照。
- SharedUiController新增真实单图入口，复用ImageIO已归一化图片；原相机/滤镜探针可打开同一共享组件。单次NSData批量复制，不逐像素/逐字节跨ObjC调用；PNG先验签名/IHDR及无符号宽高，最大2048边/20MiB，再由Skia实际解码。bitmap在控制器创建时冻结，不因后续照片/滤镜发布重置缩放。编码在现有ImageIO actor中，内存警告/切后台关闭探针并释放PNG；不加网络请求/缓存owner。
- 该入口只用于真实图片手势验收：没有Android硬件返回，原点击关闭及系统sheet退出可用；无锚点走原淡入分支，旋转无障碍暂用原英文默认。它不是完整产品PhotoPreview，2048诊断源不冒充原尺寸本地预览；完整会话前台占用、分页/连拍/EXIF/直方图/入队飞行/返回定位仍待原协调器迁入。
- 新增2项common测试验证PNG签名/截断/容量/无符号尺寸在解码前拒绝；470 shared+316 app=786项0失败/错误/跳过。86项脚本PASS；完整原UI/触感/三语言及新增照片手势源码守卫PASS，Xcode登记PASS。common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 41s（112 tasks，38 executed/74 up-to-date）。app Lint 0 errors/179 warnings/11 hints，shared无issue。
- 新增2项XCTest源码验证真实规范PNG→共享控制器、非法/超大输入拒绝、尺寸编码回读与超限图片拒绝；现32个App Swift、122个XCTest及2项iOS位图Native测试全部待Mac编译/执行。不能将源码对照或工厂创建测试当截图/手势/内存性能已验证。
- Debug/Release合并Manifest摘要不变，无遗留Gradle进程；本批仅Android UI作薄接线，MainActivity/ViewModel/协议/服务/GPS/打包脚本与55876fa无差异，依赖/版本未改，未打包/提交/推送。下一步迁完整PhotoPreview分页模型与协调器：本地来源须在overlay打开时冻结、逐页高清/EXIF和邻页预取/取消保留原顺序，ImageBitmap/URI/直方图/日历与时钟只拆窄平台边界；不能跳过连拍/入队飞行/返回定位来宣称预览完成。


## 第二十五批记录：原预览分页与会话规则共享（Windows约70%）

- SharedPhotoPreviewModel承载原PhotoPreviewItem/两种路由与手势枚举、合集展开/收起/返回定位、来源快照、本地来源是否已解析、上滑方向/阻尼及远程缩略图兜底条件。函数正文不重写，仅公共可见性/隐藏ObjC UI符号；Android原PhotoPreview直接引用，未新建Native第二套分页模型或协调器。
- 合集保留独立页和稳定key，只有主动展开才在其后插入成员；重复展开返回同一个列表，收起只移除目标burst成员。全部成员的本地来源在overlay打开时一起读取并冻结，后续传输完成不热换本次正在显示的图。原遍历次序/重复handle后写覆盖/显式null保留，没有借迁移去重或调整老规则。
- 原上滑临界值1.15、触摸slop比较、横向/下滑放行、超阈值0.22阻尼与1.24上限完全保留；缩略图兜底仍是当前页且FHD不可用且EXIF已结束三个条件同时成立。布局/飞行动画、真实IO/取消/高清及EXIF读取协调器未改。
- Android localOriginalPreviewRoute仍使用原CameraViewModel的RAW/TIFF集合；Java日期/时间校验、原formatFileSize与本地化、Uri/ContentResolver/位图读取保留平台侧。没有为迁移更改Android业务常量或用另一套日期校验替代现有行为；这些边界在完整预览抽取时再按原调用点接入。
- 原9项测试迁commonTest（分页/快照4、上滑意图3、读取门控2），只转换JUnit导入和测试类名；Android保留原日期/大小、RAW/TIFF路由、网格门控及飞行弧线测试。新增4项common边界测试：0/1/3/16/100成员、重复来源调用顺序/显式null、精确slop/对角阈值和8种兜底条件。483 shared+307 app=790项零失败/错误/跳过；app数量下降是9项搬迁，不是删测试。
- 新增5项辅助检查，91项PASS；完整原PhotoPreview剩余正文、共享模型及全部迁移/保留测试逐字对照，排序/阈值/条件变异可检出。common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 50s（112 tasks，38 executed/74 up-to-date）；app Lint 0 errors/179 warnings/11 hints，shared无issue。
- 两种合并Manifest摘要不变，无遗留Gradle进程；MainActivity/ViewModel/协议/服务/GPS/打包脚本与55876fa无差异，依赖/版本不改，未打APK。本批没有新增Apple实现或XCTest：32个App Swift、122项XCTest和2项iOS位图Native测试仍待Mac；迁入的common测试也须经Mac Native执行，不能用Android通过替代。
- 上一检查点37bcbe6已本地提交（未推送）；从本批起按验证完成的批次做本地提交，不再让多个大批次长期堆积。下一步完整PhotoPreview仍需逐项拆出相机状态/优先占用、缓存及FHD/EXIF、本地图片/来源标识、直方图、平台文本/日期/时钟等窄边界，保留分页预取/取消顺序、连拍/入队飞行/返回定位；本批共享模型不是完整iOS预览页面已接通。

## 第二十六批记录：原预览单页与展示组件共享（Windows约72%）

- SharedPhotoPreviewPage迁入原PreviewPage正文，SharedPhotoPreviewBurst迁入原合集页与三张堆叠，SharedPhotoPreviewDetails迁入原EXIF信息条/连拍导航/入队按钮。Android原私有入口保留签名并真实调用共享正文；只拆图片、组合时读取的语言文本、单调时钟与原连拍图片/徽标窄接口，不新增页面架构或第二套Native算法。
- FHD仍按SystemClock.uptimeMillis计算300ms渐显、16ms步进，原缩略图不透明垫底、无缩略图时高清立即显示。remember与加载Effect键、远程无图标记条件、视频禁缩放/占位/原元数据来源不改。Android图片接口直接调用原CameraViewModel缓存/读取，不增加网络查询或调度器。
- 连拍保留take(3).reversed顺序、角度/偏移/尺寸/点击与当前页缩放重置；入队飞行幽灵仍留原协调器并保持loadEnabled=false。EXIF保留原字段顺序、非零EV条件、细空格分隔及13/12/11字号选择；Android日期/视频格式化、URI、本地读取、高清/EXIF预取和优先占用仍在原位。
- 显式抽取链逐字比较55876fa的原正文和Android完整剩余文件，仅列举必要的边界替换；新增7项脚本用例覆盖原协调器不变、渐显/读取键/连拍/EXIF与常量及条件变异。98项Python检查、原UI迁移守卫和工程结构检查通过。
- 483 shared+307 app=790项零失败/错误/跳过；common metadata、Android Debug/Release编译与双模块Lint最终BUILD SUCCESSFUL in 3m 6s（112 tasks，36 executed/76 up-to-date）。首轮发现新增组合接口命名警告，改为Photo/Badge后重跑，未添加抑制；最终app Lint仍0 errors/179 warnings/11 hints，shared无issue。
- MainActivity/ViewModel/协议/服务/GPS和dist/dist-debug与55876fa无差异，依赖/版本未改，未打APK。本批无新增Swift/XCTest：32个App Swift、122项XCTest、2项iOS位图Native测试仍待Mac编译/执行，Windows回归不等于Apple绘制/手势通过。
- 按用户要求随本批本地提交新增《无卡紧急直存手机可行性调研.md》，原文不改，仅纳入文档，不实施其提出的新功能；原Markdown硬换行与末尾空行保留。上一批ce2f8c0已本地提交，本批不推送。
- 下一步仍是完整PhotoPreview协调器及Native真实接线：逐页高清/EXIF、本地来源冻结、邻页预取/取消、直方图、优先占用、连拍返回与入队飞行必须继续保留原流程。此次展示组件共享不代表完整iOS预览已完成；Windows任务继续开放，不能标100%。

## 第二十七批记录：原直方图分析与展示共享（Windows约73%）

- LuminanceHistogram及原统计正文迁入commonMain；唯一读像素边界是同步readRow，Android原Bitmap入口仍调用getPixels，同一行数组/同一stride/同一抽样坐标，不新增解码、线程或缓存。统计保持24_000目标密度、ceil(sqrt(...))步长、Rec.709整数权重54/183/19和按峰值线性归一化。原注释误称RGB/log已按实际算法纠正，算法没有改。
- 原HistogramOverlay、HistogramMark和PreviewHistogramButton正文共享，Android预览及遥控实际复用；保留118×62布局、透明度/圆角/路径描边/五根竖条高度/44dp按钮和原组合位置读取无障碍文本。RemoteViewfinderFeatures其余网格/AF/斑马代码逐字保留，完整RemoteScreen和PhotoPreview协调器不改；250ms遥控节流、预览produceState键/视频门控与后台线程不改。
- calculateImageLuminanceHistogram提供已解码ImageBitmap逐行读取的共用入口，供Native完整预览继续接线，不逐像素跨Swift/Kotlin，不再次解JPEG。没有把该入口存在误记为完整Native预览已接通；真实Skia颜色/行起点/stride仍须Mac验收。
- 新增8项common测试：黑白及三原色bin、线性峰值、全灰阶/alpha不参与亮度、24k精确边界、单行缓冲复用/抽样行、单像素及原维度钳制、读取异常原样传播、VGA/XGA/奇数边/6000×4000模式图。测试专用oracle冻结55876fa原算法正文，只替换Bitmap测试载体；生产没有第二份算法。491 shared+307 app=798项零失败/错误/跳过。
- 新增7项Python检查，105项PASS；显式源码对照覆盖整个剩余预览/遥控正文、共享统计/绘制/开关和测试oracle，修改权重/采样/几何/斑马常量可检出。工程结构通过；common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 34s（112 tasks，39 executed/73 up-to-date）；app Lint 0 errors/179 warnings/11 hints，shared无issue。
- 新增3项iOS Native位图测试源码：端点/三原色、201×121抽样行与stride、1像素与单列边界；与原2项纹理测试合计5项，全部未在Windows运行。32个App Swift/122个XCTest也仍待Mac编译/执行，不能将common metadata通过当成Apple运行通过。
- 两种合并Manifest摘要不变，构建结束后无java.exe遗留；MainActivity/ViewModel/协议/服务/GPS/打包脚本与55876fa无差异，依赖/版本未改，未打APK。本批检查后本地提交，不推送；上一批19eb7a9已纳入用户调研MD，本批未再修改它。
- 下一步完整预览迁入不能省略：原QueueFlightEasing/queueFlightBezierPoint唯一来源；原相机缓存/FHD/EXIF/交互优先和整页setFhdActive边界；本地URI以保留身份/相等语义的源标识适配，NEF/NRW内嵌JPEG与TIFF相机FHD路由不改；340ms延迟、当前页优先→EXIF→前后邻页、±2淘汰窗口及忙→闲恢复的原Effect键/取消顺序保持。完成协调器后再接Native实际目录/本地原片/解码/优先占用及页面状态，继续其余Windows功能，不宣称73%就是成品验收进度。

## 第二十八批记录：完整原分页预览协调器共享（Windows约76%）

- SharedPhotoPreviewOverlay迁入完整原PhotoPreviewOverlay正文及合集入队残影，不是另写简化分页器。Android入口保留原签名/默认值并实际调用共享实现，旧私有展示包装已移除；已迁组件直接复用。QueueFlightEasing/queueFlightBezierPoint从FileListScreen迁入唯一共享源，列表/单张/合集仍共用原弧线。
- PreviewSessionSource<Source>只划分真实调用点的图片/EXIF/相机优先窗口/前台占用/单调时钟边界；Source在Android仍是原Uri，不做字符串转换、重新归一化或复制来源算法。共享层持有原会话快照、页内状态与任务，Android仅保留ContentResolver/Dispatchers.IO/PhotoFrameExporter/CameraViewModel直接适配。语言资源在原组合位置读取，任务进度仍仅在原角标内部按生命周期订阅；BackHandler与原直方图Bitmap读取保持平台实现。
- 原顺序与条件保留：340ms独立延迟，不依赖展开动画返回；优先本地当前页→必要时交互窗口内相机FHD与当前EXIF→前后邻页；传输忙时不预读邻页相机但可读本地。主加载Effect不加入transfersBusy，忙→闲另行恢复；16ms等待已有任务、取消重新抛出/其他本地解码异常回退、finally清loading、±2即时淘汰、离线不永久记FHD失败和打开后传输完成不热换图都保留。
- 原上滑/连拍/关闭/飞行不删减：先真实入队确认再抬图，32ms残影预挂载、560ms原缓动与1000ms视觉超时；翻页清前页影子，合集影子loadEnabled=false只读缓存；先定位合集页再移除成员，原返回格定位在不透明幕之后。原旋转连续角度和正模保留，Android仍Math.floorMod/toRadians，Native只适配数学intrinsic。
- 新增6项common测试覆盖端点/越界进度、竖直向内弯曲、最大弧高/横向偏移淡出、顶部边界原向下控制点、反向轨迹/缓动端点、负旋转及整数极值正模；原Android飞行测试保留。497 shared+307 app=804项零失败/错误/跳过。
- 新增9项脚本检查，114项PASS；从55876fa逐步应用既有抽取再比对完整共享协调器与剩余Android适配，原接口默认值、来源身份、FHD/EXIF顺序、所有重要Effect键/占用/释放/入队确认/缓存幽灵及数值条件变异都有守卫。源码比对不替代双端重组、快速手势、帧时钟或相机真机验收。
- 首轮BUILD SUCCESSFUL in 3m 31s；复查将单图/合集残影的迁移注释归位后最终重跑：common metadata、Android Debug/Release编译及双模块Lint BUILD SUCCESSFUL in 3m 18s（112 tasks，34 executed/78 up-to-date）。app Lint仍0 errors/179 warnings/11 hints，shared无issue；两种合并Manifest摘要不变。MainActivity/ViewModel/协议/服务/GPS/打包脚本与55876fa无差异，依赖/版本未改，未打APK，按批本地提交不推送。
- 本批没有冒充Native页面完成：32个App Swift、122个XCTest及5项iOS位图Native测试仍待Mac编译/运行，新增common代码也待Native编译。NativeOriginalFilesPage的onPreview/onPreviewBurst目前仍为previewPending；真实相机读取/本地原片/优先占用与正式完整页面接线是下一批，不把原单图诊断入口当完整预览。
- 接线约束已核对实际代码：NativeOriginalFileIndex.localLocator已有真实沙盒URL索引，须沿用其查找结果并在打开时冻结；Swift读取还须验证URL归属、权限及解码边界。NativeFilesPageModel.enqueue/OriginalFilesPageBridge.enqueue通过actor异步回传真实接受数，与Android同步Boolean入口不同，不能直接返回true伪造成功或丢掉原飞行动画；需将真实接受结果、页面代次、关闭/取消/部分接受纳入接线测试，同时保持Android同步路径不变。整页前台占用须与CameraPreviewStore的令牌配对，关闭预览只释放本页，不停相机目录/队列或新增第二个queue.updates消费者。
- 下一步：Native完整预览页上下文/真实读取与入口、上述异步入队确认、预览方向/直方图偏好与返回定位；继续STA-direct/RAW/视频预览、扫描批次填充、完整事件/恢复、遥控/GPS/效果/权益和其余共享页面。76%仅为Windows可做工作估计，目标保持开放。


## 第二十九批记录：Native真实FHD读取与独立预览生命周期（Windows约77%）

- NativePreviewReadSession提供正式预览读取生命周期，不新建相机或队列；NativeFilesPageModel绑定现有OriginalFilesPageBridge，每次打开递增代次、关闭旧预览，父页面关闭释放接口引用。原片来源直接调用原NativeOriginalFileIndex.localLocator，与已保存徽标同一查找规则；这里只提供来源钩子，还没有执行本地原片读取。
- 每页最多32个等待请求，单调请求ID/30秒期限；注册后才能同步回调，重复/取消/过期/目录身份变化结果不发布。取消清理回到UI线程，单个取消不关闭整页，关闭整页不停止相机/队列；Swift取消槽直到任务真实退出才释放，共享在途请求由原缓存/通道处理，不另发全局取消或声称已实现PTP可恢复排空。
- Swift整页前台令牌在第一次读取前获取，结束时按原代次成对释放；新旧页交错释放不会清除另一页令牌，沿用CameraPreviewStore的连接级后台填充门控。没有第二个queue.updates消费者，没有新相机/目录/队列所有者。
- 正式FHD接口只读取FHD，不像诊断preview接口立即退回缩略图；保持后续共享协调器要求的FHD→EXIF→允许缩略图兜底顺序。缓存只读缩略图接口缺失时不发I/O。正式解码独立采用1920长边、不自动按EXIF旋转，原诊断/网格方向归一化默认值不改；ImageIO与Android RGB565的重采样/颜色像素一致性尚未证明，留Mac/真机对照。
- NativePreviewImageBridge从NSData一次有界复制到自有PNG，先检查33字节到20MiB及IHDR尺寸1..1920；不是逐字节跨Swift/Kotlin，也不把头校验当作真实解码成功。后续正式PreviewSessionSource仍需接Skia实际解码、缓存、EXIF、完整本地原片与RAW路径，不能拿有界FHD代替原尺寸本地图。
- 新增10项common测试，507 shared+307 app=814项0失败/错误/跳过；覆盖同步/重复/迟到回调、单个/整页取消、旧目录、32槽限额、期限清理、PNG尺寸溢出/坏头/限额、父子会话与真实原片索引。新增7项只读源码守卫，121项Python及原UI完整迁移/工程结构检查通过。
- common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 11s（112 tasks，36 executed/76 up-to-date）；app Lint仍0 errors/179 warnings/11 hints，shared无issue。两种Manifest摘要不变，MainActivity/ViewModel/协议/服务/GPS/dist/dist-debug与55876fa无差异；本批没有修改Android源码、版本或依赖，未打APK。
- 新增6个XCTest源码场景：FHD失败不抢缩略图、成功缓存、只读缓存缺失无I/O、EXIF方向差异、1920尺寸及坏图、NSData边界；32个App Swift/128个XCTest/5项iOS位图Native测试全部待Mac编译/执行，不能将Windows结果当Apple通过。
- 本批本地提交、不推送。用户要求一并提交的《无卡紧急直存手机可行性调研.md》已在19eb7a9原文提交，本批未改变该文档；检查工作区没有另外未追踪的MD。
- NativeOriginalFilesPage两个预览回调仍明确previewPending，未提前启用不完整页面。下一步继续正式预览EXIF/本地文件读取与实际图片适配、来源冻结、真实异步入队接受确认/取消/部分接受、原返回定位/方向直方图偏好；STA-direct/RAW/视频/事件恢复/其它页面等仍在范围内，不宣称Windows收口。


## 第三十批记录：原预览异步真实入队确认接点（Windows约78%）

- SharedPhotoPreviewOverlay新增可选onTransferAsync，默认null；Android调用者不传入，原单张/合集同步Boolean回调、校验顺序、32/560/1000ms飞行时序和所有原动画正文逐字保留。Native使用时等待实际接受数，再复用同一个startPreviewQueueFlight，不另写动画、不乐观返回成功、不重复提交。
- PreviewQueueAcceptance只管理本页等待任务，没有相机/队列/服务所有权。一次仅一个请求，冻结文件列表，开始与确认后都检查当前页/关闭状态；翻页、关闭、父scope取消及异常释放等待。取消不撤销可能已经成功进入真实队列的任务，迟到旧回调不能播放动画或清掉新请求。
- 只有实际接受数等于完整请求数才播放整组残影；0、负数、越界或部分接受都不伪装整组成功，部分接受保留NativeFilesPageModel原有PARTIAL_ENQUEUE提示和真实队列状态。异步等待先回落上滑位移，避免等相机/actor期间图片一直悬在半空；Android未启用此分支，原同步拖动行为不变。
- 新增9项等待器common测试与2项真实NativeFilesPageModel.enqueue接线测试；518 shared+307 app=825项0失败/错误/跳过。覆盖等待前无动画/重复点击、部分与非法返回、取消/关闭/旧页迟到、同步立即完成、可变调用列表、异常释放，以及不响应取消的生产者迟到也不能影响新请求；真实模型用例验证部分提示和关闭预览不停止父队列。
- 新增4项Python检查，125项PASS。枚举可选接点的5处精确变换，逆向移除后与ec109df完整协调器逐字相同；55876fa原抽取全链与Android完整适配仍逐字对照，时序/判断/数值变异不会被规范化隐藏。此守卫不是Compose帧时序/真机交互验收的替代。
- common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 20s（112 tasks，36 executed/76 up-to-date）；app Lint仍0 errors/179 warnings/11 hints，shared无issue；两种合并Manifest摘要不变，构建进程已退出。Android源码/版本/依赖/打包脚本本批未改，MainActivity/ViewModel/协议/服务/GPS/dist/dist-debug仍与55876fa无差异。
- 本批没有新增Swift；32个App Swift、128个XCTest、5项iOS位图Native测试和新common逻辑的Apple目标仍待Mac编译/执行。Native正式页面尚未传入onTransferAsync（预览入口仍previewPending），该接点将在完整真实图片/EXIF/本地原片适配后使用，不能记作整页已接通。
- 上批ec109df已本地提交，本批按验证批次本地提交不推送；调研MD原文保持已提交状态。下一步正式图片/本地原片/EXIF与页面上下文、定位及偏好继续，其他Windows可写任务保持开放。


## 第三十一批记录：本地普通原片原尺寸读取与来源冻结（Windows约79%）

- NativeFilesPageModel创建预览读取会话时冻结实际原片索引结果，以完整CameraFileInfo→locator保存，不随打开后完成的传输热替换；本地来源判定不要求相机在线。NativePreviewReadSession把FHD与本地读取归入同一个请求ID/最多32槽/主线程回调和取消清理机制，关闭后释放来源闭包，不新建相机/目录/队列所有者。
- 原片读取由已有CameraOriginalQueue转到同一个CameraOriginalStore。只接受此前发布的精确索引URL，拒绝外部URL/查询片段/未索引路径/临时part；保留shared的名称、大小、copy后缀匹配唯一来源，不在Swift重新匹配文件名。核对原片根/日期目录/实际文件归属与尺寸，以O_NOFOLLOW逐层open/openat持有目录及文件描述符，fstat复核普通文件与长度；64KiB分块读取/检查取消、结束核对EOF，所有描述符成对释放，不触网、不重扫索引、不写原片。
- 普通图片DIRECT_BITMAP路径使用ImageIO完整CGImageSourceCreateImageAtIndex，再不携带原EXIF方向写PNG；没有thumbnail API或1920/2048缩放，保留原像素网格供手动旋转。NativeLocalPreviewImage与FHD载体分开，NSData一次有界复制；沿用PNG签名/IHDR校验，诊断2048/20MiB与FHD1920限制不放宽。本地仅受ByteArray/编码表示上限约束，不是缩小原片；实际高分辨率内存峰值、ImageIO与Skia解码/色彩仍须Mac验收，不能声称无限尺寸或内存安全已经实测。
- 修正前批Native读取期限的边界：自身30秒超时返回null，允许共享协调器继续本地失败→相机FHD或FHD失败→EXIF→缩略图回退；父协程取消仍抛CancellationException。此前直接传播自身TimeoutCancellationException会让当前页加载Effect提前终止，本批正式页面启用前修复，Android原路径未改。
- 新增5项common测试（含手动推进deadline的确定性测试，不依赖睡眠）：离线冻结来源/错误来源拒绝、FHD和本地共同32槽及同一ID空间、取消本地不污染后续FHD、8256×5504及超过20MiB载体不被缩成FHD、已准入FHD/本地真正超时释放槽且返回miss可继续后续请求；原零期限用例同步修正。523 shared+307 app=830项0失败/错误/跳过。
- 新增5项Python守卫，130项PASS；原UI全链完整对照与工程结构检查通过。新增8项XCTest源码：已发布索引/多块读取且不变更文件或索引、外部/别名/私有part拒绝、删除和长度变动、叶子及日期目录被符号链接替换、取消先于访问、3000×1500原尺寸/方向、独立PNG边界。32个App Swift、136个XCTest及5项iOS位图Native测试仍全部待Mac编译/执行。
- 首轮BUILD SUCCESSFUL in 3m 13s后补期限回退与确定性测试；最终common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 12s（112 tasks，31 executed/81 up-to-date）。app Lint保持0 errors/179 warnings/11 hints，shared无issue；两种合并Manifest摘要不变，构建结束无java进程遗留。Android源码/版本/依赖/打包脚本本批未改，MainActivity/ViewModel/协议/服务/GPS/dist/dist-debug仍与55876fa无差异；不打APK，不推送。
- RAW仍是明确未完成项：实际parseNefHeaderMetadata/largestEmbeddedJpegRange及本地16MiB索引前缀/按解码像素选最大JPEG逻辑目前在Android NikonCamera/PhotoFrameExporter平台文件，不是已可被Native调用的共享函数。不能用ImageIO直接解RAW代替这套选择规则，也不能让TIFF误走普通原片分支；本批仅提供DIRECT_BITMAP读取能力，下一步须按原调用点继续共享/接线，不能记作RAW支持完成。
- Native正式预览入口仍previewPending，完整PreviewSessionSource的Skia图片、缩略图缓存共享、EXIF及RAW路由、真实异步入队接点与页面上下文/返回定位/偏好仍待整合。本批普通原片读取接口不是完整预览已接通，也不是Windows收口。
- API签名核对参考[Swift官方open/openat实现](https://github.com/swiftlang/swift/blob/main/stdlib/public/Platform/Platform.swift)，该阅读不替代Apple SDK编译和文件描述符真机验证。上一检查点5547d30已本地提交，本批按验证批次本地提交；用户调研MD原文保持已提交状态。


## 第三十二批记录：Native真实位图与网格/预览缓存复用（Windows约80%）

- 原NativeGridImages从SharedUiController移到同目录独立文件，真实文件页继续使用同一实例；保留32MiB/128项LRU和远程8次有界重试。NativePreviewBitmaps借用该实例的同步缓存与异步加载，不建立第二份缩略图缓存；关闭预览只释放本页来源/读取会话，网格缓存与父队列仍存活，父页面退出才关闭网格缓存。
- 新适配真正调用Skia Image.makeFromEncoded→toComposeImageBitmap，不把PNG头校验当解码成功；临时Image在finally关闭，交给Compose独立位图。FHD核对期望尺寸/1920长边，本地保留完整尺寸，图片解码移到Default，返回后核对取消/本页身份，FHD/原片缓存与±2淘汰继续由原共享Overlay唯一持有。
- allowRemote参数从NativeFilesPageModel经现有Swift适配传到CameraPreviewStore。false只查内存再查真实磁盘，不等待正在进行的远程任务、不发GetThumb、不将本地miss负缓存；离线仍可尝试本地缓存。网格在禁止触网时也实际走这条路径，只尝试一次本地读取；true保留现有远程加载、合并与重试规则。整页前台占用和原共享预览的FHD→EXIF→远程缩略图放行顺序继续待完整页面绑定，不能提前绕过。
- 补上缩略图返回时的Swift和common双重目录身份检查，目录刷新后同handle已代表不同文件时丢弃迟到结果；本地/远程请求均适用。Native缩略图自身15秒期限返回可回退/重试结果，不误当父协程取消；真实关闭/翻页取消仍传播。原片入队逻辑未修改。
- 新增3项common测试：离线本地缓存不升级触网、错误身份及关闭后迟到拒绝、目录身份变化后旧缩略图不能发布。526 shared+307 app=833项0失败/错误/跳过；新增5项Python守卫共135项PASS，覆盖唯一缓存、真实解码/资源释放、禁止触网路径、权限传递和Native测试PNG的CRC/真实红绿像素，原UI全链和Xcode结构检查通过。
- 新增6项iOS Native测试源码：真实红绿PNG解码后资源寿命、坏图及尺寸不符、预览与网格位图对象相同/关页保留父缓存、本地miss后远程可成功、同handle异身份拒绝、FHD与原片实际解码且不污染缩略图缓存。与原5项合计11项，全部仍待Mac Native编译/执行；新增3个Swift磁盘回退场景，32个App Swift/139个XCTest仍待Mac编译/执行，不把Windows结果当作Native真实通过。
- 首轮BUILD SUCCESSFUL in 3m 19s；复查补目录迟到身份校验后最终common metadata、Android Debug/Release编译及双模块Lint BUILD SUCCESSFUL in 4m 54s（112 tasks，31 executed/81 up-to-date）。app Lint仍0 errors/179 warnings/11 hints，shared无issue；两种合并Manifest摘要不变。Android源码/版本/依赖/打包脚本本批未改，MainActivity/ViewModel/协议/服务/GPS/dist/dist-debug仍与55876fa无差异；未打APK、不推送。
- NativeGridImages的预览工厂及NativePreviewBitmaps已能供完整预览调用，但NativeOriginalFilesPage仍明确previewPending，尚未创建完整PreviewSessionSource或传入共享Overlay。下一步整合EXIF/RAW原规则、文本与页面上下文、原返回定位/旋转直方图偏好和真实异步入队；缩略图既有ByteArray桥接与高分辨率内存/取消后的资源峰值也仍需性能验收。不能将图片适配完成当作整页或Windows工作完成。
- 上批a0ef55b已本地提交，本批按验证批次本地提交；用户调研MD原文保持已提交状态。Windows目标继续开放。


## 第三十三批记录：RAW索引纯解析唯一实现与Android逐输入对照（Windows约81%）

- 将NikonCamera原有NefPreviewReference/NefHeaderMetadata、parseNefHeaderMetadata、largestEmbeddedJpegRange/largestEmbeddedJpeg及依赖的staDirectCaptureDate原样提入shared/preview/NefPreviewMetadata。Android原包名入口保留typealias与薄委托；所有现有STA-direct及本地RAW调用者实际使用同一共享实现，不在Swift重写TIFF/JPEG索引算法。
- 仅将JVM US_ASCII替换为逐字节公共适配：0..127保留，128..255每个字节产生U+FFFD；不是UTF-8解码。大小端、16MiB候选长度限制、有效前缀、目录深度8/计数512、日期优先级/宽松取数字、去重及排序、JPEG最新SOI/首个等长胜出全部保持。
- 4项Python守卫完整对照073188f：整个NikonCamera仅允许上述委托替换、完整共享解析正文仅允许可见性/ASCII适配、冻结JVM测试基线与原文一致、整个PhotoFrameExporter未变。不仅检查函数名或局部片段；连接、命令顺序、TID、读写、扫描及实际RAW按像素数选图均不变。
- 新增10项common测试和4项Android差分测试，后者包含4,000组随机/截断输入、4,000组TIFF/JPEG头部变异及256种ASCII字节样本。测试源码中的旧算法仅作冻结oracle，不进入产品；536 shared+311 app=847项，0失败/错误/跳过。迁移前损坏TIFF极端IFD偏移可抛越界异常，差分同时锁定异常类型；本批不顺便修旧算法，Native后续必须在Kotlin边界将解析失败转为miss，不能直接让异常穿过Swift桥。
- common metadata、Android Debug/Release编译、双模块Lint BUILD SUCCESSFUL in 3m 26s（112 tasks，40 executed/72 up-to-date）。139项Python、原UI全链及Xcode结构检查PASS；app Lint仍0 errors/179 warnings/11 hints，shared无issue，两个合并Manifest摘要保持不变，构建进程已退出。
- 本批Android有一处受控纯逻辑提取，不再声称协议文件零差异；MainActivity/ViewModel/服务/GPS/dist/dist-debug与55876fa无差异，版本/依赖不改。32个App Swift/139个XCTest/11项Native位图测试没有新增，Apple编译及真机仍待验；不打APK、不推送。
- 073188f已是上批提交，本批验证后本地提交；用户调研MD已随19eb7a9提交，原文未改。下一步将共享候选解析接入Native安全分段原片读取/按实际解码像素选取，再补EXIF与完整会话。现在还不是iOS RAW预览完成，也不是Windows100%。


## 第三十四批记录：Native本地RAW分段读取与原选图规则（Windows约82%）

- 从PhotoFrameExporter真实调用点提取LocalRawPreviewPolicy：16MiB前缀、TIFF索引后追加最大扫描JPEG再distinct、完整SOI/EOI包络、正尺寸Long像素乘积、严格大于才替换（等像素保留首个）。Android立即使用同一规则，BitmapFactory边界读取/完整解码、文件打开/skip/read和异常行为未改；整文件源码守卫只允许5处枚举替换，不在Swift重写业务选择算法。
- NativeRawPreviewBridge只批量复制有界索引前缀一次，候选JPEG正文不进Kotlin逐字节循环；包络检查只读取首尾4字节并调用shared。Kotlin侧捕获旧TIFF解析Exception并返回空候选，防止损坏偏移的异常穿越ObjC；不改变Android原异常行为、不捕获内存耗尽等Error。
- CameraOriginalStore的已有索引URL/目录及叶子O_NOFOLLOW/openat/fstat校验提为两条读取共同使用的私有withOriginalInput，校验正文逐字对照0d2f0b9（只将最大文件尺寸参数化）。普通图片原完整读取/Int32上限/EOF核验保留；RAW允许大文件，只读最多16MiB前缀，再从前缀切片或同一已持有描述符seek精确候选，64KiB块检查取消。越出文件的候选跳过；结束再检查描述符尺寸，不触网/重扫/改原片/建第二个owner。
- ImageIO只探测每个候选JPEG的像素尺寸，调用shared比较，胜者才由原originalBitmapPNG完整解码；不将RAW容器交给系统渲染，不按编码长度选图，不自动旋转/缩到FHD。已有CameraOriginalQueue转发存储读取；readLocalRaw经同一个NativePreviewReadSession的冻结来源、请求ID/32槽/30秒回退与取消，Swift适配共用请求表，NativePreviewBitmaps走真实Skia完整位图。离线不禁用本地，关页不关闭父队列或清网格缓存。
- 新增5项common规则测试（包括2,000组包络与1,000组各20候选的像素选择对照）及3项读取会话测试（离线与错误来源、共用槽/取消迟到、确定性期限miss）。544 shared+311 app=855项0失败/错误/跳过；144项Python检查、完整原UI链与Xcode结构检查PASS。
- 新增8项Swift XCTest源码：编码更大但像素更小、全尺寸/原方向、超过2GiB且前缀之外的稀疏RAW候选、无TIFF扫描回退、等面积首个胜出、越界/坏图跳过、索引/尺寸/链接拒绝、取消和Native畸形头异常隔离；新增1项Native实际RAW位图适配测试。现有32个App Swift、147个XCTest、12项Native位图测试全部仍待Mac编译/执行，尤其ImageIO与BitmapFactory候选可解码性/色彩及稀疏文件行为不能当Windows实测通过。
- common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 37s（112 tasks，36 executed/76 up-to-date）；Lint仍app 0 errors/179 warnings/11 hints、shared无issue，两个合并Manifest摘要不变。MainActivity/ViewModel/服务/GPS/dist/dist-debug与55876fa无差异，NikonCamera本批未再改；版本和依赖不变，不打APK、不推送。
- 本批按验证批次本地提交，0d2f0b9为上批检查点；用户调研MD仍已提交且原文未改。Native正式网格入口仍previewPending，RAW适配是完整会话的真实输入，不将其当整页成品；接下来继续EXIF读取/显示原语义、路由/文本与完整页面状态、旋转直方图偏好和返回定位，Windows目标保持开放。


## 第三十五批记录：原预览EXIF语义共享与Native格式适配（Windows约83%）

- 逐项核对确认预览不同于相框：使用Float分数/APEX计算、曝光时间不回退ShutterSpeedValue、不清理原ISO文本、空/异常数值保留旧可见结果、光圈取整阈值/日期首次非空白/镜头trim、GPS解码值优先再Float/DMS回退及成对有效、海拔仅有限非零。不能直接把PhotoFrameMetadata转PhotoExif。本批将CameraViewModel的三段纯函数提入PreviewExifPolicy，Android原parseExifImpl以AndroidPreviewExifSource/DecimalFormatter委托；不更改EXIF缓存键、负缓存、128KiB/2MiB读头、临时TIFF文件、相机/本地读取或协程顺序。
- PreviewExifSource保持惰性属性访问而不是提前收集所有标签；fNumber存在时不读APEX，日期有首选值时不读后备，GPS解码坐标有效时不读原始DMS。Android适配仍直接使用ExifInterface原标签/latLong/getAltitude，数值仍由原Java Formatter呈现；曝光补偿单独Locale.ROOT，其余字段仍默认格式Locale。common标准pow在JVM差分中与原Math.pow一致。
- 新增9项common测试和4项Android差分测试，包含5种Locale共4,000组字段/坐标/异常输入及访问顺序对照、4,000个随机APEX Float位模式、法语字段逗号而EV小数点、DMS/无效及零值边界。553 shared+315 app=868项0失败/错误/跳过。
- 5项新Python守卫完整对照9a84fc9的CameraViewModel、共享解析正文、Android惰性标签/格式映射、仅测试的冻结原算法，以及原Apple相框读取器全文不变。合计149项辅助检查PASS；原UI全链完整对照及Xcode结构检查通过，不用局部字符串结果替代整个迁移范围。
- NativePreviewExifValues/Bridge复用同一解析，ApplePreviewExifFormatter只适配Float数值、默认Locale与ROOT、half-up及Java非有限值拼写；没有替换原相框格式器。新增3项Apple金样源码覆盖法语/ROOT、APEX/日期/GPS与取整/负零/NaN/Infinity。32个App Swift、150个XCTest、12项Native位图测试仍待Mac；Foundation与Java数值格式和Kotlin/Native行为未实测，不能声称两平台输出已全部证实相同。
- common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 20s（112 tasks，39 executed/73 up-to-date）；app Lint仍0 errors/179 warnings/11 hints，shared无issue；两种合并Manifest摘要不变，构建进程已退出。MainActivity/服务/GPS/dist/dist-debug与55876fa无差异。ViewModel现在有受控纯解析委托，不再记作文件零差异；版本/依赖/协议收发未改，不打APK、不推送。
- 本批验证后本地提交，9a84fc9为前一检查点；用户调研MD仍已提交且原文未改。Native新EXIF值载体/格式器已可调用但尚未接ImageIO真实属性、现有原片描述符与相机文件头/稳定缓存；正式网格预览仍previewPending。下一步完成真实EXIF读取/取消/回退/缓存，再整合完整会话、文本、偏好和返回定位。Windows工作未结束。


## 第三十六批记录：本地EXIF安全随机读取与实际属性（Windows约84%）

- 新增薄平台文件PreviewExifReader，Xcode FileReference/Group/Sources各接一次。CameraOriginalStore.originalExif复用原withOriginalInput的精确索引URL/目录及叶子O_NOFOLLOW/openat/fstat验证，再交给CGDataProviderDirectCallbacks按需读取；不重开路径、不整文件Data、不固定128KiB/2MiB前缀、不mmap，能访问大RAW较深处元数据而不强制把全部内容放进内存。
- 提供器持有已校验描述符的dup与CLOEXEC，pread只读且不改变原描述符位置；每64KiB检查锁保护的取消标志，EINTR重试，截断/失败记错，EOF有界。Swift withTaskCancellationHandler即使ImageIO回调不在原Task线程也能终止后续读取。Unmanaged由提供器releaseInfo释放，构造失败独立释放；关闭只释放本次读者，父队列/原片仍保留。CF回调资源寿命和Foundation行为仍须Mac执行验证。
- 只调用ImageIO属性接口，不解码图片；原预览字段调用NativePreviewExifValues/Bridge，原相框读取器完全未改。参考实际依赖的[AndroidX 1.3.7官方源码包](https://dl.google.com/dl/android/maven2/androidx/exifinterface/exifinterface/1.3.7/exifinterface-1.3.7-sources.jar)：保留Double精度的已解码GPS仅接受完整大写N/S/E/W引用对，其余交还原Float/DMS回退；海拔缺引用不伪装为海平面以上，未知非负整数引用维持原行为。拒绝布尔冒充数值和非整数海拔引用。Apple构造签名依据[CGDataProviderDirectCallbacks官方文档](https://developer.apple.com/documentation/coregraphics/cgdataproviderdirectcallbacks)及其JSON声明核对，非编译证据。
- 新增localExif到同一NativePreviewReadSession，冻结来源、32槽/统一请求ID、30秒miss和父取消处理不变；Swift适配借用原队列→存储器，离线不禁用、不偷偷回退相机。正式页面仍未创建完整PreviewSessionSource，尚未使用这些输入当成产品预览。
- 新增6项common测试（坐标精度/引用缺失与大小写、海拔规则、离线EXIF/错误来源、共用槽/迟到、确定性期限）。559 shared+315 app=874项0失败/错误/跳过。新增7个XCTest源码：真实属性/坐标精度与ISO、布尔及缺海拔引用拒绝、真实已发布JPEG读取/索引不变、真实CF提供器及原FD位置不变、dup后超过2GiB读取、取消/截断、不安全来源。33个App Swift、157个XCTest、12项Native位图测试全部仍待Mac。
- 新增6项Python守卫，合计155项PASS；原UI全链与Xcode结构PASS。common metadata、Android Debug/Release编译与双模块Lint BUILD SUCCESSFUL in 3m 8s（112 tasks，34 executed/78 up-to-date）。Lint仍app 0 errors/179 warnings/11 hints、shared无issue；两个合并Manifest摘要不变，构建进程已退出。Android app目录本批零差异，版本/协议/打包脚本不动，不打APK、不推送。
- 重要未完成项/下一优先级：ImageIO可能把原RATIONAL转换成Double小数，原Android非兼容标签则交给Float(num)/Float(den)。已找到并锁定曝光偏置36293949/725879001：原Float分数为0.05000000074505806（显示EV），Double后转Float为0.04999999701976776（被0.05阈值隐藏）。这是Native接线差异，不是Android迁移回归；数学样本测试PASS只证明差异可复现，不证明两端等价。必须补原始RATIONAL标签读取覆盖ImageIO值，特别APEX/偏置/焦距，之后才能启用正式预览或宣称EXIF等价。
- 本批作为安全读取基础的验证检查点本地提交；8d24978为前批提交，用户调研MD仍已提交且原文不改。下一步先完成上述原分数数值源，再接相机EXIF读头/稳定共享缓存与完整会话/文本/偏好/返回定位；不能将本地读取已写当作EXIF或Windows全部完成。


## 第三十七批记录：原RATIONAL读取与实际AndroidX字节对照（Windows约84%，兼容性补强）

- PreviewExifRationalReader补读预览五项数值源：FNumber/ExposureTime先按Double属性转换，APEX/曝光偏置/焦距保留原分子分母，再交给现有shared Float规则；SRATIONAL保留符号，URATIONAL保留32位无符号值，零分母先按AndroidX归一化为0/1。缺失/不兼容标签清除ImageIO可能合成的数值，其它属性不变。Android入口仍使用原ExifInterface，没有替换Android读取或调整0.05阈值。
- Swift沿用已验证原片描述符的同一个dup/pread读取者，实现薄随机字节接口；Native每次批量复制有界NSData，不逐字节跨桥。读取消先由原共享标志终止，再抛CancellationError；不新建连接、缓存或文件所有者，不重开URL，不整文件载入。每请求至多512KiB、累计8MiB/4096次、目录深度64/256个访问用于拒绝异常输入；这些防护不代表与Android损坏文件的部分结果行为完全相同。
- 新增13项common测试：双字节序TIFF/JPEG、0.05EV真实字节→属性覆盖→显隐、兼容Double属性、符号极值/零分母、缺失/重复/不兼容/UNDEFINED/多值标签、逐字节截断、APP1内偏移边界、取消异常、循环/请求预算及3GiB虚拟RAW中4MiB外元数据的只读小范围访问，含4,000组随机原分数。首次失败定位为测试预期：指针等于已知长度时AndroidX跳过目录；校正样本而未改实现迎合预期。最终572 shared+315 app=887项0失败/错误/跳过。
- 新增独立离线check_exif_rational_oracle.py：直接使用缓存中未修改AndroidX 1.3.7 AAR及本次编译shared类，唯一平台替身为无输出android.util.Log；不改Android测试配置/依赖。2,024组TIFF/JPEG（500组随机五标签×双大小端×两容器，另加边界/重复/零分母）比较真实getAttribute的原Float运算及可见PhotoExif，全部PASS。AAR SHA256为0e8f1832266c5b0667ad3d3b1098e624e49a09075493a014a7e88af01fd30ad3；这是JVM真实库证据，不是ImageIO/Native运行证据。执行：先跑shared测试，再运行python iosApp/scripts/check_exif_rational_oracle.py，需现有JAVA_HOME/ANDROID_HOME与依赖缓存，不下载。
- 新增2项Python接线守卫，157项全部PASS；原UI全链及Xcode结构PASS。新增2个Apple测试源码直接注入未约分JPEG EXIF字节，覆盖大小端临界EV、负偏置与零分母，并检查借用FD位置不变。33个App Swift/159个XCTest/12项Native位图测试均仍待Mac编译和执行。
- common metadata、Android Debug/Release编译及双模块Lint最终BUILD SUCCESSFUL in 2m 22s（112 tasks，10 executed/102 up-to-date）；app仍0 errors/179 warnings/11 hints，shared无issue，两种Manifest摘要不变。app目录本批零差异，MainActivity/服务/GPS/dist/dist-debug仍对照55876fa无变化。构建已退出，不打APK、不推送。
- 边界未收口，IOS-D05继续NEXT：当前原分数读者只处理首个Exif APP1，尚不能代表Android遍历多段APP1及复杂thumbnail/preview/GPS/互操作目录的全行为；损坏文件部分结果、其它ImageIO合成字段与原始属性差异仍须逐项对照。下一优先级补这些明确边界，再接相机EXIF读头/稳定缓存与完整预览会话。正式入口仍previewPending；不声称EXIF全部等价，不将此兼容性补强人为计作新功能完成百分比。
- 本批验证后本地提交；e9598a7为前一检查点。用户新增“无卡紧急直存手机可行性调研.md”已在19eb7a9提交且原文未改，本次无遗漏未跟踪MD。Windows全目标保持开放。


## 第三十八批记录：多EXIF段与跨目录访问兼容（Windows仍约84%）

- 先用原AndroidX 1.3.7真实库复现两处差异：后段EXIF指向新相对目录时会覆盖原值（原reader只读首段）；GPS先访问与EXIF共用的偏移时，后者不得重新解释同一目录。两条差分在旧编译shared上明确失败，再改实现并复测，未调整Android行为或降低测试预期。
- 原始分数读者改为按顺序处理JPEG全部Exif APP1，到SOS/EOI停止，不扫描图像熵数据。相对偏移访问集跨段保留，根IFD每段仍重新读，只有递归跳转受已访问集约束。属性保留原8字节，最后才按最终EXIF字节序转换，覆盖Android跨段保留旧值却使用最后字节序的细节。首IFD偏移改为原库的有符号Int语义；每段范围、读取预算和取消接口保留。
- 目录类型区分TIFF/EXIF/其它：TIFF可进入SubIFD、EXIF、GPS，EXIF可进入Interop；GPS/Interop不把普通编号错误解释为EXIF指针或数值字段。接受USHORT/ULONG/UNDEFINED的原指针兼容类型，非法SLONG/IFD类型跳过。全局visited防止目录别名重读，未引入另一套缓存、连接或原片所有者。
- 新增3项common测试（多段旧值保留/新目录覆盖/三段顺序、最终字节序解释旧值、GPS/EXIF先后访问）；575 shared+315 app=890项全部通过。实际库oracle保留原2,024组固定种子样本，另加21组确定性目录/段类型样本和800组随机多段组合（两段各两种字节序×新旧偏移），共2,845组字段与可见PhotoExif一致。随机多段独立种子，不替换旧随机样本。
- 新增1项Apple测试源码，在可解码JPEG内插入第二段未约分EXIF，验证相同偏移保持+0.1EV、新目录覆盖为-0.7EV，借用FD位置不变。33个App Swift/160个XCTest/12项Native位图测试仍待Mac；真实ImageIO对重复APP1的接受及桥接不能由JVM对照代替。157项Python检查、原UI全链和Xcode结构PASS。
- common metadata、Android Debug/Release编译及双模块Lint BUILD SUCCESSFUL in 3m 18s（112 tasks，34 executed/78 up-to-date），构建已退出。app Lint仍0 errors/179 warnings/11 hints、shared无issue；两种Manifest摘要不变，app目录本批零差异，MainActivity/服务/GPS/dist/dist-debug对照55876fa不变。不打APK、不推送。
- 仍未宣称完整EXIF等价：thumbnail/preview目录占用选择、RAW嵌入JPEG元数据、畸形文件与截断头的部分属性保留需要继续对照。后者与相机128KiB/2MiB读头直接相关，下一优先级按真实Android路径补部分结果语义，再接现有连接的读头命令与稳定缓存；其它目录边界保留在IOS-D05验收要求，不静默删减。正式入口仍previewPending，Windows进度保持84%，不是新的完整产品功能已交付。
- 本批验证后本地提交；ce3bc31为前检查点。用户调研MD仍已在19eb7a9提交且原文未改，当前无遗漏新MD。Windows目标保持开放。


## 第三十九批记录：相机EXIF命令与截断文件头输入（Windows约85%）

- CameraWiFiConnection.exifHeader沿用已有PTP串行通道，借PtpTransferBridge.partialParameters(handle,0,count)形成原5参数，发送NK_GET_PARTIAL_OBJECT_EX。复用previewCommand，仅将其参数形式泛化并为原缩略图/FHD保留handle薄委托；不新建session/socket，不改变事件、保活、下载或部分下载支持状态。允许有界1..2MiB输入，实际后续选择沿Android JPEG128KiB/RAW及TIFF2MiB；OK非空才返回数据，Busy/unsupported/无句柄/空数据均miss且不重试，传输异常关闭owner，取消向上抛出。标准AP/STA命令已写，配对STA-direct的recent-header捷径仍待实现。
- PreviewExifRationalReader新增显式readHeader与partial结果；原read完整文件入口仍严格。逐项读取IFD，后面的字段/目录截断不抹去前面已获取的原分数；JPEG只采纳已完整落在头部内的APP1，后续不完整段不混入。字节序逐字段读取，保留后段头部改变最终字节序的顺序。底层返回nil/短读、取消异常和请求/深度预算耗尽仍拒绝或抛出，不当正常部分结果。
- Swift PreviewExifReader.metadata(header:)使用不可变且最多2MiB的Data范围输入→shared部分分数→ImageIO属性→原shared预览规则；没有全图解码、文件写入或第二个网络请求。ImageIO无属性时仍可返回已可靠取得的原数值，不因缺图像熵数据丢弃EXIF。本地描述符入口和完整PreviewExifFileReader逐字保持42f4678，继续dup/pread/安全索引/取消，不切换到宽松头部模式。
- 新增4项common测试（早期字段保留而本地仍拒绝、完整/不完整JPEG段边界、底层失败/取消不当截断、预算及未知格式拒绝）。579 shared+315 app=894项0失败/错误/跳过。实际AndroidX oracle增加352组大小端TIFF/JPEG逐字节截断样本，共3,197组字段/可见值对照通过；不将有限数值样本解释为所有EXIF字段或畸形布局全等价。
- 新增7个Apple测试源码：两种读头大小的独立命令金字节、5类miss不重试/不关连接、非法限额无请求及错误TID关连接、JPEG仅APP1无图像数据、TIFF后字段截断保留光圈、取消EXIF不打断其它事务、已取消头部解析抛取消。33个App Swift/167个XCTest/12项Native位图测试均仍待Mac编译/运行。
- 新增3项Python守卫，整个CameraWiFiConnection只允许新增EXIF方法和参数泛化，其余文件正文与42f4678相同；整个本地描述符读取者/入口保持不变，header不解码/不重开文件。160项辅助检查、原UI全链与Xcode结构PASS。common metadata、Android Debug/Release编译及双模块Lint BUILD SUCCESSFUL in 3m 8s（112 tasks，34 executed/78 up-to-date），构建已退出。Lint仍app0 errors/179 warnings/11 hints、shared无issue，Manifest摘要不变；app/dist/dist-debug本批零差异，不打APK、不推送。
- 本批完成远程输入所需的两个可调用端点，不是正式预览闭环；NEXT接缓存和NativePreviewReadSession/页面调用。重要所有权约束：Android exifCache是ViewModel级HashMap，无断开清空，稳定键为shared exifKey(file)且区分缓存nil/未查过；不能塞进每次重连重建的CameraPreviewStore。后续应由现有长寿命页面/工作区所有者持有一个轻量结果缓存，连接和本地队列仍仅借用，不另造网络/文件服务。未连相机不负缓存、失败响应负缓存、取消不伪装miss、本地与远程同键优先顺序逐项保留。
- 仍保留IOS-D05验收边界：thumbnail/preview目录占用、RAW嵌入JPEG、忽略字段造成的异常读取停止点与ImageIO其它字段一致性；不会在这些事项未核对时声称EXIF全等价。正式previewPending继续，配对STA-direct/其余UI/事件恢复/遥控/GPS/效果/权益等Windows工作仍未结束。42f4678为前检查点，本批验证后提交；用户调研MD仍已保存且原文未改。


## 第四十批记录：跨重连EXIF缓存与统一读取会话（Windows约86%）

- NativePreviewExifCache是轻量UI线程结果表，键直接调用既有shared exifKey(file)，用非空Entry包装nullable PhotoExif区分“没有尝试”与“已尝试为空”。不加handle/URL/Locale后缀，不随断开、页面关闭或缩略图内存压力清理，不另开相机/文件服务。当前长期CameraHandshakeProbe持有唯一实例，显式传给每个OriginalFilesPageBridge；将来正式工作区沿用同样长期所有权，不能在页面内默认new或塞进连接级CameraPreviewStore。
- NativePreviewExifPolicy提供原六种扩展名的Native标量映射：JPEG128KiB、NEF/NRW/TIFF2MiB、其它0；新守卫直接读取Android当前EXIF_SUPPORTED_EXTENSIONS、RAW/TIFF集合及实际maxSize表达式作对照，防止后续一端修改后静默漂移。Android原HashMap和读取方法本批未改，稳定身份计算仍是同一个shared入口。
- NativePreviewReadSession增加exif(file)，本地EXIF参数带入冻结的CameraFileInfo供同键缓存；两种EXIF与FHD/本地/RAW共用原32槽、请求ID、30秒miss、父取消及关闭逻辑。远程EXIF采用仍在当前目录的完整文件身份校验，不把connected作为查询缓存的前置条件；FHD仍保留原connected检查。目录替换/页面关闭后的迟到回调不发布，关闭时清除额外身份闭包。
- OriginalFilesPageBridge真实借用CameraExifSource（现有CameraWiFiConnection）读头，再交既有PreviewImageDecoder actor处理元数据，避免主线程做头部解析；不会触发第二条连接或借缩略图重试。先查缓存，再将不支持格式记nil，未连相机的未命中不记nil。真实失败/miss记负缓存，取消/页面失效不写缓存。本地读取也先查同一缓存，再委托原队列的安全索引读取；本地与远程谁先得到结果就按原稳定键复用，无隐式相机回退。
- 新增7项common测试（4项缓存/稳定键/扩展范围，3项离线查询/完整身份/共用槽/取消迟到/确定性超时）。586 shared+315 app=901项0失败/错误/跳过。既有3,197组实际AndroidX原分数/截断对照继续PASS。
- 新增5项Apple集成测试源码：远程成功后换连接/handle并离线本地/远程命中、nil和抛错负缓存抑制本地重试、离线未命中不污染及不支持格式无需IO、取消不负缓存且可重试、真实已保存JPEG本地EXIF先填缓存后远程不发请求。33个App Swift/172个XCTest/12项Native位图测试仍待Mac，不将假连接测试源码当运行结果。
- 新增5项Python守卫，165项全部PASS：对照Android当前扩展名/限额，整个Probe仅增加缓存与注入，整个缩略图store仅增加借用协议，整个文件页只允许EXIF及其依赖修改，完整Native文件模型仅增加离线EXIF身份回调，整个解码器仅增加actor元数据委托；本地安全读者和网络连接原有守卫保留。原UI全链与Xcode结构PASS。
- common metadata、Android Debug/Release编译及双模块Lint BUILD SUCCESSFUL in 2m 57s（112 tasks，34 executed/78 up-to-date），构建已退出。app仍0 errors/179 warnings/11 hints、shared无issue；两种Manifest摘要不变，app/dist/dist-debug本批零差异，MainActivity/服务/GPS/打包路径对照55876fa不变。不打APK、不推送。
- 当前读取输入与缓存已真实接线，但完整PreviewSessionSource/旋转和直方图偏好/文本/本地路由/返回定位/正式入口仍待组装；不能将输入接齐当预览页面成品。IOS-D05仍NEXT；thumbnail/preview目录占用、RAW嵌入JPEG、其它ImageIO字段与Apple实际解码/交互边界继续保留验收要求。配对STA-direct、自动事件/恢复、完整其它UI/遥控/GPS/效果/权益等Windows任务仍开放。
- 本批验证后本地提交；ccccc01为前一检查点。用户调研MD已在19eb7a9保存且原文未改，无遗漏未跟踪MD；Windows粗估86%不是iOS成品或真机验收百分比。

## 第四十一批记录：完整预览交互窗口与传输分块让路（Windows约87%）

- 接完整PreviewSessionSource时核对到一项真实缺口：Android CameraIoGate.withInteractivePriority在当前页FHD和EXIF之间保持交互登记，withTransferSlice在锁前等待且拿锁后复查；iOS原来只有整页后台缩略图抑制，普通事务FIFO仍会让下一下载分块插入。先补该必要调度，不把空优先级函数接到共享协调器，也不修改Android现有gate。
- PtpIPCommandSession在原完整事务FIFO中增加可嵌套UUID交互登记。只有executeStreaming下一事务等待登记清空，普通控制/元数据仍按可执行请求顺序运行；已发送的数据块不会被抢占。流式调用从等待恢复后，在相同actor、无进一步挂起的位置复查，再分配TID/发送；等待取消不关闭其它事务，不消耗TID。重复/外来释放无效，最后登记退出唤醒下载，关闭owner清理登记并唤醒所有等待者。没有第二个socket或并行PTP通道，原收包/流式sink/保活/事件实现不变。
- CameraWiFiConnection向借用者提供begin/endInteractivePreview，同时为实际FHD和EXIF调用登记独立窗口；成功、失败和取消都等待释放。外层整页当前照片窗口可覆盖FHD→EXIF间隙，内层实际请求即便由合并缓存任务持有也能按自身生命周期释放。CameraExifSource仅增加窄优先级接口，仍由原连接实现，不增加服务owner。
- NativePreviewReadSession.withInteractivePriority用现有UI上下文、单调请求ID、32个待回调槽及30秒注册期限等待授权；拒绝/超时不执行无优先级替代块，成功才进入原协调器的FHD+EXIF块。finally在NonCancellable+UI上下文释放；取消等待也调用原cancelPreviewRead。OriginalFilesPageBridge持有每会话的有限令牌任务，结束/更换会话、取消注册和关闭页面均释放；即使平台在取消后才返回令牌，也会释放而不污染下一会话。完整源和入口尚未调用该括号，仍是下一组装步骤。
- 新增4项common测试：同一窗口覆盖两种读取及结果传回、拒绝/确定性超时/迟到授权不执行块、错误和读取中取消释放、关闭时待注册及新调用拒绝。首轮唯一失败为异常对象assertSame：JVM协程堆栈恢复复制异常；改为核验类型、消息和cause链末端原对象，不修改产品代码绕过测试。第二轮590 shared+315 app=905项，0失败/错误/跳过。
- 新增6项Apple测试源码：FHD/EXIF间下载等待与嵌套登记、正在发送的块不被打断、等待取消不耗TID且通道可用、关闭唤醒等待、页面令牌准确释放、换页后迟到旧令牌不影响新令牌。当前33个App Swift/178个XCTest/12项Native位图测试仍待Mac编译运行；源码中的调度测试不能作为Apple并发已验收的证据。
- 新增4项Python守卫，169项全部PASS。相对c7cb39e整份连接/页面仅允许上述窗口接线；原FIFO文件仅登记/选择等待者/流式准入改变，整个普通execute和流式收发正文保持。旧批次全文件守卫只先剥离本批明确新增内容，再做原基线比较；EXIF、本地读取和原完整共享UI守卫继续PASS。3,197组实际AndroidX数值/截断样本继续PASS，Xcode结构PASS。
- 第二轮common metadata、Android Debug/Release编译及双模块Lint：BUILD SUCCESSFUL in 2m 27s（112 tasks，10 executed/102 up-to-date）。构建已退出；app仍0 errors/179 warnings/11 hints，shared无issue；debug/release Manifest摘要保持DF0F0F7C…/6EA659D8…；本批app、dist、dist-debug零差异。不打APK、不推送。
- 下一步继续组装Native PreviewSessionSource、语言/偏好和真实目录打开/返回定位。发现localOriginalPreviewRoute仍是Android三分支薄适配，需要在接Native时核对RAW/TIFF扩展集合，不把TIFF误接本地普通解码。仍保留IOS-D05的目录占用、RAW嵌入JPEG元数据、其它ImageIO字段和Apple实际验证门槛；STA-direct、事件/可恢复排空、其它产品页面等Windows工作继续开放。c7cb39e为前检查点，本批验证后提交。

## 第四十二批记录：Native完整预览平台源及原三语言文本（Windows约87%）

- 新增NativePreviewSessionSource，完整实现原PreviewSessionSource<String>：借用同一NativeGridImages/NativePreviewBitmaps和NativePreviewReadSession供缓存缩略图、实际FHD/本地/RAW位图、本地与远程EXIF、当前页优先窗口；直方图用既有calculateImageLuminanceHistogram，时钟用NSProcessInfo.systemUptime。没有新增图片调度器、EXIF缓存、相机/队列owner或第二份分页逻辑。
- open工厂只在UI打开时复制文件与本地来源，并从既有model取得读取会话；没有桥接则返回null，不伪装可用。以完整CameraFileInfo冻结身份，从source反查冻结文件给本地IO；后来的索引变化不热替换。读取会话从构造起已登记后台缩略图抑制，原overlay的setFhdActive(false)在销毁时结束该会话；关闭幂等，清除连接和来源引用，不清父网格、不停传输、不清跨重连EXIF缓存。
- 本地三分支路由改为shared originalLocalPreviewRoute，两端调用同一函数；Android PhotoPreview.kt仅将原localOriginalPreviewRoute改成薄委托，其余整个文件逐字守卫。NEF/NRW走RAW内嵌JPEG，TIFF走相机FHD，其它仍DIRECT_BITMAP；不添加大小写/空白归一化或其它RAW格式。辅助测试核对shared扩展集合与Android实际NIKON_RAW_EXTENSIONS/TIFF_EXTENSIONS一致，防止配置漂移。
- NativePreviewTextCatalog提供原10个预览文案的英/简/繁版本并实现PreviewSessionText，30条与Android当前资源逐字对照；语言选择沿用现有Native规则。视频信息保留必须提供的格式回调，没有编造默认日期或省略信息。实际Native视频大小/日期格式仍待下一步接入；本批不改Android的Java日期/Locale或文件大小格式实现。
- 新增3项common测试（两项路由和一项语言选择）及5项iOS Native源码测试（工厂/生命周期、真实位图+EXIF+优先窗口、离线冻结来源、RAW与TIFF区分、真实像素直方图/单调时钟）。Windows593 shared+315 app=908项，0失败/错误/跳过。33个App Swift/178个XCTest/17项Native预览和位图测试仍待Mac编译运行，Native新类本身尚未被Windows编译器编译。
- 新增4项Python守卫，总173项PASS；整个Android预览文件仅路由委托，原共享协调器和所有原UI守卫继续PASS。3,197组实际AndroidX字节对照、Xcode结构PASS。Gradle BUILD SUCCESSFUL in 3m 26s（112 tasks，38 executed/74 up-to-date）；common metadata、Android Debug/Release编译和双模块Lint通过，app0 errors/179 warnings/11 hints，shared无issue。Manifest摘要不变，版本/相机协议/服务/GPS/打包脚本本批未改；无APK、无推送。
- 平台源和文案已写，但SharedUiController/NativeOriginalFilesPage尚未实际打开完整overlay，previewPending仍保留。本批不提高87%估计。NEXT视频信息格式回调、旋转/直方图偏好、原目录快照构建、打开/返回定位与实际入口；要沿原FileListScreen的后台构建快照、来源身份检查、连拍不提前展开、关闭时黑幕下定位及未传输筛除后淡出语义。不能以组件可构造替代产品预览验收。
- IOS-D05的EXIF目录占用/RAW嵌入元数据/其它ImageIO一致性及Apple实跑门槛继续开放；STA-direct、事件恢复和其它产品功能仍须继续。a174602为前检查点，本批验证后本地提交。

## 第四十三批记录：预览旋转与直方图偏好（Windows约87%）

- NativeBrowsePreferences增加旋转/直方图字段，沿原previewFloorMod归一化到0..3；默认0/false，对照Android TransferViewModel真实恢复/保存值。保留旧八参数构造器转发默认值，新的十参数构造器供实际保存恢复，避免旧Swift调用点被迫整体改动；导出重载仍须Mac编译验证。
- NativeFilesPageModel使用独立只读previewOptions状态流供现有共享overlay输入；两个setter只更新预览偏好并调用原persistPreferences。保存时一起带上布局、筛选和预览字段，互相不清空；失败保留当前页状态并通过原preferencesFailed提示。关闭后不接受写入，改变开关/方向不结束或重开读取会话、不动相机/队列/原片索引。
- BrowsePreferencesStore继续同一个UserDefaults键和v1文档，两新字段为可选，旧v1缺字段读为0/false且读取不写回。保存写入共享归一化结果；损坏、新字段错误类型/超出Int32、未来版本仍拒绝保存并保留原数据。未增加设置服务、存储文件、权限或隐私声明。
- 新增3项common测试：默认值/正负及极值归一化、预览/布局/筛选交错保存与重新打开、存储失败/读取会话不重建/关闭后禁止写入。596 shared+315 app=911项，0失败/错误/跳过。新增3项Apple测试源码：旧文档无写读取并升级、非法新字段保护、极值读写和旧导出构造器可调用；181个XCTest及17项Native预览/位图测试仍待Mac。
- 新增3项Python守卫，总176项PASS。整份文件模型除预览状态/setter/保存字段外与122cdf2一致，整份Swift store只增加可选字段和读写映射；旧EXIF整文件守卫先剥离本批明确新增项后继续原基线比较。原UI、Xcode结构及3,197组实际AndroidX样本PASS。
- Gradle BUILD SUCCESSFUL in 3m 12s（112 tasks，34 executed/78 up-to-date）：common metadata、Android Debug/Release编译、测试与双模块Lint通过。app0 errors/179 warnings/11 hints、shared无issue；Manifest摘要保持。app/dist/dist-debug本批零差异，版本/服务/协议/GPS不变；无APK、无推送。
- 本批是偏好存储/状态准备，完整预览入口仍未打开，进度保持87%。NEXT视频大小/日期格式平台适配，再将已有源、文案、偏好直接接原共享overlay与目录页打开/返回定位；不以读取接口或偏好就绪替代完整产品页。原EXIF/STA-direct/事件恢复及其它Windows可写任务继续开放。122cdf2为前检查点，本批验证后提交。


## 第四十四批记录：真实文件页打开共享完整预览（Windows约89%）

- SharedUiController.originalFiles把同一NativeGridImages、NativePreviewSessionSource、原三语PreviewSessionText和既有模型直接接入NativeOriginalFilesPage。长按照片/连拍可构建并打开SharedPhotoPreviewOverlay，不再仅显示previewPending；原分页/缩放/旋转/直方图/FHD+EXIF/邻页预取/上滑入队协调器不复制、不重写。
- 后台按原网格规则构建开页快照，返回UI后校验来源identity；长按连拍只展开该份快照，不提前重排底层网格。冻结所有成员的完整文件身份/本地来源；生命周期结束取消构建并关闭本次源，不停止父队列或清掉共享网格缓存。偏好与队列变化不会以key重开预览。
- 接原旋转/直方图持久偏好、真实入队接受数、真实任务进度与已保存判断；飞行落点使用当前临时页真实队列按钮坐标，不声称正式工作区胶囊/接收动画已完成。关闭时先判当前筛选结果，再在黑幕下展开对应连拍、按原日期标题/折叠状态寻找格位、三行跑道/六行阈值预定位及88dp留白滚动；返回高亮760ms后清除，nonce防旧任务清掉新高亮。已筛除的文件不展开、不乱滚。
- 日期/视频纯规则提为PreviewMetadataText，两端共用。Android仅薄委托，保留原Locale数字格式器和文件大小适配；year 0/公历400年闰年、无效时间退回日期、PTP时区后缀不转换、SIZE_UNKNOWN和严格大于4GiB及原分隔符不变。Swift只用NumberFormatter渲染已验证的整数，不借Calendar重新解释日期。
- 新增冻结迁移前原函数oracle并逐字锁定d7f3b2c来源。Android实际生产委托对比五种Locale、3,014种日期输入及视频大小边界，共15,490组结果；新增11项common与2项app测试。607 shared+317 app=924项，0失败/错误/跳过。新增2项Apple日期格式golden，共183个XCTest、17项Native预览/位图测试，仍未在Mac编译运行。
- 180项Python、完整原UI/平台边界守卫、Xcode结构/61项任务ID和3,197组实际AndroidX数值样本均PASS。更新的旧占位断言改为验证实际overlay/本地源/真实入队；其它旧整文件基线只剥离本批明确的日期适配新增，再继续原历史比较，没有把现版本直接设为新基线。
- Gradle BUILD SUCCESSFUL in 3m 31s（112 tasks，39 executed/73 up-to-date）：common metadata、Android Debug/Release编译、测试及双模块Lint通过。app0 errors/179 warnings/11 hints、shared无issue。Debug/Release Manifest摘要不变；协议/服务/版本/打包脚本未改；无APK、无推送。用户无卡直存调研MD已在19eb7a9提交且本批原文未改。
- 这是源码真实接线，不等于Apple渲染、Swift导出名、Native图片/并发、横屏/快速开关/退出手势或真机网络已验收。Mac矩阵补：普通/连拍长按、快速重开/关闭、翻页期间下载、离线已有原片、预览中筛除当前项、旋转/直方图反复开关、返回定位及两种语言数字、退出不停止队列。完整工作区/选择设置/STA-direct与MPF/事件恢复/遥控GPS/效果权益仍未完，保留完整目标。NEXT继续IOS-D05已登记EXIF边界和正式产品工作区接线；d7f3b2c为本批前检查点，本批验证后本地提交。


## 第四十五批记录：原设置卡片共享与Native照片列表偏好（Windows约89%）

- 从a478ffe的SettingsScreen提取原目录、照片列表、外观三卡，以及SettingsCard/CardDivider/SectionLabel/BooleanSettingsWheel四个基础控件。所有布局、间距、按压/提示颜色、拨轮松手提交、主题/皮肤顺序、语言改变后关闭、触感开关自身可反馈的分支均保留。Android使用显式状态/回调与原资源适配；整个剩余设置文件逐字对照，目录选择/授权、效果草稿/位图、购买、GPS、更新/页脚不重写。
- 三个GPS仍使用的紧凑拨轮尺寸改为指向同一shared值的Android私有别名；其余GPS正文未动。不增加架构层，不把Android ViewModel/Uri/LicenseManager/系统Intent引入common。新提取器只对已登记片段替换，统一UI检查脚本增加整份原设置/共享控件对照。
- Native真实文件页新增临时设置承载层，直接显示原SharedPhotoListSettingsCard：列数2/3/4、连拍合并、点击/长按行为。取消尚未完成的预览构建后开设置，打开时冻结按钮坐标，使用既有SharedAnchorPopup。去掉此前临时循环列数按钮和Switch，不复制SwiftUI设置卡片。其它目录/外观卡片仅完成共享源码，Native绑定未完成前不展示空操作；这不是完整设置页收口。
- NativeBrowsePreferences新增tapToPreview，默认false来自Android真实prefs；保留旧八/十参数构造器，十一参数承载完整状态。现有v1文档用可选字段，旧数据不写读取、错误类型保留不覆盖。模型布局更新用copy保留该字段，所有筛选/预览保存一起携带；失败沿现有提示，关闭后不写，不清目录/不重开读取会话。SharedThumbnailGrid直接消费真实偏好，只交换已有普通照片点击/长按入口，连拍手势仍使用原实现。
- Native三语24项设置标签、4项皮肤标签和标题/关闭共90条来自原资源。复核发现Android XML中的反斜杠n需按资源规则解释，已用实际aapt2 dump strings确认两行输出，修正6条交互标签并加运行时字符串golden；未知转义直接报错而非静默生成差异文本。
- 新增5项common测试（构造器默认、跨布局/筛选/预览保存与重开、失败/读取会话、语言完整性、6条实际换行），612 shared+317 app=929项，0失败/错误/跳过。新增2项Apple偏好旧数据/往返/错误类型测试，共185个XCTest和17项Native预览/位图测试，全部Apple执行仍待Mac。
- 186项Python、完整原UI/设置源文件守卫、Xcode结构/61任务ID、3,197组真实AndroidX样本PASS。首轮BUILD SUCCESSFUL in 3m 35s；修正文案/追加用例后最终BUILD SUCCESSFUL in 3m 26s（112 tasks，30 executed/82 up-to-date）。common metadata、Android Debug/Release编译和双模块Lint通过；app0 errors/179 warnings/11 hints，shared无issue。Manifest摘要相同，Android协议/ViewModel/服务/版本及打包脚本未改；无APK、无推送。
- 当前粗估保持89%，完整设置外壳/帮助/页脚、Native主题/语言/材质/触感/常亮实际保存及跨页生效、目录/provider与自动传输、正式工作区仍须继续；IOS-D05 EXIF/RAW/STA-direct等已登记边界不取消。NEXT沿已有SharedZTransferTheme/设置卡片接真实外观偏好和统一生命周期，不能把一个照片设置弹层等同完整设置。Mac补验拨轮连续切换/关闭重开/两行标签、语言改变后的关闭、主题/皮肤与GPS原布局以及新构造器导出名。a478ffe为本批前检查点，验证后本地提交。


## 第四十六批记录：Native应用外观偏好与真实页面绑定（Windows约89%）

- `NativeAppearanceModel`是独立应用级UI状态，不新增相机层、不并入每连接的browse快照。复用原ThemeMode/SkinPreset/SharedAppearanceSettingsCard；默认SYSTEM/system/FROSTED_GLASS/触感开/常亮开，未知已有皮肤回退TITANIUM并尝试修复，与Android实际恢复一致。主题/语言/皮肤/触感/常亮均实际保存；失败保留当前UI、显示已有偏好失败文案，未知版本/坏数据不覆盖。
- `AppAppearanceSettings`唯一owner持有版本化UserDefaults（独立key、16KiB上限），文件页和队列页仅借用同一model。`NativeAppTheme`复用原颜色、纹理palette和背景brush，不是仅改配色；控制器观察StateFlow更新主题/语言，现有images、preview source、扫描/队列/取消和关闭逻辑不改、不以偏好值作为会话key。SwiftUI薄壳跟随相同明暗值，UI语言不改变系统数字Locale。
- 真实文件页设置弹层用原外观卡片绑定五项；语言松手改变仍沿原卡片关闭弹层。原照片/筛选/完整预览触感使用实时开关，设置触感拨轮本身保留原特例。独立队列页和文件内队列的主题/语言一致；队列操作触感/暂停提示仍是U05未完项，不夸大为所有页面触感已补全。
- 常亮由应用前台状态与用户开关共同控制；失去焦点/进入后台同步释放，回到前台恢复，关页不释放应用owner，owner关闭去观察者/释放常亮/断开platform引用。遵循Apple的[空闲计时器说明](https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled)与[失活通知说明](https://developer.apple.com/documentation/uikit/uiapplication/willresignactivenotification)；这不赋予后台持续传输能力。
- 新增10项common外观测试：真实默认、旧值修复、完整快照/重开、去重、语言刷新、前后台与常亮、存储异常/失败、关闭后迟到调用。新增5项XCTest存储隔离/坏文档/旧值修复/同步生命周期/保存失败场景；4个既有控制器验收调用改注入无系统副作用的外观model。共34个App Swift、190个XCTest及17项Native预览/位图测试，Apple仍全部Mac待验。
- Windows实际：622 shared + 317 app = 939项，0失败/错误/跳过；193项Python、完整原UI守卫、两Swift桥整文件仅参数变更守卫、Native文件页/控制器枚举差异、Xcode注册/61任务ID检查PASS；3,197组真实AndroidX EXIF样本仍PASS（仅既定五数值/可见文本范围）。Gradle最终BUILD SUCCESSFUL in 3m 44s，112 tasks（36 executed/76 up-to-date），common metadata/Android Debug与Release编译及双模块Lint通过；app0 errors/179 warnings/11 hints，shared无issue。
- 本批Android app源文件/配置、shared既有主题/设置卡片实现、相机收发/服务/GPS、版本与打包脚本均未改；Debug/Release Manifest SHA256分别仍为`DF0F0F7CE221B04D9A65EC81300ACD7D993894B66B0635F3265361417A075EEB`/`6EA659D889883DFC1BCB57895C391B914CBAFEC45F9B730A9738A7B5C02FF8EC`。无APK、无推送；本批前检查点`ac79211`，核对后本地提交。
- NEXT：继续原设置外壳/帮助与页脚、目录/provider实际保存和自动传输配置、正式共享工作区；其后既定STA-direct/MPF/事件恢复/遥控/GPS/效果/权益/EXIF边界任务不取消。首次Mac须检查新导出名/Swift actor、两页切主题皮肤语言时不重建会话、触感关闭、旋转/后台/锁屏常亮及截图/生命周期；当前源码和Windows测试不是Apple实际运行证据。


## 第四十七批记录：Files provider协调发布基础与真实手动入口（Windows约89%）

- 本批先补目录设置的必要执行层，不展示尚未接线的产品目录卡片。`ProviderOriginalPublisher`仅接受已完整保存的`SavedCameraFile`，借用原`ScopedDirectoryStore.withDirectory`，授权开始/停止包住整个NSFileCoordinator读源/写目录访问；使用协调器实际给出的URL，支持其在协调期间重定位。没有把书签URL当作永久访问权，也不持有相机网络事务等待provider。
- 64KiB分块复制到同目录唯一私有part，校验原片声明长度与原SHA256、同步关闭、分块回读目标副本，再按shared原同名候选规则发布。禁止覆盖/替换已有文件；路径与日期桶校验、源/根/日期目录链接拒绝；失败只尝试清理本次已创建part，应用内原片不删。若provider拒绝清理可能残留私有part，不能声称跨provider原子事务/云端上传已完成；新建的空日期目录不作递归删除。
- 取消同时调用NSFileCoordinator.cancel与独立线程安全标记，排队协调/每块/最终move前均检查；发布完成后不因晚到取消反报失败。协调器在实际同步操作线程内创建/使用，只有cancel跨线程；不假定actor有固定线程。Apple明确cancel不会中断已经执行中的accessor，因此保留逐块检查；provider单次底层读写阻塞时仍须Mac/真机验证响应时间。
- Debug的真实下载结果/队列取出结果保留已验证原片记录和拍摄日期，可点“写入已选目录”或“按拍摄日期写入已选目录”；复用shared日期目录函数及既有本地dayKey。队列取出日期来自同一queue快照，不借另一个连接的界面快照；原源文件、原索引及队列默认沙盒目标保持不变。此入口不是正式目录设置、队列自动写入或provider索引已经完成。
- 新增14项`ProviderPublicationTests`：实际NSFileCoordinator本地复制/作用域平衡、共享同名候选/保留别人的part、日期桶、协调URL重定位、长度/相同长度内容变化、分块/最终边界取消、取消协调等待、协调失败、撤权保留书签、不安全目录、源/日期链接、provider回读内容变化。测试只建各自UUID临时根，全部Mac待验。现35个App Swift、2个XCTest源文件共204个方法；17项Native预览/位图测试状态不变。
- 修正结构脚本原先只统计CameraNetworkTests.swift的问题，改为汇总全部测试源；新增多源/嵌套目录统计单测。新增7项Windows守卫，完整旧相机探针仅移除枚举的导出增量后与23b893e一致，老EXIF缓存守卫仍逐字比较；自动下载/索引/预览/Android源码未改。
- Windows本批200项Python、Xcode源文件与Scheme/61任务ID、原共享UI全量源码守卫及diff空白检查PASS。仅Apple/脚本/文档变更，未重复Gradle/Android测试、未打包、未推送；939项Kotlin/Android、Lint 0 errors/179 warnings/11 hints及Manifest摘要沿用第46批，不能写成本批执行。前检查点23b893e，核对后本地提交。
- 参考Apple[目录授权与文件协调](https://developer.apple.com/documentation/uikit/providing-access-to-directories)、[双URL协调](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(readingitemat:options:writingitemat:options:error:byaccessor:))和[取消语义](https://developer.apple.com/documentation/foundation/nsfilecoordinator/cancel())。Mac须补新Swift文件编译、真实iCloud/第三方provider授权/改名/撤权/磁盘满/写入中后台与文件管理器并发、超大RAW/视频和取消边界；源码守卫不是执行证明。
- NEXT继续provider目标快照/变更与索引、已有文件/预览读取，再把自动队列发布、按日期/延后开始和正式共享目录卡片串成完整链路。手动发布当前保留实际沙盒文件名；自动队列绑定时应使用任务原始文件名而非沙盒重名后缀。自动事件/工作区/遥控/GPS/效果/权益和EXIF已登记边界均不取消，Windows进度粗估仍89%，目标保持完整范围。


## 第四十八批记录：Provider授权快照与原片索引（Windows约89%）

- 上批`ProviderOriginalPublisher`扩展并更名为`ProviderOriginalStore`：一个actor持有同一授权快照、索引和发布入口，不新增第二个目录/扫描业务实现。Xcode引用及原发布测试同步更名；`copyVerified`及其分块/校验/取消/不覆盖算法整段与5843705逐字一致。
- `ExportDirectorySelection`只封装1MiB内的书签Data，不包含对外裸路径或持续访问权限。Store首次操作绑定快照，之后每次读/写均核对当前授权并重新平衡作用域；改选/忘记后旧对象失败，不静默改写到新目录。固定快照操作不落盘刷新旧书签，避免覆盖新选择；普通owner原stale刷新行为不变，刷新后显式重建绑定。已进入的同步操作使用当次授权直到退出，新操作再验证。
- provider目录条目读取通过NSFileCoordinator的`.withoutChanges`协调并使用其实际URL；只扫描名称/大小等文件元数据，不读照片字节、不生成上传zip。临时扫描实例局限在accessor内，完整候选回到owner actor后才替换正式索引，避免跨await共享可变缓存。扫描取消/失败/目录丢失均保留旧结果；代次检查阻止迟到扫描覆盖更晚扫描/已完成发布。
- 复用`OriginalFileIndexCache`原根目录/一层ZT日期桶、隐藏合法原片、私有part排除、不跟随链接和1024条journal规则。只增加可选缺失根目录策略、取消回调、纯候选提交及预计算规范URL入口；沙盒仍使用原默认参数，缺失沙盒根视为空的分支没有变化，完整源码归一化守卫证明默认分支/其余代码保留。
- 发布完成后在授权/accessor内部规范化结果URL，owner随后增量record而不再做授权外文件系统操作。缓存读取也验证授权并协调核对实际根路径；同一书签对应目录被移动时强制重扫，不能返回旧locator。索引只是与Android相同的候选文件名/大小元数据，不代表已有文件全部通过SHA256/内容验证。
- Debug发布与“检查目标原片索引”复用一个ProviderOriginalStore；显式选择/忘记/普通书签刷新后重建绑定。真实索引计数已可读，但没有把旧沙盒队列或共享文件页冒然切到provider：目标任务快照、provider普通/RAW/EXIF已有文件读取、页面代次重置和正式目录设置仍是下一步。
- 新增11项Mac待验XCTest：实际协调根/日期/隐藏/part扫描、发布后的增量与重开、同书签目录移动、缺失provider保留、切授权拒绝旧读写、忘记授权、固定stale不写旧书签、取消扫描/协调等待、沙盒缺失根默认对照、扫描中取消不发布部分结果。总35个App Swift、2个XCTest源共215方法，17项Native预览/位图测试仍待Mac；没有声称Swift编译或文件服务运行通过。
- Windows本批207项Python、Xcode注册/61任务ID、原共享UI守卫及diff检查PASS。新增7项provider索引源码守卫；原授权Store、原索引默认流程、相机诊断及原发布算法均有整文件/整段对照，原EXIF守卫继续通过。Android/shared/Gradle/版本/打包脚本未改，无Gradle重跑或APK；939项Kotlin/Android与Lint/Manifest沿用第46批结果。前检查点5843705，核对后本地提交、无推送。
- 依据Apple[目录协调](https://developer.apple.com/documentation/uikit/providing-access-to-directories)与[withoutChanges](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/withoutchanges)使用同步目录读取；不把目录枚举误当成图片内容读取。Mac/真机还须验iCloud/第三方provider列举完整性、重定位、权限/离线/占用失败、actor/Sendable导出及快速切目录/并发扫描发布；静态代次守卫不是这些运行行为的证明。
- NEXT沿同一ProviderOriginalStore接目标原片普通/RAW/EXIF安全读取及共享路由，再接队列自动发布、原始相机文件名/按日期/延后开始与完整目录卡片。正式工作区/其余设置/自动事件恢复/STA-direct/遥控/GPS/效果/权益和EXIF边界任务全部保留。Windows粗估仍89%，不因索引基础写完就把完整目标缩为阶段性探针。


## 第四十九批记录：沙盒与Provider共用原片读取器（Windows约89%）

- 将CameraOriginalStore的普通原片、RAW候选分段/像素选优、EXIF与逐层无链接描述符打开提为唯一`IndexedOriginalReader`。CameraOriginalStore仅捕获原索引条目并委托，EXIF仍由原任务取消handler持有共享标记；provider使用同一读取器，不复制解析/安全检查。原普通图片Int32长度上限、64KiB分块、原尺寸/方向语义、RAW前缀/候选/大小复检及ImageIO属性实现保留。
- 新读取器只持有root、不可变单条索引元数据与取消标记，不持有可变索引、打开的文件或相机连接。默认检查原Swift任务取消，并增加同一线程安全标记以覆盖协调accessor/ImageIO回调；所有描述符在同步调用结束前关闭。原沙盒读取区通过枚举式逆转换与381364e整文件对照；新守卫同时注入错误委托/安全检查/RAW选优变异，确认归一化不会隐藏这些差异。
- ProviderOriginalStore新增同名三读取入口；先在owner冻结索引条目/根路径，再核对绑定授权，在作用域内对**文件本身**协调内容读取。使用默认读取选项，等待已有编辑提交和云文件实体，不用目录元数据的withoutChanges代替内容协调。accessor实际URL必须与冻结locator相同，当前根必须与索引根相同；变化后失败并要求上层重扫/重新打开，不静默读取另一位置。返回只含Data/PhotoExif，不返回仍需授权的reader/描述符。
- 取消同时通知协调器和读取器标记，覆盖协调等待、逐块读取及EXIF回调；读取返回前再次检查，取消结果不入索引/不写文件。原provider发布/扫描函数、本地预览解码与EXIF实现、网络/队列/共享页面及Android均未改；已有文件读取入口已写，产品页面目标选择/预览路由与自动队列发布仍需下一批接线，不把底座算完整产品链路。
- 新增10项XCTest：实际协调日期桶原片读取且不改源/索引；provider与沙盒真实JPEG EXIF同源对照；超过2GiB的稀疏RAW候选分段读取与普通读取长度拒绝；未索引/非原locator拒绝；改授权后三条读取拒绝；撤权不碰协调器/不删书签；协调URL重定位拒绝与重试；大小变化/叶链接拒绝；协调等待取消释放与重试；非取消Task下共享取消标记仍拦截三路。36个App Swift、2个测试文件合计225项XCTest均Mac待验，17项Native预览/位图测试状态不变。
- Windows实际：215项Python（新增8项读取归属/完整源码及守卫变异检查）、Xcode注册/61任务ID、原共享UI源码守卫及diff空白检查PASS。没有Swift工具链，未做Apple编译/运行。Android/shared/Gradle/版本/打包脚本均未改，本批不重复Gradle；939项Kotlin/Android与Lint/Manifest沿用第46批，不能标成本批执行。前检查点381364e，核对后本地提交；无APK/无推送。
- Apple依据：[单文件读取协调](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(readingitemat:options:error:byaccessor:))说明文件协调与目录协调的等待对象不同、未下载内容可能长时间等待，必须使用accessor提供的实际URL；[withoutChanges](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/withoutchanges)跳过其它presenter保存未提交修改，不用于本批原片内容读取。Mac需补真实iCloud/第三方provider占位下载、并发移动/编辑/撤权、锁屏/取消、巨型RAW和首次Swift泛型/桥接编译验证。
- NEXT：将绑定目标的索引与三种已有文件读取接真实共享文件页，切目标清理旧来源/取消在途请求；随后自动队列使用任务原始文件名发布、日期/自动传输/延后开始和正式目录卡片。完整设置/工作区、STA-direct/MPF/视频、事件恢复/遥控/GPS/效果/权益及EXIF未验证边界仍保留，Windows粗估保持89%，不提前收口。


## 第五十批记录：Files目录接真实共享文件页（Windows约90%）

- 新增窄`OriginalFilesReading: Actor`接口，仅4个既有只读方法；CameraOriginalQueue、CameraOriginalStore、ProviderOriginalStore通过空extension符合协议，不复制执行器/观察者/业务规则。OriginalFilesPageBridge默认仍借原队列作为来源，可显式借provider；索引与普通图片/RAW/EXIF全部经同一个不可变引用，不混用沙盒索引和provider图片。
- 原页面扫描、进度订阅、入队、缩略图、FHD、解码、EXIF正负缓存策略/生命周期和关闭逻辑未改。只增加构造注入、4处读路由及2项内部只读状态供确定性生命周期测试；完整页面逆转换后与3118b6a逐字相等。旧EXIF cache仍按Android原文件身份共用，不因目录切换另创第二套缓存；关闭后的迟到结果仍禁止写缓存。
- Debug“打开共享文件浏览（已选原片目录）”先固定并校验授权，再打开**原同一个共享文件页/完整预览**，无第二套SwiftUI列表。授权准备不扫描/不下载图片，首次索引由页面执行；失败不偷偷回退沙盒。按原默认未开启日期整理，页面查找仍用根桶，不擅自跨日期桶匹配；按日期配置是后续正式目录设置任务。已有日期桶的底层扫描/读取仍保留。
- 目录选择/忘记/书签刷新先关闭旧页，重开用新model，依原关闭链取消索引和图片/EXIF/优先窗口并清空冻结来源；不是在仍显示的预览里替换source。导航序号仅防授权准备期间用户已打开另一工作区后旧请求再抢回页面；同时核对连接身份与取消。原唯一队列观察者、相机连接/传输worker保持原所有权，不因换页停止队列。
- 界面明确标注此入口只改变已保存识别与本地预览，**新下载当前仍写沙盒**。自动provider发布、真实目录设置卡片/按日期/延后开始、队列目标快照仍须后续接入，不能把读取链路当完整保存目标已经完成；没有悄悄重新定义最终iOS范围。
- 新增7项页面XCTest：真实provider索引→共享冻结来源→离线完整位图/EXIF并拒绝沙盒locator；三路读取注入与无沙盒/网络IO；同revision换页后旧索引迟到拒绝；旧图片迟到不取消新页请求；旧EXIF迟到不污染共用缓存；重复进度不重复查索引；默认仍走原队列沙盒。另2项provider授权准备测试覆盖无重复扫描/固定旧授权拒绝和缺失授权不落盘。37个App Swift、2个测试文件共234项XCTest及17项Native预览/位图测试均Mac待验。
- Windows实际222项Python、Xcode注册/61任务ID、原共享UI源码守卫、diff空白检查PASS。新增7项接线/整文件与守卫变异检查；XCTest异步断言守卫仍保留，失败输出改为具体行而非倾倒整个测试文件。Android/shared/Gradle/版本/打包脚本和原队列/读取器均未改，无Gradle重跑/无APK/无推送；939项Kotlin/Android与Lint/Manifest仍沿用第46批，非本批执行。前检查点3118b6a，核对后本地提交。
- Mac需首次编译Actor协议/导出类型，执行新增页面与文件协调测试，再验真实provider占位内容、切目录/快速切页/断线、预览关闭与队列继续。新增跨桥测试调用共享suspend入口的Swift async映射，依据[Kotlin官方互操作说明](https://kotlinlang.org/docs/native-objc-interop.html#suspending-functions)，当前Windows检查不是桥接或渲染已通过的证明。
- NEXT：同一目录授权绑定接自动队列发布（使用相机任务原始文件名，避免沙盒重名后缀影响目标命名），完成目标/日期/自动传输/延后开始与原共享目录卡片。完整设置/工作区、选择/事件恢复、STA-direct/MPF/视频、遥控/GPS/效果/权益和EXIF剩余边界继续保留。Windows粗估约90%，不按测试数换算，不将首次Mac验收当继续写代码的停止条件。


## 第五十一批记录：原片队列目录发布与保留原片重试（Windows约90%）

- 核对Android实际startPendingTransfers/processQueue：根目录在一轮执行开始固定，日期桶已在TransferTask快照内。Apple队列增加空闲时显式configureDestination，验证前后均检查worker/core.running，验证中若队列已启动则拒绝切换；运行中目标不能改变。暂时的Debug授权改选/忘记要求先等当前完成并切回沙盒，避免改掉在途绑定。不是新的Swift排队/重试策略，core所有决策仍由shared执行。
- OriginalFilesDestination仅在既有只读接口上增加授权验证和发布，ProviderOriginalStore实际符合协议。runNext先验证目标、再调用原CameraOriginalStore下载；完整沙盒原片进入stagedFiles后才await发布，返回成功后才增加完成revision/调用core.completed。磁盘复制期间字节进度可到100%但任务仍TRANSFERING；无成功发布不冒充COMPLETED，耗时包含发布阶段。取消若在实际发布完成后到达，不反报失败；发布前取消保留完整沙盒原片用于恢复。
- Provider发布新增可选originalName，默认nil完全保留旧手动路径。队列传task.file.fileName和task.destinationFolderName，目标同名候选来自shared，绝不把沙盒重名后缀带成新的相机原名；原长度/SHA256/回读/安全组件/私有part/不覆盖/清理算法不改。任务分享/图库入口仍获得app-owned原片，不把作用域已结束的provider URL交给现有ShareLink或元数据读取。
- 发布失败后单个重试取shared新taskId并转移完整原片记录；批量重试先由core.retryFailed决定资格/排除/FIFO，新ID按原in-place历史位置且文件/日期桶一致转移IO上下文，不重抄业务选择算法。重试只向provider再次发布，后者重新校验源长度和SHA256；默认沙盒路径不走保留发布原片捷径。移除/清理仅释放记录，不删除任何原片。保留记录仅当前队列内存，不能称为进程恢复/持久断点。
- Debug已接“队列保存到所选目录/切回应用沙盒”，配置成功才镜像状态并关闭旧文件页；默认新页借同一transferDestination作索引/预览源，显式只读provider入口仍保留。当前配置只在本连接有效，不声称偏好已持久化。当前目标检查使用固定授权校验，不刷新其书签；断开清理目标UI状态，验证后晚到配置不会覆盖其它连接。只有用户显式启用才改变队列目标，默认仍是原沙盒链路。
- 新增6项队列XCTest：真实provider发布且沙盒重名不污染目标名/分享源保持本地；发布未完成不更新完成状态/运行中禁止切目标/日期快照；单重试不再请求相机；批量排除与同名不同原片对应新ID；撤权在下载前失败；取消前后提交边界。新增2项publisher原名覆盖/危险名拒绝测试。共37个App Swift、242项XCTest和17项Native预览/位图用例均Mac待验。
- Windows实际230项Python（新增8项目录队列/整文件和守卫变异检查）、Xcode注册/61任务ID、原共享UI守卫、diff空白检查PASS。新增显式差异逆转换维持旧队列/publisher/探针整文件检查，而非删除旧基线；共享core/reducer、Android全部源码/Gradle/版本/打包脚本未改。无Gradle重跑/无APK/无推送；939项Kotlin/Android及Lint/Manifest仍沿用第46批，非本批执行。前检查点5921001，核对后本地提交。
- 未完成边界明确保留：Android“目标已存在相同原片时直接引用/跳过”的原规则尚待接入当前原片队列，本批延续现有iOS手动重复导出路径，不将重复发布说成最终等价；正式目录卡片/日期与自动传输/延后开始/偏好恢复、离线已有文件任务、持久恢复与效果/权益也未完成。真实provider阻塞、磁盘满、并发移动/撤权、取消和Swift协议/桥接必须Mac/真机验收。
- NEXT先接目标原片存在性与shared精确文件名/大小匹配的复用边界，再完成原共享目录设置、日期/延后开始/自动入队。完整工作区/选择/事件恢复/STA-direct/MPF/视频/遥控/GPS/效果/权益及EXIF余项继续保留；Windows粗估仍90%，不以局部闭环替换全部目标。

## 第五十二批记录：原片命中元数据与跳过状态共享接口（Windows约90%）

- 基线核对：Android TransferViewModel的findOriginal使用ExistingFileNameIndexCore；processQueue先按任务日期桶查已有原片，纯原片命中后copy为COMPLETED/skipped=true/progress=1/downloaded=本地大小/speed=0。它不设置下载耗时或下载速率，也不走实际下载后的计数；效果派生是另一条分支，本批不替代它。
- NativeOriginalFileIndex由internal开放给平台单所有者调用，增加不可变NativeOriginalMatch（实际本地名称/大小/不透明locator）；find仍委托同一ExistingFileNameIndexCore和同一日期桶键。localLocator继续取同一命中；更新版本/原子验证/替换/副本后缀/精确名优先/大小规则均未重写。locator只代表元数据，不代表文件授权或持久有效路径。
- NativeOriginalTransferQueue新增completedExisting，仅匹配当前activeId且本地字节非负才采用Android原copy字段，清空activeId/activeProgress；不添加虚构耗时/速率、不改普通completed、FIFO、暂停、撤回或重试。此接口针对纯原片阶段，不承诺效果/权益流水线已经接通。
- 新增7项commonTest：精确名优先与错误大小回退；未知相机大小返回实际本地大小及零字节不是通配；根/日期桶隔离与实际名称；重扫删除/增量替换/无效和过时更新/冻结结果；与Android跳过copy逐字段相等；等待/错ID/负字节拒绝及迟到进度/失败/完成隔离；暂停与普通下载路径保持。
- Windows实际执行：gradlew.bat :shared:testDebugUnitTest :shared:compileCommonMainKotlinMetadata :app:testDebugUnitTest，BUILD SUCCESSFUL in 1m 18s，49 tasks（10 executed/39 up-to-date）；报告汇总629 shared + 317 app = 946 tests，0 failures/errors/skipped，其中本批7项实际通过。232项Python、原共享UI整文件守卫、Xcode引用/61任务ID及diff检查PASS。第51批共享队列全文件守卫仅允许剥离这段精确新增方法，旧主体仍逐字比较；新增索引枚举差异恢复及Android原实现未改检查，未删除旧基线。
- 本批没有Swift源码变更；37个App Swift、242项XCTest及17项Native预览/位图测试仍Mac待验，JVM测试不是Native导出验证。Android业务代码、Gradle、版本、dist和dist-debug脚本未改；Release/Lint/Manifest仅沿用第46批历史证据，没有声称本批重跑。前检查点e04bbeb；本地提交，不推送、不打包。
- NEXT：把平台同一目录所有者的扫描结果交给这个shared索引，再接真实队列的已有原片引用/跳过；外部原片分享必须在固定授权和协调范围内安全读取/按需生成app-owned来源，不能把已退出scope的URL塞给现有分享入口。需要覆盖无命中下载、命中零网络、撤权/删除/目录移动、重复任务、日期桶、取消与分享失败；在这些接线完成前，仍明确标记目标复用未完成。
- 完整目录设置/日期/自动入队/延后开始/偏好恢复、共享工作区与选择、STA-direct/MPF/视频、事件恢复、遥控/GPS/效果/权益及EXIF余项继续保留。粗估保持90%，本批只是可调用且已回归的共享能力，不能代替整个iOS或Windows目标完成。

## 第五十三批记录：实际队列复用已有原片与按需安全分享（Windows约91%）

- CameraOriginalQueue每轮start新建一个NativeOriginalFileIndex，首次通过实际目标所有者扫描，之后消耗原索引的有界增量；每次查找仍验证provider授权。精确名/副本后缀/大小/根与日期桶全部调用第52批shared接口，Swift不复制命名算法，不每张照片全量扫目录。索引无效/授权失败不静默当作空目录继续下载；新一轮会重扫被外部删除的文件。
- runNext在任何相机下载/再次发布之前查目标已有原片，命中后保存同一source+不可变名称/大小/locator引用，调用core.completedExisting并发布完成revision。跳过不造下载耗时/速度、不复制目标文件；即使相机离线，已知任务仍可按目标索引完成。此前发布失败留下的沙盒文件不删除，但若重试命中目标，分享以实际命中的目标为准。原无命中下载、成功发布后完成、保留原片重试、FIFO/暂停仍保持原主体。
- OriginalQueueRow与唯一OriginalQueuePageBridge透传skipped；NativeQueuePageSnapshot只增加默认false参数及TransferTask字段赋值，原SharedTransferScreen读取同一标记显示已有/跳过，无第二套产品页面。新增1项commonTest验证实际shared页面模型保留skipped/COMPLETED/本地字节与空耗时；普通调用默认行为不变。
- OriginalFilesReusing是既有只读Actor接口的窄扩展，只增加copyOriginal；CameraOriginalStore与ProviderOriginalStore借唯一IndexedOriginalReader实现。引用只是元数据，复制前检查实际索引名称/大小和精确locator，仍使用旧根/日期目录/叶子NOFOLLOW描述符链与fstat。新增复制允许零字节并保持64KiB分块/EOF和最终长度/取消检查；普通图片/RAW/EXIF的非零默认与旧读取正文未改。
- provider复制仍在固定目录授权和NSFileCoordinator内容accessor内完成，不返回provider URL或打开的描述符。queue.prepareSavedFile先创建应用内私有part，等待源复制与协调退出，再复核预期字节、取消、fsync/关闭并按旧SandboxTransferFile命名规则发布；失败仅清理本次part。原片不被覆盖/移动/删除，分享不重新访问相机。副本位于app原片根下独立Shared Originals目录（扫描不纳入普通根/日期桶），同一历史任务后续分享可复用已准备副本；尚无跨进程分享缓存清理策略，不将其当持久恢复完成。
- 清除/移除任务只释放已有原片引用和缓存，不删除文件；分享准备期间若历史被清除，不写回已移除任务。Debug分享新请求/页面取消/断开会取消旧准备任务，先清空旧分享URL，晚到结果需核对同一队列/仍存在的taskId；失败有明确提示且不反改已完成任务状态。正式产品分享/效果/图库更多入口仍按总任务继续接。
- 新增4项队列XCTest：离线日期桶命中副本且不创建提前副本/零相机请求/按需分享缓存；同名异大小继续下载不覆盖；已存在文件删除后分享失败但历史不回退；新一轮重扫删除后重新下载。旧“同元数据重复请求两次下载”测试更新为Android目标语义：第一项下载，第二项跳过/分享ABC而非再下载DEF，原索引仅一份原片，清历史不删文件。
- 新增5项provider/reader XCTest：零字节与200KiB实际流式复制/SHA/授权平衡/不改变源索引；重扫后原片大小变化仍拒绝冻结旧引用；撤权拒绝准备；协调阻塞取消清理part保留原片；共享取消标志及叶子符号链接拒绝。共37个App Swift、251项XCTest和17项Native预览/位图测试待首次Mac编译/执行，不能算Windows执行证据。
- Windows实际：947项Kotlin/Android（630+317），0失败/错误/跳过；common metadata/Android Debug编译，BUILD SUCCESSFUL in 35s（49 tasks：10 executed/39 up-to-date）。241项Python、原共享UI整文件守卫、Xcode引用/61任务ID和diff检查PASS。新增9项接线/整文件/变异守卫，原第46～52批守卫先剥离枚举新增差异后仍逐字比较，不删除旧基线。Android业务源码/Gradle/版本/打包脚本未改；Release/Lint/Manifest本批未重跑，历史证据仍为第46批。前检查点d54f2d8，本地提交，无推送/无APK。
- 保留的边界：与Android一样，索引命中不是内容哈希相等证明，同名同大小仍按原规则复用；一轮运行期间外部删除可能使已缓存条目过时，实际分享/预览会重新验证并报错，新一轮重扫。目录权限/真实cloud占位材料化/巨型文件/磁盘满/并发编辑和Swift导出类型必须Mac及真机验收。未将原片路径推广成完整效果/权益/恢复流水线完成。
- NEXT：正式共享目录卡片实际绑定、日期整理/延后开始/自动入队偏好及跨连接恢复，确保文件页查找日期桶与队列设置一致；之后继续完整设置/工作区/选择/事件恢复/STA-direct/MPF/视频/遥控/GPS/效果/权益/EXIF余项。Windows粗估91%，全部范围不变，不以这个原片闭环提前宣称100%。

## 第五十四批记录：日期/延后开始偏好及真实入队与文件识别（Windows约91%）

- 再核对Android实际加载/保存：organize_transfers_by_date与defer_transfer_start默认false；前者影响新任务日期桶，已入队任务保存旧destinationFolderName；是否自动启动仍由shared原shouldRunQueueAfterEnqueue决定，修改选完再传本身不突然启动/暂停旧队列。
- 新增NativeTransferPreferences两个不可变值；destinationFolder直接委托原transferDestinationFolderName，未复制日期校验或副本识别算法。NativeFilesPageModel保存独立传输偏好StateFlow，修改仅更新实际状态与平台保存，不改扫描/文件/任务历史；不可读取数据按默认呈现并保留失败标记，浏览偏好成功保存不能清掉传输偏好的失败提示。
- Apple TransferPreferencesStore放在原配置源文件内，独立ztransfer.transfer.preferences键、v1 Codable、4KiB上限。首次读取不落盘；损坏/未知版本/错误类型不自动覆盖或清空，不保存bookmark、URL、相机或队列身份。不更改旧BrowsePreferencesStore正文/键/已存内容；无需新增Xcode源文件登记。
- 文件页设置使用原SharedSettingsCard/SharedBooleanSettingsWheel和原三语言文案、触感，接真实按天保存/选完再传回调。这里只显示已接通的两项；完整SharedTransferDirectorySettingsCard仍等目录原子改选与自动事件流水线接好再使用，不用一个没有行为的“实时传输”开关冒充完成。
- OriginalFilesPageBridge在创建异步入队Task之前读取model.currentTransferPreferences与当地Gregorian日期并冻结，单张/批量/预览的实际入队复用此路径。Debug入队优先借当前文件页live偏好，未开页时从同一存储恢复；同样冻结日期与选完再传，不再硬编码。已入队任务、已有运行状态和原queue/core均未改；单独的低层手动下载/发布验收探针仍保持其显式参数，不是产品偏好入口。
- 已保存徽标、未传输筛选集合、本地原片预览三处使用同一mutableTransfers.destinationFolder。页面remember键加入按天开关及当地dayKey，按天开启时每60秒轻量读取日期以覆盖空闲跨午夜，关闭时取消该时钟协程；没有扫描磁盘/相机。缺失/非法拍摄日期仍用当前当地日，已有拍摄日期按原规则。旧预览来源仍在打开时冻结，设置入口沿原链先关闭预览，不中途替换其source。
- 新增4项commonTest实际通过：传输偏好独立于浏览/目录并重开恢复、无变化/关闭后不重复保存；保存失败保留live选项且不被浏览保存清除；根/日期切换时徽标/筛选/预览一致；缺失拍摄日期跨日改查桶但旧队列任务日期不变。新增3项XCTest待Mac：首次读取/持久恢复不触碰浏览键；损坏/未来/类型/超限文档保护；真实文件页恢复日期+延后偏好后入队在回调前生成正确WAITING任务且无网络/文件写入。
- Windows实际：951项Kotlin/Android（634+317）0失败/错误/跳过；common metadata/Android Debug编译，BUILD SUCCESSFUL in 31s，49 tasks（10 executed/39 up-to-date）。247项Python、原共享UI整文件守卫、Xcode引用/61任务ID和diff检查PASS。新增6項偏好/精确旧主体/参数冻结/日期与失败路由/守卫变异检查；旧接线检查先剥离本批枚举差异再继续原全文件比较，未删除旧基线。37个App Swift、254項XCTest和17项Native预览/位图测试仍Mac待验。
- Android业务代码、原共享目录/照片设置组件、相机/原片队列执行器、Gradle、版本及打包脚本未改。Release/Lint/Manifest本批未重跑，仅保留第46批历史证据；无APK/无推送。前检查点73ba6cd，本地提交。Windows粗估保持91%，不按测试个数换算。
- NEXT：原目录卡片实际选目录。必须先准备/验证新授权而不改旧授权，再在队列空闲/禁止竞态启动的边界一起提交目标及保存授权，成功才关旧页/换同源索引，失败维持原目标；不能先覆盖全局书签后才发现configureDestination因队列启动而拒绝。随后恢复显式provider目标偏好、接原自动新文件筛选与事件调度；完整设置/工作区/选择/STA-direct/MPF/视频/恢复/遥控/GPS/效果/权益/EXIF余项仍照全表继续。

## 第五十五批记录：保存目录准备、队列提交边界与迟到配置保护（Windows约91%）

- 前检查点fadbbcd。本批仅Apple适配、Apple测试、Windows守卫和文档；Android/shared/Gradle/版本/打包脚本不变，未重跑Gradle、未打包、未推送。
- ScopedDirectoryStore先准备候选：快照旧书签，验证新目录、创建并重新解析候选授权，但不写当前书签。提交要求同一准备者，重新验证授权，并在所有实例共用的短同步锁内比较旧字节再原子写入；显式select/forget、读取和过期书签刷新都用同一锁，迟到刷新不能覆盖新选择。书签读取有1MiB硬上限，空旧文件可显式修复。仅进程内协调；不宣称崩溃事务、外部进程互斥或授权永不失效。
- ProviderDirectoryChange保留同一个候选选择与预绑定provider。queue空闲时进入提交边界，期间接受原入队规则但暂不启动worker；提交成功后无await/取消检查再设置目标。失败沿用旧目标；期间的启动合并一次，后来的暂停/停止撤销该启动，随后显式开始仍有效。在途原片禁止改目标，配置修订号拒绝迟到旧validate覆盖新选择。网络/下载/发布主体与shared调度规则未改。
- Debug现有目录改选入口已接该流程：成功后才替换provider和页面来源、关闭旧页，失败保留旧状态，断开会取消目录任务。仍未把独立书签当成“用户选择provider目标”的持久偏好；正式共享目录卡片和跨连接目标恢复在后续完成。
- 新增13项XCTest源码：真实候选/授权提交与固定provider、跨store竞争、准备者身份、忘记授权、首次选择/空文件修复、取消/撤权、迟到stale刷新、写失败；队列切换中入队/启动/暂停/停止/取消/旧验证/在途发布拒绝；真实准备对象→队列→新目录已有原片复用→按需分享且零网络的集成场景。267项累计XCTest和17项Native预览/位图仍需Mac，未在Windows运行。
- Windows实际255项Python通过，含新增8項精确旧主体/准备不写入/锁与CAS/提交后不可回滚/启动边界/迟到配置/UI顺序/守卫变异检查；37个App Swift注册、61任务ID、原共享UI整文件守卫和diff检查通过。新增枚举差异逆转换保持旧整文件检查；修正旧变异检查重复归一化，避免“缺少新字段就报错”的假阳性。
- 951项Kotlin/Android（634+317）及common metadata/Debug编译证据仍是第54批31s结果；Release/Lint/Manifest仍是第46批，不冒充本批重新执行。用户无卡紧急直存调研MD已在19eb7a9提交，原文不改，无其它新增未跟踪MD。
- NEXT：正式共享目录卡片接入实际选择入口、目标状态和失败反馈，持久化显式provider选择并在连接恢复时校验；随后自动新文件筛选/事件入队。完整设置/工作区/选择/STA-direct/MPF/视频/恢复/遥控/GPS/效果/权益/EXIF余项继续，Windows进度保持约91%，不提前收口。

## 第五十六批记录：显式保存目标偏好与重连恢复（Windows约91%）

- 前检查点ce167b6；新增生产文件OriginalDestinationPreferences，Xcode Sources注册一次。只保存sandbox/provider意图，不保存路径/书签/相机身份；授权只用于浏览或手动导出时不会推断成传输目标。版本1、1KiB边界，默认读取不写盘；损坏/未知版本/错误类型保留原数据，不静默降级覆盖。
- 成功改目录/成功显式切换队列目标之后才保存意图。偏好保存失败不会回滚已成功配置的队列，而显示“本次已生效、下次可能需重选”；不是书签与UserDefaults跨存储原子事务，不宣称断电持久化。未知偏好仍可显式选择当前连接目标，但不能自动覆盖未知数据，下一连接会继续提示，后续正式设置需提供明确恢复/重置交互。
- AP/STA持久连接在向页面暴露队列前恢复目标；每次重新创建固定授权的provider并校验，构造queue时一次传入。沙盒选择不访问任何书签；外部目录缺失/撤权/无效、偏好未知等返回明确不可用的目标，其索引/普通原片/RAW/EXIF/复制/发布七入口均报错，不返回空索引，不悄悄落到沙盒。取消会中止恢复，不伪装可恢复错误。
- 不可用目标沿用原queue的失败和重试状态，原片下载之前失败；换选有效目录或显式切回沙盒使用原空闲配置边界，成功后旧错误清除并关旧文件页。文件页默认来源仍与实际队列目标一致，Debug摘要明确显示恢复失败而不是误写“应用沙盒”。持久连接入口已实接；正式设置/工作区的产品入口仍未完成。
- 新增6项XCTest源码：默认/显式沙盒零授权访问及独立偏好；损坏/未来/错误类型/超长文档保留与不可用读取；每次重连独立provider、已有原片零网络复用；缺失授权失败零网络/零沙盒写入及显式改目录后原任务重试；恢复前及工厂阶段取消；撤权禁止发布/分享、原授权和文件不变、恢复权限后新连接可再验证。累计273项XCTest、17项Native预览/位图待Mac运行。
- Windows实际261项Python通过（新增6项恢复顺序/精确旧主体/显式意图/失败闭合/持久化时点/变异守卫），38个App Swift注册、61任务ID、原共享UI整文件守卫和diff检查通过。新接线逆转换后继续所有旧整文件检查，网络协议、共享core、provider发布、书签提交主体未改。
- Android/shared/Gradle/版本/打包脚本无差异；本批不重复Gradle，951项Kotlin/Android（634+317）/common metadata/Debug编译仍是第54批31s历史证据，Release/Lint/Manifest仍为第46批。按批本地提交，无APK/无推送；用户调研MD原文仍在先前提交中。
- NEXT：正式共享目录卡片与系统选择器/目标错误和恢复交互、自动新文件筛选与事件入队，然后完整设置/工作区/选择/STA-direct/MPF/视频/恢复/遥控/GPS/效果/权益/EXIF余项。Windows约91%，目标继续开放，不把本批当成全功能或Apple运行验收。

## 第五十七批记录：共享设置页的真实目录选择入口（Windows约91%）

- 前检查点5c7b253。SharedTransferDirectoryHeader由原目录卡片标题行逐字提取，仅调整缩进；Android原SharedTransferDirectorySettingsCard实际调用它，原三拨轮/目录回调/注意动画不改。Native设置复用同一标题/按钮及既有日期/延后拨轮，不复制另一套产品控件；未接自动事件前不显示无效自动开关。
- 新增NativeDirectorySettingsModel只管理页面系统选择请求：单所有者、单个在途请求、递增ID、匹配完成、关闭释放；取消不清掉已有授权错误。NativeFilesPageModel拥有它并在关闭时释放。该模型不保存书签、不实现队列规则或目录IO。
- OriginalFilesPageBridge通过真实UIViewController打开系统.folder选择器（asCopy=false、单选）。只接受本次controller回调，取消结束请求；选中后先关闭自己的系统选择器，再调用连接所有者已有安全提交。页关闭取消自己持有的选择器并去掉delegate；关闭后的迟到完成不回写模型。无展示宿主/其它系统窗口在显示时，直接结束请求并给出失败提示。
- 真实文件页已从连接所有者得到选择回调及当前目标/错误摘要。改选继续ProviderDirectoryChange→原queue空闲提交边界；失败保留旧页/旧目录并将错误返回设置页，成功关闭旧页释放固定来源。当前显示保存模式摘要而非完整路径；完整目录卡片的自动事件开关、更多目标恢复/重置交互及正式工作区仍未收口。
- 新增5项commonTest实际通过：重复点击与迟到/重复完成隔离、取消保留旧警告、关闭不可复活、同步宿主失败不留busy、缺失/重复绑定不发请求。Windows共639 shared +317 app =956项，0失败/错误/跳过；common metadata与Android Debug编译，BUILD SUCCESSFUL in 2m 9s，49 tasks（10 executed/39 up-to-date）。
- 267项Python检查通过，新增6项原行提取/整文件恢复/请求生命周期/真实picker所有权/连接所有者完成反馈/变异检查。旧原UI全文件检查在剥离本批枚举提取后仍继续逐字对照，没有删基线；Xcode注册38个App Swift/61任务ID和diff检查通过。273项XCTest与17项Native预览/位图仍Mac待验，本批没有假称运行Apple测试。
- Mac新增验收：从真实共享设置打开系统目录选择器，覆盖取消/重选/队列刚开始运行导致拒绝/文件页关闭/重复或迟到delegate；成功必须先关picker再关旧页，新页来源为新目标；失败必须保留旧目标与页面、显示错误；同时核对Android原目录卡片布局/按钮/注意动画未变。Windows编译/源码对照不能替代这些UI验收。
- Android app源码、协议/原片执行器、书签/publisher主体、Gradle依赖/版本/打包脚本未改。本批改shared控件后已实际重跑Debug/common回归；Release/Lint/Manifest全套仍沿用第46批，不计为本批执行。无APK/无推送，按批本地提交；用户MD原文仍保留已提交。
- NEXT：原自动新文件选择/过滤和事件调度，接通后回用完整目录卡片；目标恢复/重置与目录名展示、完整工作区/选择/STA-direct/MPF/视频/事件恢复/遥控/GPS/效果/权益/EXIF余项继续。Windows粗估91%，没有达到100%。


## 第五十八批记录：自动新文件的共享入队边界（本轮Windows约80%）

- 前检查点e575350；本批同时保存用户四项范围暂缓。只推进传图，不接会员/效果/遥控/GPS；进度沿用顶部重新估计的约80%，不沿用历史91%。
- NativeOriginalTransferQueue新增批量新媒体入口，调用现有newMediaQueueCandidates与isAutoTransferMedia；历史全部状态按原文件名/大小/拍摄时间规则抑制重复，手动传输仍可重复。候选顺序、日期目录、合并存储卡信息、元数据验证、暂停及启动继续用原实现，不在Swift另写规则。
- Apple队列新增同一actor内的接收入口，要求开启自动选项、有显式目录、参数数目匹配且未取消；成功后沿用原启动和目录提交保护。事件所有者尚未接入，入口要求仅传新发现行，不传首次完整目录；没有开启一个无实际事件来源的自动开关，本批不算自动传输闭环完成。
- 新增4项common测试覆盖原去重顺序/手动重复、所有历史状态、坏元数据/未知媒体、双卡及真正暂停后新入队。首次运行发现测试误以为空闲暂停会留下暂停状态；原执行规则只接受运行中暂停，修正样本先运行再暂停，不改生产规则。复核并修正一项既有待验XCTest的同类空闲暂停断言，目录切换中阻止启动的断言仍保留。
- 960项Kotlin/Android（643 shared+317 app）实际0失败/错误/跳过；common metadata/Debug编译，最终BUILD SUCCESSFUL in 12s，49 tasks（3 executed/46 up-to-date），首次55s已完成生产编译但测试失败，不能记作首次全通过。271项Python、原UI整文件守卫、Xcode结构和diff检查通过。
- 新增3项XCTest源码：开启/目标/取消及并发重复事件、真正暂停后的入队/完成后抑制、目录提交期间入队最终写入新目标。38个App Swift、276项XCTest及17项Native预览/位图均仍Mac待验；不宣称Apple编译运行通过。
- Android app业务源码、已有共享队列/媒体规则、网络协议/文件执行器、Gradle/版本/打包脚本未改；新增共享Apple适配入口后已跑上述回归。Release/Lint/Manifest全套仍是第46批历史证据。无APK/无推送，按批本地提交。
- NEXT：按Android首次扫描基线/新增事件/移除和重扫规则接入真实发现来源，不能把首次旧目录自动入队，也不能只用UI刷新修订号冒充无丢失事件流。然后自动设置及完整传图工作区；Windows目标继续开放。


## 第五十九批记录：连接内有界事件记录（本轮Windows约80%）

- 前检查点5bedb81。真实AP/STA事件接收已将shared解码得到的code/transactionId/firstParameter连同revision保存，再发布原最新状态通知。PING仍仅PONG、不增加事件计数；不完整事件沿用原解码拒绝行为，不自行重写协议。
- 记录保留最近256条，重复事件不去重、顺序不重排。读取带connectionID/revision游标，不消费记录，不新增AsyncStream或消费者；首次读取、其它连接、未来游标、记录缺口返回空事件+requiresRescan，不能把残存尾部当完整日志。溢出后重扫时应保留扫描前游标，随后再读期间事件，不能在扫描完成后跳到最新游标而漏变化。
- 读取只允许ready且未取消，关闭清理记录；迟到接收只能在opening/ready写入。revision达到上限关闭连接，禁止回绕旧游标。全部是同一连接actor内的记录，不开第二个socket、命令队列或产品状态层；命令执行、保活/下载/取消主体精确恢复后与上一提交一致。
- 新增4项XCTest源码：AP/STA分片事件流、重复/移除/未知事件与32位无符号字段、可重复读取；容量边界/缺口不返回尾部；错代/未来/取消/关闭；PING及短载荷后正确事件。累计280项XCTest、38个App Swift及17项Native预览/位图仍需Mac编译运行，不冒充Windows执行。
- Windows实际275项Python、原UI整文件守卫、结构和diff检查通过；新增4项接收/单代/有界/整主体/变异守卫。补充最新枚举逆转换接到旧链路，旧EXIF直接读取守卫也先剥离本批变化，所有旧完整主体比较保留。
- Android app/shared/Gradle/版本/打包脚本均未改；960项Kotlin/Android（643+317）为第58批本轮已验证证据，本批不重复Gradle；Release/Lint/Manifest仍第46批。只本地提交，无APK/无推送。
- NEXT：相机首次handle基线、成功扫描的新增差量、单文件新增/移除和缺口重扫消费，再与已写自动入队入口和正式自动开关连接。当前只完成接收与入队两端边界，中间消费尚未接通，不能宣称自动传图功能完成。完整传图工作区及其它本轮任务继续，Windows约80%，未到100%。


## 第六十批记录：W01首次扫描基线与后续差量（总计划80.4%，1/50）

- 前检查点42abf5b；同时提交用户要求的独立剩余任务表和入口链接。50项固定计分，W01本批WIN-DONE得1分，收尾2.0%、总计划80.4%；不把建表或旧第58/59批再计分，下一项W02。
- 新增NativeCameraHandleBaseline，复用原cameraHandleDelta。每个真实CameraCatalog连接所有者独立持有；原始跨卡handle在shared中去重并拷贝，不按文件名/媒体/符号位筛选。首个成功枚举仅建立基线，首个空目录同样有效；关闭新增检测仍更新基线并保留移除差量，避免以后把旧文件补报成新文件。
- 真实refresh在所有存储卡枚举成功且连接代/取消校验通过后提交基线，先于ObjectInfo读取，与Android CameraViewModel原顺序一致。后续元数据部分失败/取消不撤销已成功的handle基线；枚举失败、枚举后取消/断开/错代不提交。部分文件快照仍沿用原保护，不能将metadata读取失败当删除。
- CameraCatalogSnapshot返回可选handleDelta，新增显式初始化器保留旧调用默认；refresh的detectNewHandles默认false，不改变原手动刷新入口。它仅是原始编号差量，不等于已验证可发布的新媒体；事件消费/旧逻辑身份去重/删除发布/自动开关按W02—W06继续，不能宣称自动传输闭环完成。
- 6项新增common实跑：首次目录、空卡、禁用检测仍更新、双卡重复/带符号handle与输入拷贝、重连独立所有者、2048组组合直接对照原shared差量函数。共649 shared+317 app=966项，0失败/错误/跳过；common metadata/Android Debug编译BUILD SUCCESSFUL in 43s，49 tasks（10 executed/39 up-to-date）。
- 新增4项XCTest源码覆盖真实目录路径的首次/后续/关闭检测、空卡/首次部分元数据、第二卡失败/枚举后取消/关闭/错代、元数据阶段取消仍保留基线但不覆盖旧列表。累计284项XCTest、38个App Swift及17项Native预览/位图仍Mac待验，不将源码检查算Apple运行。
- Windows279项Python、原UI完整主体守卫、结构和diff检查通过；新增4项顺序/同代/共享委托/变异守卫，并通过枚举逆转换继续旧整文件比较。Android app业务、原catalog规则/扫描器、Wi-Fi协议/队列执行器、Gradle/版本/打包脚本未改。Release/Lint/Manifest仍第46批历史证据，本批未重跑；无APK/无推送。


## 第六十一批记录：W02-A原新增对象规则共享化（总计划80.6%，1.5/50分）

- 前检查点8484b35。按剩余任务表原拆分规则，W02分为共享规则提取A和Apple事件调度接线B，各0.5分，总分仍50；本批仅A达Windows门槛，W02整体仍DOING。当前完整主项1/50，得分1.5/50，收尾3.0%、总计划80.6%；下一项W02-B，不能宣称真实新增消费或自动传输已完成。
- NewCameraObjectPolicy提取原handle准入、首次匹配行发布、真正新增判定和重试常量。无基线/已知handle/可见行、无效0/-1、同名同大小同时间的备份归属合并、保持主行元数据、无变化返回原List/原状态引用均不改变。时序仍90ms合并、每批16、最多5次，失败间隔180/360/720/1400ms。
- Android CameraViewModel仅四处枚举委托差异：入队准入、失败延迟取值、列表发布/added判定、常量引用；原循环/协程所有权/时钟/扫描与FHD门控/读取协议/迟到移除防护/新媒体emit及缩略图唤醒顺序不动。新helper在getAndUpdate中仍为纯函数，重试执行不会带入IO；没有另造Swift业务算法。
- 新增7项common测试：有效/无效/有无基线与可见handle、前插顺序与原对象引用、备份扩卡且不算新增、同handle不替换原元数据、优先第一个匹配行、精确节奏与越界契约、399组发布和1197组准入组合对照提取前算法。
- Windows实跑656 shared+317 app=973项，0失败/错误/跳过；common metadata/Android Debug编译BUILD SUCCESSFUL in 1m 5s，49 tasks（12 executed/37 up-to-date）。283项Python、原共享UI整文件守卫、结构和diff检查通过。一个旧EXIF整ViewModel守卫初次因本批委托差异失败，补最新枚举逆转换后继续对照旧完整主体，不删除或放宽旧检查；另有新变异检查确保无关保活变化不能被归一化隐藏。
- 本批无Apple生产改动/新增XCTest，38个App Swift、284项XCTest及17项Native预览/位图仍Mac待验。Android业务文件有受控共享委托，不称Android零改动；协议、服务、Gradle/版本/打包脚本不变，未发现回归不等于已做最终真机验收。Release/Lint/Manifest仍第46批历史检查，本批未重复执行；无APK/无推送，按批本地提交。


## 第六十二批记录：W02-B真实新增事件解析与发布（总计划80.8%，2/50分）

- 前检查点9a65a60。本批W02-B达Windows门槛，原0.5分计入W02，W02整体WIN-DONE；W01/W02共2个主项、2/50分，收尾4.0%、总计划80.8%，下一项W03。正式Release工作区仍待W07，不把现有真实诊断入口当成品页面验收。
- CameraHandshakeProbe复用唯一connection.updates观察者，按连接代从revision零读取有界记录，避免第二个AsyncStream消费者抢通知；事件记录只登记到该连接的CameraCatalog，由独立串行worker读取GET_OBJECT_INFO，不阻塞事件转发。打开连接期间仍保留的通知也能读到，溢出不伪装完整日志。
- 每个目录所有者保留首次成功handle基线、待解析顺序、对象token、扫描代及独立发布版本。复用shared的0/-1/已知与可见handle准入、90ms合并、每批16、最多5次及180/360/720/1400ms失败间隔。扫描/整页预览占用仅暂缓，不消耗失败次数；连接实际命令排队后、分配TID/发包前再次检查准入。传输异常停止worker，不能在失效通道上连续重试。
- 读取返回后复查连接代/状态、token、扫描代及socket事件revision。已收到但尚未转发的通知不允许旧读取抢先发布；移除撤销包括在途的待解析token，移除再添加属于新token。关闭取消worker并拒绝迟到写回；完整扫描已纳入的handle不会再报告新增。
- PtpObjectInfo到CameraFileInfo保留Android既有字段/未知大小/storage哨兵处理；文件夹/无文件名不发布，未知扩展名可见但不报告为自动媒体。shared原isNew/publish负责真正新增、前插和备份卡归属合并，不替换主行名称/大小/日期。Native基线recordPublished只有已有枚举基线才追加，不用事件假造首次基线。
- 发布到已有OriginalFilesPageBridge和CameraPreviewStore，不另建Swift业务列表。页面合并最新快照，等待原扫描/入队结束后交给同一个NativeFilesPageModel；不为每个新增事件发起全量网络扫描。页面和预览缓存以发布版本拒绝旧快照，缓存同步新文件允许身份，避免新增行与缩略图索引脱节；关闭页面取消待发布工作。
- 边界明确保留给后续：首轮没有完整latest前暂存事件，首次完整目录建立后才解析；元数据部分失败/扫描有事件竞争仍按原保护保留旧列表。删除现有行/属性/存储变化W03、缺口和扫描竞争的自动重扫/追赶W04尚未实现；当前移除/缺口置needsEventRescan并暂停新增解析，须显式成功稳定扫描解除。自动开关/真实入队W05未启用；真正新增媒体目前只回调/提示，不声称自动传图闭环。标准AP/STA之外的STA-direct仍归W12—W15。
- 新增4项common实跑：发布不制造基线/后续枚举替换、已知与可见handle、未知大小/身份不全/storage哨兵/保护字段、文件夹/空名/未知扩展与原媒体判定。660 shared+317 app=977项，0失败/错误/跳过；common metadata/Android Debug编译BUILD SUCCESSFUL in 41s，49 tasks（10 executed/39 up-to-date）。
- 新增12项XCTest源码：初始旧对象/无效/重复/双卡/未知文件、Busy成功与最多5次、基线/预览让路、扫描覆盖在途结果、移除再添加token、socket与观察者滞后、缺口/错代/关闭、传输异常停止与显式恢复、真实拒绝准入无发包/TID消耗、真实Busy/坏载荷/随后成功事务、页面扫描等待与旧版本拒绝、缩略图准入同步与旧缓存拒绝。累计296项XCTest、38个App Swift及17项Native预览/位图仍待Mac实际编译运行。
- 290项Python、原共享UI完整主体守卫、结构和diff检查通过。新增7项实际路由/共享调用/顺序/版本/变异检查；本批7个生产文件的枚举逆转换回9a65a60整文件后继续原守卫。修正旧测试read已经逆转换又重复转换的问题，元数据保留条件仍受严格守卫，未删掉旧检查。无关事务号/扫描推进变异仍可被发现；源码守卫不等于Swift并发测试运行。
- 本批Android app源码、服务/协议、shared既有UI、Gradle/版本/打包脚本未修改；仅shared新增Apple所需的轻量字段映射/基线访问接口，原Android共享调用不变。Release/Lint/Manifest仍第46批历史证据，本批未重跑；无APK、无推送，按授权详细本地提交。最终Android三连接真机等价与Apple实际运行均不由本批Windows检查代替。


## 第六十三批记录：W03-A全别名索引及共享删除核对入口（总计划81.0%，2.5/50分）

- 前检查点e216b1d。执行前将W03一分拆成A/B两个独立半分子项：A为全别名索引与原规则Native访问接口，B为实际删除/对象属性/存储卡事件的IO调度及页面/缓存更新；总分仍50。本批仅A达Windows门槛，完整主项仍2/50，得分2.5/50、收尾5.0%、总计划81.0%；下一项W03-B，不宣称删除事件闭环已经接通。
- 发现的iOS准备缺口：Native扫描器内部保留隐藏备份ObjectInfo，但Apple完整快照原来只遍历合并后可见行，丢掉副卡别名。这会妨碍后续轻量删除核对时选择仍存活的备份；它是iOS适配缺口，不是Android回归，也不是相机照片被实际删除。
- NativeCameraCatalogScan新增按首次成功接收顺序保存的handle索引及O(1) indexedObjectInfoAt。文件夹、失败/无名对象不进入文件索引；非空回退名但身份不完整的对象仍保留原不完整标记。旧查询/扫描倒序/双卡归并/主行选择/总数/失败处理不改，重复handle不复制索引项。未通过遍历HashMap或对handle数值排序来重建真实读序。
- CameraCatalog完整扫描现在把所有索引元数据带入objectInfos和显式indexedObjectInfos，新增发布延续旧索引并追加新对象；合并备份后不丢副卡ObjectInfo。仅使用已经读到的元数据，不增加相机命令、不再扫一遍目录。旧fixture构造保留可选参数默认并采用确定性顺序；生产两个构造点均显式传递真实顺序。部分扫描依然不能替换旧完整快照，包括它的完整别名索引。
- NativeCameraCatalogReconciliation是窄共享入口：nullable currentHandles区分失败/不完整枚举与成功空卡；字段转换复用NewCameraObjectPolicy，稳定LinkedHashMap传给Android已实际调用的reconcilePublishedCameraFiles，未重写逻辑身份/主别名替换/卡归属合并算法。它只提出重建后的行，不修改实时目录、不自行读相机、不生成新增媒体事件。W03-B负责调用前验证所有查询成功及连接代，并接实际页面和缓存发布。
- NativeCameraHandleBaseline.acceptIdleEnumeration复用原cameraHandleDelta和Android applyIdleHandleCatalog的remove-only转换；没有已成功的基线或传入null时不变，成功空卡可移除已知handle。新发现的handle不立即纳入knownHandles，允许resolver继续读取/后续核对重试，只有recordPublished才追加；原完整扫描acceptEnumeration保持原语义。
- 新增10项common测试，另加强原双卡扫描样本：目录索引过滤/不完整身份/越界及重复不排序，idle首次/失败/重复/发布转移和1024组旧规则组合，主卡删除副卡保留/副卡删除收缩归属/全删、多个幸存别名按索引顺序选主、未解析现有行保留/未知新增不擅自发布、384组行重建直接对照原共享内核。670 shared+317 app=987项，0失败/错误/跳过；common metadata/Android Debug编译BUILD SUCCESSFUL in 50s，49 tasks（10 executed/39 up-to-date）。
- 新增3项XCTest源码：真实双卡扫描保留隐藏别名并通过Native接口提出副卡替代、第二次部分元数据失败保留旧全索引且null不等于空卡、Native idle基线跨桥契约；原新增事件样本增加全索引延续断言。共299项XCTest、38个App Swift和17项Native预览/位图仍Mac待编译运行；没有声称这些Apple场景已执行。
- 298项Python、结构、原共享UI整文件守卫及diff检查PASS。新增8项明确的全索引/旧主体恢复/真实生产构造/共享委托/idle状态/变异守卫；仅3个旧生产文件枚举逆转换至e216b1d，继续旧整文件对照；新facade另作委托检查。Android app、旧重建内核、网络IO、队列、现有页面和缓存实现、Gradle/版本/打包脚本未改。Release/Lint/Manifest仍第46批历史证据，未重复执行，无APK/无推送。
- W03-B审查注意：Android相册事件入口目前只直接处理ObjectAdded/ObjectRemoved，设备属性事件在遥控页另有处理；不能把设备参数变化当作文件被删除。后续对象属性/存储卡适配须核实协议含义并记录平台边界，不修改Android原行为。W04完整缺口/扫描竞争追赶、W05自动开关、W07正式入口仍未完成。
- 一并提交此前用户要求的docs/测试与验证/iOS首次Mac操作指南.md和docs/iosApp入口链接：覆盖环境版本、推送/同步前提、模拟器、Debug真机一张JPG、现有验证脚本及错误回传；文档不另计完成分。本文记录的是本地检查点，Mac仍需在明确推送后拉取最新提交。
