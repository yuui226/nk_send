# ZTransfer 相机模拟器

这是一个与 App 生产代码完全独立的 PTP/IP 服务，用于手边没有相机时验证：

日常开启、关闭和无线调试命令请直接看：[USAGE.md](USAGE.md)。

- 命令通道与事件通道初始化；
- OpenSession；
- 存储卡、照片句柄和 ObjectInfo 枚举；
- 示例图片的缩略图、预览与下载；
- 空事件轮询和连接保活。

服务只使用 Python 标准库，不需要安装依赖。默认模拟 36 张照片，并复用 12 组启动时生成的示例 PNG，不会向项目写缓存或图片文件。

## 先做本机协议自检

在项目根目录运行：

```powershell
python .\camera_simulator\verify.py --spawn
```

看到 `OK: dual-channel handshake...` 表示模拟服务覆盖了 App 进入照片列表所需的协议链路。

## 启动服务

```powershell
.\camera_simulator\start.ps1
```

默认监听所有 IPv4 网卡的 TCP `15740`。终端会打印 App 发来的每条 PTP 命令；按 `Ctrl+C` 停止。

## 公司电脑无法开启热点：无线调试方式

Debug 包内置了一个仅由 ADB 启动参数开启的回环端点；Release 源集没有这个参数和地址。
手机已经通过无线调试出现在 `adb devices` 后，打开两个 PowerShell 终端。

终端一启动模拟器：

```powershell
.\camera_simulator\start.ps1 -BindAddress 127.0.0.1
```

终端二构建、安装独立包名的 Debug App，建立反向隧道并启动：

```powershell
.\camera_simulator\connect-debug-device.ps1
```

Debug 包名为 `com.ztransfer.debug`，不会覆盖手机里的正式版和正式版数据。关闭模拟器后可清理隧道：

```powershell
adb reverse --remove tcp:15740
```

如果 Windows 防火墙拦截入站连接，可在管理员 PowerShell 中为这个测试端口添加规则：

```powershell
New-NetFirewallRule -DisplayName "ZTransfer Camera Simulator" -Direction Inbound -Protocol TCP -LocalPort 15740 -Action Allow
```

验证结束后可以删除该规则：

```powershell
Remove-NetFirewallRule -DisplayName "ZTransfer Camera Simulator"
```

## 让真机上的现有 App 找到电脑

App 的生产协议固定使用相机地址 `192.168.1.1:15740`，并将 DHCP 网关 `192.168.1.1` 作为“值得探测”的候选特征。因此只启动服务还不够，测试网络也必须满足这个地址约定。

建议使用一个与家庭局域网隔离的 Windows 移动热点：

1. 打开 Windows“移动热点”，让手机连接这个热点。
2. 在电脑的热点虚拟网卡 IPv4 属性中设置：
   - IP：`192.168.1.1`
   - 子网掩码：`255.255.255.0`
3. 在手机该 Wi-Fi 的高级设置中选择静态地址：
   - IP：`192.168.1.2`
   - 网关：`192.168.1.1`
   - 前缀长度：`24`
   - DNS：`192.168.1.1`
4. 运行 `.\camera_simulator\start.ps1`，再打开 App。

预期表现：

1. 连接页保留两张卡，并短暂显示“正在识别相机…”；
2. 模拟器完成双通道握手后，Wi-Fi 图标才飞出；
3. 成功动画结束后进入照片列表；
4. 列表显示 36 张示例图片，其中部分带保护标记，可用于测试长列表滚动。

注意：

- 不要在网关本来就是 `192.168.1.1` 的家庭局域网中给电脑抢占该地址，会与路由器冲突。
- 只在隔离的测试热点中使用以上静态地址。
- 验证结束后，把电脑热点网卡和手机 Wi-Fi 恢复为自动获取地址。
- 模拟器没有修改 App 的地址、发现逻辑或构建配置，不会进入发布包。
