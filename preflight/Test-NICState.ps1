#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-NICState' `
    -ScriptBlock {
        $adapters = @(
            Get-NetAdapter -ErrorAction Stop |
                Select-Object Name, Status, LinkSpeed, InterfaceDescription, MacAddress
        )

        $upAdapters = @(
            $adapters |
                Where-Object { $_.Status -eq 'Up' }
        )

        if ($upAdapters.Count -lt 1) {
            throw 'No active network adapters were detected.'
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Adapters     = $adapters
            UpCount      = $upAdapters.Count
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-NICState'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    UpAdapterCount = $data.UpCount
    Adapters      = $data.Adapters
    ValidatedAt   = [datetime]::UtcNow.ToString('o')
}