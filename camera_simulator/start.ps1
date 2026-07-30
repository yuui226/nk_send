param(
    [string]$BindAddress = "0.0.0.0",
    [int]$Port = 15740,
    [switch]$Quiet
)

$arguments = @(
    (Join-Path $PSScriptRoot "simulator.py"),
    "--bind", $BindAddress,
    "--port", $Port
)
if ($Quiet) {
    $arguments += "--quiet"
}

python @arguments
