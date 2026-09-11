# Lossless format conversion of the repository-owned, fully opaque brand PNG.
# No visual redesign, resizing or Android resource changes.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$taskRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$taskSource = Join-Path $taskRoot 'docs\品牌素材\ztransfer_icon_1024.png'
$taskTarget = Join-Path $taskRoot 'iosApp\ZTransfer\Configuration\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$taskInput = [System.Drawing.Bitmap]::new($taskSource)
try {
    if ($taskInput.Width -ne 1024 -or $taskInput.Height -ne 1024) { throw 'Expected 1024px brand icon' }
    for ($taskY = 0; $taskY -lt 1024; $taskY++) {
        for ($taskX = 0; $taskX -lt 1024; $taskX++) {
            if ($taskInput.GetPixel($taskX, $taskY).A -ne 255) { throw 'Brand icon has transparency; manual design review required' }
        }
    }
    $taskOutput = [System.Drawing.Bitmap]::new(1024, 1024, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $taskGraphics = [System.Drawing.Graphics]::FromImage($taskOutput)
        try { $taskGraphics.DrawImageUnscaled($taskInput, 0, 0) } finally { $taskGraphics.Dispose() }
        $taskOutput.Save($taskTarget, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $taskOutput.Dispose() }
} finally { $taskInput.Dispose() }
Write-Output 'Prepared opaque RGB AppIcon from existing brand pixels.'
