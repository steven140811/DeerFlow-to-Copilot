param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Message,

    [Parameter(Position = 1)]
    [string]$ThreadId = "",

    [Parameter(Position = 2)]
    [ValidateSet("flash", "standard", "pro", "ultra")]
    [string]$Mode = "pro",

    [Parameter()]
    [string]$Email = $(if ($env:DEERFLOW_EMAIL) { $env:DEERFLOW_EMAIL } else { "" }),

    [Parameter()]
    [string]$Password = $(if ($env:DEERFLOW_PASSWORD) { $env:DEERFLOW_PASSWORD } else { "" }),

    [Parameter()]
    [switch]$AutoInitialize
)

$ErrorActionPreference = "Stop"

$ProfileScript = Join-Path $PSScriptRoot "profile.ps1"
if (Test-Path -LiteralPath $ProfileScript) {
    . $ProfileScript
}

$SavedProfile = if (Get-Command Get-VSCodeToDeerFlowProfile -ErrorAction SilentlyContinue) {
    Get-VSCodeToDeerFlowProfile
}
else {
    $null
}

if (-not $Email -and $SavedProfile -and $SavedProfile.DeerFlowEmail) {
    $Email = [string]$SavedProfile.DeerFlowEmail
}
if (-not $Password -and $SavedProfile -and $SavedProfile.DeerFlowPassword) {
    $Password = [string]$SavedProfile.DeerFlowPassword
}

$DeerFlowUrl = if ($env:DEERFLOW_URL) { $env:DEERFLOW_URL.TrimEnd("/") } elseif ($SavedProfile -and $SavedProfile.DeerFlowUrl) { ([string]$SavedProfile.DeerFlowUrl).TrimEnd("/") } else { "http://localhost:2026" }
$GatewayUrl = if ($env:DEERFLOW_GATEWAY_URL) { $env:DEERFLOW_GATEWAY_URL.TrimEnd("/") } else { $DeerFlowUrl }
$RawLangGraphUrl = if ($env:DEERFLOW_LANGGRAPH_URL) { $env:DEERFLOW_LANGGRAPH_URL.TrimEnd("/") } else { "" }
$HasCredentials = [bool]($Email -and $Password)
$AutoInitializeRequested = $AutoInitialize.IsPresent -or (($env:DEERFLOW_AUTO_INITIALIZE ?? "") -match '^(?i:1|true|yes|on)$') -or [bool]($SavedProfile -and $SavedProfile.AutoInitialize)
$ConfigureScriptHint = ".\configure.ps1"

function Write-Stderr {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
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

function Get-DefaultLangGraphUrl {
    param([string]$BaseUrl)

    try {
        $uri = [System.Uri]$BaseUrl
        if ($uri.Port -eq 8001) {
            return "$($BaseUrl.TrimEnd('/'))/api"
        }
    }
    catch {
    }

    return "$($BaseUrl.TrimEnd('/'))/api/langgraph"
}

function Normalize-LangGraphUrl {
    param(
        [string]$SelectedGatewayUrl,
        [string]$ConfiguredLangGraphUrl
    )

    if (-not $ConfiguredLangGraphUrl) {
        return $ConfiguredLangGraphUrl
    }

    try {
        $gatewayUri = [System.Uri]$SelectedGatewayUrl
        $configuredUri = [System.Uri]$ConfiguredLangGraphUrl
        if (
            $gatewayUri.Port -eq 8001 -and
            $configuredUri.Port -eq 8001 -and
            $gatewayUri.Host -eq $configuredUri.Host -and
            $configuredUri.AbsolutePath.TrimEnd("/") -eq "/api/langgraph"
        ) {
            return "$($SelectedGatewayUrl.TrimEnd('/'))/api"
        }
    }
    catch {
    }

    return $ConfiguredLangGraphUrl
}

function Get-DeerFlowSetupStatus {
    param([string]$SelectedGatewayUrl)

    try {
        return Invoke-RestMethod -Uri "$SelectedGatewayUrl/api/v1/auth/setup-status" -Method Get
    }
    catch {
        return $null
    }
}

function Get-SessionCookieValue {
    param(
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$Uri,
        [string]$Name
    )

    if (-not $Session) {
        return $null
    }

    $cookies = $Session.Cookies.GetCookies([System.Uri]$Uri)
    $cookie = $cookies[$Name]
    if ($cookie) {
        return $cookie.Value
    }

    return $null
}

function Get-CsrfHeaders {
    param(
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$Uri
    )

    $csrfToken = Get-SessionCookieValue -Session $Session -Uri $Uri -Name "csrf_token"
    if (-not $csrfToken) {
        return @{}
    }

    return @{ "X-CSRF-Token" = $csrfToken }
}

function Get-AuthFailureMessage {
    param(
        [string]$SelectedGatewayUrl,
        [string]$SelectedDeerFlowUrl,
        [bool]$CredentialsProvided,
        [bool]$AllowAutoInitialize
    )

    $setupUrl = Get-SetupUrl -SelectedDeerFlowUrl $SelectedDeerFlowUrl -SelectedGatewayUrl $SelectedGatewayUrl
    $setupStatus = Get-DeerFlowSetupStatus -SelectedGatewayUrl $SelectedGatewayUrl
    if ($setupStatus -and $setupStatus.needs_setup) {
        if ($CredentialsProvided -and -not $AllowAutoInitialize) {
            return "DeerFlow first-run setup is still pending. Open $setupUrl to create the first admin, or rerun with -AutoInitialize."
        }

        return "DeerFlow first-run setup is still pending. Open $setupUrl to create the first admin, or save credentials with $ConfigureScriptHint, then rerun."
    }

    if (-not $CredentialsProvided) {
        return "DeerFlow requires login for LangGraph access. Set DEERFLOW_EMAIL and DEERFLOW_PASSWORD in this terminal, or run $ConfigureScriptHint to save them once, then rerun."
    }

    return "DeerFlow authentication is required for LangGraph access. Re-enter DEERFLOW_EMAIL and DEERFLOW_PASSWORD, or update them in $ConfigureScriptHint, then rerun."
}

function Get-SetupUrl {
    param(
        [string]$SelectedDeerFlowUrl,
        [string]$SelectedGatewayUrl
    )

    try {
        $uiUri = [System.Uri]$SelectedDeerFlowUrl
        if ($uiUri.Port -eq 8001 -and ($uiUri.Host -eq "localhost" -or $uiUri.Host -eq "127.0.0.1")) {
            return "$($uiUri.Scheme)://localhost:2026/setup"
        }

        return "$($uiUri.AbsoluteUri.TrimEnd('/'))/setup"
    }
    catch {
        return "$SelectedGatewayUrl/setup"
    }
}

function New-DeerFlowSession {
    param(
        [string]$SelectedGatewayUrl,
        [string]$SelectedDeerFlowUrl,
        [string]$SelectedEmail,
        [string]$SelectedPassword,
        [bool]$AllowAutoInitialize
    )

    if (-not $SelectedEmail -or -not $SelectedPassword) {
        return $null
    }

    $setupStatus = Get-DeerFlowSetupStatus -SelectedGatewayUrl $SelectedGatewayUrl
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    if ($setupStatus -and $setupStatus.needs_setup) {
        if (-not $AllowAutoInitialize) {
            Write-Stderr "ERROR: DeerFlow first-run setup is still pending. Open $(Get-SetupUrl -SelectedDeerFlowUrl $SelectedDeerFlowUrl -SelectedGatewayUrl $SelectedGatewayUrl) to create the first admin, or rerun with -AutoInitialize."
            exit 1
        }

        $initializeBody = @{ email = $SelectedEmail; password = $SelectedPassword } | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri "$SelectedGatewayUrl/api/v1/auth/initialize" -Method Post -ContentType "application/json" -Body $initializeBody -WebSession $session | Out-Null
        }
        catch {
            Write-Stderr "ERROR: DeerFlow initialization failed: $(Get-ErrorMessage -ErrorRecord $_)"
            exit 1
        }
    }
    else {
        try {
            Invoke-RestMethod -Uri "$SelectedGatewayUrl/api/v1/auth/login/local" -Method Post -Body @{ username = $SelectedEmail; password = $SelectedPassword } -WebSession $session | Out-Null
        }
        catch {
            Write-Stderr "ERROR: DeerFlow login failed: $(Get-ErrorMessage -ErrorRecord $_)"
            exit 1
        }
    }

    $csrfToken = Get-SessionCookieValue -Session $session -Uri $SelectedGatewayUrl -Name "csrf_token"
    if (-not $csrfToken) {
        Write-Stderr "ERROR: DeerFlow authentication succeeded, but no CSRF cookie was issued."
        exit 1
    }

    return $session
}

function Get-DeerFlowContext {
    param([string]$SelectedMode, [string]$SelectedThreadId)

    switch ($SelectedMode) {
        "flash" {
            return @{ thinking_enabled = $false; is_plan_mode = $false; subagent_enabled = $false; thread_id = $SelectedThreadId }
        }
        "standard" {
            return @{ thinking_enabled = $true; is_plan_mode = $false; subagent_enabled = $false; thread_id = $SelectedThreadId }
        }
        "pro" {
            return @{ thinking_enabled = $true; is_plan_mode = $true; subagent_enabled = $false; thread_id = $SelectedThreadId }
        }
        "ultra" {
            return @{ thinking_enabled = $true; is_plan_mode = $true; subagent_enabled = $true; thread_id = $SelectedThreadId }
        }
    }
}

$LangGraphUrl = if ($RawLangGraphUrl) {
    Normalize-LangGraphUrl -SelectedGatewayUrl $GatewayUrl -ConfiguredLangGraphUrl $RawLangGraphUrl
}
else {
    Get-DefaultLangGraphUrl -BaseUrl $DeerFlowUrl
}

function ConvertFrom-Sse {
    param([string]$Raw)

    $events = New-Object System.Collections.Generic.List[object]
    $currentEvent = $null
    $dataLines = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($Raw -split "`r?`n")) {
        if ($line.StartsWith("event:")) {
            if ($currentEvent -and $dataLines.Count -gt 0) {
                $events.Add([pscustomobject]@{ Event = $currentEvent; Data = ($dataLines -join "`n") })
            }
            $currentEvent = $line.Substring(6).Trim()
            $dataLines.Clear()
        }
        elseif ($line.StartsWith("data:")) {
            $dataLines.Add($line.Substring(5).Trim())
        }
        elseif ([string]::IsNullOrWhiteSpace($line) -and $currentEvent) {
            if ($dataLines.Count -gt 0) {
                $events.Add([pscustomobject]@{ Event = $currentEvent; Data = ($dataLines -join "`n") })
            }
            $currentEvent = $null
            $dataLines.Clear()
        }
    }

    if ($currentEvent -and $dataLines.Count -gt 0) {
        $events.Add([pscustomobject]@{ Event = $currentEvent; Data = ($dataLines -join "`n") })
    }

    return $events
}

function Get-FinalText {
    param($Messages)

    $messageArray = @($Messages)
    [array]::Reverse($messageArray)
    foreach ($item in $messageArray) {
        if ($item.type -eq "tool" -and $item.name -eq "ask_clarification" -and $item.content) {
            return [string]$item.content
        }
        if ($item.type -eq "ai") {
            if ($item.content -is [string] -and $item.content) {
                return $item.content
            }
            if ($item.content -is [array]) {
                $parts = foreach ($block in $item.content) {
                    if ($block -is [string]) {
                        $block
                    }
                    elseif ($block.type -eq "text") {
                        $block.text
                    }
                }
                $text = ($parts -join "")
                if ($text) {
                    return $text
                }
            }
        }
    }
    return ""
}

try {
    Invoke-RestMethod -Uri "$GatewayUrl/health" -Method Get | Out-Null
}
catch {
    Write-Stderr "ERROR: DeerFlow is not reachable at $GatewayUrl. Start DeerFlow first, then retry."
    Write-Stderr "For local mode, run: make dev"
    Write-Stderr "For Docker mode, run: make docker-start"
    exit 1
}

$session = New-DeerFlowSession -SelectedGatewayUrl $GatewayUrl -SelectedDeerFlowUrl $DeerFlowUrl -SelectedEmail $Email -SelectedPassword $Password -AllowAutoInitialize $AutoInitializeRequested

if (-not $ThreadId) {
    $threadRequest = @{
        Uri = "$LangGraphUrl/threads"
        Method = "Post"
        ContentType = "application/json"
        Body = "{}"
    }
    if ($session) {
        $threadRequest.WebSession = $session
        $threadHeaders = Get-CsrfHeaders -Session $session -Uri $GatewayUrl
        if ($threadHeaders.Count -gt 0) {
            $threadRequest.Headers = $threadHeaders
        }
    }

    try {
        $thread = Invoke-RestMethod @threadRequest
    }
    catch {
        $details = Get-ErrorMessage -ErrorRecord $_
        if ($details -match 'CSRF token missing|CSRF token mismatch|Authentication required|Not authenticated|Invalid token') {
            Write-Stderr "ERROR: $(Get-AuthFailureMessage -SelectedGatewayUrl $GatewayUrl -SelectedDeerFlowUrl $DeerFlowUrl -CredentialsProvided $HasCredentials -AllowAutoInitialize $AutoInitializeRequested)"
        }
        else {
            Write-Stderr "ERROR: Failed to create a DeerFlow thread: $details"
        }
        exit 1
    }

    $ThreadId = $thread.thread_id
    if (-not $ThreadId) {
        Write-Stderr "ERROR: Failed to create a DeerFlow thread."
        exit 1
    }
    Write-Stderr "Thread: $ThreadId"
}

$body = @{
    assistant_id = "lead_agent"
    input = @{
        messages = @(
            @{
                type = "human"
                content = @(@{ type = "text"; text = $Message })
            }
        )
    }
    stream_mode = @("values", "messages-tuple")
    stream_subgraphs = $true
    config = @{ recursion_limit = 1000 }
    context = Get-DeerFlowContext -SelectedMode $Mode -SelectedThreadId $ThreadId
} | ConvertTo-Json -Depth 30

try {
    $runRequest = @{
        Uri = "$LangGraphUrl/threads/$ThreadId/runs/wait"
        Method = "Post"
        ContentType = "application/json"
        Body = $body
    }
    if ($session) {
        $runRequest.WebSession = $session
        $runHeaders = Get-CsrfHeaders -Session $session -Uri $GatewayUrl
        if ($runHeaders.Count -gt 0) {
            $runRequest.Headers = $runHeaders
        }
    }

    $response = Invoke-RestMethod @runRequest
}
catch {
    $details = Get-ErrorMessage -ErrorRecord $_
    if ($details -match 'CSRF token missing|CSRF token mismatch|Authentication required|Not authenticated|Invalid token') {
        Write-Stderr "ERROR: $(Get-AuthFailureMessage -SelectedGatewayUrl $GatewayUrl -SelectedDeerFlowUrl $DeerFlowUrl -CredentialsProvided $HasCredentials -AllowAutoInitialize $AutoInitializeRequested)"
    }
    else {
        Write-Stderr "ERROR: DeerFlow run failed: $details"
    }
    exit 1
}

if ($response.messages) {
    $finalText = Get-FinalText -Messages $response.messages
    if ($finalText) {
        Write-Output $finalText
        Write-Output ""
        Write-Stderr "---"
        Write-Stderr "Thread ID: $ThreadId"
        exit 0
    }
}

if ($response.error) {
    Write-Stderr "ERROR from DeerFlow: $($response.error)"
    exit 1
}

Write-Stderr "ERROR: No AI response found in the DeerFlow wait response."
exit 1