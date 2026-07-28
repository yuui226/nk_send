# Google Play 支付服务端配置

服务端仍然零 npm 依赖。Google Play 未配置时，国内微信下单、激活、续期和更新接口保持原样；Google 接口返回 `GOOGLE_PLAY_DISABLED`。

## 1. Play Console 与服务账号

1. 在 Google Cloud 创建服务账号，并为 Play Developer API 授权。
2. 在 Play Console 的“API 访问权限”中关联该服务账号，授予读取订单、管理订单和订阅所需的最小权限。
3. 下载服务账号 JSON 到服务器专用目录，权限设为仅运行服务的用户可读。不要提交到 Git，也不要放入 SQLite。
4. 推荐通过 systemd 环境文件设置：

```text
GOOGLE_PLAY_SERVICE_ACCOUNT_FILE=/opt/ztransfer-license/secrets/google-play-service-account.json
```

也支持 `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` 直接提供完整 JSON；两者都存在时 JSON 优先。配置文件中的 `serviceAccountFile` 只应是路径，不能内嵌私钥。

## 2. config.json

加入以下非敏感配置：

```json
{
  "googlePlay": {
    "packageName": "com.ztransfer.play",
    "pubsubAudience": "https://你的域名:8443/google-play/rtdn",
    "pubsubServiceAccountEmail": "play-rtdn-push@你的项目.iam.gserviceaccount.com",
    "voidedLookbackDays": 30
  }
}
```

- `packageName` 必须和 Play 版 applicationId 完全相同。
- `pubsubAudience` 必须和 Pub/Sub 推送订阅配置的 OIDC audience 完全相同。
- `pubsubServiceAccountEmail` 是 Pub/Sub 推送使用的身份，不是调用 Android Publisher API 的服务账号。建议单独创建。
- 只配置 `packageName` 却没有服务账号凭证时，所有购买验证会 fail closed，绝不会相信 App 自报的付款结果。

服务端固定接受两个 Play Console 商品：

| Play 商品 ID | Play 类型 | 本地权益 |
|---|---|---|
| `ztransfer_pro_lifetime` | 一次性商品 | `lifetime` |
| `ztransfer_pro_annual` | 自动续订订阅 | `annual`，到期时间严格使用 Google 返回值 |

## 3. App 协议

购买和“恢复购买”共用：

```http
POST /v1/google-play/verify
Content-Type: application/json

{
  "fp": "32位小写设备指纹",
  "package_name": "com.ztransfer.play",
  "product_id": "ztransfer_pro_lifetime",
  "purchase_token": "Google Play purchaseToken",
  "app_ver": "2.0"
}
```

成功：

```json
{
  "ok": true,
  "code": "ABCDEF",
  "product": "lifetime",
  "token": "本服务原有的签名离线通行证"
}
```

年费成功响应额外包含 `expires_at`。同一个 purchaseToken 重试是幂等的；换机恢复会把同一 Google 授权迁到新设备，延续当前“一次只绑定一台设备”的规则。

常见错误：

- `BAD_REQUEST`：包名、商品、设备指纹或 token 格式不合法。
- `PURCHASE_MISMATCH`：Google 返回的商品与请求不一致。
- `PURCHASE_NOT_ACTIVE`：待支付、已过期、退款或撤销。
- `VERIFY_UNAVAILABLE`：Google API 或服务账号暂时不可用，应稍后重试。
- `FULFILL_FAILED`：本地权益落库失败，应稍后重试。

服务端验证 Google 返回的包名上下文、商品 ID、购买状态和订阅到期时间，然后先原子落权，再 acknowledge。acknowledge 暂时失败不会把已付款用户降级，下一次验证或 RTDN 会继续重试。

## 4. RTDN 与退款

在 Google Cloud：

1. 创建 Pub/Sub topic，并在 Play Console 配置 Real-time developer notifications。
2. 创建 HTTPS push subscription，地址为 `/google-play/rtdn`。
3. 为 push subscription 启用 OIDC token，选择专用推送服务账号。
4. audience 必须设为 config 中完全相同的 `pubsubAudience`。

RTDN 入口验证 Google OIDC JWT 的签名、issuer、audience、有效期及指定 email。没有配置 audience、缺少 Bearer token、验签失败都会返回 401，不允许“先信消息再处理”。

RTDN 只能及时通知状态变化，退款/拒付还需要定期拉取 Voided Purchases。可每天由受保护的管理任务调用：

```http
POST /admin/google-play/reconcile-voided
X-Admin-Token: 原有管理令牌
```

该任务默认回看 30 天（Google API 对查询窗口也有限制）。它只会吊销 `google_play_purchases` 明确关联的 Google 激活码，不查询或修改国内 `orders`，不会因 Google 退款误伤微信订单。

## 5. 部署检查

```powershell
node --test server/tests/payment-regression.test.js
node --test server/tests/google-play-regression.test.js
```

部署数据库前照常备份 `license.db`。新表为独立的 `google_play_purchases`；迁移只新增表和索引，不改国内订单字段。
