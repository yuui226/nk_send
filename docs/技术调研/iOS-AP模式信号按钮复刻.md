# iOS AP 模式信号按钮复刻

## Android 行为依据

- `SignalPill` 在 AP 在线时绘制四根由低到高的圆角信号柱，点击后在右侧展开当前 RSSI；USB 显示 USB 图标与连接类型，STA 使用独立的连接拓扑图标且不展开强度。
- Android 原始 RSSI 的档位为：`-30 dBm` 及以上四格、`-45` 及以上三格、`-55` 及以上两格、`-65` 及以上一格、更弱零格；图标仍至少点亮第一根以维持可见性。
- 四格使用连接绿，中档使用强调橙，低档使用错误红；木纹主题使用专属薄荷绿/暖金/珊瑚红及深色未点亮柱。

## iOS 平台实现

- 2026-09-18 最终产品决定：iOS 不提供 AP 信号强度读取和展示，不申请 `Access Wi-Fi Information` capability，不调用 `NetworkExtension` / `NEHotspotNetwork`，也不启动周期轮询。
- AP 已连接时在照片列表、传输队列和监看页统一显示静态四段圆角信号柱；点击不更改布局、不展开文字、不触发其他操作。
- 四根柱固定宽 `4pt`、间距 `2.5pt`、高度依次 `6/9/12/15pt`、圆角 `1.5pt`，整体宽恒为 `23.5pt`，保留 Android 按钮的静态外观。
- USB 点击展开连接类型、STA 未连接时点击重试的原有行为不受影响。

## 2026-10-15 当前配置复核

全功能审查F181发现：当前`ios/project.yml`与`ios/ZTransfer/ZTransfer.entitlements`重新含有`com.apple.developer.networking.wifi-info=true`，生成工程的App真机Debug/Release引用该文件；未发现代码使用SSID/NetworkExtension。与上面的2026-09-18产品决定冲突，需后续纠正配置。本轮只记录，未修改工程、构建或验签；以下“不含权限”和构建成功是当时历史结果，不能当作当前配置证明。

## 历史验证

- 检查三个界面的 AP 按钮均只保留空操作，无信号百分比状态、无定时任务、无 `NetworkExtension` 引用。
- 检查应用 entitlements 不含 `com.apple.developer.networking.wifi-info`，个人开发团队可使用原包名进行 Debug 签名。
- 2026-09-18：通用 iOS 设备和模拟器 Debug 构建均 `BUILD SUCCEEDED`；已覆盖安装并启动到 iPhone 17 Pro 模拟器和当前连接的 iPhone。实际签名 entitlements 仅有应用/团队标识与 Debug `get-task-allow`，无 Wi-Fi Information 权限。


2026-10-17 F181 developer-side completion: removed networking.wifi-info from project.yml entitlement properties, app ZTransfer.entitlements and additionally discovered StoreKit/SimulatorDebug.entitlements (retaining get-task-allow there). Generated pbxproj already points Debug/Release device configurations to app entitlements, Debug simulator override to simulator file; no project regeneration or unrelated changes required. plutil lint both entitlement files and pbxproj passed; rg finds no networking.wifi-info under ios. xcodebuild -showBuildSettings Debug/Release iphoneos confirms CODE_SIGN_ENTITLEMENTS=ZTransfer/ZTransfer.entitlements (/tmp/ztransfer-f181-debug-settings-20261017.log and release-settings log); Release read-only query emitted sandbox CoreSimulator service warnings but returned settings/exit0. /tmp/ztransfer-f181-simulator-20261017.log TEST BUILD SUCCEEDED exit0; codesign -d --entitlements :- on resulting Debug simulator app returns empty entitlement dictionary, no Wi-Fi Information. This verifies simulator artifact only, no device signing/build/install performed and no tests run. Restores explicit2026-09-18 platform decision; no SSID/NEHotspotNetwork calls found. Count139/182,43 unclosed.
