# ZTransfer 图形管理中心。
# 这是原命令行管理器的独立 UI，底层复用 admin.ps1 中已经验证过的安全请求、APK 和 OSS 逻辑。
[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
trap {
    [Windows.MessageBox]::Show(
        "管理器遇到未处理的错误：`n$($_.Exception.Message)",
        'ZTransfer 管理中心',
        [Windows.MessageBoxButton]::OK,
        [Windows.MessageBoxImage]::Error
    ) | Out-Null
    exit 1
}

$legacyScript = Join-Path $PSScriptRoot 'admin.ps1'
$xamlPath = Join-Path $PSScriptRoot 'admin-gui.xaml'
if (-not (Test-Path -LiteralPath $legacyScript) -or -not (Test-Path -LiteralPath $xamlPath)) {
    [System.Windows.MessageBox]::Show('管理器文件不完整，请确认 admin.ps1 和 admin-gui.xaml 位于同一目录。', 'ZTransfer 管理中心') | Out-Null
    exit 1
}

. $legacyScript -LibraryMode
$script:AdminCurlConnectTimeoutSeconds = 10
$script:AdminCurlMaxTimeSeconds = 30

[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$reader.Close()
$iconPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\品牌素材\ztransfer_icon_320.png'
if (Test-Path -LiteralPath $iconPath) {
    $icon = New-Object Windows.Media.Imaging.BitmapImage
    $icon.BeginInit()
    $icon.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $icon.UriSource = New-Object System.Uri -ArgumentList $iconPath
    $icon.EndInit()
    $icon.Freeze()
    $window.Icon = $icon
}

$controlNames = @(
    'RootGrid','NavOverview','NavCodes','NavPricing','NavUpdates','NavSettings',
    'SidebarServer','PageTitle','PageSubtitle','ServerDot','ServerStatus','RefreshButton',
    'PageOverview','MetricCodes','MetricDevices','MetricRevoked','MetricUnbound','RecentCodesGrid',
    'QuickNewCode','QuickPublish','QuickTest','PaidAlert','PaidAlertText','PaidAlertButton',
    'PageCodes','CodeSearch','CodeStatusFilter','NewCodeButton','CodesGrid','DetailHint',
    'CodeDetailPanel','DetailCode','DetailStatus','DetailDevice','DetailNote','UnbindButton',
    'ExpiryButton','RevokeButton','UnrevokeButton',
    'PagePricing','AnnualState','AnnualPrice','AnnualOriginal','SaveAnnual','LifetimeState',
    'LifetimePrice','LifetimeOriginal','SaveLifetime',
    'PageUpdates','ReleaseTitle','ReleaseDetails','ValidateUpdate','ChangePolicy','StageApk',
    'PublishApk','ConfigureOss','OssState','StatsScope','StatsGrid',
    'PageSettings','SettingsServer','TokenState','SetToken','TestServerButton',
    'SettingsOssState','SettingsConfigureOss','FooterStatus','BusyText','BusyBar'
)
$ui = @{}
foreach ($name in $controlNames) { $ui[$name] = $window.FindName($name) }

$script:Ledger = $null
$script:LedgerRows = @()
$script:FilteredLedgerRows = @()
$script:Pricing = $null
$script:Release = $null
$script:StatsRows = @()
$script:CurrentPage = 'Overview'
$script:IsBusy = $false
$script:ActiveWorker = $null
$script:PageLoaded = @{ Overview = $false; Codes = $false; Pricing = $false; Updates = $false; Settings = $false }

function New-Brush([string]$hex) {
    return [Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

function Set-Footer([string]$text) {
    $ui.FooterStatus.Text = $text
}

function Set-Busy([bool]$busy, [string]$text = '') {
    $script:IsBusy = $busy
    $ui.RootGrid.IsEnabled = -not $busy
    $window.Cursor = if ($busy) { [Windows.Input.Cursors]::Wait } else { [Windows.Input.Cursors]::Arrow }
    $ui.BusyText.Text = if ($busy) { $text } else { '' }
    $ui.BusyBar.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
    $ui.RefreshButton.IsEnabled = -not $busy
    $window.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::Render, [Action]{})
}

function Start-CoreWorker([string]$operation, [hashtable]$payload, [string]$busyText, [scriptblock]$onSuccess) {
    if ($script:ActiveWorker) { return }
    Set-Busy $true $busyText
    $runspace = $null
    $powerShell = $null
    try {
        $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        $powerShell = [Management.Automation.PowerShell]::Create()
        $powerShell.Runspace = $runspace
        $workerBody = {
        param($corePath, $adminToken, $action, $data)
        $ErrorActionPreference = 'Stop'
        . $corePath -LibraryMode
        $script:Token = $adminToken
        $script:AdminCurlConnectTimeoutSeconds = 10
        $script:AdminCurlMaxTimeSeconds = 30

        switch ($action) {
            'stage' {
                $target = New-OssReleaseTarget $data.Meta
                if (-not (Upload-VersionedApkToOss $data.ApkPath $data.Meta $target)) { throw 'OSS 上传失败。' }
                if (-not (Test-PublicOssApk $target.PublicUrl $data.Meta)) { throw '公网对象校验失败。' }
                [PSCustomObject]@{ Ok=$true; Url=$target.PublicUrl; VersionName=$data.Meta.VersionName }
            }
            'publish' {
                $target = New-OssReleaseTarget $data.Meta
                if (-not (Upload-VersionedApkToOss $data.ApkPath $data.Meta $target)) { throw '版本 APK 上传失败。' }
                if (-not (Test-PublicOssApk $target.PublicUrl $data.Meta)) { throw '版本 APK 公网校验失败。' }

                $latestState = Get-UpdatePublishState
                if (-not $latestState) { throw '无法再次确认服务端版本，已停止发布。' }
                $latestCode = if ($latestState.Current) { [int]$latestState.Current.versionCode } else { 0 }
                if ($latestCode -ne [int]$data.InitialVersionCode) {
                    throw '上传期间服务端版本已变化，已停止发布，避免覆盖错误版本。'
                }
                if (-not (Copy-VersionedApkToLatest $data.Meta $target)) { throw '固定下载地址更新失败。' }
                if (-not (Test-PublicOssApk $target.LatestPublicUrl $data.Meta)) { throw '固定下载地址校验失败。' }

                $draft = @{
                    versionCode=[int]$data.Meta.VersionCode; versionName=[string]$data.Meta.VersionName
                    minSupportedVersionCode=[int]$data.MinSupportedVersionCode; url=[string]$target.PublicUrl
                    password=''; notes=[string]$data.Notes; sha256=[string]$data.Meta.Sha256
                    sizeBytes=[long]$data.Meta.SizeBytes; publishedAt=''
                }
                $resp = Call 'POST' '/admin/update/publish' $draft
                if (-not $resp -or -not $resp.ok) {
                    $detail = if ($resp.detail) { "：$($resp.detail)" } elseif ($resp.err) { "：$($resp.err)" } else { '' }
                    throw "服务端版本信息发布失败$detail"
                }
                [PSCustomObject]@{ Ok=$true; VersionName=$data.Meta.VersionName; Url=$target.PublicUrl }
            }
            'validate' {
                if (-not (Test-PublicOssApkFull $data.ReleaseUrl $data.Expected)) { throw '当前版本地址校验失败。' }
                if (-not (Test-PublicOssApkFull $data.LatestUrl $data.Expected)) { throw '固定下载地址校验失败。' }
                [PSCustomObject]@{ Ok=$true }
            }
            default { throw "未知后台操作：$action" }
        }
        }
        [void]$powerShell.AddScript($workerBody.ToString()).AddArgument($legacyScript).AddArgument($script:Token).AddArgument($operation).AddArgument($payload)
        $async = $powerShell.BeginInvoke()
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(120)
        $script:ActiveWorker = [PSCustomObject]@{
            PowerShell=$powerShell; Runspace=$runspace; Async=$async; Timer=$timer; OnSuccess=$onSuccess
        }
        $timer.Add_Tick({
            $job = $script:ActiveWorker
            if (-not $job -or -not $job.Async.IsCompleted) { return }
            $job.Timer.Stop()
            $result = $null
            $failure = $null
            try {
                $output = @($job.PowerShell.EndInvoke($job.Async))
                $result = $output | Select-Object -Last 1
                if ($job.PowerShell.HadErrors -and $job.PowerShell.Streams.Error.Count -gt 0) {
                    $failure = $job.PowerShell.Streams.Error[$job.PowerShell.Streams.Error.Count - 1].Exception.Message
                }
            } catch { $failure = $_.Exception.Message }
            $callback = $job.OnSuccess
            $job.PowerShell.Dispose()
            $job.Runspace.Dispose()
            $script:ActiveWorker = $null
            Set-Busy $false
            if ($failure) { Show-Notice $failure '操作未完成' 'Error'; Set-Footer $failure }
            else { & $callback $result }
        })
        $timer.Start()
    } catch {
        if ($powerShell) { $powerShell.Dispose() }
        if ($runspace) { $runspace.Dispose() }
        $script:ActiveWorker = $null
        Set-Busy $false
        throw
    }
}

function Show-Notice([string]$message, [string]$title = '提示', [string]$kind = 'Info') {
    $icon = switch ($kind) {
        'Error' { [Windows.MessageBoxImage]::Error }
        'Warning' { [Windows.MessageBoxImage]::Warning }
        default { [Windows.MessageBoxImage]::Information }
    }
    [Windows.MessageBox]::Show($window, $message, $title, [Windows.MessageBoxButton]::OK, $icon) | Out-Null
}

function Confirm-Action([string]$message, [string]$title = '请确认') {
    return [Windows.MessageBox]::Show(
        $window, $message, $title,
        [Windows.MessageBoxButton]::YesNo,
        [Windows.MessageBoxImage]::Warning,
        [Windows.MessageBoxResult]::No
    ) -eq [Windows.MessageBoxResult]::Yes
}

function Show-InputDialog([string]$title, [string]$description, [array]$fields, [string]$okText = '确定') {
    $dialog = New-Object Windows.Window
    $dialog.Title = $title
    $dialog.Owner = $window
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.SizeToContent = 'Height'
    $dialog.Width = 480
    $dialog.MinHeight = 220
    $dialog.ResizeMode = 'NoResize'
    $dialog.Background = New-Brush '#F7F9FC'
    $dialog.FontFamily = 'Microsoft YaHei UI'
    $dialog.FontSize = 13

    $card = New-Object Windows.Controls.Border
    $card.Margin = '18'
    $card.Padding = '22'
    $card.Background = New-Brush '#FFFFFF'
    $card.BorderBrush = New-Brush '#E2E8F0'
    $card.BorderThickness = '1'
    $card.CornerRadius = '12'
    $grid = New-Object Windows.Controls.Grid
    $card.Child = $grid
    $dialog.Content = $card

    $controls = @{}
    $row = 0
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $desc = New-Object Windows.Controls.TextBlock
    $desc.Text = $description
    $desc.TextWrapping = 'Wrap'
    $desc.Foreground = New-Brush '#667085'
    $desc.Margin = '0,0,0,16'
    [Windows.Controls.Grid]::SetRow($desc, $row++)
    $grid.Children.Add($desc) | Out-Null

    foreach ($field in $fields) {
        $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
        $label = New-Object Windows.Controls.TextBlock
        $label.Text = [string]$field.Label
        $label.Foreground = New-Brush '#475467'
        $label.Margin = '0,0,0,6'
        [Windows.Controls.Grid]::SetRow($label, $row++)
        $grid.Children.Add($label) | Out-Null

        $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
        if ($field.Secret) {
            $input = New-Object Windows.Controls.PasswordBox
            $input.Password = [string]$field.Value
        } elseif ($field.Choices) {
            $input = New-Object Windows.Controls.ComboBox
            $input.Padding = '8,6'
            foreach ($choice in @($field.Choices)) { $input.Items.Add([string]$choice) | Out-Null }
            $input.SelectedIndex = if ($null -ne $field.SelectedIndex) { [int]$field.SelectedIndex } else { 0 }
        } else {
            $input = New-Object Windows.Controls.TextBox
            $input.Text = [string]$field.Value
            if ($field.Multiline) {
                $input.AcceptsReturn = $true
                $input.TextWrapping = 'Wrap'
                $input.MinHeight = 72
                $input.VerticalContentAlignment = 'Top'
            }
        }
        $input.Padding = '9,7'
        $input.BorderBrush = New-Brush '#D9E0EA'
        $input.BorderThickness = '1'
        $input.Margin = '0,0,0,13'
        [Windows.Controls.Grid]::SetRow($input, $row++)
        $grid.Children.Add($input) | Out-Null
        $controls[[string]$field.Name] = $input
    }

    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Margin = '0,5,0,0'
    $cancel = New-Object Windows.Controls.Button
    $cancel.Content = '取消'
    $cancel.Padding = '18,8'
    $cancel.Margin = '0,0,8,0'
    $cancel.IsCancel = $true
    $ok = New-Object Windows.Controls.Button
    $ok.Content = $okText
    $ok.Padding = '18,8'
    $ok.Background = New-Brush '#2563EB'
    $ok.Foreground = New-Brush '#FFFFFF'
    $ok.BorderThickness = '0'
    $ok.IsDefault = $true
    $ok.Add_Click({ $dialog.DialogResult = $true })
    $buttons.Children.Add($cancel) | Out-Null
    $buttons.Children.Add($ok) | Out-Null
    [Windows.Controls.Grid]::SetRow($buttons, $row)
    $grid.Children.Add($buttons) | Out-Null

    if ($dialog.ShowDialog() -ne $true) { return $null }
    $result = @{}
    foreach ($field in $fields) {
        $control = $controls[[string]$field.Name]
        $result[[string]$field.Name] = if ($field.Secret) {
            $control.Password
        } elseif ($field.Choices) {
            $control.SelectedIndex
        } else {
            $control.Text
        }
    }
    return $result
}

function Get-ApiErrorText($resp) {
    if (-not $resp) { return '服务器没有返回有效响应，请检查网络、服务器地址和证书配置。' }
    $message = switch ([string]$resp.err) {
        'NOT_FOUND' { '没有找到对应的激活码或设备绑定。' }
        'AMBIGUOUS' { '设备标识匹配到多台设备，请刷新后重试。' }
        'CODE_REVOKED' { '该激活码已经吊销。' }
        'ALREADY_PERMANENT' { '该激活码已经永久有效。' }
        'ORIGINAL_TOO_LOW' { '划线原价必须严格高于售价，或填写 0。' }
        'UNAUTHORIZED' { '管理员令牌不正确。' }
        default { if ($resp.err) { "服务器返回错误：$($resp.err)" } else { '服务器请求失败。' } }
    }
    if ($resp.detail) { $message = "$message`n$($resp.detail)" }
    return $message
}

function Invoke-Api([string]$method, [string]$path, $body = $null, [bool]$requireOk = $true) {
    if ($path.StartsWith('/admin/') -and -not $script:Token) {
        if (-not (Request-GuiToken)) { throw '缺少管理员令牌。' }
    }
    $resp = Call $method $path $body
    if (-not $resp) { throw (Get-ApiErrorText $resp) }
    if ($requireOk -and -not $resp.ok) { throw (Get-ApiErrorText $resp) }
    return $resp
}

function Request-GuiToken {
    if ($script:Token) { return $true }
    $result = Show-InputDialog '管理员令牌' '首次使用需要服务器 config.json 中的 adminToken。令牌会保存在本机，请勿外传。' @(
        [PSCustomObject]@{ Name='Token'; Label='adminToken'; Value=''; Secret=$true }
    ) '保存并继续'
    if (-not $result) { return $false }
    $token = ([string]$result.Token).Trim()
    if (-not $token) { Show-Notice '令牌不能为空。' '无法保存' 'Warning'; return $false }
    [IO.File]::WriteAllText($TokenFile, $token, (New-Object Text.UTF8Encoding($false)))
    $script:Token = $token
    Update-SettingsState
    return $true
}

function Format-GuiTime($iso) {
    if (-not $iso) { return '—' }
    try { return ([datetime]$iso).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { return [string]$iso }
}

function Get-GuiExpiry($iso) {
    if (-not $iso) { return '永久' }
    try {
        $date = ([datetime]$iso).ToLocalTime()
        if ($date -lt (Get-Date)) { return '已过期 ' + $date.ToString('yyyy-MM-dd') }
        return $date.ToString('yyyy-MM-dd') + ' 到期'
    } catch { return [string]$iso }
}

function Convert-LedgerRows($ledger) {
    $rows = foreach ($code in @($ledger.codes)) {
        $bindings = @($code.bindings)
        $expired = $false
        if ($code.expires_at) {
            try { $expired = ([datetime]$code.expires_at).ToUniversalTime() -lt [datetime]::UtcNow } catch {}
        }
        $statusText = if ($code.status -eq 'revoked') { '已吊销' } elseif ($expired) { '已过期' } else { '正常' }
        $deviceModel = if ($bindings.Count -gt 0) {
            (@($bindings | ForEach-Object { if ($_.model) { $_.model } else { '未知设备' } }) -join '、')
        } else { '未绑定' }
        [PSCustomObject]@{
            Code = [string]$code.code
            Status = [string]$code.status
            StatusText = $statusText
            IsExpired = $expired
            ExpiryText = Get-GuiExpiry $code.expires_at
            DeviceModel = $deviceModel
            Note = [string]$code.note
            CreatedText = Format-GuiTime $code.created_at
            Raw = $code
        }
    }
    return @($rows)
}

function Apply-CodeFilter {
    $query = ([string]$ui.CodeSearch.Text).Trim().ToLowerInvariant()
    $selected = $ui.CodeStatusFilter.SelectedItem
    $status = if ($selected) { [string]$selected.Tag } else { 'all' }
    $script:FilteredLedgerRows = @($script:LedgerRows | Where-Object {
        $matchesStatus = $status -eq 'all' -or
            ($status -eq 'expired' -and $_.IsExpired) -or
            ($status -ne 'expired' -and $_.Status -eq $status -and -not ($status -eq 'active' -and $_.IsExpired))
        $haystack = ("{0} {1} {2}" -f $_.Code, $_.Note, $_.DeviceModel).ToLowerInvariant()
        $matchesStatus -and (-not $query -or $haystack.Contains($query))
    })
    $ui.CodesGrid.ItemsSource = $script:FilteredLedgerRows
    Set-Footer ("显示 {0} / {1} 个激活码" -f $script:FilteredLedgerRows.Count, $script:LedgerRows.Count)
}

function Update-CodeDetail {
    $row = $ui.CodesGrid.SelectedItem
    if (-not $row) {
        $ui.DetailHint.Visibility = 'Visible'
        $ui.CodeDetailPanel.Visibility = 'Collapsed'
        return
    }
    $code = $row.Raw
    $bindings = @($code.bindings)
    $deviceText = if ($bindings.Count -eq 0) { '未绑定设备' } else {
        @($bindings | ForEach-Object {
            $model = if ($_.model) { $_.model } else { '未知设备' }
            $fp = [string]$_.fp
            "${model}`n${fp}`n激活：$(Format-GuiTime $_.activated_at)`n最近续签：$(Format-GuiTime $_.last_renew_at)"
        }) -join "`n`n"
    }
    $ui.DetailHint.Visibility = 'Collapsed'
    $ui.CodeDetailPanel.Visibility = 'Visible'
    $ui.DetailCode.Text = $row.Code
    $statusLines = @("$($row.StatusText) · $($row.ExpiryText)", "创建：$($row.CreatedText)")
    if ($code.status -eq 'revoked') {
        if ($code.revoked_at) { $statusLines += "吊销：$(Format-GuiTime $code.revoked_at)" }
        if ($code.revoke_reason) { $statusLines += "原因：$($code.revoke_reason)" }
    }
    $ui.DetailStatus.Text = $statusLines -join "`n"
    $ui.DetailDevice.Text = $deviceText
    $ui.DetailNote.Text = if ($code.note) { [string]$code.note } else { '—' }
    $ui.UnbindButton.IsEnabled = $bindings.Count -gt 0
    $ui.ExpiryButton.IsEnabled = $code.status -ne 'revoked'
    $ui.RevokeButton.Visibility = if ($code.status -eq 'revoked') { 'Collapsed' } else { 'Visible' }
    $ui.UnrevokeButton.Visibility = if ($code.status -eq 'revoked') { 'Visible' } else { 'Collapsed' }
}

function Refresh-Ledger([bool]$showBusy = $true) {
    if ($showBusy) { Set-Busy $true '正在读取激活码…' }
    try {
        $script:Ledger = Invoke-Api 'GET' '/admin/codes'
        $script:LedgerRows = Convert-LedgerRows $script:Ledger
        Apply-CodeFilter
        $ui.RecentCodesGrid.ItemsSource = @($script:LedgerRows | Select-Object -First 6)
        $codes = @($script:Ledger.codes)
        $devices = 0
        foreach ($code in $codes) { $devices += @($code.bindings).Count }
        $revoked = @($codes | Where-Object { $_.status -eq 'revoked' }).Count
        $unbound = @($script:Ledger.paid_unbound).Count
        $ui.MetricCodes.Text = [string]$codes.Count
        $ui.MetricDevices.Text = [string]$devices
        $ui.MetricRevoked.Text = [string]$revoked
        $ui.MetricUnbound.Text = [string]$unbound
        if ($unbound -gt 0) {
            $ui.PaidAlert.Visibility = 'Visible'
            $ui.PaidAlertText.Text = "有 $unbound 笔已付款订单尚未完成设备绑定，请及时核对。"
        } else { $ui.PaidAlert.Visibility = 'Collapsed' }
        $script:PageLoaded.Overview = $true
        $script:PageLoaded.Codes = $true
        Set-Footer "已读取 $($codes.Count) 个激活码"
    } catch {
        Set-Footer $_.Exception.Message
        Show-Notice $_.Exception.Message '读取失败' 'Error'
    } finally {
        if ($showBusy) { Set-Busy $false }
    }
}

function Refresh-Pricing {
    Set-Busy $true '正在读取定价…'
    try {
        $script:Pricing = Invoke-Api 'GET' '/v1/pricing'
        $annual = Get-PricingProduct $script:Pricing 'annual'
        $lifetime = Get-PricingProduct $script:Pricing 'lifetime'
        if ($annual) {
            $ui.AnnualPrice.Text = ([decimal]$annual.price_fen / 100).ToString('0.##')
            $ui.AnnualOriginal.Text = ([decimal]$annual.original_fen / 100).ToString('0.##')
            $ui.AnnualState.Text = Format-PricingSummary $annual 'annual'
        }
        if ($lifetime) {
            $ui.LifetimePrice.Text = ([decimal]$lifetime.price_fen / 100).ToString('0.##')
            $ui.LifetimeOriginal.Text = ([decimal]$lifetime.original_fen / 100).ToString('0.##')
            $ui.LifetimeState.Text = Format-PricingSummary $lifetime 'lifetime'
        } else {
            $ui.LifetimeState.Text = '当前服务端未提供永久会员定价'
            $ui.SaveLifetime.IsEnabled = $false
        }
        $script:PageLoaded.Pricing = $true
        Set-Footer '定价已更新'
    } catch {
        Show-Notice $_.Exception.Message '读取定价失败' 'Error'
    } finally { Set-Busy $false }
}

function Save-Pricing([string]$product) {
    $priceBox = if ($product -eq 'annual') { $ui.AnnualPrice } else { $ui.LifetimePrice }
    $originalBox = if ($product -eq 'annual') { $ui.AnnualOriginal } else { $ui.LifetimeOriginal }
    $name = if ($product -eq 'annual') { '年费会员' } else { '永久会员' }
    $price = Convert-YuanToFen $priceBox.Text $false
    $original = Convert-YuanToFen $originalBox.Text $true
    if (-not $price.Ok -or $price.Fen -le 0) { Show-Notice '售价请输入 0.01 至 100000.00 元，最多两位小数。' '金额不正确' 'Warning'; return }
    if (-not $original.Ok) { Show-Notice '划线原价请输入 0 至 100000.00 元，最多两位小数。' '金额不正确' 'Warning'; return }
    if ($original.Fen -gt 0 -and $original.Fen -le $price.Fen) { Show-Notice '划线原价必须严格高于售价，或填写 0。' '金额不正确' 'Warning'; return }
    if ($product -eq 'lifetime' -and -not (Test-LifetimePricingProtocol $script:Pricing)) {
        Show-Notice '当前服务端不支持永久会员定价，已拒绝提交。' '无法修改' 'Error'; return
    }
    if (-not (Confirm-Action "确认将${name}售价改为 $($priceBox.Text) 元？`n改价会立即对新订单生效。" '确认改价')) { return }
    Set-Busy $true '正在保存定价…'
    try {
        [void](Invoke-Api 'POST' '/admin/pricing' @{ product=$product; price_fen=$price.Fen; original_fen=$original.Fen })
        Set-Footer "${name}定价已保存"
        Refresh-Pricing
    } catch { Show-Notice $_.Exception.Message '保存失败' 'Error' } finally { Set-Busy $false }
}

function Refresh-UpdateData {
    Set-Busy $true '正在读取版本信息…'
    try {
        $releaseResp = Invoke-Api 'GET' '/admin/update' $null $false
        if (-not $releaseResp.ok -and $releaseResp.err -ne 'NO_VERSION_INFO') { throw (Get-ApiErrorText $releaseResp) }
        $script:Release = if ($releaseResp.ok) { $releaseResp.release } else { $null }
        if ($script:Release) {
            $mode = if ([int]$script:Release.minSupportedVersionCode -ge [int]$script:Release.versionCode) { '硬更新' } else { '软更新' }
            $ui.ReleaseTitle.Text = "$($script:Release.versionName)  ·  versionCode $($script:Release.versionCode)"
            $size = ([double]$script:Release.sizeBytes / 1MB).ToString('0.00')
            $ui.ReleaseDetails.Text = "$mode  ·  ${size} MiB  ·  发布于 $(Format-GuiTime $script:Release.publishedAt)`n$($script:Release.url)"
        } else {
            $ui.ReleaseTitle.Text = '尚未发布版本'
            $ui.ReleaseDetails.Text = '—'
        }
        $stats = Invoke-Api 'GET' '/admin/update/stats'
        $script:StatsRows = @($stats.rows)
        Apply-StatsFilter
        Update-OssState
        $script:PageLoaded.Updates = $true
        Set-Footer '版本信息已更新'
    } catch {
        Show-Notice $_.Exception.Message '读取版本信息失败' 'Error'
    } finally { Set-Busy $false }
}

function Apply-StatsFilter {
    $rows = @($script:StatsRows)
    $scope = $ui.StatsScope.SelectedItem
    if ($scope -and [string]$scope.Tag -eq 'recent') {
        $targets = @($rows | ForEach-Object { [int]$_.targetVersionCode } | Sort-Object -Descending -Unique | Select-Object -First 3)
        $rows = @($rows | Where-Object { $targets -contains [int]$_.targetVersionCode })
    }
    $display = foreach ($row in $rows) {
        [PSCustomObject]@{
            Target = if ($row.targetVersionName) { "$($row.targetVersionName) ($($row.targetVersionCode))" } else { "versionCode $($row.targetVersionCode)" }
            Source = if ($row.sourceVersionName) { "$($row.sourceVersionName) ($($row.sourceVersionCode))" } else { "versionCode $($row.sourceVersionCode)" }
            Checks = [long]$row.checkCount
            Installs = [long]$row.installTriggerCount
            LastCheck = Format-GuiTime $row.lastCheckAt
        }
    }
    $ui.StatsGrid.ItemsSource = @($display)
}

function Update-OssState {
    $tool = Get-OssUtilPath
    $credentials = Get-OssCredentials
    $state = if (-not $tool) { '未找到 ossutil，请检查项目工具包' } elseif (-not $credentials) { '尚未配置上传凭证' } else { '工具与加密凭证已就绪' }
    $ui.OssState.Text = $state
    $ui.SettingsOssState.Text = $state
}

function Update-SettingsState {
    try { $ui.SidebarServer.Text = ([uri]$Server).Host } catch { $ui.SidebarServer.Text = $Server }
    $ui.SettingsServer.Text = $Server
    $tokenSource = if ($env:ZT_ADMIN_TOKEN) { '环境变量 ZT_ADMIN_TOKEN' } elseif (Test-Path -LiteralPath $TokenFile) { '本机 admin-token.txt' } else { '尚未配置' }
    $ui.TokenState.Text = $tokenSource
    $ui.SetToken.Content = if ($script:Token) { '更换令牌' } else { '设置令牌' }
    Update-OssState
    $script:PageLoaded.Settings = $true
}

function Test-GuiServer([bool]$showSuccess = $true) {
    Set-Busy $true '正在检测服务器…'
    try {
        [void](Invoke-Api 'GET' '/healthz')
        $ui.ServerDot.Fill = New-Brush '#12B76A'
        $ui.ServerStatus.Text = '服务器正常'
        if ($showSuccess) { Show-Notice "服务器连接正常。`n$Server" '检测完成' }
        Set-Footer '服务器连接正常'
        return $true
    } catch {
        $ui.ServerDot.Fill = New-Brush '#F04438'
        $ui.ServerStatus.Text = '连接异常'
        if ($showSuccess) { Show-Notice $_.Exception.Message '服务器连接失败' 'Error' }
        Set-Footer $_.Exception.Message
        return $false
    } finally { Set-Busy $false }
}

function Show-Page([string]$page) {
    $pages = @('Overview','Codes','Pricing','Updates','Settings')
    foreach ($name in $pages) { $ui["Page$name"].Visibility = if ($name -eq $page) { 'Visible' } else { 'Collapsed' } }
    $script:CurrentPage = $page
    $meta = switch ($page) {
        'Overview' { @('总览','授权与版本状态一目了然') }
        'Codes' { @('激活码','查找、生成并管理设备授权') }
        'Pricing' { @('定价','管理年费与永久会员价格') }
        'Updates' { @('版本更新','测试、发布并跟踪 App 更新') }
        'Settings' { @('设置','服务器、令牌与上传凭证') }
    }
    $ui.PageTitle.Text = $meta[0]
    $ui.PageSubtitle.Text = $meta[1]
    if (-not $script:PageLoaded[$page]) {
        switch ($page) {
            { $_ -in @('Overview','Codes') } { Refresh-Ledger; break }
            'Pricing' { Refresh-Pricing; break }
            'Updates' { Refresh-UpdateData; break }
            'Settings' { Update-SettingsState; break }
        }
    }
}

function Refresh-CurrentPage {
    if ($script:IsBusy) { return }
    switch ($script:CurrentPage) {
        { $_ -in @('Overview','Codes') } { Refresh-Ledger; break }
        'Pricing' { Refresh-Pricing; break }
        'Updates' { Refresh-UpdateData; break }
        'Settings' { Update-SettingsState; [void](Test-GuiServer $false); break }
    }
}

function Invoke-NewCodeDialog {
    $result = Show-InputDialog '生成激活码' '手动生成的激活码默认永久有效；年费码可填写 365 天。' @(
        [PSCustomObject]@{ Name='Count'; Label='生成数量'; Value='1' },
        [PSCustomObject]@{ Name='Days'; Label='有效期天数（0 = 永久）'; Value='0' },
        [PSCustomObject]@{ Name='Note'; Label='备注（可留空）'; Value='' }
    ) '生成并复制'
    if (-not $result) { return }
    if ([string]$result.Count -notmatch '^\d+$' -or [int]$result.Count -lt 1 -or [int]$result.Count -gt 100) { Show-Notice '生成数量必须是 1 至 100 的整数。' '输入不正确' 'Warning'; return }
    if ([string]$result.Days -notmatch '^\d+$' -or [int]$result.Days -gt 36500) { Show-Notice '有效期必须是 0 至 36500 的整数，永久码填写 0。' '输入不正确' 'Warning'; return }
    Set-Busy $true '正在生成激活码…'
    try {
        $resp = Invoke-Api 'POST' '/admin/codes' @{ count=[int]$result.Count; days=[int]$result.Days; note=[string]$result.Note }
        $codes = @($resp.codes)
        try { [Windows.Clipboard]::SetText(($codes -join "`r`n")) } catch {}
        Show-Notice ("已生成 {0} 个激活码，并复制到剪贴板：`n`n{1}" -f $codes.Count, ($codes -join "`n")) '生成成功'
        Refresh-Ledger $false
    } catch { Show-Notice $_.Exception.Message '生成失败' 'Error' } finally { Set-Busy $false }
}

function Show-PaidUnboundDetails {
    $orders = @($script:Ledger.paid_unbound)
    if ($orders.Count -eq 0) { Show-Notice '当前没有付款后未绑定的订单。'; return }
    $lines = foreach ($order in $orders) {
        $amount = Format-PriceFen $order.amount_fen
        $fp = if ($order.device_fp) { [string]$order.device_fp } else { '—' }
        "订单：$($order.out_trade_no)`n激活码：$($order.code)  ·  商品：$($order.product)  ·  金额：$amount`n付款：$(Format-GuiTime $order.paid_at)`n设备：$fp"
    }
    Show-Notice ($lines -join "`n`n") "付款未绑定（$($orders.Count) 笔）" 'Warning'
}

function Get-SelectedCodeRow {
    $row = $ui.CodesGrid.SelectedItem
    if (-not $row) { Show-Notice '请先选择一个激活码。' '尚未选择' 'Warning'; return $null }
    return $row
}

function Invoke-UnbindSelected {
    $row = Get-SelectedCodeRow
    if (-not $row) { return }
    $bindings = @($row.Raw.bindings)
    if ($bindings.Count -eq 0) { Show-Notice '该激活码当前没有绑定设备。'; return }
    $binding = $bindings[0]
    if ($bindings.Count -gt 1) {
        $choices = @($bindings | ForEach-Object { "$(if ($_.model) { $_.model } else { '未知设备' }) · $($_.fp)" })
        $pick = Show-InputDialog '选择解绑设备' '该激活码存在多条绑定记录，请选择要解绑的设备。' @(
            [PSCustomObject]@{ Name='Index'; Label='设备'; Choices=$choices; SelectedIndex=0 }
        ) '继续'
        if (-not $pick) { return }
        $binding = $bindings[[int]$pick.Index]
    }
    if (-not (Confirm-Action "确认解绑 $($binding.model)？`n用户随后可以在新设备上重新激活。" '解绑设备')) { return }
    Set-Busy $true '正在解绑设备…'
    try {
        [void](Invoke-Api 'POST' '/admin/unbind' @{ code=$row.Code; fp=$binding.fp })
        Refresh-Ledger $false
        Show-Notice '设备已解绑。' '操作完成'
    } catch { Show-Notice $_.Exception.Message '解绑失败' 'Error' } finally { Set-Busy $false }
}

function Invoke-RevokeSelected {
    $row = Get-SelectedCodeRow
    if (-not $row) { return }
    $result = Show-InputDialog '吊销激活码' "吊销 $($row.Code) 后，其设备将降级为免费版。" @(
        [PSCustomObject]@{ Name='Reason'; Label='吊销原因'; Value='退款' }
    ) '下一步'
    if (-not $result) { return }
    if (-not (Confirm-Action "确认吊销 $($row.Code)？`n此操作会影响用户授权。" '最后确认')) { return }
    Set-Busy $true '正在吊销…'
    try {
        [void](Invoke-Api 'POST' '/admin/revoke' @{ code=$row.Code; reason=[string]$result.Reason })
        Refresh-Ledger $false
        Show-Notice '激活码已吊销。' '操作完成'
    } catch { Show-Notice $_.Exception.Message '吊销失败' 'Error' } finally { Set-Busy $false }
}

function Invoke-UnrevokeSelected {
    $row = Get-SelectedCodeRow
    if (-not $row) { return }
    $message = "解除吊销会同时清空 $($row.Code) 近 30 天的激活记录。`n请确认这是误伤；用户之后需要在 App 中重新输入激活码。"
    if (-not (Confirm-Action $message '解除吊销')) { return }
    Set-Busy $true '正在解除吊销…'
    try {
        $resp = Invoke-Api 'POST' '/admin/unrevoke' @{ code=$row.Code }
        Refresh-Ledger $false
        Show-Notice "已解除吊销，并清空 $($resp.cleared_activations) 条激活记录。" '操作完成'
    } catch { Show-Notice $_.Exception.Message '操作失败' 'Error' } finally { Set-Busy $false }
}

function Invoke-ExpirySelected {
    $row = Get-SelectedCodeRow
    if (-not $row) { return }
    $result = Show-InputDialog '修改有效期' "当前：$($row.ExpiryText)`n延期会在现有到期日基础上增加，不会吃掉剩余时间。" @(
        [PSCustomObject]@{ Name='Mode'; Label='操作'; Choices=@('设为永久','延长天数'); SelectedIndex=0 },
        [PSCustomObject]@{ Name='Days'; Label='延长天数（选择“设为永久”时忽略）'; Value='90' }
    ) '确认修改'
    if (-not $result) { return }
    $days = 0
    if ([int]$result.Mode -eq 1) {
        if ([string]$result.Days -notmatch '^\d+$' -or [int]$result.Days -le 0 -or [int]$result.Days -gt 36500) { Show-Notice '延长天数必须是 1 至 36500 的整数。' '输入不正确' 'Warning'; return }
        $days = [int]$result.Days
    }
    Set-Busy $true '正在修改有效期…'
    try {
        [void](Invoke-Api 'POST' '/admin/expiry' @{ code=$row.Code; days=$days })
        Refresh-Ledger $false
        Show-Notice $(if ($days -eq 0) { '已设为永久有效。' } else { "已延长 $days 天。" }) '操作完成'
    } catch { Show-Notice $_.Exception.Message '修改失败' 'Error' } finally { Set-Busy $false }
}

function Select-GuiApk([string]$title) {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = $title
    $dialog.Filter = 'Android 安装包 (*.apk)|*.apk'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($window) -eq $true) { return $dialog.FileName }
    return $null
}

function Ensure-OssReady {
    if (-not (Get-OssUtilPath)) { Show-Notice '项目内未找到 ossutil.exe，请重新下载项目工具包。' 'OSS 不可用' 'Error'; return $false }
    if (-not (Get-OssCredentials)) { Show-Notice '请先配置 OSS 上传凭证。' '尚未配置' 'Warning'; return $false }
    return $true
}

function Configure-GuiOss {
    $result = Show-InputDialog '配置 OSS' '只需输入 AccessKey。Secret 会由 Windows 当前账号加密保存，不会写入项目。' @(
        [PSCustomObject]@{ Name='Id'; Label='AccessKey ID'; Value=''; Secret=$false },
        [PSCustomObject]@{ Name='Secret'; Label='AccessKey Secret'; Value=''; Secret=$true }
    ) '保存并测试'
    if (-not $result) { return }
    $id = ([string]$result.Id).Trim()
    $secret = ([string]$result.Secret).Trim()
    if (-not $id -or -not $secret) { Show-Notice 'AccessKey ID 和 Secret 都不能为空。' '输入不完整' 'Warning'; return }
    Set-Busy $true '正在测试 OSS 凭证…'
    $previousCredential = if (Test-Path -LiteralPath $OssCredentialFile -PathType Leaf) { [IO.File]::ReadAllBytes($OssCredentialFile) } else { $null }
    $credentialSaved = $false
    try {
        $secure = ConvertTo-SecureString $secret -AsPlainText -Force
        New-Item -ItemType Directory -Path $OssCredentialDir -Force | Out-Null
        $saved = @{ version=1; accessKeyId=$id; encryptedAccessKeySecret=(ConvertFrom-SecureString $secure) } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($OssCredentialFile, $saved, (New-Object Text.UTF8Encoding($false)))
        $ossutil = Get-OssUtilPath
        if (-not $ossutil) { throw '未找到 ossutil.exe。' }
        $args = @('ls', "oss://$OssBucket/releases/", '--limited-num', '1', '--region', $OssRegion, '--endpoint', $OssEndpoint)
        if ((Invoke-OssUtilAuthenticated $ossutil $args) -ne 0) { throw 'OSS 测试失败，请检查密钥配对和 RAM 权限。' }
        $credentialSaved = $true
        Update-OssState
        Show-Notice 'OSS 配置有效。' '测试通过'
    } catch {
        if (-not $credentialSaved) {
            if ($null -ne $previousCredential) { [IO.File]::WriteAllBytes($OssCredentialFile, $previousCredential) }
            else { Remove-Item -LiteralPath $OssCredentialFile -Force -ErrorAction SilentlyContinue }
            Update-OssState
        }
        Show-Notice $_.Exception.Message 'OSS 配置失败' 'Error'
    } finally { Set-Busy $false }
}

function Invoke-GuiStage {
    if (-not (Ensure-OssReady)) { return }
    $apk = Select-GuiApk '选择仅上传测试、不正式发布的 ZTransfer APK'
    if (-not $apk) { return }
    $backgroundStarted = $false
    Set-Busy $true '正在验证 APK…'
    try {
        $meta = Read-LocalApkMetadata $apk
        if (-not $meta) { throw 'APK 校验未通过。请确认它是正式签名包，且 Android SDK Build Tools 可用。' }
        $summary = "版本 $($meta.VersionName)（versionCode $($meta.VersionCode)）`n大小 $(([double]$meta.SizeBytes/1MB).ToString('0.00')) MiB`n`n仅上传版本化测试地址，不会覆盖 ZTransfer.apk，也不会改变 App 当前版本。"
        Set-Busy $false
        if (-not (Confirm-Action $summary '确认上传测试包')) { return }
        Start-CoreWorker 'stage' @{ ApkPath=$apk; Meta=$meta } '正在上传并校验测试包…' {
            param($result)
            try { [Windows.Clipboard]::SetText([string]$result.Url) } catch {}
            Show-Notice "测试包已上传并校验通过，地址已复制：`n$($result.Url)" '上传完成'
            Set-Footer '测试包上传完成，当前发布未改变'
        }
        $backgroundStarted = $true
    } catch { Show-Notice $_.Exception.Message '上传失败' 'Error' } finally { if (-not $backgroundStarted) { Set-Busy $false } }
}

function Invoke-GuiPublish {
    if (-not (Ensure-OssReady)) { return }
    $backgroundStarted = $false
    Set-Busy $true '正在核对服务端发布能力…'
    try {
        $publishState = Get-UpdatePublishState
        if (-not $publishState) { throw '服务端发布能力校验未通过。' }
        $initialRelease = $publishState.Current
        Set-Busy $false
        $apk = Select-GuiApk '选择要正式发布的 ZTransfer APK'
        if (-not $apk) { return }
        Set-Busy $true '正在验证 APK…'
        $meta = Read-LocalApkMetadata $apk
        if (-not $meta) { throw 'APK 校验未通过。请确认它是正式签名包，且 Android SDK Build Tools 可用。' }
        if ($initialRelease -and [int]$meta.VersionCode -le [int]$initialRelease.versionCode) {
            throw "APK versionCode $($meta.VersionCode) 必须高于当前发布的 $($initialRelease.versionCode)。"
        }
        Set-Busy $false
        $form = Show-InputDialog '发布新版本' "已验证 $($meta.VersionName)（versionCode $($meta.VersionCode)），$(([double]$meta.SizeBytes/1MB).ToString('0.00')) MiB。" @(
            [PSCustomObject]@{ Name='Policy'; Label='更新策略'; Choices=@('软更新（推荐）','硬更新（旧版本必须安装）'); SelectedIndex=0 },
            [PSCustomObject]@{ Name='Notes'; Label='更新说明（可留空）'; Value=''; Multiline=$true }
        ) '下一步'
        if (-not $form) { return }
        $hardUpdate = [int]$form.Policy -eq 1
        $policyText = if ($hardUpdate) { '硬更新' } else { '软更新' }
        $confirm = "即将正式发布 $($meta.VersionName)（versionCode $($meta.VersionCode)）。`n策略：$policyText`n`n将更新固定下载地址和服务端当前版本，是否继续？"
        if (-not (Confirm-Action $confirm '正式发布确认')) { return }

        $initialCode = if ($initialRelease) { [int]$initialRelease.versionCode } else { 0 }
        $minSupported = if ($hardUpdate) { [int]$meta.VersionCode } else { 1 }
        Start-CoreWorker 'publish' @{
            ApkPath=$apk; Meta=$meta; InitialVersionCode=$initialCode
            MinSupportedVersionCode=$minSupported; Notes=[string]$form.Notes
        } '正在上传、校验并发布新版本…' {
            param($result)
            Show-Notice "版本 $($result.VersionName) 已正式发布。" '发布成功'
            Refresh-UpdateData
        }
        $backgroundStarted = $true
    } catch {
        Show-Notice $_.Exception.Message '发布未完成' 'Error'
    } finally { if (-not $backgroundStarted) { Set-Busy $false } }
}

function Invoke-GuiValidateUpdate {
    if (-not $script:Release) { Show-Notice '当前没有可验证的发布版本。' '无法验证' 'Warning'; return }
    $expectedPrefix = "$OssPublicBaseUrl/releases/"
    if (-not ([string]$script:Release.url).StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Show-Notice '当前发布仍是旧下载源；下一次发布会自动切换到香港 OSS。' '旧下载源' 'Warning'; return
    }
    if (-not (Confirm-Action '将完整下载当前版本地址和固定下载地址，并核对大小、SHA-256、包名及版本。是否继续？' '验证下载')) { return }
    try {
        $expected = @{ SizeBytes=[long]$script:Release.sizeBytes; Sha256=[string]$script:Release.sha256; VersionCode=[int]$script:Release.versionCode; VersionName=[string]$script:Release.versionName }
        $latestUrl = "$OssPublicBaseUrl/$OssLatestObjectKey"
        Start-CoreWorker 'validate' @{ ReleaseUrl=[string]$script:Release.url; LatestUrl=$latestUrl; Expected=$expected } '正在完整下载并校验…' {
            param($result)
            Show-Notice '当前版本地址和新用户固定下载地址均有效。' '验证通过'
            Set-Footer '版本下载校验通过'
        }
    } catch { Show-Notice $_.Exception.Message '验证失败' 'Error' }
}

function Invoke-GuiPolicy {
    if (-not $script:Release) { Show-Notice '当前没有已发布版本。' '无法修改' 'Warning'; return }
    $currentHard = [int]$script:Release.minSupportedVersionCode -ge [int]$script:Release.versionCode
    $result = Show-InputDialog '更新策略' '软更新允许稍后或忽略；硬更新会要求所有旧版本升级后才能继续。' @(
        [PSCustomObject]@{ Name='Policy'; Label='策略'; Choices=@('软更新','硬更新'); SelectedIndex=$(if ($currentHard) { 1 } else { 0 }) }
    ) '应用策略'
    if (-not $result) { return }
    $hard = [int]$result.Policy -eq 1
    if ($hard -and -not (Confirm-Action '硬更新会阻止旧版本继续使用，确认启用？' '启用硬更新')) { return }
    Set-Busy $true '正在修改更新策略…'
    try {
        $min = if ($hard) { [int]$script:Release.versionCode } else { 1 }
        [void](Invoke-Api 'POST' '/admin/update/policy' @{ minSupportedVersionCode=$min })
        Refresh-UpdateData
        Show-Notice '更新策略已修改并立即生效。' '操作完成'
    } catch { Show-Notice $_.Exception.Message '修改失败' 'Error' } finally { Set-Busy $false }
}

function Change-GuiToken {
    if ($env:ZT_ADMIN_TOKEN) {
        Show-Notice '当前令牌由环境变量 ZT_ADMIN_TOKEN 提供。请先修改或移除该环境变量，再重新打开管理器。' '环境变量优先' 'Warning'
        return
    }
    $result = Show-InputDialog '更换管理员令牌' '新令牌会写入 admin-token.txt，内容不会在界面中回显。' @(
        [PSCustomObject]@{ Name='Token'; Label='新 adminToken'; Value=''; Secret=$true }
    ) '保存'
    if (-not $result) { return }
    $token = ([string]$result.Token).Trim()
    if (-not $token) { Show-Notice '令牌不能为空。' '无法保存' 'Warning'; return }
    [IO.File]::WriteAllText($TokenFile, $token, (New-Object Text.UTF8Encoding($false)))
    $script:Token = $token
    Update-SettingsState
    Show-Notice '管理员令牌已更新。' '保存成功'
}

# 导航与通用操作
$ui.NavOverview.Add_Checked({ Show-Page 'Overview' })
$ui.NavCodes.Add_Checked({ Show-Page 'Codes' })
$ui.NavPricing.Add_Checked({ Show-Page 'Pricing' })
$ui.NavUpdates.Add_Checked({ Show-Page 'Updates' })
$ui.NavSettings.Add_Checked({ Show-Page 'Settings' })
$ui.RefreshButton.Add_Click({ Refresh-CurrentPage })
$ui.QuickNewCode.Add_Click({ Invoke-NewCodeDialog })
$ui.QuickPublish.Add_Click({ $ui.NavUpdates.IsChecked = $true; Invoke-GuiPublish })
$ui.QuickTest.Add_Click({ [void](Test-GuiServer $true) })
$ui.PaidAlertButton.Add_Click({ Show-PaidUnboundDetails })

# 激活码页
$ui.CodeSearch.Add_TextChanged({ Apply-CodeFilter })
$ui.CodeStatusFilter.Add_SelectionChanged({ Apply-CodeFilter })
$ui.CodesGrid.Add_SelectionChanged({ Update-CodeDetail })
$ui.CodesGrid.Add_MouseDoubleClick({
    $row = $ui.CodesGrid.SelectedItem
    if ($row) { try { [Windows.Clipboard]::SetText([string]$row.Code); Set-Footer "已复制激活码 $($row.Code)" } catch {} }
})
$ui.NewCodeButton.Add_Click({ Invoke-NewCodeDialog })
$ui.UnbindButton.Add_Click({ Invoke-UnbindSelected })
$ui.RevokeButton.Add_Click({ Invoke-RevokeSelected })
$ui.UnrevokeButton.Add_Click({ Invoke-UnrevokeSelected })
$ui.ExpiryButton.Add_Click({ Invoke-ExpirySelected })

# 定价页
$ui.SaveAnnual.Add_Click({ Save-Pricing 'annual' })
$ui.SaveLifetime.Add_Click({ Save-Pricing 'lifetime' })

# 版本更新页
$ui.StatsScope.Add_SelectionChanged({ Apply-StatsFilter })
$ui.ValidateUpdate.Add_Click({ Invoke-GuiValidateUpdate })
$ui.ChangePolicy.Add_Click({ Invoke-GuiPolicy })
$ui.StageApk.Add_Click({ Invoke-GuiStage })
$ui.PublishApk.Add_Click({ Invoke-GuiPublish })
$ui.ConfigureOss.Add_Click({ Configure-GuiOss })

# 设置页
$ui.SetToken.Add_Click({ Change-GuiToken })
$ui.TestServerButton.Add_Click({ [void](Test-GuiServer $true) })
$ui.SettingsConfigureOss.Add_Click({ Configure-GuiOss })

$window.Add_ContentRendered({
    Update-SettingsState
    if (-not $script:Token) {
        if (-not (Request-GuiToken)) {
            $ui.NavSettings.IsChecked = $true
            Set-Footer '尚未设置管理员令牌'
            return
        }
    }
    Show-Page 'Overview'
    [void](Test-GuiServer $false)
})
$window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:ActiveWorker) {
        $eventArgs.Cancel = $true
        Show-Notice '上传、发布或校验仍在进行，请等待完成后再关闭管理器。' '操作进行中' 'Warning'
    }
})

if ($ValidateOnly) {
    $missing = @($controlNames | Where-Object { $null -eq $ui[$_] })
    if ($missing.Count -gt 0) { throw "XAML 缺少控件: $($missing -join ', ')" }
    $sampleLedger = [PSCustomObject]@{
        codes = @(
            [PSCustomObject]@{ code='ABC123'; status='active'; note='测试'; expires_at=$null; created_at='2026-01-01T00:00:00Z'; bindings=@() },
            [PSCustomObject]@{ code='XYZ789'; status='revoked'; note=''; expires_at='2025-01-01T00:00:00Z'; created_at='2026-01-01T00:00:00Z'; bindings=@() }
        )
    }
    $sampleRows = Convert-LedgerRows $sampleLedger
    if ($sampleRows.Count -ne 2 -or $sampleRows[0].ExpiryText -ne '永久' -or $sampleRows[1].StatusText -ne '已吊销') {
        throw '激活码视图模型自检失败'
    }
    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $powerShell = [Management.Automation.PowerShell]::Create()
    try {
        $powerShell.Runspace = $runspace
        [void]$powerShell.AddScript(@'
param($corePath)
. $corePath -LibraryMode
$meta = @{ VersionCode=48; VersionName='1.75'; Sha256=('a' * 64) }
(New-OssReleaseTarget $meta).PublicUrl
'@).AddArgument($legacyScript)
        $workerResult = @($powerShell.Invoke()) | Select-Object -Last 1
        if ($powerShell.HadErrors -or -not ([string]$workerResult).EndsWith('/releases/ZTransfer-v1.75-aaaaaaaaaaaa.apk')) {
            throw '后台运行空间自检失败'
        }
    } finally {
        $powerShell.Dispose()
        $runspace.Dispose()
    }
    $window.Close()
    Write-Output 'GUI validation passed'
    return
}

[void]$window.ShowDialog()
