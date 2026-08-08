# 香港 OSS 自动发布一次性设置

管理工具默认使用：

- Bucket：`ztransfer-hk`
- 地域：香港 `cn-hongkong`
- Endpoint：`https://oss-cn-hongkong.aliyuncs.com`
- 自定义公网域名：`https://apk.ztransfer.top`
- App 版本目录：`releases/`
- 新用户固定对象：`ZTransfer.apk`

## 1. Bucket 设置

1. 确认 `ztransfer-hk` 允许目标对象设置为公共读。
2. Bucket ACL 可以保持私有，不要设成公共读写。
3. 管理工具只把 `releases/*.apk` 和根目录 `ZTransfer.apk` 设置为公共读。
4. `apk.ztransfer.top` 必须继续绑定到该 Bucket，并保持有效 HTTPS 证书。
5. 建议开启 OSS 访问日志、流量和费用告警。

两个下载地址用途不同：

```text
https://apk.ztransfer.top/releases/ZTransfer-v1.57-<SHA前12位>.apk
    App 更新专用；发布后永不覆盖，可以长期缓存。

https://apk.ztransfer.top/ZTransfer.apk
    官网和新用户专用；每次发布覆盖，禁止缓存旧版本。
```

## 2. RAM 最小权限

继续使用专用上传用户，不要使用阿里云主账号 AccessKey。将 `<阿里云账号ID>` 替换为主账号 ID：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["oss:GetBucketInfo"],
      "Resource": "acs:oss:*:<阿里云账号ID>:ztransfer-hk"
    },
    {
      "Effect": "Allow",
      "Action": ["oss:ListObjects"],
      "Resource": "acs:oss:*:<阿里云账号ID>:ztransfer-hk",
      "Condition": {
        "StringLike": {
          "oss:Prefix": [
            "releases",
            "releases/*",
            "ZTransfer.apk"
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
        "acs:oss:*:<阿里云账号ID>:ztransfer-hk/releases/*",
        "acs:oss:*:<阿里云账号ID>:ztransfer-hk/ZTransfer.apk"
      ]
    }
  ]
}
```

该用户不需要删除对象、修改 Bucket、管理证书或访问其他 Bucket 的权限。

## 3. 在管理工具录入凭证

1. 双击 `激活码管理.bat`。
2. 进入“App 更新管理”。
3. 选择“配置 / 测试 OSS 上传”。
4. 输入专用 RAM 用户的 AccessKey ID 和 AccessKey Secret。

凭证由 Windows 当前账号加密保存在：

```text
%LOCALAPPDATA%\ZTransfer\oss-upload-credential.json
```

它不会写入项目。换电脑或轮换 AccessKey 后需要重新录入。

## 4. 发布流程

选择“发布新版本”并选择正式 APK。管理工具会自动：

正式发布入口不再要求额外输入 `PUBLISH`；完成 APK、更新说明和软硬更新策略选择后会直接执行。

1. 确认服务端支持香港 OSS 双地址发布；旧服务端会在上传前被拒绝；
2. 校验包名、正式签名，并读取 `versionCode`、`versionName`；
3. 计算大小、SHA-256 和 MD5；
4. 上传不可变的 `releases/ZTransfer-v{versionName}-{SHA前12位}.apk`；
5. 设置 APK Content-Type、公共读和一年不可变缓存；
6. 从 `apk.ztransfer.top` 读取响应头，校验公网可访问性、精确大小、MD5、SHA-256 元数据和 Content-Type；
7. 再次确认服务端当前版本没有在上传期间变化；
8. 由 OSS 在同桶内把版本对象复制为 `ZTransfer.apk`，设置为禁止缓存，不再从管理机重复上传；
9. 对固定地址执行同样的公网响应头校验；
10. 两个对象都通过后，才向服务端发布新的版本信息。

如果任一步失败，管理工具不会继续提交服务端版本信息。跨 OSS 和业务服务不存在分布式事务；如果
两个对象已经上传但最后的服务端请求失败，按工具提示排查后重新发布，不要手工猜测版本数据。

## 5. 发布后检查

```text
App 版本地址：
https://apk.ztransfer.top/releases/ZTransfer-v<versionName>-<hash>.apk

新用户固定地址：
https://apk.ztransfer.top/ZTransfer.apk
```

管理工具“验证当前 OSS 下载”仍会从公网完整下载两个地址，深度验证 APK 的版本、签名、文件大小和
SHA-256；该手动检查不属于每次发布的快速路径。

## 6. 不要做的事情

- 不要让 App 自动更新使用会被覆盖的 `ZTransfer.apk`；
- 不要恢复 `.bin` 后缀或 `application/octet-stream`；
- 不要把 AccessKey 写进项目、批处理或文档；
- 不要在版本对象上传并验证前修改服务端发布记录；
- 不要删除仍可能被旧客户端使用的历史版本对象。
