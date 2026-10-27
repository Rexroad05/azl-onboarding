#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$config = $Context.Config
$siteName = [string]$config.site.name

$executionHosts = @(
    Get-ManagementPlaneValue `
        -Object $config `
        -Name 'execution_hosts'
)

if ($executionHosts.Count -lt 1) {
    throw 'execution_hosts must contain at least one approved execution host.'
}

$errors = [System.Collections.Generic.List[string]]::new()
$hostSummaries = [System.Collections.Generic.List[string]]::new()

foreach ($executionHost in $executionHosts) {
    $hostId = [string]$executionHost.id
    $computerName = [string]$executionHost.computer_name
    $hostingSite = [string]$executionHost.hosting_site
    $packageRoot = [string]$executionHost.package_root
    $artifactsPath = [string]$executionHost.artifacts_path
    $allowedSites = @($executionHost.allowed_sites)

    if ([string]::IsNullOrWhiteSpace($hostId)) {
        [void]$errors.Add('Each execution host requires id.')
        continue
    }

    foreach ($requiredProperty in @(
            @{
                Name = 'computer_name'
                Value = $computerName
            },
            @{
                Name = 'hosting_site'
                Value = $hostingSite
            },
            @{
                Name = 'package_root'
                Value = $packageRoot
            },
            @{
                Name = 'artifacts_path'
                Value = $artifactsPath
            }
        )) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredProperty.Value)) {
            [void]$errors.Add(
                "Execution host $hostId requires $($requiredProperty.Name)."
            )
        }
    }

    if ($allowedSites -notcontains $siteName) {
        [void]$errors.Add(
            "Execution host $hostId is not authorized for site $siteName."
        )
    }

    $transport = $executionHost.transport

    if ($null -eq $transport) {
        [void]$errors.Add(
            "Execution host $hostId requires transport configuration."
        )
    }
    else {
        if ([string]$transport.primary -ne 'WinRM-HTTPS') {
            [void]$errors.Add(
                "Execution host $hostId transport.primary must be WinRM-HTTPS."
            )
        }

        $winrmPort = [int]$transport.winrm_port

        if ($winrmPort -lt 1 -or $winrmPort -gt 65535) {
            [void]$errors.Add(
                "Execution host $hostId has invalid WinRM port $winrmPort."
            )
        }
    }

    [void]$hostSummaries.Add(
        "$hostId ($computerName; hosting site $hostingSite)"
    )
}

if ($errors.Count -gt 0) {
    throw (
        "Execution host configuration validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

return [pscustomobject]@{
    Passed         = $true
    Check          = 'Test-ExecutionHostConfiguration'
    ExecutionHosts = $hostSummaries.ToArray()
    Summary        = (
        "$($hostSummaries.Count) approved execution host(s) validated for site $siteName."
    )
    ValidatedAt    = [datetime]::UtcNow.ToString('o')
}