#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$storage = Get-ManagementPlaneValue `
    -Object $Context.Config.network `
    -Name 'storage'

$requireRdma = Get-ManagementPlaneValue `
    -Object $storage `
    -Name 'require_rdma'

if ($requireRdma -ne $true) {
    return [pscustomobject]@{
        Passed       = $true
        Check        = 'Test-RdmaState'
        Node         = $Context.Node.name
        ManagementIp = $Context.Node.management.ip
        Summary      = 'RDMA validation is not required by the protected storage baseline.'
        ValidatedAt  = [datetime]::UtcNow.ToString('o')
    }
}

$storageAdapters = @($Context.Node.storage)

if ($storageAdapters.Count -lt 1) {
    throw "Node $($Context.Node.name) has no storage adapter configuration."
}

$adapterNames = @($storageAdapters | ForEach-Object { [string]$_.adapter })

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-RdmaState' `
    -ArgumentList @($adapterNames) `
    -ScriptBlock {
        param(
            [string[]]$AdapterNames
        )

        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($adapterName in $AdapterNames) {
            $rdma = Get-NetAdapterRdma `
                -Name $adapterName `
                -ErrorAction Stop

            if (-not $rdma.Enabled) {
                throw "RDMA is not enabled on storage adapter $adapterName."
            }

            if (
                [string]$rdma.Operational -notin @(
                    'True',
                    'Ready',
                    'Operational'
                )
            ) {
                throw (
                    "RDMA is not operational on storage adapter $adapterName. " +
                    "Current state: $($rdma.Operational)"
                )
            }

            $results.Add([pscustomobject]@{
                Adapter     = $adapterName
                Enabled     = $rdma.Enabled
                Operational = $rdma.Operational
            })
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Adapters     = $results.ToArray()
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-RdmaState'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Adapters     = $data.Adapters
    Summary      = (
        "RDMA is enabled and operational on $($data.Adapters.Count) storage adapter(s)."
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}