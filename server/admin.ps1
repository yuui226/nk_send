# ZTransfer 激活码管理脚本(在你自己的 Windows 电脑上运行)。
# 先设置环境变量(或改下面两行默认值):
#   $env:ZT_SERVER = "https://<ECS公网IP>:8443"
#   $env:ZT_ADMIN_TOKEN = "<config.json 里的 adminToken>"
# 用法:
#   .\admin.ps1 new 5 "7月QQ群批次"      生成 5 个激活码
#   .\admin.ps1 list                     台账(码 + 绑定)
#   .\admin.ps1 unbind KRMXTP ZT-YYYY-YYYY   解绑(激活码 6 位;第二个参数是设备码)
#   .\admin.ps1 revoke KRMXTP "退款"          吊销
param(
    [Parameter(Mandatory = $true)][string]$Cmd,
    [string]$A1,
    [string]$A2
)

$server = if ($env:ZT_SERVER) { $env:ZT_SERVER } else { "https://127.0.0.1:8443" }
$token = $env:ZT_ADMIN_TOKEN
if (-not $token) { Write-Error "请先设置 `$env:ZT_ADMIN_TOKEN"; exit 1 }

# 自签名证书,用 curl.exe -k 跳过系统证书校验(身份由 admin token 保证)
function Call($method, $path, $body) {
    $args = @("-k", "-s", "-X", $method, "-H", "X-Admin-Token: $token", "$server$path")
    if ($body) { $args += @("-H", "Content-Type: application/json", "-d", $body) }
    $out = & curl.exe @args
    if (-not $out) { Write-Error "服务器无响应: $server"; exit 1 }
    $out | python -m json.tool 2>$null
    if ($LASTEXITCODE -ne 0) { $out }
}

switch ($Cmd) {
    "new" {
        $count = if ($A1) { [int]$A1 } else { 1 }
        $note = if ($A2) { $A2 } else { "" }
        Call "POST" "/admin/codes" (@{ count = $count; note = $note } | ConvertTo-Json -Compress)
    }
    "list" { Call "GET" "/admin/codes" $null }
    "unbind" { Call "POST" "/admin/unbind" (@{ code = $A1; fp = $A2 } | ConvertTo-Json -Compress) }
    "revoke" { Call "POST" "/admin/revoke" (@{ code = $A1; reason = $A2 } | ConvertTo-Json -Compress) }
    default { Write-Error "未知命令: $Cmd(可用: new / list / unbind / revoke)"; exit 1 }
}
