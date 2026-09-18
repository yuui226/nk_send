# iOS STA 真机传输耗时诊断

## 范围与依据

2026-09-17 用户同意：加入内部耗时记录并打真机 Debug 诊断包，用于定位同 Wi-Fi 下
安卓约 3 MB/s、iOS 约 400 KB/s 的差距。此项不是吞吐修复，不据编译/本机测试宣称速度恢复。

对照安卓 `NikonCamera.downloadToFile` 的命令、分块、输出与进度边界；iOS 的顺序列表加载、
UI/动画、相机命令、超时、取消、连接生命周期及 TCP 参数均不因诊断改变。
仅真实 STA 的 Debug 下载创建诊断实例；AP、USB、Release 不创建实例、不写该日志。

## 采集与解读

每文件一个随机 id；记录 file_begin、chunk_begin、receiving、chunk_end、file_end。
receiving 最多每 5 秒输出一次；每次网络回调仅做内存计数，磁盘输出在独立 utility 队列执行。
日志为 JSON Lines（数值字段用保留三位小数的字符串存储），不记录照片内容、文件名、
相机地址、目录路径或设备身份。日志失败不影响传输结果。

- `gate_acquired_ms`：自开始申请本块起到拿到 CameraIOGate 的时间。
- `session_acquired_ms`：同一起点到拿到 PTPSession 的时间；减去上一项才是 session 等待。
- `command_sent_ms`：同一起点到 Network.framework 确认命令提交完成；不代表相机已收到。
- `first_read_ms`：本块第一次网络回调交付字节的时间，可能是 START_DATA，而非照片数据。
- `first_payload_ms`：首个照片数据包交给 sink 后的时间，包含该包收齐和处理所需时间。
- `receive_wait_ms`：累计等待 NWConnection receive 回调的时间，包含系统调度，不是 TCP RTT。
  `max_receive_wait_ms` / `reads_waiting_50ms` 表示最长等待及 >=50 ms 的等待次数。
- `wire_bytes` / `read_calls`：实际回调交付字节/次数，含 PTP/IP 帧开销，不能当照片有效字节。
- `payload_bytes`：本块交给输出 sink 的照片字节；`sink_ms` 包含缓冲、写盘、header/进度处理。
- `write_ms` / `write_calls` / `write_bytes`：本块实际 FileHandle.write 调用耗时、次数及尝试字节。
  **write_ms 已包含在 sink_ms 中，不能两者相加**。最后不足 1 MiB 的缓冲在文件结束时刷新，
  用 file_end 的 `file_write_ms` / `file_write_calls` 核对全文件写盘量；失败时写入字节不是落盘保证。
- `between_chunks_ms`：前一块诊断结束到下一块申请之间的时间；下一块排队另看 gate/session。
- `finalize_ms`：最终缓冲刷新、close、最终文件落位的耗时；发生于数据接收结束后。
- `response_code`：PTP 响应码的十进制值；-1 表示该块抛错、未取得响应，不臆造相机错误码。
- `success`：整个下载结果成功为 1，错误/取消为 0。若进程突然结束可能没有 file_end；
  此时不能把最后一条中途记录当完整吞吐结果。

字段按块重置，全文件写盘统计保留；文件总耗时还包含大小查询/输出预备等步骤，
可结合第一块的 file_elapsed_ms 与 chunk_elapsed_ms 区分准备开销。
日志本身只能区分 App 内阶段，不能证明 ACK stretching、重传或接收窗口的根因；
确认这些仍需相机端口抓包或有控制的真机单变量对比。

## 留存与取回

App 沙盒：`Library/Caches/Diagnostics/sta-transfer.jsonl`。
达到 2 MiB 后轮转为 `sta-transfer.previous.jsonl`，最多保留当前及上一份（阈值附近可多一条记录）。
卸载或系统清缓存会删除，测试后不要卸载。手机连接且可用后执行：

```sh
xcrun devicectl device copy from \
  --device 00008110-000C28E03481401E \
  --domain-type appDataContainer --domain-identifier com.ztransfer.ios \
  --source Library/Caches/Diagnostics \
  --destination /tmp/ztransfer-sta-diagnostics --timeout 30
```

同一位置再次取回前选择新的目标目录，保留旧样本。该命令只读取该 App 的诊断目录。
首份真机样本已按该方式成功取回，见下方记录；不需要打开日志窗或重启 App。

打包沿用 `dist-debug-ios/build.command`，新增 `IOS_SKIP_SIMULATOR=1` 开关；
本次启用此开关，不查询/构建/安装/启动模拟器。原脚本仍会向指定真机安装并启动。

## 验证进度（4/4，仅诊断采集任务，不代表慢速已修复）

- [x] 分阶段计时接入真实 STA 下载、PTPSession、NWConnection、FileHandle 输出。
- [x] 两项针对性协议测试通过：16 MiB 流式内容与缓冲内容逐字节一致，记录正确有效字节、
  网络字节及各接收边界；跨块重置统计、保留全文件写盘统计、失败标记测试通过。
  命令：`ZTRANSFER_PROTOCOL_ONLY=1 swift test --package-path ios --filter 'PTPIPTransferRecoveryTests.test(BulkDownload|DiagnosticsReset)'`。
  本机回放 buffered=13.37 ms、带诊断 streaming=14.80 ms；不作为真机速度结论。
- [x] 真机 Debug 打包：`dist-debug-ios/ZTransfer-ios-debug-1.82-20260917-214131.ipa`
  及同名 `.app`。原脚本以 `IOS_SKIP_SIMULATOR=1` 执行，`BUILD SUCCEEDED`、退出码 0；
  codesign 严格校验、IPA 完整性检查通过。安装到指定 iPhone 并启动成功，未操作模拟器。
  包内含前一任务修复的 Assets.car 与 CFBundleIcons/AppIcon；主屏图标实际显示仍由用户确认。
  构建仅出现既有 AVAssetWriter/CMSampleBuffer Sendable、方向及 AppIntents 警告。
- [x] 真机复现慢速、取回日志、依据阶段耗时确定后续修复方向：耗时集中于接收回调等待，
  排除本次下载的块间竞争与文件写入瓶颈；下一阶段需验证底层网络/TCP 行为，尚未改参数。

## 首份真机样本

用户完成下载后，从其 iPhone 成功读取诊断目录至
`/tmp/ztransfer-sta-diagnostics-20260917-2145/sta-transfer.jsonl`。
文件 id：`9793A0C9-B960-4DB0-8BF5-95DDF1356C31`，完整 file_begin 至 file_end，
success=1、响应码 8193（0x2001）。本轮未重新构建、安装、启动或修改 App 行为。

| 项目 | 实测 |
| --- | --- |
| 有效文件字节 | 24,382,922（23.253 MiB） |
| 全文件耗时 | 43,884.635 ms |
| 平均有效吞吐 | 542.59 KiB/s（0.530 MiB/s） |
| 数据请求数 | 1，offset=0，请求长度等于全部文件长度 |
| CameraIOGate 排队 | 2.990 ms |
| PTPSession 额外等待 | 约 0.043 ms |
| 首次网络回调 | 距本块开始 59.147 ms |
| 累计 receive 回调等待 | 43,631.565 ms，约占全文件 99.42% |
| 网络回调 | 3,774 次，平均约 6,462 字节/次 |
| 最长单次 receive 等待 | 340.664 ms；94 次等待 >=50 ms |
| sink 累计处理 | 51.891 ms（含该阶段写盘） |
| 全文件实际写盘 | 24 次，累计 37.955 ms |
| 最终刷新/关闭/落位 | 2.197 ms（含最后一次写盘） |

结论边界：本次是在一个已开始的数据相位内部持续缓慢，没有后续分块可供目录命令插入。
因此不能再归因于块间列表竞争、分块太小、最终保存慢、写盘调用太多或速度 UI 算错。
但 receive 等待包含 Network.framework 调度，不能将其直接称为 Wi-Fi 空口耗时，也不能仅凭
这些汇总值区分 ACK stretching、TCP 窗口、重传、路由器/相机节奏或框架回调调度。
本样本不证明其他下载场景的 UI busy 转发不存在问题，只排除它作为本次持续慢速的主因。

下一步建议是单变量真机对照：仅 STA 尝试 `tcp.disableAckStretching = true`，保留其他配置、
命令、文件、网络和诊断不变。Apple SDK `Network.framework/Headers/tcp_options.h`
说明该选项使 ACK 每隔一个数据包发送；这不同于 noDelay，也不等于设置安卓 4 MiB 接收缓冲。
依据：[Apple disableAckStretching 文档](https://developer.apple.com/documentation/network/nwprotocoltcp/options/disableackstretching)。
这是待验证假设，不是已确定根因；应先获用户同意改变参数及再次打包，再与基线比较。

## STA ACK 单变量对照（已完成，未解决慢速，源码撤回实验选项）

用户随后同意制作对照包。唯一运行行为变更是在
`PTPIPSocketTransport.parameters(sta: true)` 中设置 `tcp.disableAckStretching = true`；
STA 命令/事件连接共用该参数，AP 保持系统默认值，USB 不经过此路径。
没有同时调整 receive 缓冲、NWConnection 读取窗口、QoS、分块、写盘或 UI 生命周期。
这是 iOS 特有的受控验证，不声称安卓存在同名开关或该开关等价于安卓 socket 设置。

对照任务 **3/3 完成，仅实验完成，不代表速度修复**：

- [x] STA-only 参数及范围验证。最小协议测试
  `PTPIPTransferRecoveryTests.testACKStretchingProbeIsSTAOnlyAndPreservesNoDelayAndRouting`
  **1/1 通过**，验证 STA 开启、AP 默认、两者 noDelay 与路由约束保留；`git diff --check` 通过。
- [x] 真机对照包 `dist-debug-ios/ZTransfer-ios-debug-1.82-20260917-214819.ipa`
  及同名 `.app`。沿用原脚本并指定 `IOS_SKIP_SIMULATOR=1` 与用户 iPhone UDID，
  `BUILD SUCCEEDED`、退出码 0；codesign 严格校验及 IPA 完整性检查通过。
  设备安装、启动成功，未操作模拟器。基线仍保留为 `214131` 包与首份诊断样本。
- [x] 同网络同照片复测并取回日志，结果见下方。仍为接收等待主导，没有达到安卓速度，
  不保留未经证明的参数作为修复。

复测使用原保存位置下的新空文件夹，避免完整本地文件命中导致不走相机下载。
保留原诊断记录与原下载文件，不要求卸载/清缓存，不操作模拟器。

### ACK 对照结果与撤回

用户反馈“差不多，还是一样的速度”，日志成功取回至
`/tmp/ztransfer-sta-diagnostics-ack-20260917-2151/sta-transfer.jsonl`，其中保留基线与新增完整下载。
新增 id：`7AB8415A-6449-4A2A-8FF0-A1448DAF3C1F`，有效字节同为 24,382,922，单次请求，
响应 0x2001，success=1。

| 项目 | 基线 | 关闭 ACK stretching |
| --- | --- | --- |
| 总耗时 | 43.885 s | 40.889 s |
| 有效吞吐 | 542.59 KiB/s | 582.35 KiB/s |
| receive 等待 | 43.632 s（99.42%） | 40.632 s（99.37%） |
| 全文件写盘 | 37.955 ms | 35.644 ms |
| CameraIOGate 等待 | 2.990 ms | 7.984 ms |
| 接收回调数 | 3,774 | 3,686 |
| 最长单次接收等待 | 340.664 ms | 307.001 ms |

单次吞吐提高约 7.33%，不足以排除网络自然波动；仍远低于用户的安卓约 3 MB/s。
结论是该单变量没有解决主要差距，不能声称彻底排除了 ACK 的任何影响。
已从源码撤回 `disableAckStretching = true`，参数回归测试改为验证 STA/AP 都保持默认 ACK
策略，同时保留 noDelay 与路由约束。此轮不自动打包，因此手机仍是 `214819` ACK 对照包，
不是已回退版本。诊断采集逻辑不变。
撤回后的最小参数回归测试 `testTCPParametersPreserveDefaultACKPolicyNoDelayAndRouting`
1/1 通过，`git diff --check` 通过；未运行整套测试或 App 构建。

下一步需要 TCP 包证据。设备查询显示 CoreDevice Transport Type 为 localNetwork；
`idevice_id -l` 未列出 USB 手机，`rvictl -l` 无可用接口。请用户将 iPhone 用数据线连接 Mac
后再检查抓包条件；保持相机连接方式仍为 STA，避免把 USB 调试线误解为相机 USB 模式。
目前未抓取其他 App 流量、未重新握手相机，也未修改接收缓冲或换网络实现。

### USB 抓包第一次尝试：摘要被截断，不可用于 TCP 结论

用户连接 USB 后，`idevice_id -l` 能识别指定 iPhone，`rvictl -s` 创建 `rvi0` 成功。
当前进程读取 BPF 被拒绝，因此由用户在自己的终端执行 sudo tcpdump。
此前给出的 `-s 128` 未考虑该 Mac 的 PKTAP 附加头长度，是代理提供参数的错误。
`/tmp/ztransfer-sta-tcp-2152.txt` 中 24,754 条均为 `[|pktap]`，只有时间戳，没有可解码的
TCP 序号/ACK/窗口；不能从此样本推断丢包、重传、接收窗口或相机发包节奏。

同期 App 日志成功取回 `/tmp/ztransfer-sta-diagnostics-pcap-2155/sta-transfer.jsonl`。
新增 id `1ECF5FB0-A681-403B-9B43-597B8EBC0DB1`：同为 24,382,922 字节，完整成功，
总耗时 42,360.994 ms，receive 等待 42,114.663 ms，写盘 35.532 ms；仍没有恢复吞吐。
手机仍为 ACK 对照包，没有在本次采集中改变 App 或相机连接。

补采改用 `-s 0`，仅输出相机端口的文本 TCP 摘要，不使用 `-w` / `-A` / `-X`，
不保存照片载荷。应先让用户启动采集，检查真实文本中已出现 TCP seq/ack/win/length，
确认格式有效后再让用户重传同一文件，避免再次消耗无效真机测试。

### 有效 TCP 摘要：接收端没有明显窗口耗尽，存在周期性到包空档

修正 snaplen 后先检查 seq/ack/win/length 可读，再请用户传同一文件并停止抓包。
有效输入 `/tmp/ztransfer-sta-tcp-full-2155.txt` 共 27,976 行；只分析下载请求（第 4597 行）
至最终 ACK（第 27532 行），不将前后列表/空闲命令混入下载吞吐。
分析脚本 `/tmp/analyze_sta_tcp.py` 按 TCP 序号区间合并统计，重复字节不计入有效吞吐；
此次序号未回绕，唯一 38 字节请求作为候选，再以应用记录的 24,387,716 个协议字节核对终点。
完整序号覆盖恰好等于该长度，没有用包数猜测文件是否完整。

App 样本：`/tmp/ztransfer-sta-diagnostics-tcp-valid/sta-transfer.jsonl`，
id `548909B7-2252-4C22-8330-C810E744868C`。24,382,922 字节，success=1，
总耗时 41,477.319 ms，receive 等待 41,224.192 ms，写盘 33.573 ms。
TCP 请求到最终 ACK 为 41.466 s，与 App 时间一致，不是 App 提前收完后卡在保存阶段。

| TCP 摘要指标 | 结果及边界 |
| --- | --- |
| 数据段 | 19,200 个，其中 84 个与已见序号重叠 |
| 重复字节 | 110,660（约 0.45%）；单点 RVI 不能把所有重复直接认作无线丢包 |
| 手机窗口字段 | 本段 3,735 个手机 ACK 均为 65,535，无零窗口；没有 SYN，不能推断协商缩放倍数 |
| 已见但尚未累计确认字节 | 最大 17,172；不是相机端真实拥塞窗口，也不能看到仍在空中的包 |
| 最新一批新数据到完整 ACK 的本机间隔 | 中位 0.201 ms、P90 0.286 ms、P99 1.011 ms |
| 新数据到达间隙 >=50 ms | 81 次，总计 8.777 s；其中 74 次在空档开始后 1 ms 内已发出覆盖前一数据段的 ACK |
| 80–120 ms 到达空档 | 75 次，其相邻起点间隔中位 523.31 ms（部分空档被更长停顿替代） |
| 以 >1 ms 间隙划分的到达批次 | 3,517 批，字节数中位 6,265，批次起点间隔中位 12.17 ms |

解释：未观察到接收窗口耗尽；通常 ACK 很快交给本机网络层，但新数据迟迟不到达。
RVI 时间戳不是无线实际发射/对端收到时间，所以不能说相机一定已经收到 ACK，或直接将
周期性空档判为 iOS 节能/AWDL。少量重复字节也可能造成拥塞退避，不能只因比例小就彻底排除。
这些证据缩小到协议栈/无线交付及发送端节奏，尚不能分清相机、路由器、无线共存或系统驱动。

### 补查安卓的无线低延迟能力（此前传输路径对照遗漏）

`CameraViewModel.kt:639` 定义会话级 WifiLock，并在 `activateStaCamera` 接受会话时 acquire；
`TransferService.kt:108` 另在 Wi-Fi 传输期间 acquire。Android 10+ 选择
`WIFI_MODE_FULL_LOW_LATENCY`，旧版本用 `WIFI_MODE_FULL_HIGH_PERF`。
iOS `TransferQueue.beginBackgroundTransferActivity` 只有 UIApplication 后台执行时间申请，
不是等价的无线低延迟锁。这是已证实的平台能力差异，不是已证实的慢速根因。
Android 官方还限定低延迟锁只在已连接 AP、亮屏、持锁 App 前台时生效，设备支持也有影响：
[WifiManager 文档](https://developer.android.com/reference/android/net/wifi/WifiManager#WIFI_MODE_FULL_LOW_LATENCY)。

iOS 代码检查未发现主动启用 includePeerToPeer，Bonjour 在发现完成/取消后停止；
未发现传输中主动以半秒节奏扫描 Wi-Fi 的代码。不凭这份 TCP 文本臆造一个“iOS WifiLock”。
`NWParameters.serviceClass` 主要描述出站服务要求，不保证入站优先级，也不能当作关闭无线节能
的等价开关：[Apple ServiceClass](https://developer.apple.com/documentation/network/nwparameters/serviceclass-swift.enum)。

历史建议（用户随后明确否决，已停止该方向）：保持当前 App、相机和 Wi-Fi 不变，仅在 iPhone **设置 > 蓝牙**临时关闭蓝牙，
同文件/新空目标目录复测，完成后恢复。该测试会暂时断开蓝牙配件；不是正式解决方案，也不要求
用户永久关蓝牙。Apple DTS 将蓝牙/点对点无线干扰列为需要排查的因素，并强调控制中心不等于
完全关闭蓝牙：[Investigating Network Latency Problems](https://developer.apple.com/forums/thread/45210)。
若没有改善，应继续收集双端/无线层证据或设计受控底层传输对照，不能重复将缓存/写盘作为主因。

本轮仅分析、代码阅读及文档记录，没有修改 App、重新构建或安装，也没有切换用户系统设置。

## 回到字节接收实现：BSD Socket 候选通道

用户明确要求不再排查蓝牙；此后不再安排蓝牙/省电设置实验。当前根因仍未得到证明，
后续以安卓 Socket 与 iOS Network.framework 的实际接收实现为比较对象。

新增 `PTPIPPOSIXChannel`：按安卓在 connect 前设置 4 MiB SO_RCVBUF、TCP_NODELAY，
绑定发现阶段的本地 IPv4 地址；读取最多 64 KiB，处理短读/EINTR，发送循环处理部分写入。
接收和发送分别放在专用 DispatchQueue，阻塞系统调用不占用 Swift 协作线程，也不堵住
取消请求的发送通道。connect 用 nonblocking connect + poll 截止时间，建立后恢复 blocking。
SO_NOSIGPIPE 为 Darwin 平台所需；失败不悄悄换路由，也不把实际内核缓冲大小当成请求大小。

候选通道只替换字节 I/O。新增 `PTPIPSocketConnection` 适配层，仍复用现有
PTPIPSocketTransport 的 Init 握手、帧解析、session、取消及 drain，不复制第二套协议状态机。
已接收 socket 不因单个调用者取消而关闭；关闭时先 shutdown 唤醒阻塞 I/O，所有已开始的
系统调用退出后才 close fd，避免描述符重用错误。连接建立失败仍回收自己持有的未接受连接。

诊断新增 `bsd_socket` 与 `kernel_receive_buffer_bytes` 字段，后者由 getsockopt 实测；
NW 后端无该数值时记录 -1，而非把 maximumLength 伪装成内核缓冲。
默认后端仍是 Network.framework，当前 App 的 STA/AP 路径均未选用候选通道，USB 不变。
没有重新打包/安装/启动或建立相机的第二会话。**新增通道不等于速度修复完成**。

验证记录：

- 最初 5 项字节通道测试有 4 项失败，原因是测试 NWListener 的端口为 0 时就启动客户端；
  修正测试服务器就绪条件后 5/5 通过，不把初次失败计为通过。
- 后续补充不可绑定地址不得换路由，字节层 6/6 通过；真实 getsockopt 返回的内核缓冲
  满足 4 MiB，2 MiB 回显内容逐字节一致，取消调用者不关闭连接，close 唤醒/拒绝排队 I/O。
- 同一 PTP fixture 分别验证 NW/BSD。BSD 16 MiB 流式与缓冲内容一致；取消后排空再执行下一
  命令、写盘错误保留原错误、3 秒静默排空超时回收、持续慢速排空不误超时、分包到达续期均通过。
- 本机回放仅验证实现与开销，不代表相机的手机吞吐。不能以本机十几毫秒宣称达到安卓 3 MB/s。

本阶段 **2/4 完成**：

- [x] 与安卓同类的 BSD 字节通道及共享 PTP 适配层实现。
- [x] 最终两组专项测试 **22/22 通过**（6 个字节层、16 个 NW/BSD 协议/诊断测试）；
  全部 PTP Swift 文件针对 iPhoneOS arm64/iOS 16 SDK 的 Swift 6 静态类型检查通过，
  工程 plist 与 diff 检查通过。未启动模拟器，未链接/打包 App。
- [ ] 获准后仅 STA 启用候选通道并生成真机 Debug 包，确认实际后端与内核缓冲日志。
- [ ] 真机同文件速度验收及连接/列表稳定性验证；未达成前不将总目标标记完成。

仍需真机验证节点：明确启用 STA 的 BSD 后端、生成获准 Debug 包，再传同一文件；同时记录
实际内核缓冲、阶段耗时与 backend 标识。只有该结果显著改善且连接/取消/列表行为保持正确，
才能决定是否保留并作为修复；没有改善则继续检查实际握手/收包差异，不将候选默认合入。

### 获准启用真机对比

2026-09-17 用户“来啊不要墨迹”明确同意前述打包、安装和真机对比。
STAConnectionCoordinator 仅在 DEBUG 选择 BSD；AP、USB 和 Release 保持原后端。
BSD 连接超时/拒绝使用与 NW 相同的暂时未就绪判定，不增加新的重试规则、界面或操作。
本轮不新增取消/主动断开功能；只比较字节接收方式。构建安装和真机速度结果待记录。

本轮验证节点进度 **3/4**（实现、独立验证、打包安装已完成；真机吞吐验收未完成）：

- 补充 BSD 错误分类断言，`STAConnectionCoordinatorTests.testRetryClassificationAndBackoffMatchAndroid`
  **1/1 通过**，未运行全量测试；`git diff --check` 通过。
- `IOS_SKIP_SIMULATOR=1 IOS_DEVICE_ID=00008110-000C28E03481401E bash dist-debug-ios/build.command`
  返回 0，`BUILD SUCCEEDED`，签名和 IPA 校验成功，未操作模拟器。
- 产物 `dist-debug-ios/ZTransfer-ios-debug-1.82-20260917-221726.ipa`；CoreDevice 确认
  安装并启动 `com.ztransfer.ios` 成功。
- 完整构建安装输出：`/tmp/ztransfer-sta-bsd-device-build-20260917.log`。
- 仍待用户同文件传输，读取新的 `bsd_socket=1` / 实际内核缓冲日志并比较耗时。
  安装成功不代表速度已改善。

### BSD 真机首轮结果：有提升，尚未达到安卓

用户反馈“快了一些，但是还是赶不上安卓的速度”。日志取自
`/tmp/ztransfer-sta-bsd-measurement-2219/sta-transfer.jsonl`：三次完整成功传输均为
`bsd_socket=1`、`kernel_receive_buffer_bytes=4194304`，响应 0x2001。

| 样本 ID 前缀 | 文件字节 | 完整耗时 | MiB/s | 接收等待占比 | 写盘耗时 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 8EA134FE | 24384880 | 17.776 s | 1.308 | 98.91% | 35.434 ms |
| 6D9A20FD | 10047960 | 7.724 s | 1.241 | 97.54% | 17.710 ms |
| 1C5ACDA9 | 24481210 | 18.757 s | 1.245 | 98.94% | 35.078 ms |

上轮 NW 的 24382922 字节文件为 40.889–43.885 s、0.530–0.569 MiB/s。
本轮文件大小不同，因此不能声称严格同文件 A/B，也不能把接收框架和缓冲设置的组合效果
全部归因于某一个选项。数据与用户反馈一致，支持保留 BSD 继续验证；仍未达到用户所述
安卓 3 MB/s 以上的目标，不能标记传输速度修复完成。

下一步补充 TCP_CONNECTION_INFO 只读快照：每个传输分块开始保存基线，现有五秒检查点及
结束日志记录接收窗口/缩放、MSS、协商选项、接收计数和乱序字节。累积计数同时转为分块差值，
避免将前序列表/缩略图流量计入当前文件。仅读取 TCP_SENDMOREACKS 的现值，不修改 ACK 策略。
不增加新传输命令或界面，不增加用户取消/断开行为，不改变已经生效的缓冲参数。

字段依据：[Apple XNU TCP 实现](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp_usrreq.c)
的 `tcp_connection_fill_info`，及本机 iPhoneOS SDK 的公开 `netinet/tcp.h`。
手机发送端 RTT/重传计数不能代表相机发送端拥塞窗口或相机重传数；离散快照也不能排除采样间的
短暂窗口耗尽。未成功取得的快照明确标为不可用，不能当成零丢包或零窗口。

只读快照的本机字节回显与现有协议专项 **17/17 通过**；增加分块差值、NW 不可用及分块重置
断言后定向 **3/3 通过**。iPhoneOS arm64/iOS 16、Swift 6、DEBUG 类型检查通过。
本次尚未重新打包/安装，真机 TCP 快照数据仍待新包验证。

随后用户“不要墨迹直接干”授权安装：运行相同 `IOS_SKIP_SIMULATOR=1` 真机打包命令，
`BUILD SUCCEEDED`、脚本返回 0，签名/IPA 检查通过。已安装并启动
`dist-debug-ios/ZTransfer-ios-debug-1.82-20260917-222219.ipa` 对应 App；
再次查询 CoreDevice 进程，确认新安装路径下进程 PID 1849 存活。未操作模拟器。
构建记录 `/tmp/ztransfer-sta-tcp-state-device-build-20260917.log`。
此包只补充只读 TCP 状态日志，未更改 BSD 缓冲区或 ACK 参数；等待同文件实测数据。

### TCP 首份实测与 BSD ACK 单变量对照

`/tmp/ztransfer-sta-tcp-state-measurement-2224/sta-transfer.jsonl` 的样本
`1D0443A3-5953-4610-A1D1-5284777D5CA3` 成功接收 10065709 字节，耗时 9.599 s，
1.000 MiB/s，接收等待 98.91%，写盘 16.255 ms。与上一轮文件仍不等长，不能做严格同文件速度结论。

- 只读快照生效：接收缓冲实际 4 MiB，但 TCP 接收窗口为 65535，缩放 0，协商选项 0，
  MSS 1460。当前连接没有协商窗口缩放、SACK 或时间戳；不能声称 4 MiB 缓冲已经放大线上窗口。
- 分块接收乱序计数 354493 字节，相对内核接收计数 10087028 为 3.51%。这是乱序计数，
  不是丢包率或可直接等同的重传字节。
- `tcp_send_more_acks=0`；手机发送侧平滑 RTT 为 28 ms。该 RTT 与离散窗口快照不足以证明
  相机受窗口限制，不能据此计算并宣称吞吐硬上限。

下一项单变量：仅 Debug 的 BSD 适配器传入 `sendMoreACKs=true`，通过公开
`TCP_SENDMOREACKS` 提高确认频率，保持现有缓冲、PTP 请求、帧处理和文件写入不变。
直接字节通道默认仍 false；AP/NW/USB/Release 均不变。
依据：[Apple TCP 手册](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man4/tcp.4)
对该选项的定义；属于平台网络栈对照，不是安卓新增业务功能。
先前 NW 的类似设置未显著提升，此次是在已改善的 BSD 路径上验证，必须以实际 option=1
及同文件速度为依据；未改善就不把该开关作为修复保留。没有新增取消/主动断开功能。

选项实际生效/短读完整性、BSD 16 MiB 内容与诊断、NW 配置未变的定向测试 **3/3 通过**。

沿用户“不要墨迹直接干”的真机对照流程，已生成并安装启动
`dist-debug-ios/ZTransfer-ios-debug-1.82-20260917-222433.ipa`：脚本返回 0、
`BUILD SUCCEEDED`，签名及 IPA 校验通过，未操作模拟器。
构建输出 `/tmp/ztransfer-sta-bsd-ack-device-build-20260917.log`。
尚待该包同文件传输结果，不将 ACK 改动或整体速度目标标记完成。

### BSD ACK 对照结果：有效启用，速度较高但样本不同

取回 `/tmp/ztransfer-sta-bsd-ack-measurement-2226/sta-transfer.jsonl`：
样本 `600A8114-EDE1-4E8C-A8B9-819961C09EAF`，24530733 字节，14.744521 秒，
**1.586646 MiB/s**，成功、响应 0x2001，`tcp_send_more_acks=1`。
接收等待占比 98.69%，写盘 34.579 ms；接收窗口仍为 65535、缩放/选项均为 0。
乱序计数 230339 / 内核接收计数 24559325 = 0.938%，不能当成丢包率。

本轮比之前 BSD 默认 ACK 的 1.00–1.31 MiB/s 样本高，但文件不同、没有重复样本，
还不足以证实 ACK 参数的因果收益或稳定速度。暂保留真机对照设置，不扩大到 Release，
不继续叠加无证据的网络参数。原本要求同文件测试时没有说明本地文件会命中跳过，
是验证流程遗漏：TransferQueue 在发送相机命令前查找目标目录同名同大小原图并直接完成。
有效重复测试应选择空的传输目标目录，手动重新加入同一文件；为避免混淆前后记录，
可以移除旧完成卡片，但手动 enqueue 本身允许同文件新任务，不强制清卡片。
任务记录移除不删除导出照片，不需要卸载 App 或清缩略图缓存。下一步对同一相机文件
在 iOS/Android 当前相同网络分别取真实传输结果，避免比较不同文件或历史速度。

用户随后明确“不需要搞同一个文件，你只需要看速度就行了”。此要求优先：后续接受任意文件的
实际传输速度，不再要求同文件、切空目录或清任务记录。仍如实保留样本差异，避免声称单样本
已经证明某选项的因果收益；保留当前 BSD + more ACKs 真机设置，继续定位剩余耗时。

### 拆分 recv 调度时间与系统调用时间

旧 `receive_wait_ms` 包含 DispatchQueue 排队、recv、缓冲操作和 Swift 恢复执行时间。
因此 98%–99% 的接收等待不能全部视为网络耗时。安卓在 Dispatchers.IO 的同步读写循环中
连续读包，而当前 iOS 每次底层读取通过专用队列返回 Swift，需要实测该差异的开销。

新增诊断按每次成功底层读取累计：排队时间 `posix_queue_wait_ms`、recv 墙钟时间
`posix_syscall_ms`、工作线程其他时间 `posix_worker_other_ms`、Swift 恢复时间
`posix_resume_wait_ms`，并记录 >=50 ms 的 recv 次数和累计时间。这些是已有等待时间的
细分，不可叠加到总耗时；recv 墙钟仍可能包含操作系统抢占，不能当物理网络 RTT。
诊断关闭时不读时钟、不新增 I/O，保持缓冲、ACK、读包及写盘规则不变。
系统调用后先保存 errno，避免计时 API 干扰失败处理。

字节回显/BSD 下载 **2/2 通过**；补充计数一致、细分不超过外层总等待、NW 内容一致与
分块重置断言后定向 **3/3 通过**。目前未取得该细分的真机数据，不能据此声称调度是瓶颈。

真机诊断包 `dist-debug-ios/ZTransfer-ios-debug-1.82-20260917-222829.ipa` 已打包、安装并启动，
脚本返回 0、`BUILD SUCCEEDED`，签名/IPA 校验通过；始终 `IOS_SKIP_SIMULATOR=1`。
构建记录 `/tmp/ztransfer-sta-recv-phases-device-build-20260917.log`。
下一轮允许任意文件，读取调度/系统调用细分后再决定优化，速度目标仍未完成。

### 真机 recv 细分结论与握手再核对

`/tmp/ztransfer-sta-recv-phases-first-check/sta-transfer.jsonl`，样本
`40E4955C-98E2-4968-8EF9-53E726E52BCD` 成功接收 10115567 字节，6.218494 秒，
**1.551333 MiB/s**，BSD 与 ACK=1 均生效。按用户要求直接判断实际速度，不要求同文件。

- recv 墙钟 **5972.329 ms（96.04%）**；专用队列等待 49.835 ms，Swift 恢复 57.511 ms，
  工作线程其他开销 22.884 ms；写盘 15.778 ms。
- 即使静态扣除所有 recv 以外的实测时间，也仅对应约 1.615 MiB/s，远不足以解释与安卓
  3 MB/s 以上的差距。此计算不是更换接收时序后的预测，但足以否定“主要耗在 Swift 排队”的说法。
- 13 次 >=50 ms 的 recv 合计 1175.071 ms，占总时间 18.90%。其余等待也不可忽略，
  不能把全部差距归因于那 13 次停顿。
- 接收窗口仍为 65535，无窗口缩放/SACK/时间戳。recv 等待包含内核调度，尚不能仅凭本日志
  区分相机发包、路由器、手机无线驱动/协议栈，不能把这些候选直接写成已确认根因。

再次对读 Android `makeStaInitReq`/`initializeStaBrowsingSession`/`sendCmd`/下载分块和
iOS `staInitCommandRequest`/`STABrowsingSession.open`/`CameraRepository`：当前 STA
探索入口均开启完整存储探测，初始化顺序、16 字节身份字段、UTF-16LE 名称、32 位版本、
0x9431 的五参数和 dataPhase=1 一致；没有发现遗漏的相机加速命令。已有对应字节与脚本测试
已检查，本轮未重复跑这些未改动的测试，也未打包安装新包。

只读检查 `adb devices -l`：当前没有连接安卓设备。`/dev/bpf0` 仍仅 root 可读，当前没有
活动 rvi0 tcpdump；不能声称正在抓包。下一步需要安卓端的当前运行/链路对照，而不是继续
叠加无证据的 socket 参数或重写已证明只占少量时间的文件/调度代码。

用户询问“必须要抓安卓包吗”后纠正后续路径：**安卓设备/抓包不是继续排查的必需条件**。
此前将其视为唯一下一步不准确；继续使用 iOS 已安装包和 RVI TCP 摘要即可排查本端收发时序。
不再要求安卓接线、同文件或重新安装。现有旧抓包来自 NW，不能当成 BSD+ACK 当前行为证据。

检查当前设备 RVI 注册显示 `(null)`；执行 `rvictl -s` 成功创建 **rvi1**（旧 rvi0 仍存在，
不能继续硬用旧接口）。`sudo -n tcpdump -D` 明确返回需要密码，BPF 仅 root 可读；
不绕过该权限，不让用户把密码发到聊天。需要用户在本机终端启动只保存 TCP 包头摘要的命令。
分析脚本 `/tmp/analyze_sta_tcp.py` 补充候选请求清单和显式行号选择，避免背景缩略图的多个
38 字节命令导致错误匹配；仍需精确匹配新日志的 wire_bytes，不能猜测哪一段是下载。

### BSD+ACK 的有效 RVI 抓包：周期性收包停顿

用户完成抓取，`tcpdump` PID 70374 已退出。保留文件
`/tmp/ztransfer-sta-bsd-tcp-current.txt`（107817 行，TCP 摘要，不含照片内容）、
`/tmp/ztransfer-sta-bsd-capture-diagnostics-2235/sta-transfer.jsonl`。
App 样本 `D2F44725-D191-4B6B-8354-A7815BD9CF92`，24540994 字节、14.453002 秒，
约 1.62 MiB/s，接收协议总字节 24545812。

分析显式选择请求行 129（38 字节命令），TCP 唯一序号连续覆盖 **恰好 24545812 字节**，
从命令至最终 ACK 为 14.442280 秒，与 App 耗时吻合。原始 RVI 存在同一包的重复观察和
成批写出导致的时间戳倒序；脚本已先按包时间戳排序，再用区间并集计算首次出现的字节。
原始约 49 MB 的 TCP 长度求和不是实际下载大小，重叠字节也不能当作重传率。
报告 `/tmp/ztransfer-sta-bsd-tcp-current-analysis.json`。

- 有 27 次 >=50 ms 的新数据到达间隔，合计 2524.160 ms（约 17.5%）。这 27 次的
  起始间隔中位数 **524.747 ms**（515.767–533.414 ms），具有明显周期性。
- 27 次停顿前，接收侧都在 **1 ms 内**确认了已观察到的全部数据；完整 ACK 延迟中位数
  0.225 ms，p99 0.877 ms，最大 1.377 ms。没有证据支持继续提高 ACK 频率解决周期停顿。
- 抓取到的手机 ACK 窗口全为 65535；最大观察未确认跨度为 65535，但不能将它直接认定为
  相机拥塞窗口或持续窗口耗尽。当前分析也不足以区分相机、AP、无线驱动和系统网络栈。
- 即使扣除这 27 次停顿，当前样本折算吞吐仍不到安卓所报 3 MB/s，不可把整个差距只归因于
  周期停顿。没有蓝牙根因证据，不重启该排查方向。

查阅 iPhoneOS SDK `SO_NET_SERVICE_TYPE` 与 Apple 网络服务文档：分类应匹配业务，
不能把照片批量下载伪装为语音/视频来抢优先级；不据此盲加 QoS 参数。
参考：[Apple 服务类别](https://developer.apple.com/documentation/network/nw_service_class_responsive_data)。

为排除测量环境的干扰，先清理本轮和前轮创建的两个 RVI 注册（仅 Mac 抓包接口，
不是关闭 App 的相机连接；原始日志全部保留），不改包、不修改用户 Wi-Fi/蓝牙配置。
下一步拔 USB 后在现有 App 前台传任意文件看速度，再接回读取日志。
这是测量环境对照，不表示已确认 USB 或调试导致慢速。

### 脱线测试：仍有接收长等待，不能归因于抓包本身

用户完成测试后取回
`/tmp/ztransfer-sta-unplugged-measurement-2240-final/sta-transfer.jsonl`。
新增 5 个成功样本实际速度为 1.625、1.562、1.787、1.664、1.752 MiB/s，
仍低于用户所报安卓速度；没有通过再次改包或设置制造额外变量。
其中 24288136 字节样本为 12.958614 秒、recv 12.453629 秒、25 次 >=50 ms recv
合计 2.291642 秒；24166979 字节样本为 13.157398 秒、26 次长 recv 合计 2.366128 秒。
拔线和移除 RVI 没有消除接收长等待；不能将 USB 或抓包认定为主要根因。
这批只读阶段累计不能证明每次停顿仍恰好相隔 0.525 秒，因此不把此前 RVI 周期直接套入。

再次对照 Android 的会话/传输 WifiLock，确有平台能力差异，但不能由此证明该差异就是
当前瓶颈。Apple `responsiveData` 是业务类别提示，不是 Wi-Fi 低时延锁；暂无证据支持
把它当等价修复，未修改服务类别、蓝牙或其他系统设置，未新打包。

转向 iPhone 系统 `wifid` 日志：本机已有 idevicesyslog，可按进程过滤，不需安卓或 sudo。
当前 `idevice_id -l/-n` 都为空，USB 树也未见手机，不能将 devicectl 能复制文件当成 USB
已接入。已启动只读采集命令（仅 wifid 进程）等待指定 iPhone 接入：
`idevicesyslog -u 00008110-000C28E03481401E --no-colors -p wifid -x`，
输出 `/tmp/ztransfer-iphone-wifid-20260917-2240.log`。
此时仅打印 Waiting for device，尚未取得系统 Wi-Fi 日志，不声称已找到扫描/省电根因。

随后 USB 枚举已出现指定 iPhone，同一采集进程开始正常输出 wifid（未重新启动另一份）。
22:43 的传输前样本显示 5 GHz、信道 36、80 MHz，RSSI 约 -44 dBm；当前没有依据把
问题归为 iPhone 误连 2.4 GHz 或弱信号。此为传输前链路状态，不能替代传输期间的数据。
原始日志包含 SSID/BSSID 等本机网络信息，仅保留在上述 /tmp 文件，不写入技术报告。
LQM 统计行即使标记 Error 也只是日志级别，不能据此认定实际故障。
已告知用户可以开始任意文件传输，采集保持运行，完成后再关联 App 耗时数据。

### wifid 传输期间结果：未发现扫描/漫游证据，根因仍未确定

用户完成后取回 `/tmp/ztransfer-sta-wifid-correlated-2244/sta-transfer.jsonl`。
样本 `AB6C1637-48AC-4FC5-9DBF-0CBB98985603` 成功下载 29342381 字节，
18.712666 秒，约 **1.495 MiB/s（1.568 MB/s）**，仍未达到安卓所报 3 MB/s 以上。
同一份 BSD+ACK=1 包、4 MiB 接收缓冲，没有修改连接参数或用户系统设置。

- recv 墙钟 18039.847 ms（96.40%）；队列等待 151.178 ms、恢复等待 168.151 ms、
  工作线程其他时间 67.889 ms；写盘 40.534 ms。38 次 >=50 ms recv 合计 3727.317 ms。
- wifid 在 22:43:26–46 的 5 秒统计快照中，持续为 5 GHz、信道 36、80 MHz，
  RSSI -49 至 -42 dBm。RX 重试比例 0.2–0.6%，TX 重试比例 3.6–6.1%；
  接收 FIFO 溢出与 rx_nobuf 为 0。业务流量为普通 BE，未见被标记为后台 BK。
- 本次完整日志未发现实际扫描开始/完成、漫游或信道切换事件；反复打印的
  `EvaluateAPEnvironment` / `RoamCache` 只是评估及缓存信息，不能当发生了漫游。
  也未取得能解释接收停顿的 Wi-Fi 睡眠/唤醒事件。缺少事件不证明绝对没有发生。
- CCA 快照为 15–68，不能只由信号强就宣布链路不存在争用；手机侧重试统计也不覆盖
  相机到 AP 的另一段链路。`TxRate` / `RxRate` 不是应用有效下载速度。
- App 日志没有绝对时间字段，此处按用户操作及系统流量上升/回落定位传输时段，
  不是逐次 recv 与系统事件的精确时间关联。未将旧 RVI 的 0.525 秒周期强套到本次。
- 再读 `PTPIPDiscoveryService.swift`：Bonjour 发现首地址/超时后停止浏览及解析，
  发现返回会结束其子任务；没有启用 includePeerToPeer，也没有连接后持续扫描的代码。
  未发现可据此直接修复的扫描泄漏，不修改已验证的发现生命周期。

已核实并结束本次 Mac 上的 idevicesyslog 采集进程（PID 71070，退出 0），
确认没有剩余 idevicesyslog/tcpdump；**没有关闭 App 相机连接**。
本轮只读检查与记录结果，未改业务源码、未构建/安装、未运行未改动的测试。
目前证据仍不足以在相机、AP 与 iPhone 无线驱动/网络栈之间确认根因，不能标记问题解决。

### 后续 AP 对照的限制

已请用户用现有包的相机热点 AP 模式传任意文件反馈速度，不要求安卓、同文件或重装。
再次核对当前源码：`WiFiConnectionService.connectAP` 使用默认 Network.framework，
而 STA Debug 使用 BSD+ACK；AP 也不会创建当前仅 STA 启用的文件诊断记录。
所以该观察只能补充“当前两条完整路径的速度表现”，**不能将差值单独归因于 STA 网络模式**，
也不能因 STA JSONL 没有新记录而判断 AP 测试未发生。若需要严格模式对照，应先控制接收
后端和诊断覆盖，不能直接沿用这次粗对照下因果结论；目前未扩改 AP 实现或安装新包。
只读取回 `/tmp/ztransfer-sta-check-after-wifid-2255/sta-transfer.jsonl`，最新仍为
`AB6C1637-48AC-4FC5-9DBF-0CBB98985603`；尚无用户反馈的 AP 实际速度。

### 范围纠正：只继续 STA，不以 AP 测试为前提

用户明确指出当前任务只处理 STA。撤回 AP 测试要求，不切换相机模式、不修改 AP 代码，
也不再把等待 AP 结果作为继续工作的阻塞条件。

复查现有两份有效 STA TCP 摘要，按原分析脚本去重后的新字节区间统计：
BSD+ACK 样本 26866 个新增数据段中，<=128 字节有 8286 个，占段数 30.84%，
但只占字节数 2.11%；旧 NW 样本则为 19116 段中的 286 段，占 1.50%，
只占字节数 0.080%。小包较多的 BSD 样本反而更快，所以不能仅由小包比例断言根因。
BSD 样本 10–50 ms 段间隔有 362 次、合计 5.018 秒；旧 NW 为 2033 次、合计 29.006 秒。
这进一步表明已改善的不只是约 0.525 秒一次的长间隙，仍不可把所有差距归为该周期。
两样本不是受控同文件同时 A/B，也不能据此孤立归因于 ACK 参数。

复核 Apple XNU `tcp_connection_fill_info`，确认公开 `TCP_CONNECTION_INFO` 的
options/wscale 是按协商状态填充，不是未实现的恒零字段；当前窗口未缩放的诊断解读仍成立。
没有 SYN/SYN-ACK 记录仍无法确认未协商的具体原因，不能靠扩大 SO_RCVBUF 宣称解除窗口上限。
依据：https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp_usrreq.c 。
本轮没有据此盲改 ACK/接收窗口/QoS，也未重新构建或安装。
另只读调用指定 iPhone 的 `idevicediagnostics diagnostics WiFi`，接口返回
`WifiInfoDeprecated`，没有得到额外无线统计；不把退出码 0 当诊断数据已可用。

### STA 握手证据缺口

再查两份有效 TCP 摘要，没有 SYN/SYN-ACK、wscale 或 sackOK；早期 2152 摘要仅为
截断的 `[|pktap]`，也无法恢复握手。只读取得
`/tmp/ztransfer-sta-handshake-audit/sta-transfer.jsonl`，最新仍为 AB6C1637 样本。
当前只能确认已建立连接未协商窗口缩放，不能确认 iPhone 是否提出过缩放、对端如何回应，
也没有证据证明这就是与安卓速度差距的根因。

USB 已连接，当前无 tcpdump/idevicesyslog；`rvictl -l` 未列出活动设备。
`sudo -n tcpdump -D` 返回需要密码，不能自行启动特权抓包或把任务当作已在采集中。
后续仅补 STA 正常建连的包头摘要，不改 AP、不装包，不主动关闭 App 相机连接；
需要用户在本机终端授权抓包，并在其正常重新连接 STA 时取得该段证据。

### STA SYN 实测：手机提出扩展，对端仅回复 MSS

随后用户启动采集，实际 tcpdump PID 72451（root），
`/tmp/ztransfer-sta-handshake.txt` 已有 3 对 SYN/SYN-ACK，不再处于等待抓包启动状态。
手机 SYN 均为 SEW，选项 MSS=1460、wscale=6、时间戳、SACK permitted；
相机方向 SYN-ACK 均为 S+ACK，窗口字段 32768，选项仅 MSS=1460。
因此不能再怀疑 iOS 没提出窗口缩放；手机请求已经发出，但这次对端响应没有接受扩展。
相机 SYN-ACK 的 32768 是相机接收窗口，不是手机接收窗口，不能套成下载的直接上限。
手机接收窗口未缩放仍不足以解释全部速度差距，也不能推断安卓连接协商状态。

为验证 SYN 中 ECN 请求是否与缺少窗口扩展有关，在 Mac 的同一 STA 相机地址上
顺序做 2 次 TCP-only 探测：只建立 TCP，读取公开 TCP_CONNECTION_INFO，然后释放探测
自己的套接字；未发送 PTP/InitCommand/OpenSession 命令，未操作手机既有相机会话。
本机路由确认为 en0 直达相机子网，均设置 TCP_NODELAY、4 MiB SO_RCVBUF：

| ECN 请求（TCP_ENABLE_ECN） | TCP 建连耗时 | 协商 options | snd/rcv scale |
| --- | ---: | ---: | --- |
| 0 | 84.841 ms | 0 | 0 / 0 |
| 1 | 12.084 ms | 0 | 0 / 0 |

两次实际 SO_RCVBUF 均为 4194580，状态均为 ESTABLISHED。这个小样本说明从 Mac
关闭 ECN 也没有得到窗口扩展，不支持据此给 iOS 增加“禁用 ECN”的改包试验；
Mac 握手不是 iPhone 吞吐测试，两个建连时间也不能作为 ECN 的性能 A/B。
TCP_ENABLE_ECN 是 iPhoneOS 公共 tcp.h 选项，0/1 行为已对照 Apple XNU tcp_usrreq.c。

尝试只停止本次 tcpdump 的 `sudo -n kill -INT 72451` 仍要求本机密码，未成功；
采集仍运行，需用户在启动它的终端按 Ctrl+C。没有试图关闭手机相机连接来结束采集。
本轮未修改业务源码，未打包/安装；STA 慢速目标未完成。

### 无线驱动只读检查：未取得停顿的调度证据

`idevicediagnostics ioregentry AppleBCMWLANCore` 可用（与已废弃的 WiFi diagnostics
命令不同）。仅查看 Wi-Fi 驱动节点：DriverKit release 构建、芯片 4387，
当前电源状态为 3、最大状态 3、LastSleepMode/LastWakeReason 均 0。
这些只是查询时刻的状态，不能证明此前传输期间始终未进入无线省电。
`AppleBCMWLANProximityInterface` 只有接口配置/类别，没有可用的信道调度时间线；
不能因节点存在就把周期停顿归因于 AWDL。未写入 IORegistry 或尝试开启内部调试权限。

devicectl 确认 wifip2pd 进程 226 与 App 1914 正在运行；只读过滤采集
`/tmp/ztransfer-sta-wifip2pd-20260917.log`，进程 72787，等待至少 30 秒后仅得到
6 条 `Skipping Padding Read`，未取得调度/切频事件。已停止该采集，退出 0。
不能把这些读取填充提示当无线错误，也不能把缺少事件当调度绝对没有发生。
此前用户启动的 root 握手 tcpdump 72451 仍在运行，已请用户 Ctrl+C 结束，
不混淆两个采集进程。

Apple DTS 的网络延迟诊断说明区分了 IP 层抓包与 Wi-Fi 链路层抓包；当前 RVI
证据不足以分离相机/AP/iPhone 无线驱动的延迟。若继续使用空口抓包，需要额外的
无线监听环境/用户授权，不能擅自占用 Mac 无线网卡导致网络中断。
参考：https://developer.apple.com/forums/tags/core-wlan （Debugging Network Latency Problems）。

### 用户要求回到源码对照

用户拒绝 Mac 无线监听方案，要求仔细研究安卓/iOS 的 STA 实现差异；不再等待该授权，
不把监听或 AP 测试作为继续条件。当前工作树专项审查见
[STA下载-Android与iOS实现差异审查.md](STA下载-Android与iOS实现差异审查.md)。
主要未对齐项为连续 I/O 执行模型、可复用包缓冲，以及 Debug/Release 后端选择；
Wi-Fi 低延迟锁另列为平台差异，不宣称已确认根因。
同时仅清理先前创建的 Mac RVI 注册，rvictl -x 返回 SUCCEEDED；未改变 Mac Wi-Fi
设置，没有关闭 App 的相机连接。本轮未改生产源码或打包。

### 安卓 STA 完整策略对齐包（23:20）

按用户要求扩展为 12 项逐段源码对照，详细依据、差异和测试见
[STA下载-Android与iOS实现差异审查.md](STA下载-Android与iOS实现差异审查.md)。
本次将 BSD 下载改为每数据相位一次工作队列提交，复用输入/包头/包体，
大包仿 BufferedInputStream 直接读入包体；同步写盘，保留每次短读活动更新和预读余量。
STA Debug/Release 后端统一，命令/事件 socket 配置分开，并移除安卓未设置的 ACK 实验项。
文件准备移到协议查询/计时之前，和 Android TransferViewModel → downloadToFile 顺序一致。
没有改变 STA 命令选择、4/32/64 MiB 阈值、列表加载规则、AP/USB 后端或新增断开功能。

49 项协议/连接/分帧回归、13 项实际策略/写盘/gate 回归通过；其中策略矩阵 216 组合。
Release 分支 PTP 源码静态类型检查通过；本地回环不作为手机吞吐证明。
真机 Debug 产物 `ZTransfer-ios-debug-1.82-20260917-232045.ipa` 已编译、签名并安装成功。
脚本自动启动阶段因手机 Locked 返回 1；尚未确认新版进程启动，尚无新版速度样本。
不要把这个状态误写为构建失败、闪退或慢速目标已完成。

### 对齐包首轮真机结果：仍慢，不能宣布修复

确认新版 232045 App 的 PID 1966 已运行。取回
`/tmp/ztransfer-sta-parity-phone-2325.jsonl`：
`6AC9516A-23A2-4F1A-A79C-9F0F34D83A4E` 成功 24274851 B / 18.097127 s = 1.279225 MiB/s；
`150A8DF9-6A19-43A5-BF35-F3C5835F7DA4` 成功 10099524 B / 7.121982 s = 1.352384 MiB/s。
两笔 `posix_phase_worker_calls=1`，连续读取生效，默认 ACK=0，内核缓冲4 MiB。
recv 墙钟占 98.39/98.45%；第二笔落盘仅16.580 ms。用户反馈“还是慢”与数据一致。

上一轮把“安卓不显式改 ACK”直接等同于“Darwin 也应使用默认 ACK”过于机械：
两种内核的确认算法不同。源码依据和边界补到完整对照文档。恢复 STA 命令口
TCP_SENDMOREACKS=1（Debug/Release 一致、事件口默认），保留全部连续读包改动。
这是恢复此前较好的适配基线，不声称能解决先前 ACK=1 时仍存在的吞吐差距，
也不把两笔不同文件测量当受控因果实验。新组合测试/产物结果待追加。

恢复适配后的 4 项定向测试通过。只运行真机 Debug 脚本，生成并安装
`ZTransfer-ios-debug-1.82-20260917-232827.ipa`；BUILD SUCCEEDED，签名/IPA 检查通过。
自动启动因 Locked 被拒绝，脚本返回 1，随后进程查询无 ZTransfer。
需要手机解锁打开新版才能继续真机验证，尚不具备认定完整修复的证据。

### 23:28 修正包实测：1.60 MiB/s，仍未通过性能验收

用户回复“好了”后，确认 PID 1985 运行 `...232827.app/ZTransfer`，取回日志
`/tmp/ztransfer-sta-restored-ack-latest.jsonl`。新成功样本
`2C2BFEFF-FED1-4E03-B54A-1A72205EC476` 为单分块 23981155 B / 14.307045 s，
即 1.598528 MiB/s（1.676178 MB/s）。连续读取 worker=1、ACK=1、NODELAY=1、
内核缓冲 4 MiB，排除旧包或恢复设置未生效。

recv 墙钟 14002.851 ms，占 97.8738%；10180 次读取，其中 29 次 >=50 ms，
合计 2643.373 ms。写盘 33.438 ms、sink 49.136 ms（包含写盘）、
finalize 2.470 ms、gate 6.890 ms。本次仅回到此前 1.5–1.8 MiB/s 区间，
没有达到用户报告的安卓 3+ MB/s；不宣称连续读取实现已经解决吞吐差距。
recv 墙钟并非纯网络时间，不据此猜测蓝牙、路由器、无线省电或相机根因。
剩余根因尚未定位；本轮只读取真机结果并更新证据，没有新的生产改动或打包。

### 2026-09-18 000803 对齐包反馈：仍约 1.6

`ZTransfer-ios-debug-1.82-20260918-000803.app` 已构建并安装；用户解锁打开后报告
“1.6mb”。只读进程查询确认 PID 2016 对应本批次安装目录，不是旧包。
这是用户速度读数，单位未经截图确认、没有本次原始字节/时间数据，不以旧 JSON 样本
补充或伪造本次耗时分解。正常启动默认关闭逐 recv 诊断。

同步借用包体、逐次 Socket 读取超时、默认关闭诊断、事件队列和后台断言修正均已包含
在该包；按反馈没有明显提速，安卓 3+ MB/s 的目标仍未达到。再次核对 Socket/PacketReader/
同步下载 pump 未找到新的、足以解释倍数差的代码证据。本轮只读确认版本、复核源码并
更新记录，没有再次改包或安排网络设置、抓包、蓝牙测试。根因仍未定位。
