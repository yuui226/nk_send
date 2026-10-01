# 原生 StoreKit 首次权益读取诊断

2026-09-19 用户决定 D10：接受约一秒的短暂同步延迟，不再要求首次读取立即含新交易。因此下述严格首次断言是历史诊断证据，不能单凭其失败阻塞产品交付。一秒后可见是本程序主动再查询的结果，不代表主 App 已自动更新或苹果保证一秒同步；主 App 最终是否自行收敛须单独区分。本次未修改测试、生产代码或原始结果，开发继续暂停。

这个独立 App 不引用 ZTransfer 的购买管理器、权益模型或启动代码，只调用苹果的
StoreKit／StoreKitTest。它用于调查现有自动恢复测试失败，不随主 App 编译或发布。
保持交易监听后，购买非消耗商品、验证并完成交易，再读取 `currentEntitlements`。
两个用例分别在准备阶段调用／不调用 `AppStore.sync()`，排除该准备步骤的影响。

当前 Xcode 27／iOS 26.5 模拟器的两个用例均失败：购买历史有交易 `0`，首次权益读取为空；
失败断言之后等待 1 秒，再读能够取得交易 `0`。后面的读取只是诊断，不能将已失败的
首次读取改判通过；生产代码没有引入这段等待、轮询或自动 `AppStore.sync()`。

这证明该现象不需要项目自己的状态管理／停止重建逻辑也能出现，不证明真实苹果沙盒
有同样问题，也不证明所有系统版本都会失败。主工程的失败用例继续保留；实际 App
冷启动通过是另一项证据，不能互相替代。苹果文档规定非消耗商品属于当前权益，监听
应在启动时建立：[currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements)、
[updates](https://developer.apple.com/documentation/storekit/transaction/updates)。

使用项目根目录运行，`SIMULATOR_ID` 换成测试模拟器 ID。输出目录需为新目录，避免复用
旧 `.xcresult`。此诊断仅用于本地 Xcode 测试，系统付款对话框关闭，不会产生真实扣款。

```sh
probe_output="$(mktemp -d /tmp/ztransfer-native-probe.XXXXXX)"
cp -R ios/StoreKit/NativeRecoveryProbe "$probe_output/NativeRecoveryProbe"
cp ios/StoreKit/ZTransfer.storekit "$probe_output/ZTransfer.storekit"
xcodegen generate --spec "$probe_output/NativeRecoveryProbe/project.yml"
xcodebuild -project "$probe_output/NativeRecoveryProbe/NativeStoreKitProbe.xcodeproj" \
  -scheme NativeStoreKitProbe -configuration Debug \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath "$probe_output/DerivedData" -collect-test-diagnostics never \
  -resultBundlePath "$probe_output/NativeRecovery.xcresult" \
  test CODE_SIGN_IDENTITY=- > "$probe_output/NativeRecovery.log" 2>&1
```

初始独立复现日志：`/tmp/ztransfer-native-continuous-listener.log`，移除准备同步：
`/tmp/ztransfer-native-without-fixture-sync.log`，两种准备方式和后续读取对照：
`/tmp/ztransfer-native-timing-observation.log`／同名 `.xcresult`。原生交易记录显示商品类型为
`Non-Consumable`、购买归属为此诊断 App 的 Bundle ID，不是商品类型或主 App ID 不匹配。

仓库保存版本按上面的复制／生成方式再次运行：`/tmp/ztransfer-native-final-reproduction.log`／
同名 `.xcresult`，2 个用例均在首次权益断言失败，随后读取均为 `[0]`。这个 `TEST FAILED`
是待调查现象，不能写成恢复通过。早先直接把 Xcode 工程生成到另一个目录导致签名文件相对
路径失效，`/tmp/ztransfer-native-repo-reproduction.log` 属于构建失败、不构成运行证据；
现说明明确先复制源文件与共享商品配置到临时目录再生成，最终运行已验证该流程。

## 年费转永久的独立对照

新增四条对照，不引用主 App 的任何源码，保持原生交易监听、实际购买与 finish：

- `testAnnualAndLifetimeRemainVisibleWithoutStatusFault`
- `testAnnualAndLifetimeRemainVisibleWithStatusFault`
- `testLifetimeAfterEstablishedAnnualWithoutStatusFault`
- `testLifetimeAfterEstablishedAnnualWithStatusFault`

前两项连续购买年费与永久版；后两项在购买永久版之前，先等待年费状态确认为 subscribed，
复刻主工程集成测试的前提。购买永久版之后到首次权益查询之间没有人为等待；只在严格
断言已经记录失败后，间隔 1 秒作诊断采样，不把后续读到交易改判首次读取通过。

Xcode 27／iOS 26.5 实测：

| 对照 | 首次 currentEntitlements | 首次 latest(lifetime) | 后续采样 |
|---|---|---|---|
| 连续购买，不注入状态故障 | 空 | nil | 年费与永久均已验证 |
| 连续购买，注入状态故障 | 空 | nil | 故障仍开启时已能读到两份权益 |
| 先确认年费，不注入状态故障 | 仅年费 | nil | 年费与永久均已验证 |
| 先确认年费，注入状态故障 | 仅年费 | nil | 故障仍开启时已能读到两份权益 |

所有情况下 SKTestSession 历史均包含未撤销的年费 id=0 和永久 id=1；查询日志区分 verified、
unverified 与 nil，此次缺失不是返回了未通过验证的永久交易。状态故障不是复现的必要条件，
项目自己的购买管理器、停止重建、退款逻辑也不是必要条件；这不证明主工程其他竞态不存在，
也不能替代真实苹果沙盒、账户切换或重装验证。

证据：`/tmp/ztransfer-native-pair.log`／`.xcresult` 前两项 0/2；
`/tmp/ztransfer-native-established-pair.log`／`.xcresult` 后两项 0/2，均为 TEST FAILED。
第一次运行产生四条失败断言，仍只算两个失败用例；后两项各仅永久断言失败。
生成工程位于 `/tmp/ztransfer-native-pair.3f9ijc7a/`，仍按上述复制流程构建；可用
`-only-testing:NativeStoreKitProbeTests/NativeStoreKitProbeTests/方法名` 单独运行各项。
生产代码没有加入诊断用的等待、额外同步或本地永久权限兜底。

## 完成交易时机和按商品查询的对照

新增 `testPurchaseIsVisibleBeforeFinishingTransaction`：购买返回已验证交易后，先读取全量
当前权益再 finish，仍保留首次必须含永久交易的严格断言。首次为空并失败，完成交易后
的诊断采样才读到交易。因此“finish 提前移除了当前权益”不足以解释原现象；不是建议
延迟完成正式交易。

新增 `testFinishedPurchaseIsVisibleInProductScopedEntitlements`：先 finish，再直接调用
iOS 18.4 起的 `Transaction.currentEntitlements(for:)`，不提前用全量读取暖缓存；本次首次
返回永久交易，通过。接口定义见 [苹果文档](https://developer.apple.com/documentation/storekit/transaction/currententitlements(for:))。
两项证据 `/tmp/ztransfer-native-read-boundary.log`／`.xcresult`，1/2，整体 TEST FAILED。
测试工程 `/tmp/ztransfer-native-read-boundary.YuGZd5/`，没有使用主工程购买管理器。

这个单用例通过**不能证明替换查询接口能解决整体问题**。随后在主工程临时改为较新系统
分别读取两个已知商品、统一发布快照，旧系统保持原 API。原测试断言／等待均未调整：
修改前两个既有失败用例 0/2（`/tmp/ztransfer-scoped-query-before.log`）；试验实现完整
StoreKitPurchaseTests 14/16（`/tmp/ztransfer-scoped-query-after.log`／`.xcresult`）。重建
管理器恢复通过，年费转永久后仍漏查永久，宽限期补款恢复 subscribed 也失败；3 条失败
记录属于 2 个失败用例，不能写成 13/16。**这次生产查询替换已撤回**，当前源码仍使用原
全量快照。保留新增独立对照，继续等待真实沙盒／其他运行环境的证据；尚未证明单项改善
来自接口语义还是执行时序差异，也没有加入定时等待、轮询、自动同步或永久标记。

撤回后按同样的前两项顺序复查，`/tmp/ztransfer-scoped-query-rollback.log`／`.xcresult`
为 1/2：年转永久退款／到期通过，宽限期用例在查找 `hasPurchaseIssue` 交易的前置步骤
失败，尚未执行模拟补款；这与试验实现中“执行补款后未恢复 subscribed”的失败位置不同。
因此不能简单把宽限期失败归因于新查询接口，也不能沿用此前通过记录宣称当前已稳定。

后续定位到主测试 helper 在 resolve 之前提前关闭重试模拟。按苹果 SDK 的“交易退出重试
后 resolve 无效”约束，改为保留问题并直接解决对应交易，结束后统一清理；生产代码未改。
`/tmp/ztransfer-billing-issue-resolution-order.log`／`.xcresult` 三项 3/3，通过退款／到期及
有、无宽限期的补款恢复。这个新结果不改变前述原生查询失败和未采用接口试验的结论，
也不替代真实苹果沙盒；完整证据在主迁移台账第 10 节。
