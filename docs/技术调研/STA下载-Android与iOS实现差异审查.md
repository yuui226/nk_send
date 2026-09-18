# STA 下载：Android 与 iOS 实现差异审查

2026-09-17，依据当前工作树。只处理 STA；不进行 Mac 无线监听，不切 AP，不改网络设置。

## 范围与状态

第一轮完成下表 **12/12 项源码对照**；这不是全部实现差异已经消除。
用户新增“尽一切可能对齐 STA 传输的所有逻辑”后，继续核对文末所列剩余六项，
其中同步借用收包/写盘、默认关闭诊断、逐次 Socket 读取超时已落地并完成主机定向验证，
已安装 20260918-000803 真机包，用户报告速度仍约 1.6（原文“1.6mb”，未核实单位）；
性能验收仍未通过。后续也已对齐配对事件读取预算和有界非阻塞事件投递，
后台到期断言归还已修正并完成定向验证；公开无线能力和真机验收仍未完成。
初次 4 项审查及第一阶段实现记录保留在后面，不能用历史状态覆盖本节最新状态。
这是源码审查完成度，**不是 STA 慢速修复完成度**。业务策略/读取路径已收敛，
平台能力不宣称完全相同；23:20 对齐包真机只有 1.28–1.35 MiB/s，**性能验收未通过**。
现已恢复 STA 命令口的 Darwin ACK 适配，保留连续读取；23:28 新组合真机实测
1.598528 MiB/s，仅回到此前 1.5–1.8 MiB/s 区间，**仍未达到安卓速度**。
真机数据见 [iOS-STA传输耗时诊断.md](iOS-STA传输耗时诊断.md)。

## 安卓 STA 从入口到落盘的完整路径

`MainActivity.shouldPreferHighThroughputTransfers`（文件页/传输页为 true）
→ `TransferViewModel` FIFO 取当前相机会话、检查本地文件和续传半成品、打开/定位输出
→ 1 MiB `BufferedOutputStream`
→ `NikonCamera.downloadToFile` 整文件登记下载活动、进入 IO 线程、开始单调时钟计时
→ 必要时 `0x9421 GetObjectSize` → 冻结高吞吐策略 → 选择 partial/full
→ 每块持有 `CameraIoGate.withTransferSlice` → 发送命令 → 连续 pump 到 CMD_RESPONSE
→ 校验实收、推进偏移 → 下一块（仅完整事务之间让交互优先）
→ 关闭冲刷输出 → 改名/复制保存 → 按本次新增字节与端到端时长计算完成速度。

真实 STA 调用方 `CameraViewModel.kt:2000/2108` 总是传入 `exploreAlbumAccess=true`，
不是直接采用 `connectSta` 的默认参数。`directObjectRead` 必须由相机探测结果决定，
不能因为连接类型叫 STA 就统一强制/统一禁用；iOS `STAAlbumAccess` 对应保存该结果。

| # | 检查点 / 安卓依据 | iOS 对照及本次处理 | 状态 |
| --- | --- | --- | --- |
| 1 | `NikonCamera.connectSta`：绑定发现验证过的本地地址；连接 3 s；命令口 NODELAY、4 MiB RCVBUF；事件口默认配置 | BSD 保留相同路由与命令口配置；新增事件口区分；不再对事件口也设置命令口选项 | 已对齐 |
| 2 | 安卓 Debug/Release 同一 Socket 路径，不手动设置 ACK 频率 | STA Debug/Release 统一 BSD；默认 ACK 对照后性能未通过，命令口恢复 Darwin SENDMOREACKS 适配；事件口默认，AP/USB 后端不变 | 后端一致；ACK 明列平台适配，不能宣称内核等价 |
| 3 | `MainActivity:204/646`：文件/传输工作区 true，监看 false；`downloadToFile` 在大小解析后取一次快照 | `PhotoListView:528/574/581` 与 repository 冻结点一致；忙碌不等于高吞吐，切页不中途改本文件策略 | 一致，未改 UI |
| 4 | `TransferViewModel:2130–2269`：先本地命中/续传检查、打开输出，再进入下载计时；4 MiB 续传对齐 | 修正 repository 先发大小探测、再准备文件的顺序；文件准备后开始计时，大小查询仍计时；补准备失败零相机请求测试 | 已对齐；完整 App 回放测试另列 |
| 5 | `getObjectSizeInternal:3780`：0/0xFFFFFFFF 才用 0x9421 查询，成功且 8 字节正 Int64 才采纳；负回复仍未知，线错误传播 | 相同判断及完整数据相位恢复；不额外查询每个已知大小文件 | 一致 |
| 6 | `shouldUsePartialObjectDownload:252`：支持状态非 false、大小已知，并满足 direct / 非高吞吐 / 续传 / 大于 128 MiB | iOS `directReader != nil` 对应 direct；直读 STA 即使高吞吐、小文件仍用 0x9431；不误走 0x1009 | 一致，216 组合验证 |
| 7 | `downloadChunkSize:268`：高吞吐 64 MiB；否则 >512 MiB 为 32 MiB，其余 4 MiB；最后一块取剩余 | 同常量、同严格大于边界；参数 `[handle, offsetLo, offsetHi, reqSize, 0]`、dataPhase=1；请求最大 64 MiB，iOS reqHi 恒为 0 | 一致 |
| 8 | `downloadToFile:4030–4123`：按实收推进；每块声明校验/零进展失败/总长校验；只有首块、零数据、零续传且 0x2005 才回退全量 | 相同条件、会话内记忆 partial 支持；00:40 复审补齐 64 位负声明长度的未知语义；DeviceBusy/非空错误不切策略 | 正常策略一致；声明长度修正已回归、尚未打包 |
| 9 | `downloadToFile.pump` + `PacketReader`：同一 IO 工作线程持续读到响应；8 字节头、1 MiB 可增长体、64 KiB 输入缓冲 | 每相位一次 worker、跨下载复用缓冲；后续新增同步借用包体直接送 writer，大包不创建拥有所有权的 Data；短读活动与余量交接保留 | 执行及借用消费方式已对齐；真机待验证 |
| 10 | `TransferViewModel:2265` + `writeChunk`：1 MiB 缓冲输出；同步读-写-读；新文件可保留 256 KiB EXIF 头，续传不保留 | `CameraDownloadWriter` 相同；大包直接写、小包合并、关闭冲刷；不为每包调主线程或另加磁盘任务 | 一致，生产 writer 已独立回放 |
| 11 | `CameraIoGate`：下载活动跨所有分块；FHD/EXIF 仅事务间优先；心跳锁前/锁后查下载活动；后台取图等待 | 原活动边界一致；00:37 复审发现取得锁后的交互优先级二次检查缺失，已补齐。STA 下载期间不按滚动取消、重排列表任务 | 11 项 gate/会话相关主机回归通过；本次竞态修正尚未打包 |
| 12 | `emitProgress`/`TransferSpeedTest`：200 ms、包含协议/写入/块间等待，新传字节不含续传旧字节；会话/服务 WifiLock+WakeLock | 进度与测速规则对齐（文件准备顺序见 #4）；CPU/后台/Wi-Fi 锁无法机械照搬，详见平台边界 | 测速一致；无线锁平台差异 |

### 分支决策表（先看实际分支，不能只看函数名）

| 条件 | 安卓和 iOS STA 应采用的路径 |
| --- | --- |
| 大小未知且查询未能解析，非续传 | `0x1009 GetObject`；不是 4/64 MiB partial |
| 大小未知且不能 partial，但已有续传偏移 | 报续传不可用，不从 0 写入已经 seek 的文件 |
| 大小已知、direct=true、partial 未明确不支持 | 一定 `0x9431`；高吞吐下每请求至多 64 MiB |
| 大小已知、direct=false、高吞吐、非续传、≤128 MiB | `0x1009` 整文件；不能把此分支套给 direct=true 的相机 |
| 大小已知、partial 未明确不支持、非高吞吐 | `0x9431`；≤512 MiB 为 4 MiB，>512 MiB 为 32 MiB |
| 首 partial 返回 0x2005 且未写入任何数据、无续传 | 记忆不支持后全量回退；其余错误直接失败 |

### 必须明示的平台/安全边界

- Java `Socket` → Darwin BSD socket；Swift queue 是专用阻塞工作队列，不阻塞主线程或
  Swift 协作执行器。操作系统 TCP/Wi-Fi 实现不可能靠同参数变成同一实现。
- 安卓 RawPacket 允许下一次读取覆盖内部数组；iOS 后续增加专用于同步文件写入的
  borrowed sink，指针仅在回调内有效，不进入 Task/队列。需要持有数据的旧 sink
  仍获得拥有所有权的 Data。借用路径不构造包体 Data 切片，不依赖 COW 来保护跨包持有。
  已测连续两包内存地址复用；未做全进程堆分配统计，不宣称绝对零分配。
- 安卓会话和传输服务持有 LOW_LATENCY WifiLock（旧版 HIGH_PERF），同时有 CPU WakeLock。
  iOS 当前后台任务只保有限执行时间，不等同于无线低延迟锁。未发现可直接照搬的公开等价
  接口，不使用私有 API 或伪装语音/视频业务；也不把该差异直接定为根因。
- iOS 保留现有事务 ID/协议完整性校验，不为追求字面相同而删掉安全检查；坏数据不应保存。
  不新增主动断开功能，错误后的协议恢复是原有生命周期逻辑。
- USB 的 ImageCaptureCore 单回调整块限制与本任务无关，保留其有依据的 4 MiB 限制。
  AP 后端与监看页面不修改。前置文件准备顺序属于共用下载流程，不改变 USB 分块方案。

### 本次改动和验证账本

- `PTPIPPOSIXChannel/PacketReader`：连续读取、包缓冲复用、大包直读、socket 角色配置。
- `PTPIPSocketConnection/Transport`：下载数据相位一次进入读队列、事件口角色传递；
  普通命令和恢复流程继续接收归还的预读余量。
- `STAConnectionCoordinator`：同一个 BSD 后端用于 Debug/Release；不改 AP。
- `CameraRepository`：输出准备先于协议大小查询/计时，其他 STA 决策不另造策略。
- `PTPTransferDiagnostics`：单数据相位 worker 次数，准确注明 recv-only 字段口径。
- 生产协议专项：49/49 通过，日志 `/tmp/ztransfer-sta-android-aligned-verified.log`。
  首次新增 NODELAY 断言误把 Darwin 非零掩码 4 当成只能返回 1，已规范为布尔值并重跑通过；
  不隐藏初次失败，也不把它误报为 TCP_NODELAY 未生效。
- `bash tools/sta-transfer-tests/verify.sh`：13/13 通过（包含 216 种 STA 策略组合、
  安卓测速样例、实际 writer 小包/大包/续传/EXIF，以及已有 gate 测试 9 项）。
  脚本机械提取实际 Foundation 生产声明，不复制一份策略冒充生产测试；不启动模拟器。
- `CameraDownloadTests` 新增 direct STA 不走全量和输出准备失败不发大小查询的回放用例；
  这两项依赖完整 App 测试目标，**尚未运行**，不能计入 49+13。
  整个 CameraDownloadTests.swift 已对新生成的真机 App 模块通过 Swift 6/iPhoneOS
  静态类型检查；这仍不等于执行。首次手动检查漏加 XCTest Swift overlay 搜索路径，
  补齐 Developer/usr/lib 后返回 0，日志 `/tmp/ztransfer-sta-camera-download-tests-typecheck-verified.log`。
- 本地回环只验证内容/执行结构，不以毫秒级耗时宣称真机已经达到安卓速度。
  Debug 真机包与下一次速度样本在验证后追加；Release 仅做协议静态检查，不冒充发布验收。

大包直读依据：[Android BufferedInputStream.read1](https://android.googlesource.com/platform/libcore/+/51b1b6997fd3f980076b8081f7f1165ccc2a4008/ojluni/src/main/java/java/io/BufferedInputStream.java)。
无可用缓冲且请求长度不小于缓冲时，直接读入调用方数组；不是任何包都强制多拷一层 64 KiB。

### 真机包交付状态（23:20 后）

已运行仓库 `dist-debug-ios/build.command`，显式 `IOS_SKIP_SIMULATOR=1` 和既有 iPhone UDID。
Xcode 输出 **BUILD SUCCEEDED**；签名/IPA 检查通过，安装已成功。
产物：`dist-debug-ios/ZTransfer-ios-debug-1.82-20260917-232045.ipa`（同名 `.app`）。
日志：`/tmp/ztransfer-sta-android-parity-device-build.log`。
自动启动被系统以 **Locked** 拒绝，导致组合脚本最后返回 1；这不是编译失败或启动崩溃证据。
等待手机解锁、打开新版 STA 并发起实际下载；**尚无此包的真机速度结果**。
Release 条件编译的全部 PTP 源码已通过 iPhoneOS arm64/iOS 16、Swift 6 静态类型检查，
未打 Release 包，未做 Release 真机验收。

后续只记录新版成功传输的端到端 MiB/s、实收字节与总时长，核对 `bsd_socket=1`、
`posix_phase_worker_calls=1`、该包实际 ACK 选项和内核缓冲配置。用户不需找同一个文件、
不需提供 Android 抓包、不需切 AP 或改 Mac 网络。若仍有差距，继续依据这份对照表
和新包实测缩小范围，不把本地回环/设置相同当成吞吐已相同。

### 23:20 包的实测否证与平台适配纠正

已确认手机运行的路径为 `...232045.app/ZTransfer`、PID 1966，排除仍在测旧包。
取回 `Library/Caches/Diagnostics/sta-transfer.jsonl` 到
`/tmp/ztransfer-sta-parity-phone-2325.jsonl`，新完成的两笔：

| 样本 ID | 文件字节 | 总耗时 | 实际速度 | recv 墙钟占比 |
| --- | ---: | ---: | ---: | ---: |
| 6AC9516A-23A2-4F1A-A79C-9F0F34D83A4E | 24274851 | 18.097127 s | 1.279225 MiB/s | 98.3917% |
| 150A8DF9-6A19-43A5-BF35-F3C5835F7DA4 | 10099524 | 7.121982 s | 1.352384 MiB/s | 98.4460% |

均成功、单相位 worker=1、4 MiB 内核缓冲、NODELAY=1、SENDMOREACKS=0。
第二笔写盘只有 16.580 ms，>=50 ms 的 recv 合计 1334.706 ms。
收包与写盘结构已生效，但并未解决主要差距。recv 是墙钟，仍可能含内核处理或线程调度，
不能把它直接等同空口传输/相机 RTT；也不能据此宣称物理 Wi-Fi 根因已证实。

需纠正上一轮推论：Android 未显式 setsockopt ACK，不代表 Darwin 的默认确认策略
与 Linux 相同。公开 [Android 内核 tcp_input.c](https://android.googlesource.com/kernel/common/+/refs/tags/android15-6.6-2024-09_r10/net/ipv4/tcp_input.c)
包含 quickack 与接收窗口条件；Apple [tcp_cc_delay_ack](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp_cc.c)
采用自身的延迟确认条件，[TCP_SENDMOREACKS 实现](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp_usrreq.c)
通过 TF_QUICKACK 改变该条件。源码说明的是平台差异，不是所测 Android 手机内核版本
或 iPhone 在线 ACK 节奏的直接观测。

因此恢复先前较高速度样本使用的公开 Darwin ACK 适配，仅 STA 命令 socket，
Debug/Release 一致；事件口默认。保留连续读取和所有业务策略，不再反复切换两种
应用层下载实现。先前适配样本约 1.5–1.8 MiB/s，仍低于安卓，所以此次恢复只作为
防止性能回退的选择，**不是完整修复，也不以不同文件样本声称严格因果关系**。
旧 ACK=1 抓包已表明长停顿前数据被及时确认，不能继续把所有剩余差距归咎于 ACK。

恢复适配后的命令口/事件口配置、字节回显、16 MiB 流式回放 **4/4 通过**，日志
`/tmp/ztransfer-sta-platform-ack-tests.log`。修正包
`dist-debug-ios/ZTransfer-ios-debug-1.82-20260917-232827.ipa` 已 BUILD SUCCEEDED、
签名/IPA 检查通过并安装；自动启动再次因设备 Locked 被拒绝，组合脚本返回 1。
本次进程查询未发现 ZTransfer，不能宣称新版已运行；没有新组合真机速度结果。
`adb devices -l` 当前无安卓设备，仅作只读可用性检查，未要求用户准备安卓抓包。
未改 Mac 网络，没有再次进行 RVI/空口抓包，也没有修改 AP/USB 或删除导出照片。

### 23:28 修正包实测：恢复旧水平，主要差距仍在

用户回复“好了”后，设备进程查询确认 PID 1985 的可执行文件为
`ZTransfer-ios-debug-1.82-20260917-232827.app/ZTransfer`。最新日志复制到
`/tmp/ztransfer-sta-restored-ack-latest.jsonl`，成功样本
`2C2BFEFF-FED1-4E03-B54A-1A72205EC476`：

- 实收并写入 23981155 B，单分块，端到端 14.307045 s；
  **1.598528 MiB/s（十进制 1.676178 MB/s）**。
- `bsd_socket=1`、`posix_phase_worker_calls=1`、`tcp_send_more_acks=1`、
  `tcp_no_delay=1`、4 MiB 内核接收缓冲：确认连续读取与 ACK 适配组合已生效。
- recv 墙钟 14002.851 ms，占总耗时 97.8738%；10180 次读取，
  29 次 >=50 ms 的 recv 合计 2643.373 ms。
- 写盘 33.438 ms；sink 49.136 ms（包含写入，不与写盘相加）；
  finalize 2.470 ms；等待 gate 6.890 ms。该样本不支持写盘或排队为主要瓶颈。

本轮只能确认恢复到此前 ACK 适配的速度区间，不能认定连续读取已带来额外提速，
也不能拿不同文件的前后数据证明单一选项的因果效应。Android 3+ MB/s 的验收目标
仍未达到。recv 墙钟含内核处理和可能的线程调度，不能据此断言是路由器、相机、
无线省电或物理链路问题；剩余根因未定位。本轮未改生产代码、未再次构建或安装。

## 继续对齐所有 STA 逻辑：剩余六项账本

本节优先于下方历史记录。不把“12 项已审查”当成“所有实现完全一致”，也不因为
前一轮 recv 占比高就跳过仍可对齐的应用实现。用户当前目标仍在进行中。

| 项目 | 当前工作与证据 | 仍需完成 |
| --- | --- | --- |
| 1. 同步借用缓冲到写盘 | BSD reader.withPacket 在复用包体内部同步消费；PTPSession 透传 borrowed sink；writer 小包复制入 1 MiB 输出缓冲、大包同步直接 write；保留短写/EINTR/错误计数 | 真机吞吐和分配行为验证 |
| 2. 诊断与正常路径一致 | 不再因 DEBUG 默认创建诊断器；仅开发启动环境 `ZTRANSFER_STA_DIAGNOSTICS=1` 开启，Release 关闭。正常下载没有逐 recv 诊断加锁/时钟/计数 | 新包正常启动验证；关闭后没有新 JSON 记录是预期，不能误判没传输 |
| 3. 超时与读取活动 | STA BSD 普通命令/文件下载/初始化应答使用 SO_RCVTIMEO；去掉整个事务计时，慢写盘不触发网络超时；初始化 5 s、正常 60 s，事件无限等待；配对按包设置剩余预算 | 真机验证；保留超时/恢复边界回归 |
| 4. 同步及调度 | 已去掉逐 recv 的 Swift 往返；STA 不再创建 session activity watchdog，正常读取不刷新恢复时钟；事件容量 64 非阻塞投递，与业务回调分离 | writer 关闭保护锁、abort 状态锁和控制命令异步边界仍需保留生命周期证明；不能无依据移除互斥 |
| 5. 校验与异常路径 | 借用路径保留长度和事务 ID 校验；写入失败仍按原流程排空响应，下一命令同会话可用 | 整理比安卓严格的输入校验为有理由的差异，不以删安全校验冒充性能优化；扩展边界回放 |
| 6. 无线活跃/后台生命周期 | Android WifiLock/WakeLock 与 iOS 有限后台时间不是等价；后台到期改为同步先归还断言，再清理捕获的旧 worker，拒绝授予不打断前台任务 | 公开无线能力与真机前后台切换验证；未找到 WifiLock 等价证据不写成已实现或绝对不可能 |

### 同步借用实现的验证（23:46）

依据 Android `PacketReader.readPacketRaw` → `NikonCamera.downloadToFile.pump/writeChunk`
→ 1 MiB BufferedOutputStream 的同步串行生命周期，不改变命令、块大小、顺序、UI
或主动断开功能。生产 writer 直接同步消费指针；没有 `Data(bytesNoCopy:)` 逃逸包装。
普通拥有型 sink 继续接收独立 Data，控制包和异常 drain 保留原有拥有型表示。
FileHandle 持有文件描述符和关闭生命周期，底层 write 循环处理短写和 EINTR；
未完成写入不推进 writer 字节计数。共享 writer 的非借用输入也经过相同缓冲逻辑，
AP/USB 传输后端与业务策略未改；原有拥有型写入/续传测试一并回归。

- 45/45 协议、POSIX reader、收包恢复测试通过：
  `/tmp/ztransfer-sta-borrowed-tests-verified2.log`。
  新增同地址连续复用、显式持有副本不被覆盖、借用消费失败后预读归还、
  16 MiB 借用路径不调用拥有型回调、借用写盘失败恢复；原有 NW/BSD 流程继续通过。
- 新增借用包事务 ID/截断拒绝、剥离四字节 ID、END_DATA 后仍等待响应，2/2 通过：
  `/tmp/ztransfer-sta-borrowed-codec-tests.log`。
- 实际生产 writer/策略/gate 15/15 通过：
  `/tmp/ztransfer-sta-borrowed-writer-tests2.log`。
  新增原始内存立即覆盖后文件及 EXIF 头仍正确，以及只读文件写入失败、字节不虚增。
- 首轮编译暴露跨文件私有读取工具不可访问，以及 nonescaping 回调内捕获发送闭包的
  Swift 独占访问约束，已分别改为本地非对齐整数读取、消费结束后发送 PONG，重跑通过。
- iPhoneOS arm64/iOS 16、Swift 6 的 DEBUG/非 DEBUG 两组静态类型检查通过，覆盖全部
  PTP、实际 writer/策略提取代码、CameraIOGate 和实际本地化；不是完整 App 编译。
  日志 `/tmp/ztransfer-sta-borrowed-ios-debug-typecheck.log`、
  `/tmp/ztransfer-sta-borrowed-ios-release-typecheck.log`（退出码均为 0）。
- 未构建/安装 App、未启动模拟器，手机仍是 232827 包。上述主机回放不代表真机提速。

### 超时边界对齐（23:53）

重新完整阅读 `NikonCamera.connectSta`、`PacketReader.readFully`、
`abortActiveTransaction/drainCmdResponse`、`startEvtThread`，发现一项此前记录错误：
Android **在 initializeStaBrowsingSession 成功之后**才把 5 s 改为 60 s，而 iOS
`STABrowsingSession.command` 原注释称“之前”，代码全部传了 60 s。已纠正注释和数值，
配对、初始化、访问探测命令均传 5 s；连接完成后的正常会话仍默认 60 s。

实现变化：

- BSD 普通读取及整文件 packet pump 安装 `SO_RCVTIMEO`，每个阻塞 recv 有独立等待预算。
  短读后下一次重新等待完整预算；正数纳秒向上取整至微秒，不把极小预算误设成无限等待。
  调用结束恢复原 Socket 选项；不把事件口永久留在 5 s/60 s 超时。
- 内核 EAGAIN/EWOULDBLOCK 映射为现有 `PTPSessionError.timeout`，继续走原异常排空逻辑；
  没有新增用户主动断开/取消入口，也没有为了测试改变正常连接所有权。
- `PTPCommandTransport.usesSocketReadTimeouts` 与 framework-owned 生命周期分开。
  STA 不再创建外层活动 watchdog；不会在同步写盘时触发“接收超时”。
  `AsyncDeadline` 的无计时器模式只保留取消通知/晚到结果隔离，恢复前仍不撤掉底层接收者。
- 普通 STA 命令取消等待者后仍读完响应，再向等待者报告取消，不在滚动时中断共享连接。
  AP/NW 和 USB 的既有超时策略不变。
- InitCommand/InitEvent 应答也改为每次读取 5 s，而非整个发送+收完整包合计 5 s。
  初始化尚未交付的连接仍可由其建连任务取消并清理，保持原生命周期。
- 恢复状态的 lastRead 只在进入恢复后才更新；正常文件接收不再为无用恢复时钟取时间。
  3 s 恢复活动预算仍保留，不能把异常情况下阻塞的 recv 变为无限等待。

验证：67/67 定向协议测试通过，日志 `/tmp/ztransfer-sta-read-timeout-final-tests.log`。
新增真实本机 BSD 回放：250 ms 读取预算下同步 writer 阻塞 600 ms 仍成功；
普通命令分四次间隔 100 ms 收齐、总时间超过 250 ms 仍成功；100 ms 静默读超时后
排空并复用同一会话；取消缩略图等待者不发送 PTP Cancel；短时读取超时退出后事件式
无限读取能等到更晚数据。初始化夹具断言前六命令均为 5 s、下一正常命令为 60 s，
配对命令也均为 5 s。原有拆包慢读、借用写入失败、PING、慢速排空和静默断线回归通过。

iPhoneOS arm64/iOS 16、Swift 6 全部 PTP 源码 DEBUG/非 DEBUG 类型检查均返回 0：
`/tmp/ztransfer-sta-read-timeout-ios-debug-typecheck.log`、
`/tmp/ztransfer-sta-read-timeout-ios-release-typecheck.log`。
最后缩减恢复时钟更新后，BSD/NW 慢速排空、内核超时恢复及慢 writer 的 4/4 定向复验
通过，日志 `/tmp/ztransfer-sta-drain-clock-tests.log`。未构建/安装 App，真机仍未验证这些改动。
配对可选事件等待、事件投递及后台生命周期没有因此被标记为全部对齐。

本轮当时确认源码差异（已在下一节处理）：Android `NikonCamera.kt:1290/1943` 使用容量 64 的 Channel，
事件线程 trySend 不等待消费者；iOS `startEvents` 直接 await `repo.receiveEvent`，
会等待 repository actor 排队。当前 receiveEvent 本身不执行相机命令，但这并不等于
它永远即时获得 actor。需要对齐有界、非阻塞事件投递，并验证慢消费者期间事件口
PING 仍及时回应；当时尚未实现，也尚未证明这个差异是当前吞吐根因。

### 事件通道和配对等待对齐（23:58）

依据 `NikonCamera.ptpIpEventChannel/startEvtThread`、`parsePtpIpEvent`、
`RemoteProbeTest.parsesPtpIpObjectAddedEventPayload`、`completeInitialPairing`：

- 事件口只解析 `STAEvent(code, handle)` 并 `yield` 到容量 64 的
  `AsyncStream.bufferingOldest`，满时丢弃新项，对齐 `Channel(64).trySend`。
  不把任意大的原始事件 Data 放进队列；无效事件先过滤，不占容量。
- 独立 consumer 按 FIFO await repository，读 Socket 的任务不等业务 actor；
  PING 仍由同一事件口直接 PONG。没有消费者时仍回应 PING，不积攒事件。
- 已启动不会重复创建读者/消费者，已关闭不能重启。原有连接关闭时取消投递任务、
  结束 stream、结束读任务；不会再派发队列中剩余项。已进入业务处理的回调不能撤销，
  不伪称关闭可以回滚已处理事件。没有增加用户断开入口。
- 配对等待仍默认 8 s，但在每包前按剩余整毫秒设置读超时，包内每次短读使用这个预算，
  与 Android 一致；持续分段的单包可以超过原总预算，不用另一个总计时器截断它。
  可选事件缺失仍不撤销已经确认的配对标记。普通超时返回前实际读者已经退出，
  不遗留一个未完成的 read 去抢后续事件。
- AP/NW 配对等待仍保留原行为；STA 接线改为传递已解析的 STAEvent，repository
  使用原事件业务逻辑，没有改照片列表加载、目录更新策略或 UI 文案。

验证记录：

- 事件接入后的 30/30 原有协议/协调回归通过：`/tmp/ztransfer-sta-event-queue-tests.log`。
- 新增事件回放 3/3 通过：`/tmp/ztransfer-sta-event-queue-verified.log`。
  暂停第一个消费者，连续发送其余 74 个事件及 PING；暂停期间收到 PONG，解除后严格
  只交付 1...65。无效事件不占容量；重复启动、关闭时队列丢弃、无订阅者 PONG 均覆盖。
- 合并配对等待后的 44/44 定向回归通过：`/tmp/ztransfer-sta-event-pairing-verified.log`。
  包括原协议恢复、配对标记和连接协调。配对时序断言随后强化并单独重跑 2/2 通过：
  `/tmp/ztransfer-sta-pairing-deadline-final-tests.log`。直接记录等待函数返回的耗时，
  而非把发送测试数据所用时间当作等待耗时；250 ms 预算下 150 ms 间隔分片读完约 490 ms。
- iPhoneOS arm64/iOS 16、Swift 6 全部 PTP 源码 DEBUG/非 DEBUG 静态类型检查返回 0：
  `/tmp/ztransfer-sta-event-pairing-ios-debug-typecheck.log`、
  `/tmp/ztransfer-sta-event-pairing-ios-release-typecheck.log`。这不是完整 App 构建或 UI 验证。
- 尚未构建或安装 App，手机仍未测这一组合；回放成功不等于速度差距已经解决。

### 后台生命周期：不是 WifiLock 的同义替换

Android `TransferService.onTimeout` 及时释放锁并停止保活服务。iOS 当前
`TransferQueue.backgroundTransferExpired` 只 cancel worker，实际 endBackgroundTask
要等 `run` 的 defer；网络排空或文件清理延迟可能拖过系统到期时间。这是本轮发现并
修正的问题（见下节），不能因前台下载成功就标记真机后台行为完成。
Apple [beginBackgroundTask](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:))
明确要求在到期清理中结束申请，否则有被系统终止的风险。

另已核查公开 [BGContinuedProcessingTask](https://developer.apple.com/documentation/BackgroundTasks/BGContinuedProcessingTask)：
它能支持从前台延续到后台，但系统会显示 Live Activity 并提供取消入口，且仍可能被系统终止。
这不是透明的 Wi-Fi 性能锁；在用户明确不要新增取消功能和严格复刻 UI 的约束下，
没有擅自接入。若后续确需采用，需先讨论这一用户可见的平台差异，不能冒充无差异实现。

### 后台到期清理对齐（2026-09-18 00:02）

在 `TransferQueue.swift` 增加 MainActor 隔离的 `TransferBackgroundActivity`，
只拥有 UIKit 后台断言，不拥有相机连接。系统到期回调内先同步 endBackgroundTask，
再取消创建该断言时捕获的 worker，最后异步通知队列清理本代标记。没有新增业务取消入口，
没有改变现有 .nkpart_ 保留/WAITING 恢复流程，也没有为无线提速伪装音视频后台能力。

具体边界：

- 重复到期与正常收尾只结束同一断言一次；结束后的晚到回调不再调用到期处理。
- 创建过程中同步到期时先记 pending，等 begin 返回 ID 后立即结束该 ID，再通知清理。
- 系统拒绝授予断言（invalid）不取消前台传输，符合 Android 保活服务启动失败后
  仍允许前台传输的原则；不把“拿不到后台时间”当成“相机连接已失败”。
- 捕获 worker 句柄而不是到异步回调时再读取当前 worker；现有 UUID 代际校验仍保留。
  旧代清理不会把后来新建的任务取消或覆盖掉新断言。MainActor.run 返回时还会核对代际，
  已过期的断言不重新安装回队列。

`bash tools/sta-transfer-tests/verify.sh` **19/19 通过**：
`/tmp/ztransfer-sta-background-lifecycle-tests.log`。其中 4 个新增测试运行实际生产生命周期
类，验证 end 在 expire 通知之前、重复结束、晚到旧回调、新断言独立、创建中立即到期、
申请失败不打断前台；其余实际 writer/策略/gate 回归通过。

新增 `tools/sta-transfer-tests/check-background-ios.sh`：从原文件机械提取生命周期类和
队列 UIKit 方法原文，以最小 actor 字段外壳执行 iPhoneOS arm64/iOS16 Swift6 静态检查，
没有复制一份方法冒充生产实现。最终捕获 worker 版本通过，退出码 0：
`/tmp/ztransfer-sta-background-ios-adapter-final-typecheck.log`。
此检查不等于整个 TransferQueue 运行或完整 App 编译；真实系统到期、前后台切换仍待手机验证。

### 保留同步保护的理由与验收边界

STA 热路径已不再创建 `PTPReceiveActivity` 或默认逐 recv 诊断。仍保留的 writer 锁
保护 close/最后一次写入，POSIX 描述符锁保护 shutdown/活跃操作结束后的 fd 关闭，
abort 锁保护恢复任务与读队列并发。Android 的同步 I/O 栈不能直接替代这些跨队列
生命周期；贸然删锁会留下关闭与晚到回调竞态。已有写入失败、关闭后写入拒绝、排空
后复用和关闭阻塞 read 的测试支持保留这些保护，但没有据此宣称两端锁开销完全一样。
协议长度和事务 ID 校验也保留，借用指针仅在同步回调内有效。真机分配/吞吐尚未验收，
不会仅因测试绿灯把整个“尽可能对齐”目标标记完成。

### 合并验证与下一个真机节点（2026-09-18 00:04）

在上述修改全部合入当前工作树后，运行
`ZTRANSFER_PROTOCOL_ONLY=1 swift test --package-path ios --filter 'PTPIP|PTPSession|STA'`，
**111/111 通过**，日志 `/tmp/ztransfer-sta-consolidated-regression-20260918.log`。
包含 PTP/IP 分帧、Socket、发现、事务、STA 配对/配置/元数据、事件及恢复；不是完整 App
测试集，不包括 UIKit 队列 UI 或真实相机吞吐。生产 writer/策略/gate/后台断言的
19 项主机测试和 UIKit 适配静态检查见前节，不能冒称已经跑过真机后台到期。

本轮回归后已请求运行 `dist-debug-ios/build.command` 并安装真机 Debug，用户随后明确
回复“允许”；执行结果见下一节。新包正常启动默认不生成
逐 recv 诊断，速度应按 App 的实收字节/端到端用时验证，需要诊断时才显式带启动环境。
不得沿用旧 232827 的 1.60 MiB/s 当作这些源码修改的成绩。

### 真机 Debug 打包与安装（2026-09-18 00:08 批次）

获用户明确授权后，以 `IOS_SKIP_SIMULATOR=1` 和指定真机
`00008110-000C28E03481401E` 运行 `bash dist-debug-ios/build.command`。
Xcode 输出 **BUILD SUCCEEDED**，签名及 IPA 完整性校验通过，生成：

- `dist-debug-ios/ZTransfer-ios-debug-1.82-20260918-000803.app`
- `dist-debug-ios/ZTransfer-ios-debug-1.82-20260918-000803.ipa`

`devicectl` 已报告安装成功，安装目录为
`9D3C8765-4837-4D6D-BE94-F20ED5BFB074/ZTransfer-ios-debug-1.82-20260918-000803.app`。
随后自动启动被系统以 `Locked` 拒绝，脚本因此退出 1；这是手机锁屏导致的启动失败，
不是编译失败、安装失败或已观测到的 App 闪退。尚未确认新版运行，需解锁后打开。
未启动或构建模拟器，未重复运行整套测试，未启用逐 recv 诊断。
完整日志：`/tmp/ztransfer-sta-aligned-device-20260918-build.log`。
真实相机传输速度、前后台切换和后台到期行为仍待验证，不能据打包成功宣称已达到安卓速度。

### 000803 包用户实测反馈：仍约 1.6，未明显提速

用户随后报告“1.6mb”。只读查询确认 PID 2016 正在运行上述
`9D3C8765-4837-4D6D-BE94-F20ED5BFB074/ZTransfer-ios-debug-1.82-20260918-000803.app/ZTransfer`，
排除仍运行旧安装包的情况。此处是用户读数，不是新的逐 recv 诊断样本；没有本次实收
字节、总时间或单位截图，不将其伪精确记成 1.600000 MiB/s，也不沿用旧包耗时分解。
按用户反馈，这批对齐未带来明显端到端提升，尚未达到安卓 3+ MB/s。

再次阅读 Android `connectSta`、`PacketReader`、下载 pump 及 iOS 对应生产路径：
命令口配置、64 KiB 输入缓冲、可增长包体、同步借用写盘、每相位单工作队列均已接入。
未发现新的正常路径固定等待或每次 recv 的异步往返；保留的异常恢复锁不能无依据删除。
尚无新证据把差距归因于某个剩余差异，不能将无线锁或 TCP 平台差异直接定为根因。
本轮未修改生产代码、未重新打包、未启动诊断采集或更改设备网络设置。
前后台切换和后台到期行为仍未真机验收；整个慢速问题仍未解决。

### 调度复审：取得锁后的交互优先级竞态（2026-09-18 00:37）

Android `NikonCamera.kt` 的 `CameraIoGate.withTransferSlice` 在
`interactiveWaiters.first { it == 0 }` 后等待 `mutex.lock()`，然后再次检查
`interactiveWaiters.value == 0`；若优先请求已经到达，立即归还锁并重新等待。
iOS 原先只在 `canStart/serviceNextWaiter` 分配锁时检查；等待者已获授锁、但 actor
continuation 尚未恢复期间，新交互请求可以登记。恢复后的 `withLock` 未再次判断，
会抢在预览前开始下一下载分块。这纠正上表此前笼统的“一致”结论。

`CameraIOGate.withLock` 现按 Android 的循环，在取得锁后再次检查交互登记；不满足时
通过本轮 `defer` 归还锁，再排队等待。普通命令 FIFO 和整个下载期间跳过心跳的逻辑不变。
没有增加固定延迟、用户取消/断开入口，未改变 UI、动画、缩略图加载顺序或 AP 后端。
该 gate 是共用调度组件，修正适用于使用它的下载分块；不是 STA 之外的新策略。

验证证据：

- 新增 `CameraIOGateHandoffTests` 两项确定性回归。仅主机验证脚本启用
  `STA_GATE_HANDOFF_TESTING`，用一次性 barrier 精确暂停在获授锁后，不靠 sleep 碰运气；
  App 工程未定义此标记，不编译测试 barrier 或回调。
- 临时源码副本只移除新的二次检查，负向对照确实得到 `[transfer, preview]`，
  与要求的 `[preview, transfer]` 相反：2 项中 1 项按预期失败。日志
  `/tmp/ztransfer-sta-gate-handoff-negative-control.log`。
  首次负向对照尝试用 stdin 与其他 Swift 文件混编未成功，不计作复现；改为临时文件后才得到上述断言证据。
- 生产修正下 `bash tools/sta-transfer-tests/verify.sh` **21/21 通过**，包含原 19 项和
  新增的交互登记时序、放弃获授任务后不遗留锁两项；日志
  `/tmp/ztransfer-sta-gate-handoff-20260918.log`。
- 不启用测试标记，对实际 `CameraIOGate.swift` 做 Swift 6、arm64/iOS 16 的 iPhoneOS
  类型检查，返回 0；不是 App 构建或真机运行验证。

该修正对齐交互让路竞态，不解释没有预览操作时仍约 1.6 的持续吞吐。
未重新构建/安装，新手机包仍是 000803；整个性能问题未解决，目标继续保持未完成。

### 声明长度复审：Android signed Long 与 Swift UInt64（2026-09-18 00:40）

Android `NikonCamera.pump` 的 START_DATA 12 字节形式通过 `getLongLE(4)` 读取有符号
Long；逐块/整文件仅在声明值为正时检查实收长度。原 iOS 按 UInt64 原样保存，
例如全 `FF` 被解释成 18446744073709551615，导致正常收尾后仍误报残缺，未知大小时
也会向 writer 进度传入错误的巨大总数。这是源码语义差异，不是本次真机慢速的已证实原因。

现在 PTP/IP 下载相位把 64 位字段中对应负 Long 的值表示为 `nil`（未知）；
0 和所有非负 Long 仍保留。8 字节旧形式的 32 位长度仍按 unsigned 解码；
`0xFFFFFFFF` 不被统一擦除，因为 Android 的 full/partial 校验对它有不同规则。
事务 ID、包长度、正常正数声明短读、partial 的最终文件大小校验均未放宽。
这修正共用 PTP/IP 下载解析，不更换 AP/USB 后端、请求策略或用户操作。

证据：

- 修改生产代码前新增两项 codec 测试：未知声明的用例产生 12 个预期断言失败，
  非负/32 位边界用例通过；`/tmp/ztransfer-sta-signed-length-before.log`。
- 修正后 `PTPIPCodecTests|PTPIPTransferRecoveryTests` **44/44 通过**；
  `/tmp/ztransfer-sta-signed-length-after.log`。覆盖拥有/借用入口、负 Long 边界、
  0/Int64.max/32 位未知标记；新增真实 BSD 回环验证收到 END_DATA 和 COMMAND_RESPONSE、
  正确保留三个数据字节、没有误触发恢复、下一命令仍可使用同一会话。
- `bash tools/sta-transfer-tests/verify.sh` **22/22 通过**；
  `/tmp/ztransfer-sta-signed-length-writer.log`。新增实际生产 phase→borrowed writer 回放，
  验证未知/已知 totalHint 的进度总数和落盘字节，不用复制策略替代生产实现。
- 全部 PTP 源码 iPhoneOS arm64/iOS 16、Swift 6 静态类型检查返回 0；
  `/tmp/ztransfer-sta-signed-length-ios-typecheck.log`。不是完整 App 或真机功能测试。

未构建/安装，手机仍是 000803；新增修正未真机验证。正常传输速度仍约 1.6，
未找到足够证据把剩余吞吐差距归因到这项边界修正，整体目标仍未完成。

### 无线能力核查边界

Apple 的 [NetworkServiceType 文档](https://developer.apple.com/documentation/foundation/nsurlrequest/networkservicetype-swift.enum)
说明其作用是提供流量用途提示，并非可宣称与 WifiLock 等价的锁。
[NWParameters.ServiceClass](https://developer.apple.com/documentation/network/nwparameters/serviceclass-swift.enum)
主要描述发送流量优先级，不保证改变接收优先级，缺少特定需求或实测依据应使用 bestEffort。
[QA1934](https://developer.apple.com/library/archive/qa/qa1934/_index.html)
明确不应把批量数据标为 voice/video 来追求带宽。因此本轮没有修改服务类型或伪装业务。
这排除的是一个不合适的替代方案，不是已经证明所有 iOS 等效方案都不存在。

## 改动前的初次对照记录

下表记录改动前的审查基线；连续读取改动的验证状态见末节。

| 项目 | Android | iOS 审查基线 | 判断 |
| --- | --- | --- | --- |
| 下载命令 | STA direct validated 强制 0x9431、五参数、dataPhase=1 | directReader 存在时同策略、同参数排列 | 已对齐，不应改为 0x1009 冒充安卓快路径 |
| 请求分块 | 普通 4 MiB；大于 512 MiB 为 32 MiB；高吞吐优先 64 MiB；首命令前冻结策略 | 对应策略一致 | 已对齐；实测单分块内已慢，不能归因于频繁重发请求 |
| Socket | 绑定已验证本地地址；TCP_NODELAY；连接前 4 MiB SO_RCVBUF | STA Debug BSD 对齐上述配置，另设 SENDMOREACKS=1 | ACK 设置是 iOS 试验项，不是安卓源码行为 |
| 执行模型 | downloadToFile 在 Dispatchers.IO；readFully 在当前 I/O 工作线程持续读取 | 每次 recv 单独排到 readQueue，短读后恢复 Swift，再 await 排队读取 | **未对齐：连续读取被拆成逐次异步读取** |
| 包缓冲 | 64 KiB BufferedInputStream；复用 8 字节包头、初始 1 MiB 可扩容包体和 RawPacket | 每次 recv 创建至多 64 KiB Data；readExactly 分包拼装，余量经字典取放 | **未对齐：没有相同的可复用包读取器** |
| 去除事务 ID | 共享 buffer 按 offset=4/count 同步写入 | dropFirst(4) 切片交给 sink，decode(header:body:) 不再拼整包 | 此处已有优化，不能误报为必然整包复制 |
| 写盘 | BufferedOutputStream 1 MiB | CameraDownloadWriter 1 MiB pendingOutput | 语义对齐；实测写盘仅 40.534 ms，不支持主要瓶颈判断 |
| 调度/心跳 | 整下载活动标记，事务间交互优先，下载期间跳过空闲探测 | CameraIOGate + PTPSession 保留上述边界 | 未发现正常下载中新增固定 sleep 或周期释放命令通道 |
| 进度/测速 | 200 ms 更新，新传字节除以协议下载总时间 | 同样 200 ms；进度另投递 actor，收包不等待 UI；扣除续传字节 | 未发现逐小包主线程同步刷新或测速口径导致倍数差 |
| 无线活跃策略 | 会话锁 + 传输锁，API29+ WifiLock LOW_LATENCY；另有 CPU WakeLock | beginBackgroundTask 保后台执行时间，不是 Wi-Fi 低延迟锁 | **平台差异**，不可宣称等价，也不可直接宣称是根因 |
| 构建选择 | 始终使用上述 Socket/PacketReader | 仅 DEBUG 的 STA 使用 BSD，Release 仍是 NW；ACK 也有条件编译 | **尚未收敛**，Debug 验证不能代替 Release 验证 |

## 源码依据

- `app/src/main/java/com/ztransfer/protocol/NikonCamera.kt`：CameraIoGate（约 194）、下载策略（约 251）、STA socket（约 1664）、downloadToFile/pump（约 3818）、分块循环（约 3990）。
- `app/src/main/java/com/ztransfer/protocol/PacketReader.kt`：buffer/headerBuf/raw、readPacketRaw/readFully。内部缓冲必须在下一次读取前消费，不是无限预取或多连接并行。
- `app/src/main/java/com/ztransfer/viewmodel/TransferViewModel.kt`：约 2265 的 1 MiB 输出缓冲。
- `app/src/main/java/com/ztransfer/service/TransferService.kt`：acquireWifiLock；`viewmodel/CameraViewModel.kt`：约 639 的会话锁。
- `ios/ZTransfer/Transport/PTP/PTPIPPOSIXChannel.swift`：receive/onQueue。
- `ios/ZTransfer/Transport/PTP/PTPIPSocketTransport.swift`：receivePTP/receive/readExactly/takeBuffered。
- `ios/ZTransfer/Transport/PTP/PTPIPCodec.swift`：PTPIPDownloadPhase.consume、ptpipReadWindow、decode。
- `ios/ZTransfer/Transport/PTP/PTPSession.swift`：完整事务互斥和活动 watchdog。
- `ios/ZTransfer/Domain/CameraRepository.swift`：downloadResult/downloadResultImpl；`CameraDownload.swift`：CameraDownloadWriter。
- `ios/ZTransfer/Domain/TransferQueue.swift`：进度回调、beginBackgroundTask；`ios/ZTransfer/UI/PhotoListView.swift`：高吞吐开关。
- `ios/ZTransfer/Transport/PTP/STAConnectionCoordinator.swift`：DEBUG 后端选择；`PTPIPSocketConnection.swift`：ACK 设置。

## 证据边界

最近真机样本 18.712666 秒、5913 次读取；recv 墙钟 18.039847 秒，排队 0.151178 秒，
Swift 恢复 0.168151 秒，工作线程其他 0.067889 秒。排队加恢复只占约 1.7%，
不能断言去掉 await 就必然从 1.5 到 3 MB/s。连续 I/O 和缓冲复用是待验证的实现差异，
不是已证实根因。读取节奏可能影响整个流水线，但必须用新实现验证。

如果此前“完全一样”的表述涵盖缓冲生命周期、执行模型或 Release，应撤回。
业务协议一致不等于底层性能行为一致。

## 审查时拟定的验证顺序

1. 隔离验证 STA BSD 连续读包体及缓冲复用，保留单命令连接、完整事务、分块和界面规则；不加入主动断开或额外业务按钮。
2. 回放拆头/拆包体/粘包/PING/END_DATA 后 response/短读错误；每次收字节仍刷新 inactivity watchdog，不能等待填满大块才刷新。
3. 明确缓冲借用生命周期：不能把可变内存套成长期存活的 Data(bytesNoCopy:) 交给允许保留 Data 的现有 sink；必要时增加同步借用接口或安全复制。
4. 相同脚本数据比较 worker 提交/恢复次数和分配，Mac 回环吞吐不能冒充真机速度；有收益证据后再集中验证 STA 真机包。
5. 最终收敛 Debug/Release 后端并分别验证；不能把只存在于诊断包的优化标记为最终完成。

## 测试审查

已阅读 Android CameraIoGateTest.kt、TransferSpeedTest.kt，以及 iOS 对应下载策略、
BSD 回显、PTP 下载回放和诊断计数断言。现有测试验证字节和计数，**不验证与安卓相同的
缓冲复用或 worker 生命周期**，后续需补覆盖。
初次审查没有生产代码变更，未重复运行测试；随后新增验证见下节，历史通过不算本轮新执行。

## 连续读取验证实现（第一阶段历史记录，最新状态以上表为准）

已在 STA Debug 使用的 BSD 下载路径接入 `withPacketPump`：一个数据相位只提交一次
readQueue 工作，持续读到 COMMAND_RESPONSE 才返回 Swift 调用方。END_DATA 仍只是
末尾数据包；PING/PONG、事务 ID 校验、响应处理和既有错误恢复沿用现有协议逻辑。
没有新增主动断开、用户取消按钮、界面状态、重试策略或固定等待。

`PTPIPPOSIXPacketReader` 按通道延迟创建并跨下载保留：64 KiB 输入缓冲、8 字节包头、
初始 1 MiB 只增长不收缩的包体。包体提供拥有生命周期的 Data 切片，不使用借用指针
包装 bytesNoCopy。同步消费完毕后可以复用；如果 sink 保留了旧包，后续写入由 COW
隔离，不能为了模仿 Android 的共享 ByteArray 而覆盖已交给调用方的数据。
这对齐的是连续读取与缓冲生命周期，不宣称 Swift/Java 分配次数完全相同。

输入余量在成功、sink 抛错等所有退出路径交还原 transport 缓冲，下一事务或恢复流程
仍可读取。每次 recv 短读都更新活动时间，不等整包收齐才刷新 inactivity watchdog。
发送仍经同一 writeQueue 串行化，未增加连接或并行 PTP 请求。普通控制命令仍走原路径。

诊断新增 `posix_phase_worker_calls`，单分块回放断言为 1。连续路径的 `receive_wait_ms`
和 `posix_syscall_ms` 统计 recv 墙钟；逐次 queue/resume 字段为 0，因为已没有逐次切换。
首次工作提交、最终恢复、组包等仍计入文件总耗时，但不计入上述 recv 字段。
不能直接把新旧 receive_wait 差值解释为端到端提速，需比较文件总时间与实收字节。

验证与限制：

- 针对性的 POSIX 与 PTP 下载回放已覆盖拆头、拆包体、粘包余量交接、非法长度、截断、
  保留旧包后继续读取、缓冲增长、PING、慢速短读超时续期、写盘失败恢复以及连续事务。
- 16 MiB 数据逐字节相等；普通命令→流式下载→普通命令→再次下载保持同一会话可用。
- iPhoneOS 27 SDK、arm64/iOS 16、Swift 6、DEBUG 的全部 PTP 源码静态类型检查通过。
- 未运行 Android Gradle、模拟器或 App 构建/安装；未取得新版真机速度。
- Debug/Release 后端仍未收敛；Release 的 NW 路径未切换。真机吞吐未验收，慢速目标未完成。
