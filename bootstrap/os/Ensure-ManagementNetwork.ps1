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

function New-ApprovalRequiredResult {
    param(
        [string]$Summary,
        [string]$Reason,
        [string]$ReconnectTarget
    )

    return New-HcnEnsureResult `
        -Check 'Ensure-ManagementNetwork' `
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
    $node = Get-Value -Object $Context -Name 'Node'

    if ($null -eq $node) {
        throw 'Ensure-ManagementNetwork requires a node-scoped execution context.'
    }

    $nodeManagement = Get-Value `
        -Object $node `
        -Name 'management'

    $managementVnicName = [string](
        Get-Value `
            -Object $managementVnic `
            -Name 'name'
    )

    $expectedIp = [string](
        Get-Value `
            -Object $nodeManagement `
            -Name 'ip'
    )

    $expectedPrefix = [int](
        Get-Value `
            -Object $nodeManagement `
            -Name 'prefix'
    )

    $expectedGateway = [string](
        Get-Value `
            -Object $nodeManagement `
            -Name 'gateway'
    )

    $result = Invoke-ManagementPlaneCommand `
        -Context $Context `
        -OperationName 'Ensure-ManagementNetwork' `
        -ArgumentList @(
            $managementVnicName,
            $expectedIp,
            $expectedPrefix,
            $expectedGateway
        ) `
        -ScriptBlock {
            param(
                [string]$ManagementVnicName,
                [string]$ExpectedIp,
                [int]$ExpectedPrefix,
                [string]$ExpectedGateway
            )

            $adapter = Get-NetAdapter `
                -Name $ManagementVnicName `
                -ErrorAction Stop

            $addresses = @(
                Get-NetIPAddress `
                    -InterfaceIndex $adapter.ifIndex `
                    -AddressFamily IPv4 `
                    -ErrorAction SilentlyContinue
            )

            $routes = @(
                Get-NetRoute `
                    -InterfaceIndex $adapter.ifIndex `
                    -AddressFamily IPv4 `
                    -DestinationPrefix '0.0.0.0/0' `
                    -ErrorAction SilentlyContinue
            )

            $addressPresent = @(
                $addresses |
                    Where-Object {
                        $_.IPAddress -eq $ExpectedIp -and
                        $_.PrefixLength -eq $ExpectedPrefix
                    }
            ).Count -gt 0

            $gatewayPresent = @(
                $routes |
                    Where-Object {
                        $_.NextHop -eq $ExpectedGateway
                    }
            ).Count -gt 0

            [pscustomobject]@{
                ComputerName   = $env:COMPUTERNAME
                Adapter        = $adapter.Name
                InterfaceIndex = $adapter.ifIndex
                IPAddress      = $ExpectedIp
                Prefix         = $ExpectedPrefix
                Gateway        = $ExpectedGateway
                IsCompliant    = (
                    $addressPresent -and
                    $gatewayPresent
                )
            }
        }

    $data = @($result.Data) |
        Select-Object -First 1

    if (-not $data.IsCompliant) {
        return New-HcnEnsureResult `
            -Check 'Ensure-ManagementNetwork' `
            -Outcome 'Blocked' `
            -Summary (
                "CNEF management vNIC $($data.Adapter) does not match the " +
                'protected management IP and gateway configuration. No ' +
                'automatic vNIC IP change is permitted.'
            ) `
            -AdditionalProperties @{
                RequiresApproval = $true
                ApprovalReason   = (
                    'Changing the management-vNIC IP address or gateway can ' +
                    'interrupt connectivity and requires an approved network change.'
                )
                RequiresReboot   = $false
                ReconnectTarget  = $data.IPAddress
                Node             = $result.Node
                Adapter          = $data.Adapter
                IPAddress        = $data.IPAddress
                Prefix           = $data.Prefix
                Gateway          = $data.Gateway
            }
    }

    return New-HcnEnsureResult `
        -Check 'Ensure-ManagementNetwork' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            "CNEF management vNIC $($data.Adapter) already has " +
            "$($data.IPAddress)/$($data.Prefix) and gateway $($data.Gateway)."
        ) `
        -AdditionalProperties @{
            Node         = $result.Node
            ManagementIp = $result.ManagementIp
            Adapter      = $data.Adapter
            IPAddress    = $data.IPAddress
            Prefix       = $data.Prefix
            Gateway      = $data.Gateway
        }
}

$node = Get-Value -Object $Context -Name 'Node'

if ($null -eq $node) {
    throw 'Ensure-ManagementNetwork requires a node-scoped execution context.'
}

$config = Get-Value -Object $Context -Name 'Config'
$network = Get-Value -Object $config -Name 'network'
$management = Get-Value -Object $network -Name 'management'
$nodeManagement = Get-Value -Object $node -Name 'management'

$nodeName = [string](Get-Value -Object $node -Name 'name')
$adapterName = [string](Get-Value -Object $management -Name 'primary_adapter')
$ipAddress = [string](Get-Value -Object $nodeManagement -Name 'ip_address')
$prefixLength = [int](Get-Value -Object $management -Name 'prefix')
$gateway = [string](Get-Value -Object $management -Name 'gateway')

if (
    [string]::IsNullOrWhiteSpace($adapterName) -or
    [string]::IsNullOrWhiteSpace($ipAddress) -or
    [string]::IsNullOrWhiteSpace($gateway)
) {
    throw "Management network configuration is incomplete for node $nodeName."
}

$approvalKey = "$($Context.PhaseId).$($Context.StageId).$nodeName.$($Context.Operation)"

$inspectionResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param($AdapterName)

        $cluster = Get-Cluster -ErrorAction SilentlyContinue
        $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
        $interface = Get-NetIPInterface `
            -InterfaceIndex $adapter.ifIndex `
            -AddressFamily IPv4 `
            -ErrorAction Stop

        $addresses = @(
            Get-NetIPAddress `
                -InterfaceIndex $adapter.ifIndex `
                -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue
        )

        $routes = @(
            Get-NetRoute `
                -InterfaceIndex $adapter.ifIndex `
                -AddressFamily IPv4 `
                -DestinationPrefix '0.0.0.0/0' `
                -ErrorAction SilentlyContinue
        )

        [pscustomobject]@{
            ExistingCluster = ($null -ne $cluster)
            AdapterName     = $adapter.Name
            InterfaceIndex  = $adapter.ifIndex
            Addresses       = $addresses
            DefaultRoutes   = $routes
        }
        } `
        -ArgumentList @($adapterName)

    $inspection = @($inspectionResponse.Data) |
        Select-Object -First 1

if ($inspection.ExistingCluster) {
    return New-HcnEnsureResult `
        -Check 'Ensure-ManagementNetwork' `
        -Outcome 'Blocked' `
        -Summary "Node $nodeName is already clustered. Management IP configuration changes are blocked." `
        -AdditionalProperties @{ Node = $nodeName; ExistingCluster = $true }
}

$desiredAddressPresent = @(
    $inspection.Addresses |
        Where-Object {
            $_.IPAddress -eq $ipAddress -and
            $_.PrefixLength -eq $prefixLength
        }
).Count -gt 0

$desiredGatewayPresent = @(
    $inspection.DefaultRoutes |
        Where-Object { $_.NextHop -eq $gateway }
).Count -gt 0

if ($desiredAddressPresent -and $desiredGatewayPresent) {
    return New-HcnEnsureResult `
        -Check 'Ensure-ManagementNetwork' `
        -Outcome 'AlreadyCompliant' `
        -Summary "Management IP $ipAddress/$prefixLength and gateway $gateway are configured on $adapterName for node $nodeName." `
        -AdditionalProperties @{
            Node        = $nodeName
            AdapterName = $adapterName
            IPAddress   = $ipAddress
            Prefix      = $prefixLength
            Gateway     = $gateway
        }
}

if (-not (Test-ApprovedOperation -Context $Context -ApprovalKey $approvalKey)) {
    return New-ApprovalRequiredResult `
        -Summary "Management IP configuration on node $nodeName requires correction on adapter $adapterName." `
        -Reason (
            "Adding or changing the management IP address or default gateway can interrupt the current remote session. " +
            "Approve only after confirming the desired IP $ipAddress/$prefixLength and gateway $gateway."
        ) `
        -ReconnectTarget $ipAddress
}

$changeResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param(
            $AdapterName,
            $IPAddress,
            $PrefixLength,
            $Gateway
        )

        $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
        $interfaceIndex = $adapter.ifIndex

        $addressExists = @(
            Get-NetIPAddress `
                -InterfaceIndex $interfaceIndex `
                -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.IPAddress -eq $IPAddress -and
                    $_.PrefixLength -eq $PrefixLength
                }
        ).Count -gt 0

        if (-not $addressExists) {
            New-NetIPAddress `
                -InterfaceIndex $interfaceIndex `
                -IPAddress $IPAddress `
                -PrefixLength $PrefixLength `
                -DefaultGateway $Gateway `
                -AddressFamily IPv4 `
                -ErrorAction Stop | Out-Null
        }

        $gatewayExists = @(
            Get-NetRoute `
                -InterfaceIndex $interfaceIndex `
                -AddressFamily IPv4 `
                -DestinationPrefix '0.0.0.0/0' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.NextHop -eq $Gateway }
        ).Count -gt 0

        if (-not $gatewayExists) {
            New-NetRoute `
                -InterfaceIndex $interfaceIndex `
                -AddressFamily IPv4 `
                -DestinationPrefix '0.0.0.0/0' `
                -NextHop $Gateway `
                -RouteMetric 10 `
                -ErrorAction Stop | Out-Null
        }

        [pscustomobject]@{
            AdapterName = $AdapterName
            IPAddress   = $IPAddress
            Prefix      = $PrefixLength
            Gateway     = $Gateway
        }
        } `
        -ArgumentList @(
            $adapterName,
            $ipAddress,
            $prefixLength,
            $gateway
        )

    $changeResult = @($changeResponse.Data) |
        Select-Object -First 1

return New-HcnEnsureResult `
    -Check 'Ensure-ManagementNetwork' `
    -Outcome 'Changed' `
    -Changed $true `
    -Summary "Ensured management IP $ipAddress/$prefixLength and gateway $gateway on $adapterName for node $nodeName." `
    -AdditionalProperties @{
        Node        = $nodeName
        AdapterName = $changeResult.AdapterName
        IPAddress   = $changeResult.IPAddress
        Prefix      = $changeResult.Prefix
        Gateway     = $changeResult.Gateway
        ReconnectTarget = $ipAddress
    }