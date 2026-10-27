#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$expectedGateway = [string]$Context.Node.management.gateway

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-Gateway' `
    -ArgumentList @($expectedGateway) `
    -ScriptBlock {
        param($ExpectedGateway)

        $routes = @(
            Get-NetRoute `
                -DestinationPrefix '0.0.0.0/0' `
                -ErrorAction Stop |
                Where-Object { $_.NextHop -eq $ExpectedGateway }
        )

        if ($routes.Count -lt 1) {
            throw "Default route through gateway $ExpectedGateway was not found."
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Gateway      = $ExpectedGateway
            Routes       = @(
                $routes |
                    Select-Object InterfaceAlias, InterfaceIndex, NextHop, RouteMetric
            )
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-Gateway'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Gateway      = $data.Gateway
    Routes       = $data.Routes
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}