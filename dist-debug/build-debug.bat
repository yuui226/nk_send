:; exec bash "$(dirname -- "$0")/build.command" "$@"
@echo off
setlocal
set "SKIP_INSTALL="

:parse_args
if "%~1"=="" goto :build
if /i "%~1"=="--no-install" (
    set "SKIP_INSTALL=1"
    shift
    goto :parse_args
)
echo Usage: %~nx0 [--no-install]
exit /b 1

:build

rem This script lives in dist-debug\. Run the Gradle build from the project root.
cd /d "%~dp0.."

echo Building timestamped Debug APK...
rem Reuse the JVM, task outputs and configured task graph across local Debug builds.
call "%~dp0..\gradlew.bat" :app:assembleDebug --daemon --build-cache --configuration-cache --console=plain
if errorlevel 1 (
    echo.
    echo Debug build FAILED.
    pause
    exit /b 1
)

echo.
echo Build complete. The timestamped APK is in:
echo   %~dp0
echo.

set "DEBUG_APK="
for /f "delims=" %%F in ('dir /b /a-d /o-d "%~dp0ZD-*.apk" 2^>nul') do if not defined DEBUG_APK set "DEBUG_APK=%~dp0%%F"
if not defined DEBUG_APK (
    echo Timestamped Debug APK was not found.
    pause
    exit /b 1
)

rem Optional local QQ delivery; failures never invalidate the successful APK build.
if not defined ZTRANSFER_QQ_CONFIG set "ZTRANSFER_QQ_CONFIG=%~dp0..\.build-tools\qq-debug\config.json"
if not exist "%ZTRANSFER_QQ_CONFIG%" goto :after_qq_delivery
where node >nul 2>nul
if errorlevel 1 (
    echo WARNING: Node.js was not found; skipping QQ delivery. APK is ready.
    goto :after_qq_delivery
)
node "%~dp0..\tools\qq-debug\qq-apk.mjs" send "%DEBUG_APK%"
if errorlevel 1 echo WARNING: QQ delivery failed. APK is ready; check QQ before sending again.

:after_qq_delivery
if defined SKIP_INSTALL (
    echo Build only; skipping device installation.
    goto :finish
)

where adb >nul 2>nul
if errorlevel 1 (
    echo ADB was not found. Skipping device installation.
    echo.
    goto :finish
)

set "ADB_DEVICE_FOUND="
set "ADB_INSTALL_FAILED="
set "ADB_LAUNCH_FAILED="
for /f "skip=1 tokens=1,2" %%A in ('adb devices 2^>nul') do (
    if "%%B"=="device" (
        set "ADB_DEVICE_FOUND=1"
        echo Installing to %%A...
        adb -s "%%A" install -r "%DEBUG_APK%"
        if errorlevel 1 (
            set "ADB_INSTALL_FAILED=1"
        ) else (
            echo Launching ZTransfer on %%A...
            adb -s "%%A" shell am start -n com.ztransfer.debug/com.ztransfer.MainActivity
            if errorlevel 1 set "ADB_LAUNCH_FAILED=1"
        )
        echo.
    )
)

if not defined ADB_DEVICE_FOUND (
    echo No authorized ADB device connected. Skipping device installation.
    echo.
)

if defined ADB_INSTALL_FAILED (
    echo One or more device installations FAILED.
)

if defined ADB_LAUNCH_FAILED (
    echo ZTransfer could not be launched on one or more devices.
)

:finish
rem The APK build succeeded. ADB installation/launch is optional, so close a window opened by
rem double-clicking this script regardless of its result. Build failures exit earlier after pause.
exit /b 0
