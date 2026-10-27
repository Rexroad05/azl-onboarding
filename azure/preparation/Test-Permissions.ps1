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
$account = Invoke-FactoryAz @(
    'account',
    'show'
)

# Read-only validation: confirm the current Azure identity can query
# the target resource group and list resources within it.
$resourceGroup = Invoke-FactoryAz @(
    'group',
    'show',
    '--name',
    $config.azure.resource_group
)

$resources = Invoke-FactoryAz @(
    'resource',
    'list',
    '--resource-group',
    $config.azure.resource_group
)

return [pscustomobject]@{
    Passed           = $true
    Check            = 'Test-Permissions'
    AccountName      = $account.user.name
    SubscriptionId   = $account.id
    ResourceGroup    = $resourceGroup.name
    ResourceCount    = @($resources).Count
    PermissionLevel  = 'Read/query access validated. Deployment permissions are validated in Phase 2.'
    ValidatedAt      = [datetime]::UtcNow.ToString('o')
}