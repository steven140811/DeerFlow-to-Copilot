param(
    [switch]$Reset
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$TargetScript = Join-Path $RepoRoot "skills\public\vscode-to-deerflow\scripts\configure.ps1"

if (-not (Test-Path -LiteralPath $TargetScript)) {
    throw "Configure script not found: $TargetScript"
}

$arguments = @("-ExecutionPolicy", "Bypass", "-File", $TargetScript)
if ($Reset) {
    $arguments += "-Reset"
}

& ((Get-Process -Id $PID).Path) @arguments
exit $LASTEXITCODE