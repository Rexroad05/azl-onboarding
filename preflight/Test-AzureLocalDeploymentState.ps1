#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$node = Get-ManagementPlaneValue `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Test-AzureLocalDeploymentState requires a node-scoped context.'
}

$nodeName = [string](
    Get-ManagementPlaneValue `
        -Object $node `
        -Name 'name'
)

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-AzureLocalDeploymentState' `
    -ScriptBlock {
        $cluster = Get-Cluster -ErrorAction SilentlyContinue

        $registrationStatus = $null
        $azureResourceName = $null
        $connectionStatus = $null

        $azureStackHciCommand = Get-Command `
            -Name Get-AzureStackHci `
            -ErrorAction SilentlyContinue

        if ($null -ne $azureStackHciCommand) {
            $azureStackHci = Get-AzureStackHci `
                -ErrorAction SilentlyContinue

            if ($null -ne $azureStackHci) {
                $registrationStatus = [string]$azureStackHci.RegistrationStatus
                $azureResourceName = [string]$azureStackHci.AzureResourceName
                $connectionStatus = [string]$azureStackHci.ConnectionStatus
            }
        }

        $nonPrimordialStoragePools = @(
            Get-StoragePool `
                -ErrorAction Stop |
                Where-Object {
                    $_.IsPrimordial -eq $false
                } |
                Select-Object `
                    FriendlyName,
                    HealthStatus,
                    OperationalStatus,
                    Size,
                    AllocatedSize
        )

        $virtualDisks = @(
            Get-VirtualDisk `
                -ErrorAction SilentlyContinue |
                Select-Object `
                    FriendlyName,
                    HealthStatus,
                    OperationalStatus,
                    Size,
                    FootprintOnPool
        )

        [pscustomobject]@{
            ComputerName               = $env:COMPUTERNAME
            Clustered                  = ($null -ne $cluster)
            ClusterName                = if ($null -ne $cluster) {
                [string]$cluster.Name
            }
            else {
                $null
            }
            RegistrationStatus         = $registrationStatus
            AzureResourceName          = $azureResourceName
            ConnectionStatus           = $connectionStatus
            NonPrimordialStoragePools  = $nonPrimordialStoragePools
            VirtualDisks               = $virtualDisks
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

$blockingReasons = [System.Collections.Generic.List[string]]::new()

if ($data.Clustered) {
    [void]$blockingReasons.Add(
        "Node is already clustered: $($data.ClusterName)"
    )
}

if ($data.RegistrationStatus -eq 'Registered') {
    [void]$blockingReasons.Add(
        "Node is already Azure registered: $($data.AzureResourceName)"
    )
}

if (@($data.NonPrimordialStoragePools).Count -gt 0) {
    [void]$blockingReasons.Add(
        'Node contains one or more non-primordial storage pools: ' +
        (($data.NonPrimordialStoragePools.FriendlyName) -join ', ')
    )
}

if (@($data.VirtualDisks).Count -gt 0) {
    [void]$blockingReasons.Add(
        'Node contains one or more existing virtual disks: ' +
        (($data.VirtualDisks.FriendlyName) -join ', ')
    )
}

if ($blockingReasons.Count -gt 0) {
    throw (
        "Azure Local deployment safety state blocks Apply for node ${nodeName}:`n - " +
        ($blockingReasons -join "`n - ")
    )
}

return [pscustomobject]@{
    Passed                    = $true
    Check                     = 'Test-AzureLocalDeploymentState'
    Node                      = $result.Node
    ManagementIp              = $result.ManagementIp
    Clustered                 = $data.Clustered
    ClusterName               = $data.ClusterName
    RegistrationStatus        = $data.RegistrationStatus
    AzureResourceName         = $data.AzureResourceName
    ConnectionStatus          = $data.ConnectionStatus
    NonPrimordialStoragePools = $data.NonPrimordialStoragePools
    VirtualDisks              = $data.VirtualDisks
    Summary                   = (
        "Node $nodeName is unclustered, unregistered, contains no non-primordial " +
        'storage pools, and contains no virtual disks.'
    )
    ValidatedAt               = [datetime]::UtcNow.ToString('o')
}