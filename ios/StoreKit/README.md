# iOS 高级版支付测试

配置和责任分工见 [iOS 高级版进度与配置操作清单](../../docs/商业化与授权/iOS高级版进度与配置操作清单.md)：U01–U06 为用户／账户成员准备及开发工程交接，U07 为法律页面，U08 为可暂缓的优惠活动。客户端支付代码已接入；测试未通过、未执行和后台未配置不得混为“功能未实现”。本文件保留各阶段的真实测试记录，不作整体完成百分比统计。

最新产品口径（2026-09-19，D10）：用户接受购买后约一秒的短暂权益同步，不要求首次查询立即命中新交易。下文历史首次查询断言失败仍按实际记录，但不能再单凭瞬时缺失判定产品阻塞。独立诊断的一秒后可见来自主动重查；同进程恢复测试原已等待 App 状态 10 秒仍失败，自动收敛尚未确认。此次只更新口径，未改／运行测试或生产代码，继续按用户要求暂停。

最新状态（2026-09-19）：两个首次权益查询／重建恢复失败仍保留。按商品查询的临时替换未通过整组回归，已撤回；不能将试验实现的 14/16 当作当前生产代码结果。后续修正测试补款步骤：保留模拟扣款问题，直接调用 `resolveIssueForTransaction`，不先关闭重试模拟。年转永久退款／到期、宽限期补款及无宽限期补款的定向组合 3/3 通过（`/tmp/ztransfer-billing-issue-resolution-order.log`／`.xcresult`）；没有修改生产支付代码，没有重跑完整套件，不能由此判定真实苹果沙盒通过。此前 1/2 失败与诊断仍保留，详见迁移台账第 10 节及 [原生查询对照](NativeRecoveryProbe/README.md)。

## 两种测试环境

- **`ZTransfer-StoreKit` Scheme**：Xcode 本地 StoreKit Testing，使用本目录的 `ZTransfer.storekit`。测试价格为人民币 39.99／年和 99.99 永久，不扣真实款，不证明苹果后台已创建商品或允许该价格档位。
- **`ZTransfer` Scheme**：不指定本地 StoreKit 配置。开发签名真机安装后使用苹果 Sandbox Apple Account 测试；TestFlight 也使用沙盒交易。不能仅凭 Debug／Release 判断交易环境。

本地配置不属于 App 的资源，不打包进正式 App；只有独立交易／界面测试 bundle 会复制配置文件。客户端没有修改 `isPro` 的隐藏解锁入口。两种环境共用生产的 StoreKit 2 交易交付与验证逻辑。

## 本地运行

1. 在 `ios/` 运行 `xcodegen generate`。
2. Xcode 打开 `ZTransfer.xcodeproj`，选择 `ZTransfer-StoreKit` 和 iOS 模拟器，运行。
3. 连接页右上设置 → 解锁高级版。可测试年费、永久、恢复购买。
4. 在 Xcode 的 StoreKit Transaction Manager 中测试退款、取消续订、续订与到期；待批准可用 StoreKit 测试选项或自动化测试控制。
5. 年转永久后旧年费仍独立存在，必须在苹果管理入口取消续订。不能把永久购买成功当作年费取消成功。

自动化测试（替换为本机可用模拟器 ID）：

```sh
xcodebuild -project ios/ZTransfer.xcodeproj -scheme ZTransfer-StoreKit \
  -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath /tmp/ztransfer-premium-derived test CODE_SIGN_IDENTITY=-
```

不要对 StoreKit 交易测试使用 `CODE_SIGNING_ALLOWED=NO`。本机实测模拟器包缺少 `get-task-allow` 开发调试标记时会被 `storekitd` 以 `is not installed for development` 拒绝加载测试配置，返回 `SKInternalErrorDomain Code=3`；仅改成本地签名仍不足。项目仅对 **Debug＋iOS Simulator** 使用 `SimulatorDebug.entitlements` 补此标记，Release 和真机继续使用原有签名配置，不能把模拟器调试标记带入正式发布。

`ZTransferStoreKitTests` 使用真实本地 StoreKit 测试交易覆盖商品配置、年度与永久聚合、退款回退、到期、待批准、重建管理器恢复、取消续订及价格加载失败。执行结果以项目审查台账为准，存在测试文件不代表已经通过。

此前完整回归的 10 个交易场景中 9 个通过，包含主动恢复购买、取消续订后的日期展示、年费待批准但永久先到账，以及扣款重试／宽限期补款恢复；**购买后立即停止并重建管理器的自动恢复仍失败**。该失败测试保留，不按整体通过或支付已完成交付。已有交易预建后的恢复结果不能代替此场景；实际 App 冷启动另有下节 UI 验证，重装与苹果沙盒仍待验证。最新证据见 `docs/商业化与授权/安卓高级版全量审查与iOS迁移对照.md` 第 10 节。

已增加[独立原生恢复诊断](NativeRecoveryProbe/README.md)：一个不引用本项目业务代码的最小 App，持续监听 `Transaction.updates`，直接购买／完成非消耗交易后读取权益，也出现首次为空、后续读取可见的现象。准备阶段调用／不调用 `AppStore.sync()` 的两种变体均复现。首次断言仍失败，后续等待只用于采样，不移入生产代码；原有恢复测试仍保留。该证据排除了必须由本项目管理器停止／重建才能触发的解释，不能直接推断真实苹果沙盒或其他系统版本。诊断工程不加入主 App 的构建或测试目标。

待批准后的重试已修正：苹果拒绝 Ask to Buy 不交付交易，因此 `pendingProducts` 只关联晚到成功，不能持续禁用商品。保留 `operation` 防止并发购买；用户可在上次请求返回后主动重试。新增 `testDeclinedAskToBuyCanPurchaseAgainWithoutRestart` 使用实际本地拒绝和再次购买，修复前失败、修复后通过。此前四项定向组合 `/tmp/ztransfer-pending-declined-after.log` 为 3/4，旧年费晚到账未清 pending；后续定位到订阅状态通知只刷新、不交付其携带的已验证批准交易。现将有待批准请求的 subscribed 通知交给既有交易处理器，保持商品／签名验证、交付后 finish 和庆祝去重。修复后 `/tmp/ztransfer-pending-status-delivery.log` 六项 6/6（含宽限期／扣款重试），再按原失败组合运行 `/tmp/ztransfer-pending-status-original-order.log` 为 4/4。完整诊断及历史失败保留在迁移台账；未验证实际待批准 UI／真实沙盒，两个既有首次查询与重建恢复失败仍未解决。

## 从实际界面验证购买、升级与冷启动

```sh
bash ios/StoreKit/test-recovery-ui.sh SIMULATOR_ID
```

脚本在每个场景前运行宿主测试配置本地 StoreKit 并清空交易，再逐项运行 `ZTransfer-StoreKitUI`：

- 永久版到账后、尚未确认系统成功提示时，立即终止并重启 App，检查自动恢复。
- 确认系统成功提示后，检查普通永久购买页自动收起，再检查冷启动恢复。
- 购买年费后转永久：检查重复购买年费被禁用、下次续费日期、购买前说明的取消／继续分支、升级后保留取消年费提醒及重启后的管理入口；再进入苹果管理页实际取消原年费，检查永久权益保留、取消提醒和下次扣款日期消失，重启后状态一致。
- 苹果管理页取消：`testAppleSubscriptionManagementCancelsRenewalAndKeepsPaidTerm`，先从实际界面完成本地年费购买，再通过 App 管理入口打开苹果页面取消续订；检查返回及重启后仍为高级版、续订已关闭并显示有效期。运行结果以台账为准，不能仅因存在用例就算验收通过。
- 高级徽标：`testPurchasedBadgeCelebratesWithoutReopeningPurchaseInBothSettings`，实际购买后分别进入连接页与相机照片列表的设置，连续点击高级徽标，截图留证；检查保持设置页、不重新打开购买页、设置仍可关闭。
- 简中／繁中／英文购买页：检查滚动区域在屏幕内，标题关闭按钮、两套餐金额与月均价、按年扣费说明、购买／恢复／兑换可达，并返回顶部关闭。方法名为 `testPurchasePageLayoutInAllLanguages`，同一用例可指定不同尺寸模拟器运行。
- 免费工作台：`testFreeWorkbenchLocksWatermarkButAllowsFiltersAndFrames`，检查滤镜／边框可修改和保存，默认水印的全部文字控制项被锁定，图片类型入口不能切换，逐次点击显示高级版提示且不修改值，重启后重复检查。
- 购买后工作台：`testPurchasedWorkbenchEditsAndPersistsTextWatermark`，实际购买永久版，检查水印开关／文字／全部文字样式控件可修改，再重启确认自定义值仍在。该用例不包含图片水印导入。
- 图片水印工作台：`testPurchasedWorkbenchImportsImageWatermarkAndKeepsItAfterCancelAndRelaunch`，脚本先把仓库 `debug_sample_01.jpg` 加入专用模拟器相册，再购买永久版，通过系统选图器导入。检查图片类型仅显示大小／透明度／位置，修改后取消替换和重启仍保留；尚无旧图片时还检查首次取消选图保持文字模式和可见拨轮一致。系统图片元素按实际屏幕内位置点击，不把新系统未提供的辅助功能点击坐标当作产品失败。已有图片的重复运行仍验证替换、取消和持久化，但不重复覆盖“从未导入”的分支。

- 免费相机设置：`testFreeCameraEffectsKeepWatermarkLockedAndSaveFreeChoices`，从 Debug 相机照片列表进入真实设置，检查滤镜／边框可改，全部水印控制项锁定；返回设置主页面保存草稿，重启后重复检查。Debug 照片入口不修改高级权益。
- 付费相机设置：`testPurchasedCameraEffectsSaveTextWatermarkWhenPopupCloses`，实际购买永久版后进入相机设置，修改文字与六项样式，通过弹窗外点击保存；重新打开及冷启动后均核对原值与可编辑状态。运行结果见实施台账，不以用例存在替代通过证据。
- 相机图片水印：`testPurchasedCameraImportsImageWatermarkAndKeepsItAfterCancelAndRelaunch`，复用工作台的实际购买／系统导入检查，但从相机设置进入；导入成功后不先关闭编辑器，直接重启 App 验证即时保存，再编辑图片样式、取消替换、返回设置保存并重启复核。方法已注册，结果以迁移台账为准。
- 实际相册保存：`testFreeWorkbenchSavesPhotoThroughSystemAuthorization`，免费状态从系统选图器选择一张图片，确认默认水印开启，点击生成后在系统提示中允许添加照片，检查成功和回到可生成状态。
- 实际双图批量保存：`testFreeWorkbenchSavesTwoPhotosThroughSystemAuthorization`，免费滤镜／边框开启，系统选图器勾选两张，系统授权后保存两张并恢复操作；脚本核对恰好新增两张 JPEG，所有旧原图哈希不变。
- 拒绝相册保存：`testWorkbenchDeniedPhotoSaveReportsFailureAndCanRetry`，在实际系统授权提示中拒绝，检查失败明细和再次尝试仍失败，不能重复弹授权框或伪报成功。

工作台和相机设置用例会修改指定模拟器中各自独立的滤镜／边框／水印偏好，应使用专用测试模拟器。脚本结束时清理 StoreKit 交易，不删除用户偏好或素材；页面滚动使用边缘区域，避免把滚动误发给中央的参数拨轮。相机设置的滚动区域可能宽于弹窗实际接收触摸的范围，测试按两者交集选择边缘，不使用屏幕固定坐标。

图片用例还会向指定模拟器的系统相册添加上述测试图片，不自动删除相册照片；它验证的是水印素材导入，没有把“生成效果图并写回相册”算作已通过。

三条相册保存用例会重置指定 App 的 `photos`／`photos-add` 权限，保留用户在测试系统提示中的选择；仅允许命名为 `ZTransfer-*` 的专用模拟器，不能在用户日常模拟器执行。脚本添加测试图片后记录相册原始文件的内容哈希，UI 完成后用 `verify-photo-export.py` 验证：允许时按所选用例恰好新增一张或两张 JPEG，拒绝和重试后零新增，所有原图保持不变。新增文件副本、尺寸及哈希保存在当次结果目录，供视觉复核；检查只读取模拟器相册，不替 App 写入或修复资产。实际执行结果继续以台账为准。

所有付款都在苹果系统的 **Xcode 测试确认单**上确认。Apple 的交易监听可能在 `purchase()` 返回前交付权益；App 成功页的自动收起需等用户确认系统成功提示，两者分别验证。最后无论成功或失败都运行宿主测试清理交易。每次结果保存在脚本输出的独立临时目录；可设置 `ZTRANSFER_TEST_DERIVED_DATA` 复用已有编译缓存。第二个可选参数可指定上述任一完整测试方法名，拼错时直接报错，避免空跑被误认为通过。

当前 Xcode 27／iOS 26.5 模拟器会拒绝独立 UI runner 的 StoreKit 测试控制请求，报 `is not installed for development`；不能忽略错误后把旧交易当成新测试结果。脚本把 `SKTestSession` 配置和清理留在有调试权限的 App 宿主进程，常规 UI runner 只操作实际界面，不注入高级标记；退款控制诊断的限制见下文。UI 测试必须核对系统付款单为 Xcode 且明确不扣款，才点击确认。

扣款重试测试的苹果系统提示可能在交易清理后仍覆盖下一次 App 启动。UI runner 只对同时出现 `Billing Problem` 与 `[Xcode]` 的测试提示点击 `Cancel`；不自动解决扣款，不关闭未知系统提示。页面断言仍正常执行，不能以此跳过入口验证。

上述三条实际付款 App 界面路径此前均通过，升级后及重启后的管理页截图已检查。但后续 `ztransfer-storekit-ui.ZY4KyB/` 的永久购买冷启动回归未通过：准备及清理成功，点击购买后 10 秒内未出现系统测试付款单，没有确认付款。随后仅重启专用模拟器，未改生产代码、付款等待上限或 Xcode／不扣款断言，`ztransfer-storekit-ui.1hPQPk/` 的相同用例及准备／清理全部通过。现象随测试环境重启消失，但根因未确定，不能宣称已修复测试环境的偶发问题。它们与上面的**同进程重建管理器**是独立场景，后者的失败没有删除或放宽断言。冷启动通过也不代表重装、换账户或真实苹果沙盒通过；苹果系统管理页的普通年费取消、年转永久后取消现均已本地验证，结果见下段，真实沙盒仍待验证。

苹果管理页新增用例在专用 SE 3／iOS 26.5 通过：`ztransfer-storekit-ui.KXh2Kv/` 准备、UI 1/1（62.682 秒）和清理均 TEST SUCCEEDED。真实本地年费购买后打开苹果 Xcode 管理页、确认取消，返回／重启均保留 Pro、续订关闭和本期有效期。系统网页取消动作按实际 StaticText 定位，关闭使用导航栏控件；两次先前失败为等待／控件定位问题，完整记录见台账。已查看重启截图和系统截图；立即截图尚未反映网页状态刷新，不将其作为取消结果证据。

随后扩展年转永久用例，实际进入同一苹果页面取消旧年费：`ztransfer-storekit-ui.0P5Obd/` UI 1/1（94.279 秒），准备／清理均 TEST SUCCEEDED。返回和重启后均保留永久高级版、显示续订关闭，原取消提醒、下次扣款日期和购买选项消失；取消前后截图已核对。两条用例复用系统取消操作，普通年费回归 `ztransfer-storekit-ui.283oHG/` UI 1/1（61.984 秒），准备／清理均通过。这只补齐 Xcode 本地管理流程，真实苹果沙盒仍待验证，既有首次查询／同进程恢复失败不因此消除。

2026-09-19 再扩展同一普通年费用例 `testAppleSubscriptionManagementCancelsRenewalAndKeepsPaidTerm`：取消后重启，再从苹果管理页选择原年度商品，核对 Xcode／不扣款提示并确认重新订阅，关闭成功提示及管理页。返回与再次重启均检查 Pro、Auto-renewal is on、Annual renewal on 日期与取消时的 Valid until 日期相同，旧有效期／关闭续订提示消失。最终 `/var/folders/rr/fss4jpkd4j75hmdqk75km2x80000gn/T/ztransfer-storekit-ui.LYMJ1l/` UI 1/1（132.402 秒）、准备和清理均 TEST SUCCEEDED，脚本退出 0；`/tmp/ztransfer-reenable-final-attachments/` 的返回／重启截图已查看。本次没有新增测试方法，脚本默认仍为 16 项，未全量重跑。

测试定位修正：重新订阅的成功提示在 App 的辅助功能树中，需要通过 `app.alerts["You’re all set."]` 确认；付款确认单仍属于 SpringBoard。未关闭成功提示时，网页暂时不可查询不代表管理页已关闭。确认单的不扣款说明可能前置变更生效说明，现匹配包含完整不扣款句子的文本，仍必须同时存在 Xcode 才能确认。中间两次 UI 失败及一次主动中断保留于迁移台账；未修改生产支付代码或动画。本地通过不替代真实苹果沙盒或两个既有查询／恢复失败的修复。按用户要求，本项完成并同步文档后暂停，整体完整里程碑仍 3/8。

三语布局用例已在 iPhone SE 3 与 iPhone 17 Pro（iOS 26.5）通过，包含屏幕边界和操作可达断言；不能代替其他尺寸／动态字体、付费状态三语或真实沙盒验收。

修正小屏英文短值换行后，在 SE 3 重跑三语用例：`ztransfer-storekit-ui.IY07eA/` UI 1/1（165.543 秒），准备／清理均通过。已查看 `/tmp/ztransfer-table-fit-attachments/` 三语表格截图，Supported／Unlimited 完整显示。保持安卓列宽、文案和行布局，仅对年费／永久短值按需适配 iOS 字宽；构建安装结果见台账。

工作台免费、付费文字、付费图片三个用例在专用 iPhone SE 3（iOS 26.5）上 3/3 通过，准备和交易清理也通过。已检查免费／付费文字重启截图、首次取消选图及图片重启截图，并核对私有图片的哈希和实际字节。修复了首次选图尚未完成时拨轮提前显示 Logo 的问题：点按只提出候选值，使用原动画同步实际接受的选择。相机设置与系统单图保存的后续独立验收见下文；编辑中失权和真实苹果沙盒仍待验证。具体日志、最终 Debug 构建安装结果见迁移台账第 10 节。

购买页 UI 回归保留在 `ios/PopupUITests/PremiumPurchaseUITests.swift`，复用该目录的独立 runner。先构建并安装 Debug App，再把 runner 的配置及 Swift 文件复制到临时目录、运行 `xcodegen generate`，只执行 `PremiumPurchaseUITests`。UI runner 使用 `CODE_SIGN_IDENTITY=-` 本地签名；可用 `-collect-test-diagnostics never` 避免失败时耗时收集整机诊断。测试检查真实设置入口、按钮范围稳定、套餐／恢复／兑换可达，以及连续两次开关；不注入假的高级权益。

## 录制失权后的实际 MP4 收尾验证

`ZTransferTests/RemoteLifecycleTests` 的 `testExpiryFinalizesPlayableRecordingBeforeExhaustedMonitorExits` 和 `testPausedRecordingFinalizesOnRevocationAndConcurrentPageExit` 使用生产解码、录制、到期回调及退出链路；相机 JPEG 与已验证权益输入受控，不通过 StoreKit 模拟真实退款。为避免采集麦克风或权限弹框，先在**专用测试模拟器**设置：

```sh
xcrun simctl privacy SIMULATOR_ID revoke microphone com.ztransfer.ios
```

设备须已启动且测试宿主已安装。没有拒绝权限时上述两项会明确 `XCTSkip`，不能将跳过计作通过；不要修改用户真机的权限。使用普通 `ZTransfer` Scheme 定向运行上述两项及 `ZTransferTests/RemoteViewfinderRecorderTests`，不需要 StoreKit 商品配置。原录制器用例也已从“文件非空”增强为实际可播放、正时长、轨道数和全帧解码验证。

`/tmp/ztransfer-recording-loss-decode-v2.log`／`.xcresult`：TEST SUCCEEDED，3/3、零跳过；附件 `/tmp/ztransfer-recording-loss-attachments/` 保留到期／暂停撤销的两份 MP4。首次 `/tmp/ztransfer-recording-loss-decode.log` 为测试清理闭包的 Sendable 编译失败，修正后才执行；没有更改生产代码。离线测试解码 helper 有一次 QoS 等待警告，不是生产帧率测量。范围仅含本地无声录制，不含真机后台、有声录制、系统授权等待或实际苹果到期／退款；支付查询缺口和真实沙盒状态不变。

## 苹果沙盒前置配置（尚未完成）

2026-09-19 本机只读核对：已找到有效 Apple Development 签名身份，且一台 iPhone 14（iOS 26.6.2）已配对并开启开发者模式。现有描述文件为 `LocalProvision=true` 的免费个人团队配置，App ID 是 `com.ztransfer.ios.personaldebug`，覆盖该真机，但没有正式工程所用的 `com.ztransfer.ios` 描述文件，也不包含工程的 Wi-Fi 信息能力。工程 `DEVELOPMENT_TEAM` 仍为空。因此不能把“有证书／有手机”记为真实沙盒已经就绪，也不能直接套用个人调试包的描述文件。是否另有付费团队、App Store Connect App／商品及测试账户，已询问用户，尚未确认；未读取或索取账户密码、未改团队／Bundle ID、未安装真机 App。

工程隔离只读检查已通过：`ZTransfer` Scheme 没有本地 StoreKit 配置，主 App 资源阶段不包含 `.storekit`；`ZTransfer-StoreKit`／`ZTransfer-StoreKitUI` 使用本地配置，商品文件仅进入两个 StoreKit 测试 bundle。模拟器调试签名覆盖仅适用于 Debug＋Simulator。此检查没有执行新的构建，不能代替正式归档、签名或真实沙盒验收。Xcode 本地测试可在后台商品配置前运行；真实沙盒使用 App Store Connect 商品与沙盒账户，见 [苹果测试环境说明](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/overview-of-testing-in-sandbox)。

1. 在开发者账户配置 App `com.ztransfer.ios` 的签名团队、Bundle ID 与 App Store Connect 记录；现有记录如有不同，须同步实际标识，不能另建重复 App。
2. 创建订阅组与一年自动续期商品 **`com.ztransfer.ios.pro.annual`**，以及非消耗商品 **`com.ztransfer.ios.pro.lifetime`**。商品 ID 必须与代码一致；不是授权码。
3. 两商品均关闭家庭共享。核对人民币目标价格档位，配置实际销售地区、本地化及审核资料；不擅自用相近档位替代目标价。
4. 在订阅设置启用 **16 天、仅已付费续订**的 Billing Grace Period，并启用沙盒测试。客户端读取苹果实际宽限期日期，不本地加 16 天。
5. 完成 Paid Apps 协议、收款与税务资料，创建 Sandbox Apple Account，在真机开发者设置登录。使用 `ZTransfer` Scheme，运行设置中的购买／恢复／管理功能。
6. 在 App Info 配置 `ZTransferPrivacyPolicyURL` 与 `ZTransferTermsOfUseURL` 为用户确认的 HTTPS 页面，同时在 App Store Connect 填写对应资料。当前没有已发布的页面，不捏造链接；正式上架前必须补齐并验证购买页可打开。
7. 优惠码金额、期限、资格和发码数量尚未定，不预建示例活动。确定后按苹果后台配置付费／免费 offer codes，并在苹果沙盒验证兑换及交易交付。永久商品优惠码要求 iOS 16.3 或更新系统。

需要真机沙盒验证的场景：购买确认／取消／待批准、回前台到账、退款、续费／到期／宽限期、永久与年费并存、账户切换、重装和同账户新设备恢复、相机 Wi-Fi 无外网／蜂窝可用、优惠码兑换。未执行的场景不得标记完成。

## 高级权限与实际水印输出

`ZTransfer` Scheme 的 `PremiumBusinessTests` 和 `PhotoEffectsBatchTests` 用于业务门控验证，不依赖 Apple 商品配置。此前合并定向运行 23/23 通过，包含生产渲染器的真实 JPEG 对比：旧任务在退款／升级后仍用入队水印，新任务采用当前权限；图片水印换素材后重试保留旧图；相机下载途中失权不改变派生水印；本地批次等待相册授权期间不被权益变化或重复点击改写。另覆盖退款后即时保存保护已有高级水印参数、免费新增收藏采用默认水印，以及相机／工作台独立存储。

最新监看到期修正后，`PremiumBusinessTests` 为 18/18（`/tmp/ztransfer-monitor-deadline-after.log`／`.xcresult`），本轮没有重跑 PhotoEffectsBatchTests。新增四项验证已知截止时间在无新 StoreKit 发布时触发失权并计入剩余免费额度、延期／转永久替换旧截止任务、非活跃到期不记免费时长、退出取消任务。该一次唤醒复用录制的失权回调，永久版无定时器；测试使用受控权益模型与真实任务调度，不代表真机录制保存或实际苹果到期服务已验收。修复前失败与范围见迁移台账。

本地批次业务测试使用受控授权和临时文件替代系统相册写入，不据此判定真实选图／授权／保存通过；系统单图路径另有下述 UI 和文件核对证据，物理相机仍需验证。这些业务测试不替代 StoreKit 支付测试或苹果沙盒，既有同进程重建管理器的恢复失败状态不变。最新日志与输出附件路径见迁移台账第 10 节。

相机设置两条新增用例已在专用 iPhone SE 3／iOS 26.5 通过（最终 2/2）：付费文字键盘避让、弹窗外关闭提交及重启保存；免费状态滤镜／边框返回保存、全部水印控制项锁定及重启保持。还核对免费编辑后的私有偏好仍保留上次付费文字与样式。首次付费用例发现键盘遮挡，已修正设置弹窗底部安全区处理；完整结果与中间失败记录见台账第 10 节。相机图片导入和系统单图保存另有独立验收，不由这两条文字／免费用例代替；编辑中退款和实体相机仍待验证。

系统相册保存两条用例最终 2/2 通过：允许添加照片时 UI 成功并新增一个可读 JPEG，18 张原图哈希未变；拒绝及再次生成均显示失败，不重复弹授权，21 张原图未变且零新增。脚本逐次保留原图清单、输出副本和验证 JSON；结果及中间测试定位问题见台账第 10 节。选择的是系统网格当前第一张照片，重复运行可能选到上次输出，因此不以该测试替代固定输入的渲染像素回归、批量或其他格式验收。

双图系统保存的独立验收已通过：`ztransfer-storekit-ui.7ciEdc/` 准备、UI 1/1（54.339 秒）、清理均 TEST SUCCEEDED，文件校验确认旧 25 张原图未变，新建两张 JPEG（632×947、542×812）。已查看选图勾选两张、完成状态以及两张实际输出。选择的是系统网格当前前两张，本次为之前的输出，故有多重边框；不把它作为固定输入像素测试、其他格式、大量批次或处理中失权的证据。完整路径、哈希和范围见迁移台账第 10 节。

相机图片水印新增用例在专用 SE 3／iOS 26.5 通过（`ztransfer-storekit-ui.fbfvuc/`，UI 1/1，准备与清理均通过）：首次取消保持文字模式，实际系统导入后直接重启仍恢复，图片三项样式修改、取消替换和返回保存后的再次重启均保留。已检查实际预览截图，私有图片哈希与保存配置及系统相册所选文件一致。此用例复用工作台导入步骤，仍分别验证相机的即时导入保存和编辑草稿提交行为。

共用图片导入测试的工作台回归也已通过：`ztransfer-storekit-ui.vK17gD/` 准备、UI 1/1、清理均成功，重启截图已检查。与相机用例各自验证作用域的保存行为，不把两个入口合并成一份业务状态。

## 编辑过程中退款／到期的补验

`StoreKitPurchaseTests.testRefundAndExpiryProtectOpenEditorPreferencesInBothScopes` 使用实际本地永久购买、退款、重新购买年费和到期事件，驱动相机／工作台共用的 `PremiumAccess`，不直接设置高级标记。两个独立配置作用域都检查：旧高级水印偏好保留、免费边框编辑仍能保存、进行中的图片导入结果不能再提交、新图片导入不能开始、有效水印回到品牌默认参数。新增定向用例 1/1 通过，证据 `/tmp/ztransfer-storekit-editor-events-final.log`／同名 `.xcresult`；未重跑完整交易套件，原同进程恢复失败仍保留。

实际界面退款用例 `PremiumRecoveryUITests.testRefundWhileWorkbenchEditorIsOpenRestoresFreeWatermark` **尚未通过**。可将完整方法名作为脚本第二个参数单独诊断；它不在脚本默认的 16 条常规回归中，也不计作通过。`ztransfer-storekit-ui.goyQPa/` 在正常界面购买之后创建 `SKTestSession`，仍被 `storekitd` 明确拒绝：`com.ztransfer.ios.storekituitests.xctrunner is not installed for development`，因此未执行到退款／编辑断言。准备与清理通过，不能将其写成界面退款验收。

尝试仅对 UI 测试目标的模拟器 Debug 使用签名内的 `get-task-allow` 后，`ztransfer-storekit-ui.eeKM7K/` 的 runner 无法启动。该试验的 entitlement 文件及 `ENTITLEMENTS_DESTINATION=Signature` 配置已经撤回；不修改正式 App 签名，不往 App 添加退款测试按钮／假授权入口。保留失败诊断，实际界面退款还需可用的测试环境验证。

补验最终版明确等待重新购买得到年度权益，再触发到期；`/tmp/ztransfer-storekit-editor-events-final.log` 为 `TEST SUCCEEDED`，1/1。图片导入部分是受控回调，不冒充系统选图期间退款的 UI 验收。撤回签名试验后，`ztransfer-storekit-ui.kkS6oZ/` 的正常永久购买、系统成功提示确认、购买页关闭及冷启动恢复 1/1，准备／清理均通过。

## 高级徽标烟花验收

`testPurchasedBadgeCelebratesWithoutReopeningPurchaseInBothSettings` 在真实本地永久购买、重启恢复后验证连接页／照片列表两个设置入口：连续点击 Pro 徽标不再打开购买页，设置弹窗仍可正常关闭。最终 `ztransfer-storekit-ui.ayMCih/` UI 1/1，准备与清理也通过，两张截图已查看。

生产绘制将固定随机参数、方向和颜色保存在每次发射的独立记录中，保持安卓时序与轨迹。`PremiumFireworksTests` 对优化前保存的 8 张 PNG 做 RGBA 逐像素比较，全部相同（`/tmp/ztransfer-fireworks-after.log`／`.xcresult`）；测试资源不进入正式 App。此检查不代表实际帧率或所有尺寸验收。Debug 构建、安装、启动证据见迁移台账第 10 节。

## 网络错误与订阅状态缺失

新增两项恢复网络错误集成测试通过，覆盖有效年费／到期、已验证宽限期／永久退款回退；使用实际本地购买和 appStoreSync 模拟错误，不手动设置 isPro，不代表真实相机 AP 离线。

`testSubscriptionStatusFaultReturnsEmptyAndRecovers` 验证当前 iOS 26.5 的原生行为：注入错误前状态有一项，错误期间组／商品查询均返回空数组而非抛错，清除后恢复。此检查已通过，不计作生产 catch 分支验收。

有效年度交易仍在、但订阅状态为空时，生产代码改为 renewal=unknown，保留永久用户的年费管理入口；不会由此发放权益。对应 unknown 断言通过，**整项仍未通过**：`testEmptyStatusCannotHideAnnualManagementAfterLifetimePurchase` 在刚买永久后立即注入故障并刷新时只剩年费；失败后采样显示测试历史仍有未撤销永久交易，但当前权益／最新永久交易查询没有返回它。严格断言保留，不加入延迟或自动 sync 绕过。

本轮 `/tmp/ztransfer-storekit-network-final.log`／`.xcresult` 为 3/4，整体 TEST FAILED；最终缺口重现为 `/tmp/ztransfer-storekit-empty-status-history.log`／`.xcresult`。原 10 项中 9 项通过的历史基线未重跑，新旧缺口是否同源尚未确认；中间失败与诊断证据见迁移台账第 10 节。

独立原生程序随后加入年费转永久对照：先确认年费可查询、再购买永久后立即读取，均只返回年费，latest(lifetime) 为 nil；有／无状态故障两组都复现，后续采样均能读到永久。这证明故障注入与项目管理器不是复现的必要条件，未证明真实沙盒同样受影响。四项对照及 0/4 的严格首次断言结果见 [原生诊断](NativeRecoveryProbe/README.md)；主工程失败项仍保留，未以诊断后续读取代替验收。

## 权益快照与退款记录顺序

完整扫描与监听统一应用同交易的签名顺序保护，避免旧副本覆盖内存里较新的退款记录。当前扫描不含商品时仍移除，不把旧账户权益作为永久兜底；不同交易也不沿用旧记录。本轮权益模型 14/14（修正前 13/14），本地 StoreKit 退款、到期、宽限期、补款及编辑器失权回归 5/5。证据分别为 `/tmp/ztransfer-snapshot-order-after.log`／`.xcresult` 和 `/tmp/ztransfer-snapshot-order-storekit.log`／`.xcresult`，均 TEST SUCCEEDED。

模型用例构造已验证记录输入，未在苹果服务诱发乱序；集成用例通过实际本地交易验证既有退款／续订路径没有退化。上面的首次查询缺失仍未解决，真实账户切换与沙盒仍待验收，完整失败套件未重跑。

## Debug 连接动画预览

对照安卓 DebugSimulatorButton，模拟照片入口普通点击按真实权益选择连接效果，长按 500 ms 请求本次模拟连接的高级金色效果。预览只绑定模拟 CameraSession，不修改 PremiumAccess、StoreKit 或免费额度；Release 不组合入口。保持已经确认的 iOS 620 ms 主段＋760 ms 成功效果和原交接时序。

新增 `testDebugPremiumAnimationPreviewKeepsFreeWatermarkLocked` 验证实际长按进入后，设置仍显示免费入口、水印全部控制项仍锁定，重启后普通点击仍为免费。新增模型检查预览归属、松手重复连接无效、另一个工作区不继承及真实权限／额度未变。结果：`/tmp/ztransfer-premium-debug-preview.log`／`.xcresult` 定向 2/2；`ztransfer-storekit-ui.k3pkFI/` 的 UI 1/1，准备／清理均通过。录屏 `/tmp/ztransfer-debug-preview.mp4` 的 81.25 秒金色光环与 213.1 秒绿色双环帧已查看，确认长按预览与重启后的普通点击正确选择效果；UI 截图也已检查。Debug 构建、安装、启动通过，完整证据见迁移台账第 10 节。这不是实际帧率或真机连接验收。
