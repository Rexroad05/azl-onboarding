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
    -OperationName 'Test-NTP' `
    -ScriptBlock {
        $statusOutput = @(
            & w32tm /query /status 2>&1
        )

        if ($LASTEXITCODE -ne 0) {
            throw (
                "w32tm /query /status failed: " +
                ($statusOutput -join '; ')
            )
        }

        $sourceOutput = @(
            & w32tm /query /source 2>&1
        )

        if ($LASTEXITCODE -ne 0) {
            throw (
                "w32tm /query /source failed: " +
                ($sourceOutput -join '; ')
            )
        }

        $peerOutput = @(
            & w32tm /query /peers 2>&1
        )

        if ($LASTEXITCODE -ne 0) {
            throw (
                "w32tm /query /peers failed: " +
                ($peerOutput -join '; ')
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Source       = ($sourceOutput -join "`n").Trim()
            Status       = ($statusOutput -join "`n").Trim()
            Peers        = ($peerOutput -join "`n").Trim()
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-NTP'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Source       = $data.Source
    Status       = $data.Status
    Peers        = $data.Peers
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}