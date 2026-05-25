param(
    [string]$BridgeUrl = $(if ($env:DEERFLOW_COPILOT_BRIDGE_URL) { $env:DEERFLOW_COPILOT_BRIDGE_URL.TrimEnd("/") } else { "http://127.0.0.1:8765" }),
    [Alias("RequiredModel")]
    [string[]]$AllowedModels = @("gpt-5.4", "gpt-5-mini", "gpt-5.4-mini"),
    [ValidateSet("none", "minimal", "low", "medium", "high", "xhigh")]
    [string]$ExpectedReasoningEffort = "xhigh",
    [switch]$SkipRoundTrip,
    [string]$DeerFlowEmail = $(if ($env:DEERFLOW_EMAIL) { $env:DEERFLOW_EMAIL } else { "" }),
    [string]$DeerFlowPassword = $(if ($env:DEERFLOW_PASSWORD) { $env:DEERFLOW_PASSWORD } else { "" }),
    [switch]$AutoInitialize
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = if ($env:DEER_FLOW_CONFIG_PATH) { $env:DEER_FLOW_CONFIG_PATH } else { Join-Path $RepoRoot "config.yaml" }
$ChatScript = Join-Path $RepoRoot "skills\public\vscode-to-deerflow\scripts\chat.ps1"
$ProfileScript = Join-Path $RepoRoot "skills\public\vscode-to-deerflow\scripts\profile.ps1"
$ConfigureScriptHint = ".\scripts\configure-vscode-to-deerflow.ps1"
$PowerShellExe = (Get-Process -Id $PID).Path

if (Test-Path -LiteralPath $ProfileScript) {
    . $ProfileScript
}

$SavedProfile = if (Get-Command Get-VSCodeToDeerFlowProfile -ErrorAction SilentlyContinue) {
    Get-VSCodeToDeerFlowProfile
}
else {
    $null
}

if (-not $DeerFlowEmail -and $SavedProfile -and $SavedProfile.DeerFlowEmail) {
    $DeerFlowEmail = [string]$SavedProfile.DeerFlowEmail
}
if (-not $DeerFlowPassword -and $SavedProfile -and $SavedProfile.DeerFlowPassword) {
    $DeerFlowPassword = [string]$SavedProfile.DeerFlowPassword
}

$SavedDeerFlowUrl = if (-not $env:DEERFLOW_URL -and $SavedProfile -and $SavedProfile.DeerFlowUrl) {
    ([string]$SavedProfile.DeerFlowUrl).TrimEnd("/")
}
else {
    ""
}

$AutoInitializeRequested = $AutoInitialize.IsPresent -or (($env:DEERFLOW_AUTO_INITIALIZE ?? "") -match '^(?i:1|true|yes|on)$') -or [bool]($SavedProfile -and $SavedProfile.AutoInitialize)

function Write-Step {
    param([string]$Text)
    Write-Host "[check] $Text" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[ok] $Text" -ForegroundColor Green
}

function Fail {
    param([string]$Text)
    Write-Host "[fail] $Text" -ForegroundColor Red
    exit 1
}

function New-DeerFlowCandidate {
    param(
        [string]$GatewayUrl,
        [string]$LangGraphUrl,
        [string]$Label
    )

    return [pscustomobject]@{
        GatewayUrl = $GatewayUrl.TrimEnd("/")
        LangGraphUrl = $LangGraphUrl.TrimEnd("/")
        Label = $Label
    }
}

function Get-DefaultLangGraphUrl {
    param([string]$GatewayUrl)

    try {
        $uri = [System.Uri]$GatewayUrl
        if ($uri.Port -eq 8001) {
            return "$($GatewayUrl.TrimEnd('/'))/api"
        }
    }
    catch {
    }

    return "$($GatewayUrl.TrimEnd('/'))/api/langgraph"
}

function Normalize-LangGraphUrl {
    param(
        [string]$GatewayUrl,
        [string]$LangGraphUrl
    )

    if (-not $LangGraphUrl) {
        return $LangGraphUrl
    }

    try {
        $gatewayUri = [System.Uri]$GatewayUrl
        $langGraphUri = [System.Uri]$LangGraphUrl
        if (
            $gatewayUri.Port -eq 8001 -and
            $langGraphUri.Port -eq 8001 -and
            $gatewayUri.Host -eq $langGraphUri.Host -and
            $langGraphUri.AbsolutePath.TrimEnd("/") -eq "/api/langgraph"
        ) {
            return "$($GatewayUrl.TrimEnd('/'))/api"
        }
    }
    catch {
    }

    return $LangGraphUrl
}

function Get-DeerFlowCandidates {
    $candidates = New-Object System.Collections.Generic.List[object]

    if ($env:DEERFLOW_GATEWAY_URL -or $env:DEERFLOW_LANGGRAPH_URL) {
        $gatewayUrl = if ($env:DEERFLOW_GATEWAY_URL) { $env:DEERFLOW_GATEWAY_URL } elseif ($env:DEERFLOW_URL) { $env:DEERFLOW_URL } else { "http://localhost:2026" }
        $langGraphUrl = if ($env:DEERFLOW_LANGGRAPH_URL) { Normalize-LangGraphUrl -GatewayUrl $gatewayUrl -LangGraphUrl $env:DEERFLOW_LANGGRAPH_URL } else { Get-DefaultLangGraphUrl -GatewayUrl $gatewayUrl }
        $candidates.Add((New-DeerFlowCandidate -GatewayUrl $gatewayUrl -LangGraphUrl $langGraphUrl -Label "environment override"))
    }

    if ($env:DEERFLOW_URL) {
        $baseUrl = $env:DEERFLOW_URL.TrimEnd("/")
        $candidates.Add((New-DeerFlowCandidate -GatewayUrl $baseUrl -LangGraphUrl (Get-DefaultLangGraphUrl -GatewayUrl $baseUrl) -Label "DEERFLOW_URL"))
    }
    elseif ($script:SavedDeerFlowUrl) {
        $candidates.Add((New-DeerFlowCandidate -GatewayUrl $script:SavedDeerFlowUrl -LangGraphUrl (Get-DefaultLangGraphUrl -GatewayUrl $script:SavedDeerFlowUrl) -Label "saved profile"))
    }

    $candidates.Add((New-DeerFlowCandidate -GatewayUrl "http://localhost:2026" -LangGraphUrl "http://localhost:2026/api/langgraph" -Label "local proxy"))
    $candidates.Add((New-DeerFlowCandidate -GatewayUrl "http://127.0.0.1:2026" -LangGraphUrl "http://127.0.0.1:2026/api/langgraph" -Label "local proxy loopback"))
    $candidates.Add((New-DeerFlowCandidate -GatewayUrl "http://localhost:8001" -LangGraphUrl "http://localhost:8001/api" -Label "gateway direct"))
    $candidates.Add((New-DeerFlowCandidate -GatewayUrl "http://127.0.0.1:8001" -LangGraphUrl "http://127.0.0.1:8001/api" -Label "gateway direct loopback"))

    $seen = @{}
    foreach ($candidate in $candidates) {
        $key = "$($candidate.GatewayUrl)|$($candidate.LangGraphUrl)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $candidate
        }
    }
}

function Resolve-ReachableDeerFlow {
    foreach ($candidate in Get-DeerFlowCandidates) {
        try {
            $health = Invoke-RestMethod -Uri "$($candidate.GatewayUrl)/health" -Method Get
            return [pscustomobject]@{
                Candidate = $candidate
                Health = $health
            }
        }
        catch {
            continue
        }
    }

    return $null
}

function Get-DeerFlowSetupStatus {
    param([string]$GatewayUrl)

    try {
        return Invoke-RestMethod -Uri "$GatewayUrl/api/v1/auth/setup-status" -Method Get
    }
    catch {
        return $null
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Fail "Config file not found: $ConfigPath"
}

$configText = Get-Content -LiteralPath $ConfigPath -Raw
$modelBlockMatch = [regex]::Match($configText, '(?ms)^\s*-\s*name:\s*vscode-copilot\b.*?(?=^\s*-\s*name:|\z)')
if (-not $modelBlockMatch.Success) {
    Fail "config.yaml does not contain a vscode-copilot model block."
}

$modelBlock = $modelBlockMatch.Value
$allowedModels = @($AllowedModels | Where-Object { $_ } | Select-Object -Unique)
if ($allowedModels.Count -eq 0) {
    Fail "No allowed Copilot models were provided."
}

$allowedModelPattern = ($allowedModels | ForEach-Object { [regex]::Escape($_) }) -join '|'
$escapedEffort = [regex]::Escape($ExpectedReasoningEffort)

if ($modelBlock -notmatch 'use:\s*deerflow\.models\.vscode_copilot_provider:VSCodeCopilotChatModel') {
    Fail "config.yaml points vscode-copilot to the wrong provider."
}
if ($modelBlock -match "model:\s*(?<model>$allowedModelPattern)(\s|$)") {
    $configuredModel = $Matches.model
}
else {
    Fail "config.yaml is not pinned to an allowed Copilot model: $($allowedModels -join ', ')"
}
if ($modelBlock -notmatch 'supports_reasoning_effort:\s*true') {
    Fail "config.yaml is missing supports_reasoning_effort: true"
}
if ($modelBlock -notmatch "reasoning_effort:\s*$escapedEffort(\s|$)") {
    Fail "config.yaml is not pinned to reasoning_effort: $ExpectedReasoningEffort"
}
Write-Ok "config.yaml is pinned to $configuredModel with reasoning_effort: $ExpectedReasoningEffort"

Write-Step "Checking bridge at $BridgeUrl"
try {
    $bridgeHealth = Invoke-RestMethod -Uri "$BridgeUrl/health" -Method Get
}
catch {
    Fail "Bridge is not reachable at $BridgeUrl. Start the Extension Development Host window and run 'DeerFlow Copilot Bridge: Start'."
}

if ($null -eq $bridgeHealth.configured_model -or $null -eq $bridgeHealth.configured_reasoning_effort) {
    Fail "Bridge health output is missing configured_model/configured_reasoning_effort. Restart the bridge from the new Extension Development Host window so the latest code is active."
}
if ($bridgeHealth.PSObject.Properties.Name -notcontains 'request_ready') {
    Fail "Bridge health output is from an older bridge build. Close the old Extension Development Host window, start a new one, then run 'DeerFlow Copilot Bridge: Start' again."
}
if ($bridgeHealth.PSObject.Properties.Name -contains 'request_ready' -and -not $bridgeHealth.request_ready) {
    $probeError = if ($bridgeHealth.request_probe -and $bridgeHealth.request_probe.error) { $bridgeHealth.request_probe.error } else { "Approve the Copilot access prompt in the Extension Development Host window, then rerun 'DeerFlow Copilot Bridge: Start'." }
    Fail "Bridge is listening, but real Copilot requests are not ready yet. $probeError"
}
if ($allowedModels -notcontains [string]$bridgeHealth.configured_model) {
    Fail "Bridge default model is '$($bridgeHealth.configured_model)', expected one of: $($allowedModels -join ', ')."
}
if ($bridgeHealth.configured_reasoning_effort -ne $ExpectedReasoningEffort) {
    Fail "Bridge default reasoning effort is '$($bridgeHealth.configured_reasoning_effort)', expected '$ExpectedReasoningEffort'."
}
Write-Ok "Bridge health is ok and defaults to $($bridgeHealth.configured_model) / $ExpectedReasoningEffort"

Write-Step "Checking bridge model inventory"
try {
    $modelsResponse = Invoke-RestMethod -Uri "$BridgeUrl/v1/models" -Method Get
}
catch {
    Fail "Failed to query $BridgeUrl/v1/models: $($_.Exception.Message)"
}

$availableModels = @($modelsResponse.data)
$missingModels = @()
foreach ($allowedModel in $allowedModels) {
    $match = @($availableModels | Where-Object { $_.id -eq $allowedModel -or $_.family -eq $allowedModel })
    if ($match.Count -eq 0) {
        $missingModels += $allowedModel
    }
}
if ($missingModels.Count -gt 0) {
    Fail "Bridge did not expose one or more allowed models: $($missingModels -join ', '). Check your Copilot model availability in the Extension Development Host window."
}
Write-Ok "Bridge exposes allowed model set: $($allowedModels -join ', ')"

if ($SkipRoundTrip) {
    Write-Ok "Skipped DeerFlow round-trip check."
    exit 0
}

$deerFlow = Resolve-ReachableDeerFlow
if (-not $deerFlow) {
    Fail "DeerFlow is not reachable. Start DeerFlow first, then rerun this check. Try 'make dev' after installing Node.js, pnpm, nginx, and make; or set DEERFLOW_GATEWAY_URL / DEERFLOW_LANGGRAPH_URL explicitly."
}

$gatewayUrl = $deerFlow.Candidate.GatewayUrl
$langGraphUrl = $deerFlow.Candidate.LangGraphUrl
Write-Ok "DeerFlow gateway is reachable at $gatewayUrl ($($deerFlow.Candidate.Label))"

if ($AutoInitializeRequested -and (-not $DeerFlowEmail -or -not $DeerFlowPassword)) {
    Fail "Auto-initialize was requested, but DEERFLOW_EMAIL / DEERFLOW_PASSWORD are not set."
}

$setupStatus = Get-DeerFlowSetupStatus -GatewayUrl $gatewayUrl
if ($setupStatus -and $setupStatus.needs_setup -and (-not $DeerFlowEmail -or -not $DeerFlowPassword)) {
    Fail "DeerFlow first-run setup is still pending. Open http://localhost:2026/setup, or save credentials with $ConfigureScriptHint and enable auto initialize, then rerun this check."
}

if ((-not $DeerFlowEmail -or -not $DeerFlowPassword) -and (-not $setupStatus -or -not $setupStatus.needs_setup)) {
    Fail "DeerFlow round-trip requires login. Set DEERFLOW_EMAIL and DEERFLOW_PASSWORD in this terminal, or run $ConfigureScriptHint to save them once, then rerun this check."
}

if (-not (Test-Path -LiteralPath $ChatScript)) {
    Fail "Chat helper script not found: $ChatScript"
}

$previousGatewayUrl = $env:DEERFLOW_GATEWAY_URL
$previousLangGraphUrl = $env:DEERFLOW_LANGGRAPH_URL
$previousDeerFlowEmail = $env:DEERFLOW_EMAIL
$previousDeerFlowPassword = $env:DEERFLOW_PASSWORD
$previousAutoInitialize = $env:DEERFLOW_AUTO_INITIALIZE

try {
    $env:DEERFLOW_GATEWAY_URL = $gatewayUrl
    $env:DEERFLOW_LANGGRAPH_URL = $langGraphUrl
    $env:DEERFLOW_EMAIL = $DeerFlowEmail
    $env:DEERFLOW_PASSWORD = $DeerFlowPassword
    if ($AutoInitializeRequested) {
        $env:DEERFLOW_AUTO_INITIALIZE = "1"
    }
    else {
        Remove-Item Env:DEERFLOW_AUTO_INITIALIZE -ErrorAction SilentlyContinue
    }

    Write-Step "Running end-to-end DeerFlow -> bridge -> Copilot check"
    $roundTripOutput = & $PowerShellExe -ExecutionPolicy Bypass -File $ChatScript -Message "Reply with EXACT text: DEERFLOW_BRIDGE_OK" -Mode standard 2>&1 | Out-String
    $roundTripExitCode = $LASTEXITCODE

    if ($roundTripExitCode -ne 0) {
        Fail "End-to-end DeerFlow request failed. Output:`n$roundTripOutput"
    }
    if ($roundTripOutput -notmatch 'DEERFLOW_BRIDGE_OK') {
        Fail "End-to-end DeerFlow request completed, but the expected marker was not returned. Output:`n$roundTripOutput"
    }
}
finally {
    if ($null -eq $previousGatewayUrl) {
        Remove-Item Env:DEERFLOW_GATEWAY_URL -ErrorAction SilentlyContinue
    } else {
        $env:DEERFLOW_GATEWAY_URL = $previousGatewayUrl
    }

    if ($null -eq $previousLangGraphUrl) {
        Remove-Item Env:DEERFLOW_LANGGRAPH_URL -ErrorAction SilentlyContinue
    } else {
        $env:DEERFLOW_LANGGRAPH_URL = $previousLangGraphUrl
    }

    if ($null -eq $previousDeerFlowEmail) {
        Remove-Item Env:DEERFLOW_EMAIL -ErrorAction SilentlyContinue
    } else {
        $env:DEERFLOW_EMAIL = $previousDeerFlowEmail
    }

    if ($null -eq $previousDeerFlowPassword) {
        Remove-Item Env:DEERFLOW_PASSWORD -ErrorAction SilentlyContinue
    } else {
        $env:DEERFLOW_PASSWORD = $previousDeerFlowPassword
    }

    if ($null -eq $previousAutoInitialize) {
        Remove-Item Env:DEERFLOW_AUTO_INITIALIZE -ErrorAction SilentlyContinue
    } else {
        $env:DEERFLOW_AUTO_INITIALIZE = $previousAutoInitialize
    }
}

Write-Ok "End-to-end DeerFlow request returned the expected marker"

try {
    $bridgeHealthAfter = Invoke-RestMethod -Uri "$BridgeUrl/health" -Method Get
}
catch {
    Fail "Bridge health check after round-trip failed: $($_.Exception.Message)"
}

if ($null -eq $bridgeHealthAfter.cached_model -or $bridgeHealthAfter.cached_model.id -ne $RequiredModel) {
    $actualCachedModel = if ($bridgeHealthAfter.cached_model) { $bridgeHealthAfter.cached_model.id } else { "<none>" }
    Fail "Round-trip did not leave the bridge pinned to '$RequiredModel'. Current cached model: $actualCachedModel"
}

Write-Ok "Bridge cached model is $RequiredModel after the round-trip"
Write-Host ""
Write-Host "All DeerFlow Copilot bridge checks passed." -ForegroundColor Green