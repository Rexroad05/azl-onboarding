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

$cluster = Get-ClusterDeploymentValue `
    -Object $config `
    -Name 'cluster'

$clusterDeployment = Get-ClusterDeploymentSettings `
    -Config $config

$deploymentClusterName = [string](
    Get-ClusterDeploymentValue `
        -Object $clusterDeployment `
        -Name 'cluster_name'
)

$clusterName = [string](
    Get-ClusterDeploymentValue `
        -Object $cluster `
        -Name 'name'
)

$nodes = @(
    Get-ClusterDeploymentValue `
        -Object $config `
        -Name 'nodes'
)

if ($clusterName -notmatch '^[A-Za-z0-9-]{1,63}$') {
    throw "cluster.name is invalid: $clusterName"
}

if (
    -not [string]::IsNullOrWhiteSpace($deploymentClusterName) -and
    $deploymentClusterName -ne $clusterName
) {
    throw (
        "cluster_deployment.cluster_name $deploymentClusterName does not match " +
        "cluster.name $clusterName."
    )
}

if ($nodes.Count -ne 2) {
    throw "Phase 2.1 requires exactly two nodes. Found: $($nodes.Count)."
}

$nodeNames = @(
    $nodes |
        ForEach-Object {
            [string](
                Get-ClusterDeploymentValue `
                    -Object $_ `
                    -Name 'name'
            )
        }
)

if (@($nodeNames | Select-Object -Unique).Count -ne $nodeNames.Count) {
    throw 'Node names must be unique.'
}

foreach ($nodeName in $nodeNames) {
    if ($nodeName -notmatch '^[A-Za-z0-9-]{1,63}$') {
        throw "Node name is invalid: $nodeName"
    }
}

return New-ClusterDeploymentResult `
    -Check 'Test-ClusterDeploymentNaming' `
    -Passed $true `
    -Summary (
        "Cluster name $clusterName and $($nodeNames.Count) node names " +
        'meet Phase 2.1 naming requirements.'
    ) `
    -AdditionalProperties @{
        ClusterName = $clusterName
        NodeNames   = $nodeNames
    }