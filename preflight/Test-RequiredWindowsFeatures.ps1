#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$requiredFeatures = @(
    'Hyper-V',
    'Failover-Clustering',
    'FS-Data-Deduplication',
    'BitLocker'
)

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-RequiredWindowsFeatures' `
    -ArgumentList @($requiredFeatures) `
    -ScriptBlock {
        param(
            [string[]]$RequiredFeatures
        )

        $command = Get-Command `
            -Name Get-WindowsFeature `
            -ErrorAction SilentlyContinue

        if ($null -eq $command) {
            throw 'Get-WindowsFeature is unavailable on the remote HCN.'
        }

        $features = @(
            Get-WindowsFeature `
                -Name $RequiredFeatures `
                -ErrorAction Stop |
                Select-Object Name, InstallState
        )

        $missingFeatures = @(
            $features |
                Where-Object {
                    $_.InstallState -ne 'Installed'
                }
        )

        if ($missingFeatures.Count -gt 0) {
            throw (
                'Required Windows features are not installed: ' +
                (($missingFeatures.Name) -join ', ')
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Features     = $features
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-RequiredWindowsFeatures'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    Features     = $data.Features
    Summary      = (
        "$($data.Features.Count) required Windows features are installed."
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}