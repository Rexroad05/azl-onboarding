#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ClusterDeployment.Common.psm1" -Force
Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$clusterDeployment = Get-ClusterDeploymentSettings `
    -Config $Context.Config

$safety = Get-ClusterDeploymentValue `
    -Object $clusterDeployment `
    -Name 'safety'

$blockExistingCluster = [bool](
    Get-ClusterDeploymentValue `
        -Object $safety `
        -Name 'block_existing_cluster'
)

$blockExistingRegistration = [bool](
    Get-ClusterDeploymentValue `
        -Object $safety `
        -Name 'block_existing_registration'
)

$blockExistingAzureResource = [bool](
    Get-ClusterDeploymentValue `
        -Object $safety `
        -Name 'block_existing_azure_resource'
)

$node = Get-ClusterDeploymentValue `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Test-ClusterDeploymentSafetyState requires a node-scoped context.'
}

$nodeName = [string](
    Get-ClusterDeploymentValue `
        -Object $node `
        -Name 'name'
)

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-ClusterDeploymentSafetyState' `
    -ScriptBlock {
        $cluster = Get-Cluster -ErrorAction SilentlyContinue

        $registrationStatus = $null
        $azureResourceName = $null

        $getAzureStackHciCommand = Get-Command `
            -Name Get-AzureStackHci `
            -ErrorAction SilentlyContinue

        if ($null -ne $getAzureStackHciCommand) {
            $azureStackHci = Get-AzureStackHci `
                -ErrorAction SilentlyContinue

            if ($null -ne $azureStackHci) {
                $registrationStatus = [string]$azureStackHci.RegistrationStatus
                $azureResourceName = [string]$azureStackHci.AzureResourceName
            }
        }

        [pscustomobject]@{
            Clustered = ($null -ne $cluster)
            ClusterName = if ($null -ne $cluster) {
                [string]$cluster.Name
            }
            else {
                $null
            }
            RegistrationStatus = $registrationStatus
            AzureResourceName = $azureResourceName
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

if ($blockExistingCluster -and $data.Clustered) {
    return New-ClusterDeploymentResult `
        -Check 'Test-ClusterDeploymentSafetyState' `
        -Passed $false `
        -Summary (
            "Node $nodeName is already clustered as $($data.ClusterName). " +
            'Phase 2 deployment safety state blocks execution.'
        ) `
        -AdditionalProperties @{
            Node = $nodeName
            Clustered = $true
            ClusterName = $data.ClusterName
        }
}

if (
    $blockExistingRegistration -and
    $data.RegistrationStatus -eq 'Registered'
) {
    return New-ClusterDeploymentResult `
        -Check 'Test-ClusterDeploymentSafetyState' `
        -Passed $false `
        -Summary (
            "Node $nodeName is already Azure registered. " +
            'Phase 2 deployment safety state blocks execution.'
        ) `
        -AdditionalProperties @{
            Node = $nodeName
            RegistrationStatus = $data.RegistrationStatus
        }
}

if (
    $blockExistingAzureResource -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$data.AzureResourceName
    )
) {
    return New-ClusterDeploymentResult `
        -Check 'Test-ClusterDeploymentSafetyState' `
        -Passed $false `
        -Summary (
            "Node $nodeName already has Azure resource $($data.AzureResourceName). " +
            'Phase 2 deployment safety state blocks execution.'
        ) `
        -AdditionalProperties @{
            Node = $nodeName
            AzureResourceName = $data.AzureResourceName
        }
}

return New-ClusterDeploymentResult `
    -Check 'Test-ClusterDeploymentSafetyState' `
    -Passed $true `
    -Summary (
        "Node $nodeName is unclustered, unregistered, and safe for future " +
        'Phase 2 deployment readiness validation.'
    ) `
    -AdditionalProperties @{
        Node = $nodeName
        Clustered = $data.Clustered
        RegistrationStatus = $data.RegistrationStatus
        AzureResourceName = $data.AzureResourceName
    }