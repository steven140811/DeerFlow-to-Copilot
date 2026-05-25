<#
.SYNOPSIS
Starts DeerFlow on Windows, optionally initializes the first admin account, and opens the browser UI.

.DESCRIPTION
This helper prefers Docker on Windows when Docker is available. If Docker is not
available, it falls back to the official local dev flow through Git Bash.

If the system has not been initialized yet, the script can create the first admin
account through DeerFlow's public auth API. Credentials that are verified or
successfully initialized are saved with Windows DPAPI so other local helper
scripts can reuse them.

.EXAMPLE
pwsh -ExecutionPolicy Bypass -File .\scripts\start-deerflow-ui.ps1 -Email admin@example.com

.EXAMPLE
pwsh -ExecutionPolicy Bypass -File .\scripts\start-deerflow-ui.ps1 -Mode Docker -Email admin@example.com -Password "StrongPass123!"
#>

[CmdletBinding()]
param(
    [ValidateSet("Auto", "Docker", "Local")]
    [string]$Mode = "Auto",

    [string]$Email = $(if ($env:DEERFLOW_EMAIL) { $env:DEERFLOW_EMAIL } else { "" }),

    [string]$Password = $(if ($env:DEERFLOW_PASSWORD) { $env:DEERFLOW_PASSWORD } else { "" }),

    [string]$BaseUrl = $(if ($env:DEERFLOW_URL) { $env:DEERFLOW_URL.TrimEnd("/") } else { "" }),

    [switch]$SkipAdminInitialize,

    [switch]$SkipCredentialSave,

    [switch]$SkipCopilotBridge,

    [switch]$NoBrowser,

    [int]$StartupTimeoutSeconds = 300,

    [int]$BridgeStartupTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path $PSScriptRoot -Parent
$GitBashRunner = Join-Path $RepoRoot "scripts\run-with-git-bash.cmd"
$CopilotBridgeLauncher = Join-Path $RepoRoot "scripts\start-vscode-copilot-bridge.ps1"
$ConfigPath = if ($env:DEER_FLOW_CONFIG_PATH) { $env:DEER_FLOW_CONFIG_PATH } else { Join-Path $RepoRoot "config.yaml" }
$ProfileScript = Join-Path $RepoRoot "skills\public\vscode-to-deerflow\scripts\profile.ps1"

if (Test-Path -LiteralPath $ProfileScript) {
    . $ProfileScript
}

$SavedProfile = if (Get-Command Get-VSCodeToDeerFlowProfile -ErrorAction SilentlyContinue) {
    Get-VSCodeToDeerFlowProfile
}
else {
    $null
}

if (-not $BaseUrl) {
    if ($SavedProfile -and $SavedProfile.DeerFlowUrl) {
        $BaseUrl = ([string]$SavedProfile.DeerFlowUrl).TrimEnd("/")
    }
    else {
        $BaseUrl = "http://localhost:2026"
    }
}

if (-not $Email -and $SavedProfile -and $SavedProfile.DeerFlowEmail) {
    $Email = [string]$SavedProfile.DeerFlowEmail
}
if (-not $Password -and $SavedProfile -and $SavedProfile.DeerFlowPassword) {
    $Password = [string]$SavedProfile.DeerFlowPassword
}

function Write-Step {
    param([string]$Text)
    Write-Host "[step] $Text" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Text)
    Write-Host "[info] $Text" -ForegroundColor DarkCyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[ok] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[warn] $Text" -ForegroundColor Yellow
}

function Fail {
    param([string]$Text)
    throw $Text
}

function Add-PathEntries {
    param(
        [System.Collections.Generic.List[string]]$Target,
        [System.Collections.Generic.HashSet[string]]$Seen,
        [string]$RawPath
    )

    if (-not $RawPath) {
        return
    }

    foreach ($entry in ($RawPath -split ';')) {
        $candidate = $entry.Trim()
        if (-not $candidate) {
            continue
        }

        $key = $candidate.ToLowerInvariant()
        if ($Seen.Add($key)) {
            $Target.Add($candidate)
        }
    }
}

function Get-NodeInstallPaths {
    $registryKeys = @(
        'HKLM:\SOFTWARE\Node.js',
        'HKCU:\SOFTWARE\Node.js'
    )

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($registryKey in $registryKeys) {
        $properties = Get-ItemProperty -Path $registryKey -ErrorAction SilentlyContinue
        if ($null -eq $properties) {
            continue
        }

        $installPathProperty = $properties.PSObject.Properties['InstallPath']
        if ($installPathProperty -and $installPathProperty.Value) {
            $paths.Add(([string]$installPathProperty.Value).TrimEnd('\'))
        }
    }

    return $paths
}

function Sync-ProcessPath {
    if ($env:OS -ne 'Windows_NT') {
        return
    }

    $entries = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    Add-PathEntries -Target $entries -Seen $seen -RawPath ([Environment]::GetEnvironmentVariable('Path', 'Machine'))
    Add-PathEntries -Target $entries -Seen $seen -RawPath ([Environment]::GetEnvironmentVariable('Path', 'User'))
    Add-PathEntries -Target $entries -Seen $seen -RawPath $env:Path

    foreach ($nodeInstallPath in (Get-NodeInstallPaths)) {
        Add-PathEntries -Target $entries -Seen $seen -RawPath $nodeInstallPath
    }

    $env:Path = ($entries -join ';')
}

function ConvertTo-PlainText {
    param([Security.SecureString]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Get-ErrorMessage {
    param($ErrorRecord)

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return [string]$ErrorRecord.ErrorDetails.Message
    }

    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
        return [string]$ErrorRecord.Exception.Message
    }

    return ($ErrorRecord | Out-String).Trim()
}

function Test-DockerAvailable {
    $dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCommand) {
        return $false
    }

    try {
        & $dockerCommand.Source info *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

Sync-ProcessPath

function Resolve-LaunchMode {
    switch ($Mode) {
        "Docker" {
            if (-not (Test-DockerAvailable)) {
                Fail "Docker mode was requested, but Docker is not installed or the daemon is not reachable."
            }
            return "Docker"
        }
        "Local" {
            return "Local"
        }
        default {
            if (Test-DockerAvailable) {
                return "Docker"
            }

            Write-Warn "Docker is not available on this machine. Falling back to local mode."

            return "Local"
        }
    }
}

function Invoke-GitBashScript {
    param(
        [string[]]$Arguments,
        [string]$FailureMessage
    )

    if (-not (Test-Path -LiteralPath $GitBashRunner)) {
        Fail "Git Bash launcher not found: $GitBashRunner"
    }

    Push-Location $RepoRoot
    try {
        & $GitBashRunner @Arguments
        if ($LASTEXITCODE -ne 0) {
            Fail "$FailureMessage (exit code $LASTEXITCODE)"
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-LocalDependencyCheck {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCommand) {
        Fail "Python is not available on PATH. Install Python 3.12+ or use Docker mode."
    }

    Write-Step "Checking local prerequisites"
    Push-Location $RepoRoot
    try {
        & $pythonCommand.Source (Join-Path $RepoRoot "scripts\check.py")
        if ($LASTEXITCODE -ne 0) {
            Fail "Local dependency check failed. Install the missing tools for local mode, or install and start Docker, then rerun this script."
        }
    }
    finally {
        Pop-Location
    }
}

function Test-DeerFlowReachable {
    param([string]$Url)

    try {
        $healthResponse = Invoke-WebRequest -Uri "$($Url.TrimEnd('/'))/health" -SkipHttpErrorCheck -TimeoutSec 5
        if ([int]$healthResponse.StatusCode -lt 200 -or [int]$healthResponse.StatusCode -ge 400) {
            return $false
        }

        foreach ($path in @('/', '/login')) {
            $pageResponse = Invoke-WebRequest -Uri "$($Url.TrimEnd('/'))$path" -SkipHttpErrorCheck -MaximumRedirection 3 -TimeoutSec 5
            if ([int]$pageResponse.StatusCode -ge 200 -and [int]$pageResponse.StatusCode -lt 400) {
                $content = [string]$pageResponse.Content
                if ($content -match '<title>\s*DeerFlow\s*</title>' -or $content -match '\bDeerFlow\b') {
                    return $true
                }
            }
        }

        return $false
    }
    catch {
        return $false
    }
}

function Wait-DeerFlowReady {
    param(
        [string]$Url,
        [int]$TimeoutSeconds
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-DeerFlowReachable -Url $Url) {
            return
        }

        Start-Sleep -Seconds 2
    }

    Fail "DeerFlow did not become ready at $Url within $TimeoutSeconds seconds. Check logs under logs/ or Docker logs."
}

function Test-CopilotBridgeConfigured {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $false
    }

    try {
        return Select-String -Path $ConfigPath -Pattern 'use:\s*deerflow\.models\.vscode_copilot_provider:VSCodeCopilotChatModel' -Quiet
    }
    catch {
        return $false
    }
}

function Get-CopilotBridgeHealth {
    try {
        return Invoke-RestMethod -Uri "http://127.0.0.1:8765/health" -Method Get -TimeoutSec 5
    }
    catch {
        return $null
    }
}

function Test-CopilotBridgeListening {
    return $null -ne (Get-CopilotBridgeHealth)
}

function Test-CopilotBridgeReachable {
    $health = Get-CopilotBridgeHealth
    if ($null -eq $health) {
        return $false
    }

    $requestReadyProperty = $health.PSObject.Properties['request_ready']
    if ($requestReadyProperty) {
        return [bool]$requestReadyProperty.Value
    }

    return $true
}

function Wait-CopilotBridgeReady {
    param([int]$TimeoutSeconds)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-CopilotBridgeReachable) {
            return $true
        }

        Start-Sleep -Seconds 2
    }

    return $false
}

function Ensure-CopilotBridge {
    param([int]$TimeoutSeconds)

    if ($SkipCopilotBridge) {
        Write-Warn "Skipping VS Code Copilot bridge startup because -SkipCopilotBridge was requested."
        return $false
    }

    if (-not (Test-CopilotBridgeConfigured)) {
        return $false
    }

    if (Test-CopilotBridgeReachable) {
        Write-Ok "VS Code Copilot bridge is already reachable at http://127.0.0.1:8765"
        return $true
    }

    if (Test-CopilotBridgeListening) {
        Write-Warn "VS Code Copilot bridge is listening, but Copilot requests are not ready yet. Approve any Copilot access prompt in the Extension Development Host window, then retry."
        return $false
    }

    if (-not (Test-Path -LiteralPath $CopilotBridgeLauncher)) {
        Write-Warn "VS Code Copilot bridge launcher was not found at $CopilotBridgeLauncher"
        return $false
    }

    $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwshCommand) {
        Write-Warn "pwsh is not available, so the VS Code Copilot bridge could not be launched automatically."
        return $false
    }

    Write-Step "Starting VS Code Copilot bridge"
    Start-Process -FilePath $pwshCommand.Source -ArgumentList @(
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $CopilotBridgeLauncher,
        '-WorkspacePath',
        $RepoRoot
    ) | Out-Null

    if (Wait-CopilotBridgeReady -TimeoutSeconds $TimeoutSeconds) {
        Write-Ok "VS Code Copilot bridge is reachable at http://127.0.0.1:8765"
        return $true
    }

    Write-Warn "The VS Code Copilot bridge window was launched, but the bridge is not reachable yet. If the Extension Development Host asks for Copilot model access, approve it there."
    return $false
}

function Get-DeerFlowSetupStatus {
    param([string]$Url)

    try {
        return Invoke-RestMethod -Uri "$($Url.TrimEnd('/'))/api/v1/auth/setup-status" -Method Get -TimeoutSec 10
    }
    catch {
        Fail "Failed to query DeerFlow setup status: $(Get-ErrorMessage -ErrorRecord $_)"
    }
}

function Prompt-ForCredentials {
    param(
        [string]$CurrentEmail,
        [string]$CurrentPassword,
        [string]$Reason
    )

    $resolvedEmail = $CurrentEmail
    $resolvedPassword = $CurrentPassword

    Write-Info $Reason

    if (-not $resolvedEmail) {
        $resolvedEmail = (Read-Host "DeerFlow email").Trim()
    }

    if (-not $resolvedPassword) {
        $securePassword = Read-Host "DeerFlow password" -AsSecureString
        $resolvedPassword = ConvertTo-PlainText -Value $securePassword
    }

    if (-not $resolvedEmail -or -not $resolvedPassword) {
        Fail "Email and password are required to continue."
    }

    return [pscustomobject]@{
        Email = $resolvedEmail
        Password = $resolvedPassword
    }
}

function Initialize-DeerFlowAdmin {
    param(
        [string]$Url,
        [string]$SelectedEmail,
        [string]$SelectedPassword
    )

    $body = @{ email = $SelectedEmail; password = $SelectedPassword } | ConvertTo-Json
    try {
        $user = Invoke-RestMethod -Uri "$($Url.TrimEnd('/'))/api/v1/auth/initialize" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 15
        return [pscustomobject]@{
            Success = $true
            Email = [string]$user.email
        }
    }
    catch {
        $message = Get-ErrorMessage -ErrorRecord $_
        if ($message -match "System already initialized") {
            return [pscustomobject]@{
                Success = $false
                AlreadyInitialized = $true
                Message = $message
            }
        }

        Fail "Failed to initialize DeerFlow admin: $message"
    }
}

function Test-DeerFlowLogin {
    param(
        [string]$Url,
        [string]$SelectedEmail,
        [string]$SelectedPassword
    )

    try {
        Invoke-RestMethod -Uri "$($Url.TrimEnd('/'))/api/v1/auth/login/local" -Method Post -Body @{ username = $SelectedEmail; password = $SelectedPassword } -TimeoutSec 15 | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Save-ValidatedProfile {
    param(
        [string]$Url,
        [string]$ValidatedEmail,
        [string]$ValidatedPassword
    )

    if ($SkipCredentialSave) {
        return
    }

    if (-not (Get-Command Save-VSCodeToDeerFlowProfile -ErrorAction SilentlyContinue)) {
        return
    }

    $savedPath = Save-VSCodeToDeerFlowProfile -DeerFlowUrl $Url -DeerFlowEmail $ValidatedEmail -DeerFlowPassword $ValidatedPassword -AutoInitialize $true
    Write-Ok "Saved DeerFlow credentials to $savedPath"
}

function Open-DeerFlowUi {
    param(
        [string]$Url,
        [bool]$NeedsSetup
    )

    if ($NoBrowser) {
        return
    }

    $target = if ($NeedsSetup) {
        "$($Url.TrimEnd('/'))/setup"
    }
    else {
        "$($Url.TrimEnd('/'))/login?next=$([System.Uri]::EscapeDataString('/workspace'))"
    }

    Start-Process $target | Out-Null
    Write-Ok "Opened $target"
}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Fail "DeerFlow config was not found at $ConfigPath. Create config.yaml first, for example by running 'make setup'."
    }

    $launchMode = Resolve-LaunchMode
    $startedMode = $null

    if (Test-DeerFlowReachable -Url $BaseUrl) {
        Write-Ok "DeerFlow is already reachable at $BaseUrl"
    }
    else {
        switch ($launchMode) {
            "Docker" {
                Write-Step "Preparing Docker runtime"
                Invoke-GitBashScript -Arguments @("./scripts/docker.sh", "init") -FailureMessage "Docker init failed"
                Write-Step "Starting DeerFlow with Docker"
                Invoke-GitBashScript -Arguments @("./scripts/docker.sh", "start") -FailureMessage "Docker startup failed"
                $startedMode = "Docker"
            }
            "Local" {
                Invoke-LocalDependencyCheck
                Write-Step "Starting DeerFlow in local daemon mode"
                Invoke-GitBashScript -Arguments @("./scripts/serve.sh", "--dev", "--daemon") -FailureMessage "Local startup failed"
                $startedMode = "Local"
            }
        }

        Write-Step "Waiting for DeerFlow UI to become ready"
        Wait-DeerFlowReady -Url $BaseUrl -TimeoutSeconds $StartupTimeoutSeconds
        Write-Ok "DeerFlow is ready at $BaseUrl"
    }

    $setupStatus = Get-DeerFlowSetupStatus -Url $BaseUrl
    $needsSetup = [bool]$setupStatus.needs_setup
    $validatedCredentials = $false
    $copilotBridgeReady = Ensure-CopilotBridge -TimeoutSeconds $BridgeStartupTimeoutSeconds

    if ($needsSetup) {
        if ($SkipAdminInitialize) {
            Write-Warn "DeerFlow still needs first-run setup. Opening the setup page."
        }
        else {
            $resolvedCredentials = Prompt-ForCredentials -CurrentEmail $Email -CurrentPassword $Password -Reason "First-run setup is still pending. Admin credentials are required."
            $Email = $resolvedCredentials.Email
            $Password = $resolvedCredentials.Password

            if ($Password.Length -lt 8) {
                Fail "Password must be at least 8 characters."
            }

            Write-Step "Initializing the first DeerFlow admin account"
            $initializeResult = Initialize-DeerFlowAdmin -Url $BaseUrl -SelectedEmail $Email -SelectedPassword $Password
            if ($initializeResult.Success) {
                Write-Ok "Initialized DeerFlow admin account: $($initializeResult.Email)"
                Save-ValidatedProfile -Url $BaseUrl -ValidatedEmail $Email -ValidatedPassword $Password
                $validatedCredentials = $true
                $needsSetup = $false
            }
            elseif ($initializeResult.AlreadyInitialized) {
                Write-Warn "Another process initialized DeerFlow while this script was running."
                $setupStatus = Get-DeerFlowSetupStatus -Url $BaseUrl
                $needsSetup = [bool]$setupStatus.needs_setup
            }
        }
    }
    elseif ($Email -and $Password) {
        Write-Step "Verifying DeerFlow login credentials"
        if (Test-DeerFlowLogin -Url $BaseUrl -SelectedEmail $Email -SelectedPassword $Password) {
            Write-Ok "Verified DeerFlow login for $Email"
            Save-ValidatedProfile -Url $BaseUrl -ValidatedEmail $Email -ValidatedPassword $Password
            $validatedCredentials = $true
        }
        else {
            Write-Warn "DeerFlow is already initialized, but the provided email/password could not be verified. The browser UI will still open, but the credentials were not saved."
            Write-Warn "If you forgot the current admin password, use backend/app.gateway.auth.reset_admin or reset it from the UI after logging in."
        }
    }
    else {
        Write-Info "No DeerFlow credentials were supplied. The browser UI will open and you can log in there."
    }

    Open-DeerFlowUi -Url $BaseUrl -NeedsSetup $needsSetup

    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  DeerFlow launch summary"
    Write-Host "=========================================="
    Write-Host "  URL:           $BaseUrl"
    if ($startedMode) {
        Write-Host "  Start mode:    $startedMode"
    }
    else {
        Write-Host "  Start mode:    already running"
    }
    if ($needsSetup) {
        Write-Host "  Auth status:   setup required"
    }
    elseif ($validatedCredentials) {
        Write-Host "  Auth status:   credentials verified"
    }
    else {
        Write-Host "  Auth status:   UI opened"
    }
    if (Test-CopilotBridgeConfigured) {
        if ($copilotBridgeReady) {
            Write-Host "  Copilot:       bridge ready"
        }
        else {
            Write-Host "  Copilot:       bridge launching or pending approval"
        }
    }
    Write-Host ""
    if ($startedMode -eq "Docker") {
        Write-Host "  Stop command:  scripts\run-with-git-bash.cmd ./scripts/docker.sh stop"
    }
    elseif ($startedMode -eq "Local") {
        Write-Host "  Stop command:  scripts\run-with-git-bash.cmd ./scripts/serve.sh --stop"
    }
    else {
        Write-Host "  Stop command:  make docker-stop  or  make stop"
    }
}
catch {
    Write-Host "[fail] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}