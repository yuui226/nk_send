# Z传 iOS 工程

`iosApp` 是 Z传的 iOS 薄壳，和 Android App 共用根目录下的 `shared` Kotlin Multiplatform 模块。

Windows 侧的 Android 共享化阶段已经完成：`shared` 已由 Android 工程实际依赖，并承载平台中立的相机协议、文件目录、传输队列、遥控/GPS、EXIF、相框、滤镜、会员规则及最小 presentation state。Android 仍使用原来的 Activity、Compose 页面、Service 与系统适配，运行入口和平台流程没有改变。

## Mac 首次准备

1. 安装与 Kotlin 2.2.21 兼容的 Xcode，并至少启动一次完成组件安装。
2. 安装 Android Studio、Android SDK 35 和 JDK 17。因为这是同一个 Gradle 工程，Xcode 构建共享模块时也需要能够配置 Android 模块。
3. 在仓库根目录创建不提交的 `local.properties`，配置 Mac 上的 Android SDK 路径，例如：

   ```properties
   sdk.dir=/Users/你的用户名/Library/Android/sdk
   ```

4. 用 Xcode 打开 `iosApp/ZTransfer.xcodeproj`。
5. 在 ZTransfer target 的 Signing & Capabilities 中选择自己的 Apple Developer Team。
6. 选择 iPhone 模拟器或真机运行。

## 开始编写 iOS 代码

当前结构已经可以直接开始填充 iOS 实现。Mac 上先完成共享 framework/Xcode 链路验收，再按以下边界落位：

- 跨平台模型、协议和业务规则：`shared/src/commonMain/kotlin`。
- 需要由 Kotlin 调用且适合窄接口封装的 Apple 实现：按真实需求放入 `shared/src/iosMain/kotlin`。
- 只有确实需要 `expect/actual` 的小型 Android 适配才放入 `shared/src/androidMain/kotlin`；现有 Android 系统实现继续留在 `app`。
- Swift App 生命周期、系统授权跳转和暂时无法共享的原生界面：`iosApp/ZTransfer`。

第一步是 `M01`：确认 Xcode 能构建并导入 `ZTransferShared`、模拟器能启动。随后进行本地网络授权和 Wi-Fi PTP/IP 真机探针；平台 transport 只负责 Network.framework I/O，复用 `shared` 中已经完成的协议 codec 和连接决策。Compose Multiplatform UI 仍按页面逐步启用，单独验证 Android 依赖与页面行为。

仓库包含共享的 `ZTransfer` Scheme。Mac 首次拉取后可先执行无签名的模拟器构建验收：

```sh
xcodebuild \
  -project iosApp/ZTransfer.xcodeproj \
  -scheme ZTransfer \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

然后在 Xcode 中选择开发者 Team，连接真实 iPhone，开始验证相机 Wi-Fi 和系统权限。只有真机探针通过后，才继续批量迁移协议和 UI。

Xcode 的第一个 Build Phase 会调用：

```sh
/bin/sh ./gradlew :shared:embedAndSignAppleFrameworkForXcode
```

它会先构建 `ZTransferShared.framework`，再编译 Swift 薄壳。工程已关闭 User Script Sandboxing，并把脚本放在 Compile Sources 之前，与 Kotlin 官方的 Direct Integration 方案一致。

## 目录职责

- `shared/src/commonMain`：只能放 Android 和 iOS 都能编译的代码。
- `shared/src/commonTest`：共享逻辑测试。
- `shared/src/androidMain`：有真实 `expect/actual` 需求时才建立的 Android 小型适配。
- `shared/src/iosMain`：有共享 Kotlin 调用方时才建立的 Apple 小型适配。
- `app`：现有 Android 应用入口和 Android 专属能力。
- `iosApp`：iOS 应用入口、签名、权限和 Apple 专属配置。

## 迁移约束

1. 不批量移动现有 Android 源码。
2. 每次只迁移一个已经有测试覆盖的纯 Kotlin 单元。
3. 先让 Android 使用迁移后的共享实现，再实现或验证 iOS。
4. Android 专属 API 不得进入 `commonMain`。
5. 每次结构迁移后都必须运行 Android 单元测试和 Debug 构建。
6. iOS 真机能力只能在 Mac 和真实 iPhone 上验收，Windows 构建不作为 iOS 通过依据。

## 版本

- 产品版本：1.81
- Android `versionCode`：54
- iOS `build number`：54

两个平台保持相同的用户可见版本号，各自维护商店要求的内部构建号。
