# iOS 首次 Mac 操作指南（MacBook Air M1）

> 目的：尽早验证 Apple 工具链和一条真实传图链路，提前发现需要返工的问题。不是要求现在完成全部 iOS 验收。
> 对照代码：`research/ios` 分支，第62批 `e216b1d`；编写时尚未在 Mac 编译。后续以实际同步到的提交和[剩余任务表](../技术调研/iOS剩余任务进度表.md)为准。

> 2026-09-08工作区更新：新增正式共享首页，Debug诊断通过右上角“开发诊断”进入，二者复用同一个会话所有者。自动传图、发现/历史相机及媒体兼容补充源码已接入但尚未在Mac编译/验收；首次仍先手动传一张JPG，之后再测试自动传图。下文诊断按钮操作仍可通过Debug入口使用，不代表最新首页已完成视觉1:1验收。

## 先看这段：这次做到哪里就够了

按顺序完成：**准备环境 → 同步代码 → 环境检查 → 模拟器启动 → iPhone 连接相机、下载并保存一张 JPG**。

- 前面的步骤失败，就保留错误交给我修，不必硬往后走，也不需要自己修改业务代码。
- 没带相机或 iPhone，可以先完成模拟器启动；它已经能提前发现一批编译、链接和共享界面问题，但不能替代真机传图。
- 最小流程跑通后，再执行文末的完整自动检查。第一次不测照片效果、会员、遥控监看、GPS，也不测尚未接完的自动传图。
- 最新工作区默认显示共享产品首页，仍在开发验收中；Debug构建保留“开发诊断”入口。

## 1. 准备设备和环境

准备 MacBook Air M1、能传数据的 iPhone 连接线、iPhone、尼康相机，以及卡上一张不敏感的普通 JPG。初次测试保持 App 在前台、iPhone 解锁；Mac 接电，关闭不必要的大型软件。

### 1.1 安装合适的 Xcode

本仓库固定使用 Kotlin **2.2.21**、Compose Multiplatform **1.8.2**、Gradle **8.11.1**、Android Gradle 插件 **8.10.1**，首次验证不要接受 IDE 的自动升级建议。

优先按当前 Kotlin 对应的 **Xcode 26.0** 建立验证环境。官方兼容表明确列出这组对应关系；这不是宣称本项目已经用它编译通过，也不是要求安装“最新版 Xcode”。如果 Mac 已装其它版本，先记录版本，不急着卸载或升级项目。[Kotlin 官方兼容表](https://kotlinlang.org/docs/multiplatform/multiplatform-compatibility-guide.html)

Xcode 26 的官方系统要求包含 macOS Sequoia 15.6 至 Tahoe 26.x。先在“苹果菜单 → 关于本机”检查系统；不匹配时先确认环境方案，系统升级前备份。如果 iPhone 系统与所选 Xcode 无法配合，也先报告，不要为此临时升级 Kotlin/Gradle。[Apple Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)

安装入口：[Apple Xcode 下载](https://developer.apple.com/download/all/)。可能需要登录 Apple 账号；按版本查找 Xcode，解压后放入“应用程序”。启动一次，按提示同意许可并完成必要组件下载。

在 Xcode 的 Settings 中找到 **Components / Platforms**（名称随版本变化），安装一个该 Xcode 支持的 iOS 模拟器运行环境。项目要求 iOS 16 或以上，不用特意装 iOS 16；有一个可用的 iPhone 模拟器即可。

打开 Mac 的“终端”，检查：

```sh
uname -m
xcode-select -p
xcodebuild -version
xcrun simctl list devices available
```

预期：架构为 `arm64`；开发目录指向完整 Xcode；能显示 Xcode 版本和可用 iPhone 模拟器。不要用 Rosetta 模式的终端执行本项目 Apple 验证脚本。

如果开发目录是 `/Library/Developer/CommandLineTools`，且 Xcode 确实装在下列位置，再执行：

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

如果应用实际叫 `Xcode_26.app`，就把路径改成真实名称。这里需要输入 Mac 登录密码，输入时不显示字符是正常的；不要把密码发给我。

### 1.2 安装 JDK 17

安装 **macOS / aarch64（ARM64）/ JDK 17**，不是 JRE，也不是 Windows 安装包。可以使用 [Eclipse Temurin 官方下载](https://adoptium.net/temurin/releases/?version=17) 的 macOS 安装包。

检查：

```sh
/usr/libexec/java_home -v 17
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
"$JAVA_HOME/bin/java" -version
```

应显示 Java 17。`export` 只对当前终端会话生效；仓库的自动检查脚本会自行选择 JDK 17。不要把个人 Java 路径写入共享的 Gradle 配置。若 Xcode 后面提示找不到 Java，先发这几条输出和 Xcode 错误，不要另装一串不同版本碰运气。

### 1.3 准备 Android SDK 和 Python

虽然这次做 iOS，但同一 Gradle 工程仍会配置 Android 模块，需要本机 Android SDK。

1. 安装 Apple Silicon 版 [Android Studio](https://developer.android.com/studio)。本次可只用它管理 SDK，无需启动 Android 模拟器。
2. 打开 SDK Manager（欢迎页 More Actions，或 Tools → SDK Manager）。在 SDK Platforms 中安装 **Android API 35**。
3. 在 SDK Tools 中安装 Android SDK Platform-Tools、Command-line Tools；展开包详情，准备 Android SDK Build-Tools **35.0.0**。按提示接受 SDK 许可。
4. 记下 SDK Manager 顶部的 **Android SDK Location**。常见位置是 `/Users/你的用户名/Library/Android/sdk`，以实际显示为准。[Android 官方 SDK 管理说明](https://developer.android.com/studio/intro/update#sdk-manager)
5. 在终端执行 `python3 --version`。若找不到，安装 [Python 官方 macOS 版本](https://www.python.org/downloads/macos/) 后重新打开终端；建议 Python 3.10 或以上，现有验收脚本只用标准库，无需安装额外 Python 包。

不用单独安装 Kotlin、全局 Gradle、CocoaPods，也不用新建另一个 iOS 仓库。项目已自带 Gradle Wrapper 和 Xcode 工程。

## 2. 把正确版本同步到 Mac

**先确认 Windows 的代码已提交并推送，再在 Mac 拉取。** 编写本文时最新实现 `e216b1d` 仍是本地提交；仅在 Mac 执行 pull，并不能拿到 Windows 未推送的内容。本文本身也要随提交同步，不能只同步旧代码。

开始操作前可先让我完成一次明确的“提交并推送”。不要复制 Windows 的整个构建目录，也不要复制 `local.properties`、`.gradle`、`build` 或 Android 签名文件。

Mac 首次取代码：在仓库托管页面复制你有权限访问的克隆地址，把下面的占位内容替换掉。不要把访问令牌直接写在地址里。

```sh
mkdir -p ~/code
cd ~/code
git clone --branch research/ios '替换为项目的真实克隆地址' nk_send
cd nk_send
```

如果 Mac 已有仓库，则进入原目录，先执行：

```sh
git status --short
```

有未提交修改就先保留并告诉我，不要执行清空或强制覆盖。工作区干净后再执行：

```sh
git fetch origin
git switch research/ios
git pull --ff-only
```

如果只有远端分支、切换失败，改用 `git switch --track origin/research/ios`。若提示分支分叉，停止并发错误，不用强制重置。

最后核对：

```sh
git branch --show-current
git log -1 --oneline
```

应在 `research/ios`，提交号应与 Windows 最近一次推送的提交一致。本文之后继续开发时，不要求永远停在 `e216b1d`。

## 3. 配置本机 SDK，然后只检查环境

以下所有项目命令都在 **仓库根目录 `nk_send`** 执行，不是在 `iosApp` 内。根目录应同时有 `gradlew`、`shared`、`app`、`iosApp`。

用代码编辑器在根目录新建或编辑 **纯文本** `local.properties`（不要保存成 `.txt`），写入实际 SDK 路径：

```properties
sdk.dir=/Users/你的用户名/Library/Android/sdk
```

替换“你的用户名”，路径不加引号。若已有其它本地配置，保留其它行，只更新 `sdk.dir`。这个文件已被 Git 忽略，不提交，也不复用 Windows 的 `D:\...` 路径。

运行：

```sh
python3 iosApp/scripts/verify_on_mac.py --preflight-only
```

通过时会显示 Xcode、选中的 iPhone 模拟器，以及：

```text
Preflight passed. No Swift build or XCTest has been run.
```

这一步只检查环境，不编译代码，也不自动判断 Xcode 与 Kotlin 的版本组合一定兼容。出现 `PREFLIGHT BLOCKED` 时先解决它；此时通常还没有生成验收目录，直接保留终端错误即可。

## 4. 首次编译：先让模拟器显示首页和共享组件

1. 双击 `iosApp/ZTransfer.xcodeproj`，或者在仓库根目录执行 `open iosApp/ZTransfer.xcodeproj`。
2. Xcode 顶部 Scheme 选 **ZTransfer**，运行设备选刚安装的 **iPhone 模拟器**，不是“Any iOS Device”。
3. 在 Product → Scheme → Edit Scheme 中确认 Run 使用 **Debug**。不要改成 Release。
4. 点击左上角运行三角形，或按 **Command + R**。
5. 首次会下载依赖并构建共享框架。保持联网，不同时启动验收脚本、另一个 Gradle 构建或 Android Studio 的项目同步。内存紧张时关闭 Android Studio。

Xcode 已有构建 shared 的步骤。不要手动拖入下载来的 framework，也不要另外运行 `embedAndSignAppleFrameworkForXcode` 来“补一下”；该任务需要 Xcode 提供的构建环境。

成功的判断：模拟器出现 Z传首页；点击 **“检查共享 Compose 组件”**，能打开共享组件页面并返回，没有立即崩溃。截图保留。

如果失败：按 **Command + 9** 打开构建报告，展开失败步骤，保留**第一个具体错误及上下文**。只有最后一行 `Command PhaseScriptExecution failed` 不够，它通常只是汇总。按第8节反馈，先别继续真机步骤。

这一阶段不连接模拟器里的相机，也不算网络、文件权限或真机体验已通过。

## 5. 把 Debug App 安装到自己的 iPhone

1. 用数据线把 **iPhone 接 Mac**，解锁并按提示信任电脑。这根线用于安装和调试，不是实现相机 USB 传图。
2. Xcode → Settings → Apple Accounts 登录自己的 Apple 账号。
3. 左侧选择蓝色项目图标 → TARGETS 的 **ZTransfer** → Signing & Capabilities：勾选 **Automatically manage signing**，Team 选择自己的团队。
4. 个人试装可以先使用账号可用的 Personal Team，不要求先购买上架会员；可用能力及签名限制以 Xcode 提示为准。[Apple 开发者账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account)
5. 当前 Bundle Identifier 是 `com.ztransfer.ios`。若它不能用于你的个人签名，改成你自己的唯一测试标识，例如 `com.你的英文标识.ztransfer.dev`；不要修改 Android applicationId。记录改动，暂不把个人 Team/测试标识混入通用工程提交。
6. Xcode 顶部设备改选你的 iPhone。按提示在 iPhone“设置 → 隐私与安全性 → 开发者模式”中启用并完成重启确认；入口未出现时先让 Xcode 识别设备。必要时按系统提示信任开发者。
7. 按 Command + R，确认手机出现同一个 **Debug 首页**。[Apple 真机运行说明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

只选 App target 并运行即可；若后续要在真机运行测试，测试 target 的签名也需匹配。模拟器自动验收不需要填写 Team，也不需要购买证书。

## 6. 最小真机验证：先用 AP 传一张 JPG

第一次优先 AP，即 **iPhone 连接相机自己发出的 Wi-Fi**，减少路由器、STA 配对和专用兼容模式的干扰。若你的机型/相机配置不能提供对应连接方式，记录机型和菜单状态，改做标准 STA 或交给我确认，不重置相机已有档案。

### 6.1 连接并看目录

1. 给相机准备一张普通测试 JPG。先断开 Android Z传、SnapBridge、电脑相机软件等已有相机会话，避免占用。
2. 相机开启可用于传图的 Wi-Fi/PTP-IP 连接；iPhone 在系统 Wi-Fi 设置中加入该网络。“无互联网连接”不等于无法连接相机。不同机型菜单不同，不要求照抄其它机型的菜单路径。
3. 返回 Z传首页 **“开发诊断：相机连接”**。确认相机 IP；默认值只是默认，实际地址不同就填写实际值，不把 Mac/iPhone 自己的 IP 填进去。
4. **关闭“STA 标准握手”**，保持 **“持续会话、文件抽样与原片下载”开启**。
5. 点 **“开始诊断”**。如弹出本地网络权限，允许；此前拒绝过则到系统设置中的 Z传权限或“隐私与安全性 → 本地网络”检查。超时不必然等于拒绝权限。
6. 预期：状态显示连接保持，出现真实相机文件的抽样信息。只显示前20个对象不代表整张卡只有20张。
7. 点 **“打开共享文件浏览（真实目录）”**，等待扫描；检查有真实文件、缩略图，没有持续卡死。返回诊断页后若会话已断开，就重新连接，不把临时页面切换的生命周期当成最终产品体验已验收。

### 6.2 下载、系统导出、图库保存

1. 在诊断页抽样列表中找到测试 JPG，点它旁边的 **“下载”**。首次先不测试批量、RAW、长视频或大文件。
2. 等下载完成。不要只凭出现进度条判断成功，应有已保存结果，且能操作该结果。
3. 点 **“导出到文件”**，在系统界面选择自己创建的测试目录；确认完成后，在“文件”App 中打开导出的 JPG。
4. 如需顺便验证图库，回到 Z传，对该已保存结果点 **“加入系统图库”**，允许添加照片，确认图库里可以打开这张图。首次退出 App 去“文件”或“照片”查看时，当前诊断连接可能会关闭，这是当前实现边界。
5. 记录原相机文件名、是否成功打开、图片方向是否正常、是否完整。不要求为了验证去删除相机上的原图。

**做到这里就可以先把结果发给我。** 它证明的是“该机型、该方式、该样本”的最小链路，不是全部模式/媒体/后台能力都正确。

### 6.3 STA 可作为第二轮，不和 AP 混着排错

让 iPhone 和相机加入同一可互访的局域网，确认不是隔离的访客网络。重新连接时开启 **“STA 标准握手”**，填相机实际 IP，或使用 **“查找局域网 Bonjour 相机服务”** 后选择候选；未发现 Bonjour 服务不等于相机一定不存在。

只有你明确要建立电脑连接档案时，才开启 **“允许电脑模式配对”**；需要新建档案向导才再开启对应向导选项，并先在相机进入配对流程。配对会实际修改相机档案，不要为了排错反复删除/重建。按界面提示配对成功后重新连接。“预期机身 GUID”不清楚就留空，不随意编造。

重复一张 JPG 的读取和下载。当前 **STA-direct 专用兼容路径还没接完**；出现 AccessDenied 或专用模式提示时，保留机型、连接模式和日志，不直接断言 Android 功能被破坏。

## 7. 最小流程通过后：运行现有完整自动检查

先结束 Xcode 正在进行的运行/测试，关闭相机会话，确保没有其它 Gradle 构建。Mac 保持可访问依赖仓库的互联网连接；不用让 Mac 加入相机的无互联网热点。

在根目录执行：

```sh
python3 iosApp/scripts/verify_on_mac.py
```

脚本自动选择一个可用 iPhone 模拟器，串行执行：

1. 工程结构检查。
2. `shared` 的 Apple Silicon 模拟器 Native 测试。
3. Debug Swift/XCTest。
4. **无签名的 Release 真机架构编译**。

最后一项不是签名安装包、Archive、TestFlight 或上架，不会运行 Android 的 `dist/build.bat`。当前 Release 没有 Debug 诊断入口，不能拿它代替第5—6节的 Debug 真机操作。

指定模拟器时，使用 `xcrun simctl list devices available` 中真实的 UUID：

```sh
python3 iosApp/scripts/verify_on_mac.py --simulator '替换为真实模拟器UUID'
```

结果在 `iosApp/build/verification/日期时间-随机编号/`：

- `report.json`：总状态和每个步骤的结果。
- `structure.log`、`native-tests.log`、`swift-tests.log`、`release-device-build.log`：执行到哪个步骤，就有哪个步骤的日志。
- `Tests.xcresult`：执行到 Swift 测试时产生的结果包，可用 Xcode 查看；早期失败时可能没有。
- `DerivedData`：构建缓存，通常不用发给我。

最终显示 `PASS: ...` 且报告所有步骤 PASS，才能算这轮自动检查通过。失败会立即停止，后面的步骤不是“已通过”。脚本不会自动修配置；环境检查通过也不等于 Swift 导出名称、链接或并发行为已经正确。

首次看到编译错误并不说明你操作错了。我们的 Apple 源码尚未首次编译，这一步就是把这些问题找出来再修。

## 8. 出错时怎么处理和反馈

| 现象 | 先做什么 |
|---|---|
| `PREFLIGHT BLOCKED` | 发完整提示，加上 Xcode/Java/Python 版本；此时不要求提供不存在的报告文件 |
| `No matching available iPhone simulator` | 安装 iOS 运行环境，并在 Xcode 的设备管理中创建/选择可用 iPhone 模拟器 |
| `SDK location not found` / SDK 35 缺失 | 核对本机 `local.properties`、API 35 和 SDK Manager 的实际路径 |
| Java runtime 找不到 | 发 `/usr/libexec/java_home -v 17` 输出和 Xcode 首个错误；不要把 Windows Java 路径复制过来 |
| Gradle/Native 依赖下载失败 | 发失败 URL 和错误，检查联网/代理；不要关闭 TLS 验证，不要先升级依赖或清空所有缓存 |
| `No such module ZTransferShared` / Kotlin 导出或 Swift 类型错误 | 发失败阶段完整日志，尤其是此前的 shared 构建错误；不要手动复制 framework 掩盖问题 |
| Signing / provisioning 错误 | 核对自己的 Team、测试 Bundle ID、设备信任；不发送密码、私钥、证书或恢复码 |
| 相机连接超时 | 发机型、固件、AP/STA、IP 来源、权限状态、相机连接菜单状态和错误；先排查别的软件占用 |
| 手机只显示标题，没有诊断按钮 | 核对 Run 配置是不是 Debug；当前 Release 的入口尚未完成 |
| 转圈很久/疑似无响应 | 先保留最近输出和活动监视器状态；不要并行再启动第二次构建，也不要把所有 Java 进程一键杀掉 |

遇到代码编译或测试失败，优先发 **第一处具体错误**；需要时附对应整份日志或 `Tests.xcresult`。分享前检查日志和截图，遮盖个人账号、配对身份、敏感文件路径或照片信息。通常不需要把整个 DerivedData 或相机照片库打包。

可按下面填一份结果给我：

```text
代码：分支 / git log -1 的提交号
Mac：macOS版本 / M1 / 内存
工具：Xcode版本 / Java版本 / Python版本
iPhone：机型 / iOS版本（没有则写未测）
相机：机型 / 固件 / AP或STA（没有则写未测）

环境检查：通过 / 失败
模拟器启动及共享组件：通过 / 失败 / 未测
Debug安装到iPhone：通过 / 失败 / 未测
相机连接和目录：通过 / 失败 / 未测
一张JPG下载及Files打开：通过 / 失败 / 未测
添加到图库：通过 / 失败 / 未测
完整自动检查：通过 / 失败 / 未执行

第一处错误：
对应日志/报告目录：
我在Mac上改过哪些配置：
```

最后运行 `git status --short`，保留并说明 Mac 上的改动。不要为了回到干净状态丢弃修复，也不要盲目把个人签名配置和本地文件一起提交。

本次通过后可继续回 Windows 开发；我们再依据真实结果更新任务表对应的 Apple 验收项。一次冒烟成功不代表 Mac 的12项总验收完成，也不改变暂缓功能的范围。
