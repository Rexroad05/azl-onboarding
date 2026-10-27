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

$activeDirectory = Get-ManagementPlaneValue `
    -Object $config `
    -Name 'active_directory'

$azure = Get-ManagementPlaneValue `
    -Object $config `
    -Name 'azure'

$identityMode = [string](
    Get-ManagementPlaneValue `
        -Object $activeDirectory `
        -Name 'identity_mode'
)

if ($identityMode -eq 'LocalIdentityWithKeyVault') {
    $keyVault = Get-ManagementPlaneValue `
        -Object $azure `
        -Name 'key_vault'

    if ($null -eq $keyVault) {
        throw (
            'azure.key_vault is required for LocalIdentityWithKeyVault.'
        )
    }

    $keyVaultName = [string](
        Get-ManagementPlaneValue `
            -Object $keyVault `
            -Name 'name'
    )

    $keyVaultResourceGroup = [string](
        Get-ManagementPlaneValue `
            -Object $keyVault `
            -Name 'resource_group'
    )

    $keyVaultResourceId = [string](
        Get-ManagementPlaneValue `
            -Object $keyVault `
            -Name 'resource_id'
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($requiredValue in @(
            @{
                Path = 'azure.key_vault.name'
                Value = $keyVaultName
            },
            @{
                Path = 'azure.key_vault.resource_group'
                Value = $keyVaultResourceGroup
            },
            @{
                Path = 'azure.key_vault.resource_id'
                Value = $keyVaultResourceId
            }
        )) {
        if ([string]::IsNullOrWhiteSpace([string]$requiredValue.Value)) {
            [void]$errors.Add("$($requiredValue.Path) is required.")
        }
    }

    if (
        -not [string]::IsNullOrWhiteSpace($keyVaultResourceId) -and
        $keyVaultResourceId -notmatch
        '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.KeyVault/vaults/[^/]+$'
    ) {
        [void]$errors.Add(
            'azure.key_vault.resource_id is not a valid Azure Key Vault resource ID.'
        )
    }

    if ($errors.Count -gt 0) {
        throw (
            "Local Identity configuration validation failed:`n - " +
            ($errors -join "`n - ")
        )
    }

    return [pscustomobject]@{
        Passed              = $true
        Check               = 'Test-ActiveDirectoryConfiguration'
        IdentityMode        = $identityMode
        KeyVaultName        = $keyVaultName
        KeyVaultResourceGroup = $keyVaultResourceGroup
        KeyVaultResourceId  = $keyVaultResourceId
        Summary             = (
            'Local Identity with Azure Key Vault configuration validated. ' +
            'AD DS domain-controller validation is not required by this profile.'
        )
        ValidatedAt         = [datetime]::UtcNow.ToString('o')
    }
}

$dns = Get-ManagementPlaneValue `
    -Object $config `
    -Name 'dns'

$domainFqdn = [string](
    Get-ManagementPlaneValue `
        -Object $activeDirectory `
        -Name 'domain_fqdn'
)

$srvRecord = [string](
    Get-ManagementPlaneValue `
        -Object $activeDirectory `
        -Name 'srv_record'
)

$validationDomainController = [string](
    Get-ManagementPlaneValue `
        -Object $activeDirectory `
        -Name 'validation_domain_controller'
)

$requiredPorts = @(
    Get-ManagementPlaneValue `
        -Object $activeDirectory `
        -Name 'required_ports'
)

$allowedDnsServers = @(
    Get-ManagementPlaneValue `
        -Object $dns `
        -Name 'allowed_servers'
)

$errors = [System.Collections.Generic.List[string]]::new()

if ([string]::IsNullOrWhiteSpace($domainFqdn)) {
    [void]$errors.Add('active_directory.domain_fqdn is required.')
}

if ([string]::IsNullOrWhiteSpace($srvRecord)) {
    [void]$errors.Add('active_directory.srv_record is required.')
}

if ([string]::IsNullOrWhiteSpace($validationDomainController)) {
    [void]$errors.Add(
        'active_directory.validation_domain_controller is required.'
    )
}

if ($allowedDnsServers.Count -lt 1) {
    [void]$errors.Add(
        'dns.allowed_servers must contain at least one server for ADDS validation.'
    )
}

if ($requiredPorts.Count -lt 1) {
    [void]$errors.Add(
        'active_directory.required_ports must contain at least one port.'
    )
}

foreach ($port in $requiredPorts) {
    $portNumber = [int]$port

    if ($portNumber -lt 1 -or $portNumber -gt 65535) {
        [void]$errors.Add(
            "Invalid active_directory.required_ports value: $port"
        )
    }
}

if ($errors.Count -gt 0) {
    throw (
        "Active Directory configuration validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

return [pscustomobject]@{
    Passed                     = $true
    Check                      = 'Test-ActiveDirectoryConfiguration'
    IdentityMode               = 'ActiveDirectoryDomainServices'
    DomainFqdn                 = $domainFqdn
    SrvRecord                  = $srvRecord
    ValidationDomainController = $validationDomainController
    ValidationDnsServer        = $allowedDnsServers[0]
    RequiredPorts              = $requiredPorts
    Summary                    = (
        "ADDS domain, SRV record, validation domain controller, DNS server, " +
        "and $($requiredPorts.Count) required port(s) validated."
    )
    ValidatedAt                = [datetime]::UtcNow.ToString('o')
}