#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\HcnEnsure.Common.psm1" -Force

$expectedManagementIp = [string]$Context.Node.management.ip

$dnsConfiguration = Get-HcnEnsureValue `
    -Object $Context.Config `
    -Name 'dns'

$desiredDnsServers = @(
    Get-HcnEnsureValue `
        -Object $dnsConfiguration `
        -Name 'allowed_servers'
)

if ($desiredDnsServers.Count -lt 1) {
    throw 'dns.allowed_servers must contain at least one DNS server.'
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Ensure-DNS' `
    -ArgumentList @($expectedManagementIp, $desiredDnsServers) `
    -ScriptBlock {
        param(
            [string]$ExpectedManagementIp,
            [string[]]$DesiredDnsServers
        )

        $ipAddress = @(
            Get-NetIPAddress `
                -AddressFamily IPv4 `
                -ErrorAction Stop |
                Where-Object {
                    $_.IPAddress -eq $ExpectedManagementIp
                }
        )

        if ($ipAddress.Count -ne 1) {
            throw (
                "Expected management IP $ExpectedManagementIp was not found."
            )
        }

        $interfaceIndex = $ipAddress[0].InterfaceIndex

        $currentDnsServers = @(
            (Get-DnsClientServerAddress `
                -InterfaceIndex $interfaceIndex `
                -AddressFamily IPv4 `
                -ErrorAction Stop).ServerAddresses
        )

        $matchesDesired = (
            $currentDnsServers.Count -eq $DesiredDnsServers.Count -and
            @(
                $currentDnsServers |
                    Where-Object {
                        $DesiredDnsServers -notcontains $_
                    }
            ).Count -eq 0
        )

        $changed = $false

        if (-not $matchesDesired) {
            Set-DnsClientServerAddress `
                -InterfaceIndex $interfaceIndex `
                -ServerAddresses $DesiredDnsServers `
                -ErrorAction Stop

            $changed = $true
        }

        $finalDnsServers = @(
            (Get-DnsClientServerAddress `
                -InterfaceIndex $interfaceIndex `
                -AddressFamily IPv4 `
                -ErrorAction Stop).ServerAddresses
        )

        $matchesDesired = (
            $finalDnsServers.Count -eq $DesiredDnsServers.Count -and
            @(
                $finalDnsServers |
                    Where-Object {
                        $DesiredDnsServers -notcontains $_
                    }
            ).Count -eq 0
        )

        if (-not $matchesDesired) {
            throw (
                "DNS configuration did not match desired state. Desired: " +
                "$($DesiredDnsServers -join ', '). Current: " +
                "$($finalDnsServers -join ', ')"
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Changed      = $changed
            InterfaceIndex = $interfaceIndex
            Before       = $currentDnsServers
            After        = $finalDnsServers
        }
    }

$data = $result.Data | Select-Object -First 1

if ($data.Changed) {
    return New-HcnEnsureResult `
        -Check 'Ensure-DNS' `
        -Outcome 'Changed' `
        -Changed $true `
        -Summary (
            "DNS updated from ($($data.Before -join ', ')) to " +
            "($($data.After -join ', '))."
        ) `
        -AdditionalProperties @{
            Node         = $result.Node
            ManagementIp = $result.ManagementIp
            DnsServers   = $data.After
        }
}

return New-HcnEnsureResult `
    -Check 'Ensure-DNS' `
    -Outcome 'AlreadyCompliant' `
    -Summary (
        "DNS already matches approved configuration: " +
        "$($data.After -join ', ')."
    ) `
    -AdditionalProperties @{
        Node         = $result.Node
        ManagementIp = $result.ManagementIp
        DnsServers   = $data.After
    }