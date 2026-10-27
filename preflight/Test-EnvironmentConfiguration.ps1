#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigValue {
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

function Test-UnresolvedValue {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $true
    }

    if ($Value -isnot [string]) {
        return $false
    }

    $text = $Value.Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $true
    }

    return (
        $text -match '(?i)replace_with' -or
        $text -match '(?i)<approved_' -or
        $text -match '(?i)<replace' -or
        $text -match '(?i)^todo$' -or
        $text -match '(?i)^tbd$'
    )
}

function Assert-RequiredValue {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Errors
    )

    if (Test-UnresolvedValue -Value $Value) {
        [void]$Errors.Add("$Path is required and must not be unresolved.")
    }
}

$config = $Context.Config

if ($null -eq $config) {
    throw 'Factory context does not contain Config.'
}

$errors = [System.Collections.Generic.List[string]]::new()
$deferredRequirements = [System.Collections.Generic.List[string]]::new()

$deployment = Get-ConfigValue -Object $config -Name 'deployment'
$site = Get-ConfigValue -Object $config -Name 'site'
$cluster = Get-ConfigValue -Object $config -Name 'cluster'
$network = Get-ConfigValue -Object $config -Name 'network'
$azure = Get-ConfigValue -Object $config -Name 'azure'
$activeDirectory = Get-ConfigValue -Object $config -Name 'active_directory'
$workflow = Get-ConfigValue -Object $config -Name 'workflow'

if ($null -eq $deployment) {
    [void]$errors.Add('deployment configuration is required.')
}
else {
    $scenario = [string](Get-ConfigValue -Object $deployment -Name 'scenario')

    if ($scenario -ne 'PreinstalledAzureLocal') {
        [void]$errors.Add(
            "deployment.scenario must be PreinstalledAzureLocal. Found: $scenario"
        )
    }

    if (
        (Get-ConfigValue -Object $deployment -Name 'use_management_plane_only') -ne $true
    ) {
        [void]$errors.Add(
            'deployment.use_management_plane_only must be true.'
        )
    }
}

if ($null -eq $site) {
    [void]$errors.Add('site configuration is required.')
}

$siteName = [string](Get-ConfigValue -Object $site -Name 'name')
$topology = Get-ConfigValue -Object $site -Name 'topology'
$topologyIntent = [string](Get-ConfigValue -Object $topology -Name 'intent')
$declaredNodeCount = Get-ConfigValue `
    -Object $topology `
    -Name 'phase1_node_count'

if ($siteName -notmatch '^[A-Za-z0-9_-]+$') {
    [void]$errors.Add('site.name is missing or invalid.')
}

if ($topologyIntent -notin @(
        'ValidationOnly',
        'Onboarding',
        'Reference'
    )) {
    [void]$errors.Add(
        'site.topology.intent must be ValidationOnly, Onboarding, or Reference.'
    )
}

$singleServer = Get-ConfigValue `
    -Object $deployment `
    -Name 'single_server'

$isSingleServer = (
    (Get-ConfigValue -Object $singleServer -Name 'enabled') -eq $true
)

$storageIntent = [string](
    Get-ConfigValue `
        -Object $singleServer `
        -Name 'storage_intent'
)

$isStorageIntentNone = (
    $isSingleServer -and
    $storageIntent -eq 'None'
)

$identityMode = [string](
    Get-ConfigValue `
        -Object $activeDirectory `
        -Name 'identity_mode'
)

$isLocalIdentity = (
    $identityMode -eq 'LocalIdentityWithKeyVault'
)

$clusterName = [string](Get-ConfigValue -Object $cluster -Name 'name')

if ([string]::IsNullOrWhiteSpace($clusterName)) {
    [void]$errors.Add('cluster.name is required.')
}

$nodes = @(
    Get-ConfigValue `
        -Object $config `
        -Name 'nodes'
)

$phaseOneTopology = Get-ConfigValue `
    -Object $deployment `
    -Name 'phase1_topology'

$minimumNodes = Get-ConfigValue `
    -Object $phaseOneTopology `
    -Name 'minimum_nodes'

$maximumNodes = Get-ConfigValue `
    -Object $phaseOneTopology `
    -Name 'maximum_nodes'

if (
    $null -ne $minimumNodes -and
    $null -ne $maximumNodes -and
    (
        $nodes.Count -lt [int]$minimumNodes -or
        $nodes.Count -gt [int]$maximumNodes
    )
) {
    [void]$errors.Add(
        "Phase 1 supports $minimumNodes through $maximumNodes nodes. " +
        "Found: $($nodes.Count)."
    )
}

if (
    $null -ne $declaredNodeCount -and
    [int]$declaredNodeCount -ne $nodes.Count
) {
    [void]$errors.Add(
        "site.topology.phase1_node_count $declaredNodeCount does not " +
        "match configured node count $($nodes.Count)."
    )
}

$nodeNames = [System.Collections.Generic.List[string]]::new()
$nodeNumbers = [System.Collections.Generic.List[string]]::new()

foreach ($node in $nodes) {
    $nodeName = [string](Get-ConfigValue -Object $node -Name 'name')
    $nodeNumber = [string](Get-ConfigValue -Object $node -Name 'node_number')
    $management = Get-ConfigValue -Object $node -Name 'management'

    if ([string]::IsNullOrWhiteSpace($nodeName)) {
        [void]$errors.Add('Each node requires a name.')
        continue
    }

    if ($nodeNames -contains $nodeName) {
        [void]$errors.Add("Duplicate node name: $nodeName")
    }

    [void]$nodeNames.Add($nodeName)

    if ($nodeNumber -notmatch '^\d{2}$') {
        [void]$errors.Add(
            "nodes.$nodeName.node_number must be a two-digit value."
        )
    }
    elseif ($nodeNumbers -contains $nodeNumber) {
        [void]$errors.Add(
            "Duplicate node_number value: $nodeNumber"
        )
    }
    else {
        [void]$nodeNumbers.Add($nodeNumber)
    }

    if ($null -eq $management) {
        [void]$errors.Add("nodes.$nodeName.management is required.")
        continue
    }

    foreach ($requiredManagementProperty in @(
            'ip',
            'prefix',
            'gateway',
            'vlan_id',
            'adapter'
        )) {
        Assert-RequiredValue `
            -Value (Get-ConfigValue -Object $management -Name $requiredManagementProperty) `
            -Path "nodes.$nodeName.management.$requiredManagementProperty" `
            -Errors $errors
    }

    $nodeStorage = @(
        Get-ConfigValue `
            -Object $node `
            -Name 'storage'
    )

    if ($isStorageIntentNone) {
        if ($nodeStorage.Count -gt 0) {
            [void]$errors.Add(
                "nodes.$nodeName.storage must be empty when storage intent is None."
            )
        }
    }
    elseif ($nodeStorage.Count -lt 1) {
        [void]$errors.Add(
            "nodes.$nodeName must define storage adapters for the selected profile."
        )
    }
}

$managementNetwork = Get-ConfigValue `
    -Object $network `
    -Name 'management'

if ($null -eq $managementNetwork) {
    [void]$errors.Add('network.management configuration is required.')
}
else {
    foreach ($requiredManagementProperty in @(
            'subnet',
            'prefix',
            'gateway',
            'vlan_id',
            'primary_adapter'
        )) {
        Assert-RequiredValue `
            -Value (Get-ConfigValue -Object $managementNetwork -Name $requiredManagementProperty) `
            -Path "network.management.$requiredManagementProperty" `
            -Errors $errors
    }
}

$storageNetworkConfiguration = Get-ConfigValue `
    -Object $network `
    -Name 'storage'

$storageNetworks = @(
    Get-ConfigValue `
        -Object $storageNetworkConfiguration `
        -Name 'networks'
)

if ($isStorageIntentNone) {
    if ($storageNetworks.Count -gt 0) {
        [void]$errors.Add(
            'network.storage.networks must be empty when storage intent is None.'
        )
    }

    [void]$deferredRequirements.Add(
        'Storage-network configuration is not required by the protected single-server profile.'
    )
}
elseif ($storageNetworks.Count -lt 1) {
    [void]$errors.Add(
        'network.storage.networks must contain at least one storage network.'
    )
}

$dns = Get-ConfigValue -Object $config -Name 'dns'
$dnsServers = @(
    Get-ConfigValue `
        -Object $dns `
        -Name 'allowed_servers'
)

if ($dnsServers.Count -lt 1) {
    [void]$errors.Add('At least one allowed DNS server is required.')
}

$ntp = Get-ConfigValue -Object $config -Name 'ntp'
$ntpServers = @(
    Get-ConfigValue `
        -Object $ntp `
        -Name 'servers'
)

if ($ntpServers.Count -lt 1) {
    [void]$errors.Add('At least one NTP server is required.')
}

if ($null -eq $azure) {
    [void]$errors.Add('azure configuration is required.')
}
else {
    foreach ($requiredAzureProperty in @(
            'cloud',
            'location',
            'tenant_id',
            'subscription_id',
            'resource_group'
        )) {
        Assert-RequiredValue `
            -Value (Get-ConfigValue -Object $azure -Name $requiredAzureProperty) `
            -Path "azure.$requiredAzureProperty" `
            -Errors $errors
    }

    if ($isLocalIdentity) {
        $keyVault = Get-ConfigValue `
            -Object $azure `
            -Name 'key_vault'

        if ($null -eq $keyVault) {
            [void]$errors.Add(
                'azure.key_vault is required for LocalIdentityWithKeyVault.'
            )
        }
        else {
            foreach ($requiredKeyVaultProperty in @(
                    'name',
                    'resource_group',
                    'resource_id'
                )) {
                Assert-RequiredValue `
                    -Value (Get-ConfigValue -Object $keyVault -Name $requiredKeyVaultProperty) `
                    -Path "azure.key_vault.$requiredKeyVaultProperty" `
                    -Errors $errors
            }
        }
    }
}

if ($isLocalIdentity) {
    if (
        (Get-ConfigValue `
            -Object $activeDirectory `
            -Name 'require_prebootstrap_workgroup_state') -ne $true
    ) {
        [void]$errors.Add(
            'active_directory.require_prebootstrap_workgroup_state must be true for Local Identity.'
        )
    }

    [void]$deferredRequirements.Add(
        'AD DS domain-controller, SRV-record, and port validation are not required by Local Identity.'
    )
}
else {
    Assert-RequiredValue `
        -Value (Get-ConfigValue -Object $activeDirectory -Name 'validation_domain_controller') `
        -Path 'active_directory.validation_domain_controller' `
        -Errors $errors
}

$executionHosts = @(
    Get-ConfigValue `
        -Object $config `
        -Name 'execution_hosts'
)

if ($executionHosts.Count -lt 1) {
    [void]$errors.Add(
        'execution_hosts must contain at least one approved execution host.'
    )
}

foreach ($executionHost in $executionHosts) {
    $hostId = [string](Get-ConfigValue -Object $executionHost -Name 'id')

    foreach ($requiredExecutionHostProperty in @(
            'computer_name',
            'hosting_site',
            'package_root',
            'artifacts_path'
        )) {
        Assert-RequiredValue `
            -Value (Get-ConfigValue -Object $executionHost -Name $requiredExecutionHostProperty) `
            -Path "execution_hosts.$hostId.$requiredExecutionHostProperty" `
            -Errors $errors
    }
}

$stages = @(
    Get-ConfigValue `
        -Object $workflow `
        -Name 'stages'
)

if ($stages.Count -ne 4) {
    [void]$errors.Add(
        "Phase 1 requires exactly four onboarding workflow stages. Found: $($stages.Count)."
    )
}
else {
    $actualStageIds = @(
        $stages |
            ForEach-Object {
                [int](Get-ConfigValue -Object $_ -Name 'id')
            }
    )

    foreach ($requiredStageId in @(1, 2, 3, 4)) {
        if ($actualStageIds -notcontains $requiredStageId) {
            [void]$errors.Add(
                "workflow.stages is missing Phase 1 stage $requiredStageId."
            )
        }
    }
}

if ($errors.Count -gt 0) {
    throw (
        "Environment configuration validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

return [pscustomobject]@{
    Passed               = $true
    Check                = 'Test-EnvironmentConfiguration'
    Site                 = $siteName
    Cluster              = $clusterName
    NodeCount            = $nodes.Count
    TopologyIntent       = $topologyIntent
    StageCount           = $stages.Count
    SiteProfile          = [string]$config.site_profile.name
    SingleServer         = $isSingleServer
    StorageIntent        = $storageIntent
    IdentityMode         = $identityMode
    DeferredRequirements = $deferredRequirements.ToArray()
    Summary              = (
        "Environment configuration validated for site $siteName. " +
        "SingleServer=$isSingleServer; StorageIntent=$storageIntent; " +
        "IdentityMode=$identityMode."
    )
    ValidatedAt          = [datetime]::UtcNow.ToString('o')
}