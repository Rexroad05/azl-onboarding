#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$StatePath,

    [Parameter(Mandatory)]
    [ValidateSet('Approve', 'Deny')]
    [string]$Decision
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    throw "Deployment state does not exist: $StatePath"
}

$state = Get-Content `
    -LiteralPath $StatePath `
    -Raw |
    ConvertFrom-Json `
    -AsHashtable

if ($state.status -ne 'PAUSED') {
    throw (
        "Deployment state is $($state.status), not PAUSED. " +
        'No approval action is available.'
    )
}

if ($null -eq $state.pendingApproval) {
    throw 'Deployment state contains no pending approval request.'
}

$approvalKey = [string]$state.pendingApproval.ApprovalKey

if ([string]::IsNullOrWhiteSpace($approvalKey)) {
    throw 'Pending approval request does not contain ApprovalKey.'
}

$approvalType = $null

if ($state.pendingApproval -is [System.Collections.IDictionary]) {
    if ($state.pendingApproval.Contains('ApprovalType')) {
        $approvalType = [string]$state.pendingApproval['ApprovalType']
    }
}
elseif ($null -ne $state.pendingApproval.PSObject.Properties['ApprovalType']) {
    $approvalType = [string]$state.pendingApproval.ApprovalType
}

if ([string]::IsNullOrWhiteSpace($approvalType)) {
    $approvalType = 'ConfigurationChange'

    if ($state.pendingApproval -is [System.Collections.IDictionary]) {
        $state.pendingApproval['ApprovalType'] = $approvalType
    }
    else {
        Add-Member `
            -InputObject $state.pendingApproval `
            -MemberType NoteProperty `
            -Name 'ApprovalType' `
            -Value $approvalType `
            -Force
    }
}

if ($approvalType -eq 'InteractiveAuthentication') {
    throw (
        'Interactive authentication does not use Approve or Deny. ' +
        'Complete the device-code sign-in, then resume the workflow.'
    )
}

$decisionTime = [datetime]::UtcNow.ToString('o')
$decisionUser = $env:USERNAME

if ([string]::IsNullOrWhiteSpace($decisionUser)) {
    $decisionUser = 'UnknownOperator'
}

if ($Decision -eq 'Approve') {
    $state.approvedOperations[$approvalKey] = @{
        ApprovedAt   = $decisionTime
        ApprovedBy   = $decisionUser
        ApprovalType = $approvalType
        PhaseId      = $state.pendingApproval.PhaseId
        StageId      = $state.pendingApproval.StageId
        Operation    = $state.pendingApproval.Operation
        Node         = $state.pendingApproval.Node
    }

    $state.pendingApproval.Decision = 'Approved'
    $state.pendingApproval.DecisionAt = $decisionTime
    $state.pendingApproval.DecisionBy = $decisionUser

    if (
        $approvalType -eq 'Reboot' -and
        $null -ne $state.pendingReboot
    ) {
        $state.pendingReboot.Decision = 'Approved'
        $state.pendingReboot.DecisionAt = $decisionTime
        $state.pendingReboot.DecisionBy = $decisionUser
        $state.pendingReboot.Status = 'APPROVED'
    }

    $state.status = 'APPROVED'
}
else {
    $state.pendingApproval.Decision = 'Denied'
    $state.pendingApproval.DecisionAt = $decisionTime
    $state.pendingApproval.DecisionBy = $decisionUser

    if (
        $approvalType -eq 'Reboot' -and
        $null -ne $state.pendingReboot
    ) {
        $state.pendingReboot.Decision = 'Denied'
        $state.pendingReboot.DecisionAt = $decisionTime
        $state.pendingReboot.DecisionBy = $decisionUser
        $state.pendingReboot.Status = 'DENIED'
    }

    $state.status = 'DENIED'
}

$temporaryPath = "$StatePath.$([guid]::NewGuid().ToString('N')).tmp"

try {
    $state |
        ConvertTo-Json -Depth 50 |
        Set-Content `
            -LiteralPath $temporaryPath `
            -Encoding utf8

    Move-Item `
        -LiteralPath $temporaryPath `
        -Destination $StatePath `
        -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item `
            -LiteralPath $temporaryPath `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

return [pscustomobject]@{
    StatePath    = $StatePath
    Decision     = $Decision
    ApprovalKey  = $approvalKey
    ApprovalType = $approvalType
    UpdatedAt    = [datetime]::UtcNow.ToString('o')
}