#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

function Get-Value {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-ManagementPlaneValue `
        -Object $Object `
        -Name $Name
}

function ConvertTo-IPv4Integer {
    param(
        [Parameter(Mandatory)]
        [string]$Address
    )

    $parsedAddress = $null

    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsedAddress)) {
        throw "Invalid IPv4 address: $Address"
    }

    if (
        $parsedAddress.AddressFamily -ne
        [System.Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw "Only IPv4 addresses are supported: $Address"
    }

    $bytes = $parsedAddress.GetAddressBytes()

    return (
        ([uint64]$bytes[0] -shl 24) -bor
        ([uint64]$bytes[1] -shl 16) -bor
        ([uint64]$bytes[2] -shl 8) -bor
        [uint64]$bytes[3]
    )
}

function Get-CidrInformation {
    param(
        [Parameter(Mandatory)]
        [string]$Cidr
    )

    if (
        $Cidr -notmatch
        '^(?<Address>\d{1,3}(\.\d{1,3}){3})/(?<Prefix>\d{1,2})$'
    ) {
        throw "Invalid CIDR value: $Cidr"
    }

    $networkAddress = $Matches.Address
    $prefix = [int]$Matches.Prefix

    if ($prefix -lt 1 -or $prefix -gt 30) {
        throw "Invalid CIDR prefix: $Cidr"
    }

    $addressValue = ConvertTo-IPv4Integer -Address $networkAddress
    $allBits = [uint64]4294967295
    $hostBits = 32 - $prefix
    $hostMask = [uint64]([math]::Pow(2, $hostBits) - 1)
    $mask = $allBits -bxor $hostMask
    $networkValue = $addressValue -band $mask
    $broadcastValue = $networkValue -bor $hostMask

    if ($addressValue -ne $networkValue) {
        throw "CIDR must use the network address: $Cidr"
    }

    return [pscustomobject]@{
        Cidr      = $Cidr
        Prefix    = $prefix
        Network   = $networkValue
        Broadcast = $broadcastValue
    }
}

function Test-AddressInCidr {
    param(
        [Parameter(Mandatory)]
        [string]$Address,

        [Parameter(Mandatory)]
        [object]$CidrInformation
    )

    $addressValue = ConvertTo-IPv4Integer -Address $Address

    return (
        $addressValue -gt $CidrInformation.Network -and
        $addressValue -lt $CidrInformation.Broadcast
    )
}

$config = $Context.Config
$network = Get-Value -Object $config -Name 'network'
$storage = Get-Value -Object $network -Name 'storage'
$storageIntent = [string](Get-Value -Object $storage -Name 'intent')

$storageNetworks = @(
    Get-Value `
        -Object $storage `
        -Name 'networks'
)

if ($storageIntent -eq 'None') {
    if ($storageNetworks.Count -gt 0) {
        throw (
            'network.storage.networks must be empty when storage intent is None.'
        )
    }

    foreach ($node in @($config.nodes)) {
        $nodeStorage = @(
            Get-Value `
                -Object $node `
                -Name 'storage'
        )

        if ($nodeStorage.Count -gt 0) {
            throw (
                "Node $($node.name) defines storage adapters while storage intent is None."
            )
        }
    }

    return [pscustomobject]@{
        Passed          = $true
        Check           = 'Test-StorageNetworkConfiguration'
        StorageNetworks = @()
        StorageIpCount  = 0
        Summary         = (
            'Storage network configuration is not applicable to the protected ' +
            'single-server storage-intent-none profile.'
        )
        ValidatedAt     = [datetime]::UtcNow.ToString('o')
    }
}

$errors = [System.Collections.Generic.List[string]]::new()

if ($storageNetworks.Count -lt 1) {
    throw 'network.storage.networks must contain at least one storage network.'
}

$storageNetworkNames = [System.Collections.Generic.List[string]]::new()
$storageNetworkVlans = [System.Collections.Generic.List[int]]::new()
$storageNetworkMap = @{}

foreach ($storageNetwork in $storageNetworks) {
    $networkName = [string]$storageNetwork.name
    $adapterName = [string]$storageNetwork.adapter
    $subnet = [string]$storageNetwork.subnet
    $prefix = [int]$storageNetwork.prefix
    $vlanId = [int]$storageNetwork.vlan_id

    if ([string]::IsNullOrWhiteSpace($networkName)) {
        [void]$errors.Add('Each storage network requires name.')
        continue
    }

    if ($storageNetworkNames -contains $networkName) {
        [void]$errors.Add("Duplicate storage network name: $networkName")
    }

    [void]$storageNetworkNames.Add($networkName)

    if ([string]::IsNullOrWhiteSpace($adapterName)) {
        [void]$errors.Add("Storage network $networkName requires adapter.")
    }

    if ($storageNetworkVlans -contains $vlanId) {
        [void]$errors.Add(
            "Duplicate storage VLAN $vlanId assigned to storage network $networkName."
        )
    }

    [void]$storageNetworkVlans.Add($vlanId)

    if ($vlanId -lt 1 -or $vlanId -gt 4094) {
        [void]$errors.Add(
            "Storage network $networkName has invalid VLAN: $vlanId"
        )
    }

    try {
        $cidr = Get-CidrInformation -Cidr $subnet

        if ($cidr.Prefix -ne $prefix) {
            [void]$errors.Add(
                "Storage network $networkName prefix /$prefix does not match $subnet."
            )
        }

        $storageNetworkMap[$networkName] = [pscustomobject]@{
            Name    = $networkName
            Adapter = $adapterName
            Cidr    = $cidr
            Prefix  = $prefix
            VlanId  = $vlanId
        }
    }
    catch {
        [void]$errors.Add(
            "Storage network $networkName has invalid subnet $subnet. " +
            $_.Exception.Message
        )
    }
}

$storageAddresses = [System.Collections.Generic.List[string]]::new()

foreach ($node in @($config.nodes)) {
    $nodeName = [string]$node.name
    $nodeStorageAdapters = @($node.storage)

    if ($nodeStorageAdapters.Count -lt 1) {
        [void]$errors.Add(
            "Node $nodeName does not define any storage adapters."
        )
        continue
    }

    foreach ($nodeStorageAdapter in $nodeStorageAdapters) {
        $networkName = [string]$nodeStorageAdapter.network
        $adapterName = [string]$nodeStorageAdapter.adapter
        $ipAddress = [string](Get-Value -Object $nodeStorageAdapter -Name 'ip')

        if ([string]::IsNullOrWhiteSpace($ipAddress)) {
            $ipAddress = [string](
                Get-Value `
                    -Object $nodeStorageAdapter `
                    -Name 'ip_address'
            )
        }

        $prefix = [int]$nodeStorageAdapter.prefix
        $vlanId = [int]$nodeStorageAdapter.vlan_id

        if (-not $storageNetworkMap.Contains($networkName)) {
            [void]$errors.Add(
                "Node $nodeName adapter $adapterName references unknown storage network $networkName."
            )
            continue
        }

        $storageNetwork = $storageNetworkMap[$networkName]

        if ($adapterName -ne $storageNetwork.Adapter) {
            [void]$errors.Add(
                "Node $nodeName storage adapter $adapterName does not match " +
                "storage network $networkName adapter $($storageNetwork.Adapter)."
            )
        }

        if ($prefix -ne $storageNetwork.Prefix) {
            [void]$errors.Add(
                "Node $nodeName storage adapter $adapterName prefix /$prefix " +
                "does not match storage network $networkName prefix /$($storageNetwork.Prefix)."
            )
        }

        if ($vlanId -ne $storageNetwork.VlanId) {
            [void]$errors.Add(
                "Node $nodeName storage adapter $adapterName VLAN $vlanId " +
                "does not match storage network $networkName VLAN $($storageNetwork.VlanId)."
            )
        }

        try {
            if (
                -not (
                    Test-AddressInCidr `
                        -Address $ipAddress `
                        -CidrInformation $storageNetwork.Cidr
                )
            ) {
                [void]$errors.Add(
                    "Node $nodeName storage adapter $adapterName IP $ipAddress " +
                    "is outside $($storageNetwork.Cidr.Cidr)."
                )
            }
        }
        catch {
            [void]$errors.Add(
                "Node $nodeName storage adapter $adapterName has invalid IP $ipAddress."
            )
        }

        if ($storageAddresses -contains $ipAddress) {
            [void]$errors.Add(
                "Duplicate storage IP address configured: $ipAddress"
            )
        }

        [void]$storageAddresses.Add($ipAddress)
    }
}

if ($errors.Count -gt 0) {
    throw (
        "Storage network configuration validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

return [pscustomobject]@{
    Passed          = $true
    Check           = 'Test-StorageNetworkConfiguration'
    StorageNetworks = @(
        $storageNetworkMap.Values |
            Sort-Object Name |
            ForEach-Object {
                "$($_.Name): $($_.Cidr.Cidr), VLAN $($_.VlanId), Adapter $($_.Adapter)"
            }
    )
    StorageIpCount  = $storageAddresses.Count
    Summary         = (
        "$($storageNetworkMap.Count) storage network(s) and " +
        "$($storageAddresses.Count) storage IP assignment(s) validated."
    )
    ValidatedAt     = [datetime]::UtcNow.ToString('o')
}