[CmdletBinding()]
param(
    [string]$WorkspacePath = $(Split-Path $PSScriptRoot -Parent),
    [string]$ExtensionsRoot = $(Join-Path $HOME ".vscode\extensions"),
    [switch]$SkipSettingsUpdate
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Text)
    Write-Host "[step] $Text" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[ok] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[warn] $Text" -ForegroundColor Yellow
}

$SourceDir = Join-Path $WorkspacePath "integrations\vscode-copilot-bridge"
if (-not (Test-Path -LiteralPath $SourceDir)) {
    throw "Bridge extension source was not found: $SourceDir"
}

$PackageJsonPath = Join-Path $SourceDir "package.json"
if (-not (Test-Path -LiteralPath $PackageJsonPath)) {
    throw "Bridge extension package.json was not found: $PackageJsonPath"
}

$PackageJson = Get-Content -LiteralPath $PackageJsonPath -Raw | ConvertFrom-Json
$Publisher = [string]$PackageJson.publisher
$Name = [string]$PackageJson.name
$Version = [string]$PackageJson.version

if (-not $Publisher -or -not $Name -or -not $Version) {
    throw "Bridge extension package metadata is incomplete."
}

$TargetDirName = "$Publisher.$Name-$Version-local"
$TargetDir = Join-Path $ExtensionsRoot $TargetDirName

Write-Step "Installing DeerFlow Copilot bridge into the main VS Code profile"
New-Item -ItemType Directory -Path $ExtensionsRoot -Force | Out-Null

$ExistingInstalls = Get-ChildItem -LiteralPath $ExtensionsRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "$Publisher.$Name-*" -and $_.FullName -ne $TargetDir }

foreach ($Existing in $ExistingInstalls) {
    Remove-Item -LiteralPath $Existing.FullName -Recurse -Force
}

if (Test-Path -LiteralPath $TargetDir) {
    Remove-Item -LiteralPath $TargetDir -Recurse -Force
}
New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

$EntriesToCopy = Get-ChildItem -LiteralPath $SourceDir -Force |
    Where-Object { $_.Name -notin @('node_modules', '.git') }

foreach ($Entry in $EntriesToCopy) {
    Copy-Item -LiteralPath $Entry.FullName -Destination $TargetDir -Recurse -Force
}

if (-not $SkipSettingsUpdate) {
    $SettingsDir = Join-Path $env:APPDATA "Code\User"
    $SettingsPath = Join-Path $SettingsDir "settings.json"
    New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null

    $SettingsObject = @{}
    if (Test-Path -LiteralPath $SettingsPath) {
        $RawSettings = Get-Content -LiteralPath $SettingsPath -Raw
        if ($RawSettings.Trim()) {
            $Parsed = $RawSettings | ConvertFrom-Json -AsHashtable
            if ($Parsed) {
                $SettingsObject = $Parsed
            }
        }
    }

    $SettingsObject['deerflowCopilotBridge.autoStart'] = $true
    $SettingsObject['deerflowCopilotBridge.model'] = 'gpt-5.4'
    $SettingsObject['deerflowCopilotBridge.reasoningEffort'] = 'xhigh'

    $SettingsObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $SettingsPath -Encoding utf8
}

Write-Ok "Installed bridge extension to $TargetDir"
Write-Host ""
Write-Host "Next step:" -ForegroundColor Cyan
Write-Host "  Reload the current VS Code window once so the main window can load the bridge extension." -ForegroundColor White
Write-Host "  After that, Ctrl + Shift + B can start DeerFlow without launching a separate Extension Development Host window." -ForegroundColor White