# ZTransfer OSS 操作手册

本文档记录 ZTransfer App 更新使用阿里云 OSS 的完整操作，包括首次设置、发布新版本、
验证下载、凭证维护、费用查看、安全注意事项和故障排查。

## 1. 当前固定配置

| 项目 | 当前值 |
|---|---|
| Bucket | `ztransfer` |
| 地域 | 华北 2（北京），`cn-beijing` |
| Endpoint | `https://oss-cn-beijing.aliyuncs.com` |
| 发布目录 | `releases/` |
| 公网域名 | `ztransfer.oss-cn-beijing.aliyuncs.com` |
| 对象后缀 | `.bin` |
| Content-Type | `application/octet-stream` |
| 对象 ACL | `public-read`（公共读） |

正式更新地址必须采用下面的形式：

```text
https://ztransfer.oss-cn-beijing.aliyuncs.com/releases/ZTransfer-v版本代码-SHA前12位.bin
```

例如：

```text
https://ztransfer.oss-cn-beijing.aliyuncs.com/releases/ZTransfer-v15-c70807f69cfe.bin
```

正式地址必须同时满足：

- 使用 `https`；
- 域名必须是上面的固定 OSS 域名；
- 文件必须位于 `releases/`；
- 文件名必须以 `.bin` 结尾；
- 不能带 `Expires`、`OSSAccessKeyId`、`Signature` 等查询参数；
- 不能使用 OSS 控制台生成的临时签名 URL。

服务端会直接把这个永久 URL 发给客户端，不再解析蓝奏云，也不会修改 URL。

## 2. 几个常用名词

### Bucket

Bucket 是 OSS 中保存文件的容器。项目使用的 Bucket 名是 `ztransfer`。

### Object

Object 是 Bucket 里的单个文件。例如：

```text
releases/ZTransfer-v15-c70807f69cfe.bin
```

### ACL

ACL 是访问权限。项目采用：

- Bucket 保持“私有”；
- 只把 `releases/` 中发布的安装包对象设为“公共读”；
- 不要把 Bucket 或对象设成“公共读写”。

公共读表示任何人拿到 URL 都能下载，但不能上传、覆盖或删除。

### RAM

RAM 是阿里云的子账号和权限系统。项目应使用一个专门负责发布更新的 RAM 用户，
不要在管理工具中使用阿里云主账号 AccessKey。

## 3. 阿里云控制台首次设置

这些步骤只需做一次。

### 3.1 检查 Bucket

进入阿里云 OSS 控制台，打开 Bucket `ztransfer`，确认：

1. 地域为“华北 2（北京）”；
2. Bucket ACL 保持“私有”；
3. 账号级和 Bucket 级的“阻止公共访问”均已关闭；
4. 不需要配置 CORS；
5. 不需要配置静态网站；
6. 不需要开启传输加速；
7. 不需要配置自定义域名。

关闭“阻止公共访问”不等于把整个 Bucket 公开。管理工具只会把正式发布对象单独设成
公共读。

### 3.2 创建专用 RAM 用户

创建一个只供 ZTransfer 发布使用的 RAM 用户，并为它创建 AccessKey。

创建自定义权限策略，内容如下：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "oss:ListObjects"
      ],
      "Resource": [
        "acs:oss:*:*:ztransfer"
      ],
      "Condition": {
        "StringLike": {
          "oss:Prefix": [
            "releases",
            "releases/*"
          ]
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "oss:GetObject",
        "oss:PutObject",
        "oss:GetObjectAcl",
        "oss:PutObjectAcl"
      ],
      "Resource": [
        "acs:oss:*:*:ztransfer/releases/*"
      ]
    }
  ]
}
```

把该策略授权给专用 RAM 用户。这份策略只允许：

- 查看 `releases/`；
- 上传和读取 `releases/` 中的对象；
- 设置这些对象的 ACL；
- 不能访问其他 Bucket；
- 不能删除对象。

### 3.3 保存 AccessKey

AccessKey Secret 通常只在创建时显示一次。应保存在自己的密码管理器中，不要：

- 写进代码或 Markdown；
- 发到聊天群；
- 截图外传；
- 提交到 Git；
- 使用主账号 AccessKey。

## 4. 项目内首次配置

### 4.1 打开管理工具

在项目目录双击：

```text
server\激活码管理.bat
```

也可以在项目根目录的 PowerShell 中运行：

```powershell
.\server\激活码管理.bat
```

进入主菜单后选择“App 更新管理”，然后选择：

```text
[2] 配置 / 测试 OSS 上传
```

依次输入同一条 RAM AccessKey 的：

1. AccessKey ID；
2. AccessKey Secret。

输入完成后，工具会测试 `releases/` 目录访问权限。看到下面内容表示成功：

```text
Object Number is: 0
OSS 配置有效。
```

`Object Number is: 0` 只表示目录中当前没有列出对象，不是错误。

### 4.2 凭证保存位置

凭证保存在：

```text
%LOCALAPPDATA%\ZTransfer\oss-upload-credential.json
```

AccessKey Secret 由 Windows 当前账号加密：

- 不会写入项目；
- 不会提交到 Git；
- 只有同一台电脑上的同一 Windows 用户可以解密；
- 换电脑或换 Windows 账号后需要重新配置。

项目使用的 `ossutil` 默认位于：

```text
tools\ossutil\2.3.0\ossutil-2.3.0-windows-amd64\ossutil.exe
```

项目固定使用的 Windows `ossutil.exe` 已加入 Git，克隆完整项目后可以直接使用。下载时
留下的 `ossutil.zip` 仍被忽略，不会重复占用仓库空间。若 EXE 遗失，也可以重新放回上面的
固定路径，或者把 `ossutil.exe` 安装到系统 `PATH`。

仓库内 OSSUtil 2.3.0 Windows AMD64 文件的 SHA-256 是：

```text
7BD88C9A26BA36712AD734D70844C248FBB572DCD2E66B7B0CF89472E9623E2B
```

新设备克隆后仍需在管理工具菜单 `[2]` 中输入自己的 AccessKey。Git 只保存发布程序，
不会保存或同步 OSS 凭证。

## 5. 日常发布新版本

### 5.1 准备 APK

发布前确认：

- 包名是 `com.ztransfer`；
- `versionCode` 高于线上版本；
- `versionName` 已正确增加；
- 使用正式签名，不是 debug 签名；
- APK 可以正常安装。

项目打包工具：

```powershell
.\dist\build.bat
```

生成文件的命名规则是：

```text
ZTransfer-{versionName}-{yyMMddHHmm}.apk
```

例如：

```text
ZTransfer-1.46-2607251320.apk
```

也可以使用其他方式生成正式 APK，管理工具不要求文件名固定。

### 5.2 发布操作

1. 打开 `server\激活码管理.bat`；
2. 进入“App 更新管理”；
3. 选择 `[3] 发布新版本`；
4. 在文件选择窗口中选择 APK；
5. 输入更新说明，可以留空；
6. 选择更新策略；
7. 检查版本、文件大小、OSS 地址和 SHA-256；
8. 输入 `y` 确认上传并发布。

更新策略：

```text
[1] 软更新：用户可以稍后或忽略
[2] 硬更新：所有旧版本必须安装才能继续
```

除非确实需要强制所有用户立即更新，否则使用软更新。

### 5.3 工具自动完成的工作

确认后管理工具会自动：

1. 读取 APK 包名、`versionName` 和 `versionCode`；
2. 拒绝包名不是 `com.ztransfer` 的 APK；
3. 拒绝 `versionCode` 不高于当前线上版本的 APK；
4. 计算文件大小和 SHA-256；
5. 生成 `releases/ZTransfer-v{versionCode}-{SHA前12位}.bin`；
6. 以 `.bin` 后缀上传；
7. 设置 `Content-Type: application/octet-stream`；
8. 设置对象 ACL 为 `public-read`；
9. 设置一年不可变缓存；
10. 把完整 SHA-256 写入对象元数据；
11. 从公网 URL 完整下载一次；
12. 校验下载文件的大小、SHA-256、包名和版本；
13. 所有校验通过后，才把新版本信息发布到服务端。

只有看到下面提示才算发布完成：

```text
公网下载校验通过。
发布成功，App 将直接从 OSS 下载；无需重启服务。
```

发布后不需要：

- 重启服务端；
- 修改客户端；
- 手动复制 OSS URL；
- 手动编辑 `app-latest.json`；
- 手动设置对象 ACL。

## 6. App 更新管理菜单

```text
[1] 查看当前发布
[2] 配置 / 测试 OSS 上传
[3] 发布新版本
[4] 验证当前 OSS 下载
[5] 修改软/硬更新策略
[6] 查看更新统计
[0] 返回
```

### `[1] 查看当前发布`

查看当前线上版本、`versionCode`、更新策略、下载地址、文件大小、SHA-256 和发布时间。

### `[2] 配置 / 测试 OSS 上传`

用于：

- 首次保存 AccessKey；
- 更换 AccessKey；
- 检查 RAM 权限；
- 检查 Bucket、地域和 Endpoint 是否匹配。

再次执行会覆盖本机原来保存的 OSS 凭证。

### `[3] 发布新版本`

选择本地 APK，自动上传、验证并发布。日常发布只需使用这一项。

### `[4] 验证当前 OSS 下载`

从服务端读取当前发布信息，再从公网完整下载一次当前对象，并校验：

- 大小；
- SHA-256；
- 包名；
- `versionCode`；
- `versionName`。

建议每次发布后再执行一次，也可以在用户反馈下载异常时执行。

### `[5] 修改软/硬更新策略`

只修改当前发布的强制程度，不重新上传 APK：

- 软更新：`minSupportedVersionCode = 1`；
- 硬更新：`minSupportedVersionCode = 当前 versionCode`。

修改后立即生效，无需重启服务。

### `[6] 查看更新统计`

查看各用户版本的检查次数、目标版本、安装触发次数、最近检查和最近安装时间。

## 7. 手动查看和验证 OSS 对象

### 7.1 在控制台查看

进入：

```text
OSS 控制台 → Bucket ztransfer → 文件管理 → releases/
```

正式对象应具备：

- 文件名以 `.bin` 结尾；
- ACL 为“公共读”；
- URL 不带签名参数；
- Content-Type 为 `application/octet-stream`；
- 元数据中有 `sha256`；
- Cache-Control 为 `public, max-age=31536000, immutable`。

### 7.2 手动测试永久 URL

浏览器直接打开永久 URL 应开始下载，不应要求登录，也不应出现 XML 错误。

PowerShell 中可以执行：

```powershell
curl.exe -fL -o "$env:TEMP\ztransfer-test.bin" -- "https://ztransfer.oss-cn-beijing.aliyuncs.com/releases/实际文件名.bin"
```

计算下载文件的 SHA-256：

```powershell
Get-FileHash -Algorithm SHA256 "$env:TEMP\ztransfer-test.bin"
```

测试后删除临时文件：

```powershell
Remove-Item -LiteralPath "$env:TEMP\ztransfer-test.bin"
```

日常应优先使用管理工具菜单 `[4]`，因为它还会验证 APK 包名和版本。

## 8. 更换、重置和撤销 AccessKey

### 8.1 更换 AccessKey

推荐顺序：

1. 在 RAM 中创建新的 AccessKey；
2. 管理工具选择 `[2] 配置 / 测试 OSS 上传`；
3. 输入新 AccessKey；
4. 确认显示“OSS 配置有效”；
5. 回到 RAM 控制台禁用或删除旧 AccessKey。

不要先删除旧 AccessKey，以免新凭证有误时无法发布。

### 8.2 删除本机保存的凭证

关闭管理工具后执行：

```powershell
Remove-Item -LiteralPath "$env:LOCALAPPDATA\ZTransfer\oss-upload-credential.json"
```

下次发布时工具会提示重新配置。

### 8.3 换电脑或换 Windows 账号

Windows 加密凭证不能直接复制使用。新环境中应重新运行菜单 `[2]`，输入 AccessKey。

## 9. 删除旧安装包

当前 RAM 发布策略故意没有删除权限。需要清理旧对象时，在阿里云 OSS 控制台手动删除。

删除前必须确认：

1. 该对象不是“查看当前发布”显示的 URL；
2. 当前线上版本已经发布并通过菜单 `[4]` 验证；
3. 没有仍在使用旧发布链接的客户端；
4. 对象不再需要用于问题回溯。

不要删除当前发布对象。客户端每次安装都需要从该 URL 下载，删除后所有用户都会更新失败。

安装包通常只有数 MiB，存储费用很低。没有明确清理需求时，保留旧对象更安全。

## 10. 发布失败时的安全状态

管理工具采用“先上传并完整验证，最后发布版本信息”的顺序。

因此：

- 上传失败：线上版本不变；
- 公网下载失败：线上版本不变；
- SHA-256 或版本校验失败：线上版本不变；
- 服务端发布失败：线上版本不变，但 OSS 中可能留下一个未引用对象；
- 只有全部成功后，客户端才会看到新版本。

如果出现：

```text
APK 已上传但版本信息未发布
```

可以先保留该对象，解决服务端或管理员令牌问题后重新发布；也可以确认它没有被线上引用后，
在 OSS 控制台删除。

## 11. 费用、余额和告警

### 11.1 主要费用来源

OSS 更新主要产生：

1. 标准型存储容量；
2. 外网流出流量；
3. GET 请求；
4. PUT 请求。

对小型 APK 来说，主要费用通常是“外网流出流量”。

以账单中曾显示的 `0.25 元/GB` 为例，一个 `1.92 MiB` 的安装包被 1000 名用户各下载一次：

```text
1.92 MiB × 1000 ≈ 1.875 GiB
1.875 × 0.25 元 ≈ 0.47 元
```

实际价格以阿里云当时账单为准。重复下载、下载失败后的重试和异常流量都会增加费用。

### 11.2 查看费用

在阿里云控制台搜索并进入：

```text
费用与成本 → 账单管理 → 账单详情
```

筛选：

- 产品：对象存储 OSS；
- 地域：华北 2（北京）；
- 计费项：外网流出流量、标准型存储容量、GET、PUT。

### 11.3 查看余额和充值

在“费用与成本”中查看账户余额，并使用“充值”给阿里云账户充值。

OSS 按量付费属于后付费资源，可能先产生费用再出账；余额不足并不代表可以长期欠费使用。
欠费达到阿里云限制后，资源可能受限或停止服务，客户端就会下载失败。

建议：

- 保持少量余额；
- 开启余额不足提醒；
- 开启按日费用提醒；
- 定期查看 OSS 外网流出流量；
- 发布后观察当天和第二天账单。

### 11.4 异常流量

公共读对象不能保证自动拦截所有恶意或异常下载。OSS 可能提供平台级安全保护，但不能把它
当作免费的业务流量限额。

应至少配置：

- 账户余额告警；
- 每日费用告警；
- OSS 流量监控告警；
- 下载量突增人工检查。

如果用户规模明显增大或遭遇盗刷，再考虑 CDN、防盗链、签名 URL 或更完整的流量防护。
当前客户端和服务端使用永久公共 URL，不应在没有配套改造时直接开启 Referer 白名单或
私有读，否则正常客户端会立即下载失败。

## 12. 常见错误排查

### 12.1 `SignatureDoesNotMatch`

示例：

```text
403 SignatureDoesNotMatch
```

含义：AccessKey ID 和 AccessKey Secret 不匹配，或者复制内容有误。

处理：

1. 确认 ID 和 Secret 来自同一条 AccessKey；
2. 不要混用两次创建的密钥；
3. 重新复制，避免多余空格或换行；
4. 管理工具重新选择菜单 `[2]`；
5. 仍失败时创建一条新 AccessKey 再测试。

这通常不是 Bucket 名或地域错误。

### 12.2 `AccessDenied`

示例：

```text
403 AccessDenied
```

含义：密钥签名正确，但 RAM 用户没有对应权限。

检查：

- 自定义权限策略是否已经授权给正确的 RAM 用户；
- Bucket 是否为 `ztransfer`；
- 策略 Resource 是否包含 `ztransfer/releases/*`；
- ListObjects 是否包含 Bucket 本身；
- Prefix 条件是否允许 `releases` 和 `releases/*`。

### 12.3 公网 URL 返回 `400`

检查：

1. 是否使用了带 `Expires`、`OSSAccessKeyId`、`Signature` 的临时 URL；
2. 对象是否真实存在；
3. 对象 ACL 是否为公共读；
4. 账号级或 Bucket 级“阻止公共访问”是否重新开启；
5. URL 中 Bucket、地域和对象路径是否正确；
6. 正式对象是否位于 `releases/` 并以 `.bin` 结尾。

不要把 OSS 控制台临时预览或签名 URL 发布给客户端。

### 12.4 上传成功，但“公网地址不能下载；未发布”

说明上传完成，但公共访问验证失败。线上版本没有改变。

重点检查：

- 对象 ACL；
- “阻止公共访问”；
- Bucket 地域；
- URL；
- 本机是否能正常访问 OSS 公网域名。

修复后重新发布即可。

### 12.5 `项目内未找到 ossutil.exe`

检查默认路径：

```text
tools\ossutil\2.3.0\ossutil-2.3.0-windows-amd64\ossutil.exe
```

可以重新放回项目工具目录，或者安装 `ossutil.exe` 并加入系统 `PATH`。

### 12.6 无法读取 APK 版本信息

确认：

- 文件确实是 APK，不是 AAB；
- Android SDK Build Tools 已安装；
- `aapt`、`aapt2` 或 `apkanalyzer` 可以被项目找到；
- APK 没有损坏。

### 12.7 `versionCode` 必须高于当前版本

修改 `app/build.gradle.kts` 中的 `versionCode`，重新生成正式 APK。只修改
`versionName` 不够，客户端判断更新使用的是 `versionCode`。

### 12.8 永久 URL 被服务端拒绝

服务端只接受：

```text
https://ztransfer.oss-cn-beijing.aliyuncs.com/releases/*.bin
```

以下地址会被拒绝：

- `http`；
- 其他 Bucket；
- 不在 `releases/`；
- `.apk` 后缀；
- 带查询参数；
- 带用户名、密码或 URL Fragment。

### 12.9 换电脑后凭证无法使用

这是 Windows 账号加密的预期结果。删除或忽略旧凭证，在新电脑上重新执行菜单 `[2]`。

## 13. 错误发布和回滚

当前更新系统不支持把 `versionCode` 降回旧版本，也不建议直接覆盖已经发布的对象。

如果发布了有问题的版本：

1. 立即判断是否需要改成软更新；
2. 修复 App；
3. 增加 `versionCode`；
4. 生成新的正式 APK；
5. 作为更高版本重新发布；
6. 新版本验证成功后，再考虑删除错误版本对象。

由于对象名包含 `versionCode` 和 SHA-256 前缀，不同内容不会共用同一 URL，可以避免
OSS/CDN 缓存把旧 APK 当成新 APK。

## 14. 每次发布检查清单

发布前：

- [ ] `versionCode` 已增加；
- [ ] `versionName` 正确；
- [ ] 使用正式签名；
- [ ] APK 包名是 `com.ztransfer`；
- [ ] 更新说明已准备；
- [ ] 已决定软更新或硬更新；
- [ ] 阿里云账户余额正常。

发布中：

- [ ] OSS 上传成功；
- [ ] 公网完整下载成功；
- [ ] 大小、SHA-256、包名和版本校验通过；
- [ ] 服务端提示发布成功。

发布后：

- [ ] 菜单 `[1]` 显示新版本；
- [ ] 菜单 `[4]` 验证当前 OSS 下载成功；
- [ ] 测试手机能检查到更新；
- [ ] 测试手机能完成下载并打开系统安装器；
- [ ] 查看更新统计；
- [ ] 观察 OSS 流量和费用。

## 15. 相关文件

| 文件 | 作用 |
|---|---|
| `server/激活码管理.bat` | Windows 管理工具入口 |
| `server/admin.ps1` | OSS 配置、上传、验证和发布逻辑 |
| `server/OSS发布设置.md` | 首次 RAM/Bucket 设置简版 |
| `server/license-server.js` | 服务端更新地址校验与直接下发 |
| `app/src/main/java/com/ztransfer/update/AppUpdateManager.kt` | Android 下载、校验和安装逻辑 |
| `dist/build.bat` | 正式 APK/AAB 打包和命名 |
| `docs/App更新系统.md` | App 更新系统整体设计 |
