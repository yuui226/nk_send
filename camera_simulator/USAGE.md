# 相机模拟器使用说明

用于手边没有相机时，让 Android Debug 包通过无线调试连接电脑上的模拟相机，并进入照片列表。

模拟器和正式 App 完全独立：

- 仅 `com.ztransfer.debug` 可以通过 ADB 参数启用模拟入口；
- 正式包 `com.ztransfer` 不包含模拟地址和开关；
- 普通点击 Debug App 图标不会自动启用模拟入口，建议按下面的命令启动。

## 使用前准备

1. 手机打开“无线调试”，并与电脑配对。
2. 在项目根目录打开 PowerShell。
3. 确认手机在线：

```powershell
adb devices
```

列表中应当只有一台状态为 `device` 的手机。

## 日常开启

需要两个 PowerShell 窗口。

### 1. 启动电脑模拟相机

在第一个窗口运行：

```powershell
.\camera_simulator\start.ps1 -BindAddress 127.0.0.1
```

保持这个窗口开启。看到下面的提示表示服务已经监听：

```text
ZTransfer camera simulator listening on 127.0.0.1:15740
```

### 2. 建立手机到电脑的通道并启动 Debug App

如果 Debug 包已经安装，在第二个窗口运行：

```powershell
.\camera_simulator\connect-debug-device.ps1 -SkipBuild -SkipInstall
```

这条命令不会构建、不会安装，只会：

1. 建立 `adb reverse tcp:15740 tcp:15740`；
2. 关闭正在运行的 Debug App；
3. 携带模拟开关重新启动 Debug App。

随后 App 会完成模拟 PTP/IP 握手，并进入包含 36 张示例图片的照片列表。

## Debug 包尚未安装

先在明确需要时单独构建：

```powershell
.\gradlew.bat assembleDebug
```

然后安装现有 APK、建立通道并启动：

```powershell
.\camera_simulator\connect-debug-device.ps1 -SkipBuild
```

`-SkipBuild` 表示使用已经生成的 APK，不重复构建。

## 关闭模拟器

### 正常关闭

回到运行 `start.ps1` 的窗口，按：

```text
Ctrl+C
```

然后可清理 ADB 反向通道：

```powershell
adb reverse --remove tcp:15740
```

如需同时关闭 Debug App：

```powershell
adb shell am force-stop com.ztransfer.debug
```

### 模拟器在后台运行、找不到窗口

先确认占用端口的进程：

```powershell
$simulatorPid = (Get-NetTCPConnection -LocalPort 15740 -State Listen).OwningProcess
Get-CimInstance Win32_Process -Filter "ProcessId=$simulatorPid" |
    Select-Object ProcessId, Name, CommandLine
```

确认命令行指向 `camera_simulator\simulator.py` 后再停止：

```powershell
Stop-Process -Id $simulatorPid
adb reverse --remove tcp:15740
```

不要在未检查命令行的情况下停止端口进程，以免误关其他服务。

## 开关后的预期表现

- 模拟器运行且 ADB 通道有效：握手成功后进入照片列表。
- 模拟器关闭：新连接无法握手，连接页保留两张卡片并显示相机未检测到。
- 已在照片列表时关闭模拟器：App 会检测到连接中断并尝试重连。
- 保持 App 进程和 ADB 通道不变，再次启动模拟器：通常会自动重连。
- 手机重启、Debug App 被系统回收或无线调试重连后：重新运行
  `connect-debug-device.ps1 -SkipBuild -SkipInstall`。

## 状态检查

检查电脑服务是否监听：

```powershell
Get-NetTCPConnection -LocalPort 15740 -State Listen
```

检查 ADB 通道：

```powershell
adb reverse --list
```

正常情况下应看到：

```text
tcp:15740 tcp:15740
```

检查当前前台 App：

```powershell
adb shell dumpsys window | Select-String "mCurrentFocus"
```

应包含：

```text
com.ztransfer.debug/com.ztransfer.MainActivity
```

## 常见问题

### `adb devices` 没有手机

确认手机无线调试仍然开启；必要时重新配对或重新执行 `adb connect`。

### 提示找到多台设备

给脚本明确指定设备序列号：

```powershell
.\camera_simulator\connect-debug-device.ps1 `
    -DeviceSerial "adb devices 中显示的序列号" `
    -SkipBuild `
    -SkipInstall
```

### 端口 15740 已被占用

运行：

```powershell
Get-NetTCPConnection -LocalPort 15740 -State Listen
```

如果已经是 `simulator.py`，不需要重复启动；否则先确认并处理占用该端口的程序。

### 服务已启动，但 App 仍停留在连接页

依次确认：

1. `adb reverse --list` 中存在 `tcp:15740 tcp:15740`；
2. 启动的是 `com.ztransfer.debug`；
3. 使用了 `connect-debug-device.ps1`，而不是直接点击 App 图标；
4. 模拟器窗口没有报错并且仍在运行。

## 最短命令速查

开启：

```powershell
# 窗口一
.\camera_simulator\start.ps1 -BindAddress 127.0.0.1

# 窗口二
.\camera_simulator\connect-debug-device.ps1 -SkipBuild -SkipInstall
```

关闭：

```text
在窗口一按 Ctrl+C
```

```powershell
adb reverse --remove tcp:15740
adb shell am force-stop com.ztransfer.debug
```
