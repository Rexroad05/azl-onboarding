#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$dhcpConfiguration = Get-ManagementPlaneValue `
    -Object $Context.Config.network `
    -Name 'dhcp'

$requiredAdapters = @(
    Get-ManagementPlaneValue `
        -Object $dhcpConfiguration `
        -Name 'disable_on'
)

if ($requiredAdapters.Count -lt 1) {
    throw 'network.dhcp.disable_on must contain at least one adapter.'
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-DhcpState' `
    -ArgumentList @($requiredAdapters) `
    -ScriptBlock {
        param(
            [string[]]$RequiredAdapters
        )

        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($adapterName in $RequiredAdapters) {
            $interfaces = @(
                Get-NetIPInterface `
                    -InterfaceAlias $adapterName `
                    -AddressFamily IPv4 `
                    -ErrorAction Stop
            )

            if ($interfaces.Count -lt 1) {
                throw "No IPv4 interface found for adapter $adapterName."
            }

            foreach ($interface in $interfaces) {
                if ([string]$interface.Dhcp -ne 'Disabled') {
                    throw (
                        "DHCP is $($interface.Dhcp) on adapter $adapterName; " +
                        'expected Disabled.'
                    )
                }

                $results.Add([pscustomobject]@{
                    Adapter        = $adapterName
                    InterfaceIndex = $interface.InterfaceIndex
                    Dhcp           = $interface.Dhcp
                })
            }
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Interfaces   = $results.ToArray()
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-DhcpState'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Interfaces   = $data.Interfaces
    Summary      = (
        "DHCP is disabled on $($data.Interfaces.Count) required interface(s)."
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}