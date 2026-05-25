param(
    [string]$VSCodeRoot = "D:\VSCode-win32-x64-1.121.0",
    [string]$WorkspacePath = "D:\DeerFlow"
)

$ErrorActionPreference = "Stop"

$codeCmd = Join-Path $VSCodeRoot "bin\code.cmd"
$codeExe = Join-Path $VSCodeRoot "Code.exe"
$extensionPath = Join-Path $WorkspacePath "integrations\vscode-copilot-bridge"

if (-not (Test-Path $extensionPath)) {
    throw "Bridge extension path not found: $extensionPath"
}

if (Test-Path $codeCmd) {
    & $codeCmd --new-window --extensionDevelopmentPath $extensionPath $WorkspacePath
    exit $LASTEXITCODE
}

if (Test-Path $codeExe) {
    & $codeExe --new-window --extensionDevelopmentPath $extensionPath $WorkspacePath
    exit $LASTEXITCODE
}

throw "VS Code executable not found under $VSCodeRoot"