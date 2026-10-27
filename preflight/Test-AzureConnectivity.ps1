#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$hostName = switch ([string]$Context.Config.azure.cloud) {
    'AzureUSGovernment' { 'management.usgovcloudapi.net' }
    default { 'management.azure.com' }
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-AzureConnectivity' `
    -ArgumentList @($hostName) `
    -ScriptBlock {
        param($HostName)

        $connection = Test-NetConnection `
            -ComputerName $HostName `
            -Port 443 `
            -WarningAction SilentlyContinue

        if (-not $connection.TcpTestSucceeded) {
            throw "TCP 443 connectivity failed for $HostName."
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            HostName     = $HostName
            RemotePort   = 443
            RemoteAddress = $connection.RemoteAddress.IPAddressToString
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed        = $true
    Check         = 'Test-AzureConnectivity'
    Node          = $result.Node
    ManagementIp  = $result.ManagementIp
    AzureHost     = $data.HostName
    RemoteAddress = $data.RemoteAddress
    ValidatedAt   = [datetime]::UtcNow.ToString('o')
}