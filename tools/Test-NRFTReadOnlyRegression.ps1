#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$PackageRoot = (
        [IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..')
        )
    ),

    [string]$ArtifactsPath,

    [string]$Site = 'NRFT',

    [switch]$NoThrow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop

function New-RegressionCheck {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Passed,

        [Parameter(Mandatory)]
        [string]$Details
    )

    return [pscustomobject]@{
        Check   = $Name
        Passed  = $Passed
        Details = $Details
    }
}

function Get-RegressionYaml {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required YAML file does not exist: $Path"
    }

    return (
        Get-Content `
            -LiteralPath $Path `
            -Raw |
            ConvertFrom-Yaml `
            -Ordered
    )
}

function Get-JsonHashtable {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (
        Get-Content `
            -LiteralPath $Path `
            -Raw |
            ConvertFrom-Json `
            -AsHashtable
    )
}

function Get-Value {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

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

function Add-RegressionCheck {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Checks,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Passed,

        [Parameter(Mandatory)]
        [string]$PassDetails,

        [Parameter(Mandatory)]
        [string]$FailDetails
    )

    $details = if ($Passed) {
        $PassDetails
    }
    else {
        $FailDetails
    }

    $Checks.Add(
        (New-RegressionCheck `
            -Name $Name `
            -Passed $Passed `
            -Details $details)
    )
}

$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)

if ([string]::IsNullOrWhiteSpace($ArtifactsPath)) {
    $ArtifactsPath = Join-Path $PackageRoot 'artifacts'
}

$ArtifactsPath = [IO.Path]::GetFullPath($ArtifactsPath)

$defaultsPath = Join-Path $PackageRoot 'protected\defaults.yaml'
$phaseManifestPath = Join-Path $PackageRoot 'protected\phase-manifest.yaml'
$siteArtifactPath = Join-Path $ArtifactsPath $Site

$defaults = Get-RegressionYaml -Path $defaultsPath
$phaseManifest = Get-RegressionYaml -Path $phaseManifestPath

$checks = [System.Collections.Generic.List[object]]::new()

$deployment = Get-Value `
    -Object $defaults `
    -Name 'deployment'

$blockExistingClusters = Get-Value `
    -Object $deployment `
    -Name 'block_existing_registered_cluster_changes'

Add-RegressionCheck `
    -Checks $checks `
    -Name 'Existing Cluster Mutation Block Enabled' `
    -Passed ($blockExistingClusters -eq $true) `
    -PassDetails 'deployment.block_existing_registered_cluster_changes is true.' `
    -FailDetails 'deployment.block_existing_registered_cluster_changes is not true.'

$phaseOne = @(
    $phaseManifest.workflow.phases |
        Where-Object {
            [int]$_.id -eq 1
        }
) | Select-Object -First 1

$stageOneTwo = @(
    $phaseOne.stages |
        Where-Object {
            [int]$_.id -eq 2
        }
) | Select-Object -First 1

$stageOneTwoOperations = @($stageOneTwo.operations)

$firstOperation = if ($stageOneTwoOperations.Count -gt 0) {
    [string]$stageOneTwoOperations[0]
}
else {
    $null
}

Add-RegressionCheck `
    -Checks $checks `
    -Name 'Stage 1.2 Existing Cluster Guard First' `
    -Passed ($firstOperation -eq 'Test-AzureLocalDeploymentState') `
    -PassDetails 'Stage 1.2 begins with Test-AzureLocalDeploymentState.' `
    -FailDetails "Stage 1.2 first operation is '$firstOperation'."

$ensureBeforeGuard = $false

for ($index = 0; $index -lt $stageOneTwoOperations.Count; $index++) {
    if (
        [string]$stageOneTwoOperations[$index] -like 'Ensure-*' -and
        $index -eq 0
    ) {
        $ensureBeforeGuard = $true
    }
}

Add-RegressionCheck `
    -Checks $checks `
    -Name 'No Ensure Operation Precedes Existing Cluster Guard' `
    -Passed (-not $ensureBeforeGuard) `
    -PassDetails 'All Ensure operations occur after the existing-cluster guard.' `
    -FailDetails 'An Ensure operation precedes the existing-cluster guard.'

$latestState = $null
$latestStatePath = $null
$latestStageOneEvidencePath = $null
$latestStageTwoEvidencePath = $null

if (Test-Path -LiteralPath $siteArtifactPath -PathType Container) {
    $stateFiles = @(
        Get-ChildItem `
            -LiteralPath $siteArtifactPath `
            -Filter 'deployment-state.json' `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending
    )

    foreach ($stateFile in $stateFiles) {
        $runDirectory = Split-Path `
            -Path $stateFile.FullName `
            -Parent

        $evidenceDirectory = Join-Path `
            $runDirectory `
            'evidence'

        $stageTwoEvidence = @(
            Get-ChildItem `
                -LiteralPath $evidenceDirectory `
                -Filter 'phase-1-stage-2-*.json' `
                -File `
                -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending
        ) | Select-Object -First 1

        if ($null -eq $stageTwoEvidence) {
            continue
        }

        $stageOneEvidence = @(
            Get-ChildItem `
                -LiteralPath $evidenceDirectory `
                -Filter 'phase-1-stage-1-*.json' `
                -File `
                -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending
        ) | Select-Object -First 1

        $latestState = Get-JsonHashtable `
            -Path $stateFile.FullName

        $latestStatePath = $stateFile.FullName
        $latestStageTwoEvidencePath = $stageTwoEvidence.FullName

        if ($null -ne $stageOneEvidence) {
            $latestStageOneEvidencePath = $stageOneEvidence.FullName
        }

        break
    }
}

$stageTwoEvidenceExists = (
    -not [string]::IsNullOrWhiteSpace($latestStageTwoEvidencePath)
)

Add-RegressionCheck `
    -Checks $checks `
    -Name 'NRFT Stage 1.2 Evidence Exists' `
    -Passed $stageTwoEvidenceExists `
    -PassDetails "Evidence: $latestStageTwoEvidencePath" `
    -FailDetails "No Phase 1 Stage 1.2 evidence was found under $siteArtifactPath."

if ($null -ne $latestState) {
    $stateStages = Get-Value `
        -Object $latestState `
        -Name 'stages'

    $stageOneRecord = Get-Value `
        -Object $stateStages `
        -Name '1'

    $stageOnePassed = (
        $null -ne $stageOneRecord -and
        [string](Get-Value -Object $stageOneRecord -Name 'status') -eq 'PASS'
    )

    Add-RegressionCheck `
        -Checks $checks `
        -Name 'NRFT Stage 1.1 Passed' `
        -Passed $stageOnePassed `
        -PassDetails "Stage 1.1 PASS evidence found in $latestStatePath." `
        -FailDetails "Stage 1.1 PASS record was not found in $latestStatePath."

    $pendingApproval = Get-Value `
        -Object $latestState `
        -Name 'pendingApproval'

    $pendingReboot = Get-Value `
        -Object $latestState `
        -Name 'pendingReboot'

    Add-RegressionCheck `
        -Checks $checks `
        -Name 'NRFT Run Contains No Pending Approval' `
        -Passed ($null -eq $pendingApproval) `
        -PassDetails 'No pending approval request is recorded.' `
        -FailDetails 'A pending approval request exists; NRFT regression is not read-only clean.'

    Add-RegressionCheck `
        -Checks $checks `
        -Name 'NRFT Run Contains No Pending Reboot' `
        -Passed ($null -eq $pendingReboot) `
        -PassDetails 'No pending reboot request is recorded.' `
        -FailDetails 'A pending reboot request exists; NRFT regression is not read-only clean.'
}

if ($stageTwoEvidenceExists) {
    $stageTwoRaw = Get-Content `
        -LiteralPath $latestStageTwoEvidencePath `
        -Raw

    $stageTwoEvidence = Get-JsonHashtable `
        -Path $latestStageTwoEvidencePath

    $stageTwoReason = [string](
        Get-Value `
            -Object $stageTwoEvidence `
            -Name 'reason'
    )

    $partialResults = @(
        Get-Value `
            -Object $stageTwoEvidence `
            -Name 'partialResults'
    )

    $partialOperations = @(
        $partialResults |
            ForEach-Object {
                [string](
                    Get-Value `
                        -Object $_ `
                        -Name 'Operation'
                )
            }
    )

    $combinedEvidenceText = $stageTwoReason + "`n" + $stageTwoRaw

    $existingClusterDetected = (
        $combinedEvidenceText -match '(?i)clustered|existing.*cluster'
    )

    $existingRegistrationDetected = (
        $combinedEvidenceText -match '(?i)registered|azure resource'
    )

    $blockedCorrectly = (
        $existingClusterDetected -and
        $existingRegistrationDetected
    )

    Add-RegressionCheck `
        -Checks $checks `
        -Name 'NRFT Stage 1.2 Blocked on Existing Registered Cluster' `
        -Passed $blockedCorrectly `
        -PassDetails 'Stage 1.2 evidence shows existing clustered and registered Azure Local state.' `
        -FailDetails "Stage 1.2 did not show expected cluster/registration block evidence: $stageTwoReason"

    $ensureOperationFound = @(
        $partialOperations |
            Where-Object {
                $_ -like 'Ensure-*'
            }
    ).Count -gt 0

    $ensureEvidenceFound = (
        $stageTwoRaw -match '"Operation"\s*:\s*"Ensure-' -or
        $stageTwoRaw -match '"operation"\s*:\s*"Ensure-'
    )

    $noEnsureEvidence = (
        -not $ensureOperationFound -and
        -not $ensureEvidenceFound
    )

    Add-RegressionCheck `
        -Checks $checks `
        -Name 'NRFT Stage 1.2 Contains No Ensure Execution Evidence' `
        -Passed $noEnsureEvidence `
        -PassDetails 'No Ensure execution evidence was found in the Stage 1.2 artifact.' `
        -FailDetails 'Ensure execution evidence was found. Treat the NRFT regression result as unsafe.'
}

$results = $checks.ToArray()

$results |
    Format-Table `
        Check,
        Passed,
        Details `
        -AutoSize

$failedChecks = @(
    $results |
        Where-Object {
            -not $_.Passed
        }
)

$returnValue = [pscustomobject]@{
    Site                 = $Site
    PackageRoot          = $PackageRoot
    ArtifactsPath        = $ArtifactsPath
    LatestStatePath      = $latestStatePath
    StageOneEvidencePath = $latestStageOneEvidencePath
    StageTwoEvidencePath = $latestStageTwoEvidencePath
    Passed               = ($failedChecks.Count -eq 0)
    FailedChecks         = $failedChecks
    Checks               = $results
    ValidatedAt          = [datetime]::UtcNow.ToString('o')
}

if ($failedChecks.Count -gt 0 -and -not $NoThrow) {
    throw (
        'NRFT read-only regression failed: ' +
        ($failedChecks.Check -join '; ')
    )
}

return $returnValue