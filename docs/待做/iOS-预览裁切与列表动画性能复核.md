# iOS 预览裁切与列表动画性能复核

基准：本机 Android `9d7dd882`，iOS `ec304362` 加当前未提交修改。用户明确限定照片列表页及其预览、裁切、上滑入队，要求功能、样式、交互及动画完整对齐；保持其他页面范围不变。主代理独立处理。

## 本轮任务（5 项）

- [x] P01 核验 FHD 正常/竖图/旋转/信息区位置，接入裁切位置过渡。
- [x] P02 原预览透明裁切、比例/角点/缩放/取消恢复、失败重试与确认生命周期。
- [x] P03 裁切 Material 图标及固定位置加号/勾号交叉淡化。
- [x] P04 列表、预览和裁切入队残影渲染优化，保留时间线、真实入队/接收/取消逻辑。
- [x] P05 页面高频更新审查、针对性验证和证据记录。

## 行为依据

阅读 `PhotoPreview.kt` 的 ZoomablePreviewViewport、cropLayoutProgress、closeCrop、startPreviewQueueFlight、CropEditor 调用及固定操作槽；`CropEditor.kt`、`CropEditorGeometry.kt`、`PreviewCropPlacement.kt`；`FileListScreen.kt` 的 QueueFlightGhost。对应测试 `CropEditorGeometryTest`、`PreviewCropPlacementTest`。

- 图片预览底部留系统安全区加 88；信息区下缘为状态栏加 70/112；宽度留白竖图 40、横图 24，正常竖图额外上提至多 12。裁切顶部取胶囊底加 20，横图再加 60；底部再留 84，横图上对齐系数 .5、竖图 1；布局/缩放归一化及取消恢复均 220ms FastOutSlowIn。
- 裁切使用现有 FHD 纹理，控件透明；比例三行，高 40/40/44，横向 20，行距 2；只改变框，不按每次比例重新缩小照片；触摸三分线 120ms，工具显隐/加号勾号 180ms，比例选中 160ms。加载等待 400ms 后出现指示，失败重试，未形成有效裁切时禁止确认。
- 普通上滑主图抬起 105/155ms 至 -132，缩放减少 .055、透明度减少 .07；回弹 stiffness1500/damping .78，未入队回弹 stiffness400/damping .82。残影预留 32ms，再飞行 560ms，路径 CubicBezier(.5,0,.8,.35)，落点为胶囊右缘内 28；最后 6% 消失。裁切直接使用裁切框起飞，不抬主图。
- 列表整组先 420ms 错峰吸取，再 560ms 卡片摞飞行；吸取与飞行是独立图层，不能把吸取过程叠加到尚不可见的飞行容器里。

## 验证记录

- 首轮透明裁切编译及几何/准备/视口回归：`/tmp/ztransfer-inline-crop-tests.log`，14/14，TEST SUCCEEDED。
- 原生图层首轮编译发现 Swift 严格并发要求（CADisplayLink 的非隔离 deinit/Target），`/tmp/ztransfer-crop-flight-compile-tests.log` 为 TEST FAILED；已调整为主 actor 的弱目标与移除/销毁停止，最终复验已通过；保留这次失败记录。
- 尚未真机安装、FPS/CPU 采样或物理手势验收。此前两项文档的 24/24 及胶囊 14/14 属于各自的历史验证，不代替本轮结果。


## 最终开发侧结果

5/5 项开发侧完成，真机性能/物理手势仍待验证，不把代码验证当真机验收。

- P01：正常 FHD 原有的宽度留白/信息区/竖图上提已核验，不冒称均为本轮新增。新增裁切位置进度及正常/裁切切换、进入前缩放记录、取消恢复和方向纠正后的恢复规则。实际生产变换的像素测试证明 400×800 视口中竖图裁切显示区域为 y=110…649，非屏幕正中心。
- P02：移除 NavigationStack 系统 sheet；透明裁切框与控件叠在原预览图上，拖动通过轻量观察者改变原图变换，比例切换不重新适配图片。沿用 JPEG 裁切算法、MCU 对齐、准备取消代次、重复确认闸门和错误重试。只等尚未结束的 220ms 入场，方向纠正才额外等待 240ms，慢 FHD 不再额外固定等待。取消禁用输入至 220ms 恢复结束，离页取消清理。
- P03：Material Crop/Check/Close；Crop 路径额外从本机 material-icons-extended-android 1.5.4 的 CropKt 字节码核对，包含两段 L 形/端部与圆角接头；固定操作槽交叉淡化而非按钮移位。
- P04：共享 QueueFlightLayerSurface，图片及图层仅配置时设置，帧钟只变更图层变换/透明度；单张从真实照片尺寸、位置和冻结的方向起飞，裁切从真实裁切框起飞且不抬主图。整组列表吸取与飞行独立。保留无缩略图占位；离页停止时钟，时限内重挂载恢复；完成释放残影图片。真实入队仍先于视觉占位，取消仍释放占位。
- P05：上滑位移/裁切几何只更新局部观察者；当前预览视口为无发布坐标快照；缩放布尔状态仅变化时发布。列表空态脉冲从每帧 TimelineView 改为一次原生透明度动画，并对齐安卓每方向 1600ms FastOutSlowIn。缩略图缓存/后台 FHD 解码/有限窗口淘汰、正常翻页和信息区淡化、队列进度独立观察等既有结构保留。16ms 等待仅用于同一 FHD 请求的异步所有权，不驱动 UI 帧刷新，未擅改下载调度。

### 最终验证及限制

- `ztransfer-crop-flight-rendering-tests.log`：40 项中 38 通过，2 条断言失败来自 CGRect.intersection 的约 1e-13 舍入差。改为 1e-9 几何容差，未改生产行为。初版截图测试窗口未挂 UIWindowScene，截图全黑；人工查看后改为真实 scene/key window，增加非黑像素断言，不能引用旧图为外观证据。
- `/tmp/ztransfer-preview-page-final-tests.log`：61/61，0 失败/跳过，TEST SUCCEEDED，exit0。包含裁切几何、FHD 实际渲染、三行控件截图、原生图层生命周期、30 次上滑/裁切更新不增加父 body 次数、原效果弹窗/列表滚动/预览缓存取消等回归。
- 收尾改动后 `/tmp/ztransfer-preview-page-cleanup-tests.log`：24/24，0 失败/跳过，TEST SUCCEEDED，exit0。包含新增无缓存占位/移除停止及重挂载恢复，裁切准备/确认取消回归。两次有重复项，不能相加声称 85 个独立测试。
- 已查看真实组件渲染截图：`/Users/orys/Library/Developer/CoreSimulator/Devices/FC8ECF06-0A56-4949-B64C-3EE06870025E/data/Containers/Data/Application/ED50731C-3B15-4B65-A4AD-C9132FA913BB/tmp/ztransfer-inline-crop-controls.png`。这是受控图像的组件截图，不是真机相机画面；不证明所有手势或全部页面像素一致。
- `git diff --check` 通过。未运行 XCUITest、真机包/安装、FPS/CPU 采样，未提交或推送。必须在真实照片数量、相机连接与设备上复测滚动、打开预览、裁切取消/确认及上滑入队流畅度；当前结论是删除已识别的额外刷新/重建，不是已保证所有设备恒定满帧。
