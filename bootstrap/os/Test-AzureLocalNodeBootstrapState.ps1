#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\..\preflight\ManagementPlane.Common.psm1" -Force

function Get-BootstrapValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-ManagementPlaneValue `
        -Object $Object `
        -Name $Name
}

function Get-StageOneTwoState {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    if ($null -eq $Context.State) {
        throw 'Bootstrap validation requires Context.State.'
    }

    $stages = Get-BootstrapValue `
        -Object $Context.State `
        -Name 'stages'

    if ($null -eq $stages) {
        throw 'Bootstrap validation state does not contain stages.'
    }

    if ($stages -is [System.Collections.IDictionary]) {
        if (-not (@($stages.Keys) -contains '2')) {
            throw (
                'Phase 1 Stage 1.2 completion record is missing. ' +
                'Node bootstrap cannot proceed.'
            )
        }

        return $stages['2']
    }

    $stageProperty = $stages.PSObject.Properties['2']

    if ($null -eq $stageProperty) {
        throw (
            'Phase 1 Stage 1.2 completion record is missing. ' +
            'Node bootstrap cannot proceed.'
        )
    }

    return $stageProperty.Value
}

$node = Get-BootstrapValue `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Test-AzureLocalNodeBootstrapState requires a node-scoped context.'
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

$requireStage12Completion = [bool](
    Get-BootstrapValue `
        -Object $nodeBootstrap `
        -Name 'require_stage_12_completion'
)

$requireAzureGovernmentSession = [bool](
    Get-BootstrapValue `
        -Object $nodeBootstrap `
        -Name 'require_azure_government_session'
)

$requireResourceGroupValidation = [bool](
    Get-BootstrapValue `
        -Object $nodeBootstrap `
        -Name 'require_resource_group_validation'
)

$requireResourceProviderValidation = [bool](
    Get-BootstrapValue `
        -Object $nodeBootstrap `
        -Name 'require_resource_provider_validation'
)

$nodeName = [string](
    Get-BootstrapValue `
        -Object $node `
        -Name 'name'
)

$activeDirectory = Get-BootstrapValue `
    -Object $config `
    -Name 'active_directory'

$identityMode = [string](
    Get-BootstrapValue `
        -Object $activeDirectory `
        -Name 'identity_mode'
)

$azure = Get-BootstrapValue `
    -Object $config `
    -Name 'azure'

$keyVault = Get-BootstrapValue `
    -Object $azure `
    -Name 'key_vault'

if ($bootstrapMode -ne 'ReadinessOnly') {
    throw (
        "Unsupported deployment.node_bootstrap.mode: $bootstrapMode. " +
        'Only ReadinessOnly is approved for the current package.'
    )
}

if ([string]::IsNullOrWhiteSpace($approvedExecutionMethod)) {
    throw 'deployment.node_bootstrap.approved_execution_method is required.'
}

if ($allowClusterCreation) {
    throw (
        'deployment.node_bootstrap.allow_cluster_creation must remain false ' +
        'until Phase 2 execution is approved.'
    )
}

if ($allowArcRegistration) {
    throw (
        'deployment.node_bootstrap.allow_arc_registration must remain false. ' +
        'Arc registration is a Phase 1.4 activity.'
    )
}

if ($requireStage12Completion) {
    $stageOneTwoState = Get-StageOneTwoState -Context $Context

    if ([string]$stageOneTwoState.status -ne 'PASS') {
        throw (
            'Phase 1 Stage 1.2 is not recorded as PASS. ' +
            'Node bootstrap readiness cannot proceed.'
        )
    }
}

if ($identityMode -eq 'LocalIdentityWithKeyVault') {
    $keyVaultName = [string](
        Get-BootstrapValue `
            -Object $keyVault `
            -Name 'name'
    )

    $keyVaultResourceGroup = [string](
        Get-BootstrapValue `
            -Object $keyVault `
            -Name 'resource_group'
    )

    $keyVaultResourceId = [string](
        Get-BootstrapValue `
            -Object $keyVault `
            -Name 'resource_id'
    )

    if (
        [string]::IsNullOrWhiteSpace($keyVaultName) -or
        [string]::IsNullOrWhiteSpace($keyVaultResourceGroup) -or
        [string]::IsNullOrWhiteSpace($keyVaultResourceId)
    ) {
        throw (
            'Local Identity node bootstrap readiness requires Azure Key Vault ' +
            'name, resource group, and resource ID.'
        )
    }
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-AzureLocalNodeBootstrapState' `
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
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

if ($data.Clustered) {
    throw (
        "Node $nodeName is already clustered as $($data.ClusterName). " +
        'Phase 1.3 node bootstrap is blocked.'
    )
}

if (
    $data.RegistrationStatus -eq 'Registered' -or
    -not [string]::IsNullOrWhiteSpace([string]$data.AzureResourceName)
) {
    throw (
        "Node $nodeName is already Azure registered. " +
        "Registration status: $($data.RegistrationStatus); " +
        "Azure resource: $($data.AzureResourceName). " +
        'Phase 1.3 node bootstrap is blocked.'
    )
}

return [pscustomobject]@{
    Passed                            = $true
    Check                             = 'Test-AzureLocalNodeBootstrapState'
    Node                              = $result.Node
    ManagementIp                      = $result.ManagementIp
    BootstrapMode                     = $bootstrapMode
    ApprovedExecutionMethod           = $approvedExecutionMethod
    RequireStage12Completion          = $requireStage12Completion
    RequireAzureGovernmentSession     = $requireAzureGovernmentSession
    RequireResourceGroupValidation    = $requireResourceGroupValidation
    RequireResourceProviderValidation = $requireResourceProviderValidation
    IdentityMode                      = $identityMode
    KeyVaultName                      = if (
        $identityMode -eq 'LocalIdentityWithKeyVault'
    ) {
        [string](Get-BootstrapValue -Object $keyVault -Name 'name')
    }
    else {
        $null
    }
    Clustered                         = $data.Clustered
    RegistrationStatus                = $data.RegistrationStatus
    AzureResourceName                 = $data.AzureResourceName
    Summary                           = (
        "Node $nodeName is unclustered and unregistered. " +
        "Phase 1.3 readiness-only bootstrap prerequisites are valid."
    )
    ValidatedAt                       = [datetime]::UtcNow.ToString('o')
}