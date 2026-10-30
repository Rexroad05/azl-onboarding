#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Environment,

    [ValidateSet('Plan', 'Validate', 'Apply')]
    [string]$Mode = 'Plan',

    [ValidateRange(1, 4)]
    [int]$PhaseId = 1,

    [ValidateRange(0, 99)]
    [int]$ThroughStage = 0,

    [ValidateRange(1, 99)]
    [int]$StartStage = 1,

    [string]$StartOperation,

    [string]$ArtifactsPath = (Join-Path $PSScriptRoot '..\artifacts'),

    [string]$RunId = (
        [datetime]::UtcNow.ToString('yyyyMMddTHHmmss') +
        '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    ),

    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop
Import-Module "$PSScriptRoot\Factory.psm1" -Force

function Save-FactoryState {
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Write-FactoryJson `
        -Value $State `
        -Path $Path
}

function Get-StateValue {
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

function Get-PendingApprovalType {
    param(
        [AllowNull()]
        [object]$PendingApproval
    )

    return [string](
        Get-StateValue `
            -Object $PendingApproval `
            -Name 'ApprovalType'
    )
}

function Get-PendingApprovalOperation {
    param(
        [AllowNull()]
        [object]$PendingApproval
    )

    return [string](
        Get-StateValue `
            -Object $PendingApproval `
            -Name 'Operation'
    )
}

function Get-PendingApprovalPhaseId {
    param(
        [AllowNull()]
        [object]$PendingApproval
    )

    $value = Get-StateValue `
        -Object $PendingApproval `
        -Name 'PhaseId'

    if ($null -eq $value) {
        return $null
    }

    return [int]$value
}

function Get-PendingApprovalStageId {
    param(
        [AllowNull()]
        [object]$PendingApproval
    )

    $value = Get-StateValue `
        -Object $PendingApproval `
        -Name 'StageId'

    if ($null -eq $value) {
        return $null
    }

    return [int]$value
}

function Initialize-FactoryState {
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string]$ConfigHash,

        [Parameter(Mandatory)]
        [string]$Mode,

        [Parameter(Mandatory)]
        [int]$PhaseId
    )

    $state = @{
        schemaVersion = 'phase-package-v1'
        site = $Config.site.name
        cluster = $Config.cluster.name
        runId = $RunId
        configHash = $ConfigHash
        mode = $Mode
        approvedOperations = @{}
        pendingApproval = $null
        pendingReboot = $null
        pendingInteractiveAuthentication = $null
        operationCheckpoints = @{}
        deploymentScenario = $Config.deployment.scenario
        currentPhase = $PhaseId
        currentStage = 1
        returnToPhase = $PhaseId
        returnToStage = 1
        returnToOperation = $null
        status = 'RUNNING'
        startedAt = [datetime]::UtcNow.ToString('o')
        completedAt = $null
        phases = @{}
        stages = @{}
        nodes = @{}
    }

    foreach ($node in @($Config.nodes)) {
        $management = Get-FactoryValue `
            -Object $node `
            -Name 'management'

        $managementAddress = [string](
            Get-FactoryValue `
                -Object $management `
                -Name 'ip'
        )

        if ([string]::IsNullOrWhiteSpace($managementAddress)) {
            $managementAddress = [string](
                Get-FactoryValue `
                    -Object $management `
                    -Name 'ip_address'
            )
        }

        $state.nodes[$node.name] = @{
            name = $node.name
            nodeNumber = $node.node_number
            managementAddress = $managementAddress
            managementAdapter = $management.adapter
            status = 'NOT_STARTED'
            currentPhase = $PhaseId
            currentStage = 1
            arcResourceId = $null
            lastError = $null
            stages = @{}
        }
    }

    $state.phases[[string]$PhaseId] = @{
        status = 'RUNNING'
        stages = @{}
        startedAt = [datetime]::UtcNow.ToString('o')
    }

    return $state
}

function Reset-FactoryStateFromStage {
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StartStage
    )

    foreach ($stageKey in @($State.stages.Keys)) {
        if ([int]$stageKey -ge $StartStage) {
            $State.stages.Remove($stageKey)
        }
    }

    $phaseState = $State.phases[[string]$PhaseId]

    if ($null -ne $phaseState) {
        foreach ($stageKey in @($phaseState.stages.Keys)) {
            if ([int]$stageKey -ge $StartStage) {
                $phaseState.stages.Remove($stageKey)
            }
        }
    }

    if ($null -ne $State.operationCheckpoints) {
        foreach ($checkpointKey in @($State.operationCheckpoints.Keys)) {
            $parts = $checkpointKey -split '\.'

            if (
                $parts.Count -eq 2 -and
                [int]$parts[0] -eq $PhaseId -and
                [int]$parts[1] -ge $StartStage
            ) {
                $State.operationCheckpoints.Remove($checkpointKey)
            }
        }
    }

    foreach ($nodeName in @($State.nodes.Keys)) {
        $nodeState = $State.nodes[$nodeName]

        foreach ($stageKey in @($nodeState.stages.Keys)) {
            $parts = $stageKey -split '\.'

            if (
                $parts.Count -eq 2 -and
                [int]$parts[0] -eq $PhaseId -and
                [int]$parts[1] -ge $StartStage
            ) {
                $nodeState.stages.Remove($stageKey)
            }
        }

        if (
            [int]$nodeState.currentPhase -eq $PhaseId -and
            [int]$nodeState.currentStage -ge $StartStage
        ) {
            $nodeState.currentStage = $StartStage
            $nodeState.status = 'NOT_STARTED'
            $nodeState.lastError = $null
        }
    }

    $State.returnToOperation = $null
}

function Get-StageDisplayName {
    param(
        [Parameter(Mandatory)]
        [object]$Stage
    )

    if (
        $Stage -is [System.Collections.IDictionary] -and
        $Stage.Contains('display_name')
    ) {
        return [string]$Stage['display_name']
    }

    if ($null -ne $Stage.PSObject.Properties['display_name']) {
        return [string]$Stage.display_name
    }

    return [string]$Stage.name
}

function Get-PhaseDisplayName {
    param(
        [Parameter(Mandatory)]
        [object]$Phase
    )

    if (
        $Phase -is [System.Collections.IDictionary] -and
        $Phase.Contains('display_name')
    ) {
        return [string]$Phase['display_name']
    }

    if ($null -ne $Phase.PSObject.Properties['display_name']) {
        return [string]$Phase.display_name
    }

    return [string]$Phase.name
}

function Get-FactoryPrerequisiteState {
    param(
        [Parameter(Mandatory)]
        [string]$SiteArtifactRoot,

        [Parameter(Mandatory)]
        [string]$CurrentStatePath,

        [Parameter(Mandatory)]
        [string]$ConfigHash,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StartStage
    )

    if ($StartStage -le 1) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $SiteArtifactRoot -PathType Container)) {
        throw (
            "Stage $StartStage requires prior PASS evidence, but site artifact " +
            "directory does not exist: $SiteArtifactRoot"
        )
    }

    $requiredStageKeys = @(
        1..($StartStage - 1) |
            ForEach-Object {
                [string]$_
            }
    )

    $stateFiles = @(
        Get-ChildItem `
            -LiteralPath $SiteArtifactRoot `
            -Filter 'deployment-state.json' `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -ne $CurrentStatePath
            } |
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

        if ($candidateState.configHash -ne $ConfigHash) {
            continue
        }

        if ([int]$candidateState.currentPhase -ne $PhaseId) {
            continue
        }

        $candidateStages = Get-StateValue `
            -Object $candidateState `
            -Name 'stages'

        if ($null -eq $candidateStages) {
            continue
        }

        $allPrerequisitesPassed = $true

        foreach ($stageKey in $requiredStageKeys) {
            $stageRecord = Get-StateValue `
                -Object $candidateStages `
                -Name $stageKey

            if (
                $null -eq $stageRecord -or
                [string](
                    Get-StateValue `
                        -Object $stageRecord `
                        -Name 'status'
                ) -ne 'PASS'
            ) {
                $allPrerequisitesPassed = $false
                break
            }
        }

        if ($allPrerequisitesPassed) {
            return [pscustomobject]@{
                StatePath = $stateFile.FullName
                State = $candidateState
            }
        }
    }

    throw (
        "Stage $StartStage requires PASS evidence for Stage(s) " +
        "$($requiredStageKeys -join ', ') with the current resolved " +
        'configuration hash. Revalidate the prerequisite stages first.'
    )
}

function Resolve-FocusedOperation {
    param(
        [Parameter(Mandatory)]
        [object[]]$PhaseStages,

        [Parameter(Mandatory)]
        [int]$StartStage,

        [Parameter(Mandatory)]
        [string]$StartOperation
    )

    if ([string]::IsNullOrWhiteSpace($StartOperation)) {
        return $null
    }

    $stage = @(
        $PhaseStages |
            Where-Object {
                [int]$_.id -eq $StartStage
            }
    ) |
        Select-Object -First 1

    if ($null -eq $stage) {
        throw (
            "Focused operation $StartOperation cannot be resolved because " +
            "Phase $PhaseId Stage $StartStage does not exist."
        )
    }

    if ($StartOperation -notin @($stage.operations)) {
        throw (
            "Focused operation $StartOperation is not defined in Phase " +
            "$PhaseId Stage $StartStage."
        )
    }

    return $StartOperation
}

function Test-NativeArcRegistrationApproval {
    param(
        [AllowNull()]
        [object]$PendingApproval
    )

    if ($null -eq $PendingApproval) {
        return $false
    }

    return (
        (Get-PendingApprovalPhaseId -PendingApproval $PendingApproval) -eq 1 -and
        (Get-PendingApprovalStageId -PendingApproval $PendingApproval) -eq 4 -and
        (Get-PendingApprovalOperation -PendingApproval $PendingApproval) -eq 'Register-ArcNode' -and
        (Get-PendingApprovalType -PendingApproval $PendingApproval) -eq 'ConfigurationChange'
    )
}

function Test-NativeArcInteractivePause {
    param(
        [AllowNull()]
        [object]$PendingApproval
    )

    if ($null -eq $PendingApproval) {
        return $false
    }

    return (
        (Get-PendingApprovalPhaseId -PendingApproval $PendingApproval) -eq 1 -and
        (Get-PendingApprovalStageId -PendingApproval $PendingApproval) -eq 4 -and
        (Get-PendingApprovalOperation -PendingApproval $PendingApproval) -eq 'Register-ArcNode' -and
        (Get-PendingApprovalType -PendingApproval $PendingApproval) -eq 'InteractiveAuthentication'
    )
}

function Get-FactoryExecutionOutcome {
    param(
        [AllowNull()]
        [object]$Result
    )

    if ($null -eq $Result) {
        return 'FAILED'
    }

    $nestedResult = Get-StateValue `
        -Object $Result `
        -Name 'Result'

    $isPaused = (
        (Get-StateValue `
            -Object $nestedResult `
            -Name 'RequiresApproval') -eq $true -or
        (Get-StateValue `
            -Object $nestedResult `
            -Name 'PauseRequested') -eq $true
    )

    if ($isPaused) {
        return 'PAUSED'
    }

    if (
        (Get-StateValue `
            -Object $Result `
            -Name 'Passed') -eq $false
    ) {
        return 'FAILED'
    }

    $outcome = [string](
        Get-StateValue `
            -Object $Result `
            -Name 'Outcome'
    )

    switch ($outcome) {
        'AlreadyCompliant' { return 'SKIPPED' }
        'Skipped'          { return 'SKIPPED' }
        'Changed'          { return 'CHANGED' }
        default            { return 'PASSED' }
    }
}

function Write-FactoryExecutionEvent {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [string]$EventType,

        [Parameter(Mandatory)]
        [string]$Outcome,

        [AllowNull()]
        [Nullable[int]]$PhaseId,

        [AllowNull()]
        [Nullable[int]]$StageId,

        [AllowNull()]
        [string]$Operation,

        [AllowNull()]
        [string]$Scope,

        [AllowNull()]
        [string]$Node,

        [AllowNull()]
        [string]$Summary,

        [AllowNull()]
        [string]$Reason,

        [AllowNull()]
        [string]$Evidence,

        [AllowNull()]
        [Nullable[int]]$Attempt
    )

    if (-not [string]::IsNullOrWhiteSpace($Summary)) {
        $Summary = Protect-FactoryErrorMessage `
            -Message $Summary
    }

    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $Reason = Protect-FactoryErrorMessage `
            -Message $Reason
    }

    $event = [ordered]@{
        SchemaVersion = 'deployment-execution-event-v1'
        TimestampUtc = [datetime]::UtcNow.ToString('o')
        EventType = $EventType
        Outcome = $Outcome
        PhaseId = $PhaseId
        StageId = $StageId
        Operation = $Operation
        Scope = $Scope
        Node = $Node
        Attempt = $Attempt
        Summary = $Summary
        Reason = $Reason
        Evidence = $Evidence
    }

    $eventDirectory = Split-Path `
        -Path $EventPath `
        -Parent

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $eventDirectory |
        Out-Null

    $json = $event |
        ConvertTo-Json `
            -Depth 10 `
            -Compress

    [System.IO.File]::AppendAllText(
        $EventPath,
        "$json`n",
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Write-FactoryOperationEvents {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId,

        [Parameter(Mandatory)]
        [int]$Attempt,

        [Parameter(Mandatory)]
        [string]$Evidence
    )

    foreach ($result in @($Results)) {
        $outcome = Get-FactoryExecutionOutcome `
            -Result $result

        $operation = [string](
            Get-StateValue `
                -Object $result `
                -Name 'Operation'
        )

        $scope = [string](
            Get-StateValue `
                -Object $result `
                -Name 'Scope'
        )

        $node = [string](
            Get-StateValue `
                -Object $result `
                -Name 'Node'
        )

        $summary = [string](
            Get-StateValue `
                -Object $result `
                -Name 'Summary'
        )

        $reason = [string](
            Get-StateValue `
                -Object $result `
                -Name 'Reason'
        )

        $eventType = switch ($outcome) {
            'FAILED' { 'OperationFailed' }
            'PAUSED' { 'OperationPaused' }
            default  { 'OperationCompleted' }
        }

        Write-FactoryExecutionEvent `
            -EventPath $EventPath `
            -EventType $eventType `
            -Outcome $outcome `
            -PhaseId $PhaseId `
            -StageId $StageId `
            -Operation $operation `
            -Scope $scope `
            -Node $node `
            -Summary $summary `
            -Reason $reason `
            -Evidence $Evidence `
            -Attempt $Attempt
    }
}

$packageRoot = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..')
)

$environmentPath = [IO.Path]::GetFullPath($Environment)

if (-not (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
    throw "Resolved configuration does not exist: $environmentPath"
}

if ($RunId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'RunId may contain only letters, numbers, underscores, and hyphens.'
}

if ($Mode -eq 'Plan' -and -not [string]::IsNullOrWhiteSpace($StartOperation)) {
    throw 'StartOperation is not supported in Plan mode.'
}

$config = Read-FactoryConfig `
    -Path $environmentPath

$configHash = (
    Get-FileHash `
        -LiteralPath $environmentPath `
        -Algorithm SHA256
).Hash

$phases = @($config.workflow.phases)

if ($phases.Count -lt 1) {
    throw 'Resolved configuration does not include workflow.phases.'
}

$phase = @(
    $phases |
        Where-Object {
            [int]$_.id -eq $PhaseId
        }
) |
    Select-Object -First 1

if ($null -eq $phase) {
    throw "Requested phase does not exist: $PhaseId"
}

if (-not [bool]$phase.implemented) {
    throw "Phase $PhaseId is declared but not implemented."
}

$phaseStages = @(
    $phase.stages |
        Sort-Object {
            [int]$_.id
        }
)

if ($phaseStages.Count -lt 1) {
    throw "Phase $PhaseId contains no stages."
}

$maximumPhaseStage = [int](
    $phaseStages |
        ForEach-Object {
            [int]$_.id
        } |
        Sort-Object -Descending |
        Select-Object -First 1
)

if ($ThroughStage -eq 0) {
    $ThroughStage = if ($Mode -eq 'Plan') {
        $maximumPhaseStage
    }
    elseif ($Mode -eq 'Validate') {
        [Math]::Min(2, $maximumPhaseStage)
    }
    else {
        $maximumPhaseStage
    }
}

if ($ThroughStage -gt $maximumPhaseStage) {
    throw (
        "ThroughStage $ThroughStage exceeds maximum Stage " +
        "$maximumPhaseStage for Phase $PhaseId."
    )
}

if ($StartStage -gt $maximumPhaseStage) {
    throw (
        "StartStage $StartStage exceeds maximum Stage " +
        "$maximumPhaseStage for Phase $PhaseId."
    )
}

if ($StartStage -gt $ThroughStage) {
    throw (
        "StartStage $StartStage cannot be greater than " +
        "ThroughStage $ThroughStage."
    )
}

$artifactRoot = [IO.Path]::GetFullPath($ArtifactsPath)
$siteArtifactRoot = Join-Path $artifactRoot $config.site.name
$runDirectory = Join-Path $siteArtifactRoot $RunId
$siteLockPath = Join-Path $siteArtifactRoot '.factory.lock'
$statePath = Join-Path $runDirectory 'deployment-state.json'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $siteArtifactRoot |
    Out-Null

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

New-Item `
    -ItemType Directory `
    -Force `
    -Path (Join-Path $runDirectory 'reports') |
    Out-Null

$siteLock = $null
$executeApprovedReboot = $false
$approvedRebootRequest = $null
$resumeInteractiveAuthentication = $false
$focusedResume = $false
$focusedStartOperation = $null
$allowPendingOperationResume = $false
$resumeApproval = $null
$context = $null
$executionEventPath = $null

try {
    $siteLock = [IO.File]::Open(
        $siteLockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )

    if ($Resume) {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            throw "Resume state does not exist: $statePath"
        }

        $state = Get-Content `
            -LiteralPath $statePath `
            -Raw |
            ConvertFrom-Json `
            -AsHashtable

        if ($state.configHash -ne $configHash) {
            throw 'Resolved configuration changed since the run began. Start a new run.'
        }

        if ($state.mode -ne $Mode) {
            throw 'Run mode changed since the run began. Start a new run.'
        }

        if ([int]$state.currentPhase -ne $PhaseId) {
            throw 'Requested phase differs from the saved run phase.'
        }

        if ($state.status -eq 'READY') {
            throw 'This run is already READY. Start a new run if re-execution is required.'
        }

        if ($state.status -eq 'DENIED') {
            throw (
                'This run contains a denied operator action. Start a new run ' +
                'or correct state through approved workflow procedures.'
            )
        }

        if ($state.status -eq 'VALIDATED') {
            throw (
                'This run completed validation successfully. Start a new run ' +
                'for additional validation or Apply execution.'
            )
        }

        if ($state.status -eq 'PLAN_COMPLETE') {
            throw (
                'This run was Plan-only. Start a new run for Validate or Apply execution.'
            )
        }

        if ($null -eq $state.returnToStage) {
            throw 'Resume state does not contain a valid returnToStage value.'
        }

        if ($null -eq $state.operationCheckpoints) {
            $state.operationCheckpoints = @{}
        }

        if (-not $state.Contains('returnToOperation')) {
            $state.returnToOperation = $null
        }

        $pendingApprovalType = Get-PendingApprovalType `
            -PendingApproval $state.pendingApproval

        $pendingApprovalOperation = Get-PendingApprovalOperation `
            -PendingApproval $state.pendingApproval

        $pendingApprovalPhaseId = Get-PendingApprovalPhaseId `
            -PendingApproval $state.pendingApproval

        $pendingApprovalStageId = Get-PendingApprovalStageId `
            -PendingApproval $state.pendingApproval

        $startStage = [int]$state.returnToStage

        if (
            [string]::IsNullOrWhiteSpace($StartOperation) -and
            $state.status -eq 'APPROVED' -and
            (Test-NativeArcRegistrationApproval `
                -PendingApproval $state.pendingApproval)
        ) {
            $StartOperation = 'Register-ArcNode'
        }

        if (
            [string]::IsNullOrWhiteSpace($StartOperation) -and
            $state.status -eq 'PAUSED' -and
            (Test-NativeArcInteractivePause `
                -PendingApproval $state.pendingApproval)
        ) {
            $StartOperation = [string](
                Get-StateValue `
                    -Object $state.pendingInteractiveAuthentication `
                    -Name 'ReturnToOperation'
            )

            if ([string]::IsNullOrWhiteSpace($StartOperation)) {
                $StartOperation = 'Register-ArcNode'
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($StartOperation)) {
            $focusedStartOperation = Resolve-FocusedOperation `
                -PhaseStages $phaseStages `
                -StartStage $startStage `
                -StartOperation $StartOperation

            if ($state.status -eq 'PAUSED') {
                if ($pendingApprovalType -ne 'InteractiveAuthentication') {
                    throw (
                        'This run is paused awaiting operator approval. ' +
                        'Approve or deny the pending action before resuming.'
                    )
                }

                if ($null -eq $state.pendingInteractiveAuthentication) {
                    throw (
                        'Interactive authentication pause is missing ' +
                        'pendingInteractiveAuthentication state.'
                    )
                }

                if (
                    $pendingApprovalOperation -ne $focusedStartOperation -or
                    $pendingApprovalPhaseId -ne $PhaseId -or
                    $pendingApprovalStageId -ne $startStage
                ) {
                    throw (
                        "Focused resume operation $focusedStartOperation does not " +
                        'match the saved interactive authentication pause.'
                    )
                }

                $resumeInteractiveAuthentication = $true
                $focusedResume = $true
            }
            elseif ($state.status -eq 'APPROVED') {
                if ($null -eq $state.pendingApproval) {
                    throw (
                        'Approved workflow is missing pending approval metadata. ' +
                        'Do not resume until state is corrected.'
                    )
                }

                if ($pendingApprovalType -eq 'Reboot') {
                    if ($null -eq $state.pendingReboot) {
                        throw (
                            'Approved reboot state is missing pendingReboot metadata. ' +
                            'Do not resume until state is corrected.'
                        )
                    }

                    $executeApprovedReboot = $true
                    $approvedRebootRequest = $state.pendingReboot
                }
                elseif (
                    $pendingApprovalOperation -eq $focusedStartOperation -and
                    $pendingApprovalPhaseId -eq $PhaseId -and
                    $pendingApprovalStageId -eq $startStage
                ) {
                    $focusedResume = $true
                    $allowPendingOperationResume = $true
                    $resumeApproval = $state.pendingApproval
                    $state.pendingApproval = $null
                    $state.status = 'RUNNING'
                }
                else {
                    throw (
                        "Focused resume operation $focusedStartOperation does not " +
                        'match the saved approved operation.'
                    )
                }
            }
            elseif ($state.status -notin @('BLOCKED', 'RUNNING')) {
                throw (
                    "Focused resume is not available while workflow state is " +
                    "$($state.status)."
                )
            }

            if (
                $focusedResume -and
                -not $executeApprovedReboot
            ) {
                $state.returnToOperation = $focusedStartOperation
            }
        }

        if (
            -not $focusedResume -and
            -not $executeApprovedReboot
        ) {
            if ($state.status -eq 'PAUSED') {
                if ($pendingApprovalType -eq 'InteractiveAuthentication') {
                    if ($null -eq $state.pendingInteractiveAuthentication) {
                        throw (
                            'Interactive authentication pause is missing ' +
                            'pendingInteractiveAuthentication state.'
                        )
                    }

                    $resumeInteractiveAuthentication = $true
                }
                else {
                    throw (
                        'This run is paused awaiting operator approval. ' +
                        'Approve or deny the pending action before resuming.'
                    )
                }
            }

            if (
                $state.status -eq 'APPROVED' -and
                $pendingApprovalType -eq 'Reboot'
            ) {
                if ($null -eq $state.pendingReboot) {
                    throw (
                        'Approved reboot state is missing pendingReboot metadata. ' +
                        'Do not resume until state is corrected.'
                    )
                }

                $executeApprovedReboot = $true
                $approvedRebootRequest = $state.pendingReboot
            }

            Reset-FactoryStateFromStage `
                -State $state `
                -PhaseId $PhaseId `
                -StartStage $startStage
        }
    }
    else {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            throw "Run already exists: $RunId. Use -Resume or select a new RunId."
        }

        if (-not [string]::IsNullOrWhiteSpace($StartOperation)) {
            throw (
                'StartOperation requires -Resume and a saved operation checkpoint state.'
            )
        }

        $state = Initialize-FactoryState `
            -Config $config `
            -RunId $RunId `
            -ConfigHash $configHash `
            -Mode $Mode `
            -PhaseId $PhaseId

        $startStage = $StartStage

        if ($startStage -gt 1 -and $Mode -ne 'Plan') {
            $prerequisiteState = Get-FactoryPrerequisiteState `
                -SiteArtifactRoot $siteArtifactRoot `
                -CurrentStatePath $statePath `
                -ConfigHash $configHash `
                -PhaseId $PhaseId `
                -StartStage $startStage

            foreach ($stageNumber in 1..($startStage - 1)) {
                $stageKey = [string]$stageNumber

                $priorStageRecord = Get-StateValue `
                    -Object $prerequisiteState.State.stages `
                    -Name $stageKey

                if ($null -eq $priorStageRecord) {
                    throw (
                        "Prerequisite run $($prerequisiteState.StatePath) is missing " +
                        "expected Stage $stageNumber PASS evidence."
                    )
                }

                $state.stages[$stageKey] = $priorStageRecord
                $state.phases[[string]$PhaseId].stages[$stageKey] = `
                    $priorStageRecord
            }

            $state.prerequisiteRunId = $prerequisiteState.State.runId
            $state.prerequisiteStatePath = $prerequisiteState.StatePath
            $state.currentStage = $startStage
            $state.returnToStage = $startStage
        }
    }

    if ($Mode -eq 'Apply' -and $ThroughStage -lt $startStage) {
        throw (
            "Apply ThroughStage $ThroughStage cannot be earlier than " +
            "the current start stage $startStage."
        )
    }

    if (
        -not [string]::IsNullOrWhiteSpace($focusedStartOperation) -and
        $ThroughStage -ne $startStage
    ) {
        throw (
            'Focused operation resume must use a single-stage execution scope.'
        )
    }

    $context = @{
        Root = $packageRoot
        Config = $config
        RunDirectory = $runDirectory
        StatePath = $statePath
        RunId = $RunId
        Mode = $Mode
        PhaseId = $PhaseId
        ThroughStage = $ThroughStage
        StartOperation = $focusedStartOperation
        AllowPendingOperationResume = $allowPendingOperationResume
        ResumeApproval = $resumeApproval
        State = $state
        LastResults = [System.Collections.Generic.List[object]]::new()
        ExecutionEventPath = (
            Join-Path $runDirectory 'execution-events.jsonl'
        )
    }

    $executionEventPath = $context.ExecutionEventPath

    Save-FactoryState `
        -State $state `
        -Path $statePath

    Write-FactoryExecutionEvent `
        -EventPath $executionEventPath `
        -EventType $(if ($Resume) { 'RunResumed' } else { 'RunStarted' }) `
        -Outcome 'PASSED' `
        -PhaseId $PhaseId `
        -StageId $startStage `
        -Operation $focusedStartOperation `
        -Scope 'Site' `
        -Node $null `
        -Summary $(if ($Resume) {
            'Deployment workflow resumed.'
        }
        else {
            'Deployment workflow started.'
        }) `
        -Reason $null `
        -Evidence 'deployment-state.json' `
        -Attempt $null

    if ($resumeInteractiveAuthentication) {
        $state.status = 'RUNNING'

        Save-FactoryState `
            -State $state `
            -Path $statePath

        Write-FactoryExecutionEvent `
            -EventPath $executionEventPath `
            -EventType 'InteractiveAuthenticationResumed' `
            -Outcome 'PAUSED' `
            -PhaseId $PhaseId `
            -StageId $startStage `
            -Operation $focusedStartOperation `
            -Scope 'Node' `
            -Node ([string]$state.pendingInteractiveAuthentication.Node) `
            -Summary 'Interactive authentication resume session started.' `
            -Reason $null `
            -Evidence 'deployment-state.json' `
            -Attempt $null

        Write-Host (
            "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
            'Resuming interactive authentication for node ' +
            "$($state.pendingInteractiveAuthentication.Node)."
        ) -ForegroundColor Yellow
    }

    if ($executeApprovedReboot) {
        $state.status = 'RUNNING'

        Save-FactoryState `
            -State $state `
            -Path $statePath

        Write-FactoryExecutionEvent `
            -EventPath $executionEventPath `
            -EventType 'RebootStarted' `
            -Outcome 'CHANGED' `
            -PhaseId $PhaseId `
            -StageId $startStage `
            -Operation 'ApprovedRebootAndReconnect' `
            -Scope 'Node' `
            -Node ([string]$approvedRebootRequest.Node) `
            -Summary 'Approved reboot and reconnect started.' `
            -Reason $null `
            -Evidence 'deployment-state.json' `
            -Attempt $null

        try {
            $rebootResult = & "$PSScriptRoot\Invoke-NodeRebootAndReconnect.ps1" `
                -Context $context `
                -RebootRequest $approvedRebootRequest

            $rebootEvidencePath = (
                "evidence\phase-$PhaseId-stage-$startStage-" +
                "approved-reboot-$($approvedRebootRequest.Node).json"
            )

            Write-FactoryJson `
                -Value $rebootResult `
                -Path (
                    Join-Path `
                        $runDirectory `
                        $rebootEvidencePath
                )

            $state.pendingReboot = $null
            $state.pendingApproval = $null
            $state.status = 'RUNNING'

            if ($state.nodes.Contains($approvedRebootRequest.Node)) {
                $state.nodes[$approvedRebootRequest.Node].status = 'RUNNING'
                $state.nodes[$approvedRebootRequest.Node].lastError = $null
            }

            Save-FactoryState `
                -State $state `
                -Path $statePath

            Write-FactoryExecutionEvent `
                -EventPath $executionEventPath `
                -EventType 'RebootCompleted' `
                -Outcome 'CHANGED' `
                -PhaseId $PhaseId `
                -StageId $startStage `
                -Operation 'ApprovedRebootAndReconnect' `
                -Scope 'Node' `
                -Node ([string]$approvedRebootRequest.Node) `
                -Summary 'Approved reboot and reconnect completed.' `
                -Reason $null `
                -Evidence $rebootEvidencePath `
                -Attempt $null
        }
        catch {
            $reason = Protect-FactoryErrorMessage `
                -Message $_.Exception.Message

            $state.status = 'BLOCKED'
            $state.returnToPhase = $PhaseId
            $state.returnToStage = $startStage
            $state.returnToOperation = [string](
                Get-StateValue `
                    -Object $approvedRebootRequest `
                    -Name 'ReturnToOperation'
            )
            $state.phases[[string]$PhaseId].status = 'BLOCKED'

            if ($state.nodes.Contains($approvedRebootRequest.Node)) {
                $state.nodes[$approvedRebootRequest.Node].status = 'FAIL'
                $state.nodes[$approvedRebootRequest.Node].lastError = $reason
            }

            $rebootFailureEvidencePath = (
                "evidence\phase-$PhaseId-stage-$startStage-" +
                'reboot-reconnect-failure.json'
            )

            Write-FactoryJson `
                -Value @{
                    phaseId = $PhaseId
                    stageId = $startStage
                    status = 'REBOOT_RECONNECT_FAIL'
                    node = $approvedRebootRequest.Node
                    pendingReboot = $approvedRebootRequest
                    reason = $reason
                    timestamp = [datetime]::UtcNow.ToString('o')
                } `
                -Path (
                    Join-Path `
                        $runDirectory `
                        $rebootFailureEvidencePath
                )

            Save-FactoryState `
                -State $state `
                -Path $statePath

            Write-FactoryExecutionEvent `
                -EventPath $executionEventPath `
                -EventType 'RebootFailed' `
                -Outcome 'FAILED' `
                -PhaseId $PhaseId `
                -StageId $startStage `
                -Operation 'ApprovedRebootAndReconnect' `
                -Scope 'Node' `
                -Node ([string]$approvedRebootRequest.Node) `
                -Summary 'Approved reboot and reconnect failed.' `
                -Reason $reason `
                -Evidence $rebootFailureEvidencePath `
                -Attempt $null

            throw (
                "Approved reboot/reconnect for node " +
                "$($approvedRebootRequest.Node) failed. $reason"
            )
        }
    }

    if ($Mode -eq 'Plan') {
        $planOperations = @()

        foreach ($stage in $phaseStages) {
            if (
                [int]$stage.id -lt $StartStage -or
                [int]$stage.id -gt $ThroughStage
            ) {
                continue
            }

            foreach ($operation in @($stage.operations)) {
                $metadata = Get-FactoryOperationMetadata `
                    -Operation $operation

                $planOperations += @{
                    phaseId = $PhaseId
                    stageId = $stage.id
                    stage = $stage.name
                    operation = $operation
                    scope = $metadata.Scope
                    mutates = $metadata.Mutates
                }
            }
        }

        Write-FactoryJson `
            -Value @{
                status = 'PLAN_ONLY'
                site = $config.site.name
                cluster = $config.cluster.name
                phaseId = $PhaseId
                throughStage = $ThroughStage
                runId = $RunId
                generatedAt = [datetime]::UtcNow.ToString('o')
                operations = $planOperations
            } `
            -Path (Join-Path $runDirectory 'plan.json')

        $state.status = 'PLAN_COMPLETE'
        $state.completedAt = [datetime]::UtcNow.ToString('o')

        Save-FactoryState `
            -State $state `
            -Path $statePath

        Write-FactoryExecutionEvent `
            -EventPath $executionEventPath `
            -EventType 'PlanCompleted' `
            -Outcome 'PASSED' `
            -PhaseId $PhaseId `
            -StageId $ThroughStage `
            -Operation $null `
            -Scope 'Site' `
            -Node $null `
            -Summary 'Plan-only workflow completed. No node operations were executed.' `
            -Reason $null `
            -Evidence 'plan.json' `
            -Attempt $null

        Write-Output "Plan written to $runDirectory. No operations were executed."
        return
    }

    $eligibleStages = @(
        & "$PSScriptRoot\Invoke-Phase.ps1" `
            -Phase $phase `
            -StartStage $startStage `
            -ThroughStage $ThroughStage
    )

    if ($eligibleStages.Count -lt 1) {
        throw (
            "No eligible stages were returned for Phase $PhaseId, " +
            "start stage $startStage, ThroughStage $ThroughStage."
        )
    }

    $eligibleStageCount = $eligibleStages.Count
    $currentStageIndex = 0

    foreach ($stage in $eligibleStages) {
        $currentStageIndex++

        $stageId = [int]$stage.id
        $stageKey = [string]$stageId
        [int]$maxAttempts = $stage.max_attempts
        [int]$retrySeconds = $stage.retry_seconds

        if ($maxAttempts -lt 1) {
            throw "Phase $PhaseId / Stage $stageId has invalid max_attempts value."
        }

        $stageDisplayName = Get-StageDisplayName `
            -Stage $stage

        $phaseDisplayName = Get-PhaseDisplayName `
            -Phase $phase

        $stagePercentComplete = [math]::Floor(
            (($currentStageIndex - 1) / $eligibleStageCount) * 100
        )

        Write-Progress `
            -Id 1 `
            -Activity "Phase $PhaseId - $phaseDisplayName" `
            -Status "Stage $stageId - $stageDisplayName" `
            -PercentComplete $stagePercentComplete

        $state.status = 'RUNNING'
        $state.currentPhase = $PhaseId
        $state.currentStage = $stageId
        $state.phases[[string]$PhaseId].status = 'RUNNING'

        Save-FactoryState `
            -State $state `
            -Path $statePath

        $passed = $false

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            Write-FactoryExecutionEvent `
                -EventPath $executionEventPath `
                -EventType 'StageStarted' `
                -Outcome 'PASSED' `
                -PhaseId $PhaseId `
                -StageId $stageId `
                -Operation $null `
                -Scope 'Site' `
                -Node $null `
                -Summary (
                    "Phase $PhaseId Stage $stageId attempt $attempt started."
                ) `
                -Reason $null `
                -Evidence 'deployment-state.json' `
                -Attempt $attempt

            try {
                $stageResult = & "$PSScriptRoot\Invoke-Stage.ps1" `
                    -Stage $stage `
                    -Context $context

                if ($stageResult.Paused -eq $true) {
                    $state.status = 'PAUSED'
                    $state.currentPhase = $PhaseId
                    $state.currentStage = $stageId
                    $state.returnToPhase = $PhaseId
                    $state.returnToStage = $stageId
                    $state.pendingApproval = $stageResult.PendingApproval
                    $state.returnToOperation = [string](
                        Get-StateValue `
                            -Object $stageResult.PendingApproval `
                            -Name 'ReturnToOperation'
                    )

                    if ([string]::IsNullOrWhiteSpace($state.returnToOperation)) {
                        $state.returnToOperation = [string](
                            Get-StateValue `
                                -Object $stageResult.PendingApproval `
                                -Name 'Operation'
                        )
                    }

                    $pauseType = [string](
                        Get-StateValue `
                            -Object $stageResult.PendingApproval `
                            -Name 'ApprovalType'
                    )

                    if ($pauseType -eq 'Reboot') {
                        $state.pendingReboot = $stageResult.PendingApproval
                        $state.pendingInteractiveAuthentication = $null
                    }
                    elseif ($pauseType -eq 'InteractiveAuthentication') {
                        $state.pendingInteractiveAuthentication = `
                            $stageResult.PendingApproval

                        $state.pendingReboot = $null
                    }
                    else {
                        $state.pendingReboot = $null
                        $state.pendingInteractiveAuthentication = $null
                    }

                    $state.phases[[string]$PhaseId].status = 'PAUSED'

                    $pausedEvidencePath = (
                        "evidence\phase-$PhaseId-stage-$stageId-paused.json"
                    )

                    Write-FactoryJson `
                        -Value $stageResult `
                        -Path (
                            Join-Path `
                                $runDirectory `
                                $pausedEvidencePath
                        )

                    Write-FactoryOperationEvents `
                        -EventPath $executionEventPath `
                        -Results @($stageResult.Results) `
                        -PhaseId $PhaseId `
                        -StageId $stageId `
                        -Attempt $attempt `
                        -Evidence $pausedEvidencePath

                    Save-FactoryState `
                        -State $state `
                        -Path $statePath

                    Write-FactoryExecutionEvent `
                        -EventPath $executionEventPath `
                        -EventType 'StagePaused' `
                        -Outcome 'PAUSED' `
                        -PhaseId $PhaseId `
                        -StageId $stageId `
                        -Operation $state.returnToOperation `
                        -Scope 'Site' `
                        -Node ([string]$stageResult.PendingApproval.Node) `
                        -Summary (
                            "Phase $PhaseId Stage $stageId paused for $pauseType."
                        ) `
                        -Reason ([string]$stageResult.PendingApproval.Reason) `
                        -Evidence $pausedEvidencePath `
                        -Attempt $attempt

                    Write-Host (
                        "PAUSED: Phase $PhaseId Stage $stageId requires " +
                        "$pauseType action. Operation: " +
                        "$($stageResult.PendingApproval.Operation). Node: " +
                        "$($stageResult.PendingApproval.Node)."
                    ) -ForegroundColor Yellow

                    return
                }

                $stageEvidencePath = (
                    "evidence\phase-$PhaseId-stage-$stageId-" +
                    "attempt-$attempt.json"
                )

                Write-FactoryJson `
                    -Value $stageResult `
                    -Path (
                        Join-Path `
                            $runDirectory `
                            $stageEvidencePath
                    )

                Write-FactoryOperationEvents `
                    -EventPath $executionEventPath `
                    -Results @($stageResult.Results) `
                    -PhaseId $PhaseId `
                    -StageId $stageId `
                    -Attempt $attempt `
                    -Evidence $stageEvidencePath

                $passRecord = @{
                    status = 'PASS'
                    attempt = $attempt
                    timestamp = [datetime]::UtcNow.ToString('o')
                    resultCount = @($stageResult.Results).Count
                }

                $state.stages[$stageKey] = $passRecord
                $state.phases[[string]$PhaseId].stages[$stageKey] = $passRecord
                $state.pendingApproval = $null
                $state.pendingReboot = $null
                $state.pendingInteractiveAuthentication = $null
                $state.returnToOperation = $null

                Save-FactoryState `
                    -State $state `
                    -Path $statePath

                Write-FactoryExecutionEvent `
                    -EventPath $executionEventPath `
                    -EventType 'StageCompleted' `
                    -Outcome 'PASSED' `
                    -PhaseId $PhaseId `
                    -StageId $stageId `
                    -Operation $null `
                    -Scope 'Site' `
                    -Node $null `
                    -Summary (
                        "Phase $PhaseId Stage $stageId completed successfully."
                    ) `
                    -Reason $null `
                    -Evidence $stageEvidencePath `
                    -Attempt $attempt

                $passed = $true
                break
            }
            catch {
                $reason = Protect-FactoryErrorMessage `
                    -Message $_.Exception.Message

                $failureRecord = @{
                    status = 'FAIL'
                    attempt = $attempt
                    timestamp = [datetime]::UtcNow.ToString('o')
                    reason = $reason
                }

                $state.stages[$stageKey] = $failureRecord
                $state.phases[[string]$PhaseId].stages[$stageKey] = `
                    $failureRecord

                $failureEvidencePath = (
                    "evidence\phase-$PhaseId-stage-$stageId-" +
                    "attempt-$attempt.json"
                )

                Write-FactoryJson `
                    -Value @{
                        phaseId = $PhaseId
                        stageId = $stageId
                        attempt = $attempt
                        status = 'FAIL'
                        reason = $reason
                        timestamp = [datetime]::UtcNow.ToString('o')
                        partialResults = @($context.LastResults)
                    } `
                    -Path (
                        Join-Path `
                            $runDirectory `
                            $failureEvidencePath
                    )

                Write-FactoryOperationEvents `
                    -EventPath $executionEventPath `
                    -Results @($context.LastResults) `
                    -PhaseId $PhaseId `
                    -StageId $stageId `
                    -Attempt $attempt `
                    -Evidence $failureEvidencePath

                Save-FactoryState `
                    -State $state `
                    -Path $statePath

                Write-FactoryExecutionEvent `
                    -EventPath $executionEventPath `
                    -EventType 'StageFailed' `
                    -Outcome 'FAILED' `
                    -PhaseId $PhaseId `
                    -StageId $stageId `
                    -Operation $null `
                    -Scope 'Site' `
                    -Node $null `
                    -Summary (
                        "Phase $PhaseId Stage $stageId attempt $attempt failed."
                    ) `
                    -Reason $reason `
                    -Evidence $failureEvidencePath `
                    -Attempt $attempt

                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds (
                        [Math]::Min(
                            300,
                            [Math]::Max(0, $retrySeconds)
                        )
                    )
                }
            }
        }

        if (-not $passed) {
            $returnToStage = [int]$stage.return_to_stage

            $state.status = 'BLOCKED'
            $state.returnToPhase = $PhaseId
            $state.returnToStage = $returnToStage
            $state.phases[[string]$PhaseId].status = 'BLOCKED'

            Save-FactoryState `
                -State $state `
                -Path $statePath

            Write-FactoryExecutionEvent `
                -EventPath $executionEventPath `
                -EventType 'RunBlocked' `
                -Outcome 'FAILED' `
                -PhaseId $PhaseId `
                -StageId $stageId `
                -Operation $null `
                -Scope 'Site' `
                -Node $null `
                -Summary (
                    "Phase $PhaseId Stage $stageId is blocked."
                ) `
                -Reason (
                    "Resolve the failure and resume from Stage $returnToStage."
                ) `
                -Evidence 'deployment-state.json' `
                -Attempt $null

            throw (
                "Phase $PhaseId Stage $stageId is BLOCKED. " +
                "Resolve the failure and resume from Stage $returnToStage."
            )
        }

        $context.StartOperation = $null
        $context.AllowPendingOperationResume = $false
        $context.ResumeApproval = $null
    }

    if ($ThroughStage -lt $maximumPhaseStage) {
        $state.status = 'VALIDATED'
        $state.currentPhase = $PhaseId
        $state.currentStage = $ThroughStage
        $state.returnToPhase = $null
        $state.returnToStage = $null
        $state.returnToOperation = $null
        $state.completedAt = [datetime]::UtcNow.ToString('o')
        $state.phases[[string]$PhaseId].status = 'VALIDATED'

        Save-FactoryState `
            -State $state `
            -Path $statePath

        Write-FactoryExecutionEvent `
            -EventPath $executionEventPath `
            -EventType 'RunCompleted' `
            -Outcome 'PASSED' `
            -PhaseId $PhaseId `
            -StageId $ThroughStage `
            -Operation $null `
            -Scope 'Site' `
            -Node $null `
            -Summary (
                "Validation completed through Phase $PhaseId Stage $ThroughStage."
            ) `
            -Reason $null `
            -Evidence 'deployment-state.json' `
            -Attempt $null

        Write-Output (
            "VALIDATED through Phase $PhaseId Stage $ThroughStage for site " +
            "$($config.site.name)."
        )

        return
    }

    $state.status = 'READY'
    $state.completedAt = [datetime]::UtcNow.ToString('o')
    $state.returnToPhase = $null
    $state.returnToStage = $null
    $state.returnToOperation = $null
    $state.pendingApproval = $null
    $state.pendingReboot = $null
    $state.pendingInteractiveAuthentication = $null
    $state.phases[[string]$PhaseId].status = 'PASS'
    $state.phases[[string]$PhaseId].completedAt = `
        [datetime]::UtcNow.ToString('o')

    Save-FactoryState `
        -State $state `
        -Path $statePath

    Write-FactoryExecutionEvent `
        -EventPath $executionEventPath `
        -EventType 'RunCompleted' `
        -Outcome 'PASSED' `
        -PhaseId $PhaseId `
        -StageId $ThroughStage `
        -Operation $null `
        -Scope 'Site' `
        -Node $null `
        -Summary (
            "Phase $PhaseId completed and the workflow is READY."
        ) `
        -Reason $null `
        -Evidence 'deployment-state.json' `
        -Attempt $null

    Write-Output (
        "READY: Phase $PhaseId completed for site $($config.site.name). " +
        "Evidence: $runDirectory"
    )
}
finally {
    try {
        if (
            $null -ne $context -and
            -not [string]::IsNullOrWhiteSpace($context.RunDirectory) -and
            (
                Test-Path `
                    -LiteralPath $context.RunDirectory `
                    -PathType Container
            )
        ) {
            $reportResult = Invoke-FactoryOperation `
                -Operation 'New-DeploymentReport' `
                -Context $context

            Write-FactoryJson `
                -Value $reportResult `
                -Path (
                    Join-Path `
                        $context.RunDirectory `
                        'evidence\deployment-report-operation.json'
                )
        }
    }
    catch {
        $reportFailureReason = Protect-FactoryErrorMessage `
            -Message $_.Exception.Message

        Write-Warning (
            "Deployment report generation failed: $reportFailureReason"
        )

        if (-not [string]::IsNullOrWhiteSpace($executionEventPath)) {
            try {
                Write-FactoryExecutionEvent `
                    -EventPath $executionEventPath `
                    -EventType 'ReportGenerationFailed' `
                    -Outcome 'FAILED' `
                    -PhaseId $PhaseId `
                    -StageId $null `
                    -Operation 'New-DeploymentReport' `
                    -Scope 'Site' `
                    -Node $null `
                    -Summary 'Deployment report generation failed.' `
                    -Reason $reportFailureReason `
                    -Evidence $null `
                    -Attempt $null
            }
            catch {
                # Reporting failure must never mask the deployment outcome.
            }
        }
    }

    Write-Progress `
        -Id 1 `
        -Activity "Azure Local Factory - Phase $PhaseId" `
        -Completed

    if ($null -ne $siteLock) {
        $siteLock.Dispose()
    }
}