#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$deployment = Get-ManagementPlaneValue `
    -Object $Context.Config `
    -Name 'deployment'

$singleServer = Get-ManagementPlaneValue `
    -Object $deployment `
    -Name 'single_server'

$isSingleServer = (
    (Get-ManagementPlaneValue `
        -Object $singleServer `
        -Name 'enabled') -eq $true
)

$hardware = Get-ManagementPlaneValue `
    -Object $Context.Config `
    -Name 'hardware'

$managementVnic = Get-ManagementPlaneValue `
    -Object $hardware `
    -Name 'management_vnic'

if ($isSingleServer -and $null -ne $managementVnic) {
    $managementVnicName = [string](
        Get-ManagementPlaneValue `
            -Object $managementVnic `
            -Name 'name'
    )

    $expectedVlanMode = [string](
        Get-ManagementPlaneValue `
            -Object $managementVnic `
            -Name 'vlan_mode'
    )

    $expectedVlanId = [int](
        Get-ManagementPlaneValue `
            -Object $managementVnic `
            -Name 'vlan_id'
    )

    $result = Invoke-ManagementPlaneCommand `
        -Context $Context `
        -OperationName 'Test-ManagementVlanState' `
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

            if (
                [string]$vlan.OperationMode -ne $ExpectedVlanMode -or
                [int]$vlan.AccessVlanId -ne $ExpectedVlanId
            ) {
                throw (
                    "Management vNIC $ManagementVnicName VLAN state is " +
                    "OperationMode=$($vlan.OperationMode), " +
                    "AccessVlanId=$($vlan.AccessVlanId); expected " +
                    "OperationMode=$ExpectedVlanMode, " +
                    "AccessVlanId=$ExpectedVlanId."
                )
            }

            [pscustomobject]@{
                ComputerName  = $env:COMPUTERNAME
                Adapter       = $ManagementVnicName
                OperationMode = [string]$vlan.OperationMode
                AccessVlanId  = [int]$vlan.AccessVlanId
            }
        }

    $data = @($result.Data) |
        Select-Object -First 1

    return [pscustomobject]@{
        Passed        = $true
        Check         = 'Test-ManagementVlanState'
        Node          = $result.Node
        ManagementIp  = $result.ManagementIp
        Adapter       = $data.Adapter
        OperationMode = $data.OperationMode
        VlanId        = $data.AccessVlanId
        Summary       = (
            "CNEF management vNIC $($data.Adapter) is " +
            "$($data.OperationMode) with VLAN $($data.AccessVlanId), " +
            'matching the protected profile.'
        )
        ValidatedAt   = [datetime]::UtcNow.ToString('o')
    }
}

$managementNetwork = Get-ManagementPlaneValue `
    -Object $Context.Config.network `
    -Name 'management'

$expectedVlanId = [int](
    Get-ManagementPlaneValue `
        -Object $managementNetwork `
        -Name 'vlan_id'
)

$primaryAdapter = [string](
    Get-ManagementPlaneValue `
        -Object $managementNetwork `
        -Name 'primary_adapter'
)

if ([string]::IsNullOrWhiteSpace($primaryAdapter)) {
    $primaryAdapter = [string]$Context.Node.management.adapter
}

if ($expectedVlanId -lt 1 -or $expectedVlanId -gt 4094) {
    throw "Invalid expected management VLAN: $expectedVlanId"
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-ManagementVlanState' `
    -ArgumentList @(
        $primaryAdapter,
        $expectedVlanId
    ) `
    -ScriptBlock {
        param(
            [string]$PrimaryAdapter,
            [int]$ExpectedVlanId
        )

        $vlan = Get-NetAdapterVlan `
            -Name $PrimaryAdapter `
            -ErrorAction Stop

        $actualVlanId = $vlan.AccessVlanId

        if ($null -eq $actualVlanId) {
            throw "No access VLAN was returned for adapter $PrimaryAdapter."
        }

        if ([int]$actualVlanId -ne $ExpectedVlanId) {
            throw (
                "Management adapter $PrimaryAdapter VLAN is $actualVlanId; " +
                "expected $ExpectedVlanId."
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Adapter      = $PrimaryAdapter
            AccessVlanId = [int]$actualVlanId
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-ManagementVlanState'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Adapter      = $data.Adapter
    VlanId       = $data.AccessVlanId
    Summary      = (
        "Management adapter $($data.Adapter) VLAN " +
        "$($data.AccessVlanId) matches the site configuration."
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}