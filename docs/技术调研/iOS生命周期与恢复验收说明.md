# iOS 生命周期与恢复验收说明（W31—W40）

基线：8594187（W21—W30 已推送）。这里的完成只指 Windows 交付门槛，不代表 Apple 编译或真机验收。

## 实现与平台边界

| 项 | 实际入口与已实现约束 | Mac 必须执行的场景/期望 |
|---|---|---|
| W31 | PtpIPCommandSession / PtpIPChannel：共享 Cancel 编码，同一 TID 排空期间持有命令锁；32 MiB 上限、3 秒绝对超时；畸形/截断/超限关闭 | 大文件传输中暂停/撤回、磁盘 sink 抛错、相机不回应；能排空则下一个命令帧同步，不能则断开，不假成功 |
| W32 | CameraWorkspace / CameraHandshakeProbe：旧代关闭后显式连接；就绪发布前再核对代际；既有路由/ACK 身份核对保留；无自动重连/自动开始 | AP、STA 标准和 STA-direct 各自断 Wi-Fi/换网络/相机断电并重连；旧进度不能进入新列表，手动暂停仍需用户开始 |
| W33 | SessionBackgroundLease：前台启用一个有限 UIKit 后台清理额度；退后台取消；expiration 强制断开；结束成对释放 | 锁屏、来回切前后台、授权弹窗 inactive、系统宽限到期；不无限下载，不自动开始；常亮回后台释放 |
| W34 | TransferRecoveryJournal：低频原队列快照，原子私有 JSON，512 KiB/500 行上限、连接/序号隔离；未知/坏记录保留并显式备份重置；首页显示待核对记录 | 下载中杀进程；重启可见旧文件名/完成计数与不完整提示；旧相机/卡/句柄不直接恢复，不续写旧 part；重新连并按新目录选择 |
| W35 | TransferFailureMessage：磁盘不足、撤权、来源变化、发布校验、取消分开；沿用 SandboxTransferFile/ProviderOriginalStore/OriginalActionCopies 的安全发布/本次临时文件释放 | ENOSPC、同名并发、provider 移走/撤权、iCloud 未下载、复制取消；原片仍在，不写假完成，可重新选择目标再试 |
| W36 | NativeGridImages / 两页 model / CameraPreviewStore：编码与解码有界，memory epoch 丢弃晚到结果；告警释放两页图片/预览并停止后台补图，按需读取可继续；不动目录和队列 | 大目录/大量事件/NEF、大图和连续传输；内存警告后旧图不回填，队列仍真实推进；Instruments 测峰值、卡顿与关闭后对象释放 |
| W37 | 正式首页 safeDrawing+IME，目录 safeDrawing、操作 FlowRow，队列底部安全区；保存选择长列表可滚动 | 小屏/刘海/横竖屏/iPad 分屏、键盘打开、空卡/无相机/拒权；关键按钮可见可操作；预览/弹层/系统 sheet 返回不丢会话 |
| W38 | 正式队列返回目标至少 48 dp；既有共享网格语义和动作保留；保存选择项文件名标签，低频结果 polite 播报；随字体放大连接卡 | VoiceOver 从连接到文件/预览/队列/保存往返；焦点回到触发控件，动作与照片名可读；最大动态字号无不可达按钮；不每 200 ms 朗读速度 |
| W39 | NativeTransferMessages 在当前语言渲染稳定错误码，已显示失败也能切换；网络/发现/保存/目录/恢复接现有三语设置，不新建偏好源 | 简中/繁中/英文跨页即时切换；失败、部分导出/取消保留真实含义，主题/触感/默认设置不重置；诊断技术输出非第二套产品文案 |
| W40 | 工程仅本地网络与 PhotoKit add-only 用途，InfoPlist.strings 三语注册；暂缓定位/蓝牙/麦克风不再可从 Debug 首页触发；保存失败提供系统设置入口 | 首次拒绝/之后撤销网络与相册权限；返回设置后重新执行真实请求，不缓存旧授权；普通超时不能显示拒权；启动不弹暂缓能力权限 |

## 不隐瞒的差异

- Android 源码的取消排空预算为 32 MiB / 3000 ms 读超时；iOS 采用 3 秒**绝对**清理上限，避免连续无关流量延长后台清理。这是保守的平台差异，超过则关闭并要求重连，不宣称定时语义逐毫秒相同。
- Android 原任务队列是进程内状态，未发现进程重启后盲目恢复句柄的实现。新增 iOS 记录用于解释恢复，不自动重新入队。完整原片仍由现有索引/共享身份匹配决定复用；partial 不是原片，旧相机/卡不套旧 handle。
- 系统宽限只用于停止和收尾。Apple 不提供本应用任意时长锁屏传图承诺。[UIKit 后台任务说明](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask%28expirationhandler%3A%29?language=objc)
- 界面适配与无障碍在 Windows 只验证代码入口/约束和场景，实际布局、焦点和朗读必须 M08/M09 实测，发现缺陷回开 W37/W38。
- W35 保留本次操作拥有的临时文件清理规则和原片保留，不修改 Android 文件路径或发布行为。

## Windows 检查与证据

- Gradle：公共 metadata、shared/app Debug 单测、Android Debug/Release Kotlin 编译、shared/app Debug Lint；修复 settings 可空描述类型错误后 BUILD SUCCESSFUL（3m29s）。1082 项单测（shared 765 + app 317）。
- Python：lifecycle_completion_wiring 追加精确逆向层，不改 W21 或更早固定指纹；当前接线/权限/生命周期及变异拒绝检查加在 test_lifecycle_completion_wiring。完整运行结果登记主任务表。
- check_structure：44 个 App Swift、8 个测试文件、446 个 XCTest 方法注册；均 NOT RUN。另 17 项 Native 图片测试待 Mac。
- 相对 8594187：app、platform、shared/androidMain、Gradle 配置、dist、dist-debug 无差异。本批只 iOS / Native 专用公共界面与测试文档；不冒充整个分支从未改 Android。
- 新增 XCTest：取消持锁/无响应/存储失败排空、后台额度代际与立即过期、恢复记录代际/损坏/容量/未知版本、错误路径脱敏。使用原测试 target，不复制模拟队列实现。
