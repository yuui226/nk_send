@echo off
setlocal

rem This script lives in dist-debug\. Run the Gradle build from the project root.
cd /d "%~dp0.."

echo Building timestamped Debug APK...
call "%~dp0..\gradlew.bat" :app:assembleDebug --no-daemon --console=plain
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
pause
