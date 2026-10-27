#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Stage,

    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\Factory.psm1" -Force

$phaseId = [int]$Context.PhaseId
$stageId = [int]$Stage.id
$allOperations = @($Stage.operations)

if ($allOperations.Count -lt 1) {
    throw "Phase $phaseId Stage $stageId has no operations."
}

if ($null -eq $Context.LastResults) {
    $Context.LastResults = [System.Collections.Generic.List[object]]::new()
}
else {
    $Context.LastResults.Clear()
}

$results = [System.Collections.Generic.List[object]]::new()
$Paused = $false
$PendingApproval = $null

function Get-ResultValue {
    param(
        [AllowNull()]
        [object]$Result,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Result) {
        return $null
    }

    if ($Result -is [System.Collections.IDictionary]) {
        if ($Result.Contains($Name)) {
            return $Result[$Name]
        }

        return $null
    }

    $property = $Result.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Get-ContextValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Context.ContainsKey($Name)) {
        return $Context[$Name]
    }

    return $null
}

function Get-FactoryPassSummary {
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [object]$Result
    )

    $explicitSummary = Get-ResultValue `
        -Result $Result `
        -Name 'Summary'

    if (-not [string]::IsNullOrWhiteSpace([string]$explicitSummary)) {
        return [string]$explicitSummary
    }

    return "Operation $Operation completed successfully."
}

function Get-FactoryOperationOutcome {
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    $outcome = Get-ResultValue `
        -Result $Result `
        -Name 'Outcome'

    $changed = Get-ResultValue `
        -Result $Result `
        -Name 'Changed'

    if (-not [string]::IsNullOrWhiteSpace([string]$outcome)) {
        return [string]$outcome
    }

    if ($changed -eq $true) {
        return 'Changed'
    }

    return 'Validated'
}

function Get-OperationCheckpointKey {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Site', 'Node')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$Operation,

        [AllowNull()]
        [string]$NodeName
    )

    if ($Scope -eq 'Site') {
        return "Site::$Operation"
    }

    if ([string]::IsNullOrWhiteSpace($NodeName)) {
        throw "Node checkpoint requires a node name: $Operation"
    }

    return "Node::$NodeName::$Operation"
}

function Get-StageCheckpointStore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId
    )

    if ($null -eq $Context.State.operationCheckpoints) {
        $Context.State.operationCheckpoints = @{}
    }

    $stageCheckpointKey = "$PhaseId.$StageId"

    if (
        -not $Context.State.operationCheckpoints.Contains(
            $stageCheckpointKey
        )
    ) {
        $Context.State.operationCheckpoints[$stageCheckpointKey] = @{}
    }

    return $Context.State.operationCheckpoints[$stageCheckpointKey]
}

function Set-OperationCheckpoint {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId,

        [Parameter(Mandatory)]
        [ValidateSet('Site', 'Node')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$Operation,

        [AllowNull()]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'SKIPPED', 'PAUSED')]
        [string]$Status,

        [AllowNull()]
        [string]$Outcome,

        [AllowNull()]
        [string]$Summary,

        [AllowNull()]
        [string]$Reason,

        [AllowNull()]
        [string]$EvidenceSource
    )

    $store = Get-StageCheckpointStore `
        -Context $Context `
        -PhaseId $PhaseId `
        -StageId $StageId

    $checkpointKey = Get-OperationCheckpointKey `
        -Scope $Scope `
        -Operation $Operation `
        -NodeName $NodeName

    $store[$checkpointKey] = @{
        status = $Status
        phaseId = $PhaseId
        stageId = $StageId
        operation = $Operation
        scope = $Scope
        node = $NodeName
        outcome = $Outcome
        summary = $Summary
        reason = $Reason
        evidenceSource = $EvidenceSource
        timestamp = [datetime]::UtcNow.ToString('o')
    }
}

function Test-OperationCheckpoint {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId,

        [Parameter(Mandatory)]
        [ValidateSet('Site', 'Node')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$Operation,

        [AllowNull()]
        [string]$NodeName
    )

    if ($null -eq $Context.State.operationCheckpoints) {
        return $false
    }

    $stageCheckpointKey = "$PhaseId.$StageId"

    if (
        -not $Context.State.operationCheckpoints.Contains(
            $stageCheckpointKey
        )
    ) {
        return $false
    }

    $store = $Context.State.operationCheckpoints[$stageCheckpointKey]

    $checkpointKey = Get-OperationCheckpointKey `
        -Scope $Scope `
        -Operation $Operation `
        -NodeName $NodeName

    if (-not $store.Contains($checkpointKey)) {
        return $false
    }

    $checkpoint = $store[$checkpointKey]

    return (
        $checkpoint.status -in @(
            'PASS',
            'SKIPPED'
        )
    )
}

function Seed-OperationCheckpointFromPendingApproval {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId,

        [Parameter(Mandatory)]
        [object[]]$OperationsBeforeStart
    )

    foreach ($operation in $OperationsBeforeStart) {
        $metadata = Get-FactoryOperationMetadata `
            -Operation $operation

        if ($metadata.Scope -eq 'Site') {
            Set-OperationCheckpoint `
                -Context $Context `
                -PhaseId $PhaseId `
                -StageId $StageId `
                -Scope 'Site' `
                -Operation $operation `
                -NodeName $null `
                -Status 'PASS' `
                -Outcome 'Validated' `
                -Summary (
                    'Checkpoint seeded from the same-run pending approval state.'
                ) `
                -Reason $null `
                -EvidenceSource 'SameRunPendingApprovalMigration'

            continue
        }

        foreach ($node in @($Context.Config.nodes)) {
            Set-OperationCheckpoint `
                -Context $Context `
                -PhaseId $PhaseId `
                -StageId $StageId `
                -Scope 'Node' `
                -Operation $operation `
                -NodeName ([string]$node.name) `
                -Status 'PASS' `
                -Outcome 'Validated' `
                -Summary (
                    'Checkpoint seeded from the same-run pending approval state.'
                ) `
                -Reason $null `
                -EvidenceSource 'SameRunPendingApprovalMigration'
        }
    }
}

function Assert-PriorOperationCheckpoints {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId,

        [Parameter(Mandatory)]
        [object[]]$OperationsBeforeStart
    )

    foreach ($operation in $OperationsBeforeStart) {
        $metadata = Get-FactoryOperationMetadata `
            -Operation $operation

        if ($metadata.Scope -eq 'Site') {
            if (
                -not (
                    Test-OperationCheckpoint `
                        -Context $Context `
                        -PhaseId $PhaseId `
                        -StageId $StageId `
                        -Scope 'Site' `
                        -Operation $operation `
                        -NodeName $null
                )
            ) {
                throw (
                    "Focused resume requires valid Stage $stageId checkpoint " +
                    "evidence for site operation $operation."
                )
            }

            continue
        }

        foreach ($node in @($Context.Config.nodes)) {
            $nodeName = [string]$node.name

            if (
                -not (
                    Test-OperationCheckpoint `
                        -Context $Context `
                        -PhaseId $PhaseId `
                        -StageId $StageId `
                        -Scope 'Node' `
                        -Operation $operation `
                        -NodeName $nodeName
                )
            ) {
                throw (
                    "Focused resume requires valid Stage $stageId checkpoint " +
                    "evidence for node $nodeName operation $operation."
                )
            }
        }
    }
}

function Get-FactoryApprovalRequest {
    param(
        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId,

        [Parameter(Mandatory)]
        [string]$Operation,

        [AllowNull()]
        [string]$NodeName
    )

    $requiresApproval = Get-ResultValue `
        -Result $Result `
        -Name 'RequiresApproval'

    if ($requiresApproval -ne $true) {
        return $null
    }

    $approvalKey = Get-ResultValue `
        -Result $Result `
        -Name 'ApprovalKey'

    if ([string]::IsNullOrWhiteSpace([string]$approvalKey)) {
        $approvalKey = "$PhaseId.$StageId.$NodeName.$Operation"
    }

    return [pscustomobject]@{
        ApprovalKey = [string]$approvalKey
        ApprovalType = 'ConfigurationChange'
        PhaseId = $PhaseId
        StageId = $StageId
        Operation = $Operation
        Node = $NodeName
        Reason = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'ApprovalReason'
        )
        RequiresReboot = [bool](
            Get-ResultValue `
                -Result $Result `
                -Name 'RequiresReboot'
        )
        ReconnectTarget = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'ReconnectTarget'
        )
        ReturnToOperation = $Operation
        RequestedAt = [datetime]::UtcNow.ToString('o')
    }
}

function Get-FactoryRebootApprovalRequest {
    param(
        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId,

        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [string]$NodeName
    )

    $pauseRequested = Get-ResultValue `
        -Result $Result `
        -Name 'PauseRequested'

    $pauseType = [string](
        Get-ResultValue `
            -Result $Result `
            -Name 'PauseType'
    )

    if (
        $pauseRequested -ne $true -or
        $pauseType -notin @(
            'Reboot',
            'RebootPending'
        )
    ) {
        return $null
    }

    $rebootReason = [string](
        Get-ResultValue `
            -Result $Result `
            -Name 'RebootReason'
    )

    if ([string]::IsNullOrWhiteSpace($rebootReason)) {
        $rebootReason = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'Reason'
        )
    }

    if ([string]::IsNullOrWhiteSpace($rebootReason)) {
        $rebootReason = (
            "Operation $Operation changed node $NodeName and requires " +
            'a controlled reboot before workflow continuation.'
        )
    }

    return [pscustomobject]@{
        ApprovalKey = "$PhaseId.$StageId.$NodeName.$Operation.Reboot"
        ApprovalType = 'Reboot'
        PhaseId = $PhaseId
        StageId = $StageId
        Operation = $Operation
        Node = $NodeName
        Reason = $rebootReason
        RequiresReboot = $true
        ReconnectTarget = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'ReconnectTarget'
        )
        ReturnToOperation = $Operation
        NativeBootstrapRebootPending = (
            $pauseType -eq 'RebootPending' -or
            (
                Get-ResultValue `
                    -Result $Result `
                    -Name 'NativeBootstrapRebootPending'
            ) -eq $true
        )
        RequestedAt = [datetime]::UtcNow.ToString('o')
    }
}

function Get-FactoryInteractiveAuthenticationRequest {
    param(
        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId,

        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [string]$NodeName
    )

    $pauseRequested = Get-ResultValue `
        -Result $Result `
        -Name 'PauseRequested'

    $pauseType = [string](
        Get-ResultValue `
            -Result $Result `
            -Name 'PauseType'
    )

    if (
        $pauseRequested -ne $true -or
        $pauseType -ne 'InteractiveAuthentication'
    ) {
        return $null
    }

    $reason = [string](
        Get-ResultValue `
            -Result $Result `
            -Name 'Reason'
    )

    if ([string]::IsNullOrWhiteSpace($reason)) {
        $reason = (
            "Interactive authentication is required for operation " +
            "$Operation on node $NodeName."
        )
    }

    return [pscustomobject]@{
        ApprovalKey = (
            "$PhaseId.$StageId.$NodeName.$Operation." +
            'InteractiveAuthentication'
        )
        ApprovalType = 'InteractiveAuthentication'
        AuthenticationMethod = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'AuthenticationMethod'
        )
        PhaseId = $PhaseId
        StageId = $StageId
        Operation = $Operation
        Node = $NodeName
        Workflow = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'Workflow'
        )
        BootstrapStatus = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'BootstrapStatus'
        )
        BootstrapConfigPath = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'BootstrapConfigPath'
        )
        StatusRecordPath = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'StatusRecordPath'
        )
        LastCheckedAtUtc = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'LastCheckedAtUtc'
        )
        SessionStartedAtUtc = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'SessionStartedAtUtc'
        )
        ReturnToOperation = $Operation
        Reason = $reason
        RequiresReboot = $false
        ReconnectTarget = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'ReconnectTarget'
        )
        LogPath = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'LogPath'
        )
        ErrorLogPath = [string](
            Get-ResultValue `
                -Result $Result `
                -Name 'ErrorLogPath'
        )
        ProcessId = Get-ResultValue `
            -Result $Result `
            -Name 'ProcessId'
        RequestedAt = [datetime]::UtcNow.ToString('o')
    }
}

function New-FactoryNodeContext {
    param(
        [Parameter(Mandatory)]
        [hashtable]$BaseContext,

        [Parameter(Mandatory)]
        [object]$Node
    )

    $nodeContext = @{}

    foreach ($key in $BaseContext.Keys) {
        $nodeContext[$key] = $BaseContext[$key]
    }

    $nodeContext.Node = $Node
    $nodeContext.NodeState = $BaseContext.State.nodes[$Node.name]

    return $nodeContext
}

function Set-NodeStageState {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [int]$PhaseId,

        [Parameter(Mandatory)]
        [int]$StageId,

        [Parameter(Mandatory)]
        [ValidateSet('NOT_STARTED', 'RUNNING', 'PASS', 'FAIL', 'PAUSED')]
        [string]$Status,

        [AllowNull()]
        [string]$Reason
    )

    $nodeState = $Context.State.nodes[$NodeName]
    $stageKey = "$PhaseId.$StageId"

    if ($null -eq $nodeState.stages) {
        $nodeState.stages = @{}
    }

    $nodeState.currentPhase = $PhaseId
    $nodeState.currentStage = $StageId
    $nodeState.status = $Status
    $nodeState.lastError = $Reason

    $nodeState.stages[$stageKey] = @{
        status = $Status
        timestamp = [datetime]::UtcNow.ToString('o')
        reason = $Reason
    }
}

$startOperation = [string](
    Get-ContextValue `
        -Context $Context `
        -Name 'StartOperation'
)

$operations = $allOperations

if (-not [string]::IsNullOrWhiteSpace($startOperation)) {
    $startIndex = [array]::IndexOf(
        [string[]]$allOperations,
        $startOperation
    )

    if ($startIndex -lt 0) {
        throw (
            "Focused operation $startOperation is not defined in Phase " +
            "$phaseId Stage $stageId."
        )
    }

    $operationsBeforeStart = @(
        $allOperations |
            Select-Object -First $startIndex
    )

    $allowPendingOperationResume = (
        Get-ContextValue `
            -Context $Context `
            -Name 'AllowPendingOperationResume'
    ) -eq $true

    if (
        $operationsBeforeStart.Count -gt 0 -and
        $allowPendingOperationResume
    ) {
        Seed-OperationCheckpointFromPendingApproval `
            -Context $Context `
            -PhaseId $phaseId `
            -StageId $stageId `
            -OperationsBeforeStart $operationsBeforeStart
    }

    if ($operationsBeforeStart.Count -gt 0) {
        Assert-PriorOperationCheckpoints `
            -Context $Context `
            -PhaseId $phaseId `
            -StageId $stageId `
            -OperationsBeforeStart $operationsBeforeStart
    }

    $operations = @(
        $allOperations |
            Select-Object -Skip $startIndex
    )

    Write-Host (
        "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
        "Focused resume: Phase $phaseId Stage $stageId begins at " +
        "$startOperation."
    ) -ForegroundColor Cyan
}

foreach ($operation in $operations) {
    $metadata = Get-FactoryOperationMetadata `
        -Operation $operation

    if ($Context.Mode -eq 'Validate' -and [bool]$metadata.Mutates) {
        throw "Validate mode blocks mutating operation: $operation"
    }

    if ($metadata.Scope -eq 'Site') {
        try {
            $result = Invoke-FactoryOperation `
                -Operation $operation `
                -Context $Context

            $outcome = Get-FactoryOperationOutcome `
                -Result $result

            $operationResult = [pscustomobject]@{
                Passed = $true
                PhaseId = $phaseId
                StageId = $stageId
                Operation = $operation
                Scope = 'Site'
                Node = $null
                Outcome = $outcome
                Changed = (
                    Get-ResultValue `
                        -Result $result `
                        -Name 'Changed'
                )
                Summary = Get-FactoryPassSummary `
                    -Operation $operation `
                    -Result $result
                Result = $result
                CompletedAt = [datetime]::UtcNow.ToString('o')
            }

            $approvalRequest = Get-FactoryApprovalRequest `
                -Result $result `
                -PhaseId $phaseId `
                -StageId $stageId `
                -Operation $operation `
                -NodeName $null

            if ($null -ne $approvalRequest) {
                Set-OperationCheckpoint `
                    -Context $Context `
                    -PhaseId $phaseId `
                    -StageId $stageId `
                    -Scope 'Site' `
                    -Operation $operation `
                    -NodeName $null `
                    -Status 'PAUSED' `
                    -Outcome $outcome `
                    -Summary $operationResult.Summary `
                    -Reason $approvalRequest.Reason `
                    -EvidenceSource 'FactoryPause'

                $results.Add($operationResult)
                $Context.LastResults.Add($operationResult)

                return [pscustomobject]@{
                    Passed = $true
                    Paused = $true
                    PhaseId = $phaseId
                    StageId = $stageId
                    Results = $results.ToArray()
                    PendingApproval = $approvalRequest
                    CompletedAt = [datetime]::UtcNow.ToString('o')
                }
            }

            $checkpointStatus = if (
                $outcome -in @(
                    'AlreadyCompliant',
                    'Skipped'
                )
            ) {
                'SKIPPED'
            }
            else {
                'PASS'
            }

            Set-OperationCheckpoint `
                -Context $Context `
                -PhaseId $phaseId `
                -StageId $stageId `
                -Scope 'Site' `
                -Operation $operation `
                -NodeName $null `
                -Status $checkpointStatus `
                -Outcome $outcome `
                -Summary $operationResult.Summary `
                -Reason $null `
                -EvidenceSource 'FactoryExecution'

            $results.Add($operationResult)
            $Context.LastResults.Add($operationResult)

            $statusLabel = switch ($outcome) {
                'AlreadyCompliant' { 'SKIPPED' }
                'Skipped' { 'SKIPPED' }
                'Changed' { 'CHANGED' }
                default { 'PASSED' }
            }

            Write-Host (
                "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
                "Site | $operation | $statusLabel | $($operationResult.Summary)"
            ) -ForegroundColor Green
        }
        catch {
            $failure = [pscustomobject]@{
                Passed = $false
                PhaseId = $phaseId
                StageId = $stageId
                Operation = $operation
                Scope = 'Site'
                Node = $null
                Reason = Protect-FactoryErrorMessage `
                    -Message $_.Exception.Message
                CompletedAt = [datetime]::UtcNow.ToString('o')
            }

            $Context.LastResults.Add($failure)

            throw $failure.Reason
        }

        continue
    }

    foreach ($node in @($Context.Config.nodes)) {
        $nodeName = [string]$node.name

        $nodeContext = New-FactoryNodeContext `
            -BaseContext $Context `
            -Node $node

        try {
            Set-NodeStageState `
                -Context $Context `
                -NodeName $nodeName `
                -PhaseId $phaseId `
                -StageId $stageId `
                -Status 'RUNNING' `
                -Reason $null

            $result = Invoke-FactoryOperation `
                -Operation $operation `
                -Context $nodeContext

            $outcome = Get-FactoryOperationOutcome `
                -Result $result

            $operationResult = [pscustomobject]@{
                Passed = $true
                PhaseId = $phaseId
                StageId = $stageId
                Operation = $operation
                Scope = 'Node'
                Node = $nodeName
                Outcome = $outcome
                Changed = (
                    Get-ResultValue `
                        -Result $result `
                        -Name 'Changed'
                )
                Summary = Get-FactoryPassSummary `
                    -Operation $operation `
                    -Result $result
                Result = $result
                CompletedAt = [datetime]::UtcNow.ToString('o')
            }

            $approvalRequest = Get-FactoryApprovalRequest `
                -Result $result `
                -PhaseId $phaseId `
                -StageId $stageId `
                -Operation $operation `
                -NodeName $nodeName

            if ($null -eq $approvalRequest) {
                $approvalRequest = Get-FactoryRebootApprovalRequest `
                    -Result $result `
                    -PhaseId $phaseId `
                    -StageId $stageId `
                    -Operation $operation `
                    -NodeName $nodeName
            }

            if ($null -eq $approvalRequest) {
                $approvalRequest = Get-FactoryInteractiveAuthenticationRequest `
                    -Result $result `
                    -PhaseId $phaseId `
                    -StageId $stageId `
                    -Operation $operation `
                    -NodeName $nodeName
            }

            if ($null -ne $approvalRequest) {
                Set-OperationCheckpoint `
                    -Context $Context `
                    -PhaseId $phaseId `
                    -StageId $stageId `
                    -Scope 'Node' `
                    -Operation $operation `
                    -NodeName $nodeName `
                    -Status 'PAUSED' `
                    -Outcome $outcome `
                    -Summary $operationResult.Summary `
                    -Reason $approvalRequest.Reason `
                    -EvidenceSource 'FactoryPause'

                Set-NodeStageState `
                    -Context $Context `
                    -NodeName $nodeName `
                    -PhaseId $phaseId `
                    -StageId $stageId `
                    -Status 'PAUSED' `
                    -Reason $approvalRequest.Reason

                $results.Add($operationResult)
                $Context.LastResults.Add($operationResult)

                Write-Host (
                    "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
                    "$nodeName | $operation | PAUSED | " +
                    "$($approvalRequest.ApprovalType) | " +
                    "$($approvalRequest.Reason)"
                ) -ForegroundColor Yellow

                return [pscustomobject]@{
                    Passed = $true
                    Paused = $true
                    PhaseId = $phaseId
                    StageId = $stageId
                    Results = $results.ToArray()
                    PendingApproval = $approvalRequest
                    CompletedAt = [datetime]::UtcNow.ToString('o')
                }
            }

            $checkpointStatus = if (
                $outcome -in @(
                    'AlreadyCompliant',
                    'Skipped'
                )
            ) {
                'SKIPPED'
            }
            else {
                'PASS'
            }

            Set-OperationCheckpoint `
                -Context $Context `
                -PhaseId $phaseId `
                -StageId $stageId `
                -Scope 'Node' `
                -Operation $operation `
                -NodeName $nodeName `
                -Status $checkpointStatus `
                -Outcome $outcome `
                -Summary $operationResult.Summary `
                -Reason $null `
                -EvidenceSource 'FactoryExecution'

            $results.Add($operationResult)
            $Context.LastResults.Add($operationResult)

            $statusLabel = switch ($outcome) {
                'AlreadyCompliant' { 'SKIPPED' }
                'Skipped' { 'SKIPPED' }
                'Changed' { 'CHANGED' }
                default { 'PASSED' }
            }

            Write-Host (
                "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
                "$nodeName | $operation | $statusLabel | " +
                "$($operationResult.Summary)"
            ) -ForegroundColor Green
        }
        catch {
            $reason = Protect-FactoryErrorMessage `
                -Message $_.Exception.Message

            Set-NodeStageState `
                -Context $Context `
                -NodeName $nodeName `
                -PhaseId $phaseId `
                -StageId $stageId `
                -Status 'FAIL' `
                -Reason $reason

            $failure = [pscustomobject]@{
                Passed = $false
                PhaseId = $phaseId
                StageId = $stageId
                Operation = $operation
                Scope = 'Node'
                Node = $nodeName
                Reason = $reason
                CompletedAt = [datetime]::UtcNow.ToString('o')
            }

            $Context.LastResults.Add($failure)

            $escapedOperation = [regex]::Escape($operation)

            $cleanReason = $reason -replace `
                "^(Operation\s+$escapedOperation\s+failed\.\s*)",
                ''

            $cleanReason = $cleanReason -replace `
                "^$escapedOperation\s+failed\.\s*",
                ''

            throw (
                "Node=$nodeName; Operation=$operation; Outcome=Failed. " +
                $cleanReason
            )
        }
    }
}

foreach ($node in @($Context.Config.nodes)) {
    $nodeName = [string]$node.name
    $nodeState = $Context.State.nodes[$nodeName]

    if (
        $nodeState.currentPhase -eq $phaseId -and
        $nodeState.currentStage -eq $stageId -and
        $nodeState.status -eq 'RUNNING'
    ) {
        Set-NodeStageState `
            -Context $Context `
            -NodeName $nodeName `
            -PhaseId $phaseId `
            -StageId $stageId `
            -Status 'PASS' `
            -Reason $null
    }
}

$gateResult = & "$PSScriptRoot\Invoke-ValidationGate.ps1" `
    -Results $results.ToArray() `
    -PhaseId $phaseId `
    -StageId $stageId

return [pscustomobject]@{
    Passed = $gateResult.Passed
    Paused = $Paused
    PendingApproval = $PendingApproval
    Check = "Phase-$phaseId-Stage-$stageId"
    PhaseId = $phaseId
    StageId = $stageId
    Results = $results.ToArray()
    GateResult = $gateResult
    CompletedAt = [datetime]::UtcNow.ToString('o')
}