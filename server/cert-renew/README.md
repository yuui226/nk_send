# apk.ztransfer.top 证书自动续期

## 这是什么

这是 `apk.ztransfer.top` 的 HTTPS 证书自动续期服务。

用户通过浏览器或 ZTransfer 访问香港 OSS 下载 APK 时，浏览器需要验证域名证书。证书过期后，
浏览器会提示连接不安全，甚至直接阻止下载。本服务会在证书进入续期窗口后自动完成申请、验证、
部署和检查，正常情况下不需要人工续证。

它只维护 HTTPS 证书，不负责以下工作：

- 不上传、删除或重命名 APK；
- 不决定哪个 APK 是最新版；
- 不修改服务端返回的更新地址；
- 不修改 ZTransfer App、官网或激活服务。

本方案使用 Let’s Encrypt 签发的第三方证书，不消耗阿里云“个人测试证书（免费版）”额度。

## 当前配置

| 项目 | 当前值 |
| --- | --- |
| 下载域名 | `apk.ztransfer.top` |
| OSS Bucket | 香港地域 `ztransfer-hk` |
| 运行服务器 | 轻量应用服务器 `106.15.239.203` |
| 服务器目录 | `/opt/ztransfer-cert-renew` |
| RAM 用户 | `ztransfer-cert-renew` |
| 阿里云 CLI profile | `ztransfer-` |
| CA | Let’s Encrypt |
| 证书类型 | RSA 2048，单域名证书 |
| 检查周期 | 每 6 小时检查，附加最多 30 分钟随机延迟 |
| systemd timer | `ztransfer-cert-renew.timer` |
| systemd service | `ztransfer-cert-renew.service` |

首次自动签发和 OSS 部署完成于 2026-08-06。该日期只是部署记录，证书会持续自动更新。

## 工作原理

```text
systemd timer
    ↓ 每 6 小时检查
renew.sh + acme.sh
    ↓ 进入续期窗口时
AliDNS 创建 _acme-challenge.apk.ztransfer.top TXT 记录
    ↓
Let’s Encrypt 验证域名并签发证书
    ↓
删除临时 TXT 记录
    ↓
deploy-oss.sh 校验证书、私钥和域名
    ↓
ossutil 调用 OSS PutCname 更新 apk.ztransfer.top 的证书
    ↓
核对 OSS 控制面指纹、公网证书指纹和 HTTPS 访问
```

具体保护逻辑：

1. `acme.sh` 根据 CA 的续期窗口决定是否签发，不会每 6 小时申请一张证书。
2. DNS 脚本只允许操作 `_acme-challenge.apk.ztransfer.top`，不会修改其他解析记录。
3. 部署前检查证书有效期、域名以及证书和私钥是否匹配。
4. OSS 更新后同时核对控制面证书指纹和公网证书指纹。
5. OSS 边缘节点可能短时间新旧证书并存；只要两张证书仍有效，下载不会中断。
6. 新证书验证成功后才保存为已部署版本；失败时保留并尝试恢复上一张证书。
7. 如果 CA 已签发成功但 OSS 部署失败，下一轮定时检查会继续部署该候选证书。
8. 使用文件锁避免两个续期任务同时运行。

## 项目文件

| 文件 | 作用 |
| --- | --- |
| `renew.sh` | 总入口，判断首次签发或常规续期，并处理待部署证书重试 |
| `dns_ali_cli.sh` | acme.sh 的 AliDNS DNS-01 验证插件 |
| `deploy-oss.sh` | 校验证书、更新 OSS、检查线上状态并处理回退 |
| `sync-ossutil-config.js` | 从阿里云 CLI profile 生成仅供 ossutil 使用的配置 |
| `ztransfer-cert-renew.service` | systemd 一次性续期任务及安全隔离配置 |
| `ztransfer-cert-renew.timer` | 每 6 小时触发一次检查 |
| `README.md` | 本文档 |

仓库中不保存 AccessKey、证书私钥或 ossutil 认证配置。敏感数据只存在服务器上。

## 服务器上的文件

```text
/opt/ztransfer-cert-renew/
├── acme/             # acme.sh 3.1.4
├── bin/ossutil       # ossutil 2.3.0
├── acme-config/      # ACME 账号和续期状态
├── acme-certs/       # CA 签发的证书
├── candidate/        # 最新候选证书和私钥
├── deployed/         # 上一份已验证部署的证书和私钥
├── work/             # 部署时的临时文件
├── ossutil.conf      # 运行时生成的 OSS 凭证配置
└── 本目录中的脚本
```

关键权限：

- `/root/.aliyun` 和 `/opt/ztransfer-cert-renew`：`700`；
- AccessKey 配置、证书私钥和 `ossutil.conf`：`600`；
- systemd 服务没有多余 Linux capabilities，只允许访问必要的网络地址族；
- RAM 用户没有 APK 上传、读取或删除权限。

## 日常使用

正常情况下不需要操作。查看定时器是否运行：

```bash
systemctl status ztransfer-cert-renew.timer
```

正常状态应包含：

```text
Active: active (waiting)
```

查看最近一次执行结果：

```bash
systemctl status ztransfer-cert-renew.service
journalctl -u ztransfer-cert-renew.service -n 100 --no-pager
```

手动执行一次常规检查：

```bash
systemctl start ztransfer-cert-renew.service
```

如果证书尚未进入续期窗口，日志显示 `Skipping` 是正常现象，不是错误。

检查公网证书：

```bash
openssl s_client -connect apk.ztransfer.top:443 -servername apk.ztransfer.top </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -fingerprint -sha256
```

检查 APK 是否仍可下载：

```bash
curl -fsS --range 0-0 -o /dev/null \
  https://apk.ztransfer.top/ZTransfer-1.57-test.apk && echo OK
```

上面的 APK 文件名只是当前测试对象。正式包名称变化不会影响证书续期。

## 更换 RAM AccessKey

只有主动禁用、删除或轮换 RAM 用户 AccessKey 时才需要执行本节。不要把 AccessKey 写入仓库。

在服务器上重新配置现有 profile：

```bash
aliyun configure --mode AK --profile ztransfer-
```

输入 RAM 用户 `ztransfer-cert-renew` 的新 AccessKey ID 和 AccessKey Secret，然后执行：

```bash
chmod 700 /root/.aliyun
chmod 600 /root/.aliyun/config.json
systemctl start ztransfer-cert-renew.service
journalctl -u ztransfer-cert-renew.service -n 50 --no-pager
```

`sync-ossutil-config.js` 会在每次任务开始时同步 ossutil 配置，不需要手工编辑
`/opt/ztransfer-cert-renew/ossutil.conf`。

## RAM 最小权限

RAM 用户只需要管理指定 DNS 验证记录和指定 Bucket 自定义域名证书。恢复环境时可使用以下策略，
将 `<阿里云账号ID>` 替换为主账号 ID：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "alidns:AddDomainRecord",
        "alidns:DeleteDomainRecord",
        "alidns:DescribeSubDomainRecords",
        "alidns:DescribeDomainRecordInfo"
      ],
      "Resource": "acs:alidns::<阿里云账号ID>:domain/ztransfer.top"
    },
    {
      "Effect": "Allow",
      "Action": [
        "oss:PutCname",
        "oss:ListCname"
      ],
      "Resource": "acs:oss:*:<阿里云账号ID>:ztransfer-hk"
    },
    {
      "Effect": "Allow",
      "Action": [
        "yundun-cert:DescribeSSLCertificatePrivateKey",
        "yundun-cert:DescribeSSLCertificatePublicKeyDetail",
        "yundun-cert:CreateSSLCertificate"
      ],
      "Resource": "*"
    }
  ]
}
```

不要给该用户增加 OSS 对象上传、下载、覆盖或删除权限。

## 停用和恢复

临时停用自动续期：

```bash
systemctl disable --now ztransfer-cert-renew.timer
```

这不会删除当前 OSS 证书，但证书到期前必须重新启用：

```bash
systemctl enable --now ztransfer-cert-renew.timer
```

不要随意删除以下目录，否则可能丢失 ACME 账号、证书状态或回退副本：

```text
/opt/ztransfer-cert-renew/acme-config
/opt/ztransfer-cert-renew/acme-certs
/opt/ztransfer-cert-renew/candidate
/opt/ztransfer-cert-renew/deployed
```

## 常见故障

### 日志显示 AccessDenied

检查 RAM AccessKey 是否有效、策略是否仍绑定到 `ztransfer-cert-renew` 用户，以及策略中的域名、
Bucket 和账号 ID 是否正确。

### DNS 验证失败

检查 AliDNS 权限和 `_acme-challenge.apk.ztransfer.top` 是否能正常创建。任务正常结束后会自动删除
临时 TXT 记录。

### OSS 更新失败

检查 `oss:PutCname`、`oss:ListCname` 和三个 `yundun-cert` 权限，并查看：

```bash
journalctl -u ztransfer-cert-renew.service -n 200 --no-pager
```

### 更新后偶尔仍看到旧证书

OSS 边缘节点采用渐进同步，短时间命中新旧证书都可能发生。不要反复手工重新绑定证书，先等待传播。
部署脚本会核对 OSS 控制面和至少一个公网节点的新证书指纹。

### APK 返回 NoSuchKey

这表示 URL 中的 APK 对象名称不存在，与 HTTPS 证书无关。检查服务端返回的对象路径和 OSS 中的
实际文件名。

## 哪些情况仍需要人工处理

日常续期不需要人工操作，但以下基础设施变化无法由脚本猜测：

- 服务器被重装、释放或长期关机；
- RAM AccessKey 被禁用、删除或轮换；
- RAM 权限策略被删除或修改；
- 域名不再由当前 AliDNS 账号管理；
- Bucket、地域或下载域名发生变化；
- 阿里云或 Let’s Encrypt 的接口规则发生重大变化。

目前没有配置失败通知。如果发现浏览器证书警告，首先查看 systemd 状态和日志。只要服务器、域名、
RAM 用户和 Bucket 配置保持不变，证书会自动续期并部署。
