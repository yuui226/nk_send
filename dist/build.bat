@echo off
setlocal
rem This script lives in dist\, but the Gradle build must run from the
rem project root. %~dp0 = this script's dir (dist\), so %~dp0.. is the root.
cd /d "%~dp0.."

rem ---- Release signing guard -------------------------------------------------
rem keystore.properties holds the signing password, so it is gitignored and the
rem .jks lives outside the repo: a fresh clone (new machine) will NOT have them.
rem When it is missing, build.gradle.kts SILENTLY falls back to the debug key --
rem a debug-signed build cannot be installed over users' existing app, and
rem shipping one is an accident you only notice after the fact. So stop here
rem rather than hand back a bad artifact.
if not exist "keystore.properties" (
    echo.
    echo ==========================================================
    echo  ERROR: keystore.properties not found - refusing to build.
    echo ==========================================================
    echo.
    echo  Without it this build would be signed with the DEBUG key.
    echo  Existing users could NOT upgrade over such a build.
    echo.
    echo  Fix on a new machine:
    echo    1. Restore ztransfer-release.jks from your backup
    echo       ^(kept outside the repo, e.g. D:\code\ztransfer-keys\^).
    echo    2. Create keystore.properties in the project root:
    echo.
    echo       storeFile=D:/code/ztransfer-keys/ztransfer-release.jks
    echo       storePassword=^<the keystore password^>
    echo       keyAlias=ztransfer
    echo       keyPassword=^<same password^>
    echo.
    echo  Lost the .jks? Then this app can never be updated again -
    echo  every user would have to uninstall and reinstall.
    echo.
    pause
    exit /b 1
)

rem Default: release APK (for direct distribution, e.g. QQ group).
rem "build.bat aab" builds the Android App Bundle required by Google Play.
set "TASK=assembleRelease"
set "SRC=app\build\outputs\apk\release\app-release.apk"
set "EXT=apk"
if /i "%~1"=="aab" (
    set "TASK=bundleRelease"
    set "SRC=app\build\outputs\bundle\release\app-release.aab"
    set "EXT=aab"
)

echo Building %EXT% (%TASK%)...
rem Use the explicit path to gradlew.bat: cmd does not search the current
rem directory for `call` targets in some environments.
call "%~dp0..\gradlew.bat" %TASK% --no-daemon
if errorlevel 1 (
    echo.
    echo Build FAILED.
    pause
    exit /b 1
)

rem Build-completion time stamp HHMM, e.g. 0929 = finished at 09:29.
rem %TIME% may be " 9:29:.." (leading space for single-digit hour); pad it to 0.
set "HH=%TIME:~0,2%"
set "MM=%TIME:~3,2%"
set "HH=%HH: =0%"
set "STAMP=%HH%%MM%"

rem Copy the artifact into the script's own folder (dist\), named with the stamp.
set "DST=%~dp0ztransfer_%STAMP%.%EXT%"

if not exist "%SRC%" (
    echo.
    echo ERROR: artifact not found at %SRC%
    pause
    exit /b 1
)

copy /Y "%SRC%" "%DST%" >nul
echo.
echo Artifact copied to: %DST%

rem R8 mapping file: required to de-obfuscate crash stack traces from this
rem exact build. Keep it local (do NOT distribute it with the app).
set "MAPPING=app\build\outputs\mapping\release\mapping.txt"
if exist "%MAPPING%" (
    copy /Y "%MAPPING%" "%~dp0ztransfer_%STAMP%.mapping.txt" >nul
    echo Mapping copied to:  %~dp0ztransfer_%STAMP%.mapping.txt
)
pause
