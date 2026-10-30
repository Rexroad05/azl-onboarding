#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ArtifactsPath,

    [Parameter(Mandatory)]
    [string]$Site,

    [Parameter(Mandatory)]
    [string]$PhaseManifestPath,

    [Parameter(Mandatory)]
    [string]$CurrentConfigHash,

    [string]$RunnerProfile = 'AzureLocalExecution'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop

function Get-StatusValue {
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

function Test-NativeArcRegistrationSession {
    param(
        [AllowNull()]
        [object]$PendingApproval
    )

    if ($null -eq $PendingApproval) {
        return $false
    }

    $operation = [string](
        Get-StatusValue `
            -Object $PendingApproval `
            -Name 'Operation'
    )

    $workflow = [string](
        Get-StatusValue `
            -Object $PendingApproval `
            -Name 'Workflow'
    )

    $phaseId = Get-StatusValue `
        -Object $PendingApproval `
        -Name 'PhaseId'

    $stageId = Get-StatusValue `
        -Object $PendingApproval `
        -Name 'StageId'

    return (
        $operation -eq 'Register-ArcNode' -and
        [int]$phaseId -eq 1 -and
        [int]$stageId -eq 4 -and
        (
            $workflow -eq 'NativeAzureLocalBootstrap' -or
            [string]::IsNullOrWhiteSpace($workflow)
        )
    )
}

$phaseManifest = Get-Content `
    -LiteralPath $PhaseManifestPath `
    -Raw |
    ConvertFrom-Yaml `
    -Ordered

$siteArtifactPath = Join-Path `
    $ArtifactsPath `
    $Site

$latestState = $null
$latestStatePath = $null

if (Test-Path -LiteralPath $siteArtifactPath -PathType Container) {
    $stateFiles = @(
        Get-ChildItem `
            -LiteralPath $siteArtifactPath `
            -Filter deployment-state.json `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending
    )

    foreach ($stateFile in $stateFiles) {
        try {
            $candidateState = Get-Content `
                -LiteralPath $stateFile.FullName `
                -Raw |
                ConvertFrom-Json `
                -AsHashtable
        }
        catch {
            continue
        }

        if (
            $candidateState.mode -eq 'Plan' -or
            $candidateState.status -eq 'PLAN_COMPLETE'
        ) {
            continue
        }

        $latestState = $candidateState
        $latestStatePath = $stateFile.FullName
        break
    }
}

$configChanged = $false

if (
    $null -ne $latestState -and
    $latestState.Contains('configHash') -and
    $latestState.configHash -ne $CurrentConfigHash
) {
    $configChanged = $true
}

$pendingApproval = $null
$pendingInteractiveAuthentication = $null
$focusedOperation = $null

if (
    $null -ne $latestState -and
    $latestState.Contains('pendingApproval') -and
    $null -ne $latestState.pendingApproval
) {
    $pendingApproval = $latestState.pendingApproval
}

if (
    $null -ne $latestState -and
    $latestState.Contains('pendingInteractiveAuthentication') -and
    $null -ne $latestState.pendingInteractiveAuthentication
) {
    $pendingInteractiveAuthentication = `
        $latestState.pendingInteractiveAuthentication
}

if (
    $null -ne $latestState -and
    $latestState.Contains('returnToOperation') -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$latestState.returnToOperation
    )
) {
    $focusedOperation = [string]$latestState.returnToOperation
}

$nativeArcRegistrationSession = $null

if (Test-NativeArcRegistrationSession -PendingApproval $pendingApproval) {
    $nativeArcRegistrationSession = $pendingApproval
}
elseif (
    Test-NativeArcRegistrationSession `
        -PendingApproval $pendingInteractiveAuthentication
) {
    $nativeArcRegistrationSession = `
        $pendingInteractiveAuthentication
}

$phaseResults = [System.Collections.Generic.List[object]]::new()

foreach ($phase in @($phaseManifest.workflow.phases)) {
    $phaseId = [int]$phase.id
    $implemented = [bool]$phase.implemented
    $stageResults = [System.Collections.Generic.List[object]]::new()

    foreach ($stage in @($phase.stages)) {
        $stageId = [int]$stage.id
        $stageKey = [string]$stageId
        $status = 'LOCKED'
        $reason = $null

        if (-not $implemented) {
            $status = 'NOT_IMPLEMENTED'
            $reason = (
                'Phase is declared but does not contain approved executable operations.'
            )
        }
        elseif ($phaseId -eq 1) {
            if ($null -eq $latestState) {
                if ($stageId -eq 1) {
                    $status = 'READY'
                }
            }
            elseif ($configChanged) {
                if ($stageId -eq 1) {
                    $status = 'READY'
                    $reason = (
                        'Configuration or protected package changed. ' +
                        'Stage 1.1 must be revalidated.'
                    )
                }
                else {
                    $status = 'LOCKED'
                    $reason = (
                        'Configuration changed. Earlier validation evidence is no longer current.'
                    )
                }
            }
            elseif (
                $latestState.status -eq 'PAUSED' -and
                $null -ne $pendingApproval -and
                [int](Get-StatusValue -Object $pendingApproval -Name 'PhaseId') -eq $phaseId -and
                [int](Get-StatusValue -Object $pendingApproval -Name 'StageId') -eq $stageId
            ) {
                $status = 'PAUSED'

                $approvalType = [string](
                    Get-StatusValue `
                        -Object $pendingApproval `
                        -Name 'ApprovalType'
                )

                if (
                    $approvalType -eq 'InteractiveAuthentication' -and
                    (
                        Test-NativeArcRegistrationSession `
                            -PendingApproval $pendingApproval
                    )
                ) {
                    $reason = (
                        'Native Azure Local Arc registration session is awaiting ' +
                        'interactive device-code completion. ' +
                        [string](
                            Get-StatusValue `
                                -Object $pendingApproval `
                                -Name 'Reason'
                        )
                    )
                }
                elseif ($approvalType -eq 'InteractiveAuthentication') {
                    $reason = (
                        'Interactive device-code authentication is awaiting completion. ' +
                        [string](
                            Get-StatusValue `
                                -Object $pendingApproval `
                                -Name 'Reason'
                        )
                    )
                }
                elseif ($approvalType -eq 'Reboot') {
                    $reason = (
                        'Approved configuration change requires a separately approved reboot. ' +
                        [string](
                            Get-StatusValue `
                                -Object $pendingApproval `
                                -Name 'Reason'
                        )
                    )
                }
                else {
                    $reason = [string](
                        Get-StatusValue `
                            -Object $pendingApproval `
                            -Name 'Reason'
                    )
                }
            }
            elseif (
                $latestState.status -eq 'APPROVED' -and
                $null -ne $pendingApproval -and
                [int](Get-StatusValue -Object $pendingApproval -Name 'PhaseId') -eq $phaseId -and
                [int](Get-StatusValue -Object $pendingApproval -Name 'StageId') -eq $stageId
            ) {
                $status = 'APPROVED'

                $approvalType = [string](
                    Get-StatusValue `
                        -Object $pendingApproval `
                        -Name 'ApprovalType'
                )

                if ($approvalType -eq 'Reboot') {
                    $reason = (
                        'Pending reboot was approved. Resume will reboot, reconnect, ' +
                        'and revalidate the affected node.'
                    )
                }
                elseif (
                    (
                        Test-NativeArcRegistrationSession `
                            -PendingApproval $pendingApproval
                    )
                ) {
                    $reason = (
                        'Native Azure Local Arc registration was approved. ' +
                        'Start the focused registration session.'
                    )
                }
                else {
                    $reason = (
                        'Pending configuration change was approved. Resume is required.'
                    )
                }
            }
            elseif (
                $latestState.status -eq 'DENIED' -and
                $null -ne $pendingApproval -and
                [int](Get-StatusValue -Object $pendingApproval -Name 'PhaseId') -eq $phaseId -and
                [int](Get-StatusValue -Object $pendingApproval -Name 'StageId') -eq $stageId
            ) {
                $status = 'DENIED'

                $approvalType = [string](
                    Get-StatusValue `
                        -Object $pendingApproval `
                        -Name 'ApprovalType'
                )

                if ($approvalType -eq 'Reboot') {
                    $reason = 'Pending reboot was denied by the operator.'
                }
                else {
                    $reason = 'Pending configuration change was denied by the operator.'
                }
            }
            
            elseif (
                $latestState.status -eq 'BLOCKED' -and
                $latestState.Contains('returnToPhase') -and
                $latestState.Contains('returnToStage') -and
                [int]$latestState.returnToPhase -eq $phaseId -and
                [int]$latestState.returnToStage -eq $stageId
            ) {
                $status = 'BLOCKED'

                $reason = (
                    'Previous execution blocked at this stage. Review failure evidence, ' +
                    'correct the issue, clear cached credentials if applicable, and use ' +
                    'Continue Recommended Workflow Action to intentionally retry.'
                )
            }
            elseif (
                $latestState.Contains('stages') -and
                $latestState.stages.Contains($stageKey) -and
                $latestState.stages[$stageKey].status -eq 'PASS'
            ) {
                $status = 'PASS'
            }
            elseif (
                $latestState.Contains('stages') -and
                $latestState.stages.Contains($stageKey) -and
                $latestState.stages[$stageKey].status -eq 'FAIL'
            ) {
                $status = 'BLOCKED'
                $reason = [string]$latestState.stages[$stageKey].reason
            }
            elseif ($stageId -eq 1) {
                $status = 'READY'
            }
            else {
                $previousStageKey = [string]($stageId - 1)

                if (
                    $latestState.Contains('stages') -and
                    $latestState.stages.Contains($previousStageKey) -and
                    $latestState.stages[$previousStageKey].status -eq 'PASS'
                ) {
                    $status = 'READY'
                }
            }
        }

        $stageResults.Add([pscustomobject]@{
            PhaseId = $phaseId
            StageId = $stageId
            Name = [string]$stage.name
            DisplayName = [string]$stage.display_name
            Mode = [string]$stage.mode
            Status = $status
            Reason = $reason
        })
    }

    $phaseResults.Add([pscustomobject]@{
        PhaseId = $phaseId
        Name = [string]$phase.name
        DisplayName = [string]$phase.display_name
        Implemented = $implemented
        Stages = $stageResults.ToArray()
    })
}

$lastFailure = $null

if (
    $null -ne $latestState -and
    $latestState.Contains('stages')
) {
    $failedStages = @(
        $latestState.stages.GetEnumerator() |
            Where-Object {
                $_.Value.status -eq 'FAIL'
            } |
            Sort-Object {
                [datetime]$_.Value.timestamp
            } -Descending
    )

    if ($failedStages.Count -gt 0) {
        $lastFailure = [pscustomobject]@{
            StageId = $failedStages[0].Key
            Reason = [string]$failedStages[0].Value.reason
            Timestamp = [string]$failedStages[0].Value.timestamp
            Evidence = $latestStatePath
        }
    }
}

return [pscustomobject]@{
    Site = $Site
    RunnerProfile = $RunnerProfile
    ConfigChanged = $configChanged
    LatestStatePath = $latestStatePath
    LatestState = $latestState
    Phases = $phaseResults.ToArray()
    LastFailure = $lastFailure
    PendingApproval = $pendingApproval
    PendingInteractiveAuthentication = $pendingInteractiveAuthentication
    NativeArcRegistrationSession = $nativeArcRegistrationSession
    FocusedOperation = $focusedOperation
    RetrievedAtUtc = [datetime]::UtcNow.ToString('o')
}