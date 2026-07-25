# OSS 自动发布一次性设置

管理工具使用固定配置：

- Bucket：`ztransfer`
- 地域：北京 `cn-beijing`
- 上传目录：`releases/`
- 公网域名：`ztransfer.oss-cn-beijing.aliyuncs.com`

## 1. Bucket 设置

1. 在 OSS 控制台确认账号级和 `ztransfer` Bucket 级的“阻止公共访问”均已关闭。
2. Bucket ACL 建议保持“私有”，不要设成“公共读写”。
3. 管理工具只把 `releases/` 下的新版本对象单独设为“公共读”。
4. 不需要设置 CORS、静态网站、传输加速或自定义域名。

“公共读”是为了让 Android 客户端使用永久、无签名、无过期时间的 HTTPS 地址直接下载。

## 2. 创建专用 RAM 用户

不要使用阿里云主账号 AccessKey。创建一个只供 ZTransfer 发布使用的 RAM 用户，并为它创建 AccessKey。

创建自定义权限策略，将下面 JSON 原样粘贴：

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

把这条自定义策略授权给刚创建的 RAM 用户。该用户不能访问别的 Bucket，也不能删除文件。

## 3. 在管理工具录入一次凭证

1. 双击 `激活码管理.bat`。
2. 进入“App 更新管理”。
3. 选择“配置 / 测试 OSS 上传”。
4. 输入 RAM 用户的 AccessKey ID。
5. 输入 AccessKey Secret。

认证方式固定为 `AK`，凭证固定加密，不再询问。凭证由 Windows 当前账号加密后保存在
`%LOCALAPPDATA%\ZTransfer\oss-upload-credential.json`，只有同一台电脑上的同一 Windows
用户可以解密，不会写入项目。项目里的 `tools/ossutil/` 只保存阿里云官方命令行工具，
并已被 Git 忽略。

## 4. 以后发布

选择“发布新版本”，挑选本地 APK 即可。管理工具会自动：

1. 读取包名、versionName 和 versionCode；
2. 计算文件大小与 SHA-256；
3. 以 `.bin` 后缀和 `application/octet-stream` 上传；
4. 设置对象为公共读；
5. 从公网完整下载一次并核对内容；
6. 校验通过后才把版本信息发布到服务端。

官方参考：

- [ossutil 配置](https://help.aliyun.com/en/oss/developer-reference/config-create-configuration-file)
- [RAM 目录级权限](https://help.aliyun.com/en/oss/user-guide/access-control-base-on-ram-policy)
- [阻止公共访问](https://help.aliyun.com/en/oss/user-guide/block-public-access)
- [固定公网 URL](https://help.aliyun.com/en/oss/use-a-fixed-file-url-to-access-a-file)
