#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$networkAdapter = Get-ManagementPlaneValue `
    -Object $Context.Config.hardware `
    -Name 'network_adapter'

$expectedDriverPattern = [string](
    Get-ManagementPlaneValue `
        -Object $networkAdapter `
        -Name 'expected_driver_pattern'
)

if ([string]::IsNullOrWhiteSpace($expectedDriverPattern)) {
    $expectedDriverPattern = '*Mellanox*'
}

$minimumLinkSpeedGbps = Get-ManagementPlaneValue `
    -Object $networkAdapter `
    -Name 'minimum_link_speed_gbps'

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-MellanoxDriverBaseline' `
    -ArgumentList @(
        $expectedDriverPattern,
        $minimumLinkSpeedGbps
    ) `
    -ScriptBlock {
        param(
            [string]$ExpectedDriverPattern,
            [object]$MinimumLinkSpeedGbps
        )

        $adapters = @(
            Get-NetAdapter -ErrorAction Stop |
                Where-Object {
                    $_.InterfaceDescription -like $ExpectedDriverPattern
                } |
                Select-Object `
                    Name,
                    Status,
                    LinkSpeed,
                    InterfaceDescription,
                    DriverProvider,
                    DriverVersion
        )

        if ($adapters.Count -lt 1) {
            throw (
                "No adapters matched required driver pattern: $ExpectedDriverPattern"
            )
        }

        $missingDriverInformation = @(
            $adapters |
                Where-Object {
                    [string]::IsNullOrWhiteSpace([string]$_.DriverProvider) -or
                    [string]::IsNullOrWhiteSpace([string]$_.DriverVersion)
                }
        )

        if ($missingDriverInformation.Count -gt 0) {
            throw (
                'Driver provider/version missing for adapters: ' +
                (($missingDriverInformation.Name) -join ', ')
            )
        }

        if ($null -ne $MinimumLinkSpeedGbps) {
            $minimumSpeed = [decimal]$MinimumLinkSpeedGbps

            foreach ($adapter in $adapters) {
                $speedMatch = [regex]::Match(
                    [string]$adapter.LinkSpeed,
                    '(\d+(\.\d+)?)'
                )

                if (-not $speedMatch.Success) {
                    throw (
                        "Unable to parse link speed '$($adapter.LinkSpeed)' " +
                        "for adapter $($adapter.Name)."
                    )
                }

                $actualSpeed = [decimal]$speedMatch.Groups[1].Value

                if ($actualSpeed -lt $minimumSpeed) {
                    throw (
                        "Adapter $($adapter.Name) link speed is $actualSpeed Gbps; " +
                        "minimum required is $minimumSpeed Gbps."
                    )
                }
            }
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Adapters     = $adapters
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

$summary = @(
    $data.Adapters |
        ForEach-Object {
            "$($_.Name): $($_.DriverProvider) $($_.DriverVersion), $($_.LinkSpeed)"
        }
)

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-MellanoxDriverBaseline'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Adapters     = $data.Adapters
        Summary      = (
        "$($data.Adapters.Count) adapter(s) matched protected driver baseline " +
        "${expectedDriverPattern}: " +
        ($summary -join '; ')
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}