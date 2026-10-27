#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\..\controller\Factory.psm1" -Force

$config = $Context.Config

$cloud = Invoke-FactoryAz @(
    'cloud',
    'show'
)

if ($cloud.name -ne $config.azure.cloud) {
    throw (
        "Azure cloud mismatch. Expected $($config.azure.cloud); " +
        "current cloud is $($cloud.name)."
    )
}

$account = Invoke-FactoryAz @(
    'account',
    'show'
)

if ($account.id -ne $config.azure.subscription_id) {
    throw (
        "Azure subscription mismatch. Expected $($config.azure.subscription_id); " +
        "current subscription is $($account.id)."
    )
}

if ($account.tenantId -ne $config.azure.tenant_id) {
    throw (
        "Azure tenant mismatch. Expected $($config.azure.tenant_id); " +
        "current tenant is $($account.tenantId)."
    )
}

return [pscustomobject]@{
    Passed         = $true
    Check          = 'Connect-Azure'
    AzureCloud     = $cloud.name
    SubscriptionId = $account.id
    TenantId       = $account.tenantId
    AccountName    = $account.user.name
    ValidatedAt    = [datetime]::UtcNow.ToString('o')
}