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

    if ($null -eq $Object) {
        return $null
    }

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

    $approvedOperations = Get-Value -Object $Context.State -Name 'approvedOperations'

    if ($null -eq $approvedOperations) {
        return $false
    }

    if ($approvedOperations -is [System.Collections.IDictionary]) {
        return $approvedOperations.Contains($ApprovalKey)
    }

    return ($null -ne $approvedOperations.PSObject.Properties[$ApprovalKey])
}

function New-ApprovalRequiredResult {
    param(
        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [string]$Summary,

        [Parameter(Mandatory)]
        [string]$Reason,

        [Parameter(Mandatory)]
        [string]$ReconnectTarget
    )

    return New-HcnEnsureResult `
        -Check $Check `
        -Outcome 'Blocked' `
        -Summary $Summary `
        -AdditionalProperties @{
            RequiresApproval = $true
            ApprovalReason   = $Reason
            RequiresReboot   = $false
            ReconnectTarget  = $ReconnectTarget
        }
}

$deployment = Get-Value `
    -Object $Context.Config `
    -Name 'deployment'

$singleServer = Get-Value `
    -Object $deployment `
    -Name 'single_server'

$isSingleServer = (
    (Get-Value -Object $singleServer -Name 'enabled') -eq $true
)

$hardware = Get-Value `
    -Object $Context.Config `
    -Name 'hardware'

$managementVnic = Get-Value `
    -Object $hardware `
    -Name 'management_vnic'

if ($isSingleServer -and $null -ne $managementVnic) {
    $managementVnicName = [string](
        Get-Value `
            -Object $managementVnic `
            -Name 'name'
    )

    $expectedVlanMode = [string](
        Get-Value `
            -Object $managementVnic `
            -Name 'vlan_mode'
    )

    $expectedVlanId = [int](
        Get-Value `
            -Object $managementVnic `
            -Name 'vlan_id'
    )

    $result = Invoke-ManagementPlaneCommand `
        -Context $Context `
        -OperationName 'Ensure-ManagementVlan' `
        -ArgumentList @(
            $managementVnicName,
            $expectedVlanMode,
            $expectedVlanId
        ) `
        -ScriptBlock {
            param(
                [string]$ManagementVnicName,
                [string]$ExpectedVlanMode,
                [int]$ExpectedVlanId
            )

            $vlan = Get-VMNetworkAdapterVlan `
                -ManagementOS `
                -VMNetworkAdapterName $ManagementVnicName `
                -ErrorAction Stop

            [pscustomobject]@{
                ComputerName   = $env:COMPUTERNAME
                Adapter        = $ManagementVnicName
                OperationMode  = [string]$vlan.OperationMode
                AccessVlanId   = [int]$vlan.AccessVlanId
                IsCompliant    = (
                    [string]$vlan.OperationMode -eq $ExpectedVlanMode -and
                    [int]$vlan.AccessVlanId -eq $ExpectedVlanId
                )
            }
        }

    $data = @($result.Data) |
        Select-Object -First 1

    if (-not $data.IsCompliant) {
        return New-HcnEnsureResult `
            -Check 'Ensure-ManagementVlan' `
            -Outcome 'Blocked' `
            -Summary (
                "CNEF management vNIC $($data.Adapter) VLAN state differs " +
                'from the protected untagged VLAN 0 profile. No automatic ' +
                'vNIC VLAN change is permitted.'
            ) `
            -AdditionalProperties @{
                RequiresApproval = $true
                ApprovalReason   = (
                    'Changing the Management OS vNIC VLAN can interrupt the ' +
                    'current remote session and requires an approved network change.'
                )
                RequiresReboot   = $false
                ReconnectTarget  = $result.Node
                Node             = $result.Node
                Adapter          = $data.Adapter
                OperationMode    = $data.OperationMode
                AccessVlanId     = $data.AccessVlanId
            }
    }

    return New-HcnEnsureResult `
        -Check 'Ensure-ManagementVlan' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            "CNEF management vNIC $($data.Adapter) is $($data.OperationMode) " +
            "with VLAN $($data.AccessVlanId), matching the protected profile."
        ) `
        -AdditionalProperties @{
            Node         = $result.Node
            ManagementIp = $result.ManagementIp
            Adapter      = $data.Adapter
            OperationMode = $data.OperationMode
            VlanId       = $data.AccessVlanId
        }
}

$node = Get-Value -Object $Context -Name 'Node'

if ($null -eq $node) {
    throw 'Ensure-ManagementVlan requires a node-scoped execution context.'
}

$config = Get-Value -Object $Context -Name 'Config'
$network = Get-Value -Object $config -Name 'network'
$management = Get-Value -Object $network -Name 'management'

$adapterName = [string](Get-Value -Object $management -Name 'primary_adapter')
$vlanId = [int](Get-Value -Object $management -Name 'vlan_id')
$nodeName = [string](Get-Value -Object $node -Name 'name')

if ([string]::IsNullOrWhiteSpace($adapterName)) {
    throw "Node $nodeName has no configured management adapter."
}

if ($vlanId -lt 1 -or $vlanId -gt 4094) {
    throw "Management VLAN ID '$vlanId' for node $nodeName is invalid."
}

$approvalKey = "$($Context.PhaseId).$($Context.StageId).$nodeName.$($Context.Operation)"

$inspectionResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param($AdapterName)

        $cluster = Get-Cluster -ErrorAction SilentlyContinue

        $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop

        $vlanProperty = @(
            Get-NetAdapterAdvancedProperty `
                -Name $AdapterName `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DisplayName -match 'VLAN' -or
                    $_.RegistryKeyword -match 'Vlan'
                }
        ) | Select-Object -First 1

        [pscustomobject]@{
            ExistingCluster = ($null -ne $cluster)
            AdapterName     = $adapter.Name
            AdapterStatus   = $adapter.Status
            VlanProperty    = $vlanProperty
        }
    } `
    -ArgumentList @($adapterName)

$inspection = @($inspectionResponse.Data) |
    Select-Object -First 1

if ($inspection.ExistingCluster) {
    return New-HcnEnsureResult `
        -Check 'Ensure-ManagementVlan' `
        -Outcome 'Blocked' `
        -Summary "Node $nodeName is already clustered. Management VLAN changes are blocked." `
        -AdditionalProperties @{
            Node            = $nodeName
            ExistingCluster = $true
        }
}

if ($null -eq $inspection.VlanProperty) {
    return New-HcnEnsureResult `
        -Check 'Ensure-ManagementVlan' `
        -Outcome 'Blocked' `
        -Summary (
            "Adapter $adapterName on node $nodeName does not expose a configurable VLAN advanced property. " +
            'Do not infer or force a driver-specific VLAN setting.'
        ) `
        -AdditionalProperties @{
            Node        = $nodeName
            AdapterName = $adapterName
        }
}

$currentVlan = [string]$inspection.VlanProperty.RegistryValue

if ($currentVlan -eq [string]$vlanId) {
    return New-HcnEnsureResult `
        -Check 'Ensure-ManagementVlan' `
        -Outcome 'AlreadyCompliant' `
        -Summary "Management adapter $adapterName on node $nodeName is already configured for VLAN $vlanId." `
        -AdditionalProperties @{
            Node        = $nodeName
            AdapterName = $adapterName
            VlanId      = $vlanId
        }
}

if (-not (Test-ApprovedOperation -Context $Context -ApprovalKey $approvalKey)) {
    return New-ApprovalRequiredResult `
        -Check 'Ensure-ManagementVlan' `
        -Summary "Management VLAN $vlanId is required on adapter $adapterName for node $nodeName." `
        -Reason (
            "Changing a management-adapter VLAN can interrupt remote management connectivity. " +
            "Approve only after confirming the management switch port is configured for VLAN $vlanId."
        ) `
        -ReconnectTarget $nodeName
}

$changeResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param(
            $AdapterName,
            $DesiredVlanId
        )

        $vlanProperty = @(
            Get-NetAdapterAdvancedProperty `
                -Name $AdapterName `
                -ErrorAction Stop |
                Where-Object {
                    $_.DisplayName -match 'VLAN' -or
                    $_.RegistryKeyword -match 'Vlan'
                }
        ) | Select-Object -First 1

        if ($null -eq $vlanProperty) {
            throw "No configurable VLAN advanced property was found on adapter $AdapterName."
        }

        Set-NetAdapterAdvancedProperty `
            -Name $AdapterName `
            -RegistryKeyword $vlanProperty.RegistryKeyword `
            -RegistryValue ([string]$DesiredVlanId) `
            -NoRestart `
            -ErrorAction Stop

        [pscustomobject]@{
            AdapterName = $AdapterName
            VlanId      = $DesiredVlanId
        }
        } `
        -ArgumentList @(
            $adapterName,
            $vlanId
        )

    $changeResult = @($changeResponse.Data) |
        Select-Object -First 1

return New-HcnEnsureResult `
    -Check 'Ensure-ManagementVlan' `
    -Outcome 'Changed' `
    -Changed $true `
    -Summary "Configured management adapter $adapterName on node $nodeName for VLAN $vlanId." `
    -AdditionalProperties @{
        Node        = $nodeName
        AdapterName = $changeResult.AdapterName
        VlanId      = $changeResult.VlanId
    }