# Z传 iOS 版本 1:1 复刻方案

实施进度与下一项任务见 [iOS迁移任务清单](./iOS迁移任务清单.md)。

## 一、目标与结论

目标是在尽量保持 Z传 Android 版功能、视觉和业务规则一致的前提下，实现 iOS 版本，并避免今后维护两套完全独立的代码。

推荐技术路线：

> **Kotlin Multiplatform（KMP）+ Compose Multiplatform，共享业务逻辑和绝大部分 UI；Android 与 iOS 只分别实现系统能力。**

不建议另建一套完整的 SwiftUI 工程。当前 Android 项目约有 5.95 万行 Kotlin，其中约 2.85 万行是 Compose UI。若用 SwiftUI 重新实现，首版需要重写大量界面，后续每次修改功能也容易变成两边分别维护。

Compose Multiplatform 的 iOS 支持已经稳定，官方也提供了将现有 Jetpack Compose 应用逐步迁移到 KMP 的方案：

- [Migrating a Jetpack Compose app to Kotlin Multiplatform](https://kotlinlang.org/docs/multiplatform/migrate-from-android.html)
- [Compose Multiplatform for iOS Is Stable and Production-Ready](https://blog.jetbrains.com/kotlin/2025/05/compose-multiplatform-1-8-0-released-compose-multiplatform-for-ios-is-stable-and-production-ready/)

### 当前实施状态

`research/ios` 分支已经完成第一阶段的最小结构改造：

- 保留原有 `app` Android 应用模块及全部页面、Service、资源和业务流程。
- 新增单一 `shared` KMP 模块，不继续拆出更多子模块。
- Android 已实际依赖 `shared`，首个共享模型 `CameraConnectionType` 保持原包名和 API 不变。
- 新增 `iosApp` Xcode 薄壳，通过官方 Direct Integration 方式构建 `ZTransferShared.framework`。
- Xcode 工程包含可版本控制的共享 Scheme；当前已具备开始编写 `iosMain` 平台探针并在 M1 模拟器、iPhone 真机运行的工程入口。
- Kotlin/Compose Compiler 统一为 2.2.21；AGP 8.10.1、Gradle 8.11.1 同步满足 Android 对 Kotlin 2.2 的最低工具链要求，并支持现代 Xcode；现有 Android Compose 依赖未升级。
- 共享模块测试、Android 全部单元测试和仓库标准 Debug 打包均已通过。
- `shared` 与 App 的 Android Lint 均已通过；蓝牙状态常量已修正，11 个仅用于派生 Flow 同步首帧的 `StateFlow.value` 读取采用带说明的局部抑制，未改变运行逻辑，也没有新增全局 baseline。
- 对比改造前后的 Debug APK，合并后的 Android Manifest 除版本号外完全一致。

后续继续遵循“小步迁移”：一次只移动一个有测试保护的纯 Kotlin 单元，不批量调整 Android 目录或运行时结构。

当前尚未在 `shared` 中启用 Compose Multiplatform UI 依赖。这与官方渐进迁移顺序一致：先完成平台探针和共享业务核心，再逐页迁移 UI。提前启用会改变 Android 当前 Compose 依赖解析结果，增加与第一阶段目标无关的回归面。

## 二、最终工程结构

不要为 iOS 新建一个完全独立的仓库，而是在当前仓库内逐步形成下面的结构：

```text
nk_send/
├─ shared/
│  ├─ src/commonMain/          Android 与 iOS 共用
│  │  ├─ protocol/             PTP/PTP-IP 协议、包解析、操作码
│  │  ├─ domain/               相机、照片、传输任务等模型
│  │  ├─ features/             连接、浏览、传输、遥控、GPS 状态机
│  │  ├─ presentation/         ViewModel、UI State、业务规则
│  │  └─ ui/                   Compose 页面、主题、图标、字符串
│  │
│  ├─ src/androidMain/         Android 系统实现
│  └─ src/iosMain/             iOS 系统实现
│
├─ app/                        Android 入口、Service、Manifest
├─ iosApp/                     Xcode 工程、iOS 入口、Info.plist
└─ server/                     现有授权服务器
```

共同代码通过接口使用手机系统能力，例如：

```kotlin
interface CameraNetworkTransport
interface PhotoStorage
interface BluetoothTransport
interface LocationProvider
interface BackgroundTaskController
interface VideoRecorder
interface PurchaseService
```

各平台分别实现这些接口：

```text
CameraNetworkTransport
├─ Android：Android Network + Java Socket
└─ iOS：Network.framework + NWConnection
```

这样共同层只关心“连接相机”“下载文件”“保存照片”，不直接依赖 Android 或 iOS API。

对于大型平台功能，优先使用共同接口和依赖注入，不在业务代码中到处判断当前系统。参考：[KMP 平台 API 指南](https://kotlinlang.org/docs/multiplatform/multiplatform-connect-to-apis.html)。

## 三、哪些代码可以只改一次

| 功能区域 | 目标共享程度 | 日后修改方式 |
|---|---:|---|
| PTP 操作码、数据包解析 | 90% 以上 | 改一次 |
| 相机文件读取、双卡合并、排序筛选 | 85% 以上 | 改一次 |
| 传输队列、重试、断点续传、错误分类 | 80% 以上 | 通常改一次 |
| 遥控状态机、曝光参数、对焦逻辑 | 80% 以上 | 通常改一次 |
| GPS 数据编码与配对状态机 | 70%–85% | 协议改一次，BLE 接口分平台 |
| Compose 页面、主题、动画、交互 | 75%–90% | 通常改一次 |
| 相框布局、滤镜参数、EXIF 模型 | 60%–80% | 规则改一次，底层渲染按需要分平台 |
| Wi-Fi、蓝牙、定位、文件保存 | 20%–50% | 平台实现分别维护 |
| 后台运行、购买、更新 | 很低 | 各平台独立实现 |

以后修改功能的典型情况：

- 修改筛选、传输规则、界面布局、PTP 命令：通常只改 `commonMain`。
- 新增系统能力，例如自动连接相机 Wi-Fi：共同层定义流程，Android/iOS 各写一个适配器。
- 修复 Android ROM 兼容问题：只改 Android。
- 修复 iOS 权限或系统行为：只改 iOS。
- 无论代码改在哪里，都需要在 Android 手机和 iPhone 上分别验证。

目标是让总代码的约 65%–80% 共用，让普通产品功能的主要实现只写一次。双端会增加测试和发布成本，但不应该长期变成两套完整开发工作。

## 四、“1:1”需要接受的平台差异

iOS 不是 Android 的换皮版本。可以做到功能目标、视觉和业务规则高度一致，但以下能力必须采用 iOS 等价方案。

### 4.1 USB 相机直连

Android 版通过 `UsbManager` 和 USB Bulk Endpoint 直接访问相机：

- `app/src/main/java/com/ztransfer/protocol/UsbPtpConnection.kt`

普通 iOS App 没有与 Android USB Host 对等的任意 USB 设备访问方式。Apple 的 External Accessory 通道主要面向获得厂商授权的 MFi 配件：

- [Apple External Accessory](https://developer.apple.com/documentation/externalaccessory)

方案：

- iOS 首版只支持 Wi-Fi PTP/IP。
- iOS 界面不展示 USB 入口。
- 除非以后 Nikon 提供受支持的配件协议，否则不承诺 iOS USB PTP。

### 4.2 锁屏和长期后台传输

Android 版使用前台服务维持相机和传输会话：

- `app/src/main/AndroidManifest.xml`
- `app/src/main/java/com/ztransfer/service/TransferService.kt`
- `app/src/main/java/com/ztransfer/service/CameraSessionService.kt`

iOS 普通 App 的后台运行时间有限。系统托管的长期后台下载只支持 HTTP/HTTPS，无法接管 Z传使用的自定义 PTP TCP 会话：

- [Extending your app’s background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
- [Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)

iOS 等价方案：

- 前台持续稳定传输。
- 短暂进入后台时申请有限的延长时间。
- 即将被系统挂起时安全关闭文件并保留断点。
- 回到前台后自动重连并续传。
- 不承诺锁屏后始终能够传完超大视频。

### 4.3 Wi-Fi 和局域网

iOS 可以使用 `NWConnection` 建立 PTP TCP 连接，也可以通过 `NEHotspotConfiguration` 引导用户加入相机热点，但用户必须明确授权：

- [Apple Wi-Fi configuration](https://developer.apple.com/documentation/networkextension/wi-fi-configuration)
- [Apple Network framework](https://developer.apple.com/documentation/network)

iOS 需要实现：

- Local Network 权限说明与拒绝后的恢复入口。
- 相机 AP 热点连接引导。
- STA 模式下的 mDNS、历史 IP 和子网发现。
- 无互联网相机热点下的连接状态判断。

如果使用 UDP 广播或组播，还需要向 Apple 申请 Multicast Networking entitlement：

- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

### 4.4 照片和文件保存

Android 版使用 `MediaStore` 和 SAF 让用户选择传输目录。iOS 应改成：

- 默认保存到系统照片图库中的“Z传”相册；或者
- 保存到 App 文件目录，再通过系统文件选择器或分享功能导出；
- 用户只授权“添加照片”时，不读取无关照片；
- 需要处理 iOS 的完整、受限和仅添加照片权限。

参考：[Apple PhotoKit 隐私与权限](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app)。

### 4.5 付费与授权

当前 Android 版使用外部支付、二维码和激活码。iOS 内解锁高级功能原则上必须提供 StoreKit 内购，不能直接照搬二维码支付解锁。

Apple 允许跨平台用户访问已经购买的权益，但相同权益应在 iOS 内提供内购选项：

- [App Review Guidelines 3.1](https://developer.apple.com/app-store/review/guidelines/)

推荐结构：

```text
Android 支付 ─┐
              ├─ 现有服务器统一记录 Z传会员权益
iOS StoreKit ─┘
```

共同层只读取统一的会员状态，购买流程分别由 Android 支付实现和 iOS StoreKit 实现。

### 4.6 App 更新

- Android 保留现有 APK 下载更新流程。
- iOS 通过 App Store 或 TestFlight 更新。
- 更新公告和版本判断可以共享。
- iOS 不能下载并自行安装 IPA。

## 五、功能分层方案

### 5.1 完全或主要共享

- PTP/PTP-IP 常量、包结构和响应码。
- Nikon 操作码与属性解析。
- 相机能力探测和功能开关。
- 双存储卡文件合并与排序。
- 日期、类型、保护、连拍、传输状态筛选。
- 缩略图任务调度和缓存策略。
- 传输队列、失败重试、大文件分块和断点数据模型。
- 文件完整性、同名文件和临时文件规则。
- 遥控拍摄状态机。
- 快门、光圈、ISO、曝光补偿的格式化与档位规则。
- 对焦、录像和相机事件状态机。
- GPS 数据编码、频率和海拔策略。
- 免费版限制和会员权益判断。
- Compose 页面、主题、动画和交互。

### 5.2 Android 平台实现

- Android 网络绑定与相机热点识别。
- Java Socket 输入输出。
- USB Host PTP。
- `MediaStore`、SAF 和 Android 文件权限。
- Android Bluetooth 与定位。
- Foreground Service、通知和 WakeLock。
- `MediaCodec`、`MediaMuxer` 和音频录制。
- APK 更新。
- 当前 Android 支付流程。

### 5.3 iOS 平台实现

- `Network.framework` / `NWConnection` PTP 传输。
- `NEHotspotConfiguration` 和局域网权限。
- PhotoKit、Files 与安全作用域 URL。
- CoreBluetooth 与 CoreLocation。
- iOS 后台宽限和断点保存。
- AVFoundation / VideoToolbox 端侧监看录像。
- StoreKit 2 购买、恢复和收据校验。
- App Store 更新入口。

## 六、迁移实施顺序

### 阶段 0：冻结 Android 1.81 验收基线

- 为当前 1.81 建立明确的代码基线。
- 将现有真机测试清单扩展为 Android/iOS 功能矩阵。
- 每项标记为“完全一致”“iOS 等价实现”或“iOS 不支持”。
- 保留 PTP 数据包、相机响应、效果图和 EXIF 样本。
- 迁移过程中 Android 版继续正常构建和发布。

### 阶段 1：建立 iOS 技术探针

先不复刻完整界面，在 MacBook Air M1 和真实 iPhone 上验证最关键的硬件链路：

1. iPhone 连接相机 Wi-Fi，并完成 PTP/IP 握手。
2. 获取相机信息、照片列表和缩略图。
3. 下载一张 JPG、一个 NEF 和一个大视频。
4. 测试 AP 模式和 STA 模式。
5. 用 CoreBluetooth 发现 Nikon 相机并验证 GPS 配对/写入。
6. 测试前后台切换、断线、临时文件和恢复传输。
7. 验证实时监看帧率和连续运行稳定性。

这一步用于尽早发现 Apple 权限、相机兼容性和后台限制。

### 阶段 2：拆分共享核心，先让 Android 使用

优先拆分当前几个超大文件：

- `NikonCamera.kt`：拆成协议解析、命令状态机、网络/USB 传输层。
- `CameraViewModel.kt`：拆出连接、文件扫描和浏览用例。
- `TransferViewModel.kt`：拆出共同传输队列和恢复状态机。
- `PhotoFrameExporter.kt`：拆出相框布局规则、EXIF 模型与平台渲染器。

每拆出一部分，先让 Android 使用新的共同实现并通过现有测试。不要一次性重写整个 App。

### 阶段 3：迁移协议、业务和测试到 commonMain

建议顺序：

1. 数据模型、错误类型和格式化函数。
2. PTP 常量、数据包解析和相机能力探测。
3. 文件列表、分组、排序和筛选。
4. 传输队列、重试和断点续传。
5. 遥控、曝光、对焦和录像状态机。
6. GPS 协议与策略。
7. 会员权益规则。

现有单元测试尽量移动到 `commonTest`，让同一批测试验证 Android 和 iOS 共用逻辑。

### 阶段 4：迁移共享 UI

按照风险从低到高迁移：

1. 主题、字体、颜色、图标和字符串资源。
2. 通用按钮、弹窗、卡片和动画。
3. 设置页和授权状态页。
4. 首页与连接状态。
5. 文件列表、网格、筛选和分组。
6. 照片预览、缩放和翻页。
7. 传输队列与进度页。
8. 遥控、实时监看和横屏控制。
9. 相框、滤镜和水印编辑。

每个页面进入 `commonMain` 后，Android 和 iOS 使用同一个 Composable。iOS 只保留很薄的应用入口和必要的原生系统界面。

### 阶段 5：补齐 iOS 平台实现

建议按照下面的顺序形成可用版本：

1. Wi-Fi PTP 连接。
2. 文件浏览、缩略图和原图传输。
3. PhotoKit/Files 保存与分享。
4. 预览、筛选和传输队列。
5. 遥控与实时监看。
6. 端侧监看录像。
7. BLE GPS。
8. 相框、滤镜和水印导出。
9. StoreKit 2 与服务器权益同步。
10. TestFlight 和 App Store 发布配置。

## 七、双端验收标准

### 7.1 共同逻辑测试

- PTP 包解析使用固定二进制样本测试。
- 相机文件排序、双卡合并和筛选使用共同测试。
- 传输队列和断点续传使用共同状态机测试。
- 遥控参数和事件解析使用共同测试。
- GPS 编码使用固定字节结果测试。
- 相框布局和滤镜参数使用固定输入输出测试。

### 7.2 Android 真机测试

- 继续使用现有真机测试清单。
- 覆盖 Wi-Fi AP、STA 和 USB。
- 验证前台服务、锁屏和后台传输。
- 确保迁移过程中没有回归。

### 7.3 iPhone 真机测试

- 覆盖至少一台真实 iPhone，不以模拟器代替相机测试。
- 覆盖相机 AP、手机热点和家庭路由器 STA。
- 覆盖局域网、蓝牙、定位、照片和麦克风权限的允许与拒绝。
- 覆盖切后台、锁屏、系统挂起、来电和网络切换。
- 覆盖 JPG、NEF、MOV、大文件、同名文件和断点恢复。
- 覆盖遥控、横屏、实时监看、录像和 GPS。

## 八、以后修改一个功能时怎么做

以后每个功能都在同一个功能分支中完成：

```text
共同需求
  ↓
commonMain：业务逻辑 + UI + 单元测试
  ↓
如果涉及系统能力，再修改 androidMain / iosMain
  ↓
Windows 验证 Android
MacBook 验证 iPhone
  ↓
同一个产品版本发布到两个平台
```

版本号建议：

- 用户看到的产品版本保持一致，例如 Android/iOS 都是 `1.81`。
- Android `versionCode` 和 iOS `build number` 各自递增。
- 两个平台可以因 App Store 审核时间不同而不在同一天上线。

必须坚持以下约束：

1. 业务规则不能复制进 Android 和 iOS 两个目录。
2. 页面默认放在共同 UI，只有系统界面才做平台实现。
3. 平台层不决定会员限制、传输策略或相机协议行为。
4. 新功能先设计共同接口，再补平台实现。
5. 所有共同功能都要有 `commonTest`。
6. 每次改共同代码都要验证 Android 和 iPhone，但不代表要写两份代码。

## 九、推荐的首个 iOS 可用版本范围

第一版先建立最有价值、风险最低的闭环：

- 相机 Wi-Fi AP 连接。
- STA 模式连接与发现。
- 相机信息和双卡文件浏览。
- 缩略图、筛选、分组和照片预览。
- JPG、NEF、MOV 原文件传输。
- 大文件分块、失败重试和前台断点续传。
- 保存到照片图库或 Files。
- 与 Android 基本一致的 Compose UI。
- 免费版限制和基础会员状态。

随后再补：

- 实时监看与遥控拍摄。
- 曝光参数、对焦、相机录像。
- 手机端监看录像。
- BLE GPS。
- 相框、滤镜、文字和 Logo 水印。
- StoreKit 完整购买与恢复。

USB PTP、锁屏长期传输和 App 内自行更新不作为 iOS 对等功能承诺。

## 十、最终原则

Z传 iOS 版不应被当成“再写一个 App”，而应当成为同一个跨平台产品的第二个运行目标：

- 协议只写一份。
- 业务只写一份。
- UI 尽量只写一份。
- 系统能力分别适配。
- 两个平台分别测试和发布。

初期需要对现有 Android 代码进行一次较大的结构调整，但完成后，大多数新功能只需要修改共同代码。双端会增加平台适配和测试成本，不会让日常开发工作固定翻倍。
