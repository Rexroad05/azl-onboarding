#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\..\preflight\ManagementPlane.Common.psm1" -Force

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-AzureLocalOS' `
    -ScriptBlock {
        $command = Get-Command `
            -Name Get-AzureStackHCI `
            -ErrorAction SilentlyContinue

        if ($null -eq $command) {
            throw 'Get-AzureStackHCI is unavailable on the remote node.'
        }

        $operatingSystem = Get-CimInstance `
            -ClassName Win32_OperatingSystem `
            -ErrorAction Stop

        $azureLocalState = @(
            Get-AzureStackHCI -ErrorAction Stop
        )

        if ($azureLocalState.Count -lt 1) {
            throw 'Get-AzureStackHCI returned no Azure Local state.'
        }

        [pscustomobject]@{
            ComputerName       = $env:COMPUTERNAME
            OperatingSystem    = $operatingSystem.Caption
            OSVersion          = $operatingSystem.Version
            BuildNumber        = $operatingSystem.BuildNumber
            AzureLocalStateRaw = (
                $azureLocalState |
                    ConvertTo-Json -Depth 10 -Compress
            )
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed            = $true
    Check             = 'Test-AzureLocalOS'
    Node              = $result.Node
    ManagementIp      = $result.ManagementIp
    RemoteComputer    = $data.ComputerName
    OperatingSystem   = $data.OperatingSystem
    OSVersion         = $data.OSVersion
    BuildNumber       = $data.BuildNumber
    ValidatedAt       = [datetime]::UtcNow.ToString('o')
}