# iOS 并行50子项审计（2026-09-08）

## 结论

先提交检查点 `8503823`（`research/ios`，46文件、4526新增/167删除），再由主agent和3个并行agent审计。未推送。审计后的修复、测试与文档仍在工作区。

**50个子项源码已落地，不等于剩余50个主任务完成，更不等于完整iOS版已1:1验收。** 发现4个具体实现问题和1组测试覆盖盲区，已修源码并补样本。Windows验证通过，Apple验证未运行。

Android app、shared/androidMain、shared/jvmMain、版本/Gradle配置及dist/dist-debug脚本与ca00994无差异；共享EXIF旧入口及原UI主体受回归/源码守卫保护。本次检查未发现Android回归，不能由此保证所有设备运行绝对无差异。

## 本次实际执行

只启动一轮Gradle，没有同时启动多个构建；没有生成或交付APK，没有执行Xcode/Swift编译。

```text
gradlew.bat :shared:compileCommonMainKotlinMetadata :shared:testDebugUnitTest
  :app:testDebugUnitTest :app:compileDebugKotlin :shared:lintDebug :app:lintDebug
  --no-daemon --console=plain
BUILD SUCCESSFUL in 7m 19s
86 actionable tasks: 35 executed, 51 up-to-date
```

上面为便于阅读换行，实际在同一Gradle命令执行。主机Java17/Android SDK使用本机已有路径。

| 检查 | 实际结果 | 不覆盖什么 |
|---|---|---|
| shared单元测试 | 709项，0失败/错误/跳过 | Swift actor与Apple系统行为 |
| Android app单元测试 | 317项，0失败/错误/跳过 | 三种连接方式真实设备回归 |
| common metadata / Android编译 | 通过 | Kotlin/Native导出、Swift类型检查 |
| shared / app Debug Lint | 均0错误；shared无issue，app179个Warning/11个Hint | 警告不等于已修完；Release打包未运行 |
| Python源码/工具检查 | 最终314项通过；首轮4项失败已修 | 不冒充iOS代码运行 |
| 原共享UI迁移守卫 | 原主体/适配接线逐项通过 | 像素、手势和重组性能 |
| Xcode工程结构 | 42 App Swift、8 XCTest文件引用唯一；393个测试方法存在 | 393项全部未在Mac执行 |
| Git范围/空白检查 | Android宿主及打包脚本无差异，diff检查通过 | 不是功能绝对不变的数学证明 |

本次Gradle覆盖最终Kotlin源码：审计后的生产修复仅在Swift文件，没有在构建途中修改shared或Android生产代码，故未再开第二轮相同Windows构建。

## 50子项逐组追踪

逐项执行点仍在[iOS并行实现批次](./iOS并行实现批次.md)，下表将P01—P50完整分组、不增加分母。

| 子项 | 当前实现/证据 | 实现边界及未验部分 |
|---|---|---|
| P01—P08 | CameraCatalog / WiFi / PreviewStore；删除、属性、卡槽、缺口、准入和代次；25项CatalogEventReconciliationTests源码 | 完整/失败/迟到/关闭、删除打断补扫及存活副卡样本已写，真实Swift竞态待Mac |
| P09—P14 | TransferPreferencesStore、CameraAutomaticTransferCoordinator、共享设置和现有queue；16项AutomaticTransferTests源码、6项共享设置测试已执行 | 单一队列/真实目标准入；W06整条传输反馈闭环未完 |
| P15—P20 | opt-in PreviewExifSupplement与现有有界reader；16项common测试已执行、9项ExifCompatibilityTests源码 | 默认read/readHeader行为未改；MakerNote/嵌入JPEG/ImageIO全部差异尚未补齐 |
| P21—P30 | NativeConnectionHome、CameraWorkspace、同一会话所有者、已有文件/队列页；13项common首页测试已执行、11项Workspace XCTest源码 | Release有真实入口，不必进Debug；首页模式记忆、繁中、完整原布局/配对反馈仍缺，不宣称完整1:1 |
| P31—P40 | Bonjour具体服务选择、地址历史/档案/明确恢复；3项common地址测试已执行、16项DiscoveryProfile XCTest源码 | 无自动切端点/扫网段；实网发现、路由与身份恢复产品体验仍须验收 |
| P41—P50 | 原片读取结束复核、会话隔离、ImageIO释放/尺寸表示/取消；17项MediaPreviewCompatibilityTests源码 | RGBA四通道和8方向像素样本已补；实际色彩、内存峰值及系统解码需Mac |

393项XCTest = 原有299项 + 目录25 + 自动16 + EXIF9 + Workspace11 + Discovery16 + Media17。17项既有Kotlin/Native图片测试亦仍待Mac，不计入Windows已运行数量。

## 审计修正

1. **删除打断补扫导致新照片漏自动通知**：稳定轻量核对后补发保留候选；使用原发布版本/取消门控，不增加一轮metadata IO。
2. **待补传照片主卡删除、副卡仍在却丢资格**：资格按现有共享逻辑身份交给存活别名、只消费一次；同名不同大小不能误继承。以上两项合计新增6条确定性目录样本。
3. **关闭自动传输时偏好保存失败仍可能入队**：先取消未接纳工作并锁定当前会话关闭，再保存；失败继续提示，只有成功显式开启解除。新增2条held-admission/损坏偏好样本。
4. **首次浏览重复完整扫描**：仅复用同连接、ready、事件版本相同的完整稳定目录；仍初始化本地原片索引，手动刷新始终扫描。新增5条真实页面/计数IO样本，包含失效缓存和扫描token回收。
5. **像素测试抽样漏绿色/alpha，方向3—8仅查尺寸**：改为按像素检查RGBA全部通道，新增8方向实际像素位置检查。仅改测试，不改Android或图片旋转策略。

首轮4项Python失败中：一项旧阶段“尚无自动开关”假设改用精确基线逆转换；一项变异目标已消失导致空替换，增加目标存在断言；一项重复逆转换改读原始源码；一项XCT与独立await同一行触发保守正则，拆行。没有删除旧规则或放宽为任意代码跳过；当前接线另有明确守卫。

## 主任务计分与真实剩余

按[剩余任务表](./iOS剩余任务进度表.md)的Windows门槛，W03-B +0.5、W04 +1、W05 +1；W01—W05共5主项/5分，收尾10.0%，延续历史刻度总计划82.0%。Mac仍0/12。Apple样本已写是Windows交付条件，不代表样本已运行；Mac发现问题必须重开对应任务。

本批不能关闭的代表性缺口：

- W06：连拍→扫描/事件→原片发布→徽标/飞入等完整反馈与失败闭环。
- W07/W08：模式记忆、繁中、完整首页/配对反馈、热点与权限产品引导。
- W09/W10：实网接口/路由、档案恢复全链路、既有身份JSON与地址元数据的存储职责验收；未擅自迁Keychain。
- W18/W19：完整RAW元数据来源优先级、真实ImageIO颜色/方向/大图表现。
- 其余45个未完成主任务按原表继续，不因本次通过一个全量测试就顺带完成。
- Xcode/Kotlin Native/Swift编译、系统目录授权、AP/STA真机传图和Apple内存指标仍必须Mac/iPhone验证。

照片效果、会员支付、遥控监看、GPS发送继续暂缓；没有趁本轮审计恢复这些范围。
