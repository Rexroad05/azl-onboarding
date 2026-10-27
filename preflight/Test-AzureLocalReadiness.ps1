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
    -OperationName 'Test-AzureLocalReadiness' `
    -ScriptBlock {
        $azureLocalCommand = Get-Command `
            -Name Get-AzureStackHCI `
            -ErrorAction SilentlyContinue

        if ($null -eq $azureLocalCommand) {
            throw 'Get-AzureStackHCI is unavailable.'
        }

        $azureLocalState = @(
            Get-AzureStackHCI -ErrorAction Stop
        )

        if ($azureLocalState.Count -lt 1) {
            throw 'Get-AzureStackHCI returned no readiness data.'
        }

        $managementAdapters = @(
            Get-NetAdapter `
                -ErrorAction Stop |
                Where-Object { $_.Status -eq 'Up' }
        )

        if ($managementAdapters.Count -lt 1) {
            throw 'No active network adapters were detected.'
        }

        [pscustomobject]@{
            ComputerName      = $env:COMPUTERNAME
            ActiveAdapterCount = $managementAdapters.Count
            AzureLocalState   = (
                $azureLocalState |
                    ConvertTo-Json -Depth 10 -Compress
            )
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed             = $true
    Check              = 'Test-AzureLocalReadiness'
    Node               = $result.Node
    ManagementIp       = $result.ManagementIp
    ActiveAdapterCount = $data.ActiveAdapterCount
    ValidatedAt        = [datetime]::UtcNow.ToString('o')
}