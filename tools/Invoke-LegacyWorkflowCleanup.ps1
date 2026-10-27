#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Apply,

    [switch]$SkipReleaseManifest,

    [switch]$SkipValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot

$legacyPrePhase12Directory = Join-Path $repositoryRoot 'archive\legacy-pre-phase12'
$legacyWindowsAdaptersDirectory = Join-Path $repositoryRoot 'archive\legacy-windows-adapters'
$legacyGatesDirectory = Join-Path $repositoryRoot 'archive\legacy-gates'
$futureGitHubActionsDirectory = Join-Path $repositoryRoot 'archive\future-github-actions'

$archiveDirectories = @(
    $legacyPrePhase12Directory
    $legacyWindowsAdaptersDirectory
    $legacyGatesDirectory
    $futureGitHubActionsDirectory
)

$legacyPrePhase12Files = @(
    'bootstrap\os\Enable-PowerShellRemoting.ps1',
    'bootstrap\os\Invoke-SolutionBaseline.ps1',
    'bootstrap\os\Set-DNS.ps1',
    'bootstrap\os\Set-HostName.ps1',
    'bootstrap\os\Set-LocalDeploymentAdministrator.ps1',
    'bootstrap\os\Set-ManagementNetwork.ps1',
    'bootstrap\os\Set-NicRoleMapping.ps1',
    'bootstrap\os\Set-NTP.ps1',
    'bootstrap\os\Test-SolutionBaselineInputs.ps1',
    'config\workflow\stages.yaml',
    'tests\unit\SolutionBaseline.Tests.ps1'
)

$legacyWindowsAdapterFiles = @(
    'adapters\windows\Test-ClusterHealth.ps1',
    'adapters\windows\Test-HostRemoting.ps1',
    'adapters\windows\Test-StorageHealth.ps1'
)

$legacyGateFiles = @(
    'gates\Gate-01-InputValidation.ps1',
    'gates\Gate-02-Preflight.ps1',
    'gates\Gate-03-HCNBootstrap.ps1',
    'gates\Gate-04-AzureLocalValidation.ps1'
)

$futureGitHubWorkflowFiles = @(
    '.github\workflows\onboard-site.yml',
    '.github\workflows\validate-site.yml'
)

$obsoleteAdapterOperations = @(
    'Set-NicRoleMapping',
    'Set-ManagementNetwork',
    'Set-DNS',
    'Set-NTP',
    'Enable-PowerShellRemoting',
    'Set-HostName',
    'Set-LocalDeploymentAdministrator',
    'Invoke-SolutionBaseline',
    'Test-SolutionBaselineInputs'
)

$obsoletePathFragments = @(
    'adapters/windows/Test-ClusterHealth.ps1',
    'adapters/windows/Test-HostRemoting.ps1',
    'adapters/windows/Test-StorageHealth.ps1',
    'bootstrap/os/Enable-PowerShellRemoting.ps1',
    'bootstrap/os/Invoke-SolutionBaseline.ps1',
    'bootstrap/os/Set-DNS.ps1',
    'bootstrap/os/Set-HostName.ps1',
    'bootstrap/os/Set-LocalDeploymentAdministrator.ps1',
    'bootstrap/os/Set-ManagementNetwork.ps1',
    'bootstrap/os/Set-NicRoleMapping.ps1',
    'bootstrap/os/Set-NTP.ps1',
    'bootstrap/os/Test-SolutionBaselineInputs.ps1',
    'config/workflow/stages.yaml',
    'gates/Gate-01-InputValidation.ps1',
    'gates/Gate-02-Preflight.ps1',
    'gates/Gate-03-HCNBootstrap.ps1',
    'gates/Gate-04-AzureLocalValidation.ps1'
)

function Write-CleanupStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ConsoleColor]$Color = [ConsoleColor]::Cyan
    )

    Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] $Message" -ForegroundColor $Color
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return $Path.Substring($repositoryRoot.Length).TrimStart('\', '/')
}

function Test-GitTrackedFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $relativePath = Get-RelativePath -Path $Path

    & git -C $repositoryRoot ls-files --error-unmatch -- $relativePath 2>$null

    return ($LASTEXITCODE -eq 0)
}

function Move-FactoryFileToArchive {
    param(
        [Parameter(Mandatory)]
        [string]$RelativeSourcePath,

        [Parameter(Mandatory)]
        [string]$ArchiveDirectory
    )

    $sourcePath = Join-Path $repositoryRoot $RelativeSourcePath

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Write-CleanupStatus `
            -Message "SKIP: $RelativeSourcePath does not exist." `
            -Color Yellow
        return
    }

    $destinationPath = Join-Path `
        $ArchiveDirectory `
        (Split-Path -Leaf $sourcePath)

    if (Test-Path -LiteralPath $destinationPath) {
        throw (
            "Archive destination already exists: $destinationPath. " +
            'Resolve the duplicate before continuing.'
        )
    }

    if (-not $Apply) {
        Write-CleanupStatus `
            -Message "PLAN: Archive $RelativeSourcePath -> $(Get-RelativePath -Path $destinationPath)" `
            -Color Yellow
        return
    }

    if (-not $PSCmdlet.ShouldProcess(
            $RelativeSourcePath,
            "Archive to $(Get-RelativePath -Path $destinationPath)"
        )
    ) {
        return
    }

    if (Test-GitTrackedFile -Path $sourcePath) {
        $relativeDestinationDirectory = Get-RelativePath -Path $ArchiveDirectory

        & git `
            -C $repositoryRoot `
            mv `
            -- `
            $RelativeSourcePath `
            $relativeDestinationDirectory

        if ($LASTEXITCODE -ne 0) {
            throw "git mv failed for $RelativeSourcePath."
        }
    }
    else {
        Move-Item `
            -LiteralPath $sourcePath `
            -Destination $destinationPath `
            -ErrorAction Stop
    }

    Write-CleanupStatus `
        -Message "ARCHIVED: $RelativeSourcePath" `
        -Color Green
}

function Update-TextFile {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [scriptblock]$Transform
    )

    $path = Join-Path $repositoryRoot $RelativePath

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-CleanupStatus `
            -Message "SKIP: $RelativePath does not exist." `
            -Color Yellow
        return
    }

    $originalContent = Get-Content -LiteralPath $path -Raw
    $updatedContent = & $Transform $originalContent

    if ($updatedContent -eq $originalContent) {
        Write-CleanupStatus `
            -Message "NO CHANGE: $RelativePath" `
            -Color DarkGray
        return
    }

    if (-not $Apply) {
        Write-CleanupStatus `
            -Message "PLAN: Update $RelativePath" `
            -Color Yellow
        return
    }

    if ($PSCmdlet.ShouldProcess($RelativePath, 'Update legacy workflow references')) {
        Set-Content `
            -LiteralPath $path `
            -Value $updatedContent `
            -NoNewline `
            -Encoding utf8

        Write-CleanupStatus `
            -Message "UPDATED: $RelativePath" `
            -Color Green
    }
}

function Add-SupersessionNotice {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath,

        [Parameter(Mandatory)]
        [string]$NoticeTitle,

        [Parameter(Mandatory)]
        [string]$NoticeBody
    )

    Update-TextFile `
        -RelativePath $RelativePath `
        -Transform {
            param($Content)

            if ($Content -match [regex]::Escape($NoticeTitle)) {
                return $Content
            }

            $notice = @"

## $NoticeTitle

$NoticeBody
"@

            return $Content.TrimEnd() + "`r`n" + $notice
        }
}

Write-Host ''
Write-Host 'Azure Local Legacy Workflow Cleanup' -ForegroundColor Cyan
Write-Host ''

if (-not $Apply) {
    Write-CleanupStatus `
        -Message 'PLAN MODE: No files will be changed. Re-run with -Apply to execute.' `
        -Color Yellow
}

foreach ($directory in $archiveDirectories) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        if ($Apply) {
            New-Item `
                -ItemType Directory `
                -Path $directory `
                -Force | Out-Null

            Write-CleanupStatus `
                -Message "CREATED: $(Get-RelativePath -Path $directory)" `
                -Color Green
        }
        else {
            Write-CleanupStatus `
                -Message "PLAN: Create $(Get-RelativePath -Path $directory)" `
                -Color Yellow
        }
    }
}

# Remove obsolete operation mappings from the protected adapter catalog.
Update-TextFile `
    -RelativePath 'protected\adapters.yaml' `
    -Transform {
        param($Content)

        $operationsPattern = (
            $obsoleteAdapterOperations |
                ForEach-Object { [regex]::Escape($_) }
        ) -join '|'

        return [regex]::Replace(
            $Content,
            "(?m)^\s*(?:$operationsPattern)\s*:\s*.*(?:\r?\n)?",
            ''
        )
    }

# Remove legacy expected paths from the prior build-integrity test.
Update-TextFile `
    -RelativePath 'preflight\Test-BuildScriptIntegrity.ps1' `
    -Transform {
        param($Content)

        $filteredLines = foreach ($line in ($Content -split "`r?`n")) {
            $isLegacyLine = $false

            foreach ($fragment in $obsoletePathFragments) {
                if ($line -match [regex]::Escape($fragment)) {
                    $isLegacyLine = $true
                    break
                }
            }

            if (-not $isLegacyLine) {
                $line
            }
        }

        return ($filteredLines -join "`r`n")
    }

# Remove archived files from the plain-text repository inventory.
Update-TextFile `
    -RelativePath 'FILE-MANIFEST.md' `
    -Transform {
        param($Content)

        $filteredLines = foreach ($line in ($Content -split "`r?`n")) {
            $normalizedLine = $line.Replace('\', '/')
            $isLegacyLine = $false

            foreach ($fragment in $obsoletePathFragments) {
                if ($normalizedLine -match [regex]::Escape($fragment)) {
                    $isLegacyLine = $true
                    break
                }
            }

            if (-not $isLegacyLine) {
                $line
            }
        }

        return ($filteredLines -join "`r`n")
    }

# Archive the legacy implementation files.
foreach ($file in $legacyPrePhase12Files) {
    Move-FactoryFileToArchive `
        -RelativeSourcePath $file `
        -ArchiveDirectory $legacyPrePhase12Directory
}

foreach ($file in $legacyWindowsAdapterFiles) {
    Move-FactoryFileToArchive `
        -RelativeSourcePath $file `
        -ArchiveDirectory $legacyWindowsAdaptersDirectory
}

foreach ($file in $legacyGateFiles) {
    Move-FactoryFileToArchive `
        -RelativeSourcePath $file `
        -ArchiveDirectory $legacyGatesDirectory
}

foreach ($file in $futureGitHubWorkflowFiles) {
    Move-FactoryFileToArchive `
        -RelativeSourcePath $file `
        -ArchiveDirectory $futureGitHubActionsDirectory
}

# Update documentation with a clear authoritative-workflow statement.
Add-SupersessionNotice `
    -RelativePath 'docs\adapter-contract.md' `
    -NoticeTitle 'Current Workflow Supersession' `
    -NoticeBody (
        'The current deployment workflow is manifest-driven. ' +
        'Authoritative operation mappings are maintained in `protected/adapters.yaml`; ' +
        'stage sequencing is maintained in `protected/phase-manifest.yaml`. ' +
        'Legacy `adapters/windows` mappings were archived and are not part of the active package.'
    )

Add-SupersessionNotice `
    -RelativePath 'docs\failure-catalog.md' `
    -NoticeTitle 'Current Remediation Model' `
    -NoticeBody (
        'Legacy imperative `Set-*` remediation scripts were superseded by idempotent `Ensure-*` adapters. ' +
        'Current adapters validate desired state, skip compliant settings, request approval before disruptive changes, ' +
        'and block mutation on existing or registered Azure Local clusters.'
    )

Add-SupersessionNotice `
    -RelativePath 'docs\REPOSITORY-LAYOUT.md' `
    -NoticeTitle 'Current Workflow Layout' `
    -NoticeBody (
        'The active workflow uses `protected/phase-manifest.yaml`, `protected/adapters.yaml`, `controller/`, ' +
        '`launcher/`, `preflight/`, and `bootstrap/os/Ensure-*`. ' +
        'Legacy numbered gate scripts, generic Windows adapters, and imperative setter scripts are archived under `archive/`.'
    )

Add-SupersessionNotice `
    -RelativePath 'docs\github-actions.md' `
    -NoticeTitle 'Current Execution Model' `
    -NoticeBody (
        'GitHub Actions is not part of the current operator workflow. ' +
        'The active execution path is the local deployment manager launched through `Run-AzureLocalDeploymentManager.cmd`. ' +
        'GitHub Actions workflow drafts are retained only as archived future-reference material.'
    )

Add-SupersessionNotice `
    -RelativePath 'IMPLEMENTATION-STATUS.md' `
    -NoticeTitle 'Legacy Workflow Archive' `
    -NoticeBody (
        'The legacy gate, baseline, generic adapter, and imperative setter workflow was archived. ' +
        'Phase 1.1 and 1.2 now use the manifest-driven idempotent `Ensure-*` workflow and approval/pause/resume state model.'
    )

if (-not $SkipReleaseManifest) {
    if (-not $Apply) {
        Write-CleanupStatus `
            -Message 'PLAN: Regenerate protected/release-manifest.json.' `
            -Color Yellow
    }
    else {
        Write-CleanupStatus `
            -Message 'Regenerating protected/release-manifest.json...' `
            -Color Cyan

        Push-Location $repositoryRoot

        try {
            & '.\tools\New-ReleaseManifest.ps1'

            if ($LASTEXITCODE -ne 0) {
                throw "New-ReleaseManifest.ps1 returned exit code $LASTEXITCODE."
            }
        }
        finally {
            Pop-Location
        }

        Write-CleanupStatus `
            -Message 'REGENERATED: protected/release-manifest.json' `
            -Color Green
    }
}

if (-not $SkipValidation) {
    if (-not $Apply) {
        Write-CleanupStatus `
            -Message 'PLAN: Run Phase 1.1/1.2 and Batch 2B readiness audits.' `
            -Color Yellow
    }
    else {
        Push-Location $repositoryRoot

        try {
            Write-CleanupStatus `
                -Message 'Running Phase 1.1 / 1.2 adapter readiness audit...' `
                -Color Cyan

            & '.\tools\Test-Phase12AdapterReadiness.ps1'

            Write-CleanupStatus `
                -Message 'Running Batch 2B approval-engine readiness audit...' `
                -Color Cyan

            & '.\tools\Test-Batch2BApprovalEngineReadiness.ps1' `
                -RunApprovalSimulation
        }
        finally {
            Pop-Location
        }
    }
}

Write-Host ''

if ($Apply) {
    $completionMessage = 'Cleanup completed. Review git status and git diff before committing.'
}
else {
    $completionMessage = 'Plan completed. Review planned actions, then re-run with -Apply.'
}

Write-CleanupStatus `
    -Message $completionMessage `
    -Color Green