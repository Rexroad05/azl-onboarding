#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$networkConfiguration = Get-ManagementPlaneValue `
    -Object $Context.Config `
    -Name 'network'

$storageConfiguration = Get-ManagementPlaneValue `
    -Object $networkConfiguration `
    -Name 'storage'

$storageIntent = [string](
    Get-ManagementPlaneValue `
        -Object $storageConfiguration `
        -Name 'intent'
)

if ($storageIntent -eq 'None') {
    return [pscustomobject]@{
        Passed       = $true
        Check        = 'Test-StorageNetworkReadiness'
        Node         = $Context.Node.name
        ManagementIp = $Context.Node.management.ip
        Adapters     = @()
        Summary      = (
            'Storage network readiness is not applicable to the protected ' +
            'single-server storage-intent-none profile.'
        )
        ValidatedAt  = [datetime]::UtcNow.ToString('o')
    }
}

$requireRdma = Get-ManagementPlaneValue `
    -Object $storageConfiguration `
    -Name 'require_rdma'

$requireSriov = Get-ManagementPlaneValue `
    -Object $storageConfiguration `
    -Name 'require_sriov'

$nodeStorageAdapters = @($Context.Node.storage)

if ($nodeStorageAdapters.Count -lt 1) {
    throw (
        "Node $($Context.Node.name) does not define any storage adapters."
    )
}

$siteStorageNetworks = @(
    $Context.Config.network.storage.networks
)

if ($siteStorageNetworks.Count -lt 1) {
    throw 'network.storage.networks must contain at least one storage network.'
}

foreach ($nodeStorageAdapter in $nodeStorageAdapters) {
    $networkName = [string]$nodeStorageAdapter.network

    $siteStorageNetwork = @(
        $siteStorageNetworks |
            Where-Object {
                $_.name -eq $networkName
            }
    )

    if ($siteStorageNetwork.Count -ne 1) {
        throw (
            "Node $($Context.Node.name) storage adapter " +
            "$($nodeStorageAdapter.adapter) references unknown storage network " +
            "$networkName."
        )
    }

    $siteStorageNetwork = $siteStorageNetwork[0]

    if (
        [int]$nodeStorageAdapter.vlan_id -ne
        [int]$siteStorageNetwork.vlan_id
    ) {
        throw (
            "Node $($Context.Node.name) storage adapter " +
            "$($nodeStorageAdapter.adapter) VLAN $($nodeStorageAdapter.vlan_id) " +
            "does not match storage network $networkName VLAN " +
            "$($siteStorageNetwork.vlan_id)."
        )
    }

    if (
        [int]$nodeStorageAdapter.prefix -ne
        [int]$siteStorageNetwork.prefix
    ) {
        throw (
            "Node $($Context.Node.name) storage adapter " +
            "$($nodeStorageAdapter.adapter) prefix $($nodeStorageAdapter.prefix) " +
            "does not match storage network $networkName prefix " +
            "$($siteStorageNetwork.prefix)."
        )
    }
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-StorageNetworkReadiness' `
    -ArgumentList @(
        $nodeStorageAdapters,
        [bool]$requireRdma,
        [bool]$requireSriov
    ) `
    -ScriptBlock {
        param(
            [object[]]$ExpectedStorageAdapters,
            [bool]$RequireRdma,
            [bool]$RequireSriov
        )

        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($expectedAdapter in $ExpectedStorageAdapters) {
            $adapterName = [string]$expectedAdapter.adapter
            $expectedIp = [string]$expectedAdapter.ip
            $expectedPrefix = [int]$expectedAdapter.prefix

            $adapter = Get-NetAdapter `
                -Name $adapterName `
                -ErrorAction Stop

            if ($adapter.Status -ne 'Up') {
                throw (
                    "Storage adapter $adapterName is not Up. " +
                    "Current status: $($adapter.Status)"
                )
            }

            $ipAddress = @(
                Get-NetIPAddress `
                    -InterfaceIndex $adapter.ifIndex `
                    -AddressFamily IPv4 `
                    -ErrorAction Stop |
                    Where-Object {
                        $_.IPAddress -eq $expectedIp
                    }
            )

            if ($ipAddress.Count -ne 1) {
                throw (
                    "Storage adapter $adapterName does not have expected IP " +
                    "$expectedIp."
                )
            }

            if ($ipAddress[0].PrefixLength -ne $expectedPrefix) {
                throw (
                    "Storage adapter $adapterName has prefix " +
                    "$($ipAddress[0].PrefixLength), expected $expectedPrefix."
                )
            }

            $rdmaState = $null
            $sriovState = $null

            if ($RequireRdma) {
                $rdmaState = Get-NetAdapterRdma `
                    -Name $adapterName `
                    -ErrorAction Stop

                if (
                    -not $rdmaState.Enabled -or
                    $rdmaState.Operational -notin @('True', 'Ready', 'Operational')
                ) {
                    throw (
                        "Storage adapter $adapterName RDMA is not ready. " +
                        "Enabled: $($rdmaState.Enabled); " +
                        "Operational: $($rdmaState.Operational)"
                    )
                }
            }

            if ($RequireSriov) {
                $sriovState = Get-NetAdapterSriov `
                    -Name $adapterName `
                    -ErrorAction Stop

                if (
                    -not $sriovState.Enabled -or
                    $sriovState.SriovSupport -ne 'Supported'
                ) {
                    throw (
                        "Storage adapter $adapterName SR-IOV is not ready. " +
                        "Enabled: $($sriovState.Enabled); " +
                        "Support: $($sriovState.SriovSupport)"
                    )
                }
            }

            $results.Add([pscustomobject]@{
                Adapter          = $adapterName
                Status           = $adapter.Status
                LinkSpeed        = $adapter.LinkSpeed
                IPAddress        = $ipAddress[0].IPAddress
                PrefixLength     = $ipAddress[0].PrefixLength
                RdmaEnabled      = if ($null -ne $rdmaState) {
                    $rdmaState.Enabled
                }
                else {
                    $null
                }
                RdmaOperational  = if ($null -ne $rdmaState) {
                    $rdmaState.Operational
                }
                else {
                    $null
                }
                SriovEnabled     = if ($null -ne $sriovState) {
                    $sriovState.Enabled
                }
                else {
                    $null
                }
                SriovSupport     = if ($null -ne $sriovState) {
                    $sriovState.SriovSupport
                }
                else {
                    $null
                }
            })
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Adapters     = $results.ToArray()
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-StorageNetworkReadiness'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Adapters     = $data.Adapters
    Summary      = (
        "Storage network readiness validated for " +
        "$($data.Adapters.Count) adapter(s)."
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}