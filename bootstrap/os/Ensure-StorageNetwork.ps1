#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\HcnEnsure.Common.psm1" -Force

function Get-Value {
    param([object]$Object, [string]$Name)
    return Get-HcnEnsureValue -Object $Object -Name $Name
}

function Test-ApprovedOperation {
    param([hashtable]$Context, [string]$ApprovalKey)

    $approved = Get-Value -Object $Context.State -Name 'approvedOperations'

    if ($null -eq $approved) {
        return $false
    }

    if ($approved -is [System.Collections.IDictionary]) {
        return $approved.Contains($ApprovalKey)
    }

    return ($null -ne $approved.PSObject.Properties[$ApprovalKey])
}

$node = Get-Value -Object $Context -Name 'Node'

if ($null -eq $node) {
    throw 'Ensure-StorageNetwork requires a node-scoped execution context.'
}

$config = Get-Value -Object $Context -Name 'Config'
$network = Get-Value -Object $config -Name 'network'
$storage = Get-Value -Object $network -Name 'storage'
$storageIntent = [string](
    Get-Value `
        -Object $storage `
        -Name 'intent'
)

if ($storageIntent -eq 'None') {
    return New-HcnEnsureResult `
        -Check 'Ensure-StorageNetwork' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            'Storage network configuration is not applicable to the protected ' +
            'single-server storage-intent-none profile.'
        ) `
        -AdditionalProperties @{
            Node = [string](Get-Value -Object $Context.Node -Name 'name')
            StorageIntent = $storageIntent
            Networks = @()
        }
}
$storageNetworks = @(Get-Value -Object $storage -Name 'networks')
$nodeStorage = @(Get-Value -Object $node -Name 'storage')
$nodeName = [string](Get-Value -Object $node -Name 'name')

if ($storageNetworks.Count -lt 1 -or $nodeStorage.Count -lt 1) {
    throw "Storage network configuration is incomplete for node $nodeName."
}

$desiredNetworks = foreach ($siteStorageNetwork in $storageNetworks) {
    $storageNetworkName = [string](Get-Value -Object $siteStorageNetwork -Name 'name')

    $nodeStorageEntry = @(
        $nodeStorage |
            Where-Object {
                [string](Get-Value -Object $_ -Name 'network') -eq $storageNetworkName
            }
    ) | Select-Object -First 1

    if ($null -eq $nodeStorageEntry) {
        throw "Node $nodeName has no storage address definition for $storageNetworkName."
    }

    [pscustomobject]@{
        Name        = $storageNetworkName
        AdapterName = [string](Get-Value -Object $siteStorageNetwork -Name 'adapter')
        IPAddress   = [string](Get-Value -Object $nodeStorageEntry -Name 'ip_address')
        Prefix      = [int](Get-Value -Object $nodeStorageEntry -Name 'prefix')
        VlanId      = [int](Get-Value -Object $siteStorageNetwork -Name 'vlan_id')
    }
}

$approvalKey = "$($Context.PhaseId).$($Context.StageId).$nodeName.$($Context.Operation)"

$inspectionResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param($DesiredNetworks)

        $cluster = Get-Cluster -ErrorAction SilentlyContinue
        $results = foreach ($desired in $DesiredNetworks) {
            $adapter = Get-NetAdapter -Name $desired.AdapterName -ErrorAction Stop

            $addresses = @(
                Get-NetIPAddress `
                    -InterfaceIndex $adapter.ifIndex `
                    -AddressFamily IPv4 `
                    -ErrorAction SilentlyContinue
            )

            [pscustomobject]@{
                Name        = $desired.Name
                AdapterName = $adapter.Name
                InterfaceIndex = $adapter.ifIndex
                IPAddress   = $desired.IPAddress
                Prefix      = $desired.Prefix
                AddressPresent = @(
                    $addresses |
                        Where-Object {
                            $_.IPAddress -eq $desired.IPAddress -and
                            $_.PrefixLength -eq $desired.Prefix
                        }
                ).Count -gt 0
            }
        }

        [pscustomobject]@{
            ExistingCluster = ($null -ne $cluster)
            Networks        = $results
        }
        } `
        -ArgumentList @(, $desiredNetworks)

    $inspection = @($inspectionResponse.Data) |
        Select-Object -First 1

if ($inspection.ExistingCluster) {
    return New-HcnEnsureResult `
        -Check 'Ensure-StorageNetwork' `
        -Outcome 'Blocked' `
        -Summary "Node $nodeName is already clustered. Storage network changes are blocked." `
        -AdditionalProperties @{ Node = $nodeName; ExistingCluster = $true }
}

$nonCompliantNetworks = @(
    $inspection.Networks |
        Where-Object { -not $_.AddressPresent }
)

if ($nonCompliantNetworks.Count -eq 0) {
    return New-HcnEnsureResult `
        -Check 'Ensure-StorageNetwork' `
        -Outcome 'AlreadyCompliant' `
        -Summary "All configured storage IP addresses are present for node $nodeName." `
        -AdditionalProperties @{
            Node     = $nodeName
            Networks = $inspection.Networks
        }
}

if (-not (Test-ApprovedOperation -Context $Context -ApprovalKey $approvalKey)) {
    $pendingNames = $nonCompliantNetworks.Name -join ', '

    return New-HcnEnsureResult `
        -Check 'Ensure-StorageNetwork' `
        -Outcome 'Blocked' `
        -Summary "Storage network configuration is required for node ${nodeName}: $pendingNames." `
        -AdditionalProperties @{
            RequiresApproval = $true
            ApprovalReason   = (
                "Adding storage IP addresses can affect RDMA and storage-network connectivity. " +
                'Approve only after verifying the storage switch VLAN and addressing plan.'
            )
            RequiresReboot   = $false
            ReconnectTarget  = $nodeName
            Node             = $nodeName
            PendingNetworks  = $nonCompliantNetworks
        }
}

$changeResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param($DesiredNetworks)

        $changes = foreach ($desired in $DesiredNetworks) {
            $adapter = Get-NetAdapter -Name $desired.AdapterName -ErrorAction Stop

            $exists = @(
                Get-NetIPAddress `
                    -InterfaceIndex $adapter.ifIndex `
                    -AddressFamily IPv4 `
                    -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.IPAddress -eq $desired.IPAddress -and
                        $_.PrefixLength -eq $desired.Prefix
                    }
            ).Count -gt 0

            if (-not $exists) {
                New-NetIPAddress `
                    -InterfaceIndex $adapter.ifIndex `
                    -IPAddress $desired.IPAddress `
                    -PrefixLength $desired.Prefix `
                    -AddressFamily IPv4 `
                    -ErrorAction Stop | Out-Null
            }

            [pscustomobject]@{
                Name        = $desired.Name
                AdapterName = $desired.AdapterName
                IPAddress   = $desired.IPAddress
                Prefix      = $desired.Prefix
                Changed     = (-not $exists)
            }
        }

        return $changes
        } `
        -ArgumentList @(, $desiredNetworks)

    $changeResult = @($changeResponse.Data)

return New-HcnEnsureResult `
    -Check 'Ensure-StorageNetwork' `
    -Outcome 'Changed' `
    -Changed $true `
    -Summary "Ensured configured storage IP addresses for node $nodeName." `
    -AdditionalProperties @{
        Node     = $nodeName
        Networks = $changeResult
    }