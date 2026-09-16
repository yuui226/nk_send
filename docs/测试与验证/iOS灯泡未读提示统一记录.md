# iOS 灯泡未读提示统一（2026-09-16）

## 范围与进度

本轮补齐用户指出的“未读时呼吸、点击后永久静止”，包括 GPS、STA、AP、主设置、照片效果二级设置、本地照片效果，共 6 个入口。实现与静态验证任务 4/4；设备验收任务 0/1。该记录不表示监看入口引导、其他设置动画或全局触感反馈已经完成。

- [x] 阅读安卓公共灯泡组件、6 个调用点、已读状态读写和默认值测试。
- [x] 抽取统一灯泡组件及呼吸时间模型，删除分散的旧动画。
- [x] 接入 6 个入口并逐项核对独立的持久化键及点击写入顺序。
- [x] 完成曲线数值、Swift 语法、工程文件和差异检查。
- [ ] 在 iOS 设备验收未读呼吸、点击立即停止、页面重入和应用重启后保持静止。

## 安卓行为依据

- `app/src/main/java/com/ztransfer/ui/screen/TipLightbulbButton.kt`：按钮缩放 1 → 1.09；红点缩放 0.72 → 1.12、透明度 0.58 → 1；单程 900 毫秒，FastOutSlowIn（三次贝塞尔 0.4, 0, 0.2, 1），反向循环。红点直径 7、顶端与右侧内缩 5、颜色 #FF4D3D。已读时按钮缩放为 1，移除红点。
- `HomeScreen.kt`：STA/AP 分别使用独立已读状态；按钮尺寸为 34/36。
- `SettingsScreen.kt`：主设置/照片效果二级页分别使用独立已读状态，尺寸为 30/28；GPS 灯泡尺寸为 30，并使用 GPS 独立状态。
- `LocalPhotoEffectsOverlay.kt`：本地照片效果使用独立已读状态，尺寸为 38。
- `TransferViewModel.kt`：各帮助状态默认 false，打开帮助时写入 true；`TransferStateTest.helpIntroductionsAreIndependentlyUnseenByDefault` 校验这些默认值。

安卓 `HomeScreen.kt` 还有 STA 连接失败时重置已读、连接成功时自动标记已读的特殊处理；iOS `ConnectionPage` 已同步这两个边界。AP、GPS、主设置和照片效果页没有该重置逻辑，点击后保持静止。

## iOS 实现与持久化核对

`TipLightbulbButton` 统一图标比例、圆角、红点和注意力动画；页面只传尺寸、文案、未读状态和点击动作。`TipAttentionValues` 从组件出现时开始计时，反向阶段沿同一条贝塞尔曲线返回，避免使用正弦或系统 easeInOut 近似。已读后立即使用静止值并暂停 TimelineView；移除父弹窗隐式动画对读状态切换的插值，避免点击后还继续缩放一段时间。

| 入口 | 存储作用域 / 键 | 点击行为 |
| --- | --- | --- |
| STA | AppStorage / `sta_connection_help_viewed` | 先保存 true，再展示帮助；连接失败重置为未读，连接成功自动标记已读 |
| AP | AppStorage / `ap_connection_help_viewed` | 先保存 true，再展示帮助 |
| 主设置 | AppStorage / `main_settings_help_viewed` | 先保存 true，再展示帮助 |
| 照片效果二级设置 | AppStorage / `photo_effects_help_viewed` | 先保存 true，再展示帮助 |
| 本地照片效果 | AppStorage / `local_photo_effects_help_viewed` | 补齐此前缺少的持久化，先保存 true，再展示帮助 |
| GPS | `nikon_gps` / `connection_help_viewed` | 直接在点击处理里调用 `markConnectionHelpViewed()`，保存并更新发布状态，再展示帮助 |

GPS 的已读恢复由 `GPSCoordinator.init` 完成，其余入口通过 AppStorage 读取持久化值。各状态保持独立，不因共用组件而合并；页面出现、关闭帮助或切换二级页不重置已读标志。删除主设置和本地照片效果残留的 repeatForever 状态，移除早先只有半幅缩放、没有红点同步动画的临时 modifier。

补充复查：`GPSCoordinator.clearPairing()`、GPS 身份失效处理和 `NikonGPSBluetoothClient.clearPairing()` 仅清理设备身份，不删除帮助已读键；`STAProfileStore.resetPairing()` 仅清理配对配置，不删除 `sta_connection_help_viewed`。只有安卓定义的 STA 连接失败边界会重新激活 STA 引导；AP、GPS 和设置页面不会因切换页面或普通错误重新激活。

## 验证结果与边界

- 对生产 `TipAttentionMotion.swift` 直接运行独立 Swift 脚本，15 项断言通过：起点、900 毫秒峰值、1800 毫秒回到起点、反向对称、下一周期、负时间保护和已读静止值。450 毫秒按钮缩放约 1.06980052，用于区别线性/正弦近似。
- `xcodebuild test` 在 iPhone 17 Pro 模拟器上通过 234 项测试，包含灯泡曲线回归和触感反馈门控/渐强长按测试。
- 修改的 Swift 源文件通过 `swiftc -frontend -parse`；这是语法检查，不是 App 类型检查或整包构建。
- `plutil -lint ios/ZTransfer.xcodeproj/project.pbxproj` 与 `git diff --check` 通过；新组件和时间模型均加入 App Sources。
- 6 个入口的读写路径已完成源码核对；应用重启、真机帧率和红点视觉效果尚未进行真机运行时验收。
- 顺手修正上轮监看入口草稿误用 Kotlin `coerceAtLeast` 的 Swift 表达式，替换为 `max(0, playCount)`；未据此宣称监看入口完整复刻已完成。
