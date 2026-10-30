#Requires -Version 7.4
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop

$packageRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..')
)

$artifactsPath = Join-Path $packageRoot 'artifacts'
$phaseManifestPath = Join-Path $packageRoot 'protected\phase-manifest.yaml'
$releaseVersionPath = Join-Path $packageRoot 'protected\release-version.json'

if (-not (Test-Path -LiteralPath $releaseVersionPath -PathType Leaf)) {
    throw "Release version file does not exist: $releaseVersionPath"
}

$releaseVersion = Get-Content `
    -LiteralPath $releaseVersionPath `
    -Raw |
    ConvertFrom-Json

$displayVersion = [string]$releaseVersion.displayVersion

if ([string]::IsNullOrWhiteSpace($displayVersion)) {
    $displayVersion = "v$($releaseVersion.releaseVersion)"
}

$script:ManagerSessionCredentialVariables = `
    [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

function Register-ManagerSessionCredentials {
    param(
        [AllowEmptyCollection()]
        [string[]]$EnvironmentVariableNames
    )

    foreach ($environmentVariableName in @($EnvironmentVariableNames)) {
        if (-not [string]::IsNullOrWhiteSpace($environmentVariableName)) {
            [void]$script:ManagerSessionCredentialVariables.Add(
                $environmentVariableName
            )
        }
    }
}

function Clear-ManagerSessionCredentials {
    foreach (
        $environmentVariableName in
        @($script:ManagerSessionCredentialVariables)
    ) {
        [Environment]::SetEnvironmentVariable(
            $environmentVariableName,
            $null,
            'Process'
        )
    }

    $script:ManagerSessionCredentialVariables.Clear()
}

function Protect-ManagerErrorMessage {
    param(
        [AllowNull()]
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return 'The action failed without a detailed error message.'
    }

    $sanitized = $Message

    $sensitiveVariables = @(
        Get-ChildItem Env: |
            Where-Object {
                $_.Name -match (
                    '(?i)password|secret|token|credential|client[_-]?secret'
                )
            }
    )

    foreach ($sensitiveVariable in $sensitiveVariables) {
        if (
            -not [string]::IsNullOrWhiteSpace(
                [string]$sensitiveVariable.Value
            )
        ) {
            $sanitized = $sanitized.Replace(
                [string]$sensitiveVariable.Value,
                '[REDACTED]'
            )
        }
    }

    $sanitized = $sanitized -replace `
        '(?i)bearer\s+[a-z0-9\-_\.\=]+',
        'Bearer [REDACTED]'

    $sanitized = $sanitized -replace `
        '(?i)(password|secret|token)\s*[:=]\s*\S+',
        '$1=[REDACTED]'

    return $sanitized
}
function Get-AvailableSites {
    $inputDirectory = Join-Path $packageRoot 'operator-inputs'

    return @(
        Get-ChildItem `
            -LiteralPath $inputDirectory `
            -Filter '*.variables.yaml' `
            -File |
            ForEach-Object {
                $_.Name -replace '\.variables\.yaml$', ''
            } |
            Sort-Object
    )
}

function Select-RunnerProfile {
    return 'AzureLocalExecution'
}

function Get-FactoryObjectValue {
    [CmdletBinding()]
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
        if (@($Object.Keys) -contains $Name) {
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

function Get-StageColor {
    param(
        [Parameter(Mandatory)]
        [string]$Status
    )

    switch ($Status) {
        'PASS'            { 'Green' }
        'READY'           { 'Green' }
        'SKIPPED'         { 'White' }
        'CHANGED'         { 'DarkYellow' }
        'PAUSED'          { 'Yellow' }
        'APPROVED'        { 'Cyan' }
        'DENIED'          { 'Red' }
        'BLOCKED'         { 'Red' }
        'FAIL'            { 'Red' }
        'LOCKED'          { 'DarkYellow' }
        'NOT_IMPLEMENTED' { 'DarkGray' }
        default           { 'White' }
    }
}

function Get-StageStatus {
    param(
        [Parameter(Mandatory)]
        [object]$Status,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId
    )

    $stage = @(
        $Status.Phases |
            Where-Object {
                $_.PhaseId -eq $PhaseId
            } |
            ForEach-Object {
                $_.Stages
            } |
            Where-Object {
                $_.StageId -eq $StageId
            }
    ) |
        Select-Object -First 1

    if ($null -eq $stage) {
        return 'UNKNOWN'
    }

    return [string]$stage.Status
}

function Test-NativeArcRegistrationSession {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$PendingApproval
    )

    if ($null -eq $PendingApproval) {
        return $false
    }

    $phaseId = Get-FactoryObjectValue `
        -Object $PendingApproval `
        -Name 'PhaseId'

    $stageId = Get-FactoryObjectValue `
        -Object $PendingApproval `
        -Name 'StageId'

    $operation = [string](
        Get-FactoryObjectValue `
            -Object $PendingApproval `
            -Name 'Operation'
    )

    return (
        $phaseId -eq 1 -and
        $stageId -eq 4 -and
        $operation -eq 'Register-ArcNode'
    )
}

function Get-NextReadyStage {
    param(
        [Parameter(Mandatory)]
        [object]$Status
    )

    return @(
        $Status.Phases |
            ForEach-Object {
                $_.Stages
            } |
            Where-Object {
                $_.Status -eq 'READY' -and
                $_.Mode -in @(
                    'Validate',
                    'Apply'
                )
            } |
            Sort-Object PhaseId, StageId |
            Select-Object -First 1
    )
}

function Get-WorkflowPosition {
    param(
        [Parameter(Mandatory)]
        [object]$Status
    )

    $latestState = $Status.LatestState
    $pendingApproval = $Status.PendingApproval

    $latestWorkflowState = ''
    if ($Status.ConfigChanged) {
        return [pscustomobject]@{
            WorkflowState = 'READY'
            PhaseId = 1
            StageId = 1
            ReturnOperation = $null
        }
    }

    # An active approval, paused workflow, approved resume, or failed workflow
    # takes precedence over a nominal next-ready stage.
    $hasActiveWorkflowState = (
        $null -ne $latestState -and
        (
            $null -ne $pendingApproval -or
            $latestWorkflowState -in @(
                'APPROVED',
                'PAUSED',
                'FAILED',
                'BLOCKED',
                'REBOOT_REQUIRED'
            )
        )
    )

    if ($hasActiveWorkflowState) {
        return [pscustomobject]@{
            WorkflowState = $latestWorkflowState
            PhaseId = $latestState.currentPhase
            StageId = $latestState.currentStage
            ReturnOperation = [string]$latestState.returnToOperation
        }
    }

    # For normal READY processing, the displayed workflow position must reflect
    # the actual unlocked stage, not a stale historical workflow-state record.
    $nextReadyStage = @(
        Get-NextReadyStage -Status $Status
    )

    if ($nextReadyStage.Count -eq 1) {
        return [pscustomobject]@{
            WorkflowState = 'READY'
            PhaseId = [int]$nextReadyStage[0].PhaseId
            StageId = [int]$nextReadyStage[0].StageId
            ReturnOperation = $null
        }
    }

    # No saved state and no current executable stage.
    if ($null -eq $latestState) {
        return [pscustomobject]@{
            WorkflowState = 'NOT_STARTED'
            PhaseId = 1
            StageId = 1
            ReturnOperation = $null
        }
    }

    # Final fallback: retain the latest state when the workflow is complete,
    # blocked, or otherwise has no single unlocked next stage.
    return [pscustomobject]@{
        WorkflowState = $latestWorkflowState
        PhaseId = $latestState.currentPhase
        StageId = $latestState.currentStage
        ReturnOperation = [string]$latestState.returnToOperation
    }
}

function Write-ManagerSummaryHeader {
    param(
        [Parameter(Mandatory)]
        [string]$Site,

        [Parameter(Mandatory)]
        [string]$RunnerProfile,

        [Parameter(Mandatory)]
        [string]$DisplayVersion,

        [Parameter(Mandatory)]
        [object]$Status
    )

    $position = Get-WorkflowPosition `
        -Status $Status

    Clear-Host

    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '        AZURE LOCAL DEPLOYMENT MANAGER' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "Site:            $Site"
    Write-Host "Runner Profile:  $RunnerProfile"
    Write-Host "Artifacts:       $artifactsPath"
    Write-Host "Package Version: $DisplayVersion"
    Write-Host "Workflow State:  $($position.WorkflowState)"
    Write-Host "Current Phase:   $($position.PhaseId)"
    Write-Host "Current Stage:   $($position.StageId)"

    if (-not [string]::IsNullOrWhiteSpace($position.ReturnOperation)) {
        Write-Host "Return Operation: $($position.ReturnOperation)"
    }

    if ($null -ne $Status.NativeArcRegistrationSession) {
        $session = $Status.NativeArcRegistrationSession

        Write-Host ''
        Write-Host 'NATIVE ARC REGISTRATION SESSION' -ForegroundColor Yellow
        Write-Host (
            "  Node:              $(
                Get-FactoryObjectValue `
                    -Object $session `
                    -Name 'Node'
            )"
        )
        Write-Host (
            "  Bootstrap Status:  $(
                Get-FactoryObjectValue `
                    -Object $session `
                    -Name 'BootstrapStatus'
            )"
        )
        Write-Host (
            "  Last Checked UTC:  $(
                Get-FactoryObjectValue `
                    -Object $session `
                    -Name 'LastCheckedAtUtc'
            )"
        )
    }

    Write-Host ''
}

function Write-CurrentWorkflowStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Site,

        [Parameter(Mandatory)]
        [string]$RunnerProfile,

        [Parameter(Mandatory)]
        [string]$DisplayVersion,

        [Parameter(Mandatory)]
        [object]$Status
    )

    $position = Get-WorkflowPosition `
        -Status $Status

    Clear-Host

    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '              CURRENT WORKFLOW STATUS' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "Site:            $Site"
    Write-Host "Runner Profile:  $RunnerProfile"
    Write-Host "Package Version: $DisplayVersion"
    Write-Host "Workflow State:  $($position.WorkflowState)"
    Write-Host "Current Phase:   $($position.PhaseId)"
    Write-Host "Current Stage:   $($position.StageId)"

    if (-not [string]::IsNullOrWhiteSpace($position.ReturnOperation)) {
        Write-Host "Return Operation: $($position.ReturnOperation)"
    }

    Write-Host ''

    foreach ($phase in @($Status.Phases)) {
        Write-Host $phase.DisplayName -ForegroundColor Cyan

        foreach ($stage in @($phase.Stages)) {
            $line = '  {0,-5} {1,-52} {2}' -f `
                ("$($stage.PhaseId).$($stage.StageId)"),
                $stage.DisplayName,
                $stage.Status

            Write-Host `
                $line `
                -ForegroundColor (
                    Get-StageColor `
                        -Status $stage.Status
                )
        }

        Write-Host ''
    }

    if ($null -ne $Status.NativeArcRegistrationSession) {
        $session = $Status.NativeArcRegistrationSession

        Write-Host 'Current Native Arc State' -ForegroundColor Yellow
        Write-Host (
            "  Node:              $(
                Get-FactoryObjectValue `
                    -Object $session `
                    -Name 'Node'
            )"
        )
        Write-Host (
            "  Bootstrap Status:  $(
                Get-FactoryObjectValue `
                    -Object $session `
                    -Name 'BootstrapStatus'
            )"
        )
        Write-Host (
            "  Status Record:     $(
                Get-FactoryObjectValue `
                    -Object $session `
                    -Name 'StatusRecordPath'
            )"
        )
        Write-Host (
            "  Last Checked UTC:  $(
                Get-FactoryObjectValue `
                    -Object $session `
                    -Name 'LastCheckedAtUtc'
            )"
        )
        Write-Host ''
    }

    if ($null -eq $Status.LastFailure) {
        Write-Host 'Last Failure: None' -ForegroundColor Green
    }
    else {
        Write-Host 'Last Failure' -ForegroundColor Red
        Write-Host "  Stage:    $($Status.LastFailure.StageId)"
        Write-Host "  Time:     $($Status.LastFailure.Timestamp)"
        Write-Host "  Reason:   $($Status.LastFailure.Reason)"
        Write-Host "  Evidence: $($Status.LastFailure.Evidence)"
    }

    Write-Host ''
    Read-Host 'Press ENTER to return to the Deployment Manager' |
        Out-Null
}

function Write-WorkflowMap {
    param(
        [Parameter(Mandatory)]
        [object]$Status
    )

    Clear-Host

    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '                    WORKFLOW MAP' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host ''

    Write-Host 'Phase 1 - HCN Foundation and Azure Registration' -ForegroundColor Cyan
    Write-Host '  1.1 Input and Build Validation' -ForegroundColor White
    Write-Host '      Validate site inputs, names, IPs, package, and build readiness.' -ForegroundColor DarkGray
    Write-Host (
        "      [$(
            Get-StageStatus -Status $Status -PhaseId 1 -StageId 1
        )]"
    ) -ForegroundColor (
        Get-StageColor `
            -Status (
                Get-StageStatus -Status $Status -PhaseId 1 -StageId 1
            )
    )

    Write-Host ''
    Write-Host '  1.2B Ensure HCN Desired State' -ForegroundColor White
    Write-Host '      Inspect state → approve changes → ensure desired state → reboot/revalidate when required.' -ForegroundColor DarkGray
    Write-Host (
        "      [$(
            Get-StageStatus -Status $Status -PhaseId 1 -StageId 2
        )]"
    ) -ForegroundColor (
        Get-StageColor `
            -Status (
                Get-StageStatus -Status $Status -PhaseId 1 -StageId 2
            )
    )

    Write-Host ''
    Write-Host '  1.3 Azure Local Node Bootstrap Readiness' -ForegroundColor White
    Write-Host '      Validate Azure Government identity, subscription, providers, resource group, endpoints, and node readiness.' -ForegroundColor DarkGray
    Write-Host (
        "      [$(
            Get-StageStatus -Status $Status -PhaseId 1 -StageId 3
        )]"
    ) -ForegroundColor (
        Get-StageColor `
            -Status (
                Get-StageStatus -Status $Status -PhaseId 1 -StageId 3
            )
    )

    Write-Host ''
    Write-Host '  1.4 Azure Arc Machine Registration and Validation' -ForegroundColor White
    Write-Host '      Validate agent → approve → native Arc bootstrap → authenticate → validate Arc resource, HIMDS, and node health.' -ForegroundColor DarkGray
    Write-Host (
        "      [$(
            Get-StageStatus -Status $Status -PhaseId 1 -StageId 4
        )]"
    ) -ForegroundColor (
        Get-StageColor `
            -Status (
                Get-StageStatus -Status $Status -PhaseId 1 -StageId 4
            )
    )

    Write-Host ''
    Write-Host 'Phase 2 - Azure Local Cluster Deployment' -ForegroundColor Cyan
    Write-Host '  2.1 Cluster Deployment Input Validation        [NOT IMPLEMENTED]' -ForegroundColor DarkGray
    Write-Host '  2.2 Azure Local Cluster Deployment             [NOT IMPLEMENTED]' -ForegroundColor DarkGray
    Write-Host '  2.3 Cluster, Storage, and Control Validation   [NOT IMPLEMENTED]' -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'Phase 3 - Post-Deployment Azure Local Services  [NOT IMPLEMENTED]' -ForegroundColor DarkGray
    Write-Host 'Phase 4 - Operational Validation and Certification [NOT IMPLEMENTED]' -ForegroundColor DarkGray

    $position = Get-WorkflowPosition `
        -Status $Status

    Write-Host ''
    Write-Host 'Current Workflow Position' -ForegroundColor Yellow
    Write-Host "  Phase:      $($position.PhaseId)"
    Write-Host "  Stage:      $($position.StageId)"
    Write-Host "  State:      $($position.WorkflowState)"

    if (-not [string]::IsNullOrWhiteSpace($position.ReturnOperation)) {
        Write-Host "  Operation:  $($position.ReturnOperation)"
    }

    Write-Host ''
    Read-Host 'Press ENTER to return to the Deployment Manager' |
        Out-Null
}

function Get-ResolvedConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedConfigurationPath
    )

    if (-not (Test-Path -LiteralPath $ResolvedConfigurationPath -PathType Leaf)) {
        throw "Resolved configuration file was not found: $ResolvedConfigurationPath"
    }

    $configuration = ConvertFrom-Yaml -Yaml (
        Get-Content `
            -LiteralPath $ResolvedConfigurationPath `
            -Raw `
            -ErrorAction Stop
    ) -Ordered

    if ($configuration -isnot [System.Collections.IDictionary]) {
        throw 'Resolved configuration did not deserialize to a mapping.'
    }

    return $configuration
}

function Get-OperatorCredentialRequirements {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Configuration,

        [Parameter(Mandatory)]
        [ValidateSet('Plan', 'Apply', 'Validate')]
        [string]$Mode,

        [Parameter(Mandatory)]
        [int]$ThroughStage
    )

    $requiresRemoteSession = (
        $Mode -ne 'Plan' -and
        $ThroughStage -ge 2
    )

    if (-not $requiresRemoteSession) {
        return [pscustomobject]@{
            RequireAddsCredentials = $false
            RequireLocalAdministratorCredentials = $false
            HasBootstrapNodes = $false
            RequireAzureAuthentication = $false
            ConnectionSummary = (
                'No remote node credentials required for this action.'
            )
        }
    }

    $nodes = @(
        Get-FactoryObjectValue `
            -Object $Configuration `
            -Name 'nodes'
    )

    $bootstrapNodes = @(
        $nodes |
            Where-Object {
                $bootstrapConnection = Get-FactoryObjectValue `
                    -Object $_ `
                    -Name 'bootstrap_connection'

                $null -ne $bootstrapConnection
            }
    )

    $standardNodes = @(
        $nodes |
            Where-Object {
                $bootstrapConnection = Get-FactoryObjectValue `
                    -Object $_ `
                    -Name 'bootstrap_connection'

                $null -eq $bootstrapConnection
            }
    )

    $requiresAzureAuthentication = (
        $Mode -ne 'Plan' -and
        $ThroughStage -ge 3
    )

    return [pscustomobject]@{
        RequireAddsCredentials = ($standardNodes.Count -gt 0)
        RequireLocalAdministratorCredentials = ($bootstrapNodes.Count -gt 0)
        HasBootstrapNodes = ($bootstrapNodes.Count -gt 0)
        RequireAzureAuthentication = $requiresAzureAuthentication
        ConnectionSummary = (
            'Bootstrap-local nodes: {0}; standard AD DS nodes: {1}.' -f
            $bootstrapNodes.Count,
            $standardNodes.Count
        )
    }
}

function Get-TemporaryCertificateExceptionAuthorization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Configuration
    )

    $remoteManagement = Get-FactoryObjectValue `
        -Object $Configuration `
        -Name 'remote_management'

    if ($null -eq $remoteManagement) {
        throw 'Resolved configuration does not contain remote_management.'
    }

    return (
        (Get-FactoryObjectValue `
            -Object $remoteManagement `
            -Name 'allow_temporary_certificate_exception') -eq $true
    )
}

function Initialize-WorkflowWinRmCertificateValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Configuration,

        [Parameter(Mandatory)]
        [pscustomobject]$CredentialRequirements
    )

    if (-not $CredentialRequirements.HasBootstrapNodes) {
        return $null
    }

    $previousCertificateMode = [Environment]::GetEnvironmentVariable(
        'FACTORY_WINRM_CERTIFICATE_MODE'
    )

    $previousTemporaryApproval = [Environment]::GetEnvironmentVariable(
        'FACTORY_ALLOW_UNTRUSTED_WINRM'
    )

    $state = [pscustomobject]@{
        PreviousCertificateMode = $previousCertificateMode
        PreviousTemporaryApproval = $previousTemporaryApproval
        CertificateValidationMode = 'Strict'
        TemporaryExceptionActive = $false
    }

    $temporaryExceptionAuthorized = `
        Get-TemporaryCertificateExceptionAuthorization `
            -Configuration $Configuration

    $launcherSelectionLocked = (
        [Environment]::GetEnvironmentVariable(
            'FACTORY_WINRM_CERTIFICATE_MODE_LOCKED'
        ) -eq 'Launcher'
    )

    $requestedCertificateMode = [string](
        [Environment]::GetEnvironmentVariable(
            'FACTORY_WINRM_CERTIFICATE_MODE'
        )
    )

    $requestedTemporaryApproval = [string](
        [Environment]::GetEnvironmentVariable(
            'FACTORY_ALLOW_UNTRUSTED_WINRM'
        )
    )

    if ($launcherSelectionLocked) {
        if ($requestedCertificateMode -eq 'Strict') {
            [Environment]::SetEnvironmentVariable(
                'FACTORY_WINRM_CERTIFICATE_MODE',
                'Strict',
                'Process'
            )

            [Environment]::SetEnvironmentVariable(
                'FACTORY_ALLOW_UNTRUSTED_WINRM',
                $null,
                'Process'
            )

            Write-Host (
                'Using launcher-selected Strict WinRM certificate validation.'
            ) -ForegroundColor Cyan

            return $state
        }

        if ($requestedCertificateMode -eq 'ApprovedTemporaryException') {
            if (-not $temporaryExceptionAuthorized) {
                throw (
                    'The launcher selected an approved temporary WinRM certificate ' +
                    'exception, but protected package configuration does not ' +
                    'authorize that exception for this site.'
                )
            }

            if (
                $requestedTemporaryApproval -ne
                'APPROVED_TEMPORARY_EXCEPTION'
            ) {
                throw (
                    'The launcher-selected temporary WinRM certificate exception ' +
                    'does not contain the required approval token.'
                )
            }

            [Environment]::SetEnvironmentVariable(
                'FACTORY_WINRM_CERTIFICATE_MODE',
                'ApprovedTemporaryException',
                'Process'
            )

            [Environment]::SetEnvironmentVariable(
                'FACTORY_ALLOW_UNTRUSTED_WINRM',
                'APPROVED_TEMPORARY_EXCEPTION',
                'Process'
            )

            $state.CertificateValidationMode = `
                'ApprovedTemporaryException'

            $state.TemporaryExceptionActive = $true

            Write-Host (
                'Using launcher-approved temporary WinRM certificate exception ' +
                'for this Deployment Manager session. FQDN/CN validation remains enforced.'
            ) -ForegroundColor Yellow

            return $state
        }

        throw (
            "Launcher certificate mode $requestedCertificateMode is invalid. " +
            'Restart the Deployment Manager through the approved launcher.'
        )
    }

    $useTemporaryException = $false

    Write-Host ''
    Write-Host (
        'WinRM certificate validation is Strict by default.'
    ) -ForegroundColor Yellow

    if ($temporaryExceptionAuthorized) {
        Write-Host (
            'The selected bootstrap endpoint may require an approved temporary ' +
            'CA-chain and certificate-revocation exception.'
        ) -ForegroundColor Yellow

        Write-Host (
            'Certificate hostname/CN validation remains enforced.'
        ) -ForegroundColor Yellow

        Write-Host ''

        $confirmation = Read-Host (
            'Type TEMPORARY-CERTIFICATE-EXCEPTION to enable the exception ' +
            'for this action only, or press ENTER to retain Strict validation'
        )

        if ($confirmation -ceq 'TEMPORARY-CERTIFICATE-EXCEPTION') {
            $useTemporaryException = $true
        }
    }
    else {
        Write-Host (
            'A temporary WinRM certificate exception is not authorized by ' +
            'protected package configuration.'
        ) -ForegroundColor Yellow
    }

    if ($useTemporaryException) {
        [Environment]::SetEnvironmentVariable(
            'FACTORY_WINRM_CERTIFICATE_MODE',
            'ApprovedTemporaryException',
            'Process'
        )

        [Environment]::SetEnvironmentVariable(
            'FACTORY_ALLOW_UNTRUSTED_WINRM',
            'APPROVED_TEMPORARY_EXCEPTION',
            'Process'
        )

        $state.CertificateValidationMode = `
            'ApprovedTemporaryException'

        $state.TemporaryExceptionActive = $true

        Write-Host (
            'Approved temporary WinRM certificate exception enabled for ' +
            'this factory action only.'
        ) -ForegroundColor Yellow
    }
    else {
        [Environment]::SetEnvironmentVariable(
            'FACTORY_WINRM_CERTIFICATE_MODE',
            'Strict',
            'Process'
        )

        [Environment]::SetEnvironmentVariable(
            'FACTORY_ALLOW_UNTRUSTED_WINRM',
            $null,
            'Process'
        )

        Write-Host (
            'WinRM certificate validation mode: Strict.'
        ) -ForegroundColor Cyan
    }

    return $state
}

function Restore-WorkflowWinRmCertificateValidation {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [pscustomobject]$State
    )

    if ($null -eq $State) {
        return
    }

    [Environment]::SetEnvironmentVariable(
        'FACTORY_WINRM_CERTIFICATE_MODE',
        $State.PreviousCertificateMode,
        'Process'
    )

    [Environment]::SetEnvironmentVariable(
        'FACTORY_ALLOW_UNTRUSTED_WINRM',
        $State.PreviousTemporaryApproval,
        'Process'
    )
}

function Invoke-FactoryAction {
    param(
        [Parameter(Mandatory)]
        [string]$Site,

        [Parameter(Mandatory)]
        [ValidateSet('Plan', 'Validate', 'Apply')]
        [string]$Mode,

        [Parameter(Mandatory)]
        [int]$ThroughStage,

        [Parameter(Mandatory)]
        [string]$RunnerProfile,

        [int]$StartStage = 1,

        [string]$StartOperation,

        [switch]$Resume,

        [string]$ResumeRunId
    )

    $certificateValidationState = $null
    $workflowSucceeded = $false
    $safeFailureReason = $null

    try {
        $mergeResult = & "$PSScriptRoot\Merge-FactoryConfiguration.ps1" `
            -PackageRoot $packageRoot `
            -Site $Site `
            -ArtifactsPath $artifactsPath

        $requireAzureCli = (
            $Mode -ne 'Plan' -and
            $ThroughStage -ge 3
        )

        $requireConfiguredModules = (
            $Mode -ne 'Plan' -and
            $ThroughStage -ge 3
        )

        $workstationValidationParameters = @{
            PackageRoot = $packageRoot
            RunnerProfile = $RunnerProfile
        }

        if ($requireAzureCli) {
            $workstationValidationParameters.RequireAzureCli = $true
        }

        if ($requireConfiguredModules) {
            $workstationValidationParameters.RequireConfiguredModules = $true
        }

        & "$PSScriptRoot\Test-OperatorWorkstation.ps1" `
            @workstationValidationParameters |
            Out-Null

        $resolvedConfiguration = Get-ResolvedConfiguration `
            -ResolvedConfigurationPath $mergeResult.ResolvedConfigPath

        $credentialRequirements = Get-OperatorCredentialRequirements `
            -Configuration $resolvedConfiguration `
            -Mode $Mode `
            -ThroughStage $ThroughStage

        $requiresDeploymentPassword = (
            $Mode -eq 'Apply' -and
            $ThroughStage -eq 2
        )

        Write-Host ''
        Write-Host 'Credential Routing'
        Write-Host ('  {0}' -f $credentialRequirements.ConnectionSummary)

        if ($credentialRequirements.RequireAddsCredentials) {
            Write-Host '  AD DS credential initialization: required.'
        }
        else {
            Write-Host '  AD DS credential initialization: not required.'
        }

        if ($credentialRequirements.RequireLocalAdministratorCredentials) {
            Write-Host (
                '  Bootstrap-local administrator credential initialization: required.'
            )
        }
        else {
            Write-Host (
                '  Bootstrap-local administrator credential initialization: not required.'
            )
        }

        if ($requiresDeploymentPassword) {
            Write-Host '  Deployment password initialization: required.'
        }
        else {
            Write-Host '  Deployment password initialization: not required.'
        }

        Write-Host ''

        if ($Mode -ne 'Plan' -and $ThroughStage -ge 2) {
            $certificateValidationState = `
                Initialize-WorkflowWinRmCertificateValidation `
                    -Configuration $resolvedConfiguration `
                    -CredentialRequirements $credentialRequirements
        }

        $session = & "$PSScriptRoot\Initialize-OperatorSession.ps1" `
            -RequireAddsCredentials:$credentialRequirements.RequireAddsCredentials `
            -RequireLocalAdministratorCredentials:$credentialRequirements.RequireLocalAdministratorCredentials `
            -RequireDeploymentPassword:$requiresDeploymentPassword

        Register-ManagerSessionCredentials `
            -EnvironmentVariableNames $session.CreatedEnvironmentVariables

        $requiresAzureGovernmentAuthentication = (
            $Mode -ne 'Plan' -and
            $ThroughStage -ge 3
        )

        if ($requiresAzureGovernmentAuthentication) {
            $azureSessionResults = @(
                & "$PSScriptRoot\Initialize-AzureGovernmentSession.ps1" `
                    -ResolvedConfigPath $mergeResult.ResolvedConfigPath
            )

            if ($azureSessionResults.Count -ne 1) {
                throw (
                    'Azure Government session initializer returned ' +
                    "$($azureSessionResults.Count) result object(s); expected one."
                )
            }

            $azureSession = $azureSessionResults[0]

            if ($null -eq $azureSession.PSObject.Properties['SubscriptionId']) {
                throw (
                    'Azure Government session initializer did not return ' +
                    'a valid SubscriptionId property.'
                )
            }

            Write-Host (
                "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
                "Azure Government authentication validated for subscription " +
                "$($azureSession.SubscriptionId)."
            ) -ForegroundColor Green
        }

        $factoryParameters = @{
            Environment = $mergeResult.ResolvedConfigPath
            Mode = $Mode
            StartStage = $StartStage
            ThroughStage = $ThroughStage
            ArtifactsPath = $artifactsPath
        }

        if (-not [string]::IsNullOrWhiteSpace($StartOperation)) {
            $factoryParameters.StartOperation = $StartOperation
        }

        if ($Resume) {
            if ([string]::IsNullOrWhiteSpace($ResumeRunId)) {
                throw 'ResumeRunId is required when resuming a workflow.'
            }

            $factoryParameters.Resume = $true
            $factoryParameters.RunId = $ResumeRunId
        }

        & "$packageRoot\controller\Invoke-AzureLocalFactory.ps1" `
            @factoryParameters

        $workflowSucceeded = $true
    }
    catch {
        $safeFailureReason = Protect-ManagerErrorMessage `
            -Message $_.Exception.Message

        Write-Host ''
        Write-Host 'WORKFLOW ACTION FAILED OR BLOCKED' -ForegroundColor Red
        Write-Host ''
        Write-Host "Reason: $safeFailureReason" -ForegroundColor Red
        Write-Host ''

        Write-Host (
            'The factory preserved workflow state, evidence, and any available ' +
            'deployment report. Review workflow status and failure evidence before retrying.'
        ) -ForegroundColor Yellow
    }
    finally {
        Restore-WorkflowWinRmCertificateValidation `
            -State $certificateValidationState
    }

    if ($workflowSucceeded) {
        Write-Host ''
        Write-Host (
            'Workflow action returned control to the Deployment Manager.'
        ) -ForegroundColor Green
    }

    Write-Host ''
    Read-Host 'Press ENTER to return to the Deployment Manager' |
        Out-Null

    return 
}
function Invoke-NativeArcRegistrationSession {
    param(
        [Parameter(Mandatory)]
        [string]$Site,

        [Parameter(Mandatory)]
        [string]$RunnerProfile,

        [Parameter(Mandatory)]
        [object]$Status
    )

    if ($null -eq $Status.LatestState) {
        throw 'Native Arc registration session requires saved workflow state.'
    }

    Invoke-FactoryAction `
        -Site $site `
        -Mode Apply `
        -StartStage 4 `
        -ThroughStage 4 `
        -StartOperation 'Register-ArcNode' `
        -RunnerProfile $runnerProfile `
        -Resume `
        -ResumeRunId ([string]$Status.LatestState.runId)
}

function Invoke-RecommendedWorkflowAction {
    param(
        [Parameter(Mandatory)]
        [string]$Site,

        [Parameter(Mandatory)]
        [string]$RunnerProfile,

        [Parameter(Mandatory)]
        [object]$Status
    )

    $nextReadyStage = @(
        Get-NextReadyStage `
            -Status $Status
    )

    $pendingApproval = $Status.PendingApproval

    $approvalType = [string](
        Get-FactoryObjectValue `
            -Object $pendingApproval `
            -Name 'ApprovalType'
    )

    $isInteractiveAuthenticationPaused = (
        $null -ne $pendingApproval -and
        $approvalType -eq 'InteractiveAuthentication'
    )

    $isNativeArcRegistrationSession = (
        $null -ne $Status.NativeArcRegistrationSession
    )

    $isNativeArcConfigurationApproval = (
        $isNativeArcRegistrationSession -and
        -not $isInteractiveAuthenticationPaused -and
        $approvalType -eq 'ConfigurationChange'
    )

    $hasApprovedWorkflow = (
        $null -ne $Status.LatestState -and
        $Status.LatestState.status -eq 'APPROVED'
    )

    if (
        $isNativeArcRegistrationSession -and
        (
            $hasApprovedWorkflow -or
            $isInteractiveAuthenticationPaused
        )
    ) {
        Invoke-NativeArcRegistrationSession `
            -Site $Site `
            -RunnerProfile $RunnerProfile `
            -Status $Status

        return
    }

    if (
        $null -ne $pendingApproval -and
        -not $isInteractiveAuthenticationPaused
    ) {
        $approvalLabel = if ($isNativeArcConfigurationApproval) {
            'approve and start Native Arc Registration Session'
        }
        else {
            (
                "approve $approvalType"
            )
        }

        $confirmation = Read-Host (
            "Type APPROVE to $approvalLabel for operation " +
            "$(
                Get-FactoryObjectValue `
                    -Object $pendingApproval `
                    -Name 'Operation'
            ) on node $(
                Get-FactoryObjectValue `
                    -Object $pendingApproval `
                    -Name 'Node'
            )"
        )

        if ($confirmation -cne 'APPROVE') {
            Write-Host 'Approval canceled.' -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            return
        }

        & "$PSScriptRoot\Set-DeploymentApproval.ps1" `
            -StatePath $Status.LatestStatePath `
            -Decision Approve |
            Out-Null

        if ($isNativeArcConfigurationApproval) {
            Write-Host (
                'Native Arc registration approved. Starting focused registration session.'
            ) -ForegroundColor Green

            Invoke-NativeArcRegistrationSession `
                -Site $Site `
                -RunnerProfile $RunnerProfile `
                -Status $Status

            return
        }

        $resumeStage = [int]$Status.LatestState.returnToStage

        Invoke-FactoryAction `
            -Site $Site `
            -Mode Apply `
            -StartStage $resumeStage `
            -ThroughStage $resumeStage `
            -RunnerProfile $RunnerProfile `
            -Resume `
            -ResumeRunId ([string]$Status.LatestState.runId)

        return
    }

    if ($hasApprovedWorkflow) {
        $resumeStage = [int]$Status.LatestState.returnToStage

        Invoke-FactoryAction `
            -Site $Site `
            -Mode Apply `
            -StartStage $resumeStage `
            -ThroughStage $resumeStage `
            -RunnerProfile $RunnerProfile `
            -Resume `
            -ResumeRunId ([string]$Status.LatestState.runId)

        return
    }

    $hasBlockedWorkflow = (
        -not $Status.ConfigChanged -and
        $null -ne $Status.LatestState -and
        $Status.LatestState.status -eq 'BLOCKED'
    )

    if ($hasBlockedWorkflow) {
        $retryPhase = [int]$Status.LatestState.returnToPhase
        $retryStage = [int]$Status.LatestState.returnToStage

        if ($retryPhase -ne 1 -or $retryStage -lt 1) {
            throw (
                'Blocked workflow state does not contain a valid Phase 1 retry position.'
            )
        }

        Write-Host ''
        Write-Host (
            "The previous workflow attempt is BLOCKED at Stage $retryPhase.$retryStage."
        ) -ForegroundColor Yellow

        Write-Host (
            'Review evidence, correct the issue, and clear cached session credentials if required before retrying.'
        ) -ForegroundColor Yellow

        $confirmation = Read-Host (
            'Type RETRY to intentionally retry the blocked workflow stage'
        )

        if ($confirmation -cne 'RETRY') {
            Write-Host 'Blocked workflow retry canceled.' -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            return
        }

        Invoke-FactoryAction `
            -Site $Site `
            -Mode Apply `
            -StartStage $retryStage `
            -ThroughStage $retryStage `
            -RunnerProfile $RunnerProfile `
            -Resume `
            -ResumeRunId ([string]$Status.LatestState.runId)

        return
    }
    
    if ($nextReadyStage.Count -ne 1) {
        Write-Host (
            'No executable workflow action is currently unlocked. Review status or failure evidence.'
        ) -ForegroundColor Yellow

        Start-Sleep -Seconds 3
        return
    }

    if ($nextReadyStage.Mode -eq 'Validate') {
        Invoke-FactoryAction `
            -Site $Site `
            -Mode Validate `
            -StartStage ([int]$nextReadyStage.StageId) `
            -ThroughStage ([int]$nextReadyStage.StageId) `
            -RunnerProfile $RunnerProfile

        return
    }

    Write-Host ''
    Write-Host (
        "WARNING: Stage $($nextReadyStage.PhaseId)." +
        "$($nextReadyStage.StageId) may change Azure Local node configuration."
    ) -ForegroundColor Yellow

    $confirmation = Read-Host 'Type APPLY to continue'

    if ($confirmation -cne 'APPLY') {
        Write-Host 'Apply canceled.' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    Invoke-FactoryAction `
        -Site $Site `
        -Mode Apply `
        -StartStage ([int]$nextReadyStage.StageId) `
        -ThroughStage ([int]$nextReadyStage.StageId) `
        -RunnerProfile $RunnerProfile
}

function Invoke-CurrentStagePlan {
    param(
        [Parameter(Mandatory)]
        [string]$Site,

        [Parameter(Mandatory)]
        [string]$RunnerProfile,

        [Parameter(Mandatory)]
        [object]$Status
    )

    $nextReadyStage = @(
        Get-NextReadyStage `
            -Status $Status
    )

    if ($nextReadyStage.Count -eq 1) {
        Invoke-FactoryAction `
            -Site $Site `
            -Mode Plan `
            -StartStage ([int]$nextReadyStage.StageId) `
            -ThroughStage ([int]$nextReadyStage.StageId) `
            -RunnerProfile $RunnerProfile

        return
    }

    if (
        $null -ne $Status.LatestState -and
        [int]$Status.LatestState.currentPhase -eq 1 -and
        [int]$Status.LatestState.currentStage -eq 4
    ) {
        Invoke-FactoryAction `
            -Site $Site `
            -Mode Plan `
            -StartStage 4 `
            -ThroughStage 4 `
            -RunnerProfile $RunnerProfile

        return
    }

    Write-Host (
        'No current or next executable stage is available to plan.'
    ) -ForegroundColor Yellow

    Start-Sleep -Seconds 2
}

function Show-DeploymentManagerHelp {
    param(
        [Parameter(Mandatory)]
        [string]$Site
    )

    $documentationRoot = Join-Path `
        $packageRoot `
        'docs'

    $readmePath = Join-Path `
        $documentationRoot `
        'Deployment-Manager-README.md'

    $sopPath = Join-Path `
        $documentationRoot `
        'Deployment-Manager-SOP.html'

    $siteArtifactRoot = Join-Path `
        $artifactsPath `
        $Site

    while ($true) {
        Clear-Host

        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host '             DEPLOYMENT MANAGER HELP AND SOP' -ForegroundColor Cyan
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'A - View Quick Start README in Console'
        Write-Host 'B - Open Deployment Manager SOP in Browser'
        Write-Host 'C - Show Report and Evidence Locations'
        Write-Host 'X - Return to Main Menu'
        Write-Host ''

        $selection = Read-Host 'Select a help action'

        switch ($selection.ToUpperInvariant()) {
            'A' {
                Clear-Host

                if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
                    Write-Host (
                        "Deployment Manager README was not found: $readmePath"
                    ) -ForegroundColor Yellow
                }
                else {
                    Get-Content `
                        -LiteralPath $readmePath `
                        -Raw |
                        Write-Host
                }

                Write-Host ''
                Read-Host 'Press ENTER to continue' |
                    Out-Null
            }

            'B' {
                if (-not (Test-Path -LiteralPath $sopPath -PathType Leaf)) {
                    Write-Host (
                        "Deployment Manager SOP was not found: $sopPath"
                    ) -ForegroundColor Yellow
                }
                else {
                    Write-Host (
                        "Opening Deployment Manager SOP: $sopPath"
                    ) -ForegroundColor Cyan

                    Invoke-Item `
                        -LiteralPath $sopPath
                }

                Read-Host 'Press ENTER to continue' |
                    Out-Null
            }

            'C' {
                Clear-Host

                Write-Host 'REPORT AND EVIDENCE LOCATIONS' -ForegroundColor Cyan
                Write-Host ''
                Write-Host "Site artifact root: $siteArtifactRoot"

                if (
                    Test-Path `
                        -LiteralPath $siteArtifactRoot `
                        -PathType Container
                ) {
                    $latestReport = @(
                        Get-ChildItem `
                            -LiteralPath $siteArtifactRoot `
                            -Recurse `
                            -Filter 'deployment-report.html' `
                            -File `
                            -ErrorAction SilentlyContinue |
                            Sort-Object `
                                LastWriteTimeUtc `
                                -Descending |
                            Select-Object `
                                -First 1
                    ) |
                        Select-Object `
                            -First 1

                    if ($null -ne $latestReport) {
                        $runDirectory = Split-Path `
                            -Path $latestReport.Directory.FullName `
                            -Parent

                        Write-Host ''
                        Write-Host "Latest run directory: $runDirectory"
                        Write-Host "HTML report:          $($latestReport.FullName)"
                        Write-Host (
                            "JSON report:          " +
                            "$(Join-Path $latestReport.Directory.FullName 'deployment-report.json')"
                        )
                        Write-Host (
                            "Execution events:     " +
                            "$(Join-Path $runDirectory 'execution-events.jsonl')"
                        )
                        Write-Host (
                            "Evidence directory:   " +
                            "$(Join-Path $runDirectory 'evidence')"
                        )
                    }
                    else {
                        Write-Host ''
                        Write-Host (
                            'No deployment HTML report exists for this site yet.'
                        ) -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host ''
                    Write-Host (
                        'No artifact directory exists for this site yet.'
                    ) -ForegroundColor Yellow
                }

                Write-Host ''
                Read-Host 'Press ENTER to continue' |
                    Out-Null
            }

            'X' {
                return
            }

            default {
                Write-Host 'Invalid help action selection.' -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
    }
}
function Show-AdvancedActions {
    param(
        [Parameter(Mandatory)]
        [string]$Site,

        [Parameter(Mandatory)]
        [string]$RunnerProfile,

        [Parameter(Mandatory)]
        [object]$Status
    )

    while ($true) {
        Clear-Host

        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host '                    ADVANCED ACTIONS' -ForegroundColor Cyan
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'A - Plan Phase 1.1 Through 1.3'
        Write-Host 'B - Plan Stage 1.4 Azure Arc Registration'
        Write-Host 'C - View Raw Deployment State'
        Write-Host 'D - View Native Arc Bootstrap Status Record'
        Write-Host 'E - Clear Cached Session Credentials'
        Write-Host 'X - Return to Main Menu'
        Write-Host ''

        $selection = Read-Host 'Select an advanced action'

        switch ($selection.ToUpperInvariant()) {
            'A' {
                Invoke-FactoryAction `
                    -Site $Site `
                    -Mode Plan `
                    -ThroughStage 3 `
                    -RunnerProfile $RunnerProfile
            }

            'B' {
                Invoke-FactoryAction `
                    -Site $Site `
                    -Mode Plan `
                    -StartStage 4 `
                    -ThroughStage 4 `
                    -RunnerProfile $RunnerProfile
            }

            'C' {
                if ($null -eq $Status.LatestStatePath) {
                    Write-Host (
                        'No onboarding deployment state exists for this site.'
                    ) -ForegroundColor Yellow
                }
                else {
                    Write-Host (
                        "Latest onboarding state: $($Status.LatestStatePath)"
                    ) -ForegroundColor Cyan

                    $Status.LatestState |
                        ConvertTo-Json `
                            -Depth 30 |
                        Write-Host
                }

                Read-Host 'Press ENTER to continue' |
                    Out-Null
            }

            'D' {
                $nativeSession = $Status.NativeArcRegistrationSession

                $statusRecordPath = [string](
                    Get-FactoryObjectValue `
                        -Object $nativeSession `
                        -Name 'StatusRecordPath'
                )

                if (
                    [string]::IsNullOrWhiteSpace($statusRecordPath) -or
                    -not (
                        Test-Path `
                            -LiteralPath $statusRecordPath `
                            -PathType Leaf
                    )
                ) {
                    Write-Host (
                        'No native Arc bootstrap status record is currently available.'
                    ) -ForegroundColor Yellow
                }
                else {
                    Get-Content `
                        -LiteralPath $statusRecordPath `
                        -Raw |
                        Write-Host
                }

                Read-Host 'Press ENTER to continue' |
                    Out-Null
            }
            
            'E' {
                Clear-ManagerSessionCredentials

                Write-Host ''
                Write-Host (
                    'Cached manager session credentials were cleared.'
                ) -ForegroundColor Yellow

                Write-Host (
                    'The next workflow action will prompt for required ' +
                    'AD DS, Local Administrator, and deployment credentials.'
                ) -ForegroundColor Yellow

                Write-Host (
                    'Azure Government PowerShell sign-in context was not changed.'
                ) -ForegroundColor Cyan

                Write-Host ''
                Read-Host 'Press ENTER to continue' |
                    Out-Null
            }
            
            'X' {
                return
            }

            default {
                Write-Host 'Invalid advanced action selection.' -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
    }
}

$sites = @(Get-AvailableSites)

if ($sites.Count -eq 0) {
    throw 'No operator variables files were found under operator-inputs.'
}

$site = $sites[0]

if ($sites.Count -gt 1) {
    Write-Host 'Available sites:'

    for ($index = 0; $index -lt $sites.Count; $index++) {
        Write-Host "  $($index + 1) - $($sites[$index])"
    }

    $selectedSiteIndex = Read-Host 'Select site number'

    if ($selectedSiteIndex -notmatch '^\d+$') {
        throw 'Invalid site selection.'
    }

    $siteIndex = [int]$selectedSiteIndex - 1

    if ($siteIndex -lt 0 -or $siteIndex -ge $sites.Count) {
        throw 'Selected site number is outside the available range.'
    }

    $site = $sites[$siteIndex]
}

$runnerProfile = Select-RunnerProfile

$workstationResult = & "$PSScriptRoot\Test-OperatorWorkstation.ps1" `
    -PackageRoot $packageRoot `
    -RunnerProfile $runnerProfile

Write-Verbose (
    "Operator workstation validated. Profile={0}; PowerShell={1}; Artifacts={2}" -f
    $workstationResult.RunnerProfile,
    $workstationResult.PowerShell,
    $workstationResult.ArtifactsPath
)

    try {
        while ($true) {
            try {
                # -----------------------------------------------------------------
                # Keep the existing code here that:
                # - runs Merge-FactoryConfiguration.ps1
                # - runs Get-DeploymentManagerStatus.ps1
                # - writes the manager header
                # - determines recommended action
                # - writes the Actions menu
                # -----------------------------------------------------------------

                $mergeResult = & "$PSScriptRoot\Merge-FactoryConfiguration.ps1" `
                    -PackageRoot $packageRoot `
                    -Site $site `
                    -ArtifactsPath $artifactsPath

                $status = & "$PSScriptRoot\Get-DeploymentManagerStatus.ps1" `
                    -ArtifactsPath $artifactsPath `
                    -Site $site `
                    -PhaseManifestPath $phaseManifestPath `
                    -CurrentConfigHash $mergeResult.ResolvedConfigHash `
                    -RunnerProfile $runnerProfile

                Write-ManagerSummaryHeader `
                    -Site $site `
                    -RunnerProfile $runnerProfile `
                    -DisplayVersion $displayVersion `
                    -Status $status

                $nextReadyStage = @(
                    Get-NextReadyStage `
                        -Status $status
                )

                $pendingApproval = $status.PendingApproval

                $approvalType = [string](
                    Get-FactoryObjectValue `
                        -Object $pendingApproval `
                        -Name 'ApprovalType'
                )

                $isInteractiveAuthenticationPaused = (
                    $null -ne $pendingApproval -and
                    $approvalType -eq 'InteractiveAuthentication'
                )

                $isNativeArcRegistrationSession = (
                    $null -ne $status.NativeArcRegistrationSession
                )

                $isNativeArcConfigurationApproval = (
                    $isNativeArcRegistrationSession -and
                    -not $isInteractiveAuthenticationPaused -and
                    $null -ne $pendingApproval -and
                    $approvalType -eq 'ConfigurationChange'
                )

                $hasConfigurationApproval = (
                    $null -ne $pendingApproval -and
                    -not $isInteractiveAuthenticationPaused
                )

                $hasApprovedWorkflow = (
                    $null -ne $status.LatestState -and
                    $status.LatestState.status -eq 'APPROVED'
                )

                $hasBlockedWorkflow = (
                    -not $status.ConfigChanged -and
                    $null -ne $status.LatestState -and
                    $status.LatestState.status -eq 'BLOCKED'
                )

                $hasNativeArcSessionResume = (
                    $isNativeArcRegistrationSession -and
                    (
                        $hasApprovedWorkflow -or
                        $isInteractiveAuthenticationPaused
                    )
                )

                Write-Host 'NEXT RECOMMENDED ACTION' -ForegroundColor Cyan

                if ($hasNativeArcSessionResume) {
                    Write-Host (
                        '  Start or Resume Native Arc Registration Session'
                    ) -ForegroundColor Green
                }
                elseif ($isNativeArcConfigurationApproval) {
                    Write-Host (
                        '  Approve and Start or Resume Native Arc Registration Session'
                    ) -ForegroundColor Yellow
                }
                elseif ($hasConfigurationApproval) {
                    Write-Host (
                        '  Approve Pending Configuration Change or Reboot'
                    ) -ForegroundColor Yellow
                }
                elseif ($hasBlockedWorkflow) {
                    Write-Host (
                        '  Review Blocked Failure, Clear Credentials if Needed, Then Retry Intentionally'
                    ) -ForegroundColor Yellow
                }
                elseif ($hasApprovedWorkflow) {
                    Write-Host (
                        '  Resume Approved Workflow'
                    ) -ForegroundColor Green
                }
                elseif ($nextReadyStage.Count -eq 1) {
                    Write-Host (
                        "  $($nextReadyStage.Mode) Stage " +
                        "$($nextReadyStage.PhaseId)." +
                        "$($nextReadyStage.StageId) - " +
                        "$($nextReadyStage.DisplayName)"
                    ) -ForegroundColor Green
                }
                else {
                    Write-Host (
                        '  Review workflow status, failure evidence, or read-only validation.'
                    ) -ForegroundColor Yellow
                }

                Write-Host ''
                Write-Host 'Actions'
                Write-Host '  1 - Continue Recommended Workflow Action'
                Write-Host '  2 - Plan Current/Next Stage'
                Write-Host '  3 - Show Current Workflow Status'
                Write-Host '  4 - Run Read-Only Validation'
                Write-Host '  5 - View Last Failure and Evidence'
                Write-Host '  6 - Show Workflow Map'
                Write-Host '  7 - Advanced Actions'
                Write-Host '  8 - Help and Deployment Manager SOP'
                Write-Host '  9 - Exit'
                Write-Host ''

                # Keep exactly one selection prompt.
                $selection = Read-Host 'Select an option'

                switch ($selection.ToUpperInvariant()) {
                    '1' {
                        Invoke-RecommendedWorkflowAction `
                            -Site $site `
                            -RunnerProfile $runnerProfile `
                            -Status $status
                    }

                    '2' {
                        Invoke-CurrentStagePlan `
                            -Site $site `
                            -RunnerProfile $runnerProfile `
                            -Status $status
                    }

                    '3' {
                        Write-CurrentWorkflowStatus `
                            -Site $site `
                            -RunnerProfile $runnerProfile `
                            -DisplayVersion $displayVersion `
                            -Status $status
                    }

                    '4' {
                        & "$PSScriptRoot\Start-ReadOnlyValidation.ps1" `
                            -PackageRoot $packageRoot `
                            -ArtifactsPath $artifactsPath `
                            -Site $site `
                            -RunnerProfile $runnerProfile

                        Read-Host (
                            'Read-only validation completed. Press ENTER to return to the Deployment Manager'
                        ) |
                            Out-Null
                    }

                    '5' {
                        if ($null -eq $status.LastFailure) {
                            Write-Host (
                                'No recorded onboarding failure exists for this site.'
                            ) -ForegroundColor Green
                        }
                        else {
                            Write-Host ''
                            Write-Host 'LAST ONBOARDING FAILURE' -ForegroundColor Red
                            Write-Host "Stage:    $($status.LastFailure.StageId)"
                            Write-Host "Time:     $($status.LastFailure.Timestamp)"
                            Write-Host "Reason:   $($status.LastFailure.Reason)"
                            Write-Host "Evidence: $($status.LastFailure.Evidence)"
                        }

                        Read-Host 'Press ENTER to continue' |
                            Out-Null
                    }

                    '6' {
                        Write-WorkflowMap `
                            -Status $status
                    }

                    '7' {
                        Show-AdvancedActions `
                            -Site $site `
                            -RunnerProfile $runnerProfile `
                            -Status $status
                    }

                    '8' {
                        Show-DeploymentManagerHelp `
                            -Site $site
                    }

                    '9' {
                        Clear-ManagerSessionCredentials

                        Write-Host (
                            'Exiting Azure Local Deployment Manager.'
                        ) -ForegroundColor Cyan

                        return
                    }

                    default {
                        Write-Host 'Invalid menu selection.' -ForegroundColor Red
                        Start-Sleep -Seconds 2
                    }
                }
            }
                    catch {
            $safeReason = Protect-ManagerErrorMessage `
                -Message $_.Exception.Message

            Write-Host ''
            Write-Host 'DEPLOYMENT MANAGER ACTION FAILED' -ForegroundColor Red
            Write-Host ''
            Write-Host "Reason: $safeReason" -ForegroundColor Red
            Write-Host ''

            Write-Host (
                'The Deployment Manager remains active. Review workflow status, ' +
                'failure evidence, and deployment reports before retrying.'
            ) -ForegroundColor Yellow

            Write-Host ''
            Read-Host 'Press ENTER to return to the Deployment Manager' |
                Out-Null
        }
    }
}
finally {
    Clear-ManagerSessionCredentials
}