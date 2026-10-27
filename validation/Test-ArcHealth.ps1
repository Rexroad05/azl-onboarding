#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop
Import-Module "$PSScriptRoot\..\preflight\ManagementPlane.Common.psm1" -Force

function Get-ArcValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if (@($Object.Keys) -contains $Name) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

$node = Get-ArcValue `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Test-ArcHealth requires a node-scoped context.'
}

$config = Get-ArcValue `
    -Object $Context `
    -Name 'Config'

$azure = Get-ArcValue `
    -Object $config `
    -Name 'azure'

$arcAgent = Get-ArcValue `
    -Object $azure `
    -Name 'arc_agent'

$subscriptionId = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'subscription_id'
)

$tenantId = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'tenant_id'
)

$resourceGroup = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'resource_group'
)

$nodeName = [string](
    Get-ArcValue `
        -Object $node `
        -Name 'name'
)

$expectedAgentPath = [string](
    Get-ArcValue `
        -Object $arcAgent `
        -Name 'agent_executable_path'
)

$himdsServiceName = [string](
    Get-ArcValue `
        -Object $arcAgent `
        -Name 'himds_service_name'
)

if ([string]::IsNullOrWhiteSpace($himdsServiceName)) {
    $himdsServiceName = 'himds'
}

$azContext = Get-AzContext

if ($null -eq $azContext) {
    throw 'Azure PowerShell context is unavailable for Arc health validation.'
}

if ($azContext.Environment.Name -ne 'AzureUSGovernment') {
    throw (
        "Azure environment mismatch. Expected AzureUSGovernment; current " +
        "environment is $($azContext.Environment.Name)."
    )
}

if ($azContext.Tenant.Id -ne $tenantId) {
    throw (
        "Azure tenant mismatch. Expected $tenantId; current tenant is " +
        "$($azContext.Tenant.Id)."
    )
}

if ($azContext.Subscription.Id -ne $subscriptionId) {
    throw (
        "Azure subscription mismatch. Expected $subscriptionId; current " +
        "subscription is $($azContext.Subscription.Id)."
    )
}

$arcResource = Get-AzResource `
    -ResourceGroupName $resourceGroup `
    -Name $nodeName `
    -ResourceType 'Microsoft.HybridCompute/machines' `
    -ErrorAction Stop

$provisioningState = [string]$arcResource.Properties.provisioningState

if (
    -not [string]::IsNullOrWhiteSpace($provisioningState) -and
    $provisioningState -ne 'Succeeded'
) {
    throw (
        "Azure Arc machine $nodeName provisioning state is " +
        "$provisioningState; expected Succeeded."
    )
}

$nodeAgentResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-ArcHealth' `
    -ArgumentList @(
        $expectedAgentPath,
        $himdsServiceName
    ) `
    -ScriptBlock {
        param(
            [string]$ExpectedAgentPath,
            [string]$HimdsServiceName
        )

        function Resolve-AzureConnectedMachineAgentPath {
            param(
                [AllowNull()]
                [string]$ExpectedPath
            )

            $candidatePaths = @(
                $ExpectedPath
                "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
                "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
            ) |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Select-Object -Unique

            foreach ($candidatePath in $candidatePaths) {
                if (
                    Test-Path `
                        -LiteralPath $candidatePath `
                        -PathType Leaf
                ) {
                    return $candidatePath
                }
            }

            $agent = Get-Command `
                -Name 'azcmagent.exe', 'azcmagent' `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($null -ne $agent) {
                return [string]$agent.Source
            }

            return $null
        }

        $agentPath = Resolve-AzureConnectedMachineAgentPath `
            -ExpectedPath $ExpectedAgentPath

        $himds = Get-Service `
            -Name $HimdsServiceName `
            -ErrorAction SilentlyContinue

        if ([string]::IsNullOrWhiteSpace($agentPath)) {
            throw 'Azure Connected Machine agent is not present.'
        }

        if ($null -eq $himds -or $himds.Status -ne 'Running') {
            throw 'Azure Arc HIMDS service is not present or not running.'
        }

        [pscustomobject]@{
            AgentPath = $agentPath
            AgentVersion = @(
                & $agentPath --version 2>&1
            ) -join "`n"
            HimdsStatus = [string]$himds.Status
        }
    }

$nodeAgentState = @($nodeAgentResponse.Data) |
    Select-Object -First 1

return [pscustomobject]@{
    Passed               = $true
    Check                = 'Test-ArcHealth'
    Node                 = $nodeName
    ManagementIp         = $nodeAgentResponse.ManagementIp
    ArcResourceId        = $arcResource.ResourceId
    ArcResourceName      = $arcResource.Name
    ArcProvisioningState = $provisioningState
    AgentPath            = $nodeAgentState.AgentPath
    AgentVersion         = $nodeAgentState.AgentVersion
    HimdsStatus          = $nodeAgentState.HimdsStatus
    Summary              = (
        "Azure Arc resource and local agent health validated for node " +
        "$nodeName."
    )
    ValidatedAt          = [datetime]::UtcNow.ToString('o')
}