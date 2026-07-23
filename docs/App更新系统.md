# App 更新系统

本文档描述当前 App、服务端和管理工具的完整更新逻辑。

## 1. 设计原则

- 管理员发布步骤最少。
- 用户正常更新只点击一次“立即更新”，最后确认系统安装。
- 服务端只维护一个当前发布版本。
- 不提供暂停、回滚或多级兼容策略。
- 蓝奏云直链按下载请求实时解析，不缓存临时直链。
- 自动更新失败时保留蓝奏云手动下载入口。
- 更新统计只保存聚合次数，不保存用户或设备信息。

## 2. 组成

### App

- 自动或手动检查更新。
- 判断软更新和硬更新。
- 请求服务端解析蓝奏云直链。
- 直接读取蓝奏云临时直链下载 APK。
- 校验 APK 后打开系统安装器。
- 自动更新失败时复制蓝奏云链接和密码。
- 上报系统安装器触发次数。

### 服务端

- 保存当前发布信息。
- 返回最新版本信息。
- 调用第三方接口解析蓝奏云直链。
- 管理软更新和硬更新策略。
- 保存更新聚合统计。

### Windows 管理工具

- 查看当前发布。
- 验证当前蓝奏云链接。
- 发布新版本。
- 修改软更新或硬更新。
- 查看更新统计。

## 3. 发布信息

当前发布保存在服务端 `app-latest.json`：

```json
{
  "versionCode": 6,
  "versionName": "1.40",
  "minSupportedVersionCode": 1,
  "url": "https://example.lanzou.com/xxxx",
  "password": "zzzz",
  "notes": "更新说明",
  "sha256": "APK 的 SHA-256",
  "sizeBytes": 1736632,
  "publishedAt": "2026-07-23T00:00:00.000Z"
}
```

字段说明：

| 字段 | 作用 |
|---|---|
| `versionCode` | App 判断版本新旧的唯一依据 |
| `versionName` | 展示给用户 |
| `minSupportedVersionCode` | 软硬更新策略 |
| `url` | 蓝奏云分享链接，也是自动更新失败时的手动入口 |
| `password` | 蓝奏云密码，可以为空 |
| `notes` | 更新说明 |
| `sha256` | APK 完整性校验 |
| `sizeBytes` | APK 大小校验 |
| `publishedAt` | 发布时间 |

服务端只保存分享链接和密码，不保存蓝奏云临时直链。

## 4. 管理员发布流程

1. 提高 App 的 `versionCode`，生成并签名 APK。
2. 将 APK 上传到蓝奏云。
3. 复制蓝奏云提供的完整分享文本，例如：

   ```text
   https://wwbvu.lanzouu.com/iHRZb3y0zpwf
   密码:zzzz
   ```

4. 打开管理工具，进入“App 更新管理”。
5. 选择“发布新版本”。
6. 填写更新说明，选择软更新或硬更新。
7. 确认发布。

管理工具自动完成：

- 从剪贴板正则提取链接和密码。
- 调用解析接口验证分享信息。
- 下载一次真实 APK。
- 本机无法连接蓝奏云下载节点时，自动通过服务端转发本次 APK。
- 校验包名必须为 `com.ztransfer`。
- 从 APK 自动读取 `versionCode` 和 `versionName`。
- 自动计算文件大小和 SHA-256。
- 确认 `versionCode` 高于当前发布版本。
- 原子写入新的 `app-latest.json`。

管理员不需要手填链接、密码、`versionCode` 或 `versionName`。

## 5. 软更新和硬更新

系统只保留两种策略：

### 软更新

```text
minSupportedVersionCode = 1
```

用户可以：

- 立即更新。
- 稍后更新。
- 忽略当前版本。

软更新每天最多自动提示一次。用户忽略后，该版本不再自动提示；手动检查仍会显示。

### 硬更新

```text
minSupportedVersionCode = versionCode
```

所有旧版本都必须更新：

- 更新弹窗不能通过返回键或点击外部关闭。
- 不显示“稍后”或“忽略此版本”。
- 必须进入更新或手动下载流程。

修改软硬策略不需要重新发布 APK，修改后立即生效。

## 6. 检查更新

### 自动检查

- App 启动后初始化更新管理器。
- 普通情况下每 6 小时最多请求一次。
- 缓存的是硬更新时，每次启动都会重新检查，以及时取得最新版本和策略。
- 软更新每天最多弹窗一次。
- 检查失败不会影响 App 正常使用，也不会显示多余弹窗。

### 手动检查

用户在设置页点击“检查更新”：

- 连接相机 Wi-Fi：不请求服务器，只提示“需要连接互联网”。
- 有互联网：立即请求服务器，不受 6 小时间隔和忽略状态限制。
- 已是最新版本：提示“已是最新版本”。
- 检查失败：提示“检查失败，请检查网络”。
- 发现新版本：直接显示更新弹窗，不重复显示底部提示。

检查接口：

```http
GET /v1/app/latest?currentVersionCode=5&currentVersionName=1.36
```

服务端返回版本、策略、更新说明、大小、SHA-256，以及作为手动兜底的蓝奏云链接和密码。

## 7. 用户更新流程

用户点击“立即更新”后：

1. App 判断当前是否连接相机 Wi-Fi。
2. 如果仍连接，只提示“请断开相机 Wi-Fi”。
3. App 不会自动断开相机，也不会停止正在进行的传输。
4. 用户自行断开后再次点击“立即更新”。
5. App 请求当前发布版本的临时直链。
6. 服务端实时调用：

   ```text
   https://lz.qaiu.top/json/parser?url={分享链接}&pwd={密码}
   ```

7. 服务端只接受：

   ```text
   success = true
   code = 200
   data.directLink = HTTPS 地址
   ```

8. 蓝奏云 `*.lanosso.com:446` 地址自动规范为标准 HTTPS 443。
9. App 直接下载 APK，并显示真实进度；连接超时 15 秒，读取停滞超时 30 秒。
10. 下载完成后自动校验。
11. 校验通过后自动打开 Android 系统安装器。
12. 用户在系统页面确认安装。

App 不会绕过 Android 的安装授权。

## 8. APK 校验

下载完成后依次检查：

1. 文件存在。
2. 文件大小与发布信息一致。
3. SHA-256 与发布信息一致。
4. APK 可以被 Android 正常解析。
5. 包名等于当前 App 包名。
6. APK `versionCode` 等于目标版本。
7. APK 签名与当前已安装 App 的签名一致。

任何一项失败：

- 删除已下载文件。
- 不打开系统安装器。
- 进入手动更新流程。

校验通过的 APK 通过 `FileProvider` 临时授权给系统安装器读取。

Android 8 及以上首次安装更新时，系统可能要求用户允许“安装未知应用”。

## 9. 自动更新失败

任何 App 内自动更新失败时，统一执行：

1. 将蓝奏云分享信息复制到用户剪贴板：

   ```text
   https://蓝奏云分享链接
   密码:zzzz
   ```

2. 提示：

   ```text
   请手动更新，已复制到剪贴板
   ```

3. 显示“打开下载页”按钮。

如果没有密码，剪贴板只包含链接。

该流程适用于直链解析、下载、APK 校验或系统安装器拉起失败。

APK 文件始终由 App 直接从蓝奏云读取，不通过业务服务器转发。

## 10. 版本变化处理

下载直链接口只接受当前发布的 `versionCode`：

```http
POST /v1/app/download-url

{
  "versionCode": 6
}
```

如果 App 缓存的版本已经不是服务端当前版本：

- 服务端拒绝旧版本请求。
- App 重新检查一次最新发布信息。
- 如果目标版本发生变化，改为展示新的版本。
- 不继续下载已经过期的目标版本。

这也防止下载接口被当作公共蓝奏云解析器使用。

## 11. 更新统计

服务端使用 SQLite 表 `update_stats` 聚合保存：

```text
source_version_code
source_version_name
target_version_code
target_version_name
check_count
install_trigger_count
last_check_at
last_install_at
```

主键：

```text
(source_version_code, target_version_code)
```

统计时机：

- 服务端成功处理一次检查请求：`check_count + 1`。
- App 成功拉起系统安装器：异步上报 `install_trigger_count + 1`。

安装触发上报接口：

```http
POST /v1/app/install-trigger
```

统计特点：

- 使用 SQLite `UPSERT`，同一版本组合始终只有一行。
- 不保存设备码、IP 或逐条事件。
- 上报失败不会阻塞或影响安装。
- 统计的是请求和安装器触发次数，不是独立用户数。
- 安装器触发不等于用户最终安装成功。
- 手动下载后的安装无法统计。
- 客户端统计可以被伪造，不能用于计费或授权判断。

管理工具中的“查看更新统计”按“用户版本 → 目标版本”展示统计结果。

## 12. 服务端接口

### 公开接口

| 接口 | 作用 |
|---|---|
| `GET /v1/app/latest` | 检查最新版本并记录检查次数 |
| `POST /v1/app/download-url` | 为当前发布版本解析临时直链 |
| `POST /v1/app/install-trigger` | 记录系统安装器触发次数 |

### 管理接口

| 接口 | 作用 |
|---|---|
| `GET /admin/update` | 查看当前发布 |
| `GET /admin/update/stats` | 查看更新统计 |
| `POST /admin/update/validate` | 验证蓝奏云分享信息 |
| `POST /admin/update/apk` | 管理工具本机下载失败时转发一次 APK |
| `POST /admin/update/publish` | 发布新版本 |
| `POST /admin/update/policy` | 修改软硬更新策略 |

所有接口均受 IP 限速保护；检查、下载、统计和管理请求按类别分别限速。管理接口还必须通过管理员令牌认证。

## 13. 服务端状态边界

服务端只维护：

- 一个当前发布文件 `app-latest.json`。
- 一个 SQLite 聚合统计表。

服务端不维护：

- 暂停状态。
- 上一版本快照。
- 回滚状态。
- 临时直链缓存。
- 内存回退版本。

新版有问题时，应修复 APK、提高 `versionCode` 并重新发布。

## 14. 部署和验证

服务端代码更新后：

1. 备份当前 `license-server.js`。
2. 上传新脚本。
3. 执行 Node 语法检查。
4. 重启 `ztransfer-license` systemd 服务。
5. 检查 `/healthz`。
6. 检查最新版本接口。
7. 检查管理接口和统计接口。
8. 验证当前蓝奏云链接能够解析为 HTTPS 直链。
9. 检查服务日志没有启动、SQLite 或语法错误。

更新服务端脚本时，不覆盖：

- `config.json`
- `license.db`
- `app-latest.json`
- TLS 证书
- 签名私钥

当前实现的可视化流程见：

[更新流程演示](update-system-flow.html)
