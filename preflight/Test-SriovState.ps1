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

$requireSriov = Get-ManagementPlaneValue `
    -Object $storage `
    -Name 'require_sriov'

if ($requireSriov -ne $true) {
    return [pscustomobject]@{
        Passed       = $true
        Check        = 'Test-SriovState'
        Node         = $Context.Node.name
        ManagementIp = $Context.Node.management.ip
        Summary      = 'SR-IOV validation is not required by the protected storage baseline.'
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
    -OperationName 'Test-SriovState' `
    -ArgumentList @($adapterNames) `
    -ScriptBlock {
        param(
            [string[]]$AdapterNames
        )

        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($adapterName in $AdapterNames) {
            $sriov = Get-NetAdapterSriov `
                -Name $adapterName `
                -ErrorAction Stop

            if (-not $sriov.Enabled) {
                throw "SR-IOV is not enabled on adapter $adapterName."
            }

            if ([string]$sriov.SriovSupport -ne 'Supported') {
                throw (
                    "SR-IOV is not supported on adapter $adapterName. " +
                    "Current state: $($sriov.SriovSupport)"
                )
            }

            $results.Add([pscustomobject]@{
                Adapter      = $adapterName
                Enabled      = $sriov.Enabled
                SriovSupport = $sriov.SriovSupport
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
    Check        = 'Test-SriovState'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Adapters     = $data.Adapters
    Summary      = (
        "SR-IOV is enabled and supported on $($data.Adapters.Count) storage adapter(s)."
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}