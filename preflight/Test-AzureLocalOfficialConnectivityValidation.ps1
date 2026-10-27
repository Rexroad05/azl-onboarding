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
    -OperationName 'Test-AzureLocalOfficialConnectivityValidation' `
    -ScriptBlock {
        $command = Get-Command `
            -Name Invoke-AzStackHciConnectivityValidation `
            -ErrorAction SilentlyContinue

        if ($null -eq $command) {
            throw 'Invoke-AzStackHciConnectivityValidation is unavailable.'
        }

        $validationResults = @(
            Invoke-AzStackHciConnectivityValidation `
                -ErrorAction Stop
        )

        $failedResults = @(
            $validationResults |
                Where-Object {
                    ([string]$_.Severity -match 'Error|Failed') -or
                    ([string]$_.Status -match 'Error|Failed')
                }
        )

        if ($failedResults.Count -gt 0) {
            throw (
                'Azure Local official connectivity validation returned errors: ' +
                (($failedResults | Out-String).Trim())
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            ResultCount  = $validationResults.Count
            Results      = $validationResults
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-AzureLocalOfficialConnectivityValidation'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    ResultCount  = $data.ResultCount
    Summary      = (
        'Official Azure Local connectivity validation completed without errors.'
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}