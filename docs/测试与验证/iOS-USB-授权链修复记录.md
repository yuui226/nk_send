# iOS USB 授权链修复记录

## 问题

iOS USB 传输使用公开的 `ImageCaptureCore`。原实现只申请
`contentsAuthorizationStatus`，但连接建立后会通过
`requestSendPTPCommand` 发送 PTP 命令。iOS 将外部相机的内容访问和控制访问拆成两项授权，因此只获得内容授权不能证明可以打开控制会话或发送 PTP。

工程同时缺少 Apple 对 iOS 外部相机控制要求的
`NSCameraUsageDescription`。连接页也没有说明尼康相机应选择标准
`MTP/PTP`；相机菜单中的 `iPhone` 档是 NX MobileAir 专用路径，不是第三方 App 的通用 USB/PTP 模式。

行为依据：

- [Apple ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore)：iOS 外部相机控制需要 `NSCameraUsageDescription`。
- [Apple ICDeviceBrowser](https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser)：内容访问和相机控制分别提供授权状态与申请方法。
- [Apple 相机转接器说明](https://support.apple.com/118280)：Lightning iPhone 连接标准 PTP 相机需要 Lightning to USB Camera Adapter 或 Lightning to USB 3 Camera Adapter。
- [Nikon USB 数据连接说明](https://onlinemanual.nikonimglib.com/z8/en/nwm_usb_%20data_connection_357.html)：`iPhone` 仅用于 NX MobileAir；其他连接选择 `MTP/PTP`。

## 修复

- `ImageCaptureUSBTransport` 顺序申请内容授权和控制授权，避免同时弹出两项系统授权。
- 只有两项授权均为 `authorized` 时，USB 状态才进入可连接；`openSession` 和 `sendPTP` 也做相同的防御性门控。
- App 回到前台或重新显示连接工作区时重新读取授权，用户在系统设置修改权限后不必强退 App 或重新插线。
- 权限被拒后，重新插线不会错误清除授权提示；授权恢复后回到等待相机状态。
- `Info.plist`、Xcode 工程配置和 `project.yml` 同步加入外部相机用途说明。
- iOS USB 卡加入“相机 USB 设置选择 MTP/PTP”步骤；平台专用文案放在
  `IOSLocalization`，不修改可重新生成的 Android 文案映射。
- 首次目录加载前如发生物理断线，照片页改为显示安卓同义的
  “有线连接已断开 / 请重新连接相机并确保相机已开机”状态，
  不提供主动断开或软件重连按钮。
- 照片、传输队列和监看页的 USB 信号胶囊在已连接时可展开显示
  `USB`；断线时点击不执行任何连接或关闭命令。
- ImageCaptureCore 返回空错误说明时，使用本地化的未知 USB 错误文案，
  避免界面出现空白错误状态。
- 监看页开发者日志窗与 USB 无关，本次未修改。

## 平台能力审查

本轮继续逐项检查了发现、授权、会话、PTP 命令、文件传输、取消、后台、
断线恢复和远控准备。业务层仍对齐安卓的尼康操作码、状态流转和文案；
传输层按 iOS 公开能力实现，不复刻 Android `UsbManager` 的接口占用、bulk
endpoint、interrupt endpoint 或前台服务。

| 项目 | Android 基准 | iOS 公开能力与处理 |
| --- | --- | --- |
| PTP 回调 | raw USB 分别读取 data/response container | `requestSendPTPCommand` completion 的顺序是 `inData`、PTP response；原实现接反，已修正并加回归测试 |
| OpenSession 后首命令 | raw host 完成握手即可发命令 | ImageCaptureCore 在 open completion 后另发 `deviceDidBecomeReady`；现在等待 ready 后才发 `GetDeviceInfo`，不再套用 Android 5 秒握手时限 |
| 命令超时 | socket/bulk read timeout | ImageCaptureCore 会在 App 后台暂停设备通信，并通过自身 callback 返回通信超时；USB 不再使用会把暂停时间算进去的 Swift wall-clock timeout |
| 命令取消 | raw host 可取消或关闭 endpoint | iOS 没有 PTP command cancel API，而且 App 不允许主动断开相机；已发出的 pass-through 命令会等待 ImageCaptureCore 的终态 callback，UI 退出只丢弃迟到结果，不关闭会话 |
| 文件数据 | bulk endpoint 可边收边写 | pass-through completion 会把一个完整 data phase 交给 App；超过 4 MiB 及大小未知的 iOS USB 对象改走 4 MiB `GetPartialObjectEx`，未知大小读到短包为止，绝不回退为无上限的整文件内存 callback |
| 后台 | 前台服务可维持 USB host 工作 | iOS 后台会暂停 ImageCaptureCore；USB 不再申请用于继续相机传输的 UIKit background task，心跳和目录轮询仅在前台运行 |
| 错误分类 | IOException/断线统一进入重连 | Apple 的 failed-open、failed-send-PTP、invalid/not-open session、pass-through/transfer failure 错误码映射为断线，进入同一重连语义 |
| 远控准备 | Android raw host 可按自身生命周期重开 USB handle | iOS 不照搬 raw USB 的关后重开；在现有序列化 ImageCaptureCore session 上清理 Nikon 兼容事件并进入控制模式，连接全程保留 |
| USB 事件 | raw USB interrupt endpoint 可持续排空 | ImageCaptureCore 的 `didReceivePTPEvent` 只作为框架排空入口；与安卓一致，业务状态仍由唯一 Nikon `GetEvent` 轮询消费，避免两个消费者互相偷事件 |
| 断线界面 | 保留已进入的 USB 工作区，空目录显示有线断开指引 | iOS 保留同样的工作区与文案语义；等待物理重连，不新增主动断开/软件重连功能 |
| USB 状态胶囊 | 在线可展开显示 `USB`，离线无点击动作 | 照片、队列、监看三个页面已对齐，点击离线 USB 图标不会关闭、重开或重试连接 |
| 空错误说明 | 始终有可见错误文案 | iOS 框架错误未附描述时回退到本地化 `usb_unknown_error`，不向 UI 传递空字符串 |

全项目的 iOS USB 路径已确认没有 `requestCloseSession` 调用，也没有供用户或
页面生命周期触发的主动断开入口。物理拔线、系统关闭 session 和真实传输错误
只会让应用丢弃失效的本地 owner 并按当前仍存在的系统 session 尝试恢复；不会
以“取消任务”或“退出监看页”为理由主动关闭相机连接。

Apple SDK 头文件还明确说明：进入后台时浏览器会依次通知 will-suspend /
did-suspend，设备通信保持暂停直到前台恢复，而且框架不会替 App 改变或关闭
session。现实现因此保留已连接工作区；周期性 USB 循环在后台不发新命令，
已经发出的命令等待框架恢复并回调，前台后继续心跳与目录维护。

ImageCaptureCore 中已有 `ICCameraFile` thumbnail/read/download 封装，但当前生产
照片浏览、预览、下载和尼康远控全部通过同一个序列化 PTP session；这些框架
文件方法没有生产调用，不会与 pass-through 命令并发。后续若启用它们，必须
先纳入同一个 I/O owner，不能直接与当前 PTP session 并行。

## 自动检查与验证边界

- `Info.plist` 已通过 `plutil -lint`。
- `project.yml` 已通过 YAML 解析。
- 新增双授权聚合测试，以及拒绝权限后重新插线、从系统设置恢复授权的状态测试。
- 新增 PTP completion data/response 顺序、ImageCaptureCore 命令取消保持连接、
  iOS USB 分块上限、未知大小分块终止、录像启动中退出清理、
  空框架错误文案回退及 Apple 错误码分类的回归测试。
- 全量 Swift 静态 typecheck 已检查到本次 USB 改动；命令仍会停在工程既有的
  `PhotoListView` 默认参数 MainActor 隔离错误（与 USB 改动无关）。
- 按项目约定，本次未自动运行 Xcode 构建、模拟器测试、安装或打包。
- 模拟器不能证明物理 USB/PTP 链路可用。最终真机验证需要：相机选择
  `MTP/PTP`、iPhone 解锁、使用支持数据的线材；Lightning iPhone 需要
  Apple 相机转接器，部分相机还需要带供电的 Lightning to USB 3 Camera
  Adapter。首次连接依次允许内容访问和相机控制，然后确认完成
  `OpenSession` 与 `GetDeviceInfo`。
