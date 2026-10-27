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
    -OperationName 'Test-AzureLocalPolicyState' `
    -ScriptBlock {
        $command = Get-Command `
            -Name Get-AzureStackHCI `
            -ErrorAction SilentlyContinue

        if ($null -eq $command) {
            throw 'Get-AzureStackHCI is unavailable on the remote node.'
        }

        $state = @(
            Get-AzureStackHCI -ErrorAction Stop
        )

        $serializedState = $state |
            ConvertTo-Json -Depth 10 -Compress

        if (
            $serializedState -match '(?i)out[\s_-]*of[\s_-]*policy' -or
            $serializedState -match '(?i)outofpolicy' -or
            $serializedState -match '(?i)unsupported' -or
            $serializedState -match '(?i)expired'
        ) {
            throw (
                'Azure Local node appears out of policy, unsupported, or expired.'
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            State        = $serializedState
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-AzureLocalPolicyState'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    RemoteNode   = $data.ComputerName
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}