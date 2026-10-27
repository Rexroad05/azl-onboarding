#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

function Get-ConfigValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if (@($Object.Keys) -contains $Name) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

$config = $Context.Config

$activeDirectory = Get-ConfigValue `
    -Object $config `
    -Name 'active_directory'

$identityMode = [string](
    Get-ConfigValue `
        -Object $activeDirectory `
        -Name 'identity_mode'
)

if ($identityMode -ne 'LocalIdentityWithKeyVault') {
    return [pscustomobject]@{
        Passed         = $true
        Check          = 'Test-LocalIdentityKeyVaultReadiness'
        IdentityMode   = $identityMode
        Outcome        = 'NotApplicable'
        Classification = 'ProfileNotApplicable'
        Summary        = (
            'Local Identity Key Vault readiness is not applicable to the ' +
            'resolved identity profile.'
        )
        ValidatedAt    = [datetime]::UtcNow.ToString('o')
    }
}

$azure = Get-ConfigValue `
    -Object $config `
    -Name 'azure'

$keyVault = Get-ConfigValue `
    -Object $azure `
    -Name 'key_vault'

if ($null -eq $keyVault) {
    throw 'azure.key_vault is required for LocalIdentityWithKeyVault.'
}

$subscriptionId = [string](
    Get-ConfigValue `
        -Object $azure `
        -Name 'subscription_id'
)

$keyVaultName = [string](
    Get-ConfigValue `
        -Object $keyVault `
        -Name 'name'
)

$keyVaultResourceGroup = [string](
    Get-ConfigValue `
        -Object $keyVault `
        -Name 'resource_group'
)

$keyVaultResourceId = [string](
    Get-ConfigValue `
        -Object $keyVault `
        -Name 'resource_id'
)

foreach ($requiredValue in @(
        @{
            Path = 'azure.subscription_id'
            Value = $subscriptionId
        },
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
        throw "$($requiredValue.Path) is required for Local Identity readiness."
    }
}

$azContext = Get-AzContext

if ($null -eq $azContext) {
    throw (
        'Azure PowerShell context is unavailable. Stage 1.3 requires Azure ' +
        'Government authentication before Local Identity Key Vault validation.'
    )
}

if ($azContext.Subscription.Id -ne $subscriptionId) {
    throw (
        "Azure PowerShell subscription mismatch. Expected $subscriptionId; " +
        "current subscription is $($azContext.Subscription.Id)."
    )
}

$vaultResource = Get-AzResource `
    -ResourceId $keyVaultResourceId `
    -ErrorAction Stop

if ($null -eq $vaultResource) {
    throw (
        "Azure Key Vault resource $keyVaultResourceId was not found."
    )
}

if ($vaultResource.ResourceType -ne 'Microsoft.KeyVault/vaults') {
    throw (
        "Resource $keyVaultResourceId is type $($vaultResource.ResourceType); " +
        'expected Microsoft.KeyVault/vaults.'
    )
}

if ($vaultResource.Name -ine $keyVaultName) {
    throw (
        "Azure Key Vault name mismatch. Expected $keyVaultName; " +
        "received $($vaultResource.Name)."
    )
}

if ($vaultResource.ResourceGroupName -ine $keyVaultResourceGroup) {
    throw (
        "Azure Key Vault resource group mismatch. Expected " +
        "$keyVaultResourceGroup; received $($vaultResource.ResourceGroupName)."
    )
}

return [pscustomobject]@{
    Passed                = $true
    Check                 = 'Test-LocalIdentityKeyVaultReadiness'
    IdentityMode          = $identityMode
    SubscriptionId        = $subscriptionId
    KeyVaultName          = $vaultResource.Name
    KeyVaultResourceGroup = $vaultResource.ResourceGroupName
    KeyVaultResourceId    = $vaultResource.ResourceId
    ResourceType          = $vaultResource.ResourceType
    Summary               = (
        "Local Identity Azure Key Vault readiness validated for " +
        "$($vaultResource.Name)."
    )
    ValidatedAt           = [datetime]::UtcNow.ToString('o')
}