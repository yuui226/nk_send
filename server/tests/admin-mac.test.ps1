# Run on macOS: pwsh -NoProfile -File server/tests/admin-mac.test.ps1
# Native credential/network/clipboard/dialog commands are mocked: no remote state changes.
$ErrorActionPreference = 'Stop'
$env:ZT_ADMIN_TOKEN = 'mac-test-token'
. (Join-Path $PSScriptRoot '../admin.ps1') -LibraryMode
function Assert($condition, $message) { if (-not $condition) { throw $message } }
Assert $AdminIsMac 'This test must run on macOS'
Assert ($CurlExecutable -eq '/usr/bin/curl') 'Mac curl selection'
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('zt-admin-mac-' + [guid]::NewGuid())
New-Item -ItemType Directory $testDir | Out-Null
try {
    # Transport must keep the pin, preserve Unicode bodies, and never send the token publicly.
    function Mock-Curl {
        $script:CapturedArgs = @($args)
        $bodyAt = [array]::IndexOf($args, '--data-binary')
        if ($bodyAt -ge 0) {
            $script:BodyPath = $args[$bodyAt + 1].Substring(1)
            $script:CapturedBody = Get-Content -LiteralPath $script:BodyPath -Raw | ConvertFrom-Json
        }
        $global:LASTEXITCODE = 0
        '{"ok":true}'
    }
    $CurlExecutable = 'Mock-Curl'
    $result = Call 'POST' '/admin/codes' @{ note = "中文 空格`n第二行 📷"; count = 1 }
    Assert $result.ok 'Admin request failed'
    Assert ($CapturedArgs -contains $ServerPin) 'Certificate pin missing'
    Assert ($CapturedArgs -contains 'X-Admin-Token: mac-test-token') 'Admin token missing'
    Assert ($CapturedBody.note -eq "中文 空格`n第二行 📷") 'UTF-8 body changed'
    Assert (-not (Test-Path -LiteralPath $BodyPath)) 'Temporary request body not removed'
    $null = Call 'GET' '/v1/pricing' $null
    Assert (-not ($CapturedArgs -match 'X-Admin-Token')) 'Public request leaked token'
    Write-Host 'PASS: pinned admin transport and public token isolation'

    # SDK discovery converts Windows filenames and handles paths with spaces/Chinese.
    $env:ANDROID_HOME = Join-Path $testDir '安卓 SDK'
    $toolDir = Join-Path $env:ANDROID_HOME 'build-tools/99.0.0'
    New-Item -ItemType Directory $toolDir -Force | Out-Null
    $tool = Join-Path $toolDir 'zt-test-signer'
    Set-Content -LiteralPath $tool -Value '#!/bin/sh' -Encoding UTF8
    $found = Find-AndroidTool @('zt-test-signer.bat') @('build-tools\*\zt-test-signer.bat')
    Assert ($found -eq $tool) 'Mac SDK discovery failed'
    Write-Host 'PASS: Mac SDK names and paths'

    # Read / write fake keychain credentials, then check environment restoration on OSS failure.
    function /usr/bin/security {
        if ($args[0] -eq 'add-generic-password') {
            $script:StoredCredential = $args[[array]::IndexOf($args, '-w') + 1]
        } else { $script:StoredCredential }
        $global:LASTEXITCODE = 0
    }
    function Mock-OssUtil {
        Assert ($env:OSS_ACCESS_KEY_ID -eq 'fake-id') 'OSS access ID not passed'
        Assert ($env:OSS_ACCESS_KEY_SECRET -eq 'fake-secret') 'OSS secret not passed'
        $global:LASTEXITCODE = $script:OssExit
    }
    function Get-OssUtilPath { return 'Mock-OssUtil' }
    function Read-Host { $script:Answers.Dequeue() }
    $script:Answers = [Collections.Generic.Queue[string]]::new()
    $Answers.Enqueue(' fake-id ')
    $Answers.Enqueue(' fake-secret ')
    $script:OssExit = 0
    Assert (Invoke-OssSetup) 'Mac OSS setup failed'
    $credential = Get-OssCredentials
    Assert ($credential.AccessKeySecret -eq 'fake-secret') 'Keychain round trip failed'
    $env:OSS_ACCESS_KEY_ID = 'previous-id'
    $env:OSS_ACCESS_KEY_SECRET = 'previous-secret'
    $script:OssExit = 42
    Assert ((Invoke-OssUtilAuthenticated 'Mock-OssUtil' @('ls')) -eq 42) 'OSS exit code lost'
    Assert ($env:OSS_ACCESS_KEY_ID -eq 'previous-id') 'OSS ID was not restored'
    Assert ($env:OSS_ACCESS_KEY_SECRET -eq 'previous-secret') 'OSS secret was not restored'
    Write-Host 'PASS: Mac keychain flow and OSS environment restoration'

    # Native dialog cancellation must return directly, without another prompt.
    $apk = Join-Path $testDir '中文 相册 (test).apk'
    Set-Content -LiteralPath $apk 'fake APK'
    function /usr/bin/osascript { $global:LASTEXITCODE = $script:DialogExit; $script:SelectedPath }
    $script:DialogExit = 0
    $script:SelectedPath = $apk
    Assert ((Select-ApkFile) -eq $apk) 'Dialog path changed'
    $script:SelectedPath = ''
    Assert ($null -eq (Select-ApkFile)) 'Dialog cancellation failed'
    $script:DialogExit = 1
    $Answers.Enqueue(($apk -replace '([ ()])', '\$1'))
    Assert ((Select-ApkFile) -eq $apk) 'Dragged Terminal path decoding failed'
    Write-Host 'PASS: file choice, cancellation, escaped drag-and-drop path'

    # Notes cross the native-editor boundary as UTF-8 JSON, preserving empty and multiline input.
    function /usr/bin/osascript {
        $script:NotesResultFile = $args[-1]
        $global:LASTEXITCODE = 0
        if ($script:NotesMode -eq 'failure') { $global:LASTEXITCODE = 1; return }
        $json = switch ($script:NotesMode) {
            'cancel' { '{"accepted":false,"text":""}' }
            'empty' { '{"accepted":true,"text":""}' }
            'invalid' { '{}' }
            default { @{ accepted = $true; text = "新增参数海报 📷`n`n优化中文输入，支持`“多行粘贴`”。" } | ConvertTo-Json -Compress }
        }
        [IO.File]::WriteAllText($script:NotesResultFile, $json, [Text.UTF8Encoding]::new($false))
    }
    $script:NotesMode = 'text'
    $notes = Read-UpdateNotes
    Assert $notes.Accepted 'Notes not accepted'
    Assert ($notes.Text -eq "新增参数海报 📷`n`n优化中文输入，支持`“多行粘贴`”。") 'Notes text changed'
    Assert (-not (Test-Path -LiteralPath $NotesResultFile)) 'Notes temporary file leaked'
    $script:NotesMode = 'empty'
    $notes = Read-UpdateNotes
    Assert ($notes.Accepted -and $notes.Text -eq '') 'Empty notes must be allowed'
    foreach ($mode in @('cancel', 'invalid', 'failure')) {
        $script:NotesMode = $mode
        Assert (-not (Read-UpdateNotes).Accepted) "Unsafe result: $mode"
        Assert (-not (Test-Path -LiteralPath $NotesResultFile)) 'Failed notes temporary file leaked'
    }
    $AdminIsMac = $false
    $Answers.Enqueue('Windows 单行说明')
    Assert ((Read-UpdateNotes).Text -eq 'Windows 单行说明') 'Windows notes input changed'
    $AdminIsMac = $true
    # Cancellation must stop before selecting the update policy or uploading anything.
    function Get-UpdatePublishState { @{ Current = $null } }
    function Select-ApkFile { 'fake.apk' }
    function Read-LocalApkMetadata { @{ VersionCode = 999; VersionName = '9.99'; Sha256 = ('a' * 64) } }
    function Upload-VersionedApkToOss { throw 'Upload must not run after notes cancellation' }
    $script:NotesMode = 'cancel'
    Invoke-UpdatePublish
    Assert ($Answers.Count -eq 0) 'Unexpected terminal notes or policy input'
    Write-Host 'PASS: Unicode multiline/empty notes, Windows fallback, cancellation and failure stop publication'

    # Generation reuses the original logic and copies all codes with UTF-8 text.
    function Call { @{ ok = $true; codes = @('ABC123', 'DEF456') } }
    function /usr/bin/pbcopy { $script:CopiedCodes = @($input) -join "`n"; $global:LASTEXITCODE = 0 }
    $Answers.Enqueue('2'); $Answers.Enqueue('测试'); $Answers.Enqueue('365')
    Invoke-NewCodes
    Assert ($CopiedCodes -eq "ABC123`nDEF456") 'Clipboard lost codes'
    Write-Host 'PASS: code generation clipboard'
} finally {
    Remove-Item -LiteralPath $testDir -Recurse -Force
}
