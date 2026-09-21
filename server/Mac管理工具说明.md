# Mac 激活码管理

在 Finder 中双击本目录的 `激活码管理.command` 即可。它与 Windows 的 `激活码管理.bat` 共用 `admin.ps1`，主菜单、App 更新子菜单及操作流程相同。请将 `激活码管理.command`、`admin.ps1`、`mac-admin-tools.sh` 和 `mac-update-notes.js` 保留在同一目录。

- 启动时优先使用已安装的 PowerShell 7；没有则自动从微软官方 GitHub 下载到 `~/Library/Caches/ZTransfer/admin-tools/`，校验 SHA-256 后使用，无需 sudo 或 Homebrew。首次下载需要联网，以后复用缓存。
- 支持 Apple Silicon 和 Intel Mac。自动下载的 PowerShell 7.6 需要 macOS 14 或更新版本；较旧系统可先安装适用的 PowerShell 7。
- 管理员令牌仍使用环境变量 `ZT_ADMIN_TOKEN` 或同目录 `admin-token.txt`，首次输入后自动保存。
- 生成的激活码自动复制到 Mac 剪贴板。选择 APK 时弹出 Mac 文件选择窗口；窗口不可用时可以输入或拖入路径。
- 第一次使用 OSS 功能会自动下载与 Windows 一致的 ossutil 2.3.0，验证后缓存。OSS AccessKey 在“App 更新管理 → 配置 / 测试 OSS 上传”中录入，存到 Mac 系统钥匙串，服务名为 `com.ztransfer.admin.oss-upload`。Windows 的加密凭证不能直接迁移，需要重新录入一次。
- 更新说明使用 Mac 原生多行编辑窗口，支持中文输入、⌘V 粘贴、⌘A 全选和回车换行；点“继续”后回到终端选择更新策略。点“取消”或窗口出错会停止本次发布，不会继续上传。
- 发布 APK 仍需 Android SDK Build Tools 和 Java。工具会自动查找 `ANDROID_HOME` / `ANDROID_SDK_ROOT`、Android Studio 默认 SDK 目录和 Homebrew SDK 目录，并保留包名、正式签名及下载内容校验。

下载失败时检查网络后重新双击；错误会留在终端窗口中，按回车才关闭。也可以在终端使用原有命令行参数，例如：

```sh
./激活码管理.command list
./激活码管理.command pricing
```

依赖来源：[PowerShell 官方发布](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6)、[ossutil 官方历史版本](https://help.aliyun.com/zh/oss/developer-reference/ossutil-2-0-historical-iteration-version)。
