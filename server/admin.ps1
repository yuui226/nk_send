# ZTransfer 激活码管理(在你自己的 Windows 电脑上运行)。
# 双击同目录的《激活码管理.bat》进入交互菜单;也可以命令行调用:
#   .\admin.ps1 new 5 "7月QQ群批次"           生成 5 个永久激活码
#   .\admin.ps1 new 5 "年费补发" 365          生成 5 个 365 天激活码(第三个参数是有效期天数)
#   .\admin.ps1 list                          台账(码 + 绑定)
#   .\admin.ps1 unbind KRMXTP ZT-YYYY-YYYY    解绑(激活码 6 位;第二个参数是设备码)
#   .\admin.ps1 revoke KRMXTP "退款"          吊销
#   .\admin.ps1 unrevoke KRMXTP               解除吊销(查重误伤时用)
#   .\admin.ps1 expiry KRMXTP 0               把该码设为永久(送永久授权)
#   .\admin.ps1 expiry KRMXTP 90              在现有到期日上延长 90 天(补偿)
# 管理员令牌:优先读环境变量 ZT_ADMIN_TOKEN,否则读同目录 admin-token.txt,
# 都没有则首次运行时提示输入并保存到 admin-token.txt(该文件是密钥,勿外传)。
param(
    [string]$Cmd,
    [string]$A1,
    [string]$A2,
    [string]$A3
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

# 有效期:空 = 永久(手动发的码),否则订阅到期时刻。已过期的标黄——那台机现在是免费版。
function Format-Expiry($iso) {
    if (-not $iso) { return @{ Text = "永久"; Color = "Cyan" } }
    try { $d = ([datetime]$iso).ToLocalTime() } catch { return @{ Text = $iso; Color = "Gray" } }
    if ($d -lt (Get-Date)) { return @{ Text = ("已过期 {0}" -f $d.ToString("yyyy-MM-dd")); Color = "Yellow" } }
    return @{ Text = ("{0} 到期" -f $d.ToString("yyyy-MM-dd")); Color = "Gray" }
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
        # 单设备浮动授权:在用设备最多 1 台(新机激活即顶替旧机)。
        Write-Host ("  [{0}]  在用 {1} 台  " -f $c.status, $bindings.Count) -NoNewline
        $exp = Format-Expiry $c.expires_at
        Write-Host $exp.Text -NoNewline -ForegroundColor $exp.Color
        Write-Host ("  创建 {0}  {1}" -f (Format-Time $c.created_at), $c.note)
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
    # 手动发码默认永久(自测/补偿/送人);要发年费码就填 365。
    $daysIn = Read-Host "有效期天数(回车 = 永久;年费填 365)"
    $days = 0
    if ($daysIn -match '^\d+$') { $days = [int]$daysIn }
    $resp = Call "POST" "/admin/codes" @{ count = $count; note = $note; days = $days }
    if (-not $resp) { return }
    if (-not $resp.ok) { Show-Error $resp; return }
    Write-Host ""
    $kind = if ($days -gt 0) { "{0} 天有效期" -f $days } else { "永久" }
    Write-Host ("生成了 {0} 个激活码({1}):" -f @($resp.codes).Count, $kind) -ForegroundColor Green
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

function Invoke-Unrevoke {
    $code = (Read-Host "要解除吊销的激活码(6 位)").Trim().ToUpper()
    if (-not $code) { return }
    Write-Host ""
    Write-Host "解除吊销会同时清空该码近 30 天的激活记录(否则次数还在窗口里,用户一激活又被自动吊销)。" -ForegroundColor Yellow
    Write-Host "记录清了就查不到滥用证据,请确认是误伤再继续。" -ForegroundColor Yellow
    $confirm = Read-Host "确认解除 $code ?输入 y 确认"
    if ($confirm -ne "y") { Write-Host "已取消"; return }
    $resp = Call "POST" "/admin/unrevoke" @{ code = $code }
    if ($resp -and $resp.ok) {
        # App 收到 CODE_REVOKED 时已经把本地的码删了,不会自己回来;必须让用户主动走"恢复授权"。
        Write-Host ("已解除吊销,清空了 {0} 条激活记录。请让用户在 App 里点『恢复授权』找回。" -f $resp.cleared_activations) -ForegroundColor Green
    }
    else { Show-Error $resp }
}

function Invoke-Expiry {
    $code = (Read-Host "要改有效期的激活码(6 位)").Trim().ToUpper()
    if (-not $code) { return }
    # 先把它现在的状态摆出来再让人选,免得改错码
    $ledger = Get-Ledger
    if (-not $ledger) { return }
    $entry = @($ledger.codes) | Where-Object { $_.code -eq $code } | Select-Object -First 1
    if (-not $entry) { Write-Host "没有这个激活码: $code" -ForegroundColor Red; return }
    $exp = Format-Expiry $entry.expires_at
    Write-Host ""
    Write-Host ("  {0}  [{1}]  当前:" -f $entry.code, $entry.status) -NoNewline
    Write-Host (" " + $exp.Text) -ForegroundColor $exp.Color
    Write-Host ""
    Write-Host "  [1] 设为永久(送永久授权)"
    Write-Host "  [2] 延长 N 天(补偿;在现有到期日基础上加,不吃掉剩余时间)"
    $pick = Read-Host "选择(回车取消)"
    $days = -1
    switch ($pick.Trim()) {
        "1" { $days = 0 }
        "2" {
            $n = Read-Host "延长几天?(比如 90)"
            if ($n -match '^\d+$' -and [int]$n -gt 0) { $days = [int]$n }
        }
    }
    if ($days -lt 0) { Write-Host "已取消"; return }
    $resp = Call "POST" "/admin/expiry" @{ code = $code; days = $days }
    if ($resp -and $resp.ok) {
        if ($resp.expires_at) {
            Write-Host ("已改为 {0} 到期" -f (Format-Time $resp.expires_at)) -ForegroundColor Green
        }
        else {
            Write-Host "已设为永久有效" -ForegroundColor Green
        }
        Write-Host "用户不用做任何事:重开 App(或最多 24 小时内的自动续签)即生效。" -ForegroundColor DarkGray
    }
    elseif ($resp -and $resp.err -eq "ALREADY_PERMANENT") {
        Write-Host "失败: 这已经是永久码,没有到期日可延" -ForegroundColor Red
    }
    elseif ($resp -and $resp.err -eq "CODE_REVOKED") {
        Write-Host "失败: 该码已被吊销,改有效期没意义——请先用 [5] 解除吊销" -ForegroundColor Red
    }
    else { Show-Error $resp }
}

function Invoke-Pricing {
    $resp = Call "GET" "/v1/pricing" $null
    if ($resp -and $resp.ok) {
        $cur = "{0:N2} 元" -f ($resp.price_fen / 100)
        $org = if ($resp.original_fen -gt 0) { "{0:N2} 元" -f ($resp.original_fen / 100) } else { "不划线" }
        Write-Host ""
        Write-Host ("当前定价: {0} / {1} 天   划线原价: {2}" -f $cur, $resp.period_days, $org) -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "改价立即对新订单生效,不用重启服务;已生成的二维码仍按下单时的价收款。" -ForegroundColor DarkGray
    $priceIn = Read-Host "新售价(元,比如 19.9;回车取消)"
    if (-not ($priceIn -match '^\d+(\.\d{1,2})?$')) { Write-Host "已取消"; return }
    $orgIn = Read-Host "划线原价(元,比如 39.9;回车 = 不划线)"
    $priceFen = [int][math]::Round([double]$priceIn * 100)
    $orgFen = 0
    if ($orgIn -match '^\d+(\.\d{1,2})?$') { $orgFen = [int][math]::Round([double]$orgIn * 100) }
    $resp = Call "POST" "/admin/pricing" @{ price_fen = $priceFen; original_fen = $orgFen }
    if ($resp -and $resp.ok) {
        $org = if ($resp.original_fen -gt 0) { "{0:N2} 元" -f ($resp.original_fen / 100) } else { "不划线" }
        Write-Host ("已改为 {0:N2} 元 / {1} 天,划线原价 {2}" -f ($resp.price_fen / 100), $resp.period_days, $org) -ForegroundColor Green
        Write-Host "App 端每天启动时最多拉一次新价,老用户界面上的展示价最多滞后一天;" -ForegroundColor DarkGray
        Write-Host "但下单时现读服务端,收的钱永远是这个新价。" -ForegroundColor DarkGray
    }
    elseif ($resp -and $resp.err -eq "ORIGINAL_TOO_LOW") {
        Write-Host "失败: 划线原价低于售价,这样就成了'原价更便宜'的反向促销——多半是填反了" -ForegroundColor Red
    }
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
            $days = if ($A3) { [int]$A3 } else { 0 }   # 0 = 永久
            Call "POST" "/admin/codes" @{ count = $count; note = $note; days = $days }
        }
        "list" { Call "GET" "/admin/codes" $null }
        "unbind" { Call "POST" "/admin/unbind" @{ code = $A1; fp = $A2 } }
        "revoke" { Call "POST" "/admin/revoke" @{ code = $A1; reason = $A2 } }
        "unrevoke" { Call "POST" "/admin/unrevoke" @{ code = $A1 } }
        "expiry" { Call "POST" "/admin/expiry" @{ code = $A1; days = [int]$A2 } }
        "pricing" {
            # 无参 = 查当前定价;有参 = 改价(单位:元)
            if ($A1) { Call "POST" "/admin/pricing" @{ price_fen = [int][math]::Round([double]$A1 * 100); original_fen = if ($A2) { [int][math]::Round([double]$A2 * 100) } else { 0 } } }
            else { Call "GET" "/v1/pricing" $null }
        }
        default { Write-Error "未知命令: $Cmd(可用: new / list / unbind / revoke / unrevoke / pricing)"; exit 1 }
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
    Write-Host "  [5] 解除吊销(查重误伤了正版用户)"
    Write-Host "  [6] 修改定价(售价 / 划线原价)"
    Write-Host "  [7] 修改有效期(送永久 / 补偿延期)"
    Write-Host "  [8] 测试服务器连接"
    Write-Host "  [0] 退出"
    Write-Host ""
    $choice = Read-Host "选择"
    switch ($choice.Trim()) {
        "1" { Invoke-NewCodes }
        "2" { $l = Get-Ledger; if ($l) { Show-Ledger $l } }
        "3" { Invoke-Unbind }
        "4" { Invoke-Revoke }
        "5" { Invoke-Unrevoke }
        "6" { Invoke-Pricing }
        "7" { Invoke-Expiry }
        "8" { Test-Server }
        "0" { exit 0 }
        default { Write-Host "输入 0-8" -ForegroundColor Yellow }
    }
}
