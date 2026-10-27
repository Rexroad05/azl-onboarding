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

function Get-AzureGovernmentContext {
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $azure = Get-ConfigValue `
        -Object $Config `
        -Name 'azure'

    $expectedCloud = [string](
        Get-ConfigValue `
            -Object $azure `
            -Name 'cloud'
    )

    $expectedTenant = [string](
        Get-ConfigValue `
            -Object $azure `
            -Name 'tenant_id'
    )

    $expectedSubscription = [string](
        Get-ConfigValue `
            -Object $azure `
            -Name 'subscription_id'
    )

    if ($expectedCloud -ne 'AzureUSGovernment') {
        throw (
            "Stage 1.3 requires azure.cloud AzureUSGovernment. " +
            "Resolved value: $expectedCloud"
        )
    }

    $azContext = Get-AzContext

    if ($null -eq $azContext) {
        throw (
            'Azure PowerShell context is unavailable. Azure Government ' +
            'authentication must complete before Stage 1.3 validation.'
        )
    }

    if ($azContext.Environment.Name -ne 'AzureUSGovernment') {
        throw (
            'Azure PowerShell environment mismatch. Expected AzureUSGovernment; ' +
            "current environment is $($azContext.Environment.Name)."
        )
    }

    if ($azContext.Tenant.Id -ne $expectedTenant) {
        throw (
            "Azure PowerShell tenant mismatch. Expected $expectedTenant; " +
            "current tenant is $($azContext.Tenant.Id)."
        )
    }

    if ($azContext.Subscription.Id -ne $expectedSubscription) {
        throw (
            "Azure PowerShell subscription mismatch. Expected " +
            "$expectedSubscription; current subscription is " +
            "$($azContext.Subscription.Id)."
        )
    }

    return [pscustomobject]@{
        Context = $azContext
        Azure = $azure
        TenantId = $expectedTenant
        SubscriptionId = $expectedSubscription
    }
}

if ([string]::IsNullOrWhiteSpace([string]$Context.Operation)) {
    throw 'Stage 1.3 Azure validation requires Context.Operation.'
}

$azureState = Get-AzureGovernmentContext `
    -Config $Context.Config

$operation = [string]$Context.Operation
$resourceGroupName = [string](
    Get-ConfigValue `
        -Object $azureState.Azure `
        -Name 'resource_group'
)

switch ($operation) {
    'Connect-Azure' {
        return [pscustomobject]@{
            Passed         = $true
            Check          = 'Connect-Azure'
            Cloud          = $azureState.Context.Environment.Name
            TenantId       = $azureState.Context.Tenant.Id
            SubscriptionId = $azureState.Context.Subscription.Id
            Account        = $azureState.Context.Account.Id
            Summary        = (
                'Azure Government PowerShell context is authenticated and ' +
                'matches the resolved tenant and subscription.'
            )
            ValidatedAt    = [datetime]::UtcNow.ToString('o')
        }
    }

    'Test-Subscription' {
        $subscription = Get-AzSubscription `
            -SubscriptionId $azureState.SubscriptionId `
            -TenantId $azureState.TenantId `
            -ErrorAction Stop

        if ($subscription.State -ne 'Enabled') {
            throw (
                "Azure subscription $($subscription.Id) state is " +
                "$($subscription.State); expected Enabled."
            )
        }

        return [pscustomobject]@{
            Passed         = $true
            Check          = 'Test-Subscription'
            SubscriptionId = $subscription.Id
            SubscriptionName = $subscription.Name
            TenantId       = $subscription.TenantId
            State          = $subscription.State
            Summary        = (
                "Azure Government subscription $($subscription.Name) is enabled."
            )
            ValidatedAt    = [datetime]::UtcNow.ToString('o')
        }
    }

    'Test-Permissions' {
        if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
            throw 'azure.resource_group is required for permission validation.'
        }

        $resourceGroup = Get-AzResourceGroup `
            -Name $resourceGroupName `
            -ErrorAction Stop

        return [pscustomobject]@{
            Passed            = $true
            Check             = 'Test-Permissions'
            SubscriptionId    = $azureState.SubscriptionId
            ResourceGroupName = $resourceGroup.ResourceGroupName
            Location          = $resourceGroup.Location
            Summary           = (
                'Azure Government authenticated identity has read access to the ' +
                'configured subscription and resource group.'
            )
            ValidatedAt       = [datetime]::UtcNow.ToString('o')
        }
    }

    'Test-ResourceProviders' {
        $requiredProviders = @(
            Get-ConfigValue `
                -Object $azureState.Azure `
                -Name 'providers'
        )

        if ($requiredProviders.Count -lt 1) {
            throw 'azure.providers must contain at least one required provider.'
        }

        $providerResults = [System.Collections.Generic.List[object]]::new()

        foreach ($providerName in $requiredProviders) {
            $provider = Get-AzResourceProvider `
                -ProviderNamespace $providerName `
                -ErrorAction Stop

            if ($provider.RegistrationState -ne 'Registered') {
                throw (
                    "Azure resource provider $providerName registration state is " +
                    "$($provider.RegistrationState); expected Registered."
                )
            }

            $providerResults.Add(
                [pscustomobject]@{
                    Provider = $provider.ProviderNamespace
                    RegistrationState = $provider.RegistrationState
                }
            )
        }

        return [pscustomobject]@{
            Passed         = $true
            Check          = 'Test-ResourceProviders'
            Providers      = $providerResults.ToArray()
            Summary        = (
                "$($providerResults.Count) required Azure resource provider(s) " +
                'are registered.'
            )
            ValidatedAt    = [datetime]::UtcNow.ToString('o')
        }
    }

    'Test-ResourceGroup' {
        if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
            throw 'azure.resource_group is required.'
        }

        $resourceGroup = Get-AzResourceGroup `
            -Name $resourceGroupName `
            -ErrorAction Stop

        return [pscustomobject]@{
            Passed            = $true
            Check             = 'Test-ResourceGroup'
            ResourceGroupName = $resourceGroup.ResourceGroupName
            Location          = $resourceGroup.Location
            ProvisioningState = $resourceGroup.ProvisioningState
            Summary           = (
                "Azure resource group $($resourceGroup.ResourceGroupName) " +
                'was found and is readable.'
            )
            ValidatedAt       = [datetime]::UtcNow.ToString('o')
        }
    }

    default {
        throw "Unsupported Stage 1.3 Azure validation operation: $operation"
    }
}