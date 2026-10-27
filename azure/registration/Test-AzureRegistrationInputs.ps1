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

function Get-ArcValue {
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

$azure = Get-ArcValue `
    -Object $config `
    -Name 'azure'

if ($null -eq $azure) {
    throw 'Resolved configuration does not contain azure settings.'
}

$authentication = Get-ArcValue `
    -Object $azure `
    -Name 'authentication'

$arcRegistration = Get-ArcValue `
    -Object $azure `
    -Name 'arc_registration'

$arcAgent = Get-ArcValue `
    -Object $azure `
    -Name 'arc_agent'

if ($null -eq $authentication) {
    throw 'azure.authentication configuration is required.'
}

if ($null -eq $arcRegistration) {
    throw 'azure.arc_registration configuration is required.'
}

if ($null -eq $arcAgent) {
    throw 'azure.arc_agent configuration is required.'
}

$cloudName = [string](
    Get-ArcValue -Object $azure -Name 'cloud'
)

$tenantId = [string](
    Get-ArcValue -Object $azure -Name 'tenant_id'
)

$subscriptionId = [string](
    Get-ArcValue -Object $azure -Name 'subscription_id'
)

$resourceGroup = [string](
    Get-ArcValue -Object $azure -Name 'resource_group'
)

$location = [string](
    Get-ArcValue -Object $azure -Name 'location'
)

$authenticationMethod = [string](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'authentication_method'
)

$requiredAccountType = [string](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'required_account_type'
)

$mode = [string](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'mode'
)

$allowRegistration = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'allow_registration'
)

$allowDeviceCodeRegistration = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'allow_device_code_registration'
)

$requireInteractiveUser = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'require_interactive_user'
)

$requireConnectedMachineAgent = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'require_connected_machine_agent'
)

$requireExistingClusterBlock = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'require_existing_cluster_block'
)

$requireExistingArcRegistrationBlock = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'require_existing_arc_registration_block'
)

$useAzureCliCredentialsOnNode = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'use_azure_cli_credentials_on_node'
)

$agentRequired = [bool](
    Get-ArcValue `
        -Object $arcAgent `
        -Name 'required'
)

$agentInstallationMode = [string](
    Get-ArcValue `
        -Object $arcAgent `
        -Name 'installation_mode'
)

if ($cloudName -ne 'AzureUSGovernment') {
    throw (
        "Phase 1.4 requires AzureUSGovernment. Resolved cloud: $cloudName"
    )
}

foreach ($requiredValue in @(
        @{
            Path = 'azure.tenant_id'
            Value = $tenantId
        },
        @{
            Path = 'azure.subscription_id'
            Value = $subscriptionId
        },
        @{
            Path = 'azure.resource_group'
            Value = $resourceGroup
        },
        @{
            Path = 'azure.location'
            Value = $location
        }
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredValue.Value)) {
        throw "$($requiredValue.Path) is required."
    }
}

if ($mode -ne 'InteractiveDeviceCode') {
    throw (
        "Unsupported azure.arc_registration.mode: $mode. " +
        'InteractiveDeviceCode is required for live Arc registration.'
    )
}

if (-not $allowRegistration -or -not $allowDeviceCodeRegistration) {
    throw (
        'azure.arc_registration.allow_registration and ' +
        'allow_device_code_registration must both be true.'
    )
}

if ($authenticationMethod -ne 'DeviceCode') {
    throw (
        "Unsupported azure.arc_registration.authentication_method: " +
        "$authenticationMethod. DeviceCode is required."
    )
}

if ($requiredAccountType -ne 'user') {
    throw (
        "Unsupported azure.arc_registration.required_account_type: " +
        "$requiredAccountType. user is required."
    )
}

if (-not $requireInteractiveUser) {
    throw (
        'azure.arc_registration.require_interactive_user must be true.'
    )
}

if ($useAzureCliCredentialsOnNode) {
    throw (
        'azure.arc_registration.use_azure_cli_credentials_on_node must remain false.'
    )
}

if (-not $agentRequired) {
    throw 'azure.arc_agent.required must be true for Stage 1.4.'
}

if ($agentInstallationMode -notin @(
        'FactoryManaged',
        'ExternallyManaged'
    )) {
    throw (
        "Unsupported azure.arc_agent.installation_mode: " +
        "$agentInstallationMode."
    )
}

$azContext = Get-AzContext

if ($null -eq $azContext) {
    throw (
        'Azure PowerShell context is unavailable. Azure Government ' +
        'authentication must complete before Arc readiness validation.'
    )
}

if ($azContext.Environment.Name -ne 'AzureUSGovernment') {
    throw (
        'Azure environment mismatch. Expected AzureUSGovernment; current ' +
        "environment is $($azContext.Environment.Name)."
    )
}

if ($azContext.Tenant.Id -ne $tenantId) {
    throw (
        "Azure tenant mismatch. Expected $tenantId; current tenant is " +
        "$($azContext.Tenant.Id)."
    )
}

if ($azContext.Subscription.Id -ne $subscriptionId) {
    throw (
        "Azure subscription mismatch. Expected $subscriptionId; current " +
        "subscription is $($azContext.Subscription.Id)."
    )
}

$subscription = Get-AzSubscription `
    -SubscriptionId $subscriptionId `
    -TenantId $tenantId `
    -ErrorAction Stop

if ($subscription.State -ne 'Enabled') {
    throw (
        "Azure subscription is not enabled. Current state: $($subscription.State)"
    )
}

$resourceGroupState = Get-AzResourceGroup `
    -Name $resourceGroup `
    -ErrorAction Stop

return [pscustomobject]@{
    Passed                              = $true
    Check                               = 'Test-AzureRegistrationInputs'
    Cloud                               = $azContext.Environment.Name
    TenantId                            = $azContext.Tenant.Id
    SubscriptionId                      = $azContext.Subscription.Id
    ResourceGroup                       = $resourceGroupState.ResourceGroupName
    Location                            = $location
    AccountName                         = $azContext.Account.Id
    AccountType                         = $azContext.Account.Type
    ArcRegistrationMode                 = $mode
    AllowRegistration                   = $allowRegistration
    AuthenticationMethod                = $authenticationMethod
    RequireConnectedMachineAgent        = $requireConnectedMachineAgent
    RequireExistingClusterBlock         = $requireExistingClusterBlock
    RequireExistingArcRegistrationBlock = $requireExistingArcRegistrationBlock
    AgentInstallationMode               = $agentInstallationMode
    Summary                             = (
        'Azure Government interactive-user Arc registration inputs are valid.'
    )
    ValidatedAt                         = [datetime]::UtcNow.ToString('o')
}