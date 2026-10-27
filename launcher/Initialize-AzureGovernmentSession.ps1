#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResolvedConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

if (-not (Test-Path -LiteralPath $ResolvedConfigPath -PathType Leaf)) {
    throw "Resolved configuration does not exist: $ResolvedConfigPath"
}

$config = Get-Content `
    -LiteralPath $ResolvedConfigPath `
    -Raw |
    ConvertFrom-Yaml `
    -Ordered

$azure = $config.azure

if ($null -eq $azure) {
    throw 'Resolved configuration does not contain azure settings.'
}

$cloudName = [string]$azure.cloud
$tenantId = [string]$azure.tenant_id
$subscriptionId = [string]$azure.subscription_id

if ([string]::IsNullOrWhiteSpace($cloudName)) {
    throw 'azure.cloud is required.'
}

if ($cloudName -ne 'AzureUSGovernment') {
    throw (
        "Stage 1.3 requires AzureUSGovernment. Resolved azure.cloud is $cloudName."
    )
}

if ([string]::IsNullOrWhiteSpace($tenantId)) {
    throw 'azure.tenant_id is required.'
}

if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw 'azure.subscription_id is required.'
}

if ($null -ne (Get-Command -Name az -ErrorAction SilentlyContinue)) {
    Write-Host (
        "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
        'Configuring Azure CLI cloud: AzureUSGovernment'
    ) -ForegroundColor Cyan

    & az cloud set `
        --name AzureUSGovernment `
        --only-show-errors `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to set Azure CLI cloud to AzureUSGovernment.'
    }

    $azureCliCloud = @(
        & az cloud show `
            --only-show-errors `
            --output json
    ) -join "`n" |
        ConvertFrom-Json -AsHashtable

    if ($azureCliCloud.name -ne 'AzureUSGovernment') {
        throw (
            'Azure CLI cloud validation failed. Expected AzureUSGovernment; ' +
            "received $($azureCliCloud.name)."
        )
    }
}

Write-Host (
    "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
    'Azure Government PowerShell device authentication is required.'
) -ForegroundColor Yellow

Write-Host (
    'Complete device authentication using an approved Azure Government account ' +
    "authorized in tenant $tenantId."
) -ForegroundColor Yellow

Connect-AzAccount `
    -Environment AzureUSGovernment `
    -Tenant $tenantId `
    -UseDeviceAuthentication `
    -SkipContextPopulation |
    Out-Null

Set-AzContext `
    -Subscription $subscriptionId `
    -Tenant $tenantId |
    Out-Null

$azContext = Get-AzContext

if ($null -eq $azContext) {
    throw 'Azure PowerShell authentication did not establish an Az context.'
}

if ($azContext.Environment.Name -ne 'AzureUSGovernment') {
    throw (
        'Azure PowerShell cloud mismatch after authentication. Expected ' +
        "AzureUSGovernment; current environment is $($azContext.Environment.Name)."
    )
}

if ($azContext.Tenant.Id -ne $tenantId) {
    throw (
        "Azure PowerShell tenant mismatch after authentication. Expected " +
        "$tenantId; current tenant is $($azContext.Tenant.Id)."
    )
}

if ($azContext.Subscription.Id -ne $subscriptionId) {
    throw (
        "Azure PowerShell subscription mismatch after authentication. Expected " +
        "$subscriptionId; current subscription is $($azContext.Subscription.Id)."
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

return [pscustomobject]@{
    Passed         = $true
    Cloud          = $azContext.Environment.Name
    TenantId       = $azContext.Tenant.Id
    SubscriptionId = $azContext.Subscription.Id
    AccountName    = $azContext.Account.Id
    AccountType    = $azContext.Account.Type
    ValidatedAt    = [datetime]::UtcNow.ToString('o')
}