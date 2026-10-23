# 蓝牙启动 STA 与“连接至计算机”调研

更新：2026-10-23。状态：Z30 V1.20 已验证蓝牙认证及遥控启动，但未声明菜单键支持；尚未验证菜单按键或 STA 唤醒成功。

## 目标与现状

目标是由 App 通过已配对的蓝牙，让相机启用保存的计算机基础结构网络配置，加入手机热点或路由器，再接入现有 STA/PTP-IP 流程。首次网络配置可以预先保存，日常连接不再操作机身。也要研究新机型的智能设备 STA，不能用 AP 唤醒替代这个目标。

- Z30、Z5 等虽然没有智能设备 STA 菜单，但支持“连接至计算机”的基础结构网络。见 [Z30 手册](https://onlinemanual.nikonimglib.com/z30/en/10-02.html)、[Z5 手册](https://onlinemanual.nikonimglib.com/z5/en/10_establishing_wireless_connections_02.html)。
- 现有 `NikonCamera.connectSta()` 从已知 IP 的网络连接开始；发现、计算机配对和传输不负责启动相机 Wi-Fi。
- 已提交的 `2e3923df` 仅实现 BLE 请求相机热点（AP），实际唤醒效果仍待真机验证。
- D5600 等并非“有 Wi-Fi 就能走计算机 STA”。[WTU 1.9.3 手册第 3 页](https://download.nikonimglib.com/archive4/YB7ZW00rVlDr04pONHM55OfVkS06/D-WTU___-010930BF-___EN-ALL___.pdf) 明确列出 D850、D750、D500、D7500、D7200、D5600、D5500、D5300 不支持通过内置无线 LAN 进行电脑配对。

## 已核实与已排除的路线

| 路线 | 实际证据 | 结论边界 |
|---|---|---|
| BLE `2005=01` | ZPill、birdcam、N-link；SnapBridge 的 Wi-Fi 连接调用链 | 唤起智能设备热点，不是已证实的 STA 选择命令 |
| BLE `2005=02` | SnapBridge 原始字节码及经典蓝牙连接调用链 | 经典蓝牙连接请求，不能当 STA 参数 |
| BLE `2005=80` | SnapBridge 的 ConnectionNotRequiredEstablishment | 不需要连接的标志，不是 STA 参数 |
| BLE `2004` | SnapBridge 接口只有 read，解析 SSID、密码、加密方式 | 已检视实现是获取热点凭据，没有电脑配置选择字段 |
| BLE `2008 ConnectionRequest` | 接收相机自动传输请求，写 OFF 确认；部分 ON 仅为 App 内部事件 | 没有依据把它写成 STA 启动命令 |
| PTP `0xD12E ConnectionPath` | 本地 16 份 Z 系 MTP 文档均标 Get-only | 只读报告传输路径 |
| PTP `0x90C2 ChangeCameraMode` | 已建立会话后的机身控制模式 | 不等于菜单“连接至计算机”的联网开关 |
| PTP `0x9435 ChangeApplicationMode` | 已建立会话后的应用操作限制 | 不负责 AP/STA 切换 |
| PTP `0x952B/0x935A` | 现有 App 及公开计算机配对案例 | 已联网之后建立主机信任，不负责开网 |
| PTP `0x9006/0x9007/0x9009` | libgphoto2 2006 年 Nikon P2 网络配置代码 | 旧设备 USB 写配置，不能推定现代 Z 系 BLE 可启动 |
| SnapBridge `WIFI_STATION` 切换 | 断 BLE、保存 App 模式、Bonjour 发现、连接 host/port | 切换 App 工作模式，未向机身发送启动 STA 命令 |

这些结果排除的是具体误用，不证明相机固件绝无其他私有指令。

## 官方 SnapBridge 静态分析记录

安装包来自 [尼康中国官方下载页](https://www.nikon.com.cn/sc_CN/service-and-support/downloads/app.tag/app/snap_bridge.dcr)，版本 `2.14.0.3003`。

- 下载地址：`https://app-publish.nikkorclub.com.cn/resources/common/web/products/software/downloads/SnapBridge-2.14.0.3003.apk`
- SHA-256：`bc6129ecccb1137a5af68e57136c01b74fdfa6e809a0621ad18cd0482a54352a`
- 仅作本地静态协议分析，没有安装、运行或将官方实现复制到项目。
- 临时证据目录：`/tmp/nikon-sta-research-20261023/`。目录不保证长期保留，以下是可重新定位的关键类。

| 证据 | 类／方法 |
|---|---|
| 连接请求 bit0=Wi-Fi、bit1=经典 BT、bit7=不需要连接 | `snapbridge.bleclient.m`；常规反编译位运算有错误，已检查 fallback 字节码 |
| Wi-Fi 路径获取热点凭据、写 bit0、手机加入 SSID | `snapbridge.backend.C0348a4` → `N0.e()` |
| 经典蓝牙写 bit1 | `snapbridge.backend.M3` |
| STA 模式改变只写 App 配置并断开 BLE | `Pe.call()` → `N0.d()`、`P4` |
| STA 自动／手动连接依赖已发现的 NsdServiceInfo | `e6.c`、`e6.h`、`C0876n3` |
| STA 最终按 host/port 开 socket | `C0349a5` |

完整反编译有 39 处错误；上述 STA 关键调用链正文完整。涉及位掩码的异常表达式已额外用字节码核实，不能把反编译产物当作完全准确的源码。

[官方 STA 使用流程](https://nikonimglib.com/snbr/onlinehelp/en/wifi_st_mode_connection_6.html) 也要求先从机身建立／选择网络。Z30、Z5 官方手册还明确：连接智能设备的蓝牙会终止计算机连接，后续切换时必须处理 BLE 释放与 Wi-Fi 接管。

## 待验证的菜单遥控候选

发现 `00002021-3dd4-4255-8d62-6dc7b9bd5561` 提供菜单按键协议。这是一条候选路径，尚未证明网络菜单在遥控期间可操作，也未证明能够可靠自动导航。

| 请求 | 字节（十六进制） | 意义 |
|---|---|---|
| Feature 查询 | `04 00 01 00` | 查询遥控支持 |
| Configuration 查询 | `04 00 10 00` | 查询按键支持位；不修改配置 |
| 开启／关闭遥控会话 | `05 00 11 00 01`／`05 00 11 00 00` | 蓝牙遥控，不是 STA |
| 按键 | `06 00 12 00 KK SS` | KK 键码，SS 为 1 按下／0 松开 |

本探针只允许 MENU=5、OK=7、上=8、下=9、右=10、左=11。没有电源、拍照、录像或删除按键入口。

响应前缀为小端 UInt16 长度、opcode、响应码；响应码 1 才表示请求成功。Configuration 在偏移 4 的 UInt32 中独立声明 MENU（bit4）和方向选择（bit6）。Feature 没有独立的 keyEvents 位，不得把 shootingEvent 解释成按键能力。

`2020` 状态可报告 NOT_CONTROL、PHOTO、PLAY、MENU，但没有当前菜单路径、选中行或菜单文字。进入 MENU 或收到按键 ACK 都不表示 STA 已启动。盲发固定菜单序列不具备可靠依据。

### 遥控能力查询的会话前提

官方 `C0833m1.a(ICameraGetRemoteControlSupportInfoListener)` 在未进入遥控时返回 `NOT_REMOTE_MODE`。启动调用链由 `W0.a()` 先发送 RemoteControlMode=REMOTE_CONTROL，之后 `N0.a(listener)` 才查询 Feature 与 Configuration。这证明官方的调用顺序，尚不能证明每台相机都会拒绝提前查询。

Debug v2 据此把检查分成两步：“读取能力”只读 GATT、Power、Feature 特征和当前状态并订阅响应；“测试菜单”经用户点击后先开启遥控，再查询两项按键能力。两项响应成功且声明 MENU 支持，才允许发送 MENU；方向键另外要求 selector 支持。不能拿进入遥控前的查询拒绝来判定相机不支持。接口存在也不能当作机型支持的证明。

## Z30 V1.20 真机反馈与下一步

用户于 2026-10-23 18:14（北京时间）提交 Debug v2 日志，App 1.99-debug(72)、Android 37。以下只保留与协议有关的响应，不保存相机自定义名或身份：

| 请求／字段 | 真机数据 | 已证实的含义 |
|---|---|---|
| Power | `03` | 相机报告 VALID_WAKE |
| RemoteMode 开启 | `0500110001` → `04001101` | 遥控启动成功 |
| 状态 | `01000006000000000000000000000000` | PHOTO；拍摄限制字节为 `06` |
| Feature | `0C0001010101030007000000` | remoteControl=true |
| Configuration | `08001001EE010000` | flags=`0x1EE`；MENU=false，selector=true |

Configuration 的 MENU 为 bit4、selector 为 bit6，已再次对照官方解析器及 fallback 字节码确认，未发现错位。官方将其映射为 `RemoteControlSupportInfo.getCanSupportMenuKeyEvent()`；实时拍摄限制是另一组 `2020` 数据。`06` 对应 RecOperationLimit 与 PhotoError，不是菜单禁止位，也不能单凭它推定缺卡、镜头状态或错误原因。

这份日志证明当前会话没有声明 MENU 支持。v2 因此在 App 内停止，**没有发送 MENU**，不能把它写成“固件已拒绝 MENU”，也不能推定所有状态／固件永远不支持。

Debug v3 保留原来的能力判断，增加独立“验证菜单键（一次）”诊断入口：只有遥控启动和能力查询成功、但 MENU 未声明时才显示；用户再次点击才发送已知 MENU=5 的按下／松开，不发送其他尝试指令。实际拒绝／超时就断开并保留日志；收到成功响应后仍要求观察机身是否真正打开菜单，不据此推断 STA 成功。未声明 MENU 的会话不提供重复菜单按键，直到重新读取能力；没有自动方向导航。

该实验只用于区分能力声明与实际按键响应，不是正式功能的能力回退。若确认按键被拒绝，当前智能设备蓝牙菜单路线在此测试条件下不可用；ML-L7 的单独遥控器配对不可直接等同于 GPS/SnapBridge 配对，[Z30 官方手册](https://onlinemanual.nikonimglib.com/z30/en/15-04.html) 还明确它与其他设备连接互斥。不能未经验证把更换配对身份当作一键 STA 方案。

## Debug 包验证步骤与判定

测试入口位于连接页 Wi-Fi 卡片的“蓝牙测试”，仅 Debug 可见。继续复用现有 GPS 蓝牙认证，仅连接已保存的相机；不重配对、不写定位，也不写 AP/STA 开关。

1. 若此 Debug 包尚未与相机配对，先在 GPS 功能完成一次配对，再关闭 GPS。断开相机 Wi-Fi／USB 会话，保留相机蓝牙。先开启手机热点（或让手机加入预期路由器），回到 App 选 STA，取消正在进行的连接／扫描，再打开蓝牙测试。不要在测试中途切到系统设置，退后台会释放测试连接。
2. 点击“读取能力”，一次收集型号／固件（若可读）、相关 GATT 能力、LSS Feature 特征、Power 和遥控状态。日志不记录密码或配对密钥。
3. 若“测试菜单”可用，点击后进入遥控并查询两个按键能力响应；声明 MENU 支持时发送菜单按键。若提示“未声明菜单键支持”，v3 可再显式点击“验证菜单键（一次）”进行上述独立诊断。观察机身是否真正打开菜单；拒绝、超时或缺失接口都保留原始响应。
4. 菜单确实打开后，可使用显式方向／确定按钮观察“连接至计算机”是否可进入、已保存配置能否启用。每步由用户观察，不自动导航。
5. 记录网络菜单是否灰色、启用时 BLE 是否断开、相机是否真正加入预期热点。完成按键操作后先点“断开”并关闭测试面板，再使用现有 STA 连接按钮完成发现与连接。断 BLE 本身不能判成功。
6. 复制测试日志。日志保留上一份结果，连接切换／退出面板后仍可查看。面板关闭、退后台、GPS 或其他连接接管、空闲超时均释放测试连接。

完整目标的通过条件：从相机未启用计算机网络开始，由手机操作启用正确的已保存配置；确认相机在预期网络出现并建立现有 PTP/IP 会话；验证取消、失败、重试以及 GPS 恢复。若只能遥控菜单，需另行解决菜单状态定位与机型差异，不能直接当成通用一键功能发布。

Debug 与 Release 使用不同 applicationId，GPS 和计算机配对身份不会自动共享。若只在 Release 配置过相机，新 Debug 首次需要完成相应配对；计算机端要求确认配对不等于蓝牙开网失败。代码复核确认现有 STA 会先释放 AP 网络请求，按实际热点／局域网接口发现相机并绑定本地地址建立 PTP 双通道。本探针禁止在扫描、握手或已连接期间开启，连接状态变化时停止探针；这不等于已完成实际 BLE→计算机网络交接验证。

## 公开项目索引

- [ZPill 固定提交](https://github.com/jaminxx-aha/ZPill/blob/76d4c8ed6bce0da1a962ffc7fc9e7ccc8e1f3afd/lib/core/ble/ble_camera_session.dart)：AP 请求。
- [birdcam](https://github.com/attilaolah/birdcam/blob/93ffc86a85a474dd884e4ac0168a991c1fdb1822/nikon/coolpix/a900.go)：热点读配置与单字节开关。
- [N-link](https://github.com/Wan-1230/N-link/blob/238363580212ad42411503323d8bd1fcd3bcba5d/app/src/main/java/com/nikonlink/app/device/ble/BleManager.kt)：仅实现 `2005=01`，注释中的 `02` 不是 STA 证据。
- [libgphoto2 历史](https://github.com/gphoto/libgphoto2/blob/bceecb0f0365d015b564e4b08122e28eb16088db/camlibs/ptp2/ChangeLog)：旧 Nikon P2 网络配置。
- [big-watermalon/NikonLink 移除 BLE 的提交](https://github.com/big-watermalon/NikonLink/commit/479f5aebf436408523842368370649243e216d4b)：README 的 BLE 激活说法没有当前调用链支持。
- [gphoto2 #1314](https://github.com/gphoto/libgphoto2/issues/1314)：ZR 计算机配对抓包，仍先手动开网，不是 BLE 唤醒。
- [现有计算机 STA 实现说明](计算机Wi-Fi客户端与智能设备STA模式.md)。
