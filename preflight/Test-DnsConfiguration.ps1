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
$dns = Get-ManagementPlaneValue `
    -Object $config `
    -Name 'dns'

$allowedDnsServers = @(
    Get-ManagementPlaneValue `
        -Object $dns `
        -Name 'allowed_servers'
)

$productionDnsServers = @(
    Get-ManagementPlaneValue `
        -Object $dns `
        -Name 'production_servers'
)

$errors = [System.Collections.Generic.List[string]]::new()

if ($allowedDnsServers.Count -lt 1) {
    [void]$errors.Add(
        'dns.allowed_servers must contain at least one DNS server.'
    )
}

$allDnsServers = @(
    $allowedDnsServers + $productionDnsServers |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        } |
        Sort-Object -Unique
)

foreach ($dnsServer in $allDnsServers) {
    $parsedAddress = $null

    if (
        -not [System.Net.IPAddress]::TryParse(
            [string]$dnsServer,
            [ref]$parsedAddress
        )
    ) {
        [void]$errors.Add(
            "DNS server is not a valid IP address: $dnsServer"
        )
    }
}

$duplicateAllowedServers = @(
    $allowedDnsServers |
        Group-Object |
        Where-Object {
            $_.Count -gt 1
        } |
        Select-Object -ExpandProperty Name
)

foreach ($duplicateDnsServer in $duplicateAllowedServers) {
    [void]$errors.Add(
        "Duplicate allowed DNS server: $duplicateDnsServer"
    )
}

if ($errors.Count -gt 0) {
    throw (
        "DNS configuration validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

return [pscustomobject]@{
    Passed               = $true
    Check                = 'Test-DnsConfiguration'
    AllowedDnsServers    = $allowedDnsServers
    ProductionDnsServers = $productionDnsServers
    Summary              = (
        "$($allowedDnsServers.Count) allowed DNS server(s) and " +
        "$($productionDnsServers.Count) production DNS server(s) validated."
    )
    ValidatedAt          = [datetime]::UtcNow.ToString('o')
}