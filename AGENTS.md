# Project Working Agreements

## APK packaging

- “打包”默认指生成供测试、传到手机安装的 Debug APK，一律运行仓库根目录下的 `dist-debug/build-debug.bat`。
- 只交付 `dist-debug/ZTransfer-debug-{version}-{yyyyMMdd-HHmmss}.apk` 中最新生成的时间戳文件。
- 不把 `app/build/outputs/...` 下的 Gradle 标准产物作为交付文件，也不要手动改名后交付。
- Debug 打包不得修改、移动或删除 `dist` 中的任何内容；`dist` 保留给正式发布流程。
- 只有用户明确要求正式版或 Release 时，才使用 `dist/build.bat`。
