# iOS 触感反馈复刻记录（2026-09-16）

## 对照范围

依据安卓 `app/src/main/java/com/ztransfer/ui/util/Haptics.kt` 及全部 `haptics.*` 调用点核对：普通 tick、长按、成功、失败和 GPS 800 毫秒渐强长按。iOS 统一由 `ZTransferHaptics` 门控，普通触感尊重 `haptics_enabled`；触感设置自身切换沿用安卓的“即使当前关闭也确认本次切换”规则。

## 已接入的触发点

| 安卓触发 | iOS 对应位置 | 触发时机 |
| --- | --- | --- |
| 连接成功 / 失败 | `ConnectionPage` | 成功庆祝延迟到 620ms；失败只在失败结果首次变化时触发 |
| 队列开始、暂停 | `PhotoListView` | 目录有效且操作被接受后 |
| 单张、整组入队 | `PhotoListView`、`PhotoPreviewView` | 入队前置条件通过后各震一次，预览层不与列表层重复 |
| 长按照片预览 | `PhotoListView` | 长按真正打开预览时 |
| 连拍展开/收回、高分辨率图像就绪 | `PhotoPreviewView` | 状态改变或当前图像实际解码成功时 |
| 队列完成 | `PhotoListView.QueuePill` | 有真实活动批次完成且未取消时 |
| 设置拨轮、照片效果、收藏、展开子设置 | `DetentWheel`、`PhotoEffectsEditorView` | 每个有效档位或有效操作一次 |
| GPS 展开、普通按钮、800ms 长按 | `GPSConnectionControl` | 提交改变、有效普通点击、长按开始/取消/完成；离开页面、切后台和关闭触感会停止渐强反馈 |
| 远程曝光逐档、自动 ISO | `RemoteExposureTile`、`RemoteViewModel` | 每个新档位、实际状态改变被接受后 |
| 远程快门、录像、半按、点按对焦、追踪取消 | `RemoteViewModel`、`RemoteShutterButton` | 命令生命周期的接受、成功和取消路径分别触发，迟到的协议结果不补震 |

## 渐强长按参数

`HapticPolicy.swift` 保留安卓十个脉冲的开始时间、时长和振幅：`0/8/24`、`120/8/28`、`230/9/34`、`330/9/42`、`420/10/52`、`500/10/64`、`570/11/78`、`630/11/96`、`680/12/118`、`725/12/142`，总时长 800ms，末脉冲结束于 737ms 后留 63ms 静默。提前松手立即停止，完成后才补重击。

## 无对应 iOS 触发点

- 安卓 `Fireworks.kt` 的烟花爆炸 tick 只服务于安卓高级版徽标彩蛋；当前 iOS 没有高级版徽标、烟花 overlay 或对应入口，因此没有可复刻的 iOS 触发点。
- 安卓取景器本地 MP4 录制保存成功 tick（`RemoteScreen.stopRecorder`）依赖安卓专有的 `StreamRecorder`；当前 iOS 远程页只有相机录像命令，没有取景器本地录制入口，因此未添加不可达的震动调用。

## 验证

- `xcodebuild -project ios/ZTransfer.xcodeproj -scheme ZTransfer -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/nk_send_haptics_current build CODE_SIGNING_ALLOWED=NO`：`BUILD SUCCEEDED`。
- 当前修改和新增 Swift 文件通过 `swiftc -frontend -parse`，工程文件通过 `plutil -lint`，`git diff --check` 通过。
- `ios/ZTransferTests/HapticsTests.swift` 覆盖全局门控、设置切换例外、渐强长按取消/完成去重和十脉冲参数；在 iPhone 17 Pro iOS Simulator 上与现有测试一起运行，234 项全部通过（含 3 项触感测试）。
- `swift test --package-path ios` 不适用于完整 iOS 目标，因包目标包含 UIKit，失败原因是 macOS SwiftPM 无法解析 UIKit，并非触感实现编译错误。
