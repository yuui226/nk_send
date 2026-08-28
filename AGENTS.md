# Project Working Agreements

## APK packaging

- “打包”默认指生成供测试、传到手机安装的 Debug APK，一律运行仓库根目录下的 `dist-debug/build-debug.bat`。
- 只交付 `dist-debug/ZTransfer-debug-{version}-{yyyyMMdd-HHmmss}.apk` 中最新生成的时间戳文件。
- 不把 `app/build/outputs/...` 下的 Gradle 标准产物作为交付文件，也不要手动改名后交付。
- Debug 打包不得修改、移动或删除 `dist` 中的任何内容；`dist` 保留给正式发布流程。
- 只有用户明确要求正式版或 Release 时，才使用 `dist/build.bat`。
- 修改完成且目标是提供 Debug APK 时，直接运行 `dist-debug/build-debug.bat`，以脚本输出的编译结果为准；成功后直接交付最新时间戳 APK，失败后根据输出修复并重新运行。
- 不要在 Debug 打包前重复运行全量编译、`assembleDebug` 或整套测试。只有复杂逻辑确实需要打包流程无法覆盖的针对性验证时，才额外运行对应的最小测试，并提前说明原因。

## Gradle execution on Windows

- 本项目的 Gradle Wrapper 和依赖缓存位于工作区外的用户目录，Wrapper 还可能访问腾讯镜像。在受限执行环境中直接运行 `gradlew.bat` 容易出现 `SocketException: Permission denied`、重复下载或缓存访问异常。因此需要执行 Gradle 校验时，从一开始就使用允许访问本机 Gradle 缓存及网络镜像的主机环境，不要先在受限沙箱中试跑一次。
- Gradle 命令至少预留 240 秒，不要用很短的超时把同步构建伪装成异步任务；同一时间只运行一个 Gradle 构建。
- Gradle 超时后不要立即再次启动构建。先确认原进程是否仍在运行；若遗留守护进程或出现 `Could not delete ... caches-jvm`，先运行 `gradlew.bat --stop`，确认缓存不再被占用后再重试。
- 判断结果时以 Gradle 输出中的 `BUILD SUCCESSFUL` / `BUILD FAILED` 为准，不只依赖外层命令的退出码。
