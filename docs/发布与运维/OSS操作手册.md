# 香港 OSS 发布操作手册

## 目标

ZTransfer 的正式 APK 统一发布到香港 OSS：

| 用途 | 地址 |
| --- | --- |
| App 自动更新 | `https://apk.ztransfer.top/releases/ZTransfer-v<versionName>-<hash>.apk` |
| 官网和新用户 | `https://apk.ztransfer.top/ZTransfer.apk` |

用户下载不需要密码，不经过蓝奏云，安装包流量不经过业务服务器。

## 日常发布

1. 提高 `build.gradle.kts` 中的 versionCode 和 versionName。
2. 按正式发布流程生成签名 APK。
3. 双击 `server/激活码管理.bat`。
4. 进入“App 更新管理”。
5. 选择“发布新版本”。
6. 选择刚生成的正式 APK。
7. 填写更新说明并选择软更新或硬更新。
8. 核对版本、大小、SHA-256、版本地址和固定地址。
9. 输入大写 `PUBLISH` 确认。

工具自动执行上传、公共读设置、完整下载校验和服务端元数据发布。成功输出中应同时出现：

```text
App 版本地址: https://apk.ztransfer.top/releases/....apk
新用户固定地址: https://apk.ztransfer.top/ZTransfer.apk
```

不需要登录服务器修改 `app-latest.json`，也不需要重启服务。

## 发布前只上传测试

需要先验证香港 OSS、又不能影响线上用户时，在“App 更新管理”选择：

```text
[3] 仅上传测试包（不发布、不覆盖固定地址）
```

该入口只上传并校验不可变的 `releases/ZTransfer-v{versionName}-{SHA前12位}.apk`，不会覆盖
`ZTransfer.apk`，也不会调用服务端 `/admin/update/publish`。App 的当前更新版本和下载地址保持
原样。工具会输出独立测试地址，可直接在手机浏览器下载安装验证。

版本化对象使用“存在即跳过写入”的 OSS 选项：同一 APK 再次操作时保留桶内原对象，再从公网
完整下载校验；不会以测试包覆盖任何已有版本对象。内容变化会产生新的 SHA 文件名，因此与旧包
并存。

为避免误操作，仅上传必须手动输入大写 `UPLOAD`；正式发布必须输入大写 `PUBLISH`。测试完成后
再选择“正式发布新版本”，工具会重新核验并完成固定地址与服务端版本切换。

## 首次配置或更换电脑

1. 根据 `server/OSS发布设置.md` 给专用 RAM 用户配置 `ztransfer-hk` 最小权限。
2. 打开管理工具的“配置 / 测试 OSS 上传”。
3. 输入 AccessKey ID 和 AccessKey Secret。
4. 确认 `releases/` 列表测试通过。

凭证加密保存在：

```text
%LOCALAPPDATA%\ZTransfer\oss-upload-credential.json
```

项目中不保存 AccessKey。轮换密钥后重新运行配置即可。

## 发布工具实际做了什么

### 版本对象

对象名：

```text
releases/ZTransfer-v{versionName}-{SHA256前12位}.apk
```

属性：

```text
Content-Type: application/vnd.android.package-archive
Cache-Control: public, max-age=31536000, immutable
ACL: public-read
```

版本对象发布后永不覆盖。App 服务端只允许该目录下无查询参数的 HTTPS `.apk` 地址。

### 固定对象

对象名：

```text
ZTransfer.apk
```

属性：

```text
Content-Type: application/vnd.android.package-archive
Cache-Control: no-cache, no-store, must-revalidate
Content-Disposition: attachment; filename="ZTransfer.apk"
ACL: public-read
```

每次发布覆盖固定对象，供官网和新用户使用。App 自动更新禁止使用该地址。

### 校验

工具分别从自定义域名完整下载版本对象和固定对象，并核对：

- 文件大小；
- SHA-256；
- 包名 `com.ztransfer`；
- 正式签名证书；
- versionCode；
- versionName。

任一地址失败都不会提交新的服务端发布信息。

## 发布后人工抽查

浏览器访问：

```text
https://apk.ztransfer.top/ZTransfer.apk
```

预期直接下载 `.apk`，不出现密码页面。手机打开后应进入 Android 安装流程。

管理工具中选择“验证当前 OSS 下载”，它会检查：

1. 服务端当前版本化地址；
2. 新用户固定地址；
3. 两个文件是否与当前发布元数据一致。

## 当前线上迁移方式

当前 1.56 仍指向北京 OSS 的历史 `.bin` 文件。本地迁移代码不会自动改写它。

部署迁移代码后：

1. 旧版本仍能继续下载现有 1.56；
2. 下一次发布更高 versionCode 时，管理工具上传香港 OSS `.apk`；
3. 服务端从该版本开始返回 `apk.ztransfer.top/releases/*.apk`；
4. 官网同时改为固定 `apk.ztransfer.top/ZTransfer.apk`。

不要用同一个 versionCode 强行覆盖线上发布记录。

## 常见错误

### AccessDenied

检查 RAM 策略是否同时覆盖：

```text
ztransfer-hk/releases/*
ztransfer-hk/ZTransfer.apk
```

并确认具有 GetObject、PutObject、GetObjectAcl、PutObjectAcl 和受前缀限制的 ListObjects。

### NoSuchKey

对象没有成功上传，或者 URL 文件名不一致。它与 HTTPS 证书无关。

### ApkDownloadForbidden

说明使用了 OSS 默认域名。对外必须使用：

```text
https://apk.ztransfer.top/...
```

### 浏览器仍下载旧固定版本

检查 `ZTransfer.apk` 的 Cache-Control 是否为 `no-cache, no-store, must-revalidate`，再核对对象
SHA-256。不要给固定对象设置 immutable。

### 版本对象正确、固定对象错误

不要发布服务端元数据。重新上传固定对象并完整校验；版本对象无需重复生成。

### 两个对象已经上传，但服务端发布失败

先排查管理员令牌、服务端网络或 `OSS_URL_REQUIRED`。版本对象可以保留。重新执行发布前确认
versionCode 尚未被服务端接受；不要手工编造 SHA-256。

### OSS_URL_REQUIRED

服务端只接受：

```text
https://apk.ztransfer.top/releases/*.apk
```

默认 OSS 域名、固定 `ZTransfer.apk`、`.bin`、HTTP、查询参数和其他目录都会被拒绝。

## 下载统计

- App 检查和安装器触发次数查看管理工具“更新统计”；
- 新用户固定链接和真实文件请求查看 OSS 访问日志；
- OSS 的 Range、重试和断点续传可能产生多个请求，不能简单等同于独立用户；
- 业务服务不代理 APK 内容，因此不承担安装包带宽。

## 回退

如果新版本有问题：

1. 不删除历史版本对象；
2. 固定 `ZTransfer.apk` 可以重新覆盖为上一份已验证 APK；
3. 服务端目前不提供降低 versionCode 的普通发布操作，避免旧 App 接收降级包；
4. 需要撤回时先停止继续传播，并根据影响决定发布更高 versionCode 的修复版；
5. 不要把固定对象地址写进 App 的 `app-latest.json`。

## 相关文档

- `server/OSS发布设置.md`：Bucket、RAM 和凭证一次性配置；
- `docs/发布与运维/App更新系统.md`：App、服务端和 OSS 的完整更新流程；
- `server/cert-renew/README.md`：`apk.ztransfer.top` HTTPS 证书自动续期；
- `docs/发布与运维/官网下载OSS跳转方案.md`：官网与新用户固定下载设计。
