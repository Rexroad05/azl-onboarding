#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$ValidationManifestPath,

    [Parameter(Mandatory)]
    [ValidateSet('HcnDiscoveryReadiness', 'HcnComplianceValidation')]
    [string]$ValidationProfile,

    [string]$ArtifactsPath = (Join-Path $PSScriptRoot '..\artifacts'),

    [string]$RunId = (
        [datetime]::UtcNow.ToString('yyyyMMddTHHmmss') +
        '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop
Import-Module "$PSScriptRoot\Factory.psm1" -Force

function Get-ReadOnlyValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-FactoryValue `
        -Object $Object `
        -Name $Name
}

function New-ReadOnlyResult {
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [AllowNull()]
        [string]$Node,

        [Parameter(Mandatory)]
        [ValidateSet('Passed', 'Finding', 'Failed', 'Skipped')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Classification,

        [Parameter(Mandatory)]
        [string]$Summary,

        [AllowNull()]
        [object]$Details
    )

    return [pscustomobject]@{
        Operation = $Operation
        Node = $Node
        Status = $Status
        Classification = $Classification
        Summary = $Summary
        Details = $Details
        CompletedAt = [datetime]::UtcNow.ToString('o')
    }
}

function Get-OperationSummary {
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    $summary = Get-ReadOnlyValue `
        -Object $Result `
        -Name 'Summary'

    if (-not [string]::IsNullOrWhiteSpace([string]$summary)) {
        return [string]$summary
    }

    return 'Validation adapter completed without a summary.'
}

function Write-ReadOnlyValidationProgress {
    param(
        [Parameter(Mandatory)]
        [string]$Node,

        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [ValidateSet('Passed', 'Finding', 'Failed', 'Skipped')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Classification,

        [Parameter(Mandatory)]
        [string]$Summary
    )

    $statusLabel = switch ($Status) {
        'Passed' {
            if ($Classification -eq 'ReferenceDifference') {
                'REFERENCE'
            }
            else {
                'PASSED'
            }
        }

        'Skipped' {
            if ($Classification -eq 'ExpectedLifecycleState') {
                'NOT APPLICABLE'
            }
            elseif ($Classification -eq 'ConfigurationDeferred') {
                'DEFERRED'
            }
            else {
                'SKIPPED'
            }
        }

        'Finding' { 'FINDING' }
        'Failed'  { 'FAILED' }
        'Skipped' { 'SKIPPED' }
        default    { $Status.ToUpperInvariant() }
    }

    $color = switch ($statusLabel) {
        'PASSED'         { 'Green' }
        'REFERENCE'      { 'Cyan' }
        'FINDING'        { 'Yellow' }
        'FAILED'         { 'Red' }
        'SKIPPED'        { 'DarkYellow' }
        'NOT APPLICABLE' { 'Cyan' }
        'DEFERRED'       { 'DarkYellow' }
        default          { 'White' }
    }

    Write-Host (
        "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
        "$Node | $Operation | $statusLabel | $Summary"
    ) -ForegroundColor $color
}

$packageRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..')
)

$environmentPath = [IO.Path]::GetFullPath($Environment)
$validationManifestPath = [IO.Path]::GetFullPath($ValidationManifestPath)

if (-not (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
    throw "Resolved configuration does not exist: $environmentPath"
}

if (-not (Test-Path -LiteralPath $validationManifestPath -PathType Leaf)) {
    throw "Read-only validation manifest does not exist: $validationManifestPath"
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId may contain only letters, numbers, underscores, and hyphens.'
}

$config = Read-FactoryConfig -Path $environmentPath

$validationManifest = Get-Content `
    -LiteralPath $validationManifestPath `
    -Raw |
    ConvertFrom-Yaml `
    -Ordered

$profile = @(
    $validationManifest.validation_profiles |
        Where-Object {
            [string]$_.name -eq $ValidationProfile
        }
) | Select-Object -First 1

if ($null -eq $profile) {
    throw "Read-only validation profile does not exist: $ValidationProfile"
}

$operations = @($profile.operations)

if ($operations.Count -lt 1) {
    throw "Read-only validation profile contains no operations: $ValidationProfile"
}

foreach ($operation in $operations) {
    $metadata = Get-FactoryOperationMetadata `
        -Operation $operation

    if ([bool]$metadata.Mutates) {
        throw (
            "Read-only validation profile contains mutating operation: " +
            "$operation"
        )
    }
}

$artifactRoot = [IO.Path]::GetFullPath($ArtifactsPath)

$siteValidationRoot = Join-Path `
    $artifactRoot `
    "$($config.site.name)\validation"

$runDirectory = Join-Path `
    $siteValidationRoot `
    $RunId

New-Item `
    -ItemType Directory `
    -Force `
    -Path $runDirectory |
    Out-Null

New-Item `
    -ItemType Directory `
    -Force `
    -Path (Join-Path $runDirectory 'evidence') |
    Out-Null

$state = @{
    schemaVersion = 'read-only-validation-v1'
    site = $config.site.name
    cluster = $config.cluster.name
    runId = $RunId
    mode = 'Validate'
    validationProfile = $ValidationProfile
    status = 'RUNNING'
    startedAt = [datetime]::UtcNow.ToString('o')
    completedAt = $null
    nodes = @{}
    stages = @{}
    phases = @{}
    approvedOperations = @{}
    pendingApproval = $null
    pendingReboot = $null
    pendingInteractiveAuthentication = $null
}

foreach ($node in $config.nodes) {
    $state.nodes[$node.name] = @{
        name = $node.name
        status = 'NOT_STARTED'
        currentPhase = 1
        currentStage = [int]$profile.id
        stages = @{}
        lastError = $null
    }
}

$context = @{
    Root = $packageRoot
    Config = $config
    RunDirectory = $runDirectory
    StatePath = (Join-Path $runDirectory 'read-only-validation-state.json')
    RunId = $RunId
    Mode = 'Validate'
    PhaseId = 1
    ThroughStage = [int]$profile.id
    State = $state
    LastResults = [System.Collections.Generic.List[object]]::new()
    ReadOnlyValidation = $true
    ValidationProfile = $ValidationProfile
}

Write-FactoryJson `
    -Value $state `
    -Path $context.StatePath

$results = [System.Collections.Generic.List[object]]::new()

foreach ($operation in $operations) {
    $metadata = Get-FactoryOperationMetadata `
        -Operation $operation

    if ($metadata.Scope -eq 'Site') {
        try {
            $result = Invoke-FactoryOperation `
                -Operation $operation `
                -Context $context

            $summary = Get-OperationSummary -Result $result

            $results.Add(
                (New-ReadOnlyResult `
                    -Operation $operation `
                    -Node $null `
                    -Status 'Passed' `
                    -Classification 'Compliant' `
                    -Summary $summary `
                    -Details $result)
            )

            Write-ReadOnlyValidationProgress `
                -Node 'Site' `
                -Operation $operation `
                -Status 'Passed' `
                -Classification 'Compliant' `
                -Summary $summary
        }
        catch {
            $reason = Protect-FactoryErrorMessage `
                -Message $_.Exception.Message

            $results.Add(
                (New-ReadOnlyResult `
                    -Operation $operation `
                    -Node $null `
                    -Status 'Finding' `
                    -Classification 'ValidationFinding' `
                    -Summary $reason `
                    -Details $null)
            )

            Write-ReadOnlyValidationProgress `
                -Node 'Site' `
                -Operation $operation `
                -Status 'Finding' `
                -Classification 'ValidationFinding' `
                -Summary $reason
        }

        continue
    }

    foreach ($node in $config.nodes) {
        $nodeContext = @{}

        foreach ($key in $context.Keys) {
            $nodeContext[$key] = $context[$key]
        }

        $nodeContext.Node = $node
        $nodeContext.NodeState = $state.nodes[$node.name]

        try {
            $result = Invoke-FactoryOperation `
                -Operation $operation `
                -Context $nodeContext

            $classification = [string](
                Get-ReadOnlyValue `
                    -Object $result `
                    -Name 'Classification'
            )

            if ([string]::IsNullOrWhiteSpace($classification)) {
                $classification = 'Compliant'
            }

            if ($operation -eq 'Get-AzureLocalDeploymentState') {
                $clustered = [bool](
                    Get-ReadOnlyValue `
                        -Object $result `
                        -Name 'Clustered'
                )

                $registrationStatus = [string](
                    Get-ReadOnlyValue `
                        -Object $result `
                        -Name 'RegistrationStatus'
                )

                if ($clustered -or $registrationStatus -eq 'Registered') {
                    $classification = 'ReferenceDifference'
                }
            }

            $summary = Get-OperationSummary -Result $result

            $adapterOutcome = [string](
                Get-ReadOnlyValue `
                    -Object $result `
                    -Name 'Outcome'
            )

            $readOnlyStatus = if (
                $adapterOutcome -eq 'NotApplicable' -or
                $classification -eq 'ExpectedLifecycleState' -or
                $classification -eq 'ConfigurationDeferred'
            ) {
                'Skipped'
            }
            else {
                'Passed'
            }

            $results.Add(
                (New-ReadOnlyResult `
                    -Operation $operation `
                    -Node ([string]$node.name) `
                    -Status $readOnlyStatus `
                    -Classification $classification `
                    -Summary $summary `
                    -Details $result)
            )

            Write-ReadOnlyValidationProgress `
                -Node ([string]$node.name) `
                -Operation $operation `
                -Status $readOnlyStatus `
                -Classification $classification `
                -Summary $summary
        }
        catch {
            $reason = Protect-FactoryErrorMessage `
                -Message $_.Exception.Message

            $classification = if ($ValidationProfile -eq 'HcnDiscoveryReadiness') {
                'ReferenceDifference'
            }
            else {
                'ValidationFinding'
            }

            $results.Add(
                (New-ReadOnlyResult `
                    -Operation $operation `
                    -Node ([string]$node.name) `
                    -Status 'Finding' `
                    -Classification $classification `
                    -Summary $reason `
                    -Details $null)
            )

            Write-ReadOnlyValidationProgress `
                -Node ([string]$node.name) `
                -Operation $operation `
                -Status 'Finding' `
                -Classification $classification `
                -Summary $reason
        }
    }
}

$failedCount = @(
    $results |
        Where-Object {
            $_.Status -eq 'Failed'
        }
).Count

$findingCount = @(
    $results |
        Where-Object {
            $_.Status -eq 'Finding'
        }
).Count

$overallOutcome = if ($failedCount -gt 0) {
    'Failed'
}
elseif ($findingCount -gt 0) {
    'PassedWithFindings'
}
else {
    'Passed'
}

$state.status = $overallOutcome
$state.completedAt = [datetime]::UtcNow.ToString('o')

Write-FactoryJson `
    -Value $results.ToArray() `
    -Path (
        Join-Path $runDirectory (
            "evidence\read-only-$($profile.name)-results.json"
        )
    )

$reportResult = & "$packageRoot\reports\New-ValidationFindingsReport.ps1" `
    -RunDirectory $runDirectory `
    -Site $config.site.name `
    -ProfileName ([string]$profile.name) `
    -DisplayName ([string]$profile.display_name) `
    -Results $results.ToArray() `
    -OverallOutcome $overallOutcome `
    -ContextSummary @{
        Cluster = $config.cluster.name
        ValidationProfile = $ValidationProfile
        PowerShell = $PSVersionTable.PSVersion.ToString()
        ReadOnly = $true
        OperationCount = $operations.Count
        NodeCount = @($config.nodes).Count
    }

$state.reportHtmlPath = $reportResult.HtmlPath
$state.reportJsonPath = $reportResult.JsonPath

Write-FactoryJson `
    -Value $state `
    -Path $context.StatePath

return [pscustomobject]@{
    Passed = ($overallOutcome -ne 'Failed')
    OverallOutcome = $overallOutcome
    Site = $config.site.name
    ValidationProfile = $ValidationProfile
    DisplayName = $profile.display_name
    RunDirectory = $runDirectory
    HtmlReportPath = $reportResult.HtmlPath
    JsonReportPath = $reportResult.JsonPath
    Summary = $reportResult.Summary
    Results = $results.ToArray()
    CompletedAt = [datetime]::UtcNow.ToString('o')
}