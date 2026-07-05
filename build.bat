@echo off
echo Building APK...
call gradlew.bat assembleRelease --no-daemon
pause
