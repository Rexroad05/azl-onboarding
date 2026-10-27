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

$network = Get-ClusterDeploymentValue `
    -Object $config `
    -Name 'network'

$storage = Get-ClusterDeploymentValue `
    -Object $network `
    -Name 'storage'

$storageNetworks = @(
    Get-ClusterDeploymentValue `
        -Object $storage `
        -Name 'networks'
)

$deploymentStorage = Get-ClusterDeploymentValue `
    -Object $clusterDeployment `
    -Name 'storage'

$requiredNetworks = @(
    Get-ClusterDeploymentValue `
        -Object $deploymentStorage `
        -Name 'required_networks'
)

$nodes = @(
    Get-ClusterDeploymentValue `
        -Object $config `
        -Name 'nodes'
)

if ($storageNetworks.Count -ne 2) {
    throw "Expected exactly two network.storage.networks entries. Found: $($storageNetworks.Count)."
}

if ($requiredNetworks.Count -ne 2) {
    throw (
        "Expected exactly two cluster_deployment.storage.required_networks entries. " +
        "Found: $($requiredNetworks.Count)."
    )
}

foreach ($requiredNetwork in $requiredNetworks) {
    $matchingNetwork = @(
        $storageNetworks |
            Where-Object {
                [string](
                    Get-ClusterDeploymentValue `
                        -Object $_ `
                        -Name 'name'
                ) -eq [string]$requiredNetwork
            }
    )

    if ($matchingNetwork.Count -ne 1) {
        throw "Required storage network is missing or duplicated: $requiredNetwork"
    }
}

foreach ($storageNetwork in $storageNetworks) {
    $networkName = [string](
        Get-ClusterDeploymentValue `
            -Object $storageNetwork `
            -Name 'name'
    )

    $adapterName = [string](
        Get-ClusterDeploymentValue `
            -Object $storageNetwork `
            -Name 'adapter'
    )

    $prefix = Get-ClusterDeploymentValue `
        -Object $storageNetwork `
        -Name 'prefix'

    $vlanId = Get-ClusterDeploymentValue `
        -Object $storageNetwork `
        -Name 'vlan_id'

    if ([string]::IsNullOrWhiteSpace($adapterName)) {
        throw "Storage network $networkName has no adapter."
    }

    if ($null -eq $prefix -or [int]$prefix -lt 1 -or [int]$prefix -gt 32) {
        throw "Storage network $networkName has invalid prefix."
    }

    if ($null -eq $vlanId -or [int]$vlanId -lt 1 -or [int]$vlanId -gt 4094) {
        throw "Storage network $networkName has invalid VLAN."
    }
}

foreach ($node in $nodes) {
    $nodeName = [string](
        Get-ClusterDeploymentValue `
            -Object $node `
            -Name 'name'
    )

    $nodeStorage = @(
        Get-ClusterDeploymentValue `
            -Object $node `
            -Name 'storage'
    )

    if ($nodeStorage.Count -ne 2) {
        throw "Node $nodeName must have exactly two storage address entries."
    }

    foreach ($requiredNetwork in $requiredNetworks) {
        $entry = @(
            $nodeStorage |
                Where-Object {
                    [string](
                        Get-ClusterDeploymentValue `
                            -Object $_ `
                            -Name 'network'
                    ) -eq [string]$requiredNetwork
                }
        )

        if ($entry.Count -ne 1) {
            throw (
                "Node $nodeName has missing or duplicate storage configuration " +
                "for $requiredNetwork."
            )
        }

        $storageIp = [string](
            Get-ClusterDeploymentValue `
                -Object $entry[0] `
                -Name 'ip_address'
        )

        Test-ClusterDeploymentIPv4Address `
            -Address $storageIp `
            -Label "$nodeName $requiredNetwork storage IP" |
            Out-Null
    }
}

return New-ClusterDeploymentResult `
    -Check 'Test-ClusterDeploymentStorage' `
    -Passed $true `
    -Summary (
        "Storage network definitions, node storage addressing, RDMA, SR-IOV, " +
        'and Storage Spaces Direct readiness inputs are valid.'
    ) `
    -AdditionalProperties @{
        RequiredStorageNetworks = $requiredNetworks
        RequireRdma = [bool](
            Get-ClusterDeploymentValue `
                -Object $deploymentStorage `
                -Name 'require_rdma'
        )
        RequireSriov = [bool](
            Get-ClusterDeploymentValue `
                -Object $deploymentStorage `
                -Name 'require_sriov'
        )
        RequireStorageSpacesDirect = [bool](
            Get-ClusterDeploymentValue `
                -Object $deploymentStorage `
                -Name 'require_storage_spaces_direct'
        )
    }