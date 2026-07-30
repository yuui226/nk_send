param(
    [string]$DeviceSerial = "",
    [switch]$SkipBuild,
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path $PSScriptRoot -Parent
$apk = Join-Path $projectRoot "app\build\outputs\apk\debug\app-debug.apk"

if ([string]::IsNullOrWhiteSpace($DeviceSerial)) {
    $connected = @(
        adb devices |
            Select-String -Pattern "^(\S+)\s+device$" |
            ForEach-Object { $_.Matches[0].Groups[1].Value }
    )
    if ($connected.Count -ne 1) {
        throw "Expected exactly one connected ADB device; found $($connected.Count). Pass -DeviceSerial explicitly."
    }
    $DeviceSerial = $connected[0]
}

if (-not $SkipBuild) {
    & (Join-Path $projectRoot "gradlew.bat") :app:assembleDebug --console=plain
    if ($LASTEXITCODE -ne 0) {
        throw "Debug build failed."
    }
}

if (-not (Test-Path -LiteralPath $apk)) {
    throw "Debug APK not found: $apk"
}

& adb -s $DeviceSerial reverse tcp:15740 tcp:15740
if ($LASTEXITCODE -ne 0) {
    throw "adb reverse failed."
}

if (-not $SkipInstall) {
    & adb -s $DeviceSerial install -r $apk
    if ($LASTEXITCODE -ne 0) {
        throw "Debug APK installation failed."
    }
}

& adb -s $DeviceSerial shell am force-stop com.ztransfer.debug
& adb -s $DeviceSerial shell am start `
    -n com.ztransfer.debug/com.ztransfer.MainActivity `
    --ez com.ztransfer.debug.LOOPBACK_CAMERA true
if ($LASTEXITCODE -ne 0) {
    throw "Could not launch the Debug app."
}

Write-Host ""
Write-Host "Debug app launched through adb reverse on device $DeviceSerial"
Write-Host "Keep camera_simulator\start.ps1 -BindAddress 127.0.0.1 running in another terminal."
