# iOS 全界面性能优化台账

## 目标与约束

2026-10-18 用户要求逐个界面检查并优化列表滚动、动画渲染、界面更新，减少额外运算、卡顿和发热，同时保留功能、交互、动画体验。范围是整个 Z传 iOS 应用，不缩减为照片列表页。Android 是行为参考，iOS 可使用合适的原生渲染/调度方法，但不能借优化删除动画、改动动画时序、丢事件、降低有效信息刷新或改变取消/重试/持久化规则。

基线：iOS `ec304362` 与当前工作树（包含前一轮照片列表/预览/胶囊未提交改动）；Android 本机 `9d7dd882`。按用户要求主代理独立推进，不启动大量子代理。沿用已授权的专项模拟器验证；不擅自真机打包、安装、提交或推送。

## 完成口径

每项依次经过“源代码和行为核对 → 确认热点或无效更新 → 优化/说明无需改动 → 针对性验证 → 记录限制”。只有核对和证据都具备才记开发侧完成。全应用目标还需要代表性运行负载和设备性能证据，不能把模型测试/编译通过外推为整机功耗或流畅度达标。历史测试仅作定位线索，不能自动核销本台账。

当前：**33/34 项开发侧完成**。P17 的 USB 真机监看卡顿已修复，用户复测确认“这次流畅了”；P34 的其他综合场景继续待验。下方保留问题重开和中间失败记录。

## 逐界面/共享路径检查清单

| 编号 | 界面或路径 | 主要入口 | 必须核对的项目 | 状态 |
|---|---|---|---|---|
| P01 | 根页面、工作台翻页/切换 | App/RootView | 隐藏页生命周期、状态观察范围、手势排他、动画中断/恢复 | 开发侧完成，真机待验 |
| P02 | 连接页/连接卡片 | Connection/ConnectionPage、ConnectionMethodCard | 持续动画局部化、连接状态无效发布、成功切页、后台时钟 | 开发侧完成，真机待验 |
| P03 | GPS 控件及面板 | Connection/GPSConnectionControl | 秒级时间显示、GPS/地点发布范围、弹层开合、离页清理 | 开发侧完成，真机待验 |
| P04 | STA/AP 提示及配对重置 | Connection/STATipsOverlay、STAResetPairingOverlay | 重复布局/图层、触摸命中、弹层卸载 | 开发侧完成，真机待验 |
| P05 | 主设置 | SettingsView、SettingsPopupOverlay | 整列滚动、测量反馈、目录查询、摘要计算、配置更新范围 | 开发侧完成，真机待验 |
| P06 | 筛选/日期/评级弹窗 | PhotoFilterPopupOverlay、PhotoFilterComponents | 控件测量、滚动、评级进度、选择事件及提示动画 | 开发侧完成，真机待验 |
| P07 | 照片列表与分组 | PhotoListView | 滚动坐标快照、分组/排序重复计算、可见缩略图、日期折叠/返回顶部 | 开发侧完成，真机待验 |
| P08 | 照片预览与连拍 | PhotoPreviewView | 翻页/缩放状态范围、解码/缓存、直方图、开关/旋转/入队动画 | 开发侧完成，真机待验 |
| P09 | 裁切预览 | PhotoCropEditor | 拖动/缩放局部更新、图片复用、布局/取消恢复、确认/重试 | 开发侧完成，真机待验 |
| P10 | 传输队列列表/任务卡片 | TransferQueueView | 滚动/排序、完成移位/删除、侧滑、缩略图、非活跃行更新 | 开发侧完成，真机待验 |
| P11 | 进度/速度/数量/状态动画 | PhotoListView、TransferQueueView、Queue*组件 | 无效发布、每帧文本/图层分配、静止停止、忙闲切换/接收动画 | 开发侧完成，真机待验 |
| P12 | 本地照片效果工作台 | LocalPhotoEffectsView | 多图分页、批量标签、滚动状态、预读/取消、拨轮手势 | 开发侧完成，真机待验 |
| P13 | 设置/预览照片效果入口 | PhotoEffectsEditorView、PreviewPhotoEffectsEditor | 独立草稿、同配方去重、渲染队列、弹层布局、返回保存 | 开发侧完成，真机待验 |
| P14 | 效果全屏预览/对比 | PhotoEffectsExpandedPreview | 原图/效果图切换、分页与手势、图像缓存/淘汰、隐藏页 | 开发侧完成，真机待验 |
| P15 | 滤镜/LUT/边框选择列表 | PhotoEffectChooserDialog、PhotoLUTChooser | 大目录扫描/搜索、列表身份、缩略图、收藏、目录读取与取消 | 开发侧完成，真机待验 |
| P16 | 效果参数/水印/导入 | PhotoEffectsControls、SettingsView | 拨轮密集更新、预览请求合并、文字测量、文件/照片选择返回 | 开发侧完成，真机待验 |
| P17 | 遥控取景主界面 | RemoteView、RemoteLUTMetalView | 相机帧与整页状态隔离、帧解码/GPU提交、纵横屏/后台/停止 | 开发侧完成，USB卡顿修复经用户真机确认 |
| P18 | 取景直方图/波形/斑马/伪色/峰值 | RemoteView、RemoteExposureAnalysis | 开关门控、采样/缓存、过期帧丢弃规则、输出不变 | 开发侧完成，真机待验 |
| P19 | 水平仪/方向/构图网格 | RemoteHorizonOverlay、RemoteFramingGridOverlay | 传感输入去重、动画时钟范围、Canvas 几何、切换恢复 | 开发侧完成，真机待验 |
| P20 | 曝光参数拨轮/数值列表 | RemoteExposureTile、RemoteParameterPanel/Input | 格式化/布局缓存、状态与手势分离、相机写入节奏不变 | 开发侧完成，真机待验 |
| P21 | 遥控工具栏与菜单编辑 | RemoteConfiguredToolbar、RemoteToolEditorMotion、RemoteChoicePopup | 拖动/重排局部更新、隐藏工具、模式交叉淡化、菜单计时 | 开发侧完成，真机待验 |
| P22 | Picture Control/NP3 面板 | RemotePictureControlPanel | 目录/预设排序、迟到回调隔离、加载提示、存储/取消 | 开发侧完成，真机待验 |
| P23 | 遥控 LUT 列表/参数 | RemoteView、RemoteLUTMonitorState | LUT 读取/解析/上传去重、强度更新、跨面板生命周期 | 开发侧完成，真机待验 |
| P24 | 快门/相机录像/本地录制 | RemoteShutterButton、RemoteRecorderBar | 秒数更新频率、动画时钟、录制回调范围、收尾保存不受影响 | 开发侧完成，真机待验 |
| P25 | 遥控照片回看 | RemotePhotoReviewView | 分页/FHD/RAW配对、加载取消、恢复取景、页面身份 | 开发侧完成，真机待验 |
| P26 | Pro 购买/恢复/徽章 | PremiumPurchaseView | 状态发布、按钮动画、商店请求生命周期、隐藏页面 | 开发侧完成，真机待验 |
| P27 | 成功庆祝/烟花 | PremiumFireworks、连接成功动画 | 粒子预计算、有限时钟、离页释放、原时序和视觉 | 开发侧完成，真机待验 |
| P28 | 诊断日志/开发面板 | RemoteView、DebugPhotoProtectionPanel、PTPTransferDiagnostics | 日志截断/字符串构建、滚动快照、订阅生命周期 | 开发侧完成，真机待验 |
| P29 | 系统选取器/权限/授权返回 | DirectoryPicker、Photo/LUT 导入、App 生命周期 | 主线程阻塞、数据读取、重复回调、恢复状态 | 开发侧完成，真实Provider/真机待验 |
| P30 | 公共弹窗/阴影/玻璃主题 | GeniePopupPanel、AndroidShadowView、Theme | 闲置帧钟、截图/网格/GPU提交、几何缓存、隐藏图层/主题切换 | 开发侧完成，真机待验 |
| P31 | 公共拨轮/灯泡/提示/按钮 | DetentWheel、TipLightbulbButton、PhotoListHint 等 | 稳定输入去重、局部观察、命中/长按/拖动、灯泡保持静态 | 开发侧完成，真机待验 |
| P32 | 图片/效果工作队列与缓存 | Domain 中预览、缩略图、效果渲染器 | 主线程图像工作、并发预算、缓存身份/容量、取消代次 | 开发侧完成，真机待验 |
| P33 | 生命周期、内存与共享发布 | 页面模型/主题/App 状态 | 重复通知、隐藏页任务、时钟引用环、后台/重入/内存压力 | 开发侧完成，真机待验 |
| P34 | 全界面综合性能验证 | 上述各路径 | 大列表/快速切页/持续动画/传输中操作、性能前后对照、功能回归 | 部分通过：模拟照片体感确认；真实相机待验 |

## 每项通用验证维度

1. 空闲：静止后是否仍执行布局/图像处理/计时；持续视觉动画只保留必要运算；前后台与离页停止规则。
2. 高频交互：滚动、拖动、缩放、拨轮、取景和传输进度只刷新必要子树；不丢失有效事件，不通过降速制造假优化。
3. 图像：解码/缩放/直方图/LUT/缓存工作是否在正确线程；同一内容去重；过期工作取消；原图与导出质量不变。
4. 渲染：几何/路径/文本计算可复用；避免重复截图、叠层与绘制；保留透明度/位置/时长/弹簧和图层顺序。
5. 生命周期：关闭、取消、失败、重试、方向变化、后台恢复、相机断开、内存压力均保持状态正确。
6. 证据：针对性测试、真实组件渲染、刷新次数/计算次数、耗时/内存/CPU/FPS，逐项注明覆盖范围与未测限制。

## 初始扫描发现（不是完成结论）

- 页面/弹层清单已从 RootView、UI 顶层视图及其子界面枚举，未把 DEBUG 测试 Harness 当用户页面。
- 前一轮照片列表已有高频坐标与预览动画隔离；本台账仍须结合相邻页面、共享组件检查，不能直接照搬历史完成状态。
- `AndroidShadowFrameClock` 对所有挂载阴影持续运行，并每帧检查祖先几何；静止时虽不提交 GPU，仍有 CPU 几何采样，需要证明可安全缩减工作后再修改，不能漏掉父层动画。
- 多个动画驱动器在输入不变时仍修改 `@Published` 结构体；先验证是否导致无效通知，再保持原动画模型优化发布。
- 遥控、工作台、队列已有部分局部观察和任务隔离，必须读实际接线，不能仅凭“使用 SwiftUI/TimelineView”认定必然低效。

## 运行/验证记录

### P12 工作台与 P17 取景（开发侧完成）

- P12 依据：Android `LocalPhotoEffectsOverlay.kt`、`LocalPhotoPreviewPager.kt`、`PhotoEffectsPreviewCacheTest.kt` / Prefetch/Transition 测试。工作台页的 scrollOffset 仅用于返回手势准入，预览全局 anchor 仅用于展开时快照；原先两者每像素写入 SwiftUI State。改为不发布的引用快照，保留实时坐标、-2/70 阈值、拨轮触点排除及打开时坐标。未变更 picker 选择/替换、4:3 可见页解码、长按500ms、文字140ms防抖、比较500ms和下两项滤镜预热规则。批量结果按单张完成发布；图像缓存有限、独立取消代次和离页清理保留。
- P17 依据：Android `RemoteScreen.kt` 的 conflated 取帧/解码、首帧与 USB8次稳定门控、会话保帧/清帧分支和 `RemoteLiveViewSchedulingTest.kt`。原 iOS 每帧通过根 model 连续发布图片、时间戳、各分析数组和 state.frameSequence，造成整个工具栏/面板重算。新增取景专属通知，同一帧同步变更仅通知一次，只有首图/清图/尺寸及控制状态变化发布给整页。实际取帧、解码、分析采样周期、录制append、FPS与帧序号均不降频。焦点500ms过期仍独立通知取景；提示气泡动画仅由现有子视图观察。
- `ztransfer-p12-p17-performance-tests.log` 首次编译因自定义 ObservableObjectPublisher 的 Swift 严格主线程 conformance 声明失败，测试未运行；已按编译器建议保留主线程隔离并使用 @preconcurrency 协议符合，正在相同专项中重验，不能记为通过。
- GPU 复核补充：MTKTextureLoader 改为随 renderer 复用，最多保留最近一张 CGImage/源纹理；失败不替换有效缓存，GPU command buffer 自持在途纹理，未循环改写正在使用的纹理。同一图像的纯控件更新不再提交绘制；新图在旧 drawable 在途期间到达，完成/呈现汇合后补绘最新图，避免最后一帧依赖下一次到达；窗口尺寸变化仍重绘，失败/卸载不恢复任务。
- 后续两轮新增测试编译分别暴露 CGRect 数值推断和像素期望数组推断错误，已显式类型修正；`performance-fixed.log` / `performance-final.log` 均为失败且未执行测试，保留，不误记通过。
- 最终 `/tmp/ztransfer-p12-p17-performance-verified.log`：**63/63、0失败/跳过、TEST SUCCEEDED、exit0**。包含工作台30次坐标更新不重算父body、展开快照/缓存重入、拨轮区域，取景120帧一帧一次局部通知/整页零通知、30帧真实host子树更新且图片不陈旧、500ms焦点过期、尺寸变化/停用/迟到拒绝、解码并发与切换、8项会话回归。Metal真实输出验证20次同图上传1次、替换失败保留旧缓存并可重试、仅保留最近图、换LUT输出随之改变，真实MTKView确认在途末帧补绘。
- 不将这些计数和模拟器GPU输出外推为真机FPS/CPU/温度。P18分析绘制、P19传感输入和P20工具控件的进一步开销分别继续；未真机测试、安装、提交。


### P18 取景分析绘制（开发侧完成）

- 依据：Android `RemoteScreen.kt` decode、`RemoteExposureAnalysis.kt` analyzeMonitorFrame/Throttle、`RemoteMonitorScopes.kt` WaveformOverlay；分析源为最多256×192，波形256×128，直方图250ms、斑马50ms、波形125ms，伪色逐有效解码帧。对应缓存/阈值/尺寸测试已核对，未更改这些采样/开关/取消规则。
- 热点：iOS波形每次Canvas重绘都计算32,768像素颜色并逐点填矩形；伪色在主线程body内转换整张像素缓冲。现两者在既有detached解码worker生成不可变CGImage；波形位图与bins一起按125ms缓存，尺寸、RGB/Luma、会话切换/关闭全部同步失效。界面一次绘图复用图像，波形按安卓FillBounds/Medium采样，保留刻度/参考线/布局。直方图/斑马/分析布局对稳定输入使用Equatable门控，未降低有效刷新频率。
- 图像ARGB字节顺序、透明波形密度、阈值、源像素和尺寸未改变；加号/对焦/录制/取景生命周期不变。基准没有单独的对焦峰值工具，此项不新增工具；音量峰值保留原数据/绘制。
- `/tmp/ztransfer-p18-analysis-tests.log` 首轮因为纯值View的Equatable方法继承MainActor隔离编译失败，未运行；比较方法改为nonisolated后，`/tmp/ztransfer-p18-analysis-fixed.log` **55项，54通过、1权限前置条件跳过、0失败，TEST SUCCEEDED、exit0**。实际覆盖新位图通道/透明度与非法尺寸拒绝、125ms内同波形CGImage身份复用/125ms边界更新、伪色逐帧、模式/尺寸/会话/关闭失效、完整真实来源/覆盖层变形与缩放、生产scope布局、LUT状态/输出/在途末帧及对焦回归。
- 跳过的是P17补充录制收尾回归：要求专用模拟器麦克风已拒绝。已仅对测试模拟器执行privacy revoke，随P19补跑通过；不是分析功能测试失败。未真机验收。

### P19 水平仪/方向/构图（开发侧完成）

- 对照Android `RemoteScreen.kt` 250ms机身角度采样、1.5s有效双轴头/0xD067回退、三次失败停属性查询及`RemoteViewfinderFeatures.kt`水平仪100ms角度/160ms颜色、0.7/1.2迟滞和构图线规则，阅读FramingGrid/Orientation/Viewport测试。iOS使用系统方向的既有批准差异保留，方向260ms稳定和80/140ms转场、关闭/冻结/回看门控未改。
- 相同角度不再发布，变化的roll/pitch对仅通知取景一次，避免无效整页重算。水平仪动画驱动忽略相同输入的结构体写入，但离页stop后重入同目标仍恢复未完成动画；稳定输入通过Equatable门控隔离相机逐帧更新。构图网格同样保持输入与尺寸变化有效，稳定时跳过重算。`/tmp/ztransfer-p19-horizon-tests.log` **28/28、0失败/跳过、TEST SUCCEEDED、exit0**。包括同角度120次不发布、双轴一次/变更/清空局部通知、真实CADisplayLink停用/相同目标恢复、实际host中Equatable水平仪从水平动画到垂直的像素断言、100/160ms模型/颜色、方向门控及构图几何、双轴头→属性回退/三失败/重新启用。此前权限跳过的录制撤权/并发退出收尾已实际补跑通过。
- 本组结束后git diff --check通过；未新增全量测试、真机安装/CPU/FPS/热状态测试、提交或推送。设备层面仍在P34待验。

### P10 队列列表与 P11 进度/状态动画（开发侧完成）

- 行为依据：Android `TransferScreen.kt` 的倒序稳定身份、活动行进度订阅、生成中200ms计时、300ms Oklab卡片变色、280ms收合及320ms清空兜底；`FileListScreen.kt`/`QueuePillStateTest.kt` 的队列摘要、胶囊宽度/数字/模式保留；`TransferQueueActionVisibilityTest.kt` 的清空期间操作抑制、`LiquidProgressWaveTest.kt` 的波形边界与循环。源代码和对应测试已核对。
- 已有正确路径：队列使用LazyVStack与reversed视图，UUID稳定；进度流已独立，只有活动卡订阅，不把既有隔离算作本轮新增。行位移使用内容坐标而非滚动坐标，尺寸/位移/侧滑时钟停稳后结束，缩略图命中直接复用解码缓存、STA只等已有缓存更新；取消/会话与重试策略未改。液面8/12段路径原本只在局部绘制，包络低于阈值时卸载时钟，保留2200/2600ms、Float谐波和既有UUID种子。
- P10改动：效果耗时的Timeline仅生成实际运行且有起始时间时200ms刷新；完成/等待时不再持续唤醒，仍保留同一个Timeline/气泡节点，避免退出/重入动画重置。300ms卡片变色只通知底色与色标叶节点，不再重算文件名、缩略图、按钮与各标签。
- 批量清空：先撤下等待任务和标记收合，280ms后用一个actor调用线性筛选目标ID并发布一次，替代每卡一个延时任务/数组删除/整队列索引重建。继续在删除时校验终态及生成占用；动画期间新加入、重试换身份、已开始传输/生成的任务不误删。原320ms终态兜底保留，失败移除仍解除收合标记恢复卡片。标记回收使用集合交集，避免每个待删ID再遍历完整ID数组。
- P11改动：卡片小标签的140ms宽度及105ms响应/弹回仅更新布局修饰器；相同物理像素测量和响应状态不再写Published结构体，停用后重测不复用旧宽度。进度平滑外层、顶栏胶囊宽度外层改为仅持有时钟，现有绘制/布局子节点订阅，原数字滚动、退出快照、右缘固定及中断规则保留。LiveQueuePill只在结构输入更新时构造任务摘要，200ms速度采样复用该摘要。
- 空队列标志：原每帧Published→SwiftUI body→Canvas重绘改为保留同一DoubleZMark内容、只由透明UIKit祖先图层执行动画。4.8秒循环的两段2.4秒曲线分别为(.4,0,.2,1)和反向(.8,0,.6,1)，透明度.42↔.54、缩放.985↔1.015；独立祖先保留340ms显现的乘法关系。离页/离窗清除，重新进入重启；重复配置不重启动画，主题仍由原环境更新。不改灯泡或其他持续动画。
- 验证历史：`/tmp/ztransfer-p10-p11-performance-tests.log`首次因新增测试闭包缺少显式self编译失败，测试未执行；修正后`performance-fixed.log`执行56项，其中宽度测试用700ms固定等待误认为弹簧已结束，2断言失败，其余通过。未缩短动画来迎合测试；改为等待实际isRunning停止、上限3秒。
- 最终`/tmp/ztransfer-p10-p11-performance-final.log`：**56/56、0失败/跳过、TEST SUCCEEDED、exit0**。包括500任务真实队列批量删除/新任务/重试/活动下载与生成保护、活动订阅迁移、真实host计时停止/恢复且不重挂载、卡片颜色中断与局部body计数、120次重复标签测量零通知、胶囊宽度帧不重算父body、实际像素右缘固定、数字滚动、尺寸/侧滑/移位/进度/颜色与波形模型回归。
- 另`/tmp/ztransfer-p11-native-mark-render.log` **1/1、0失败/跳过、TEST SUCCEEDED、exit0**（与上组重复项，非新增独立测试）：加强实际原生宿主像素检查，含显现/正向/反向presentation值、持续动画中内容body不重算、启停/重复配置/离窗；实际黑色图形覆盖数验证非空白/非实心块，已目视`/tmp/ztransfer-p11-empty-mark.png`显示清晰双Z。只是组件渲染与刷新范围证据，未测真机FPS/CPU/温度或真实传输中的整页功耗；未安装、提交、推送。

## 下一组

P17 重新打开后已修复并获用户真机确认，当前累计33/34项，剩余P34其他综合场景；不会把这次监看通过外推为全应用/所有机型性能均通过。

### P13 设置/预览效果入口（开发侧完成）

- Android依据：`SettingsScreen.kt` 392–425行的后台示例图/旋转源、2982行起的`PhotoEffectsRenderedPreview`；源/方向记忆、三个最近成片缓存、单份滤镜中间图、独立对比图、500ms对比延迟、后两个滤镜顺序预热；140ms只对文字变更防抖且先归一化displayText。已阅读PreviewCache/Prefetch/Transition测试，核对220ms图片交叉淡化与110/190ms画布转换，未改这些时序。设置与预览仍共用SettingsPopupOverlay和独立于本地工作台的草稿/存储，未合并业务状态。
- 确定热点：设置预览的全局anchor每像素写入State，导致整块预览body及JSON渲染键重复构造；源旋转在body、主渲染任务、预热任务多次同步生成整张UIImage；无用cachedContextKey State还制造额外刷新。现复用非观察的PhotoEffectsGeometrySnapshot存坐标，打开时冻结anchor；像素身份memo仅在有效配方/源/EXIF改变时编码，保留单一身份和强引用防地址复用，不共享不同编辑器草稿。水印按displayText归一化，显示相同的空白编辑不重启渲染。
- 实际旋转移入既有可取消串行后台gate，用一份当前源/方向缓存供主图、对比和预热复用；零度直接复用源，切源/方向/关闭失效，消费者取消不取消仍被另一消费者等待的共享工作。示例图生成与旋转也移进worker。保留现有图像尺寸、scale、方向、成片渲染质量与缓存容量；预热不再构造无人使用的返回数组和重复JSON键。
- 临时原图/失败图显示使用只改UIImage方向元数据的轻量包装，复用同一CGImage并在状态不变时复用包装对象，不在body逐像素旋转。先尝试GPU旋转视图时，像素检查发现270°及部分EXIF方向整体偏移1px：布局先舍入再旋转产生；诊断PNG/pixel bbox确认后已替换为先确定图像方向再布局。补透明源测试又确认原路径保留alpha，多余黑底已删除，未放宽失败阈值。
- 展开快照复用为PhotoEffectsExpandedPreviewSnapshot：两个入口都固定打开图片/anchor，异步对比图只按该图片身份补齐。连接入口原先没有传comparison，现在与安卓已读源码一致，返回仍只关闭当前展开，不更换底层草稿。
- 验证历史：`p13-effects-performance-tests.log`首次因LocalPhotoPreviewImages要求非空对比图编译失败，已改共享快照支持可空输入；`performance-fixed.log`执行29项、3像素断言失败；`rotation-diagnostic.log`重复定位该1项失败，实际差异为x37…81与x38…82。`performance-oriented.log`修正方向包装后29/29、0失败/跳过、TEST SUCCEEDED/exit0；其后`source-final.log`补透明测试5项中1项3断言失败，`alpha-diagnostic.log`重复定位，实际多余黑底已修。中间失败全部保留，不将早期通过当最终结论。
- 最终`/tmp/ztransfer-p13-effects-performance-final.log`：**30/30、0失败/跳过、TEST SUCCEEDED、exit0**。覆盖后台线程/共享旋转复用（40次同源同方向只生成一次）、消费者取消/关闭后迟到拒绝/新源重开、零度直接引用、单方向容量、八种EXIF方向×五种旋转输入的实际组件像素与scale/fit、透明源alpha与CGImage身份复用；120次非像素偏好变更及显示等价水印只编码一次、曝光补偿和含分隔符EXIF身份区分、30次坐标更新父body不变及冻结anchor、现有缓存容量/预热/取消/快照/弹窗/草稿回归。已查看最终临时显示样张；保存的270°样张及透明源样张与原物理旋转路径的bbox一致，RGBA平均字节差均0.0。中间结果不与最终项数累加。未安装/提交，真机滑动FPS、CPU与热状态未测。

### P14 效果全屏预览/对比（开发侧完成）

- 行为依据：已阅读Android `SinglePhotoPreviewOverlay`/`ZoomablePreviewViewport`和`PreviewGestureGeometryTest`：独立图片变换状态、长按500ms按身份对比、展开340/关闭260ms、双击240ms FastOutSlowIn和旋转220ms、旋转过程中按实时角度重新拟合；拖动/捏合应中断缩放并保留当前可见值。
- 图片手势和每帧状态移入`PhotoEffectsExpandedImageSurface`，外层仅持有交互对象，不订阅帧；单次合并发布变换与捏合状态，相同输入不通知。只有正在旋转/双击缩放且已显示时才启用CADisplayLink，弱目标避免引用环，停稳/离页停止。复用原图和共享钳位/缩放几何，没有每帧生成位图。
- 补齐旋转220ms、双击240ms曲线与实时角度拟合。旋转重入从当前可见角度继续；拖动中断双击时使用当前显示值，捏合改单指只累计新位移。SwiftUI取消拖动也清理基线。关闭延时Task随页面取消，展开/关闭原340/260ms保持。
- 对比边界补强：LongPress的first(true)仍处于等待阶段，只有second(true)才显示对比；捏合或关闭及时退出对比。对比图仍由P13固定图片身份快照提供，不改变工作台与设置的独立草稿。
- `/tmp/ztransfer-p14-expanded-performance-tests.log` **28/28、0失败/跳过、TEST SUCCEEDED、exit0**；最终对比/取消补强后`/tmp/ztransfer-p14-expanded-final.log` **10/10、0失败/跳过、TEST SUCCEEDED、exit0**。后组包含前组重复项，不累加为38独立测试。覆盖240/220ms中途值/结束、动画中断、双指改单指、连续旋转、满500ms阶段门控、重复状态去重、实际display link停用/恢复/所有者释放、真实生产组件30次拖动父body不重算且实际像素位置准确移动30点、旋转后的像素方向，以及既有展开生命周期/固定快照/缓存/布局回归。
- 未执行UI手势自动化或真机FPS/CPU/温度验证；模拟器组件像素与发布次数不能等同整机性能。未安装、提交或推送。

### P15 滤镜/LUT/边框选择列表（开发侧完成）

- Android依据：完整核对`PhotoLutEditor.kt`、`PhotoLutEditorState.kt`、`LutCategoryList.kt`/`PresetCategoryBrowser`、SettingsScreen的滤镜选择器、`LutFolderRepository`/`PresetFolderRepository`及收藏/解析缓存测试。LUT按目录顺序稳定分组为收藏优先，不按点击收藏顺序重排；内置滤镜/边框仍保留各自收藏顺序。分类独立于本地化文字，初始定位选中项，切分类重建右列，刷新不跳回选中项，固定32高操作栏/36:64双列/2点行距不变。边框是有限枚举拨轮，没有目录/缩略图/搜索，未增加不存在的列表功能。
- 原热点：LUT拨轮每个名称闭包都重新生成全目录名称表，多个selectionOptions/orderedFiles访问反复分组；弹窗更新时完整测量每个名称并由VStack创建所有行。现编辑器按当前目录与收藏持有一个索引，缓存原顺序重名编号、分类、按ID查找、本地化名称和当前选项数组；目录内容/元数据或收藏变化才失效，同一成功扫描复用，缺失的私有快照选项仍保留。相机/本地角色的配方/草稿未合并，语言变更更新显示名称，不改变分类身份。
- 弹窗高度先用单行最小高度判断是否已达到原上限；达到即直接返回，否则只测到上限。10,000项目录需0次文本测量，60组长短/多行/中英文/空列表/宽高组合与原全量计算完全相同。
- 大目录不能仅用LazyVStack：实际host测试定位第2500项仍创建2510行且偏8.5点。因此改为`UITableView`复用滚动容器，行仍是原`PhotoEffectChooserRow`，以文件/分类ID复用；取消系统最小行高、间距、分隔线和边缘效果，保留透明度与原Button动作。先按估计定位，再用目标真实行框精确对齐；后台更新保留可见项目ID与行内偏移，普通状态更新不调用滚动定位；无持续时钟。
- 扫描/解析现有路径本已在串行后台PresetIOQueue，保留根目录加一级分类、全部条目10,000预算、元数据复查、权限范围、取消检查、10秒请求期限、失败不覆盖旧目录/配方和关闭拒绝迟到结果，不冒称本轮新增异步读取。
- 验证历史均保留：`p15-chooser-performance-tests.log`新增测试闭包缺self编译失败；`performance-fixed.log`14项2断言失败（SwiftUI远处滚动的行数/定位）；`chooser-native-list.log`14项1失败（用绝对contentOffset判断滚动位置，原生估计值更新时会变化）；已改验证用户可见行ID及屏幕位置，并只在目录变更时恢复锚点。`native-position-pixels.log`4项5断言失败（系统默认52.33行高）；`native-row-sizing.log`4项2断言失败（解除最小行高后估计定位偏12点），已按实际行框修正。`native-position-final.log`4/4通过，进一步标准色域和明确像素缓冲验证`row-pixel-verification.log`1/1通过；中间项不累加。
- 最终`/tmp/ztransfer-p15-chooser-final.log`：**29/29、0失败/跳过、TEST SUCCEEDED、exit0**。包含大目录定位/拖后刷新/前方插入保留身份/切分类、真实原生容器六种行高与sRGB/透明像素（平均字节差最大0.0092）、3,000项实际仅创建31行、120次非目录状态变化复用索引/选项存储、目录增删/重扫/收藏跨角色失效、重复名称与本地化、取消/超时/独立请求/文件读取预算/损坏与权限/重试/私有快照回归。已查看两列行截图；初次P3透明截图与sRGB参考的显示差异另用标准范围截图和明确sRGB缓冲核实，未放宽像素断言。
- 模拟器组件验证不等于真机FPS、手势惯性或整页功耗验收，仍由P34覆盖；未运行UI自动化、真机打包、安装、提交或推送。

### P16 效果参数/水印/导入（开发侧完成）

- 依据：核对Android SettingsScreen/LocalPhotoEffectsOverlay参数、水印文字及导入回调，TransferViewModel的后台导入、PhotoFrameWatermarkStore的128KiB流/20MiB预算/内容摘要与原子私有副本，以及文字、图像摘要、收藏、解析缓存测试。iOS拨轮已是拖动期间局部预览、松手且值改变才提交；仅文字预览140ms防抖、500ms对比、紧凑34pt参数及原显隐过渡不改，不为减少运算而降低输入/渲染采样。
- 热点与改动：同一个PhotoLUTEditorState原来同时被工作台/设置外层、SettingsView、整个PhotoEffectsControls与LUT叶节点观察。现由不转发通知的PhotoLUTEditorLifetime维持StateObject的懒创建/独立生命周期，仅LUT控件与PhotoLUTChooserPresentation订阅读取、分类、选择状态。两个入口错误通知改按notice事件接收并跳过订阅初值，保留每次真实错误展示，不因旧通知重播提示；草稿变化仍更新页面和预览，打开/关闭选择窗不遗漏。
- LUTRequestController的空闲取消、相同pending/loading值不再发布，取消代次、ticket、定时器始终照常失效；PhotoLUTStore的相同选择、归一化强度、调整及role重读不再发布。PhotoEffectsStore仅在归一化后的设置/master值改变时发布。明确保留每次显式持久化与磁盘校验，不能用简单相等guard漏掉首次保存、旧键迁移、外部修改后的重新保存或缺失水印回退。
- 已有正确路径继续保留：水印导入通过PhotosPicker临时文件和detached worker执行有界复制/哈希/图片校验，store持有导入代次；导入成功即更新私有摘要、收藏与持久化，关闭弹窗后仍可完成。没有为离页省电取消用户正在导入的图片，也未引入全分辨率UIImage数组。像素身份缓存/渲染串行gate、文字防抖和三张水印解码缓存沿用既有实现，不冒称本轮新增。
- `/tmp/ztransfer-p16-parameter-performance-tests.log` **35/35、0失败/跳过、TEST SUCCEEDED、exit0**。包含120次空闲取消/相同LUT偏好零通知，两个作用域120次相同设置零通知但首次/显式重写仍落盘；真实host参数叶节点更新、父body不重算、选择窗非空与错误事件继续到达；LUT取消/超时、目录收藏/缓存、拨轮松手/取消/接受值渲染、紧凑控件高度、两入口模块及预览回归，水印原字节摘要/20MiB上限/2048解码/缓存/重复代次/损坏回退和偏好恢复。
- 补强实际接线：`/tmp/ztransfer-p16-popup-import-final.log` **7/7、0失败/跳过、TEST SUCCEEDED、exit0**，覆盖SettingsPopupOverlay实际挂载/重复打开/关闭/首次最终高度/横向低空间/effectsOnly非空，以及导入中退款、保存边界与两个作用域付费偏好保护。两组42项，包含与此前组重复的回归，不作为新独立功能数。P16本轮无失败重跑；git diff --check通过。
- 尚未验证PhotosPicker云端提供方真实等待、真机手指操作/FPS/CPU/温度；这些属于系统选取器P29及综合P34。未运行UI自动化、真机打包、安装、提交或推送。


### P20 曝光参数拨轮与数值列表（开发侧完成）

- Android依据：RemoteScreen.ParamTile、RemoteParameterPanel、RemoteExposureProgramTest/RemoteDiagnosticExposureTest；180ms吸附、150ms邻行淡显、900ms反向加载脉冲、18pt行距、±1.5原始越界/0.3阻尼/最多0.45行、AUTO 44×30触区及紧凑字号不变。拖动跨档立刻提交delta，松手/取消对齐最新真值；实际写入仍沿用160ms合并、旧事务排空和代次保护，未修改协议层。
- 原热点：同一body多次构造Configuration并扫描锚点，动画帧重复格式化最多5个数值；@Published整个wheel即使显示相同也通知，CADisplayLink强持有自身；菜单每次重新格式化/测宽全部枚举并用VStack创建所有行。现Configuration按输入复用，文本使用按属性失效的最多64项缓存；仅视觉快照改变才发布，显示时钟使用弱目标，静止/离页停止，离页后的迟到配置不重启；加载可见时仍连续脉冲。
- 菜单按属性/值域/显示scale持有一个标签与宽度索引，current和关闭变化复用；scale改变只重测宽而不重格式化。复用P15原生列表，新增rowSpacing默认2、参数专用0，原SwiftUI按钮与选中背景不变；只测量一个实际单行控件高度，按数量得到内容高度，不凭UIFont估算像素舍入。保留current前3项初始定位、用户滚动位置、横屏邻锚展开、选择立即写入及原Genie关闭。
- 编译过程如实保留：`/tmp/ztransfer-p20-parameters-performance-tests.log`测量闭包主线程声明失败，`performance-fixed.log`弱时钟目标缺MainActor，`performance-actor.log`非隔离deinit不能访问CADisplayLink，`parameters-clock-tests.log`新增测试误改let值域；均未执行测试，已按现有弱时钟模式/重建描述符修正。不是测试通过记录。
- 最终`/tmp/ztransfer-p20-parameters-verified.log`：**39/39、0失败/跳过、TEST SUCCEEDED、exit0**。120次相同配置/空闲帧零通知且只格式化5个行值；实际Tile宿主20次拖动父body不变、图像像素变化且仅跨档发1条指令/释放无重复；时钟加载、静止、离页迟到、重入与弱释放验证通过。10,000项菜单120次选择变化0次额外格式化/测宽，scale变化仅测宽；实际3,000项菜单定位2497、滚动后改current不跳动、缩为2项高度等于2个实测行高；截图`/tmp/ztransfer-p20-short-menu.png`已查看。既有公共列表3000项31行构建及六种像素检查、拨轮15项手势/动画与5项写入/Busy重试/迟到/不可读回归同时通过。
- P21已核对Android RemoteToolBar与布局测试，定位整工具栏观察帧状态、拖动坐标分别发布和Crossfade重建内容，尚未实施/验证，不能核销。累计11/34开发侧完成、剩余23项；未运行真机FPS/CPU/热状态或UI手势自动化，未真机打包、安装、提交、推送。


### P21 遥控工具栏与菜单编辑（开发侧完成）

- 依据：Android RemoteToolBar.kt完整手势/AnimatedToolSlot/Crossfade/ApplyRemoteToolLayout及RemoteToolLayoutTest，iOS实际RemoteView接线和既有持久化/拖动/布局/时序测试。保持位移弹簧520/.88/0.5物理像素阈值及双轴共享期限、120ms提起、180ms隐藏图标淡化、±1.3°/160ms线性往返与ordinal×55ms延迟、220ms编辑高度、160ms模式交叉淡化及中断1500临界弹簧；首帧直接在位置上，移动使用真实显示起点与目标槽命中，拖后无额外隐藏/写入，锁/旋转固定且照片/录像偏好独立。
- 原热点：整条RemoteConfiguredToolbar观察每帧的三份Published状态，重复构建/布局；拖动x/y分别发布且previousTranslation写入State；模式淡化每帧再次调用整栏content。现在动画模型由一个非观察时钟持有，仅对应slot的位移/缩放/角度/图标透明度发生变化才更新其modifier，高度另持独立发布；固定/隐藏/静止slot不随他人摇摆刷新。按槽集合复用迭代键，移除时丢弃旧表现对象，恢复从新基准位置初始化；拖动坐标为即时快照、每个输入仍直接更新动画，根只发布开始/结束及实际布局变化。
- Crossfade只发布模式层级成员变化，透明度使用叶节点观察；原关闭命中及出场层触摸屏蔽不变。工具栏/模式/相机菜单加载指示均改弱时钟目标，静止/离页停止，迟到布局不启动停用的编辑时钟；菜单未加载或选项pending才运行指示动画，原600ms双向淡化和1332/666ms弧线规则保留。菜单测量本不订阅这些帧，未额外改变短选项布局或相机控制器的取消/失败/重试。
- 首轮`/tmp/ztransfer-p21-toolbar-performance-tests.log`失败：实际命中测试2断言失败，另一个旧geometry测试因为仍从regular中强找已固定的LOCK而nil崩溃，xcode重启测试宿主；不能只摘重启后8通过的尾部当全组成功。`toolbar-hit-diagnostic.log`复现命中2断言，日志确认固定40ms时仍为首个透明电影帧，反转时自然直接回到静止照片层。测试改为确认电影层已实际可点击且两层都在，再立即反转并验证屏蔽；没有拉长生产动画或修改命中逻辑。`toolbar-live-clock-tests.log`8/8验证真实时钟推进/停止、反转命中通过。旧geometry测试按当前Android和RemoteView的manager+两固定项重写，去掉错误的LOCK属于regular假设及强解包。
- 最终`/tmp/ztransfer-p21-toolbar-final.log`：**49/49、0失败/跳过、TEST SUCCEEDED、exit0**，无崩溃重启。包括120次相同配置零通知、120帧摇摆仅可见活动slot发布而隐藏/固定/高度零发布、120次拖动只开始/结束2次根通知且全部坐标累积保留；真实host动画像素变化但父与内容body次数不变，实时显示时钟运行/停用/恢复/弱释放；真实完整工具栏重排出现中间坐标并最终移210pt，锁/旋转位置固定，隐藏后恢复；模式中断与真实出场屏蔽、移除/重新挂载初始化、全部布局/图标标签/菜单/独立偏好回归。前面8项含重复，不累加为额外独立项。
- git diff --check通过。累计12/34开发侧完成、剩余22项，接下来P22 Picture Control/NP3与P23遥控LUT列表/参数；仍无真机FPS/CPU/热状态结论，无UI手势自动化，未真机打包、安装、提交或推送。


### P22 Picture Control / NP3 面板（开发侧完成）

- 行为依据：Android RemotePictureControlPanel.kt、PictureControlPresetChooser.kt、PictureControlFolderState.kt，及SerialPresetQueueTest/PictureControlReplacementTest；9槽位、内置预设优先、目录元数据浏览、10秒超时、独立取消代次和共享读取队列、显式槽位写入/验证/激活/回滚不变。iOS现有原生List有限槽位/惰性预设行保留，本项不宣称此前延期的安卓转场样式已完成。
- 修正真实引用环：folder.onNotice原闭包捕获整张View及model，现只弱持有model，close同时释放notice回调。已接受的相机写入仍完成读回/回滚，未通过强行取消写入来释放对象。
- 元数据索引抽取为PresetCatalogIndex，照片LUT与NP3各自持有独立快照，分组/分类/标签按当前目录复用，未合并偏好或任务生命周期。相同扫描结果继续提交bookmark，但不重复发布files/folder/hasSnapshot；元数据变化使索引失效。相机刷新仍每次读取，只去掉相同overview/错误/预设/报告的重复发布。
- `/tmp/ztransfer-p22-np3-performance-tests.log`：**37/37、0失败/跳过、TEST SUCCEEDED、exit0**。包括10,000条目录120次索引/标签读取复用、10轮相同扫描零元数据发布/修改时间变化一次发布；120轮刷新仍121次相机读取且相同overview零发布、loading起止完整；真实UIHostingController挂载面板后释放host/model（不依赖先close）对象回收且迟到notice无副作用；写入校验/取消期间排空/回滚/协议/内置预设与照片LUT共用索引回归。
- 累计13/34开发侧完成、剩余21项。没有真机FPS/CPU/热状态结论，无UI手势自动化，未真机打包、安装、提交或推送。


### P23 遥控 LUT 列表与图像状态（开发侧完成）

- 行为依据：Android LutMonitorState.kt、RemoteLutPanel.kt、LutCategoryList.kt、RemoteScreen.kt的模式/帧可用/前后台/选目录环境；解析与首次GPU呈现共用10秒期限、候选首帧确认前保留原层、一次GPU重试及独立surface身份、两模式选择与故障抑制、同选项取消加载不重解析，全部保留。当前遥控LUT没有强度控件，强度项不适用，未添加安卓没有的参数。现有iOS原生菜单样式保留，本项不替代历史样式复刻验收。
- 主页面改由RemoteLUTMonitorLifetime持有状态，仅转发工具栏active有/无变化；目录扫描、加载标志、候选和true→true滤镜切换由RemoteLUTPanel与RemoteLUTImage直接观察。分类选择迁入面板自己的State，重开定位当前项、后台刷新保留用户分类；使用独立PresetCatalogIndex的分类和ID索引。文件规范化仍执行，但移至原IO队列，不在主线程交付回调重复排序；相同扫描保持索引，变化元数据仍触发更新/重载。
- 空闲invalidate/off/重复错误不再写相同Published值，但每次取消代次、磁盘权限/元数据检查、bookmark与显式选择持久化、实际错误onNotice事件均保留。未改变ParsedLUTCache的16项/8MiB界限与磁盘校验；未改P17的GPU纹理/末帧调度。
- `/tmp/ztransfer-p23-lut-performance-tests.log`：**35/35、0失败/跳过、TEST SUCCEEDED、exit0**。10K目录多次扫描索引复用/深层文件过滤/修改时间失效、分类保留及删除回退；120次空闲取消零通知且每次清除持久化、重复错误121次事件/一次状态；真实3K项面板定位2500、可见行<30、加载进度可见、扫描/失败后原位，父body不变；真实RemoteLUTImage的两次Metal提交均驱动候选转active，第二次不重算父body、旧层卸载/off清理、无观察引用环；原有18项状态/截止/取消/权限/同大小覆盖/重入与两模式、缓存/最后一帧实际渲染回归均通过。
- 模拟器Metal确认沿用提交完成fallback，不能冒充真机drawable已呈现或FPS。累计14/34开发侧完成、剩余20项；未真机打包、安装、提交或推送。


### P24 快门与录制（开发侧完成）

- 已对照Android RemoteScreen.kt/ShutterButton与RecControlBar.kt及现有手势、录制、宽度/提示模型测试。显示快照去重、局部计时观察与弱帧钟改动已写入，尚未核销。首轮`/tmp/ztransfer-p24-capture-performance-tests.log`因嵌套ClockTarget未声明MainActor、调用advance触发严格并发编译失败，测试未运行；已补显式隔离，继续专项。

- 第二轮`/tmp/ztransfer-p24-capture-actor-tests.log`为新增测试Controls默认计时对象在非隔离上下文初始化的编译错误，测试仍未执行；已给测试宿主显式MainActor。

- 第三轮`/tmp/ztransfer-p24-capture-isolated-tests.log`执行41项，40通过/1断言失败（0跳过）：新帧钟测试将既有Float比例运算结果60.000004与整数60做精确比较。实际时钟已停止、控件/生命周期/可播放文件测试通过；断言按已有尺寸测试加1e-5浮点精度，未修改动画公式或时序。真实控件截图`/tmp/ztransfer-p24-recording-controls.png`已查看，两个计时分别1:05/2:05、录制方块与暂停后继续图标正确。

- 最终实现：动画模型变成不发布的内部状态，仅等值可比较Display变化才发布；快门外壳与录制外壳持有控制器，只有绘制叶节点观察；弱CADisplayLink目标避免运行中引用环，离页停用后晚到配置不能重启，重新进入显式activate。Recorder的退出复位/提示1800ms重启保留。Camera/local各有独立秒数观察，只有对应文字订阅，不再每秒重建整页/胶囊；重复秒数不发布。原300ms长按、100/120/160ms快门、400/.5弹簧、保存标签60ms延迟、提示与timer渐变/物理像素位移不改。录制取帧、暂停/继续、停止归零、AVAssetWriter收尾/发布代码未修改。
- 最终补验`/tmp/ztransfer-p24-capture-final.log` **4/4、0失败/跳过、TEST SUCCEEDED、exit0**。前轮40/41中的唯一失败已覆盖，合计41个专项均有最终通过证据（补验与前轮3项重叠，非45独立项，前轮仍真实保留失败）。包括120次同配置/空闲/同时间帧零发布、真实帧钟推进/离页不重启/复用激活/弱释放；实际host快门和胶囊像素持续变化而父body稳定、两个秒数局部更新；生产1秒计时、暂停冻结/恢复、取消计时归零、最终文件可解码；原长按/取消/模式同步、录像失权并发退出/编码失败、16项真实编码器/积压/PTS/收尾回归。
- 累计15/34开发侧完成，剩余19项；真实手机CPU/FPS/热状态仍待P34，无UI手势自动化、无真机打包/安装/提交/推送。


### P25 遥控照片回看（开发侧完成）

- 行为依据：Android RemotePhotoReview.kt、RemoteReviewCatalogTest/RemoteReviewFrameGateTest与iOS对应模型/目录/预览加载代码。保留冻结的每卡handle流、12项分页/整时间组发布、JPEG优先/首handle稳定身份、空目录或错误只执行一次兼容EndLiveView、200ms间隔、离页排空已接受命令、需要时恢复取景；FHD当前优先/前后串行预读、五项图像保留窗和关闭取消未改。
- 底层监看只观察review active开关，分页/失败/重试交给回看面板自己观察；外层面板不再重复订阅只透传的传输队列，实际PhotoPreviewView的队列观察仍在。每个接受的目录结果仅构建一次首选文件/首handle映射/RAW标题索引，相同目录保留缓存；晚到JPEG仍替换IO文件而沿用capture页面身份。空值/相同hasMore/failed去重，取消代次、读取重试和关闭等待不变。
- 同一时间戳大组原每读一个handle都重新扫描pending全组的日期与名字；现增量缓存最长日期与同名候选，仅匹配对应名字，异常后pending/cursor/index一起保留，整组发布时一起清空。不改日期精度/缺失日期配对与歧义规则。
- `/tmp/ztransfer-p25-review-performance-tests.log` **18/18、0失败/跳过、TEST SUCCEEDED、exit0**。真实回看宿主的加载→错误→重试→预览像素改变但底层parent body不更新；120次快照/存储复用、下一页加载中保留快照、晚到JPEG的RAW标题/首handle/页面ID稳定、重开清快照/观察对象释放；1,000对同时间戳双卡照片在第500次元数据失败后完整重试、2,001个handle仅失败项重读一次，保留整组/顺序/下一组；现有关闭等待、兼容停止、断线丢弃、FrameGate取消和真实监看暂停帧/事件但保活回归通过。
- 通用PhotoPreviewView每次生成pages/初始化分组等共享开销继续归P08/P32审查，本项不冒称完成整套普通预览性能。运行日志出现既有link.slash系统符号不可用信息，登记给P02/P31对照处理；未改该无关图标。git diff --check通过。累计16/34开发侧完成、剩余18项，真机CPU/FPS/热状态仍待P34，无真机打包/安装/提交/推送。

### P26 Pro 购买/恢复/徽章（开发侧完成）

- 依据：Android SettingsScreen.ProBadgeButton的2600ms linear、-1w→+2w、全宽透明/金色0.65/透明光带与28/48pt尺寸；PurchaseDialog/LicenseDialogs及此前确认的苹果独立内购替代。完整核对iOS购买页、价格/套餐/对比表、购买/待批准/恢复/管理/取消、singleton监听与revision收敛；不改商品、价格、授权或交易完成顺序。
- 光带由TimelineView逐帧Canvas改为保留的CAGradientLayer位置动画。SwiftUI不再逐帧重绘；同输入/布局不重启动画，改宽重算同一绝对相位，暂停固定当前光带、恢复按既有wall-clock相位，离窗/卸载及非active场景停止动画。保留原按钮内容、背景、裁剪、命中区域和禁用透明度。
- 原生渐变首次对照失败：透明黑端点使光带发灰。改用同金色RGB、alpha=0端点后，3种尺寸×6个相位RGBA平均通道误差均≤0.25（原阈值未放宽）。真实host验证presentation匀速移动、父/子body不随帧更新、120次相同配置不改beginTime、暂停/改宽/离窗/重入/stop；导出光带截图已查看。
- StoreKit仅对空message、相同renewal、已存在/缺失的pending标记、无模拟权益时重复置nil去重；refresh、verified grant/expiry/finish/庆祝事件与持久化清除仍执行。120次相同空状态零通知，模拟永久覆盖/退出正确。价格仍正常加载，不以商品ID比较吞掉价格变化；应用级交易监听不随购买页隐藏停止。
- 早期日志保留：p26-badge-performance为新增测试隐式self编译失败；p26-badge-fixed为19/20，光带像素1项12条断言失败；p26-sheen-pixel-diagnostic重复确认透明黑插值问题。p26-gold-sheen为3/3；最终p26-p27-final再次覆盖这3项。权益模型17/17来自badge-fixed，P26共20项模型/组件均有最终通过证据。
- 本地StoreKit首轮错误使用CODE_SIGNING_ALLOWED=NO，被SKTestSession拒绝（Code3），卡初始化后中断exit75；signed版恢复模拟器get-task-allow仍受旧请求阻塞，同样中断exit75。夹具改先建立本地SKTestSession，再排空宿主监听，保留排空后才清交易/创建新store；重启专用模拟器但未擦数据。正式App代码/签名设置未改。
- p26-storekit-local-first为5/6，晚到年度批准瞬间权益短暂annual。用HEAD原始StoreKitPurchaseStore跑同组六项，p26-storekit-baseline同样5/6、同一断言失败，结束自动还原优化源并cmp确认一致。按既有D10“允许短暂同步、必须自动收敛”，补充等待App自己回lifetime，仍保留10秒期限，未额外调用refresh/sync或改变权益断言。`/tmp/ztransfer-p26-storekit-convergence-tests.log` **6/6、0失败/跳过、TEST SUCCEEDED、exit0**，实测0.168秒自动回lifetime；取消续订/退款仍保留永久、不重复庆祝。另覆盖普通待批准、拒绝重买、产品失败、付款取消/失败、显式恢复。这不是修复快照短暂不同步，也不核销R01其他恢复/账户范围或真实苹果沙盒。
- P26共26项模型/组件/本地StoreKit专项有最终通过证据，重跑重叠不累加。没有UI自动化或真机安装，不把本地模拟购买等同真实支付沙盒，不据此宣称设备功耗/FPS达标。

### P27 成功庆祝/烟花（开发侧完成）

- 依据：完整阅读Android Fireworks.kt、HomeScreen/FileListScreen顶层独立烟花所有权、HomeScreen.ConnectionSuccessOverlay及iOS庆祝/Root切页。每次点击独立seed、36主火花+18星尘、400ms上升/触感+1600ms爆炸、非命中、并发不合并；空集合无Timeline节点。既有随机参数、三角函数和粒子底色预计算保留。
- SettingsPopupOverlay仅用State持有引用，只有PremiumFireworksOverlay观察active；开始/结束不再重建设置与效果编辑器。不存在的finish不发布。36颗火花的三段历史时间/四次方扩散/笔宽每帧仅算3次，保留每颗粒子速度、重力、透明度与原运算顺序。离页结构化Task取消，不补发触感或保留页面，按已有所有权卸载释放。
- 连接成功效果现有独立绘制层、静态content边界、Root在1380ms后220ms收尾卸载已核对；未改既有620ms+760ms时序/路径。本机Android现为500ms延迟且premium尾部有额外淡出，旧测试名UsesAndroidTiming不能证明当前两端完全一致。本次按性能目标保留当前动画；连接页其他持续时钟、隐藏页归P02/P33，不声称完成视觉差异复刻。
- p26-p27-render-lifecycle为新增测试多余右括号编译失败；修正后的render-fixed为7/8（1项3条断言失败）：时间测试中的drawHierarchy同步等待模拟器Metal，造成触感测量延迟并错过两发结束间的轮询窗口。改为独立截图测试，用active事件序列验证每发独立结束；原400/1600ms与0.39–0.7秒触感断言不改，没有缩短动画或放宽像素阈值。
- 最终`/tmp/ztransfer-p26-p27-final-tests.log` **9/9、0失败/跳过、TEST SUCCEEDED、exit0**：P26徽章3项+P27六项。P27覆盖20次并发身份/120次重复finish零通知、真实host两发[1,2]→[2]→[]、触感每发一次/原时长、父body稳定、实际渲染像素变化、卸载取消触感与weak释放、两个seed×四阶段共8张固定帧逐像素完全一致、既有连接时序边界。截图导出到`/tmp/ztransfer-p26-p27-attachments/`，已查看原生光带、烟花上升/爆炸图。
- 累计18/34开发侧完成、剩余16。git diff --check通过。无真机CPU/FPS/热状态证据，无真机打包/安装/提交/推送，整体目标保持active。

### P28 诊断日志/开发面板（开发侧完成）

- 依据：完整核对Android LiveViewFocusDiagnostic及对应测试、RemoteScreen开发面板与DebugPhotoGenerationProbePanel。焦点采样200ms/60秒/80行/8标记、iOS既有6000 UTF8字节上限、显示状态最新值、独立录制/焦点/NP3报告和复制180000字节门控保留。Android当前焦点诊断类未接主界面，不据此删除iOS已有入口。
- 停止诊断后不再执行display/mark报告构造；运行时仅可见内容变化使报告缓存失效，样本计数仍完整保留至收尾。提取头信息仅复制最多1024字节，避免每次复制整张JPEG；不同布局/短头/非法偏移仍按原规则。报告改独立ObservableObject，面板局部观察；每个有效报告仍持久化，重复值不再刷新整个遥控页或写相同偏好。
- 报告行按输入缓存，复制大字符串在点击时惰性构造且取最新数据。开发面板复用原生可见行列表，保留字体/颜色/170pt高度；首次定位末行，最终行文本变化且原可见位置在新列表末三行内时跟随，上翻时保留锚点。原先把报告字符数当滚动行ID的错误一并消除。评级面板按打开/清空/探测完成刷新快照，LazyVStack保留滚动身份，复制仍读最新完整报告。
- 评级日志预算改增量字符计数并缓存快照，48行/8000字符/单行260字符与空白归一化、keepExisting/恢复/清空规则不改。传输诊断原本按chunk或5秒生成短JSON、后台串行写盘和2MiB轮换，没有逐包文件I/O，保持原实现。Root当前无独立诊断面板，修正清单入口。录像诊断仍排空已接受命令后退出；焦点离页停止，面板关闭不截断独立探测；没有改变相机调度或忙碌/失败处理。
- 首组`/tmp/ztransfer-p28-focus-report-tests.log` **5/5通过**；最终`/tmp/ztransfer-p28-diagnostic-list-tests.log` **15/15、0失败/跳过、TEST SUCCEEDED、exit0**，包含前组5项，不相加。覆盖120次空闲/相同输入零根通知、真实host30次报告局部更新与逐次持久化/父body稳定、8MiB JPEG与仅头报告相同、60秒计数与重启、240次Unicode日志和旧算法逐字对照、独立复制作用域；3002行定位/上翻追加保位/尾部跟随总计只构建62个行节点，现有6种行像素/高度和大列表回归也通过。RAW连续探测捕获保留与真实调度等待回归通过。
- git diff --check通过。未做UI自动化、真机滚动/CPU/FPS/热状态或外部剪贴板验收；评级私有面板事件接线为源码核对，未把模型测试宣称为每个按钮实机操作证据。累计19/34开发侧完成，剩余15项；下一组P29系统选取器/权限返回，目标保持active。

### P29 系统选取器/权限返回（开发侧完成）

- 已读Android SettingsScreen/OpenDocumentTree与TransferViewModel.setTransferDirUri、LocalPhotoEffectsOverlay/LocalPhotoBatchViewModel、PhotoEffectsBatch及对应测试、PhotoLutEditor取消与刷新规则。选目录在取得持久授权后发布；选图取消不清旧选择、生成/授权等待期间拒绝替换或重复开始、两worker与2400ms结果展示均保留。
- DirectoryAccessStore.setDirectory改后台申请scope/创建bookmark，主线程统一持久化并替换当前lease/URL。准备期间保留旧有效目录；新选择、clear或owner销毁取消过期提交，迟到结果释放自身授权，不碰在途下载/生成持有的旧lease。相同待处理URL合并为一个请求，同目录完成后再次选择仍重新校验授权/写bookmark，仅省掉相同URL通知。保持原拒绝/失败清空偏好行为；取消自身任务后清除pending，允许同目录重试。接口返回可等待Task，生产Settings不等待文件服务即可关闭系统选择窗，测试和调试队列夹具按需等待结果。
- DirectoryPicker采用每次呈现单次结果交付，取消后不接收迟到结果；更新representable时更新回调，避免使用旧闭包。未添加提示、按钮、尺寸或动画变化。LocalPhotoBatchViewModel在变更Published状态前拒绝空选择、忙碌重复请求与相同/过期进度，避免mutating方法内部guard已返回却触发整页发布；合法重选仍递增代次并取消旧2400ms计时，完成与失败计数不变。
- `/tmp/ztransfer-p29-directory-selection-tests.log` **13/13**：新目录6类边界中的前5项、真实队列旧目录下载/活跃与等待生成scope、销毁/启动清理及非法bookmark、USB权限阻塞/返回/拒绝3项。`/tmp/ztransfer-p29-picker-return-tests.log` **11/11**：含重复目录5项，新增空选/重复点击120次零通知、真实三张完成恰好3次进度+1次终态、授权拒绝及2400ms后保留错误、前后台屏幕持有、等待授权期间升级/退款后原快照实际渲染与保存、图片类型门控。
- 最后自查补请求自身取消后的重试清理，`/tmp/ztransfer-p29-directory-cancel-final.log` **9/9、0失败/跳过、TEST SUCCEEDED、exit0**：目录6项和在途scope3项。三组均TEST SUCCEEDED/exit0，共20个不同专项有最终通过证据，不把13+11+9当独立项数。慢provider在start和bookmark分别挂起时，主RunLoop仍响应；120次同待处理URL仅一次provider操作；新请求覆盖/clear/deinit后旧结果不落盘、成功start/stop成对，拒绝start不stop。
- 第一组结束时尚存：DirectoryAccessStore.init/restore同步解析/续期书签，PictureControlFolderState.init及scan成功回调同步resolve，PhotosPicker副本及其他权限接线未完。因此当时保持19/34，没有提前核销；后续完成如下。
- 启动恢复改后台解析/申请scope/续期与规范化路径。Root保留原初始化准入顺序：恢复成功或确认无效后才启动USB/Wi‑Fi发现、开放现有页面交互/辅助功能，期间现有连接页可正常绘制，无新增页面/提示。可取消等待者不取消应用持有的恢复；清理登记在URL发布/等待者放行前完成，后台清理未结束时实际队列仍等待。新目录或clear拦截旧恢复；启动期间新选择自身取消会重新恢复原保存书签，避免误变未配置。无效/拒绝移除旧bookmark，续期失败但原授权可用时保留旧bookmark与目录，沿用原规则。
- NP3初始化解析交给现有PresetIOQueue，关闭/换目录取消旧恢复ticket，迟到续期不覆盖新bookmark；只在恢复未定时暂缓目录入口，避免误触首次选择确认。扫描携带已经解析的root，不在主线程再次resolve；监看LUT同样复用PreparedFolder.root。原10秒扫描期限/失败保留目录/独立photo、monitor、NP3偏好不变。GPS/CoreLocation回调继续由主线程管理UI/授权，保持启用、AP阻止与恢复owner门控；麦克风异步授权返回后重新验证当前帧/工具状态，USB授权既有专属队列不变。
- PhotosPicker的FileRepresentation明确等待后台文件副本完成才返回，保持provider临时URL有效期；沿用原生copyItem及文件路径，不增加全量Data读入，也不替换为逐块软件复制。复制前/后取消检查，失败/取消删除自己独有的半成品；预览/导出/水印调用者继续负责成功副本的既有清理。水印导入仍由store代次接纳，可跨弹窗关闭完成，不修改已接受任务生命周期。
- `/tmp/ztransfer-p29-startup-restoration-tests.log` **25/25**：慢resolve/start/续期时MainRunLoop响应、等待者取消/共享恢复、覆盖/clear拒绝迟到结果、无效/拒绝/续期失败、清理注册先于准入、真实队列旧scope和清理屏障；NP3关闭weak释放/迟到续期不落盘、扫描复用root不再解析、目录/超时/大目录回归，监看LUT从真实目录到Metal及模式/后台恢复回归。
- `/tmp/ztransfer-p29-picker-lifetime-final.log` **16/16**：4MiB副本逐字相等/保留HEIC后缀/独立文件身份、provider被释放后仍有效、后台复制时主RunLoop响应、ENOSPC半成品清理与重试、复制前/中取消不伤原图；批次授权拒绝/独立权益快照与屏幕持有、实际录制授权返回时当前图像尺寸/无图拒绝、隐藏录制工具门控、USB授权恢复与GPS错误映射。最终补强`/tmp/ztransfer-p29-startup-replacement-final.log` **2/2**，实际挂起原恢复和新目录写书签，取消后再次恢复原目录，所有scope平衡。六组日志去重共**42个专项**有最终通过证据，均0失败/跳过、TEST SUCCEEDED/exit0；没有把各组简单累加。
- git diff --check通过，所有测试进程结束。未UI自动化、真实云端Provider/系统选择窗口/真实授权弹窗或设备性能测试，注入provider与文件操作证据不等同实际iCloud/真机验收；Root启动入口与按钮门控为源码接线/编译验证。累计20/34开发侧完成、剩余14项，未安装/提交/推送，整体目标active。

### P30 公共弹窗/阴影/主题（开发侧完成）

- 已读Android GeniePopupLayer/AnchorPopup、GlassButton阴影入口，以及iOS GeniePopupPanel/AndroidShadowView和祖先presentation/卸载测试。Genie已按每段转场单次capture、相同进度不重画、settle停表/释放纹理，gentle路径使用单live layer；不能再把已存在优化冒充本轮成果。初查后继续核对了主题材质、隐藏/尺寸变化和高频进度回调观察范围，结果见下文；后台综合门控保留在P33。
- 初查确认阴影虽跳过相同最终Geometry的网格/GPU工作，每个挂载host每帧仍独立获取presentation、遍历祖先、做3次坐标转换与窗口/屏幕查询，相同参数也setNeedsLayout。现同一帧按实际显示树共享祖先与窗口快照，仅保留弱model引用与值签名；静止、隐藏及零尺寸不再重复转换，参数变更才请求布局。祖先动画、暂停/移除、bounds滚动、重挂载/隐藏、窗口原点/密度、仿射与非仿射拒绝及渲染失败重试仍按原帧率和原算法；同步layout后下一帧强制校验，防止model提前而presentation尚未提交。没有停止全局采样或降低动画频率。
- 继续读取Android GlassButton颗粒/实体纹理、SkinTexture与CameraControlSkinTest，以及iOS玻璃/实体finish/纹理store和主题接线。实体纹理保持后台串行、相同请求共享、80个有限变体缓存；改为具体纹理叶节点收到完成结果，不再让整个缓存每新增一张图通知所有按钮。取消的旧主题结果仍缓存供后续使用，但不能覆盖新主题。毛玻璃路径只取决于行列数，缓存键由小数宽高改行列数，保留64组上限、原hash/颗粒位置/外层裁剪。原生液态玻璃、钢印/光场和按压时序不改，灯泡保持静态。
- Genie的12段有界绘制、相邻行复用、320/350ms与gentle260/220ms、单次capture/尺寸变化重取、输入门控、progress叶节点观察、settle释放纹理/停表均已核对；未将既有实现记成新增优化。补真实宿主验证两种转场结束后120次相同配置不产生额外进度，退场途中卸载后宿主weak释放。后台/整机渲染功耗仍归P33/P34。
- 初组`/tmp/ztransfer-p30-shadow-geometry-tests.log`11/11通过。`material-popup-tests.log`19项中18通过、1项10个断言失败（TEST FAILED/exit65）：实际首次挂载发现空Group没有节点启动.task；已保留透明占位，并把测试色块设为与生产相同256×256。修复后`material-mounted-fixed.log`3/3通过，不掩盖首次失败。
- 最终`/tmp/ztransfer-p30-final.log`：**27/27、0失败/跳过、TEST SUCCEEDED、exit0**，覆盖前述专项。100个阴影共享20级祖先只采样121层、120个稳定帧无变更；真实宿主稳定/隐藏/零尺寸跳过坐标转换，父动画保持采样，暂停、移除、恢复、重挂载正确；3组真实GPU裁剪输出和坐标/光源、weak释放回归通过。240次同颗粒网格的小数宽度不重建路径；真实纹理宿主主题切换、迟到拒绝、缓存恢复的RGB像素准确，生成无关纹理时两按钮及父body次数均不增加；既有纹理共享/失败重试、钢印与边缘像素、弹窗尺寸/反转回归通过。
- 累计21/34开发侧完成、剩余13项。未UI自动化、真机CPU/FPS/热状态测试、安装、提交或推送；计算次数和组件渲染不外推为真机性能结论。下一组P31已读公共拨轮/提示，发现长选项配置hash/已选索引在拖动中重复计算、提示动画重复Published及直接帧钟目标待处理，尚未核销。

### P31 公共拨轮、灯泡、提示与按钮（开发侧完成）

- 依据：Android ReleaseCommitWheel.kt/ReleaseCommitWheelTest、GlassButton按压/主题入口、FileListScreen底部提示的1800ms替换计时和弹簧400半高滑动，RemoteScreen提示160/200ms及中断spring400/1500；iOS按钮Controller/PressState、两类提示、灯泡/自适应帮助框及实际接线已核对。仍保留用户批准的450ms长按、静态灯泡/红点、原生液态玻璃；未改灯泡图标、颜色、尺寸或加入呼吸。
- 通用拨轮把当前项索引与手势配置缓存到当前不可变输入，配置hash仅首次遍历选项，拖动帧不重复查找/整组hash；哈希相同仍逐值比较，不以摘要代替身份。选项、行高、enabled/readOnly变化仍替换手势并拒绝旧代次，已选变化保留在途起点；>3项拖动、短列表点击、松手提交/拒绝回显、取消回退、长按触感与区域排他不改。只绘制原来的最多4行，无新增全列表预计算。
- 提示时钟保留内部完整动画状态，仅显示值改变时发布frame，弱目标避免控制器被CADisplayLink保活；相同visible/高度与静止frame不重复通知，stop/reentry规则保留。照片列表根只持有提示状态，底部提示仅透明度/位置叶节点观察帧，文字/测量/阴影不逐帧重建。重复同文案依然取消旧deadline并重新计时，只去掉不变text/visible通知；退场文字保留及旧任务失效规则不改。
- 液态玻璃圆角阴影保持原UIBezierPath和材质，仅bounds/圆角变更时重建path，样式变化即时应用，相同配置不重新设置图层值。现有按钮按压frame去重、弱帧钟/场景停用、100ms滚动触感延迟/90ms短按视觉及即时业务action保持，未替换识别器或改动点击时序。GPS的既有link.slash不可用符号留在P02/P03页面检查，不冒称本组修复。
- 验证历史：`p31-common-controls-tests.log`30项中29通过、1项2断言失败（TEST FAILED/exit65）。首个宿主断言把语义Color.red当纯红；改显式sRGB后`p31-hint-render.log`3项中2通过，另一个假设被截图证实：UIKit缩小截图会过滤矩形边缘，纯色内部为118×38而非120×40，不能用纯色像素数断言整个矩形尺寸；中间帧固定等待也不能充当实际帧证据。改为同屏幕尺度静态宿主逐RGBA对照，并观察真实中间帧；诊断`p31-hint-timing-diagnostic.log`1/1通过，模型显示原331ms/237ms弹簧未变，截图已查看。未改动画速度或放宽像素差阈值，旧失败日志保留。
- 最终`/tmp/ztransfer-p31-final.log` **38/38、0失败/跳过、TEST SUCCEEDED、exit0**。包含1万项120次索引/手势hash不再访问选项、故意碰撞/倒序仍失效、真实拨轮外部更新与重排像素；120次提示重复输入零无效发布、同文案120次仍延长deadline、两个活动时钟weak释放；真实帧最终RGBA与静态宿主完全一致、反转连续，父和内容body不变；完整生产提示测量后出现、消失、再次出现的截图一致，父body稳定；120次阴影配置/布局不重建路径且尺寸/圆角/样式变化正确。全部按钮/提示来源/取消/超时/两行布局回归通过。
- 收尾将缓存依赖的三个拨轮输入明确设为let，防止绕过初始化后修改导致缓存失配；`/tmp/ztransfer-p31-wheel-immutable-inputs.log` **4/4、0失败/跳过、TEST SUCCEEDED**，与上组重复，不累计为42个独立专项。git diff --check通过；全部测试结束，累计22/34开发侧完成、剩余12项。未UI自动化、真机FPS/CPU/热状态/真实物理手势验证、安装、提交或推送，整体目标active。

### P32 图片工作队列/缓存初查（未完成）

- 已开始检查PhotoPreviewView的后台ImageIO/直方图、PhotoEffectsPreviewCache共享工作与取消、PhotoThumbnailStore和解码缓存入口。预览/效果已有后台worker和串行gate，不沿用旧测试直接核销。PhotoThumbnailStore命中时touch会对memoryOrder执行removeAll，逐个失效也重复遍历；大目录缓存命中可能产生线性开销，待对照Android最终LruCache规则及现有测试后处理。CameraSession解码缓存/磁盘查询、并发预算/内存/原图质量及错误取消仍待完整核对。本组尚未修改或验证。

### P32 图片工作队列/缓存完成（2026-10-18）

- 对照Android CameraViewModel的字节预算LruCache、InflightThumb共享取图和解码、预填充仅落盘，以及BoundedAccessCache、LutColorPipeline与现有测试。iOS缩略图内存顺序改为字典加值类型双向链接：命中、移位、单项失效和逐项淘汰为常数时间，完整目录清理只遍历一次；保持原字节预算、超大条目先淘汰旧项再淘汰自身、内存/负缓存/磁盘/远程顺序和会话清理规则，不引入引用环。可见请求在同一Flight内共享解码/验证结果，超预算图片也只解码一次；后台预填充仍保留原始字节且不占解码缓存，失败/RAW重试/取消/磁盘写失败锁定不变。
- LUT逐像素循环之外只准备一次规范化参数及固定系数，去掉每像素三通道临时数组；保留Float计算顺序、强度混合/裁剪、ARGB透明度、四千像素取消检查和发布前检查。效果渲染器复用一个CIContext，继续关闭中间图缓存，原图转换和分块共享上下文；没有复用可变CIFilter。依据本机iPhoneSimulator27.1 SDK的CoreImage/CIContext.h第47–55行关于线程安全及上下文内部队列/内核开销的说明。
- 其余路径完成源码核对：CameraSession解码NSCache同步命中及缩略图actor后台处理、ImageIO预览/分析上限与解码前后取消、效果目标池3项/旋转源1项、共享任务取消所有权/全局串行预览gate；NP3预览最多2个像素worker、原图单worker和分块、生成原图预算64MiB余量、离线输出独立双worker，以及LUT缓存8MiB/16项/同键单读和水印3项缓存。已有后台实现不冒记为新增优化，未降低质量或改任务生命周期。页面直方图重复发布、预览pages计算等仍由P08处理，内存警告/后台综合生命周期归P33，不能由本项代替。
- `/tmp/ztransfer-p32-thumbnail-tests.log` **41/41、0失败/跳过、TEST SUCCEEDED、exit0**：独立旧数组策略对照2万次随机操作、5万条缓存2万次命中、实际4字节预算淘汰/磁盘恢复/清理/换机、24个同图请求只解码一次（含超预算及无效字节）、取消单个消费者不影响其余请求，以及现有磁盘/STA/RAW/坏缓存/写失败/裁边回归。5万条命中测试耗时日志仅为模拟器观察值，不外推真机吞吐。
- `/tmp/ztransfer-p32-lut-pixels-tests.log` 首轮编译失败：新增测试插入位置误占了现有RemoteLUTDisplayPerformanceTests的@MainActor，已恢复，日志保留。随后`/tmp/ztransfer-p32-lut-context-tests.log` **38项中37项通过，1项2个断言失败**：测试直接比较带行对齐填充的buffer（160与148字节stride），不是像素差异；LUT完整字节对照、全部方向/透明度、跨分块、预算拒绝和取消均已通过。改为明确检验预览转换路径并逐行比较全部有效RGBA，分块路径由已通过的原图测试覆盖。
- 最终`/tmp/ztransfer-p32-cache-final.log` **11/11、0失败/跳过、TEST SUCCEEDED、exit0**：3项LUT新专项全部通过（含118,342个颜色/参数/alpha组合、15组实际129×65位图逐像素相同、24路并发/8方向新旧CIContext像素一致），另补LUT容量/并发读失败重试/持有值被淘汰后继续有效3项及后台源准备/旋转/关闭取消5项。三组共有87个不同专项获得最终通过证据，重叠项不重复累加；首次失败未改写为全绿。
- git diff --check通过；测试进程全部结束。累计23/34开发侧完成、剩余11项；未UI自动化、真机FPS/CPU/内存峰值/热状态测量、安装、提交或推送。真机性能仍由P34验证，整体目标保持active。

### P01 根页面初查（未完成）

- 已读RootView的页面准入、连接庆祝交接和系统目录恢复门控。根页面持有并整体观察ConnectionViewModel、PhotoEffectsStore、GPSCoordinator和DirectoryAccessStore，实际直接使用的部分值仅是启用位/会话/恢复状态；录制保存提示也仍用StateObject。HomeWorkspacePagerIOS还观察整个GPS状态。下一步对照Android页面/发现暂停规则并核对各发布路径，拆出只影响局部的订阅，验证事件、目录恢复及庆祝/重连交接顺序；尚未修改或核销P01。

### P01 根页面/工作台完成（2026-10-18）

- 已完整对照Android HomeWorkspacePager的GPS enabled/releaseLocalWorkspace投影、MainActivity连接成功路由及HomeWorkspacePagerTest的进入/返回/发现暂停/GPS门控规则。iOS RootPresentationModel一次持有原服务和队列，只发布根页面实际读取的会话身份、展示模式、效果主开关、GPS开关、目录和恢复状态；Combine使用Published传入值，避免willSet时读取旧状态。原始模型仍完整发布详情，连接卡/GPS/编辑器继续各自观察，不合并业务状态或删除事件。
- HomeWorkspacePresentation只发布“GPS开启”“连接需要释放离线工作台”两位，原USB/Wi-Fi各阶段条件保持。Root录制保存提示改非观察持有，提示叶子仍按原时序更新。保留先恢复目录再启动发现、AP/GPS互斥、GPS允许从工作台返回、发现从发起进入到返回落稳全程暂停、设备重连替换队列provider和保留列表、首次连接620+760ms后220ms交接等原路径；没有为优化改变动画、手势、页面身份或生命周期。当前Android庆祝时序差异仍是此前P27明确保留的既有差异，本项不冒称两端时序完全一致。
- `/tmp/ztransfer-p01-root-projection-tests.log` **39/39、0失败/跳过、TEST SUCCEEDED、exit0**。新增4项覆盖：120次连接详情/GPS状态与频率/效果草稿变化，原GPS仍发布至少240次，但root与pager投影零通知；主开关/GPS/会话正确更新，投影weak释放；全部80种USB/Wi-Fi/是否有会话组合保持释放规则；真实RootView与HomeWorkspacePagerIOS宿主各120次跨运行循环更新body次数保持不变，相关开关仍更新；真实原生上下切页及GPS锁定/允许返回均通过；根等待目录期间持续绘制，卸载取消启动等待而目录独立恢复仍发布URL。其余包括20项连接、14项原生工作台阈值/嵌套滚动/拨轮命中/中断/尺寸变化及1项目录恢复清理准入回归。
- git diff --check通过，全部测试结束；没有运行UI自动化、真机安装/CPU/FPS/热状态验证、提交或推送。累计24/34开发侧完成、剩余10项。真实宿主计算次数只证明无效更新减少，不能替代P34真机流畅度和功耗验收。

### P02 连接页初查（未完成）

- ConnectionPage仍观察完整GPSCoordinator，但直接参与卡片暗化/进入工作台/提示关闭的值只有enabled；GPS详情应继续由GPSConnectionControl独立观察。连接卡和成功场景已有独立TimelineView及静态内容边界，需继续核对持续注意动画、后台/隐藏暂停和布局开销，不把既有优化重复算作成果。尚未修改或核销P02。


### P02 连接页完成（2026-10-18）

- 对照Android HomeScreen的2400ms连续注意相位/两卡偏移0.5/320ms强度过渡、GPS门控、CameraViewModel的StateFlow去重及HomeConnectionPresentation/ConnectionCardMaterial/StaConnectionIsolation测试；当前原生卡片持续动画不改，灯泡保持静态。ConnectionPage只订阅GPS开启位，详情仍由GPS控件观察。120轮BLE名称、频率、效果草稿更新时真实页面body稳定，GPS关闭后仍改变连接卡并恢复真实presentation缩放，未替换原生动画实现。
- 成功动效的两个Timeline阶段按现有620ms和1380ms绝对终点停钟；nil时静止、后台不逐帧更新，重入取消旧截止任务，前台继续绝对时序，保持同一content身份。仍保留Root之后220ms交接，不改变P27记录的Android当前时序差异。
- 连接reducer、模式选择、取消时的空字段、配对目录展示值只在变化时发布；处理事件的后续取消/重试代码仍执行，模式偏好仍每次显式选择写入。120次重复发现/授权/刷新零无效通知，121次取消清理全部执行；配对新增/清除即时发布，120次相同模式选择仍恢复被移除的持久化键。
- 最终`/tmp/ztransfer-p02-connection-final.log` **35/35、0失败/跳过、TEST SUCCEEDED、exit0**，包含22连接状态、2有限时钟、5原生注意、5真实根/连接/Home宿主及1烟花回归。先前`p02-connection-render-tests`为27过/1失败；attention-diagnostic/layer-lifetime/layer-removal/loop-timing/native-loop-scope/loop-delayed-isolation/finite-repeat-sentinel/keyframe-isolation/explicit-keytimes/ca-controls等诊断失败保留。根因是新增测试仅创建UIWindow(frame:)，没有绑定UIWindowScene，提交后系统移除所有CA动画；普通opacity/matrix对照也失败，而绑定场景的现有队列对照通过。修正测试场景后，原始生产动画直接通过。已撤回试验性循环参数、事务包装、关键帧时间和全部调试打印；不能把测试环境误报记为产品动画修复。
- git diff --check通过；模拟器宿主/状态证据不代替真机CPU、FPS及热状态，P34待验。未UI自动化、真机安装、提交或推送。累计25/34开发侧完成、剩余9项。

### P03 GPS面板初查（未完成）

- 已阅读Android GpsConnectionControl的detailVisibility挂载、独立倒计时、lastSent格式缓存、状态/坐标提示与持久化边界及GpsConnectionPresentationTest。iOS头部仍整体观察GPS；周期时钟包住整条控件行，重复创建DateFormatter；Genie原生宿主在目标为0时仍保留内容，需门控隐藏计时，保留会话已建立证据、坐标提示任务和BLE/GEO业务。尚未修改或核销P03。


### P03 GPS控件与面板完成（2026-10-18）

- 入口投影仅发布enabled和原状态颜色分组，坐标/设备名/更新频率/地点结果由原面板继续完整观察。没有合并GPS业务状态、减少BLE/GEO事件或取消后台连接。120次名称/频率变化不重建头部，启用/停用和颜色改变仍即时更新；投影及实际页面卸载释放通过。
- 一秒倒计时缩到独立GPSCountdownScope；最后写入时间/频率配置/长按停用按钮不再每秒随行重建。HH:mm:ss保留en_US_POSIX与上海时区，一个formatter按最后写入日期缓存结果，120次相同日期仅格式化一次。倒计时沿用一秒节奏，隐藏、后台、无最后写入时间时无周期任务；包含第一次0:00后停钟，新写入期限恢复，前台直接补到当前绝对时间，不变更GPS写入调度。
- 原生Genie仍保留同一面板和会话建立证据/地点提示状态，收起直到onSettled(0)才停止可见倒计时，并保留退出层级；关闭中重开不被旧完成回调停用。未改340/260ms弹层、长按、85/360ms写入闪光、复制/地点提示任务、错误与重试。原link.slash不可用符号仍是既有功能/样式缺口，本组未将其冒称修复或两端全视觉一致。
- `/tmp/ztransfer-p03-gps-presentation.log` 43项中42通过、1失败（头部断言观察到2个意外状态变化）；定位为测试CLLocationManager虽覆写authorizationStatus，仍把delegate注册给真实模拟器并异步回调权限状态。按已有GPS协议夹具隔离delegate后，`/tmp/ztransfer-p03-gps-fixture-final.log` **9/9、0失败/跳过、TEST SUCCEEDED、exit0**。前组34项GPS协议、5项原生动画已通过；两组共48个不同专项具备最终通过证据，重叠不累加。覆盖真实倒计时父body稳定、隐藏/后台/到期停钟及新期限恢复、28个入口状态映射、时间缓存，真实GPS面板开关/反转/原宿主身份与释放、根页面和连接/Home回归、GEO海拔/写入取消/重试及权限状态等。
- git diff --check通过，所有测试进程结束。未UI自动化、真机CPU/FPS/热状态验证、安装、提交或推送。累计26/34开发侧完成、剩余8项；P04初读，STA/AP提示和配对重置本身为静态有限内容，无持续时钟，需继续核对共享布局/退出和取消确认链路。


### P04 STA/AP提示和配对重置完成（2026-10-18）

- 已核对Android HomeScreen.TipsBubble/ResetStaPairingDialog、SettingsScreen.GpsResetPairingDialog及iOS对应入口、确认/取消/重置路径。两类提示/确认均为有限静态内容，无自身持续计时/目录扫描；TipPopupLayer按340/260ms退出卸载，打开锚点按原规则固定，真实视口变化才重定位。重置只经确认执行，关闭按钮/遮罩不清理数据，STA先取消连接并等待cleanup再清理配置。共享Genie静止/退出/中断释放仍由已优化宿主负责。
- AdaptiveTipPanel的隐藏测量副本是用于首帧同步确定滚动高度的有限文字，未参与持续动画帧计算；本轮不以删除它来冒险恢复曾出现的空白/跳高。现有文案/布局/提示退出规则保持，不将性能核对声明为全部两端视觉一致。
- 修复审核中看到的两个不存在的SF Symbol：GPS断开配对link.slash及重置对话框bluetooth，改为Android当前依赖material-icons-extended 1.5.4（BOM2023.10.01）中的LinkOff/Bluetooth原始24单位填充路径。已从本机依赖classes.jar读取PathBuilder指令并转换为同一坐标与贝塞尔，静态缓存Path供各次绘制复用，保留18/17尺寸与原按钮动作/配色。STA原有可绘制link+strike未改变。消除重复查找不存在符号及日志，补上P02/P03记录的图标缺口。
- `/tmp/ztransfer-p04-pairing-overlays.log` **33/33、0失败/跳过、TEST SUCCEEDED、exit0**，包括9项STA配对/迁移/清理身份存储，22连接状态和事件清理，真实GPS面板反转/释放与静止Genie无帧工作/关闭期间卸载释放。最终日志没有No symbol警告。没有新增低价值图标测试，矢量依据为实际Android依赖指令；未进行像素对齐验收或UI手势自动化。
- git diff --check通过，所有测试结束。累计27/34开发侧完成、剩余7；P05初读主设置：整列布局/高度反馈已保持稳定，目录提醒的有限动画状态仍放在整页，待移到目录卡片局部；未开始修改P05。未真机性能、安装、提交或推送。


### P05 主设置完成（2026-10-18）

- 对照Android SettingsScreen目录注意效果及TransferDirectoryAttentionTest：仅被阻止操作请求且未配置目录时提示，2轮180/280ms后220ms落到0.55，幅度0.008、FastOutSlowIn曲线原样保留。将有限动画状态和取消任务移入SettingsDirectoryAttentionCard；表单、目录文本/拨轮不再随提示阶段重建，重复启停和卸载取消不会被旧任务恢复。
- 滚动探针仅在bounces/alwaysBounceVertical值不同才写入，仍每次核对真实祖先，避免缓存失效导致移动后错误控制另一个滚动视图。继续保留一整列、整体Surface、同步测量后展开、presentationID拒绝过期高度、相同高度去重、缩放不反馈布局。没有引入新高度缓存或后台目录扫描，目录授权/选择由P29的后台流程负责。
- 主设置摘要只读已持有的轻量效果配置/本地化名字，未发现主设置绘制时读取LUT或文件；根的AppStorage变化对应现有配置控件和主题/语言，目录/效果/权益观察仍需支持摘要、图像导入完成和权益改变。保留当前观察和独立草稿语义，不增加可能漏掉语言/导入结果的缓存。效果预览/选择器专用开销已由P13/P15/P16处理，本项不重复算成果。
- `/tmp/ztransfer-p05-settings-attention.log` **7/7、0失败/跳过、TEST SUCCEEDED、exit0**。新生产目录卡片验证父body和内部控件body稳定、相同终点静止、取消/重启/卸载无迟到更新；4项实际SettingsPopupLayout及2项捕获/生命周期回归覆盖两个入口首帧最终高度、整列滚动、关闭后换尺寸重开、预览效果关闭回原宿主、描边/材质交接与释放。原阈值下mesh→live像素平均差0.209619/255。已导出并查看`/tmp/ztransfer-p05-settings-images/36BE0FFA-F894-4B54-8B6F-0D13159F9B4F.png`实际设置截图，标题/表单保持整体，灯泡静态。导出首次因xcresulttool自身TestReport缓存权限失败，经授权环境导出成功；不是测试/产品故障。
- git diff --check通过，测试全部结束。累计28/34开发侧完成、剩余6（P06–P09/P33/P34）。未UI自动化、真机性能、安装、提交或推送，整个目标保持active。

### P06 筛选弹窗初查（未完成）

- 已初读PhotoFilterPopupOverlay/PhotoFilterComponents和Android FileListScreen评级行：iOS评级repeatForever任务只按loading控制，弹层保留挂载时关闭/后台仍需核对停用；进度更新可能影响整弹窗，扩展名rows也重复Set/sort但规模有限。Android评级呼吸0.72→1、900ms/Reverse且仅启用并loading时创建，需要保持实际曲线和进度/长按日志/日期页切换规则。日期/评级相关测试已定位，尚未改P06。


### P06 筛选/日期/评级弹窗（开发侧完成）

- 已读Android FileListScreen.FilterOverlay、日期/评级控件与StorageSlotFilterTest/FilterButtonPaletteTest，iOS相关日期、持久化、评级及协议生命周期测试。即时提交、外部清空同步、日期局部草稿、逻辑卡槽、评级长按复制及提示灯静态不变。文件类型行在单次表单计算中只构造一份，几何偏好同值不再写State。
- PhotoRatingProgress只携带四个显示字段，字典变化不发布给弹窗；只有左侧评级控件观察，保留原状态文案/颜色与81×34触区。复用NativeAttentionHost运行0.72–1、900ms反向透明度动画，进度改变不重置相位，关闭/后台/卸载停止，日期页移除该节点。原iOS为linear，当前Android默认FastOutSlowIn；本轮按性能目标保留旧曲线，明确记录既有差异，不冒称完全视觉一致，卡片/GPS/灯泡不改。
- 真实完整弹窗测试发现“等退出结束再停用”会给已隐藏hosting树发送延迟更新，动画仍存活；改在Genie关闭捕获边界停用，关闭继续使用原快照与原时序，快速反转保持同一宿主。不是用延长等待放过失败。
- `/tmp/ztransfer-p06-filter-presentation.log`先因测试Input缺MainActor编译失败；修正后`filter-actor.log`32项中31过、1关闭生命周期失败。修复后`/tmp/ztransfer-p06-filter-hidden.log`3/3、0失败/跳过、TEST SUCCEEDED/exit0，失败专项及两项相邻专项全部通过；连同前组29项未受后续局部修改影响的回归，共32个不同专项有最终证据。覆盖完整弹窗120次进度parent body/尺寸不变、宿主反转/释放；真实CA呈现值变化且SwiftUI body不逐帧刷新、进度最新/同相位/触区命中/前后台/关闭恢复；120次字典单独变化零通知，以及17评级协议、7筛选日期、5既有原生动画。
- 测试全部结束，git diff --check通过。未运行UI自动化或真机FPS/CPU/温度/安装/提交。P07仍需收紧列表根对完整ratingScan的观察，以及无具体星级时反复筛选/分组排序，不能用本项核销列表整体性能。累计29/34开发侧完成、剩余P07–P09/P33/P34。


### P07 照片列表与分组（开发侧完成）

- Android依据：FileListScreen的activeRatingValues仅在具体星级生效、remember目录/筛选分组、buildThumbnailGridItems/滚动索引、日期折叠/相机移除/传输出队；已读BurstGridItemsTest、BurstGroupingTest及iOS扫描/回看/目录回归。原每个评级返回都会Published完整ratingScan并全目录排序；现完整扫描仍保留，进度只发P06投影，具体评级值改变才重算筛选；空列表的“没有匹配”句子独立观察加载状态，不丢失结束时文案。
- 日期排序、连拍识别、可选格式/日期只在可见目录内容改变时建立，筛选按已排序的分组保序应用；连拍筛选使用完整作用域的成员集合，不能按筛后子集重算。相同sections不再发布；显式筛选保存、扫描/缩略图优先级与评级生命周期操作保留。目录元数据/句柄替换、范围改变、传输退出仍正常重建，未改变同时间戳的相机枚举顺序或未知日期优先规则。
- PhotoListGridCache让实际网格与返回顶部索引共用一次连拍投影；目录、连拍映射/开关/展开、日期折叠/收起范围改变才失效，其余弹窗/动画状态复用。已有滚动坐标引用快照与缩略图后台工作保留，日期高度同值不写State。信号提醒帧只由按钮modifier观察，根页面只持有时钟；弱CADisplayLink目标、同值不发布、停稳自动停钟。120ms/原弹簧、触发重入和持续离线呼吸不改。
- `/tmp/ztransfer-p07-list-projection.log` **85/85、0失败/跳过、TEST SUCCEEDED/exit0**，无失败重跑。含真实120个评级依次返回/完整字典与进度更新、未选星级时根零额外发布/零额外筛选排序、选星级立即匹配；120组筛选与原始先过滤后排序逐项相同、相同目录复用及元数据/删除/加载范围失效；5000项120次复用和16种展开/折叠组合、实际按钮动画父/内容body稳定/重入/空闲零发布/所有者释放；35扫描批次、17评级、13滚动/入队、11原图索引及剩余分组/列表回归。测试计数包含前轮重复回归，不作为新增功能数。
- 未改变图片质量、请求并发、动画时序、取消重试或独立状态。测试全部结束，git diff --check通过；真机FPS/CPU/热状态仍由P34验收，未UI自动化/安装/提交。累计30/34开发侧完成，继续P08/P09/P33/P34。


### P08 照片预览与连拍（开发侧完成）

- Android依据：PhotoPreview.kt的remember预览集合、review列表更新、produceState直方图bitmap身份/FHD优先/后台计算、前后各两页保留/预热顺序与入队残影；PhotoPreviewItemsTest和既有几何/效果/取消测试已核对。列表与回看各自持有纯数据投影缓存，未合并页码、草稿、加载或任务生命周期。相同目录/连拍展开只建立一次打开集合，选中索引独立查询；当前分页及加载身份分别缓存，晚到JPEG保持review页ID而读取新handle。普通打开集合继续冻结；关闭清缓存。
- 删除未被使用却每次初始化都运行的连拍计算；展开初始集合改一次顺序追加，替代反向多次拼接整数组；列表平铺预览文件随sections发布缓存。所有缓存保留完整元数据、映射和展开输入，不能仅用文件数作为key。
- 直方图只由独立overlay观察，结果和fileID原子发布，同一已显示/待算UIImage复用计算，相同cached/clear不重复发布但取消代次始终生效；不同bitmap的同一handle仍重算。保持已有1920预览/分析采样、RGB共峰、FHD优先、关闭清理、180ms显隐、页面淡化/绘制位置。旧晚到测试注释说“新image”却复用同一UIImage，现改为真实不同对象以验证源替换；另补120次相同源去重测试，未删晚到/取消断言。
- 已审查并保留此前正确的局部缩放/捏合、裁切几何、队列拖动、560ms原生残影图层、有限窗口清理及后台解码。16ms等待是既有同一请求所有权等待，不是驱动UI；未降低有效帧率/质量或更改预热和相机请求调度。
- `/tmp/ztransfer-p08-preview-projection.log` **28/28、0失败/跳过、TEST SUCCEEDED/exit0**，无失败重跑。含3000项120次打开/分页复用、旧反向插入逐项对照、元数据及review晚JPEG身份、120同源待算/完成/缓存共享与取消、真实直方图叶子120更新/翻页淡化父body不变/卸载；生产PhotoPreviewView真实FHD及邻页请求顺序/缓存、保留窗口/取消、效果及7裁切/残影组件渲染。截图BEA8FE83.../tmp/ztransfer-inline-crop-controls.png已查看，透明框与原图/三行工具正常；不是新真机外观验收。
- 全部测试结束，git diff --check通过。累计31/34开发侧完成，剩余P09/P33/P34；未UI自动化、真机FPS/CPU/温度/安装/提交。P09当前确认裁切每次几何发布仍让整组比例按钮重建、空reset也发布，下一步局部化，尚未改。


### P09 裁切预览（开发侧完成）

- 依据：再次阅读Android CropEditor/CropEditorGeometry、PreviewCropPlacement及对应几何/比例/多点交互测试。保留原图位置与纹理、透明遮罩、三行比例按钮、120ms触摸网格/160ms选中/220ms恢复、400ms加载等待及错误重试；几何与JPEG裁切算法、MCU/像素边界完全不变。
- 裁切控件只观察比例/是否准备/是否有裁切的轻量投影，图框与手势单独观察实时几何，确认按钮仅观察准入位。每次有效几何计算后复用selection，同值/无效变换不发布；准备reset即使无显示变化也更新取消代次，但不重复发布空值。重试/关闭/迟到失败/重复确认/拒绝保留草稿规则保持。
- `/tmp/ztransfer-p09-crop-projection.log`先因新增测试CGPoint.nan类型歧义编译失败；显式CGFloat后`/tmp/ztransfer-p09-crop-typed.log` **40/40、0失败/跳过、TEST SUCCEEDED/exit0**。包含真实裁切组件120次几何变化/选择逐次精确一致、比例按钮和父body稳定、比例修改仍立即更新、零位移/无效输入/120空reset零发布/卸载释放，以及6手势几何、15准备/确认/取消/方向、6失败准入、2视口、2时序及7渲染/残影回归。
- 相同393×852受控画面的优化前后截图通过CoreGraphics转换sRGB RGBA逐字节比较，平均差 **0.0/255**；新图3FA1A7AD.../tmp/ztransfer-inline-crop-controls.png已查看。先尝试Python图像比较因本机无Pillow不可用，后改本地Swift/CoreGraphics只读分析，不属于产品测试失败。未宣称真机手势/FPS验收。
- 全部测试结束，git diff --check通过，累计32/34开发侧完成，剩余P33/P34。P33初查仍有若干有限动画时钟强持有自身，页面正常onDisappear已停止，但中断卸载路径仍应消除引用环；共享阴影为有意单例且成员弱引用，不能误当泄漏。未UI自动化/真机安装/提交。


### P33 生命周期、内存与共享发布（2026-10-18）

- 核对Android SettingsScreen、FileListScreen、LandscapeMonitorControls对应有限动画/中断模型，以及iOS页面卸载、scenePhase、服务停机和缓存所有权。共享弱目标ZTransferDisplayLink替换8处直接self目标（6个视图模型时钟、Genie宿主、队列滑动宿主）；页面中断卸载不必等下一帧才能释放owner，遗留链接下一帧自行invalidate。原run-loop、帧时间源、时长/弹簧/曲线、重入和停止顺序保持。
- 效果开关、遥控dock、队列返回按钮在输入不变时不写Published；判断后仍执行排程，避免stop后同一目标无法恢复。卡片色彩只发布变化的ARGB值，挂载重置与实际颜色终点保留。测试需要直接访问的三种内部时钟改为模块可见，无对外API或业务状态合并。
- 共享阴影时钟是有意存在的单例，成员为weak且空集合停钟，不误判为引用环；其余已使用弱target的时钟不重复重写。Root的USB前后台、Remote曝光分析/LUT/方向候选门控、遥控退出等待在途PTP和录制收尾、StoreKit应用级更新监听、ScreenAwake多owner规则均保留。没有因页面离开取消应继续的传输或商店任务。
- 缓存核对：解码NSCache按物理内存1/8预算且有原生淘汰；缩略图压缩数据LRU有预算、会话替换/扫描重置清理，订阅离开仅移除自身；预览按owner关闭、效果池3项与LUT/水印预算已由P32专项验证。本项未新增内存警告功能或声称模拟了真实系统内存压力，峰值/热状态仍归P34。
- Android当前master switch几何/颜色与旧iOS实现尚有历史差异；旧测试名AndroidGeometry不证明最新端间像素一致。本轮仅改变通知/引用生命周期，保留原视觉和180ms时序，不以性能优化名义扩大样式改动。
- `/tmp/ztransfer-p33-clock-lifecycle.log` **44/44通过、0失败/跳过、TEST SUCCEEDED、exit0**：新增3项覆盖6类时钟×20次活跃释放、120次同值不通知、停后同目标恢复/终点、ARGB量化去重；原水平仪6、开关2、遥控布局11、滑动8、队列真实渲染5、弹窗寿命1、常亮2、Genie/响应模型4、后台恢复与在途停机2共同回归。无UI自动化。
- 首次沙箱内devicectl只读查询CoreDeviceService超时；主机查询成功，但Instruments初始显示手机offline。用户随后明确批准本轮构建/覆盖安装/性能验证并回复已接数据线。P34进入真机节点，不能提前标完成。


### P34 真机综合验证：进行中（2026-10-18）

- 用户明确授权本轮构建、覆盖安装和真机性能验证，并已把iPhone 15 Plus连接电脑；不卸载、不提交、不运行UI自动化。
- `IOS_DEVICE_ID=00008120-000A08110CF1A01E IOS_SKIP_SIMULATOR=1 bash ios/dist-debug-ios/d-b-ios.command`：`/tmp/ztransfer-p34-device-delivery.log`为BUILD SUCCEEDED、1安装成功/0失败、exit0，总57秒。产物`ios/dist-debug-ios/ZTransfer-ios-debug-1.97-20261018-200138.ipa`及配对.app；签名/ZIP校验成功，旧debug包由脚本清理。安装目录70031413-93D4-40B7-AE79-51BDC62D5E7A，普通无参数启动，PID905。
- 安装前Activity Monitor录制遇设备断连，实际仅0.777809秒（`p34-before-activity.trace`），无可用前后对照。初次导出新trace时它仍在保存，Document Missing Template Error；等待录制进程exit0后完整导出成功。旧idevicescreenshot不支持当前服务，改用本机devicectl capture screenshot，截图`/tmp/ztransfer-p34-after-idle.png`已查看，确认前台连接页/STA/GPS未展开/静态灯泡正常；截图不是持续动画或物理操作验收。
- `/tmp/ztransfer-p34-after-idle.trace`：Activity Monitor，真实iPhone15 Plus/iOS27.0.1，20.727370秒，按时间上限正常结束。activity-monitor-process-live有17个ZTransfer PID905区间，首段CPU未知不计；其余按duration加权CPU **0.022672%单核**，峰值0.374842%，physical footprint **46.3924–46.4081MiB**。原始XML与汇总在同名前缀`-process.xml`/`-summary.json`。不外推为GPU/电池功耗，也不声称相对本轮优化前提升。
- 同轮thermal-state全程**Serious**，未人为诱导；当前热机条件限制后续FPS结论，不能说整机发热已验收。继续录制手动模拟目录滚动/预览/效果弹窗，真实大卡目录/传输/相机取景仍待独立覆盖，不提前核销P34。

- 用户随后完成模拟目录的手动操作，并明确反馈“丝滑多了，体感上……这个先过”，当前列表/预览/弹窗操作体验按用户确认记录通过；不扩展为真实相机、大目录、传输或遥控录制已通过。用户计划稍后接相机再试，本轮不继续要求重复模拟操作。
- 动画性能录制仍无有效数据：`p34-interactions.log`（Animation Hitches+Activity Monitor系统采样）等待设备超时exit13；`p34-hitches-retry.log`按PID905附加失败exit21（Cannot find process）；`p34-hitches-system.log`单独Animation Hitches系统采样等待设备超时exit13。同期devicectl进程/截图正常，DDI可用/开发者模式开启/有线tunnel connected；不能把录制失败归咎于应用卡顿，也不能声称已测FPS或hitch率。全部录制进程结束。
- 下一步实机场景：首次目录加载+快速滚动；传输中同时滚动/预览/效果参数；裁切入队成片与取消重试；断连重连/前后台恢复；遥控取景/拍摄/录制收尾与持续使用热状态。33/34不变，P34部分通过，未提交/推送。


#### P34 剩余验收边界与版本留档

用户准备接真实相机后，保持本轮已安装版本稳定。以下项目按实际反馈逐项更新，不因模拟照片体感通过而自动通过：

| 验证路径 | 本轮已有证据 | 尚需真实负载确认 |
|---|---|---|
| 连接页持续动画/空闲资源 | 真机20.727秒CPU/内存，截图正常 | 持续使用后的温度恢复、真实连接/重连 |
| 列表/预览/效果弹窗 | 用户模拟照片体感明确通过；模型/组件专项 | 实际大目录与不同格式照片；传输中操作 |
| 效果/裁切/保存 | 取消、缓存、几何与像素专项 | 实际成片方向/裁切/效果、文件可正常打开 |
| 队列/进度/速度/数量 | 状态模型、局部渲染与右缘专项 | 实际传输期间动画和吞吐；失败重试/断连恢复 |
| 遥控/取景/参数/录制/回看 | 协议与呈现专项 | 相机连续帧下交互、录制收尾/保存、回看恢复 |
| 前后台/系统目录与选图 | 生命周期/授权/在途取消专项 | 真机后台返回、实际文件提供方及相机任务恢复 |
| 全局热状态/内存/FPS | 空闲CPU/内存可用；本轮Serious热状态 | 长时间真实负载；有效动画性能采样和对照仍缺失 |

2026-10-18本次收尾只读核对：生产源码文件没有晚于已安装构建的修改；末组44/44日志和签名打包安装日志仍可读取，git diff --check通过。为后续崩溃/卡顿符号化记录本地产物两个UUID：启动程序`A1AD4FB3-DC73-38DE-8701-2C2A55D7F263`；实际Debug代码`ZTransfer.debug.dylib`为`773A8E0A-5161-3855-9228-D5C854822D38`，SHA-256 `51785866990cf1dbd805ad30779472b855b746d28ce9423720d7d78d1015944c`。这些是本地已交付产物身份，安装成功证据见上方日志，不冒称读取了设备二进制。没有新增构建、安装、采样、产品改动、提交或推送；待用户真实相机试用反馈。

### P17/P34 USB 监看卡顿复查（2026-10-18，未验收）

- 用户反馈 USB、HD/LUT/分析均关闭时画面卡顿但读数约46fps，要求所有模式都检查。截图 `/tmp/ztransfer-monitor-stutter.png` 确认44.0fps；快门1/25仅为截图信息，无因果证据，不归因为相机设置，也不要求用户改快门后才继续处理。
- Android `RemoteScreen.kt` 785–835、1023–1037、1125–1192：后台 `BitmapFactory.decodeByteArray` 生成实际像素，CONFLATED保留最新待处理帧；1秒FPS窗口统计接收间隔。iOS同样统计接收，所以原读数不能作屏幕呈现帧率证据。本轮不靠修改这个数值来宣称流畅度修复。Android `RemoteLiveViewSchedulingTest` 的USB稳定前不放开属性轮询/首帧暖机/忙响应规则保留。
- 确认显示路径隐患：后台调用 `UIImage(data:)` 不保证JPEG已经解压，ImageIO SDK 明确 `ShouldCacheImmediately` 默认false、在render时解码。现在所有模式共享的后台worker用ImageIO立即解压并缓存，保持完整尺寸、色彩空间和8种EXIF方向，仍使用最新帧单槽和原代次/分析门控/录制时间戳；普通模式省去无缓存分析时的第二次JPEG尺寸读取，每帧工作放在autoreleasepool中释放临时对象。
- `/tmp/ztransfer-monitor-decode-tests.log`：54/54、0失败/跳过、TEST SUCCEEDED/exit0。含新增sRGB/P3×8方向逐像素对照、640×424/1280×720/1920×1080尺寸与像素、坏数据拒绝；原分析缓存/更换/取消、页面帧隔离、反挤压几何、LUT颜色/候选与失败回退回归。
- 同一模拟器20次构建+首次CGContext绘制对照：640×424首次绘制3.587→0.591ms，1920×1080为25.748→5.691ms；相应后台准备3.785/24.732ms。只是显示阶段工作迁移的组件证据，非手机性能或屏幕FPS。图像输入和首次绘制相同，没有降低质量/尺寸或复用同一已解压实例来取巧。
- 补改普通模式尺寸读取门控/autoreleasepool后 `/tmp/ztransfer-monitor-recording-tests.log`：16/16、0失败/跳过、TEST SUCCEEDED/exit0，12项分析回归与4项可播放录制、反挤压/源尺寸改变、阻塞只保留最新及失败后恢复验证。两组共58个不同测试，不把重复12项累加。
- 原手机Time Profiler尝试被设备断连终止，trace有效时长仅0.925秒，不能当作有效热点/帧率基线。当前正在构建覆盖安装修复版，仍需真实USB、HD/LUT/分析组合复测。P17和P34不核销；无UI自动化、卸载、提交或推送。

#### 同轮继续：确认布局观察位置错误，修复待真机复测

- 第一个仅提前解码的版本202427构建/安装成功（27秒），用户反馈“基本没有改善”。因此不将解码迁移当作这次卡顿已解决，也不把用户的卡顿归因于快门或主观感受。
- 按生产结构复现：`RemoteFrameScope { GeometryReader { 读取frameImage/元数据 } }` 把订阅置于几何边界外，几何尺寸不变时内部closure可被SwiftUI复用，收到新图却不更新画面。`/tmp/ztransfer-monitor-geometry-before.log`中连续提交16帧，界面停在第6帧；父body零更新，帧内容仅5次更新，3条断言失败、TEST FAILED/exit65。
- 修正为生产共用 `RemoteViewfinderFrameScope`：`GeometryReader { RemoteFrameScope { content(size) } }`，在稳定几何之内直接观察帧更新。完整图像、LUT输入、伪色/斑马/波形、对焦元数据和FPS文字一起读取最新状态；外围工具栏仍不订阅每帧。不重建取景身份/viewport，不改手势、布局尺寸、分析/录制时序或接收FPS口径。
- 函数抽取首轮缺少显式return而编译失败（`monitor-geometry-after.log`），已修复。`/tmp/ztransfer-monitor-geometry-fixed.log`：26/26、0失败/跳过、TEST SUCCEEDED/exit0，连续15次变化全到达内容，最终第16帧；真实宿主经缩放组件的第二层GeometryReader仍显示最新绿色源图（至少60,000对应像素），父body仍0变化。包含焦点颜色、视口几何及LUT候选/失败/生命周期回归。
- `/tmp/ztransfer-monitor-production-pixels.log`：1/1、0失败/跳过、TEST SUCCEEDED/exit0。完整生产 `RemoteView` 接入USB模拟相机，实际经过750ms暖机/取帧/后台解码/状态发布/双重布局/屏幕宿主，分别检查640×424普通与1920×1080+RGB波形/直方图。各连续6次只变JPEG颜色（不改参数、布局或方向），每次都显示对应的新颜色像素；移除页面后会话正常退出。不是UI手势自动化，也不是手机FPS测量。
- 新修复正在集中构建覆盖安装；P17/P34保持未验收。前一个58项加本轮26项/整页1项存在交叠，不把总执行次数冒称独立任务数。

#### P17 本次修复验收（2026-10-18）

- 第二版 `ZTransfer-ios-debug-1.97-20261018-203200.app/.ipa` 由d-b-ios脚本构建签名/打包并通过局域网覆盖安装同一iPhone15 Plus，51秒、BUILD SUCCEEDED、1安装成功/0失败，普通无参数启动；安装目录B4AD6AE7-8672-4530-A270-0CF047EB8A2A。日志 `/tmp/ztransfer-monitor-observation-device-build.log`，脚本仅按规则清理前一对Debug包，用户数据保留。
- 用户收到“重新进入USB监看并平移，再开HD或波形”的复测请求后明确回复“这次流畅了”。记录为本次USB监看可感知卡顿通过；用户没有逐项列出每个组合/长时温度，不据此声称全模式数值FPS、所有机型或热状态均验收。
- 根因有旧结构失败、新结构像素与整页测试通过、真实手机反馈三类证据。P17恢复开发侧完成；累计33/34，P34仍保留其他场景。FPS仍是接收统计，不宣传为准确屏幕呈现测量。
- 本轮各阶段共61个不同专项有通过记录（重复执行不叠加），没有运行UI手势自动化；没有提交或推送。所有测试/构建进程已结束，未遗留临时诊断探针。长期全应用goal暂停状态不由本次局部修复修改。
