#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$expectedIp = [string]$Context.Node.management.ip

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-IPConfiguration' `
    -ArgumentList @($expectedIp) `
    -ScriptBlock {
        param($ExpectedIp)

        $ipAddress = @(
            Get-NetIPAddress `
                -AddressFamily IPv4 `
                -ErrorAction Stop |
                Where-Object { $_.IPAddress -eq $ExpectedIp }
        )

        if ($ipAddress.Count -ne 1) {
            throw "Expected management IP $ExpectedIp was not found."
        }

        [pscustomobject]@{
            ComputerName  = $env:COMPUTERNAME
            InterfaceAlias = $ipAddress[0].InterfaceAlias
            InterfaceIndex = $ipAddress[0].InterfaceIndex
            IPAddress      = $ipAddress[0].IPAddress
            PrefixLength   = $ipAddress[0].PrefixLength
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed         = $true
    Check          = 'Test-IPConfiguration'
    Node           = $result.Node
    ManagementIp   = $result.ManagementIp
    InterfaceAlias = $data.InterfaceAlias
    InterfaceIndex = $data.InterfaceIndex
    IPAddress      = $data.IPAddress
    PrefixLength   = $data.PrefixLength
    ValidatedAt    = [datetime]::UtcNow.ToString('o')
}