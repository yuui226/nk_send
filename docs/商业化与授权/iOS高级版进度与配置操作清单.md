# iOS 高级版：当前进度、剩余工作与配置操作

更新：2026-09-19。本文是当前进度入口；[迁移台账](安卓高级版全量审查与iOS迁移对照.md)第 8 节保存 A01–A15／B01–B17 的逐项实现、策略、差异及证据，第 10 节保留历史过程。[接入方案](iOS高级版与苹果内购接入方案.md)保存完整业务约定。

## 1. 当前到底完成了什么

**已确认的客户端主要功能都已有接入，不能再描述为“支付尚未实施”。** 购买页、年费／永久购买、恢复购买、续订管理、优惠码兑换入口、交易验证、到期／退款／宽限期处理，以及传输、监看、录制、水印的权限判断均已有代码。A01–A15 的 15 项主要功能接入点均已存在；这只是代码接入情况，不等于 15 项全部验收通过。

本地 Xcode 模拟购买已经配置并实际运行过；**真实苹果沙盒尚未打通**。同一份生产 StoreKit 代码用于两种环境，不需要再写另一套沙盒支付。后台商品和工程签名尚待配置，不把本地测试价格误记为苹果后台已建商品。

| 统计口径 | 当前事实 | 不能据此推断 |
|---|---|---|
| 安卓映射覆盖 | 32/32 项有方案；第 8 节逐行给出实现状态 | 不是 32/32 项已交付，其中含不迁移和平台运营项 |
| 客户端主要功能接入 | A01–A15 均有接入；B 类按苹果方式替换，详见台账 | 不是所有运行场景已正确，也不是后台已配置 |
| 完整交付里程碑 | 原方案前 3/8 项完整闭环，其余项混合包含实现、外部配置和验收 | 不是代码只写完 37.5%，也不能推算还剩 62.5% 代码 |
| 曾口头估算“约 70%” | 仅为粗略工程判断，没有统一分母 | 不作为正式进度、验收率或剩余工时承诺；以后按清单状态汇报 |

此轮只做代码／文档静态核对及苹果官方配置说明核对，未新增运行测试、构建、安装、提交或推送；没有访问用户的 App Store Connect 后台。下文“待配置”表示本项目尚无完成证据，不表示断言用户账户中一定没有相关记录。

## 2. 实现及配置还缺什么（不混入待验收项）

| 编号 | 还缺的工作 | 已有部分与准确边界 | 谁处理／需要什么 |
|---|---|---|---|
| R01 | 确认权益查询结果短暂缺失后，App 是否会自行恢复；如会持续错误，再修对应处理 | 已有完整交易处理和恢复代码。用户 D10 接受约一秒同步延迟，不要求首次立即命中；原生诊断一秒后主动重查可见，不等于 App 自动恢复。同进程重建测试曾等待 App 状态 10 秒失败；年转永久后刷新曾暂时仅剩年费。两条观察不直接认定为两个独立生产 bug，更不能认定苹果线上有 bug | 开发负责区分和必要修复；不需要用户设计技术方案。不再为瞬时查询缺失本身反复优化 |
| R02 | 落实正式签名、App／两种商品及商业配置，并接到现有工程 | 商品 ID、StoreKit 调用及本地测试配置已有；工程 Team 为空，尚未确认匹配正式 Bundle ID 的配置 | 用户／有权限的账户成员完成 U01–U06；开发完成 Team、标识及工程配置核对 |
| R03 | 确定并发布隐私政策和使用条款，填写两个 URL | `PremiumPurchaseView.legalLinks` 已有；当前缺 URL 时链接不显示，所以不能记为已交付可用法律页面 | 用户确认正文、发布位置或提供已有 HTTPS 地址；开发可协助制作页面，取得地址后写入工程，见 U07 |
| R04 | 配置实际优惠活动 | 苹果兑换入口和交易交付已有；金额／期限／资格未确定，没有创建实际活动 | 用户定规则并由有权限账户配置，见 U08；可暂缓，不阻塞原价购买功能 |

R02–R04 主要是外部配置和资料，不是还缺大块客户端功能。也不意味着“用户配完后开发零工作”：开发仍负责工程接入和检查配置是否匹配。没有新增自有授权服务器、激活码数据库或跨平台账户的待开发任务。

## 3. 用户／账户成员操作步骤

下面按“先接通真实沙盒，再补上线和活动”的顺序。已有正确配置就复用，不重复建 App／商品。后台导航以英文名称辅助定位，中文翻译随界面可能不同。只需反馈配置结果、标识和公开链接，不需要把账户密码、验证码、银行或税务明细发到对话中。

### U01 确认团队和 App 身份

1. 登录 Apple Developer，确认用于发布此 App 的 Apple Developer Program 团队可用；记录团队名称和 Team ID。
2. 在 Certificates, Identifiers & Profiles → Identifiers 查找正式 App ID。当前工程使用 `com.ztransfer.ios`；若尚不存在且决定采用它，再创建 Explicit App ID。明确 App ID 默认启用内购能力。
3. 在 App Store Connect → Apps 查找对应 App；不存在时再新建 iOS App，并选同一个 Bundle ID。若已有 App 的标识不同，先交给开发核对，不另建一份重复商品体系。
4. 反馈 Team ID、实际 Bundle ID、App 记录是否已建立。当前本机曾只找到 `com.ztransfer.ios.personaldebug` 的个人调试描述文件，不能直接把它视为正式 App 的签名，也不能据此断言用户没有付费团队。

开发后续负责：把团队配置写到工程源 `ios/project.yml`，核对生成工程；处理签名及现有 Access WiFi Information 能力与描述文件的一致性，不要求用户修改 Swift 代码。

依据：[注册 App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id)、[App Store Connect 工作流程](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-workflow)。

### U02 协议、收款和税务

1. 由 Account Holder 登录 App Store Connect → Business，处理 Paid Apps Agreement。
2. 按后台提示补齐收款和税务资料、处理待生效事项。
3. 反馈协议当前是否有效、是否仍有后台要求处理的项目即可。法律协议由账户持有人确认；银行和税务资料由用户或有对应权限的成员办理，不把填表转成 App 开发任务。

依据：[协议及账户配置流程](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-workflow)。

### U03 创建年度自动续期商品

1. 打开对应 App → Monetization → Subscriptions，创建或复用一个用于高级版的订阅组。
2. 在组内新增年度商品：Product ID **`com.ztransfer.ios.pro.annual`**，周期 **1 Year**，参考名称可用“一年高级版”。这里是每年一次扣费的自动续期订阅，不额外添加月付套餐。
3. 配置名称／说明的本地化、实际销售地区和价格。人民币目标 **¥39.99／年**；必须核对后台可选档位，选不到时反馈实际选项，不擅自换价。月均价由 App 根据实际年价计算，后台不另建月费商品。
4. **不启用 Family Sharing**。按后台要求补商品资料及审核信息；开发可提供购买入口说明和截图。
5. 反馈订阅组／商品 ID、实际人民币价格、销售地区、商品状态及后台尚缺资料。

依据：[创建订阅组和订阅商品](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/)。

### U04 创建永久非消耗商品

1. 打开对应 App → Monetization → In-App Purchases → 新增。
2. 类型选择 **Non-Consumable**，Product ID **`com.ztransfer.ios.pro.lifetime`**，参考名称可用“永久高级版”。永久商品不放进年费订阅组，不创建另一份“永久订阅”。
3. 补名称／说明、价格和地区；人民币目标 **¥99.99**，实际档位同样先核对。**不启用 Family Sharing**。
4. 反馈商品 ID、实际价格、地区、状态及缺失资料。年费用户买永久后仍需自己在苹果管理页取消年费；App 已有购买前说明和购买后入口，后台配置不能让这两个不同类型商品自动互相取消。

依据：[创建非消耗型内购](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/create-consumable-or-non-consumable-in-app-purchases)。

### U05 配置扣款宽限期

1. 对应 App → Subscriptions → Billing Grace Period → Set Up／Edit。
2. 选择 **16 days**，适用续订类型选 **Only Paid to Paid Renewals**。
3. 当前接沙盒阶段先选 **Only Sandbox Environment**；正式上线前再按已确认的产品规则切到 **Production and Sandbox Environment**，不要把“仅沙盒开启”记为正式环境也完成。
4. 保存并反馈时长、适用类型和环境。沙盒会加速订阅过程，不需要实际等 16 天；App 已按苹果返回的宽限期截止时间判断，不自行延长授权。

依据：[苹果宽限期配置](https://developer.apple.com/help/app-store-connect/manage-subscriptions/enable-billing-grace-period-for-auto-renewable-subscriptions)。

### U06 建立真实沙盒账户并连接现有支付代码

1. App Store Connect → Users and Access → Sandbox → 新增测试账户；使用未被注册为 Apple Account 的测试邮箱，选择与目标商品地区匹配的商店地区。
2. 在用于测试的 iPhone 启用 Developer Mode；由开发准备正式 Bundle ID 的开发签名包。工程使用普通 **`ZTransfer` Scheme**，StoreKit Configuration 不选择本地文件；`ZTransfer-StoreKit`／`ZTransfer-StoreKitUI` 保留给 Xcode 本地模拟。
3. 按当前系统提供的沙盒入口登录测试账户（通常在 Settings → Developer → Sandbox Apple Account；必要时先由开发签名 App 发起一次购买以显示入口）。使用专门的 Sandbox 登录，不把测试账户设成手机主 iCloud 账户。账户登录由用户操作。
4. 反馈“测试账户已建立、商店地区、设备已登录”。开发负责确认 App 读取的是 App Store Connect 两个商品，而不是本地 `.storekit` 文件；真实沙盒不是新支付模块，也不单靠 Debug 标记决定。

U01–U06 是当前接通真实沙盒的账户／工程准备；后台新增商品资料可能需要时间传播，不能把刚保存后暂时不可见直接判断为客户端缺实现。

依据：[建立沙盒账户](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/create-a-sandbox-apple-account)、[沙盒环境说明](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/overview-of-testing-in-sandbox)、[在设备使用沙盒](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox)。

### U07 提供隐私政策和使用条款

1. 有现成页面：提供两个对应的公开 **HTTPS URL**，确认正文适用于 iOS App 及此次苹果内购。只有安卓激活码／外部付款说明的旧条款不能直接当作已适配。
2. 没有页面：用户确定主体、联系信息、发布位置和正文；开发可以协助起草／制作，用户确认后再发布。此文档任务不代替正文确认或发布。
3. 用户／账户成员打开 App Store Connect → Apps → 对应 App → App Privacy，编辑 Privacy Policy URL 并保存，补齐实际隐私信息。开发把 `ZTransferPrivacyPolicyURL`、`ZTransferTermsOfUseURL` 写入 `ios/project.yml` 的 App Info 配置并同步生成的 `ios/ZTransfer/Info.plist`，避免后续生成工程丢失；使用条款的上架资料与最终选用正文保持一致。
4. 不需要自建授权数据库来托管这两份静态页面；发布地址确定后才有可用链接，当前 App 无配置时不会显示虚构地址。

当前实现依据：`ios/ZTransfer/UI/PremiumPurchaseView.swift` 的 `legalLinks`／`legalURL`；后台入口依据：[管理 App 隐私](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)。本节描述资料交接和现有代码行为，不替用户作法律条款决定。

### U08 优惠码活动（可暂缓）

1. 用户先决定商品（年度／永久）、免费赠送或折后实付价、适用人群、地区、数量、兑换有效期；年度优惠还需明确优惠持续期和优惠后续费规则。这里不是用户在 App 临时输入“减多少钱”的自有券系统。
2. **年费**：App → Subscriptions → 订阅组 → 年度商品 → Subscription Prices 的新增菜单 → Create Offer Codes，按活动填写规则，生成对应测试／正式代码。
3. **永久**：App → In-App Purchases → 永久商品 → Offer Codes → Create Offer，设置资格、地区和 Free Offer／Paid Offer，选择实际优惠价。
4. 测试活动使用 Sandbox Codes；不要把测试码发给正式用户。永久内购的正式发码还受 App／商品发布审核状态限制，按后台提示办理；它与配置优惠草稿、生成沙盒码不同。永久内购的 App 内兑换要求 iOS 16.3 或更新，现有文案已说明。
5. 反馈活动对应商品、优惠价／时长、资格和状态。开发不需要再造验码服务器，现有苹果兑换入口和交易监听负责权益交付。

依据：[年度订阅优惠码](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-subscription-offer-codes)、[永久等内购优惠码](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/create-offer-codes-for-in-app-purchases)。

### U09 上线前的资料与运营收尾

1. 在对应 App／商品页补齐本地化、审核截图与说明、隐私信息、最终销售地区和后台提示的缺失资料；开发可准备技术说明，账户成员负责确认和录入。
2. 正式提交前，复核 U05 已按计划启用生产宽限期、两商品未开启家庭共享、U07 链接有效；提交审核和发布作为独立操作，不因本次文档更新自动执行。
3. 上线后的营收由账户成员进入 Sales and Trends／Payments and Financial Reports 查看。苹果报表替代安卓自有营收台账，但不提供原来的设备绑定表或客服 CRM；没有待开发的同名客户端后台。当前未执行发布、审核提交或报表核对。

参考：[App Store Connect 发布与运营流程](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-workflow)。

## 4. 安卓逐项对应关系在哪里

[迁移台账第 2、3 节](安卓高级版全量审查与iOS迁移对照.md)保存安卓原行为和源文件依据；**第 8.2／8.3 节的 32 行是当前逐项实现清单**，已补“实现状态”列，另保留 iOS 策略、差异、已跑证据和未验收部分。各行使用固定编号，不把旧机制不迁移当作功能漏做。

| iOS 代码入口（仓库相对路径） | 对应编号和职责 |
|---|---|
| `ios/ZTransfer/Domain/FreeUsageStore.swift`、`TransferQueue.swift` | A01–A04：25 次／日、400 MiB、队列逐任务拦截、成功计数和 5／1 提醒 |
| `ios/ZTransfer/Domain/RemoteUsageMeter.swift`、`RemoteViewModel.swift`；`UI/RemoteView.swift` | A05–A06：180 秒／日、首帧起算、录制门控、已知期限到达时安全收尾 |
| `ios/ZTransfer/Domain/PhotoEffects.swift`、`LocalPhotoBatchViewModel.swift`、`TransferQueue.swift`；`UI/SettingsView.swift`、`PhotoEffectsEditorView.swift`、`LocalPhotoEffectsView.swift` | A07–A10：免费滤镜／边框、高级水印、偏好保护及已入队快照；两个配置作用域独立 |
| `ios/ZTransfer/UI/PremiumPurchaseView.swift`、`PremiumFireworks.swift`；`UI/Connection/ConnectionPage.swift`、`ConnectionMethodCard.swift` | A11–A14：高级入口、庆祝、连接效果、套餐和续订状态；Debug 预览不改真实权限 |
| `ios/ZTransfer/Domain/StoreKitPurchaseStore.swift`、`PremiumEntitlement.swift`；`App/ZTransferApp.swift`、`RootView.swift`、`IOSLocalization.swift` | A13–A15、B01–B12、B14–B15：应用级交易处理、权益聚合、生命周期刷新、三语错误与恢复／管理／兑换入口 |
| `ios/StoreKit/`、`ios/StoreKitTests/`、`ios/StoreKitUITests/`、`ios/project.yml` | B13：本地商品／独立测试 Scheme，真实沙盒须 U01–U06 |
| 苹果后台和 App Store | B09 的家庭共享配置、B14 活动、B16 运营报表、B17 正式分发；不新增安卓设备风控／APK 安装器 |

最主要的已确认差异：不再有自有激活码或一机一码；购买归属“媒体与购买项目”账户；年费自动续订、永久独立购买且不自动取消年费；苹果管理价格和优惠；正常续订不催手动续费；退款重算其他有效权益；所有已入队任务保留水印；约一秒同步延迟可接受。没有新增 GPS、浏览、筛选、滤镜或边框付费门槛。

## 5. 待验收单列，不计作“功能未写”

真实沙盒购买／续费／退款／宽限期／恢复、换账户／重装／换设备、相机网络和离线跨期、真机录制收尾、运行中失权、额度与跨日、大批次／其他格式、付费状态三语／大字体／其他尺寸、最低支持系统及真机性能仍有未覆盖部分。具体通过范围和历史失败以台账第 10 节为准；不能从一个本地用例通过推定全部通过。

用户已要求停止开发；本次更新文档不自动恢复这些测试，也不借文档整理新增实现范围。下一次恢复时按 R01–R04 和 U01–U09 跟进，完成一个配置项记录实际结果，而不是重复汇报已写好的功能为待开发。
