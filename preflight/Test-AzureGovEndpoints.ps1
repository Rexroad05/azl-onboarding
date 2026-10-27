#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$endpointHosts = @($Context.Config.azure.connectivity_hosts)

if ($endpointHosts.Count -lt 1) {
    throw 'azure.connectivity_hosts must contain at least one host.'
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-AzureGovEndpoints' `
    -ArgumentList @($endpointHosts) `
    -ScriptBlock {
        param(
            [string[]]$EndpointHosts
        )

        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($endpointHost in $EndpointHosts) {
            $connection = Test-NetConnection `
                -ComputerName $endpointHost `
                -Port 443 `
                -WarningAction SilentlyContinue

            $results.Add([pscustomobject]@{
                HostName          = $endpointHost
                Port              = 443
                TcpTestSucceeded  = $connection.TcpTestSucceeded
                RemoteAddress     = if ($null -ne $connection.RemoteAddress) {
                    $connection.RemoteAddress.IPAddressToString
                }
                else {
                    $null
                }
            })
        }

        $failedEndpoints = @(
            $results |
                Where-Object { -not $_.TcpTestSucceeded }
        )

        if ($failedEndpoints.Count -gt 0) {
            throw (
                'TCP 443 connectivity failed for: ' +
                (($failedEndpoints.HostName) -join ', ')
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Endpoints    = $results.ToArray()
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-AzureGovEndpoints'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Endpoints    = $data.Endpoints
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}