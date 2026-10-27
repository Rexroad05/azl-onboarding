#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigValue {
    param(
        [Parameter(Mandatory)] [object]$Object,
        [Parameter(Mandatory)] [string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $output = @(
        & git -C $RepositoryRoot @Arguments 2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw (
            "Git command failed: git $($Arguments -join ' '). " +
            ($output -join '; ')
        )
    }

    return @($output)
}

$config = Get-ConfigValue -Object $Context -Name 'Config'
$root = [string](Get-ConfigValue -Object $Context -Name 'Root')

if ($null -eq $config) {
    throw 'Factory context does not contain Config.'
}

if ([string]::IsNullOrWhiteSpace($root)) {
    throw 'Factory context does not contain Root.'
}

$repositoryRoot = [IO.Path]::GetFullPath($root)
if ($null -eq (Get-Command -Name git -ErrorAction SilentlyContinue)) {
    throw 'Repository integrity validation requires Git on the automation controller.'
}

$gitRootOutput = @(
    & git -C $repositoryRoot rev-parse --show-toplevel 2>&1
)

if ($LASTEXITCODE -ne 0) {
    throw (
        "Repository integrity validation requires a Git worktree. " +
        "Git did not recognize this path: $repositoryRoot"
    )
}

$gitRepositoryRoot = (
    $gitRootOutput |
        Select-Object -First 1
).Trim()

if ([string]::IsNullOrWhiteSpace($gitRepositoryRoot)) {
    throw "Unable to determine the Git repository root for: $repositoryRoot"
}

$requiredFiles = @(
    'controller/Factory.psm1',
    'controller/Invoke-AzureLocalFactory.ps1',
    'controller/Invoke-Stage.ps1',
    'controller/Invoke-ValidationGate.ps1',
    'bootstrap/discovery/Test-BootstrapNetwork.ps1',
    'bootstrap/discovery/Find-iDRAC.ps1',
    'azure/registration/Invoke-AzureLocalArcInitialization.ps1',
    'azure/registration/Register-ArcNode.ps1',
    'environments/NRFT.yaml',
)

$errors = [System.Collections.Generic.List[string]]::new()
$fileHashes = [ordered]@{}

foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path $repositoryRoot $relativePath

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $errors.Add("Required immutable Phase 1 file is missing: $relativePath")
        continue
    }

    $fileHashes[$relativePath] = (
        Get-FileHash -LiteralPath $fullPath -Algorithm SHA256
    ).Hash
}

if ($errors.Count -gt 0) {
    throw ("Build script integrity validation failed:`n - " + ($errors -join "`n - "))
}

$commit = (
    Invoke-Git `
        -Arguments @('rev-parse', 'HEAD') `
        -RepositoryRoot $repositoryRoot |
    Select-Object -First 1
).Trim()

if ([string]::IsNullOrWhiteSpace($commit)) {
    throw 'Git commit SHA could not be determined.'
}

$status = @(
    Invoke-Git `
        -Arguments @('status', '--porcelain', '--untracked-files=all') `
        -RepositoryRoot $repositoryRoot
)

if ($status.Count -gt 0) {
    throw (
        'Repository contains uncommitted or untracked files. ' +
        'Phase 1 Apply requires an immutable clean worktree.'
    )
}

$githubSha = [Environment]::GetEnvironmentVariable('GITHUB_SHA')

if (
    -not [string]::IsNullOrWhiteSpace($githubSha) -and
    -not $commit.StartsWith($githubSha, [System.StringComparison]::OrdinalIgnoreCase) -and
    -not $githubSha.StartsWith($commit, [System.StringComparison]::OrdinalIgnoreCase)
) {
    throw (
        "GitHub workflow commit mismatch. GITHUB_SHA=$githubSha; " +
        "worktree commit=$commit."
    )
}

$runDirectory = [string](Get-ConfigValue -Object $Context -Name 'RunDirectory')

if (-not [string]::IsNullOrWhiteSpace($runDirectory)) {
    $evidenceDirectory = Join-Path $runDirectory 'evidence'
    New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null

    $evidence = [ordered]@{
        site        = $config.site.name
        cluster     = $config.cluster.name
        commit      = $commit
        validatedAt = [datetime]::UtcNow.ToString('o')
        fileHashes  = $fileHashes
    }

    $evidencePath = Join-Path $evidenceDirectory 'phase1-code-integrity.json'

    $evidence |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $evidencePath -Encoding utf8
}

[pscustomobject]@{
    Passed         = $true
    Check          = 'Test-BuildScriptIntegrity'
    Commit         = $commit
    ValidatedFiles = $fileHashes.Count
    ValidatedAt    = [datetime]::UtcNow.ToString('o')
}