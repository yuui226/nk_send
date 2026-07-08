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

rem Build-completion time stamp HHMM, e.g. 0929 = finished at 09:29.
rem %TIME% may be " 9:29:.." (leading space for single-digit hour); pad it to 0.
set "HH=%TIME:~0,2%"
set "MM=%TIME:~3,2%"
set "HH=%HH: =0%"
set "STAMP=%HH%%MM%"

rem Copy the artifact into the script's own folder (dist\), named with the stamp.
set "DST=%~dp0nk_send_%STAMP%.apk"

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
