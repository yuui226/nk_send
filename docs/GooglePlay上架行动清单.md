# ZTransfer 上架 Google Play：需要我本人操作的清单

> 最后核对：2026-07-28
>
> 用法：只勾选本清单中需要账号所有者、收款人或产品负责人亲自完成/确认的事项。代码、构建和服务器改造见文末“可以交给 Codex 的工作”。
>
> 重要更新：Google 当前官方表格显示，中国同时支持 Play 开发者注册和商家注册，默认结算币种为美元，不需要为了收款冒用香港或海外身份。
>
> 官方依据：[支持开发者和商家注册的地区](https://support.google.com/googleplay/android-developer/answer/9306917?hl=zh-Hans)

---

## 一、注册前先决定（需要我确认后告诉 Codex）

### 1. 开发者主体

- [ ] 确认使用 **个人开发者账号**。
  - 我目前只有普通 Google 账号、尚未注册 Play Console，因此现在注册会被视为 2023-11-13 之后创建的新个人开发者账号。
  - 首次正式发布前，需要完成“至少 12 名测试者连续加入封闭测试 14 天”。
  - 不为了跳过封闭测试虚构企业身份。
- [ ] 如果改用真实公司/组织账号，提前准备 D‑U‑N‑S 编号、营业执照、公司地址和授权代表证件，并将决定告诉 Codex。

官方说明：

- [选择个人或组织账号](https://support.google.com/googleplay/android-developer/answer/13634885?hl=en)
- [新个人账号封闭测试要求](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en)

### 2. 两个发行渠道

- [ ] 确认保留“一套代码、两个构建版本”的方案：
  - 国内直装版：微信/虎皮椒支付，自有 APK 更新。
  - Google Play 版：Google Play Billing，Google Play 更新。
- [ ] 确认两个版本使用不同包名。当前建议：
  - 国内版继续使用 `com.ztransfer`。
  - Play 版使用 `com.ztransfer.play`。
- [ ] 确认 Play 商店对外名称。当前建议英文名为 `ZTransfer`。
- [ ] 确认老用户迁移规则：
  - [ ] 允许国内版老用户在 Play 版输入原激活码并换绑。
  - [ ] 是否允许同一份老授权同时激活国内版和 Play 版：`允许 / 不允许`。

### 3. Play 版商品

- [ ] 确认 Play 版采用“免费下载 + 应用内购买”，而不是付费下载。
- [ ] 确认永久版商品：
  - 建议商品 ID：`ztransfer_pro_lifetime`
  - 商品类型：一次性、非消耗型永久权益
  - 建议基础价格：`________`
- [ ] 确认年费版是否首发：
  - [ ] 第一版只上永久版，稳定后再加年费。
  - [ ] 第一版同时上年费。
- [ ] 如果上年费，确认续费方式：
  - [ ] 自动续订年度订阅。
  - [ ] 预付一年、到期不自动扣款（需要确认目标国家是否支持相应方案）。
  - 建议商品 ID：`ztransfer_pro_annual`
  - 建议基础价格：`________`
- [ ] 确认首发国家/地区：
  - [ ] 所有 Google Play 可销售地区。
  - [ ] 首批仅英语主要市场：`________________`。

> 建议：第一版先做永久版，减少取消、扣款失败、宽限期、暂停和续费通知带来的复杂度。

---

## 二、注册 Play Console（必须本人操作）

- [ ] 选择一个长期使用、开启两步验证的 Google 账号作为 Play Console 所有者。
- [ ] 保存好该 Google 账号的恢复邮箱、恢复手机号和备用验证码。
- [ ] 前往 [Play Console 注册页面](https://play.google.com/console/signup)。
- [ ] 选择正确的账号类型：个人。
- [ ] 使用本人真实中国姓名、真实地址、手机号和邮箱填写资料。
- [ ] 使用支持的银行卡支付一次性 25 美元注册费。
- [ ] 保存注册付款邮件和交易凭证。
- [ ] 按页面要求完成身份证件验证。
- [ ] 按页面要求使用 Play Console 手机 App 验证一台真实 Android 设备。
- [ ] 完成联系邮箱和手机号的一次性验证码验证。
- [ ] 记录并妥善保存 Play Console Developer ID。

注意：

- 旧 Gmail 账号不等于旧开发者账号；是否需要 12 人 × 14 天测试，看的是 Play Console 开发者账号创建时间。
- 姓名、地址、付款资料和证件应保持完全一致，不使用购买的开发者账号或他人资料。
- 开始收费后，Google Play 会按消费者保护要求公开商家的完整法定地址。注册前确认自己接受这一点。

官方说明：

- [开发者账号所需资料](https://support.google.com/googleplay/android-developer/answer/13628312)
- [开发者身份与联系方式验证](https://support.google.com/googleplay/android-developer/answer/10841920)

---

## 三、开通商家收款（必须本人操作）

### 1. 创建付款资料

- [ ] 在 Play Console 打开 `设置 → 付款设置/付款资料`。
- [ ] 创建中国区 Google Payments 商家付款资料。
- [ ] 法定姓名填写本人证件姓名。
- [ ] 法定地址填写可验证的中国实体地址，不使用邮政信箱或虚假地址。
- [ ] 填写公开商家资料：
  - 商家/产品名称：`________________`
  - 客服邮箱：`________________`
  - 网站：`________________`
  - 信用卡账单显示名称：`________________`
- [ ] 创建前再次核对国家、主体类型和姓名；付款资料一旦与 Play Console 绑定，修改成本较高。

官方说明：[创建付款资料](https://support.google.com/googleplay/android-developer/answer/7161426?hl=en)

### 2. 准备并绑定收款银行账户

- [ ] 联系自己的银行，确认账户可以接收来自境外的美元电汇。
- [ ] 向银行确认并记录以下资料：
  - 收款人英文姓名（必须与银行记录一致）
  - 银行英文名称
  - 账号
  - SWIFT/BIC
  - 分行英文名称和地址（如需要）
  - 中间行信息（如银行要求）
- [ ] 确认银行账户与商家付款资料同属中国。
- [ ] 在 `Play Console → 设置 → 付款设置 → 收款方式` 添加银行账户。
- [ ] 如果 Google 要求小额入账验证，收到款项后回到 Play Console 填写准确金额。
- [ ] 如果 Google 要求银行证明，上传官方银行对账单或账户证明。
- [ ] 确认付款方式状态变为已验证。

不要把银行账号、证件、密钥或付款资料提交到 Git 仓库。

官方说明：[添加商家银行账户](https://support.google.com/googleplay/android-developer/answer/7161440?hl=en)

### 3. 税务资料

- [ ] 在付款资料的税务信息页面，按本人真实情况完成问卷。
- [ ] 非美国个人按 Google 引导填写并提交 W‑8BEN/外国身份声明。
- [ ] 保存提交回执和税务表副本。
- [ ] 了解 Google 代收代缴的消费税/VAT 与本人在中国需要申报的经营/个人收入税不是同一件事。
- [ ] 收入开始产生后，咨询熟悉跨境数字服务收入的会计或税务人员，不根据网络模板虚填税务身份。

官方说明：[填写商家税务信息](https://support.google.com/googleplay/android-developer/answer/7163598?hl=en)

### 4. 服务费

- [ ] 在 Play Console 检查并报名适合自己的低费率/首个 100 万美元收入档位计划（页面名称可能随地区调整）。
- [ ] 定价时暂按约 15% 平台成本做预算，最终以 Console 实际显示为准。

官方说明：[Google Play 服务费](https://support.google.com/googleplay/android-developer/answer/112622?hl=en)

---

## 四、把应用创建到 Play Console（必须本人操作）

> 做这一步前，先与 Codex 最终确认 Play 包名。包名创建并发布后不能随意更换。

- [ ] 点击 `Play Console → 首页 → 创建应用`。
- [ ] 默认语言选择英语（美国）或最终确定的默认英语地区。
- [ ] 应用名称填写最终名称。
- [ ] 类型选择“应用”，不是游戏。
- [ ] 价格选择“免费”。免费应用仍然可以销售应用内商品。
- [ ] 填写公开客服邮箱。
- [ ] 接受开发者政策、美国出口法律和 Play App Signing 条款。
- [ ] 创建应用后，把以下信息发给 Codex：
  - Play 包名
  - 默认语言
  - 最终应用名称
  - Developer ID（只发编号，不发账号密码）

官方说明：[创建和设置应用](https://support.google.com/googleplay/android-developer/answer/9859152?hl=en)

---

## 五、准备公开资料（需要我提供或确认）

### 1. 客服和隐私联系人

- [ ] 准备一个海外用户可用、会长期查看的客服邮箱：`________________`
- [ ] 确认隐私请求/数据删除也使用该邮箱，或另设邮箱：`________________`
- [ ] 确认公开网站域名或网页地址：`________________`
- [ ] 不在英文 Play 版只提供 QQ 作为唯一客服方式。

### 2. 隐私政策中的事实确认

- [ ] 确认允许服务器为授权和反滥用保存以下数据：
  - 哈希后的设备标识
  - 手机厂商与型号
  - App 版本
  - 激活码和授权绑定
  - 订单、商品和付款状态
  - Google Play purchase token / order ID
  - 用于安全限流和日志的 IP 地址
- [ ] 确认上述数据的保存期限：`________________`
- [ ] 确认用户申请删除数据的处理方式和时限：`________________`
- [ ] 确认退款、欺诈调查或法定义务要求保留的记录可以在必要期限内继续保存。
- [ ] 确认照片、视频和相机文件只在相机与手机之间本地传输，不上传授权服务器。
- [ ] 审阅并批准 Codex 起草的中英文隐私政策。
- [ ] 将隐私政策发布到全球可公开访问、无需登录、非 PDF 的固定网页。
- [ ] 把隐私政策 URL 发给 Codex，并填入 Play Console。

不能在 Data Safety 中填写“完全不收集数据”，因为当前授权服务器确实接收和保存设备标识及订单信息。

官方说明：

- [用户数据与隐私政策](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en)
- [Data Safety 填写说明](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en)

### 3. 商店文字

- [ ] 审阅并批准 Codex 起草的：
  - 英文应用名称
  - 80 字符以内简短描述
  - 完整英文描述
  - 更新说明
  - “兼容 Nikon 相机但并非 Nikon 官方产品”的品牌免责声明
- [ ] 确认描述中明确说明部分高级功能需要应用内购买。
- [ ] 确认不使用“最好、第一、官方、100%兼容”等无法证明的宣传语。

### 4. 商店图片

- [ ] 确认或提供 512 × 512 Play 商店图标。
- [ ] 确认或提供 1024 × 500 Feature Graphic。
- [ ] 使用英文界面准备真实手机截图，建议至少覆盖：
  - 连接相机
  - 照片列表/缩略图
  - 文件传输
  - 遥控取景
  - 高级版功能
- [ ] 检查截图不包含私人照片、序列号、Wi‑Fi 密码、通知、手机号或其他个人信息。
- [ ] 审阅最终图片与排列顺序。

---

## 六、完成 App Content/政策表单（必须本人提交，Codex 可协助逐项判断）

- [ ] `隐私政策`：填写已发布的隐私政策 URL。
- [ ] `广告`：按当前事实选择“不包含广告”。
- [ ] `应用访问权限`：
  - 免费区无需登录。
  - 向审核员说明如何进入和测试高级功能。
  - 如果审核需要高级权限，提供专用审核激活码；不要提供个人账号密码。
- [ ] `目标受众和内容`：按真实受众填写；不要为了扩大覆盖面声明主要面向儿童。
- [ ] `内容分级`：如实填写问卷并保存分级结果。
- [ ] `新闻应用`：选择“否”。
- [ ] `健康应用`：按实际功能选择“否”。
- [ ] `数据安全`：依据最终 Play 构建和隐私政策逐项填写，至少重点核对：
  - Device or other IDs
  - Purchase history
  - App functionality
  - Fraud prevention, security and compliance
  - 数据传输是否加密
  - 用户能否请求删除
- [ ] `权限/特殊 API`：检查并解释麦克风用于相机取景器录像配音；确认 Play 构建不包含 `REQUEST_INSTALL_PACKAGES`。
- [ ] `前台服务`：如 Console 要求，说明 `dataSync` 前台服务用于用户主动发起的相机文件传输。
- [ ] `金融功能`、`VPN`、`政府应用`等不适用声明按事实选择“否”。
- [ ] 最后将 Data Safety、隐私政策和 App 实际行为进行一次一致性核对后再提交。

---

## 七、设置商品和定价（必须本人在 Console 创建，Codex 提供准确参数）

> Google Play Billing 功能通常需要先上传一个包含 Billing Library 的内部测试构建后才完整显示。

### 永久版

- [ ] 打开 `获利/Monetize → 商品/Products → 一次性商品`。
- [ ] 创建商品 ID：`ztransfer_pro_lifetime`。
- [ ] 商品名称和描述使用最终批准的中英文文案。
- [ ] 设置基础价格。
- [ ] 检查 Google 自动换算的主要市场本地价格。
- [ ] 必要时针对购买力差异手动调整少数国家价格。
- [ ] 选择销售国家/地区。
- [ ] 激活/发布商品。

### 年费版（如果首发）

- [ ] 打开 `获利/Monetize → 商品/Products → 订阅`。
- [ ] 创建订阅 ID：`ztransfer_pro_annual`。
- [ ] 创建年度 base plan。
- [ ] 按已确定方案选择自动续订或预付。
- [ ] 填写价格、宽限期、暂停/恢复和国家可用性。
- [ ] 审阅用户取消后的权益截止规则。
- [ ] 激活/发布订阅和 base plan。

商品 ID 一旦投入使用就不要随意更名或复用为另一种权益。

---

## 八、配置服务器访问 Google（账号权限必须本人操作）

Codex 可以写服务器代码，但以下云账号操作需要由我在 Google 页面完成：

- [ ] 在 Google Cloud Console 创建专用项目，例如 `ztransfer-play-production`。
- [ ] 在该项目启用 `Google Play Developer API`。
- [ ] 创建专用于 ZTransfer 服务端的 service account。
- [ ] 在 Play Console 的 `用户和权限` 中邀请该 service account 邮箱。
- [ ] 只授予完成购买验证所需权限，Google Billing 官方要求重点包括：
  - `View financial data, orders, and cancellation survey responses`
  - `Manage orders and subscriptions`
- [ ] 将权限限制到 ZTransfer 应用，不给无关应用或管理员权限。
- [ ] 创建服务端所需凭证，并通过服务器密钥/环境变量安全部署。
- [ ] 不通过聊天、邮件或 Git 提交 service account 私钥 JSON。
- [ ] 凭证配置完成后，让 Codex 在服务器上做一次只读购买验证测试。

官方说明：[Google Play Developer API 入门](https://developers.google.com/android-publisher/getting_started)

### 实时购买通知（永久版也建议做；订阅版必须优先做）

- [ ] 在 Google Cloud 项目启用 Pub/Sub。
- [ ] 创建 Play 实时通知 topic。
- [ ] 给 `google-play-developer-notifications@system.gserviceaccount.com` 授予该 topic 的 Pub/Sub Publisher。
- [ ] 创建推送到 ZTransfer HTTPS 服务端的 subscription。
- [ ] 在 `Play Console → Monetize → Monetization setup → Real-time developer notifications` 填入完整 topic 名称。
- [ ] 选择接收订阅和一次性商品的全部通知。
- [ ] 点击 `Send Test Message`，与 Codex 一起确认服务器收到并正确处理。

官方说明：[Play Billing 准备与 RTDN 配置](https://developer.android.com/google/play/billing/getting-ready)

---

## 九、签名和构建资料（需要本人保管）

- [ ] 让 Codex/Android Studio 生成独立的 Play 上传密钥。
- [ ] 将 `.jks`、alias 和密码保存到至少两个安全位置。
- [ ] 不把密钥或密码提交到 Git。
- [ ] 为 Play 版启用 Play App Signing。
- [ ] 明确区分：
  - 上传密钥：由我保管，用来签 AAB。
  - App signing key：由 Google Play 保管，用来签发给用户的 APK。
- [ ] 下载并保存 Play App Signing 页面显示的 SHA‑256/SHA‑1 证书指纹。
- [ ] 确认正式构建缺少上传密钥时会失败，不能自动回退到 debug 签名。
- [ ] 每次发布前确认 `versionCode` 已递增。

官方说明：[Play App Signing](https://support.google.com/googleplay/android-developer/answer/9842756?hl=en)

---

## 十、内部购买测试（需要本人在 Console 配置并参与测试）

- [ ] 在 `Play Console → 设置 → 许可证测试` 添加自己和测试用 Google 账号。
- [ ] 建议另外准备至少两个测试账号：
  - 一个测试首次购买和恢复。
  - 一个测试退款、重复购买和换机。
- [ ] 将 Play AAB 发布到内部测试轨道。
- [ ] 确保测试账号同时有权访问内部测试版本。
- [ ] 完成永久版测试：
  - [ ] 成功购买
  - [ ] 用户取消支付
  - [ ] Pending 订单
  - [ ] 重复点击购买
  - [ ] 杀进程后恢复
  - [ ] 卸载重装后恢复
  - [ ] 换设备后恢复/换绑
  - [ ] Play Console 退款后撤销权益
  - [ ] 断网和相机 Wi‑Fi 场景
- [ ] 如果有年度订阅，额外测试：
  - [ ] 自动续费
  - [ ] 用户取消但尚未到期
  - [ ] 宽限期
  - [ ] 账号保留/暂停
  - [ ] 到期
  - [ ] 退款和撤销
- [ ] 确认测试订单没有被当成真实收入和永久生产订单处理。

官方说明：[许可证与应用内购测试](https://support.google.com/googleplay/android-developer/answer/6062777?hl=en)

---

## 十一、封闭测试 12 人 × 14 天（必须本人组织）

- [ ] 招募建议 15～20 名测试者，避免有人中途退出导致不足 12 人。
- [ ] 测试者必须：
  - 有可访问 Google Play 的 Google 账号。
  - 使用真实 Android 设备。
  - 愿意安装并实际体验 App。
- [ ] 建立 Google Groups 或测试邮箱列表。
- [ ] 在 Play Console 创建封闭测试轨道。
- [ ] 添加测试者名单。
- [ ] 上传通过内部测试的 AAB。
- [ ] 发布封闭测试版本并取得 opt-in 链接。
- [ ] 将链接和明确操作说明发给测试者。
- [ ] 确认至少 12 人点击加入，而不只是收到邀请。
- [ ] 从第 1 天到第 14 天每天检查人数保持 ≥12。
- [ ] 提醒测试者期间不要退出测试。
- [ ] 收集真实反馈，至少覆盖：
  - 手机品牌和 Android 版本
  - 相机型号
  - USB/Wi‑Fi 连接
  - 浏览和传输
  - 英文界面
  - Play购买或恢复
  - 崩溃/卡顿/失败步骤
- [ ] 保存问题、反馈和修复记录，申请 Production 权限时需要回答。
- [ ] 满足连续 14 天后，在 Dashboard 申请 Production 访问权限。
- [ ] 如实回答：
  - 如何招募测试者
  - 测试者如何使用
  - 收到哪些反馈
  - 根据反馈做了哪些修改
  - 为什么应用已经适合正式发布

官方说明：[新个人账号测试要求](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en)

---

## 十二、正式发布前的最终确认（需要本人批准）

- [ ] 在真实英文系统手机上完整走一次免费功能。
- [ ] 用生产候选 AAB 完成一次 Play 测试购买和恢复。
- [ ] 确认 Play 版中不存在：
  - 微信支付二维码
  - 虎皮椒支付链接
  - “到网站/QQ购买”之类引导
  - 自行下载或安装 APK
  - `REQUEST_INSTALL_PACKAGES`
- [ ] 确认仍可为已购买老用户提供“输入已有激活码”，但不借此引导新用户绕过 Play 付款。
- [ ] 确认隐私政策、Data Safety 和实际网络请求一致。
- [ ] 确认审核员能够进入免费区，并能按审核说明测试高级区。
- [ ] 确认所有商店图片、描述、价格、国家、客服邮箱正确。
- [ ] 确认银行和税务资料状态正常。
- [ ] 查看 Play Console `政策状态`，处理全部错误和警告。
- [ ] 审阅最终 AAB 的版本号、包名、签名和大小。
- [ ] 将封闭测试版本晋升到 Production，或创建新的 Production release。
- [ ] 填写最终发布说明。
- [ ] 选择立即发布或 Managed Publishing。
- [ ] 点击送审。

---

## 十三、上线后需要长期做的事（必须由账号所有者负责）

### 每周

- [ ] 查看 Policy status、崩溃、ANR、评论和客服邮箱。
- [ ] 回复有价值的商店评论，记录重复出现的问题。
- [ ] 检查支付服务器的 Google 验证和实时通知错误。

### 每月

- [ ] 核对 Play 财务报表、订单、退款、拒付和银行入账。
- [ ] 抽查 Google 订单与自有授权台账是否一致。
- [ ] 检查 service account、服务器证书和 Pub/Sub 是否正常。

### 每次发布

- [ ] 先发布内部测试，再逐步发布正式版。
- [ ] 递增 `versionCode`。
- [ ] 检查目标 API 和 Play Billing Library 截止要求。
- [ ] 如果数据收集、权限、SDK、支付或账号功能变化，同步更新隐私政策和 Data Safety。
- [ ] 保留上一正式版本和发布记录，但不在 Play 版恢复自更新 APK。

### 每年

- [ ] 更新税务资料或按 Google 通知重新认证。
- [ ] 核对开发者姓名、地址、邮箱、电话、银行账户仍然真实有效。
- [ ] 及时处理 Google 发来的政策和身份复验邮件。

---

## 十四、可以交给 Codex 完成的工作

以下事项通常不需要我在网页上亲自操作，只需要提供决定或在关键节点验收：

- 建立 `direct` / `play` product flavors。
- 生成国内 APK 和 Play AAB 两套构建任务。
- 为 Play 版使用独立包名。
- 把微信支付、二维码和虎皮椒代码限制在国内版。
- 把 APK 自更新和 `REQUEST_INSTALL_PACKAGES` 限制在国内版。
- 接入 Google Play Billing Library。
- 实现永久购买、恢复购买和错误处理。
- 如果决定首发年费，实现订阅生命周期。
- 改造服务器以验证 purchase token、确认购买、处理退款和撤销。
- 接入并验证 RTDN 接收端。
- 兼容老激活码和新 Play 购买权益。
- 升级 `compileSdk` / `targetSdk` 到 API 36。
- 修改正式构建，禁止回退到 debug 签名。
- 编写自动化测试并进行构建检查。
- 起草隐私政策、Data Safety 填写建议、商店文案和审核说明。
- 生成待上传的正式 AAB。

需要我配合 Codex 的原则：

- 账号密码、身份证、银行卡、税号和私钥只由我本人保管。
- 页面需要登录、接受协议、身份验证、银行/税务提交和最终发布时，由我亲自操作。
- Codex 可以根据我提供的截图或页面文字逐项指导，但不在仓库保存任何敏感资料。

---

## 当前最先要做的 8 件事

- [ ] 1. 确认个人开发者账号和 `com.ztransfer.play` 包名方案。
- [ ] 2. 确认第一版只上永久版，还是同时上年费。
- [ ] 3. 注册并完成 Play Console 身份/设备验证。
- [ ] 4. 创建并验证中国商家付款资料、美元收款银行和税务资料。
- [ ] 5. 确认客服邮箱、公开网站和隐私联系人。
- [ ] 6. 招募 15～20 名封闭测试候选人。
- [ ] 7. 让 Codex 开始拆分国内版/Play版并接入永久购买。
- [ ] 8. 内部购买测试通过后，立即启动连续 14 天封闭测试。
