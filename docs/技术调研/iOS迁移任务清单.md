# iOS 迁移任务清单

> 给后续实现过程使用的轻量执行账本。架构结论见 [iOS版本1比1复刻方案](./iOS版本1比1复刻方案.md)。

## 当前状态

- 分支：`research/ios`
- 产品版本：`1.81`（Android `versionCode` / iOS build 均为 `54`）
- 当前阶段：通用代码盘点完成，开始按原子批次迁移纯 Kotlin 逻辑
- 下一项：`P01` PTP 常量与响应文本的平台解耦
- Mac 最近检查点：`M01`，在第一批真实共享协议完成后执行

状态只使用：`DONE`、`NEXT`、`TODO`、`MAC`、`BLOCKED`。

## 完成规则

一个迁移任务只有同时满足以下条件才能标记 `DONE`：

1. 代码迁入 `commonMain`，不是复制一份。
2. Android 已改为使用迁入后的实现，原包名/API 尽量保持不变。
3. 共享逻辑及对应测试迁入 `commonTest`，固定输入输出不变。
4. Android 相关测试、Lint 和标准 Debug 打包按风险完成验证。
5. 涉及 Native/Apple API 时，在 Mac 补齐 Kotlin/Native、模拟器或真机证据。
6. 本文状态和“验证记录”同步更新。

## 任务

### 0. 基础设施

| ID | 状态 | 任务 | 完成点 |
|---|---|---|---|
| F01 | DONE | Android 1.81 基线、方案和迁移分支 | 版本、方案、分支已建立 |
| F02 | DONE | 建立单一 `shared` KMP 模块 | Android 已依赖 shared；`commonMain/commonTest` 可用 |
| F03 | DONE | 建立 iOS 工程入口 | 真机/M1 模拟器 target、framework、Xcode 脚本和 Shared Scheme 已配置 |
| F04 | DONE | Windows 侧 Android 安全验收 | 测试、Lint、Debug APK、真机安装启动通过 |
| M01 | MAC | 首次 Mac 工程链路验收 | `xcodebuild` 成功，Swift 可导入 `ZTransferShared`，模拟器启动 |
| M02 | MAC | 首次 iPhone 权限/网络探针 | Local Network 授权与相机 Wi-Fi 基础连通通过 |

### 1. Android 可共享代码盘点

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| S01 | DONE | 列出可共享类型、Android/Java 依赖和迁移顺序 | 已按直接迁移、先拆边界、平台保留三类完成盘点 |
| S02 | TODO | 冻结协议和业务固定样本 | PTP 字节、排序结果、队列状态、GPS payload、EXIF/滤镜结果 |
| S03 | TODO | 明确平台接口清单 | 网络、USB、文件、蓝牙、定位、后台、录像、支付、更新 |

### 2. 纯模型与基础规则

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| C01 | DONE | 迁移连接方式模型 | `CameraConnectionType` 已由 Android 使用 |
| C02 | TODO | 迁移通用枚举、错误和相机/文件值模型 | 不包含 `android.*`、`java.io` 或 Socket |
| C03 | TODO | 迁移格式化、坐标、日期和数值规则 | 替换或隔离 JVM-only API |
| C04 | TODO | 迁移共享测试工具和固定样本加载 | 后续协议任务复用 |

### 3. PTP 与相机协议

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| P01 | NEXT | PTP 常量、基础字节读写与容器编解码 | 先迁纯常量和格式映射，再处理包结构与端序 |
| P02 | TODO | PTP/IP 握手和命令/事件包 | 只迁协议，不迁具体 Socket |
| P03 | TODO | Nikon 属性、能力和对象信息解析 | 固定二进制样本验证 |
| P04 | TODO | 存储卡、对象元数据与双卡合并规则 | 顺序、别名、去重保持一致 |
| P05 | TODO | AP/STA 发现和配对状态规则 | 网络扫描实现留在平台层 |
| P06 | TODO | 遥控、实时监看和录像协议状态 | 与平台视频渲染分离 |

### 4. 文件浏览与传输

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| T01 | TODO | 文件排序、筛选、日期分组和连拍识别 | 迁移现有相关单测 |
| T02 | TODO | 缩略图调度、优先级和缓存规则 | 存储实现留平台层 |
| T03 | TODO | 传输任务、队列和暂停/继续状态机 | UI 与 Service 不进入本批次 |
| T04 | TODO | 重试、错误分类、分块和断点规则 | 文件 IO 通过接口注入 |
| T05 | TODO | 命名、同名文件、临时文件和完整性规则 | Android 结果保持一致 |

### 5. 遥控、GPS 与媒体规则

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| R01 | TODO | 曝光、ISO、快门、光圈等格式与档位 | 迁移 `Remote*Test` |
| R02 | TODO | 对焦、拍摄、录像与实时监看调度状态机 | 相机 IO 走公共接口 |
| G01 | DONE | GPS 更新频率模型 | 原包名/API 不变，现有单测迁入 `commonTest` |
| G02 | DONE | GPS 公开状态模型 | `GpsStatus/GpsState` 已共享，Android 恢复策略独立验证 |
| G03 | DONE | GPS 恢复与海拔规则 | 公共规则已共享，常量保持模块内可见，原测试迁入 `commonTest` |
| G04 | DONE | GPS payload codec | 完整 41 字节向量固定；纯 Kotlin writer 与平台 UTC 适配已分离 |
| G05 | TODO | GPS 配对业务状态机 | Android BLE 与 iOS CoreBluetooth 分开 |
| E01 | TODO | EXIF、相框元数据和布局规则 | Bitmap/Canvas 渲染留平台层 |
| E02 | TODO | 滤镜参数、收藏和水印规则 | 渲染器通过平台接口实现 |
| L01 | TODO | 免费版限制和会员权益判断 | 支付流程不共享 |

### 6. ViewModel 与共享 UI

| ID | 状态 | 任务 | 主要范围 |
|---|---|---|---|
| V01 | TODO | 从 `CameraViewModel` 提取连接、扫描和浏览用例 | 保持 Android State/UI 行为 |
| V02 | TODO | 从 `TransferViewModel` 提取队列和恢复用例 | Service 生命周期留 Android |
| V03 | TODO | 建立共享 presentation state | 不复制业务判断到 Swift |
| U01 | TODO | 核心稳定后启用 Compose Multiplatform | 单独验证 Android Compose 依赖变化 |
| U02 | TODO | 主题、资源与通用组件 | 按组件迁移，不整页搬迁 |
| U03 | TODO | 首页、设置与授权状态 UI | Android/iOS 共用 Composable |
| U04 | TODO | 文件列表、预览与传输 UI | 保留性能基线 |
| U05 | TODO | 遥控、实时监看、相框与滤镜 UI | 最后迁移高风险页面 |

### 7. 平台实现与最终验收

| ID | 状态 | 任务 | 完成点 |
|---|---|---|---|
| A01 | TODO | 收口 Android 平台实现 | USB、Service、MediaStore、Socket、BLE 等只在 Android 层 |
| I01 | MAC | iOS 网络实现 | `NWConnection`、热点引导、AP/STA 发现 |
| I02 | MAC | iOS 文件与照片实现 | PhotoKit、Files、临时文件和恢复 |
| I03 | MAC | iOS 蓝牙、定位与后台实现 | CoreBluetooth、CoreLocation、后台宽限 |
| I04 | MAC | iOS 录像、购买和更新实现 | AVFoundation、StoreKit、App Store |
| Q01 | TODO | Android 迁移最终多轮回归 | 全测试、Lint、APK、Manifest、固定样本、性能、真机功能矩阵 |
| Q02 | MAC | iOS 模拟器和真机功能矩阵 | 权限、网络、传输、后台、异常恢复 |
| Q03 | TODO | 双端代码边界审计 | 无重复业务规则，无平台 API 泄漏到 `commonMain` |

## Android 阶段结束条件

只有 `C/P/T/R/G/E/L/V/A` 中计划共享的任务全部完成，并且 `Q01`、`Q03` 通过，才宣布 Android 共享化改造结束。平台专属代码保留不算未完成。

## S01 盘点结论

- 可直接迁移：公开纯 Kotlin 模型/规则，如 GPS 更新频率；公开 GPS 状态模型可在下一批拆出。
- 先拆再迁：PTP 常量与本地化、Live View 元数据与 Lab 常量、相机文件顶层模型、滤镜内核、相框领域模型、ViewModel 纯策略。
- 平台保留：Android USB/Service/MediaStore/Bitmap/BLE/定位、JVM Socket/文件流，以及 iOS 对应系统实现。
- 强约束：`internal` 不能跨 `app`/`shared`；不为“方便搬运”公开实现细节，先设计小而稳定的公共 API。
- 迁移顺序：公开纯模型 → 固定样本与协议 codec → 文件/队列状态机 → ViewModel 用例 → 共享 UI → 双端平台实现。

## 验证记录

| 日期 | 任务 | 结果/证据 |
|---|---|---|
| 2026-09-04 | F02/C01 | shared 测试通过；Android APK 中 `CameraConnectionType` 仅一个定义 |
| 2026-09-04 | F03 | PBX 无悬空引用；Scheme XML、Blueprint、POSIX 脚本和 LF 属性静态检查通过 |
| 2026-09-04 | F04 | App/shared Lint、Debug 构建通过；APK 已在 Android 真机安装启动且无启动崩溃 |
| 2026-09-04 | F04 | `ZTransfer-debug-1.81-20260904-133704.apk`，SHA-256 `06573A4FB10506F022FA8AA4ADA974FB9C3F34F467E152F789836A83F8D06C48` |
| 2026-09-04 | S01/G01 | 盘点完成；GPS 频率源码逐行等价迁移，shared/GPS 测试及 App/shared Lint 通过 |
| 2026-09-04 | G01 | `ZTransfer-debug-1.81-20260904-135947.apk`；Manifest 不变，真机启动无崩溃，源码/APK 均为单一定义 |
| 2026-09-04 | G02 | `GpsStatus/GpsState` 逐行等价迁移；shared/Android GPS 测试和双模块 Lint 通过 |
| 2026-09-04 | G03 | 恢复/海拔逻辑仅调整跨模块可见性，测试输入输出不变并迁入 `commonTest` |
| 2026-09-04 | G02/G03 | `ZTransfer-debug-1.81-20260904-141505.apk`，SHA-256 `5CE2951E743A13D8C141345EC833F36ED88CD65CFB5E734E11B55B68E6BFC5EA`；Manifest 不变，真机启动无崩溃，共享类均为单一定义 |
| 2026-09-04 | G04 | 两组完整 41 字节向量先在旧 JVM encoder 通过，再由纯 Kotlin commonMain encoder 原样通过；Android UTC 适配测试通过，无新增依赖 |
| 2026-09-04 | G04 | App/shared Lint、Debug 打包及真机启动通过；`ZTransfer-debug-1.81-20260904-143655.apk`，SHA-256 `6D9519CAA95A12DE44B6B8B218CC5027BBA19BAD686373570F60E1AF69327203`；Manifest 不变，codec/时间模型均为单一定义 |

## 更新约定

- 开始任务：把该项改成 `NEXT`，顶部“下一项”同步更新。
- 完成任务：改成 `DONE`，在验证记录追加一行。
- 需要 Mac：保持 `MAC`，Windows 能完成的准备工作写进完成点。
- 不记录零碎编辑，只记录可以独立验收的迁移批次。
