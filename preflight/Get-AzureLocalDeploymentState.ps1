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
    throw 'Get-AzureLocalDeploymentState requires a node-scoped context.'
}

$nodeName = [string](
    Get-ManagementPlaneValue `
        -Object $node `
        -Name 'name'
)

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Get-AzureLocalDeploymentState' `
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

        $computerSystem = Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop

        [pscustomobject]@{
            ComputerName       = $env:COMPUTERNAME
            Clustered          = ($null -ne $cluster)
            ClusterName        = if ($null -ne $cluster) {
                [string]$cluster.Name
            }
            else {
                $null
            }
            RegistrationStatus = $registrationStatus
            AzureResourceName  = $azureResourceName
            ConnectionStatus   = $connectionStatus
            Domain             = [string]$computerSystem.Domain
            PartOfDomain       = [bool]$computerSystem.PartOfDomain
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

$summary = if ($data.Clustered -or $data.RegistrationStatus -eq 'Registered') {
    (
        "Reference/deployed state discovered for node $nodeName. " +
        "Clustered=$($data.Clustered); " +
        "RegistrationStatus=$($data.RegistrationStatus); " +
        "AzureResource=$($data.AzureResourceName)."
    )
}
else {
    (
        "Onboarding candidate state discovered for node $nodeName. " +
        "Clustered=$($data.Clustered); " +
        "RegistrationStatus=$($data.RegistrationStatus)."
    )
}

return [pscustomobject]@{
    Passed             = $true
    Check              = 'Get-AzureLocalDeploymentState'
    Node               = $result.Node
    ManagementIp       = $result.ManagementIp
    Clustered          = $data.Clustered
    ClusterName        = $data.ClusterName
    RegistrationStatus = $data.RegistrationStatus
    AzureResourceName  = $data.AzureResourceName
    ConnectionStatus   = $data.ConnectionStatus
    Domain             = $data.Domain
    PartOfDomain       = $data.PartOfDomain
    Summary            = $summary
    ValidatedAt        = [datetime]::UtcNow.ToString('o')
}