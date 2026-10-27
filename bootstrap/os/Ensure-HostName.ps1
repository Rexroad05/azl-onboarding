#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\HcnEnsure.Common.psm1" -Force

function Get-Value {
    param([object]$Object, [string]$Name)
    return Get-HcnEnsureValue -Object $Object -Name $Name
}

function Test-ApprovedOperation {
    param([hashtable]$Context, [string]$ApprovalKey)

    $approved = Get-Value -Object $Context.State -Name 'approvedOperations'

    if ($null -eq $approved) {
        return $false
    }

    if ($approved -is [System.Collections.IDictionary]) {
        return $approved.Contains($ApprovalKey)
    }

    return ($null -ne $approved.PSObject.Properties[$ApprovalKey])
}

$node = Get-Value -Object $Context -Name 'Node'

if ($null -eq $node) {
    throw 'Ensure-HostName requires a node-scoped execution context.'
}

$nodeName = [string](Get-Value -Object $node -Name 'name')

if ([string]::IsNullOrWhiteSpace($nodeName)) {
    throw 'The resolved node configuration does not contain a node name.'
}

$inspectionResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        $cluster = Get-Cluster -ErrorAction SilentlyContinue

        [pscustomobject]@{
            ExistingCluster = ($null -ne $cluster)
            CurrentHostName = $env:COMPUTERNAME
        }
    }

$inspection = @($inspectionResponse.Data) |
    Select-Object -First 1

if ($inspection.ExistingCluster) {
    return New-HcnEnsureResult `
        -Check 'Ensure-HostName' `
        -Outcome 'Blocked' `
        -Summary "Node $nodeName is already clustered. Hostname changes are blocked." `
        -AdditionalProperties @{
            Node            = $nodeName
            ExistingCluster = $true
            CurrentHostName = $inspection.CurrentHostName
        }
}

if ($inspection.CurrentHostName -ieq $nodeName) {
    return New-HcnEnsureResult `
        -Check 'Ensure-HostName' `
        -Outcome 'AlreadyCompliant' `
        -Summary "Hostname $nodeName is already configured." `
        -AdditionalProperties @{
            Node            = $nodeName
            CurrentHostName = $inspection.CurrentHostName
        }
}

$phaseId = Get-Value `
    -Object $Context `
    -Name 'PhaseId'

$stageId = Get-Value `
    -Object $Context `
    -Name 'StageId'

$operationName = [string](
    Get-Value `
        -Object $Context `
        -Name 'Operation'
)

if ($null -eq $phaseId) {
    $phaseId = 1
}

if ($null -eq $stageId) {
    $stageId = 2
}

if ([string]::IsNullOrWhiteSpace($operationName)) {
    $operationName = 'Ensure-HostName'
}

$approvalKey = (
    "$phaseId." +
    "$stageId." +
    "$nodeName." +
    "$operationName"
)

if (-not (Test-ApprovedOperation -Context $Context -ApprovalKey $approvalKey)) {
    return New-HcnEnsureResult `
        -Check 'Ensure-HostName' `
        -Outcome 'Blocked' `
        -Summary "Hostname correction from $($inspection.CurrentHostName) to $nodeName is required." `
        -AdditionalProperties @{
            RequiresApproval = $true
            ApprovalReason   = (
                "Renaming an Azure Local node requires a reboot and changes the WinRM reconnect identity. " +
                "Approve only after verifying that the desired hostname is correct and not already assigned."
            )
            RequiresReboot   = $true
            ReconnectTarget  = $nodeName
            Node             = $nodeName
            CurrentHostName  = $inspection.CurrentHostName
            DesiredHostName  = $nodeName
        }
}

$changeResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param($DesiredHostName)

        Rename-Computer `
            -NewName $DesiredHostName `
            -Force `
            -ErrorAction Stop
        } `
        -ArgumentList @($nodeName)

    $null = @($changeResponse.Data)

return New-HcnEnsureResult `
    -Check 'Ensure-HostName' `
    -Outcome 'Changed' `
    -Changed $true `
    -Summary "Renamed node from $($inspection.CurrentHostName) to $nodeName. Reboot approval and reconnect are required before continuing." `
        -AdditionalProperties @{
            Node            = $nodeName
            PreviousHostName = $inspection.CurrentHostName
            DesiredHostName  = $nodeName
            RequiresReboot   = $true
            ReconnectTarget  = $nodeName
            PauseRequested   = $true
            PauseType        = 'Reboot'
            RebootReason     = (
                "Node rename from $($inspection.CurrentHostName) to $nodeName " +
                'requires a reboot and post-reboot validation.'
            )
        }