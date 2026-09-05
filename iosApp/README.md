# Z传 iOS 工程

`iosApp` 是 Z传的 iOS 薄壳，和 Android App 共用根目录下的 `shared` Kotlin Multiplatform 模块。

Android 业务共享化阶段已完成：`shared`承载平台中立协议、目录、队列、遥控/GPS、EXIF、效果、会员规则。用户已批准继续受控UI共享化：CMP 1.8.2已启用，原主题/图标/进度等组件已搬入shared并被Android实际调用；原Activity、Service、网络/传输流程仍保留。完整页面与Apple系统适配尚在填充。

## Mac 首次准备

1. 安装与 Kotlin 2.2.21 兼容的 Xcode，并至少启动一次完成组件安装。
2. 安装 Android Studio、Android SDK 35 和 JDK 17。因为这是同一个 Gradle 工程，Xcode 构建共享模块时也需要能够配置 Android 模块。
3. 在仓库根目录创建不提交的 `local.properties`，配置 Mac 上的 Android SDK 路径，例如：

   ```properties
   sdk.dir=/Users/你的用户名/Library/Android/sdk
   ```

4. 用 Xcode 打开 `iosApp/ZTransfer.xcodeproj`。
5. 在 ZTransfer target 的 Signing & Capabilities 中选择自己的 Apple Developer Team。
6. 选择 iPhone 模拟器或真机运行。

## 开始编写 iOS 代码

完整实现账本见 [iOS实现任务清单](../docs/技术调研/iOS实现任务清单.md)。当前有33个App Swift文件、172个XCTest场景及12项iOS位图Native测试，均待Mac编译/运行；586项共享测试、315项Android测试、165项辅助脚本及common metadata/Android Debug与Release编译/双模块Lint已在Windows通过（第四十批2m 57s）。按用户定义，Windows可做工作全部结束为100%，当前粗估86%；不等于iOS成品或真机验收进度。

Debug新增“检查共享Compose组件”：UIKit容器显示commonMain的主题、图标、进度、材质按钮、连接卡片、拨轮、帮助提示与烟花，并提供触感验收按钮，不复制SwiftUI产品页面。颜色/字号/动画/几何有原样源码检查；Android依赖升级的差异与未验收默认样式见任务清单。Android位图/触感适配已随组件移至shared/androidMain，原行为保留；系统栏仍在app，不把探针当正式完整UI。

完整队列正文/列表/动画/徽标/确认与操作编排已迁SharedTransferScreen，Android通过最小状态与回调真实接入，原状态收集、图片加载、格式化和队列执行仍留在平台侧。iOS原片队列已补真实文件元数据/耗时/完成速度、批量撤回/带排除集重试/安全移除入口；已接MainActor状态桥与同一SharedTransferScreen，可从Debug持续连接页面点击“打开共享队列（真实任务）”检查。页面采用真实任务/缩略图/进度，操作等待actor结果，关闭页面不会停止队列。SignalPill已接真实AP/STA状态（无RSSI不伪造格数），原版开始/暂停按钮已接并通过Windows回归；完整工作区顶栏、效果/已有文件离线重试及Release产品导航仍待完成。组件探针中的队列样本仍明确标注非真实传输，不访问网络或操作真实队列。

完整原缩略图网格已迁`SharedThumbnailGrid`并由Android实际调用：日期收合、连拍合集/展开、角标、局部进度和预览手势保留原实现；平台侧只供图片、已有文件查询、语言文本及生命周期进度订阅。iOS完整标准目录/512px缩略图/单张及整组入队已接该网格，可从Debug持续连接页“打开共享文件浏览（真实目录）”进入；空队列也可打开，并可在同一控制器中切共享队列。扫描失败/部分元数据/事件竞争保留原列表，关闭页面不停止真实传输。仍待Mac编译和真机运行；页内明确显示接线中，完整预览/选择/其余设置及自动事件尚未完成，沙盒已保存文件索引已接，不是Release产品浏览页验收通过。

完整原筛选弹层、日期编辑/松手提交拨轮与通用AnchorPopup已共享，Android真实调用且保留原Java日历、语言资源、屏宽及返回键。Native已接真实目录多条件筛选、空卡、本地Gregorian日期与同源原片索引；两端共用原未传输退场协调器。首次索引未就绪禁用未传输选项；列数/连拍合并及筛选已保存恢复，恢复未传输时等待索引就绪；后台日期优先已接，仍待其余设置和完整预览。没有复制第二套产品筛选页。

原分页/连拍展开返回/来源会话快照/上滑意图规则已共享，9项原测试随之迁到common；原预览单页/FHD渐显/连拍堆叠/EXIF信息条和导航/入队按钮已共享并由Android调用；预览/遥控共用的直方图统计、绘制、图标及预览开关也已共享，Android保持原像素读取与调度，Native位图读取已有待Mac用例；完整分页/FHD/EXIF/邻页预读取消/连拍切换/入队飞行协调器已迁SharedPhotoPreviewOverlay，Android原入口实际调用；URI/图片解码/资源文案/生命周期进度等仅保留平台适配，Native完整接线仍待完成。原单图预览/缩放手势/旋转按钮已共享：Android完整列表预览与单图预览使用同一个viewport，保留原双指/双击/旋转/关闭和动画参数。Debug真实相机或滤镜预览后可点“检查原版单图缩放/旋转（真实预览）”；PNG由ImageIO归一化、限2048边/20MiB，经NSData批量复制接共享组件，打开时冻结图片，内存警告/切后台释放。仍待Mac编译与手势/截图/性能验证；这不是完整iOS预览已接通：共享协调器虽已迁完，Native目录入口/真实FHD与EXIF/本地原尺寸读取/异步入队确认及返回定位仍待接。

`Configuration/BrowsePreferencesStore`仅持有应用私有版本化浏览偏好；列数2～4、默认3列/开启连拍合并来自Android实际恢复值及shared校验。未知版本/损坏数据保留并提示，卡槽不落盘。新增UserDefaults隐私理由声明已登记到资源，完整应用/依赖隐私审计仍是发布门槛。

真实沙盒原片索引由既有CameraOriginalStore actor持有：根目录与原日期桶扫描、失败/取消保留、完成保存后增量记录和1024条有界日志；页面通过原唯一队列观察者按完成计数更新，原网格已保存徽标调用共享文件名/大小匹配。清空队列不清索引或原片，重新打开store可重新扫描磁盘。仅排除应用私有临时文件，保留合法点开头原片；不跟随符号链接。所有Apple文件系统行为仍待Mac，Files provider索引、实际预览定位和完整工作区尚未完成。

真实缩略图磁盘缓存已接入同一CameraPreviewStore：复用共享机身身份/文件键/90天规则，完整无事件竞争目录才清理旧缓存；未知机身仅按连接隔离，迟到/断线请求不能重新写入已移除结果。缓存损坏/链接/系统清缓存处理和8项新增Apple测试源码待Mac验证。同一连接级owner已接原共享ThumbnailFillQueue：完整扫描后补图、日期优先、执行中传输/前台占用让路、失败等真实变化重试；FIFO拿锁后再判准入，不占TID、不取消在途帧。磁盘写失败停止后台，关页不停止；扫描批次交错填充、完整预览/遥控页门控和裁黑边仍待接。

Debug页支持手动IP或STA Bonjour候选、AP/STA标准持续会话和显式配对；配对仅在用户开启后提交，权威ACK先落盘再等待相机提示。短程握手探针仍保留。加入对应Wi-Fi后，点击按钮才访问网络；超时不直接判断为拒绝权限。

持续模式初始抽样20个对象，也可手动扫描完整标准目录（仅展示前20行）。可下载原文件、原片FIFO排队/暂停/重试、分享实际文件、手动加入系统图库和查看真实缩略图/AP FHD。后台/退出关闭网络。这个界面仅是Debug验收工具，不是正式共享产品UI。

网络实现位于 `ZTransfer/Network`。`CameraTCPStream` 管理 Apple 网络 I/O；`PtpIPChannel` 使用 `ZTransferShared` 的现有 codec，不重写协议。载荷分块直接交给 Data sink，文件内容不逐字节穿越 Swift/Kotlin 桥。产品 UI 仍按照原方案迁入共享 Compose，SwiftUI 探针仅用于开发验收。

`PtpIPCommandSession` 为metadata/data-out/流式文件提供同一完整事务FIFO；文件每块至多64KiB，检查TID并读完最终响应。`CameraWiFiConnection`（原APCameraConnection）持有双通道/连接代次、STA初始化、下载全程保活抑制。`CameraCatalog`调用shared逐卡倒序/逐头归并/双卡备份规则。`CameraOriginalQueue`调用已有shared队列和reducer。`CameraPreviewStore`合并同键请求、区分临时失败和确定无图，编码缓存上限32MiB/256项。

`Storage`只负责Apple文件和媒体系统：本次独占临时文件、关闭后无覆盖发布、SHA256、addOnly PhotoKit、方向修正及受限输出尺寸解码、系统复制导出及Files目录书签。目录授权不代表下载已改写到provider；尚无provider协调IO、持久断点恢复或完整图库相册管理。原片队列已接真实字节进度/速度及迟到隔离。

`GPS`已有前台CoreLocation/GEO共享编码、SecRandom/CommonCrypto配对primitive及共享四阶段适配、可注入的GATT FIFO和CoreBluetooth扫描/连接/顺序订阅。Debug定位仅本地检查编码，蓝牙页只连接/订阅，不向相机发送身份或坐标。GATT就绪不表示GPS认证或OS配对成功；完整认证调度/身份保存/写坐标与恢复仍待接线。

STA-direct、MPF/RAW预览、完整事件/自动入队、共享UI、遥控/完整GPS/效果/权益仍未完成。

照片适配已有`PhotoMetadataReader`（ImageIO属性→共享EXIF/显示规则）及`PhotoFilterPreviewRenderer`（4MP sRGB/alpha转换→4096像素分块调用共享内核）。Debug可读取已下载照片元数据、查看首个内置滤镜80%预览；不会改原片或导出效果成片。原尺寸成片/相框水印、完整色彩/透明边缘对照与性能验收仍未完成，172个XCTest也未在Mac运行。

### Mac 一键验收（M1）

完成上面的SDK/Xcode准备后，在仓库根目录运行：

```sh
python3 iosApp/scripts/verify_on_mac.py
```

脚本自动选择可用iPhone模拟器，串行执行Native共享测试、Debug XCTest和无签名Release真机架构编译。日志、`Tests.xcresult`与`report.json`保存在被忽略的 `iosApp/build/verification/` 独立目录；失败即停，不签名发布、不自动改配置。可用 `--preflight-only` 只检查环境，或 `--simulator UUID` 指定已有模拟器。脚本前置选择与结果判定7项测试已在Windows通过，Mac执行步骤尚未运行；成功也不等于相机真机或商店交付验收。

用户已要求继续所有Windows可写工作；首次Mac编译是验收门槛，不再是继续写源码的停止条件。Windows无法证明Swift导出/并发/链接或Apple系统行为正确，任务账本必须保留这些未验收状态。

首次在 Mac 执行测试（`IOS_SIMULATOR_ID` 使用 `xcrun simctl list devices available` 得到的真实设备 UUID）：

```sh
xcodebuild -project iosApp/ZTransfer.xcodeproj -scheme ZTransfer \
  -configuration Debug -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_ID" \
  CODE_SIGNING_ALLOWED=NO test
```

另执行 `./gradlew :shared:iosSimulatorArm64Test` 验证 Native 共享测试。尚未执行的命令不得记为通过。

Windows 可运行 `python iosApp/scripts/check_structure.py` 检查 Xcode 引用、源码入编、Scheme 和任务 ID；它不会编译 Swift，也不能验证 Kotlin/Native 导出的 Swift 名称。

当前结构已在填充iOS实现，按以下边界落位；Mac补共享framework/Xcode链路验收：

- 跨平台模型、协议和业务规则：`shared/src/commonMain/kotlin`。
- 需要由 Kotlin 调用且适合窄接口封装的 Apple 实现：按真实需求放入 `shared/src/iosMain/kotlin`。
- 只有确实需要 `expect/actual` 的小型 Android 适配才放入 `shared/src/androidMain/kotlin`；现有 Android 系统实现继续留在 `app`。
- Swift App 生命周期、系统授权跳转和暂时无法共享的原生界面：`iosApp/ZTransfer`。

第一步是 `M01`：确认 Xcode 能构建并导入 `ZTransferShared`、模拟器能启动。随后进行本地网络授权和 Wi-Fi PTP/IP 真机探针；平台 transport 只负责 Network.framework I/O，复用 `shared` 中已经完成的协议 codec 和连接决策。Compose Multiplatform UI 仍按页面逐步启用，单独验证 Android 依赖与页面行为。

仓库包含共享的 `ZTransfer` Scheme。Mac 首次拉取后可先执行无签名的模拟器构建验收：

```sh
xcodebuild \
  -project iosApp/ZTransfer.xcodeproj \
  -scheme ZTransfer \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

然后在Xcode选择开发者Team，连接真实iPhone，验证相机Wi-Fi和系统权限。源码实现可以继续；发布和等价性结论必须等待这些实测结果。

Xcode 的第一个 Build Phase 会调用：

```sh
/bin/sh ./gradlew :shared:embedAndSignAppleFrameworkForXcode
```

它会先构建 `ZTransferShared.framework`，再编译 Swift 薄壳。工程已关闭 User Script Sandboxing，并把脚本放在 Compile Sources 之前，与 Kotlin 官方的 Direct Integration 方案一致。

## 目录职责

- `shared/src/commonMain`：只能放 Android 和 iOS 都能编译的代码。
- `shared/src/commonTest`：共享逻辑测试。
- `shared/src/androidMain`：有真实 `expect/actual` 需求时才建立的 Android 小型适配。
- `shared/src/iosMain`：有共享 Kotlin 调用方时才建立的 Apple 小型适配。
- `app`：现有 Android 应用入口和 Android 专属能力。
- `iosApp`：iOS 应用入口、签名、权限和 Apple 专属配置。

## 迁移约束

1. 不批量移动现有 Android 源码。
2. 每次只迁移一个已经有测试覆盖的纯 Kotlin 单元。
3. 先让 Android 使用迁移后的共享实现，再实现或验证 iOS。
4. Android 专属 API 不得进入 `commonMain`。
5. 每次结构迁移后都必须运行 Android 单元测试和 Debug 构建。
6. iOS 真机能力只能在 Mac 和真实 iPhone 上验收，Windows 构建不作为 iOS 通过依据。

## 版本

- 产品版本：1.81
- Android `versionCode`：54
- iOS `build number`：54

两个平台保持相同的用户可见版本号，各自维护商店要求的内部构建号。


### 正式预览读取准备（第二十九批）

现有OriginalFilesPageBridge已绑定NativePreviewReadSession：借用现有相机/缓存，独立页代次与请求取消、32槽限额、前台令牌配对；FHD只取高清、不抢EXIF之后才允许的缩略图兜底。正式FHD采用1920长边、保留相机像素方向，经NSData一次有界复制到共享图片载体；原诊断/网格方向处理不变。原片来源沿用真实索引，但本地全尺寸读取、EXIF、正式图片适配、异步入队确认和产品预览入口仍待接，不能把读取接口当完整预览已完成。新增6项XCTest仅已写，Swift/Native互操作、ImageIO方向/像素与生命周期仍待Mac验证。


### 预览真实入队确认（第三十批）

原共享预览新增可选异步入队接点，只有实际接受整个请求后才复用原飞行动画；等待中的重复点击不重复入队，部分接受保持真实队列与原提示，翻页/关闭后迟到结果不播放旧页动画。Android不传该接点，仍走原同步分支。825项共享/Android测试、125项脚本及编译/Lint在Windows通过；Native正式预览入口仍须与EXIF/本地原片及图片适配一起接通，不把接口准备算成成品页面。


### 本地普通原片读取（第三十一批）

本地来源在打开预览读取会话时按真实索引冻结，离线可读；同一相机队列持有的原片存储验证精确URL、文件归属/长度与非符号链接描述符，分块读取并成对释放。普通图片完整解码、保留原尺寸和像素方向，不套用FHD或诊断图缩放。读取自身超时返回miss以继续原回退流程，翻页/关闭取消仍传播。830项共享/Android测试、130项辅助检查及编译/Lint通过；136个XCTest仍仅已写。RAW最大内嵌JPEG规则尚在Android平台文件，不能直接用ImageIO RAW解码替换；EXIF、实际图片适配和正式预览入口仍须继续，不把接口准备当作整页完成。


### 实际位图与共享缩略图缓存（第三十二批）

真实网格使用的NativeGridImages现提供预览适配：同一份32MiB/128项缓存，关闭预览不清父缓存；FHD/本地PNG真正解码为Compose ImageBitmap并释放临时Skia Image。禁止触网时仍能读取内存/磁盘缓存，不发或等待相机请求，本地未命中不影响后续远程尝试。833项共享/Android测试、135项辅助检查和编译/Lint通过；新增Native实际解码用例后共11项Native位图测试、139个XCTest仍待Mac。完整预览入口与EXIF/RAW/页面状态仍待整合。


### RAW索引解析共享（第三十三批）

原Android TIFF/JPEG索引与日期纯解析现位于shared/preview/NefPreviewMetadata；Android保留原入口委托，连接收发与本地按解码像素数选图完全未动。新增8,256组字节差分样本及完整源码守卫，847项共享/Android测试、139项辅助检查与编译/Lint通过。旧解析面对损坏极端偏移仍可能抛异常；Native桥接必须在Kotlin侧隔离失败。Native RAW安全分段读取/实际选图仍待接，不表示已能在iOS打开RAW，Apple目标尚未编译。


### 本地RAW真实输入适配（第三十四批）

Native已沿用现有原片所有者，按共享16MiB索引与候选规则安全分段读取；按真实解码像素数选JPEG，等面积不替换，胜者保留完整尺寸与原方向。普通原片和RAW复用同一目录/文件描述符归属校验、预览请求槽与取消；畸形TIFF异常在Kotlin桥内隔离。855项共享/Android测试、144项辅助检查及编译/Lint通过；147个XCTest和12项Native位图测试仍待Mac。正式预览入口尚未启用，EXIF、完整会话与页面上下文仍需继续填充。


### 原预览EXIF共享（第三十五批）

PreviewExifPolicy提取Android原Float/字段回退/GPS/日期规则，保留惰性标签读取；Android只更改纯解析委托，不动缓存/相机/本地读取。Native值载体与专用数字适配已写，区别于相框元数据：只有EV使用ROOT，其余随Locale。868项共享/Android测试、149项辅助检查和编译/Lint通过；150个XCTest/12项Native位图测试仍待Mac。ImageIO属性/真实EXIF读头与缓存、正式完整预览会话仍需接入。


### 本地EXIF实际读取（第三十六批）

已有原片所有者经安全描述符→dup/pread随机访问→ImageIO真实属性→shared原预览规则返回PhotoExif；不会整文件载入、重新打开任意路径或固定截断本地RAW元数据。读取与原会话共用冻结来源/槽/取消，GPS保留已解码Double精度与原引用规则。874项共享/Android测试、155项辅助检查与编译/Lint通过；157个XCTest/12项Native位图测试仍待Mac。

正式预览仍未启用：已锁定ImageIO小数化与原RATIONAL的Float运算在36293949/725879001处会影响0.05EV显隐，下一批须补原始分数来源覆盖，不能把本批视作EXIF完全等价。相机文件头、稳定缓存和完整页面会话也仍待接。


### 原始EXIF分数覆盖与真实库对照（第三十七批）

本地描述符读取现补入原始五项RATIONAL：光圈/曝光时间按Android兼容Double属性，其余保留分数后交给shared Float计算，零分母归一化和正负值规则不改。887项共享/Android测试、157项辅助检查及编译/Lint通过；额外运行 `python iosApp/scripts/check_exif_rational_oracle.py`，实际AndroidX 1.3.7库与编译shared在2,024组TIFF/JPEG样本上的数值和预览结果一致。该命令使用既有JDK/Android SDK/Gradle缓存和临时测试目录，不修改Android工程。

33个App Swift/159个XCTest/12项Native位图测试仍待Mac。新增Apple测试以真实JPEG原始字节覆盖0.05EV临界、负分数和零分母，尚未运行。多Exif APP1/复杂目录遍历、异常文件部分结果和ImageIO其余属性等价仍需继续处理；正式预览入口未启用，相机文件头/缓存/完整会话仍未接完。Windows粗估保持84%，不因单次兼容性补强上调。


### 多段EXIF与跨目录访问（第三十八批）

原分数读取现遍历全部Exif APP1，并按AndroidX保留跨段已访问偏移与属性字节、使用最终字节序转换；补SubIFD/GPS/Interop类型及目录别名访问，避免首段独占或GPS被误读为EXIF。890项共享/Android测试、157项辅助检查、编译/Lint及2,845组实际AndroidX字段/可见值对照通过。33个App Swift/160个XCTest/12项Native位图测试仍待Mac，新增真实重复APP1 JPEG的保留/覆盖用例。

Windows进度仍约84%。正式预览未启用；下一步处理相机截断文件头的部分EXIF结果，再接既有连接的读取和缓存。thumbnail/preview占用选择、RAW嵌入JPEG、异常文件和Apple真实解码差异仍待核验，不把本批对照范围扩大解释为全部EXIF兼容。


### 相机EXIF读头与部分输入（第三十九批）

现有CameraWiFiConnection增加EXIF分段读头，复用shared五参数和原串行会话；失败响应不重试，传输异常关闭失效owner，取消抛出。PreviewExifReader增加最多2MiB的不可变头部解析，shared显式保留截断前已读数值；原本地描述符路径保持严格。894项共享/Android测试、160项辅助检查、编译/Lint及3,197组实际AndroidX完整/截断样本对照通过；33个App Swift/167个XCTest/12项Native位图测试仍待Mac。

Windows粗估85%。这两个输入端点还未接成正式预览；下一步将正负EXIF缓存放在跨重连的现有长期所有者上，并接Native读取会话。不能误放在连接级缩略图缓存，也不能将取消写成缓存miss。RAW嵌入JPEG/复杂目录/其它ImageIO字段、配对STA-direct及Apple真机行为继续待验。


### 跨重连EXIF缓存与统一读取（第四十批）

现有长期所有者持有shared稳定结果缓存，显式借给文件页；不属于单次连接或缩略图缓存，不在关闭页面时丢弃。远程和本地共用原exifKey/正负缓存，未连相机不负缓存、取消不写miss；实际远程路径已借用原连接读头及已有解码actor。Native EXIF与图片共用32槽、超时和取消，离线可读缓存，但仍校验完整文件身份。

901项共享/Android测试、165项辅助检查、3,197组实际库对照及编译/Lint通过；33个App Swift/172个XCTest/12项Native位图测试仍待Mac。Windows粗估86%；完整预览平台源/页面状态、偏好、返回定位和正式入口仍需组装，读取接通不等于完整页面成品。复杂RAW/EXIF、其它产品UI和配对STA-direct等任务继续开放。
