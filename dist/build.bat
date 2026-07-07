@echo off
setlocal
rem This script lives in dist\, but the Gradle build must run from the
rem project root. %~dp0 = this script's dir (dist\), so %~dp0.. is the root.
cd /d "%~dp0.."

echo Building APK...
rem Use the explicit path to gradlew.bat: cmd does not search the current
rem directory for `call` targets in some environments.
call "%~dp0..\gradlew.bat" assembleRelease --no-daemon
if errorlevel 1 (
    echo.
    echo Build FAILED.
    pause
    exit /b 1
)

set "SRC=app\build\outputs\apk\release\app-release.apk"
rem Copy the artifact into the script's own folder (dist\).
set "DST=%~dp0nk_send.apk"

if not exist "%SRC%" (
    echo.
    echo ERROR: APK not found at %SRC%
    pause
    exit /b 1
)

copy /Y "%SRC%" "%DST%" >nul
echo.
echo APK copied to: %DST%
pause
