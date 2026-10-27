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
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-HcnEnsureValue `
        -Object $Object `
        -Name $Name
}

function Test-ApprovedOperation {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$ApprovalKey
    )

    $approvedOperations = Get-Value `
        -Object $Context.State `
        -Name 'approvedOperations'

    if ($null -eq $approvedOperations) {
        return $false
    }

    if ($approvedOperations -is [System.Collections.IDictionary]) {
        return $approvedOperations.Contains($ApprovalKey)
    }

    return (
        $null -ne $approvedOperations.PSObject.Properties[$ApprovalKey]
    )
}

$node = Get-Value `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Ensure-EmbeddedAdaptersDisabled requires a node-scoped context.'
}

$config = Get-Value `
    -Object $Context `
    -Name 'Config'

$hardware = Get-Value `
    -Object $config `
    -Name 'hardware'

$adapterPattern = [string](
    Get-Value `
        -Object $hardware `
        -Name 'disabled_embedded_adapter_pattern'
)

$acceptableDisabledStatuses = @(
    Get-Value `
        -Object $hardware `
        -Name 'acceptable_disabled_adapter_statuses'
)

if ($acceptableDisabledStatuses.Count -lt 1) {
    $acceptableDisabledStatuses = @(
        'Disabled'
    )
}

$nodeName = [string](
    Get-Value `
        -Object $node `
        -Name 'name'
)

if ([string]::IsNullOrWhiteSpace($adapterPattern)) {
    return New-HcnEnsureResult `
        -Check 'Ensure-EmbeddedAdaptersDisabled' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            'No embedded-adapter disablement requirement applies to the ' +
            'resolved hardware profile.'
        ) `
        -AdditionalProperties @{
            Node = $nodeName
            AdapterPattern = $null
            Adapters = @()
        }
}

$approvalKey = (
    "$($Context.PhaseId)." +
    "$($Context.StageId)." +
    "$nodeName." +
    "$($Context.Operation)"
)

$inspectionResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param(
            [string]$AdapterPattern
        )

        $cluster = Get-Cluster -ErrorAction SilentlyContinue

        $adapters = @(
            Get-NetAdapter -ErrorAction Stop |
                Where-Object {
                    $_.InterfaceDescription -like $AdapterPattern
                }
        )

        [pscustomobject]@{
            ExistingCluster = ($null -ne $cluster)
            AdapterPattern  = $AdapterPattern
            Adapters        = @(
                $adapters |
                    Select-Object Name, Status, InterfaceDescription
            )
        }
    } `
    -ArgumentList @($adapterPattern)

$inspection = @($inspectionResponse.Data) |
    Select-Object -First 1

if ($inspection.ExistingCluster) {
    return New-HcnEnsureResult `
        -Check 'Ensure-EmbeddedAdaptersDisabled' `
        -Outcome 'Blocked' `
        -Summary (
            "Node $nodeName is already clustered. Embedded adapter changes are blocked."
        ) `
        -AdditionalProperties @{
            Node            = $nodeName
            ExistingCluster = $true
            AdapterPattern  = $adapterPattern
        }
}

$nonCompliantAdapters = @(
    $inspection.Adapters |
        Where-Object {
            $_.Status -notin $acceptableDisabledStatuses
        }
)

if ($nonCompliantAdapters.Count -eq 0) {
    $observedStatuses = @(
        $inspection.Adapters |
            ForEach-Object {
                "$($_.Name)=$($_.Status)"
            }
    )

    return New-HcnEnsureResult `
        -Check 'Ensure-EmbeddedAdaptersDisabled' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            "All embedded adapters matching $adapterPattern are in an accepted " +
            "inactive state: $($acceptableDisabledStatuses -join ', ')."
        ) `
        -AdditionalProperties @{
            Node                      = $nodeName
            AdapterPattern            = $adapterPattern
            Adapters                  = $inspection.Adapters
            AcceptableDisabledStates  = $acceptableDisabledStatuses
            ObservedStatuses          = $observedStatuses
        }
}

if (-not (Test-ApprovedOperation -Context $Context -ApprovalKey $approvalKey)) {
    return New-HcnEnsureResult `
        -Check 'Ensure-EmbeddedAdaptersDisabled' `
        -Outcome 'Blocked' `
        -Summary (
            "Embedded adapter disablement is required on node ${nodeName} for: " +
            "$($nonCompliantAdapters.Name -join ', ')."
        ) `
        -AdditionalProperties @{
            RequiresApproval = $true
            ApprovalReason   = (
                "Disabling embedded adapters matching $adapterPattern changes " +
                'host network state. Approval is required before applying the change.'
            )
            RequiresReboot   = $false
            ReconnectTarget  = $nodeName
            Node             = $nodeName
            AdapterPattern   = $adapterPattern
            NonCompliantAdapters = $nonCompliantAdapters
        }
}

$changeResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param(
            [string]$AdapterPattern,
            [string[]]$AcceptableDisabledStatuses
        )

        $changedAdapters = [System.Collections.Generic.List[string]]::new()
        $finalAdapters = [System.Collections.Generic.List[object]]::new()

        $adapters = @(
            Get-NetAdapter -ErrorAction Stop |
                Where-Object {
                    $_.InterfaceDescription -like $AdapterPattern
                }
        )

        foreach ($adapter in $adapters) {
            if ($adapter.Status -notin $AcceptableDisabledStatuses) {
                Disable-NetAdapter `
                    -Name $adapter.Name `
                    -Confirm:$false `
                    -ErrorAction Stop

                $changedAdapters.Add($adapter.Name)
            }

            $finalAdapter = Get-NetAdapter `
                -Name $adapter.Name `
                -ErrorAction Stop

            $finalAdapters.Add(
                [pscustomobject]@{
                    Name                 = $finalAdapter.Name
                    Status               = $finalAdapter.Status
                    InterfaceDescription = $finalAdapter.InterfaceDescription
                }
            )
        }

        [pscustomobject]@{
            ChangedAdapters = $changedAdapters.ToArray()
            FinalAdapters   = $finalAdapters.ToArray()
        }
    } `
    -ArgumentList @(
        $adapterPattern,
        $acceptableDisabledStatuses
    )

$changeResult = @($changeResponse.Data) |
    Select-Object -First 1

return New-HcnEnsureResult `
    -Check 'Ensure-EmbeddedAdaptersDisabled' `
    -Outcome 'Changed' `
    -Changed $true `
    -Summary (
        "Disabled embedded adapter(s) on node ${nodeName}: " +
        "$($changeResult.ChangedAdapters -join ', ')."
    ) `
    -AdditionalProperties @{
        Node                     = $nodeName
        AdapterPattern           = $adapterPattern
        ChangedAdapters          = $changeResult.ChangedAdapters
        FinalAdapters            = $changeResult.FinalAdapters
        AcceptableDisabledStates = $acceptableDisabledStatuses
    }