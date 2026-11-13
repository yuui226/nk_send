# QQ Debug APK 发送

将打包脚本生成的 `dist-debug/ZD-MMdd-HHmmss.apk` 发到自己绑定的 QQ 机器人私聊。需要 Node.js 20 或更新版本，以及 QQ 开放平台的 AppID、AppSecret；手机 QQ 中应允许机器人主动发送消息。

完成首次配置后，正常运行 `dist-debug/build-debug.bat` 即会在打包成功后自动发送，`--no-install` 只跳过 ADB 安装，不跳过 QQ。没有本机配置的电脑保持原流程。Mac 与 Windows 的 Debug 脚本均已接入，Release 不发送。

在仓库根目录安装固定版本的官方 SDK：

```sh
npm --prefix tools/qq-debug ci --ignore-scripts
```

首次绑定本人：

```sh
node tools/qq-debug/qq-apk.mjs setup
```

按终端提示输入 AppID、AppSecret（密钥隐藏输入），再用自己的手机 QQ 给机器人私聊发送终端显示的随机绑定码。绑定完成立即断开连接，之后只向这个收件人发送；再次 setup 不会覆盖已绑定的人。

发送本次成功生成的 APK：

```sh
node tools/qq-debug/qq-apk.mjs send dist-debug/ZD-1025-123456.apk
```

将示例文件名替换为打包脚本实际输出的文件名。只接受根目录 `dist-debug` 下的时间戳 APK，保留原名；本地大文件自动分片上传，当前 SDK 上限为 100 MB。

凭证和收件人仅存于本机 `.build-tools/qq-debug/config.json`（文件权限 600，新配置目录 700），可用 `ZTRANSFER_QQ_CONFIG` 指定其他本机配置路径。不要提交配置；这些配置与 Node 依赖不进入 APK，也不需要常驻服务。发送阶段只使用 HTTP，不启动 WebSocket。

配置文件不存在时返回 0 并跳过，也不要求安装 SDK。配置无效或发送失败返回非 0；打包流程保留已生成的 APK，仅提示发送失败。发送整体上限 120 秒，最终消息不自动重发；超时或结果不明时先检查手机，避免重复发送。成功提示仅代表 QQ API 已接受消息，实际下载和安装需在手机确认。

实测手机 QQ 的文件卡片可能将 APK 显示为 `.apk.1`；本脚本上传的是原始 `.apk` 文件名，公开接口没有提供关闭改名的参数。需要时在手机文件管理中恢复 `.apk` 后缀再安装。
