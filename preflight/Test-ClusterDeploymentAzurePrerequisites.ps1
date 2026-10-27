#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ClusterDeployment.Common.psm1" -Force

$config = $Context.Config

$azure = Get-ClusterDeploymentValue `
    -Object $config `
    -Name 'azure'

$clusterDeployment = Get-ClusterDeploymentSettings `
    -Config $config

$deploymentAzure = Get-ClusterDeploymentValue `
    -Object $clusterDeployment `
    -Name 'azure'

$cloud = [string](
    Get-ClusterDeploymentValue `
        -Object $azure `
        -Name 'cloud'
)

$subscriptionId = [string](
    Get-ClusterDeploymentValue `
        -Object $azure `
        -Name 'subscription_id'
)

$resourceGroup = [string](
    Get-ClusterDeploymentValue `
        -Object $azure `
        -Name 'resource_group'
)

$location = [string](
    Get-ClusterDeploymentValue `
        -Object $azure `
        -Name 'location'
)

if ($cloud -ne 'AzureUSGovernment') {
    throw "Phase 2.1 requires AzureUSGovernment. Resolved cloud: $cloud"
}

if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw 'azure.subscription_id is required.'
}

if ([string]::IsNullOrWhiteSpace($resourceGroup)) {
    throw 'azure.resource_group is required.'
}

if ([string]::IsNullOrWhiteSpace($location)) {
    throw 'azure.location is required.'
}

if (
    [string](
        Get-ClusterDeploymentValue `
            -Object $deploymentAzure `
            -Name 'subscription_id'
    ) -ne $subscriptionId
) {
    throw 'cluster_deployment.azure.subscription_id does not match azure.subscription_id.'
}

if (
    [string](
        Get-ClusterDeploymentValue `
            -Object $deploymentAzure `
            -Name 'resource_group'
    ) -ne $resourceGroup
) {
    throw 'cluster_deployment.azure.resource_group does not match azure.resource_group.'
}

if (
    [string](
        Get-ClusterDeploymentValue `
            -Object $deploymentAzure `
            -Name 'location'
    ) -ne $location
) {
    throw 'cluster_deployment.azure.location does not match azure.location.'
}

return New-ClusterDeploymentResult `
    -Check 'Test-ClusterDeploymentAzurePrerequisites' `
    -Passed $true `
    -Summary (
        "Azure Government cluster deployment prerequisites are internally " +
        'consistent with the resolved site configuration.'
    ) `
    -AdditionalProperties @{
        Cloud = $cloud
        SubscriptionId = $subscriptionId
        ResourceGroup = $resourceGroup
        Location = $location
    }