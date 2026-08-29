# Nikon Smart GPS 集成方案（research/gps）

## 结论

`hurui200320/nsg` 的 Android 实现证明：尼康 Z 系列的 Smart Device 模式可以通过 BLE 写入 GPS，而不必占用 PTP/IP 的照片传输链路。对 Z传来说，这个功能可行，但应该作为**独立的可选 BLE GPS 会话**，不能把 BLE 状态塞进现有 `CameraViewModel` 的 PTP 会话状态，也不能复用现有相机前台服务的停止/重连生命周期。

第一版建议只做“已配对相机 + 真实手机定位 + 后台持续注入”，暂不做 SnapBridge 身份自动破解和多相机并发。先用新相机/用户确认配对建立稳定闭环，再把身份恢复作为增强功能。

## 极简用户流程（最终建议）

### 用户视角

首页只增加一个开关：**自动写入 GPS**。

- 关闭：不扫描、不定位、不显示常驻通知，应用行为与现在完全一致。
- 打开：自动完成权限检查、寻找目标相机、连接 BLE、启动定位和后台写入。
- 已经配置过后，用户以后只需要打开这个开关；进入后台、回到前台、相机重启都由服务自动恢复。

主界面只显示一行状态，不暴露协议细节：

```text
自动写入 GPS  ·  已连接到 Z8  ·  GPS 8 m  ·  12 秒前更新
```

失败时只给一个动作建议，例如“请在相机上打开蓝牙后重试”或“允许定位权限”；详细 BLE/GATT 日志放到诊断页。

### 首次使用（唯一需要用户操作的相机步骤）

1. 在相机菜单进入 **连接至智能设备 → 配对（蓝牙）→ 开始配对**。不同机型的中文菜单文字可能略有差异，但都属于 Smart Device/Bluetooth pairing 模式。
2. 在 Z传打开「自动写入 GPS」开关并允许系统权限。
3. Z传自动发现相机、完成 BLE 握手；Android 系统弹出蓝牙配对确认时，用户只确认一次。
4. 配对成功后，Z传自动开始定位和写入 GPS。

如果相机以前已经和 SnapBridge 配对过，Z传优先自动识别已有广播并恢复身份，通常不需要删除 SnapBridge 配对记录；用户仍只需打开开关。自动恢复失败时才提示用户重新进入相机配对模式。

### 后续使用

1. 相机开机并保持蓝牙/智能设备连接功能开启。
2. 打开 Z传的「自动写入 GPS」开关。
3. Z传按“当前 PTP 相机 → 上次 GPS 相机 → 唯一已保存相机”的顺序自动选择目标。
4. 找不到目标时后台短时扫描并重试；只有确实需要用户介入时才显示一条提示。

用户不需要再选择 BLE 设备、填写 DeviceID、手动发送 GPS 或进入高级设置。多相机选择、SnapBridge 身份恢复、清除配对记录全部放入高级设置，普通路径不出现。

### 相机端是否还要操作

| 场景 | 相机端操作 |
|---|---|
| 第一次使用、相机未配对 | 进入一次 Smart Device 蓝牙配对模式；确认一次系统配对提示 |
| 相机已和 SnapBridge 配对 | 通常无需额外操作；保持相机蓝牙/智能设备功能开启 |
| 日常重连 | 无需操作，Z传自动扫描当前随机 BLE 地址 |
| 相机清除了配对记录、换手机或关闭蓝牙 | 重新进入一次配对模式并确认系统提示 |

相机不需要切换到 Wi‑Fi 传输模式，也不需要每次拍照前手动发送 GPS。PTP 传输继续走原有 Wi‑Fi/USB 链路，GPS 通过独立 BLE 会话旁路运行。

## 参考项目调研结果

参考仓库：<https://github.com/hurui200320/nsg>，许可证为 AGPL-3.0。Android 目录包含完整的 BLE 扫描、配对、经典蓝牙 bonding、GPS 定位和前台服务实现；协议逆向来自 MIT 许可的 `gkoh/furble`。

关键实现逻辑：

1. 扫描 Nikon Smart Device 主服务 UUID，连接后请求较大 MTU，发现服务。
2. 在 `PAIR` 特征上启用 indication，在 `NOT1` 上启用 notification；发送 4 阶段、每阶段 17 字节的配对消息。阶段 2 用 Blowfish 盐表校验，阶段 3 回写响应，阶段 4 得到相机序列号。
3. 首次配对完成后，关闭 BLE GATT，让系统通过 Bluetooth Classic 完成 bonding；相机的经典地址可能与 BLE 随机地址不同，因此按名称/广播重新发现。
4. 已配对重连不能只使用上次地址：相机每次启动可能产生新的 BLE 随机地址，必须短时扫描并更新地址。
5. 定位成功后向 `GEO` 写入 41 字节 payload。参考实现按“移动距离或最长间隔”限流，并用前台服务保持后台运行。

### 协议常量（只记录事实，不复制代码）

| 项目 | 值 |
|---|---|
| Smart Device service | `0000de00-3dd4-4255-8d62-6dc7b9bd5561` |
| PAIR（写入/indication） | `00002000-3dd4-4255-8d62-6dc7b9bd5561` |
| ID（控制器名称） | `00002002-3dd4-4255-8d62-6dc7b9bd5561` |
| TIME（可选） | `00002006-3dd4-4255-8d62-6dc7b9bd5561` |
| GEO（GPS 写入） | `00002007-3dd4-4255-8d62-6dc7b9bd5561` |
| NOT1（成功通知） | `00002008-3dd4-4255-8d62-6dc7b9bd5561` |
| Nikon manufacturer company ID | `0x0399` |

GEO 的关键字段为：头 `0x007f`、南北/东西方向、度、分、两级百分之一分、卫星数、海拔符号与数值、UTC 时间、有效标志、`WGS-84`。协议文档和测试向量位于参考仓库 `doc/nikon-z-gps.md` 与 `esp32/lib/nikon-protocol/GeoMessage.*`。

### 身份恢复的边界

相机广播中可能带有 SnapBridge 生成的 4 字节 DeviceID。参考项目通过反解 Java `Random` 的 48 位 LCG，在 SnapBridge 安装时间窗口内枚举完整 8 字节 DeviceID，再逐个尝试连接。这一流程依赖已安装 SnapBridge、候选数量和设备响应，耗时与失败模式都不适合第一版默认路径，应做成显式“恢复 SnapBridge 身份”操作。

## 与当前 Z传架构的对照

当前工程已有：

- `CameraViewModel`：管理 USB/PTP-IP 连接、照片枚举、遥控和重连。
- `CameraSessionService`：只为 PTP 相机连接提供 `connectedDevice` 前台保活，`START_NOT_STICKY`。
- `MainActivity` + Compose 导航：Home、Files/Transfer、Remote，没有 BLE 或定位状态。
- `CameraConnectionType` 只有 `USB` / `WIFI`；Manifest 没有蓝牙、定位和 `FOREGROUND_SERVICE_LOCATION` 权限。

因此 GPS 不应扩展 `CameraConnectionType`，也不应把“GPS 已连接”伪装成 `CameraState.isConnectedToCamera`。照片传输可继续使用 Wi-Fi/USB，BLE GPS 作为旁路能力单独显示。

## 推荐架构

```text
MainActivity/Settings
        │ 用户开关、配对、目标相机
        ▼
GpsViewModel  ────────────────  GpsRepository（DataStore/SharedPreferences）
        │ bind/start/stop
        ▼
NikonGpsService（独立前台服务）
   ├─ LocationSource（LocationManager GPS + NETWORK）
   ├─ NikonBleSession（扫描、GATT、MTU、特征订阅）
   ├─ NikonPairingProtocol（纯 Kotlin，无 Android 依赖）
   └─ GeoPayloadEncoder（41 字节，纯 Kotlin）
```

建议新增包：`com.ztransfer.gps`。协议编码器、配对消息和状态机先做成纯 Kotlin 单元测试；Android BLE 回调只负责把事件投递到串行协程。所有 GATT 写入必须单通道排队，避免 Android 同时写 descriptor/characteristic 导致状态错乱。

### 服务生命周期

- `NikonGpsService` 使用 `START_STICKY`，声明 `connectedDevice|location`；只有用户打开 GPS 开关并选择相机时启动。
- 相机 PTP 断开不自动关闭 GPS 服务；GPS BLE 断开也不影响照片传输。两个服务可以分别恢复。
- 断开时取消定位回调、关闭 GATT、清理超时任务；停止服务时移除通知。
- Android 12+ 申请 `BLUETOOTH_SCAN`、`BLUETOOTH_CONNECT`；Android 11 及以下按系统要求申请定位权限。Android 14+ 同时声明并按需申请 `FOREGROUND_SERVICE_LOCATION`，通知权限仍沿用现有流程。

### 连接策略

1. **扫描**：按 Smart Device service UUID 过滤，15 秒超时；UI 展示名称、RSSI、是否带 `0x0399` 广播。
2. **首次配对**：BLE 阶段机 → ID 写入 → 关闭 GATT → 引导系统 Classic bonding → bonding 成功后重新连接 BLE → Ready。
3. **重连**：先扫描当前广播（名称/服务/DeviceID），再连接；保存地址只做最后兜底，不能作为唯一依据。
4. **失败恢复**：GATT status 133、MTU 失败、配对超时分别计数并指数退避；用户可手动重试，不能在后台无限扫描。

### 定位与写入策略

- 首版使用平台 `LocationManager`，同时监听 GPS 和 NETWORK，避免强依赖 Google Play Services，在国产 ROM 上更稳。
- 只接受有效经纬度和合理精度；卫星数从 `Location.extras` 读取，取不到时写 0，不发送随机伪造坐标。
- 首次有效 fix 立即写入；之后移动距离 ≥ 3 m 或距上次写入 ≥ 20–30 s 才写入。GEO 写入完成后等待回调，10 s 超时回到 Ready。
- 传输高峰期间可把最小间隔提高到 30 s，避免 BLE 写入和 UI 日志造成额外唤醒；这不改变 PTP 数据通道。
- 先只写 GEO；TIME 特征在参考文档中存在但不是 GPS-only 必需项，待真机验证后再启用。

## 分阶段实施

### Phase 0：协议与权限骨架（1–2 天）

- 新建纯 Kotlin `PairingMessage`、Blowfish 校验、坐标转换、GEO 编码器。
- 导入参考项目公开测试向量，补充边界测试（南纬/西经、±海拔、90/180 度、UTC 跨日）。
- Manifest 与运行时权限、独立 `GpsState`、设置页开关先落地；此阶段不连接相机。

### Phase 1：BLE 发现与只读连接（1–2 天）

- 实现扫描、GATT 连接、服务/特征校验、MTU 协商、descriptor 串行写入。
- 记录真实设备的广播、服务属性、GATT status；增加开发日志导出，便于逐机型兼容。

### Phase 2：配对与稳定重连（2–4 天）

- 接入 4 阶段握手和 Classic bonding；持久化相机名称、BLE 地址、设备 ID、nonce、控制器名称。
- 做“新相机配对”和“已配对相机重启后重连”两条 UI 流程。
- SnapBridge DeviceID 自动恢复先隐藏在高级操作中，成功后把固定身份保存到单独的 GPS 偏好，不污染 PTP-IP 身份。

### Phase 3：真实 GPS 注入与后台（2–3 天）

- 接入 LocationManager、GEO 发送限流、服务通知和电池优化提示。
- 与照片传输、遥控、USB 三种模式做并发验证；任何 GPS 失败只显示 GPS 状态，不阻断照片功能。

### Phase 4：兼容性与产品化（持续）

- 建立 Z7 II、Z8、Z50 II 以及至少一台旧款机身的矩阵，记录配对、重连、休眠唤醒、后台 30 分钟、传输并发结果。
- 增加导出诊断日志、手动重连、清除 GPS 配对记录；再评估多相机轮询和 TIME/NOT2 等未验证特征。

## 验收标准

1. 用户关闭 GPS 开关后，BLE 扫描、定位回调和前台通知均停止，PTP 传输不受影响。
2. 相机重启导致 BLE 地址变化时，后台能在限定次数内扫描到并重连。
3. 真实定位点写入后，相机 GPS 图标和照片 EXIF 坐标正确；无定位时不写随机坐标。
4. BLE 失败、权限拒绝、Classic bonding 未确认、相机离线均有可理解的状态和恢复入口。
5. 不复制 AGPL 项目源码；仅依据公开协议事实独立实现，并在项目文档中保留参考项目和许可证说明。

## 许可证与实现边界

`nsg` 是 AGPL-3.0。当前 Z传若继续作为闭源/商业 App，不能直接复制其 Kotlin/C++ 实现、注释或结构；应采用清洁实现，仅参考协议事实、状态转移和测试结果。若未来决定直接合并其代码，则必须先评估 AGPL 对整个衍生作品发布源代码的要求，并在产品策略上明确选择。
