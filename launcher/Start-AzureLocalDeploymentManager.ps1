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

function Write-ManagerHeader {
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

    Clear-Host

    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '        AZURE LOCAL DEPLOYMENT MANAGER' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "Site:            $Site"
    Write-Host "Runner Profile:  $RunnerProfile"
    Write-Host "Artifacts:       $artifactsPath"
    Write-Host "Package Version: $DisplayVersion"
    Write-Host ''

    foreach ($phase in @($Status.Phases)) {
        Write-Host $phase.DisplayName -ForegroundColor Cyan

        foreach ($stage in @($phase.Stages)) {
            $color = switch ($stage.Status) {
                'PASS'            { 'Green' }
                'READY'           { 'Green' }
                'PAUSED'          { 'Yellow' }
                'APPROVED'        { 'Cyan' }
                'DENIED'          { 'Red' }
                'BLOCKED'         { 'Red' }
                'FAIL'            { 'Red' }
                'LOCKED'          { 'DarkYellow' }
                'NOT_IMPLEMENTED' { 'DarkGray' }
                default           { 'White' }
            }

            $line = '  {0,-5} {1,-52} {2}' -f `
                ("$($stage.PhaseId).$($stage.StageId)"),
                $stage.DisplayName,
                $stage.Status

            Write-Host $line -ForegroundColor $color
        }

        Write-Host ''
    }

    if ($null -ne $Status.NativeArcRegistrationSession) {
        $session = $Status.NativeArcRegistrationSession

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
        Write-Host (
            "  Status Record:     $(
                Get-FactoryObjectValue `
                    -Object $session `
                    -Name 'StatusRecordPath'
            )"
        )
        Write-Host (
            "  Resume Operation:  $(
                Get-FactoryObjectValue `
                    -Object $session `
                    -Name 'ReturnToOperation'
            )"
        )
        Write-Host ''
    }
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
        Write-Host '  Bootstrap-local administrator credential initialization: required.'
    }
    else {
        Write-Host '  Bootstrap-local administrator credential initialization: not required.'
    }

    if ($requiresDeploymentPassword) {
        Write-Host '  Deployment password initialization: required.'
    }
    else {
        Write-Host '  Deployment password initialization: not required.'
    }

    Write-Host ''

    $session = $null
    $certificateValidationState = $null

    try {
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
    }
    finally {
        if ($null -ne $session -and $null -ne $session.Cleanup) {
            & $session.Cleanup `
                $session.CreatedEnvironmentVariables
        }

        Restore-WorkflowWinRmCertificateValidation `
            -State $certificateValidationState
    }

    Read-Host 'Press ENTER to return to the Deployment Manager'
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
        -Site $Site `
        -Mode Apply `
        -StartStage 4 `
        -ThroughStage 4 `
        -StartOperation 'Register-ArcNode' `
        -RunnerProfile $RunnerProfile `
        -Resume `
        -ResumeRunId ([string]$Status.LatestState.runId)
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

while ($true) {
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

    Write-ManagerHeader `
        -Site $site `
        -RunnerProfile $runnerProfile `
        -DisplayVersion $displayVersion `
        -Status $status

    $nextReadyStage = @(Get-NextReadyStage -Status $status)

    $isInteractiveAuthenticationPaused = (
        $null -ne $status.PendingApproval -and
        [string](
            Get-FactoryObjectValue `
                -Object $status.PendingApproval `
                -Name 'ApprovalType'
        ) -eq 'InteractiveAuthentication'
    )

    $isNativeArcRegistrationSession = (
        $null -ne $status.NativeArcRegistrationSession
    )

    $isNativeArcConfigurationApproval = (
        $isNativeArcRegistrationSession -and
        -not $isInteractiveAuthenticationPaused -and
        $null -ne $status.PendingApproval -and
        [string](
            Get-FactoryObjectValue `
                -Object $status.PendingApproval `
                -Name 'ApprovalType'
        ) -eq 'ConfigurationChange'
    )

    $hasConfigurationApproval = (
        $null -ne $status.PendingApproval -and
        -not $isInteractiveAuthenticationPaused
    )

    $hasApprovedWorkflow = (
        $null -ne $status.LatestState -and
        $status.LatestState.status -eq 'APPROVED'
    )

    $hasNativeArcSessionResume = (
        $isNativeArcRegistrationSession -and
        (
            $hasApprovedWorkflow -or
            $isInteractiveAuthenticationPaused
        )
    )

    if ($hasNativeArcSessionResume) {
        Write-Host (
            'Next Allowed Action: Start or resume the focused Native Arc Registration Session.'
        ) -ForegroundColor Green
    }
    elseif ($nextReadyStage.Count -eq 1) {
        Write-Host (
            "Next Allowed Action: $($nextReadyStage.Mode) " +
            "Stage $($nextReadyStage.PhaseId).$($nextReadyStage.StageId) - " +
            "$($nextReadyStage.DisplayName)"
        ) -ForegroundColor Green
    }
    elseif ($isInteractiveAuthenticationPaused) {
        Write-Host (
            'Next Allowed Action: Resume focused interactive authentication.'
        ) -ForegroundColor Yellow
    }
    elseif ($hasConfigurationApproval) {
        Write-Host (
            'Next Allowed Action: Approve or deny the pending configuration change.'
        ) -ForegroundColor Yellow
    }
    elseif ($hasApprovedWorkflow) {
        Write-Host (
            'Next Allowed Action: Resume approved workflow.'
        ) -ForegroundColor Green
    }
    else {
        Write-Host (
            'Next Allowed Action: Review Status, Failure Evidence, or Read-Only Validation.'
        ) -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Actions'
    Write-Host '  1 - Run Next Onboarding Validation Stage'
    Write-Host '  2 - Plan Phase 1.1 Through 1.3 Onboarding Workflow'
    Write-Host '  A - Plan Stage 1.4 Azure Arc Registration'
    Write-Host '  3 - Apply Next Onboarding Stage'
    Write-Host '  4 - Run Read-Only Validation'
    Write-Host '  5 - View Status and Evidence'
    Write-Host '  6 - View Last Failure'

    if ($hasConfigurationApproval) {
        if ($isNativeArcConfigurationApproval) {
            Write-Host '  7 - Approve and Start Native Arc Registration Session'
            Write-Host '  8 - Deny Native Arc Registration Session'
        }
        else {
            Write-Host '  7 - Approve Pending Configuration Change or Reboot'
            Write-Host '  8 - Deny Pending Configuration Change or Reboot'
        }
    }

    if ($hasNativeArcSessionResume) {
        Write-Host '  N - Start or Resume Native Arc Registration Session'
    }
    elseif ($hasApprovedWorkflow -or $isInteractiveAuthenticationPaused) {
        if ($isInteractiveAuthenticationPaused) {
            Write-Host '  R - Resume Interactive Authentication'
        }
        else {
            Write-Host '  R - Resume Approved Workflow'
        }
    }

    Write-Host '  9 - Exit'
    Write-Host ''

    if ($null -ne $status.PendingApproval) {
        if ($isNativeArcRegistrationSession) {
            Write-Host 'NATIVE ARC REGISTRATION STATE' -ForegroundColor Yellow
        }
        elseif ($isInteractiveAuthenticationPaused) {
            Write-Host 'PENDING INTERACTIVE AUTHENTICATION' -ForegroundColor Yellow
        }
        else {
            Write-Host 'PENDING OPERATOR APPROVAL' -ForegroundColor Yellow
        }

        Write-Host (
            "Phase:     $(
                Get-FactoryObjectValue `
                    -Object $status.PendingApproval `
                    -Name 'PhaseId'
            )"
        )
        Write-Host (
            "Stage:     $(
                Get-FactoryObjectValue `
                    -Object $status.PendingApproval `
                    -Name 'StageId'
            )"
        )
        Write-Host (
            "Operation: $(
                Get-FactoryObjectValue `
                    -Object $status.PendingApproval `
                    -Name 'Operation'
            )"
        )
        Write-Host (
            "Type:      $(
                Get-FactoryObjectValue `
                    -Object $status.PendingApproval `
                    -Name 'ApprovalType'
            )"
        )
        Write-Host (
            "Node:      $(
                Get-FactoryObjectValue `
                    -Object $status.PendingApproval `
                    -Name 'Node'
            )"
        )
        Write-Host (
            "Reason:    $(
                Get-FactoryObjectValue `
                    -Object $status.PendingApproval `
                    -Name 'Reason'
            )"
        )

        if ($isNativeArcRegistrationSession) {
            Write-Host (
                "Bootstrap: $(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'BootstrapStatus'
                )"
            )
            Write-Host (
                "Status:    $(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'StatusRecordPath'
                )"
            )
            Write-Host (
                "Checked:   $(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'LastCheckedAtUtc'
                )"
            )
        }
        elseif ($isInteractiveAuthenticationPaused) {
            Write-Host (
                "Auth:      $(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'AuthenticationMethod'
                )"
            )
            Write-Host (
                "Log:       $(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'LogPath'
                )"
            )
        }

        if (
            (
                Get-FactoryObjectValue `
                    -Object $status.PendingApproval `
                    -Name 'RequiresReboot'
            ) -eq $true
        ) {
            Write-Host (
                'Reboot:    Separate reboot approval and reconnect are required'
            )
        }

        $reconnectTarget = [string](
            Get-FactoryObjectValue `
                -Object $status.PendingApproval `
                -Name 'ReconnectTarget'
        )

        if (-not [string]::IsNullOrWhiteSpace($reconnectTarget)) {
            Write-Host "Reconnect: $reconnectTarget"
        }

        Write-Host ''
    }

    $selection = Read-Host 'Select an option'

    switch ($selection.ToUpperInvariant()) {
        '1' {
            if ($nextReadyStage.Count -ne 1) {
                Write-Host (
                    'No onboarding validation stage is currently unlocked.'
                ) -ForegroundColor Yellow

                Start-Sleep -Seconds 2
                continue
            }

            if ($nextReadyStage.Mode -ne 'Validate') {
                Write-Host (
                    'The next unlocked stage requires Apply. Use option 3.'
                ) -ForegroundColor Yellow

                Start-Sleep -Seconds 3
                continue
            }

            Invoke-FactoryAction `
                -Site $site `
                -Mode Validate `
                -StartStage ([int]$nextReadyStage.StageId) `
                -ThroughStage ([int]$nextReadyStage.StageId) `
                -RunnerProfile $runnerProfile
        }

        '2' {
            Invoke-FactoryAction `
                -Site $site `
                -Mode Plan `
                -ThroughStage 3 `
                -RunnerProfile $runnerProfile
        }

        'A' {
            Invoke-FactoryAction `
                -Site $site `
                -Mode Plan `
                -StartStage 4 `
                -ThroughStage 4 `
                -RunnerProfile $runnerProfile
        }

        '3' {
            if ($nextReadyStage.Count -ne 1) {
                Write-Host (
                    'No Apply stage is currently unlocked.'
                ) -ForegroundColor Yellow

                Start-Sleep -Seconds 3
                continue
            }

            if ($nextReadyStage.Mode -ne 'Apply') {
                Write-Host (
                    'The next unlocked stage is a validation stage. Use option 1.'
                ) -ForegroundColor Yellow

                Start-Sleep -Seconds 3
                continue
            }

            Write-Host ''
            Write-Host (
                "WARNING: Stage $($nextReadyStage.PhaseId)." +
                "$($nextReadyStage.StageId) may change HCN configuration."
            ) -ForegroundColor Yellow

            $confirmation = Read-Host 'Type APPLY to continue'

            if ($confirmation -cne 'APPLY') {
                Write-Host 'Apply canceled.' -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }

            Invoke-FactoryAction `
                -Site $site `
                -Mode Apply `
                -StartStage ([int]$nextReadyStage.StageId) `
                -ThroughStage ([int]$nextReadyStage.StageId) `
                -RunnerProfile $runnerProfile
        }

        '4' {
            & "$PSScriptRoot\Start-ReadOnlyValidation.ps1" `
                -PackageRoot $packageRoot `
                -ArtifactsPath $artifactsPath `
                -Site $site `
                -RunnerProfile $runnerProfile

            Read-Host `
                'Read-only validation completed. Press ENTER to return to the Deployment Manager' |
                Out-Null
        }

        '5' {
            if ($null -eq $status.LatestStatePath) {
                Write-Host (
                    'No onboarding deployment state exists for this site.'
                ) -ForegroundColor Yellow
            }
            else {
                Write-Host (
                    "Latest onboarding state: $($status.LatestStatePath)"
                ) -ForegroundColor Cyan

                $status.LatestState |
                    ConvertTo-Json -Depth 30 |
                    Write-Host
            }

            Read-Host 'Press ENTER to continue'
        }

        '6' {
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

            Read-Host 'Press ENTER to continue'
        }

        '7' {
            if (-not $hasConfigurationApproval) {
                Write-Host (
                    'No pending configuration or reboot approval exists.'
                ) -ForegroundColor Yellow

                Start-Sleep -Seconds 2
                continue
            }

            $approvalLabel = if ($isNativeArcConfigurationApproval) {
                'approve and start Native Arc Registration Session'
            }
            else {
                (
                    "approve $(
                        Get-FactoryObjectValue `
                            -Object $status.PendingApproval `
                            -Name 'ApprovalType'
                    )"
                )
            }

            $confirmation = Read-Host (
                "Type APPROVE to $approvalLabel for operation " +
                "$(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'Operation'
                ) on node $(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'Node'
                )"
            )

            if ($confirmation -cne 'APPROVE') {
                Write-Host 'Approval canceled.' -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }

            & "$PSScriptRoot\Set-DeploymentApproval.ps1" `
                -StatePath $status.LatestStatePath `
                -Decision Approve |
                Out-Null

            if ($isNativeArcConfigurationApproval) {
                Write-Host (
                    'Native Arc registration approved. Starting focused registration session.'
                ) -ForegroundColor Green

                Invoke-NativeArcRegistrationSession `
                    -Site $site `
                    -RunnerProfile $runnerProfile `
                    -Status $status

                continue
            }

            Write-Host (
                "$(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'ApprovalType'
                ) approved. Select Resume Approved Workflow."
            ) -ForegroundColor Green

            Read-Host 'Press ENTER to continue'
        }

        '8' {
            if (-not $hasConfigurationApproval) {
                Write-Host (
                    'No pending configuration or reboot approval exists.'
                ) -ForegroundColor Yellow

                Start-Sleep -Seconds 2
                continue
            }

            $confirmation = Read-Host (
                "Type DENY to deny $(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'ApprovalType'
                ) for operation $(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'Operation'
                ) on node $(
                    Get-FactoryObjectValue `
                        -Object $status.PendingApproval `
                        -Name 'Node'
                )"
            )

            if ($confirmation -cne 'DENY') {
                Write-Host 'Denial canceled.' -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }

            & "$PSScriptRoot\Set-DeploymentApproval.ps1" `
                -StatePath $status.LatestStatePath `
                -Decision Deny |
                Out-Null

            Write-Host (
                'Pending workflow action denied. Onboarding workflow remains blocked.'
            ) -ForegroundColor Yellow

            Read-Host 'Press ENTER to continue'
        }

        'N' {
            if (-not $hasNativeArcSessionResume) {
                Write-Host (
                    'No approved or paused Native Arc Registration Session is available.'
                ) -ForegroundColor Yellow

                Start-Sleep -Seconds 2
                continue
            }

            Invoke-NativeArcRegistrationSession `
                -Site $site `
                -RunnerProfile $runnerProfile `
                -Status $status
        }

        'R' {
            if ($hasNativeArcSessionResume) {
                Invoke-NativeArcRegistrationSession `
                    -Site $site `
                    -RunnerProfile $runnerProfile `
                    -Status $status

                continue
            }

            if (-not ($hasApprovedWorkflow -or $isInteractiveAuthenticationPaused)) {
                Write-Host (
                    'No approved workflow or interactive authentication pause is available for resume.'
                ) -ForegroundColor Yellow

                Start-Sleep -Seconds 2
                continue
            }

            $resumeStage = [int]$status.LatestState.returnToStage

            Invoke-FactoryAction `
                -Site $site `
                -Mode Apply `
                -StartStage $resumeStage `
                -ThroughStage $resumeStage `
                -RunnerProfile $runnerProfile `
                -Resume `
                -ResumeRunId ([string]$status.LatestState.runId)
        }

        '9' {
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