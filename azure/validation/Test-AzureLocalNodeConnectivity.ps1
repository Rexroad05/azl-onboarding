#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\..\preflight\ManagementPlane.Common.psm1" -Force

function Get-ConfigValue {
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

$azure = Get-ConfigValue `
    -Object $Context.Config `
    -Name 'azure'

$connectivityHosts = @(
    Get-ConfigValue `
        -Object $azure `
        -Name 'connectivity_hosts'
)

if ($connectivityHosts.Count -lt 1) {
    throw 'azure.connectivity_hosts must contain at least one endpoint.'
}

$operation = [string]$Context.Operation

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName $operation `
    -ArgumentList @($connectivityHosts) `
    -ScriptBlock {
        param(
            [string[]]$ConnectivityHosts
        )

        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($hostName in $ConnectivityHosts) {
            $dnsRecords = @(
                Resolve-DnsName `
                    -Name $hostName `
                    -Type A `
                    -ErrorAction Stop
            )

            if ($dnsRecords.Count -lt 1) {
                throw "No A record was returned for Azure endpoint $hostName."
            }

            $connection = Test-NetConnection `
                -ComputerName $hostName `
                -Port 443 `
                -WarningAction SilentlyContinue

            if (-not $connection.TcpTestSucceeded) {
                throw (
                    "TCP 443 connectivity failed for Azure endpoint $hostName."
                )
            }

            $results.Add(
                [pscustomobject]@{
                    HostName = $hostName
                    RemoteAddress = $connection.RemoteAddress
                    RemotePort = 443
                    TcpTestSucceeded = $connection.TcpTestSucceeded
                }
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Endpoints = $results.ToArray()
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

$summaryPrefix = if ($operation -eq 'Test-AzureGovEndpoints') {
    'Azure Government endpoint validation'
}
else {
    'Azure connectivity validation'
}

return [pscustomobject]@{
    Passed       = $true
    Check        = $operation
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Endpoints    = $data.Endpoints
    Summary      = (
        "$summaryPrefix succeeded for " +
        "$($data.Endpoints.Count) endpoint(s)."
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}