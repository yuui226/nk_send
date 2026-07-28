# Google Play 分支交接说明

更新时间：2026-07-28

分支：`feature/google-play-flavors`

这份文档用于暂停后继续工作。当前已经完成“代码层面的渠道拆分和支付骨架”，但还没有配置真实 Play Console、Google Cloud、线上服务端和正式商品，因此现在不应直接发布。

## 一、当前做到哪里了

### 1. 一套代码、两个发行版本

Gradle 已拆成两个 flavor：

| 渠道 | applicationId | 支付 | 更新方式 |
|---|---|---|---|
| `direct` 国内直装版 | `com.ztransfer` | 原微信/虎皮椒二维码 | 原 APK 自更新 |
| `play` Google Play 版 | `com.ztransfer.play` | Google Play Billing | Google Play 更新 |

公共相机连接、浏览、传输、遥控、免费额度和本地授权逻辑仍共用一套代码。

渠道专属代码位于：

- `app/src/direct/`
- `app/src/play/`

国内版的 `PurchaseDialog`、ZXing 二维码依赖、APK 更新器、`REQUEST_INSTALL_PACKAGES` 和更新用 `FileProvider` 只存在于 `direct`。

Play 版使用 Google Play Billing 9.1.0 的 Java artifact。没有使用 Billing KTX，因为 9.1.0 KTX 由 Kotlin 2.x 编译，而当前工程仍使用 Kotlin 1.9；Java artifact 功能相同，也不会迫使整个国内版升级 Kotlin 工具链。

### 2. Play 购买流程

Play 版已经支持：

- 永久版商品：`ztransfer_pro_lifetime`
- 年费订阅：`ztransfer_pro_annual`
- 从 Play 查询本地化价格
- 拉起 Google 官方付款界面
- `PENDING` 待付款状态
- 取消和网络错误提示
- “恢复购买”
- 把 `purchaseToken` 交给自有服务器验证
- 服务器返回原有签名授权 token 后复用现有 Pro 权益

Play 版不会在启动时请求国内定价、微信订单或补单接口，公共购买介绍页也不会展示人民币价格或 QQ 购买引导。真正价格始终来自 Play。

### 3. 服务端 Google Play 验证

已新增：

- `POST /v1/google-play/verify`
- Google Android Publisher API 原生 Node 客户端
- 服务账号 OAuth
- 包名、商品、购买状态和订阅到期时间校验
- `google_play_purchases` 独立幂等台账
- 服务端 acknowledge
- RTDN 入口：`POST /google-play/rtdn`
- Google OIDC JWT 验签
- Voided Purchases 对账：`POST /admin/google-play/reconcile-voided`
- 退款/撤销只处理明确关联的 Google 授权码，不碰国内 `orders`

原始 `purchaseToken` 不写入 SQLite，只保存 SHA-256。

详细服务端配置见：

- `server/GooglePlay支付服务端配置.md`

### 4. 隐私政策

已准备中英文隐私政策：

- `site/privacy.html`

网站首页已增加隐私政策链接，Play 版设置页也会打开：

- `https://www.ztransfer.top/privacy.html`

注意：本地文件还需要部署到真实网站后，这个 URL 才会生效。

### 5. 构建与签名

当前配置：

- `compileSdk = 36`
- `targetSdk = 36`
- AGP `8.6.1`
- Gradle `8.11`
- JDK 17

Release 不再在正式签名缺失时偷偷回退到 debug 签名。仓库现有 `keystore.properties` 已被 Gradle 正常读取，文件本身不提交。

构建命令：

```powershell
.\gradlew.bat :app:assembleDirectDebug
.\gradlew.bat :app:assemblePlayDebug
.\gradlew.bat :app:assembleDirectRelease
.\gradlew.bat :app:bundlePlayRelease
```

产物：

```text
app/build/outputs/apk/direct/release/app-direct-release.apk
app/build/outputs/bundle/playRelease/app-play-release.aab
```

两个 Debug、国内 Release APK、Play Release AAB、两个渠道单元测试均已成功。当前 AGP 8.6.1 编译 API 36 时会给出“工具链只测试到 API 35”的警告，但产物和测试可正常完成。下次继续时，应先把 AGP/Gradle 升级到当时正式支持 API 36 的稳定组合，再执行本节四条构建命令。

### 6. 已有测试

服务端测试：

```powershell
node --test server/tests/payment-regression.test.js server/tests/google-play-client.test.js server/tests/google-play-regression.test.js
```

结果：30 项通过，其中原国内支付回归 20 项继续通过。

Android 测试：

```powershell
.\gradlew.bat :app:testDirectDebugUnitTest :app:testPlayDebugUnitTest
```

合并 Manifest 已检查：

- 国内版包含 `REQUEST_INSTALL_PACKAGES` 和更新 `FileProvider`
- Play 版包含 `com.android.vending.BILLING`
- Play 版不包含 `REQUEST_INSTALL_PACKAGES` 和更新 `FileProvider`

## 二、还需要本人完成什么

这些事项需要真实账号、身份、银行卡或线上服务器权限，代码无法代替完成。

### A. Play Console

1. 注册或完成 Google Play 开发者身份验证。
2. 创建应用，包名必须是 `com.ztransfer.play`。
3. 开启 Play App Signing，妥善保存当前 upload key。
4. 创建商品：
   - 一次性商品 `ztransfer_pro_lifetime`
   - 自动续订订阅 `ztransfer_pro_annual`
5. 为年费订阅创建并启用年度 base plan，设置各国家/地区价格。
6. 填写商店资料、内容分级、目标受众、广告声明、App access 和 Data safety。
7. 填写开发者联系邮箱；隐私政策会引用 Play 商品页里的这个邮箱。
8. 上传 `app-play-release.aab` 到内部测试。
9. 添加 License testers，用真实 Play 安装来源测试购买、待付款、恢复、续订、取消和退款。
10. 如果新注册的个人开发者账号被 Console 要求，完成至少 12 名测试者连续 14 天的封闭测试，再申请正式发布权限。

### B. Google Cloud 与服务端

1. 在 Google Cloud 启用 Google Play Android Developer API。
2. 创建 Android Publisher 服务账号，在 Play Console 授予读取/管理订单和订阅所需的最小权限。
3. 把服务账号 JSON 安全放到服务器，例如：

   ```text
   /opt/ztransfer-license/secrets/google-play-service-account.json
   ```

4. 在服务器环境文件设置：

   ```text
   GOOGLE_PLAY_SERVICE_ACCOUNT_FILE=/opt/ztransfer-license/secrets/google-play-service-account.json
   ```

5. 在服务端 `config.json` 增加：

   ```json
   {
     "googlePlay": {
       "packageName": "com.ztransfer.play",
       "pubsubAudience": "https://你的真实服务域名/google-play/rtdn",
       "pubsubServiceAccountEmail": "Pub/Sub 推送服务账号邮箱",
       "voidedLookbackDays": 30
     }
   }
   ```

6. 部署当前 `server/` 代码并重启服务。
7. 创建 Pub/Sub topic，在 Play Console 配置 RTDN。
8. 创建带 OIDC 的 HTTPS push subscription，路径使用 `/google-play/rtdn`，audience 与配置完全相同。
9. 每天由受保护任务调用一次：

   ```http
   POST /admin/google-play/reconcile-voided
   X-Admin-Token: 现有管理令牌
   ```

10. 部署前备份 `license.db`。本次迁移只新增 Google 独立表，但仍应保留可恢复备份。

### C. 网站和合规资料

1. 把 `site/privacy.html` 部署到 `www.ztransfer.top`。
2. 浏览器确认 `https://www.ztransfer.top/privacy.html` 可公开访问、不需要登录。
3. 在 Play Console 填同一个隐私政策 URL。
4. Data safety 的填写必须与隐私政策和实际行为一致：
   - 相机照片/视频只在相机和本机间处理，不上传 ZTransfer 服务器
   - 授权服务器处理散列设备标识、应用版本和购买凭据
   - Google Play 处理付款资料
   - 服务器为限流和安全处理 IP/请求时间
   - 不出售数据、不含广告和第三方行为分析 SDK
5. 准备英文应用名、简短说明、完整说明、图标、Feature Graphic、手机截图和支持邮箱。

### D. 收款

在 Play Console 建立 merchant/payment profile，完成税务与收款资料。可填写符合 Google 要求、能够接收对应外币电汇的国内银行账户；开户名必须与付款资料主体一致。具体中转行、入账币种和手续费需提前向开户行确认。

## 三、下次继续时从哪里开始

建议严格按下面顺序继续：

1. `git switch feature/google-play-flavors`
2. `git pull`
3. 将 AGP/Gradle 升级到当时正式支持 API 36 的稳定版本。
4. 运行 Android 两渠道测试和 Release 构建。
5. 运行 30 项服务端回归。
6. 部署 `site/privacy.html`，确认 URL。
7. 先在 Play Console 创建应用和两个商品。
8. 再配置 Google Cloud 服务账号、RTDN 和服务端环境。
9. 上传 AAB 到内部测试，用 License tester 做一次真实购买。
10. 验证购买、恢复、续订、退款后，再开始封闭测试。

在第 6 步之前，Play 版显示“商品不可用”是正常现象；通过 adb 直接安装的 Play APK 也不能完整模拟 Play Billing，必须从 Play 测试轨道安装。

## 四、暂停期间不要误操作

- 不要改两个 Play 商品 ID，App 和服务端都依赖精确字符串。
- 不要把服务账号 JSON、`keystore.properties`、keystore 或任何私钥提交到 Git。
- 不要把国内版包名从 `com.ztransfer` 改掉，否则会影响现有用户升级。
- 不要给 Play Manifest 加回 `REQUEST_INSTALL_PACKAGES`。
- 不要在 Play 购买页增加微信二维码、外部付款链接或“去官网更便宜”等引导。
- 未完成真实购买/退款测试前，不要直接推正式生产。
