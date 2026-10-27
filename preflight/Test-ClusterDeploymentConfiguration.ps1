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

$clusterDeployment = Get-ClusterDeploymentSettings `
    -Config $config

$readiness = Test-ClusterDeploymentReadinessMode `
    -ClusterDeployment $clusterDeployment

$cluster = Get-ClusterDeploymentValue `
    -Object $config `
    -Name 'cluster'

$azure = Get-ClusterDeploymentValue `
    -Object $config `
    -Name 'azure'

$clusterName = [string](
    Get-ClusterDeploymentValue `
        -Object $cluster `
        -Name 'name'
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

if ([string]::IsNullOrWhiteSpace($clusterName)) {
    throw 'cluster.name is required for Phase 2.1 validation.'
}

if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw 'azure.subscription_id is required for Phase 2.1 validation.'
}

if ([string]::IsNullOrWhiteSpace($resourceGroup)) {
    throw 'azure.resource_group is required for Phase 2.1 validation.'
}

if ([string]::IsNullOrWhiteSpace($location)) {
    throw 'azure.location is required for Phase 2.1 validation.'
}

return New-ClusterDeploymentResult `
    -Check 'Test-ClusterDeploymentConfiguration' `
    -Passed $true `
    -Summary (
        "Phase 2 readiness-only configuration is valid for cluster " +
        "$clusterName."
    ) `
    -AdditionalProperties @{
        ClusterName             = $clusterName
        SubscriptionId          = $subscriptionId
        ResourceGroup           = $resourceGroup
        Location                = $location
        Mode                    = $readiness.Mode
        AllowClusterCreation    = $readiness.AllowClusterCreation
        AllowResourceDeployment = $readiness.AllowResourceDeployment
        ExecutionMethod         = $readiness.ExecutionMethod
    }