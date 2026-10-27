#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$expectedIp = [string]$Context.Node.management.ip
$dnsConfiguration = Get-ManagementPlaneValue `
    -Object $Context.Config `
    -Name 'dns'

$allowedDnsServers = @(
    Get-ManagementPlaneValue `
        -Object $dnsConfiguration `
        -Name 'allowed_servers'
)

# Temporary backward compatibility while site files transition
# from dns.servers to dns.allowed_servers.
if ($allowedDnsServers.Count -lt 1) {
    $allowedDnsServers = @(
        Get-ManagementPlaneValue `
            -Object $dnsConfiguration `
            -Name 'servers'
    )
}

if ($allowedDnsServers.Count -lt 1) {
    throw (
        'DNS configuration is missing. Define dns.allowed_servers ' +
        'in the site variables YAML.'
    )
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-DNS' `
    -ArgumentList @($expectedIp, $allowedDnsServers) `
    -ScriptBlock {
        param(
            [string]$ExpectedIp,

            [string[]]$AllowedDnsServers
        )

        $ipAddress = @(
            Get-NetIPAddress `
                -AddressFamily IPv4 `
                -ErrorAction Stop |
                Where-Object {
                    $_.IPAddress -eq $ExpectedIp
                }
        )

        if ($ipAddress.Count -ne 1) {
            throw (
                "Expected management IP $ExpectedIp was not found on the remote node."
            )
        }

        $interfaceIndex = $ipAddress[0].InterfaceIndex

        $dnsConfiguration = Get-DnsClientServerAddress `
            -InterfaceIndex $interfaceIndex `
            -AddressFamily IPv4 `
            -ErrorAction Stop

        $configuredServers = @($dnsConfiguration.ServerAddresses)

        if ($configuredServers.Count -lt 1) {
            throw (
                "DNS validation failed for management interface index $interfaceIndex.`n" +
                "Allowed DNS servers:`n - " +
                ($AllowedDnsServers -join "`n - ") +
                "`nCurrent configured DNS servers: none`n" +
                "Reason: No IPv4 DNS servers are configured on the management interface."
            )
        }

        $approvedConfiguredServers = @(
            $configuredServers |
                Where-Object {
                    $AllowedDnsServers -contains $_
                }
        )

        $unexpectedDnsServers = @(
            $configuredServers |
                Where-Object {
                    $AllowedDnsServers -notcontains $_
                }
        )

        if ($approvedConfiguredServers.Count -lt 1) {
            throw (
                "DNS validation failed for management interface index $interfaceIndex.`n" +
                "Allowed DNS servers:`n - " +
                ($AllowedDnsServers -join "`n - ") +
                "`nCurrent configured DNS servers:`n - " +
                ($configuredServers -join "`n - ") +
                "`nReason: No configured DNS server matches the approved site DNS list."
            )
        }

        if ($unexpectedDnsServers.Count -gt 0) {
            throw (
                "DNS validation failed for management interface index $interfaceIndex.`n" +
                "Allowed DNS servers:`n - " +
                ($AllowedDnsServers -join "`n - ") +
                "`nCurrent configured DNS servers:`n - " +
                ($configuredServers -join "`n - ") +
                "`nUnexpected DNS servers:`n - " +
                ($unexpectedDnsServers -join "`n - ") +
                "`nReason: One or more configured DNS servers are outside the approved site DNS list."
            )
        }

        [pscustomobject]@{
            ComputerName           = $env:COMPUTERNAME
            InterfaceIndex         = $interfaceIndex
            ConfiguredDns          = $configuredServers
            AllowedDns             = $AllowedDnsServers
            ApprovedConfiguredDns  = $approvedConfiguredServers
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed              = $true
    Check               = 'Test-DNS'
    Node                = $result.Node
    ManagementIp        = $result.ManagementIp
    DnsServers          = $data.ConfiguredDns
    AllowedDnsServers   = $data.AllowedDns
    Summary             = (
        "Configured DNS servers ($($data.ConfiguredDns -join ', ')) " +
        "are within the approved DNS list."
    )
    ValidatedAt         = [datetime]::UtcNow.ToString('o')
}