Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FactoryOperationCatalog = [ordered]@{
    # -------------------------------------------------------------------------
    # Phase 1 / Stage 1.1 - Site input, configuration, and package validation
    # -------------------------------------------------------------------------
    'Test-EnvironmentConfiguration'                = @{ Scope = 'Site'; Mutates = $false }
    'Test-NamingConvention'                        = @{ Scope = 'Site'; Mutates = $false }
    'Test-IPAddressAllocation'                     = @{ Scope = 'Site'; Mutates = $false }
    'Test-StorageNetworkConfiguration'             = @{ Scope = 'Site'; Mutates = $false }
    'Test-DnsConfiguration'                        = @{ Scope = 'Site'; Mutates = $false }
    'Test-ActiveDirectoryConfiguration'            = @{ Scope = 'Site'; Mutates = $false }
    'Test-ExecutionHostConfiguration'              = @{ Scope = 'Site'; Mutates = $false }
    'Test-RequiredSecrets'                         = @{ Scope = 'Site'; Mutates = $false }
    'Test-ReleasePackageIntegrity'                 = @{ Scope = 'Site'; Mutates = $false }

    # -------------------------------------------------------------------------
    # Phase 1 / Stage 1.2 - Existing state and pre-bootstrap validation
    # -------------------------------------------------------------------------
    'Test-AzureLocalDeploymentState'               = @{ Scope = 'Node'; Mutates = $false }
    'Test-RemoteManagement'                        = @{ Scope = 'Node'; Mutates = $false }
    'Test-RemoteDesktop'                          = @{ Scope = 'Node'; Mutates = $false }
    'Test-WinRMCertificateTrust'                   = @{ Scope = 'Node'; Mutates = $false }
    'Test-NodeIdentity'                            = @{ Scope = 'Node'; Mutates = $false }
    'Test-LocalAdministratorReadiness'             = @{ Scope = 'Node'; Mutates = $false }
    'Test-LocalAdministratorCredential'            = @{ Scope = 'Node'; Mutates = $false }

    'Test-AzureLocalOS'                            = @{ Scope = 'Node'; Mutates = $false }
    'Test-AzureLocalPolicyState'                   = @{ Scope = 'Node'; Mutates = $false }
    'Test-AzureLocalReadiness'                     = @{ Scope = 'Node'; Mutates = $false }
    'Test-AzureLocalOfficialConnectivityValidation'= @{ Scope = 'Node'; Mutates = $false }
    'Test-AzureLocalOfficialHardwareValidation'    = @{ Scope = 'Node'; Mutates = $false }

    'Test-HardwareReadiness'                       = @{ Scope = 'Node'; Mutates = $false }
    'Test-NICState'                                = @{ Scope = 'Node'; Mutates = $false }
    'Test-AdapterDesignState'                      = @{ Scope = 'Node'; Mutates = $false }
    'Test-MellanoxDriverBaseline'                  = @{ Scope = 'Node'; Mutates = $false }

    'Test-IPConfiguration'                         = @{ Scope = 'Node'; Mutates = $false }
    'Test-Gateway'                                 = @{ Scope = 'Node'; Mutates = $false }
    'Test-DNS'                                     = @{ Scope = 'Node'; Mutates = $false }
    'Test-NTP'                                     = @{ Scope = 'Node'; Mutates = $false }

    'Test-StorageNetworkReadiness'                 = @{ Scope = 'Node'; Mutates = $false }
    'Test-RdmaState'                               = @{ Scope = 'Node'; Mutates = $false }
    'Test-SriovState'                              = @{ Scope = 'Node'; Mutates = $false }

    'Test-DhcpState'                               = @{ Scope = 'Node'; Mutates = $false }
    'Test-ManagementVlanState'                     = @{ Scope = 'Node'; Mutates = $false }
    'Test-IPv6Baseline'                            = @{ Scope = 'Node'; Mutates = $false }
    'Test-TpmReadiness'                            = @{ Scope = 'Node'; Mutates = $false }
    'Test-SecureBoot'                              = @{ Scope = 'Node'; Mutates = $false }
    'Test-RequiredWindowsFeatures'                 = @{ Scope = 'Node'; Mutates = $false }

    'Test-ActiveDirectoryReadiness'                = @{ Scope = 'Node'; Mutates = $false }

    # -------------------------------------------------------------------------
    # Phase 1 / Stage 1.2 - Idempotent HCN Script 1 desired state
    # -------------------------------------------------------------------------
    'Ensure-NicRoleMapping'                         = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-EmbeddedAdaptersDisabled'               = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-DhcpDisabled'                           = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-ManagementVlan'                         = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-ManagementNetwork'                      = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-DNS'                                    = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-NTP'                                    = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-StorageNetwork'                         = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-IPv6Baseline'                           = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-LocalDeploymentAdministrator'           = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-PowerShellRemoting'                     = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-RemoteDesktop'                         = @{ Scope = 'Node'; Mutates = $true }
    'Ensure-HostName'                               = @{ Scope = 'Node'; Mutates = $true }
    'Get-AzureLocalDeploymentState'                 = @{ Scope = 'Node'; Mutates = $false }

    # -------------------------------------------------------------------------
    # Phase 1 / Stage 1.3 - Azure Local node bootstrap
    # -------------------------------------------------------------------------
    'Connect-Azure'                                = @{ Scope = 'Site'; Mutates = $false }
    'Test-Subscription'                            = @{ Scope = 'Site'; Mutates = $false }
    'Test-Permissions'                             = @{ Scope = 'Site'; Mutates = $false }
    'Test-ResourceProviders'                       = @{ Scope = 'Site'; Mutates = $false }
    'Test-ResourceGroup'                           = @{ Scope = 'Site'; Mutates = $false }

    'Test-AzureConnectivity'                       = @{ Scope = 'Node'; Mutates = $false }
    'Test-AzureGovEndpoints'                       = @{ Scope = 'Node'; Mutates = $false }

    'Invoke-AzureLocalNodeBootstrap'                = @{ Scope = 'Node'; Mutates = $true }
    'Test-AzureLocalNodeBootstrapState'             = @{ Scope = 'Node'; Mutates = $false }

    'Test-LocalIdentityKeyVaultReadiness'          = @{ Scope = 'Site'; Mutates = $false }

    # -------------------------------------------------------------------------
    # Phase 1 / Stage 1.4 - Azure Arc machine registration and validation
    # -------------------------------------------------------------------------
    'Test-AzureRegistrationInputs'               = @{ Scope = 'Site'; Mutates = $false }
    'Install-AzureConnectedMachineAgent'          = @{ Scope = 'Node'; Mutates = $true }
    'Invoke-AzureLocalArcInitialization'         = @{ Scope = 'Node'; Mutates = $false }
    'Register-ArcNode'                           = @{ Scope = 'Node'; Mutates = $true }
    'Test-ArcRegistration'                       = @{ Scope = 'Node'; Mutates = $false }
    'Test-NodeHealth'                            = @{ Scope = 'Node'; Mutates = $false }
    'Test-ArcHealth'                             = @{ Scope = 'Node'; Mutates = $false }

    # -------------------------------------------------------------------------
    # Phase 2 / Stage 2.1 - Cluster deployment input validation
    # -------------------------------------------------------------------------
    'Test-ClusterDeploymentConfiguration'       = @{ Scope = 'Site'; Mutates = $false }
    'Test-ClusterDeploymentNaming'              = @{ Scope = 'Site'; Mutates = $false }
    'Test-ClusterDeploymentNetwork'             = @{ Scope = 'Site'; Mutates = $false }
    'Test-ClusterDeploymentStorage'             = @{ Scope = 'Site'; Mutates = $false }
    'Test-ClusterDeploymentAzurePrerequisites'  = @{ Scope = 'Site'; Mutates = $false }
    'Test-ClusterDeploymentTemplateInputs'      = @{ Scope = 'Site'; Mutates = $false }
    'Test-ClusterDeploymentSafetyState'         = @{ Scope = 'Node'; Mutates = $false }

    # -------------------------------------------------------------------------
    # Reporting
    # -------------------------------------------------------------------------
    'New-DeploymentReport'                          = @{ Scope = 'Site'; Mutates = $false }
}

function Get-FactoryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
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

function Read-FactoryConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Environment configuration does not exist: $Path"
    }

    if ($null -eq (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        Import-Module powershell-yaml -ErrorAction Stop
    }

    $config = Get-Content `
        -LiteralPath $Path `
        -Raw |
        ConvertFrom-Yaml `
        -Ordered

    if ($null -eq $config) {
        throw "Configuration is empty: $Path"
    }

    $deployment = Get-FactoryValue `
        -Object $config `
        -Name 'deployment'

    if ($null -eq $deployment) {
        throw 'deployment configuration is required.'
    }

    $scenario = [string](
        Get-FactoryValue `
            -Object $deployment `
            -Name 'scenario'
    )

    if ($scenario -ne 'PreinstalledAzureLocal') {
        throw (
            "Unsupported deployment scenario: $scenario. " +
            'This package supports PreinstalledAzureLocal only.'
        )
    }

    $managementPlaneOnly = Get-FactoryValue `
        -Object $deployment `
        -Name 'use_management_plane_only'

    if ($managementPlaneOnly -ne $true) {
        throw 'deployment.use_management_plane_only must be true.'
    }

    $site = Get-FactoryValue `
        -Object $config `
        -Name 'site'

    $siteName = [string](
        Get-FactoryValue `
            -Object $site `
            -Name 'name'
    )

    if ($siteName -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'site.name is missing or invalid.'
    }

    $cluster = Get-FactoryValue `
        -Object $config `
        -Name 'cluster'

    $clusterName = [string](
        Get-FactoryValue `
            -Object $cluster `
            -Name 'name'
    )

    if ([string]::IsNullOrWhiteSpace($clusterName)) {
        throw 'cluster.name is required.'
    }

    $nodes = @(
        Get-FactoryValue `
            -Object $config `
            -Name 'nodes'
    )

    $phaseOneTopology = Get-FactoryValue `
        -Object $deployment `
        -Name 'phase1_topology'

    if ($null -eq $phaseOneTopology) {
        throw 'deployment.phase1_topology is required.'
    }

    $minimumNodes = Get-FactoryValue `
        -Object $phaseOneTopology `
        -Name 'minimum_nodes'

    $maximumNodes = Get-FactoryValue `
        -Object $phaseOneTopology `
        -Name 'maximum_nodes'

    if (
        $null -eq $minimumNodes -or
        $null -eq $maximumNodes
    ) {
        throw (
            'deployment.phase1_topology.minimum_nodes and maximum_nodes ' +
            'are required.'
        )
    }

    if (
        $nodes.Count -lt [int]$minimumNodes -or
        $nodes.Count -gt [int]$maximumNodes
    ) {
        throw (
            "Phase 1 supports $minimumNodes through $maximumNodes nodes. " +
            "Found: $($nodes.Count)."
        )
    }

    $siteTopology = Get-FactoryValue `
        -Object $site `
        -Name 'topology'

    if ($null -ne $siteTopology) {
        $declaredNodeCount = Get-FactoryValue `
            -Object $siteTopology `
            -Name 'phase1_node_count'

        if (
            $null -ne $declaredNodeCount -and
            [int]$declaredNodeCount -ne $nodes.Count
        ) {
            throw (
                "site.topology.phase1_node_count $declaredNodeCount does not " +
                "match configured node count $($nodes.Count)."
            )
        }

        $topologyIntent = [string](
            Get-FactoryValue `
                -Object $siteTopology `
                -Name 'intent'
        )

        $allowedIntents = @(
            Get-FactoryValue `
                -Object $phaseOneTopology `
                -Name 'allowed_intents'
        )

        if (
            -not [string]::IsNullOrWhiteSpace($topologyIntent) -and
            $allowedIntents.Count -gt 0 -and
            $topologyIntent -notin $allowedIntents
        ) {
            throw (
                "site.topology.intent $topologyIntent is not allowed. " +
                "Allowed values: $($allowedIntents -join ', ')."
            )
        }
    
        $intent = [string](
            Get-FactoryValue `
                -Object $siteTopology `
                -Name 'intent'
        )

        $allowedIntents = @(
            Get-FactoryValue `
                -Object $phaseOneTopology `
                -Name 'allowed_intents'
        )

        if (
            -not [string]::IsNullOrWhiteSpace($intent) -and
            $allowedIntents.Count -gt 0 -and
            $intent -notin $allowedIntents
        ) {
            throw (
                "site.topology.intent $intent is not allowed. " +
                "Allowed values: $($allowedIntents -join ', ')."
            )
        }
    } 


    $workflow = Get-FactoryValue `
        -Object $config `
        -Name 'workflow'

    $stages = @(
        Get-FactoryValue `
            -Object $workflow `
            -Name 'stages'
    )

    if ($stages.Count -ne 4) {
        throw "Phase 1 requires exactly four stages. Found: $($stages.Count)."
    }

    $adapters = Get-FactoryValue `
        -Object $config `
        -Name 'adapters'

    if (
        $null -eq $adapters -or
        $adapters -isnot [System.Collections.IDictionary]
    ) {
        throw 'Configuration must include an adapters map.'
    }

    return $config
}

function Write-FactoryJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $parent = Split-Path -Path $Path -Parent

    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "Cannot determine parent directory for: $Path"
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $parent |
        Out-Null

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"

    try {
        $Value |
            ConvertTo-Json -Depth 50 |
            Set-Content `
                -LiteralPath $temporaryPath `
                -Encoding utf8

        Move-Item `
            -LiteralPath $temporaryPath `
            -Destination $Path `
            -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item `
                -LiteralPath $temporaryPath `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Protect-FactoryErrorMessage {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return 'Operation failed without a detailed error message.'
    }

    $sanitized = $Message

    $secretVariables = @(
        Get-ChildItem Env: |
            Where-Object {
                $_.Name -match '(?i)password|secret|token|credential|client[_-]?secret'
            }
    )

    foreach ($variable in $secretVariables) {
        if (-not [string]::IsNullOrWhiteSpace($variable.Value)) {
            $sanitized = $sanitized.Replace(
                [string]$variable.Value,
                '[REDACTED]'
            )
        }
    }

    $sanitized = $sanitized -replace `
        '(?i)bearer\s+[a-z0-9\-_\.\=]+',
        'Bearer [REDACTED]'

    $sanitized = $sanitized -replace `
        '(?i)(password|secret|token)\s*[:=]\s*\S+',
        '$1=[REDACTED]'

    return $sanitized
}

function Get-FactoryOperationMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Operation
    )

    if (-not $script:FactoryOperationCatalog.Contains($Operation)) {
        throw "Operation is not approved for the Azure Local factory workflow: $Operation"
    }

    return $script:FactoryOperationCatalog[$Operation]
}

function Get-FactoryAdapterPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $repositoryRoot = (
        [IO.Path]::GetFullPath([string]$Context.Root)
    ).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )

    $adapters = Get-FactoryValue `
        -Object $Context.Config `
        -Name 'adapters'

    if (-not $adapters.Contains($Operation)) {
        throw "No adapter mapping exists for operation: $Operation"
    }

    $relativePath = [string]$adapters[$Operation]

    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        throw "Adapter path is empty for operation: $Operation"
    }

    if ([IO.Path]::IsPathRooted($relativePath)) {
        throw "Adapter paths must be repository-relative: $Operation"
    }

    $adapterPath = [IO.Path]::GetFullPath(
        (Join-Path $repositoryRoot $relativePath)
    )

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    $rootPrefix = $repositoryRoot + [IO.Path]::DirectorySeparatorChar

    if (-not $adapterPath.StartsWith($rootPrefix, $comparison)) {
        throw "Adapter path escapes package root: $Operation"
    }

    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
        throw (
            'Adapter file does not exist for operation {0}: {1}' -f
            $Operation,
            $relativePath
        )
    }

    return $adapterPath
}

function Invoke-FactoryAz {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    if ($null -eq (Get-Command -Name az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is unavailable on this workstation.'
    }

    $output = @(
        & az @Arguments --only-show-errors --output json 2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI operation failed. Review approved local diagnostics.'
    }

    if ($output.Count -eq 0) {
        return $null
    }

    try {
        return (
            $output -join "`n" |
                ConvertFrom-Json -AsHashtable
        )
    }
    catch {
        throw 'Azure CLI did not return valid JSON.'
    }
}

function Invoke-FactoryOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $metadata = Get-FactoryOperationMetadata -Operation $Operation

    if ($null -eq $Context.State) {
        throw 'Factory operation requires Context.State.'
    }

    if ($null -eq $Context.State.approvedOperations) {
        $Context.State.approvedOperations = @{}
    }

    if ($null -eq $Context.State.pendingApproval) {
        $Context.State.pendingApproval = $null
    }

    if ($null -eq $Context.State.pendingReboot) {
        $Context.State.pendingReboot = $null
    }
 
    if ($null -eq $Context.State.pendingInteractiveAuthentication) {
        $Context.State.pendingInteractiveAuthentication = $null
    }

    if ($Context.Mode -eq 'Validate' -and [bool]$metadata.Mutates) {
        throw "Validate mode blocks mutating operation: $Operation"
    }

    $hasNodeContext = $Context.ContainsKey('Node')

    if ($metadata.Scope -eq 'Node' -and -not $hasNodeContext) {
        throw "Node-scoped operation requires Context.Node: $Operation"
    }

    if ($metadata.Scope -eq 'Site' -and $hasNodeContext) {
        throw "Site-scoped operation cannot run with Context.Node: $Operation"
    }

    $adapterPath = Get-FactoryAdapterPath `
        -Operation $Operation `
        -Context $Context

    $adapterContext = @{}

foreach ($key in $Context.Keys) {
    $adapterContext[$key] = $Context[$key]
}

$adapterContext.Operation = $Operation

try {
    $resultCollection = @(
        & $adapterPath -Context $adapterContext
    )
}
catch {
    $nodeSuffix = if ($hasNodeContext) {
        " for node $($Context.Node.name)"
    }
    else {
        ''
    }

    throw (
        "Operation $Operation$nodeSuffix failed. " +
        (Protect-FactoryErrorMessage -Message $_.Exception.Message)
    )
}

    if (
        $resultCollection.Count -eq 1 -and
        $resultCollection[0] -is [System.Collections.IList] -and
        $resultCollection[0] -isnot [string]
    ) {
        $nestedResultCollection = @(
            $resultCollection[0]
        )

        if ($nestedResultCollection.Count -eq 1) {
            $resultCollection = @(
                $nestedResultCollection[0]
            )
        }
    }

    if ($resultCollection.Count -ne 1) {
        $outputTypes = @(
            $resultCollection |
                ForEach-Object {
                    if ($null -eq $_) {
                        '<null>'
                    }
                    else {
                        $_.GetType().FullName
                    }
                }
        )

        throw (
            'Adapter {0} returned {1} result object(s). Types: {2}' -f
            $Operation,
            $resultCollection.Count,
            ($outputTypes -join ', ')
        )
    }

    $result = $resultCollection[0]

    $passed = Get-FactoryValue `
        -Object $result `
        -Name 'Passed'

    if ($null -eq $passed) {
        throw "Adapter result is missing Boolean Passed property: $Operation"
    }

    if ($passed -isnot [bool]) {
        throw "Adapter result Passed property must be Boolean: $Operation"
    }

    if (-not $passed) {
        $outcome = [string](
            Get-FactoryValue `
                -Object $result `
                -Name 'Outcome'
        )

        $requiresApproval = (
            Get-FactoryValue `
                -Object $result `
                -Name 'RequiresApproval'
        ) -eq $true

        $pauseRequested = (
            Get-FactoryValue `
                -Object $result `
                -Name 'PauseRequested'
        ) -eq $true

        if (
            $outcome -eq 'Blocked' -and
            (
                $requiresApproval -or
                $pauseRequested
            )
        ) {
            return $result
        }

        $reason = Get-FactoryValue `
            -Object $result `
            -Name 'Reason'

        if ([string]::IsNullOrWhiteSpace([string]$reason)) {
            $reason = Get-FactoryValue `
                -Object $result `
                -Name 'Summary'
        }

        if ([string]::IsNullOrWhiteSpace([string]$reason)) {
            $reason = 'Adapter returned Passed=false without a Reason or Summary property.'
        }

        throw (
            "Operation $Operation failed. " +
            (Protect-FactoryErrorMessage -Message ([string]$reason))
        )
    }

    $check = Get-FactoryValue `
        -Object $result `
        -Name 'Check'

    if ([string]::IsNullOrWhiteSpace([string]$check)) {
        if ($result -is [System.Collections.IDictionary]) {
            $result['Check'] = $Operation
        }
        else {
            Add-Member `
                -InputObject $result `
                -MemberType NoteProperty `
                -Name Check `
                -Value $Operation
        }
    }

    return $result
}

Export-ModuleMember -Function @(
    'Get-FactoryAdapterPath',
    'Get-FactoryOperationMetadata',
    'Get-FactoryValue',
    'Invoke-FactoryAz',
    'Invoke-FactoryOperation',
    'Protect-FactoryErrorMessage',
    'Read-FactoryConfig',
    'Write-FactoryJson'
)