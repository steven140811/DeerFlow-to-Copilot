param(
    [switch]$Reset
)

$ErrorActionPreference = "Stop"

if (
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA -and
    -not $env:DEERFLOW_VSCODE_CONFIG_STA
) {
    $env:DEERFLOW_VSCODE_CONFIG_STA = "1"
    $pwsh = (Get-Process -Id $PID).Path
    $args = @("-STA", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
    if ($Reset) {
        $args += "-Reset"
    }
    & $pwsh @args
    exit $LASTEXITCODE
}

. (Join-Path $PSScriptRoot "profile.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ($Reset) {
    $removedPath = Remove-VSCodeToDeerFlowProfile
    [System.Windows.Forms.MessageBox]::Show(
        "Saved vscode-to-deerflow config was removed.`n`n$removedPath",
        "DeerFlow Config Reset",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
}

$profile = Get-VSCodeToDeerFlowProfile

$form = New-Object System.Windows.Forms.Form
$form.Text = "Configure VS Code to DeerFlow"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(620, 320)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$labelWidth = 150
$inputLeft = 170
$inputWidth = 410

function Get-NormalizedDeerFlowUrl {
    $target = ($urlText.Text ?? "http://localhost:2026").Trim()
    if (-not $target) {
        $target = "http://localhost:2026"
    }
    return $target.TrimEnd("/")
}

function Open-DeerFlowTarget {
    param([string[]]$Candidates)

    $baseUrl = Get-NormalizedDeerFlowUrl
    foreach ($candidate in $Candidates) {
        $target = if ([string]::IsNullOrWhiteSpace($candidate)) {
            $baseUrl
        }
        else {
            "$baseUrl/$($candidate.TrimStart('/'))"
        }

        try {
            $response = Invoke-WebRequest -Uri $target -SkipHttpErrorCheck -TimeoutSec 3
            if ([int]$response.StatusCode -lt 400) {
                Start-Process $target | Out-Null
                return
            }
        }
        catch {
        }
    }

    Start-Process $baseUrl | Out-Null
}

function New-ConfigLabel {
    param([string]$Text, [int]$Top)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Left = 20
    $label.Top = $Top
    $label.Width = $labelWidth
    $label.Font = $font
    return $label
}

function New-ConfigTextBox {
    param([string]$Value, [int]$Top, [bool]$IsPassword = $false)
    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Left = $inputLeft
    $textBox.Top = $Top - 3
    $textBox.Width = $inputWidth
    $textBox.Text = $Value
    $textBox.Font = $font
    if ($IsPassword) {
        $textBox.UseSystemPasswordChar = $true
    }
    return $textBox
}

$description = New-Object System.Windows.Forms.Label
$description.Text = "Use DeerFlow's browser UI at http://localhost:2026 for visual chat. This dialog only saves local helper config for chat.ps1 and the self-check script."
$description.Left = 20
$description.Top = 16
$description.Width = 560
$description.Height = 42
$description.Font = $font

$urlLabel = New-ConfigLabel -Text "DeerFlow URL" -Top 70
$urlText = New-ConfigTextBox -Value ($profile.DeerFlowUrl ? $profile.DeerFlowUrl : "http://localhost:2026") -Top 70

$emailLabel = New-ConfigLabel -Text "Login email" -Top 110
$emailText = New-ConfigTextBox -Value $profile.DeerFlowEmail -Top 110

$passwordLabel = New-ConfigLabel -Text "Login password" -Top 150
$passwordText = New-ConfigTextBox -Value $profile.DeerFlowPassword -Top 150 -IsPassword $true

$autoInitialize = New-Object System.Windows.Forms.CheckBox
$autoInitialize.Left = $inputLeft
$autoInitialize.Top = 188
$autoInitialize.Width = 320
$autoInitialize.Text = "Auto-initialize first admin on first boot"
$autoInitialize.Checked = [bool]$profile.AutoInitialize
$autoInitialize.Font = $font

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Saved password is encrypted with Windows DPAPI and only readable by the current Windows user."
$hint.Left = 20
$hint.Top = 215
$hint.Width = 560
$hint.Height = 20
$hint.Font = $font

$openUiButton = New-Object System.Windows.Forms.Button
$openUiButton.Text = "Open DeerFlow UI"
$openUiButton.Left = 20
$openUiButton.Top = 245
$openUiButton.Width = 120
$openUiButton.Add_Click({
    Open-DeerFlowTarget -Candidates @("")
})

$openLoginButton = New-Object System.Windows.Forms.Button
$openLoginButton.Text = "Open Login UI"
$openLoginButton.Left = 150
$openLoginButton.Top = 245
$openLoginButton.Width = 110
$openLoginButton.Add_Click({
    Open-DeerFlowTarget -Candidates @("login", "")
})

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Save"
$saveButton.Left = 390
$saveButton.Top = 245
$saveButton.Width = 90
$saveButton.DialogResult = [System.Windows.Forms.DialogResult]::OK

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "Cancel"
$cancelButton.Left = 490
$cancelButton.Top = 245
$cancelButton.Width = 90
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

$form.Controls.AddRange(@(
    $description,
    $urlLabel,
    $urlText,
    $emailLabel,
    $emailText,
    $passwordLabel,
    $passwordText,
    $autoInitialize,
    $hint,
    $openUiButton,
    $openLoginButton,
    $saveButton,
    $cancelButton
))

$form.AcceptButton = $saveButton
$form.CancelButton = $cancelButton

if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    exit 0
}

$savedPath = Save-VSCodeToDeerFlowProfile \
    -DeerFlowUrl ($urlText.Text ?? "") \
    -DeerFlowEmail ($emailText.Text ?? "") \
    -DeerFlowPassword ($passwordText.Text ?? "") \
    -AutoInitialize $autoInitialize.Checked

[System.Windows.Forms.MessageBox]::Show(
    "Saved vscode-to-deerflow config.`n`n$savedPath`n`nchat.ps1 and check-deerflow-copilot-bridge.ps1 will use it automatically.",
    "DeerFlow Config Saved",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null