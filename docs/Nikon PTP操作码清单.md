# Nikon PTP 操作码完整清单

> 来源: [libgphoto2 ptp2/ptp.h](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptp.h)  
> 整理日期: 2026-07-11  
> 标注: ✅ = App 已使用 | 🔥 = 值得加入

---

## 一、标准 PTP 操作码

| 操作码 | 名称 | 功能 | 状态 |
|---|---|---|---|
| 0x1001 | GetDeviceInfo | 获取设备信息 (型号/固件/支持的操作码) | ✅ |
| 0x1002 | OpenSession | 打开会话 | ✅ |
| 0x1003 | CloseSession | 关闭会话 | ✅ |
| 0x1004 | GetStorageIDs | 获取存储卡 ID 列表 | ✅ |
| 0x1005 | GetStorageInfo | 获取指定存储卡详情 (容量/剩余) | |
| 0x1006 | GetNumObjects | 获取文件总数 | |
| 0x1007 | GetObjectHandles | 获取文件句柄列表 | ✅ |
| 0x1008 | GetObjectInfo | 获取单文件信息 (名/大小/格式/日期) | ✅ |
| 0x1009 | GetObject | 下载整个文件 | ✅ |
| 0x100A | GetThumb | 获取缩略图 JPEG | ✅ |
| 0x100B | DeleteObject | 删除文件 | |
| 0x100C | SendObjectInfo | 上传文件信息头 (为 SendObject 准备) | |
| 0x100D | SendObject | 上传文件数据 | |
| 0x100E | InitiateCapture | 触发标准拍摄 | |
| 0x100F | FormatStore | 格式化存储卡 | |
| 0x1010 | ResetDevice | 重置设备 | |
| 0x1011 | SelfTest | 自检 | |
| 0x1012 | SetObjectProtection | 设置文件保护标记 | |
| 0x1013 | PowerDown | 关机 | |
| 0x1014 | GetDevicePropDesc | 获取属性描述 (值域/可写性) | ✅ |
| 0x1015 | GetDevicePropValue | 读取属性当前值 | ✅ |
| 0x1016 | SetDevicePropValue | 写入属性值 | ✅ |
| 0x1017 | ResetDevicePropValue | 重置属性到默认值 | |
| 0x1018 | TerminateOpenCapture | 终止开放拍摄 | |
| 0x1019 | MoveObject | 移动文件到另一个存储卡/文件夹 | |
| 0x101A | CopyObject | 复制文件 | |
| 0x101B | GetPartialObject | 标准分块读取 (**Nikon 相机不支持! 返回 0x2004**) | 不可用 |
| 0x101C | InitiateOpenCapture | 开始开放拍摄 (连拍/包围) | |
| 0x101D | StartEnumHandles | 开始枚举句柄 | |
| 0x101E | EnumHandles | 枚举句柄 | |
| 0x101F | StopEnumHandles | 停止枚举句柄 | |
| 0x1020 | GetVendorExtensionMaps | 获取厂商扩展映射 | |
| 0x1021 | GetVendorDeviceInfo | 获取厂商设备信息 | |
| 0x1022 | GetResizedImageObject | 获取缩放后图像 | |
| 0x1023 | GetFilesystemManifest | 获取文件系统清单 | |
| 0x1024 | GetStreamInfo | 获取流信息 | |
| 0x1025 | GetStream | 获取流数据 | |

---

## 二、Nikon 专有操作码

### 2.1 分块/高速传输

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x9010 | AdvancedTransfer | — | 高级传输 | 未探索 |
| 0x9011 | GetFileInfoInBlock | — | 块读取文件信息 | 未探索 |
| 0x9400 | **GetPartialObjectHiSpeed** | handle, transfer_size(32bit), terminate_flag | 高速分块下载。相机自己跟踪偏移，返回 (sent_bytes, offset_low32, offset_high32) | 🔥🔥 |
| 0x9431 | **GetPartialObjectEx** | handle, offLo, offHi, sizeLo, sizeHi | 64位偏移+64位尺寸分块下载。返回 (actual_low32, actual_high32) | ✅ |

> 💡 **0x9400 vs 0x9431**: `HiSpeed` 只需 3 个参数 (相机自管偏移)，比 `Ex` 的 5 参数简洁。值得在 Z30 上测试支持情况。

### 2.2 文件信息与元数据

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x9421 | **GetObjectSize** | objectHandle | 返回 **64 位** 文件字节数。解决 >4GB 大文件 ObjectInfo 大小字段 32 位溢出报 `0xFFFFFFFF` 的问题 | 🔥🔥🔥 |
| 0x9434 | GetObjectsMetaData | — | 批量获取对象元数据 | 🔥 |

> 💡 **0x9421 是最具性价比的补充**: 一条命令, 解决 >4GB 视频拿不到真实大小 → 无法完整性校验 → 无法走分块路径的死结。配合 0x9431 可直接支持 4GB+ 文件。

### 2.3 Live View 与取景

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x9200 | GetPreviewImg | — | 获取预览图像 | |
| 0x9201 | StartLiveView | (无) | 启动 Live View | ✅ |
| 0x9202 | EndLiveView | (无) | 关闭 Live View | ✅ |
| 0x9203 | GetLiveViewImg | (无), data in | 获取 LV 帧 JPEG 数据 | ✅ |
| 0x920F | **GetFhdPicture** | objectHandle | 获取 1920×1080 全高清预览图 | 🔥🔥 |
| 0x9423 | GetLiveViewCompressedSize | — | 获取压缩 LV 尺寸 | |
| 0x9428 | GetLiveViewImageEx | (无), data in | 增强 LV 取帧 (Z8/Z9 世代) | ✅ 已探测 |

> 💡 **0x920F GetFhdPicture**: 比 GetThumb 清晰得多 (1920×1080 vs 160×120), 比 LV 帧更稳定。用于照片预览可大幅提升体验。

### 2.4 对焦

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x90C1 | AfDrive | (无) | 驱动 AF (半按快门合焦) | ✅ |
| 0x9204 | MfDrive | 2 params | 手动对焦驱动 (步进量+方向) | ✅ |
| 0x9205 | ChangeAfArea | x, y | 改变 AF 区域位置 (LV 坐标) | ✅ |
| 0x9206 | **AfDriveCancel** | (无) | 取消正在进行的 AF 驱动 | 🔥🔥 |
| 0x9424 | **StartTracking** | — | 开始主体追踪对焦 | 🔥 |
| 0x9425 | **EndTracking** | — | 结束主体追踪 | 🔥 |
| 0x941F | ActiveSelectionControl | — | 活动选择控制 | |

### 2.5 拍摄

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x90C0 | InitiateCaptureRecInSdram | (无) | 连拍/高速拍摄到 SDRAM 缓冲区 | ✅ |
| 0x90C3 | DelImageSDRAM | 1 param (0=全部) | 删除 SDRAM 中图像 | |
| 0x90CB | AfCaptureSDRAM | (无) | AF 后拍摄到 SDRAM | ✅ |
| 0x9207 | InitiateCaptureRecInMedia | -1(无AF)/-2(AF), 0(卡) | 拍摄到存储卡 | ✅ |
| 0x920A | StartMovieRecInCard | (无) | 开始录像 | ✅ |
| 0x920B | EndMovieRec | (无) | 结束录像 | ✅ |
| 0x920C | TerminateCapture | 2 params | 终止 B门/长曝光 | ✅ |
| 0x940C | CancelImagesInSDRAM | — | 取消 SDRAM 中的图像 | |
| 0x941D | MirrorUpCancel | — | 取消反光板预升 (单反机身) | |

### 2.6 曝光控制

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x9426 | **ChangeAELock** | — | AE 锁定/解锁切换 | 🔥🔥 |

### 2.7 闪光灯 (Speedlight) — 完整控制套件

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x9414 | GetSBHandles | — | 获取已连接闪光灯句柄列表 | 🔥 |
| 0x9415 | GetSBAttrDesc | — | 获取闪光灯属性描述 (值域/可写性) | 🔥 |
| 0x9416 | GetSBAttrValue | — | 读取闪光灯属性当前值 | 🔥 |
| 0x9417 | SetSBAttrValue | — | 设置闪光灯属性值 | 🔥 |
| 0x9418 | GetSBGroupAttrDesc | — | 获取多灯分组属性描述 | 🔥 |
| 0x9419 | GetSBGroupAttrValue | — | 读取多灯分组属性值 | 🔥 |
| 0x941A | SetSBGroupAttrValue | — | 设置多灯分组属性值 | 🔥 |
| 0x941B | TestFlash | — | 测试闪光 (试闪) | 🔥 |

### 2.8 白平衡

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x90C9 | SetPreWBData | 3 params, data out | 设置手动预设白平衡数据 | |
| 0x9402 | StartSpotWb | — | 进入点白平衡模式 | 🔥 |
| 0x9403 | EndSpotWb | — | 退出点白平衡模式 | 🔥 |
| 0x9404 | ChangeSpotWbArea | — | 改变点白平衡测量区域 | 🔥 |
| 0x9405 | MeasureSpotWb | — | 执行点白平衡测量 | 🔥 |
| 0x9406 | EndSpotWbResultDisp | — | 结束点白平衡结果显示 | 🔥 |

> 💡 点白平衡: LV 画面中选一个灰色区域作为白平衡参考, 精确控制色温。

### 2.9 图像优化 (Picture Control / 曲线)

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x90C5 | CurveDownload | 1 param, data in | 下载相机当前色调曲线 | 🔥 |
| 0x90C6 | CurveUpload | 1 param, data out | 上传自定义色调曲线到相机 | 🔥 |
| 0x90CC | GetPictCtrlData | 2 params, data in | 读取优化校准参数 | 🔥 |
| 0x90CD | SetPictCtrlData | 2 params, data out | 写入优化校准参数 | 🔥 |
| 0x90CE | DelCstPicCtrl | 1 param | 删除自定义优化校准 | 🔥 |
| 0x90CF | GetPicCtrlCapability | 1 param, data in | 查询优化校准支持能力 | 🔥 |

### 2.10 设置与系统

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x90C2 | ChangeCameraMode | 1 param | 切换相机曝光模式 (P/A/S/M) | ✅ |
| 0x90E0 | GetDevicePTPIPInfo | — | 获取 PTP/IP 协议版本和设备能力 | |
| 0x9209 | GetVendorStorageIDs | (无), data in | Nikon 专用存储 ID 枚举 | |
| 0x9420 | **SaveCameraSetting** | — | 保存当前相机设置到文件 | 🔥🔥 |
| 0x9422 | **ChangeMonitorOff** | — | 关闭/打开相机屏幕 | 🔥🔥 |
| 0x9435 | ChangeApplicationMode | 1 param | 切换应用模式 (传输/遥控) | ✅ |
| 0x9436 | ResetMenu | — | 重置菜单到出厂设置 | |
| 0x9006 | GetProfileAllData | — | 获取全部配置 profile 数据 | 🔥 |
| 0x9007 | SendProfileData | — | 发送配置 profile 到相机 | 🔥 |
| 0x9008 | DeleteProfile | — | 删除配置 profile | 🔥 |
| 0x9009 | SetProfileData | — | 设置配置 profile | 🔥 |

> 💡 **0x9420 SaveCameraSetting**: 遥控页一键备份当前相机设置到手机, 换机身/复位后可恢复。  
> 💡 **0x9422 ChangeMonitorOff**: 遥控拍摄时关相机屏 → 省电 + 防屏幕漏光影响长曝光。

### 2.11 事件与状态

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x90C7 | GetEvent | (无), data in | 轮询相机事件 (标准版) | ✅ |
| 0x90C8 | DeviceReady | (无) | 轮询设备就绪状态 (Live View 启动后) | ✅ |
| 0x90CA | GetVendorPropCodes | (无), data in | 获取 Nikon 专有属性码列表 | ✅ |
| 0x941C | GetEventEx | — | 增强事件轮询 (支持多参数事件) | ✅ |
| 0x9439 | GetVendorCodes | 0x09(操作码)/0x0D(属性码) | 获取厂商扩展码列表 (Z8/Z9 世代) | ✅ |

### 2.12 镜头/机身

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x941E | **PowerZoomByFocalLength** | — | 电动变焦到指定焦距 (PZ 镜头) | 🔥 |
| 0x9432 | GetManualSettingLensData | — | 获取手动镜头设置数据 | 🔥 |
| 0x9433 | InitiatePixelMapping | — | 启动像素映射 (坏点检测修复) | |

### 2.13 缩略图

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x90C4 | **GetLargeThumb** | — | 获取大缩略图 (比标准 GetThumb 质量高) | 🔥 |

### 2.14 其他

| 操作码 | 名称 | 参数 | 功能 | 状态 |
|---|---|---|---|---|
| 0x9504 | GetDevicePropEx | — | 扩展属性读取 (Nikon V1 上发现) | |

---

## 三、按优先级推荐

### 🔥🔥🔥 强烈推荐

| 操作码 | 理由 |
|---|---|
| **0x9421 GetObjectSize** | ✅ 已实现。一条命令解决 >4GB 视频 SIZE_UNKNOWN 死结。配合 0x9431 即可支持 4GB+ 分块下载。 |
| **0x9400 GetPartialObjectHiSpeed** | ❌ 经调研，此操作码在 ptp.h 有定义但**全量搜索 libgphoto2 源码/ GitHub issues / mailing list 未发现任何实际实现或调用**。推测为 Nikon 早期设计但未启用。**不建议使用**。 |

### 🔥🔥 高价值

| 操作码 | 理由 |
|---|---|
| **0x920F GetFhdPicture** | 1920×1080 预览图，比缩略图清晰 10 倍以上。照片预览体验质的飞跃。 |
| **0x9206 AfDriveCancel** | 取消 AF，对焦卡住时用户可主动中止。配合当前 AfDrive。 |
| **0x9426 ChangeAELock** | AE 锁定，遥控页实现测光/对焦分离。 |
| **0x9420 SaveCameraSetting** | 备份相机设置到手机，换机/复位的杀手功能。 |
| **0x9422 ChangeMonitorOff** | 遥控时关相机屏幕，省电 + 防漏光。 |

### 🔥 值得评估

| 操作码 | 理由 |
|---|---|
| **0x9424/0x9425 StartTracking/EndTracking** | 主体追踪对焦，Z8/Z9 旗舰功能。 |
| **0x9414–0x941B 闪光灯控制** | 完整闪光遥控，棚拍/微距场景。 |
| **0x9402–0x9406 点白平衡** | LV 画面点击区域测色温，精确白平衡。 |
| **0x90C5/0x90C6 曲线上传** | 自定义色调曲线，专业用户刚需。 |
| **0x941E PowerZoom** | PZ 镜头电动变焦，视频拍摄遥控。 |
| **0x90C4 GetLargeThumb** | 比标准缩略图质量更好的大缩略图。 |
| **0x90CC–0x90CF Picture Control** | 优化校准读/写/删，完整图像风格遥控。 |
| **0x9006–0x9009 Profile** | 相机配置备份/恢复/删除。 |

---

## 四、SnapBridge 相关发现

SnapBridge 使用 BLE (蓝牙低功耗) 维持常连接 + Wi-Fi P2P 传输大文件。其传输协议推测为：
- **小文件 (JPEG)**: 直接通过 BLE 或 Wi-Fi P2P 的 HTTP/HTTPS
- **大文件 (RAW/视频)**: 可能使用 Nikon 专有 PTP 操作码或其自有的 Wi-Fi 传输协议
- **关键差异**: SnapBridge 不依赖相机 Wi-Fi 热点模式 ( Infrastructure), 而是用 Wi-Fi Direct (P2P), 因此性能模型不同

ZTransfer 使用相机热点 + PTP/IP + TCP 的路线, 协议层面与 SnapBridge 不同, 不应直接照搬 SnapBridge 做法。
