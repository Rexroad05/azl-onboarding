#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$PackageRoot = (
        [IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..')
        )
    ),

    [switch]$RunApprovalSimulation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredFiles = @(
    'controller\Factory.psm1',
    'controller\Invoke-Stage.ps1',
    'controller\Invoke-AzureLocalFactory.ps1',
    'state\state.schema.json',
    'launcher\Set-DeploymentApproval.ps1',
    'launcher\Start-AzureLocalDeploymentManager.ps1',
    'launcher\Get-DeploymentManagerStatus.ps1'
)

$results = [System.Collections.Generic.List[object]]::new()

function Add-ReadinessResult {
    param(
        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [bool]$Passed,

        [Parameter(Mandatory)]
        [string]$Details
    )

    $results.Add([pscustomobject]@{
        Check   = $Check
        Passed  = $Passed
        Details = $Details
    })
}

function Test-FileSyntax {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $tokens = $null
    $errors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null

    return @($errors)
}

function Get-MissingPatterns {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Patterns
    )

    $content = Get-Content `
        -LiteralPath $Path `
        -Raw

    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($pattern in $Patterns) {
        if ($content -notmatch [regex]::Escape($pattern)) {
            $missing.Add($pattern)
        }
    }

    return @($missing.ToArray())
}

foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path $PackageRoot $relativePath

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Add-ReadinessResult `
            -Check "File Exists: $relativePath" `
            -Passed $false `
            -Details "Missing file: $fullPath"

        continue
    }

    Add-ReadinessResult `
        -Check "File Exists: $relativePath" `
        -Passed $true `
        -Details 'Present'

    if ($fullPath -match '\.(ps1|psm1)$') {
        $syntaxErrors = @(
            Test-FileSyntax -Path $fullPath
        )

        if ($syntaxErrors.Count -eq 0) {
            $syntaxPassed = $true
            $syntaxDetails = 'PowerShell syntax valid'
        }
        else {
            $syntaxPassed = $false
            $syntaxDetails = (
                $syntaxErrors |
                    ForEach-Object {
                        $_.Message
                    }
            ) -join '; '
        }

        Add-ReadinessResult `
            -Check "Syntax: $relativePath" `
            -Passed $syntaxPassed `
            -Details $syntaxDetails
    }
}

$factoryPath = Join-Path $PackageRoot 'controller\Factory.psm1'
$invokeStagePath = Join-Path $PackageRoot 'controller\Invoke-Stage.ps1'
$invokeFactoryPath = Join-Path $PackageRoot 'controller\Invoke-AzureLocalFactory.ps1'
$stateSchemaPath = Join-Path $PackageRoot 'state\state.schema.json'
$setApprovalPath = Join-Path $PackageRoot 'launcher\Set-DeploymentApproval.ps1'
$managerPath = Join-Path $PackageRoot 'launcher\Start-AzureLocalDeploymentManager.ps1'
$statusPath = Join-Path $PackageRoot 'launcher\Get-DeploymentManagerStatus.ps1'

if (Test-Path -LiteralPath $factoryPath -PathType Leaf) {
    $missing = @(
        Get-MissingPatterns `
            -Path $factoryPath `
            -Patterns @(
                '$adapterContext.Operation = $Operation',
                'Ensure-ManagementVlan',
                'Ensure-ManagementNetwork',
                'Ensure-StorageNetwork',
                'Ensure-IPv6Baseline',
                'Ensure-HostName'
            )
    )

    if ($missing.Count -eq 0) {
        $passed = $true
        $details = 'Adapter operation context and Batch 2B catalog entries found.'
    }
    else {
        $passed = $false
        $details = "Missing Factory patterns: $($missing -join ', ')"
    }

    Add-ReadinessResult `
        -Check 'Factory Adapter Context and Batch 2B Catalog' `
        -Passed $passed `
        -Details $details
}

if (Test-Path -LiteralPath $invokeStagePath -PathType Leaf) {
    $missing = @(
        Get-MissingPatterns `
            -Path $invokeStagePath `
            -Patterns @(
                'RequiresApproval',
                'PendingApproval',
                'Paused = $true',
                "'PAUSED'"
            )
    )

    if ($missing.Count -eq 0) {
        $passed = $true
        $details = 'Stage runner pause/approval detection found.'
    }
    else {
        $passed = $false
        $details = "Missing Invoke-Stage patterns: $($missing -join ', ')"
    }

    Add-ReadinessResult `
        -Check 'Invoke-Stage Pause Detection' `
        -Passed $passed `
        -Details $details
}

if (Test-Path -LiteralPath $invokeFactoryPath -PathType Leaf) {
    $missing = @(
        Get-MissingPatterns `
            -Path $invokeFactoryPath `
            -Patterns @(
                '$state.status = ''PAUSED''',
                '$state.pendingApproval = $stageResult.PendingApproval',
                '$state.status -eq ''PAUSED''',
                '$state.status -eq ''APPROVED''',
                'approvedOperations = @{}'
            )
    )

    if ($missing.Count -eq 0) {
        $passed = $true
        $details = 'Factory pause, approval, and resume state handling found.'
    }
    else {
        $passed = $false
        $details = "Missing factory state patterns: $($missing -join ', ')"
    }

    Add-ReadinessResult `
        -Check 'Factory Pause and Resume State' `
        -Passed $passed `
        -Details $details
}

if (Test-Path -LiteralPath $stateSchemaPath -PathType Leaf) {
    try {
        $schema = Get-Content `
            -LiteralPath $stateSchemaPath `
            -Raw |
            ConvertFrom-Json `
            -AsHashtable

        $schemaText = $schema |
            ConvertTo-Json `
            -Depth 30

        $requiredSchemaValues = @(
            'PAUSED',
            'APPROVED',
            'DENIED',
            'approvedOperations',
            'pendingApproval'
        )

        $missing = @(
            $requiredSchemaValues |
                Where-Object {
                    $schemaText -notmatch [regex]::Escape($_)
                }
        )

        if ($missing.Count -eq 0) {
            $passed = $true
            $details = (
                'State schema supports PAUSED, APPROVED, DENIED, ' +
                'approvedOperations, and pendingApproval.'
            )
        }
        else {
            $passed = $false
            $details = "Missing state schema values: $($missing -join ', ')"
        }
    }
    catch {
        $passed = $false
        $details = $_.Exception.Message
    }

    Add-ReadinessResult `
        -Check 'State Schema Pause and Approval Support' `
        -Passed $passed `
        -Details $details
}

if (Test-Path -LiteralPath $managerPath -PathType Leaf) {
    $missing = @(
        Get-MissingPatterns `
            -Path $managerPath `
            -Patterns @(
                'Approve Pending Configuration Change',
                'Deny Pending Configuration Change',
                'Resume Approved Workflow',
                'Set-DeploymentApproval.ps1',
                '-Resume'
            )
    )

    if ($missing.Count -eq 0) {
        $passed = $true
        $details = 'Approve, deny, and resume menu logic found.'
    }
    else {
        $passed = $false
        $details = "Missing manager menu patterns: $($missing -join ', ')"
    }

    Add-ReadinessResult `
        -Check 'Deployment Manager Approval Menu' `
        -Passed $passed `
        -Details $details
}

if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
    $missing = @(
        Get-MissingPatterns `
            -Path $statusPath `
            -Patterns @(
                "'PAUSED'",
                "'APPROVED'",
                "'DENIED'",
                'PendingApproval'
            )
    )

    if ($missing.Count -eq 0) {
        $passed = $true
        $details = (
            'Status logic supports PAUSED, APPROVED, DENIED, ' +
            'and pending approval.'
        )
    }
    else {
        $passed = $false
        $details = "Missing status patterns: $($missing -join ', ')"
    }

    Add-ReadinessResult `
        -Check 'Deployment Manager Status Approval Support' `
        -Passed $passed `
        -Details $details
}

if ($RunApprovalSimulation) {
    if (-not (Test-Path -LiteralPath $setApprovalPath -PathType Leaf)) {
        Add-ReadinessResult `
            -Check 'Approval Simulation' `
            -Passed $false `
            -Details 'Set-DeploymentApproval.ps1 is missing.'
    }
    else {
        $temporaryDirectory = Join-Path `
            ([System.IO.Path]::GetTempPath()) `
            "AzureLocalFactoryApprovalTest-$([guid]::NewGuid().ToString('N'))"

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $temporaryDirectory |
            Out-Null

        $temporaryStatePath = Join-Path `
            $temporaryDirectory `
            'deployment-state.json'

        try {
            $simulationState = @{
                status             = 'PAUSED'
                approvedOperations = @{}
                pendingApproval    = @{
                    ApprovalKey      = '1.2.TESTNODE.Ensure-ManagementNetwork'
                    PhaseId          = 1
                    StageId          = 2
                    Operation        = 'Ensure-ManagementNetwork'
                    Node             = 'TESTNODE'
                    Reason           = 'Simulation only.'
                    RequiresReboot   = $false
                    ReconnectTarget  = 'testnode.example.mil'
                }
            }

            $simulationState |
                ConvertTo-Json `
                -Depth 20 |
                Set-Content `
                -LiteralPath $temporaryStatePath `
                -Encoding utf8

            & $setApprovalPath `
                -StatePath $temporaryStatePath `
                -Decision Approve |
                Out-Null

            $updatedState = Get-Content `
                -LiteralPath $temporaryStatePath `
                -Raw |
                ConvertFrom-Json `
                -AsHashtable

            $approvalKey = '1.2.TESTNODE.Ensure-ManagementNetwork'

            $passed = (
                $updatedState.status -eq 'APPROVED' -and
                $updatedState.approvedOperations.Contains($approvalKey)
            )

            if ($passed) {
                $details = 'Temporary PAUSED state was approved successfully.'
            }
            else {
                $details = (
                    'Approval simulation did not produce expected APPROVED state.'
                )
            }

            Add-ReadinessResult `
                -Check 'Approval Simulation' `
                -Passed $passed `
                -Details $details
        }
        catch {
            Add-ReadinessResult `
                -Check 'Approval Simulation' `
                -Passed $false `
                -Details $_.Exception.Message
        }
        finally {
            Remove-Item `
                -LiteralPath $temporaryDirectory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
Write-Host 'Batch 2B Approval Engine Readiness Audit' -ForegroundColor Cyan
Write-Host ''

$results |
    Format-Table `
        Check,
        Passed,
        Details `
        -Wrap `
        -AutoSize

$failedChecks = @(
    $results |
        Where-Object {
            -not $_.Passed
        }
)

Write-Host ''

if ($failedChecks.Count -gt 0) {
    Write-Host (
        "FAILED: $($failedChecks.Count) Batch 2B approval engine check(s) failed."
    ) -ForegroundColor Red

    throw (
        'Batch 2B approval engine is not ready. ' +
        'Do not add disruptive Ensure-* adapters yet.'
    )
}

Write-Host (
    'PASSED: Batch 2B approval/pause/resume engine is ready for the ' +
    'five disruptive Ensure-* adapters.'
) -ForegroundColor Green