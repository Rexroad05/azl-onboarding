#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigValue {
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
        if (@($Object.Keys) -contains $Name) {
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
        throw "CIDR prefix must be between /1 and /30: $Cidr"
    }

    $addressValue = ConvertTo-IPv4Integer -Address $networkAddress
    $allBits = [uint64]4294967295
    $hostBitCount = 32 - $prefix
    $hostMask = [uint64]([math]::Pow(2, $hostBitCount) - 1)
    $mask = $allBits -bxor $hostMask
    $networkValue = $addressValue -band $mask
    $broadcastValue = $networkValue -bor $hostMask

    if ($addressValue -ne $networkValue) {
        throw "CIDR must specify the network address, not a host address: $Cidr"
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
        $addressValue -ge $CidrInformation.Network -and
        $addressValue -le $CidrInformation.Broadcast
    )
}

function Test-UsableHostAddress {
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

if ($null -eq $config) {
    throw 'Factory context does not contain Config.'
}

$errors = [System.Collections.Generic.List[string]]::new()

$deployment = Get-ConfigValue `
    -Object $config `
    -Name 'deployment'

$singleServer = Get-ConfigValue `
    -Object $deployment `
    -Name 'single_server'

$isSingleServer = (
    (Get-ConfigValue `
        -Object $singleServer `
        -Name 'enabled') -eq $true
)

$hardware = Get-ConfigValue `
    -Object $config `
    -Name 'hardware'

$managementVnic = Get-ConfigValue `
    -Object $hardware `
    -Name 'management_vnic'

$protectedVlanMode = [string](
    Get-ConfigValue `
        -Object $managementVnic `
        -Name 'vlan_mode'
)

$protectedVlanId = Get-ConfigValue `
    -Object $managementVnic `
    -Name 'vlan_id'

$allowsUntaggedManagementVlan = (
    $isSingleServer -and
    $protectedVlanMode -eq 'Untagged' -and
    $protectedVlanId -eq 0
)

$network = Get-ConfigValue `
    -Object $config `
    -Name 'network'

$management = Get-ConfigValue `
    -Object $network `
    -Name 'management'

if ($null -eq $management) {
    throw 'network.management configuration is required.'
}

$managementCidrText = [string](
    Get-ConfigValue `
        -Object $management `
        -Name 'subnet'
)

$managementPrefix = [int](
    Get-ConfigValue `
        -Object $management `
        -Name 'prefix'
)

$managementGateway = [string](
    Get-ConfigValue `
        -Object $management `
        -Name 'gateway'
)

$managementVlan = Get-ConfigValue `
    -Object $management `
    -Name 'vlan_id'

if ([string]::IsNullOrWhiteSpace($managementCidrText)) {
    [void]$errors.Add('network.management.subnet is required.')
}

if ($managementPrefix -lt 1 -or $managementPrefix -gt 30) {
    [void]$errors.Add(
        "network.management.prefix is invalid: $managementPrefix"
    )
}

if ([string]::IsNullOrWhiteSpace($managementGateway)) {
    [void]$errors.Add('network.management.gateway is required.')
}

if ($null -eq $managementVlan) {
    [void]$errors.Add('network.management.vlan_id is required.')
}
elseif ([int]$managementVlan -eq 0) {
    if (-not $allowsUntaggedManagementVlan) {
        [void]$errors.Add(
            'network.management.vlan_id 0 is permitted only for a protected ' +
            'single-server profile with an untagged management vNIC.'
        )
    }
}
elseif ([int]$managementVlan -lt 1 -or [int]$managementVlan -gt 4094) {
    [void]$errors.Add(
        "network.management.vlan_id is outside valid VLAN range: $managementVlan"
    )
}

if ($errors.Count -gt 0) {
    throw (
        "Management network configuration validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

try {
    $managementCidr = Get-CidrInformation -Cidr $managementCidrText
}
catch {
    throw "Unable to validate management CIDR. $($_.Exception.Message)"
}

if ($managementPrefix -ne $managementCidr.Prefix) {
    [void]$errors.Add(
        "network.management.prefix /$managementPrefix does not match " +
        "CIDR prefix /$($managementCidr.Prefix)."
    )
}

try {
    if (
        -not (
            Test-AddressInCidr `
                -Address $managementGateway `
                -CidrInformation $managementCidr
        )
    ) {
        [void]$errors.Add(
            "Management gateway $managementGateway is outside " +
            "$($managementCidr.Cidr)."
        )
    }
    elseif (
        -not (
            Test-UsableHostAddress `
                -Address $managementGateway `
                -CidrInformation $managementCidr
        )
    ) {
        [void]$errors.Add(
            "Management gateway $managementGateway is not a usable host address."
        )
    }
}
catch {
    [void]$errors.Add(
        "Management gateway is invalid: $managementGateway"
    )
}

$nodes = @(
    Get-ConfigValue `
        -Object $config `
        -Name 'nodes'
)

if ($nodes.Count -lt 1) {
    [void]$errors.Add('At least one node is required.')
}

$managementAddresses = [System.Collections.Generic.List[string]]::new()

foreach ($node in $nodes) {
    $nodeName = [string](
        Get-ConfigValue `
            -Object $node `
            -Name 'name'
    )

    $nodeManagement = Get-ConfigValue `
        -Object $node `
        -Name 'management'

    if ($null -eq $nodeManagement) {
        [void]$errors.Add(
            "Node $nodeName is missing management configuration."
        )
        continue
    }

    $managementIp = [string](
        Get-ConfigValue `
            -Object $nodeManagement `
            -Name 'ip'
    )

    $nodePrefix = [int](
        Get-ConfigValue `
            -Object $nodeManagement `
            -Name 'prefix'
    )

    $nodeGateway = [string](
        Get-ConfigValue `
            -Object $nodeManagement `
            -Name 'gateway'
    )

    $nodeVlan = Get-ConfigValue `
        -Object $nodeManagement `
        -Name 'vlan_id'

    if ([string]::IsNullOrWhiteSpace($managementIp)) {
        [void]$errors.Add(
            "Node $nodeName is missing management.ip."
        )
        continue
    }

    [void]$managementAddresses.Add($managementIp)

    try {
        if (
            -not (
                Test-AddressInCidr `
                    -Address $managementIp `
                    -CidrInformation $managementCidr
            )
        ) {
            [void]$errors.Add(
                "Node $nodeName management IP $managementIp is outside " +
                "$($managementCidr.Cidr)."
            )
        }
        elseif (
            -not (
                Test-UsableHostAddress `
                    -Address $managementIp `
                    -CidrInformation $managementCidr
            )
        ) {
            [void]$errors.Add(
                "Node $nodeName management IP $managementIp is not a usable host address."
            )
        }
    }
    catch {
        [void]$errors.Add(
            "Node $nodeName has an invalid management IP: $managementIp"
        )
    }

    if ($managementIp -eq $managementGateway) {
        [void]$errors.Add(
            "Node $nodeName management IP cannot equal the management gateway."
        )
    }

    if ($nodePrefix -ne $managementCidr.Prefix) {
        [void]$errors.Add(
            "Node $nodeName management prefix /$nodePrefix does not match " +
            "/$($managementCidr.Prefix)."
        )
    }

    if ($nodeGateway -ne $managementGateway) {
        [void]$errors.Add(
            "Node $nodeName gateway $nodeGateway does not match " +
            "configured gateway $managementGateway."
        )
    }

    if ($null -eq $nodeVlan) {
        [void]$errors.Add(
            "Node $nodeName management VLAN is required."
        )
    }
    elseif ([int]$nodeVlan -ne [int]$managementVlan) {
        [void]$errors.Add(
            "Node $nodeName VLAN $nodeVlan does not match " +
            "configured VLAN $managementVlan."
        )
    }
}

$duplicateManagementAddresses = @(
    $managementAddresses |
        Group-Object |
        Where-Object {
            $_.Count -gt 1
        } |
        Select-Object -ExpandProperty Name
)

foreach ($address in $duplicateManagementAddresses) {
    [void]$errors.Add(
        "Duplicate management IP address: $address"
    )
}

if ($errors.Count -gt 0) {
    throw (
        "IP allocation validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

$managementVlanMode = if (
    [int]$managementVlan -eq 0 -and
    $allowsUntaggedManagementVlan
) {
    'Untagged'
}
else {
    'Tagged'
}

return [pscustomobject]@{
    Passed             = $true
    Check              = 'Test-IPAddressAllocation'
    ManagementSubnet   = $managementCidr.Cidr
    ManagementGateway  = $managementGateway
    ManagementVlan     = [int]$managementVlan
    ManagementVlanMode = $managementVlanMode
    NodeCount          = $nodes.Count
    NodeManagementIPs  = $managementAddresses.ToArray()
    ValidatedAt        = [datetime]::UtcNow.ToString('o')
}