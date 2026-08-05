param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputPath = "",
    [string]$SoftwareName = ""
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$sourceRoot = Join-Path $repo "app\src\main\java"
$gradleFile = Join-Path $repo "app\build.gradle.kts"
$softCopyrightDirectoryName = -join ([char[]](0x8F6F, 0x8457))
$sourceMaterialBaseName = -join ([char[]](0x6E90, 0x7A0B, 0x5E8F, 0x6750, 0x6599))
$sourceProgramLabel = -join ([char[]](0x6E90, 0x7A0B, 0x5E8F))
if ([string]::IsNullOrWhiteSpace($SoftwareName)) {
    $SoftwareName = -join ([char[]](0x005A, 0x4F20, 0x76F8, 0x673A, 0x7167, 0x7247, 0x4F20, 0x8F93, 0x8F6F, 0x4EF6))
}

if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Production source directory not found: $sourceRoot"
}
if (-not (Test-Path -LiteralPath $gradleFile -PathType Leaf)) {
    throw "Gradle file not found: $gradleFile"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Join-Path (Join-Path $repo "docs") $softCopyrightDirectoryName) ($sourceMaterialBaseName + ".html")
} elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $repo $OutputPath
}

$gradle = Get-Content -Raw -Encoding UTF8 -LiteralPath $gradleFile
$versionMatch = [regex]::Match($gradle, 'versionName\s*=\s*"([^"]+)"')
if (-not $versionMatch.Success) {
    throw "Unable to determine versionName from $gradleFile"
}
$version = $versionMatch.Groups[1].Value

$sourceFiles = Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter "*.kt" |
    Sort-Object { $_.FullName.Substring($sourceRoot.Length).Replace('\', '/') }

if ($sourceFiles.Count -eq 0) {
    throw "No Kotlin production sources found below $sourceRoot"
}

$allLines = [System.Collections.Generic.List[string]]::new()
foreach ($file in $sourceFiles) {
    $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\').Replace('\', '/')
    $allLines.Add("// ============ File: $relative ============")
    foreach ($line in (Get-Content -Encoding UTF8 -LiteralPath $file.FullName)) {
        # Keep comments and indentation. Remove only blank lines so every page
        # contains exactly 50 non-empty program lines.
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $allLines.Add($line.TrimEnd())
        }
    }
}

$linesPerPage = 50
$pagesPerSection = 30
$sectionLines = $linesPerPage * $pagesPerSection
$requiredLines = $sectionLines * 2
if ($allLines.Count -lt $requiredLines) {
    throw "Only $($allLines.Count) non-empty source lines found; fewer than the required $requiredLines lines."
}

# File boundary markers are part of the submitted display stream, but they are
# generated labels rather than lines from the production source files.
$productionLineCount = $allLines.Count - $sourceFiles.Count

$submittedLines = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $sectionLines; $i++) {
    $submittedLines.Add($allLines[$i])
}
for ($i = $allLines.Count - $sectionLines; $i -lt $allLines.Count; $i++) {
    $submittedLines.Add($allLines[$i])
}

$builder = [System.Text.StringBuilder]::new()
[void]$builder.AppendLine('<!DOCTYPE html>')
[void]$builder.AppendLine('<html lang="zh-CN">')
[void]$builder.AppendLine('<head>')
[void]$builder.AppendLine('  <meta charset="utf-8" />')
[void]$builder.AppendLine("  <title>$SoftwareName V$version $sourceProgramLabel</title>")
[void]$builder.AppendLine('  <style>')
[void]$builder.AppendLine('    @page { size: A4 portrait; margin: 15mm 12mm; }')
[void]$builder.AppendLine('    * { box-sizing: border-box; }')
[void]$builder.AppendLine('    html, body { margin: 0; padding: 0; background: #fff; color: #000; }')
[void]$builder.AppendLine('    body { font-family: Consolas, "Courier New", monospace; }')
[void]$builder.AppendLine('    .page { page-break-after: always; break-after: page; break-inside: avoid; }')
[void]$builder.AppendLine('    .page:last-child { page-break-after: auto; break-after: auto; }')
[void]$builder.AppendLine('    .hdr { display: flex; justify-content: space-between; font-family: SimSun, serif; font-size: 10.5pt; border-bottom: 1px solid #000; padding-bottom: 2px; margin-bottom: 6px; }')
[void]$builder.AppendLine('    pre { margin: 0; font-size: 9pt; line-height: 1.35; white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-all; tab-size: 4; }')
[void]$builder.AppendLine('    @media screen { body { background: #ddd; } .page { width: 210mm; min-height: 297mm; margin: 8mm auto; padding: 15mm 12mm; background: #fff; box-shadow: 0 1mm 4mm #888; } }')
[void]$builder.AppendLine('    @media print { .page { margin: 0; padding: 0; } }')
[void]$builder.AppendLine('  </style>')
[void]$builder.AppendLine('</head>')
[void]$builder.AppendLine('<body>')
[void]$builder.AppendLine("<!-- Generated from app/src/main/java: $($sourceFiles.Count) Kotlin files, $productionLineCount production non-empty lines, $($allLines.Count) display-stream lines including file markers. -->")

$pageCount = $submittedLines.Count / $linesPerPage
for ($pageIndex = 0; $pageIndex -lt $pageCount; $pageIndex++) {
    $pageNumber = $pageIndex + 1
    $start = $pageIndex * $linesPerPage
    $encodedLines = for ($lineIndex = 0; $lineIndex -lt $linesPerPage; $lineIndex++) {
        [System.Net.WebUtility]::HtmlEncode($submittedLines[$start + $lineIndex])
    }
    [void]$builder.AppendLine('  <section class="page">')
    $pageLabel = -join ([char[]](0x7B2C)) + " $pageNumber " + (-join ([char[]](0x9875))) + " / " + (-join ([char[]](0x5171))) + " $pageCount " + (-join ([char[]](0x9875)))
    [void]$builder.AppendLine(('    <div class="hdr"><span>{0} V{1} {2}</span><span>{3}</span></div>' -f $SoftwareName, $version, $sourceProgramLabel, $pageLabel))
    [void]$builder.AppendLine('    <pre>')
    [void]$builder.AppendLine(($encodedLines -join "`n"))
    [void]$builder.AppendLine('    </pre>')
    [void]$builder.AppendLine('  </section>')
}

[void]$builder.AppendLine('</body>')
[void]$builder.AppendLine('</html>')

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}
[System.IO.File]::WriteAllText($OutputPath, $builder.ToString(), [System.Text.UTF8Encoding]::new($false))

Write-Output "Generated: $OutputPath"
Write-Output "Version: V$version"
Write-Output "Production Kotlin files: $($sourceFiles.Count)"
Write-Output "Production non-empty source lines: $productionLineCount"
Write-Output "Display stream lines (including file markers): $($allLines.Count)"
Write-Output "Submitted pages: $pageCount ($linesPerPage non-empty lines per page)"
