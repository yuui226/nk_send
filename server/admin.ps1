# ZTransfer 激活码管理(在你自己的 Windows 电脑上运行)。
# 双击同目录的《激活码管理.bat》进入交互菜单;也可以命令行调用:
#   .\admin.ps1 new 5 "7月QQ群批次"           生成 5 个激活码
#   .\admin.ps1 list                          台账(码 + 绑定)
#   .\admin.ps1 unbind KRMXTP ZT-YYYY-YYYY    解绑(激活码 6 位;第二个参数是设备码)
#   .\admin.ps1 revoke KRMXTP "退款"          吊销
# 管理员令牌:优先读环境变量 ZT_ADMIN_TOKEN,否则读同目录 admin-token.txt,
# 都没有则首次运行时提示输入并保存到 admin-token.txt(该文件是密钥,勿外传)。
param(
    [string]$Cmd,
    [string]$A1,
    [string]$A2
)

$ErrorActionPreference = 'Stop'
# curl 输出是 UTF-8(备注可能含中文),让 PowerShell 按 UTF-8 解码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Server = if ($env:ZT_SERVER) { $env:ZT_SERVER } else { "https://106.15.239.203:8443" }
$TokenFile = Join-Path $PSScriptRoot "admin-token.txt"

function Get-SavedToken {
    if ($env:ZT_ADMIN_TOKEN) { return $env:ZT_ADMIN_TOKEN }
    if (Test-Path $TokenFile) {
        $t = (Get-Content $TokenFile -Raw).Trim()
        if ($t) { return $t }
    }
    return $null
}

function Request-Token {
    Write-Host ""
    Write-Host "首次使用:请输入管理员令牌(服务器 config.json 里的 adminToken)" -ForegroundColor Yellow
    $t = (Read-Host "adminToken").Trim()
    if (-not $t) { return $null }
    [IO.File]::WriteAllText($TokenFile, $t, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已保存到 $TokenFile(此文件等同密码,不要发给别人)" -ForegroundColor DarkGray
    return $t
}

# 自签名证书,用 curl.exe -k 跳过系统证书校验(身份由 admin token 保证)。
# 请求体走临时文件,避免 PowerShell 5.1 按 GBK 传中文参数导致乱码。
function Call($method, $path, $bodyObj) {
    $curlArgs = @("-k", "-s", "-X", $method, "-H", "X-Admin-Token: $script:Token", "$Server$path")
    $tmp = $null
    if ($bodyObj) {
        $json = $bodyObj | ConvertTo-Json -Compress
        $tmp = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        $curlArgs += @("-H", "Content-Type: application/json", "--data-binary", "@$tmp")
    }
    try { $out = & curl.exe @curlArgs }
    finally { if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
    if (-not $out) {
        Write-Host "服务器无响应: $Server(检查网络 / 服务是否在跑)" -ForegroundColor Red
        return $null
    }
    $joined = ($out -join "`n")
    try { return $joined | ConvertFrom-Json }
    catch { Write-Host $joined; return $null }
}

function Show-Error($resp) {
    if ($null -eq $resp) { return }
    $err = if ($resp.err) { $resp.err } else { ($resp | ConvertTo-Json -Compress) }
    $hint = switch ($resp.err) {
        "NOT_FOUND" { "(没有这个激活码 / 绑定)" }
        "AMBIGUOUS" { "(设备码前缀匹配到多台设备,请输入更完整的设备码)" }
        "FP_REQUIRED" { "(缺少设备码)" }
        default { "" }
    }
    Write-Host "失败: $err $hint" -ForegroundColor Red
}

function Format-Time($iso) {
    if (-not $iso) { return "-" }
    try { return ([datetime]$iso).ToLocalTime().ToString("yyyy-MM-dd HH:mm") } catch { return $iso }
}

function Get-Ledger {
    $resp = Call "GET" "/admin/codes" $null
    if (-not $resp) { return $null }
    if (-not $resp.ok) { Show-Error $resp; return $null }
    return $resp
}

function Show-Ledger($resp) {
    $codes = @($resp.codes)
    if ($codes.Count -eq 0) { Write-Host "(还没有生成过激活码)" -ForegroundColor DarkGray; return }
    Write-Host ""
    Write-Host ("共 {0} 个激活码:" -f $codes.Count)
    foreach ($c in $codes) {
        $color = if ($c.status -eq "active") { "Green" } else { "Red" }
        $bindings = @($c.bindings)
        Write-Host ("  {0}" -f $c.code) -NoNewline -ForegroundColor $color
        Write-Host ("  [{0}]  设备 {1}/{2}  创建 {3}  {4}" -f `
            $c.status, $bindings.Count, $c.max_devices, (Format-Time $c.created_at), $c.note)
        if ($c.status -eq "revoked" -and $c.revoke_reason) {
            Write-Host ("      吊销原因: {0}" -f $c.revoke_reason) -ForegroundColor DarkRed
        }
        foreach ($b in $bindings) {
            Write-Host ("      - {0}  {1}  激活 {2}  最近续签 {3}" -f `
                $b.fp, $b.model, (Format-Time $b.activated_at), (Format-Time $b.last_renew_at)) -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

function Invoke-NewCodes {
    $countIn = Read-Host "生成几个?(直接回车 = 1)"
    $count = 1
    if ($countIn -match '^\d+$') { $count = [int]$countIn }
    $note = Read-Host "备注(比如 '7月QQ群批次',可留空)"
    $resp = Call "POST" "/admin/codes" @{ count = $count; note = $note }
    if (-not $resp) { return }
    if (-not $resp.ok) { Show-Error $resp; return }
    Write-Host ""
    Write-Host ("生成了 {0} 个激活码:" -f @($resp.codes).Count) -ForegroundColor Green
    foreach ($c in $resp.codes) { Write-Host "  $c" -ForegroundColor Green }
    try {
        Set-Clipboard -Value (@($resp.codes) -join "`r`n")
        Write-Host "(已复制到剪贴板)" -ForegroundColor DarkGray
    } catch {}
    Write-Host ""
}

function Invoke-Unbind {
    $code = (Read-Host "要解绑的激活码(6 位)").Trim().ToUpper()
    if (-not $code) { return }
    $ledger = Get-Ledger
    if (-not $ledger) { return }
    $entry = @($ledger.codes) | Where-Object { $_.code -eq $code } | Select-Object -First 1
    if (-not $entry) { Write-Host "没有这个激活码: $code" -ForegroundColor Red; return }
    $bindings = @($entry.bindings)
    if ($bindings.Count -eq 0) { Write-Host "该码当前没有绑定任何设备" -ForegroundColor Yellow; return }
    Write-Host ""
    for ($i = 0; $i -lt $bindings.Count; $i++) {
        $b = $bindings[$i]
        Write-Host ("  [{0}] {1}  {2}  激活 {3}  最近续签 {4}" -f `
            ($i + 1), $b.fp, $b.model, (Format-Time $b.activated_at), (Format-Time $b.last_renew_at))
    }
    $pick = Read-Host "解绑哪台?输入序号(回车取消)"
    if ($pick -notmatch '^\d+$') { Write-Host "已取消"; return }
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $bindings.Count) { Write-Host "序号不对,已取消" -ForegroundColor Red; return }
    $resp = Call "POST" "/admin/unbind" @{ code = $code; fp = $bindings[$idx].fp }
    if ($resp -and $resp.ok) { Write-Host "已解绑,用户可以在新设备上重新激活" -ForegroundColor Green }
    else { Show-Error $resp }
}

function Invoke-Revoke {
    $code = (Read-Host "要吊销的激活码(6 位)").Trim().ToUpper()
    if (-not $code) { return }
    $reason = Read-Host "原因(比如 '退款')"
    $confirm = Read-Host "确认吊销 $code ?该码所有设备将降级为免费版。输入 y 确认"
    if ($confirm -ne "y") { Write-Host "已取消"; return }
    $resp = Call "POST" "/admin/revoke" @{ code = $code; reason = $reason }
    if ($resp -and $resp.ok) { Write-Host "已吊销" -ForegroundColor Green }
    else { Show-Error $resp }
}

function Test-Server {
    $resp = Call "GET" "/healthz" $null
    if ($resp -and $resp.ok) { Write-Host "服务器正常: $Server" -ForegroundColor Green }
    elseif ($resp) { Show-Error $resp }
}

# ---------------------------------------------------------------- 入口

$script:Token = Get-SavedToken

if ($Cmd) {
    # 命令行模式(兼容旧用法)
    if (-not $script:Token) { Write-Error "请先设置 `$env:ZT_ADMIN_TOKEN 或在同目录放 admin-token.txt"; exit 1 }
    $resp = switch ($Cmd) {
        "new" {
            $count = if ($A1) { [int]$A1 } else { 1 }
            $note = if ($A2) { $A2 } else { "" }
            Call "POST" "/admin/codes" @{ count = $count; note = $note }
        }
        "list" { Call "GET" "/admin/codes" $null }
        "unbind" { Call "POST" "/admin/unbind" @{ code = $A1; fp = $A2 } }
        "revoke" { Call "POST" "/admin/revoke" @{ code = $A1; reason = $A2 } }
        default { Write-Error "未知命令: $Cmd(可用: new / list / unbind / revoke)"; exit 1 }
    }
    if ($resp) { $resp | ConvertTo-Json -Depth 6 }
    exit 0
}

# 交互模式(双击 bat 进入)
if (-not $script:Token) {
    $script:Token = Request-Token
    if (-not $script:Token) { Write-Host "没有令牌,无法继续" -ForegroundColor Red; Read-Host "回车退出"; exit 1 }
}

while ($true) {
    Write-Host ""
    Write-Host "=============== ZTransfer 激活码管理 ===============" -ForegroundColor Cyan
    Write-Host " 服务器: $Server"
    Write-Host ""
    Write-Host "  [1] 生成激活码"
    Write-Host "  [2] 台账(所有码 + 绑定设备)"
    Write-Host "  [3] 解绑设备(用户换手机)"
    Write-Host "  [4] 吊销激活码(退款)"
    Write-Host "  [5] 测试服务器连接"
    Write-Host "  [0] 退出"
    Write-Host ""
    $choice = Read-Host "选择"
    switch ($choice.Trim()) {
        "1" { Invoke-NewCodes }
        "2" { $l = Get-Ledger; if ($l) { Show-Ledger $l } }
        "3" { Invoke-Unbind }
        "4" { Invoke-Revoke }
        "5" { Test-Server }
        "0" { exit 0 }
        default { Write-Host "输入 0-5" -ForegroundColor Yellow }
    }
}
