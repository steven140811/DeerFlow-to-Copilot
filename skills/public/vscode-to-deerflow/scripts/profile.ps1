function Get-VSCodeToDeerFlowProfilePath {
    $appData = if ($env:APPDATA) {
        $env:APPDATA
    }
    else {
        [Environment]::GetFolderPath("ApplicationData")
    }

    return Join-Path $appData "DeerFlow\vscode-to-deerflow.profile.json"
}

function ConvertTo-ProtectedString {
    param([string]$Value)

    if (-not $Value) {
        return ""
    }

    $secure = ConvertTo-SecureString -String $Value -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secure
}

function ConvertFrom-ProtectedString {
    param([string]$Value)

    if (-not $Value) {
        return ""
    }

    try {
        $secure = ConvertTo-SecureString -String $Value
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            if ($bstr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
    }
    catch {
        return ""
    }
}

function Get-VSCodeToDeerFlowProfile {
    $path = Get-VSCodeToDeerFlowProfilePath
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            DeerFlowUrl = ""
            DeerFlowEmail = ""
            DeerFlowPassword = ""
            AutoInitialize = $false
            ProfilePath = $path
        }
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            DeerFlowUrl = ""
            DeerFlowEmail = ""
            DeerFlowPassword = ""
            AutoInitialize = $false
            ProfilePath = $path
        }
    }

    return [pscustomobject]@{
        DeerFlowUrl = [string]($raw.deerflow_url ?? "")
        DeerFlowEmail = [string]($raw.email ?? "")
        DeerFlowPassword = ConvertFrom-ProtectedString -Value ([string]($raw.password_encrypted ?? ""))
        AutoInitialize = [bool]($raw.auto_initialize ?? $false)
        ProfilePath = $path
    }
}

function Save-VSCodeToDeerFlowProfile {
    param(
        [string]$DeerFlowUrl,
        [string]$DeerFlowEmail,
        [string]$DeerFlowPassword,
        [bool]$AutoInitialize
    )

    $path = Get-VSCodeToDeerFlowProfilePath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $payload = [pscustomobject]@{
        deerflow_url = ($DeerFlowUrl ?? "").Trim()
        email = ($DeerFlowEmail ?? "").Trim()
        password_encrypted = ConvertTo-ProtectedString -Value ($DeerFlowPassword ?? "")
        auto_initialize = $AutoInitialize
        saved_at = (Get-Date).ToString("o")
    }

    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Remove-VSCodeToDeerFlowProfile {
    $path = Get-VSCodeToDeerFlowProfilePath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
    return $path
}