# Android 非 shared 特性回放手册

## 目标和执行边界

本分支只保留 Android。先将整个分支恢复到最后一个非 shared 版本，再把该版本之后新增或修改的 Android 特性逐项搬回。iOS、KMP shared、迁移脚本和迁移过程中的中间代码不属于本分支。

- Android 基线：`a6b679a`。
- 基线之后首次建立 shared 的提交：`9cf6998`。
- 回放前代码快照：tag `codex/pre-nonshared-recovery`。
- 本文只记录 `a6b679a` 之后实际改变 Android 行为、界面、文案或动画的提交。
- `9cf6998..25a7368` 的纯结构迁移不回放；其中被迁移的功能，按本文后面的功能提交重新写回原 Android 类。

每个功能块完成后单独提交并更新本文。没有完成入口、状态、持久化、错误/取消路径和 UI 对照的功能，不标记完成。

## 回放总清单

| 顺序 | 功能块 | 来源提交 | Android 落点 | 状态 |
|---|---|---|---|---|
| 1 | 三种连接协议结果保持一致 | `55876fa` | `NikonCamera`、对象元数据解析 | 待回放 |
| 2 | 队列动作、年度价格、设置弹窗 | `1403f34` | `LicenseManager`、`LicenseDialogs`、`SettingsScreen`、`AnchorPopup` | 已回放 |
| 3 | 设置/滤镜 Genie 展开收起动画 | `65d2fb1` | `AnchorPopup`、`SettingsScreen`、滤镜弹层 | 已回放 |
| 4 | 入队飞行动画后的预览计数 | `16551ee` | `FileListScreen`、`PhotoPreview` | 待回放 |
| 5 | 监看反挤压功能和持久化 | `e25a31e` | `RemoteScreen` | 已回放 |
| 6 | 反挤压选择器样式和动画 | `1a12d60`、`c07159a`、`e84ed51`、`4be6168` | `RemoteScreen` | 已回放 |
| 7 | 反挤压拨轮循环、尺寸和真实缩放 | `7f76531`、`cb296f5`、`ff2188d` | `RemoteScreen` | 已回放 |
| 8 | 分类滤镜和长按帮助 | `dcc84f7` | `SettingsScreen`、`FileListScreen`、效果浮层、资源文案 | 已回放 |
| 9 | 工作台多选和批量照片效果 | `e8e429b` | `HomeScreen`、`LocalPhotoEffectsOverlay`、批处理类 | 已回放 |

## 1. 三种连接协议结果保持一致

来源：`55876fa`。

Android 文件和职责：

- `app/src/main/java/com/ztransfer/protocol/NikonCamera.kt`：统一 USB、AP、STA 下的设备信息和对象读取结果。
- `app/src/main/java/com/ztransfer/protocol/NikonObjectMetadata.kt`：元数据语言字段和缺失字段回退。
- `app/src/main/java/com/ztransfer/protocol/PtpObjectInfoParser.kt`：PTP 对象响应解析。
- `app/src/test/java/com/ztransfer/protocol/CameraMetadataLocaleParityTest.kt`：固定响应样本的等价性断言。

恢复方式：从快照中提取上述文件相对 shared 迁移前的实际改动，写回基线中的同名 Android 类。保留响应字段读取顺序、语言选择、空值处理、异常类型和三种传输入口的共同结果；不带回 shared 包路径或迁移守卫。

验收：相同 PTP 响应在 USB/AP/STA 下得到相同的厂商、型号、文件名和元数据；中文、繁中、英文缺失字段的回退与 `55876fa` 测试一致。

## 2. 队列动作、年度价格和设置弹窗

来源：`1403f34`。

涉及文件：`LicenseManager.kt`、`LicenseDialogs.kt`、`SettingsScreen.kt`、`AnchorPopup.kt`，以及三套 `strings.xml`。快照中新增的 `QueueConfirmationPosition.kt`、`SettingsPopupMotion.kt`、`SharedAnchorPopup.kt`、`SharedTransferScreen.kt` 只提取 Android 的行为参数，不能恢复 shared UI。

必须恢复：

- 队列确认操作的可见条件、按钮位置和状态变化；
- 年度价格的计算、格式化和三语文案；
- 设置弹窗的锚点、展开方向、遮罩、关闭和回调；
- 会员/授权失败时的原错误提示和返回行为；
- 简体中文、繁体中文、英文资源逐字恢复。

验收：设置页按钮顺序和文案与快照一致；弹窗从同一按钮位置展开并在同一时机触发回调；确认、取消、重复点击不会改变原队列状态。

## 3. 设置和滤镜 Genie 展开收起动画

来源：`65d2fb1`。

涉及文件：`AnchorPopup.kt`、`SettingsScreen.kt`；几何参数来源为快照中的 `GeniePopupGeometry.kt` 和 `GeniePopupLayer.kt`，实现放回 Android 原弹层。

必须恢复：起点和终点矩形、圆角变化、裁剪方式、透明度、遮罩、内容缩放、展开/收起时长、缓动、点击外部关闭和动画中输入处理。设置入口与滤镜入口使用同一组参数，不能各写一套近似动画。

验收：两个入口的运动轨迹、时长、遮罩和关闭行为一致；连续打开/关闭不叠加任务、不闪烁、不把内容绘制到旧位置。

## 4. 入队飞行动画后的预览计数

来源：`16551ee`。

涉及文件：`FileListScreen.kt`、`PhotoPreview.kt`。

必须恢复：入队操作先创建飞行动画任务，只有动画完成回调到达后才更新预览计数；动画取消、页面关闭、快速连续入队和批量入队必须释放或合并对应回调。

验收：飞行未完成时不显示最终数量；取消不增加数量；同一照片重复触发不重复计数；从预览页返回列表后数量和实际队列一致。

## 5. 监看反挤压功能和持久化

来源：`e25a31e`。

涉及文件：`RemoteScreen.kt`。

必须恢复：档位枚举和顺序、默认值、SharedPreferences key、工具栏入口、当前值显示、选择器状态、真实画面比例变换、退出监看后的恢复和换相机时的处理。

验收：每个档位的显示比例与快照一致；重启应用和重新进入监看后恢复正确；换相机不会沿用不适用的临时画面状态；按钮和拨轮使用 Android 原图标与文字，不用 emoji 占位。

## 6. 反挤压选择器样式和动画

来源：`1a12d60`、`c07159a`、`e84ed51`、`4be6168`。

涉及文件：`RemoteScreen.kt`。

必须恢复：选择器宽高、圆角、背景材质、边框、选中态、文字字号和颜色、选项间距、锚点位置、打开/关闭动画和外部点击关闭。选择器尺寸不能随档位文字变化。

验收：选择器与工具栏按钮对齐；所有档位文字和选中态一致；打开和收起动画无跳宽、无残影；系统返回和外部点击只关闭选择器，不退出监看页。

## 7. 反挤压拨轮循环、尺寸和真实缩放

来源：`7f76531`、`cb296f5`、`ff2188d`。

必须恢复：工具栏点击的循环顺序、按钮固定尺寸、比例矩阵/裁剪计算、帧尺寸变化时的布局约束、旧帧丢弃和横竖屏处理。

验收：连续点击严格按原顺序循环；按钮不会因档位文字变化跳动；画面比例真实改变而不是只改变标签；退出后停止旧帧更新。

## 8. 分类滤镜和长按帮助

来源：`dcc84f7`。

涉及文件：`FileListScreen.kt`、`LocalPhotoEffectsOverlay.kt`、`SettingsScreen.kt`、三套 `strings.xml`、`PhotoFilterCategory.kt`、`ReleaseCommitWheel.kt`。

必须恢复：分类顺序、分类拨轮、滤镜列表过滤、选中状态、收藏和强度的独立性、长按帮助触发阈值、帮助气泡内容、关闭和返回后的恢复。

验收：分类切换不丢失当前滤镜强度；收藏不会改变分类；点击和长按不互相误触；帮助文案逐字一致；滤镜页面和设置页面使用同一分类顺序。

## 9. 工作台多选和批量照片效果

来源：`e8e429b`。

涉及文件：`HomeScreen.kt`、`LocalPhotoBatchButton.kt`、`LocalPhotoBatchViewModel.kt`、`LocalPhotoEffectsOverlay.kt`、`LocalPhotoPreviewPager.kt`、三套 `strings.xml`。批处理逻辑在 `PhotoEffectsBatch.kt`，按钮状态动画在 `ButtonStateTextMotion.kt`。

必须恢复：

- 工作台多选入口、进入/退出选择模式和选择数量；
- 单选、取消、全选、跨滚动选择和空列表边界；
- 批量预览、滤镜/相框/水印配置快照和逐项输出；
- 处理中进度、取消、单项失败、重试、完成结果和返回工作台；
- 原片只读、输出命名、重复输出隔离和低存储失败清理；
- 按钮文案、禁用态、进度态和完成动画的状态时机。

验收：批量操作不会把不同照片的配置串在一起；取消后临时文件清理；单项失败不阻塞其他项；重试只处理失败项；原片内容和路径不改变；三套文案、按钮大小和动画与快照一致。

## 结构恢复后的统一检查

- Android 源码中不再引用 `shared` 模块的业务类型或 shared UI 组件。
- 每个回放提交只包含对应功能，不夹带 iOS 文件、shared 迁移脚本或无关格式化。
- 每个功能块完成后运行 `git diff --check` 和对应的最小 Android 单元测试；不在中途自动构建或安装。
- 全部九个功能块完成后，再统一执行 Android 构建、安装和真机回归。

当前状态：Android 已恢复到 `a6b679a`；已回放 7/9 个功能块，协议一致性和入队计数尚未回放；尚未构建或安装。
