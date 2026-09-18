# iOS 应用图标复刻（2026-09-17）

用户反馈真机桌面显示默认图标。检查已安装版本对应的
`dist-debug-ios/ZTransfer-ios-debug-1.82-20260917-212645.app`：没有图标 PNG、
Assets.car 或 Info.plist 的 CFBundleIcons。工程及 `ios/project.yml` 的
ASSETCATALOG_COMPILER_APPICON_NAME 均为空，工程未配置图标资源。根因是缺失资源及配置，
不是缩略图缓存，也不能用删除 App 解决缺失资产。

## 行为依据与实现

- 安卓唯一设计来源：`app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`、
  `drawable/ic_launcher_foreground.xml`、`values/ic_launcher_background.xml`。
- 背景 #1E1E1E，白色双 Z；保持 XML 三层绘制顺序、所有顶点、4.6dp 背景色圆角描边分隔。
- `tools/generate_ios_app_icon.swift` 直接读取安卓 XML，以 CoreGraphics 生成不透明的
  1024×1024 sRGB PNG；`--check` 检查已提交资源与当前安卓源一致。没有手工另画图标。
- 安卓 adaptive icon 的 108dp 图层只有中央 72dp 显示在常态蒙版中，外围各 18dp 用于动效。
  iOS 平面图标按该可见视口映射，不把 Android 运动留白也缩进去导致图标变小。
  圆角交给 iOS 系统蒙版，不给 PNG 预裁圆角或透明背景。
  依据：[Android AdaptiveIconDrawable](https://developer.android.com/reference/android/graphics/drawable/AdaptiveIconDrawable)。
- 新增 `ios/ZTransfer/Resources/Assets.xcassets/AppIcon.appiconset`，登记 Resources 构建阶段，
  Debug/Release 和 XcodeGen 配置均指定 AppIcon。iOS 单张 1024 图由资产编译器生成设备尺寸，
  依据：[Apple 图标资源配置](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)。

## 验证（3/4 完成）

- [x] 已查明旧包与工程的缺失配置，未将系统默认图标归因于用户操作。
- [x] 生成器 `--check` 通过；检查 PNG 为 1024×1024、无 alpha；实际打开图片确认双 Z 正向、居中、分隔完整。
- [x] 单独运行 iphoneos `actool`（最低 iOS 16，iPhone/iPad）成功，输出 AppIcon PNG、
  Assets.car，以及包含 iPhone/iPad CFBundlePrimaryIcon 的部分 Info.plist；工程 plist 和 diff 检查通过。
- [ ] 等用户当前真机测试结束后，在下一个获准打包/安装节点检查新包与手机桌面显示。

本次没有重新打包/覆盖安装，避免打断用户当前真机传输测试；旧包仍不包含上述图标修复。
