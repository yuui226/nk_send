## 2026-11-11 STA 连接按钮再次点击可停止

对照 Android HomeScreen：搜索、配对、连接中再点「连接相机」调用 cancel，空闲才开始并震动。iOS 原先 staBusy 时直接 return。现由 handleSTAConnectTap 在忙碌时 cancelWiFiConnection。ConnectionStateTests.testSecondSTAConnectTapStopsTheActiveAttempt 在 iPhone 17 模拟器通过。

## 2026-11-11 设置底部隐私、条款、反馈跟随按钮风格

这三个按钮原先用 panel 扁平面，液态玻璃和实体材质都不会出现。现改为默认的 ZTransferGlassButtonStyle，不再传 panel。AppLegalLinks 里未使用的纯文字分支已删除。未跑界面测试。

## 2026-11-11 按钮风格列表把液态玻璃放在第一项

iOS 26 及以上的设置拨轮顺序改为液态玻璃、毛玻璃、木纹、相机按键、钛合金。默认仍是 ZTransferButtonSkin.defaultPreset，iOS 26 为液态玻璃，更低系统没有这一项并继续默认毛玻璃。未跑测试。

## 2026-11-11 高级版弹窗「恢复购买」改名为「恢复权益」

按钮 `iap_restore` 改为恢复权益 / 恢復權益 / Restore access。同屏验证失败、恢复失败和账户说明里的同一说法一并改掉。行为仍是 AppStore.sync()。界面测试期望文案已改，未运行。

## 2026-11-11 年费选项：月均价在总价下，续订说明改短，待运行验证

用户要求不对照安卓。一年高级版按钮左侧标题下只留一句「按年自动续订，可随时取消」（繁体、英文同步缩短），12pt medium，单行。≈月均价移到右侧总价正下方，11pt medium、次要色、右对齐。选永久版不移走这句。PremiumRecoveryUITests 文案断言已改，未运行，未构建安装。

## 2026-11-11 效果大图双指手势竞争修正，待运行验证

用户追加放大缩小不灵敏。对照Android ZoomablePreviewViewport与几何测试，源码发现效果图minimumDistance0拖动可先识别并取消窗口TouchTransform，导致第二指稍晚加入时缩放丢失。PreviewPinchObserver新增retainsTouchesForPinch仅效果大图开启，canBePrevented拒绝提前取消；普通列表默认不变。缩放倍率、边界、旋转与事件增量不改。新增实际TouchTransform+EffectsInteraction合成触摸回归，单指先移动/第二指加入/细微放大反向缩小/结束复位，未执行。三文件parse与diff检查过，无构建安装上传，不宣称已实机复现或完成灵敏度验收。详见ios/docs/照片效果大图预览修复-20261111.md后续章节。

## 2026-11-11 照片效果大图预览源码修复，运行验收待做

用户明确忽略上一个送审问题，改修工作台加工后点图白屏卡住、去标题、复用照片列表旋转及高度、开关不闪白。solo对照Android SinglePhotoPreviewOverlay/PreviewRotationButton和相关测试。移除两入口fullScreenCover，工作台/SettingsPopupOverlay稳定外层各自持有快照展示器并用overlay展示，比较图按image身份更新，源分页退出不清大图，关闭释放。复用PreviewCircleButton.rotateLeft和底部32pt共享常量，去额外safeArea累加，按用户指示去标题；340/260ms及旋转220ms保留，模态点击/辅助访问/主分页边界保留到收起结束。Genie原已传完整environment，新模型可穿过其UIHostingController。

文档ios/docs/照片效果大图预览修复-20261111.md，开发3/3、整体3/4，真机/运行待验。新增3定向模型/真实宿主像素及源移除用例但未执行，8文件swift语法parse和diff检查过；未编译/类型检查/构建安装上传，不称已复现用户当次卡死或已肉眼验收无白闪。遵守无授权不自动构建规则。TestFlight81不含本轮改动。上一审核操作实际已将正式2.05构建80改81并保存、添加草稿，未最终提交；用户转向后不再继续审核操作。

## 2026-11-11 照片效果 LUT/NP3/边框/颗粒加速，像素测试已过，真机计时未做

工作台和导出生成共用 PhotoEffectsRenderer。慢在完整原图的 CPU 像素：iOS LUT 插值仍在 Swift，NP3 无精确色表，边框窄阴影模糊整幅画布；颗粒核已与安卓 1f804ab8 一致。安卓 LUT 是 Native16K，NP3 导出有 2^20 ExactRgbMemo，浮影在四分之一代理。本次不改公式、强度、收尾、取消发布、JPEG 和原图单 worker，也不恢复安卓两层大阴影。

LUT 不透明批次进 PhotoLutBridge.cpp，轴表与 ByteSampler 相同，混合用 (byte/255)*255 和 floor(double+0.5)，半透明仍 Swift sample。NP3 的 Np3ExactApply.cpp 只扫描和查表，未命中回调现有 filterPixel；原图复用一张表，预览各自一张。颗粒 alpha 255 跳过结果不变的反预乘。窄阴影改 0.25 代理后用 UIImage.draw 画回，毛玻璃阴影裁到面板附近。

模拟器 iPhone 17 上 ZTransfer-Interactions：64 项（CubeLUT、PhotoCubeLUTMapper、PhotoNp3Rendering 含 1648 组、PhotoGrain、Np3Bitmap、Np3FilterEngine）和 LUTFinishingPerformanceTests 3 项均 Passed、exit 0，含冻结 RGBA 对照。本机 17 格 LUT 公式对照一致。未重跑 photo_grain 原生脚本，未做真机计时和阴影截图，不宣称倍速。文档 ios/docs/工作台LUT生成性能检查-20261111.md，5/6。下方同日“仍是 Swift、测试未跑”已被本条覆盖。

## 2026-11-11 工作台LUT生成性能检查与轴查表优化，待实测

用户报告工作台LUT生成慢。确认完整原图后台detached处理，LUT有缓存；iOS仍单线程Swift每像素domain除法/floor及8点插值，Android已256项轴表+默认Native16K。增加CubeLUT.ByteSampler每图预备3×256坐标，不透明像素走查表，半透明保持原float采样，两路共用原插值顺序。不降画质、不增原图并发、不改取消/强度/后调/保存。新增多尺寸domain完全相等对照测试未运行。3文件parse与diff过，未构建安装/性能计时，不称已解决全部慢或获得具体加速。文档ios/docs/工作台LUT生成性能检查-20261111.md，2/3，运行性能/像素验证待做。

## 2026-11-10 当前修复已上传TestFlight 2.05(81)，任务3/3完成

用户明确要求当前版本TestFlight。仅版本80→81，同步project.yml/pbxproj，保留巨大既有dirty树。归档ARCHIVE SUCCEEDED/exit0，1168项输入SHA256前后一致，codesign严格验证、发布包--submission检查errors空，Apple Validated ZTransfer/EXPORT SUCCEEDED，11:07 Upload succeeded/EXPORT SUCCEEDED。归档及全部日志ios/.build/appstore-20261110/build81。包含生成完整原图生命周期和冷启动后台清理修复，先前16项定向过，真实Photos/硬件仍待用户验证。

Chrome实际确认81处理完成，构建ID83edf90d-1712-4d48-a957-5d079c03fd72，中文/英文测试内容均保存并回读。加入既有本人内部测试组3c3a156f-3575-49cd-b811-92d496326be0，列表2.05(81)正在测试，1测试员4构建，旧80/79/78保留。用户正在原正式页面操作，另开Chrome标签完成TF，未改正式构建（核对仍80）、未AppStore送审/发布/手机安装/Git提交推送。用户已上传35d41643d17bd17e85ce850e581a0ddc_raw.mp4正式审核附件，但未检查视频内容。上传文档ios/docs/TestFlight当前版本上传-20261110.md，勿再引用11/9上传进行中为当前状态。

## 2026-11-10 冷启动后台清理相册私有工作目录

用户明确进程重启即新生命周期，断点续传/失败重试只在同一进程内；要求App启动后台清理、无阻塞无提示，不能等传输前。ZTransferApp.init启动进程静态utility detached任务一次；相册目录用ZTransferPhotoStaging/<进程UUID>，后台删除其他旧进程目录及历史平铺文件，保留本进程目录，立即开始传输可与清理并行。前台恢复不重复清理。用户已授权丢弃上次未入相册的私有原图/效果/分片。用户文件夹、Photos资产、导入账本不在此清理目录。新增3测试，最终定向16/16 TEST SUCCEEDED/exit0；文档任务4/5，真机杀进程/Photos仍待验。源码已改，未安装手机。详见ios/docs/相册保存与生成原图生命周期修复-20261110.md。

## 2026-11-10 相册保存与生成完整原图生命周期修复

用户报告生成“目录失效”和“格式不正确”，强调生成必须读取传输完成的完整原图。核实CameraRepository校验/close/finalize后result.url传给生成，问题是相册导入提前删除这份已完成原图，异步生成随后读空路径。未改成读取nkpart。TransferQueue现等同一原图生成读者结束后导入原图和派生图，成功后清理，失败保留完整输入供离线重试，发布串行和账本避免重复。文件夹保持既有原图保存，动画/UI不变。对照提前删除行为1测试4断言失败，实际复现“格式不正确”；目录错误由缺文件code4映射路径定位。最终定向13/13 TEST SUCCEEDED/exit0，含5新增，模拟Photos注入验证，无真实performChanges或手机安装。任务3/4，真机仍待验。详见ios/docs/相册保存与生成原图生命周期修复-20261110.md。勿将此次开发验证当作送审80或已安装手机含修复。

## 2026-11-09 iOS 传输保存位置：默认「Z传」相簿，文件夹仍可选

已确认的平台差异，安卓不改。无既有 iOS 用户，缺省直接是相册，不做旧偏好迁移。一次传输只写一个目的地。相册模式把完成的 JPEG/PNG/视频（以及系统接受的 NEF/NRW）导入系统照片，并放入以设备显示名命名的相簿（缺省「Z传」）；相簿被改名后用已存 localIdentifier 继续写入，被删除则再建同名相簿。按天/按类型在相册模式不建子目录。文件先落在应用私有暂存目录，导入成功后删除暂存原件；导入失败保留暂存并标记该条失败，不静默改写到用户文件夹。已传输记录是本地文件名+大小，重装可能重复导入。工作台本地效果仍走原有照片保存，不进这个相簿。

完全访问（read-write 的 authorized）才算通过；limited、denied、restricted 都不开始。申请只发生在即将开始传输时：手动加入并立即开始、新照片自动开始、立即开始的裁切、队列开始。启动、仅连接相机、只加入延后队列都不弹窗。拒绝后提示到「设置 → 隐私与安全性 → 照片」给 Z传 完全访问。文件夹模式不申请这个权限，仍用用户选的目录。

实现：`PhotoLibraryTransfer.swift`、`TransferQueue` 暂存与导入、`PhotoListView` 开始前申请、`SettingsView` 保存位置、`RootView` 重连目录、Info.plist 用途说明。保存位置拨轮下不放说明文字；说明在设置灯泡「传输」第一节。该拨轮选项字号与同卡存放方式、实时传输、选完再传同为 14。这张卡片里四个拨轮的左上角标签固定为 accentBlue，不跟随未开启时的灰色强调色；选项文字和边框仍按开启状态变化。安卓未改。generic 模拟器 `build-for-testing` exit 0；`PhotoLibraryTransferTests` 4/4 通过（缺省目的地、授权判定、账本、可导入类型）。未调用真实 `performChanges`，未真机验收导入和系统弹窗。未提交、未推送、未送审。

## 2026-11-09 当前版本TestFlight上传进行中：2.05(80)归档已过

本人明确“先把当前版本搞到TestFlight上”，本轮归档/校验/上传/现有内部组分配已获授权，勿再索要构建许可；不安装真机、不App Store送审/公开发布/Git提交推送。solo保留巨大既有dirty树，仅project.yml CURRENT_PROJECT_VERSION79→80及pbxproj两处同步，marketing2.05不变，原文件快照在ios/.build/appstore-20261109/build80。当前已归档ARCHIVE SUCCEEDED、exec85195 exit0，使用/tmp/ztransfer-prepay-release-20261102缓存，1172编译输入前后摘要一致，codesign严格过、verify-release-bundle.py --submission错误空。实际Info2.05/80、iPhone/iPad、iOS16、UIRequiresFullScreen/竖屏、豁免加密false、location/bluetooth-central均已看，不把archive开发profile当最终分发签名。

Apple validation exec88674正在，log同目录validation.log（最后12:28创建xcdistributionlogs，无最终结果），使用旧既有validation-options methodvalidation/destinationupload，自动签名，manageAppVersionAndBuildNumber=false。不并行跑上传，validation通过再xcodebuild -exportArchive同archive、upload-options methodapp-store-connect。当前没有80上传成功证据。进度文档TestFlight当前版本上传-20261109.md T01完/T02中/T03待1/3；有what-to-test zh/en文本，后续需从真实UI保存回读。

Chrome用户另开购物窗口，未碰其任何表单/购买；Window菜单选已存在App Store Connect窗口回到TF，原列表只有79/78。当前浏览器在本人内部测试组buildstab，2原构建；首次Testers加载显示0需最终复核，不要擅自宣称成员删除或新增别人。组ID3c3a156f-3575-49cd-b811-92d496326be0，完成上传处理后添加80，必要时查本人既有账号。原AppStore最终审核仍本人点。本轮没有跑新模型/UI/硬件测试，包中含此前未硬件验收修复，不夸整体正常。

## 2026-11-09 版权与隐私2/2完成，送审资料剩4组

本人明确回复async“确认，帮我完成这两项”，动作当时法律确认已获得，不再重复询问。助手先刷新隐私最终窗，点最终发布，后台显示“几秒钟前由钰诗胡发布”及未收集数据；随后App信息→设置内容版权→是（包含第三方内容并拥有必要版权）→完成→页面保存，显示已保存。刷新App信息回读“是，此App拥有对其第三方内容的必要权利”；再打开隐私页回读“2分钟前由钰诗胡发布”和未收集数据。两项实际持久完成，不只是准备或勾选，无需本人再点。

上架手册A05核销，材料缺项改为4组A01新Release候选/A02商店图/A03两商品审核图及同批/A04硬件视频+审核说明；隐私和素材依据顶部更新、材料清单同步。旧未发布/待版权记录仅历史。最终新候选仍检查资源/数据流，未来公开样片仍须自有许可，不以字段完成保证任意素材权利。没有提交App审核/发布App/改地区/构建安装提交推送；git diff --check通过。当前Chrome留在隐私已发布页面，后续本轮授权只覆盖这两项，不扩成App正式提交。

## 2026-11-09 版权与隐私：具体声明准备阶段（已由上方完成记录覆盖）

本人问“版权与隐私确认是不是你可以做”，solo实际准备，未止于建议。复读现有素材/隐私依据、79包检查json、当前Resources三字体OFL/IJG及其他许可、Release排除debug样片、无内置NP3/CUBE；当前源码检索未发现开发者业务API/上传/跟踪，仍StoreKit/Apple geocoder、本地处理，新增诊断仅Debug本地。官方Apple privacy FAQ确认Apple自行收集无需开发者代报，本地不算收集。不是新全量动态审计或候选包通过。

Chrome打开内容版权窗口看到完整两选项（均未选）：拟“是，包含/显示/访问第三方内容，并拥有必要版权”，依据合法许可字体等，而非虚称无任何第三方。合法许可不是版权登记/转让；不声称开发者获用户任意照片/预设分发权；公开样片仍需自有/许可。取消版权窗无变更，再打开App隐私，草稿未收集数据→点页面发布，当前停最终“是否发布你的App隐私答复”窗口。原文发布即同意答复准确、遵守审核指南和法律、变化及时更新。最终发布尚未点，版权也尚未写/保存。

依据电脑操作Confirmation Required at Action time，需本人在此具体声明准备好后一次明确确认，之后助手可代点击（并非一律必须本人亲点隐私）；原App审核提交/实际App发布仍本人。准备向本人async问是否允许保存上述版权声明并发布未收集数据隐私答复，不提交审核/发布App，不索要其他材料。素材/隐私依据与上架手册已写准备状态，未核销A05；git diff检查后保持无构建安装提交推送。收到授权须先刷新ChromeAX再完成隐私dialog、版权radio/完成及页面保存，回读两项才标完成；如本人自行点击也先回读，不重复提交。

## 2026-11-09 首次送审材料复核5/5，按本人要求本地工具先审、备案并行

本人希望先正式审核获取反馈，通过后不发布、继续测试再换包；solo实际Chrome只读核查。官方说明确认当前手动发布通过后Pending Developer Release，不会自动上架；换代码/包需移除再选新递增build、重新审核，不必先公开旧包，也不能套用批准。Apple2.1/2.2要求完整且核心实机稳定，不把正式审核当beta QA；最终长测可继续，非强制先全勾V01–V16。

实时后台：2.05准备提交、未选构建、手动发布已选；简中iPhone中等/iPad13截图均0/10；年度、永久准备提交且审核截屏均未选、组准备提交；版权仍设置入口、隐私未收集草稿Publish仍可用；审核附件空无硬件视频、线上备注旧Manage subscription双层路径。TF只有79/78，79元数据上传11/5 15:37；最新工作树仍2.05(79)但包含后续未上传修复，应新build如80再送审。商务免费/付费有效、银行可用、两税表使用中、合规2有效，价格29.90/79.90已本轮先前保存无需重做。3中文法律/support正常TLS HEAD均200；网页工具不可抓不等于站点故障。无新构建测试安装上传/改线上字段/审核提交/发布。

调查中本人明确“备案没下也先按单机app送审，除了苹果没有别的联网业务”：遵从此推进策略，备案不再自行列作本次硬性前置、继续并行；不自动关大陆、不新接后台、不虚号、不问客服。说明必须如实USB/LAN/BLE/本地处理、StoreKit/Apple地理编码与外部浏览器/用户文件提供者，可尝试审核但不宣称绝不联网或已获ICP豁免。官方协会FAQ只列单机不联网，Apple部分App需要，未查到系统服务组合一概豁免。腾讯刷新短暂旧管局中后跳登录，不能称今日已认证进度；无需为此次清单再要扫码，已知本人说未发号。若后台/审核实际要求则再补件。

上架手册顶部新增11/9权威复核（覆盖11/7待办）、五组A01候选+核心冒烟/A02商店截图/A03IAP审核图同批/A04实体手机相机同框视频和说明/A05版权隐私确认，按最少可提交材料与后续测试区分；材料清单价格/签名进度修正、验收和审核草稿/联网核查顶部更新。本人主要需自有可公开照片、硬件视频及代表设备/固件/系统连接事实，其余助手准备，最终添加审核/隐私确认/提交发布仍本人。复核任务5/5不等于材料完成5/5；git diff --check通过，5份文档73个本地链接全部存在；未提交推送。

## 2026-11-09 苹果后台定价已改年度29.90／永久79.90

本人明确“年度改29.90，永久79.90，Chrome已打开苹果后台”。solo通过cua原生Chrome操作，浏览器扩展控制在Work设置禁用但native AX可用，无额外插件。永久6830950193全球价格调整→CNY79.90→立即生效2026-11-09→确认，完成后当前价格明细售价79.90复读；年度6830954364最初价格→编辑→CNY重新计算29.90→两步确认，完成后重新打开最初价格明细售价29.90复读。不是收入列/临时优惠，未提交审核或发布。价格换算175地区，供应保持148地区，未重新开放欧盟。所有最终审核按钮仍本人操作。

记录上架步骤与分工新增11/9、商业化进度顶部与操作目标更新；旧39.90/99.90历史记录保留。正式页面已有StoreKit product.displayPrice/monthly calculation，无需改App或重打包。独立本地StoreKit文件仍旧测试价，本次未改测试夹具/生产源码，沙盒传播未实测，勿说手机已显示新价。无构建安装提交推送。

## 2026-11-08 横屏监看 Dock 旋转入口去重：源码调整完成，待运行验证

用户明确横屏展开Dock不应再有旋转按钮，旋转仅外侧常驻。solo读取Android LandscapeMonitorControls/RemoteToolPreferences及RemoteToolLayoutTest（原drawerPinsBothControls测试要求锁定+旋转都在Dock），按用户本轮明确规则覆盖该旧行为，不再另问平台差异。iOS RemoteLandscapeControls将Dock固定项改为仅.lock；外侧rotate移出dock=false淡出层，保持同一36pt槽位，展开/收起均可见；Dock底部预留36pt按钮+8pt间隔，侧栏及反挤压下方布局共用，避免滚动内容遮挡。锁定禁用旋转的业务逻辑、竖屏工具栏、照片/视频配置和原Dock动画时序不变。仅该组件3处布局修改，无新增状态/计时器/逐帧计算。git diff --check通过，未新增镜像测试，未构建/运行测试/截图验收/安装/提交/推送；不能引用前一轮85项为本轮布局验证。

## 2026-11-08 STA 气泡、水平仪与监看回看：开发侧5/5，现场问题待验

solo继续，Android独立工作区已pull到14bc46619cea5f5affe22016f0a31d9e1f1740f0，确认N日范围修复定稿；用户明确缓存/目录其他差异先不看，待Android来对齐，不撤销iOS此前严格新会话隔离。用户新报STA前台亮屏偶发断线、断开信号应提示正在尝试重连、水平仪无俯仰线、换机沿用卡回看只见旧照片；追加确认照片列表排序正常、新照片在前。

STA保活10s/连续2失败/额外1s、下载让路、事件无超时均与Android一致，未改时序或吞掉事务失同步。手机13:03缓存仅连接成功，系统日志USB/usbmux不可用，没有实际断线原因，不能宣称修好。补Debug各一份8192字符本地快照：Camera-transportFailure-latest.txt真实失效命令/错误，Camera-review-latest.txt时间覆盖与当前目录head，Camera-level-latest.txt开启工具后第一帧必要头字段。无额外探测/定时器/逐帧写盘，Release报告autoclosure不求值。手机尚无本轮诊断代码。

断开STA信号入口原一律disabled，现列表/队列/监看共用回调，ConnectionVM每个合格点击发提示事件，即便发现已执行也提示但不重复任务；Root挂PhotoListHint，沿用1800ms/28dp/spring400。USB、已连接STA/AP仍不可点。水平仪双轴解析/绘制原已有且与Android相同（仅512 compact-v1有已证实pitch），未盲加线/手机姿态；修正回看出入重置轮询失败预算与代际、拒绝迟到属性。当前相机无pitch仍需真实帧头。

回看旧逻辑每卡handles反序+跨卡head合并，列表却按已读真实日期重排，因此相同文件可出现不同排序；Android原实现也有同一假设。现新枚举handles限定成员，同会话已读时间排序，支持0x9434时每次回看刷新日期索引；已知时间/未知时间拆惰性流，比较未知head真实时间，避免旧未加载文件挡住已知最新照片。只分页读metadata，不全卡原图；完全未知且无时间索引部分仍原序，不能宣称所有无时间机型已全球有序。

r1 43过；追加partial-cache反例1失败/1断言exit65复现列表2/回看91；修正拆流后r2 51过；r3姿态解析5过；Release诊断7过，去重85方法（7新方法），含实际SwiftUI pitch-only像素变化、迟到属性不复活、回看新拍刷新/双卡/RAWJPEG/取消/一帧lookahead。不重复计数，不当物理相机验收。证据ios/docs/evidence/sta-review-level-20261108含日志、85名单、源码hash、当前任务diff；文档STA保活与监看回看水平仪核查-20261108.md任务5/6，S06现场仍未完成。全部构建已结束，未手机打包/安装/提交/推送；手机仍122616。13:34只读截图全黑，不能判断页面或验收。后续需本人操作相机验证回看第一张及新拍后重开、pitch和偶发断线；勿把开发侧通过写成实机问题已解决。

## 2026-11-08 新连接目录与缩略图缓存：开发侧4/4，真机待验

用户明确新连接不能先闪旧目录，必须本次相机从新到旧枚举最近N个实际拍摄日，再逐文件命中同机身缩略图。solo删除STACatalogRecovery/ConnectionViewModel快照传递/PhotoListViewModel.inheritCatalog，Root以session身份同步重置网格投影；同连接切页/预览/监看恢复及离线页面保留。N日停止从累计旧日期数改为当前批次实际读到更早日期，避免最新日只读首张。PhotoScanSnapshot加连接UUID＋原revision双检；未知机身无序列号/GUID时按连接隔离；不再迁移无归属平铺缓存；STA稳定编号＋大小键加拍摄时间/版本，旧弱键首次需重填。保留90日清理、全量成功才剪缓存、新拍摄范围豁免、队列重绑及既有动画。

Android已提交eafc461d也有旧范围bug；审查中独立Android工作区出现未提交CameraViewModel/PhotoDateRange/PhotoLoadingRangeTest修复，已读取参考，不是本轮修改或测试Android。不要再沿用10月16日跨连接目录继承为当前正确规则，旧台账已注明被覆盖。

r1基线3失败/8断言、r2 71过；r3追加2失败/4断言证实断点与STA弱键；r4新迟到响应测试自己占着串行permit却等后续请求，主动中止exit143，修测试释放顺序未改生产。r5最终95/95、无跳过、TEST SUCCEEDED/exit0，含四档N日、换机迟到、同编号换日期、双卡、加载扩大/收缩、新拍摄和监看恢复。证据ios/docs/evidence/catalog-cache-20261108含每轮log/源码hash/本轮diff/95名单/Android只读参考。文档照片目录新连接与缩略图缓存修复-20261108.md L01–L04完成4/5，L05物理相机待本人验。未打安装包、未安装/提交/推送；手机仍之前122616，不把模型通过当真机通过。全部构建已结束。

## 2026-11-08 12:35 STA 临时诊断清理核查完成3/3，未重新安装

用户要求核查大波STA试探代码是否清除及开销。solo确认STATCPAudit/启动参数/六种TCP对照/route导出/BSD probe均不存在生产源码，host无遗留抓包/LLDB/dns进程。保留原mDNS/端口发现、真正配对LV帧验证/一次补救/60s回网等待、业务保活/目录同步；Debug手动保护探测入口仍在但默认不运行，详细传输采样需显式环境变量且正常启动未注入。发现Release facade虽空，STAConnectionTrace仍读时钟/加锁/记录且参数提前格式化；已#ifDEBUG移除存储/时钟，文本/报告入口改非逃逸autoclosure，等待诊断计时/WiFi结果跟踪仅Debug。协议/界面不变。

Debug诊断7/7、Release本机协议目标50/50均exit0，去重51方法2新增；Release断言时钟及消息/报告求值0，慢回网+真实LV失败补救都通过。WiFi服务仅两配置语法解析通过，未完整App构建/安装/提交推送/上传，手机仍122616且早无TCP实验；本轮Release关闭日志下次打包生效。文档STA临时诊断清理与开销核查-20261108.md C01–C03完成3/3，证据sta-diagnostics-cleanup-20261108。未测真机CPU功耗，不称零开销/硬件STA验收通过。用户随后新报告N日加载仍旧照片、新机不能复用旧缓存，正在转核Android实际范围/缓存生命周期，保留以上结论。

## 2026-11-08 12:28 STA 配对后慢速回网：等待已放宽并安装，补救回归通过

用户说明前一IPv4冲突已解决，现为相机确认配对后尚未回网就失败；追加要求确保监看帧补救不被阻断。solo核对Android eafc461d仍6.6s+一次1.2s，iOS本来一致；本轮按用户明确要求调整已ACK后等待（不改Android）。同一收据/GUID/身份下，ACK起算60s窗口只对暂时网络故障按1.2s间隔重连，socket/清理计时且失败不续期；取消/错误机身/明确配对拒绝/已开始Query或Result的不确定失败保持原终止，未改UI/文案/动画。ACK仅记路线，不写成功标记；实际相册+真实LV帧通过才可信。帧验证失败/仅配对能力仍共享原一次补救，保留身份不清其他机身；有帧证据后只恢复收尾。新增真实协议回归验证慢回网→帧失败→补救→成功或再次失败，Query/Result各恰2次，无提前trust。旧标记只有明确pairing-only才作废，普通网络断线不清。

r1 55/55、r2 23/23、r3 2/2均exit0，去重58方法、8新增，证据ios/docs/evidence/sta-postpair-reconnect-20261108。按既有“STA修好一起构建安装”授权，脚本122616包BUILD SUCCEEDED/exit0，31s覆盖15Plus并启动，1成功0失败，数据保留。随后只补测试文档，生产与安装一致，无需再装。文档STA配对后网络重连等待修复-20261108.md R01–R03完成3/4，R04待用户实际相机验收；不把替身当物理通过。12:16:44最后设备记录是后续Query201F，不能称捕获了之前ACK后超时。IP变更重新发现仍未新增/未验，原固定候选策略保留。无提交推送、无运行构建。用户要捋清保存/补救，下一回复应讲路线/待验证与成功标记区别，并说明完整补救回归已通过及安装。

## 2026-11-08 11:53 STA 真正根因已确认：局域网 IP 冲突；普通版已恢复安装

本人已USB接线解锁。pymobiledevice3通过uv临时工具环境使用官方开发pcapd，无管理员授权；两轮30s仅筛相机IP ARP和TCP15740头字段，不写原始payload/其他流量。11:49:48两条ARP reply相隔83.6ms：相机MAC3c:be:e1:58:e9:73与另一MAC2c:19:5c:2d:fa:16都声明192.168.1.6。TCP相机SYNACK、手机后续ACK/SYN被导至另一MAC并收到其RST。**已确认IPv4冲突，不是未知errno，也不能再将探测socket退场差异当根因。**本人确认相机自动获取IP；是谁错误占用/分配仍待路由器核对。IEEE官方OUI另一设备前缀归小米，不能推断具体型号。用户问“相机选了被用IP？”已解释自动通常路由器分配，建议给相机DHCP保留空闲IP再获取。

临时STATCPAudit/启动参数/debugRoutes全部删除。另撤销试验BSD发现探测，恢复本轮开始Network.framework适配器，删三个probe回归及fixture计数；保留NSError真实码、Debug一次完成缓存、生产选择路径抽取与取消检查、弹窗两个修复。不为网络冲突加重试/改配对/清身份。最终43协议测试通过（/tmp/ztransfer-sta-final-protocol-20261108.log），既有去重92减删除3=保留89方法有通过证据，6新增；popup12不变。STA文档S01–S03完成3/4，S04地址冲突解决后的真实配对仍待验。ARP/TCP脱敏证据已在ios/docs/evidence/sta-second-camera-20261108，真实完整仅/tmp。

普通版115233脚本session3098已exit0，BUILD SUCCEEDED/1成功0失败，35秒覆盖15Plus并正常启动，保留数据，无audit代码/参数；日志/tmp/ztransfer-sta-normal-device-20261108.log。RVI已停止、两pcapd采集/所有listener和dns进程均已结束。临时工具未进工程依赖。只读http://192.168.1.1标题SG631Z，不读取/修改路由器配置。未提交推送。必须等相机获得不冲突地址后再声称配对解决，不能只根据协议回归通过核销。

## 2026-11-08 STA 第二台相机及弹窗关闭闪烁：已装联合修复版，等实际相机验收

用户明确当前是 STA 无法配对新相机，要求直接对照 Android，不再问现象/复制日志；另有设置等窗关闭闪一次。solo fetch/核对 Android HEAD/origin 均 eafc461d。真实生产选择流程本来已有旧机找不到→其他 GUID 延后→扫描完成再不限旧 GUID 配对；未虚称缺分支。独立 Swift 语言诊断确认原 ChannelError.system(errno) 桥接 NSError 一律枚举编号0，已 CustomNSError 保留 POSIX 真因，重试分类不变。选择 actor 与最终收尾移入协议协调器复用同一路径，增加取消检查及真实回归。三次 LLDB 未取得 errno（锁/符号/调试器自身崩溃），全部退出且 app 已 resume，不再用调试器。

确认另一实质实现差异：Android 探测 Socket.use 返回前关闭，iOS NWConnection.cancel 异步退场，可能与正式 BSD 握手重叠；已改同一 BSD 轻量探测，450ms/绑定原路由/24并发/48批次不变，无 PTP 数据/无命令优化，返回前同步 shutdown/关闭。仅说明修正生命周期差异，**尚未证明这是实际新相机失败根因或已配对成功**。Debug 连接结束只异步原子保存一份有界 Library/Caches/STAConnection-latest.txt，可 devicectl 直接读，不再要用户复制，不添网络请求/逐帧工作/Release记录。r1 85、r2 1、r3 41、r4 6 去重92协议方法通过（9新增）；证据 ios/docs/evidence/sta-second-camera-20261108。STA任务S01/S03完成2/4，S02真机errno仍缺、S04物理验收待回报。

弹窗：按Android保持已展开真实窗至关闭捕获完成，再由网格接手；打开/中途重捕仍隐藏源，动画中整个父容器隐藏，避免材质重置子层露完整窗。queued onSettled核对最新target/progress/settledTarget并调用当前回调，防旧关闭卸载已重开窗；不改动画参数/灯泡材质、不逐帧截图。模拟器r1 12项10过2失败（新KVO观察重复子层1未回调；旧安全区固定300ms时尚差opacity .00318）；r2新观察actor声明错误构建失败；r3纠正父层观察+主actor后两项通过，安全区测试/生产时长未改。去重12均有通过结果；原失败和日志完整保留，不能称r1全绿。证据popup-close-20261108；液态玻璃浅色capture/live已人工查看，其余像素对照过但未逐图看。文档开发侧P01–P03为3/3，真机肉眼未验。

用户“STA问题一起修好了再构建安装”作为集中验证安装授权，先完成实质源码差异及协议验证再跑组件/脚本。Debug2.05(79)20261108-113420 已覆盖 iPhone15Plus 00008120-000A08110CF1A01E并启动，脚本exit0/BUILD SUCCEEDED，1成功0失败，总32s，不卸载不清数据。旧103821交付包按脚本授权清理。原日志/tmp/ztransfer-sta-popup-device-20261108.log；没有运行的构建/调试器。已异步询问用户以刚才新相机正常STA连接；等待物理结果，失败直接读缓存。手机启动截图已查看，停在STA连接页，未报错。保持手机当前状态，不反复重装或调试。无提交推送。所有原工作树改动保留，before快照在/tmp/ztransfer-sta-second-camera-before-20261108与/tmp/ztransfer-popup-close-before-20261108。

最新11:37用户回报联合版仍失败。缓存已直接拿到：session2/11:36:52 两次正式CommandSocket成功前system(61)=ECONNREFUSED，原1200msretry后仍拒绝；6.393s结束。不能再写未知errno或修好。Mac同LAN Bonjour找到Z50_2/15740，11:38无数据TCP能连通，不能外推手机。临时STATCPAudit加在Trace.swift（DEBUG）、App启动参数 --sta-tcp-audit=<本轮实际IPv4>、Discovery.debugRoutes，6次有限对照绑定/自动、BSD探测/命令参数、NW，不发PTP。脚本session30199日志/tmp/ztransfer-sta-tcp-audit-device-20261108.log构建中；成功后需devicectl terminate-existing启动参数、读Library/Caches/STA-TCP-audit.txt，然后删除这些临时块恢复正常包。临时前快照/tmp/ztransfer-sta-tcp-audit-before-20261108（仅App/Discovery/Trace，不要覆盖其他新修复）；协议目标不包含DiscoveryService，临时Audit未移除前不要运行协议测试。无运行dns-sd，已CtrlC退出两进程。

11:45临时114117包已装并显式launch有限audit：手机192.168.1.15/24→相机.6，BSD四种绑定/自动×参数均61，NW两项3s超时；手机同API→Mac.5:15740六项全部OPEN，临时listener实际收到六次连接后自动退出。Mac→相机再三次全OPEN。设备STA偏好仅迁移键（所筛model/IP空），不臆断当前有旧相机记录。证据device-tcp-camera-redacted与device-tcp-mac-control-redacted。RVI无法列设备，idevice_id -l -n为空，当前只有CoreDeviceWiFi。已async请求USB接电脑解锁用于手机TCP包，只看15740握手，不要求用户再点连接；得到接线后rvictl+tcpdump，重启audit明确target相机.6即可自动触发。有限audit已结束，phone当前停普通连接页无业务活动，不要说还运行。没有遗留listener/dns进程。临时probe代码需最终移除再装普通版。

## 2026-11-07 APP备案已过腾讯初审并提交管局，保留Z传名称

本人回报初审电话建议三字名称、提示驳回风险，但决定不改名直接提交。solo查官方：腾讯11740三字要求针对网站，97691 APP说明要求安装后实际显示名称、未列三字门槛；阿里辽宁个人规则也链接网站命名。未找到辽宁公开明确针对该APP情形的最低三字条文，不保证通过，也不臆断美团/企业有豁免。尊重本人保留Z传，不改代码/商店/备案、不联系客户服务。刷新Chrome同订单30179380556798516：提交审核时间2026-11-07 14:52:24，腾讯云审核已通过、待提交管局已提交、工信部短信无需核验、管局审核中。订单锁定不可撤改，页面预计约8工作日最长20，以实际为准；尚无APP号。已纠正先前笼统“随后必须短信”提醒，本单当前无需短信。详细记录ios/docs/iOS-APP备案申请-20261107.md；若名称被正式退回，先读理由/依据，再讨论真实显示名称统一调整。无构建安装提交推送。

## 2026-11-07 APP备案最初提交记录（后续已进入管局，见上）

本人回复“已提交”后实查console.cloud.tencent.com/beian/manage：同一订单30179380556798516“新增服务-审核中”，“提交初审 已提交”“腾讯云审核 审核中”。本次提交目标已完成；没有获得APP备案号，也未进入管局审核。页面预计1–2工作日电话核实（两次未接可能驳回），之后工信部短信需24小时内核验，管局标注1–20工作日；不是审批时间保证。记录已更新，原网站/主体号不能写成APP号，尚未写入Apple。无客服消息/自动监控，无构建安装提交代码推送。下段保留准备阶段经过，最终协议提交已由本人完成，不再重复要求。

solo操作腾讯云已有APP草稿，用户完成登录。已录入Z传/软件开发/苹果平台/简繁英、真实无iOS业务后端说明、AppIcon，以及com.ztransfer.ios正式发行公钥和证书SHA1（3F9D389BFA9381D9260DB699C87CAB56426A229B）。苹果平台字段虽名MD5实用SHA1。证书从上传79的发行profile提取，与实际上传重签名产物codesign公开证书及签名日志交叉一致；原xcarchive是开发签名，不能误用。没导出私钥或保存完整profile/证件资料。

初次空域名保存被拒，随后用户明确“就写这台腾讯云服务器、备案后iOS可请求，不问客服”。已遵从，不再等待客服授权。公开DNS api.ztransfer.top→122.51.32.193，腾讯官方19630“网站/APP没有做好”允许计划上线提前备案；填写该域名，备注如实注明拟用于后续iOS后台、当前尚未接入，保留Apple系统服务/外部网页事实。没有擅自改iOS网络代码、迁移GitHub官网或DNS，也不声称备案等于无限制业务许可。本人已完成微信真实性核验及浏览器短信填写，保存服务成功，列表Z传/APP/api.ztransfer.top/正常。补充材料仅选填，已进入/review并核对所有公开技术字段和真实拟接入说明。最终复选框包含隐私声明/相关条款/互联网信息服务备案承诺书，尚未勾选或提交；已请求本人核对主体地址联系方式、阅读勾选并点提交审核，再读取回执。记录ios/docs/iOS-APP备案申请-20261107.md。无APP备案号、无初审回执；未构建安装提交推送，也未改Apple后台。客服咨询从未发送，用户明确不要联系；敏感证件、手机号、验证码、照片不存仓库。

## 2026-11-07 正式送审与单机备案条件复核

本人问能否直接送审及是否完全单机免APP备案。solo静态复核网络调用并查询工信部105号通知、互联网协会2026-01-07单机FAQ及Apple App信息文档；无自有公网业务后端，USB/BLE/LAN核心本地，StoreKit和两处CLGeocoder仍会使用联网系统能力，法律页openURL交外部浏览器。不能声称完全不联网，也不能仅据系统联网断言必备案；当前组合没有查到明确通用豁免，仍需确认大陆适用口径，未对外发咨询或更改功能/地区。隐私/条款正常TLS HEAD均200。

Chrome首次刷新登录过期，本人重新登录后只读核对版本截图、App信息、隐私、两商品/订阅组、TestFlight与商务：2.05准备提交、构建未选；简中iPhone/iPad截图均0/10；两商品审核截图空、订阅组准备提交；硬件视频/附件未补；内容版权未设置、隐私未收集数据草稿待本人发布；ICP未填。App与年度备注仍写旧Manage subscription双层路径，需跟现行续费/GPS流程更新。TF仅79/78，新Debug同79不等于上传包更新；79有1安装35使用不能当功能验收。免费/付费协议有效、银行可用、两税表使用中、810/DSA有效；年度宽限期16天仅付费转付费/仅沙盒，正式环境按既定策略待收尾。未逐地区重查价表。

更新AppStore上架步骤与分工最新7类待办、网络核查11/7复核、验收清单当前GPS证据与V12规则（有效年度无永久升级、到期后可重新选）。未核销最终V01–V16，GPS长期后台/锁屏及照片EXIF仍待本人验。仅文档修改，diff检查通过；未构建安装提交推送/上传/后台保存/送审发布，最终按钮仍本人点。

## 2026-11-07 蓝牙/GPS再次全流程复查：5/5检查完成，86项通过

本人要求再查蓝牙/GPS流程及功能，solo按Android eafc461d核对Service/BLE/ViewModel/协议/恢复/频率/海拔测试和Home/CameraViewModel GPS互斥。未发现新的生产业务流程缺陷；生产仅改GPSCoordinator一条“AP阻塞期间保存在preferences”的过时注释为本次App会话，没改运行逻辑。新增1个运行中四档频率交叉用例（12种切换，覆盖在途ACK、旧倒计时迟到、重复选择、关闭后ACK）。

完整r1运行82项：76GPS+3展示全部过，3Root中1过2失败；旧RootLocationStub固定denied却期望连接详情更新，正确权限守卫拒绝。已改该专用夹具为授权/前台、蓝牙/位置替身，无真实无线工作，原断言阈值保留；r2该夹具全部7Root用例过、TEST SUCCEEDED、exec50008 exit0；与r1去重86项通过。r1失败保留（exit65），无须重跑已通过的79项。修复的是测试前提，不是生产权限逻辑。证据ios/docs/evidence/gps-full-flow-recheck-20261107含r1/r2日志、86方法、source哈希。

只读手机缓存补齐真实旧10:07–10:09记录（不要称本轮重新操作）：10:07:32/10:08:33两次GEO成功，10:09:24实际断连→10:09:36重新ID/GEO成功；10:09:43关GPS→10:09:50开→10:09:53 ID/GEO成功，无系统首次配对窗，10:09:58关闭。脱敏device-reconnect-and-periodic-write-redacted.txt已存；普通断连和关开GPS现已实证，不再写完全未验。未知道具体断连原因，不能说证明相机关机再开机；长期锁屏/后台及新照片EXIF仍待本人相机验证。S05只缺照片EXIF，完整历史GPS目标仍不可全部核销；旧goal状态不新建重复目标。

文档ios/docs/蓝牙与GPS全流程复查-20261107.md R01–R05为5/5检查完成，GPS系统配对后连接恢复表同步。未重新安装手机（仍101735，运行逻辑相同），未提交推送/归档上传，没有遗留构建或设备采集。不要为本轮只改测试和注释再打包或要求重新配对。

## 2026-11-07 首次系统配对/GEO实机成功，GPS连接卡片整体禁用外观4/4完成并安装

本人已确认“两边成功，坐标和发送时间都有”。读取095818正常包真实缓存：10:01:30选择器仍notFound，pending身份保留→原身份重连→10:01:34第二次ID ACK/ready→实际GEO ACK→confirmed。偏好pairing_confirmed=true、pending=false及device_id/nonce/ble_address均存在；脱敏日志system-flow-device-success-1001.txt与仅布尔identity-confirmed证据已保存。首次配对和GPS写入已实机通过，不再写仍未成功；相机断开再连及新照片EXIF仍待用户操作，S05部分完成。10:09只读截图显示正常发送时间持续更新；含真实坐标仅留/tmp，不进仓库。

用户追加GPS开时两张连接卡片图标/按钮没全变灰。solo对照Android HomeScreen eafc461d：圆角背景wash位于共同父层最上方0.28/320ms，STA禁用alpha仅已连接例外1，否则.45。iOS此前wash仅cardSurface漏独立飞行badge，allowsHitTesting未传播disabled，CTA又无条件disabledAlpha1。已移动wash至共同NativeAttentionHost内最上方，正文disabled(dimmed)且保留触摸拦截，CTA条件alpha；公共灯泡未改、不加drawingGroup/截图/灰度滤镜或时钟。gps-card-disabled-r1卡片5方法通过；截图复核发现CTA例外后追加修正。r2新增像素对照夹具误用3x对2x导致12尺寸断言失败，已统一比例；r3最终1专项（12组模式/材质/明暗开关与恢复）通过、TEST SUCCEEDED、exec14970 exit0；去重5方法，36张最终图片及3张CTA修正后代表图已看。既有ButtonStateLabel flatten警告未清除，实际截图正常，不扩大验证结论。

文档ios/docs/GPS连接卡片整体禁用外观-20261107.md C01–C04为4/4完成。沿用授权脚本101735包36秒覆盖15Plus安装启动成功，1成功0失败、exec70223 exit0。安装后偏好device_id/nonce保持、confirmed=true/pending=false；近期BLE UUID与10:01不同（发现回调会更新），仅布尔记录installed.json，不能写所有偏好逐字相同。启动截图已看，GPS默认OFF、身份保留；真机开启后的置灰及后续相机重连/新照片EXIF仍由用户确认。无遗留构建或采集，不提交推送；不用重新要求首次配对或清bond。goal旧blocked状态不等于首次GPS仍失败，不新建重复目标。

## 2026-11-07 10:00 正常系统配对版已装，待一轮正常硬件验证

095818包由脚本35秒覆盖15Plus成功（localNetwork，1成功0失败），exec37702 exit0。普通启动的新进程PID8603已查，system-flow-installed.json和连接页截图已保存/查看，GPS未自启，源码无probe代码/参数。75GPS+3展示=78不同方法通过，S01–S04完成，S05仍缺物理配对/GEO/后续重连/照片坐标（4/5）。已异步请求本人仅忽略iPhone蓝牙中Z50_2旧bond（针对此前确证INVALID_LINK_KEY）→相机重新配对→Z传开启GPS→系统选择/两端确认，再反馈相机成功与坐标发送时间。用户已明确接受选设备，不再测试免列表；不能自动删系统bond/假ready。手机待操作时不要重装重启，可直接读Library/Caches/gps-diagnostic.log，注意旧09:48缓存会留到新事件覆盖。goal API仍blocked但当前用户授权修复持续；不要创建重复goal。未提交推送，无遗留构建/采集。

## 2026-11-07 用户确认恢复选设备，完整流程核查已通过，正常版安装中

用户明确“省不了选设备就先加回来，正常走通也行”，继而要求整个流程对齐Android、只增加选设备。solo完整核对eafc461d NikonGpsBleClient/Service/GpsState及协议、恢复、频率、坐标/海拔、地点与展示测试。生产probe枚举/启动参数/所有试验分支和4测试已删除；保留GATT诊断。恢复首次ID ACK→EA系统选择/确认→pending→800ms原身份重连→新ID ACK才ready→真实GEO ACK才confirmed/650+700ms成功提示。新增actual client→coordinator回归防止手机坐标提前发布；restore专项6/6、full75GPS+3展示=78/78均TEST SUCCEEDED/exit0，不相加，当前1新增。证据system-flow-source-sha256、system-flow-test-methods、remove-probe-delta及logs/system-flow-audit-r1。

Debug正常版安装进程exec37702，日志system-flow-device.log，结果待查；**普通启动，绝不再带已删除试验参数**。任务doc新增S01–S05完整对照表，目前S01–S03完成，S04安装中、S05物理验收未做。必须如实说明：iOS旧bond不能像安卓removeBond自动清理，前面00:37INVALID_LINK_KEY需要本人系统蓝牙忽略相机，不是可以保证只选一次就自动修旧密钥；用户已接受系统流程，准备具体安装后再给一次完整清理/配对指令。当前新回报工作解除旧等待，goal API仍blocked不可自行resume，未创建新goal；完整GPS尚未完成。未提交推送。

## 2026-11-07 用户指出假连接，两个免选择器实验失败，正在撤除

用户“没配对/没连接就到坐标界面”。真实094710日志09:48:21：ID ACK后试验发ready→手机定位/坐标→GEO返回CBATTErrorDomain/128→失败丢candidate；相机没收到有效GPS。09:48:30重试扫描后not found。根因是试验错误借用ready触发写入，违反coordinator/视图已连接契约，造成sessionEstablished锁存手机坐标。已承认错误，不能称之前6测试证明UI正确。ATT128应用错误无厂商细节，别杜撰为系统权限错误。证据held-link-device-failure-0948.txt+hash保存。

已撤除NikonGPSPairingRoute/所有probe状态/启动参数/4实验测试（恢复/tmp/ztransfer-gps-direct-probe-before原业务，保留GATT domain/code日志）。原EA待验证恢复、取消、身份策略不变；用户此前接受的系统配对路线回归。新增actual client→coordinator首次ID/三种picker结果都不能启动位置或接受手机坐标的集成回归，补之前只测单层的缺口。6项专项运行exec57793/logs/remove-probe-r1.log，结果待查；手机仍094710实验包，接下来沿用授权构建覆盖恢复版，**普通启动，不带实验参数**。不再让用户反复测试已失败免列表方案，不再添无根据新路线。完整GPS仍未解决；此次只是纠正回归，正常系统配对的硬件验收继续开放。未提交推送。

## 2026-11-07 09:49 保留BLE的第二免选择器实验已安装

held-link-r1 6项专项通过、TEST SUCCEEDED、exec85493 exit0，是既有78项中的修订/子集，不相加。脚本exec61885已exit0；094710包覆盖15Plus成功/保留数据，20秒构建+2秒打包+11秒设备，共33秒。随后exec80343带 --gps-direct-ble-probe明确启动，PID8594，参数已核实。证据held-link-launch.json、held-link-source-sha256.json、held-link-test-methods.txt、held-link-delta.patch及logs/held-link-*。新路径保留首次BLE/ID后连接→真实GEO，未验证前不存identity；原EA生产路线不改。已向用户异步请求相机重新开始配对→当前App开启GPS，若系统配对码确认则本人确认；不选设备、不复制日志。等待实际GEO/相机坐标/后续重连，3/4准备完成、E04仍未验收，不称已解决。当前手机新版本等待操作，不再安装重启干扰。goal工具仍blocked（API不能resume），用户消息已允许继续工作，未创建重复目标；无构建/采集遗留，无提交推送。

## 2026-11-07 09:38用户回报免选择器失败，已恢复实际修复

用户明确相机没反应、按钮配对→连接，已复制日志。手机缓存与剪贴板一致：09:38:50首次PAIR/stage3 ACK，09:38:51 ID ACK后旧实验主动断BLE，09:38:52已知UUID重连、09:38:57扫描，09:39:13超时丢候选停止；没有第二次握手/GEO。实证旧“跳过Classic后断连重连”失败，不泛化所有iOS免列表不可能。脱敏direct-probe-device-failure-0938.txt已保存。常规/network idevicesyslog均找不到设备，CoreDevice可访问，未取得新系统归档，不继续卡管理员工具。goal工具仍返回blocked，不能用update_goal擅自改active；用户已恢复工作，旧等待条件解除，计数重新起算，不创建重复目标。

solo将现有Debug --gps-direct-ble-probe改为首次ID ACK后保留现有BLE→真实GEO写入，不调用选择器/不主动断连；candidate仍内存、GEO ACK才持久化、45秒期限/失败停止保留。Apple受保护属性自动触发LE配对只是机制依据，尚未知Nikon GEO是否如此；独立协议作者仍要求Classic，不能声称已成功。6项专项运行exec85493，日志evidence/gps-pairing-recovery-20261107/logs/held-link-r1.log。本轮代码仅NikonGPSBluetoothClient与4个已有probe测试适配，正常EA路线保持；尚未安装新版本。下一步查真实测试结果后沿用授权Debug覆盖安装、带参数启动，再验证实际GEO响应；不要重复问旧方案/用户是否真的选相机。完整目标未完成。

## 2026-11-07 02:09 免选择器实验等待硬件动作，目标已blocked

第三个连续目标轮核验同一外部条件：手机实际进程仍为PID8479/015756试验包；GPS缓存仍不存在（CoreDevice7000），用户尚未反馈新路径的相机开始配对/开启GPS结果。上轮属于no progress，不是运行中的相机测试；未发现独立可推进的有效动作，不能用替身继续宣称GPS可用。本轮`update_goal(status: blocked)`已成功，完整目标“搞定蓝牙功能以及gps功能”未完成；不再自动循环查询、重装或重发同一问题。保留用户待答的新路径测试请求与试验进程；用户恢复后先核验当前进程/参数、读取GPS缓存/必要系统日志，根据真实失败继续修复，blocked计数重新起算。不要回退为清bond重测原窗口，也不要标记完成。无构建/采集遗留，无提交推送。

## 2026-11-07 免选择器实验第一次自动续查

上一目标轮为progress（新增免选择器实际路径、78项验证、015756包安装及带参数启动）。本轮只读手机：devicectl实际进程列表确认PID8479仍是同一个试验进程，未重启；GPS诊断缓存仍返回文件节点不存在7000。没有新GEO/配对事件证据，原异步问题未获回复。未重新安装或更改代码，不把进程活着当作正在做相机验证。相机开始配对/当前App启用GPS的同一外部动作等待已跨2个连续目标轮（含上轮末首次）；未达3，不标blocked/complete。后续再核验实际日志；若第三轮仍无变化、无独立有效工作，按goal规则标blocked，保留完整GPS/蓝牙目标与当前试验进程。旧清bond请求已被替代，不再要求。

## 2026-11-07 02:01 免设备选择实验已安装，待新路径硬件验证

78 GPS专项通过/exit0。Debug脚本exec41064已exit0，015756包29秒覆盖安装15Plus（1成功0失败），保留数据。随后exec10166 devicectl明确带 `--gps-direct-ble-probe` 启动成功，PID8479，launchOptions.arguments实证；证据direct-probe-launch.json。截图direct-probe-installed.png已看，连接页/GPS未启用；诊断缓存此时不存在（copy7000），不能说已有硬件GPS事件。新增异步问题call请求用户相机开始配对→当前App开启GPS，**不需要清bond、不选设备**；不要重复此前清密钥验证，也不要用户操作时再安装重启。新路使用现有真实定位，暂存identity只留内存，45秒期限，只有GEO ACK持久化；普通Release/无启动参数仍正常系统路线。App进程被杀重启会丢本次启动参数，若用户重启需由devicectl再带参数启动；不要私自持久化GPS开关。任务E01–E03完成、E04物理GPS未验（3/4）；完整蓝牙/GPS目标active未完成。新增4项包含取消/迟到/旧已确认身份不被删，78方法清单/hash/增量diff保存。无遗留构建/采集进程，未提交推送。

## 2026-11-07 GPS用户改为实际免选择器实验（覆盖此前等待清bond的安排）

用户明确“尝试无需手机选设备这一步骤是否可行，而不是让我重新测一下”。目标继续active，有实质实现工作，不沿用前两轮外部动作blocked计数。solo实现Debug显式启动参数 `--gps-direct-ble-probe`：首次BLE/ID ACK后同一身份只留内存→800ms重连→实际GEO验证，不调用EA，不伪造paired；45秒实验期限、失败停止、关闭/adapter/旧回调守卫，只有GEO ACK才持久化。既有确认身份保留，普通Release/无参数仍原路线。新增4个专项，全部GPSProtocolTests **78/78通过、TEST SUCCEEDED、exec25827 exit0**，日志`ios/docs/evidence/gps-pairing-recovery-20261107/logs/direct-probe-r1.log`；相机为替身，不能当硬件通过。手机正按已有授权脚本覆盖安装，exec41064，日志direct-probe-device.log；之后必须带参数启动，不能默认启动后声称免选择器已启用。完成情况追加同名GPS系统配对后连接恢复文档E01–E04。未提交/推送，物理GPS仍未验收。

## 2026-11-07 01:43 GPS目标第二次外部动作核验

前一目标轮是progress：取得系统旧link key失效/Non CTKD证据、修正文案、r4验证。本轮重新读取手机nikon_gps.plist仍为空；另用idevicesyslog archive取01:30之后当前系统记录，按GPS/相机配对相关事件过滤为空（/tmp/ztransfer-gps-followup-events-20261107.txt仅表头）。归档进程58537 exit0，ps确认无遗留xcodebuild/采集。未收到用户“忽略Z50_2系统旧bond并重新配对”的操作结果，无新GEO或配对成功证据。当前同一外部动作阻塞已出现2个连续目标轮（含上轮首次），未达3轮，不标blocked/complete。没有改生产代码/安装/重复测试或重新发送同一问题；原async请求仍待答。后续只读核验外部变化；第三轮若仍无操作且确无其他有意义工作，按goal规则标blocked，保留完整蓝牙/GPS目标。

## 2026-11-07 01:39 GPS本轮收尾状态

r4五项已有专项5/5通过，TEST SUCCEEDED及exec93567 exit0；不是新增5项，不代表硬件。新失败引导/Debug缓存尚未覆盖手机，当前003656可用于已经提出的清洁配对验证。实时日志01:33–01:39没有目标配对事件，采集exec73375已CtrlC正常exit0，无遗留采集/构建；后续用idevicesyslog archive读历史即可。用户尚未回答忽略Z50_2系统旧bond并重新配对的请求，必须保留待答；这是首次等待该明确外部动作，不能标记goal blocked/complete。继续目标需该设备密钥冲突先清除，不能以现有替身单测当作解决。

## 2026-11-07 01:30 GPS系统根因已查明：旧link key失效，等待清洁配对验证

目标“搞定蓝牙功能以及gps功能”active，solo。上一轮取得公开API适用边界属于实质证据进展；本轮进一步读取手机实际系统归档，不靠再改猜测版本。工具已安装 `/opt/homebrew/bin/idevicesyslog`！`idevicesyslog -u 00008120-000A08110CF1A01E archive /tmp/ztransfer-gps-system-20261107.tar --start-time 1793981040 --size-limit 60000000`成功（实际251MiB），解到/tmp/ztransfer-gps-phone-20261107.logarchive用log show时间/进程过滤。无对外上传。log collect需root、devicectl sysdiagnose密码已CtrlC取消，别再走管理员阻塞路。

00:05原轮：00:06:02.252 New link key，00:06:02.261 pairingComplete result:0；00:06:02.452 WirelessiAP BT_SUCCESS，00:06:03.096配件认证Passed，之后iAP断开，App00:06:12notFound。用户说配对成功完全正确，旧000352包丢identity是App bug；已安装003656处理notFound→pending→BLE验证。不要称MFi认证失败。

00:37新轮：系统用旧paired:1/link key连接→00:38:00.327 BT_ERROR_INVALID_LINK_KEY→picker00:38:00.329 BluetoothDeviceConnectFailedNotification→00:38:00.775关闭返回code2。证实是旧bond密钥失效，不是用户主动取消，不能通过忽略cancel/假配对解决。已async请求本人仅忘记iPhone设置蓝牙中Z50_2，随后相机开始配对、App关开GPS并双方确认；等待结果。现手机截图黑屏，当前仍003656包，不能正在操作时覆盖安装打断。实时过滤日志进程exec session73375写/tmp/ztransfer-gps-live-20261107.log（需要每次恢复查进程是否仍活），之后也可归档读历史，没必要长期空转。

系统还明确 `Non CTKD Device`/ClassicSMPSupported:0，此设备的CTKD跨传输自动配对路线不适用，继续已证实能bond的EA入口；不泛化到所有型号。当前只改三语既有失败帮助为条件式“若点选相机后窗口自动关闭，设置→蓝牙忽略该相机后重配”，并更正canVerifyCamera注释，不改业务取消策略。r4 exec93567正在5项配对子集验证，日志evidence/gps-pairing-recovery-20261107/logs/r4.log；完成需查真实结果。r3实际缓存检查存在80行3983字节，后加Debug缓存运行时落盘已证，但未安装到手机。脱敏系统证据3txt+hash已保存，同名任务doc更新。没有提交推送；权限沿用，不再问构建安装许可。整体GPS及重连/相机照片坐标尚未验收。

## 2026-11-07 GPS最新现场与免列表路线调查：后续系统证据已补在上方

已取得用户重新复制的00:37轮诊断：00:37:55 ID ACK→EA picker，00:38:00 EABluetoothAccessoryPickerErrorDomain/2→App failed/stop；不是30秒超时。用户明确“点了相机，窗口自己关闭”，不能把resultCancelled等同用户点取消。脱敏证据ios/docs/evidence/gps-pairing-recovery-20261107/device-diagnostic-0037-cancelled.txt；真实系统关闭原因未知。003656手机包仍未通过，现行cancelled分支仍会丢候选identity且停止；不能说GPS已正常。

用户问是否一定要手动选择。已纠正之前绝对说法：CoreBluetooth可自动发现连接BLE，受保护GATT访问触发系统配对；支持CTKD的设备可从BLE派生经典蓝牙密钥，bridging是联动profile不是无条件createBond。Apple WWDC2019/901与WWDC2022/10008公开依据。尚未证明Z50 II支持所需GATT/CTKD，不盲加选项。当前Nikon SnapBridge帮助把Z系列与Other Cameras分节；旧iOS“Select an accessory”位于Other Cameras，不能据此证明所有Z系列都必需。Android自行Classic发现/createBond，静默确认可能受系统权限限制；列表与确认不能混为一谈。photools所谓免配对先用SnapBridge再提取已有凭证，不解决首次配对；仅参考说明未复制代码/提取凭证。

本次继续独立调查，未改生产配对路线/未新装手机。后加Debug日志缓存已随r3编译，5个已有配对/窗口归属方法通过，非新增5项也非物理相机通过；尚未专测缓存落盘，手机仍没有该缓存。r3 exec1592已正常结束，无遗留构建。完整现状和下一步证据需求已补到ios/docs/GPS系统配对后连接恢复-20261107.md。此前模拟器/Debug覆盖安装授权持续，不重复询问；不提交推送。

## 2026-11-07 GPS实机notFound纠正及新失败：此前记录，最新诊断见上

用户报相机实际已配对却App提示重新配对，允许读取iPhone剪贴板。已用xcrun devicectl device pasteboard paste读取实际00:05轮次：Z50_2（非早期Z30），ID ACK后EA窗口打开，25秒后notFound，App直接failed/stop，根本没重连；手机无已保存identity。不是已证实的BLE重连/身份拒绝。证据gps-pairing-recovery-20261107/device-diagnostic.txt已脱敏。Apple alreadyConnected也不代表失败。实际系统iAP为何notFound没系统服务证据，不猜根因。

已改：paired/alreadyConnected/notFound/failed后保留显式pending身份（不是确认配对）再以BLE/GEO验证；cancelled和app30秒timedOut仍停止。pending跨重启保留，但GPS开关仍默认OFF；hasPairingIdentity供恢复/清除，hasSavedPairing仅GEO成功ACK后true。新verifyingPairing事件保留650/700ms首次GEO成功展示。取回同机系统已连接设备→已知UUID→4.5s fallback扫描，按同机名/唯一前缀约束；pending扫描/握手超时允许5s重连而不丢身份，真实stage2拒绝仍清除。清除同时删pending/name/UUID。台账ios/docs/GPS系统配对后连接恢复-20261107.md，前一轮旧方案被明确覆盖。

baseline仅alreadyConnected反证失败，不冒称notFound单测反证；r1广告Any字典跨隔离编译错误，提前取String修正；r2 74GPS+3展示=77通过，含四种系统结果后的GEO才确认、pending重启/超时/失败写入、同机选择。随后仅简化不可达错误文案、添等待旧连接释放的日志/注释。脚本003656包33秒覆盖15Plus、保留数据，1安装启动成功/0失败。用户00:39又报“相机没配对成功、退步了”，没有通过，不能终结GPS目标。

已截当前手机画面仍配对未完成，偏好无pending/identity；读剪贴板仍00:05旧日志。已异步请求“再长按上方蓝色GPS一次，已复制后回复；无需重新配对”，正在等当前诊断。工具可直接读取手机剪贴板，截图用devicectl device capture screenshot；不必找pymobiledevice或分享。新提示对应cancelled/timedOut，但当前轮次未取得不能断言。先保留现场，不删除系统配对/不反复重试。

当前源码额外补了DEBUG && !SWIFT_PACKAGE的GPSDiagnostics 80条缓存，100ms事件合并后台写Library/Caches/gps-diagnostic.log，后续不必每次让用户复制；在003656包之后，尚未构建安装，暂无新验证。没有提交推送。当前debug打包/覆盖安装授权持续，不重复询问。原始当前快照/偏好在/tmp/ztransfer-gps-regression-*；当次剪贴板/tmp/ztransfer-gps-current-20261107.txt仍旧日志。最近所有构建已结束；待新日志后继续实际修复，不将77测试当真机成功。

## 2026-11-07 GPS系统配对补齐：4/5，修复包已覆盖安装，待相机验收

本人反馈相机未配对成功，已明确接受iOS公开系统选择配件窗口，并要求以GPS可用为目标。solo再次对照Android eafc461d的ID ACK→Classic createBond→保存identity→800ms BLE重连→首次GEO ACK；原iOS在stage1即保存、ID ACK直接ready，实际漏整个Classic阶段。之前所谓完整链路回放注入ready，没有验证这一段，不能沿用为硬件通过证据。

现通过ExternalAccessory公开picker、前台延期/单窗口/30秒期限（Android同值）、系统确认后才存新pairing_confirmed与identity；旧无确认标记凭证清理，不动频率/帮助/其他数据。系统完成后扫描新BLE地址，systemPaired事件设置pending跨越重连，首次GEO ACK才显示650ms成功/700ms已连接。取消/超时/清除/适配器/关闭/AP及重复旧回调不复活、不假ready；已确认重连不再弹系统首次配对。不能用公开API静默删除bond/代按确认/取消OS窗口，已取消仍可见窗口须用户关闭；状态失效且不叠加新窗口。现GPS面板有三语系统步骤/失败/忽略旧配对指引，用户批准的平台交互差异。按实际isScanning才stopScan。

baseline旧实现4断言失败；r1错误变量重名编译失败后修正；r2 71通过，r3最终76不同方法通过（71GPS+3展示+2真实定位/手势UI），含系统驱动前台/窗口归属、身份迁移/延迟提交、错误取消/超时、四档GEO与确认过渡、冷启动两次OFF及按住关闭。蓝牙系统选择器返回是替身，没证明物理相机；已看第二次已授权冷启动OFF截图。台账GPS权限申请与设置引导修复第五轮，证据gps-system-pairing-20261106含baseline/r1/r2/r3、76清单/hash/本轮diff与截图。

用户已授权“现在覆盖安装”：Debug脚本产物ZTransfer-ios-debug-2.05-20261107-000352.app/.ipa，20秒构建/2秒打包/15秒安装，总37秒，1台iPhone15Plus通过localNetwork安装启动成功、0失败，保留数据。已请求本人在相机开始配对→Z传开启GPS→系统选相机/两端确认，再反馈相机成功与坐标/发送时间。P01–P04开发侧完成，P05等待物理相机/GEO验收，不能称已正常可用。没有提交推送。后续此轮安装已获授权，不重复索取；若用户追加反馈继续当前GPS目标。

## 2026-11-06 GPS冷启动与授权后闪退纠正：4/4开发侧完成，真机新包未验

本人指出一启动GPS就开启且重试，明确开关不持久化；又报允许定位后闪退。solo读Android eafc461d：NikonGpsRuntime初始OFF、ViewModel不自动开，setApModeBlocked明确不允许首次非AP报告复活服务。Android实际会写KEY_ENABLED供既有START_STICKY服务恢复，之前把它等同普通App冷启动恢复是错误。Android ERROR确实有gps_retry/toggleGps.retry，保留手动开启后错误重试。iOS已完全移除enabled持久化/冷启动续接，旧键只清理；配对/频率/帮助保留，AP发现不再受旧磁盘标志暂停。普通前后台切换保留本次已开启会话，进程重启默认OFF。

只读手机两份23:16:17/19真实SIGABRT栈，均为CBCentralManager.init断言→ensureCentral→start→GPS授权续接。原ips没有reason正文，不杜撰异常原文。源码真机专用restore identifier却缺bluetooth-central，模拟器原分支无此参数；前三轮模拟器/替身过关不能证明真机初始化。移除跨进程恢复注册/回调，与用户本次会话规则一致；同一普通initializer用于真机/模拟器；Info.plist/project.yml补bluetooth-central支持手动开启后后台工作。停止先发布OFF再Bluetooth.stop，避免同步disconnected复活重连。补状态按钮无障碍label，无可见样式动画改动。

baseline2方法15断言反证；r1删除磁盘guard后7模型断言失败暴露同步停止顺序，已修；r2 64模型展示全过，冷启动UI被空可访问label阻断，截图真实显示Enable GPS；r3补label后7展示/UI全过。最终去重68方法（61GPS模型+3展示+4UI），两次真实定位授权/终止重启验证OFF，再手动开启SEARCHING，最终OFF/授权4截图已看。旧恢复已开启测试错误期待已替换。台账GPS权限申请与设置引导修复第四轮，证据gps-cold-launch-crash-20261106含原日志、脱敏设备栈、hash、增量diff与截图。只读日志未安装手机，真机新包蓝牙授权/配对/GEO未验；未提交推送，无遗留构建。不要再引用前三轮“全链路”措辞覆盖冷启动和真机初始化缺口。

## 2026-11-06 GPS运行链路第三轮：追加3/3开发侧完成

本人再次要求检查GPS正常使用，solo按Android eafc461d NikonGpsService核对配对/ACK/周期/失败/重连，并覆盖iOS BLE协议及归属测试。发现上轮原生拒绝UI日志的locationServicesEnabled主线程警告，改仅denied后台查询、主线程续接，重复点击合并、代次隔离、弱引用；关闭/AP/重新授权/替代会话忽略旧结果，后台不跳设置。CLError.denied按当前真实授权处理，不再用迟到错误强判App拒绝；已授权保留普通定位失败重试。没有增加轮询、改变频率/协议/动画时长。

r1一次64不同测试全过：58 GPS协议模型+3展示+3真实CoreLocation/手势UI，4新增覆盖异步生命周期及四档完整配对→首次fix→ACK→650/700ms成功→静止周期→失败重试→重连立即写入→清除及晚到ACK/定时。系统查询主线程警告本轮不再出现；仍有工程及weak测试变量编译警告。原生定位弹框真实、BLE为替身；实际设置改权、物理BLE/相机GEO、真实后台定位未验，不能声称全部真机通过。台账ios/docs/GPS权限申请与设置引导修复-20261106.md第三轮，证据gps-runtime-audit-20261106含日志/64清单/hash/增量diff/附件，拒绝返回截图已看。未安装手机/提交推送，无遗留构建。

## 2026-11-06 GPS启用再次复查：追加4/4开发侧完成

本人要求再查确保GPS可正常启用。solo新增三项回归先反证（baseline 9断言失败）：Ask Next Time回到notDetermined被旧回调忽略、旧定位/写入继续；蓝牙获准后scanning未清旧permissionIssue；配对失败后用户明确重试进入授权，旧awaitingPairingAction挡住恢复。修复共用暂停定位工作/写入归属、所有GEO与BLE ready准入检查真实定位权限、获准清提示、显式retry提前释放旧配对等待。AP禁用与已关闭的迟到BLE事件入口拦截。完整中英繁公开设置路径补入指引，无私有URL、无新轮询。

最终60不同方法通过：final-r2 57模型/展示＋1原按住关闭真实UI，ui-r6 2真实CoreLocation UI（首次系统定位弹框允许→SEARCHING；拒绝→打开设置→仍拒绝返回保持指引）。新增GPSPermissionAuditHarness仅DEBUG，CoreLocation/TCC真实、Nikon BLE替身，不得说物理蓝牙已验证。首次弹框与拒绝返回截图已看。grant→resume依然由模型覆盖：Simulator Settings导航多轮未稳定进入定位详情，旧跨系统改权UI用例没有通过，最终明确缩为上述拒绝返回路径；r2/r3/r4/r5失败原始日志保留，不可将60通过描述为真实设置内改权成功。final-r1三个旧夹具用AP禁用避免硬件又注入BLE期望继续，已换可控授权/transport保持原断言；旧GPS手势夹具denied强行ready改authorized。首轮UI中英文错配及失败清理遗漏也已修成多语按钮＋XCTest teardown。

沿用模拟器授权；文档ios/docs/GPS权限申请与设置引导修复-20261106.md追加段，证据evidence/gps-enable-recheck-20261106含7轮日志、60清单、hash、增量diff、4张最终截图。未真机安装/系统蓝牙首次授权/相机配对及实际GEO写入/提交推送。无遗留构建。

## 2026-11-06 GPS权限申请与设置引导：4/4开发侧完成

本人反馈GPS提示定位/蓝牙权限后跳设置却没有开关。solo核对Android eafc461d enableGps/toggleGps与NikonGpsService；iOS声明齐全、旧notDetermined已经requestWhenInUse，不得宣称原来完全没申请。确认旧UI按错误文字跳App设置，把定位总开关关闭/受限/拒绝混用；BLE在定位之后启动，未申请时不应要求用户找蓝牙开关。新typed permissionIssue与统一续接按真实状态处理：未申请先请求，仅App明确拒绝跳公开App设置；全局关闭/系统限制在GPS面板显示中英繁具体路径。用户本轮要求下的iOS系统引导，无私有Settings URL。首次定位/首次BLE请求等前台；Always等BLE ready后前台单次申请，保留后台能力。Root返回只恢复授权，不自动重试相机错误；撤权取消GEO定时/晚到ACK、定位、BLE扫描/断连/ready不能覆盖权限状态或复活写入，关闭/AP守卫保持，无新增轮询。

r1 53项运行中既有相机恢复用例4断言失败（新续接过早清错误文案），已修；r2 54/54、r3最终GPS 51/51全过，去重54项（9新增），含用途声明成品、授权/拒绝/限制/总开关/恢复/取消及展示性能。首次notDetermined按Apple合同不额外查locationServicesEnabled，避免无谓同步查询。台账ios/docs/GPS权限申请与设置引导修复-20261106.md，证据evidence/gps-permissions-20261106含三轮日志、方法清单、hash、本任务增量diff。系统授权返回为替身；没有验证实际手机首次弹框、设置开关或物理Nikon GPS，用户这次具体触发分支未真机归因。未安装手机、归档上传、提交推送；无遗留构建。

## 2026-11-06 AP静默提示＋监看预设全量核查：10/10开发侧完成

本人要求AP检测不遮步骤，预设所有逻辑完整对照安卓；最初补充“给槽位写入”“点NP3后提示失败”，随后明确只按安卓代码核查、不再追问现象、“照着抄作业”。solo按Android eafc461d36da干净工作树核查入口/9槽、目录/分类/授权/解析、classic/V2、PASM/U档、写入/激活/清除、回读/回滚/取消、备份/bank隔离、导航/动画/文案/诊断；核心协议未发现新漏项。内置相机NP3移除仍是本人批准差异，不能补回。旧probePictureControl无生产UI入口，未移植实验入口。

AP仅展示始终保留两步，删除350ms提示任务，后台探测/失败重试/USB优先/STA保持。当前安卓源码仍含候选热点PROBING反馈，须如实记为本人本轮指定的展示差异。预设修复两层SwiftUI容器及错误容器identifier覆盖子按钮的问题：无障碍/自动化点目录可能命中返回；保留UIKit宿主标识，目录/清除独立标识。不改变业务或动画参数，不能说这是本人普通触摸写入失败根因。

最终去重85测试方法通过：r1 81协议/模型/组件，r7 19模型/文件夹/AP后台重试（含新增真实文件有效/损坏/不支持/拒读），r8两项真实点击首次目录确认取消返回及NP3→C9写入→激活→目录取消→清除。r2编译、r3未open、r4主线程隔离是新测试夹具错误，r5-r7标识问题均保留，不说一次全过。新增fileAccess注入默认仍system，测试用本地目录授权替身，真实扫描/NP3流解析运行；相机仅回放或替身，不能代替真机写入验收。中英繁各37资源逐字一致。最终C9及AP长探测/失败截图已看。台账ios/docs/AP静默检测与监看预设全量核查-20261106.md，证据evidence/ap-preset-audit-20261106含8轮日志/清单/hash。

早期只读手机报告：2.05(79)、Z50_2 V1.03、PTP/IP照片、9槽全空读取成功、D200可写但省略未注册槽，无operation；标准preferences未存目录不证明本人未曾选文件，后续不继续追问。原失败未复现/归因，按照本人最后的源码核查范围完成，真机写入/授权/性能未测。没有手机构建安装、真实相机改写、归档上传、提交推送；无遗留构建或设备读取进程。

## 2026-11-06 弹窗完整窗闪现：回归修复3/3开发侧完成，真机待验

本人随后反馈打开设置先闪完整窗，再展开。上轮“同一显示回调内隐藏即可防闪”的推断错误：drawHierarchy(afterScreenUpdates:true)可能提交渲染，不能短暂把屏幕上的完整源窗放出来。原10项测试及30fps录像没覆盖同步取图瞬间；保留历史结果但不得继续当作无闪现证据。本轮在同一宿主与内容之间增加屏幕可见性容器，取图时祖先持续不可见，子内容仍可完整取原生玻璃；取完在同一禁用隐式动画事务里隐藏源视图再恢复父容器，不改320/350ms、主题／红点／命中或网格。依旧solo。

新同步可见性检查反证：临时去掉父容器隐藏，旧顺序3次观察／3次露出，断言失败，finally恢复源码；最终3次观察／0次露出。r5十项组件＋r6两项UI共12项通过，含30组主题像素比较、快速反向、视口改变重开／预览安全区、空闲释放、连续3次真实开关及两入口模块／帮助／返回。液态玻璃差0.065–0.534，整窗0.467，4张按钮图及3次展开／末次收起30fps抽帧已看。r2测试隔离编译错误、r3错误期待同值KVO次数、r4基线450ms等待假设均如实保留并修正。没有新测取图中途尺寸变化；模拟器与录像不能替代真机。证据evidence/popup-source-flash-20261106；旧verification标记superseded。无遗留构建录像、手机安装、归档上传、提交推送。

## 2026-11-06 弹窗灯泡材质交接：追加3/3开发侧完成

本人反馈灯泡在弹窗动画期间显示错误，结束才闪现恢复。solo确认Genie的CALayer.render遗漏完整原生glassEffect底板／边缘；此前静态材质与整窗CALayer对比未覆盖此问题。captureContent先提交可见布局事务，再drawHierarchy(afterScreenUpdates:true)，同一显示回调内用新事务隐藏宿主；事务不提交直接换API会得到透明图，不能恢复该失败写法。保留完整iconControl、静态灯泡＋红点、原320/350ms运动及12条带网格，不增加逐帧取图或空闲时钟。

最终r5九项组件／布局／反向／释放＋r6两入口真实交互一项，共10个不同方法通过。五主题浅深模式三个按钮30组像素比较通过，液态玻璃均差0.065–0.107，原约6.4–7.6；真实设置窗均差0.467。修正原整窗测试参考图为UIKit层级，避免共同漏材质。基线4张、最终液态玻璃4张及整窗2张已看，实际进出30fps抽帧无提前完整弹窗闪现；模拟器结果不代表真机帧率／功耗。r1测试编译、r2基线、r3透明图失败均保留；r4修复后通过。台账ios/docs/图标按钮主题与效果模块收合-20261106.md，证据evidence/bulb-popup-capture-20261106。无手机安装、归档上传、提交推送。

## 2026-11-06 续费窗与已购显隐：追加5/5＋续费4/4，按钮文案1/1

本人最终采用：有效年费期间不显示永久升级／重复年度购买；取消续订保留本期，到期免费后重新选择两档，不永久锁定历史年费用户。此约定覆盖下文早期“年度用户自动选永久”及中间“日期＋永久升级”方案。设置年度左侧标题“续费”，帮助同步；窗口同名，只显示下次续费日期（取消则本期到期日）、适用异常与同行管理入口。永久若有历史年度待处理仍称“管理订阅”；真实共存权益／退款聚合不变。去掉三个点，免费恢复在底部，已有效Pro无恢复。自动恢复到达时直接切换内容，无强制selected永久；购买确认也复查权益。

本人确认管理订阅原来有内容只是加载慢；不要再声称持续空白或已修复苹果网络耗时。iOS17+用Apple返回的组ID管理，旧系统／缺元数据保留通用入口，返回刷新。solo沿用模拟器授权，最终3UI＋3StoreKit专项通过，覆盖小屏中文年度／取消／重启、英文取消再开启、免费三语12次切档／恢复、到期重新买年度再永久、历史共存退款、新实例自动恢复；准备清理均过。中间SE首次付款未送达的失败保留，测试改等系统按钮稳定后通过。13张最终截图已看，台账ios/docs/高级版弹窗精简与稳定布局-20261106.md，证据premium-renewal-20261106。

测试后本人追加去掉购买CTA末尾“／年”“· 永久”，现为方案名＋Apple真实价格，三语IOSLocalization同步，永久键覆写Android生成资源。此纯文案仅静态核对，未重跑构建／UI，旧截图仍有后缀。已同步快速清单、StoreKit说明及审核中英文（英文3957 UTF-8字节，仍是待本人核对草稿）。没有安装手机、归档上传、提交推送；真实沙盒/手机体验未新测。

## 2026-11-06 高级版弹窗精简：5/5开发侧完成

本人要求自动恢复购买、删冗余项、修复年费／永久切档高度闪变，并质疑恢复按钮多余。solo对照Android eafc461d LicenseDialogs及测试、Apple订阅购买页要求。确认现有启动／前台／交易监听已自动读取currentEntitlements，无需用户点恢复；不改支付验证、退款／到期或服务端。Apple要求购买页有已有订阅的恢复／登录路径，因此底部整行恢复收进右上角菜单，显式sync仅用户主动点击；未给设置加额外一行。重复法律链接只留设置，删除常驻续订开关文字／账号段落，保留简短年度自动续订说明、有效期／异常和年费转永久的取消提醒及管理入口。

切档不增删段落，购买按钮原48pt最小高度／两行14pt，选中与文字局部180ms淡变，无整窗动画或新增常驻时钟；弹窗内自动恢复到达时自动选永久档，避免已购年度档禁用。截图另修英文Supported截断，三列短值保留单行适当缩放，不改文案或共享列宽。

7个不同测试方法具有通过结果：6个本地StoreKit专项（含年度／永久新实例无需手动sync自动恢复）＋跨三语UI方法在17Pro及SE3各通过，最终12张状态截图已看，切档位置／高度／按钮高度稳定；r3首次切档24fps中间帧已看，后续仅短文字适配。r1月均硬编码3.33而Apple实际3.32、r2未处理Xcode模拟身份验证的测试问题均修正保留记录。台账ios/docs/高级版弹窗精简与稳定布局-20261106.md与evidence/premium-compact-20261106。真机／真实沙盒交易生命周期未测，未安装手机、归档上传、提交推送。币种排查仍待本人登录后的真实价格核对，不用模拟器人民币结果代替。

## 2026-11-06 高级版美元显示排查：2/3，Debug及美元金额已实机确认，待沙盒地区核对

用户问高级版为何显示美元。solo核查PremiumPurchaseView与StoreKitPurchaseStore：主价／CTA直接Product.displayPrice，月均同商品priceFormatStyle，无硬编码USD／人民币回退；普通打包Scheme未挂本地StoreKit，只有专项Scheme读取CHN配置，不能混淆本地39.90／99.90与真实沙盒。本人已明确Debug；devicectl同机截图确认年费US$5.99、永久US$14.99，不再索要渠道／金额。只读运行时storefront尝试未成功，未取得国家代码；随后正常重新打开App，无重装。Apple论坛845478为TestFlight同机USD报告，不能套用当前Debug或保证正式版自动恢复。本人追加点击购买要求Apple登录：已核对官方开发签名首次购买需独立Sandbox Apple Account，入口设置→开发者→沙盒Apple账户，无需退出日常账号；普通Apple账号不等于沙盒测试账号，沙盒交易不扣款。新截图只见桌面，未读到登录弹窗全文，不得声称已验证登录状态。后续本人自行创建中国大陆沙盒账号，助手实际看到后台测试账户列表；16:47同机截图见Apple登录框，按要求仅复制邮箱到手机剪贴板，本人完成登录并反馈成功，原始凭证不存仓库。台账ios/docs/高级版价格币种排查-20261106.md仍P01/P02完成、P03待登录后商品币种／购买确认页核对，不能把登录反馈当交易验收；历史后台人民币39.90/99.90不是本轮在线复核。币种排查只改记录，无生产代码变更／改价／代创建或登录／购买／构建／安装／提交上传。

## 2026-11-06 NP3目录入口文案：1/1完成

本人明确要求“设置滤镜文件目录”改为“设置NP3文件目录”。已修改iOS专用本地化photo_filter_set_folder，简中按原话无空格，繁中“設定NP3檔案目錄”、英文“Set NP3 folder”；相机照片效果／本地工作台共用入口同时生效。保留原资源键与目录选择行为，未改Android。同步既有测试期望和手工清单／首发台账的现行文案；台账此前已通过结果仅代表旧文案版本，本轮未新运行这些测试。静态核对共用调用链、三语键和值及git diff --check，无构建、安装、提交或推送。

## 2026-11-06 图标按钮主题＋效果模块收合：5/5开发侧完成

用户要求统一所有灯泡及返回／关闭按钮的液态玻璃适配，追加管理模块隐藏时动画异常。solo对照Android eafc461d的TipLightbulbButton／GlassBackButton、PhotoColorEffectGroup、SettingsScreen与模块测试。iconControl共用完整公共材质，移除灯泡embeddedInPanel分支；浅深五种主题均核看，拨轮内部材质不改，灯泡继续静态图标＋未读点，不恢复呼吸。核查设置／效果／日期／工作台／队列／监看／回看／帮助／购买／诊断导航按钮，原已完整材质的预览等保留正确路径。

模块改为局部240ms顶部真实高度收合＋200ms淡入出，尾间距一起插值；移除整列两处布局动画。SwiftUI结构移除会先丢父高度，故保留退出View至240ms单次可取消任务收尾，快速恢复取消清理；多行内容先组列，LUT等立即取消时缓存原退出高度，避免子编辑器缩短叠加。弹窗自然高度只由外框modifier订阅，首次测高／旧回调隔离与预览安全区规则保持。模块掩码、免费联动、最后一项保护、持久化和业务取消时机不改。

最终13个不同测试均有通过：r9最终生产代码12通过／1UI查询Close歧义失败，r10仅修测试查询后两入口完整通过。覆盖中间高度、间距、反向、静止无残留更新、被观察编辑器立即取消、多行180pt、5弹窗布局、材质动作禁用、菜单与帮助／返回实点；父层只因显隐求值2次。最终两入口24fps抽帧及13视觉证据已核看。r1/r6测试编译失败、r2-r4结构高度问题、r7-r9 AX祖先覆写／原生双层元素误查均如实保留，非一次全通过。台账ios/docs/图标按钮主题与效果模块收合-20261106.md；evidence/effect-modules-glass-20261106含十轮日志、16输入hash与最终核销。无遗留构建／录像进程。真机手感、帧率、功耗未测，无手机安装、归档上传、提交推送。

## 2026-11-06 STA首次配对核查＋队列胶囊／生成标签：4/4开发侧完成

用户要求跟进安卓最近的首次STA配对优化，队列页隐藏速度胶囊，以及生成标签省略。solo fetch确认本地android/origin均eafc461d、工作树干净。完整对照0da7b8e4与ca03503c实际入口ConnectionViewModel→WiFiConnectionService→STAConnectionCoordinator→STABrowsingSession：当前源码已包含ACK立即断开、不清事件/不等4008/不CloseSession、ACK剩余6.6秒、同机相册＋实际帧证明、一次共用修复与清理恢复及配对状态保持。本轮未发现新增STA漏接、没有改协议生产代码；57项协议回放通过。手机安装包和真实首次配对未验证，不能声称同机问题已解决。

修复真实遗漏：LiveQueuePill旧条件“非队列或任务非空”改为仅照片页显示；共享Layout按实际胶囊宽度同步缩到零间距，兼容执行控件移除后单子视图，不影响固定右缘，不把每帧宽度写回父列表。隐藏时明确禁止命中；仍保留计数／Done状态。生成耗时／短状态在标签内部完整自然测宽，140ms向右宽变，长效果说明低优先级可省略、文件大小旧有可压缩布局保持，避免窄卡溢出。

去重78项最终通过：57协议＋21组件/交互，三种主题显隐、缓存原图实际开始完成、三次队列往返＋监看、滚动／右缘恢复、父层帧重建限制、22pt提案完整短标签、320/600pt汇总。r1新Layout单子视图失效已被实测捕获修正；r2-r4误用XCTest保留的禁用字形AX bounds判断可见，已结合0宽组件测量/截图/动作禁用/实际开始操作验证；r7新增往返使次数6→8，修正测试后r8通过。实际24fps出入帧已看。台账ios/docs/STA与传输页行为对齐-20261106.md；证据ios/docs/evidence/sta-queue-20261106。无手机安装、归档上传、提交推送。

## 2026-11-06 日期分组展开／收起专项：4/4开发侧完成

用户反馈日期分组动画生硬。solo完整读取Android GroupedPhotoGrid/collapseHeight/GroupHeader/ThumbnailCell：收起300ms逐格真实高度＋透明度，6pt行距一起收缩；展开220ms、每行18ms最多4行、600ms窗口，保持即时恢复懒布局，收合中忽略竞争日期/连拍操作。

iOS改掉整块LazyVGrid裁切收缩，改为格子外层PhotoDateCellCollapseLayout（含底部6pt）逐行实际布局；标题下10pt永久保留，消除末帧跳动；箭头默认临界弹簧1500，离页结算半程收起并清空入场窗口。没有新增常驻计时，保留可见前缀＋缓冲一行、收合停止取图与普通滚动不入场规则。

最终r3五项测试通过：两渲染检查、浅深主题实际列表滚动复用已解码图、双日期各9张反复切换／次组终点一致、点击滚动长按互斥；30fps实际录像中间帧已检查连续逐行移动／淡入出，无终点间距跳变。r1/r2因模拟器旧1日加载范围导致fixture缺第二组，已仅隔离测试输入并保存恢复，未修改正式加载业务。离页结算只静态审查，真实相机／手机热量未测。台账ios/docs/日期分组动画修复-20261106.md；证据ios/docs/evidence/date-groups-20261106。无手机安装、归档上传、提交推送。

## 2026-11-06 筛选无结果空态修正：追加7/7

用户指出无匹配照片的图标错误、清除筛选文字越出按钮。已对照Android emptyFilter和GlassButton：复用顶部PhotoListFilterIcon轮廓44pt，替换系统三横线圆圈；清除按钮14pt labelLarge／medium，单行自然宽度，label内部水平14／垂直8pt padding及20pt圆角，材质包住全部内容。原呼吸及评级显隐、关闭弹窗与clearFilter接线不改。两项静态核对及git diff --check通过，未新增测试、构建、安装或提交；此前19项不是本次新验证。台账原6/6，反馈A01–A07为7/7开发侧完成，真机视觉待用户体验。

## 2026-11-06 日期页进一步紧凑化：追加5/5

用户要求去掉两行拨轮右上侧重复日期值并释放高度。已移除DateEndpointEditor摘要Text及外层VStack／6pt间距，两端各只占50pt拨轮行，外层自然测高随之缩短，不用透明占位。用户最新要求覆盖下方摘要10pt的旧显示约定；不改安卓。静态检查共用组件与原日期回调、git diff --check通过；局部低影响布局删除未新跑测试、构建或安装。前一轮19项及截图仅为旧摘要版本证据，不冒充本轮验证。台账原6/6、用户追加5/5，无提交推送。

## 2026-11-06 筛选操作反馈与日期页转场：追加4/4开发侧完成

用户实际反馈日期／重置无按压、日期页闪现、清空／完成像文字且字号异常。此前同日静态“未发现问题”没有实点覆盖，已在原台账和followup-review.json纠正范围。solo修复；沿用模拟器专项授权，不安装手机、不归档上传、不提交推送。

四个操作使用公共GlassButton按压（快点保留90ms视觉、不延迟动作）、12pt字体；清空／完成尺寸放在label内部，底板整行40pt。日期页复用双层淡入淡出，Android入150ms／出100ms；核对Compose1.5.4 SizeTransform为刚度400／阻尼40，不能写成1500。仅外部实际插值高度负责尺寸，内部根容器minHeight0允许收缩，避免旧页撑高后被UIKit居中导致中途上跳。关闭／后台停止淡入淡出时钟，重开直接主筛选页；不改评级、日期草稿或重置业务。没有保留公共Genie宿主的同步布局实验。

本轮19个不同测试最终通过（r3公共兼容12项＋r7最终筛选组件／实点7项）；最初两项测试假设错误、一次Swift隔离编译错误已修正，过程日志保留。功能测试通过后仍从录像查出中途偏移，直到r7逐帧确认进入／返回顶部固定、内容淡出入及连续尺寸才核销。7张截图／帧序列与快速重复重置trace在ios/docs/evidence/filter-motion-20261106；任务docs/待做/iOS-20261106-安卓增量复刻.md原6/6、追加4/4。真实手机视觉手感仍待用户验收，TestFlight79不包含本轮。

## 2026-11-06 Android 筛选与延时档位增量：开发侧6/6，基准89018097

本人随后要求“检查一遍”，solo复查同轮完整差异及重置/持久化/评级取消、日期宿主状态、延时偏好与取消门禁三条调用链，未发现新增问题；13个iOS最终输入和7个Android输入hash与已测版本一致，三语881键及旧引用检查通过。补充followup-review.json与台账复查记录；本次仅静态审查，不改生产代码、不重跑构建/测试，不将原56项写成新一轮结果。

用户“安卓端又有了一些改动老规矩”。solo fetch并核对本地/远端android一致、工作树干净，ca03503cc0934a53c4ccf2362b56f45b0831b729→89018097b1f98aaaa85e01e31c966a34e364a65b，1提交7文件；下轮从89018097比较。台账docs/待做/iOS-20261106-安卓增量复刻.md为6/6开发侧完成，真机待用户验收。iOS原有大量未提交修改保留，HEAD仍58d9b6ed。

筛选底部新增整行重置，恢复全部默认/评级5日并清STA隐藏保护；普通STA编辑读取模型最新保护值，重置后旧回调不复活。关闭评级读取/重置后，之前已经发出的请求即使返回也必须丢弃，不恢复值或进度；不是关闭筛选窗就关闭评级开关。日期页默认手机当地今天，已有范围较新在上，两行独立、只确认时排序；删除起始/结束和存储卡标题及无用最新相机日期扫描，保持实际拍摄日加载范围不变。延时档位改关闭/2/3/5/10/30，旧20恢复关闭；原计时/取消/AF/MF状态不改。三语881键一致，已移除内置滤镜规则保持，手工清单C05/C07/H12更新；版本号未改。

沿用已授权模拟器专项，分批56个不同测试最终通过；首轮49通过/1新测试错误地断言异步秒数同步更新失败，修正测试订阅后复测7项通过，未改计时实现。8张实际组件截图逐张检查（筛选280/390评级开关、延时横竖/浅深），评级进度局部更新及关闭动画释放回归通过。日期页未做自动触摸，真实相机/真机功耗未测；证据ios/docs/evidence/android-sync-20261106。无手机安装、Release归档、上传、提交或推送，已上传79不包含本轮。

## 2026-11-05 上架资料缺项：重新登录后9类后台页面已只读复核

本人回复已登录后，solo用Chrome逐项读版本／截图、App信息、隐私、永久商品、年度商品、价格供应、订阅总览、商务及审核共9类页面。当前2.05准备提交、未选构建、手动发布、审核列表空；简中iPhone中屏与iPad13截图各0/10；两商品审核截图均未选择文件；内容版权仍设置入口；ICP号未填；审核联系人／英文通用备注已有，无硬件视频链接或附件。隐私未收集草稿可发布，按钮留本人。已更新ios/docs/AppStore上架步骤与分工.md顶部7类缺项，不再写登录阻塞。

在线确认付费／免费协议有效、银行可用、两税表使用中、810／DSA有效；App中国大陆下载价0元，148供应／27未供应；Mac与Vision Pro均未供应。两商品各148地区、家人共享关，年费1年预付、多名额不允许；宽限期16天仅付费转付费、仅沙盒，正式环境仍待既定业务收尾。未重查所有商品全价表和所有地区合规，不能宣称真实支付或所有区域通过。没有保存／改价／改版本／添加以供审核／发布隐私／提交审核／构建／上传。1.0仍未执行；可选营销素材、服务器通知URL、旧共享密钥等空白不列成缺项。下段登录过期为本轮较早过程。

## 2026-11-05 上架资料缺项检查的初次记录

用户要求检查iOS上架还缺什么资料。solo读取最新商业／79上传／素材记录和Apple官方硬件审核、首批内购提交说明，已在ios/docs/AppStore上架步骤与分工.md顶部整理7类待办：商店截图、两项商品审核截图、硬件视频与代表设备资料、公开素材内容权利、隐私标签发布、中国大陆发行备案资料、最终版本／构建及同批内购关联。明确会员／协议／银行／两税表／810／无欧盟DSA已有完成证据，不重复索取；50个内置滤镜已移除，不再列为等待许可。真实支付与硬件验收及正式宽限期另列为非资料收尾。

本轮Chrome现有79详情页可读，但转分发页刷新后Apple登录过期（authResult=FAILED），已请求本人在浏览器登录、无需发送密码验证码。尚未取得本轮全后台逐字段复核，不能把上述记录来源当新在线验证。另见腾讯云APP备案草稿苹果包信息未完整添加，仅记录未完成状态，不改该草稿或读取／落盘证件详情。本轮只改文档，无后台修改／提交／发布／构建；1.0仍未改工程或后台。

## 2026-11-05 手工全功能测试文档；iOS 独立版本编号仅讨论

用户要求一份可按内容快速测试完整 App 的 MD，新增 ios/docs/iOS全功能快速测试清单.md，并从 ios/docs/上架前验收清单.md 链接。按真实操作顺序覆盖启动／设置、USB、列表／筛选、预览／裁切、队列／输出、照片效果、工作台、监看、AP／STA、GPS、购买、权限／性能，提供16项快速路线和失败编号模板；所有结果初始未勾选，不据文档核销硬件或支付验收。明确79不含之后的目录入口／拨轮震动修复、手机端监看录制豁免、无内置滤镜及Debug模拟权益不等于真实Apple购买；旧上架清单历史范围已加醒目标注。本轮仅文档和静态核对，无构建／安装／上传／提交／推送或新增真机结果。

用户同时询问新 iOS App 是否应与安卓独立编号。建议首发公开版本1.0、构建号继续递增（例如80）、安卓2.05只作复刻基准；当前仍是建议，未获改号指令，未改工程、已上传包或App Store Connect。后续若实施，需同步实际包版本与待提交商店记录，不把旧2.05(79)改名当新包。

## 2026-11-05 TestFlight首轮反馈（优先于下方历史记录）

79上传后新增要求已完成：初始滤镜改为“设置滤镜文件目录”并像LUT一样短按选择目录；拨轮没有真实跨档不得因按住/滑动预震。两入口共用PhotoNP3Chooser和DetentWheel已修改，去掉拨轮按下即触发的渐强震动，保留真实跨档反馈与成功长按确认；其他控件不改。沿用本人之前的模拟器专项授权，37个不同测试最终通过，N01–N03为3/3；第一批36通过/1测试宿主漏挂展示层失败，Debug宿主修复后2项复测通过（覆盖两入口目录选择/取消和实际名称/强度拖动）。触觉事件已测，真机马达体感未测。证据在ios/docs/evidence/first-feedback-20261105/filter-folder-wheel-haptics.json。此轮源码**不在已上传79内**；未新Release归档/上传/安装/git提交。追加任务见ios/docs/TestFlight首轮反馈与首发收尾-20261105.md。

最新结果：本人批准的2.05(79)正式归档、严格签名/包检查、Apple线上校验全部通过，2026-11-05 15:36:55上传成功。Apple处理完成后已加入“本人内部测试”，构建ID73e31cd6-24f3-459a-a7ce-9300d46139bb；组页实际1测试员/2构建，79正在测试、90天后过期。79简中/英文测试重点已保存并刷新回读逐字一致，78保留为旧包。任务T01–T04/T06完成5/6，T05保留真实商品价格、购买/恢复和真机验收；分批380个不同测试最终通过、5项合成检查及真正79归档资源检查通过。无手机安装、App/Beta送审、隐私发布、公开发布、git提交或推送。整体上架仍待真实验收及正式截图/硬件视频/内容版权与相关地区事项，不得把上传成功当全部功能已测。后文“正在执行/尚无新Release”为本次上传前记录，以上实际证据优先。

本人已明确改为移除50个许可不明的内置手机滤镜，保留用户导入；取代此前“保留手机滤镜”的决定，不能继续把版权许可当等待项而保留这些参数。新反馈并行保留：所有显示上下箭头的拨轮必须支持上下拖动快速调整（不限滤镜或某个入口）；高级版窗只留正式购买流程需要的操作，缩短并去掉滚动条；日期分组展开/收起修复闪现。由主代理独立处理，记录见ios/docs/TestFlight首轮反馈与首发收尾-20261105.md。当前78不会自动包含新改动，不得沿用以前测试结果核销。用户已同意查看78商品价格，尚未收到实际价格结果；本人已批准模拟器专项验证；拨轮/日期分组/购买窗17项通过。拨轮根因是onChange捕获旧配置导致箭头与dragSession不一致，已使用回调新配置修复。50个内置滤镜源码移除及导入/旧配置/队列恢复验证已完成；分批380个不同测试最终通过（包含本地StoreKit39.90/99.90价格类型周期验证）、合成包检查5项通过，T01–T04为4/6完成，仍无新Release/真机/实际支付结果。本人现已明确批准归档、校验并上传2.05(79)，更新本人内部TestFlight；允许所需修复重试，不安装手机、不提交审核、不公开发布。正在执行，新状态必须以产物与后台结果核对；不得拿78当新版。商店简中/英文描述和审核备注已保存回读，补充滤镜/LUT由用户导入、无内置调色预设；后台仍准备提交，手动发布为1，无审核提交。未要求提交git、推送或手机安装，所有审核/发布继续留本人。

## 2026-11-05 App与两项商品已建立；所有送审/发布由本人点击

最终内部测试结果：Apple已处理完2.05(78)，构建ID85122ebb-d75e-494f-8418-12fa8210b3e5；已加入“本人内部测试”组。实际组页显示1测试员/1构建、构建“正在测试”且90天后过期，本人账户“已邀请”。简中/英语Beta资料及本构建测试重点均已保存并复读，自动分发关闭。无外部组、Beta审核、手机安装或真实购买/相机验收；步骤9仍开放。下方13:30“正在处理/0构建”为中途记录，已被本结果替代。本人问测试永久购买能否停用：仅解释Apple的90天期限及沙盒权益不继承为正式购买；手动Expire Build官方明确保证停止安装，不能宣称已安装/离线设备立即被远程封禁。测试结束后停止给该用户开放新包，避免其持续换新测试包。未实际停用78、移除测试员或改支付逻辑；静态核对Release无持久化Pro开关，Debug模拟购买读取隔离，跨环境实机尚未测。

最新执行状态（2026-11-05 13:30）：Release2.05(78)已正式上传成功。最终归档ios/.build/appstore-20261105/ZTransfer-2.05-78-ipad-compat.xcarchive；ARCHIVE SUCCEEDED、codesign严格验证和发布包检查通过。实际Info.plist确认UIRequiresFullScreen=true、两平台Portrait、ITSAppUsesNonExemptEncryption=false、profileTeam6YY8Y34949。Apple线上validation记录Validated ZTransfer/EXPORT SUCCEEDED；upload.log于13:25:34记录Upload succeeded/Uploaded ZTransfer/EXPORT SUCCEEDED，进程exit0，无运行中的构建/上传任务。TestFlight实际上传表识别2.05(78)，13:30状态“正在处理”，待处理后给本人内部组分配，不重传同一构建。原失败归档/日志保留。付费App协议有效、银行可用、两税表使用中、810/DSA有效；步骤6和7核销。内部组1名账户持有人/0已分配构建，自动分发关闭，中英文Beta说明/反馈邮箱/隐私URL已保存；没有外部组或Beta审核。未安装真机、送审、发布、提交git或推送；真实购买/恢复与设备运行未验证。滤镜本人确认可能转发、许可不确定，保留功能但版权项/P10仍开放。

本人询问同版本反复构建：已按Apple官方规则说明，未上架时商店版本可一直2.05，新上传包构建号需递增78→79→80，不覆盖已成功处理的同一构建；上架后代码更新需新商店版本并审核。本次未要求改版本/重传，不因此改工程。以下同日记录是历史过程；其中待签、等待银行/协议、正在归档/上传等描述已被以上实际终态替代。

最新iPad决定：正式2.05(78)已归档和本地签名/发布包检查成功，但Apple线上validation明确因仅Portrait却未采用全屏兼容而拒绝。本人已回答“保持竖屏，采用兼容模式（建议）”，允许UIRequiresFullScreen=true，旧系统不使用分屏，iPadOS27仍有缩放结束后的离散resize；不新增横屏、不删iPad目标，更新此前多任务方案。已同步project.yml/Info.plist，需继续归档校验上传；前版archive和validation失败均保留ios/.build/appstore-20261105，不把它当已上传。所有构建/校验/上传授权持续有效，不再逐次确认修复重试。

最新商务结果：本人在重新打开的W-8BEN完成核对与提交，助手实际读取商务表格：W-8BEN和Certificate均为2026-11-05提交、“使用中”；付费App协议从等待用户信息变为“正在处理”，银行仍“正在处理”。W-8BEN已完成，不得继续要求填写、签署或重试，也不要把先前通用报错当现状。法律实体、两份税表、810及无欧盟计划的DSA均已由本人处理；商业配置整体仍等付费协议/银行生效，尚未证明真实沙盒可用。

下一验证节点本人已明确批准“允许归档、校验并上传”：授权Release2.05(78)使用付费团队归档、校验并上传ASC准备内部TestFlight，不安装手机、不送审、不公开发布。已启动xcodebuild archive，输出在ios/.build/appstore-20261105/，复用/tmp/ztransfer-prepay-release-20261102缓存；以实际进程和日志确认结果，不因本条视为成功。TestFlight已创建“本人内部测试”组，关闭自动分发，实际0测试员/0构建。本人说明50个保留手机滤镜是群友发的，已继续询问是否原创且允许随App分发；来源渠道不等于分发许可，版权项仍未设。后台其余不适用的医疗/游戏/服务器通知项不因有按钮就新增配置。

同日后续出口配置：solo复查Nikon GPS配对和SHA256用途、Apple系统加密分类、BIS对authentication/data integrity的界定，按仅使用豁免加密在ios/project.yml与ios/ZTransfer/Info.plist写入布尔false的ITSAppUsesNonExemptEncryption。私有配对消息格式不自动等于自研数据保密加密；当前转换只认证时间戳/nonce，照片和GPS载荷不走它。ASC上传向导仅列专有和系统外标准算法，未乱选、已取消，未提交材料/批准编号。依据详见ios/docs/隐私清单与数据流核查.md；不宣称EAR99决定或后台已审核通过，首次真机Archive仍须核对依赖/最终键值和处理状态。本轮不构建/上传/安装/提交/推送，原W-8BEN仍需本人实际签署，不因税务口头回复核销。

同日后续优先状态：本人拒绝发送Apple财务问询，要求先参考网上实际分享；未发送。已结合IRS当前说明及Apple论坛亲历转述，提出W-8BEN“仅证明外国身份、不提出特定协定优惠主张”的路径，Part II第9–10项和收入选项均空，不填0%/10%；6.a与生日已在原表内，未代签提交。最终还需本人核对个人资料/税务居住地址并签Part III。详情与来源已记录上架手册，不再把联系Apple财务当硬性前置。不能保证本人的全部收入免税。

随后本人回复“已核对并提交”，但商务页仍显示W-8BEN缺少税务信息，最初原表两项声明未选。本人再实际勾选并点击后出现“当前无法处理你的请求。请稍后再试。”，按钮已启用，不能再说只是未勾声明。独立商务页复查仍缺税务信息，第一份Certificate使用中、付费协议等待用户信息、银行正在处理；Apple状态页当时全部正常，未能据此定位税务报错原因。助手保留原报错表，在最后一个ASC标签页从商务页新开W-8BEN，按原授权补回相同税号与生日并确认一致，Part II不变，新表Part III留本人核对签署；已请本人仅重试这一轮，当前待结果。不要改税率或协定来碰运气，不代签，不把系统通用错误说成明确资料错误，不重复索取已有敏感资料；原始值仅用于Apple表单，不写仓库。

隐私草稿已保存：ASC实际预览“未收集数据”，发布按钮可用，未点发布。已纠正把外部QQ/邮件客服直接算App内采集的过宽判断：两反馈按钮仅复制公开QQ，固定法律链接无附加用户数据；本地照片/定位/权益没有开发者上传路径，Apple单独收集的分析/付款无需重复列入。320个联网清点输入比较，318一致、2工程配置变化；这不是抓包或新增文件完整扫描。依据及范围见ios/docs/App隐私问卷填写依据.md。以后新增App内客服上传/第三方SDK需重新申报。下方“隐私问卷未填”是此前状态，以本条为准。

商务最新进展：本人已完成法律实体更新、自行接受付费App协议，并自行确认添加银行账户。实际银行状态“正在处理”，付费协议最近核对仍“等待用户信息”，不能说已有效。本人完成税收问卷后生成两份表，并亲自提交U.S. Certificate of Foreign Status of Beneficial Owner，后台已显示2026-11-05提交、“使用中”。W-8BEN仍未提交；助手已打开并阅读Apple内附提示及IRS说明，不能把“Optional”当全部可省略，或擅自填写0%/10%与协定条款。本人随后主动提供资料并明确要求助手代填，6.a与生日已在Apple表单写入并确认有值，原始值不入仓库；第9项、税率及最终声明均未操作。原W-8BEN标签页保留未提交。本人后续明确授权将其号码用于810号表；助手填写后由本人点击完成，后台实际已显示2026-11-05、“有效”。810号已完成，不重复索取或填写。本人随后明确“不在欧盟吧，麻烦”。已在DSA选择“不是交易商，或者没有欧盟分发计划”的合并选项，依据是无欧盟计划，并保存；后台显示DSA有效。逐项取消27个欧盟成员国，App供应确认148，年度1年预付确认148/175，永久商品显示已保存148/175。三处均完成，未误取消英国/瑞士/挪威等非欧盟地区；未公开联系方式或上传DSA证明。原先175地区目标由本次决定收窄为当前148个非欧盟地区。全部最终声明由本人核对签署。W-8BEN第10项不能套用Apple旧提示：IRS2021说明对主张无美国常设机构营业利润待遇有明确附加要求；当前收入分类/预扣仍待确认，财务支持问询草稿已写上架手册但未获发送授权、未发送。下一轮先读取真实UI，不重复要求银行添加、第一份税务证明、生日或6.a填写。

用户明确“需要提交审核的都留给我点提交，告诉我需要点哪些，我需要核对后再发起”。此边界持续生效：助手可填写/保存/核对草稿，不点击添加以供审核、提交审核、Beta审核或发布，不用API绕过；隐私标签发布也留本人。价格本人确认调整为年度¥39.90、永久¥99.90，已经在Apple完整价表选取并保存，不再使用原¥39.99/¥99.99作为正式目标。

已创建Z传，Apple ID6830945574、Bundle com.ztransfer.ios、SKU ztransfer-ios-001；Team6YY8Y34949已写project.yml并XcodeGen生成，plutil通过，未构建/安装/Archive/上传。版本草稿2.05、中文Z传/英文ZTransfer及新副标题、两语言版本文案/支持URL/隐私URL已保存。版权2026及审核联系电话本人已确认；不将电话全文留在仓库。App免费下载¥0.00及148个非欧盟地区供应草稿已保存，关闭Mac/Vision Pro/校园批量优惠，保留公开App Store及手动发布；未上架，地区条件仍未核销。无自有账号登录；隐私问卷未填/发布、内容权利/DSA/ICP尚待实际依据，不能视为整体送审就绪。付费前台账P17已核销，当前14/18；P10滤镜来源/P14截图/P15实机/P16视频仍缺，不再重复询问版权/电话等事实。

永久Non-Consumable com.ztransfer.ios.pro.lifetime（6830950193）人民币基准¥99.90；年度自动续期com.ztransfer.ios.pro.annual（6830954364）1年预付¥39.90；订阅组ZTransfer Pro（22547521），组本地化高级版/Pro。两商品简中/英文名称描述及审核说明已保存，当前148个非欧盟地区供应已保存；无家庭共享、无多名额、年度只App Store渠道，未开12月合约按月付款。宽限期已保存16天、仅付费转付费、仅沙盒，正式上线前另核对正式环境；两商品审核截图仍缺，真实商品加载/沙盒未验证。详见ios/docs/AppStore上架步骤与分工.md，后续补齐实际配置结果；以下“无App/未建商品”为最初核查历史，不能当现状。

法律实体表单历史：中文城市/省份被判无效，原地址过长；经本人要求，助手在保留信息的前提下拆为两行并恢复英文格式，随后本人完成保存并接受协议。不能再把“等待地址保存”作为现状；表单格式通过也不等于全部身份审核通过。该地址是本人提供的户籍地址，不能未经核对自动断言适用于所有银行或税务字段。首批App版本、年度、订阅组、永久须同一审核提交单；所有送审/发布均留本人。

## 2026-11-05 Apple会员初次核查记录（后续App/商品配置见上文）

用户收到批准邮件后要求核实能否继续。solo通过Chrome实际读取Apple Developer账户，Program个人会员、Team ID 6YY8Y34949、续订日期2027-11-06，Program许可接受日期2026-11-05。本人自行登录及完成App Store Connect首次服务条款；助手未代签。ASC实际App列表“无 App”，商务页免费App协议“有效”、付费App协议“新”，明确要求先更新法律实体；欧盟交易商状态待提供，银行税务详情未进入不作完成判断。会员审核阻塞已解除，上架手册步骤5已核销，付费前材料仍13/18。未建App/商品、修改账户资料、刷新Xcode签名、构建/安装/Archive/上传/提交/推送；不能视为正式沙盒已可测或通过。旧手机7天开发包不会因会员升级自动换签。后续按ios/docs/AppStore上架步骤与分工.md步骤6–9继续，法律/税务/地区事实由本人填写。此次不保存网页完整AX或个人地址/电话，只有必要状态记录。

## 2026-11-05 iOS联网/备案静态核查7/7，无产品修改

同日用户确认外链跳转浏览器并要求留档、以后需要再改。文档已明确：App仅openURL发起跳转，网页请求由默认浏览器完成，无自定义openURL拦截、内嵌WebView/SFSafariViewController或App自行下载法律页面；不要将其混写成App内部自有业务请求。已记录法律入口/配置、两条地名链路及未来抓包的分类位置，未授权或实施功能删改。

用户询问除Apple服务外的联网行为及局域网是否需APP备案。solo静态扫描生产Swift、项目依赖/权限和C/C++桥接，记录ios/docs/iOS-联网行为与APP备案核查-20261105.md及evidence/network-audit-20261105/source-inventory.json。未发现安卓后端、独立HTTP业务API、广告统计/崩溃上传SDK；AP固定192.168.1.1、STA本地接口/local.Bonjour/TCP15740，USB/蓝牙本地。但设置/购买页隐私条款会openURL自有www.ztransfer.top；CLGeocoder地名、StoreKit可联网；用户选择PhotosPicker/iCloud、第三方File Provider或分享应用可能触发其网络。生成资源中APK URL无执行调用，反馈只复制QQ。未改生产代码/构建/安装/抓包/提交/推送。

法律表述须区分：工信部对象是在境内提供互联网信息服务，互联网协会2026-01-07FAQ称单机不联网无需核准，Apple现行帮助称“部分App”要ICP备案。没有查到“只调用Apple服务即一律豁免”或本App组合的明确官方认定；局域网设备通讯不等同公网信息服务属于技术/规则范围分析。不能声称本App已获免备案，也不能因政策外链就断言必然需要；应如实向Apple/住所地管局确认。源码不是抓包，不能保证系统底层仅访问Apple自营域名。未为规避备案删除功能。

## 2026-11-04 Android 2.05增量开发侧12/12，基准ca03503c

用户“安卓又有了一些新功能，还是老规矩”。solo拉取并纳入本地android最新，8a09e51b→ca03503cc0934a53c4ccf2362b56f45b0831b729，共4提交/38文件，末次源码hash一致、工作树干净。台账docs/待做/iOS-20261104-安卓增量复刻.md开发侧12/12，真机待用户验收。iOS HEAD仍58d9b6ed，保留既有未提交代码/网站，本轮未提交、推送、安装手机。下轮从ca03503c比较。

新增照片模式延时拍照0/2/5/10/20秒、持久化/隐藏归零、独立工具排序、锚点选择窗、秒数逐位动画、再次取消、MF保持/AF确认及实际模式复查。计数只订阅快门局部；后台/断连/回看/编辑/模式切换/退出取消，AF与已发送快门排空再关闭监看；会话队列与USB/IP发送口均检查共享许可，取消后不再发快门，不额外AF，有界200ms×5忙重试。参数拨轮/AUTO及相机写入互斥，临时常亮恢复。物理模式切换采用正常focus/exposure刷新；保留iOS端侧录制不提供等既有差异。

本轮STA新规则取代11月1日旧4008规则：Query/Result ACK后直接关闭临时传输，不等4008、不发CloseSession；ACK计时剩余6.6秒后同机重连，仍需相册与实际JPEG帧后落可信。每身份一次内联/远控修复共享预算，临时读取失败保凭据；已有真实帧但End失败仅一次同机清理恢复，不重新配对。初始化及每个握手响应共享绝对期限，句柄总30秒且底层读空闲5秒，其他响应5秒，PING/分片不能续命；激活后的普通传输仍用原空闲期限。移除旧4008排空和未用peek辅助。

最终去重283 iOS XCTest全部通过0最终失败/跳过；本机协议123/123与其重叠不累加。iOS r1 17通过、r2 247中1内部动画归零失败、修复后r3 171通过、选中矩形修正后r4 9通过。最终build-r6通过；r5曾Int/Bool编译失败，日志保留。4张最终横竖/浅深组件截图逐张检查，选中行矩形像素及反向关闭终点断言通过；非完整页面/实机证据。三语933键/2.05(78)一致。证据ios/docs/evidence/android-sync-20261104/verification.json及inputs/logs/screenshots-final。全部进程结束；未测真实相机、功耗、正式Archive或支付；研究QQ/Android发布后端工具不移植、不发送。无新增平台差异。

## 2026-11-04 真机覆盖安装2.03(76)，用户确认可以打开

用户报告手机旧版“不再可用”，明确要求安装。solo运行现有ios/dist-debug-ios/d-b-ios.command，指定00008120-000A08110CF1A01E（iPhone 15 Plus，设备报告iOS27.0.1），跳过模拟器；当前工作树Debug构建BUILD SUCCEEDED，未改生产代码/运行回归/提交/推送。产物ZTransfer-ios-debug-2.03-20261104-182510.app/.ipa，脚本按既定规则只保留最新Debug包；日志/tmp/ztransfer-install-20261104.SEeGp3。旧电脑包的免费开发描述文件已于2026-10-25过期，但未取得旧手机安装版本，不能写成已验证两者完全一致。

新包已无线覆盖安装，未卸载或清数据；首次自动启动被系统Security拒绝，因此脚本整体exit1，不能写成全流程一次通过。新描述文件346e0c13-2320-409a-9f83-5307c408d270包含目标设备，签名/授权匹配，开发证书有效；仍为Personal Team 6YY8Y34949的7天LocalProvision，2026-11-11 18:26:50（Asia/Shanghai）到期。用户随后确认已USB连接并解锁、已信任/验证开发者App，并明确反馈“现在能打开了”；本次安装与启动恢复完成，未据此核销相机功能/支付/热状态。此前用户已付款但Developer会员注册仍待审核，不能据付款视为会员生效或正式Apple沙盒已通过。

## 2026-11-02 付费前复核13/18，开发侧补齐，5项仍需本人材料/实机

用户要求补齐购买Apple会员前工作。solo按ios/docs/付费前复核与补齐-20261102.md执行：前轮传输F01–F04及D01已修复，缺EXIF空字段回退、纯装饰不读相机、独立地点准备且不占计算槽/计时、本地原片关闸skip、完整视频part在次数/大小/相机门控之后发布。新增TransferBusinessParityTests6方法含取消/运行期关闸/裁切时钟；旧缺EXIF测试改为回退，并以真实渲染失败保留重试来源隔离。颗粒模块旧15掩码断言纠正；预览旧尺寸断言记录当前整数边距原生栅格，未改渲染器，不宣称所有像素完全一致。分页Coordinator补@MainActor，无时序改动，14专项通过。

分批去重424 XCTest最终通过（406模型/组件/队列+18本地StoreKit），0最终失败/跳过，另4检查脚本测试通过；中途编译夹具错误/旧预期失败均保留，非一次全量通过。设备与模拟器无签名Release2.03(76)/SDK27.2构建及严格包检查均通过，未安装真机/正式签名Archive/上传/提交/推送。证据ios/docs/evidence/prepayment-20261102/。6中英文政策/条款/支持页GET200，未部署网站；地名缓存文档纠正24h/15s/5s，当前411编译输入含新增FastNoiseLite及MIT通知；商店文案补颗粒并核长度。

5项开放：50个手机NP3派生滤镜来源/使用依据（50独立hash与Android31跟踪NP3匹配0，已问原始目录/链接，不删除）；可公开照片及商店成图；代表硬件环境及当前候选验证；手机与相机同框实拍视频；名称/语言/版权年份本人事实。旧1.98截图不作当前候选；续查已补当前2.03(76)首页/设置6张并逐张核看，1个UI方法在3个新模拟器分别通过（不计入424项），原图无alpha/摘要一致，设备全清理，未注入应用数据或安装真机。记录screenshots/capture-record-20261102.json；完整核心场景仍缺，维持13/18。审核说明按实际页面/源码纠正“照片效果 / Effects”入口及USB自动发现步骤，当前自有账号登录要求及GPS入口已由Release/源码核销；硬件与后台定位仍待实机。英文Notes3612字符/3934字节，记录按UTF-8字节校验4000上限。已有姓名邮箱/价格/客服/网站不用重问。会员后才做正式商品/真实Apple沙盒/分发签名/上传和后台声明；iPad竖屏多窗口及既有方向警告保留，不擅自全屏/横屏；监看端侧录制豁免保持。目标未全完成，不可据本地通过核销本人事实/许可/真实相机。

## 2026-11-02 传输业务核对28/28；4问题与1差异待处理

用户要求核对iOS传输业务是否遗漏Android，排除鸿蒙。主代理solo按Android8a09e51b、iOS58d9b6ed+既有未提交内容审查；台账 `docs/待做/iOS-20261102-传输业务逻辑核对.md` 为28/28代码核对完成。4项问题尚未修复、1项差异尚未决定：F01无EXIF有效JPEG在生成分支抛invalidDataset；F02纯装饰边框仍捕获/补读元数据；F03地点查询占住唯一计算槽，阻塞后续就绪项；F04本地原片命中且运行期效果关闭，skipped仍false；D01完整视频part先于免费限额/大小/相机门控发布。均有真实队列受控诊断复现，不能称当前传输完全无遗漏。水印入队冻结为用户明确差异，保持；监看端侧录制继续豁免。

本轮只改两份既有测试的过期预期/前置条件：AutoTransferModeTests三语按当前Android；PhotoMetadataPreparationTests两裁切场景先启用入队再关闸，容量场景区分旧配方和关闸后新无效果任务。r1诊断夹具Swift6隔离编译失败；r2执行232方法有4旧测试失败（7条错误）；r3地点夹具构造器编译失败；r4修正后5/5通过。去重后228现有回归最终通过，另5诊断确认问题，共233不同方法最终0失败/跳过，失败历史保留。诊断临时追加已移除，DomainModelTests恢复本轮起点hash；夹具保存在evidence供修复重放。生产源码未改，未安装真机、提交或推送。证据在 `ios/docs/evidence/transfer-audit-20261102/`；真实相机、Provider、功耗和端到端UI未验。历史F065/F067等核销不证明无EXIF降级、地点准备全部正确，以本轮新增项为准。

## 2026-11-01 新STA增量完成7/7，Android基准推进8a09e51b

用户“又来了一点修改，老规矩”。solo完成dfd66a20→8a09e51b11c6fa4fa74133a4cf603c883ba7ea5a的4提交/21文件，Android工作树干净且pull已最新。台账docs/待做/iOS-20261101-STA增量复刻.md为7/7。iOS HEAD仍58d9b6ed，上一轮26项与本轮全部未提交；不改Android/网站，不安装手机，不推送。下轮增量从8a09e51b比较。

首次STA配对Result后须30秒内完整新4008，先排空旧事件，ACK必须含GUID；凭据仅内存绑定同机，会话只关闭一次5秒读预算。仅新配对重连验证8秒内真实JPEG监看帧，EX9428回退9203，只结束自己开启的监看，流坏直接退役；取消不落盘，旧可信/旧marker迁移不新增LV。两身份使用相同有界恢复，恢复清凭据但保留GUID；未确认即终止发现/自动重试，不能绕相册身份。共享配对锁覆盖重置、迁移和最终取消检查。临时DeviceInfo失败保留旧信任，仅明确pairing-only能力才失效。

相册首个ObjectInfo失败就停采样，无GetThumb，无有效正size不partial。Debug增加被动有界STA计时/完整块日志、复用文件分享且唯一文件/后台写/取消过期展示，无轮询；旧诊断入口复制/清除同步。STA失败标题/完整可滚动文案、201F/未完成提示、无流量说明、三语928键及2.03(76)一致。iOS Bonjour确有末轮100ms等待，已去掉，保留两服务间等待；不机械移植Android性能结构。

最终build-r3成功；iOS模拟器181项全部通过0失败0跳过，包含真实BSD双socket/真实JPEG/取消重置/同机/不自动重试/卡片宿主；本机协议112项通过（重叠，不累加）。英文截图已核对。证据ios/docs/evidence/android-sync-20261101/verification.json、source-sha256.json、logs、screenshots；原始xcresult /tmp/ztransfer-sta-20261101/ios-r1.xcresult。最终构建/测试结束，无运行中会话。真机相机首次配对及耗时功耗、向第三方实际分享、Release打包未测；不声称真机已过。保留既有监看端侧录制不提供等所有已批准差异。

## 2026-10-31 全轮复查完成，102项专项通过；性能按iOS实际开销判断

用户明确安卓性能优化仅作参考，目标是减少iOS无谓运算/渲染，不机械复制安卓优化结构。已solo复查当前102份新增/修改生产Swift文件及相关调用链；台账仍26/26，不新加功能差异。Android仍dfd66a20且干净，iOS HEAD58d9b6ed，未提交/推送/安装手机，网站与安卓未修改。

本次修3处：PhotoFileCatalog按days缓存日期范围，替换/增删/拍摄时间改变失效，元数据变化不失效，缓存nil且值复制独立；PhotoListViewModel四处改用缓存，每个await后仍检查准入与新照片范围豁免。PhotoThumbnailBitmapView仅圆角变化请求布局，UIKit尺寸布局保留。TransferFileTitleLabel颜色帧复用拟合文本与自然宽度，name/font/width/scale变化重算，保留后缀样式/无障碍标题。新增2个目录缓存测试+1个文字颜色帧测试。

两次build-for-testing成功，专项80+22=102不同方法全部通过/0失败，日志与xcresult均确认。包括真实PhotoList浅深色滚动缓存身份、有限重试/评级/目录性能与队列布局。8000文件128次范围检查原0.966191166s、缓存0.0074965s；只是Debug模拟器该计算，不能推断真机FPS/功耗。资源926键3语一致。证据ios/docs/evidence/android-sync-20261028/review-20261031/verification.json、source-sha256.json为本次477份当前输入；旧resumed-runtime/337方法证据是上次历史，不是本次重跑。全部构建/测试会话已结束。真机/相机验收仍留给用户。

## 2026-10-31 本轮完成26/26，Android冻结基准dfd66a20

本轮开发侧复刻/验证已收尾，台账docs/待做/iOS-20261028-安卓增量复刻.md为26/26。Android工作树干净、HEAD dfd66a20c739342fafbd927659e815e2d499e5ea；iOS HEAD仍58d9b6ed，全部工作未提交。未装手机、未推送、未改Android/网站。用户要求主代理自己处理，本轮solo。用户后续如要求新一轮同步，增量从dfd66a20比较，勿重复做旧26项。

系统授权已解决，旧24948安装exit0/Install Succeeded；模拟器iPhone17Pro/iOS26.5 UUID CA046456-B859-45F4-9CB3-2C6E2F8E03B0可用，SDK27.2，DerivedData /tmp/ztransfer-removal-derived-20261021。没有组件阻塞或遗留运行命令。旧段落中的blocked/0运行属于历史，不再适用。

恢复后337个独立方法最终通过、未解决失败0（多组专项去重，非单轮337）。48/UI、216/state初轮8方法失败16断言、63/thumbnail、57/fixes全过、1实际PhotoListView浅深色顶底顶缓存复用；N25真实逐帧断言又发现末尾29点跳动，修后25项组合全过，移除几何探针的普通宿主1项也通过。最终UIKit条件编译隔离后r7再次build+25全过。所有原始失败和通过日志、截图、像素/布局JSON、477份输入哈希在ios/docs/evidence/android-sync-20261028/resumed-runtime/final-verification.json及同目录。旧各progress.json末尾final_verification指向最终结果，不要把历史pending当剩余任务。

实际代码修复：SharedPhotoFilterFavorites在迁移时先移除无效标记再set(true)，防CFPreferences将数字1与Boolean true当相等而保留旧类型、下次重导入已删除收藏；测试覆盖取消后重开。效果加载器复用22pt/2pt的Material3圆弧，仅源未到占位保留900ms/.28-.62脉冲。PremiumBusinessTests期望补N12的101字节APP15查重标签，保留精确字节断言；LUT rescan夹具在初次目录替换后才设置另一个role。两个入口的收藏、参数和commit边界均通过真实宿主回归。

N25最终仅在PhotoPreviewView分页Group固定frame后增加ignoresSafeArea(.container, edges: review == nil ? .all : [])，防PageTabView投影归一时再次施加安全区。错误是整层图像在末尾y320→349，不是FHD解码。固定Image尺寸、stack.position、内层ignore均无效，已撤回，不要再加补偿offset。修后横图一直y320，旋转图y168，340/260/300ms、裁切与手势不变。保留显式--preview-motion-fixture下的stack几何trace，普通运行无此探针。新增实际PhotoPreviewOpeningRenderingTests有真实缓存/FHD链路与接续位置断言，UIKit部分条件编译，纯几何测试仍可供原生包使用。

最终资源--check确认926key/三语完全一致。真机相机实拍、FPS和功耗未测，仍由用户后续验收，不能拿模拟器推断。临时UIHostingController夹具的SceneStorage警告来自非App场景宿主，真实App路径没改。除用户已批准的平台差异外，没有新增差异。下一步只有用户要求才打包/装手机/提交/推送。

## 2026-10-31 组件授权已解决，24/26；正在修实际预览终点跳动

用户回复“好了”，旧session24948安装成功exit0，CoreSimulator可用。当前iPhone17Pro/iOS26.5模拟器CA046456-B859-45F4-9CB3-2C6E2F8E03B0，DerivedData /tmp/ztransfer-removal-derived-20261021，SDK27.2。不要再问授权/重装组件。solo，不装手机、不提交/推送、不碰Android或网站；冻结Android dfd66a20不变。台账24/26，仅N24汇总和N25收尾未完成。

实际iOS运行：resumed-ui-r1 48通过；resumed-state-r1 216执行/8方法失败16断言；resumed-thumbnail-r1 63通过；resumed-fixes-r1 57全部通过且覆盖所有8失败方法；resumed-list-r1真实PhotoListView浅深色顶底顶6截图1方法通过。日志均/tmp/ztransfer-*-20261031-*.log/xcresult，已开始保存ios/docs/evidence/android-sync-20261028/resumed-runtime。不要把纯macOS验证冒充本次，也不要抹除初轮失败。修复SharedPhotoFilterFavorites：CFPreferences旧数字1写true可能保留数字，迁移前remove无效标记再set(true)，新测试取消后重开不复活。LUT旧夹具先设other再第一次换目录错误，改为换完目录再设other测试refresh；PremiumBusinessTests期望编码补N12的101字节APP15身份标签，保留字节相等；不是EXIF或像素问题。两真实入口截图已看过，默认菊花换复用RemoteCameraToolLoading22/2，源图未到占位恢复900ms/.28-.62背景脉冲。

N25新增PhotoPreviewOpeningRenderingTests在真实PhotoPreviewView、真实session缓存/DebugCameraData预览链路采样像素。初版末尾稳定断言通过，但看截图发现横图y320→349，下移29点发生在展开终点、FHD到来前。加强“同宽高、尚未绿中心FHD”的中间断言后r1确实失败。xctestrun副本Build/Products/ZTransfer_preview_trace.xctestrun增加--preview-motion-fixture，测试开启ButtonInteractionTrace并附像素/布局JSON。/tmp/ztransfer-preview-layout-20261031-r1-attachments含trace：真实图像在同一时间从y320改y349，viewport一直390x752/infoBottom132。PageTabView安全区提案影响Image.scaledToFit自动居中，不是照片解码或340ms时长。

已改PhotoPreviewView.PreviewImage两个Image：photoPreviewDisplaySize(rotation0)算Fit尺寸，明确frame及position在proxy中心，再走原旋转/缩放/偏移；不改手势、裁切、340/260/300ms。当前session33242正在顺序build+test，log /tmp/ztransfer-preview-layout-build-20261031-r2.log 和 /tmp/ztransfer-preview-layout-20261031-r2.log，结果bundle同名；先poll这个，不并行启动xcodebuild。选actualOpening、CropRendering、AnchorGeometry、ReturnScroll。尚不知道r2结果，不能标完成。r1旋转图宽已到但裁切高未完全展开也触发误判，现接续断言同时要求宽高都接近终点。

N23新实际列表测试在PhotoThumbnailPresentationTests内，用真实session/model/PhotoListView、浅深色及UIScrollView滚动，确认每个已显示UIImage都是会话缓存的同一实例；6截图已看3张，连续描边、连拍层/缓存正常。该UIHosting夹具产生SceneStorage非AppLifecycle警告，仅测试宿主，真实App不走此宿主。不要因此改生产SceneStorage。本轮没有FPS/真机耗电数据。继续完成N25并最小回归，保存最终源码hash/日志/必要截图、核对资源与Androidfreeze、更新台账及记忆。goal工具上轮blocked，工具不能主动resume；用户答复已允许继续，不创建重复goal，真正完成再complete。

## 2026-10-31 N17/N25首帧与返位已补；真正运行验收阻塞，仍17/26

上一目标回合是实质progress；本轮继续改代码、补测试与证据，仍未完成整轮。冻结Android dfd66a20c739342fafbd927659e815e2d499e5ea、工作区干净；iOS HEAD58d9b6ed，所有修改未提交。solo，不装手机、不提交/推送，不改Android/网站。当前剩9项全需真实iOS运行/界面证据，不能用编译或更多纯数学测试冒充；本轮保存后将goal标记blocked，待用户完成系统授权再恢复。

阻塞已跨至少N24、N25、本轮连续验证。旧session24948/PID95870仍运行；本轮再次write_stdin返回仍活跃，ps存活3h49m。重新sample而非沿用旧样本：/tmp/ztransfer-firstlaunch-sample-20261031-latest.txt（已保存到evidence/effects-first-frame/firstlaunch-authorization-sample.txt）仍为PackageKit authorizeForRight:allowingInteraction -> AuthorizationCopyRights。CoreSimulator1174.9.2 vs Xcode要求1174.21.0。系统安装器等Mac管理员授权，已问过用户，勿重复问/启动simctl或firstLaunch、勿擅自杀旧安装进程。恢复先检查这个确切session/PID终态；授权完成且组件就绪后再跑待验集。

本轮新增Domain/PhotoEffectsPreviewTransition.swift，完全按SettingsScreen3410+规划INITIAL/UPDATE/CROSSFADE/REPLACE_CANVAS/KEEP，过时结果不接受；已读完整Android collector和6测试。PhotoEffectsAnimatedImage.visible改可选，所有入口首张接受的完整成片220ms渐入，旧图不透明垫底，比较图不重播，画布110/190ms；源showSourceWhileRendering彻底删除。DesignSystem/ZTransferNextDisplayFrame.swift为可取消的一次真实显示帧边界，弱display-link目标，无常驻任务；旧Task.yield可能合并事务的问题在这些过渡里已替换。首张画布visibility必须初值1，不然会额外等190ms，已修并加UI用例。取消/全屏cover返回恢复已接受图且不重新播放首帧。

PhotoEffectsGeometrySnapshot新增不发布的presentedFrame，两个入口展开用已接受显示的图片/对比图，不再用最新待展示结果或原图；加载时不开放大图/旋转，消失清快照。共享22pt蓝色loader，去掉灰色额外底板，工作台失败原图Fit；source=nil且生成失败显示原有失败提示，避免无限spinner。实际loader描边/样式仍待运行截图，不宣称完全视觉通过。既有组件调用更新：SettingsView、PhotoEffectsSettingsPreview、LocalPhotoPreviewCard。

返位：Domain/PhotoPreviewReturnGeometry.swift求ScrollViewReader单位锚点，使目标停在可见顶部下88pt；短视口/异常尺寸有界。PhotoList.preparePreviewDismissTarget用已有gridCache.indices（含日期标题），不再重新分组/铺平整库；成员搜索在detached纯快照上进行。展开连拍、远距离预定位与最终坐标等一次显示帧；取消后立即停止，半露格子直接返位。现有260ms滚动曲线与最终实际88pt位置仍需运行对照，不能只靠公式核销。

新增PhotoEffectsPreviewTransitionTests7方法、PhotoPreviewReturnGeometryTests2方法；/tmp/ztransfer-effects-first-frame-20261031跑真实生产planner/collector/anchor，两轮7/9全部通过（最终9独立方法，0.003s）。新UIKit4方法已编译但0执行：首帧渐入+comparison不重播、过时首帧不追加190ms、cover中断首帧恢复、实际LazyVGrid上下返位；更新旧静态ImageRenderer首帧断言，并保留旧crossfade cover测试。generic build-for-testing四轮全部exit0/TEST BUILD SUCCEEDED；最终/tmp/ztransfer-effects-first-frame-build-20261031-r4.log，session98119已闭。本轮新sessions全部闭，仅旧24948保留。证据effects-first-frame-and-return-progress.json和effects-first-frame/，final-inputs已在最后一改后重算。

恢复验证清单：N15/N19见lut-role-and-catalog-progress.json的pendingRuntimeTests；N20见shared-favorites-progress.json。N17/18运行PhotoEffectsPreviewTransitionTests、ConflatedPreviewUpdatesTests、PhotoEffectsVisibleFrameTests、PhotoEffectsFallbackLifecycleTests、PhotoFilterEditorSession/参数作用域相关集，检查两真实入口调参/复位/确认/取消。N22实际PhotoListViewModel owner与重试集；N23实际缓存/堆叠卡片/首批/滚动；N24三语和完整入口；N25新PhotoPreviewAnchorGeometry/ReturnGeometry/ReturnScroll、旧CropRendering/ProjectionPerformance以及真实打开/返回/方向/FHD接续截图与性能。只编译，不运行，不可核销上述9项。旧证据remaining是历史状态；preview-anchor-progress已链接本轮补齐证据，勿重复实现已修缺口。

## 2026-10-31 N25接线/21项原生回归，仍17/26；接着效果首帧与返位缺口

冻结Android仍dfd66a20c739342fafbd927659e815e2d499e5ea且干净；iOS HEAD58d9b6ed。solo，不派agent、不装手机、不提交/推送，不改网站。目标active，尚有独立工作不能blocked/complete。旧session24948/PID95870仍在firstlaunch管理员授权等待（最后ps存活3h22m），不要重复启动simctl/安装器，也不重复问授权。

N25新增Domain/PhotoPreviewAnchorGeometry.swift、PhotoPreviewImageGeometry.swift（现有纯布局函数移入）、PhotoPreviewPresentationClock.swift、UI/Components/PhotoPreviewAnchorPresentation.swift。完整读Android PreviewAnchorGeometry及7测试、PhotoPreview eec diff和最新df主动归组差异、278行真实instrumentation。实际图像矩阵/旋转补偿/非对称可见裁切/连续圆角，合集视频保留整页fallback。PhotoList开场/返位传完整+可见bounds，半露格子不额外滚动；删除过时fullyVisible helper并更新两个原断言。起始索引也改@State，和来源图片、来源文件、锚点一起冻结。旧PhotoPreviewAnchorTransform仍被效果展开页引用，已原样迁到新组件文件，不能再删除。

关键修正：PreviewImage底部padding会缩小真实viewport，不能用pager整页size算开场。现在onPlacementChange记录真实renderer placement并调用beginOpeningIfReady；safeInsetsReady且readyPhotoPreviewOpeningPlacement匹配当前页宽、高减previewBottomPadding、infoBottom和恢复方向才冻结并启动。始终同一clip/projection modifier层级，不在p=1换pager。@State持有clock但父页不观察Published；仅小modifier观察。340/260ms时钟遵循Android曲线；布局就绪后340ms再最多120ms等实际完成。关闭先冻结当前placement、异步定位、等真正p=0，消失会取消closeTask与等待者。普通翻页工具180ms，主动归组工具立即卸载。

新PhotoPreviewAnchorGeometryTests13方法；/tmp/ztransfer-preview-anchor-20261031实际生产几何/clock/motion+真实列表adapter摘录+8个逐字既有回归，最终native-r4.log 21/21（0.146s，session53700 exit0），前三轮10/12/13。production native copied helpers已是最终版；inputs-r4及final-inputs保存hash。没有UIKit驱动或实际页面测试执行。xcodegen完成；generic build-for-testing r1/r2失败65（Swift if expression、旧共用modifier），r3/r4/r5成功0；最终/tmp/ztransfer-preview-anchor-build-20261031-r5.log，session32486已结束。其余本轮所有session都结束；仅旧24948保留。证据preview-anchor-progress.json + preview-anchor目录，ledger仍17/26，N25进行中。

接下来两个明确代码缺口：① eec5d6db SettingsScreen修改所有入口首帧等完整效果图、22dp蓝色0.76/2dp加载、首帧220ms FastOutSlowIn渐入（以前只有直接FHD可先露原图）；后续保留上一成片，失败才原图。iOS SettingsView223仍传showSourceWhileRendering:effectsOnly；PhotoEffectsEditorView816/819/822/1004仍保留flag。PhotoEffectsAnimatedImage590+的incomingOpacity初值1、首帧visible直接显示且visible层outgoing=nil时强制alpha1，onAppear重置1；需要补初次220渐入，同时保留系统picker消失/返回不会卡透明、同bitmap comparison更新不重启动画、110/190画布替换和220常规换图。先完整读相关collector/ConflatedPreviewUpdates及现有UIKit组件测试，避免只改alpha弄坏恢复。这个缺口已记N17/N25未完成。② 既有preparePreviewDismissTarget离屏仍以top/bottom/center和260ms滚动，Android最终目标88dp顶栏下留白；新eec未修改这旧段，但完整对齐需核对，不能声称N25全完成。部分可见免滚动已改对。

N25真实UI、真实来源/返回帧、FHD接续、interrupt/perf均未跑，CoreSimulator1174.9.2/1174.21.0仍阻塞。13新测试+8既有数学仅原生证明。Android rotation placement本身报告targetRotation而非animatedRotation（PhotoPreview2811..2875已读），不要臆改成逐帧写SwiftUI状态造成新开销。其他N15/17/18/19/20/22/23/24状态与下文相同，余9项。

## 2026-10-31 N24文案/版本推进，仍17/26，接着N25

承接下条N23，当前所有新sessions已结束，仅旧24948（firstlaunch管理员授权）还活着。N24改进行中：sync-android-localization.py新增 --android-root/--check，输入缺失先失败；以冻结dfd66a20的/Users/orys/code/nk_send-android生成byResource，926键与三语源码逐项一致（en926/zh925/hant921），488处完整静态调用无缺失；photo_filter_builtin_/photo_filter_category_三处是拼接前缀不是missing。未发现此次变更中文旧字面量残留。AppLocalized.resource原来Hant缺项返回资源ID，现补IOS/en、Android/en回退；4个Hant边框名称按Android默认英文显示。renewal_needed源文字无网络已更新，应用无对应业务引用，没改变StoreKit。项目MARKETING_VERSION2.02/CURRENT_PROJECT_VERSION75；Settings fallback2.02保留-D；旧IncrementalLocalizationTests版本断言同步。

新增AndroidResourceFallbackTests两方法，真实AppLocalized枚举从RootView.swift逐字提取到/tmp/ztransfer-resource-parity-20261031，生产AndroidLocalization/IOSLocalization完整复制，swift test两方法通过（13060 exit0）。新xcodegen后generic build-for-testing42568 exit0 TEST BUILD SUCCEEDED，log /tmp/ztransfer-resource-parity-build-20261031.log；读真实Build/Products/Debug-iphonesimulator/ZTransfer.app/Info.plist确认2.02/75。iOS测试执行0。证据resource-parity-progress.json及resource-parity/（native日志、原生enum摘录、hash、gzip编译日志）；ledger标题当前dfd66a20，N24进行中，总17/26。完整入口/提示窗回归还缺，勿核销。

已开始读N25，尚未修改预览代码：Android PreviewAnchorGeometry.kt 50行完整已读，PreviewAnchorGeometryTest.kt七测试完整已读（0/90/180/270/-90/-180/-270，非对称可见裁切、终点identity、连续clip扩展、超宽/超高/目标更小/scale<.05、clip矩阵中心、progress clamp）。Android eec5d6db的PhotoPreview.kt diff存 /tmp/ztransfer-preview-eec5d6db.diff；只读1..275且有374token截断，需补127..160，剩276..end还未读。实际完整最新版必须按dfd66a20（额外主动归组时移除已淡出工具栏）对照，instrumentation FileListPreviewMotionInstrumentation.kt 278行也还未读。

N25关键已知：Android openingAnchorRect/clip固定，openingFile/缓存bitmap固定避免逐帧变几何/缓存淘汰；needsOpeningPlacement为非review、有效anchor、已缓存图、非视频，placement未就绪时不启动spring且图alpha0。onPlacementChanged首次记录openingPlacement；关闭预定位返回PreviewAnchorBounds(image,visible)，closingPlacement需冻结（diff截断处待读）。延迟加载从overlayBounds到位起算PREVIEW_DEFERRED_LOAD_DELAY_MS，再最多120ms等待progress>=1，不能无界依赖动画结束。对普通图以实际旋转后的图像frame做origin0矩阵+单一连续clip（先按saved方向旋转clip，圆角8*(1-p)/scale）；collection/video保留旧整页scale；queue/burst变换依旧合成。

iOS现PhotoPreviewAnchorTransform在UI/PhotoPreviewView.swift259..291，仍用UIScreen整页scale，min .05/max1固定，只有UnitPoint anchor，没有图像placement/visible crop/rotation。modifier接于672..683左右整个TabView，之后burst scale/alpha/offset+queueMotion；initialAnchor CGRect? 417、collapseAnchor499、opening init517..561，关闭1136附近。PreviewImage2240+，actual geometry2282/2331/2474..2501，preview visible bounds2628+；这些未完整读。先完整读Android新代码/tests与iOS实际renderer，再实现，不凭公式猜接线。未改变N25代码/状态，仍待做。所有未完成同前：N15/17/18/19/20/22/23/24进行中，N25待做；active goal继续，有独立工作，不blocked/complete、不派agent、不装手机/提交/推送。

### N25 阅读进度补充（代码尚未改）

台账改进行中，仍17/26。已补读 /tmp/ztransfer-preview-eec5d6db.diff 126..733：ZoomablePreviewViewport把onSizeChanged状态换成BoxWithConstraints真实首帧尺寸，内部rotation/pinch/tap/240ms双击逻辑只是移入新Box。关闭startClose先冻结previewPlacement（非video），再closing=true；closing期间禁手势。延迟加载明确340ms加最多120ms等待progress>=1，始点overlayBounds到位。Android instrumentation FileListPreviewMotionInstrumentation.kt读到145，146..278未读；真实FileListScreen+VM缓存600x400的magenta离中心首格，等首批500ms后tap，900ms settled-a及100ms后b的边缘差≤4，旋转可注入；禁止真机/相机。最新dfd66的主动归组工具栏卸载逻辑还需读。

iOS已读PreviewImage2240..2353：thumbnail State默认nil，body回读memoryThumbnailImage，loadEnabled=false期间没持有首图，有缓存淘汰风险。UIImage.scaledToFit→frame(proxy)→PreviewRotationTransform(rotation/imageSize/infoBottom/crop/zoom)→offset→croptransform/手势。已读2570..2637：rotationFit/displaySize/PhotoPreviewCropViewport，实际区域复用photoPreviewPlacement。尚需读PreviewRotationTransform/placement、PreviewImage后半onAppear/task/viewport回调、父body585..720/onAppear929/close1136，以及PhotoList源anchor/prepareDismissTarget。旧AnchorTransform259..291仅缩UIScreen且min .05/max1；新实现需要实际图像矩阵/连续crop，collection/video保留旧分支。固定SwiftUI层级避免p=1替换View使pager重建；保存方向是否onAppear才恢复尚待核查，不能当已确认bug。

只有原24948授权等待，本轮其他sessions均结束。继续N25独立工作，不重跑无代码变更的N23/N24检查。不派agent，不装手机/提交/推送。最后一次Python更新记忆因stdin编码错误未执行，已改apply_patch补记；源码不受影响。

## 2026-10-31 N23目录/缩略图呈现推进，仍17/26

继续同一active goal，solo，无手机安装/提交/推送；Android冻结dfd66a20c739342fafbd927659e815e2d499e5ea，本轮始末确认干净。N23实现目录索引PhotoFileCatalog（bulk重建/单行upsert，first duplicate匹配，恢复副本COW），所有PhotoListViewModel allFiles写点迁移，worker O1查当前文件。visiblePhotoBurstMembers单次分组供列表/预览使用；删除无用availableDayKeys发布/全表构造，只有collapsedDays非空才从displayedFiles清理。recentThumbnailReadyDays取消Published但保留显式updateRatingScanFromCurrentState。CameraRepository待新增对象已用pending字典/knownHandles，无安卓的空pending全表问题；deadline选择lazy，new logical identity移到查重closure外。

PhotoThumbnailPresentation.swift：泛型MainActor PhotoThumbnailLoader先订阅再读，后续本地读，generation+cancel阻止旧结果，缓存不启动任务；实际Store晚发布填入现有格子已本机验证。PhotoThumbnailFade基于既有AndroidScalar180ms，空批暂停、完成不重播。PhotoThumbnailImage.swift：独立首批clock（root @State reference，只有opacity modifier观察帧），每图UIImageView复用解码对象、原生圆角/抗锯齿、layer.opacity180ms，新图渐入、缓存即显；ready离场/复入不保留半透明；normal/stack theme outlines源码对照，液态玻璃沿用批准的glass体系。PhotoListView普通/连拍接同加载器，busy/load/remote gate；STA保持只读缓存的格子，USB/AP新增ready订阅解决旧失败后永久占位。移除连拍重复外层clip；角度1/2/3张0与[-5,+3]/[-6,+5,0]、固定偏移和底部渐变对照Android。

新增PhotoThumbnailStackMotion及PhotoThumbnailStackTransition：前三张PublishedPhotoIdentity作key，尾部变化不重播；同key换handle更新payload；进入180/退出160，中断按既有Compose critical spring保留值/速度；clock只发布结构变化，局部AndroidOpacity观察每帧。Snapshot缓存id，opacity表只在层变化时裁剪，避免每帧集合。stack内容和渐变一起过渡，计数/按钮仍在外层。

新增PhotoThumbnailPresentationTests共18方法：macOS可执行15，另3UIKit编译但0运行。native-r1 8通过，r2合并49（38既有+11新）通过，r3索引末次11通过；追加stack时r4/r5临时包缺RemoteReviewPhoto/selectNewestPhotoHeadIndex编译失败0执行，移除无关完整Catalog/Review拷贝，逐字提取真实PublishedPhotoIdentity定义后r6最终15通过。覆盖53唯一方法（38前轮+15末轮，不能说一次最终53）。真实Store晚发布、订阅释放/取消/generation、8000项索引/删除/复用/复制、fade180曲线/暂停、stack尾部/alias/180-160/中断。native临时包/tmp/ztransfer-new-object-retry-native；最终Sources有PublishedPhotoIdentity.swift真实摘录，没有PhotoCatalog.swift/RemoteReviewCatalog.swift。现有PhotoDateRange等仍是上一轮记录的真实摘录。

iOS builds r1成功（当时新测试尚未入project）、r2因误写PrefKey失败、r3修为skin_preset成功（新测试仍未入project），xcodegen后r4成功并编译全部新测试；追加stack/xcodegen后r5最终成功，/tmp/ztransfer-thumbnail-presentation-build-20261031-r5.log。所有本轮sessions结束：46523/94887/76552/1408/77450/13980/15573 exit0，9971 exit65；57805/98676 native harness exit1。证据thumbnail-presentation-progress.json + thumbnail-presentation/原始native日志、gzip build日志、inputs和identity摘录，ledger已更新。git diff --check通过。

目前只有旧24948仍活着，PID95870 xcodebuild -runFirstLaunch已2小时20分，CoreSimulator1174.9.2 vs1174.21.0等macOS管理员授权。用户没回旧async授权提示；不重复问、不代输、不kill、不另起simctl。实际SwiftUI复用/抗锯齿像素/帧率、3UIKit方法和2N22 owner仍未运行；N22/N23仍进行中。已做真实独立进展，不设goal blocked/complete。总17/26：N15/N17/N18/N19/N20/N22/N23进行中，N24/N25待做。下一步可继续N24三语2.02(75)/入口净差异、N25真实预览锚点/方向/手势；运行集成回归等系统组件许可。不要重复本轮已通过底层测试除非代码变更。

# iOS 复刻项目记忆

## 2026-10-30 N22有限重试与N23队列优化推进，仍17/26

同一active无预算goal，继续独立工作；不派agent、不改网站、不装手机、不提交/推送。Android dfd66a20c739342fafbd927659e815e2d499e5ea 本turn末次确认工作树干净。N23由待做转进行中，完成仍17/26、余9。**只有旧session24948**仍活着（PID95858/95870，simctl bootstrap→xcodebuild -runFirstLaunch，末次已等1h20m），仍在macOS PackageKit管理员授权。用户没有答复之前唯一的异步提示。勿重复问、代输密码、kill安装器、启动第二个simctl/bootstrap。当前CoreSimulator1174.9.2，Xcode要1174.21.0。其他本turn所有build/test进程均已结束；generic build-for-testing可用，iOS runtime仍0。阻塞持续多turn但本turn持续完成独立实现/验证，不设goal blocked。

N22新增Domain/NewObjectThumbnailRetries.swift，严格Android 300/900/1800ms、register put-if-absent、deadline前joined failure不加次数、takeDue只清deadline、success/delete/reset清budget。PhotoThumbnailStore统一注册、单弱Task定时器/AsyncStream<Void>唤醒、blocked handles、每Flight retryDeferred、generation/invalidated门禁；load/prefetch共同遵守deadline，empty JPG耗尽后正常negative，STA RAW/video仍unsettled。修正STA图片validator先挡住empty导致不收束：只校验nonempty，empty共走finishEmptyPrefetch，STA JPG也尊重negative。临时IO异常可延迟，取消不花额度，磁盘失败仍锁背景写入。stopRetries终止observer/timer但保留离线缓存；beginShutdown和PhotoList disconnect均接入。reconcile按有效handles收回，invalidate/旧flight不允许迟到发布。

CameraSession注册/blocked/retryWakes桥接；实际shared fetch才查isRetry传CameraRepository.thumbnail(retryNewObject:)，原事务内调用STAObjectReader.prepareNewObjectThumbnailRetry，仅清目标prefix/order、noThumb/checked/thumbnail、MPF，保留文件元数据和RAW索引。PhotoScanSnapshot新增addedHandles默认[]，真实枚举设置，resume继续携带。PhotoList applyCatalogUpdate先移除/失效/注册，再publish和auto transfer；acceptBatch按snapshot真实addedHandles且非既有logical row登记，先enqueueNew范围豁免再发布和first prefetch；历史扩大范围不注册。两处retryFailed都排除blockedhandles，retryWakes到期唤醒，不在scan期间抢后台worker。新增ScanAccumulator.newObjectIDs使scan首批新图也豁免历史范围。

N22 tests：NewObjectThumbnailRetryTests现11方法，其中9项纯store/queue在macOS运行，2项 #if os(iOS) 真实PhotoListViewModel发布/自动传输/首批预取顺序只编译未跑。临时包/tmp/ztransfer-new-object-retry-native编译实际全部PTP + Store/Disk/Queue/NewRetries，唯一隔离是从生产PhotoFilter.swift原样提取PhotoDateRange/validPhotoCaptureDay，保留extracted文件和hash，不是替代实现。最初依赖闭包误含RemoteReviewPhoto/TransferQueueItem/CameraSession编译失败；去掉无关文件后31项通过，追加queue gating后9项filtered通过；拓展STA JPG测试的Sendable三元closure触发compiler diagnostic失败，补明确@Sendable后**32方法通过**。sessions24600/81157/3821/67443/66240均结束，对应exit1/0/0/1/0。

Protocol STAProfileAndMetadataTests新增testNewObjectRetryDropsOnlyItsEarlyHeaderAndKeepsOtherObjects（真实script transport、两个JPEG文件、只重读目标header）；首轮夹具没JPEG标识，被正确认作.bin，修夹具后**11方法通过**（8JPGfallback+新STA+2旧JPEG/RAW），sessions44564 exit1、26834 exit0结束。3次iOS generic build-for-testing90750/69585/46777全部exit0 TEST BUILD SUCCEEDED。证据new-object-retry-progress.json及原始logs保存；N22完整owner运行还缺，不能核销。旧jpg-thumbnail-fallback-progress里的1个NEF137 oracle skip仍是历史记录，本轮11方法无skip。

N23已读完整Android ThumbnailFillQueue.kt和新增6场景测试。iOS PhotoThumbnailFillQueue改ArraySlice<UInt32> lanes（O1 popFirst）；markSettled只移pending/failed，poll跳过stale，updatePriorityRange/updateLoadingRange过滤pending/failed避免完成项复活；returnToFront按Android对已pending不重复搬动，插入用slice.startIndex；markFailed仅外部仍pending时清lane，普通polled failure免扫描。新增PhotoThumbnailQueueEfficiencyTests六方法，范围/STA双lane/删除复用/暂停/失败/全完成/非零slice起点及有功能断言的性能样例。

N23先用临时包原N22 queue源码运行6方法baseline exit0（96304），2000/8000半数完成登记0.217694/3.492340秒；改后全**38方法通过**exit0（8543），同场景0.000749/0.002916秒；drain改前0.000763/0.003196秒，改后0.000948/0.003870秒。只是macOS Debug队列成本，不是iOS FPS。保留thumbnail-queue-before.swift原源码及所有inputs/log/hash，manifest thumbnail-queue-efficiency-progress.json。xcodegen后generic build-for-testing75308 exit0，/tmp/ztransfer-thumbnail-queue-build-20261030.log；2项iOS owner测试仍未执行。新queue supersedes N22 manifest里的旧queue hash，后者是历史运行版本，不改旧证据。

下一步继续N23：PhotoListViewModel worker约1133仍allFiles.first(id)每张全表找；allFiles写点132(copy previous)、310/317(event)、392/450(clear)、467(scan final)、692append/697replace，可考虑维护handle→index并同步所有写点，避免用didSet每append重建。Android queue直接携file；不能粗暴用旧快照破坏新增/删除/复用。另需核对首批统一淡入、burst边缘抗锯齿/解码复用、评级关闭不因readyDays更新整页、空pending/collapsed短路。N15/N17/N18/N19/N20运行集成回归与N24三语2.02(75)/全入口、N25实际预览锚点/手势还在本轮范围。未新增goal、不完成/不blocked。git diff --check末次通过。

## 2026-10-30 N20共享收藏与N22 JPG回退推进，仍17/26

同一active goal，不派agent、不改网站、不装手机/提交/推送。安卓仍dfd66a20c739342fafbd927659e815e2d499e5ea，工作树干净。N20/N22从待做改进行中，已完成仍17/26，剩9项。当前**只有旧24948**（simctl自动触发firstlaunch，PID95858/95870）仍活着；最后确认等macOS PackageKit管理员授权，CoreSimulator1174.9.2低于Xcode1174.21.0。用户尚未答复既有异步授权提示，勿重复问/代输密码/kill安装器/再跑simctl。收到答复先收尾该会话，再恢复iOS专项。此turn是第3次遇到同一环境问题，但仍持续完成独立工作，不是无进展，不设goal blocked。

N20新增Domain/SharedPhotoFilterFavorites.swift：PhotoFilterFavorites.merge保序+去重+严格合法key，迁移键photo_filter_favorites_shared_v1只认CFBoolean true。SharedPhotoFilterFavorites MainActor、CurrentValueSubject与静态弱invalidations；真实raw传输收藏+local独有一次合并，不写local旧key，取消/目录清除不复活。兼容原iOS JSON（PhotoFilterPreferences.catalogKey归一化render/legacy ID），不应用其他配置。全目录扫描/轮询未引入。PhotoEffectsStore新let filterFavorites/可注入实例，恢复配置先用local restoredSettings再赋存储属性；共享favorites marker不遮挡旧camera JSON。配置persist两条函数删除写favorite key；update始终采用共享值，persistEditorPreferences先替换共享值再比较避免旧草稿多余写盘。owner订阅只改favorite字段，不改selected/config，NP3真换目录清自定义收藏。Settings/Local controls传显式toggleFilterFavorite(selection)，NP3 Card直接回调；SettingsView onReceive把共享list反映到打开草稿。局部PhotoEffectsSettings纯值helper仍保留历史toggle/copy，但owner边界不能写回旧收藏。

N20新增SharedPhotoFilterFavoritesTests.swift：4codec+8store/owner方法=12；覆盖真实UserDefaults不同实例、raw与JSON迁移、严格flag、独立参数/旧draft、换目录/捕获任务、weak释放。已有PhotoFilterEditorSessionTests真实SettingsView/Local宿主加跨实例同步断言；PremiumBusinessTests改显式收藏动作；DomainModelTests按新基准更正“local滤镜收藏永久独立”的两测试（frame仍独立），fixture建收藏改显式toggle。PhotoGrainControlTests补requiredcallback。三个generic build-for-testing session61199 exit65、37725/30174 exit0；首轮settings包装属性在新let初始化前使用，改local值修复。iOS测试实际0方法。所有编译进程已结束。

N20另有真正运行的macOS native检查，session38133 exit0，/tmp/ztransfer-shared-favorites-native/check.log四组PASS。编译实际SharedPhotoFilterFavorites/PhotoFilterPreferences/NP3 catalog/codec/parser/engine/Foundation/Combine；PhotoFilterPreset和LUTAdjustments从生产PhotoEffects.swift原样抽两段以避UIKit。检查迁移顺序、真实50项catalog ID映射、合法离线NP3、跨实例通知、移除/清理不复活、非布尔flag及weak释放。不是iOS owner/UI回归；harness/抽取/inputs/log与依赖hash保存在evidence/shared-favorites-native-*，shared-favorites-progress.json追加native_check而非假称12测试已跑。历史N16真实页面截图未重跑，不能引用作当前全回归。

N22新增Transport/PTP/JpegThumbnailFallback.swift并接CameraSession/CameraRepository。thumbnail(handle:file:priority:)新增可选file，原visible/background fetch传当前文件；repo可fallback已知catalog，保留原事务和directSTA分支。只OK空数据/NoThumbnail的JPG/JPEG一次0x9431(handle,0,0,min(size,128KiB),0)，不额外GetObject/FHD；无图partial响应保留miss，取消/transport异常抛出，UInt64 size上限安全。NEFExifThumbnail新增readJPEG，APP1 TIFF直接读取thumbnailBytes，不运行RAW validateImages/尺寸交换；原read()默认RAW行为保持。拆出validateImages/thumbnailBytes共同逻辑。Android固定ExifInterface已为1.4.2，下载并读对应官方sources的getJpegAttributes/APP1/readExifSegment/setThumbnailData/handleThumbnailFromJfif/Strips；URL/SHA记jpg-thumbnail-fallback-progress.json，临时源码/tmp/ztransfer-jpg-fallback/ExifInterface.java。原NEF137差异仍是旧单独问题，没有声称最新RAW全量对齐。

N22新增ProtocolTests/JpegThumbnailFallbackTests.swift八方法，macOS ZTRANSFER_PROTOCOL_ONLY=1 swift test --package-path ios --scratch-path /tmp/ztransfer-jpg-fallback-build --filter 'JpegThumbnailFallbackTests|NEFExifParityTests'：session20401 exit1编译失败（PTPResponse夹具误写parameters），修正后74275 exit0，**9方法通过/1跳过**。跳过旧testAgainstActualAndroidX137因NEF_EXIF_JAVA/NEF_EXIF_ORACLE_CLASSPATH未配；8新+1既有NEF/TIFF多样例通过。之后xcodegen+generic build-for-testing session3601 exit0 TEST BUILD SUCCEEDED，repo/session接线只编译未iOS运行。日志/evidence均保留。下载session39784也已exit0，无遗留新进程。

N22尚未实现有限重试，不要核销。本turn完整读Android NewObjectThumbnailRetries.kt/五测试、ThumbnailFillQueue.kt，CameraViewModel 619–680(单timer/markFailed/publishReady)、3120–3165(新对象baseline注册)、3950–4025/4080–4185(缓存/flight/后台/延迟失败)，NikonCamera2890–3025及4014partial。规则仅真正新增对象：300/900/1800ms，join失败不多扣额度/不延长；timer不持IOgate，单时钟唤醒；success/delete/newsession清；到期retry才清STA该handle旧prefix/noThumb/jpegChecked/MPF，不影响其他文件；3次耗尽回原negative规则。load可见和prefetch都要门禁，队列retryFailed应只允许到期项，不得形成热循环。

接下来继续N22实际架构：iOS PhotoThumbnailStore actor load/prefetchOutcome各自有negative/共享Flight，cache命中和原始字节/解码结果分层；清理/取消/共享等待门禁不可损坏。CameraSession持thumbnailStore、decodedcache，prefetch成功publish，STA失败discardRejectedThumbnail。PhotoListViewModel applyCatalogUpdate约267先publish再计算additions/autoTransfer，然后remove/invalidate/enqueueNew；监看返回reload约468仅最终result.addedHandles入队，但前面metadata batch已可能prefetch，新retry注册必须早于首次新文件读，不要只在最后注册。两处retryFailed在setFilter约796、worker空队列wake约1069。PhotoThumbnailFillQueue已有liveHandles范围豁免，保留同session和retry，remove时清；不要倒退这个已有修复。待补读scan batch准入/新事件和disconnect生命周期以决定单timer/注册归属；目前无新增retry class或占位代码。

其他N15/N17/N18/N19/N24/N25继续，所有iOS runtime集成回归待系统授权。最后git diff --check通过；此turn未fetch新scope或动Android，只确认冻结dfd66a20仍最新本地且干净。完成后仍需统一差异/文案2.02(75)/实际预览动画和性能核验，不能把此次两个小段编译/本机检查当整轮完成。

## 2026-10-30 N19参数与N15排序接线，仍17/26，模拟器系统授权待用户

同一active goal，无预算、未blocked；不派agent、不改网站、不安装手机/提交/推送。Android dfd66a20末次确认仍干净。N15/N17/N18/N19进行中，其余N20/N22–25待做，余9项。下面N16的37方法验证是历史阶段证据，后续共享代码变化还需运行回归。

**唯一未结束的工具会话24948**：xcrun simctl list devices available --json，PID95858；它自动运行Xcode自带first-launch安装，子PID95870。当前CoreSimulator1174.9.2，新Xcode要1174.21.0。sample /tmp/ztransfer-firstlaunch-sample.txt 证明停在PackageKit AuthorizationCopyRights，需要用户在macOS系统窗口完成管理员授权。已用request_user_input_async问过一次，不重复问、不输入密码、不擅自kill该提示。xcodebuild -checkFirstLaunchStatus仍exit69。收到用户回复后先收尾24948、确认新模拟器清单；原目标B6B4E291-173A-4BFE-BB9C-2D1F62643C49可能仍可用。不要把环境未就绪写成测试成功，也不要因一次环境问题将整个goal blocked；还有其他独立工作。

新增PhotoLUTParameterMemory.swift与测试文件：iOS旧dictionary存储适配安卓role+digest v2独立记忆；本角色已应用配方优先迁移，旧v1摘要其次，旧URI强度最后。严格Int32/排除Bool与浮点，损坏现有作用域字段不回退旧值。只读当前文件少量键，不每拨一档扫描整个defaults；迁移不写旧共享键，另一角色未迁移数据保持。PhotoLUTStore在Off/换文件/提交前保留旧参数，传输未应用记忆不污染已应用配方；restore控制值和渲染同源。acceptSelection现在throws，两个旧测试调用已加try。

PhotoLUTStore新增acceptFolder(prepared,replacing,previous)，identity/revision及定向folderChanges；真正换目录清两个角色选择/参数/收藏，先清后发布新folder，书签刷新或同目录不清。source门禁支持原raw path/fileURL，未知旧identifier保持兼容；迟到source和URI-less旧draft不能提交，原snapshot文件不删。PhotoLUTEditorState订阅清请求/目录，scan和read还校验revision。PhotoEffectsStore持有roleStore并订阅关闭活动Cube；SettingsView同步清打开的draft，commit前canCommitSelection+commitDraft布尔门禁。新测试有5纯迁移+3实际store，实际editor增加跨入口目录变更时排队读取取消。所有这些**只编译，未运行**。

PhotoLUTChooser改用PhotoColorAdjustmentControls共用五轮和复位；删旧.id(source)和升序四轮，参数身份再次防旧gesture，hasSelection改变重置展开，读取时readOnly而不灰化。N17完整动画/真实图片预览收敛未验。

RemoteLUTCatalog新增PresetTextOrder，按安卓AOSP String.CaseInsensitiveComparator明确charAt实现（非桌面Java codepoint版）；simple upper/lower保留surrogate，Greek iota-subscript和dotted I处理，排序内缓存字符映射/无大小写字符短路，原名与URI用rawUTF16。NP3最终fileURI生成后重排。发现Swift规范等价String会合并两类名字，改分类与labels分组键为原始Data；PresetCatalogIndex公开files(in:)/labels(in:)替代旧字典，Optional<String>.presetCategoryBytes/Identifier用于三个实际chooser稳定身份。PhotoFilterCatalogIndex复用fileIndex分组，初始化closure用local sourceIndex避免捕获半初始化self。PictureControlFolderStateTests/RemoteLUTMonitorStateTests只更新查目录API。已有15名对照包含土耳其I/sigma/Greek/组合分解/补充平面，独立Swift与AOSP算法复制版JDK17一致。Unicode17有效BMP63488全部一致；16版3个新拉丁字母映射不同（A7CE/D2/D4），没有声称跨所有OS字库等价。

证据lut-role-and-catalog-progress.json：test session75560 exit70，0方法（模拟器环境）；generic build-for-testing六轮90296 exit65、25561/79603 exit0、39570 exit65、67570/33389 exit0。最后TEST BUILD SUCCEEDED，所有编译/standalone进程已终结；仅24948等用户授权。两个编译失败是Fixture缺MainActor/旧调用缺try，和PhotoFilterCatalogIndex捕获self；日志/源hash全留。独立排序最终session93566 exit0，Unicode17session18874 exit0；前期16版precondition和规范等价分类失败事实也保留。/tmp/ztransfer-removal-derived-20261021仍为derivedData。恢复后先运行ledger所列LUT/NP3/source/catalog/monitor/PictureControl目录最小回归，不用先重复整套编译。

N20刚完整读SharedPhotoFilterFavorites.kt与其4项测试、PhotoEffectFavorites.kt/测试，尚未实施：一次按传输顺序+本地独有项稳定合并，ztransfer.photo_filter_favorites_shared_v1置true，保留旧local key但以后不重导。当前iOS独立favorites仍需接真正共享store/两个draft，不能把其他配置合并。TransferViewModel实际toggle/persist调用、Settings/Local接线尚待补读。其他N22–25、N17/N18验证继续。长期授权是模拟器专项，未获新手机安装/提交/推送授权。

## 2026-10-30 N16实际双入口完成，整轮17/26

同一active goal继续，无预算/阻塞；本人处理，不派agent、不动网站、不安装手机/提交/推送。N16完成，N15/N17/N18进行中，余9项。下面“实际页面尚未接通/16项”已是历史。所有测试进程已终结。

PhotoFilterEditorSession + Lifetime与PhotoNP3Chooser实际接入SettingsPopupOverlay/SettingsView/LocalPhotoEffectsView，RootView传pageActive。真实来源随transfer关窗提交，local即时保存；父只持有不转发的lifetime。每轮begin新建SourceState，native Files子view用lifetimeID并在callback和binding双重检查，旧picker不影响新会话。scene恢复门禁仅跳过真实picker恢复，取消不扫描；隐藏filter模块（包括初始frame-only）不扫描。draftChanged单独观察effective filter开关，inactive保留disclosure但Off→On重置。PhotoEffectChooserDialog支持560上限/提示，LUT默认440保持。旧PhotoFilterChooserOverlay/State及旧card移除，相关fixture转用生产组件。

新PhotoColorAdjustmentControls用于NP3：五紧凑轮、镜像现有RemoteToolMark(.rotate)复位80/四0；-100…100按降序5步，保留合法非整档值。DetentWheel新可选gestureIdentity加入配置，preset+全部参数作为会话身份，旧拖动失效；handler再次检查当前身份。LUT仍旧控制UI，N17/N19继续。favorites normalized允许合法np3内容key，但N20共享/迁移尚未做。实际AppLocalized读AndroidLocalization.byResource，19键三语已同时补映射和Localizable，不要只改后者。onExplicitSelection只捕获photoLUTEditor，避免捕获完整View闭环。

np3-ui-verification.json保留7轮：session70249 exit65编译失败0（旧fixture）、5864 exit0 21、31420 exit0 27、47511 exit0 30、30915 exit0 34、27652 exit0 14、30111 exit0 2。37个不同方法/128次通过；r3截图发现raw key虽测试绿，r4已修且加实际AppLocalized三语断言。13项新PhotoFilterEditorSessionTests包括真实双页和SettingsPopupOverlay，注入文件provider并调用生产session，不是synthetic触摸/系统Files测试。r3/r4/r6各6张附件通过xcresulttool export attachments保留，r4/r6全6图已逐张查看；np3-ui-verification.json含源/安卓/日志/截图SHA。无运行任务、未跑真机/功耗/全UI/Androidinstrumentation。

继续N15最终排序：共享RemoteLUTCatalog.lowercased排序并非JavaCASE_INSENSITIVE_ORDER，raw UTF16 tie；NP3将rawpath转fileURI后需复核次序。N17/N19读AndroidPhotoLutEditor/Store及参数测试，LUT按入口文件独立记忆和迁移未做，新NP3参数面板还需动画/真实预览收敛验证；N18随之收尾。N20共享收藏保持配置独立；N22缩略图回退、N23列表性能、N24文案版本2.02(75)、N25预览锚点/手势仍待做。旧localization同步脚本默认当前ioscheckout的旧app，不要直接运行覆盖新映射。

## 2026-10-30 N16来源索引推进，整轮仍16/26

持续同一active goal，无阻塞、无预算。N15/N16/N18均进行中，剩10项；未使用agent，未动网站，未安装/提交/推送。当前没有运行测试。继续实际UI，不要误核销模型阶段。

新增Domain/PhotoFilterCatalogIndex.swift：PhotoFilterChoice.preset(preset,source)/document(file,presetID)，key区分preset与document，catalogKey仍按内容；同一内置配方可拥有多个独立文件行。选中来源只有sourceRecipe与owner selected ID一致时才采用；missing/denied隐藏目录但保留离线行，read/tooMany保留目录；离线源优先savedLabel，否则使用调用方提供的photo_np3_selected_source文案，没有URI的自定义快照才使用嵌入名称。稳定收藏排序不改重名序号；内置全部/收藏/六类+目录root/folder分类；目录分组一次，不逐分类遍历全部文件。labels(locale,uncategorized,restoredSourceFallback,builtInLabel)缓存，仅50个内置需要本地化。PhotoFilterCategorySelection按真正变化的selected重新定位，否则保留用户分类。沿用公共目录排序，先前Unicode/最终URI问题仍待解决。

PhotoNp3EditorState新增catalog(selected:PhotoFilterPreset?,favorites:[String])缓存，files/failure/selectedRecipe/selectedSource/sourceLabel/hints改变清缓存；请求进度/取消不影响索引，owner强度参数无需传入索引。实际页面仍旧选择器，N16未完成。新类只进Xcode自动source，Package的纯Effects目标不依赖SourceEditor，无需加入该target。

新PhotoFilterCatalogIndexTests8项+既有PhotoNp3EditorStateTests12项=20/20，session52707终结exit0；/tmp/ztransfer-np3-catalog-20261030.{log,xcresult}，仓库np3-catalog-verification.json/summary/log保存。含10000份单文件类别和label次数/对象身份测试，非帧率/耗时指标；未跑Androidinstrumentation、全UI、Files/cloud或手机。前阶段owner r4的session50883轮询输出在压缩时丢失，恢复后handle未知，不能声称exit0：manifest已修正null，独立np3-owner-r4-summary.json证实98/98 Passed。下节50883 exit0为纠正前记录，以本节为准。

本阶段补完整读Android PhotoFilterEditor.kt约430行、PhotoNp3EditorInstrumentation.kt约488行（全部测试与fixture）、PhotoColorAdjustmentControls.kt全部、LutCategoryList.kt的category/browser/header实现。安卓选择器：长按打开并刷新；首次选目录先提示，目录picker取消不扫描；resume跳过一次picker产生的刷新；inactive取消并关选择器/提示。文件行选择始终重读；内置选择先np3.off再reset，离线快照可直接选。loading期间轮/设置/收藏readOnly且外观不禁用，chooser内Preset仍可选而Document禁用。切换preset保持展开，Off重置展开。调节5个紧凑轮+38pt镜像旋转复位，100到-100每5档，合法非5倍数要插入保留（例如9点一下到5），手势键绑定preset+全部参数，复位80/四项0。上述UI规则尚未实现。

两入口现状：SettingsPopupOverlay拥有effectsDraft、PhotoLUTLifetime，beginPresentation从store.beginDraft刷新并递增presentationID；Genie内SettingsView(.id(presentationID))，两个chooser在Genie外由popup根部承载，不能塞进滚动card/clipping。SettingsView.init已可接photoLUTEditor用于真实测试，commit用savedNP3Source fallback，需新source真实URI替换。LocalPhotoEffectsView根有effectsStore/batch StateObject、effectsBinding getter/setter直接owner更新，RootView约538在pager保留该页，尚无active参数，需要传当前page门禁。AndroidDialogPresentation是同层ZStack，不是window portal；不要放入裁剪card。PhotoEffectChooserDialog现有固定32pt header/max440，NP3还要提示页/状态行及Android max560，不能生搬旧布局。完整组件相关小段已读；LocalPhotoEffectsView/UI lifecycle和SettingsView init余段可按需补读。

建议接线时复用持有editor但不转发其每帧/IO更新的Lifetime模式，由控件和chooser订阅实际state；每次presentation创建新NP3 state，close不可逆，避免重用已close对象。owner draft与source URI一起传递，目录选择回调门禁、目录替换清draft和关闭收尾必须完整验证。不要为了复用合并两个角色，也不要用source ID冒充正在读的preset ID。下一阶段应优先实际双入口，而非重复扩大底层测试。

## 2026-10-30 N15/N18启动恢复与owner接线，整轮仍16/26

同一active goal持续推进，无阻塞/预算，独立处理、不派agent、不动网站、不安装手机/提交/推送。N15/N18进行中，余10项；下面rawrestore只识别builtin、没有np3Store/observer已成为历史状态。N16完整选择UI仍未实现。

新增PhotoFilterPreferences.swift：custom记忆键不含converter；Int32/边界/无效项/重复项/稳定编解码，保留detached custom。PhotoEffectsSettings新增filterAdjustments Codable/即时记忆复制/预览身份剔除，selectPhotoFilter(recipe,explicit:)被动刷新保留Off或活动Cube；Selection.photoRecipe给出完整值。目录清理保留内置/其他效果/活动Cube。旧强度拨轮改为修改Selection，保留NP3和后置调节。Package/Xcode同步。

PhotoEffectsStore从原始defaults创建共享np3Store（不使用local resolved suite），先恢复两个角色私有recipe再验证raw ID。传输remembered和applied分别用photo_filter_adjustments_v1/photo_filter_applied_adjustments_v1；local用filter_adjustments_v1。未提交controls不覆盖applied；强度冷启动仍按Android取最新detent map。全局folder observer清实时配置和未挂载local套件的旧配置/JSON，不访问源文件。新增canCommitNP3/commitFromEditor/savedNP3Source；SettingsView提交先guard，再提交LUT和NP3。当前SettingsView来源仅查已保存角色，N16必须接入实际editor.source(for:)；新文件未存role时不能靠这个fallback提交。LocalPhotoEffectsView仍updateFromEditor，新NP3即时source保存尚未接通。frame-only提交不提交filter。

np3-owner-verification.json保留四轮：/tmp/ztransfer-np3-owner-20261030{,-r2,-r3,-r4}.{log,xcresult}，29/29(session93216 exit0)、测试Fixture缺MainActor编译0(94009 exit65)、76/76(54246 exit0)、98/98(50883 exit0)。全部结束，无运行任务。新PhotoFilterPreferencesTests有6codec/model+8owner；实际SettingsView组件测试加NP3角色落盘断言，末轮还含batch11和全部62queue。跨轮156个不同方法成功，不是单轮156。源和日志哈希保留。未运行本阶段Kotlin、Android instrumentation、全UI、Files/cloud、真机/性能。

已读Android PhotoFilterAdjustments及其6项测试、Identity、intensity codec、LocalPrefs相关normalize/restore/save/clear和测试、PhotoPresetDirectoryState、VM初始化/记忆/提交/observer，以及两个页面NP3 callback/commit。PhotoFilterAdjustmentsInstrumentation已读32–248相关场景，末尾fixture未读；PhotoNp3EditorInstrumentation完整UI测试仍待N16。

下一步优先真实双入口选择UI，再参数面板和完整记忆核销。iOS路径是UI/PhotoEffectsEditorView.swift（controls/filterCard）、UI/LocalPhotoEffectsView.swift（effectsBinding）、UI/SettingsView.swift（controls/commit），不是Views目录。NP3.close后不能复用同一实例，初始化须用实际draft与活跃门禁。新选择的URI和recipe须一起到owner，不能猜来源。shared收藏、调节交互及上一节记录的最终URI/Unicode排序仍未收尾；任务数不增加。

## 2026-10-30 N15目录/生命周期后端接通，整轮仍16/26

同一active goal持续，上一turn为实际快照/存储进展，本turn为实际IO/状态实现与47项验证；无阻塞/预算，不派agent、不动网站、不安装手机/提交/推送。Android工作树仍dfd66a20干净ahead2；台账N15进行中、16/26，余10。下面“FileProvider IO/editor尚未实现”已被本阶段替代，但owner恢复/实际页面仍未接通。

新增Domain/PhotoNp3EditorState.swift（246行）：PhotoNp3Source可注入操作，live直接复用RemoteLUTFolderAccess.prepareFolder/prepareBookmark(with np3 extension)/withScopedFile+FileHandle/PhotoNp3Parser；共享PresetIOQueue和每editor独立LUTRequestController，10秒默认。公共prepareBookmark只增加operations参数传到prepareFolder，默认不变。NP3的PresetFile.identifier使用file:// URI，其他既有LUT仍保留原absolute path，不能混用；读取只用bookmark+relativePath。扫描时给NP3元数据映射稳定逻辑root，刷新和重选同一bookmark实际目录仍保留原root身份，原生容器路径变化不破坏来源匹配。scope操作后台defer释放，不存在等待UI提交才释放的lease。

State有folder/files/failure/selectedRecipe/selectedSource/selectedSourceLabel/sourcePresetIDs/notice，loading/pending委托request。原样实现explicit/passive刷新、相同id+source不触发owner回调、不因刷新启用Off、完整成功列表确认消失才off/onUnavailable、失败保留旧列表/recipe、文件改名先更新label即使新字节坏、换目录清双draft但保留builtin、selectionAllowed交付门禁、关闭不可再用/取消/弱释放。只管目录与来源草稿，不替owner保存角色/效果配置。UI未来要新建每次presentation生命周期，不能close后复用同一实例（对照AndroidonDispose）。实际页面还未创建这个State。

证据np3-editor-verification.json：/tmp/ztransfer-np3-editor-20261030{,-r2,-r3}.{log,xcresult}三轮21/21(session14736)、30/30(80827)、47/47(17883)，均已terminalexit0，当前无运行任务。新PhotoNp3EditorStateTests.swift有12state+3FileProvider测试：生产串行队列、故意忽略取消的gate、显式/被动/不变、所有错误保留、完整删除不动ownerStore、两role换目录/内置保留/旧保存拒绝、80ms测试注入超时与物理移除待执行scan、旧scan不能先提交、weak释放。真实临时NP3与Foundationbookmark覆盖一级类别/过滤/metadataonly、fresh读取、64KiB上限、URI身份与实际路径分离、损坏bookmark/越界relativePath/拒绝scope/取消后释放。scope许可是注入计数，未测SystemFiles/cloud授权。最终另含Codec9、Store7、PhotoLUTEditorStateTests11、RemoteLUTLoadQueueTests5；未跑Androidinstrumentation（完整读413行）、全UI、真机/CPU/FPS/功耗。

下一步实际owner接线仍需读完整相关段再改：PhotoEffectsStore init约1074，先Androidraw恢复再JSON；local scope会切UserDefaults suite，NP3共享Store必须从原始defaults创建（不是local resolvedDefaults）。Android TransferViewModel init1268+先把transfer/local私有recipe并入只读catalog，再解析selectedID；2039+setPhotoFilterConfiguration同时guard两种sourceCurrent再保存LUT/NP3和applied参数。SettingsScreen381+rememberPhotoNp3Draft的onSelected恢复独立记忆，explicit才关LUT/启用filter，496+commit才保存；LocalPhotoEffectsOverlay219+local显式/刷新语义相同，267+选择/来源变化即save并在dispose再save。1570附近ViewModel全局folderObserver清custom应用/记忆/收藏，local prefs也清；local页本身还订阅清draft。不能只实现draft的onUnavailable就遗漏页面没打开时的应用状态。PhotoEffectsStore现在没有np3Store/observer，rawrestore仍builtin-only；N18强度/参数和N20收藏也没接。

已读PhotoFilterIdentity：custom renderID是np3:64hash:converter，偏好catalogKey必须是np3:64hash（不带converter）；当前PhotoEffectsSettings.filterKey约627仍只映射builtin，normalized约1409与decodeAndroidIntensities1690仍只允许builtin，需N18统一补齐。不要用全局可变配方registry，Selection持有完整typed参数继续保持。PhotoNp3EditorInstrumentation(488行)目前只定位未读；PhotoFilterEditor.kt已读初始化/lifecycle和选择模型，剩UI完整段待N16。所有失败/未验证范围继续保留，不能核销N15或整轮。


收尾额外发现待核对的排序细节（未修改/未验证）：RemoteLUTCatalog.visibleFiles约56用lowercased再UTF16、名字/identifier fallback是Swift `<`；Android为CASE_INSENSITIVE_ORDER再原始UTF16名字/URI。NP3适配把扫描后的raw-path identifier转成file:// URL后没有按最终URI重排；相同文件名处于不同Unicode分类时，转义后的URI排序可能与原path不同。N15/N16选择器收尾时补实际用例并按安卓规则处理，避免重名序号受影响；现在的元数据测试只验证ASCII文件名，不据此声称全部Unicode排序一致。

## 2026-10-30 N15快照/存储局部完成，整轮仍16/26

同一active goal、无预算/阻塞，独立处理，不派agent、不动网站、不安装手机/提交/推送。Android再次确认dfd66a20干净ahead2，iOS基线58d9b6ed。台账N15改进行中但不核销，剩N15–N20/N22–N25共10项；下面N14阶段的“SnapshotCodec尚未实现”已被本阶段替代。

新增PhotoNp3SnapshotCodec.swift（4096上限/v1灵活/v2传统/v3分级/SHA/modified UTF-8/严格身份与范围），PhotoNp3Store.swift（shared目录bookmark、transfer/local独立快照、来源hint/label、换目录防旧draft、仅folder变化通知）。Java字符串按UTF-16计长度，显式检查surrogate，保留开头FEFF/零宽字符；同文件夹有无尾斜杠不清角色。Selection持有np3Recipe，Codable有界完整snapshot，不保留sourceURI；PhotoEffectsRenderer消费typed参数，旧builtin规范化保留lutAdjustments。正常滤镜切Cube时记忆typed配方。Package加codec，Xcode项目同步，Store尚未被UI调用。

np3-snapshot-verification.json保留四轮：r1 /tmp/ztransfer-np3-snapshot-20261030.log、22/22(session91940 exit0)；r2 -r2、测试漏try导致编译0(session25514 exit65)；r3 -r3、59/60(session71606 exit65)，新队列测试误比较入队时按原逻辑禁用的watermark；改为精确比较selectedFilter/完整recipe，未改queue实现；r4 -r4、121/121(session74426 exit0)，含全部62个TransferQueueScenarioTests。新PhotoNp3SnapshotTests.swift有codec9/store7方法，DomainModelTests同文件extension增真实队列换目录/失败/重试配方保留测试。全部进程已结束，无在跑测试。目录/关闭保留提示、角色独立、损坏拒绝、源文件不在也可真实preview/original渲染均有后端证据，不外推UI导入。

Kotlin对照在/tmp/ztransfer-np3-snapshot-oracle-20261030，JDK17，复用上阶段已验证jars。未改实际PhotoFilterPreset/Classic参数/Grading/Identity/SnapshotCodec和原始SnapshotCodecTest；仅两个converter常量与不会调用的catalogKey stub。69组fixture与Swift编码逐字节一致，原始JUnit10/10(session42034 exit0)；runner/stub/log及依赖哈希保留，fixture只在test bundle。Fingerprint.kt是另一个提取片段，未作为本轮外部fingerprint验收；Selection测试只是实际输出名的往返稳定性。

下一步N15仍要接通FileProvider IO/editor生命周期与owner提交/恢复。已读完整PhotoNp3EditorState/Store/Codec及Store/Codec测试、PresetFolderRepository/SourceFolder/IoQueue/SerialPresetQueue。可复用RemoteLUTFolderAccess.prepareFolder/prepareBookmark(fileExtension:"np3")和既有共享PresetIOQueue/LUTRequestController，不要复制IO队列。10秒超时/取消/换目录/新鲜重读/完整扫描后缺文件才失效/selectionAllowed/关闭拒绝迟到都要逐条对照。iOS bookmark准备IO自身defer释放scope；Android grant-release语义需对应到既有原生lease。

特别注意：PhotoEffectsStore.init目前先恢复Android原始偏好，restoreAndroidTransferSettings/LocalSettings仍只解析固定catalog，不能仅凭新Selection JSON声称重启恢复完整；local入口有独立UserDefaults suite，NP3共享Store须用外层共享defaults，角色不要合并。store.save与两个editor确认/实时提交尚未接线。N18每滤镜记忆仍只允许固定catalog key，typed强度/参数独立记忆仍待做。未跑全UI、手机/相机、CPU/帧率/功耗，不新增安装/提交/推送权限。

## 2026-10-30 N14渲染收尾，整轮16/26继续

同一active goal、无预算/阻塞；独立处理，不派agent、不动网站、不安装手机/提交/推送。台账16/26，N01–N14/N21/N26完成；余N15–N20/N22–N25共10项。Android仍dfd66a20干净ahead2，iOS基线58d9b6ed；下面15/26和N14未实现均为历史阶段。

Np3FilterEngine改为typed CompiledFlexibleNp3/CompiledClassicNp3共用像素外层；31base映射、quarter/Auto/黑白滤镜/调色浓度/创意强度/曲线全部对齐。CompiledNp3ColorGrading按安卓编译4×1025Float表，中性先guard不分配；HSL量化→grading→strength混合→finishing。LUTColorPipeline移出PhotoCubeLUTMapper到独立Swift文件，两个路径复用；PhotoEffectsRenderer旧内置路径补传lutAdjustments。Np3BitmapFilter新typed重载共用同一像素循环、取消、alpha转换和最多2个预览worker，未复制适配或增加UI。项目/Package sources已同步。

np3-rendering-verification.json四轮：33/33、测试编译失败0、47中46、最终60/60（session57571 exit0）。失败原因分别为测试curve参数nil/UInt16类型，及全图测试直接比较UIKit画布与RGBA适配的原始字节序；最终统一premultiplied sRGB格式后严格字节一致，无容差放宽。新PhotoNp3RenderingTests11项，含实际应用render后置调节、传统与grading并行/串行/取消/透明度、creative0/Auto/曲线拥有、纯亮度/色域/连续灰阶。最终还包括parser20、旧50预设golden、旧配方迁移/两个偏好作用域和LUT回归。N13旧manifest是历史快照，N14保存当前相关源哈希，不倒改旧证据。

Kotlin对照已补齐：/tmp/ztransfer-np3-oracle-20261030内下载固定2.2.21 compiler与依赖（Maven SHA1校验及本地SHA256记录），JDK17在/opt/homebrew/opt/openjdk@17/bin/java。未改安卓6份真实生产源码，Bitmap/Cube API仅抛错stub；Oracle.kt反射实际compileFilter/filterPixel，31base×3参数组＋10flex组，4强度×2alpha×2后置调节，1648组×518色=853664像素的SHA全部一致。旧50预设golden未改。安卓原始ClassicNp3RendererTest8＋Np3ColorGradingTest6＋LutColorPipelineTest4共18项也通过；runner/stub文本、日志、依赖哈希、test bundle夹具均保留。iOS没有引入Kotlin运行依赖。无全UI、真机/相机、CPU/帧率/功耗验收。

下一步N15：已补读PhotoNp3Store缺失45–102段，restore先匹配BuiltIn、再验证customID/来源文件夹/4096byte有界snapshot及相同id；observeFolderChanges只对实际folder值改变发通知；isSelectionCurrent防旧draft跨目录提交。SnapshotCodec全篇已读但实现未开始。仍需完整读PhotoNp3EditorState、Store/Codec测试、来源文件夹IO和两个UI调用链；N15覆盖目录授权/取消/刷新/超时/快照和队列生命周期。PhotoNp3Recipe目前只承载纯不可变参数，PhotoFilterSelection仍仅preset/intensity/lutAdjustments+Cube owner；不得仅存ID或让队列读取可变全局NP3配置。用户NP3完整导入尚未接UI，N16–20也未完成。

## 2026-10-30 N13解析完成，整轮15/26继续

同一active goal、无预算/阻塞；独立处理，不动网站，不安装手机/提交/推送。台账15/26，N01–N13/N21/N26完成，剩N14–N20/N22–N25共11项。Android仍dfd66a20干净ahead2，iOS基线58d9b6ed。下面14/26及N13未实现是历史阶段，不沿用。

新增Domain/PhotoNp3Recipe.swift、PhotoNp3Parser.swift、ClassicPhotoNp3Parser.swift，现有Np3FilterParameters加入可缺省的colorGrading及安全Codable验证。完整实现64KiB有界读/取消、TLV/字段/编码范围、Flexible 0310/Classic 0300+0310（31base、Auto=-128、quarter）、257点曲线拥有规则、三域grading、中性canonical、detail不重复锐化、SHA匹配curated保留旧ID转换、新文件内容SHA+converter版本身份。FileHandle适配只借用句柄，读上限65537，不保留源引用。PhotoNp3Recipe单独承载metadata与完整参数，未提前改持久化作用域。

PhotoNp3ParserTests 20项；9份既有测试NP3与安卓字节相同。np3-parser-verification.json保存3轮：编译失败0、32/32、34/34。第二轮误用资源测试类名未运行，最后改UserPictureControlResourcesTests并实际通过；34包括20解析+7引擎+5位图+1历史50预设安卓像素oracle+1应用资源检查。最终日志TEST SUCCEEDED，xcresult独立确认Passed/34/0失败；第三轮会话句柄未在压缩后保留，纠正原先推断的session/exit记录，exitCode改null并附结果包summary，源哈希/历史日志不变。App不带相机NP3。未运行本轮Kotlin、全UI、手机/相机、CPU/帧率/功耗。Package显式sources及Xcode工程已更新。

N14/N15尚未完成：已读PhotoFilterRenderer编译Classic系数和像素顺序、Np3ColorGrading实现/测试、ClassicNp3RendererTest以及PhotoNp3SnapshotCodec全篇；PhotoNp3Store中60–85行仍需补读，其他导入与双入口调用链/测试待逐项核对。N14需分级1025点编译表、31base明确映射、共用有界位图循环，滤镜强度混合后只应用一次LUTColorPipeline；当前iOS builtIn路径忽略lutAdjustments，用户NP3尚未接通。N15二进制快照v1 Flexible/v2 Classic/v3 grading+SHA尾校验，transfer/local状态独立，共享文件夹/收藏不能合并配置；完成解析不等于整个导入功能完成。可用JDK17在/opt/homebrew/opt/openjdk@17/bin/java，但PATH里的java仅系统stub；kotlinc/缓存尚未找到。

## 2026-10-30 N12原片复核收尾，整轮14/26继续

同一active goal继续，无预算、无阻塞；不派子agent、不动网站、不装手机/提交/推送。Android仍dfd66a20（干净ahead2，origin18145b3a），iOS HEAD58d9b6ed。台账当前14/26：N01–N12/N21/N26完成，余N13–N20/N22–N25共12。下面13/26等均为历史阶段，旧manifest不改写。

N12已实现且通过最终145/145专项，证据 `ios/docs/evidence/android-sync-20261028/original-index-verification.json`。六轮：编译失败0、编译失败0、25中24、143中141、144/144、145/145；最后session14135终态exit0。前两轮是新增测试autoclosure/隔离修正；第三轮旧“refresh即重扫”测试修为安卓实际显式重选边界，整批准入断言保留；第四轮发现新增@Published选择revision增加全局重绘，改为selectionChanges定向事件，既有性能断言未放宽。无全UI/Kotlin/手机/相机/实测功耗帧率。新建测试TransferOriginalVerificationTests.swift共20方法；旧纯历史回放API及假保留测试移除，生成失败/清空保留原片验证加强到真实TransferQueueScenarioTests。

TransferDirectoryIndex.findVerified只复核内存命中；fresh URL resourceValues + FileHandle打开/关闭，不消费内容、不用fd长度。仅明确missing才删除，权限/提供器/目录错误原样失败；继续找编号副本，编辑大小/重命名保留真实占名，未知大小非空匹配。内部replacement revision只用于compare-remove，reader新构造的同名同大小URL仍视为有效，避免无限循环。队列独占移出的索引用单消费者TransferDirectoryVerificationJob交给后台，避免失效循环COW全量复制；查重和目录扫描均传播取消，等待期间撤回可响应，取消/撤回后不迟到发布。

TransferOriginalStore是队列持有、列表共享的锁内可变索引，通知为合并的Void信号，读取最新状态。扫描在后台持有DirectoryAccessLease；按root/mode缓存，旧root/scanID结果拒绝；在途按key记录版本保护防复活/覆盖新发布，完成后清理临时版本表；共享合并不在锁内重复正则。历史卡片不再回写，已完成原片按实际字节记账，效果失败和清空不丢失。DirectoryAccessStore.selectionChanges表达同URL重选成功及真正清除；PhotoListView.onReceive强制清索引重扫，普通catalog/mode刷新复用；无重复全页发布。已读Android完整ExistingFileNameIndexTest、ExistingOriginalDocument以及TransferViewModel 172–258、396、2270–2500相关实现。

下一步N13：已全文读安卓 PhotoNp3Parser.kt(249行)、ClassicPhotoNp3Parser.kt(144)、ClassicNp3PhotoFilterParameters.kt(64)、PhotoFilterPreset.kt、Np3ColorGrading.kt；两套parser测试306+177行也已补全阅读。iOS当前Np3FilterEngine仅Flexible旧参数/渲染，Np3FilterCatalog是固定转换目录；PhotoEffects.PhotoFilterPreset仅id/name，无用户NP3解析器。尚未修改N13代码、未运行其测试。需要64KiB有界读、TLV结构/重复/结束校验、Flexible 0310与Classic 0300/0310按base分流（非仅version）、31种Classic base/quarter-step/Auto=-128、257点曲线/curve-owned sentinel、detail仅校验不二次锐化、完整grading与neutral canonical、错误INVALID/UNSUPPORTED/TOO_LARGE区分。精确source SHA匹配已有curated时保持旧id/转换；用户导入属于本轮，不能误跳过。测试夹具可来自安卓test/resources的3份Flexible和6份Z30导出，内置相机NP3仍不作为iOS正式资源。N13解析、N14渲染、N15快照/生命周期、N16–20双入口交互与独立记忆依次接通，不凭单独模型完成整轮。

## 2026-10-30 N10入场/订阅身份收尾，整轮13/26继续

本turn继续同一active goal，有实际代码与验证进展，无阻塞；get_goal确认objective仍为“安卓端又有一些新功能…老规矩…略过回滚/排查共性性能”。未设预算，不标complete/blocked，不派子agent，不动网站，未安装手机/提交/推送。台账 `docs/待做/iOS-20261028-安卓增量复刻.md` 当前13/26：N01–N11、N21、N26完成，余N12–N20/N22–N25共13项。下面12/26、11/26均为阶段历史；N09本turn也已补齐（55方法），随后N10再回归它，旧证据不改写。

N10新增 `QueueItemAppearance.swift`（QueueAppearanceKeyMap/Tracker/Checkpoint/Clock/modifier），按TransferScreen.animateItem和Foundation1.7.6实现180ms FastOutSlowIn入场，无额外系统隐式动画/全卡片transaction覆盖。只比较上一布局key map；首次无旧map、空队列切换安静重置；索引0是汇总栏，近邻窗口30、前后100，普通近邻滚动不重播，远跳不在旧map时仍遵循安卓appearance。复用QueueRemovalCoordinator原生锚点，新增viewportRows/onLayoutChange及Marker.layout回调，只有布局检查点更新缓存，不发布父层帧状态；相同range且IDs不变不重建集合。数据prepare和leave提升revision，异步旧布局不能把尚未呈现的新插入吞成历史，旧页回调也不能污染新页。叶时钟有限、不重启在途、背景/离页停表、弱target不留owner。原位置spring/移除height/卡片手势不叠额外动画。

复查还发现旧QueueProgressScope的active/inactive条件分支会销毁同一卡片子树，导致等待→下载→完成打断颜色、波形等状态。已抽到新Components/QueueProgressScope.swift，稳定内容身份，仅通过MainActor下的Combine订阅桥转发当前活动任务的objectWillChange，退出取消订阅；使用项目既有的@preconcurrency ObservableObject桥接旧协议。入场/位置modifier放到scope外层。原40行QueueProgressInvalidationTests已加强：父页不重算、仅当前活动行响应，切换任务后每行@State身份仍唯一。无需新增全列表进度观察。

证据 `ios/docs/evidence/android-sync-20261028/queue-appearance-verification.json`：8轮依次编译失败0、19中18过（像素夹具采到下方移动旧卡片）、19/19、2中1过（只滚到懒布局的估计尺寸）、编译失败0（Combine协议隔离）、3/3、集中146/146、最后revision竞态10/10。147个不同方法成功，197次成功执行；最后session6394已terminalexit0，集中session15983 exit0。不是单批147全绿。修夹具是手动淡入停0等待独立位置spring退开再采像素，滚动跟随实际修正的contentSize直到目标真正可见且超时抛错；未放宽断言。初次测试Source补MainActor。10个最后方法含近邻map、插入/重排/替换、时钟/弱释放、背景、原生懒布局屏外新项/滚回、旧布局/旧页面回调及40行身份/订阅验证。

13张最终图已查看：透明→90ms灰度→实心、真实卡片移除、数字局部/跨位。146轮模拟器沙盒已被后续安装更新，图片从xcresult附件导出，附件manifest保留；10轮图片直接复制，均sha留证。旧manifest不改写，新证据记录28个当前源码hash；模拟器/root /tmp路径完整记录，源foundation1.7.6新增LazyListScrollPosition/NearestRangeState全文及原LazyLayoutItemAnimator/Animation摘录。未运行Kotlin/全UI/真机相机/CPU/功耗/帧率验收，不声称这些已通过。N10可核销，继续后续功能，不能把剩余13项忽略。

接下来N12已初读：Android `app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt` ExistingFileNameIndex 172–258的findVerified/compare-and-remove，以及findVerifiedOriginal约2470，只对内存命中候选进行IO校验，失败权限/提供器异常不证明删除；删除后继续找副本，编辑/重命名更新真实占名；失效仅移除精确旧发布并按目录作用域更新export revision。测试 `ExistingFileNameIndexTest.kt` 包含删除副本/全删与效果隔离/文件变长/重命名/权限错误/迟到结果/大小写预留/未知大小空bucket；文件曾长输出被截断，开始实现前补全读取全部测试和调用链。iOS `Domain/TransferDirectoryIndex.swift` 当前existingOriginal只按缓存返回URL，尚无候选真实复核/精确remove；ExportedOriginalIndex仅add/merge/record/original无remove。TransferQueue.swift约1164命中后直接标completed，resourceValues取不到大小还会记0；批次开始仅扫描一次。下一步核对UI索引store生命周期/重试引用，再实现真正复核及取消/旧回调保护；注意NSURL资源属性缓存不能作为新鲜存在性证据，外部IO失败不能误删索引。N12尚未改代码/未运行其新增测试。

## 2026-10-30 N09逐位动画补齐，整轮12/26继续

上一goal turn有实际代码及80测试进展，本turn继续无阻塞，仍同一active goal；不派子agent、不动网站、不安装/提交/推送。开始已重读本文件/台账和实际工作树。Android仍dfd66a20（本地干净ahead2，origin18145b3a），iOS HEAD仍58d9b6ed。当前台账12/26：N01–N09/N11/N21/N26完成，剩N10/N12–N20/N22–N25共14。下面11/26是发现遗漏时的历史记录，N09现在补上实际实现和新验证后才能核销，不改写旧manifest。

新增UI/Components/QueueNumericValueMotion.swift与QueueAnimatedValue.swift，统一替换胶囊速度/计数、两张状态卡计数/下载速度、历史卡片速度。QueuePillRollingCount现只是共用组件薄封装；原QueuePillCountClock/CountMotion/CountLayerMotion及系统TransferNumericText删掉，DomainModelTests中4个旧整串测试迁入新的9模型+3时钟方法。TransferInfoPill.numericValue改Int64，完成速率用queueNumericValue按Kotlin.toLong饱和转换，正常字重对齐Android Normal。新解析按UTF16 Nd和三种小数点，按位权key稳定；相同text不重记原数值/不重启；单位或非数字整串转场；99→100→9保留离场位、占宽立即0、反转重用旧层。模型静止位不采样，集合仅实际缩减时整理；有限时钟只在文本叶节点，背景/隐藏/卸载停表，重新挂载取最新值不回放。胶囊原600ms采样/批次结果/Done1800/补满120+40/固定右缘宽度等不改变。

重新下载Google Maven官方Compose1.7.6 animation/core/foundation sources（当前app明确foundation1.7.6）。普通位移tween180、入160/出120、整数半行物理像素；Transition中断tween是critical1500，PostExit反向采用EnterExit默认400。父Transition快照切段会resetAnimations递归，因此未变但仍在运行的数位也需以当前值/速度重建（不生成新字符层）；不能误用“字符一样就不管在途动画”。源码URL/完整SHA及摘录保存在numeric-value-verification.json和numeric-compose-*.kt.txt，原缓存/tmp/ztransfer-numeric-compose-1.7.6。原web搜索也核对官方Android源码，但实现依据固定版本jar。

numeric-value-verification.json三轮：/tmp/ztransfer-queue-numeric-20261030 53/53、queue-numeric-layout2/2、queue-numeric-final55/55，全部TEST SUCCEEDED/exit0；55不同方法、110次成功执行。最后session24786已terminalexit0。新真实组件像素：42.1→42.3未变整数/单位区域字节一致、变化小数确实移动；9→99→100→9目标宽即时变化、右缘固定、收尾像素与原9完全一致无幽灵位。模型测试覆盖同文案原速变更、位权/缺位/小数符号、全标签单位/反转、恢复/隐藏/未挂载及weak owner；同时回归汇总卡、三主题胶囊、完成转场/批次/生产速度采样。10张numeric-final-*图已查看，2份CSV、三日志、相关当前源哈希保留；完成联系图为layer.render，不能代表实时玻璃/Metal像素。未运行Kotlin/全UI/物理相机/真机CPU/功耗/帧率。

下一步N10：新增行180ms淡入与完整卡片动画审查仍待做。已读取Foundation1.7.6 LazyLayoutItemAnimator.kt 80–181与LazyLayoutItemAnimation.kt173–203：首次keyIndexMap==null不入场；以后previousIndex==-1且上一map非null才animateAppearance，已有入场不重启；初始layer.alpha=0，再180ms FastOutSlowIn到1。可见项位置变化另走原placement，滚动delta直接消化；上一key map是LazyList近邻范围，不能简单让每次onAppear（滚动或返回页面）都淡入。两文件摘录已留证，完整缓存同上。当前QueueItemPlacement只有位置弹簧，未新增淡入，台账N10仍进行中。不要用本次数字55方法核销队列新项入场。

## 2026-10-30 队列移除局部完成验证，N09遗漏重开，整轮11/26继续

继续同一active goal，主任务独立做，不派子agent；Android目标仍dfd66a20、远端18145b3a，iOS仍58d9b6ed，网站并行内容不碰。台账当前11/26：N01–N08/N11/N21/N26完成；N09重开、N10进行中、N12–N20/N22–N25待做，共15项未完成。上一节12/26是当时记录，已发现缺项不能继续沿用；不是撤销已通过的采样、批次、宽度或效果开关验证。无新阻塞，goal不能complete/blocked。

N10新增QueueRemovalMotion.swift（可见项20ms错峰/80ms封顶、280ms线性时间线、透明度前64%/高度后18%起余82%、0.97–1缩放）、QueueRemovalCoordinator.swift（页面拥有捕获范围收尾）及原生QueueRemovalAnchor。只在操作开始读真实UIScrollView可见行几何；屏外目标立即删除，不让整队陆续补入再退出。所有行与收尾同一实际帧时间，最后40ms余量；墙钟流逝但无帧不能删除。离页/虚拟条目消失仍执行捕获范围finally，新任务/重试/忙碌任务不会被扩大范围清掉。独立叶子进度观察、收合期间禁位置弹簧，生成卡不订阅下载进度；空/非空切换重建滚动容器并清旧位置。TransferQueue/VM新增beginRemoval原子准入与removeAndReturnRetained：晚到删除回调不能把已不存在的旧卡当成busy恢复，防闪现。

N11旧测试夹具QueueRemovalCoordinatorTests有4方法未纳入上轮80场景，仍期待离页遗留取消卡、清空连新增终态也删；本轮按安卓当前finally/捕获范围改正并实际跑过。QueueCardPresentationTests离页预期同步改正。清空动画期间下载完成测试改手动帧，避免墙钟猜测。保留旧日志/哈希，不伪造旧测试已跑。

queue-removal-verification.json六轮证据：queue-removal编译失败0（非Sendable显示链不能在非隔离deinit读取，改为wait/cancel显式收尾+既有弱代理）；fixed编译失败0（旧abandon接口测试）；aligned78/78；layout1方法失败（在160ms错误期待alpha0）；layout-fixed1/1（按280*.64=179.2改200ms采样）；final80/80 TEST SUCCEEDED exit0。80个不同方法、159次成功执行。最后session27052已terminalexit0；两张latest-queue-removal PNG已查看。真实组件验证视口选择/先淡后缩、无父帧发布、晚回调不恢复、页面finally、固定确认窗及61场景。未运行Kotlin/全UI/真机相机/功耗/帧率，不安装不提交不推送。

下一步先补N09共享逐位数字动画，再收N10新增卡片180ms入场/完整动画核对。Android AnimatedQueuePillCount.kt在a90da2eb已变：queueNumericLabel允许未分组整数/小数与`.`/`,`/阿拉伯小数点；整数位权从右对齐，小数从左，未变位不动，单位变化整标签过渡，连续99→100→9保留离场位且目标宽立即0。动画位移180ms FastOutSlowIn、入160/出120，半行高位移，方向比较原数值；remember(text)令同显示文案不因原值变化重启动画。iOS QueuePillRollingCount当前仍整串+旧位移弹簧，TransferNumericText是系统numericText/240ms：没有复刻这部分，不能把旧测试当证明。需要统一胶囊、状态卡数字、历史速度标签；此前QueueCompletionState/600ms真实actor采样/120+40补满/Done1800/宽度弹簧等已验证链路保留。N10卡片进度原有目标/失败不补满及完成100ms延迟+220ms退场已在QueueCardProgressVisibilityTests回归，但新增项180ms入场未实现，因此仍不核销N10。

## 2026-10-30 新增安卓两提交并完成胶囊/效果开关，整轮12/26继续中

用户又要求“有一些改动，老规矩”，继续原active goal、主任务独立执行，不建新goal/不派子agent。Android pull返回Already up to date；本地干净领先远端2，按既有授权纳入16d38f33、dfd66a20，当前目标dfd66a20c739342fafbd927659e815e2d499e5ea，origin/android仍18145b3a。13文件哈希见android-source-addendum-20261030.json；iOS仍58d9b6ed，无提交/推送/真机安装。网站并行修改不动。

台账docs/待做/iOS-20261028-安卓增量复刻.md现12/26，N01–N09/N11/N21/N26完成。N08因新徽标规则重开后重新验证完成；N26新增关闭效果时配方捕获。剩N10、N12–N20、N22–N25，共14项，继续，不能结束整轮。新增其余范围：N23连拍图片抗锯齿/列表避免无谓集合和观察；N25主动归组不重新带出旧工具；N24版本2.02(75)和renewal_needed新三语文案核对；尚未实现这些追加。iOS版本目前仍1.98，苹果权益差异保持，不能把安卓续期后台搬来。

N09新增QueueCompletionState/Tracker与TransferSpeedDisplaySampler；生产actor逐下载600ms采样、无效不记时、首正速立即、原始字节/进度不降频、旧ID回调拒绝。删除旧QueuePillSpeedCadence/Clock；胶囊已真正接QueueDownloadDisplayModel（120+40ms），仅实际下载进度。批次保留已移除失败、区别跳过与实际工作，终态元数据不重启Done1800ms；同一结构快照缓存事件。显隐直接传visible到QueuePill，移除生产旧QueueTopPresence(kind:.pill)，宽度可0/右缘固定/最后8pt淡出+24pt羽化，宽度和液面叶节点观察。QueuePillTaskSummary.progressOwner现仅actualDownload。注意新的onChange全消费新快照，不读取旧self。

N08追加TransferQueueStatusCards：生成徽标数归0后120ms淡出但留旧正数宽度，直到行全部离场；零不读屏，空闲占全宽。新QueueGenerationRemainingBadge/Opacity叶节点时钟，不影响灯泡。N26队列所有enqueue/auto/crop接口追加可选photoEffectsEnabled，UI每次入队显式传effectsStore.isEnabled，actor默认内部调用走自身门禁，queuedEffects统一nil或有效配方。此参数只决定新任务，已有任务/重试不变；编辑器仍保存效果。

pill-latest-verification.json保留5轮：pill-20261028和pill-fixed编译失败0；pill-sampler101方法97成功/4方法失败5断言；pill-latest-20261030 108方法107成功/1失败；pill-render-20261030最终4/4成功。109不同方法累计成功、208次成功执行。101轮失败因旧测试凭空移除未完成任务而期待成功；修夹具让省略的等待任务明确本地跳过。最后物理主题几何帧采样被同步drawHierarchy冷Metal刷新阻塞，改layer.render并延长观察窗口，未降低帧数断言；真实顺序/右缘/中间尺寸断言通过。新结构/进度纯测试、真实队列采样/61项场景、新生成保宽/真实队列页、三主题胶囊状态、Done元数据期限均通过。七张实际图已看，图层图不能证明玻璃/Metal像素，非真机相机/帧率/功耗验收。旧证据源哈希不要更新。

所有build会话均已终态，最新29913 exit0。B6B4E291-173A-4BFE-BB9C-2D1F62643C49确认Shutdown，FC8ECF06-0A56-4949-B64C-3EE06870025E仍Booted不动。当前工具权限已变为全权限/never，后续exec_command不要再传sandbox_permissions。新一轮无新安装/提交授权，专项模拟器授权持续有效。

## 2026-10-28 队列状态卡完成，整轮10/25继续中

本轮有实际源码/测试/截图进展，active goal继续，非阻塞。主任务独立完成N08；台账10/25、剩15项。Android仍18145b3a、iOS58d9b6ed，未提交/推送/安装，网站文件不动。下一步N09速度胶囊与N10历史卡片、N12索引，再NP3等；不要把共享模型存在当成胶囊已经接线。

新增Domain/TransferQueuePresentation.swift、UI/Components/QueueSummaryMotion.swift、TransferQueueStatusCards.swift，真实TransferQueueView首个滚动项恒定双卡、空队列仍保留。UUID身份不变，attemptOrder在全部入队/两类重试递增，用于等待生成顺序；运行生成优先。最多3驻留/2退出，显示2行、计数全部；成功110ms绿/220ms持留，退出140ms/位移180ms；下载120ms补满+40ms合并输入的显示模型已接状态卡，尚未接顶部胶囊。原生层背景2400ms、0…0.08呼吸（前笔0.045记忆不准确，以源码0.08为准），220ms存在性淡出/卸载停止，不影响灯泡差异。

真实宿主抓到两个生产问题均修正：onChange调用读取旧self的helper会使用上一帧let输入，下载输入/生成任务与历史/动画阶段改成单个Equatable快照，回调直接消费新值；生成ZStack较少行时会在固定高度内居中，必须frame(height:...,alignment:.topLeading)。以后新回调勿重复这个模式。模拟器宿主须UIWindow(windowScene:)并显式.environment(\.scenePhase,.active)，否则黑图/背景停动画不是合格证据。真实队列夹具的UserDefaults跨actor需独立实例。

summary-verification.json保留9轮：0编译失败、0夹具编译失败、75(3方法失败)、75(2方法失败)、2(1失败)、2(1失败)、2全过、0生产页夹具编译失败、最终98/98全过。共98不同方法成功；Scene那轮工具退出码0但日志TEST FAILED，明确按失败记。最终8张实际图已实看、源/日志/图片哈希记录；覆盖纯边界/精确时序、真实组件与队列页窄宽/布局、刷新隔离/停动画、原队列59/元数据19/确认窗/标题与计数回归。非Kotlin/全UI/物理相机/真机功耗/VoiceOver，图层捕获不证明Metal模糊阴影像素。既有固定字体度量未全局更改。构建会话均已终态，最后48626退出0。旧证据共享文件哈希保留各自运行时点，不更新它们。

## 2026-10-28 队列清理和生成准入完成，整轮9/25继续中

active goal继续、非阻塞；本轮主任务独立完成N11，台账9/25，余16项，N08/N09/N10尚未完成。Android仍18145b3a且干净、iOS仍58d9b6ed；未提交/推送/安装，不动网站。Android新状态卡已详细读过（TransferQueuePresentation、TransferQueueStatusCards、QueueDownloadDisplay、GenerationQueueRows及部分测试），接下来继续状态卡/速度胶囊/进度收尾，再NP3等。

N11：beginClearQueue原子捕获非下载/非生成忙碌ID并撤回等待任务，finish只清此集合；真实UI协调器320ms后使用捕获集合，不再全局removeCleared。frameGenerationPendingCheck区分查重保护与已确认生成，isQueuedForFrameGeneration只在确认后用于计数/等待文字；未知名称或同来源正在生成保守等待，温内存名称可证明唯一来源缺失。完整目录/配方查重移动到串行生成工作线程，实际裁切/渲染才计时；命中成片直接skip；总开关关闭的离线重试快路径主动publish。原有removeCleared/clearFinished仅保留即时历史接口，不用于动画清理。

queue-admission-verification.json：78/78和80/80，两轮exit0；80不同方法、158通过，含真实清空协调器/确认窗、同源重复/异源温缓存、五种底层状态准备保护、关闭效果重试通知，及19项元数据/裁切流水线。非Kotlin/全UI/真机/性能验收。共享源码哈希记录测试时点，不倒改前批证据。构建会话69758和5095均已终态0。

N08等待生成顺序不能按UUID字符串排序：安卓Long是尝试/入队时序，iOS重试在旧历史位置替换，需要单调尝试序号或真实入队顺序，同时保留UUID业务身份。状态卡两张常驻首个滚动项，下载55%/生成45%，显示2行但全量计数；生成第三行预备、成功220ms/退出140ms/位移180ms，下载成功补满120ms+40ms停留，失败/取消不假补满。相关纯函数测试仍需完整读/移植并接入真实UI，不能只做模型标完成。/tmp/ztransfer-queue-screen-delta.patch为空（错误旧文件名），实际Android文件是TransferScreen.kt；不要依赖空patch。

## 2026-10-28 筛选评级增量完成，整轮8/25继续中

当前 active goal 持续推进，上一轮7/25和本轮均有实际源码/验证进展，非阻塞；N07已完成，总台账 docs/待做/iOS-20261028-安卓增量复刻.md 现8/25，剩余17项不可忽略或标整轮完成。再次pull Android返回Already up to date，仍18145b3a且干净；ios仍58d9b6ed，本批均未提交/推送/真机安装，网站并行文件不动。继续由主任务独立处理。

N07全运输共用PhotoRatingPlan，完整目录实际日/范围相交/未应用范围空总数/显式目录完成或足够已确认天数，不再STA独有；未知非法日期有限排除而全部保留，非评级格式日仍占边界。公历校验同安卓纯ASCII整数，不逐行构造Calendar。PhotoListViewModel扩大已截断范围前同步关完成状态，异步游标和快速再切范围不能锁定旧清单，末批范围变更同门禁；USB/AP也直接通知就绪边界。异步缓存读取间输入变化重规划，开读后固定清单；Set来源检查去平方复杂度，进度按文件，取消重开/旧回调保持。300pt筛选窗、154pt五星、其余自适应、34pt清除、6pt灯泡间距，日期页独立滚动树；清除关闭浮层并恢复全默认。

rating-verification.json保留4轮：首次私有夹具编译失败0方法；fixed 76/76；boundary 77方法其中1方法5断言失败，新测试遗漏canFill=true导致关闭通道；只修夹具后final 63/63。当前生产覆盖77不同方法；216执行215通过，不声称单批77全绿。四截图390/280宽×关闭/开启均已实看，父弹窗不随120进度更新重建、宿主连续性验证通过。实际宿主和受控目录/通道验证，非Kotlin执行/全UI/物理相机验收。PhotoRatingScanTests/ScanBatchPolicyTests最后一轮全过，其余14方法上轮通过且对应生产未变。历史报告共享源码哈希保留各自时点，不倒改旧报告。

后续从N08–N12队列块继续，再NP3/缩略图/预览等；已读取但未编辑下一块，Android净差异在/tmp/ztransfer-transfer-delta.patch、/tmp/ztransfer-queue-screen-delta.patch和/tmp/ztransfer-filelist-delta.patch。注意手机验证仍由用户操作，不自动安装/提交。蓝牙唤醒研究回滚及所有既定iOS差异保持。模型测试新加PhotoRatingScanInput必须显式传hasCompletedFileScan/appliedPhotoLoadingDays；测试PhotoListViewModel的canFill默认false，验证可用通道时必须主动true，不能把等通道误当生产挂起。

本批4个构建会话已终态（65/0/65/0）；B6确认Shutdown，FC8仍Booted未操作。当前源/7项Android依据/四图/四轮全日志及保留日志SHA全部复核，git diff --check通过。未重跑已经通过且未变化的其他专项。

## 2026-10-28 GPS 增量同步完成，整轮7/25继续中

本轮按 active goal 继续，前轮属于实际进展（源码、拉取及验证证据），非等待/空转。主任务独立完成N04/N05/N06；总台账 docs/待做/iOS-20261028-安卓增量复刻.md 当前7/25，其他18项尤其NP3完整链路/队列/筛选/缩略图/预览继续，不能结束整轮或缩小目标。Android仍18145b3a，检查时本地远端已一致且干净，未再次修改/提交Android。ios仍58d9b6ed，无新提交/推送/真机安装，网站并行修改保留。

N04倒计时立即同步接coordinator；canSyncNow逐状态且0坐标有效，后端再验持久化开启/AP/实际isRunning/认证ready/无GEO在途，用最新fix同步开始，重复点击不留后续强制写；成功ACK才更新时间/重排周期，新认证清lastWrite。同步拒绝回调不再遗留空10s定时器。N05明确主动开启+完整旧配对才预热定位30s，首次/恢复/后台重试不预热；认证前不缓存应用坐标或发布，认证后读CLLocationManager自己的两分钟内缓存。统一stopLocationUpdates取消预热，正常交接和八类停止测试。保留4.5s直连退扫描、15s扫描、7s握手、3sID；补旧配对服务发现/通知订阅15s，先退役再失败，所有清理取消旧期限。start不重开当前扫描；发现回调要求仍在扫描。客户端已有退役/对象身份/串行写门禁保持，主线程状态事件取消多余RunLoop派发，初始idle不当断连。CoreLocation频率精度档、外设UUID等既定iOS差异保持，无Classic bond冒充。

N06关闭时配对/频率/按钮权重0.60/1.08/1.18，启用0.82/0.86/1.18；频率允许拖动提示+档位selection，倒计时仍42pt可点，同步三语标签逐字资源且不再提示普通拨轮手势。GPS专用Genie80pt水平开口，公共新增参数默认仍27.2pt/tilt=true（以实际zMarkWidth常量为准）；开关320/350ms、反向/捕获保持，不改其他弹窗。两个实际控件浅色截图已看，字/按钮不遮挡；无灯泡呼吸恢复。

首轮 gps 日志编译失败0执行：漏补Debug GPSGestureAuditHarness.Bluetooth的isRunning；补齐所有conformer。gps-fixed实际64/64、TEST SUCCEEDED/exit0。随后仅读屏hint清空与新增实际宿主截图方法，gps-panel4/4（含3倒计时重复），合计68次成功/65不同方法，非单次全套。含真实生产coordinator/期限/回调与UIKit宿主，定位/蓝牙受控夹具；宽入口3锚点×2高×101进度×49截面端点/水平/保序及旧几何回归；倒计时叶观察、隐藏/后台/归零休眠验证。不是物理GPS/BLE/订阅注册/权限提示/VoiceOver/热状态/全UI验收。入口ios/docs/evidence/android-sync-20261028/gps-verification.json，三日志+两PNG+最新源码哈希。此前N01–N03/N21历史证据保留；DomainModelTests因本次新增GPS测试/协议stub变化，旧报告哈希是各自验证时刻，不能要求历史哈希与当前完整文件相同。

本批所有xcodebuild会话均已终态（首轮65，后两轮0），收尾无xcodebuild进程。B6确认Shutdown，关闭调用因已关闭返回405；FC8仍Booted未操作。git diff --check及GPS最终源码/两张已审截图SHA复核通过。下一步从N07筛选或N08–N12队列块继续；不重复已通过专项，除非新增相关修改。

## 2026-10-28 安卓新一轮增量同步进行中（4/25，尚未整体完成）

当前 active goal 是继续拉取并完整复刻 Android 新增功能、跳过已回滚内容并处理 iOS 对应性能问题，不能把此阶段通过当整轮结束。iOS 基线/HEAD 58d9b6ed，用户单独要求推送时 git push origin ios 返回 Everything up-to-date；本轮新改动均未提交/推送，无真机安装。主任务独立处理，不改网站并行文件或 Android 工作树。已重读长期规则。

首轮独立 Android 树 /Users/orys/code/nk_send-android 从7690172b至431132ca，18提交/166净变化文件哈希在 android-sync-20261028/android-source.json。蓝牙唤醒热点研究被dcc1bdda回滚，忽略；GPS立即同步保留。用户后来再次要求拉取，pull已最新，按先前授权包含本地新增eec5d6db、18145b3a；检查开始的4个dirty文件由Android侧随后提交，最终干净ahead2，新增20变化文件冻结android-source-addendum.json。新预览真实图像锚点/裁切/方向动画独列N25，NP3文档名/离线选择归N15/16、速度600ms归N09、缩略图首次180ms共用入场和共乘防重复解码归N22/23。台账 docs/待做/iOS-20261028-安卓增量复刻.md，现4/25（N01/N02/N03/N21）；其他21项继续做，尤其NP3导入/渲染/双入口/持久化、GPS、队列及缩略图等，不能漏。已移除品牌图形、内置相机NP3、监看端侧录制、灯泡呼吸继续不恢复；用户导入NP3照片滤镜是新范围，不能跳过。

N01两导出共用64项拍摄EXIF，保留原始数值精度。N21九槽实际读取、36/614字节空槽以基底0为准；可选/可写分离，只确认空槽可注册，已占用不可选不可覆盖；激活前复验枚举，回滚和双bank隔离。首轮40测试1失败（旧断言拒绝614空槽），另原编码器所属类选错未执行；改目标/断言并加组件准入后42/42成功。证据exif-slots-verification.json。

N02已有同照片元数据通过独立参数传裁切，不改配方存储、不请求手机定位或额外等待；原GPS有效优先原始字节，缺失回填并清不可靠旧海拔，保存后校验/失败清理/重试。初次36方法中1失败2精度断言，诊断重跑1方法14断言失败，均保留。独立Python TIFF解析证明保存原值33.868812345/151.209312345正确，ImageIO字典回读会舍入；现复用原TIFF reader校验原始有理数，测试独立解析保持1e-8，ImageIO显示另验1e-6。失败成片和crop-gps-raw-diagnostic.json已保留，非放宽原始精度。

N03纯地区映射按大陆/港澳/TW/国际语义，NFKC只做比较不改显示拼写；134安卓字面样例+63组合+1000仅输出输入名称不变量。缓存32LRU，成功24h/空15s/错误5s，不缓存取消/超时/不可用；实际请求跟随新版安卓3s，排队不消耗预算；原AP禁止/NWPath默认路径政策保持。CLGeocoder取消主动结束continuation，晚回调隔离。最终location-place批56/56、TEST SUCCEEDED/exit0，含实际JPEG/native裁切、队列两入口、取消清理、原字段、缓存/网络门禁实际导出；不是全UI、物理相机/文件provider/真实地理网络验收。最新production/test哈希与三次日志入口location-place-verification.json，收尾已逐项复核当前哈希及20项追加Android输入一致。Xcodegen已更新，所有专项进程结束；B6确认Shutdown（清理时已关闭），FC8仍Booted未操作。下一阶段须用当前树继续。当前无新增提交，App仍1.98。

## 2026-10-22 等宽边框、效果查重及提示框同步与整体复查

用户要求同步Android新功能，随后确认将尚未提交但已定稿的提示框改动一起纳入，并追加整体检查。Android从1f804ab8到7690172b（含8f64f803），pull已最新；另7修改+GlassHintSurface新文件，冻结20输入哈希，未写Android。独立完成同步7/7、追加复查4/4，台账docs/待做/iOS-20261022-等宽边框与效果查重同步.md。六模板信息栏不占位时四边同一ceil整数边距、原图1:1、固定1000×667参考；品牌画廊照片内信息保持。双入口canvas身份加uniform，普通220ms交叉渐变不变。equal-border-v=1、歧义AUTO/CENTER版本、实际已绘地点UTF16身份；旧无地点/颗粒配方仍兼容。预检/生成命中后独立skipFrameGeneration，保留效果名+灰色已跳过。确认500ms对比才holdConfirmed，按下/捏合不震；模块顺序滤镜/LUT/颗粒/边框/水印，位值1/2/16/4/8不变。提示公共壳去投影/材质模糊，原时序/位置/点击消费保留；端侧录制与Android常驻通知入口不新增，品牌图形/内置NP3/灯泡呼吸等已移除项不恢复。

首轮修正旧模板记忆误用于身份，现按实际渲染metadata；实际75/75+相邻14/14。追加审查又补3处：工作台漏传failed导致换布局失败旧图不回；公共可见性动画不等完成且隐藏曲线错误；初始过期canvas可闪出。真实组件基线1失败，下一次效果0.000370917秒接入；修后串行190ms FastOutSlowIn显示/110ms线性隐藏、首帧身份判定，49/49通过。三批138次成功执行、110个不同方法，不称单次全套。28行执行安卓标准几何oracle通过，6成片+队列确认1+监看4共11不同图已实看。证据ios/docs/evidence/uniform-border-20261022/verification.json。

保留此前3次夹具/参数编译失败0执行与初次32方法中2失败（14身份断言+1原有旋转时间采样）；旋转原断言重跑通过，未改生产旋转逻辑，不称偶发根因已修复。无真机相机/Photos提供者/震感/热状态验收，无全UI、Release/Archive、提交推送或真机安装，App版本仍1.98。未动网站并行修改与连接/下载协议。 专用B6已确认Shutdown（清理时已停止），FC8仍Booted未操作。


## 2026-10-21 胶片颗粒第三轮生命周期复查

用户要求再查一次，独立4/4完成。本轮仅改LocalPhotoBatchViewModel生产代码：工作台改颗粒时曾取消未完成的相同滤镜，只缓存完成图；现复用PhotoEffectsPreviewCache独立拥有滤镜任务，来源/滤镜/页面生命周期关闭它，颗粒/装饰/名字变化只取消旧完整帧等待者。安卓依据SettingsScreen3118–3134及LocalPhotoPreviewPager。另修本地完整帧新请求加入旧依赖取消任务时也失败的问题，按安卓只对加入旧任务的新请求重取自身依赖，真正取消/关闭及新计算自身取消仍传播。

grain-lifecycle-baseline 4项3过1失败，实测同一滤镜调用2次；修后同一断言1次。原样提取actor的dependency-baseline脚本exit1、fixed exit0，保留证据；另有XCTest相同取消交接回归。最终grain-lifecycle-fixed **43/43、0失败/跳过、TEST SUCCEEDED/exit0**，含新增5生命周期、22颗粒和相邻缓存/真实LUT批量。真实三图JPEG+身份冻结通过，权限/选图边界是受控夹具；未冒充系统Photos验收。18次旧帧释放仍过，24MP合成0.981秒仅Debug模拟器。入口ios/docs/evidence/film-grain-20261021/lifecycle-audit.json；前轮audit/verification旧哈希和失败记录保留。B6确认Shutdown，其他模拟器未操作。未真机安装/提交/推送，物理相机、Photos跨次名字、发热仍待设备验收。

## 2026-10-21 胶片颗粒第二轮功能与性能复查

用户追加要求仔细复查，独立完成4/4，未提交/安装真机。发现颗粒预览误用原图分块无插值绘制；独立“整图加颗粒后再正常缩放”对照基线3项2过1失败。现已降采样的预览整图处理并平滑缩放，原图仍有界分块，滤镜色板/原片背景/水印不污染。另将JPEG指纹逐字节文件读取改为8KiB缓冲，保留4MiB上限、取消、短读/截断处理，非法匹配身份立即拒绝与安卓一致。

最终grain-audit-fixed 39/39 TEST SUCCEEDED/exit0（22颗粒含本次新增6、7预览缓存、3本地缓存、5原图分块、2JPEG发布）；ASan+UBSan原生桥接通过，原核/vendor仍与安卓逐字节相同。连续18次1280×853源、1920边框预览123–402ms，关闭后旧帧弱引用全释放、gate待执行0；24MP合成1.027秒。均为Debug模拟器/主机，内存仅完成帧采样非瞬时峰值，不外推真机或编码/保存耗时。证据ios/docs/evidence/film-grain-20261021/audit.json，初次verification.json的旧哈希和失败记录保留。真实Photos提供者跨次源名、物理相机/热状态仍待设备验收。

## 2026-10-21 胶片颗粒同步安卓1f804ab8

用户要求拉取安卓并复刻胶片颗粒；独立Android工作树git pull --ff-only origin android已最新1f804ab8，源码未改。iOS起点7b9680ec，独立处理。台账docs/待做/iOS-20261021-胶片颗粒复刻.md开发侧6/6；细/中/粗50/40/30、0…100、各档记忆、双入口独立持久化、模块位16一次迁移、草稿/队列隔离、纯颗粒/滤镜/边框/水印合成与比较均接入。原核和FastNoiseLite1.1.1/许可与Android一致；原图分块和批内取消，颗粒只进照片，背景/色板/水印干净。按源名固定FNV种子，本地随机暂存名不参与；命名同步短后缀和APP15精确身份，旧长名只在无颗粒时兼容。1f804ab8效果图长按对比静默，轮盘触觉保留；不恢复已移除的品牌图形、相机内置NP3和监看端侧录制。

验证入口ios/docs/evidence/film-grain-20261021/verification.json：原样安卓原生oracle及RGBA桥接通过，46不同XCTest最终通过（分次，非单次46/46），6张实际控件三语深浅原图已逐张核看。保留第二次测试Swift6夹具编译失败0执行、第三次39项中队列夹具无目录导致1项2断言失败；仅修夹具所有权和隔离目录，生产门槛未放宽。收尾26/26、TEST SUCCEEDED。复查补全缓存请求名单种子、两拨轮公共Layout、实际byResource翻译；纯滤镜预览保留快速路径。最终Debug模拟器BUILD SUCCEEDED、MIT/第三方通知随包字节匹配，App仍1.98，未推进正式版本。不是全Release/Archive、全UI或物理相机验收，未真机安装/提交/推送；B6恢复关闭，FC8未操作。


## 2026-10-21 用户要求先提交代码，再核对入会前本人事项

已按用户要求提交当前全部代码、资源移除、相关网站/发布材料及证据到本地ios分支50bb581d（233文件），未推送；git diff --check通过，提交后干净。本轮核对不重复构建，沿用有范围限制的实际结果，不宣称全部发布就绪。最新具体操作表写入ios/docs/付费前最终核对-20261021.md：账号身份/2FA/本人付款；建议先补代表相机型号固件、15Plus系统、当前真机尤其NP3授权写入、可公开照片、硬件实拍、名称语言及版权事实。政策/客服/价格等已确认内容不再问。商店成图、字幕、材料同步由助手做；保留手机滤镜的源码/公开来源核查仍属助手事项，确缺原始凭据才问本人。

2026-10-21查Apple中文官方注册页：大陆个人在Developer App填身份、自拍、英文姓名地址；官网写¥688/年自动续订、会员费不接受Apple账户余额，最终以本人购买页为准，不能叫用户先充值余额。个人供应商显示法定姓名。本人未实际登录/身份验证/付款；注册条件不要求App、截图、演示全通过。中国大陆App备案与网站备案分开核对，欧盟DSA不能因个人就判非交易者；信息可先准备，后台核验/声明在会员后。没有重新更改素材范围、销售偏好或iPad方向。

## 2026-10-21 素材移除后经本人要求完成构建与专项测试（最新）

本人随后明确要求构建测试，因此接续第二阶段RV01–RV03，有限验证3/3完成，不能沿用下方源码阶段“不自动构建/未运行”的状态作为当前结果。新目录设备Release完整构建BUILD SUCCEEDED/exit0，CODE_SIGNING_ALLOWED=NO，实际1.98(1)包19文件，严格--submission通过，无相机NP3、原18SVG、旧目录/测试夹具；二进制SHA256 9a46272d58f5c9006fe6b8d6fde379dac66c2beee53fb1643d56d5b86b38e52c。模拟器采用Debug执行，不重复同源simulator Release，不称签名Archive或上传完成。

iPhone17/iOS26.5实际XCTest183/183、0失败/跳过，包括迁移6、模板/水印75、50滤镜Android像素oracle（一个方法）、NP3/目录/取消/backup/write rollback及2个PremiumBusiness图片水印真实导出重试。用户NP3无目录/用户目录/空目录3张实际组件图已审，无内置分类；不是系统文件provider授权或物理相机写入验收。初始4个不同UI方法均主体1/1且prepare/cleanup通过；审图相机品牌关闭仍见Nikon普通文字，原测试只等控件新label，没有等异步预览。测试侧新增有界Vision OCR等待（Z233存在且Nikon显隐连续两次匹配），保留原断言，同一相机方法额外1/1、prepare/cleanup均过，dk2U1l四张初次/重启off/text原图已由主任务实看：关闭仅Z233，开启普通文字Nikon Z233。确认此前是早截图，无生产缺陷/生产修复。计4不同UI、5次执行，不能记5不同用例或单次全套。旧图/观察和macOS Package UIKit失败0执行均保留历史。

入口ios/docs/iOS移除品牌图标与内置预设-20261021.md；最终证据ios/docs/evidence/asset-removal-validation-20261021.json及同名前缀目录。真实文件provider授权、物理相机写入及本轮真机未测；真实Apple沙盒、签名上传、全V01–V16未整体核销。保留手机滤镜来源/使用依据仍独立未核验，改名不等于原创，测试通过不解决素材权利。最终1102生产文件集合与摘要全部不变，175跟踪测试文件仅OCR测试侧变化；Android无diff。专用B6模拟器已恢复Shutdown，原FC8保持Booted未操作。未付款、提交推送或发布网站；原Android和保留滤镜生产行为不变。


## 2026-10-21 已移除 iOS 品牌图形与相机内置 NP3（最新决定）

用户明确要求移除iOS品牌Logo功能及对应档位、相机内置预设；随后明确只删相机内置预设、手机调色滤镜保留。这取代下方同日“先保留”调查决定，已授权平台差异，不再询问/自动复刻恢复。品牌只保留关闭↔普通文字，旧.logo构造/赋值/JSON/Android格式归一.text，其他设置和自定义图片水印保留。18SVG、专用Brand/Catalog/NikonGradients和渲染分支删除；22相机NP3+catalog/加载器/内置分类删除，测试目录相同22复制文件也删，测试用中性合成输入。用户文件夹、相机已有PC/写入/备份恢复/取消逻辑保留，空态用已有引导。Np3FilterCatalog/Engine/BitmapFilter字节不变，Android无改动。用户称滤镜改名后可说原创，已解释来源不因改名而改变，文案不写虚假原创；保留手机滤镜使用依据独立未核验，不能声称全部素材风险解除。

本轮源码与有限检查5/5，入口ios/docs/iOS移除品牌图标与内置预设-20261021.md及evidence/asset-removal-20261021.json。真实生产NP3源码macOS独立1113条断言过；品牌7个完整声明自动提取无改写，3类174断言过；合成包4测试/25场景过；Swift语法parse和工程plist检查过。以上不是全量XCTest/新Release/真实UI。完整Swift Package因既有UIKit无条件导入用于macOS失败，0项执行，失败保留；未造桩，不说iOS已编译失败或已通过。下次明确构建节点复验新包禁入、品牌迁移/图片水印、NP3文件夹及实机写入。按约定本轮不自动App构建安装，无提交推送发布。旧包/截图含已删功能保持历史，不能用作新包排除证据。

## 2026-10-21 预设与品牌公开许可调查（保留全部功能）

本人最新要求先查清相机预设/品牌标志授权，能直接用的保留、本人事项列出、先别删功能。本轮只查公开来源和当前使用方式，不修改生产代码、资源、显隐、颜色或导出，不发邮件/评论/表单，不构建/安装/提交/推送/部署；不得把这次调查解释成移除或改成纯文字的授权。

22份NP3的下载来源均已闭环但实际作者/许可未全部确认：phpstone原ZIP的5份逐字节匹配，PORTRAIT-02/03不再是来源不明，原文称人像自制，优先请Chris确认；3份风光请Links确认具体文件作者。NikonPC17项现行参数和原257点LUT匹配，响应无作者/许可字段，不能把编辑器代码开源当社区预设许可。已准备Chris公众号etmile、Links公开工作邮箱、NikonPC support三组询问稿及精确附件，未发出。

17品牌18 SVG均核对官方规则/联系入口，尚未找到覆盖含内购App内置、EXIF标注、照片导出及当前颜色的完整公开许可；这是证据未闭环，不是全部侵权认定，也不意味着普通品牌名一律要买授权。Apple/DJI/Google部分文字场景有条件规则，不能扩大为图形许可。Simple Icons固定commit c71c69e3a27e4436936b831c72643e6513b9f49b的新metadata在data/，17条均无license、9条guidelines；项目CC0不等于每图标许可更不授予商标权。Google G现行渐变全彩与本地单色差异、HONOR合同/版本/留白、Samsung颜色要求单独列出，未经后续确认不改实现。OnePlus官方ZIP20素材已读取，无单独许可文档；不再保留“包未读取”的旧缺口。

入口ios/docs/素材来源与授权核对.md，预设/品牌两份20261021详细调查、授权询问附件及evidence/asset-rights-research-20261021.json；调查前后44项素材/目录/渲染/工程输入SHA-256一致。当前调查完成不等于素材权利完成；收到具体许可或实际使用依据后再核范围和必要条件。先前付费前核对/材料分工已同步最新保留决定，不再让本人盲查两研究样本来源或重复找站点。

## 2026-10-21 付费前再次核对与新包法律入口（最新）

用户看到官网入口后要求再次核对付费前全部准备。本轮沿用已确认决定，不再询问QQ/AI翻译/EULA/受众/生效日/托管。双平台Release以当前1150项生产输入串行增量构建，输入前后及UI后相同；Xcode27.1、SDK27.1，普通与--submission均通过，两真实URL随包。与前一同行版仅Info.plist和project.yml两输入不同。主任务已再次核对两包二进制摘要与记录一致。旧DerivedData产品路径已更新，旧报告保持历史。

iOS26.5标准iPhone普通启动新Release，设置/购买4次法律入口及English网页切换实际完整地址和标题均通过；三尺寸（标准iPhone、15Plus、13英寸iPad）设置参考图及开关分次通过，主任务3张均实看。iPad只覆盖当前竖屏全尺寸，不外推更窄窗口、其他语言或系统。首轮Safari首次提示挡地址栏致临时测试失败，修正runner后只补跑网页通过；后续2个xcodebuild实际TEST EXECUTE SUCCEEDED/exit0，被外层仅识别TEST SUCCEEDED的脚本误报false与exit1，必须保留并解释。未改App业务/动画、未重跑已通过设置，未因此声称旧iPad/HD间歇原因修复。

六个政策页本轮正常TLS GET200且匹配发布文件；网站无需重部署。源码配置、当前网站、App实点均有证据，但正式商品、年费/永久真实UI、签名Archive、真实沙盒和上传仍未做。22份NP3（20可选+2研究）与18品牌SVG使用依据、本人可公开照片、代表相机/系统/硬件演示及少量商店事实仍待本人；建议先明确素材路线与代表实机，再按节奏入会，不能倒置会员后结果为付费前提。正式商店套图ready仍0，旧原图保留，新设置图单独采集。

当前交接入口ios/docs/付费前最终核对-20261021.md，构建/运行ios/docs/evidence/prepayment-ready-recheck-20261021.json，公网prepayment-policy-recheck-20261021.json。已清理README、13步手册、材料分工、隐私问卷、商店/审核内部记录等过时状态，英文商店描述与Notes正文不变。无付款、真机安装、源码提交/推送或再次网站发布。本次有限核对完成不等于V01–V16整体或整个发布流程完成；最低16运行时、系统27、全部字号/窗口/真实硬件不外推。

## 2026-10-21 政策正式发布与法律URL接入（最新）

用户已确认当前不把客服内容发送第三方AI/在线翻译、一般摄影非儿童专门定位、Apple标准EULA加补充说明，并明确授权补齐后发布。原14处正文标记清零，日期为实际首次发布2026-10-21，QQ沿用既有官网/App公开的953000922。正式家庭共享核查保留在会员后清单，不再阻挡网站。补充无独立App账户及效果图可能保留GPS位置。六个中英页面与原首页合并，官网yuui226/ztransfer-site master提交3d138907edde01603e2ae57bf19a87ec37bc143d已built；HTTPS/16项公网哈希检查、14个本地手机状态与导航通过，4截图已实际核看。project.yml和Info.plist已填https://www.ztransfer.top/ios/privacy/及/ios/terms/；pbxproj原本正确引用，无Swift改动。未构建/安装，不冒称旧包自动启用或App实点已验收；下次候选包验证。详见ios/docs/iOS协议页定稿与发布记录-20261021.md；下方早先草稿、HTTPS未启用、URL为空记录均为历史，不再重复询问已确认决定。

## 2026-10-21 域名备案通过，官网仍用 GitHub Pages（最新决定）

本人随后纠正：官网与后端本来已分开，配置已完成，api.ztransfer.top指向后端。以后直接沿用既有分离架构，不再说需要将官网与后端拆分或API仍待指向；旧迁移计划不能覆盖本人这条最新事实。本轮只追加官网iOS页面，不动DNS、后端或授权服务；早先Pages/HTTPS查询只保留当时快照，不扩展为当前后端验收结论。

本人确认ztransfer.top备案已通过，提供根site/为官网源；再次明确继续GitHub Pages，并授权“开始本地接入，定稿后再发布”。这取代旧运维文档中官网/root/www迁腾讯云的决定，API/授权服务目标和执行状态不由本轮改变。不要再索取网站仓库或新建仓库：只读已确认yuui226/ztransfer-site，master根目录、Custom domain=www.ztransfer.top、status=built、https_enforced=false、https_certificate=null，三文件Git blob与本地site/完全一致。不能将备案通过或built当作HTTPS及iOS政策上线。

ios/docs/site/build.mjs新增--website生成website-preview/website-dist，复用原安卓首页、CNAME、icon，仅输出首页追加iOS三链接，六个中英页面保持/ios/路径、样式隔离ios/assets。原site源不写，输出目录gitignored；14处待填标记在正式输出变更前阻断。仅本地预览已经生成，未推送/部署/改DNS或Pages/申请证书，未构建App。iOS中英文隐私正文如实补充原官网本地展示动画脚本，未新增统计、后端或第三方脚本。

本地Chromium HTTP的7页×浅深色=14手机状态与首页→中文隐私→英文→原官网流程通过，4截图已实际核看；静态链接及正式阻断证据见ios/docs/evidence/website-integration-20261021.json。用户后续询问GitHub与腾讯云利弊：当前静态官网选GitHub可避免官网流量经过业务服务器，但GitHub/域名账号和云上授权接口仍独立防护；不承诺绝对安全或所有地区可达。正式内容、HTTPS/域名访问与App法律配置仍需后续接续。

## 2026-10-21 付费前复核收尾与设置法律入口（当前）

本人已批准设置常驻法律入口，并明确要求名字简化、在反馈左边同一行。最终顺序为版本号、弹性空白、隐私、条款、反馈；繁中隱私/條款，英文Privacy/Terms。不得恢复另起一行或重复索取批准。购买页保留完整法律名称，两处共用有效HTTPS配置，独立于权益；URL空时可见但禁用，真实网页尚未发布接入。

当前SettingsView用ViewThatFits横向选择原间距或紧凑横向留白；小屏仅减横向间隔和版本/法律按钮内边距，保留完整文字/字号/按钮高度与反馈、Debug版本动作。最外层minWidth0/maxWidth∞防止自然宽度撑大既有面板。Android依据仍为SettingsScreen原版本—空白—反馈行；新增法律入口及位置属于本人明确授权的平台差异。最终SE第3代iOS26.5简中/英文/繁中同行专项1/1、TEST SUCCEEDED、exit0，3张原图已由主任务和独立复核逐张查看，英文版本/按钮均完整、面板边距正常。法律配置/路由/三语单元3/3此前通过且路由未改。历史英文折行、面板外扩和AX整铭牌测试误判均保存；iPad三语言同行/关闭只在中间版本通过，最终窄屏收紧未重跑iPad，不冒充当前全尺寸验收。旧清洁Release iPad关闭失败的根因仍未证实。

最终模拟器及无签名设备Release均BUILD SUCCEEDED/exit0，普通打包检查通过，1150项输入前后一致；严格模式仅因两个法律URL缺失返回1。见ios/docs/evidence/release-prepayment-inline-20261021.json。先前入口前/两行阶段报告保留历史哈希，复用DerivedData的产品路径现已指向同行版，不把旧包等同当前。旧6张商店候选保留，其中3张设置图已注明落后于入口变化，公开URL与候选确定后刷新；不将Debug诊断图当正式套图。

本轮材料已修正文英同站链接和GitHub项目路径，补审核外部服务、地区及测试附件，明确AI客服保护与必要许可。7页14处待填标记、49本地引用/6锚点、98两种挂载解析通过，Notes3611字节；正式生成按预期阻断，未部署。隐私不替Apple披露Apple自身采集，两条CLGeocoder路径仍保留说明；实际22份NP3（20可选+2研究）与18个品牌SVG仍需权利依据或替换决定。字体通知仅修正OFL所在文件的说明。--submission的11项配置验证留有证据，不等于真实URL可访问。

HD150ms原方法本轮普通/HD1/1通过，未改算法/断言/门槛，历史间歇失败根因仍开放，不宣称已修复或真机性能完成。iPad普通页保留本人已确认竖屏结构；945×1260浮窗只是有限内容可达证据，更窄窗口/最低16/系统27/全字号/实体设备不外推。当前四类复核交接和本人8组信息/会员后13步都集中在ios/docs/付费前准备执行记录.md顶部。本轮未支付、部署、真机安装、上传、追加提交或推送；专用SE/标准iPhone/iPad模拟器已恢复关闭。现有资料和账号条件取得后继续，不无故重跑已通过相同全套。

## 2026-10-21 监看布局、连续描边与新照片缩略图

用户明确要求：反挤压切到底部控件时返回仍在整个横向监看画布右上，回看不能盖住DISP；允许重排。导航与控制区解耦，回看+快门与DISP+旋转分排，至少8pt间距；不得按安卓原有随controls下移/重叠的几何恢复。按用户要求普通取景器加入1pt连续圆角内描边，录像2pt红线保留，单次裁切共用轮廓；原生220ms旋转、Dock280ms与端侧录制豁免继续有效。

另确认Android9d7f15a4的ThumbnailFillQueue新增入口不检查历史范围，而iOS错误地用旧范围上界拒绝新拍日期。现在实时新增及监看返回真正新增差集走统一范围豁免，暂停、失败外部重试和本会话重扫保留，删除/句柄复用撤销；首次扫描和扩大范围发现的历史对象不豁免。仍保留历史元数据扫描/显示筛选、STA顺序和相机前台独占，不增加轮询。真实新照片拍摄需用户验收。

台账docs/待做/iOS-20261021-反挤压监看布局.md开发侧5/5；本轮34个不同专项最终有通过证据，来自分次运行，不能写成单次34/34。layout-first21项20过1失败（方形布局未贴底），thumbnail-baseline1失败（旧范围漏新图），layout-thumbnail-fixed28项26过2失败（新夹具默认canFill=false），thumbnail-model-final修正夹具后6/6 TEST SUCCEEDED；完整路径/截图/限制见台账。5张最终实际组件布局、4张边框原图已核看，16种边框像素组合通过。昨日HD连续帧150ms检查仍开放。仅read-only截取原手机画面，无真机安装、提交、推送；期间外部ios/docs/site与上架文案修改保持。

## 2026-10-21 本轮付费前准备交接

按用户要求先提交的97cdc0be已完成（116文件、未推送）；之后修复未追加提交。预览旧帧/重复等待、紧凑GPS、英文无线反馈及完整水印输入框可见性已按下方Android依据取得对应专项证据。冻结后模拟器与无签名设备Release均BUILD SUCCEEDED、随包检查通过，1150项输入前后及交付复核一致；法律URL仍为空，设备方向及既有编译警告保留，不等于签名Archive/Apple上传验证。3尺寸首页/设置共6张清洁Release candidate图与1024图标已交付，核心相机素材及正式商品图仍待本人条件。

iPad普通页面按用户决定保持竖屏，不新增方向或全屏配置。iPadOS26.5/13英寸实得945×1260浮窗的首页、帮助末尾、设置底部及恢复接近全屏专项通过；原约70%窄窗口两次未达的失败保留。App.frame仍为1032×1376，不能把系统浮窗呈现当作内部连续重排或全部窗口适配证据。仅限定范围交接；系统27、最低16运行时、全字号和实机不外推。本轮结果/修改汇总及本人操作顺序集中在ios/docs/付费前准备执行记录.md，五项有限清单为四项完成、一项按实际覆盖交接；不是全部发布流程完成。没有新变化时不重跑相同全套，本人资料/网页和账号阶段按原13步手册继续。

## 2026-10-21 上架准备：水印输入框完整焦点可见性（组件及SE工作台专项通过）

SE实际文字输入/重启持久化khDfCu用例1/1通过，但逐张查看键盘图发现34pt输入框下边缘被建议栏覆盖约9.5pt；文字与光标仍可见。XCUI报告的keyboard.frame仅主键区（y451），不含约y407.5开始的建议栏，原相交断言不能证明整个控件无遮挡。依据Android `SettingsScreen.kt:2865–2967` 的WatermarkTextField聚焦后等一帧、延迟180ms、对整个34dp控件bringIntoView，本次在两个现有入口共用的PhotoEffectsControls输入框背景安装无交互UIKit探针，按相同时序向最近原有UIScrollView请求完整控件可见，利用keyboardLayoutGuide计算实际遮挡；不改宿主safearea、尺寸、文案、键盘退出和各自持久化作用域。失焦、场景非active、卸载取消待执行请求，同值更新不重启。生产改动限PhotoEffectsEditorView.swift，既有ConflatedPreviewUpdatesTests.swift新增2项局部滚动/取消测试。首轮构建因局部focused字段与UIView属性重名失败、0项执行，改为focusRequested；夹具补显式MainActor。随后`card-keyboard-fixed`合并专项6项5过1失败：AP4与键盘取消通过，整框用例仅偏移预期9.5与UIKit 3x舍入后9.6666667不符，完整34pt边界及延迟断言均未失败。主任务仅将偏移期望按screen.scale舍入，单项补验与SE实际键盘图仍待结果，不能记6/6同轮通过或缺陷已验收。完整历史保留在`ios/docs/evidence/photo-permission-recovery-20261021.json`及模拟器逐页索引。

单项补验`/tmp/ztransfer-prelaunch-keyboard-pixel-alignment.log/.xcresult`最终1/1、0失败、TEST SUCCEEDED/exit0，仅校准测试的屏幕像素舍入预期，完整框边界与时序断言保持。加上前轮取消用例，2个不同键盘组件用例均有最终通过证据；连同AP4个是6个不同用例最终通过，不能改写前轮合并运行5/6的失败终态。SE实际键盘图及真实keyboardLayoutGuide/宿主滚动范围仍待验证。

最终真实SE工作台文字专项q8FirM及cleanup各1/1、0失败、TEST SUCCEEDED；3张原图已全部打开核看。键盘图完整34pt输入框的下圆角和边框已露出，底边约814px（407pt），建议栏约815px（407.5pt）开始，属于紧贴边界，不再有原约9.5pt遮挡；不用AX主键区frame代替此核看。编辑后/重启后均为UI PRO TEST、Simple、Size71%、Opacity63%、Frame left、Adaptive、Shadow，原输入、退出及持久化断言通过。日志、cleanup、3图及冻结源码SHA-256记录在权限证据JSON的keyboardFlow.finalUI。两个入口共用该修复，但此次真实键盘UI仅工作台，不声称相机设置路径也刚复跑；其他输入法、硬件/浮动键盘、全尺寸和真机仍不外推。

## 已确认的平台差异：iPad 普通页面保持竖屏结构

2026-10-21用户明确回复“我们暂时只支持竖屏，调整大小后也是竖屏布局”。据此保留现有iPad普通页面竖屏方向声明，不添加横屏/倒置竖屏，不移除iPad支持；系统允许缩放窗口时继续使用竖向页面结构，并按实际窗口可用宽高检查内容可达性。此决定不承诺禁止新版iPadOS调整窗口，不影响监看画面内部已批准的旋转交互。有限窗口验证及无签名设备Release结果记录在`ios/docs/发布包静态检查说明.md`与既有上架进度文档，不能用方向配置存在推断全部窗口验收通过。

## 2026-10-21 上架准备：英文无线卡内容溢出修复（组件及三语言页面专项通过）

SE英文GPS截图连续三张实际显示Wi‑Fi标题被挤到卡顶、独立徽章压到STA标签、AP帮助灯泡出卡；根因是iOS将AP步骤与反馈叠放，而Android `HomeScreen.kt` 的实际无线调用设 `feedbackFollowsModeSelector=true`，两者在固定剩余高度槽内互斥。现按该实现共用真实弹性槽，保留卡高/徽章/GPS和footer，反馈入场220ms/延迟50ms、退场130ms及原曲线；AP错误橙色、重连忙碌、识别蓝色且350ms后才出现，复用既有Material3圆进度。iOS AP `.connecting` 的映射已由 `ConnectionViewModel.beginWiFiConnection` 注释和调用确认；单次延迟随状态、后台、卸载取消，不改协议。STA只有失败替换步骤，进度仍仅更新按钮。

`/tmp/ztransfer-prelaunch-card-keyboard-fixed.log` 中 `ConnectionMethodCardLayoutTests` 实际4/4、0失败，16张AP/STA组件原图已逐张核看；同轮包含键盘夹具的6项整体仍为 `TEST FAILED`/exit65，不能写该轮全绿。保留此前两次Swift 6夹具编译失败及首次执行3失败/1通过（161.5pt在3x设备像素对齐、帮助半像素边界、titanium遮罩内找不到原生标签）；修正仅限测试夹具。AP使用titanium、STA使用liquidGlass检查实际标签宿主，长错误正文按Android最多3行+省略号保留。随后 `/tmp/ztransfer-prelaunch-gps-ap-final-ui.log` 的SE三语言普通页面补验1/1、0失败、`TEST SUCCEEDED`/exit0，各语言两轮GPS开合，9张整页原图全部查看：AP反馈独占槽位，旧英文标题/徽章/帮助溢出未复发，完整GPS面板/顶栏/工作台原断言保持通过。记录与源码、25张本轮图片SHA-256在 `ios/docs/evidence/wireless-card-layout-20261021.json`；历史9张组件图和原GPS失败证据保留。此项不外推全尺寸/主题/状态、实体相机或商店截图，L02其他范围仍以逐页索引为准。

## 已确认的平台差异：监看原生旋转转场

2026-10-20用户明确允许监看旋转采用iOS原生、高性能的布局动画，要求避免先闪烁、再转向。可以用原生合成的连续旋转与旧画面淡出替代安卓先淡到零再换布局；仍保留原220ms总时长、方向稳定判断、锁定/编辑/回看准入和最新方向请求收合。后续对齐不得擅自恢复整页先隐藏的闪烁过程。旋转/锁定固定按钮按安卓主题使用区别于普通工具的底色。具体实施及验证见 `docs/待做/iOS-20261020-监看动画与效果模块菜单.md`，该约定本身不代表开发和实机验收已完成。

## 2026-10-20 上架准备：本地内购收敛

独立原生 StoreKit 诊断已证明刚完成交易短时可能不出现在 currentEntitlements；沿用此前接受短暂同步延迟的要求，本次仅在首次空快照或既有商品消失时等待 1 秒复查一次，再按权威快照发布，不持久化授权、不自动同步、不无限重试。revision 或停止状态变更阻止旧结果发布。另修正本地测试补款驱动：真实 grace/retrying 状态已确认而测试专属 hasPurchaseIssue 仍为 false 时，直接对该交易调用 Apple resolve 接口，不提前关闭重试。原免费锁定、到期、恢复和庆祝断言保持。

完整回归 `/tmp/ztransfer-prelaunch-storekit-confirmation.log` 为 17/17；新增空测试账户撤权 `/tmp/ztransfer-prelaunch-empty-account.log` 为 1/1，均 TEST SUCCEEDED/exit0，合计 18 个不同集成用例最终通过。历史失败记录保留在 ios/docs/付费前准备执行记录.md；不等于真实沙盒、账户切换、购买 UI 或全部上架准备完成。此次未安装真机、提交或推送。

## 2026-10-20—21 上架准备：效果预览旧帧修复（组件及完整Logo选图专项通过）

对照 Android `SettingsScreen.kt` 的 `collectPhotoEffectsPreviewTransitions`：普通新帧保持旧图并以220ms渐入，画布替换先110ms淡出再190ms恢复，比较图补齐不重播。真实宿主日志 `/tmp/ztransfer-prelaunch-frame-events.log` 已证实 iOS `onChange` 收到新UIImage身份，内部无参 `enqueue()` 却读取捕获旧self的图片；现改为比较完整Update并直接传递回调新值，保留原身份/画布/恢复序号/失败判等及动画规则。另 `/tmp/ztransfer-prelaunch-cover-baseline.log` 已独立复现：新帧准备后系统全屏遮盖确实取消任务，返回500ms后仍为旧红帧（blue=0/red=255，1项2像素断言失败、TEST FAILED/exit65）；原因是取消遗留outgoing与透明的新帧。现重现页面时无动画清除outgoing并恢复incomingOpacity，再续收最新输入。测试先等待真实取消，不能以UIKit present completion推断SwiftUI onDisappear已同步执行；临时逐事件日志及预览请求日志已移除，仅保留DEBUG精确取消边界测试钩子。最终 `/tmp/ztransfer-prelaunch-frame-final.log` 为5/5、0失败、TEST SUCCEEDED/exit0，覆盖普通新帧实际像素、全屏遮盖期间换帧、准备渐入时取消后的恢复及队列收合/取消；证据 `ios/docs/evidence/preview-frame-recovery-20261020.json` 保留失败基线和首轮夹具同步错误。

2026-10-21完整相机设置Logo专项 `testPurchasedCameraImportsImageWatermarkAndKeepsItAfterCancelAndRelaunch` 在iPhone13 mini模拟器fsW8DM运行1/1、0失败、TEST SUCCEEDED，cleanup亦1/1通过。7张原图已分工逐张核看：系统Photos选择器、成功导入后未关闭编辑器即重启保留Logo、取消更换后的控件与完整预览、额外500ms预览、最终重启控件及完整预览；更改后Size75%/Opacity67%/Photo center保持，取消/500ms后/重启的3张完整预览均Logo在照片中央。完整log/result路径、7图SHA-256及分工范围已存上述JSON的fullFlow。此前VQpttT失败为购买Lifetime按钮`tapWhenStable`10秒未稳定，尚未点击购买或进入选图，不能视为预览复发；主任务看过失败图按钮可见，仅加失败采样、未放宽断言，关闭5台闲置自有模拟器后重试通过，但不能据此认定失败原因。该证据覆盖本地StoreKit与模拟相机图库的完整UI流程，不等于实体相机、真实Apple沙盒或所有设备/状态验收；进度继续记入 `ios/docs/付费前准备执行记录.md`。

## 已确认的平台差异：移除无线设置跳转

2026-10-20 上架准备检查发现 Wi‑Fi/个人热点采用未公开 `App-Prefs` 路径，用户明确回复“那就去掉这个按钮”。据此移除首页 AP 的 Wi‑Fi 设置按钮、STA 热点齿轮，以及离线 AP 空态的同类入口；照片/队列 AP 信号胶囊与 USB/STA 一样只显示状态，不跳转、不响应点击。保留帮助灯泡、STA 配对重置与实际重连、GPS 权限提示的公开 App 设置入口。该差异以后不得按安卓同名按钮自动补回。

已核对 Android `HomeScreen.kt` 的两个系统设置按钮及 iOS 全部 `CameraWirelessSettings` 引用。此次只去掉入口与无用回调，保留提示、现有呼吸时序和信号布局尺寸。专项验证记录在 `ios/docs/付费前准备执行记录.md`；`/tmp/ztransfer-prelaunch-remove-settings.log` 的 5 项模型＋1 项真实顶栏交互共 6/6 通过、TEST SUCCEEDED/exit0，离线列表截图已看；不外推首页新布局与全部尺寸通过。未安装真机、提交或推送。

## 已确认的平台差异：小屏连接页预留 GPS 展开空间

2026-10-20用户否决 GPS 面板新增内部滚动，指定空间不足时减少连接页上方留白，将两张连接卡和 GPS 一起上移；空间足够保持原布局，工作台位置不变。必须在连接页初次布局时完成预留，不能打开 GPS 后再跳位。依据 Android `HomeScreen.kt` 的56dp顶栏、比例留白、固定底部入口及 `SettingsScreen.kt` 的 GPS 自然高度溢出层，首轮沿用原56pt顶部预留/310pt卡片/44+18pt工作台尺寸；复用同一已挂载 GPS 面板同步自然测量，首选8pt底部间距，不重复挂载内容树、不新增尺寸状态回传、不改 GPS 内容与动画。首轮 `/tmp/ztransfer-prelaunch-gps-layout-model.log` 的8项连接/几何与2项真实宿主回归共10/10、0失败、TEST SUCCEEDED/exit0，确认当时几何规则、GPS细节隔离、原生呼吸及面板同一宿主反向开合；不代表后续紧凑规则已验证。具体依据、历史失败及待验证项在 `ios/docs/模拟器逐页执行索引.md`，不因此关闭 L02。

2026-10-21后续实际UI：`/tmp/ztransfer-prelaunch-final-navigation.log` 为失败终态exit65；帮助/设置及GPS简中/繁中各两轮通过，英文首轮操作按钮608.5pt仍超过工作台605pt。完整GPS面板另含10pt底部留白，不能只检查按钮。固定顶栏实际下界6+36=42pt，USB卡原1.04呼吸向上伸出5pt，卡顶至少47pt才不相交；英文完整面板要求卡顶≤42.5pt，单独把56改42的试改因此撤回。现按已批准的“回收上方留白”进一步回收顶栏最多6pt空白：同次四子视图Layout统一放置顶栏、双卡与GPS，顶栏top=min(6,max(0,cardsTop−36−5−1))，按钮仍36pt且在安全区内；极紧凑卡顶42/顶栏top0，峰值呼吸后顶边37与顶栏底36间隔1pt，已测英文完整面板理论底604.5≤工作台605。空间足够继续原顶栏6pt和原比例位置；8pt底部间距为首选，紧凑时可消耗。没有缩字体/卡高、改变呼吸、移动工作台或增加滚动。

最终 `/tmp/ztransfer-prelaunch-gps-final-model.log` 为10项模型/几何＋2项真实宿主共12/12通过；`/tmp/ztransfer-prelaunch-gps-final-ui.log` 和同名 `.xcresult` 的SE三语言各两轮GPS开关专项1/1通过，均TEST SUCCEEDED/exit0。严格断言覆盖完整面板底边、36pt顶栏可点及开合前后的顶栏/GPS/工作台位置不跳，未放宽底部边界。`/tmp/ztransfer-prelaunch-gps-final-ui-images/manifest.json` 的简中/繁中6张原图已逐张查看：面板完整、与工作台有间隔、顶栏无遮挡；主任务核看另3张英文图。首轮帮助/设置底部专项1/1亦通过，3张截图由主任务核看，但同轮旧GPS英文失败仍按exit65保留。当前仅核销SE默认字号这三个语言的GPS重叠缺陷与所列交互，空间充分设备只有模型覆盖，其他GPS状态/字体/窗口和整个L02仍不能据此记为全通过。

## 已确认的平台差异：监看端侧录制

2026-10-18用户明确指定：**iOS暂不提供监看界面的端侧录制功能，这是允许的差异，后续检查发现与安卓不一致时不要补齐。**

- 端侧录制指在iPhone上将监看画面录制并保存为视频；相关录制入口、录制器、麦克风采集/权限及专属权益说明均不恢复。
- 此决定独立于安卓当前是否提供该功能；以后安卓新增或恢复端侧录制，也不得自动复刻到iOS、列为待补缺口或扣减复刻完成度。
- 相机自身录像控制、录像状态/计时和音频电平监看不属于此豁免，继续保留并按安卓基准维护。
- 历史实现、旧测试和旧完成记录只作历史证据，不构成恢复功能的依据；仅在用户后续明确要求恢复时再调整范围。

## 已确认的平台差异：队列确认窗

2026-10-20用户明确指定：清空与重试按钮保持各自位置，确认窗独立覆盖展开，不能挤动另一按钮；取消播放反向动画，确认后弹窗与对应按钮共同淡出。安卓 ConfirmFab 目前采用 Column 占位、清空确认卡会把重试按钮推高，**此处按用户要求保留 iOS 固定占位差异，后续对齐不要恢复推挤行为**。任务清空/重试准入、活动传输保护和任务收合时序仍按安卓。

## 当前任务范围（用户于2026-10-16明确调整）

- 2026-10-20用户要求先提交再修监看五项：上一轮顶栏信号/队列确认窗已独立提交7f6ed96f，未混入并行上架准备。主代理按Android25860ae6完成docs/待做/iOS-20261020-监看动画与效果模块菜单.md的5/5开发侧：统一可插值比例消除反挤压临时黑带；固定旋转/锁定底色区分，采用用户批准的原生220ms连续旋转；对焦短臂圆角和缩放补偿；回看单个全屏合成遮罩；双入口Android Tune/紧凑FilterChip模块菜单。对应几何/中间像素/三方向真实交互、回看安全区、双作用域LUT及菜单专项通过，最终截图已看、矢量可重复生成。**整轮43个不同专项为42通过、1未通过，不能写成全绿**：HD+RGB直方图/波形连续换色在150ms检查点仍偶发显示上一帧；更低开销取图和无新增宿主对照仍失败，既有分析链路在并发负载下直接调用较慢，但未定位到具体函数，不等同证明无回归或真机帧率。该项保留开放，详见台账全部失败记录；未改解码/分析产品策略或降低测试门槛。最终monitor-final为15/16、0跳过、runtimeWarnings空，临时分析探针已移除。未装机/追加提交/推送，独立上架准备修改保持；真实相机与长时功耗仍待验。

- 2026-10-20用户要求清空/重试按钮保持固定、确认窗独立覆盖、取消反向收回、确认与按钮共同淡出。主代理独立对照Android25860ae6，完成docs/待做/iOS-20261020-队列确认窗固定按钮.md的3/3开发侧。修复rowAbove混用局部/绝对坐标导致动画偏移一整块面板高度及交接跳变；旧反射测试复制同样错误公式，已纠正并增加实际展开/收回端点断言。采用真实透明固定槽位、零占位覆盖Layout、原生同次布局计算按钮锚点；确认共享原350ms关闭进度淡出，冻结启用外观，零点完成退场，避免第二次闪回，重试立即失败仍可重新操作。最终queue-confirm-verified为18/18、0失败/跳过、TEST SUCCEEDED/exit0（8模型、1实际组件几何/像素、9真实交互）；包括固定位置、反向/双击、同步淡出/无闪回、任务变化保护。全部失败迭代及错误测试预期保留记录，最终UI与组件截图已看、6份源指纹一致、diff通过、构建测试结束。未装机/真机操作验收/提交/推送，既有信号修复与同时发生的连接入口/StoreKit/工程/ios/docs外部改动保留。

- 2026-10-20用户反馈照片顶栏信号偶发居中，主代理独立读取iPhone15Plus截图确认离线信号居中、筛选挤到右侧；按Android25860ae6定位为离线NativeAttentionHost接受剩余宽度而外层未固定。CameraSignalControl最外层固定既有40×36占位，复用原尺寸常量，照片/队列共同修复；呼吸550ms/1→1.09、强调、命中和USB/STA禁点保持。同类评级宿主已有固定尺寸、连接卡片按设计满宽，不改公共宿主契约。docs/待做/iOS-20261020-照片顶栏信号按钮定位.md为2/2开发侧；修复前模型及真实UI均失败，修后8模型组件与既有非空队列/监看UI通过，新增UI的空队列隐藏胶囊错误预期纠正后补验1/1、TEST SUCCEEDED/exit0，合计10不同专项最终通过。覆盖3模式×5主题×3屏宽×在线离线重连135组合，最终列表/空队列/重连截图已查看。测试及诊断进程结束、diff通过；仅读取真机旧包截图，未安装/操作真机/提交/推送，P34/C02与ios/docs外部文件保持。

- 2026-10-20用户要求再次复查监看，再检查照片效果/工作台LUT；主代理独立按Android25860ae6完成docs/待做/iOS-20261020-LUT三入口复核.md的6/6开发侧。监看未发现新缺陷；照片侧实际复现NP3记忆被Cube覆盖、传输草稿提前落盘、私有快照丢失仍启用控件，分别修复独立NP3记忆、返回/关闭提交（工作台仍即时保存）、按快照元数据缓存可用状态；另补目录选择失败提示、隐藏LUT时清除Cube草稿。草稿持有快照至提交/丢弃，不额外长持已保存配方；无关NP3记忆不触发预览重渲染。保留两轮缺陷基线及一次修复中失败记录，纠正旧测试的提前保存/保留禁用Cube假设。集中125/125+工作台LUT批量实际JPEG专项1/1，合计126不同专项最终通过，0失败/跳过、均TEST SUCCEEDED/exit0；含真实SettingsView关闭提交、Metal像素、双入口失败/取消/恢复、3000项列表与刷新隔离、队列重试，批量三图换LUT清缓存仍使用原配方且结束释放快照。紧凑轮图已看，进程结束、diff及源指纹检查通过；未装真机/提交/推送，真实Provider/相机/功耗待用户联合测试，端侧录制豁免与原工作区/ios/docs保持。

- 2026-10-20用户要求监看LUT整体检查，主代理独立按Android25860ae6完成docs/待做/iOS-20261020-监看LUT整体复核.md的5/5开发侧。实际复现并修复：含行首#注释的正常cube被拒绝、损坏尺寸声明错报unsupported、冷进入重选原目录误清两模式选择、原目录读取失败多发提示、恢复必须扫完整目录导致无关子目录失败阻止已选LUT恢复。现初始化恢复目录身份，冷恢复按保存文件直接走书签/有界读取（打开菜单才扫描），路径仍限定原目录及一级分类；注释/BOM/CRLF与Int32尺寸分类按安卓。前轮71项未覆盖这些边界，旧scanFailed提示测试预期已纠正。4轮失败/编译夹具错误均保留，最终lut-audit-final 69/69、0失败/跳过、TEST SUCCEEDED/exit0（67模型组件文件GPU+2UI），含实际Metal像素、独立模式/后台、取消/超时/缓存、大目录滚动及横竖弹窗；3截图已看。测试QoS警告定位到故意阻塞Provider的consumeSignal夹具，非产品卡顿证据。全部进程结束、源指纹及diff通过；未装机/提交/推送，真实相机/外部Provider/真机功耗仍待用户，P34/C02不核销，端侧录制豁免及旧工作区/ios/docs保留。

- 2026-10-20用户连续要求卡片速度不省略/向右伸缩、评级加载可停止并丢弃部分结果、监看LUT交互对齐安卓。主代理独立完成docs/待做/iOS-20261020-速度标签评级与监看LUT.md的3/3开发侧：真实卡片9.9→999.9MB/s原58→52.33pt压缩复现，数字保留自然尺寸并沿用左锚140ms；评级每次进度更新重置手势身份导致180ms点击被吞，改固定动作身份，停止清空/重开/迟到回包回归通过；LUT从系统抽屉/分类下拉改工具锚定Genie、固定关闭/目录、36:64独立列、选择加载/首个GPU呈现提交/取消选目录返回，沿用独立状态及320/350ms曲线。历史同名面板不等于交互已复刻，此缺口本轮补齐。速度4/4、评级24/24，LUT各轮含失败最终去重43/43，合计71不同专项最后均通过；首轮LUT模型通过但整包UI失败未写为成功，AX标识覆盖、UITableView全局估算偏移测试纠正及横屏Dock屏外定位失败均留记录。实际屏幕可见行/3000项定位和父刷新隔离、系统Files取消、Metal提交、横竖截图已验；最终补验TEST SUCCEEDED/exit0、所有进程结束、diff通过。未真机安装/提交/推送，用户稍后再测及P34/C02待验不变，旧工作区与ios/docs保留。

- 2026-10-20用户反馈上滑会触发横翻且跟手卡顿，主代理独立完成docs/待做/iOS-20261020-上滑方向锁定与渲染.md的2/2开发侧。真实斜上滑74次移动复现先upward后因底层横移约0.30页变rejected；旧纯竖向回归不足以证明方向锁定，已纠正前轮台账。现直接锁实际分页器pan，保留上滑命中，确定方向后不再按页偏移反悔，松手/取消/卸载恢复原状态；同页同偏移去重、本地frame不变不重复测量。稳定拖动区间分页通知70→0、父body1→0，图片矩形回调296→120（含不再横移的相邻页，非CPU/FPS比例）；未证实整页逐帧重建，未据此重写渲染。原门槛/阻尼/缩放/透明度/抛起和弹簧节奏保持。baseline失败保留，native-lock2/2、regression13/13、trajectory4/4（重叠）均TEST SUCCEEDED/exit0，去重15/15最终通过；图片实际横向中心固定/纵向无回跳、后续翻页/捏合/取消/连续入队/离线拒绝/效果窗均有证据。截图已看、进程结束、diff通过；未真机安装/提交/推送，P34/C02待验及用户稍后再测不变，旧工作区和ios/docs保留。

- 2026-10-20用户反馈连接成功图标飞行、预览展开/FHD跳位与上滑入队失效。主代理独立修复：Root稳定复用Home并按动画开始日期交接；预览全屏视口置于缩放外层，实际402×656→752和194→132→158pt跳变消除；分页改在原生UIScrollView内测量，消除0.011111伪横翻拒绝，上滑保持命中并恢复96pt缩放阈值；补FHD淡入终点隐藏旧缩略图，实际截图不再残留旧边。docs/待做/iOS-20261020-连接飞行与预览跳位.md为3/3开发侧；集中23/23、FHD补验3/3（2重叠）、真实断连1/1，去重25/25最终通过，均TEST SUCCEEDED/exit0。初始真实失败、被撤回的几何方案、Root评级提示误计及旧离线启动夹具纠正均保留台账。实际图标像素轨迹、图片矩形连续性/唯一视口、短滑/下滑取消、连续入队、分页捏合/效果窗/横屏回看及卸载停用均有专项证据；未外推真机FPS/功耗，用户稍后再测及P34/C02待验不变。全部进程结束、diff通过；未真机安装/提交/推送，先前GPS/STA/USB改动与ios/docs外部文件保留。

- 2026-10-20用户指定USB第三步去掉Lightning转接器说明，与安卓第二步一致：删除IOSLocalization中usb_step_cable的三语覆盖，直接复用AndroidLocalization，简中原文为“使用 USB 数据线连接相机与手机”；iOS前三步顺序与MTP/PTP提示保留。已核对Android25860ae6的HomeScreen步骤顺序和简中/繁中/英文资源，并逐字静态比对三语一致，1/1文案任务完成、diff检查通过。纯文案调整，未构建/运行测试/安装/提交/推送，先前GPS/STA未提交改动及ios/docs保留。

- 2026-10-20用户要求修复GPS“开启GPS”灰底及STA连接按钮状态闪现：独立按Android25860ae6核对，GPS去掉误用panel材质，保留语义文字色/原800ms关闭手势；STA以稳定20pt原生文字视口实现220/190ms滚动、35+150/120ms透明度及FastOutSlowIn，反向/中断续接、同状态不重播、隐藏后台卸载清理，无持续帧钟。已连接维持完整亮度但仍禁止重复点击。docs/待做/iOS-20261020-GPS按钮与STA状态滚动.md为3/3开发侧完成；30个不同专项通过（29初轮、7宿主含重叠、1收尾重复），全部TEST SUCCEEDED/exit0，实际GPS/STA组件截图已看。构建测试结束、diff通过；未安装真机/提交/推送，用户“稍后再测”及P34/C02待验保持；ios/docs外部文件保留。

- 2026-10-19用户要求提交：本次纳入触感场景/震感设计、照片列表与队列/监看转场、首次监看冗余初始化/布局优化、参数原生加载动画及按需工具构造，共45个文件（代码、测试、台账和记忆）。沿用各轮已有专项验证及补验记录，提交前源文件指纹未变、diff检查通过；没有新增构建、装机、物理测试或推送。用户已明确“稍后再测”，P34/C02继续待真机联合验收；ios/docs/外部未跟踪文档保留、不纳入提交。具体提交号以Git记录为准。

- 2026-10-19全应用性能收尾审查：重新检查现行代码门控/取消、64份台账完整日志（50成功终态/14失败历史均存在）及最新43项/参数补验/142项补验对应关系，没有新增已确认冗余热点。整理7组联合真机验收顺序，仍覆盖P01–P34；33/34开发侧，P34/C02实际首次监看与温度功耗未验收。最后由本任务确认安装的225212版不含最近参数/按需工具优化，未读取用户当前手机状态；现有APP主机codesign严格校验和IPA ZIP通过，沙箱信任链失败已证实是环境限制。当前源指纹/日志清点留/tmp，测试前需构建当前工作树再按已有授权覆盖目标手机。当前剩余验证须用户实际连接/操作相机，随后连续三轮确认该依赖未变、无新实测反馈、源文件指纹及HEAD未变，goal已标记blocked（等待联合真机验证），并非完成；仍33/34。用户已回复“稍后再测”，当前不安装、不操作手机；用户恢复后重新计算阻塞轮次。不为等待制造无依据改动或重复构建。本轮无产品修改/新测试/构建/装机/物理采样/提交/推送，旧工作区全部保留，详见全界面性能台账最后收尾段。

- 2026-10-19全应用性能继续收尾P21：主代理独立确认RemoteView每次构造全部19工具字典（含隐藏/重复pinned/关闭的横屏Dock），改为复用安卓按工具调用的渲染闭包；普通shown、管理shown+hidden、横屏打开shown+pinned，独立配置/动作/时序不变。19个action/label规范化逐项相同。tools-on-demand 43/43（41模型组件+2模拟器交互）、TEST SUCCEEDED/exit0，无失败重跑；实际关闭Dock零构造、隐藏项只在管理构造、摇摆不重建内容、隐藏恢复/拖动与普通HD持续画面通过。三次无XCTest冷首回调328–336ms/收束644–674ms，与前轮相近，不宣称首次停顿解决或真机省电达标。共享阴影时钟有跟踪祖先原生动画用途，未擅停。台账仍33/34、C02/P34真机由用户测试；全部进程结束、diff通过。本轮未装机/提交/推送，先前所有改动与ios/docs保留，端侧录制豁免及静态灯泡不变。

- 2026-10-19用户指定真机测试留给用户、开发侧完成后一起测；本轮主代理独立复核P20/P33，取消四个未加载参数的持续SwiftUI重绘帧钟，900ms/.25↔.55原生图层动画复用已有RemoteParameterInput宿主，原读数/只读/AUTO/手势保持，后台/卸载停用；没有改灯泡。独立representable方案冷挂载无收益已撤回。34个不同专项最终全过，详见全界面性能台账末段；早期小截图只截背景的假像素证据已明确作废，改可见宿主+非空验证，真实文字主体/位置/字号一致，仅抗锯齿边缘最大1/255舍入差，实际截图已看。最终无XCTest三轮冷首回调318–338ms/收束644–668ms，再入120–130/423–439ms，与前轮相近；不宣称首次停顿解决或整机节电达标，C02/P34仍待验。台账33/34开发侧完成并纠正端侧录制豁免范围。所有构建测试/有限诊断结束、diff通过；本轮新增代码尚未装机，手机仍是225212版，未提交/推送，先前全部工作区修改和ios/docs保留。

- 2026-10-19首次监看继续优化：用户先批准安装测量，后指定“真机测试留给我…等你搞完我们一起测”，本轮仅在模拟器做诊断和专项验证，相机实测留给用户；保留已有覆盖安装授权。分段采样确认工具栏有明显首次成本；合并布局回报和独立Hosting两种方案收益不足，均完整撤回。保留第四项修复：RemoteViewModel 32个无独立订阅的控制状态改显式willSet页面通知，原通知时机/相机流程/逐帧隔离不变。普通Debug无人值守三次首回调322–347ms、收束648–678ms；恢复基线414/716ms，owner至body51→20–21ms。仍有冷挂载开销，不宣称停顿已彻底解决。集中回归monitor-notifications-final 141/142通过，工具栏测试误点重排中的管理按钮失败；按实际frame稳定后点击修正夹具，monitor-editor-settled 1/1通过，142个不同专项最终全部通过。UI冷首回调443–459ms，仍不核销C02消除停顿；所有试验已撤回、diff通过。按已有授权用d-b-ios脚本仅覆盖安装并普通启动iPhone15Plus，交付1.98-20261019-225212，构建/签名/IPA/安装全部成功，53秒，保留数据；未代跑物理相机验证。142个不同专项最终通过，构建测试已结束，diff通过。保留此前全部触感/转场未提交修改及ios/docs外部文件，未提交/推送。

- 2026-10-19继续优化首次监看额外布局，**仍未达到消除起步停顿，不能记完成**。主代理独立采样并保留三项冗余修复：RemoteViewLifetime懒创建一次独立子模型并仅转发既有页面通知、工具栏固有尺寸跨提案/放置复用、固定LOCK不再构造全工具字典。多轮AnyView边界、根链拆分、玻璃容器、临时State合并无稳定收益，均已撤回；不改相机启动/停止时序、不预热隐藏相机会话、不改工程优化级别。原Debug最终141/141（139模型组件+2真实触摸）通过，收尾诊断开关2/2重叠回归也通过，所有测试结束、diff检查通过。无XCTest测量首次帧回调394ms/收束728ms，优化编译仅临时对照362/674ms，新owner同模式349/681ms，差异不支持宣称解决；最终UI冷进入首帧仍470–505ms。以上是帧钟回调非物理像素/FPS。追加C01–C03仅定位完成，C02仍有冷挂载开销，C03真机待验；详见docs/待做/iOS-20261019-工作区页面转场.md追加段。已向用户询问本轮覆盖安装iPhone15Plus继续真机采样，等待授权，未装机/提交/推送；此前触感/转场未提交修改和外部ios/docs保留，静态灯泡/手势/端侧录制豁免不变。

- 2026-10-19用户要求照片列表↔队列、照片列表↔监看转场对齐安卓，可适度原生化。主代理独立完成docs/待做/iOS-20261019-工作区页面转场.md的5/5开发侧任务：按Android25860ae6统一24pt/300ms、进入100+200ms/退出140ms，队列固定左顶栏100+200/80ms，右胶囊不平移；移除旧全宽/三分之一视差和320ms后才显顶栏的任务。共用有限时钟/中断临界弹簧、后台一次收束、恢复页面直达、退场释放与独立滚动保位；补非活动页面AX子树隔离，不以禁用变色代替淡出。全局viewport/顶栏坐标移非发布缓存，回顶显隐去重。最终workspace-3为141/141（138模型组件+3真实触摸）、TEST SUCCEEDED/exit0；真实四次队列动画照片页body均1次，监看进入/返回1/0次，29采样帧不重建宿主，原生像素/实际往返保位/胶囊右缘/预览长按与效果窗回归通过。首轮4失败（AX真实问题与scenePhase/色彩/释放夹具）及修复证据保留。300ms是动画规格，Debug模拟器真实目标到收束队列362–478ms、首次监看805ms含挂载布局，未冒称真机稳定帧率或冷启动响应已验收。所有测试结束、diff检查通过；未真机安装/手感功耗验收/提交/推送；此前触感未提交修改及ios/docs外部文件保留，静态灯泡/原手势/监看端侧录制豁免不变。

- 2026-10-19用户要求先列安卓震动场景，再利用iPhone马达设计更丰富震感并接入，明确授权原生触感平台差异：保持安卓触发/准入/取消/结果边缘，允许UIKit/Core Haptics的类型、强弱及蓄力波形不同；不得据后续“对齐安卓”擅自改回统一tick或安卓10脉冲。主代理独立完成docs/待做/iOS-20261019-触感场景与震感设计.md的8/8开发侧任务：31场景组（含端侧录制豁免）、16语义+有限渐强蓄力，共享按需休眠引擎/复用系统发生器，关闭/后台/旧归属取消不补震；裁切入队去重、补STA搜索及反向入队蓄力。首轮直接附加SwiftUI updating破坏短按/滚动（19/22、exit65），已撤回并复用窗口级被动观察器；第二轮33/33、TEST SUCCEEDED/exit0，两轮41个不同专项最终全过（32模型/组件+9真实触摸）。普通/连拍208/203ms、反向262ms、拨轮458ms、GPS触感804ms实测事件，均为模拟器逻辑，不是物理马达延迟。没有新增持续帧钟/后台补震/音频会话改动；diff检查通过、所有进程结束。未真机安装/震感强弱功耗验收/提交/推送，ios/docs外部未跟踪文档保留；手势阈值、静态灯泡和端侧录制豁免不变。

- 2026-10-19用户要求提交全量手势审查修复：本次纳入手势代码、专项测试、审查台账与项目记忆共21个文件。沿用上一轮124/124专项通过的验证结果，提交前diff检查通过，不额外构建、安装或推送；`ios/docs/`外部未跟踪文档保留、不纳入此次提交。具体提交号以Git记录为准。

- 2026-10-19用户要求全量审查手势，主代理独立完成docs/待做/iOS-20261019-全量手势审查.md的8/8开发侧任务。实际发现并修复拨轮450ms被拖动阻挡到1131ms（修后466ms）、滚动按钮叠加延迟264ms与短触摸迟到回调、效果图600ms长按误点/工作台提前对比、GPS长按1.1s不关闭（修后830ms）、工作台旧70pt返回旁路、帮助淡入翻页穿透及预览取消/多指接力残留。效果图三个入口统一原生互斥单击/双击/500ms对比，保留分页/平移与触感；常规照片200ms、反向250ms、拨轮450ms、静态灯泡及端侧录制豁免不变。现行测试去重124/124最终通过（95模型/组件+29真实触摸UI）；所有初次失败、撤回的序列互斥方案及夹具纠正详见台账，旧队列删除/监看录制测试不恢复已移除入口。全部进程结束、diff检查通过；未真机装机/硬件端到端/VoiceOver/全iOS版本验收，不宣称完美；未提交/推送，ios/docs外部未跟踪文档保留。

- 2026-10-19用户要求提交：本次纳入高级连接成功光效、队列胶囊完整动画、预览效果窗/拨轮与照片长按手势，以及对应测试和台账，共25个文件。沿用各轮已完成的专项验证，提交前diff检查通过，不额外构建/安装/推送；`ios/docs/`为此前外部新增文档，保留未跟踪状态、不纳入此次提交。具体提交号以Git记录为准。

- 2026-10-19用户进一步指出照片长按体感超过1秒，主代理独立复查实际触摸链路，确认上一轮只改常量不足：真实长按回调754ms、预览挂载984ms。普通格子的分离点击/长按改为LongPressGesture先于TapGesture的单一互斥手势，合集去掉外层无效手势，保留图片区独立长按；200ms/12pt/340ms入场、反向250ms传输、拨轮450ms不变。修复后普通/合集真实回调206/204ms、挂载414/423ms，均先于1200ms松手；photo-hold-exclusive 1/1、regression 2/2均TEST SUCCEEDED/exit0，覆盖短按只入队一次、真实滚动取消、反向点按预览/320ms长按传输。追加H01–H03共3/3开发侧完成，详见预览效果窗与拨轮台账；前置夹具失败、旧离线admission用例不相容的证据缺口、实际延迟失败均如实保留。未像素首帧/真机时延/全套UI/装机/提交/推送，所有测试已结束、diff检查通过，未启用正常启动诊断或新持续时钟，先前工作区修改保留。

- 2026-10-19用户要求缩短长按，进一步明确仅指“长按照片触发预览”，不是拨轮。普通照片与连拍图片预览共用阈值250→200ms；12pt移动取消及340ms入场动画不变，点击预览模式的长按传输仍250ms，拨轮450ms保持。Android FileListScreen 的两类图片都依系统longPressTimeoutMillis，未硬编码；无安卓设备相连，不宣称200ms等于设备实测。追加任务1/1完成，既有预览交互约定专项short-hold 1/1、TEST SUCCEEDED/exit0，diff检查通过；未本轮触摸UI/真机时延测量/装机/提交/推送。详情记入预览效果窗与拨轮台账的追加段，先前全部工作区修改保留。

- 2026-10-19预览效果窗与拨轮：主代理独立完成docs/待做/iOS-20261019-预览效果窗与拨轮拖动.md的3/3。按Android25860ae6的PreviewEffectsDialog/SettingsOverlay，在扩展遮罩前读取安全视口，面板避开状态栏8pt、底部不重复扣安全区；通过preference提升到照片页根overlay，盖住顶部队列和右下入队并保留原预览、草稿及260/220ms动画。真实触摸先暴露圆角/留白下后台按钮仍被AX认作可点，补到退场结束的背景输入/辅助功能隔离。公共DetentWheel统一>3且启用非只读才接管拖动，点击/拖动同层、普通拨轮不挂零距离按压，移除popup整层空拖动竞争。13个不同专项最终全过（11组件/模型+2定向触摸），80→70/保存重开/长按选择器/禁用/3档点击与5档拖动均通过，实际模拟器截图已看。默认scheme不含UI、模态边缘失败、测试向末档外拖的夹具失败均保留台账。未全套UI/真机安装验收/提交/推送；此前高级光效、队列胶囊未提交修改及ios/docs外部新增文件均保留，静态灯泡与端侧录制豁免不变。

- 2026-10-19按用户要求完整复核队列胶囊，主代理独立完成docs/待做/iOS-20261019-队列胶囊完整动画复核.md的6/6。安卓25860ae6当前仍传输即显示暂停；按用户明确指定改为有WAITING才显示，最后文件不受隐藏影响。补160/120ms显隐+.72尺度、图标/颜色独立动画、预览/空队列显隐、暂停提示与离线原片准入；固定1pt锚点、入袋单有限时钟和Material原矢量。真实组件先复现控制已PAUSE而图标仍START、Done被新批次打断后宽度停68pt截字，改统一新Input回调及类别/宽度共同测量后修复；飞行押扣不再误藏Done，已批准UUID稳定映射补安卓混合。queue-final38/38、payload17/17、colors3/3，按标识去重47个不同专项最终全过；早期编译/夹具/真实失败保留台账。原生玻璃/物理及深色控件阶段图已看，父body/锚点不随动画刷新、时钟终点/弱释放回归通过；无运行中进程。未真机安装/FPS温度或端到端触摸UI验证、未提交/推送；上轮高级连接成功光效未提交修改保留，监看端侧录制等批准差异保持。

- 2026-10-19按用户“提交一次”将上一轮NEF/胶囊与弹窗的23文件提交为933da708，提交后工作区干净、未推送。随后用户要求同步高级版连接成功光效，主代理独立按已合入Android73b81a56补齐：径向金色/绿色柔光、0.62→1 smoothstep全层淡出、核心0.82+p×0.28向外扩散及零透明度终点。免费分支、单枚徽标、权益捕获和已确认的iOS620+760ms/220ms交接时序保留，Android当前500ms开始的历史差异明确记录，不冒称全时序一致。台账docs/待做/iOS-20261019-高级连接成功光效.md为3/3开发侧完成；7个不同专项最终通过，首次渐变像素采样落在金色粒子上的失败保留，改为避开粒子后绘制3/3通过。实际Pro/Free七阶段截图已看，时钟停用/替换/前后台/释放与预览权益回归通过；无新持续时钟，diff检查通过、进程结束。新增光效尚未提交/装机/真机手感验收/推送，用户允许的端侧录制豁免等差异继续保留。

- 2026-10-19用户要求同步本地安卓NEF修复并放慢速度读数、改善完成胶囊：主代理独立合并本地android至25860ae6（3提交，merge7baa8d3d），前序16个未提交文件合并前后哈希保持一致。NEF按451f50f8校验完整JPEG段/SOF/SOS/扫描和空EXIF回退，保持16MiB边界/缓存与取消，iOS版本同步1.98。胶囊只合并显示为最多500ms更新，真实测速/进度不变；保留400/.5宽度弹簧、220+35/160ms内容淡化和1800ms Done停留，填充/材质保留退场。实际像素复现退场文字把背景撑在旧宽度，改surface布局+overlay内容，右缘固定、完整点击范围；未增加持续帧钟。台账docs/待做/iOS-20261019-NEF缩略图与胶囊转场.md为4/4开发侧完成；协议41/41，胶囊25项最终均通过，共66个不同专项。固定宽度before两断言失败与修复后采样文字遮挡2px的失败均真实保留，最后3/3补验成功，原生玻璃和钛金属实际截图已看；不把外层几何通过当像素通过。所有进程结束、diff检查通过；未真机安装/物理NEF与动画手感验收/提交本轮iOS改动/推送。上一轮弹窗未提交修改及端侧录制豁免等平台差异继续保留。

- 2026-10-19用户要求STA重置有动画且不压暗、其他遮罩覆盖顶部前摄/底部控制条。STA透明外部点击区是明确批准差异，后续不得恢复默认整屏压暗。主代理独立完成docs/待做/iOS-20261019-弹窗动画与全屏遮罩.md的4/4开发任务：STA/GPS/滤镜与LUT双入口/购买共享Material Dialog +20→0/220ms、0→-10/150ms与有限透明度动画；效果模块菜单补现有320/350ms Genie、关闭保留与反转。根因是Home/工作台原生翻页容器裁在安全区，改全屏容器+固定内容间距，照片列表已有根层继续保留。30个不同专项最终通过，实际STA/GPS/设置/选择/模块截图已查看，原生翻页/GPS锁定/设置高度/观察边界/停钟释放回归通过；首次Swift6编译失败、无Scene空白截图失败及旧AOSP参数更正均保留台账。未真机安装/物理触摸/旧iOS16.0–16.3或键盘实机验证、未提交/推送；监看端侧录制豁免、静态灯泡等已批差异不变。

- 2026-10-19用户要求“提交一次然后自行检查”：先提交本轮51文件为fdfedd28，再主代理独立复查。实际复现缓存整理/范围快照迟到返回跨过断线后错误发布完成或重新加载，before两项失败3断言；补齐已有扫描代次/取消检查，模型淘汰复用断线清理成为终态，新增3项生命周期回归。commit-review-fixed 61/61、final 5/5均TEST SUCCEEDED/exit0，后5为重复验证，61个不同专项全部最终通过；细节和失败日志写入预览动画与断线性能台账。未发现其他需修改的逻辑/结构问题；未装真机/端到端UI/推送，不宣称已降温，旧P34仍待实机验证。自查修复另作补充提交，保留原提交检查基线；端侧录制豁免继续有效。

- 2026-10-19预览/导航/断线性能本轮由主代理独立完成，台账docs/待做/iOS-20261019-预览动画与断线性能.md为6/6开发侧完成。原生玻璃预览工具整体合成，翻页180ms、进入340ms/退出260ms不变；两处监看fullScreenCover改左侧24pt/300ms及100+200/140ms透明度，Root共享queueModel补回看接线；顶部胶囊40×36、执行32圆形、监看返回40×36、筛选图标19，其他页面仍系统竖屏。用户新增“断开相机仍发烫”后已复现共享AsyncStream取消使后续空等待立即返回；改独立可取消等待/合并唤醒，旧worker清理加代次；断线同步停旧模型扫描/补图/评级、格子缓存只读，已接受无线类型跨断线保留，不抢USB路径；离线信号呼吸改原生550ms缩放并后台/卸载停，灯泡仍静态。集中74项73过1渐入阈值误判，修正夹具后仅重跑1/1通过，74个不同专项最终全过；所有编译/断言失败与截图采样限制见台账。实际组件截图/布局/转场生命周期、Built Info方向与diff检查已完成，失败后遗留simctl diagnose单独终止并保留exit65历史；未真机安装/CPU温度采样/端到端UI/提交/推送，不宣称真机已降温，不核销旧P34。前一回看R03“全入口完成”漏Root队列接线的证据缺口已在本轮明确纠正。端侧录制豁免继续有效。

- 2026-10-19监看回看与传输列表任务收尾：以本地android d973f0f5为功能基准（merge3b89504b），主代理独立完成台账docs/待做/iOS-20261018-监看回看与传输列表复刻.md的7/7开发侧任务。补齐回看安全区/整体关闭/有效FHD回退/工具行与RGB/加载指示/实际入口图标和横竖布局/横屏双击局部坐标；移除单卡扫把，补原片跳过、滑动卸载/批量删除生命周期与精确卡片动画/阴影/占位。当前169个去重专项最终均通过，实际三方向切页与捏合像素、入口/队列截图已看；错误夹具及编译失败历史保留，日志见台账。原13文件12个SHA256不变，仅记忆更新，保留USB就绪检查；后来的本地android eab905f3仅Debug打包改动，不扩入本轮。端侧录制继续豁免，STA顺序加载/UUID相位/原生液态玻璃等批准差异不变。未真机安装/端到端UI/新增iOS提交/推送；物理相机与P34长时热状态不因本轮核销。全部测试进程已结束，diff与图标可重复生成检查通过。

- 2026-10-18用户确认“这样确实更合理”，批准USB首次照片列表就绪门槛这一平台差异：不能可靠诊断物理关机，仅在DeviceInfo握手后、发布cameraSession前读取StorageIDs+StorageInfo，成功缓存IDs给首轮目录，空卡正常准入，无卡/明确不可用与暂未就绪分开提示；双卡任一可读即可，不通过容量/写保护误判。等待每5秒串行复查，后台不发新请求，取消/拔线/换机/离开连接页拒绝迟到结果，权限/传输错误保留有限重试；已进入USB列表重连不重做首次门槛，保留列表队列，不启用系统目录扫描。空相册不再附“请打开相机电源”；USB卡片错误文案完整显示，步骤放不下时优先显示提示，卡高/动画不变。台账docs/待做/iOS-USB首次照片列表就绪检查.md为3/3开发侧完成；readiness55/55与card41/41两轮去重56项全部最终通过、0失败/跳过，140pt三语实际组件截图已看，diff检查通过。未真机安装/物理相机电源及卡状态验证/端到端UI/提交/推送；前序增量已提交b253c7d4，本轮仍在工作区。

- 2026-10-18按用户“先提交，再拉取本地安卓增量并复刻”完成：先提交ab5f7753，合并本地android至401f55ff（3提交/50文件，merge257c6147无冲突，iOS树不随合并变化）。主代理独立完成A01–A10，台账docs/待做/iOS-20261018-安卓增量复刻任务台账.md为10/10开发侧完成。新增Classic/Legacy V2只读协议发现、连接缓存/银行门控、严格NP3转换/九槽原字节备份与回滚；诊断概览/操作独立代次及Debug失败报告；评级默认五日/一次性迁移与加载10日；设置/效果两个入口/竖屏监看分组帮助与父翻页模态边界；按安卓移除手机端录制，保留相机录像/计时/音量电平、用户已有文件和已验收逐帧呈现。50文件索引哈希/对应路径及882三语资源逐项一致，保留Apple权益、静态灯泡与340/260ms帮助透明度约定。178轮为177用例过/1用例3断言失败（滚动末像素停钟），修正小数余量后74/74、筛选3/3、资源3/3通过；加协议52/52与报告24/24等，本轮291个不同专项最后执行均通过，历史编译/断言失败保留。真实帮助截图已看，未运行Release、端到端UI、D5600硬件、系统Files触摸；未真机安装、未追加提交/推送，全部进程已结束。合成Legacy夹具不当作实机验收，旧P34长时热状态仍待验；本轮增量目标完成，不等同全机型验收。

- 2026-10-18用户确认监看流畅后要求先提交，再复刻所有小工具图标与预设交互。前序修改已提交df455558；本轮主代理独立完成20项工具对照、真实Material1.5.4/预设四色矢量、动态RGB/伪色/倍率/锁定及管理/横屏共用，预设改锚定弹窗/九槽/双列分类/窗内清除与目录确认/返回恢复，按180+40/140ms和400/.85尺寸弹簧保留快速连续退场，停稳停钟。台账docs/待做/iOS-监看工具图标与预设交互复刻.md为6/6开发侧完成；三轮35/35、52/52、22/22通过，最终26项中1项截图背景检测误计蓝字失败，修正检测后仅重跑该项1/1通过，共70个不同专项有最终通过证据；失败日志保留。真实组件截图已看、两套矢量可重复生成、生产监看逐帧回归通过。未真机安装/系统Files手动操作/相机NP3实际写入/端到端UI手势/追加提交/推送；不外推所有机型视觉验收，P34其他综合长时热状态仍未验收。

- 2026-10-18 USB监看卡顿本轮已验收：第二版203200构建/签名/覆盖安装同一iPhone15Plus成功（51秒，目录B4AD6AE7），用户在平移/HD或波形复测请求后明确“这次流畅了”。根因是帧订阅位于GeometryReader外，收到了新帧但内部画面被复用；已把观察移入稳定几何内，普通/HD/LUT/分析共用刷新链路，保留外围隔离/手势/时序。此前只提前解码的202427版用户确认无明显改善，失败历史保留。组件旧结构16帧只到6、新结构15次全更新/真实像素/父0更新及完整RemoteView普通+HD叠层换图通过；本轮各阶段61不同专项有最终通过证据，非手机数值FPS。P17恢复完成、台账33/34；P34其他综合与长时热状态仍待验，不外推所有机型/模式。用户数据保留，所有进程结束，无UI自动化/临时探针/提交/推送，旧全应用goal仍外部暂停。当前无需重复让用户再测同一问题。

- 2026-10-18 USB监看卡顿复查：用户确认HD/LUT/分析全关仍卡、收包FPS约46，要求覆盖所有模式。提前JPEG解码版202427装机后用户说“基本没有改善”，不得宣称已解决。进一步复现生产观察边界错误：RemoteFrameScope在GeometryReader外，16帧仅画到6；before测试3断言失败。已改生产RemoteViewfinderFrameScope把观察放到几何内部，保留外围控件隔离/viewport/录制/所有分析时序。geometry-fixed26/26（15次更新全到第16帧、真实绿色像素、父body0更新），完整RemoteView普通/HD+RGB波形直方图连续6次换JPEG像素与退出释放1/1通过；抽取函数缺return的编译失败已修正记录。提前解码的sRGB/P3×8方向/全尺寸/分析/LUT/录制共58不同专项通过，作为独立优化保留。当前正在构建第二版覆盖安装，尚无第二版真机反馈；P17重新打开，台账32/34，P17/P34待验。FPS仍为安卓同口径的接收率，非屏幕FPS；不归因1/25快门，没有相关因果证据。无UI自动化/卸载/提交/推送；全应用旧goal由外部暂停，本轮按用户明确请求处理监看问题。

- 2026-10-18 P34真机进展：用户授权后d-b-ios脚本构建签名/打包/覆盖安装成功，总57秒；当前iPhone15Plus安装200138包（目录70031413，PID905），无参数普通启动/数据保留。ActivityMonitor连接页20.727秒实测CPU加权0.022672%单核、峰值0.374842%、内存46.3924–46.4081MiB；系统Serious，非整机降温验收。用户手动模拟列表/预览/效果窗后明确“丝滑多了，体感上……这个先过”，已接受这部分，计划稍后接相机；不要再催重复模拟操作。Instruments动画模板三种方式超时/找不到PID，无有效FPS数据；所有采样已结束。累计33/34，真实相机传输/大目录/遥控/长时热状态尚待P34，目标active，不标全部完成；未卸载/提交/推送，无临时性能探针。

- 2026-10-18 全应用性能P33完成：8处帧钟共享弱目标，6类活跃owner不待回调即可释放；开关/dock/FAB同值去重但仍恢复排程，ARGB同值不发布。p33-clock-lifecycle44/44、0失败/跳过、TEST SUCCEEDED/exit0，含120次活跃释放/重复输入、恢复终点及弹窗/队列/后台PTP回归。缓存/服务所有权核对保留，未模拟系统内存压力。累计33/34；用户已明确允许构建覆盖安装iPhone15 Plus并继续性能验证，且已按要求USB接电脑。P34正在运行打包脚本，尚未宣称安装或性能通过；不卸载/不提交/不UI自动化，目标active。

- 2026-10-18 全应用性能P09完成：裁切实时几何与比例/准入控件分离，同值无效输入/空reset不发布，取消代次与原JPEG算法/时序不变。p09-crop-projection测试nan类型歧义编译失败，修正后crop-typed40/40、0失败/跳过、TEST SUCCEEDED/exit0；120真实几何逐次选择一致、控件父body稳定/卸载与取消重试回归，前后393×852截图sRGB RGBA平均差0.0，已查看。累计32/34开发侧完成、剩余P33/P34。P33已初查有限动画残留CADisplayLink强引用、后台/缓存生命周期，尚未改。测试和图像比较进程全部结束，未UI自动化/真机安装/提交，目标active。

- 2026-10-18 全应用性能P08完成：两个入口独立数据投影缓存、初始展开单遍追加、分页/加载身份复用并关闭清理，移除无用连拍计算；直方图叶子观察/同源共享/原子去重，替换取消和原时序质量不改。p08-preview-projection 28/28、0失败/跳过、TEST SUCCEEDED/exit0，含3000项120复用/旧算法对照、晚JPEG身份、120同图计算/缓存共享、真实叶子body稳定、完整生产预览请求/缓存及裁切残影像素；新组件截图已查看。累计31/34开发侧完成，剩余P09/P33/P34。P09已读裁切代码：每帧几何仍重建比例按钮、空reset无效发布待优化，尚未改。测试全结束，未UI自动化/真机/安装/提交，目标active。

- 2026-10-18 全应用性能P07完成：列表根不观察完整评级，仅具体星级值变化重筛；目录排序/连拍与网格索引复用，筛选保序/同值不发布，信号帧局部观察且弱时钟。p07-list-projection 85/85、0失败/跳过、TEST SUCCEEDED/exit0，含120真实评级未选星级零列表更新、120过滤旧算法对照/范围元数据失效、5000项120复用/16种展开折叠、实际动画父body稳定/重入/释放及扫描传输回归。累计30/34开发侧完成、剩余P08/P09/P33/P34。P08已初读：previewPages反复映射、初始化有未使用的burstGroups计算、直方图整根观察/clear重复发布待修，尚未修改。全部测试结束，未UI自动化/真机/安装/提交，目标active。

- 2026-10-18 全应用性能P06完成：评级四字段投影仅按钮观察，复用原生透明度动画，进度保持相位；关闭快照/后台/日期页卸载停用，旧linear曲线差异有记录，灯泡不改。filter-actor 32项31过1关闭失败；修复隐藏hosting延迟更新后filter-hidden 3/3、0失败/跳过、TEST SUCCEEDED/exit0，共32不同专项最终证据，含真实完整弹窗120更新body/高度稳定、CA呈现/停用反转/释放及筛选评级回归。累计29/34开发侧完成、剩余P07–P09/P33/P34。P07已读Android activeRatingValues边界，确认iOS无具体星级仍逐返回筛选排序、signalAttention整根观察/强帧钟待修，尚未改。测试全部结束，未UI自动化/真机/安装/提交，目标active。

- 2026-10-18 全应用性能P05完成：目录提醒180/280ms两轮+220ms终点/0.008幅度局部到卡片，主表单和控件不随阶段重建；滚动属性仅变化时写。保留整列/高度门控/摘要本地化/独立草稿/后台目录流程。p05-settings-attention 7/7、0失败/跳过、TEST SUCCEEDED/exit0，含真实卡片父/内容body稳定与取消卸载、两入口高度/整列滚动/换尺寸重开/预览返回及描边交接；像素平均差0.209619/255，实际截图已查看。累计28/34开发侧完成、剩余6（P06–P09/P33/P34）。P06已初读筛选：评级repeatForever只按loading控制，隐藏/后台门控与进度观察范围待处理；未改。全部测试结束，无UI自动化/真机性能/安装/提交/推送，目标active。

- 2026-10-18 全应用性能P04完成：STA/AP提示和STA/GPS重置静态生命周期/确认取消已核对，无额外持续时钟；保留同步高度测量以防跳高，原弹层规则不变。缺失link.slash/bluetooth改Android实际1.5.4依赖矢量并静态缓存，解决P02/P03记录的缺口。p04-pairing-overlays 33/33、0失败/跳过、TEST SUCCEEDED/exit0（配对存储、连接清理、真实面板反转/静止卸载），无No symbol警告；未像素对齐/真机/UI自动化。累计27/34开发侧完成、剩余7（P05–P09/P33/P34）。P05已读Settings主列/高度/观察源及Android目录提醒：当前提醒状态引发整页更新，下一步局部化，尚未改。所有测试结束，未安装/提交/推送，目标active。

- 2026-10-18 全应用性能P03完成：GPS入口只观察开启/颜色分组；倒计时独立叶子，一秒节奏、隐藏/后台/无日期/首个零帧后停钟，新写入恢复；最后写入时间缓存格式化，原同一Genie面板保留会话/地点任务，退出完成才停钟且反转保持。p03-gps-presentation为42/43过（真实定位回调污染夹具），隔离delegate后gps-fixture-final 9/9、0失败/跳过、TEST SUCCEEDED/exit0；共48个不同专项最终通过，含实际宿主120轮头部不更新/开关反转/释放、倒计时父body稳定/恢复及34GPS协议。原link.slash缺失符号未修，不声称视觉一致。累计26/34开发侧完成、剩余8（P04–P09/P33/P34）；P04已初读静态提示/重置，未核销。所有测试结束，无UI自动化/真机性能/安装/提交/推送，目标active。

- 2026-10-18 全应用性能P02完成：ConnectionPage仅订阅GPS开启位，成功动效620/1380ms终点停钟；连接相同状态去重但事件清理/模式持久化保留。p02-connection-final 35/35、0失败/跳过、TEST SUCCEEDED/exit0，含120轮真实页面详情不重建、121次取消清理、配对刷新、模式写入、有限时钟中断/前后台及持续CA实际缩放。此前持续动画测试多次失败最终确认是UIWindow未绑定Scene；修正夹具后原始生产动画通过，已撤回全部试验性动画参数与诊断。累计25/34开发侧完成、剩余9（P03–P09/P33/P34）。P03已初读GPS：隐藏Genie内容仍挂载，整控制行秒钟/DateFormatter、头部全量观察待优化，尚未改。所有测试结束，无UI自动化/真机性能/安装/提交/推送，目标active。

- 2026-10-18 全应用性能P01完成：Root单个稳定owner仅发布会话/模式/开关/目录准入快照；Home按Android只观察GPS开启和释放工作台两位；提示叶子观察。p01-root-projection 39/39、0失败/跳过、TEST SUCCEEDED/exit0，含真实Root/Home各120轮详情更新body稳定、80种阶段规则、原生上下切页/GPS锁定、投影weak释放、目录挂起时绘制/卸载取消及连接/手势回归。业务发布、原620+760+220时序、发现暂停/恢复、重连provider与恢复门控不改。累计24/34开发侧完成、剩余10（P02–P09/P33/P34）。下一组P02已初读ConnectionPage：仍整体观察GPS却只需enabled；持续卡片动画/隐藏后台待进一步核对，尚未改。全部测试结束，未UI自动化/真机性能/安装/提交/推送，目标active。

- 2026-10-18 全应用性能P32完成：缩略图LRU改常数时间链接/完整清理单遍历，24路同图共享一次解码（含超预算），原预算/磁盘/STA/取消保持；LUT固定参数每图准备，CIContext复用且关闭中间缓存。p32-thumbnail 41/41；p32-lut-context 38项中37过，1项因测试误比行填充失败，修正后p32-cache-final 11/11、0失败/跳过、TEST SUCCEEDED/exit0，共87个不同专项有最终通过证据；前次测试@MainActor误移编译失败也保留。含2万随机LRU旧策略对照、实际缓存淘汰恢复、118342个颜色组合/15组RGBA位图/24路8方向、分块/预算/取消回归。累计23/34开发侧完成、剩余11（P01–P09/P33/P34），下一组根页面与其余页面更新。图片质量/并发上限/动画不改，灯泡静态；所有测试结束，未UI自动化/真机性能/安装/提交/推送，目标active。

- 2026-10-18 全应用性能P31完成：拨轮当前索引/配置hash在不可变输入处准备，碰撞仍完整比较；提示只发布变化frame、弱帧钟，照片列表根与文字测量不观察帧，同文案仍续deadline；原生圆角阴影按几何缓存，灯泡不改。p31-final 38/38、0失败/跳过、TEST SUCCEEDED/exit0，收尾不可变输入4/4重复项通过；含1万项120次不重算、重排/取消、真实提示RGBA与静态完全一致/父body稳定、生产提示再次显示、weak释放及按钮时序。初组颜色/截图边缘纯色计数与固定帧等待误断言已定位，日志保留，不改动画来过测，截图已查看。累计22/34开发侧完成、剩余12；P32初读预览/效果/缩略图缓存，PhotoThumbnailStore.touch逐命中线性removeAll待对照Android处理，尚未修改。所有测试已结束，未UI自动化/真机性能/安装/提交/推送，目标active。

- 2026-10-18 全应用性能P30完成：阴影按帧共享真实presentation祖先/窗口快照，静止/隐藏/零尺寸跳过转换，相同参数不重布局；原帧率/算法、父动画/滚动/重挂载/失败重试不改。实体纹理仅叶节点更新，旧主题迟到拒绝但共享缓存保留；毛玻璃按行列数缓存路径，灯泡和原生液态玻璃未改。首次实际宿主发现空Group无法启动纹理task，已补透明节点，失败日志保留。最终p30-final 27/27、0失败/跳过、TEST SUCCEEDED/exit0，含121层共享采样/120帧静止、实际动画与隐藏恢复、GPU裁剪、纹理RGB/切主题父body稳定、240次颗粒缓存、弹窗退场weak释放/原尺寸反转。累计21/34开发侧完成、剩余13；P31已读公共拨轮/提示，长列表重复hash/索引及提示发布/时钟待处理。全部测试结束，未UI自动化/真机性能/安装/提交/推送，目标active。

- 2026-10-18 全应用性能P29完成：启动bookmark解析/续期/scope/路径规范化移后台，Root等恢复后按原顺序启动连接和开放交互，现有页面等待时仍能绘制；清理先登记再发布URL，等待者可取消而不取消共享恢复。NP3异步解析/取消与独立续期，扫描携带root供NP3/监看LUT复用，不再回主线程resolve。PhotosPicker在provider回调返回前等后台copyItem，失败/取消清独有半成品，原图/文件编码不变。startup-restoration25/25、picker-lifetime-final16/16、startup-replacement-final2/2均0失败/跳过、TEST SUCCEEDED/exit0，含真实文件4MiB逐字对照/后台响应、两次恢复与改选取消交错、scope和清理准入、LUT目录到Metal、批次与录制权限回归；连上组日志共42个不同专项有最终证据。累计20/34开发侧完成、剩余14。下一组P30已读公共弹窗/阴影：静止阴影逐host重复祖先presentation/坐标转换待优化，不能漏祖先动画或降频；尚未改。未UI自动化/云Provider实机/性能验收/安装/提交/推送；全部测试进程结束，目标active。

- 2026-10-18 全应用性能P29部分推进：选目录scope/bookmark改后台准备与统一提交，重复pending合并、替换/clear/deinit/自身取消拒绝迟到结果并释放lease，旧传输目录作用域保留；系统picker单次交付/最新闭包。选图取消/授权等待重复点击/相同进度不再触发工作台Published，2worker/2400ms/独立快照不改。p29-directory-selection 13/13、picker-return 11/11、directory-cancel-final 9/9，均0失败/跳过、TEST SUCCEEDED/exit0；共20个独立专项，重叠不累加，含MainRunLoop响应/120次只一次provider/在途下载生成scope/晚到取消重试/3张实际渲染与权限权益回归。P29未核销：DirectoryAccessStore.init/restore及NP3初始化/回调仍同步resolve，下一步须异步化且保留启动目录先于传输准入/清理注册；PhotosPicker副本和其他权限返回仍待查。累计19/34开发侧完成、剩余15。所有测试已结束，未UI自动化/云Provider/真机性能/安装/提交/推送，目标active。

- 2026-10-18 全应用性能P28完成：焦点诊断头复制限1024字节、报告缓存/重复值去重、独立叶子观察与持久化，停止后不再拼接旧报告；开发日志按输入缓存/复制惰性构造，原生可见行保位与末三行跟随。评级日志预算增量计数与快照缓存、面板按版本更新，探测/复制/关闭调度不变。p28-diagnostic-list-tests为15/15、0失败/跳过、TEST SUCCEEDED/exit0，含真实host父body稳定/最新报告逐次持久化、8MiB源只取头、240次Unicode逐字对照、3002行仅62行节点/上翻保位/尾部跟随与协议探测回归；首组5项重叠不累加。累计19/34开发侧完成、剩余15，继续P29。未UI自动化/真机性能验收/安装/提交/推送，全应用目标active。

- 2026-10-18 全应用性能P26/P27完成：Pro光带改原生渐变位置动画，保留2600ms/相位/停用恢复；透明端点金色修复通过18组RGBA原阈值对照。权益空值/相同状态去重，交易生命周期不改；20项模型/组件及本地StoreKit6/6均有最终通过证据。StoreKit未签名及旧sandbox请求阻塞均记录并中断，夹具改先建LOCAL配置再排空共享监听；晚到账瞬间annual在优化前同样复现，按既有D10补自动收敛验证，0.168s无需refresh自行回lifetime，未声称修复所有R01。烟花父层仅持有/绘制层观察、三段拖尾参数每帧复用，400+1600ms/36+18粒子不改。p26-p27-final 9/9、0跳过、TEST SUCCEEDED/exit0，含真实并发顺序/触感/退出weak释放/父body稳定/8张基准像素完全一致，截图已查看。累计18/34开发侧完成、剩余16，下一组P28诊断报告热路径已定位但未修。连接成功保留现有620+760，记录与当前Android500ms/尾淡出的既有差异，未冒称视觉一致。本轮测试均已结束，未UI自动化/真机性能验证/安装/提交/推送，全应用目标active。

- 2026-10-18 全应用性能P25完成：回看根仅观察开关、面板本地观察/取消外层队列重复订阅；当前目录的首选文件/配对/页面身份投影复用，同时间戳pending组增量日期和同名索引。p25-review-performance 18/18、0失败/跳过、TEST SUCCEEDED/exit0，含真实宿主加载错误重试局部渲染、120次快照复用/晚到JPEG稳定身份、1K对双卡组中途失败重试完整发布、关闭排空与监看保活恢复。累计16/34开发侧完成、剩余18项，下一组P26/P27；通用预览pages/初始化分组仍归P08/P32，既有link.slash符号警告归P02/P31。未真机性能验证/安装/提交/推送，全应用目标active。

- 2026-10-18 全应用性能P24完成：快门/录像控件仅显示值变化局部发布，弱帧钟离页停用/激活恢复；camera/local秒数仅文字独立观察，原时序/300ms长按/录制流程保留。两次严格并发编译失败保留；p24-capture-isolated 40/41（唯一浮点60.000004精确断言失败），修正断言后capture-final 4/4、TEST SUCCEEDED/exit0，41个专项均有最终通过证据、3项重叠不累加。真实host像素/父body稳定、时钟释放/120次零通知、1秒计时暂停恢复/停止归零、实际可解码文件及16编码回归通过，截图已查看。累计15/34开发侧完成、剩余19项，P25进行中；未真机性能验证/安装/提交/推送，全应用目标active。

- 2026-10-18 全应用性能P23完成：遥控LUT根仅观察active有/无，菜单局部分类/索引与图像叶子独立更新；规范化移IO队列、相同扫描复用、空闲取消/错误状态去重但事件和持久化保留。p23-lut-performance 35/35、0失败/跳过、TEST SUCCEEDED/exit0，含真实3K列表保位/进度、真实Metal候选提交及替换父body稳定、10K目录元数据失效、120次空闲零通知、缓存/两模式/后台/超时回归。累计14/34开发侧完成、剩余20项，P24进行中；模拟器提交不作真机呈现/FPS证据，未安装/提交/推送，全应用目标active。

- 2026-10-18 全应用性能P22完成：NP3目录共用元数据索引但生命周期独立，相同扫描/槽位结果去重发布、每次相机读取及bookmark提交保留；面板notice弱引用与close清理消除真实引用环，已接受写入仍排空验证/回滚。p22-np3-performance 37/37、0失败/跳过、TEST SUCCEEDED/exit0，含10K目录复用/元数据失效、120次刷新仍读取/零重复overview、真实host关闭释放及协议取消回归。累计13/34开发侧完成、剩余21项，P23进行中。未真机性能验证/安装/提交/推送，全应用目标active。

- 2026-10-18 全应用性能P21完成：工具栏动画改逐slot/独立高度发布，根不观察显示帧；拖动坐标即时快照、仅起止发布，模式淡化只按层级增删更新content，透明度局部观察；三个时钟弱目标/离页停止，持续摇摆及原时序不减。p21-toolbar-final 49/49、0失败/跳过、TEST SUCCEEDED/exit0，含真实工具栏中间位移/最终210pt/固定按钮/隐藏恢复、实际帧钟/停用、父和内容body不变、120次坐标根仅2通知、模式中断真实触摸屏蔽和全部偏好回归。首轮命中固定40ms误假设及旧LOCK布局测试nil崩溃真实保留；诊断后改为实际电影帧可点击且两层存在再反转，旧fixture对齐Android当前两固定项，未改动画/命中功能；中间live-clock 8/8为重复补强。台账累计12/34开发侧完成、剩余22项，下一组P22/P23。未真机性能验证、未安装/提交/推送，目标仍全应用active。

- 2026-10-18 全应用性能P20完成：曝光拨轮配置/最多64项标签缓存、视觉快照去重发布、弱时钟静止/离页停止；菜单按值域/scale缓存，原生可见行复用与单行实测高度，current前3项定位/刷新保位。180/150/900ms、跨档写入/160ms合并/AUTO与取消规则不改。p20-parameters-verified 39/39、0失败/跳过、TEST SUCCEEDED/exit0；真实Tile20次拖动父body稳定/像素变化/只跨档提交、120次空闲零通知、1万项120次选择不重算、3000项定位/滚后刷新/短列表高度及协议回归通过，短列表截图已查看。前四次编译失败原因与日志完整保留台账。累计11/34开发侧完成、剩余23项，下一组P21工具栏（已读Android并定位整栏帧更新/拖动重复发布/模式淡化重建），尚未实施。未测真机性能、未安装/提交/推送，目标保持全应用active。

- 2026-10-18 用户新设全应用性能目标：逐界面优化滚动/动画/更新，保留功能和交互，可用适合iOS的高效实现。新增`docs/待做/iOS-全界面性能优化台账.md`共34项，主代理独立推进。前组P12工作台坐标非观察快照、P17取景帧局部合并通知/LUT加载器及单源纹理复用/末帧补绘、P18后台生成分析位图/125ms波形缓存/稳定图层去重、P19机身角度去重/局部通知/水平仪与网格隔离，共4/34开发侧完成。p12-p17-performance-verified为63/63；p18-analysis-fixed为54通过+1麦克风前置跳过，专用模拟器revoke后p19-horizon为28/28且已实际补跑该录制测试；均TEST SUCCEEDED/exit0。包含120帧整页零通知、真实host最新图/动画像素、Metal输出/末帧、缓存身份/取消/录制收尾等，组间有重叠不累加为独立项；中间编译失败日志已保留。后续P10/P11、P13–P16完成（见后续记录），累计10/34；未验证真机FPS/CPU/热状态，未安装/提交/推送。目标仍全应用且active，不能把局部完成当整体完成。

- 2026-10-18 全应用性能P10/P11续做：已完成队列生成计时仅运行时200ms刷新、卡片变色局部观察、清空280ms批量终态删除/320ms兜底、标签与胶囊宽度局部布局/重复测量去重、速度更新复用队列摘要、空队列双Z原生持续呼吸。时序、数字滚动、右缘固定、移位/侧滑、活动任务保护和重试身份均保留；灯泡未改。p10-p11-performance-final 56/56通过，p11-native-mark-render补强重复项1/1通过，均0跳过、TEST SUCCEEDED/exit0；真实host刷新计数/正反向presentation/实际像素、500任务批量删除已验证，双Z截图已查看。首轮新增测试self编译错误及第二轮700ms固定等待弹簧未结束的失败已真实记录，按实际终止状态修正测试，没有缩短动画。台账累计6/34开发侧完成，剩余28项，下一组P13/P14效果入口/全屏对比及P15/P16选择参数继续；真机FPS/CPU/热状态尚未测，未安装/提交/推送。

- 2026-10-18 全应用性能P13续做：设置/预览效果入口改非观察坐标快照、像素身份单份memo（补曝光补偿/分隔符安全）、水印displayText归一化；旋转与兜底源转入后台共享gate并缓存当前源/方向，临时显示用共享CGImage的方向包装，删无用状态/预热返回键。两个入口复用PhotoEffectsExpandedPreviewSnapshot，固定打开图/anchor、晚到对比按身份补齐。最终p13-effects-performance-final 30/30、0失败/跳过、TEST SUCCEEDED/exit0；包含40次共享只旋转1次、后台/取消/迟到/重开、120次重复配方只编码1次、EXIF八方向实际像素、透明度与同CGImage、坐标父body不刷新及快照/弹窗回归。早期GPU旋转因先布局舍入导致1px偏移，已改方向包装；透明补测抓到新增黑底并已删除，最终两个保存样张与原路径RGBA均差0.0；所有中间失败日志保留在台账。累计7/34开发侧完成，剩余27项。P14已读安卓源/测试但未完成：仍需隔离全屏缩放拖动状态、补旋转220ms/双击240ms曲线与中断连续性、取消关闭Task，不能凭P13快照核销；随后继续P15/P16。未真机FPS/CPU/热状态验证、安装、提交或推送。

- 2026-10-18 全应用性能P14完成：图片变换与手势局部观察，实际显示值中断/接手，双击240ms及旋转220ms FastOutSlowIn、实时角度拟合，满500ms对比/捏合关闭退出、取消拖动清基线、关闭Task取消；时钟停稳/离页结束且弱目标。p14-expanded-performance 28/28，最终对比补强expanded-final 10/10（含重复），均0失败/跳过、TEST SUCCEEDED/exit0；真实host父body不随30次拖动重算、像素精确移动30点、旋转方向/停用恢复/释放与既有缓存快照回归通过。累计8/34开发侧完成，剩余26项，继续P15/P16；未真机FPS/CPU/热状态验证、安装、提交或推送。上段P14未完成说明为当时记录，现以本段与台账最终结果为准。

- 2026-10-18 全应用性能P15完成：LUT目录/收藏单份索引、O(1)轮值名称、分类/重名编号和当前选项复用；弹窗高度有界测量，10,000条0次名称测量。实测LazyVStack远处定位创建2510行且偏8.5点，改原生UITableView复用原SwiftUI行，取消系统最小行高/边缘效果、实测行框精确定位并按ID保留滚动位置。最终p15-chooser-final 29/29、0失败/跳过、TEST SUCCEEDED/exit0；3,000项仅31行构建，六种行高度/sRGB像素最大平均差0.0092，120次无关更新索引/存储复用及扫描/增删/收藏/取消/超时/失败/权限/独立角色回归通过。中间编译、惰性定位、绝对offset断言、系统行高/估计偏移失败完整记录在台账。累计9/34开发侧完成，剩余25项，继续P16；未真机FPS/CPU/热状态验证、安装、提交或推送。

- 2026-10-18 全应用性能P16完成：PhotoLUTEditorLifetime保留懒创建与独立生命周期，工作台/设置外层/整块效果控件不再订阅LUT细节，LUT控件/选择窗局部观察，notice单独事件接收；空闲取消和相同LUT/效果设置去重发布，取消代次、磁盘校验与显式持久化保留。原140ms文字防抖、34pt控件、后台图片导入/关闭后落盘规则未改。p16-parameter-performance 35/35及popup-import-final 7/7，均0失败/跳过、TEST SUCCEEDED/exit0；120次无效更新零通知、实际host父body稳定/叶子更新/选择窗与错误事件、真实弹窗挂载高度关闭及导入中退款/独立偏好通过。累计10/34开发侧完成，剩余24项，继续P20/P21及其余待查项；真机性能、云端选取器仍待对应综合项，未安装、提交或推送。

- 2026-10-18 用户要求继续限定照片列表/预览/裁切/入队的交互与性能复核，主代理独立完成5/5开发侧项：正常FHD位置核验、220ms裁切布局与缩放恢复、原预览透明裁切（移除系统sheet）、Material裁切/加号勾号、真实框起飞、共享原生图片图层残影、上滑/裁切局部观察与静止时钟停止。Android基准9d7dd882，正常位置规则已存在部分不冒称新增。最终preview-page-final 61/61及收尾cleanup 24/24（含重复，非85独立项）通过，实际像素位置/组件截图/高频父body次数及取消重试已验证；中间严格并发编译失败、CGRect舍入断言失败和未挂scene全黑截图已记录并修正。详见`docs/待做/iOS-预览裁切与列表动画性能复核.md`。未运行真机FPS/CPU或物理手势，不宣称全部动画/整机流畅度已验收；未装机、提交或推送。

- 2026-10-18 用户要求列表/预览滚动性能及预览效果窗完整对齐。已移除每帧格子几何写入页面State、重复collapse发布false、预览翻页偏移驱动父视图重算及FHD淡化16ms状态循环；保留坐标实时性与既有读取/缓存/时序。预览效果按钮改安卓橙色AutoAwesome，共用SettingsPopupOverlay的effectsOnly入口，不再系统sheet；当前图/EXIF/旋转直接传入，返回保存并等220ms关闭结束后仅回到原预览。按Android AnchorPopup实现260/220ms、.94→1与opacity轻缩放，单个原生live layer、不截图网格；主设置Genie路径保留。4/4开发侧完成，最终24/24专项通过（含真实弹窗首次已呈现挂载/关闭重开、原窗高度/渲染回归、30次高频更新父body次数不变、240次重复collapse零通知），已查看控件非空截图。未装机/提交，未测真机FPS，不声称全部物理手势或性能已验收。详见`docs/待做/iOS-列表滚动与预览效果窗复核.md`。

- 2026-10-18 用户要求传输胶囊数量动画、右缘固定及状态平滑衔接。对照 android9d7dd882 FileListScreen 的 AnimatedQueuePillCount/QueuePill 及 QueuePillStateTest，保留数字半行位移、160/120ms淡化与400临界阻尼、模式220ms延迟35/退出160ms规则；取消数字时钟依赖隐藏文本Preference才能初始化，使用labelLarge20pt行框；顶栏右控件独立trailing overlay、胶囊限制可用宽度并从右上角放置；图标与文字统一Button/转场实例，保留退出快照。3/3开发侧完成，两组专项7+7=14项通过（含真实像素右缘测试），未安装真机/未提交，完整实际传输视觉验收未完成。详见`docs/待做/iOS-传输胶囊动画与右缘复核.md`，不能将纯模型和局部渲染检查冒充整套动画验收。

- 2026-10-18 工作台拨轮拖动误返回：对照android9d7dd882的ReleaseCommitWheel.kt（>3项可拖动、change.consume、松手提交）及其测试，给可拖动拨轮增加不参与命中的弱引用区域标记，工作台SwiftUI下拉返回和UIKit外层／嵌套翻页均排除从该区域开始的手势；短选项点击控件不改变规则。标记随布局实时换算、隐藏／移除不再阻挡，不添加动画或持续轮询。WorkspacePagingTests 14项（含区域布局／隐藏／移除测试）+DetentWheelDragSessionTests 2项共16/16通过，TEST SUCCEEDED、exit0，日志`/tmp/ztransfer-wheel-paging-tests.log`。未做真机手势验证、未安装或提交。
- 同轮Debug脚本速度优化：固定DerivedData增量编译继续保留；默认不再因已启动模拟器自动额外构建，显式IOS_BUILD_SIMULATOR=1启用，IOS_SKIP_SIMULATOR=1仍强制跳过。USB／局域网自动安装保持；ZIP快速压缩并保留签名／ZIP校验，增加阶段和总耗时。缓存Payload单次对照级别6：4.22秒/23,080,564字节，级别1：1.34秒/25,127,216字节；非整包构建提速结论。bash语法及diff通过，未重新打真机包。

- 2026-10-18用户要求复核参数海报FL/F等标签框及工作台/照片效果弹窗紧凑拨轮。已对照android9d7dd882的ParameterPosterFrame和SettingsScreen/PhotoLutEditor：补四项圆角空心框、字号比例/描边/居中/值间距，并让原图与预览统一缩放计划；完整清点50高主行与34高参数，多数34高原已存在，不能冒称全为本轮修复。现集中到共享DetentWheelSizing，补替换水印图片单项紧凑拨轮。首轮19项4断言失败（旧固定画布3条+细描边抗锯齿阈值1条）真实记录保留；改为3×3原图像素标记验证并校准半覆盖阈值后最终19/19、0失败/跳过、TEST SUCCEEDED、exit0。已查看海报与三列紧凑控件离屏样张，4/4开发侧完成；未安装本轮UI包或运行UI自动化，整页真机待验证，未提交。见`docs/待做/iOS-参数海报与紧凑拨轮复核.md`。

- 2026-10-18用户反馈Debug脚本未向USB/局域网设备安装。已从刚打包留下的JSON确认Xcode27设备列表首先是已配对iOS模拟器，旧脚本未排除simulated且只取首项。现由`ios/scripts/install_debug_devices.py`统一新旧JSON、排除模拟器/离线设备、保留可建立无线隧道的disconnected、去重并逐台安装启动，单台失败继续且最终报错；真机安装前移至模拟器构建之前，旧系统分支移除禁用Wi-Fi参数。12项专项通过，bash语法/diff检查通过；复用用户13:01现有包自动发现USB iPhone15 Plus，安装启动成功（9FFA4E92，1成功0失败），未重新构建；真实Wi-Fi/旧系统未验证。详见`ios/dist-debug-ios/README.md`，未提交。

- 2026-10-18用户明确安卓与iOS不做权益互通，两端定价不同且应保持独立，避免增加复杂度。安卓沿用现有购买/授权体系，iOS使用苹果内购；各端独立定价、购买、续期、退款与权益恢复，不新增跨平台账号绑定或授权同步后台。iOS同一购买Apple账户内的正常恢复购买继续保留。同步更新苹果内购接入方案；本次仅记录产品决定，未修改代码或执行测试、构建、安装、提交。

- 2026-10-18用户要求iOS Debug打包仅保留最新包，并将入口改名为d-b-ios，随后要求打包目录归入ios目录。现入口为`ios/dist-debug-ios/d-b-ios.command`（保留macOS双击执行扩展名及权限），输出目录为`ios/dist-debug-ios/`；仓库根路径已按新位置改为上溯两级，目录内忽略规则随迁移保留。对照`dist-debug/build.command`，新包生成并通过签名/ZIP校验后，仅清理本目录旧`ZTransfer-ios-debug-*.app`/`.ipa`，保留本次APP/IPA配对，原模拟器/真机安装逻辑不变。`bash -n`和diff检查通过；临时目录执行实际清理片段验证旧包删除、新包/无关文件/正式目录/符号链接目标保留及重复执行安全，移动后另验证从仓库和任意工作目录解析工程/产物路径正确。未运行真实构建、安装、提交或推送；此前文档中的旧脚本路径为历史操作记录。

- 2026-10-18用户以安卓截图要求照片效果两个入口的操作逻辑与样式一致，明确授权本轮局部视觉复刻，覆盖此前纯样式延期；全局静态灯泡及iOS液态玻璃默认主题继续保留。主代理自行对照本机android 9d7dd882，实现共享LUT三列主行/紧凑参数/双列选择弹窗、滤镜与边框水印布局对齐，并核查独立角色/共享目录收藏/失败取消；任务与真实验证结果见docs/待做/iOS-照片效果双入口对齐.md。最终effects-editor-final-tests 53/53、0失败/跳过、TEST SUCCEEDED、exit0；6/6开发侧完成，未运行UI自动化/真机构建/安装，外观与物理手势待装机对照，不宣称像素或全动画验收。未提交/推送。

- 2026-10-18用户进一步明确：所有页面的灯泡按钮都取消呼吸，防止其他页面发热。已逐一核查7处入口（STA、AP、GPS、主设置、照片效果设置、本地照片效果、筛选评级），均复用静态TipLightbulbButton，调用方无额外无限灯泡动画。刚安装的999CFD32版本已全局生效，无需新增功能修改或重装；静态未读点、独立已读持久化与点击功能保留。GPS启用时140/160ms显隐过渡仍为有限状态动画，不属于呼吸。此轮只做源码全局审查、注释/记录更新和diff检查，未新增测试/构建/安装/提交；不声称测过其他页面整体功耗。

- 2026-10-18连接页CPU最新：用户随后明确接受“灯泡呼吸停掉，只有红点也可以”，覆盖此前灯泡必须持续动画的约定；卡片和GPS仍保留持续动画。共享TipLightbulbButton改静态灯泡/7pt未读红点，原已读持久化/点击/材质不改。iPhone15 Plus同机静态红点30秒探针（含临时强制全部未读）稳定样本均值0.0309%单核，范围0.0165–0.0621%；回退旧灯泡基线均值36.654%。两张新截图显示正常白玻璃/橙色图标/红点，无旧灰块。此为应用CPU，系统thermalState仍2，尚不等于整机降温验收。普通设置复测均值0.0426%单核；40/40专项通过，清除探针后最终构建成功并安装999CFD32-9660-4BD0-A83A-ED0491868AB4，已无参数启动。CPU高占用已显著消除，温度/整机功耗未验收；详情见空闲发热排查文档，未提交。

- 2026-10-18连接页发热调查：用户拒绝有限轮次或严重发热时停止装饰动画，必须保留持续动画。Time Profiler确认主要CPU消耗在主线程SwiftUI更新。原生灯泡动画试验引入灰块/发虚，用户明确要求直接回退灯泡；TipLightbulbButton已恢复HEAD原实现，删除原生bulb/dot实验分支，保留卡片/GPS优化并删除临时CPU探针。回退同机CPU仍约36%单核，发热未解决，不得引用已撤回方案约0.04%作为当前性能。最终构建/安装/专项状态见docs/技术调研/iOS-连接页空闲发热排查.md，未提交。

- 2026-10-18首次启动冻结真机收尾：按用户要求完整卸载后重装修复版至新iPhone 15 Plus（A56C36AE-A0D4-4FC5-B0DB-B7448DE5D9C1），未代替用户首次启动。用户随后明确确认“这次首次启动不卡了”，并要求提交。结合38/38专项和真机构建成功，本轮首次启动卡顿修复已获用户真机确认；不扩展为所有系统版本的权限状态已验证。此次提交同时纳入此前第二轮57/57复核记录，不新增构建或测试。

- 2026-10-18新iPhone 15 Plus首次授权冻结：用户确认“控制相机”提示同意后恢复；旧日志browser.start约6ms、控制授权等待约8.78秒，未取得线程栈。已把ImageCaptureCore授权查询/请求从主线程移到专用队列，缓存供UI/PTP读取，保留双权限顺序和代次隔离；USB直通不变。firstlaunch-fix-tests 38/38通过（含同步阻塞时主运行循环响应及拒绝/迟到回调验证）。firstlaunch-fix-device-build构建成功，已覆盖安装目录88E6DC02-10B5-4124-ACB9-970554A62836并普通启动成功，未提交；未清数据/重置权限，真实首次授权尚未在修复版重演，不得把已授权普通启动当首次授权验收。

- 2026-10-17最新交付及第二轮检查：a53e1c6d已按用户要求构建、覆盖安装iPhone 15并普通启动成功（197-device-delivery）。随后再次复核未发现新的确定性缺陷，补跑连接呈现/下载/存储调度/LUT读取队列57/57通过（197-second-audit，0失败/跳过），无生产代码修改。真机进程只读查询返回CoreDevice4016，不能声称获得新真机运行证据；本轮仅更新记录，未再次安装、提交或推送。

- 2026-10-17用户追加功能复核：主代理自行检查并修复4处实际问题（生产预览JSON缓存键不稳定、NP3保存目录暂时不可解析后不能重试、回看RAW补JPEG导致页面身份变化、旧预设面板迟到失败误影响新页面）。functional-audit 417项中413通过/4权限跳过，权限补齐后audit-recording 4/4通过；最后面板隔离及工具偏好audit-final 9/9通过。缓存旧实现2断言失败复现保留，git diff --check通过。18/18仍仅开发侧口径，真机/Provider/手势验证限制保留，无UI自动化、安装、提交、推送。详情见增量任务台账末尾。

- 2026-10-17 新一轮安卓1.97增量：用户明确包含本地android最新9c8c1216，22提交/172文件，merge a36b339c，ios原树不变。当前任务台账docs/待做/iOS-1.97-增量复刻任务台账.md，18/18开发侧完成（最后tools-fixed 49/49、final-audit 11/11、preview-final 14/14通过；172文件来源已归类核验，817三语资源可重复生成；真机相机/Provider/手势验收待集中节点，纯视觉与精细动画延期）；忽略鸿蒙专属，保留StoreKit/更新排除和既有iOS平台差异，纯视觉延期。必须持续推进逐项实现，不能把合并/建台账当完成。

- 2026-10-17 U004当前：用户再次否决后已修实际网格上下留白压入内容、遮罩低分辨率、设置列回弹；按安卓统一单Surface/单描边/标题与卡片间距/卡片底色/背景遮罩，并关闭系统滚动边缘材质。最终settings-render-final 7/7通过，精确动画终点→实时画面原生像素平均差0.24969/255；真机构建成功，安装目录1B7FB203-1716-488D-8AEF-6975CD473D86并普通启动成功。用户随后针对打开/拖动/关开后的标题白块、跳高和闪边明确回复“这次正常了”，U004本轮问题已获真机确认并收尾；旧6项/23项证据漏洞与中间失败记录保留。主代理单独完成，未提交/推送。

- 2026-10-17 U004上一轮记录（用户否决，已由上方当前结果取代）：已按安卓将标题/卡片/页脚纳入同一滚动列，短内容自然包裹，超高整列滚动；本次内容高度确定后才展开，隔离旧测量并消除宿主二次推算。完整SettingsPopupOverlay首个可见帧到展开/小屏/两处入口/换视口重开及宿主回归6/6通过；真机构建成功，已安装同一iPhone并普通启动。用户真机观感待确认，非全量视觉验收，未提交/推送。原23项未覆盖外层高度反馈的证据缺口已明确纠正，详情见文末。

- 2026-10-17 U003–U005最新：USB/STA信号四处共用非交互入口；设置窗最终布局后整体捕获、尺寸重捕获和内描边；仅DEBUG模拟年度/永久购买及重开持久化。23/23专项通过，delivery-build成功，已安装同一iPhone并启用模拟永久版；实测冷重开isPro=true且用量仍25。普通无参数启动完成，真机弹窗观感待用户确认。开发侧修复和交付完成，未提交/推送，完整证据与失败记录见文末。

- 2026-10-17 U002最新：已定位有线首次扫描期间的后台批次/分块争用及ICC回调进度低报。USB照片整文件后台屏障、目录逐命令让路、读取前started通知已修；61/61专项通过，同图扫描争用1042ms/9.61MiB/s修复后322–343ms/29–31MiB/s。最终日常版BUILD SUCCEEDED并安装，自动测速入口已删除，免费额度/会员未改；未提交。详细证据和非物理冷拔插限制见文末。

- 2026-10-17用户新增明确要求：“目前速度胶囊的数值变化比较僵硬，进度条动画也不够丝滑……优化一下”。这授权本轮局部优化速度读数与进度动画，优先于此前纯动画延期要求；不扩成全面视觉复刻，不自动运行UI测试或把先前“提交”理解为本轮自动提交授权。安卓数值、状态和进度真实性仍保持。

- 2026-10-17最新：U001当前Z30连接后约一分钟首屏等待已修复并安装，用户重新插线确认“几秒内出现”。默认版启动日志实测首批句柄0.68秒、首条照片信息0.83秒；不再调用系统全卡目录打开接口，普通启动同样生效。最终连接/握手专项30/30通过；精确计时属于应用启动，重插速度由用户确认，完整证据与限制见文末。冷启动误入照片页已修正。

- 2026-10-17 U001早期真机记录（后续处理见文末）：用户确认重新插入后已进入照片列表，但持续转圈；/tmp/ztransfer-usb-loading.png确认列表空加载态，workspace-console记录sessionOpened后首条12字节GetDeviceInfo未回调。系统10:24:19开始PTP1.0 enumeration并接收sendPTPCommand，尚无complete catalog。用户明确要求应用自主加载、不要依赖系统加载。已核对当前SDK ICDevice.h/ICCameraDevice.h及Apple ICSessionOptions/ready文档：未找到公开的关闭系统枚举选项（仅声明enumerationChronologicalOrder）；不能将移除应用ready等待误说成关闭系统枚举，也不能宣布持续转圈已修好。当前保持连接排查，没有新增构建、接口试验或自动化测试。

- 2026-10-17 U001早期诊断记录（非当前状态）：系统日志证明OpenSession前已读出Z30 DeviceInfo，随后系统全卡枚举与应用重复GetDeviceInfo排队。按用户要求，会话打开成功即发布CameraSession；移除ready等待，将补充DeviceInfo移到两条scanCatalog入口、缓存身份选择前。撤回无改善的MainActor/selector试验。/tmp/ztransfer-usb-workspace-build.log BUILD SUCCEEDED，已安装启动；/tmp/ztransfer-usb-workspace-console.txt仅授权事件，截图/tmp/ztransfer-usb-workspace.png仍为连接页，当前未收到deviceAdded；系统最后断开时间10:20:38。尚未验证新版本连入列表、照片枚举或传输，不标修复完成；未运行新增自动化/UI测试。

- 2026-10-17真机跟进U001早期记录（后续修复见文末）：用户授权安装后，在iPhone 15/iOS27.0.1以已验证USB-C数据线直连Nikon Z30停连接页。已修openedCamera错误回退discovered对象导致不发OpenSession；修复版已安装，实测sessionOpened且指示灯闪，但仍无ready，正排查系统目录枚举。此前174/182为开发侧历史核销，不能据此宣称真机USB可用。无提交/推送。
- 用户要求：“ui测试的可以跳过，你只负责功能逻辑完整复刻，不负责样式和动画复刻”。此最新要求优先于此前样式/动画逐项对齐要求：后续不再开发或验收纯样式、动画，也不再自动运行UI测试。
- 用户补充：样式本阶段只做到基础可用，确保功能入口、操作与必要状态反馈可用；精细样式、动画及播放效果留待后续集中处理。允许为功能可用性做必要的基础界面调整，但不继续逐帧/像素或视觉参数对齐。
- 仍须完整对照安卓的功能、业务判断、状态流转、错误、取消、重试、持久化和数据安全；可继续运行已授权范围内的模型/业务专项验证。涉及页面但影响连接、任务或数据状态的逻辑仍在范围内，不能因属于UI文件而漏掉。
- 纯视觉条目按范围排除处理，不伪记为已修复；混合条目须拆出功能要求。原30/182为历史全量台账口径，功能口径总数待逐条重分类，不推算虚假完成率。
- 用户已批准液面UUID稳定映射方案，曾随动画范围延期；2026-10-19队列胶囊动画复核已补现有UTF-8稳定折叠后的安卓unsigned混合，业务UUID保持不变。
- 2026-10-17用户明确接受三项平台差异：F142保留AVAssetWriter无总收尾期限，不添加8秒截止；F177保留450ms长按阈值，不改500ms；F171保留iOS系统UIDevice方向判断，不引入CoreMotion或强行映射安卓角度分区。结合既有专项证据和源码复核，三项功能范围核销，当前174/182，功能部分已收尾，剩余8项延期视觉任务（F003、F016、F041、F080、F083、F152、F179、F182）。收尾仅更新文档，复核orientation-resume既有3/3通过日志，未新增运行测试；不声称收尾等待有界、物理方向回放或实际手势回放通过。既有证据限制继续保留，不等于全部真机验收或视觉复刻完成。


2026-10-16 F101照片LUT四项微调已完成开发侧实现和专项验证，当前核销89项，以全功能跟进页首为准。包括摘要/角色记忆、旧配方回退、实际颜色输出、v3身份、队列失败重试和控件提交/取消回调。最终f101-input 16/16；不是UI/真机手势验收。下一步F102加载/取消/错误链，F088另待独立收尾复核。

2026-10-16 F104颜色顺序开发侧核销，当前90项。先clamp LUT输出再按字节域混合，并按安卓逐轴插值；前两轮精确蓝通道差1失败保留，最终f104-interpolation 10/10通过，含半透明/透明像素。F102/F103仍未核销。

2026-10-16 F105域与快照校验开发侧核销，当前91项。文本拒绝range溢出/倒数下溢，快照验证域和精确长度；真实损坏快照不注册、不改当前来源。f105-domain 36/36通过，F102/F103/F106仍未完成。

本项目的目标是：**根据安卓端现有实现，原生复刻 iOS 端。**

2026-10-15 用户已要求按全功能复核文档逐项修复与补齐，稳妥、可维护；此新任务取代此前只审查的范围，继续由主代理自行推进。按文档优先从输出安全开始，形成完整块后集中构建/自动化，不自动提交/推送。F056完整对象双尺寸校验、F058照片失败清理及完整part仅限视频已补生产接线；最终`/tmp/ztransfer-20261015-f056-f058-fixed.log`为50/50、0跳过、TEST SUCCEEDED。首轮新增测试Swift6隔离编译失败保留。随后F057/F059补齐STA照片单请求/短读/上限及USB大文件不支持partial的安全失败（包括后续文件）；最终`/tmp/ztransfer-20261015-f056-f059-fixed.log`为56/56、0失败/跳过、TEST SUCCEEDED，第二阶段测试错误引用私有函数的编译失败亦保留。当前修复核销26/182（F052为此前已有修复），T21因V004未知大小USB EOF待证仍未完成。F064派生图重名保存已接目录级共享预留和隐藏暂存发布；重叠预留/失败释放、真实JPEG并发与队列回归17/17通过，日志`/tmp/ztransfer-20261015-f064.log`，待真机。F145已完成独有暂存目录/完整封装后共享名称预留发布，保留ViewModel既有目录失败回退。首轮`/tmp/ztransfer-20261015-f145.log`最终5/5、TEST SUCCEEDED（simctl诊断收集600秒超时警告保留）。补生产入口回退后，`/tmp/ztransfer-20261015-f145-final.log`最终6/6、0失败/跳过、TEST SUCCEEDED；真实MP4逐帧解码、原文件保护均通过，已核销待真机。共享名称类现名OutputFileNameReservations，JPEG回归同轮通过。所有构建和诊断进程已结束，未提交/推送。F117已修复galleryMat缩整画布造成裁片：按安卓参考空间缩边距/扩方形/坐标向上取整；像素测试还发现照片本体多余白描边/投影，已移除，保留外黑卡纸投影。横竖方图×60/65/100/200×原图/480预览24配置；原图每色像素数零损失，预览插值边缘按周长容差。初轮89失败定位描边，第二轮2预览纯色容差失败保留，最终`/tmp/ztransfer-20261015-f117-final.log`5/5、0失败/跳过、TEST SUCCEEDED（含1920布局及JPEG发布回归）。F117已核销待真机，F116完整文字测量仍未完成。所有构建已结束；F132已修复warning拒绝/完整写入收尾/longjmp清理状态，原生测试另发现并修复工作区必须先于read_coefficients申请的非零起点失败。最终iOS`/tmp/ztransfer-20261015-f132-offset.log`2/2、0跳过、TEST SUCCEEDED；原生ASan/UBSan故障注入`/tmp/ztransfer-20261015-f132-native-fixed.log`PASS、退出0，覆盖截断、fflush ENOSPC、fclose EIO及重试/原片。前两轮native失败日志保留。新增ios/NativeTests两文件，覆盖索引当前664；未真机模拟磁盘满。F132核销待真机。F134已改会话/任务UUID独有暂存目录、共享名称预留、父取消传递到detached、三条队列入口接线、发布后先记cropURL再检查取消及旧会话清理。最终`/tmp/ztransfer-20261015-f134-fixed.log`21/21、0失败/跳过、TEST SUCCEEDED；首轮测试fixture闭包参数匹配编译失败日志保留。覆盖两路真实native重叠/取消/活跃保护/旧会话夹具/发布边界重试单次复用；未实际杀进程重启或真机验证，不能声称真实重启验收通过。F134开发侧核销待运行验收，F062其他临时清理竞争仍未修复。F133已改原生仅保ICC、Swift按安卓35字段重建IFD0/Exif/GPS，显式写方向和四尺寸，不复制IFD1/旧缩略图/MakerNote/XMP/其他APP2。大小端×SHORT/LONG×8方向32组合使用64×48裁切、逐字段/旧数据移除/压缩流不变/越界GPS拒绝及既有完整性/生命周期回归，最终`/tmp/ztransfer-20261015-f133-rectangular.log`7/7、0跳过、TEST SUCCEEDED；原生`f133-native.log`ASan/UBSan PASS。首轮fixture混有UIKit自带EXIF导致失败已纠正并保留日志。F133核销待真机。2026-10-16 F135补256MiB源/1亿像素/192MiB codec预算、2MiB有界读头与独立可取消串行准入；同步桥接也互斥。首轮8项1失败定位URL尺寸缓存，改实时文件属性后f135-serial.log为25/25、TEST SUCCEEDED；f135-native.log ASan/UBSan PASS，极端SOF预算失败及阈值边界可重试。最终20261016-f135-admission.log为3/3、TEST SUCCEEDED，覆盖已排队取消、24路许可挂起/异常释放及12路真实裁切输出/原片保护。F135开发侧核销待真机，未测真机RSS/内存压力；F065/F072及T19其他缺口仍未完成。F131随后补每分量1…4采样及安卓4字节marker前缀门控，整理解析器；2MiB有界读头沿用F135。20261016-f131.log为13/13、TEST SUCCEEDED，含真实64KiB/2MiB边界、8万字节ICC、坏EXIF/采样/截断及相关回归。F131开发侧核销待真机；预览仍请求64KiB属于F125准备流程，未修复。F063已接原片无限递增/忽略大小写共享预留，按安卓一次rename失败同名copy，修正旧后缀重试测试；copy目标抢占不删除外部文件。20261016-f063.log为56/56，f063-publication.log为1/1，均TEST SUCCEEDED，含真实下载100重名、并发挂起发布、异常释放与旧文件保护。F063开发侧核销待真机Provider；F060/F061/F062仍未完成。F060已补worker解析目录/查索引/创建/相机调用前校验，重试重新校验，正则改绝对锚点拒绝末尾换行。20261016-f060.log为18/18、TEST SUCCEEDED，实际非法扩展拒绝且不创建层级/不调用相机，后续合法任务和64字符边界成功。F060开发侧核销待真机，F061/F062仍未完成。F061已接DirectoryAccessLease，选择器/队列/run/FrameJob各持所需旧root引用，成功start仅在最后引用结束时stop；恢复清理也保留自身引用。20261016-f061.log为25/25、f061-active.log为1/1，均TEST SUCCEEDED，覆盖下载换目录、新任务新目录、确认两路挂起+第三路等待时clear及成功/失败释放、拒绝start不stop与store销毁。测试注入授权操作，真机外部Provider尚未验收；F062删除竞争、F065生成worker规格仍未完成。F062已补TransferDirectoryPreparation：restore先注册再发布URL、queue等待共享清理、已用root不重复清理、不同root独立及等待者可取消而不取消共享清理；frame临时名加进程UUID并清理实际ZTFrames旧残留。初轮f062.log 30/30但旧清理测试名错未执行，补取消f062-final.log类型推断编译失败；最终20261016-f062-fixed.log 32/32、TEST SUCCEEDED，旧测试1项已实际执行，含挂起restore→生产queue无part→释放清理后创建/发布、重复restore不删活跃part、取消/其他root与当前frame保护。开发侧核销待真机，未实际杀进程或外部Provider重启验收。F065进行中：已接PhotoGenerationQueueState默认4096（准备/等待/运行均计入）、单utility计算槽位、满队列原文失败/原片保留及释放重试，旧双worker测试按安卓改为单worker。20261016-f065-admission.log 36/36、TEST SUCCEEDED，含4096状态边界/保序/准备绕过/关闭，生产容量2满与重试/取消失败继续、身份回归。仍未核销，当前17/182：真实下载worker仍await元数据补读，下一步结合F066独立有界准备consumer并验证实际慢头/快任务交错及关闭；F067/F068独立未完成。F065后续生产闭环已完成：独立轻量身份准入consumer+单补读consumer、单计算及4096共享容量，实际快就绪任务越过慢补头；close取消/清理准备等待活动项并隔离迟到结果，原片保留。补读真实入口由transfer改为安卓backgroundThumbnail，协议调度实测评级阻塞/放行类别正确。最终20261016-f065-f066-handoff.log 97/97，f066-identity.log 32/32，均TEST SUCCEEDED，含身份本身挂起仍允许后续原片下载、慢头与快捕获头交错、准备容量/释放重试/关闭及来源快照回归。F065开发侧核销，当前18/182；F066仍未核销：新下载header在run同步cameraSnapshot解析，下一步结合F067头预算/结果状态独立parser，禁止4096原始头无限驻留；F067/F068仍未完。所有测试进程已结束。其他遗漏继续逐组处理，不能据这一组通过宣布目标完成。

2026-10-15 本线程继续 N09/N10：计时气泡已按 Compose 1.7.6 去掉多余裁剪；生产录制 UI
验证计时、暂停、横屏切换、恢复和保存反馈通过（`n09-timer-final` 1/1），真实 MP4 为 109 帧且
全帧解码成功。高级提示/计时气泡的公共投影仍归未完 T24，N09 不因此标完成，也不再阻塞 N10。
N10 已接单个 nonce/计时器的最新消息替换，旧交互/相机录像/本地录制三套计时任务已移除；
接入 LUT 接受结果及复制日志提示，错误的协议摘要移至 24 行开发报告。后续已替换旧顶部浮层：
竖屏顶栏中间40pt槽位、横屏取景器20%锚点、160/200ms fade和三态中断弹簧已接入。
共用TextKit测量/绘制，修复末行丢失并补宿主像素带检查；最终`n10-hint-host-ink`为4/4、TEST SUCCEEDED，
实际两行/省略截图已查看；此前动画/生命周期8项通过。项目labelMedium字距解析为0，已纠正N09错误tracking。
N10离页后录制保存失败的跨页面通知仍未接入，其他主题/语言/日志叠层及全范围核销未结束，不能标完成。
完整依据、历次失败及截图发现的漏测记录在1.93台账“提示锚点、淡入淡出与文字实际绘制”。
同时修复全功能复核F052：准入已选中但返回前取消也按ticket身份清理active；确定性交接窗口测试和原调度器
回归`/tmp/ztransfer-20261015-n01-admission-cancel.log`为17/17、TEST SUCCEEDED。N01/N02仍未完成，
下一步优先F053（IDLE整文件屏障/存储读取准入回检）、F054（生产关闭调度）、F055（评级任务owner）。
本轮源码还显示N09退出中重入动画需对照PostExit→Visible规则复核，不把普通开关测试当完整中断证据。
集中回归发现旧生命周期测试共用 `.standard` 已累计 180 秒，现每项注入独立用量 suite；
隔离后 82 项中 80 项通过，2 项是旧测试要求已退出页面再生成提示，与本次离页门控冲突，
已修正断言，`/tmp/ztransfer-20261015-n10-hint-exit-final.log` **2/2、TEST SUCCEEDED**；
集中运行日志 `n10-hint-isolated` 保留两次断言失败，不能改写为单次全绿。所有构建/测试进程已结束。
并行全功能复核正在继续撤回证据不足的旧完成项，当前计数须读台账页首，不沿用下文历史数字。
本轮未更新安卓基准、未提交/推送，仍以 `ba319622` 合入的安卓 1.94 为实现基准。

2026-10-15 用户要求自行开展全功能板块审查，建立大纲并逐项寻找漏复刻，减少依赖用户反复测试发现问题。
入口为 [iOS 全功能行为复核跟进](待做/iOS-全功能行为复核跟进.md)，共32项，进度以该文档为准；本轮不分派子代理。
以当前工作树（含全部未提交修改）为据，不沿用旧完成声明。首次已确认工作台返回阈值和按钮返回时
发现暂停时序遗漏，撤回1.91 T23完成状态，原26/26改为25/26记录值；其余仍待本轮复核。
列表/队列/监看转场也未同步当前安卓规格。此为审查和跟进文档任务，尚未修改业务实现、构建或运行测试。
安卓APK更新明确不复刻，遵循已有B17的App Store方案；仅残留更新文案不等于存在自更新功能。
本轮静态审查已完成32/32（C01–C32），登记F001–F182；GPS发现失效身份未清内存、NOT1通知遗漏、
BLE超时/回调隔离缺口、写入时未重验海拔有效期及坐标/内部动画差异。旧全链路HTML顶部已纠正整体对齐声明；
照片目录又发现删除不失效快照、扫描中范围不更新、受限扫描误删范围外缓存、不完整metadata阻断后续事件、
双卡跨批旧行不刷新及续扫丢副本基线。1.93 N03撤回完成，当前记录8/15；1.91另有N09复核撤回T24，
其后C07又确认删除填充队列、写盘失败停填、无图响应、USB缓存身份及EXIF格式缺口，撤回T03；
1.91当前记录23/26（T03/T23/T24未完成）。C08又确认评级范围/代次重建、顺序、配对完成标记、
默认3日恢复及帮助动画、诊断捕获缺口；撤回N05/N06，1.93当前6/15；撤回M02，1.94当前2/3。
M01“清空整套筛选保留保护”原文不符合安卓clearFilters默认行为，已纠正文档，不算漏项。
C09又发现断线入队、连拍入口、类型清理、回顶、最新任务、frame身份、评级空态、格子视觉、飞行边界及历法混用缺口。撤回T04和N11，当前1.91记录22/26、1.93记录5/15、1.94记录2/3。
下文旧9/15、8/15、6/15及本轮早期25/26、24/26、23/26、3/3仅为历史。C10确认普通FHD重试/能力/fallback顺序、EXIF方向、解码上限、RGB直方图/视频门控、已传标记、合集缓存和预览磁盘重复扫描/飞行几何缺口；T04/N11保持未完成。
C11确认准入取消可遗留active、IDLE下载屏障及存储监看接线缺失、真实CloseSession绕过调度、旧评级收尾覆盖新任务；撤回N01/N02，1.93当前3/15（N04/N07/N08保留历史完成记录），旧5/15亦仅为历史。
C12确认完整GetObject漏known大小校验、STA照片错用视频分块、照片失败part可被直接重用和USB大对象fallback无界；撤回T21，1.91当前21/26。
C13确认目录名校验未接创建、换目录提前释放授权、启动清理与新任务竞争、原片重名100上限和两路派生无原子名称预留；撤回T22，1.91当前20/26。
C14确认生成资源/准备/计时/主开关/独立重试及离线入口缺口F065–F073，T22保持未完成；F074确认裁切仍参与自动去重，撤回T20，1.91当前19/26。下文“裁切不参与自动去重已补齐”为无当前实现证据的历史声明，不能沿用。
C15确认执行控件显隐、侧滑、重试/确认资格、卡片内容/动画、缩略图补载、进度订阅、自动飞行、押扣及Done跨批次缺口F075–F085，T23/N11保持未完成，计数仍19/26、3/15、2/3。
C16确认批次失败详情、轻点放大、LUT角色隔离/重复入口及生成行布局文案缺口F086–F090；撤回T14/T18，1.91当前17/26，1.93仍3/15、1.94仍2/3。
C17确认模块点击/分区/LUT门控/清启用/互斥/收藏及菜单缺口F091–F097，撤回T17，1.91当前16/26；1.93仍3/15、1.94仍2/3。
C18确认Cube提交清空、目录作用域/重启/微调/错误/颜色/快照/缓存/取消及NP3分类等F098–F110；普通NP3目录50项源数据静态比较无差异，不代表运行通过。计数仍16/26、3/15、2/3。
C19确认地点/坐标/持久化/指纹/测量/背景/Logo/海报/底片/水印及分配门控F111–F124；galleryMat低宽度会令照片超出画布。撤回T15/T16，连同C18共享基础缺口撤回T12，1.91当前13/26；1.93仍3/15、1.94仍2/3。
C20确认裁切准备/方向/比例/交互/接纳、头边界、原生完整性/EXIF/暂存/资源限制F125–F135；撤回T19，1.91当前12/26，1.93仍3/15、1.94仍2/3。
C21确认USB首帧错误提前stable、退出纯计时等待拖延、HD/普通重启保留旧画面F136–F138；计数仍12/26、3/15、2/3。
C22确认录像异常清模式、USB副作用记账、录制比例/错误/积压/PTS/同名覆盖及离页失败提示F139–F146；USB会话差异列V007待证，计数不变。
C23确认菜单写前异步重验及快门Range值域缺口F147/F148；撤回T06/N08，当前1.91为11/26、1.93为2/15、1.94为2/3。
C24确认焦框时效/交接/绘制缩放及暗角F149–F152，撤回N07；当前1.91为11/26、1.93为1/15、1.94为2/3。
C25确认曝光分析/状态恢复/采样、测光/统计图/音量及DISP缺口F153–F164，撤回T09/T10/T11，当前1.91为8/26、1.93为1/15、1.94为2/3。
另按用户问题复查更新：iOS仅残留文案，无版本查询/强更/APK/安装统计接线，B17排除继续有效。
C26确认监看LUT真实入口不可用及GPU/生命周期/目录/选择器缺口F165–F170，撤回T13，当前1.91为7/26、1.93为1/15、1.94为2/3。
C27确认方向生命周期/红框F171/F172，并因F167撤回T05；当前1.91为6/26、1.93为1/15、1.94为2/3。
C28确认常亮所有权及系统语言回退缺口F173/F174，计数不变。
C29确认公共拨轮/长按/三语/投影及退场输入F175–F180；撤回T25，当前1.91为5/26、1.93为1/15、1.94为2/3。源文案静态比较不是运行测试。
C30额度核心静态接线一致；C31苹果内购按平台替代审查，R01历史同步疑点及R02–R04外部配置仍未闭环，R05已纠正为当前模块联动缺口。
C32确认Wi-Fi Information配置回退F181及烟花混色F182；源码/测试归属索引共662文件，无未归属，不等于逐行覆盖或测试通过。
重读确认F052已有修复且另一轮17/17日志通过；F053已有IDLE屏障/存储排队回检及新测试，待该轮验证；F054/F055仍未修复，N01/N02不恢复完成。
本轮未运行测试或修改业务，审查完成；后续按跟进文档优先组修复并集中验证，不能把32/32审查进度当实现完成率。

2026-10-15 继续复核后，1.93 有效进度为 **9/15**（N16 按用户要求排除；N01–N08、N11 完成）。
N09 已补完全控制/录像持有、迟到命令退出清理、物理模式回读、竖屏槽位弹簧及横屏自适应 Dock，
集中回归 145 项领域/协议（3 麦克风跳过）+2 项 UI 通过。参数卡/全值表已继续补齐：真实值锚点、
越界/取消/回读、五行滚轮、AUTO 触区和横竖锚定列表；23 项集中回归、17 项补充及高亮修正 UI 通过，
详见 1.93 台账“参数卡与全值表”。快门/录制胶囊已接安卓长按、取消、独立动画、保存/暂停及按钮上方高级提示；
快门 17 项单元/生命周期通过，集中回归 22/22、真实工具栏补充 7/7 通过。以 StateObject 和显式新配置同步修正了快门旧 capturing
状态滞留，并隔离 UI 测试日额度。胶囊两种气泡的 Android 系统投影仍无完整 iOS 实现/验证依据，计时实景滑入还需核对，
N09 不能标完成。旧 1.91 T24 的阴影完成依据不足，已撤回；1.91 当前记录变为 24/26（T23/T24 未完成）。
N10 的规格/DISP/诊断块保留，但发现统一提示仍是旧顶部浮层，故撤回 N10 整体完成状态，
统一提示由 N10 独立收尾。调度器此前声称有嵌套拒绝却无实际标记，现已补 task-local 实现及测试，
本次证据与历史纠正详见 1.93 台账。当前工作树仍有此前裁切/效果/STA 等修改，必须保留；未提交或推送。

2026-10-12 用户再次要求拉取安卓、先记新功能再逐项复刻，并明确忽略鸿蒙部分。
已 fetch 并无冲突合入 `origin/android=89d78b451d03e50da965a46f047744aa8a34877c`（1.94/67），
合并 `ba319622`；相对 `8138e2de` 为 6 个提交/17 文件。入口为
[iOS 1.94 增量复刻任务台账](待做/iOS-1.94-增量复刻任务台账.md)。鸿蒙设备识别、SAF 发布兼容/journal、
最终仅 Harmony 启用的损坏诊断（原 N16）明确不迁移；安卓来源树保留供核对。普通 STA 保护筛选修复及
Debug 有界只读保护探测已完成开发侧复刻并通过审查；复刻保持 AP/USB RAW 评级探测，STA 头探测要求直读
能力已验证且不消费 ObjectInfo 保护位，不扩展为此前排除的全量属性/能力扫描。已有 35 个未提交修改完整保留；
本次同步不代表真机验收完成；旧 1.93 未完项不自动关闭，不自动提交实现改动或推送。

2026-10-07 追加同步：已在 `ios` 分支从代理 `http://127.0.0.1:7897` 获取
`origin/android=8138e2dec22aa8c8b998a7a9a7b2fa0b9f3a1ec5`，并以 `77fde8d9` 无冲突合入。
相对上一轮合并 `5d583d60` 新增 `f40f6bbf`（传输损坏诊断专用构建）和 `8138e2de`
（按类型目录 `ZT-` 前缀最终修正）。调度器没有新增行为，继续以
[全局任务调度器权威逻辑](技术调研/全局任务调度器权威逻辑.md)为唯一契约；追加范围和任务路由见
[iOS 1.93 追加同步核对](待做/iOS-1.93-追加同步核对.md)。本轮同步的按类型存放复刻已完成开发侧验证，当前由用户明确要求提交并推送；诊断专用取证仍未迁移。 N06 评级筛选 UI 已完成安卓最终浮层对照、自动化回归及 Debug 模拟器启动验证，尚未做真机验收。

2026-10-07 新一轮基准：用户要求再次拉取安卓到 ios，整理文档并继续逐功能完整复刻，特别阅读通用调度器说明。
`origin/android` 的 `2b2bf0c2802cacc909e9373562d912bce2d21175`（1.93/66）已无冲突合入 ios，合并 `5d583d60`。
相对 1.91 新增 62 提交/79 文件；本轮入口为 [iOS 1.93增量复刻任务台账](待做/iOS-1.93-增量复刻任务台账.md)，15 项独立计数。
权威调度契约为 [全局任务调度器权威逻辑](技术调研/全局任务调度器权威逻辑.md) 及最终源码，旧重构方案含过时描述。
新版星级筛选已经重新实现，必须迁移；下文和 1.91 台账“已回滚不迁移”的结论仅针对旧基准。
继续保留已批准 iOS 差异，先充分调查后实施，大块后集中构建/自动化，真机验收由用户负责。
本轮只获授权同步合并和实施，未授权后续自动提交/推送；合并记录本身属于所请求的同步操作。 N07 已完成开发侧复刻：多对焦框、显示裁剪、有效期门控、颜色/交接动画、工具持久化及 60 秒被动诊断均已接入并通过 127 项领域测试和 Debug 模拟器构建，真机验收仍由用户负责。

2026-10-08 N08 对焦模式与点按路径完成开发侧复刻：三种模式候选、手动门控、完整坐标域、AF 区域路径、三语提示、Z30 标签和响应透传已接入；补齐 D061 事件刷新、模式切换与迟到回读代次隔离、写入失败/异常后的回读、工具写入期间拍摄/录像/半按/点按互斥及模式按钮加载态。定向回归 `/tmp/ztransfer-ios193-n08-closure-regression.log` 为 85 项：82 项通过、3 项既有麦克风权限跳过；Debug 模拟器构建 `/tmp/ztransfer-ios193-n08-closure-build.log` 成功，已安装并启动 `com.ztransfer.ios`（PID 25323）。N08 标记复刻完成，待用户真机验收；总进度 8/16。

2026-10-01 用户要求将安卓分支合并到 `ios`，并以合并后的安卓实现作为新的复刻基准。
本次基准为 `android`／`origin/android` 的 `617082c3511e2532a321128b2f39c57217e74fc2`
（修复效果菜单主题切换定位跳动并精简界面），安卓 `versionName` 为 `1.91`。
后续开发与审查须以本仓库此次同步的安卓代码及对应测试逐项对照；旧任务完成记录不能证明
已覆盖新基准的新增或变更行为，须重新核对受影响项。此前用户明确确认的 iOS 平台差异和
优先规则继续有效。此次仅同步基准，不代表新增功能已在 iOS 复刻或验收完成。
验证：合并无冲突，`app/` 与上述安卓提交一致，合并未更改 `ios/`；未运行构建或测试。

2026-09-17 用户明确的 STA 照片列表加载规则优先于安卓现有的可见区域取图分支：
同一相机会话从头到尾顺序加载全部缩略图（包括 NEF），命中缓存就用缓存；滚动、筛选、
格子离屏和页面切换不得取消、重排或重启加载。前台预览、监看或传输需要通道时，
后台任务保留游标等待，再继续。格子只观察缓存，不拥有相机取图任务；失败数据不能当成成功缓存。

2026-09-18 用户要求：后续每次完成 iOS 视觉效果修改，都要构建 Debug 模拟器版本，安装并启动到
当前可用的 iOS 模拟器；以 `xcodebuild` 的 `BUILD SUCCEEDED` 和 `simctl install/launch` 结果为准。

2026-09-19 iOS 高级版讨论：年度套餐已确定为苹果自动续期订阅，用户可取消续订；永久版使用
非消耗型内购，方向为原生 StoreKit 2、无需自建授权后台。普通 StoreKit 方案不能在购买永久版后
自动替用户取消年费；用户已接受购买后引导到苹果管理页自行取消的替代流程，不得写成已支持自动取消。
功能限制、平台边界及实施状态见 [iOS高级版与苹果内购接入方案](商业化与授权/iOS高级版与苹果内购接入方案.md)。

同日用户明确：iOS 取消自有激活码，权益随购买所用的 Apple 账户（“媒体与购买项目”，不一定是
iCloud 账户），不随设备指纹绑定。逐项实现方式、替代机制、平台差异、验收和后续进度记录在
[安卓高级版全量审查与iOS迁移对照](商业化与授权/安卓高级版全量审查与iOS迁移对照.md) 的 A01–A15／B01–B17 台账；
后续实现必须维护该台账。用户随后确认支持苹果优惠码兑换解锁，由苹果管理兑换与交易，
不引入新的自有发码／激活系统；具体赠送期限、优惠规则和兑换入口布局仍需配置／确认。

同日用户明确保留年费的月均价展示，不采纳删除月均价的建议；按苹果年度商品价格换算，
同时清楚展示年度总价与每年扣费一次，不能把月均价展示成按月扣费套餐。

同日用户确认三组体验选择：剩余 5／1 次提示，正常自动续费不催买；任务中途失权时安全停止／保存
录制，且**所有已入队任务的生效水印不得改变**，包含相机传输后派生图和本地批次。这条用户规则
优先于安卓相机派生图“真正渲染前重新读取 isPro”的旧行为：入队时确定水印快照，重试沿用，
后续升级、到期、退款或编辑偏好不回写旧任务；新任务使用当前权限，不能冻结整个全局 isPro。
退款交给苹果；App 收到权益撤销后重算，仅在没有其他有效高级权益时令 isPro=false，复用免费逻辑，
不新增自有退款流程或手动清标记假装退款，不因降级清用户素材／配置或修改已入队水印。

同日商业配置确认：人民币目标价暂定年费 ¥39.99、永久 ¥99.99（苹果实际可选价格待后台核对），
保留月均价；年费转永久采用已记录的购买前说明＋购买后管理页取消流程；两种商品均不开家庭共享；
已付费订阅续订扣款失败启用 16 天苹果宽限期。当前不考虑安卓付费用户迁移。
优惠码支持免费赠送及付费折扣；付费折扣在苹果后台预设优惠后价格，用户通过苹果确认付款，
不是 App 临时减价或自有券服务器。具体折扣金额、期限和资格后续按活动配置，不能把示例当正式活动。

同日用户接受购买后约一秒的权益同步延迟，不把首次查询必须立即包含新交易作为产品要求，
不再为该瞬时缺失本身阻塞交付或反复优化。“一秒”来自本地诊断在等待后主动重查的观察，
不是苹果保证，也尚不证明 App 会自动更新。仍需区分短暂同步与持续停留在错误权益；
历史失败如实保留，不改写为已通过。当前按用户要求暂停开发，此次仅更新决定记录。

同日用户要求如实区分实现进度、验收和本人操作。当前进度入口为
[iOS高级版进度与配置操作清单](商业化与授权/iOS高级版进度与配置操作清单.md)：
R01–R04 是实现／配置遗留，U01–U09 列账户操作和开发交接步骤。迁移台账第 8 节的
32 项均有独立实现状态、策略及差异；不把后台配置或未验收重新写成客户端未开发。
口头“约 70%”不是正式完成率，3/8 仅表示原文档完整交付里程碑；按实际清单状态汇报。

2026-10-01 高级版既有实现已提交为 `296ba6b2`。进度清单扩展为 R01–R05：新增 R05 为
安卓 1.91 照片效果模块选择的复刻缺口（免费边框／水印联动、高级独立控制及独立作用域）。
旧 A01–A15 已接入的结论仅覆盖旧审查范围，不能当成新基准全部实现；本次仅静态整理，未跑测试。

2026-10-01 安卓增量静态梳理范围：`f5046780..617082c3` 的 57 个提交，按最终代码归类为
监看工具/姿态/参考线/缩放/DISP/Dock/曝光尺、监看与照片 LUT、JPEG 无损裁切、边框与元数据、
效果模块选择、传输生成双线及队列/预览交互。提交历史、最终源码、测试和设计记录须交叉核对；
本次不是逐函数全量审查，也未运行构建、测试或真机验收，不能据此标记 iOS 对应功能完成。
已确认历史覆盖点：星级筛选及 USB 损坏自动报告均已回滚；监看拍照后 FHD 回看仍是提案；
裁切最终保留未裁切原图；LUT 目录当前支持根目录及一级子目录分类；边框宽度当前源码为
60%～200%、步长 5%（旧文档仍写 10%），后续复刻以当前源码及测试为依据，不复制过时规格。

2026-10-01 用户授权按提交文件变化拆分安卓1.91增量，逐任务深入调查并完整复刻到iOS，最终统一由用户验收。
用户随后澄清：安卓测试是与生产代码并列的行为依据，必须参考并完整迁移相应 iOS 自动化测试。
每完成一大块功能后进行必要的构建及自动化验证，不每个小改动重复构建；真机测试和最终验收由用户负责。
该澄清替代本轮此前“跳过构建/运行测试”的记录，并覆盖旧的每次视觉修改自动构建安装规则；仍须如实记录测试结果。
任务状态采用“复刻完成，待用户验收”，只在实现闭环后标记，不把未实现/占位/依赖未接通写成完成。
入口：[iOS 1.91增量复刻任务台账](待做/iOS-1.91-增量复刻任务台账.md)，26项及完整提交/文件来源索引。

2026-10-01 增量复刻进度1/26：T01实时传输五档已接入设置/事件/队列/三语，旧布尔配置兼容迁移，
新增10项自动化及3项原队列回归在专用iOS 26.5模拟器通过（TEST SUCCEEDED，13/13）。
结果 `/tmp/ztransfer-ios191-t01.xcresult`。T01仅标记复刻完成待用户验收；T02调查中，其他任务未完成。
未提交或推送。后续T20加入裁切时补齐“裁切任务不参与自动去重”，T24继续公共拨轮视觉增量。

2026-10-01 T02继续实现：引导生命周期控制器和最终公共毛玻璃材质已接入，集中构建及40项测试通过，
结果 `/tmp/ztransfer-ios191-t02-lifecycle-fixed.xcresult`。T02尚有实体皮肤入口参数、无真实session的页面恢复
和滚动阈值集成待补，仍未标完成；总进度保持1/26，详细证据和首次构建失败已记入增量台账。

2026-10-01 用户再次强调：每个任务必须先“一切准备妥当了解清楚再开始复刻”，不能写很像的替代版本，
目标是完全复刻。开始实现前先完成对应安卓最终代码、相关提交、上下游调用、测试、文案/布局、动画参数、
状态/异常/取消/重试/持久化及依赖的调查；有未知项先查证，不用猜测、系统默认或近似方案补上。
这不是新增逐项审批要求，调查充分后继续自主实现。仅保留此前用户明确确认的平台差异；新增差异需要讨论。
T02虽47项测试已通过，实体阴影仍沿用旧iOS投影比例，未证明与安卓一致，不能标完成；T03保持调查阶段。

2026-10-01 T02材质纹理继续接入：三种材质80张纹理全部像素与安卓直接执行结果一致，
并已替换生产按钮的旧木纹/金属线条/相机颗粒，加入独立后台串行生成、请求去重和缓存。
集中验证`/tmp/ztransfer-ios191-material-integration.xcresult`为TEST SUCCEEDED，15/15通过。
T02仍未完成：完整反光/钢印、颜色过渡、按压、系统阴影/涟漪及默认调用位置纹理编号对应仍有遗留。
已询问用户系统效果以Android15还是其手机版本为基准，尚未收到回复，不将无回复当批准；可继续不依赖此选择的工作。

2026-10-01 T02实体反光与钢印已接入共享绘制层，准确参数与panel分支见增量台账。
首次17项验证16通过/1失败，暴露钢印亚像素按压没有变化；改用隔离绘制层和仿射偏移后，
`/tmp/ztransfer-ios191-material-finish-subpixel.xcresult`两项生产渲染测试通过。
当前仅静态/受控progress绘制完成，公共按钮仍用旧按压动画，Oklab颜色过渡和系统效果仍未闭环；T02不标完成。

2026-10-01 T02颜色数学路径已迁移：直接调用Compose1.7.6库生成144组参考值，Swift保留
D50适配/fastCbrt/半精度舍入/10位alpha/最终8位sRGB规则，生产相机丝印已消费该路径。
`/tmp/ztransfer-ios191-color-interpolation.xcresult`为TEST SUCCEEDED，10/10通过。
尚未让连续激活的每一帧消费Oklab，公共按压时序和系统效果仍待完成；总进度保持1/26。

2026-10-01 T02已让材质连续进度及相机丝印逐帧消费Oklab，毛玻璃/反光/高度/描边使用连续值，
颜色参考扩展为156组；新增90ms按压保持/取消/禁用/多事件状态模型。
`/tmp/ztransfer-ios191-material-progress.xcresult`为TEST SUCCEEDED，19/19通过。
注意：按压状态模型尚未接入真实按钮事件，独立缩放/光照帧时钟尚待实现，不能宣称完整按压反馈已完成；T02仍未完成。

2026-10-01 T02新增Compose1.7.6原生Swift动画方程及帧状态：直接执行安卓库生成90组动画参考
和1001个缓动点，保留初速度/中断/首帧/结束规则。集中验证
`/tmp/ztransfer-ios191-motion-kernel.xcresult`为TEST SUCCEEDED，17/17通过；来源及精度边界见增量台账。
新动画状态尚未替换生产ButtonStyle的旧驱动。另查明滚动容器延迟Press、提前松手补发Press/Release、
提前取消不发Press及手势抢占规则，真实事件桥接必须覆盖这些行为；不能仅接isPressed Bool。
总进度仍1/26，T02未完成，未提交/推送，真机验收仍交用户。

2026-10-01 T02公共Button现已消费独立的安卓缩放/光照/激活动画方程和帧控制器，原生点击同步执行，
补同帧成功点击的90ms显示保持，并处理滚动100ms延迟、取消、禁用和离页清理。保持Liquid Glass已批准例外。
新增生产样式的DEBUG隔离UI测试宿主及ZTransfer-Interactions scheme；四种安卓材质点击/禁用及滚动取消通过。
首轮主线程隔离编译错误已修；之后32项31通过/1失败为测试漏送回弹首帧，按安卓规则修正测试。
最终`/tmp/ztransfer-ios191-button-integration-final.xcresult`为TEST SUCCEEDED，15/15（控制器11/渲染2/UI2）。
尚未验证原生事件起点与安卓逐时刻一致，也未完成键盘多键/多指/触摸扩展区对照；不得宣称全输入时序完成。
系统阴影/涟漪/默认纹理调用身份仍未闭环；总进度1/26，T02不标完成，未提交/推送。

2026-10-01 用户指出“两小时总进度仍1/26”，质疑T02范围过大。已确认是任务拆分/优先级失误：
将公共材质渲染、颜色数学及通用输入机制全部当作T02前置条件，拖住业务迁移。现已在台账将这些
实现、未完项及完整证据移交T24统一处理，停止继续深挖触摸跟踪实验；不删除任何整体复刻要求。
T02回到三种连接断开、恢复及监看入口自身文案/几何/动画/业务范围，完成一次范围内收尾核对后再记进度，
不能仅因重新分类直接增加完成数。后续共享组件缺口在对应公共任务集中处理，避免任一业务任务无限扩张；
整体交付时仍核对全部任务和调用点，不以“共享任务另管”为由遗漏最终效果。

2026-10-01 T02按纠正后的业务范围收尾：重新对照安卓断连/恢复/引导源码和测试，修正列表进入队列或
监看后引导task仍可能继续计时的问题；计时绑定列表可见状态，取消沿用已验证的控制器清理与计数规则。
`/tmp/ztransfer-ios191-t02-business-closeout.xcresult`为TEST SUCCEEDED、20/20，App重新构建。
T02任务范围标为复刻完成待用户验收，总进度2/26；公共按钮渲染和输入机制继续属于未完成T24，不宣称整体UI已验收。
T03已开始调查，确认iOS缺普通扫描1/3首批及12/24/48缓存自适应，另需核对元数据身份/STA JPEG预览/磁盘缓存/已传身份。
STA会话全量顺序加载的已批准规则保持不变；未提交或推送。

2026-10-01 T03开始实现：STA JPG的单候选MPF增强、640长边/JPEG90、旧低清缓存隔离已接入生产，
并防止后续预览读头覆盖增强图。App集中测试22/22通过，真实PTP协议测试18/18通过，证据见台账。
总进度仍2/26；T03尚缺扫描自适应/元数据身份/已传识别闭环，不标完成。保留STA会话全量顺序规则。
未做真机测试，未提交/推送。

2026-10-01 T03扫描反馈已接通：预存缓存命中与新下载/负缓存区分；普通单卡首批1/3和12→24→48
自适应由生产列表→会话→仓库消费。集中27项测试通过（t03-scan-batches.xcresult），含真实ObjectInfo回放。
双卡旧预读循环仍需改为安卓缺失卡头补齐，不能据单卡通过标双卡完成；保留STA特殊预算的构建后两行调整
将在双卡块一并验证。总进度2/26，T03继续实现，元数据身份/已传识别尚待闭环。未提交或推送。

2026-10-01 T03双卡已改为按缺失head补齐的安卓归并流程，修正残缺ObjectInfo完整性标志、同批备份卡归属，
并通过真实PTP取消/恢复及热缓存批次回放。首次新增测试闭包参数编译错误已修；最终双卡块18/18通过
（t03-dual-card-fixed.xcresult），包括前次STA预算调整。总进度2/26；下一步跨模式已传编号匹配与元数据身份。
未做真机测试，未提交/推送。

2026-10-01 T03跨AP/STA已传识别已接通目录和导出索引，按安卓末尾编号+扩展名匹配前缀差异，保留
大小/目标目录/精确名优先/裁切区分；真实文件扫描及既有回归7/7通过（t03-exported-identity.xcresult）。
总进度仍2/26；T03剩余元数据来源身份实际接线：TransferQueue句柄缓存、可换session、retry快照及
CameraSession.frameMetadataHeader重连校验均需处理。不得仅加辅助函数后标完成。未提交/推送。

2026-10-01 T03收尾完成待用户验收，总进度3/26。元数据身份已接入实际相机/后台EXIF/生成缓存与单项、
批量重试；已知机身可重连但须核对原文件，未知机身连接隔离，无来源任务不能在重试时绑定新机身。
metadata-retry31/31通过；首次下载writer回归失败为测试读取URL缓存属性，改实时文件属性后通过。
缓存90天保留期改按.last_connected内容/标记mtime，legacy对完整字符串按安卓ASCII正则清理；
cache-audit22/22、cache-final9/9通过。T03逐要求证据表已记录，不等同真机验收或T22/T24完成。
T04开始调查普通预览：已读三个对应安卓测试，尚未实现。未提交/推送。

2026-10-01 T04普通预览与会话/解码生命周期范围完成待验收，总进度4/26。统一相机FHD、提前显示而不等EXIF、
内存/磁盘/远程兜底门控、真实捏合及布局中心、页码/方向/信息动画、本地可见页解码已接入。t04-audit125/125
（含生产预览UI序列），最后调整t04-final-insets2/2及App重编译通过。大文件内HistogramMode、裁切、工作台
单图放大和公共控件分别仍归T09/T19–20/T23/T24，不等于全文件完成。T05监看工具配置开始调查。未提交/推送。

2026-10-01 T05继续实现：工具配置保存模型及现有工具顺序/显隐已接生产，隐藏录制的准入/授权回调检查、
竖屏停止保存及横屏固定控件保留已补；t05-record-visibility13/13、t05-fixed-recorder7/7通过，包含真实MP4解码。
仍缺原位编辑、模式Crossfade、完整工具集合和生产UI验证，T05未完成，总进度4/26。未提交或推送。

2026-10-01 T05已接编辑入口、显隐/拖动、普通工具动画与高度动画；锁定工具及方向保存/隐藏解锁已接生产。
最新t05-lock10/10通过（含2项真实RemoteView UI）；完整工具集合、管理/固定槽位动画及更多边界仍未闭环。
T05未完成，总进度4/26；详细各块证据以增量任务台账末尾为准，未提交/推送。

2026-10-01 T05管理/固定槽位已接共用动画时钟；修正Layout直接读取Environment导致屏幕倍率默认为1的问题，
由工具栏传入真实倍率。t05-fixed-slots-density11/11通过（含2生产UI），xcresult无运行时警告。
T05仍未完成、总进度4/26；完整工具接线依赖T06/T09/T10/T11/T12–13，按原任务实施后回到T05核对，
不再将后续整项功能压进工具栏任务。未提交/推送，真机验收仍交用户。

2026-10-01 T06相机工具基础开始实施：照片/录像WB与对焦区域候选查询、机型/数据类型名称、选项排序和三语
已迁移；t06-camera-tool-base13/13通过并完整App编译。面板尚未接入，PC控制诊断仍缺，T05/T06均未完成，
总进度4/26。面板加载/写前再查/不可取消写回/实际测量后Genie等调查规格见台账最新T06记录，下一步继续接线。
未真机验收，未提交/推送。

2026-10-01 T06工具菜单控制器已接生产RemoteViewModel：读超时/轮询、写前重新核对、失败重试、已发送写入
不可被菜单退场拆开、监看退出等待回读后释放通道。t06-tool-lifecycle13/13通过，App重编译。
实际按钮/锚定菜单视图尚未接入，对焦追踪响应完整回放和诊断开关仍缺；不能称菜单功能完成。总进度4/26。
未提交/推送，下一步继续真实菜单布局/交互接线。

2026-10-02 T06白平衡/对焦区域真实按钮及锚定菜单已接入，含机身名称、WB三列、焦点排序、写入后关闭和
重新打开选择恢复；初次菜单零高度UI失败已修，tool-menu-measure5/5、tool-menu-close2/2通过。
公共Genie仍有T24遗留，T06诊断/能力查询及剩余边界未完成，总进度4/26。下步核对旧开发者面板“不发探测命令”
注释是否有已批准差异来源，再继续剩余范围；不能单凭注释删除任务要求。未真机验收、未提交/推送。

2026-10-02 找到既有明确平台范围例外：docs/iOS-STA-行为优先级与加载策略.html#M35（第116行）与
全链路对照R10记录用户确认排除实验性全量能力探测、属性扫描、追踪矩阵和临时属性写入。必须继续保留。
新增PC控制诊断开关是否也排除，已异步询问用户，尚无回复；不擅自决定、不阻塞正常工具与其他任务。
T06额外3项追踪释放/轮询异常/关闭迟到结果测试通过（tool-boundaries），总进度4/26，未提交/推送。

2026-10-02 T07已开始：全部10种参考线的Float几何及生产绘制消费持久化偏好已接入，移除旧三档局部状态。
安卓FramingGridTest的6项测试已迁移但未运行；菜单、模式图标和缩放/平移/对焦坐标仍未完成。
待形成完整功能块集中构建验证，不因基础代码完成增加进度；总进度4/26，未提交/推送。

2026-10-02 T07参考线菜单、模式图标与三语已接入生产，提取共用RemoteChoicePopup并回归相机工具菜单。
几何/定位/生产UI集中13/13通过（t07-grid-menu）；首帧前参考线及反挤压占位修正后再编译，定向UI1/1通过
（t07-grid-placeholder）。旧1–4倍中心缩放仍待替换，缩放层与固定仪表层的安卓边界已调查记录；T07未完成、总进度4/26。
未真机验收，未提交/推送。

2026-10-02 T07已接1–8倍视口、平移边界、固定图像窗口裁切、导航框与对焦逆变换；网格/斑马纹/对焦框
随图像变换，统计图/仪表固定。修正旧反挤压重复拉伸。8项视口/输入+6参考线单测通过；UI双击首次失败，
触摸实测确认XCTest第二down间隔约13微秒，小于安卓40ms。保留生产规则，改用忽略过早触点后接有效触点的
序列，t07-touch-timing 1/1通过并App重编译，覆盖捏合/平移/复位/反挤压切换。
T07仍需增减触点/取消、黑边触点、实际对焦与渲染尺寸收尾；总进度4/26，未真机验收/提交/推送。

2026-10-02 T07补存续触点down/up采样与黑边首次down不启动双击识别；pointer-boundaries9/9通过。
生产图像提取RemoteViewfinderImage，真实像素验证5倍率×2容器白条宽度无重复拉伸；t07-rendering14/14通过，
包括8视口+1渲染+5生产UI，App重新编译。最终仍发现待发点击未在原图尺寸/显示比例/Tracking及AF坐标尺寸变化时
取消，与安卓pointerInput key生命周期不同，下一步先修此明确遗留并核对实际对焦接线。T07未完成，总进度4/26。

2026-10-02 T07任务范围收尾完成待真机验收，总进度5/26（T01–04、T07）。输入身份变化取消待处理点击已接入，
对焦逆变换→生产模型→相机接口及确认标记闭环验证；input-lifecycle4/4通过。参考线单行20+上下16=36高度修正后
row-height1/1通过，App重编译。覆盖表见台账；共用Genie仍归未完成T24，未提交/推送。
T08开始调查，已读compact-v1姿态解析、全部5姿态测试、2水平仪测试及轮询/绘制规则；下一步继续上下游和iOS现状核对。

2026-10-02 T08 compact-v1双轴帧头解析已接真实解码；生产水平仪优先1500ms内帧头，缺失回退D067，
3失败只停属性查询并继续等待帧头恢复。纠正旧“不支持就关闭开关”和固定3次refresh契约，按安卓保留偏好并重新describe。
全部5姿态样本+4生产来源/恢复测试通过（t08-attitude-source9/9），App重编译。旧IOSLevelOverlay尚未替换，
双轴绘制、独立滞回与100/160ms动画待实现；总进度5/26，未真机验收/提交/推送。

2026-10-02 T08显示计算RemoteHorizon及安卓两项水平仪测试已迁移，另补独立俯仰用例；未运行，未接绘制。
后续双轴Canvas及100/160ms动画应直接消费这些规则，形成完整块后集中验证。总进度5/26。

2026-10-02 T08双轴圆环、俯仰弦线、独立对齐和100/160ms帧动画已接生产，旧IOSLevelOverlay已删除。
新增Oklab四分量颜色动画按官方Compose1.7.6转换器，颜色数学复用已验证公共实现；horizon13/13通过并App编译。
仍需实际绘制/生产双单轴切换及新颜色动画逐帧参考核对，不能以旧lerp回归代替该验证；T08未完成，总进度5/26。

2026-10-02 T08实际圆环渲染测试2/2通过；新增真实Compose1.7.6颜色向量动画64组参考，首次3帧差1级。
修正整个向量重新定向时不变分量也需启动的问题，color-vector-fixed13/13通过、64组逐ARGB一致，App重编译。
仍需生产页面单双轴切换最终核对，T08未完成，总进度5/26。未提交/推送。

2026-10-16 F067文本边界阶段：已对照安卓将快照字段限制256 UTF-16单位且不拆代理对，接cameraSnapshot与makeFrameReady缓存/任务/recipe统一入口。f067-bounds.log为72/72，f067-bounds-production.log为1/1，均TEST SUCCEEDED；真实JPEG超长model经过生产下载后渲染和保留快照均受限。F067完整性状态/扩读/无EXIF与LRU缓存/原始头预算仍未完成，F066独立parser亦未完成；核销仍18/182。未真机、未提交/推送。

2026-10-16 F067第二阶段：JPEG结构+四态PreparedPhotoMetadata、部分头1MiB/2MiB扩读、失败保留字段、生产maxBytes贯通且backgroundThumbnail/来源校验保留；256项访问顺序缓存保留NO_EXIF和最终PARTIAL、FAILED不缓存、不再每run清空。f067-expansion.log 102/102，f067-expansion-cap.log 1/1，均TEST SUCCEEDED，真实下载大APP2头扩读成功、无EXIF/最终PARTIAL跨重试不重复读、上限2MiB均验证。F066/F067仍未核销（18/182）：捕获头现为run同步PreparedPhotoMetadata.parse，仍需独立parser、2MiB内存/16MiBspool及同键pending共享；禁止把原始头无限排队。构建已结束，未真机/提交/推送。

2026-10-16 F066/F067开发侧闭环：新PhotoMetadataPreparation.swift集中结构/结果/LRU及HeaderStore；下载不再解析，独立身份/parser/补读consumer，捕获与补读解析统一串行actor。2MiB内存/16MiB磁盘预算、ticket释放/失败回滚、旧进程清理与同进程保护、同key等待者共享（含FAILED）及关闭迟到隔离已接线。f066-parser-serial-fixed.log 109/109；f066-parser-boundaries-fixed.log最终8/8，均TEST SUCCEEDED。中间身份夹具缺失/重载缺失、漏await编译失败和边界测试失败日志保留；最后发现单批入队去重，早先109中的共享测试只有1项，不可作为共享证据，已改两次入队并断言2任务，最终8项证明确实共享且一项渲染失败不影响另一项。默认预算、写入失败恢复、解析阻塞后续下载和关闭spool释放均验证。当前20/182，索引666（新增源/测试），F068仍未完成。未真机/杀进程/RSS验收，未提交/推送，所有构建结束。

2026-10-16 F068第一阶段：PhotoGenerationTiming统一queue/start/pause/finish及ContinuousClock毫秒域，普通效果准备/排队不计时、计算slot后开始、未实际保存不留终值；UI仍200ms刷新但不按Date求差。f068-clock.log 85/85 TEST SUCCEEDED，实际准备5000+计算500只记500、第二任务不含第一5000等待、失败/已有图无耗时及暂停累计模型均验证。F068仍未核销（20/182）：裁切暂停累计只有状态模型验证，下一步结合F072将三条裁切路径从下载worker交接计算，修正下载耗时与裁切等待边界。索引668，未实际系统校时/真机/提交/推送；构建结束。

2026-10-16 F072闭环：三路原片完成只发布/交接，run不再await裁切；裁切/普通效果共用单计算slot与4096容量，下载耗时提前冻结，FrameJob保留root授权，cropURL先记再检查取消、效果重试复用裁片。f072-handoff.log85/85，f072-routes.log42/42，f072-lifecycle.log12/12，均TEST SUCCEEDED；三路慢裁切不阻塞下一张、混合slot串行、正常metadata5000等待后crop200+effect300计500、失败重试单裁切、关闭活动发布/等待取消均验证。完整part使用MOV+注入crop的分支夹具，不声称真实视频裁切或放宽照片resume；原真实native取消测试已适配原片COMPLETED，仍验证保留发布/不重启下载。F072开发侧核销，当前21/182、索引668。F068动态暂停恢复仍待F069：安卓总开关开启先等metadata；关闭可提前执行，裁切时重新开启才可能pause等metadata，不能擅自让所有crop先跑。下一步F069并补F068动态边界；F071普通本地效果失败整卡状态、F070重试仍未修复。未真机/提交/推送，构建均结束。

2026-10-16 F069运行期核心已接setPhotoEffectsEnabled/reconsider、frameGenerationSkipped/cropEffectsSkipped、未准备任务关闭时可执行、独立准备容量默认4096（防跳过计算后无界补读）；recipe/水印不改。F068动态闭环通过：crop200→开启后等待metadata5000→effect300最终500，等待中关闭保留200，恢复不重裁；UI同单调时钟并有裁切/跳过资源入口。f069-runtime-isolated.log52/52，f069-download-regression.log42/42，均TEST SUCCEEDED。两个先前runtime编译失败为UserDefaults的MainActor隔离；queue不长期持有defaults，测试helper改返回suite名称后调用处独立创建，未改用户standard偏好。F068开发侧核销，当前22/182。F069仍缺PhotoEffectsStore总开关持久化、RootView变化传递、SettingsView入口/动画和UI验证；backend setter本身不写偏好。安卓开关在SettingsScreen.kt:5411，48×32触区/36×20轨道/半径7thumb、180ms tween位置及Oklab颜色、RTL反向、tick；RemoteHorizonColorAnimation可参考但固定160ms需合理复用，不直接照搬。设置草稿/本地照片作用域独立不清空。索引668，下一步完成F069设置端；未真机/系统校时/提交/推送，构建结束。

2026-10-16 F069设置端完成：PhotoEffectsStore独立isEnabled/setEnabled持久化photo_effects_enabled默认true，仅cameraTransfer可写；RootView.task(id:)传运行期状态，原recipe/水印/本地photos不变。设置卡片开关与编辑入口拆分，48×32触区/36×20轨道/14thumb、180ms位置和Oklab颜色、RTL、Switch无障碍语义/tick；抽出ZTransferColorAnimation默认160ms保留水平仪。f069-settings-fixed.log25/25 TEST SUCCEEDED（含既有64组颜色参考）；首轮旧类型名编译失败保留。f069-settings-ui.log1/1 TEST SUCCEEDED，真实SettingsView/store隔离DEBUG宿主证明点击开关不进编辑、进入/返回编辑不改总门控、重启关闭且recipe保留；RootView接线静态核对，不声称真机相机工作区端到端。已查看关闭态截图/tmp/ztransfer-20261016-f069-settings-ui-attachments/A5C9B5A1-729A-408F-BC0E-B2CA51569050.png，布局正常。F069开发侧核销，当前23/182、索引673；下一步F070独立派生重试/F071本地原片失败状态。未真机/提交/推送，所有构建结束。

2026-10-16 F071已移除failTaskOnError全链路参数及整卡失败分支，已有原片／完整part与新下载统一仅frameError失败，保留COMPLETED及原下载记录。纠正旧错误测试断言；f071.log为90/90、0失败、TEST SUCCEEDED（下载42、metadata16、队列32），diff检查通过，开发侧核销24/182。F070尚未修复：retry依赖当前目录和下载队列，下一步保存原始root/parent/source与授权生命周期，验证清／换目录及暂停下单条／批量独立重试。未真机／提交／推送，构建结束。

2026-10-16 F070独立派生重试完成开发侧：保存source/parent/root，重新获取旧root lease，直接生成并保留下载指标/metadata，单条批量共用规则。f070-fixed.log 91/91 TEST SUCCEEDED，四组清/换目录和暂停边界、子目录、授权释放验证通过。首轮空闲暂停断言失败、第二轮测试参数顺序编译失败保留。当前25/182，下一步F073页面离线启动；F077按钮资格未修复。未真机Provider/提交/推送，构建结束。

2026-10-16 F073开发侧启动接线完成：手动单/批/裁切ViewModel仅需目录，显式start可空session，页面启动按钮与裁切回调移除额外连接门控；自动新增仍需连接。f073.log45/45 TEST SUCCEEDED，实际ViewModel四组单/批立即/延后及两组真实JPEG裁切验证；页面仅静态调用核对，未UI/真机验收。当前26/182，F034缺原片整批拒绝、F130裁切接纳反馈、F075按钮显隐仍未修复；下一步F034准入。未提交/推送，构建结束。

2026-10-16 F034第一阶段已接当前root/storageMode整批原片索引检查，页面单/日期组/预览单/连拍入口拒绝在震动飞行入队前；信号120ms到1.15+400/.5回弹、连续中断/离页复位。f034-admission.log41项中测试typed任务漏folder导致1失败（队列35通过），f034-admission-fixed.log6/6通过。尚未核销，26/182：发现旧remoteEntryHint在监看入口且预览层下，下一步按安卓底部提示Surface/AnimatedVisibility补层级/布局/动画/文本退场/1800ms计时，之后页面UI验证。F130裁切准入独立未完成；未提交/推送。

F034第一阶段Debug模拟器构建：/tmp/ztransfer-20261016-f034-build.log BUILD SUCCEEDED；simctl install与launch成功。仅启动主App，不作为信号动画或预览提示的页面验收；F034保持未完成。

2026-10-16 F034提示层已接PhotoListHint，在预览/飞行层上方，spring400 fade+半高IntOffset、1800ms最新消息计时/文本退场保留、离页取消。f034-hint-height.log8/8、f034-hint-ui.log1/1通过，真实预览+模拟拒绝回调截图已看，提示可见且预览不关闭；不是完整列表准入E2E。新增文件索引674。仍未核销26/182：安卓Surface6dp投影未实现，完整列表单/组/预览拒绝无飞行/无入队及重连路径需UI证据。未提交/推送。

F034提示阶段最终Debug构建f034-hint-build.log BUILD SUCCEEDED，simctl install/launch成功；构建已结束，未真机/提交/推送。

2026-10-16 F034真实列表UI：PhotoListAdmissionHarness注入目录/会话/权限，真实PhotoListView+queue+预览拒绝回调。f034-real-list.log最终3/3通过，单缺失/混合日期组拒绝无队列/flight/held残留，原片离线完成，重连延后WAITING，真实预览拒绝提示可见且不关闭；截图已看。首轮宿主self捕获编译失败保留，之前2/2日志亦保留。新增宿主索引675。仍26/182：折叠连拍合集UI尚缺，Surface6dp投影归F179/T24未完；下一步继续这两项，不能将3项当全范围验收。未真机/提交/推送，构建结束。

2026-10-16 F034合集闭环：真实3张同秒连续号，列表plus/预览合集×部分缺失/全本地四组，f034-burst-ui-fixed.log1/1通过；ID下移后普通列表/重连/预览f034-cell-id-regression.log3/3通过。首次burst日志失败因父ID覆盖plus，保留。F034交互已有证据但仍26/182，提示6dp投影未实现；下一步集中F179/T24公共投影。Android15默认灯Y0 Z500 radius800、alpha.039/.19及窗口/屏幕光源变换已查，Material覆写/Skia固定版本/GPU圆角快速路径尚待核对，详见台账。未真机/提交/推送，构建结束，索引675不变。

2026-10-16 F179参数第一阶段：固定android-15.0.0_r1，新增ZTransferAndroidShadowMetrics（Float设备像素ambient/spot参数+128A8），原生generator提取原Skia函数体/循环并校验两源SHA，带BSD许可。f179-metrics.log2/2通过：24组/128字节一致；生成器后续直接提取falloff循环再生与已测bundle逐值相同。未接生产渲染，不算阴影完成，F179/F034仍未核销26/182；索引678。下一步固定SurfaceDrawContext.drawFastShadow及ShadowRRectOp的fill/stroke/overstroke网格、插值/纹理采样、非快捷路径与实际像素参考，之后接公共投影和提示6dp。临时原始文件/tmp/ztransfer-shadow-android15；脚本/fixture已保留。未真机/提交/推送，构建结束。

2026-10-16 F179圆角网格：已补非circle fill/stroke/overstroke，保留类型判定先于umbra限制的顺序。generator直接提取固定Skia构造计算/顶点函数/索引，54组全部顶点/索引对照；f179-mesh.log3/3、TEST SUCCEEDED。尚未接生产绘制，26/182不变；下一步圆形八边形、shader线性A8采样/half精度和像素参考、非快捷路径及Surface接线。GrShadowGeoProc.cpp已取至/tmp/ztransfer-shadow-android15，源码为length(offset)、uv=correction*(1-d)、linear sampler。未真机/提交/推送，构建已结束。

2026-10-16 F179圆形网格：fill八边形+中心/stroke双八边形已补，保留原始内环常量0.923579533/0.382683432；固定原函数60组所有顶点/索引对照，f179-circle.log4/4 TEST SUCCEEDED。新增固定Android15 ReorderBarrierDrawables.cpp取证，SHA8b88d7d771e0afb0d04c41fbc1c3fc7c67e10d6fa85e72521ed589f0706a0fb1，位于同tmp目录；后续alpha/透明遮挡用此，非master。尚未生产绘制，26/182不变；仍需实际shader/采样/像素参考、投影组装和页面接线，非快捷路径未完。未真机/提交/推送，所有构建结束。

2026-10-16 F179 Metal绘制层：新增ZTransferAndroidShadowRenderer，复用pipeline/LUT，半精度varying/length、linear clamp LUT、BGRA8 source-over，encode不等待/读回。首轮shader half3(float2,float)构造失败2项，改half3(float3(...))后f179-metal-fixed.log6/6 TEST SUCCEEDED；128×8纹理ramp/双层叠加及真实圆形fill/stroke像素读取通过。仅局部GPU证据，未生产页面调用、未完整Android像素对照；仍26/182。下一步HWUI投影组装/alpha/光源坐标、非快捷路径和Surface/提示接线。新增生产文件索引679，xcodegen已跑。未真机/提交/推送，所有构建结束。

2026-10-16 F179投影组装：shadowGeometry已接正向等比scale/translation ambient+spot，明确light设备/caster本地坐标，透明填充/不透明覆盖范围、circle类型保留；f179-projection.log8/8 TEST SUCCEEDED（已知数值/光源移动/scale2+平移/拓扑+此前GPU回归）。未提取完整SurfaceDrawContext对照、未页面接线，非正scale/旋转/路径/透视仍未完，26/182不变。下一步HWUI光源/alpha和实际宿主接线，再做完整像素/UI验收；索引679，未真机/提交/推送，所有构建结束。

2026-10-16 F179光源/alpha：materialLighting接AOSP默认灯及display/density/window坐标；opacity保留JNI主题先截断9/48再乘node*outline后截断。f179-lighting.log10/10 TEST SUCCEEDED，AOSP-shadow-NOTICE已纳资源。outline alpha不能取Surface背景0.92/0.95；下一步页面宿主需避免动画opacity重复衰减并跟随位移光源，非快捷路径/完整像素UI仍待做。尚未页面接入，26/182不变，索引679；未真机/提交/推送，所有构建结束。

2026-10-16 F179有界scene：renderer.scene串联light/opacity/投影/mesh，返回窗口pixel origin+整数extent+局部两层。必须先投影后裁切；完整200×180/裁切GPU在opaque和alpha0.5共72k像素比较通过（容差1），f179-scene.log11/11 TEST SUCCEEDED，零高/隐藏返回nil，负scale报错。仍未实际页面宿主，下一步按origin摆放并处理动画/opacity，再做UI验证；这不是独立Android像素参考。F034/F179未核销26/182，索引679，未真机/提交/推送，所有构建结束。

2026-10-16 F034/F179首个宿主：AndroidShadowView/Host共享Metal资源、window坐标/有界scene/按需绘制，PhotoListHint已接6dp。安卓AnimatedVisibility父层fade，Surface nodeAlpha1；故shadow在.opacity之前一起淡出，不能把父alpha再传shadow或用background alpha。仅无缩放旋转提示宿主，公共Surface未换。首build因CGPoint.zero歧义失败保留，host12/12、host-ui2/2 TEST SUCCEEDED；真实预览截图234C56EB已看，提示正常，非独立Android像素参考。host-build-fixed BUILD SUCCEEDED，simctl install/launch PID41082成功。仍26/182：动画光源/淡出完整像素对照、公共Surface及非快捷路径尚未完；索引680，未真机/提交/推送，构建结束。

2026-10-16 F179宿主支持正向等比scale，按窗口基向量读取，scene投影用scale，UIKit子画布逆scale摆放、drawable保留设备像素。0.8宿主测试首轮5断言失败因网格多余radius<=halfMinimum校验；夹紧版通过后按原ShadowRRectOp撤掉夹紧，仅删除额外拒绝，最终f179-host-scale-source12/12通过。非等比拒绝/恢复清错误亦通过。f179-scale-build BUILD SUCCEEDED，simctl install/launch PID41610。未重跑UI；公共Surface尚未替换（旋转/非快捷路径待补），仍26/182、索引680。未真机/提交/推送，所有构建结束。

2026-10-16 F179直角旋转：QuarterTurn贯通metrics/scene/host，spot逆CTM与旋转bounds，Metal子画布逆基变换用bounds/center对齐窗口像素。quarter-host13/13通过，quarter-ui真实预览1/1通过截图8F683279已看；quarter-build BUILD SUCCEEDED，simctl install/launch PID42070。RemoteView横屏±90°，但RemoteEntryReveal/工具编辑存在任意小角度，公共Surface仍不能整体换；下一步通用Skia路径/任意角度及独立像素参考。未完成26/182、索引680；未真机/提交/推送，所有构建结束。

2026-10-16 F179通用Gaussian绘制：固定SkShadowUtils/Tessellator/GrFragmentProcessors已下载tmp，GPU通用路径用插值vertex alpha直接exp(-4*(1-a)^2)-.018，不是128LUT，也不是CPU quartic。renderer新增TessellatedVertex/Layer/encodeTessellated和独立fragment，共用buffer/encoder；GPU ramp4096像素对Double公式容差1通过，f179-gaussian14/14 TEST SUCCEEDED。仍缺通用轮廓细分/convex环/塌缩修正/spot裁切及页面调用，不能声称任意旋转已支持。下一步按固定SkShadowTessellator补几何，公共Surface未换，26/182、索引680；未新增页面视觉/安装，未真机/提交/推送，测试结束。

2026-10-16 F179轮廓准备：ZTransferShadowPolygon实现Skia1/16量化、duplicate/共线清理、area/centroid/convex/direction；原生generator直接提取固定SkShadowTessellator方法，14组完整输出对照通过，polygon.log15/15 TEST SUCCEEDED。负半值遵守float*16→Double floor+.5。新增生产/fixture、xcodegen、索引681。下一步曲线细分、inset/内外环/塌缩/spot裁切，通用阴影尚未完成，公共Surface未换，仍26/182。未页面视觉变更/额外安装/真机/提交/推送，测试结束。

2026-10-16 F179 Bezier：ZTransferShadowCurve补设备quad/cubic .2阈值+Wang点数/1024cap+原递归顺序/距离运算，固定原C++函数10组逐点精确一致。生成器首轮float4适配编译失败已修，常规9组16/16后纠正NaN退化条件并加1e30输入，最终f179-curves-final16/16 TEST SUCCEEDED；generator-final成功。fixture已xcodegen，索引681不变。下一步conic转quad（圆角依赖）、路径接线和inset/内外环/spot裁切；通用阴影未完，公共Surface未换，26/182。未页面视觉/额外安装/真机/提交/推送，测试结束。

2026-10-16 F179 conic：ZTransferShadowConic实现SkGeometry非legacy chop/.25误差/32quad/单调修正/极端退化及quad→polyline，19组原函数控制点/折线对照。首conic17项1失败定位参考C++ host默认FMA；Android15 Soong global.go明确-ffp-contract=off，已修generator全部编译选项并再生所有旧fixture。最终conic-fixed17/17 TEST SUCCEEDED，generator-fixed成功；此前host默认浮点参考的目标编译一致性声明已纠正，当前全回归取代。新增生产/fixture索引682/xcodegen；下一步完整轮廓组装/inset/内外环/spot裁切，公共Surface未换，26/182。未页面视觉/额外安装/真机/提交/推送，测试结束。

2026-10-16 F179 umbra：同文件新增ZTransferShadowUmbra，复用线段距离，按固定Skia质心最近边距离/.01退让/整数SkPMLerp alpha截断修正内环塌缩。原生generator提取原调整块+原距离+SkColorData原64位插值，91组含34塌缩逐项一致；f179-umbra-generator成功、f179-umbra18/18 TEST SUCCEEDED。宿主appearance transitions警告保留，非视觉验收。fixture已xcodegen，索引682不变。下一步完整路径/inset边删除与内外环/spot裁切，尚未通用生产接线、公共Surface未换，26/182不变。无页面视觉变化/额外安装/真机/提交/推送，测试进程结束。

2026-10-16 F179 inset：新增ZTransferShadowInset，完整移植SkInsetConvexPolygon的绕向/交点/无效边删除回退/重合清理/凸性收尾；数组整数链接保留删除节点旧邻居，SkPoint归一化Double中间计算。固定原C++函数667组逐点/有效性一致（357有效、310无效、40有效减点），含91组umbra交接；非有限/UInt16顶点数边界另测。inset-generator成功、f179-inset19/19 TEST SUCCEEDED。新增生产/fixture已xcodegen，索引683（iOS生产213）；下一步路径组装/内外环圆弧与spot裁切/公共Surface接线，F034/F179仍未完26/182。无页面视觉变更/额外安装/真机/提交/推送，测试结束。

2026-10-16 F179 convex mesh：新增ZTransferShadowConvexMesh，串接umbra/inset，实现最近内点/合并/失败质心.95回退、radialSteps圆弧、内外环三角形及闭合；凸clip边/质心露出中心扇形也已补。原始inset控制尝试内环、修正后inset控制选环，保留负修正失败回退。原生generator首轮缺float除法shim编译失败已修，720组20/20后补小clip与极细三角形，最终1056组所有顶点/alpha/索引精确一致，convex-generator-final成功、f179-convex-final20/20 TEST SUCCEEDED；IOSurface通知警告保留，非页面验收。新增生产/fixture已xcodegen索引684/iOS生产214。下一步完整路径和spot投影接线、凹/一般变换、renderer/host及独立像素；公共Surface仍未换，26/182不变。无页面视觉/额外安装/真机/提交/推送，进程结束。

2026-10-16 F179 path：新增ZTransferShadowPath/Transform，单轮廓强制闭合（move不输出/尾move忽略/多轮廓拒绝）、四类线段变换后细分、透视conic齐次权重Double修正及独立spot clip采样。原SkPath Iter/Tessellator handlers/SkMatrix/SkConic函数参考144组全点/clip/area/centroid/convex/direction精确一致，path-generator成功、f179-path21/21 TEST SUCCEEDED；IOSurface警告保留非视觉验收。新增生产/fixture已xcodegen索引685/iOS生产215。下一步圆角path构造/高度光源spot投影与renderer-host接线，凹轮廓和独立像素仍缺；公共Surface未换26/182不变。无页面视觉/额外安装/真机/提交/推送，测试结束。

2026-10-16 F179 spot：新增ZTransferShadowProjection及Transform.concatenating，原GetSpotShadowTransform普通/方向/透视四角/倾斜平面/退化拒绝和SkMatrix Float/Double分支；SkRect中心经查实际Double midpoint，修正实现及参考并加大坐标。245组矩阵/outset/有效性精确一致（228有效17拒绝），spot-generator-final成功、f179-spot22/22 TEST SUCCEEDED。新增生产/fixture已xcodegen索引686/iOS生产216。日志appearance警告及新观察link.slash缺失（GPSConnectionControl.swift:598）保留，后者待C05对照，不能忽略为页面通过。下一步圆角path/ambient高度/投影网格renderer-host整合，凹轮廓/独立像素仍缺；公共Surface未换26/182。无页面视觉/额外安装/真机/提交/推送，进程结束。圆角迭代器原文已下载/tmp/ztransfer-shadow-android15/SkPathMakers.h。

2026-10-16 F179 rrect path：ShadowPath.roundedRect补SkRRect半径归一/边界排序/矩形椭圆普通圆角及CW6/CCW7默认起点，全部起点/方向/close指令原序。generator编译原SkRRect方法、SkPathMakers迭代器和SkPath三个构造函数（元数据/容器适配），504组verbs/points/weights精确一致，rrect-path-generator成功、f179-rrect-path23/23 TEST SUCCEEDED。fixture已xcodegen索引686不变。下一步圆角→ambient/spot投影→path→convex mesh的完整几何入口及组合原生参考，再renderer/host接线；凹路径/独立像素仍缺，公共Surface未换26/182。无页面视觉/额外安装/真机/提交/推送，测试结束。

2026-10-16 F179 integrated：新增ShadowGeometry.roundedRect串圆角path/ambient高度+inset/spot投影/path/convex mesh，保留每层nil失败与空mesh成功区别。原生generator同一程序组合固定原函数（构造调度适配、无凹分支），123双层全顶点/alpha/indices精确一致；ambient123有效1空，spot121有效1空+2失败且ambient保留。integrated-generator成功、f179-integrated24/24 TEST SUCCEEDED，新增生产/fixture已xcodegen索引687/iOS生产217。下一步renderer general scene裁切+Gaussian GPU、host一般变换；失败/凹fallback、透视边界及独立像素未完，公共Surface未换26/182。无页面视觉/额外安装/真机/提交/推送，测试结束。

2026-10-16 F179 general scene：renderer.tessellatedScene串完整几何/HWUI alpha/Gaussian层，共享textureBounds先投影后crop。TessellatedPreparation返回scene+failedComponents，空成功不建纹理、失败层登记并保留成功层，调用方必须处理fallback。旋转/剪切/透视×1/.5六场景共240k窗口/裁切GPU alpha对照容差1通过，另测spot失败保留ambient+标记、零宽/零高/隐藏；general-scene25/25 TEST SUCCEEDED。索引687不变，无页面新路线/额外安装/真机/提交/推送，测试结束。下一步host快速/通用选择和反变换、失败fallback、公共Surface与UI/独立像素；凹/透视边界仍缺，26/182。

2026-10-16 F179 affine host：Scene枚举接LUT/通用Gaussian，静态任意角/非等比/镜像/剪切逆变换纹理；bounds.origin修正。祖先非仿射/自身sublayer/奇异拒绝清scene；失败components不显示部分阴影。发现Skia快速支持等比轴镜像，补metrics/renderer reflected（inverse先逆转再反射），4turn协变通过。affine-host-final25/25 TEST SUCCEEDED；先前affine-host-ui1/1，截图C32AA648已看提示预览/queue0，非独立像素。最终affine-host-build BUILD SUCCEEDED，simctl安装启动PID50906。索引687，26/182不变，未真机/提交/推送，进程结束。后续优先：SkMatrix近等比容差与UIKit采样误差（当前严格匹配）、父层动画presentation逐帧更新、失败/凹fallback、透视host/边界、公共Surface与独立像素；当前仅静态仿射接入，不等于完整完成。


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

2026-10-16 F034按最新功能范围复核：既有单/日期组/预览单/连拍共享准入和上层提示已接，不重复实现。新增真实磁盘统一/按天/按类型缺原片、整批、补齐及删除刷新测试，结合真实ViewModel单/批×立即/延后离线完成；本轮/tmp/ztransfer-f034-admission.log 11/11、TEST SUCCEEDED，退出0（同名路径现为本轮结果，旧记录仅为历史）。功能开发侧核销累计57项，样式动画延期，实际触摸/真机重连待集中验收；F130/V003仍独立未完成。下一项F035。无UI测试、真机、提交或推送。

2026-10-16 F035功能修复：合集图片轻点无动作，长按只扩展独立previewExpandedBurstIDs，底层不提前insert；图片长按与两个按钮分层，父长按仅处理普通照片。真实PhotoPreviewView使用PhotoPreviewOpeningSnapshot初始化分页/索引，4项验证目标首成员/已有展开组/其他收起组/普通及关闭分组打开。最终/tmp/ztransfer-f035-input-20261016.log 4/4、TEST SUCCEEDED，退出0，diff check通过；功能开发侧累计58项，真实触摸/关闭定位留集中手工验收，样式动画延期，无UI测试/真机/提交/推送。下一项F036；T04其他缺口未完成。

2026-10-16 F036已补类型筛选归一化：publishSections使用未过滤展示范围类型，空选择立即清理，非空扫描中保留，完成且不加载后仅全无匹配才清理，部分匹配保留整组，并持久化。扫描最终发布放到完成标记之后。真实ViewModel六组合与扫描回归/tmp/ztransfer-f036-types-20261016.log 30/30、TEST SUCCEEDED、退出0，diff check通过；累计59项。未UI/真机换相机验证、提交或推送。下一项F037回顶功能规则，样式动画延期。

2026-10-16 F037第一阶段仅补PhotoListBackTopState规则及2项测试，连既有真实UIScrollView观察器2项共4/4通过，/tmp/ztransfer-f037-policy-20261016.log TEST SUCCEEDED、退出0。页面仍用-360旧门槛，未核销，累计59项。下一步必须接日期头/合集/照片实际首可见索引（安卓阈值30，4物理像素死区）、滚动结束事件和1800ms计时/离页清理/程序回顶复位，不能只计照片或用固定距离代替。无UI测试/真机/提交/推送。

2026-10-16 F037继续补滚动活动事件：PhotoListScrollActivity可选onActivityChanged，真实drag/decelerate启动，活动期间16ms查看UIKit状态，实际停止单次false；detach取消并隔离迟到回调。新增真实ObserverView测试，最终/tmp/ztransfer-f037-activity-20261016.log 5/5 TEST SUCCEEDED、退出0，diff check通过。页面尚未消费回调/状态机，首可见索引和计时/回顶复位仍待接，F037未核销累计59项；iOS最低16，勿无条件用17动画完成API，索引须含日期头/合集/实际展开成员并避免每帧扫描整目录。无UI测试/真机/提交/推送。

2026-10-16 F037实际页面已接：PhotoListScrollLayout缓存日期头/合集/实际成员索引，按可见bounds+displayScale取最低索引/整数offset；移除-360旧门槛。BackTopController接活动事件与1800ms取消计时，回顶begin/到顶finish/用户中断/离页reset；基础直接scrollTo，精细动画按最新范围延期。生产layout/2-4列/真实计时及既有观察器合计/tmp/ztransfer-f037-page-20261016.log 8/8、TEST SUCCEEDED、退出0，diff check通过。F037功能开发侧核销累计60项，未UI/真机手势验收、提交/推送。下一项F038最新任务显示。

2026-10-16 F038已修复：TransferQueueViewModel按队列顺序缓存最新handle索引，task(for:)不再优先旧传输中/等待，独立progress不重建；索引在snapshot didSet更新，保证@Published同步订阅期间旧数组/旧索引一致。25种状态组合+UUID逆序、真实队列撤回/删除回退/清空和同步订阅测试，最终/tmp/ztransfer-f038-publication-20261016.log 43/43、TEST SUCCEEDED、退出0，diff check通过，累计61项。未UI/真机/提交/推送。下一项F039合集与首成员frame身份冲突，精细动画延期。

2026-10-16 F039已修复：cellBounds改PhotoListCellID的photo/burst/burstEnqueue独立键，真实格子/按钮分别发Preference；合集长按用合集、成员返回只用photo，日期收起/预览可见索引按实际entry取坐标。visiblePhotoListCellBounds过滤无效/视口外格子，批量成员改实际viewport。生产reducer/可见来源及滚动回归/tmp/ztransfer-f039-identity-20261016.log 10/10、TEST SUCCEEDED、退出0，diff check通过，累计62项。真实页面手势待集中，精细动画延期，F041/F051未一并核销；无UI测试/真机/提交/推送。下一项F040评级空态判定。

2026-10-16 F040已接精确空提示门控：仅评级开+选具体星级+loading时隐藏无匹配句子，保留清筛选及非筛选目录提示。真实列表慢读/忙态切换/最终两星不匹配五星/清筛选恢复验证；首轮测试async条件误传同步助手编译失败已保留，最终/tmp/ztransfer-f040-final-20261016.log 16/16、TEST SUCCEEDED、退出0，diff check通过。累计63项。F041纯精细样式动画按用户范围延期，不计修复。下一项F042需拆出押扣计数/取消清理功能，纯飞行效果延期。无UI测试/真机/提交/推送。

2026-10-16 F042功能修复：PhotoListFlightAdmissions对有效可见source同源去重，真实startListQueueFlight获准后才押扣，移除中心伪造起点和批次退借照片；按UUID一次消费完成/取消，队列/监看/根离页取消任务并只释放自身计数。生产模型测试无效/重复/批次/取消/重入迟到隔离，含坐标滚动回归/tmp/ztransfer-f042-admission-20261016.log 12/12、TEST SUCCEEDED、退出0，diff check通过，累计64项。真实页面手工验收待集中，精细动画延期，F051/F084未一并核销。无UI测试/真机/提交/推送。下一项F043日期编辑器公历统一。

2026-10-16 F043已修复：PhotoFilterDates固定Gregorian仅保留系统时区，两个编辑入口的解析/显示年月日/月长/裁切/年份范围/提交统一使用，移除UI Calendar.current。4历法×2时区注入验证闰日跨月/短文本/提交及年份边界，含非法日期回归/tmp/ztransfer-f043-calendar-20261016.log 2/2、TEST SUCCEEDED、退出0，diff check通过。累计65项；实际系统设置切换页面待手工验收，未UI/真机/提交/推送。下一项F044 AP/USB预览FHD重试/能力缓存/EXIF后fallback。

2026-10-16 F044第一阶段：普通AP/USB repository.preview只请求FHD，移除提前LargeThumb/GetThumb；新增会话fhdSupported、busy2次/160ms，未知unsupported熔断但成功过不推翻，空/临时失败不熔断，取消及PTPSession异常传播。STA directReader保持独立。新增PreviewProtocolReplayTests在RatingProtocolReplayTests.swift，4项加IOGate19项/tmp/ztransfer-f044-fhd-20261016.log 23/23、TEST SUCCEEDED、退出0，diff check通过。仍未核销累计65项；下一步真实previewAndExif失败→EXIF→GetThumb顺序、transport失效不追加命令和STA回归。无UI/真机/提交/推送。

2026-10-16 F044补真实session.previewAndExif不支持FHD→发布结果→EXIF正常/Busy，返回后真实session.thumbnail命令序列确认无提前GetThumb或LargeThumb；UI门控静态接线核对，不宣称自动触发E2E。网络中断后PTPSession失效阻止后续preview/readPrefix，线上仅第一条FHD。STA18+FHD6+IOGate19最终/tmp/ztransfer-f044-order-20261016.log 43/43、TEST SUCCEEDED、退出0，diff check通过。F044开发侧核销累计66项；无UI/真机/提交/推送，下一项F045预览方向，F046解码预算独立未完成。

2026-10-16 F045已修复：普通当前/邻页都用decodeCameraPhotoPreview，ImageIO原始CGImage+UIImage.up忽略EXIF转向镜像；手动旋转保持，效果预览仍UIImage(data:)独立。真实四色JPEG EXIF1–8先验证标签再四转渲染，32组合像素一致；/tmp/ztransfer-f045-orientation-20261016.log 1/1、TEST SUCCEEDED、退出0，diff check通过，累计67项。非SwiftUI手势/裁切映射验收，无UI/真机/提交/推送。下一项F046：目前解码仍无1920预算且同步，须补尺寸限制与后台解析。

2026-10-16 F046进行中：已补1920长边/2幂采样不放大小图，当前页与邻页后台ImageIO解码及返回前取消检查；previewAndExif异步回调等待解码后再EXIF，loading所有权保持。f046-bounds为2/2，f046-background为7/7，均TEST SUCCEEDED；直方图后台化、真实翻页取消交错、内存峰值仍待补，不核销，累计67项。

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

F086开发侧核销：本地批次失败详情已接基础展示及系统文本选择，READY保留、新选择/批次清空；真实ViewModel权限拒绝和三语文案连同批次回归12/12通过，日志 `/tmp/ztransfer-f086-presentation-20261016.log`。累计78项；未做UI复制操作及真机Photos/Provider失败验收。

F087进行中：本地效果轻点放大复用共用大图，接清焦点、真实锚点、长按对比及按UIImage身份接收晚到对比/保留打开快照；最终 `/tmp/ztransfer-f087-build-final-20261016.log` TEST BUILD SUCCEEDED。仅编译，未执行UI测试；手势冲突及弹层期间异步更新仍待验证，累计78项不变。

F088进行中：PhotoLUTStore按camera/local隔离选择和强度，宿主显式持有并注入公共编辑器，本地两入口共享同一local实例。camera保留旧键，目录/收藏仍共享。`/tmp/ztransfer-f088-roles-20261016.log`专项3/3、TEST SUCCEEDED；F100身份/快照恢复、F101完整微调及共享收藏实时一致性仍需补，不核销，累计78项。

F088共享状态续修：收藏写前读取最新偏好，写后MainActor同步信号让各活跃Store重读各自目录/收藏键；角色选择不受影响。`/tmp/ztransfer-f088-shared-20261016.log`真实双实例交错及suite隔离等4/4通过，TEST SUCCEEDED。F099目录服务、F100配方恢复和F101微调仍未完成，累计78项不变。

F098进行中：已加载Cube在PhotoEffectsStore.normalized中保留原名/强度，不再误用NP3目录清除；normalized/effective按颜色效果所属FILTER/LUT模块判断启用，公共编辑器保留chooser原名。双scope生产提交及LUT角色回归 `/tmp/ztransfer-f098-commit-20261016.log` 5/5、TEST SUCCEEDED。真实像素输出、完整选择及F100重启恢复未验，不核销，累计78项。

F098补真实像素证据：双scope提交后实际PhotoEffectsRenderer将白图经64%黑Cube映射为RGBA92/92/92/255，禁用后保持白色；旧配方不受后续编辑影响。`/tmp/ztransfer-f098-pixels-20261016.log`1/1、TEST SUCCEEDED。未覆盖Photos保存、选择器或重启，F100仍待补，累计78项。

F089开发侧核销：删除本地工作台无条件重复LUT入口，唯一公共编辑器接PhotoColorEffectEditorVisibility，按活动选择而非停用记忆项互斥。免费/付费×15掩码×两类选择×开关状态及既有回归 `/tmp/ztransfer-f089-visibility-20261016.log`6/6、TEST SUCCEEDED，累计79项。F095关闭Cube入口仍缺（F103），不整体核销；未运行UI测试。

F090功能部分：生成前清水印焦点、生成主文案/计数空格和含数量的三语重选无障碍标签已对照安卓更新；f090-functional编译通过，实际键盘/VoiceOver未验，不核销。F091公共按钮已接免费框/水印成对异或及最后模块保持，无变化不写草稿；`/tmp/ztransfer-f091-toggle-20261016.log`穷举及LUT回归7/7、TEST SUCCEEDED，开发侧核销，累计80项。下一项F092框/水印独立分区；F094隐藏清启用独立未修。

F092进行中：公共编辑器拆出frameControls/watermarkControls按各自effective位构造，移除整卡FRAME禁用；隐藏水印时不应用框收藏水印。`/tmp/ztransfer-f092-sections-20261016.log` TEST BUILD SUCCEEDED；未执行UI或水印单独编辑输出专项，F094持久化清开关仍未修，累计80项。

F092开发侧核销：`/tmp/ztransfer-f092-output-20261016.log`双scope真实配置编辑/重建与PhotoEffectsRenderer输出专项1/1、TEST SUCCEEDED；只有水印时旧border不输出边框，改文字会改变成片，尺寸保持原图。结合独立控件生产接线，累计81项。未运行UI或Photos保存测试，下一项F094隐藏清启用仍待补（F093已有部分门控修复需完整矩阵验证）。

F093开发侧核销：已有colorEffectModule门控补完整双scope×NP3/Cube×FILTER/LUT四组合，免费/Pro预览和提交后真实渲染对比启用/禁用基准；`/tmp/ztransfer-f093-matrix-20261016.log`1/1、TEST SUCCEEDED，累计82项。未UI测试，F094隐藏清草稿与F100重启恢复仍待补。

F094进行中：applyModuleVisibility接模块点击/即时偏好持久化/normalized，修正水印关闭后被原值覆盖；隐藏LUT同步清角色Store选择。双scope×免费/Pro隐藏→重显→重建及权益/输出/LUT回归 `/tmp/ztransfer-f094-hide-20261016.log`10/10、TEST SUCCEEDED。Cube角色与入口交接待补证，累计82项不变。

F094开发侧核销：生产模块按钮调用togglePhotoEffectModuleDraft，同步关闭草稿及本LUT角色保存项，最后模块点击无变化。双角色Cube隐藏/重显/提交重建及回归 `/tmp/ztransfer-f094-command-20261016.log`9/9、TEST SUCCEEDED；结合前轮10/10，累计83项。未UI测试；F100正常启用Cube快照恢复独立未完成。

F095开发侧核销：唯一PhotoLUTChooser加入三语lut_off按钮，调用disablePhotoLUTDraft清Cube草稿和本角色保存项，保持其他角色/强度/NP3记忆。双角色Cube关闭→NP3启用/关闭→LUT恢复及回归 `/tmp/ztransfer-f095-off-20261016.log`9/9、TEST SUCCEEDED；累计84项。未UI测试，F103其他入口功能和F100完整恢复仍待补，下一项F096收藏完整参数。

F096进行中：PhotoFrameFavorite新增宽度/模糊/遮罩并兼容旧JSON，Android收藏9/10/12字段解析与10/12字段编码已补。首轮f096-codec新增测试缺MainActor编译失败；修正后 `/tmp/ztransfer-f096-codec-fixed-20261016.log`3/3、TEST SUCCEEDED。下一步编辑器捕获/修改/应用新参数，尚不核销，累计84项。

F096开发侧核销：收藏捕获activeMetadata、修改同步三参数、模板选择应用并写回metadataByPreset；双scope捕获60/0/200→修改200/180/0→保存重建→应用及内容保护/权益回归 `/tmp/ztransfer-f096-apply-20261016.log`5/5、TEST SUCCEEDED。结合格式阶段3/3，累计85项；首轮MainActor编译失败保留，未UI测试。

F099开发侧核销：RemoteLUTFolderAccess新增monitor/photo书签scope，照片唯一选择器使用photo并发布同一bookmarkData，监看默认键保持独立。`/tmp/ztransfer-f099-folder-20261016.log`真实临时目录保存/解析/新实例/主动共用/清除隔离1/1、TEST SUCCEEDED，累计86项。未UI或实际Provider撤权/扫描失败验收，F102/F168独立未修。F097精细菜单外观动画暂缓不核销；F098/F100完整选择恢复仍待补。

F100进行中：PhotoLUTStore新增selectLUT先快照后发布角色digest/name/source/intensity及restoreSelection实际读快照，关闭清角色配方、强度同步；删除原Cube后双角色恢复及缺快照拒绝等 `/tmp/ztransfer-f100-recipe-20261016.log`11/11、TEST SUCCEEDED。新API尚未接chooser/两宿主恢复，下一步完成接线并避免普通滤镜切换后旧Cube复活；累计86项不变。

F098/F100开发侧核销：chooser接selectLUT先快照后发布，PhotoEffectsStore两scope在初始化恢复角色配方并实际加载私有表，移除本地旧onAppear；公共编辑器切NP3清旧Cube配方。`/tmp/ztransfer-f100-hosts-20261016.log`12/12、TEST SUCCEEDED，结合recipe阶段11/11及实际渲染，累计88项。只做Store重建未实际杀进程/UI/Photos验收；同步IO/缓存目录/资源限制另归F102/F105/F106，F088微调依赖F101仍未完成。

F101进行中：LUTAdjustments四项与PhotoFilterSelection兼容解码、Cube归一化保留已补；LUTColorPipeline按安卓后处理算法实现但尚未接mapper。`/tmp/ztransfer-f101-model-20261016.log`8/8、TEST SUCCEEDED，覆盖中性/灰色/透明/极值/旧JSON。下一步实际渲染顺序与Alpha、每digest/角色记忆、控件、输出身份，累计88项不变。

F101渲染接线已补：PhotoEffectsRenderer传lutAdjustments到mapper，LUT混合量化后微调；预乘RGBA先转straight颜色处理再按原Alpha回写。`/tmp/ztransfer-f101-render-20261016.log`实际不透明/半透明/透明逐字节及回归10/10、TEST SUCCEEDED。每digest/角色微调、控件、输出身份/重试待补，累计88项。

2026-10-16 F106 接入同digest快照读取合并：读取/等待不持有缓存锁，失败可重试。f106-coalesce-20261016.log TEST SUCCEEDED、退出0；详见全功能跟进末节。F106未核销，累计91项不变，后续仍须启动懒恢复及owner/快照清理。未UI测试。

2026-10-16 F106 持久快照恢复改为仅元数据注册，首次渲染缓存未命中才解码。纠正F105历史restoreSelection坏文件必须nil的过强断言，安卓同样延迟内容校验；二进制校验未放宽。f106-lazy-20261016.log 30/30、TEST SUCCEEDED、退出0；旧目录首次迁移仍同步，owner/清理仍缺，F106未核销、91项不变。

2026-10-16 F106 配方新增轻量snapshotOwner（digest/URL），写入准备提前持有，复制/归一化保留，runtime弱跟踪，渲染优先按owner读取；不进入JSON及业务相等判断。最终f106-owner-final-20261016.log 32/32 TEST SUCCEEDED、退出0。尚未启用prune，后续须保留双角色持久配方+活跃owner，并处理写入/清理互斥及URL索引。F106未核销，91项不变。

2026-10-16 F106 接入启动和成功选LUT后的串行后台prune：删除前锁内检查活跃owner和实时双角色defaults；写入/迁移提前持有owner；仅删除私有普通.bin，成功后清对应URL登记。f106-prune-20261016.log 33/33 TEST SUCCEEDED、退出0。未穷举实际队列/写入阻塞交错；旧目录首次迁移仍同步，内存警告等尚待处理。F106未核销，91项不变。

2026-10-16 F106 写入发布/取消交接新增确定性测试：真实原子落盘后、PreparedSelection交付前屏障内prune保留；取消writer终结后prune删除，不接受角色。f106-write-handoff-20261016.log 33/33 TEST SUCCEEDED、退出0。本轮仅验证，无生产修改；旧缓存迁移、65格预算及真实队列清理交接仍待处理，F106未核销、91项不变。

2026-10-16 F106 65格实数组预算专项通过：20张轮换默认8MiB最多2张、活跃值跨淘汰/清空保持、超预算不驻留、默认16项上限。f106-large-20261016.log 1/1 TEST SUCCEEDED、退出0；不是进程RSS/OOM验证。F106仍未完成、91项不变，下一步旧缓存迁移及实际队列清理交接。

2026-10-16 F106 真实队列独占旧LUT测试通过：旧配方作用域退出后仅队列持有，编辑器换新/清理/缓存清空后仍生成旧黑LUT像素；移除任务释放owner后旧文件可删除，新角色恢复不变。f106-queue-prune-fixed-20261016.log 2/2 TEST SUCCEEDED、退出0；首轮测试可选链编译失败保留。F106未核销，下一步旧缓存迁移路径，累计91项不变。

2026-10-16 F106 旧缓存首次恢复也改为元数据注册，owner记录legacy来源，首次table读取在渲染worker校验/原子迁移；按目标路径合并迁移，不用热缓存掩盖迁移失败。f106-migration-20261016.log 34/34；强化后台迁移/目标目录失败重试f106-migration-retry-20261016.log 1/1，均TEST SUCCEEDED退出0。旧目录同步恢复缺口已补，F106待最终逐项核验，暂未核销、91项不变；无UI测试。

2026-10-16 F106最终功能逐项核验完成并开发侧核销：有界缓存/同key复用、持久快照/懒恢复迁移、活跃owner/prune、真实队列淘汰重载释放、原子发布取消交接和写失败保旧。f106-final-20261016.log 48/48 TEST SUCCEEDED、退出0；累计92项。非真机RSS/系统杀进程验收；内存警告接线不是安卓或原F106要求，不作为新增核销门槛。下一步F107像素循环取消；F102/F103其他缺口仍未核销，整体目标继续。

2026-10-16 F107第一阶段：Cube apply改throws，入口/4096像素/输出前Task取消检查，renderer传播；透明像素同样检查。f107-cancel-20261016.log 13/13 TEST SUCCEEDED退出0。发现PhotoEffectsEditorView演示图fallback detached未传取消，下一步修复并验证gate释放；F107未核销、92项不变。

2026-10-16 F107 fallback已接PhotoEffectsPreviewRenderGate.render取消桥，父取消传worker，保留原utility/设置/预览参数；共享gate排队取消即退出且后续任务可运行。f107-fallback-20261016.log 16/16 TEST SUCCEEDED退出0。下一步活动像素循环取消→释放gate→后续任务的串联验证，F107未核销、92项不变。

2026-10-16 F107开发侧核销：4096像素取消、透明/尾批检查、错误传播、fallback取消桥及活动映射取消释放共享gate均验证。f107-active-20261016.log 18/18 TEST SUCCEEDED退出0，累计93项；未UI手势/系统CG draw可中断验收。下一步F108普通滤镜分类与选择器功能，整体目标继续。

2026-10-16 F108分类改按安卓fallbackName，分类模型移到PhotoEffects领域；全50项×3种ID×3种显示名专项f108-category-20261016.log 1/1 TEST SUCCEEDED退出0。下一步PhotoFilterChooserOverlay顶部关闭、当前项定位、收藏与低屏可用性；F108未核销，93项不变。

2026-10-16 F108开发侧功能核销：50项fallback分类，chooser顶部关闭保配方、收藏排序/记忆强度、每分类当前项定位及小屏可用高度已接。f108-chooser-20261016.log 2/2 TEST SUCCEEDED退出0、生产编译通过；未UI测试/精细样式动画验收。累计94项，后续按台账F109继续，整体目标仍活动。

2026-10-16 F109第一阶段修正LocalEffectPreview顺序：先取prefetched成片，miss才过滤/合成，命中不重复像素计算。f109-cache-order-20261016.log TEST BUILD SUCCEEDED退出0，未运行测试。仍缺安卓getOrRender共享running预取提升当前/取消需求管理及计数验证；下一步继续，F109未核销、94项不变。

2026-10-16 F109新增PhotoPreviewFrameCache<Value> actor单目标共享任务：独立等待取消不撤销共享worker、成功缓存/失败重试、close立即取消等待及隔离迟到结果。f109-shared-20261016.log 2/2 TEST SUCCEEDED退出0。尚未接生产；下一步外层3项有界缓存、源图/画布身份/需求集合及LocalEffectPreview当前与预取共用，离页close；F109未核销、94项不变。

2026-10-16 F109三项LRU外层PhotoPreviewCacheSet完成模型：get创建/命中触碰、超容量close最旧任务、close全清拒绝后续。f109-bounded-20261016.log 4/4 TEST SUCCEEDED退出0。尚未接LocalEffectPreview；下一步源图/装饰身份、当前+两邻需求集合、当前和预取共用及离页close；F109未核销，94项不变。

2026-10-16 F109已接生产LocalEffectPreview：StateObject LocalPhotoPreviewCache共享当前/预取，移除prefetched字典；sorted像素key、源UIImage/metadata/装饰scope失效、单份中间滤镜图和离页close。integrate回归4/4、real-cache真实NP3复用/强度/源图/关闭1/1均TEST SUCCEEDED退出0。下一步current+两邻需求集合主动取消过期worker及必要重试/提升验证；F109未核销，94项不变。

2026-10-16 F109需求管理已接：configure async当前+两邻key，禁用预取收缩；过期worker取消但保留completed，重新需要时同entry透明重试，需求revision及等待者登记复检防旧状态。f109-demand-final-20261016.log 6/6 TEST SUCCEEDED退出0。下一步最终核验装饰变化与生产提升场景，并将nextPhotoFilterSelections从UI移领域避免倒向依赖；F109未核销、94项不变。

2026-10-16 F109开发侧核销：真实预热B→当前B同UIImage复用、源/强度/装饰失效、取消预取不取消共享worker、需求过期取消/重新请求、三项LRU及离页close均已验证；nextPhotoFilterSelections移领域。f109-final-20261016.log 10/10 TEST SUCCEEDED退出0，累计95项。未UI/真机性能验收。下一步F110原图导出资源/线程策略；整体目标未完成。


2026-10-16 F110第一阶段：原图NP3在调用worker顺序计算，预览按安卓阈值512×512最多两个任务；renderer默认original，两个实际预览入口显式preview。f110-workers-20261016.log 5/5 TEST SUCCEEDED、退出0，覆盖线程策略、513行真实像素串并行一致、透明/半透明、源数据保持及取消入口。尚未消除无框/沉浸整图缓冲，未验证高像素并发峰值，F110不核销，累计95项不变。


2026-10-16 F110第二阶段：无框原图与仅水印合并到drawFlatPhoto最终画布，沉浸纳入已有drawFilteredPhotoTiles；逐块autoreleasepool限制临时对象寿命，原图不再预先创建整幅过滤结果。1024×4101跨4Mi像素边界，对照整图预过滤后合成，无框/水印-only/沉浸逐字节相同。f110-flat-fixed-20261016.log 6/6 TEST SUCCEEDED、退出0；首轮f110-flat测试漏写settings引用导致编译失败已保留。尚待Cube/方向/透明图与高像素批次并发资源验证，未测RSS/OOM，解码及最终画布仍有全图存储；F110未核销，累计95项。


2026-10-16 F110方向/透明专项：NP3与Cube两种过滤×全部8种UIImage方向，含透明/半透明区域，原图分块对照整图预览逐字节相同；跨4Mi像素边界三合成路径回归同时通过。f110-orientation-20261016.log 2/2 TEST SUCCEEDED；未UI测试。新增发现：Android PhotoAllocationBudget.kt在解码/画布前校验饱和尺寸、系统可用内存及Java scratch预算，iOS尚缺对应预检；需按平台内存模型处理，不能将分块即视为资源安全。仍待高像素批次/传输并发、活动取消及预算验证，F110不核销、累计95项。


2026-10-16 F110预算模型：PhotoAllocationBudget按安卓实现饱和尺寸/份数/额外内存计算及native最低64MiB余量判断。f110-budget-model-20261016.log 2/2 TEST SUCCEEDED、退出0，覆盖溢出、非法值、阈值精确边界。模型尚未接生产分配入口，不声称已保护导出。已通过异步问题请求平台差异确认：iOS os_proc_available_memory替代安卓系统/Java堆检查，预算不足沿用失败/重试且不降采样；尚待用户答复。SDK os/proc.h确认接口是当前进程dirty上限余量即时快照，不应缓存。F110未核销、累计95项不变。


2026-10-16 用户已明确认可F110平台差异：使用iOS进程可用内存接口，至少64MiB余量，预算不足走既有失败/重试、不降原图尺寸。可直接继续生产接线，无须重复确认。


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


2026-10-16 用户明确认可F111联网平台方案：AP严格禁止，其他模式使用默认NWPath可用性，Geocoder一秒超时/失败兜底，不增加外部探测。可直接接线，无须重复确认。


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

2026-10-17 F149 developer-side completion: independent 500ms expiry publication, area-event invalidation, semantic focus-mode label changes, non-whiteBalance successful tool writes and session restarts now invalidate old focus frames. Android RemoteScreen718 keys mode invalidation to label: same raw across properties with different meaning invalidates, equivalent AF-S encodings preserve cutoff. Final /tmp/ztransfer-f149-label-20261017.log2/2 TEST SUCCEEDED exit0 covers both via actual queued property events with frames held. Earlier expiry3/3, restart2/2, tools2/2 cover quiet expiry/recovery, all three area events, compatibility restart versus ordinary inner retry, whiteBalance exception and tracking release. View consumes model expiry/cutoff; no UI/device tests. Earlier property-or-value comparison claim superseded by semantic label comparison. Count121/182,61 unclosed; functional denominator pending classification.

2026-10-17 F150 developer-side completion: unified RemoteFocusLayers consumes one RemoteFocusHandoff for tap and camera visibility, cancellable120ms handoff keyed by input/nonce, persistent latch across packet gaps, synchronous new-request reset and obsolete-result rejection. Ordinary fallback uses original tap point for<3s with independent expiry task; tracking has no fallback/cached geometry bypass. Existing focusDisplayState supplies gated camera frames, so stale/tool-hidden frames cannot reappear via the removed separate marker. Half-press uses production focusing/locked state while held, idle plus ordinary fallback after release; no alternate half-press state required. Final /tmp/ztransfer-f150-halfpress-20261017.log3/3 TEST SUCCEEDED exit0: held old image cannot take over fresh AF, real3s fallback eligibility expires, new half-press clears marker/nonce, late AF release and exit-drain regressions. Earlier handoff2/2 and fallback1/1 verify shared visibility, interruption, gaps and tracking exclusion. SwiftUI task sleep/cancellation and layer wiring statically reviewed and compiled; no UI clock-render/animation/device tests, per current scope. Count122/182,60 unclosed; functional denominator pending classification.

2026-10-17 F153 developer-side completion: monitor false-color/luma-waveform uses Android77/150/29 integer weights; RGB waveform and histogram/zebra weights unchanged. Final /tmp/ztransfer-f153-pipeline-20261017.log7/7 TEST SUCCEEDED exit0 covers all colored threshold edges, RGB/luma waveform and production RemoteFrameDecodePipeline primary-color decode/publication. Lossless PNG fixture deliberately isolates exact analysis values from JPEG quantization; verifies all64 pixels false-color, waveform row/count/columns, and unchanged histogram bins53/182/18. This is production decoder/analysis evidence, not camera JPEG color calibration or UI/device validation. F154 sampling/allocation remains separate. Count123/182,59 unclosed; F151 visual remainder and F152 deferred, not counted fixed.

2026-10-17 F154 developer-side completion: luma/RGB histogram share one conversion and two-axis sampling; waveform/false-color share one<=256x192 conversion/packed buffer with actual output dimensions; zebra converts directly to Android ceil-derived grid using nearest scaling instead of old cell-step centers. Final /tmp/ztransfer-f154-spatial-20261017.log1/1 TEST SUCCEEDED exit0 validates319x241 nonuniform black/white source against pixel-center reference: every zebra cell, every false-color pixel, every waveform column and exact histogram bins. Earlier histogram2/2 and monitor2/2 cover1080p, nondivisible/narrow dimensions, sample bounds and unchanged source dimensions. Static allocation audit: one full-sized histogram RGBA buffer only when requested, one bounded monitor RGBA/packed pair shared by both tools, one bounded zebra RGBA buffer; not runtime allocator/RSS profiling. Android RemoteViewfinderFeatures135-163/209-238 and RemoteExposureAnalysis83-110 basis. No UI/device validation. Count124/182,58 unclosed.

2026-10-17 F155 developer-side completion: shared luma/RGB250ms cache, missing-RGB immediate recomputation, zebra50ms refresh. Production default uses ContinuousClock; injected clock permits exact49/50 and249/250ms pixel-result validation with no sleeps. /tmp/ztransfer-f155-boundary-20261017.log1/1 TEST SUCCEEDED exit0 covers boundaries, RGB->luma hiding, off/on clearing and luma->missingRGB immediate refresh of both channels; earlier real-time cadence1/1 passed. Read Android RemoteScreen780-811 and MonitorExposurePerformanceInstrumentation. F157 in-flight configuration/reset/size cache identity remains separate. No UI/device performance testing. Count125/182,57 unclosed.

2026-10-17 F156 developer-side completion: startup view calls shared analysis configurator before start; model stores/reapplies complete waveform/falseColor/histogramRGB/histogram/zebra selection on every loop restart. Final /tmp/ztransfer-f156-recovery-20261017.log2/2 TEST SUCCEEDED exit0 covers initial/HD plus preferences saved then reconstructed before acquisition-error and recording-compatibility recovery. Recovery assertions wait for replacement image, verify RGB histogram/waveform and false-color present without retoggling, zebra off preserved. Actual SwiftUI initial wiring statically reviewed and compiled, no UI tests. F157 in-flight mode/cache identity remains separate. Count126/182,56 unclosed.

2026-10-17 F157 developer-side completion: configuration generation rejects obsolete decode/cache results; invalidatable publication permit orders main-actor delivery against mode/session changes; newest frame reprocessed if needed without new packet. Session and header-size changes clear all statistic caches/timestamps. Final /tmp/ztransfer-f157-final-20261017.log3/3 TEST SUCCEEDED exit0: actual pipeline held before delivery through off/on, RGB/luma/RGB and optional reset publishes only one final-mode/current-session frame; fixed-time size/reset and cadence regressions pass. Optional beforePublication barrier defaults nil in production. Earlier generation1/1 and publication2/2 validate in-flight decode and queued permit rejection. Android MonitorAnalysisThrottle mode/size identity basis; iOS actor/main-actor crossing guarded explicitly. No UI/device tests. Count127/182,55 unclosed.

2026-10-17 F158 developer-side completion: strict signed-byte production meter reads; D10A3x700ms unavailable retry then D1B1 fallback; readiness/foreground/movie/stability lifecycle restarts and busy gates for AF/parameter/AutoISO/recording operations, stable recording allowed. Final /tmp/ztransfer-f158-final2-20261017.log2/2 TEST SUCCEEDED exit0 verifies mode and HD reprobe counts, delayed exposure/AutoISO writes block probes until completion. First final build failed because test camera movie was immutable; changed fixture to simulate physical selector, no tests ran then. Earlier wire5, probe1, busy2, lifecycle2 selected tests passed as documented. Startup saved toggle wired; no UI/device tests. F159 late read publication, monotonic freshness and expiry remain open. Count128/182,54 unclosed.

2026-10-17 F159 developer-side completion: post-read cancellation/generation/stop/busy checks, monotonic<1500ms freshness, independent request-start+3s expiry, busy sample extension and current-generation terminal cleanup. Final /tmp/ztransfer-f159-final-20261017.log3/3 TEST SUCCEEDED exit0 covers held response across close/open (new2EV survives old1EV and old cleanup),1600ms successful stale response rejected then fresh read recovers, new half-press blocks late result, held focus retains sample>3s without extra reads, suspended read expires independently and close rejects completion. Earlier cleanup2/2 validates exactly3nil failures and lifecycle. No wall-clock dependency remains in meter loop; no OS clock mutation/UI/device test. Count129/182,53 unclosed.

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


2026-10-17 按用户明确要求简化设置页开发标识：模拟权益生效时移除“测试权益”管理按钮，徽章改为“Pro”；Debug 版本铭牌追加“-D”，Release 保持原版本文本。模拟持久化、免费额度、真实订阅管理与徽章点击行为不变。此次为用户指定界面差异，无新增动画或业务流程。git diff --check通过；未新增或运行自动化测试，真机构建进行中，尚未提交/推送。

2026-10-17 设置标识修改交付：/tmp/ztransfer-settings-pro-label-build.log BUILD SUCCEEDED、exit0；已覆盖安装同一iPhone，应用目录D52DBF62-9FD5-484E-9B5C-2A20D69EDEC7，普通无参数启动成功。未重置权益或额度；本轮未运行自动化测试，未确认真机新标签截图；git diff --check通过，未提交/推送。

2026-10-17 用户要求版本铭牌连点恢复免费版。对照Android SettingsScreen.kt版本入口及LicenseManager.revertToFree：7次点击、相邻间隔严格小于1500ms（不是总时长1500ms），成功计数归零、底部原文提示1800ms。iOS仅Debug接入现有endSimulatedPurchase，清本地模拟购买并恢复真实StoreKit状态，不清免费用量、不撤销真实购买；当前模拟Pro可恢复免费后重新走模拟购买。无按压视觉提示，使用单调时钟，提示任务随视图退出/重复触发取消。此次未新增或运行自动化/UI测试，构建结果待补；未提交/推送。

2026-10-17 铭牌恢复免费入口交付：/tmp/ztransfer-version-reset-build.log BUILD SUCCEEDED、exit0；已安装同一iPhone，目录A8EBC902-6D49-4627-AF21-52F6DD6D61FC。git diff --check通过；未代替用户触发重置、未运行手势测试，真机连点待用户使用确认；未提交/推送。

2026-10-17 筛选窗高度及底部紧凑拨轮：真机截图/tmp/ztransfer-filter-height-before.png确认日期按钮下大片空白，旧ScrollView最大高度被宿主当作自然高度。对照Android FileListScreen.FilterOverlay包裹内容：改测量带14pt内边距的自然内容，页面分别缓存高度，外层显式限高并fillsProposedSize，首轮测量后展开，日期页同样可在小屏滚动；切页未测量时沿用上一页高度。用户追加设置最底部两个拨轮对齐截图；对照SettingsScreen.BooleanSettingsWheel compact=true，将触感反馈/屏幕常亮设42高、16行高、13字号，其余布尔拨轮保留原尺寸。无业务状态改动。筛选单独构建成功；组合首次构建因Swift参数顺序失败，已纠正，最终构建中。未运行UI自动化或新增测试，未提交/推送。

2026-10-17 本轮交付：组合第二次构建发现compact替换误及存放方式拨轮，已还原原50/18规格；最终/tmp/ztransfer-filter-compact-delivery-build.log BUILD SUCCEEDED、exit0，已安装同一iPhone（12AD9CE5-932F-43A2-85A8-80E0C5C08825）并普通启动。静态diff检查通过；仅旧版截图证明问题，修复版真机外观尚待确认，无UI自动化，不声称已完成真机视觉验收；未提交/推送。

2026-10-17 角标/关闭点击修正：用户反馈筛选角标挤占选项。两次新截图/tmp/ztransfer-filter-label-before.png及current.png实际为设置窗（首张动画中），不冒充筛选截图；此前filter-height-before截图可见评级角标压近选项。对照Android ReleaseCommitWheel/ControlTileCornerBadge，iOS统一10 semibold/16高误配，改为wheelHeight<=34时8 medium/最小11高/横4纵1padding，大控件9 medium/最小15高/横6纵1padding，单行。用户追加设置×偶发点不到；Android为32dp IconButton，iOS原30pt plain image未指定完整命中矩形，改32×32并contentShape(Rectangle)，补关闭辅助标签。未证实宿主永久禁用或系统手势问题，不能宣称全部偶发情况已复现/核销。未运行新增测试或UI自动化；构建中，未提交/推送。

2026-10-17 角标/关闭按钮交付：/tmp/ztransfer-badge-close-build.log BUILD SUCCEEDED、exit0；同机安装E1CF1FE5-3454-489F-BD21-91A0BF60AABC并普通启动。静态检查通过，未执行真机手势自动化，角标观感和偶发关闭问题待用户复核；未提交/推送。

2026-10-17 用户明确指定iOS默认按钮主题为液态玻璃：新增ZTransferButtonSkin.defaultPreset作为所有skin_preset AppStorage及启动缺省归一化的共同默认。iOS26及以上liquidGlass，旧系统按现有能力回退frostedGlass；不覆盖显式已存主题、不改损坏值迁移Titanium规则。属于用户指定平台差异，无需更改安卓默认。更新既有缺省断言，未运行模型测试/UI自动化；构建中，未提交/推送。

2026-10-17 默认液态玻璃交付：/tmp/ztransfer-default-liquid-build.log BUILD SUCCEEDED、exit0；已安装同机F1945BD7-4DE2-4370-B8C4-98AC165CC809并普通启动。git diff --check通过，未清设置模拟首次安装，未运行测试；未提交/推送。

2026-10-17 1.97增量D01/D02开发侧完成，当前2/18；frames-tests15/15成功，真实接线独立录像时长、Zf v2.1门控。D03/D04进行中；存储失败旧行为已改为抛错保留缓存、非STA StorageIDs Busy也750ms重试，尚未验证此组。新iOS变更未提交，未真机安装；基线合并a36b339c已存在。

2026-10-17 1.97增量仍2/18。D03/D04首轮storage33/33、PC124项4跳过通过，但随后补session gate/页面与清理独立占用和可取消等待，正在验证最终组合。D05已建回看分页配对模型与Repository查询，未接UI，不标完成。新增文件RemoteReviewCatalog.swift/RemoteReviewCatalogTests.swift已xcodegen入工程。运行session-review日志/tmp/ztransfer-197-session-review-tests.log；新模型/控制生命周期改动未提交/真机安装。
