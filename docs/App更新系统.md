# App 更新系统

本文档描述当前 App、服务端、Windows 管理工具和香港 OSS 的完整更新逻辑。

## 1. 两类下载地址

系统故意保留两种地址，不要混用：

```text
App 自动更新：
https://apk.ztransfer.top/releases/ZTransfer-v<versionCode>-<SHA前12位>.apk

官网和新用户：
https://apk.ztransfer.top/ZTransfer.apk
```

- 版本地址发布后永不覆盖，App 可以稳定下载和重试。
- 固定地址每次发布覆盖，用户永远使用同一个链接取得最新版。
- 两者都由香港 OSS 直接传输，不经过业务服务器带宽。
- 当前版本以前的蓝奏云记录仅保留服务端兼容，不再用于发布新版本。

## 2. 组成

### App

- 自动或手动检查更新；
- 判断软更新和硬更新；
- 用户确认后向服务端请求当前版本下载地址；
- 直接从香港 OSS 下载 APK 并显示进度；
- 预检 versionCode 后打开 Android 系统安装器；
- 上报系统安装器成功拉起次数。

### 服务端

- 在 `app-latest.json` 保存一个当前发布版本；
- 返回版本、策略、说明、大小、SHA-256 和版本化 OSS 地址；
- 只允许 `https://apk.ztransfer.top/releases/*.apk` 作为新发布地址；
- 拒绝请求已经被替换的旧目标版本；
- 保存检查和安装器触发的聚合统计；
- 兼容解析历史蓝奏云发布记录。

### Windows 管理工具

- 读取 APK 的包名、versionCode 和 versionName；
- 计算文件大小和 SHA-256；
- 上传并验证版本化 APK；
- 覆盖并验证新用户固定 APK；
- 验证全部通过后向服务端发布元数据；
- 修改软硬更新策略并查看统计。

### 香港 OSS

- Bucket：`ztransfer-hk`；
- 自定义域名：`apk.ztransfer.top`；
- 传输 APK 文件并承担下载流量；
- 访问日志可用于分析固定链接和实际对象请求。

## 3. 发布信息

服务端实际发布信息保存在配置目录下的 `app-latest.json`：

```json
{
  "versionCode": 27,
  "versionName": "1.57",
  "minSupportedVersionCode": 1,
  "url": "https://apk.ztransfer.top/releases/ZTransfer-v27-a1b2c3d4e5f6.apk",
  "password": "",
  "notes": "更新说明",
  "sha256": "APK 的 64 位十六进制 SHA-256",
  "sizeBytes": 2018435,
  "publishedAt": "2026-08-06T00:00:00.000Z"
}
```

| 字段 | 作用 |
| --- | --- |
| `versionCode` | App 判断版本新旧的唯一依据 |
| `versionName` | 展示用版本名 |
| `minSupportedVersionCode` | 软硬更新策略 |
| `url` | 当前版本不可变的 OSS APK 地址 |
| `password` | OSS 发布固定为空，仅保留旧格式兼容 |
| `notes` | 更新说明 |
| `sha256` | 发布工具和固定地址校验依据 |
| `sizeBytes` | 进度和发布校验依据 |
| `publishedAt` | 发布时间 |

## 4. 发布流程

如果需要先验证香港 OSS，管理工具提供“仅上传测试包”：它只写入版本化 `releases/*.apk` 并从
公网完整下载校验，不覆盖 `ZTransfer.apk`，也不调用服务端发布接口，因此线上 App 继续收到原有
版本和下载地址。版本对象已存在时跳过写入并校验原对象，不会覆盖历史文件。确认测试通过后再
进入以下正式发布流程。

1. 提高 App `versionCode` 并生成正式签名 APK。
2. 双击 `server/激活码管理.bat`。
3. 进入“App 更新管理”。
4. 选择“发布新版本”并选择本地 APK。
5. 填写更新说明并选择软更新或硬更新。
6. 输入大写 `PUBLISH` 确认正式发布。

管理工具按顺序执行：

1. 预检服务端是否支持当前发布协议；
2. 校验包名必须为 `com.ztransfer`，且签名证书必须是正式签名；
3. 读取版本并确认 versionCode 高于当前发布；
4. 计算大小和 SHA-256；
5. 上传 `releases/ZTransfer-v{versionCode}-{SHA前12位}.apk`；
6. 设置公共读、APK Content-Type 和不可变缓存；
7. 从自定义域名完整下载版本对象并校验；
8. 再次确认服务端当前版本没有变化；
9. 覆盖 `ZTransfer.apk`，设置禁止缓存；
10. 完整下载固定对象并做同样校验；
11. 调用 `/admin/update/publish` 更新服务端发布记录。

只有两个 OSS 对象都通过校验才执行最后一步。上传工具配置见
`server/OSS发布设置.md`。

## 5. 软更新和硬更新

软更新：

```text
minSupportedVersionCode = 1
```

用户可以立即更新、稍后更新或忽略该版本。自动提示每天最多一次。

硬更新：

```text
minSupportedVersionCode = 当前发布 versionCode
```

所有更旧 App 必须进入更新流程，更新弹窗不能通过返回键或点击外部关闭。缓存的是硬更新时，
App 每次启动都会重新检查服务端，防止继续使用撤回或变化的发布信息。

## 6. App 检查和下载流程

检查接口：

```http
GET /v1/app/latest?currentVersionCode=26&currentVersionName=1.56
```

服务端返回当前发布元数据。App 只用整数 versionCode 判断新旧。

用户点击“立即更新”后：

1. 如果手机仍连接相机 Wi-Fi，App 提示用户先断开，不强制中断相机传输；
2. App 请求：

   ```http
   POST /v1/app/download-url
   Content-Type: application/json

   { "versionCode": 27 }
   ```

3. 服务端确认 27 仍是当前发布版本；
4. 服务端原样返回当前版本化 OSS URL；
5. App 直接连接香港 OSS 下载到私有更新目录；
6. 连接失败时重新领取一次地址并重试一次；
7. 下载完成后预检 APK versionCode；
8. 打开 Android 系统安装器；
9. 成功拉起安装器后异步上报统计。

Android 系统安装器负责 APK 格式、包名、签名兼容性、降级安装和最终用户确认。App 不绕过
Android 8 及以上的“允许安装未知应用”授权。

## 7. 版本变化保护

`POST /v1/app/download-url` 只接受当前发布的 versionCode。如果 App 弹窗缓存的是已经被替换的
版本，服务端返回 `VERSION_CHANGED`，App 重新检查并展示新版本，不继续下载旧目标。

服务端发布接口同时限制：

- 必须使用 HTTPS；
- Host 必须等于 `apk.ztransfer.top`；
- 路径必须位于 `/releases/`；
- 必须以 `.apk` 结尾；
- 不允许用户名、密码、查询参数或片段；
- versionCode 必须高于当前版本。

固定的 `/ZTransfer.apk` 不允许写入 `app-latest.json`，防止 App 更新过程中对象被覆盖。

## 8. 更新统计

SQLite `update_stats` 按“来源版本 → 目标版本”聚合保存：

```text
check_count
install_trigger_count
last_check_at
last_install_at
```

统计时机：

- 成功处理一次 `/v1/app/latest`：`check_count + 1`；
- App 成功拉起系统安装器：`install_trigger_count + 1`。

边界：

- 检查次数不是独立用户数；
- 拉起安装器不等于最终安装成功；
- App 从 OSS 下载的字节不经过业务服务器；
- 新用户固定链接访问应通过 OSS 访问日志统计；
- 客户端统计可以被伪造，不能用于计费或授权判断。

## 9. 接口

公开接口：

| 接口 | 作用 |
| --- | --- |
| `GET /v1/app/latest` | 检查当前版本并记录检查次数 |
| `POST /v1/app/download-url` | 返回当前版本不可变 OSS 地址 |
| `POST /v1/app/install-trigger` | 记录系统安装器触发次数 |

管理接口：

| 接口 | 作用 |
| --- | --- |
| `GET /admin/update` | 查看当前发布 |
| `GET /admin/update/stats` | 查看更新统计 |
| `POST /admin/update/validate` | 验证当前发布地址 |
| `POST /admin/update/publish` | 发布新版本 |
| `POST /admin/update/policy` | 修改软硬更新策略 |

所有接口均有 IP 限速；管理接口还需要管理员令牌。

## 10. 兼容与回退

- 当前线上版本仍可继续使用北京 OSS 的历史 `.bin` 地址；迁移代码部署后不会主动改写现有记录。
- 下一次正式发布才会写入香港 OSS `.apk` 地址。
- 服务端保留旧蓝奏云解析逻辑，仅用于读取历史发布记录。
- 发布失败不会覆盖 `app-latest.json`；已经上传但未发布的版本对象可以保留排查。
- 版本对象不要删除；固定对象可以在确认后重新覆盖。
- 本轮代码准备阶段禁止操作线上 OSS、服务端和官网，等待真机测试窗口再部署。
