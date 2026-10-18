# iOS Debug 打包

双击 `d-b-ios.command`，或在仓库根目录执行：

```sh
bash ios/dist-debug-ios/d-b-ios.command
```

- 新包签名及 ZIP 校验成功后，本目录仅保留最新一组 `.app`／`.ipa`；旧包不会在新包成功前清理。
- 自动向已配对、当前可用的全部 iOS 真机安装并启动，支持 USB 和局域网连接。局域网设备须已与这台 Mac 建立开发连接，开发者模式已开启；仅同一 Wi-Fi 并不代表可安装。
- 真机安装先于可选模拟器构建；排除模拟器及已离线设备，兼容新旧 Xcode 设备 JSON。无线隧道尚未打开的 `disconnected` 状态仍可尝试安装。
- 单台设备安装／启动失败会继续处理其他设备，最后汇总并返回失败，保留终端错误；不会把设备发现失败当作“没有连接手机”。
- `IOS_DEVICE_ID` 可限定一台设备，默认不额外构建模拟器；需要时设置 `IOS_BUILD_SIMULATOR=1`，`IOS_SKIP_SIMULATOR=1` 仍可强制跳过。原 `IOS_DEVELOPMENT_TEAM`／`IOS_DERIVED_DATA_DIR` 参数继续支持。

2026-10-18 修复依据：Xcode 27 的 `devicectl list devices` 包含 `reality=simulated` 的已配对 iOS 模拟器，旧脚本只查 iOS／paired 并在第一项停止，误将模拟器作为真机目标。设备筛选和逐台安装集中在 `../scripts/install_debug_devices.py`。

验证：`python3 -m unittest discover -s ios/scripts -p 'test_install_debug_devices.py' -v` 的12项专项通过；Bash语法及diff检查通过。复用现有 `ZTransfer-ios-debug-1.97-20261018-130133.app`，通过生产安装脚本自动发现当前 USB iPhone 15 Plus并安装／启动成功（1成功、0失败）；未重新构建，未做真实 Wi-Fi 或旧系统设备安装，相关分支仅由模拟数据及命令测试覆盖。

2026-10-18 速度调整：保留固定 DerivedData 增量编译（原本就不会默认 clean），默认只构建真机包，避免因测试遗留的已启动模拟器再编译一套。IPA 使用 ZIP 快速压缩级别 1，保留完整签名和 ZIP 校验；USB／局域网自动安装不变。输出编译、打包、设备安装和总耗时，方便区分首次编译与后续增量耗时。脚本语法检查通过。复用现有 Payload 做一次压缩对照：默认级别6为4.22秒／23,080,564字节，级别1为1.34秒／25,127,216字节，两者ZIP校验通过；这是单次压缩对照，不是完整构建提速比例。未执行本轮真实打包计时。
