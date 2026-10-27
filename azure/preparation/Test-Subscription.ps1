#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\..\controller\Factory.psm1" -Force

$subscription = Invoke-FactoryAz @(
    'account',
    'show'
)

if ($subscription.id -ne $Context.Config.azure.subscription_id) {
    throw 'Current Azure subscription does not match the resolved configuration.'
}

if ($subscription.state -ne 'Enabled') {
    throw "Azure subscription is not Enabled. Current state: $($subscription.state)"
}

return [pscustomobject]@{
    Passed         = $true
    Check          = 'Test-Subscription'
    SubscriptionId = $subscription.id
    Subscription   = $subscription.name
    State          = $subscription.state
    TenantId       = $subscription.tenantId
    ValidatedAt    = [datetime]::UtcNow.ToString('o')
}