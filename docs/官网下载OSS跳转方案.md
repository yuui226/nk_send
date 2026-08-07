# 官网与 App 使用 OSS 下载方案

## 当前结论

正式安装包可以统一上传到香港 OSS Bucket `ztransfer-hk`，并通过自定义域名直接下载：

```text
https://apk.ztransfer.top/<安装包文件名>.apk
```

该链路已经用 `ZTransfer-1.57-test.apk` 验证：

- 浏览器可以直接下载；
- OSS 返回 APK 类型；
- Android 可以调起安装流程；
- 安装包流量由香港 OSS 承担；
- 不使用 OSS 默认域名，因此不会触发默认域名的 APK 公网分发限制；
- `apk.ztransfer.top` 的 HTTPS 证书已经自动续期，不需要每 90 天手工更换。

## 推荐链路

```text
官网和新用户                       App 自动更新
      ↓                               ↓
https://apk.ztransfer.top/ZTransfer.apk   服务端返回当前 releases/*.apk
      └───────────────┬───────────────┘
                      ↓
               香港 OSS 直接返回安装包
```

官网部署在 GitHub Pages 不影响该方案。官网只保存普通链接，安装包内容不会经过 GitHub Pages、
业务服务器或激活服务。

## 发布约定

所有正式安装包统一使用 `.apk` 后缀。管理工具同时维护：

```text
releases/ZTransfer-v27-<SHA前12位>.apk  # App，不覆盖
ZTransfer.apk                           # 新用户，每次覆盖
```

服务端发布记录使用版本地址：

```text
https://apk.ztransfer.top/releases/ZTransfer-v27-<SHA前12位>.apk
```

使用 `.apk` 的原因：

- Android 浏览器和文件管理器可以明确识别安装包；
- 用户下载后可以直接进入安装流程；
- 不再依赖不同手机对 `.bin` 文件内容的猜测；
- OSS 自定义域名允许分发 APK。

官网固定使用：

```text
https://apk.ztransfer.top/ZTransfer.apk
```

## 与更新服务的关系

官网和 App 不使用同一个对象。官网固定对象会被覆盖，App 使用不可变版本对象，避免下载期间内容
变化或命中旧缓存。

OSS 只负责保存并传输文件，不会自动判断最新版。因此发布新版本时需要完成：

1. 上传并验证 `releases/` 下的版本对象；
2. 覆盖并验证固定 `ZTransfer.apk`；
3. 将服务端发布记录更新为版本对象 URL；
4. 官网链接保持不变。

不要先修改服务端地址再上传文件，否则用户会在这段时间收到 `NoSuchKey`。

## HTTPS 证书

`apk.ztransfer.top` 使用 Let’s Encrypt 证书，由轻量应用服务器上的自动续期服务维护：

```text
server/cert-renew/
```

它每 6 小时检查一次续期窗口，需要时通过 AliDNS DNS-01 验证申请新证书，再部署到 OSS。
详细原理、检查命令和恢复步骤见：

```text
server/cert-renew/README.md
```

该证书属于第三方上传证书，不消耗阿里云个人测试证书额度。

## 下载统计和防刷边界

当前 Bucket 为公共读，用户取得对象 URL 后可以直接访问 OSS。因此目前可以利用 OSS 日志、监控和
流量告警统计请求，但不能仅靠官网页面严格限制同一 IP 的下载次数。

如果以后确实出现恶意流量，可按风险逐步增加：

1. OSS 流量和费用告警；
2. OSS 访问日志分析；
3. CDN 访问控制或频率限制；
4. 将对象改为私有读，由下载接口生成短期签名 URL。

不建议一开始就设置“同一 IP 只能下载一次”。移动运营商出口 IP 可能被多人共享，浏览器也会使用
Range、重试或断点续传，过严限制容易误伤正常用户。

当前不新增下载域名或动态跳转服务。固定链接和实际文件请求通过 OSS 访问日志统计。真正的强限制
需要私有对象和短期签名地址，但暂不增加这层复杂度。

## 故障判断

### 浏览器提示证书错误

检查 `server/cert-renew/README.md` 中的 timer、service 和证书检查命令。

### 返回 NoSuchKey

URL 中的对象名与 OSS 实际文件名不一致。它与证书无关。

### 返回 AccessDenied

检查对象 ACL、Bucket 公共访问设置以及对象是否位于预期 Bucket。

### 下载后不是 APK 或不能安装

确认对象文件名为 `.apk`，内容是完整的 Android 安装包，并确认系统已允许当前浏览器安装未知应用。

## 不受影响的系统

下载域名和证书自动续期与以下系统相互独立：

- 激活码服务；
- App 与相机的连接和传输功能；
- 官网 GitHub Pages 部署；
- APK 的构建和签名流程。

修改下载方案时不要顺带调整这些服务。
