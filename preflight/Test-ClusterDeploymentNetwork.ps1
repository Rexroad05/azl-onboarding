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

$network = Get-ClusterDeploymentValue `
    -Object $config `
    -Name 'network'

$management = Get-ClusterDeploymentValue `
    -Object $network `
    -Name 'management'

$storage = Get-ClusterDeploymentValue `
    -Object $network `
    -Name 'storage'

$nodes = @(
    Get-ClusterDeploymentValue `
        -Object $config `
        -Name 'nodes'
)

$managementSubnet = [string](
    Get-ClusterDeploymentValue `
        -Object $management `
        -Name 'subnet'
)

$managementGateway = [string](
    Get-ClusterDeploymentValue `
        -Object $management `
        -Name 'gateway'
)

$managementPrefix = Get-ClusterDeploymentValue `
    -Object $management `
    -Name 'prefix'

$managementVlan = Get-ClusterDeploymentValue `
    -Object $management `
    -Name 'vlan_id'

if ($managementSubnet -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
    throw "network.management.subnet is invalid: $managementSubnet"
}

if ($null -eq $managementPrefix -or [int]$managementPrefix -lt 1 -or [int]$managementPrefix -gt 32) {
    throw 'network.management.prefix must be between 1 and 32.'
}

if ($null -eq $managementVlan -or [int]$managementVlan -lt 1 -or [int]$managementVlan -gt 4094) {
    throw 'network.management.vlan_id must be between 1 and 4094.'
}

Test-ClusterDeploymentIPv4Address `
    -Address $managementGateway `
    -Label 'network.management.gateway' |
    Out-Null

$storageNetworks = @(
    Get-ClusterDeploymentValue `
        -Object $storage `
        -Name 'networks'
)

if ($storageNetworks.Count -ne 2) {
    throw "Phase 2.1 requires exactly two storage networks. Found: $($storageNetworks.Count)."
}

$managementIps = [System.Collections.Generic.List[string]]::new()

foreach ($node in $nodes) {
    $nodeName = [string](
        Get-ClusterDeploymentValue `
            -Object $node `
            -Name 'name'
    )

    $nodeManagement = Get-ClusterDeploymentValue `
        -Object $node `
        -Name 'management'

    $nodeManagementIp = [string](
        Get-ClusterDeploymentValue `
            -Object $nodeManagement `
            -Name 'ip'
    )

    Test-ClusterDeploymentIPv4Address `
        -Address $nodeManagementIp `
        -Label "$nodeName management IP" |
        Out-Null

    $managementIps.Add($nodeManagementIp)
}

if (@($managementIps | Select-Object -Unique).Count -ne $managementIps.Count) {
    throw 'Node management IP addresses must be unique.'
}

return New-ClusterDeploymentResult `
    -Check 'Test-ClusterDeploymentNetwork' `
    -Passed $true `
    -Summary (
        "Management VLAN $managementVlan, management subnet $managementSubnet, " +
        "and $($storageNetworks.Count) storage network definitions are valid."
    ) `
    -AdditionalProperties @{
        ManagementSubnet = $managementSubnet
        ManagementGateway = $managementGateway
        ManagementPrefix = [int]$managementPrefix
        ManagementVlan = [int]$managementVlan
        StorageNetworks = $storageNetworks
        ManagementIps = $managementIps.ToArray()
    }