#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\HcnEnsure.Common.psm1" -Force

$dhcp = Get-HcnEnsureValue `
    -Object $Context.Config.network `
    -Name 'dhcp'

$requiredAdapters = @(
    Get-HcnEnsureValue `
        -Object $dhcp `
        -Name 'disable_on'
)

if ($requiredAdapters.Count -lt 1) {
    throw 'network.dhcp.disable_on must contain at least one adapter.'
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Ensure-DhcpDisabled' `
    -ArgumentList @($requiredAdapters) `
    -ScriptBlock {
        param(
            [string[]]$RequiredAdapters
        )

        $changes = [System.Collections.Generic.List[string]]::new()

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
                    Set-NetIPInterface `
                        -InterfaceIndex $interface.InterfaceIndex `
                        -Dhcp Disabled `
                        -ErrorAction Stop

                    $changes.Add(
                        "$adapterName interface index $($interface.InterfaceIndex)"
                    )
                }
            }
        }

        $finalState = [System.Collections.Generic.List[object]]::new()

        foreach ($adapterName in $RequiredAdapters) {
            $interfaces = @(
                Get-NetIPInterface `
                    -InterfaceAlias $adapterName `
                    -AddressFamily IPv4 `
                    -ErrorAction Stop
            )

            foreach ($interface in $interfaces) {
                if ([string]$interface.Dhcp -ne 'Disabled') {
                    throw (
                        "DHCP remains $($interface.Dhcp) on $adapterName; " +
                        'expected Disabled.'
                    )
                }

                $finalState.Add([pscustomobject]@{
                    Adapter        = $adapterName
                    InterfaceIndex = $interface.InterfaceIndex
                    Dhcp           = $interface.Dhcp
                })
            }
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Changed      = ($changes.Count -gt 0)
            Changes      = $changes.ToArray()
            Interfaces   = $finalState.ToArray()
        }
    }

$data = $result.Data | Select-Object -First 1

if ($data.Changed) {
    return New-HcnEnsureResult `
        -Check 'Ensure-DhcpDisabled' `
        -Outcome 'Changed' `
        -Changed $true `
        -Summary (
            "DHCP disabled on: " +
            ($data.Changes -join '; ')
        ) `
        -AdditionalProperties @{
            Node         = $result.Node
            ManagementIp = $result.ManagementIp
            Interfaces   = $data.Interfaces
        }
}

return New-HcnEnsureResult `
    -Check 'Ensure-DhcpDisabled' `
    -Outcome 'AlreadyCompliant' `
    -Summary 'DHCP is already disabled on all required interfaces.' `
    -AdditionalProperties @{
        Node         = $result.Node
        ManagementIp = $result.ManagementIp
        Interfaces   = $data.Interfaces
    }