#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\HcnEnsure.Common.psm1" -Force

function Get-BootstrapValue {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-HcnEnsureValue `
        -Object $Object `
        -Name $Name
}

$node = Get-BootstrapValue `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Invoke-AzureLocalNodeBootstrap requires a node-scoped context.'
}

$config = Get-BootstrapValue `
    -Object $Context `
    -Name 'Config'

$deployment = Get-BootstrapValue `
    -Object $config `
    -Name 'deployment'

$nodeBootstrap = Get-BootstrapValue `
    -Object $deployment `
    -Name 'node_bootstrap'

if ($null -eq $nodeBootstrap) {
    throw 'deployment.node_bootstrap configuration is required.'
}

$bootstrapMode = [string](
    Get-BootstrapValue `
        -Object $nodeBootstrap `
        -Name 'mode'
)

$approvedExecutionMethod = [string](
    Get-BootstrapValue `
        -Object $nodeBootstrap `
        -Name 'approved_execution_method'
)

$allowClusterCreation = [bool](
    Get-BootstrapValue `
        -Object $nodeBootstrap `
        -Name 'allow_cluster_creation'
)

$allowArcRegistration = [bool](
    Get-BootstrapValue `
        -Object $nodeBootstrap `
        -Name 'allow_arc_registration'
)

$nodeName = [string](
    Get-BootstrapValue `
        -Object $node `
        -Name 'name'
)

if ($bootstrapMode -ne 'ReadinessOnly') {
    return New-HcnEnsureResult `
        -Check 'Invoke-AzureLocalNodeBootstrap' `
        -Outcome 'Blocked' `
        -Summary (
            "Phase 1.3 bootstrap mode $bootstrapMode is not approved for " +
            "node $nodeName."
        ) `
        -AdditionalProperties @{
            Node                     = $nodeName
            BootstrapMode            = $bootstrapMode
            ApprovedExecutionMethod  = $approvedExecutionMethod
            AllowClusterCreation     = $allowClusterCreation
            AllowArcRegistration     = $allowArcRegistration
            Reason                   = (
                'Only ReadinessOnly bootstrap mode is approved in the ' +
                'current package.'
            )
        }
}

if ($allowClusterCreation) {
    return New-HcnEnsureResult `
        -Check 'Invoke-AzureLocalNodeBootstrap' `
        -Outcome 'Blocked' `
        -Summary (
            "Cluster creation is not approved during Phase 1.3 for " +
            "node $nodeName."
        ) `
        -AdditionalProperties @{
            Node    = $nodeName
            Reason  = (
                'Cluster creation belongs to Phase 2 and must remain ' +
                'disabled in Phase 1.3.'
            )
        }
}

if ($allowArcRegistration) {
    return New-HcnEnsureResult `
        -Check 'Invoke-AzureLocalNodeBootstrap' `
        -Outcome 'Blocked' `
        -Summary (
            "Arc registration is not approved during Phase 1.3 for " +
            "node $nodeName."
        ) `
        -AdditionalProperties @{
            Node   = $nodeName
            Reason = (
                'Arc registration belongs to Phase 1.4 and must remain ' +
                'disabled in Phase 1.3.'
            )
        }
}

return New-HcnEnsureResult `
    -Check 'Invoke-AzureLocalNodeBootstrap' `
    -Outcome 'Blocked' `
    -Summary (
        "Phase 1.3 readiness completed for node $nodeName, but no approved " +
        'AzureUSGovernment bootstrap execution method is configured.'
    ) `
    -AdditionalProperties @{
        Node                    = $nodeName
        BootstrapMode           = $bootstrapMode
        ApprovedExecutionMethod = $approvedExecutionMethod
        Reason                  = (
            'The current package intentionally blocks live node bootstrap. ' +
            'Implement a separately approved AzureUSGovernment execution method ' +
            'before enabling Phase 1.3 Apply.'
        )
        RequiresApproval        = $false
        RequiresReboot          = $false
    }