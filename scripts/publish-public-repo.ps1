<#
.SYNOPSIS
Publishes the current repository snapshot to the public GitHub mirror as a single-author branch.

.DESCRIPTION
This helper keeps local engineering history intact on the working branch. It creates or reuses
an orphan-style publish commit from a source ref's Git tree, updates a dedicated local publish
branch, and force-pushes that commit to the public remote branch.

Because the publish commit is built directly from Git's tree object, the published repository
contents match the chosen source ref exactly.

.EXAMPLE
pwsh -ExecutionPolicy Bypass -File .\scripts\publish-public-repo.ps1 -DryRun

.EXAMPLE
pwsh -ExecutionPolicy Bypass -File .\scripts\publish-public-repo.ps1 -SourceRef HEAD
#>

[CmdletBinding()]
param(
    [string]$SourceRef = "HEAD",

    [string]$PublishBranch = "public-release",

    [string]$RemoteName = "steven",

    [string]$RemoteBranch = "main",

    [string]$CommitMessage = "",

    [switch]$DryRun,

    [switch]$SkipWorkingTreeCheck
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path $PSScriptRoot -Parent

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

function Invoke-Git {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Args
    )

    $output = & git -C $RepoRoot @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $commandText = $Args -join " "
        $errorText = ($output | Out-String).Trim()
        throw "git $commandText failed.`n$errorText"
    }

    return ($output | Out-String).Trim()
}

function Get-OptionalGitValue {
    param([string[]]$Args)

    try {
        return Invoke-Git @Args
    }
    catch {
        return $null
    }
}

Write-Step "Preparing public snapshot publish workflow"

if (-not $SkipWorkingTreeCheck) {
    $workingTreeStatus = Invoke-Git status --short
    if ($workingTreeStatus) {
        throw "Working tree is not clean. Commit or stash changes before publishing, or pass -SkipWorkingTreeCheck if you really need to bypass this guard."
    }
}

$remoteUrl = Invoke-Git remote get-url $RemoteName
$authorName = Invoke-Git config user.name
$authorEmail = Invoke-Git config user.email

if (-not $authorName -or -not $authorEmail) {
    throw "Git user.name and user.email must be configured before publishing."
}

$sourceCommit = Invoke-Git rev-parse $SourceRef
$sourceTree = Invoke-Git rev-parse "$SourceRef^{tree}"
$publishRef = "refs/heads/$PublishBranch"

$existingPublishCommit = Get-OptionalGitValue rev-parse --verify $publishRef
$existingPublishTree = $null
if ($existingPublishCommit) {
    $existingPublishTree = Invoke-Git rev-parse "$existingPublishCommit^{tree}"
}

$publishCommit = $existingPublishCommit
$reusedExistingCommit = $false

if ($existingPublishTree -and $existingPublishTree -eq $sourceTree) {
    $reusedExistingCommit = $true
    Write-Info "Reusing existing $PublishBranch commit because its tree already matches $SourceRef."
}
else {
    if (-not $CommitMessage) {
        $CommitMessage = @"
feat: publish public snapshot from $sourceCommit

Source-Ref: $SourceRef
Source-Commit: $sourceCommit
"@.Trim()
    }

    $previousAuthorName = $env:GIT_AUTHOR_NAME
    $previousAuthorEmail = $env:GIT_AUTHOR_EMAIL
    $previousCommitterName = $env:GIT_COMMITTER_NAME
    $previousCommitterEmail = $env:GIT_COMMITTER_EMAIL

    try {
        $env:GIT_AUTHOR_NAME = $authorName
        $env:GIT_AUTHOR_EMAIL = $authorEmail
        $env:GIT_COMMITTER_NAME = $authorName
        $env:GIT_COMMITTER_EMAIL = $authorEmail

        $publishCommitOutput = $CommitMessage | & git -C $RepoRoot commit-tree $sourceTree 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errorText = ($publishCommitOutput | Out-String).Trim()
            throw "git commit-tree failed.`n$errorText"
        }

        $publishCommit = ($publishCommitOutput | Out-String).Trim()
    }
    finally {
        $env:GIT_AUTHOR_NAME = $previousAuthorName
        $env:GIT_AUTHOR_EMAIL = $previousAuthorEmail
        $env:GIT_COMMITTER_NAME = $previousCommitterName
        $env:GIT_COMMITTER_EMAIL = $previousCommitterEmail
    }

    $publishTree = Invoke-Git rev-parse "$publishCommit^{tree}"
    if ($publishTree -ne $sourceTree) {
        throw "Generated publish commit tree does not match the source tree. Aborting publish."
    }
}

Write-Info "Source ref: $SourceRef"
Write-Info "Source commit: $sourceCommit"
Write-Info "Source tree: $sourceTree"
Write-Info "Publish branch: $PublishBranch"
Write-Info "Publish commit: $publishCommit"
Write-Info "Remote target: $RemoteName/$RemoteBranch ($remoteUrl)"

if ($DryRun) {
    Write-Ok "Dry run complete. No refs were updated and nothing was pushed."
    return
}

Invoke-Git update-ref $publishRef $publishCommit
Invoke-Git config "branch.$PublishBranch.remote" $RemoteName
Invoke-Git config "branch.$PublishBranch.merge" "refs/heads/$RemoteBranch"

$pushRefSpec = "{0}:refs/heads/{1}" -f $publishCommit, $RemoteBranch
$pushOutput = & git -C $RepoRoot push $RemoteName $pushRefSpec --force 2>&1
if ($LASTEXITCODE -ne 0) {
    $errorText = ($pushOutput | Out-String).Trim()
    throw "git push failed.`n$errorText"
}

$remoteRefLine = Invoke-Git ls-remote $RemoteName "refs/heads/$RemoteBranch"
$remoteCommit = ($remoteRefLine -split '\s+')[0]
if ($remoteCommit -ne $publishCommit) {
    throw "Remote verification failed. Expected $publishCommit but $RemoteName/$RemoteBranch points to $remoteCommit."
}

if ($reusedExistingCommit) {
    Write-Ok "Public branch already matched the current source tree. Remote verification still passed."
}
else {
    Write-Ok "Published exact source snapshot to $RemoteName/$RemoteBranch with single-author history."
}
