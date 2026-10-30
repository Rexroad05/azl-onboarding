#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageRoot,

    [Parameter(Mandatory)]
    [string]$Site,

    [Parameter(Mandatory)]
    [string]$ArtifactsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop

function Read-YamlFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required YAML file does not exist: $Path"
    }

    return (
        Get-Content `
            -LiteralPath $Path `
            -Raw |
            ConvertFrom-Yaml `
            -Ordered
    )
}

function Resolve-HardwareBaselinePath {
    param(
        [Parameter(Mandatory)]
        [string]$PackageRoot,

        [Parameter(Mandatory)]
        [string]$BaselineFile
    )

    if ([string]::IsNullOrWhiteSpace($BaselineFile)) {
        throw 'hardware.baseline_file is required.'
    }

    if ([IO.Path]::IsPathRooted($BaselineFile)) {
        throw 'hardware.baseline_file must be repository-relative.'
    }

    $repositoryRoot = [IO.Path]::GetFullPath(
        $PackageRoot
    ).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )

    $hardwareBaselineRoot = [IO.Path]::GetFullPath(
        (Join-Path `
            $repositoryRoot `
            'config\hardware-baselines')
    ).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )

    $baselinePath = [IO.Path]::GetFullPath(
        (Join-Path `
            $repositoryRoot `
            $BaselineFile)
    )

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    $baselinePrefix = (
        $hardwareBaselineRoot +
        [IO.Path]::DirectorySeparatorChar
    )

    if (-not $baselinePath.StartsWith($baselinePrefix, $comparison)) {
        throw (
            'hardware.baseline_file must resolve under ' +
            'config\hardware-baselines.'
        )
    }

    if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
        throw "Hardware baseline file does not exist: $baselinePath"
    }

    return $baselinePath
}

function Read-HardwareBaseline {
    param(
        [Parameter(Mandatory)]
        [string]$PackageRoot,

        [Parameter(Mandatory)]
        [string]$BaselineFile
    )

    $baselinePath = Resolve-HardwareBaselinePath `
        -PackageRoot $PackageRoot `
        -BaselineFile $BaselineFile

    $baseline = Read-YamlFile `
        -Path $baselinePath

    if ($baseline -isnot [System.Collections.IDictionary]) {
        throw (
            "Hardware baseline must deserialize to a YAML map: $baselinePath"
        )
    }

    foreach ($key in $baseline.Keys) {
        if ($key -notin @(
                'hardware',
                'network'
            )) {
            throw (
                "Hardware baseline contains unsupported top-level key '$key': " +
                "$baselinePath"
            )
        }
    }

    if (
        -not $baseline.Contains('hardware') -or
        $baseline.hardware -isnot [System.Collections.IDictionary]
    ) {
        throw (
            "Hardware baseline must contain a hardware YAML map: $baselinePath"
        )
    }

    return [pscustomobject]@{
        Path = $baselinePath
        Content = $baseline
    }
}

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

function Merge-FactoryObject {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Base,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Overlay
    )

    $result = [ordered]@{}

    foreach ($key in $Base.Keys) {
        $result[$key] = $Base[$key]
    }

    foreach ($key in $Overlay.Keys) {
        if (
            $result.Contains($key) -and
            $result[$key] -is [System.Collections.IDictionary] -and
            $Overlay[$key] -is [System.Collections.IDictionary]
        ) {
            $result[$key] = Merge-FactoryObject `
                -Base $result[$key] `
                -Overlay $Overlay[$key]
        }
        else {
            $result[$key] = $Overlay[$key]
        }
    }

    return $result
}

function Merge-NodesByName {
    param(
        [object[]]$DefaultNodes,

        [object[]]$OperatorNodes
    )

    $result = [System.Collections.Generic.List[object]]::new()
    $operatorNodesByName = @{}

    foreach ($operatorNode in $OperatorNodes) {
        $operatorNodesByName[[string]$operatorNode.name] = $operatorNode
    }

    foreach ($defaultNode in $DefaultNodes) {
        $defaultNodeName = [string]$defaultNode.name

        if ($operatorNodesByName.ContainsKey($defaultNodeName)) {
            $mergedNode = Merge-FactoryObject `
                -Base $defaultNode `
                -Overlay $operatorNodesByName[$defaultNodeName]

            $result.Add($mergedNode)
        }
        else {
            $result.Add($defaultNode)
        }
    }

    foreach ($operatorNode in $OperatorNodes) {
        $operatorNodeName = [string]$operatorNode.name

        if (-not (@($DefaultNodes.name) -contains $operatorNodeName)) {
            $result.Add($operatorNode)
        }
    }

    return $result.ToArray()
}

function Assert-AllowedKeys {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Object,

        [Parameter(Mandatory)]
        [string[]]$AllowedKeys,

        [Parameter(Mandatory)]
        [string]$Path
    )

    foreach ($key in $Object.Keys) {
        if ($key -notin $AllowedKeys) {
            throw (
                "Operator variables may not define protected setting: " +
                "$Path.$key"
            )
        }
    }
}

function Assert-BootstrapConnection {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$BootstrapConnection,

        [Parameter(Mandatory)]
        [string]$NodeName
    )

    Assert-AllowedKeys `
        -Object $BootstrapConnection `
        -AllowedKeys @(
            'host',
            'port',
            'protocol'
        ) `
        -Path "nodes.$NodeName.bootstrap_connection"

    if (-not $BootstrapConnection.Contains('host')) {
        throw (
            "Operator node $NodeName bootstrap_connection.host is required."
        )
    }

    $bootstrapHost = [string]$BootstrapConnection.host

    if ([string]::IsNullOrWhiteSpace($bootstrapHost)) {
        throw (
            "Operator node $NodeName bootstrap_connection.host is required."
        )
    }

    if (
        $bootstrapHost.Contains('://') -or
        $bootstrapHost.Contains('/') -or
        $bootstrapHost.Contains('\') -or
        $bootstrapHost.Contains(':')
    ) {
        throw (
            "Operator node $NodeName bootstrap_connection.host must be " +
            'a DNS hostname only; do not include a protocol, path, or port.'
        )
    }

    $parsedAddress = $null

    if (
        [System.Net.IPAddress]::TryParse(
            $bootstrapHost,
            [ref]$parsedAddress
        )
    ) {
        throw (
            "Operator node $NodeName bootstrap_connection.host must be " +
            'a certificate-matching hostname, not a raw IP address.'
        )
    }

    if ($BootstrapConnection.Contains('protocol')) {
        $bootstrapProtocol = [string]$BootstrapConnection.protocol

        if ([string]::IsNullOrWhiteSpace($bootstrapProtocol)) {
            throw (
                "Operator node $NodeName bootstrap_connection.protocol " +
                'must not be empty when supplied.'
            )
        }

        if ($bootstrapProtocol -notin @(
                'HTTPS',
                'WinRM-HTTPS'
            )) {
            throw (
                "Operator node $NodeName bootstrap_connection.protocol must " +
                'be HTTPS or WinRM-HTTPS.'
            )
        }
    }

    if ($BootstrapConnection.Contains('port')) {
        $bootstrapPort = 0

        if (
            -not [int]::TryParse(
                [string]$BootstrapConnection.port,
                [ref]$bootstrapPort
            )
        ) {
            throw (
                "Operator node $NodeName bootstrap_connection.port " +
                'must be an integer.'
            )
        }

        if ($bootstrapPort -lt 1 -or $bootstrapPort -gt 65535) {
            throw (
                "Operator node $NodeName bootstrap_connection.port must " +
                'be between 1 and 65535.'
            )
        }

        $BootstrapConnection.port = $bootstrapPort
    }
}

function Normalize-BootstrapConnection {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Node
    )

    if (
        -not $Node.Contains('bootstrap_connection') -or
        $null -eq $Node.bootstrap_connection
    ) {
        return
    }

    if (
        $Node.bootstrap_connection -isnot
        [System.Collections.IDictionary]
    ) {
        throw (
            "Resolved node $($Node.name) bootstrap_connection must be a YAML map."
        )
    }

    Assert-BootstrapConnection `
        -BootstrapConnection $Node.bootstrap_connection `
        -NodeName ([string]$Node.name)

    if (-not $Node.bootstrap_connection.Contains('protocol')) {
        $Node.bootstrap_connection.protocol = 'HTTPS'
    }

    if (-not $Node.bootstrap_connection.Contains('port')) {
        $Node.bootstrap_connection.port = 5986
    }
}

function Normalize-ManagementAddress {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Node
    )

    if (
        -not $Node.Contains('management') -or
        $null -eq $Node.management
    ) {
        return
    }

    if ($Node.management -isnot [System.Collections.IDictionary]) {
        throw "Resolved node $($Node.name) management must be a YAML map."
    }

    if (
        $Node.management.Contains('ip_address') -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$Node.management.ip_address
        )
    ) {
        $Node.management.ip = $Node.management.ip_address
    }

    if (
        $Node.management.Contains('prefix_length') -and
        $null -ne $Node.management.prefix_length -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$Node.management.prefix_length
        )
    ) {
        $Node.management.prefix = $Node.management.prefix_length
    }
}

function Normalize-StorageIpAddress {
    param(
        [Parameter(Mandatory)]
        [object]$Node
    )

    $nodeStorage = $null

    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains('storage')) {
            $nodeStorage = $Node['storage']
        }
    }
    elseif ($null -ne $Node.PSObject.Properties['storage']) {
        $nodeStorage = $Node.storage
    }

    if ($null -eq $nodeStorage) {
        return
    }

    foreach ($storageEntry in @($nodeStorage)) {
        if ($null -eq $storageEntry) {
            continue
        }

        if ($storageEntry -is [System.Collections.IDictionary]) {
            if (
                -not $storageEntry.Contains('ip') -and
                $storageEntry.Contains('ip_address')
            ) {
                $storageEntry['ip'] = $storageEntry['ip_address']
            }

            if (
                -not $storageEntry.Contains('prefix') -and
                $storageEntry.Contains('prefix_length')
            ) {
                $storageEntry['prefix'] = $storageEntry['prefix_length']
            }

            continue
        }

        if (
            $null -eq $storageEntry.PSObject.Properties['ip'] -and
            $null -ne $storageEntry.PSObject.Properties['ip_address']
        ) {
            Add-Member `
                -InputObject $storageEntry `
                -MemberType NoteProperty `
                -Name 'ip' `
                -Value $storageEntry.ip_address `
                -Force
        }

        if (
            $null -eq $storageEntry.PSObject.Properties['prefix'] -and
            $null -ne $storageEntry.PSObject.Properties['prefix_length']
        ) {
            Add-Member `
                -InputObject $storageEntry `
                -MemberType NoteProperty `
                -Name 'prefix' `
                -Value $storageEntry.prefix_length `
                -Force
        }
    }
}

function Get-ResolvedSiteProfile {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$SiteProfiles,

        [Parameter(Mandatory)]
        [string]$SiteName,

        [AllowNull()]
        [string]$RequestedProfileName
    )

    if ([string]::IsNullOrWhiteSpace($RequestedProfileName)) {
        return [pscustomobject]@{
            Name = $null
            Overrides = [ordered]@{}
        }
    }

    $profiles = Get-ConfigValue `
        -Object $SiteProfiles `
        -Name 'profiles'

    if ($null -eq $profiles) {
        throw 'Protected site-profiles.yaml does not contain profiles.'
    }

    if (@($profiles.Keys) -notcontains $RequestedProfileName) {
        throw (
            "Requested protected site profile '$RequestedProfileName' " +
            'does not exist.'
        )
    }

    $authorizations = Get-ConfigValue `
        -Object $SiteProfiles `
        -Name 'site_profile_authorizations'

    if ($null -eq $authorizations) {
        throw (
            'Protected site-profiles.yaml does not contain site_profile_authorizations.'
        )
    }

    $authorizedProfiles = $null

    foreach ($authorizedSiteName in $authorizations.Keys) {
        if ([string]$authorizedSiteName -ieq $SiteName) {
            $authorizedProfiles = @($authorizations[$authorizedSiteName])
            break
        }
    }

    if ($null -eq $authorizedProfiles) {
        throw (
            "Site '$SiteName' is not authorized to request protected " +
            "profile '$RequestedProfileName'."
        )
    }

    if ($authorizedProfiles -notcontains $RequestedProfileName) {
        throw (
            "Site '$SiteName' is not authorized to request protected " +
            "profile '$RequestedProfileName'."
        )
    }

    $profile = $profiles[$RequestedProfileName]

    $overrides = Get-ConfigValue `
        -Object $profile `
        -Name 'overrides'

    if ($null -eq $overrides) {
        $overrides = [ordered]@{}
    }

    return [pscustomobject]@{
        Name = $RequestedProfileName
        Overrides = $overrides
    }
}

function Assert-OperatorInputAllowed {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$OperatorInput
    )

    Assert-AllowedKeys `
        -Object $OperatorInput `
        -AllowedKeys @(
            'site',
            'cluster',
            'azure',
            'network',
            'nodes',
            'dns',
            'ntp',
            'active_directory',
            'execution_hosts'
        ) `
        -Path 'root'

    if ($OperatorInput.Contains('site')) {
        if ($OperatorInput.site -isnot [System.Collections.IDictionary]) {
            throw 'Operator variables site section must be a YAML map.'
        }

        Assert-AllowedKeys `
            -Object $OperatorInput.site `
            -AllowedKeys @(
                'name',
                'display_name',
                'environment',
                'location',
                'profile',
                'topology'
            ) `
            -Path 'site'

        if ($OperatorInput.site.Contains('profile')) {
            $requestedProfile = [string]$OperatorInput.site.profile

            if ([string]::IsNullOrWhiteSpace($requestedProfile)) {
                throw 'site.profile must not be empty when supplied.'
            }
        }

        if ($OperatorInput.site.Contains('topology')) {
            if (
                $OperatorInput.site.topology -isnot
                [System.Collections.IDictionary]
            ) {
                throw 'Operator variables site.topology section must be a YAML map.'
            }

            Assert-AllowedKeys `
                -Object $OperatorInput.site.topology `
                -AllowedKeys @(
                    'phase1_node_count',
                    'intent'
                ) `
                -Path 'site.topology'

            $declaredNodeCount = $OperatorInput.site.topology.phase1_node_count

            if ($null -eq $declaredNodeCount) {
                throw 'site.topology.phase1_node_count must be a positive integer.'
            }

            $parsedNodeCount = 0

            if (
                -not [int]::TryParse(
                    [string]$declaredNodeCount,
                    [ref]$parsedNodeCount
                ) -or
                $parsedNodeCount -lt 1
            ) {
                throw 'site.topology.phase1_node_count must be a positive integer.'
            }

            $intent = [string]$OperatorInput.site.topology.intent

            if ($intent -notin @(
                    'ValidationOnly',
                    'Onboarding',
                    'Reference'
                )) {
                throw (
                    "site.topology.intent is invalid: $intent. " +
                    'Allowed values: ValidationOnly, Onboarding, Reference.'
                )
            }
        }
    }

    if ($OperatorInput.Contains('cluster')) {
        if ($OperatorInput.cluster -isnot [System.Collections.IDictionary]) {
            throw 'Operator variables cluster section must be a YAML map.'
        }

        Assert-AllowedKeys `
            -Object $OperatorInput.cluster `
            -AllowedKeys @(
                'name'
            ) `
            -Path 'cluster'
    }

    if ($OperatorInput.Contains('azure')) {
        if ($OperatorInput.azure -isnot [System.Collections.IDictionary]) {
            throw 'Operator variables azure section must be a YAML map.'
        }

        Assert-AllowedKeys `
            -Object $OperatorInput.azure `
            -AllowedKeys @(
                'subscription_id',
                'tenant_id',
                'resource_group',
                'location',
                'key_vault'
            ) `
            -Path 'azure'

        if ($OperatorInput.azure.Contains('key_vault')) {
            if (
                $OperatorInput.azure.key_vault -isnot
                [System.Collections.IDictionary]
            ) {
                throw 'Operator variables azure.key_vault section must be a YAML map.'
            }

            Assert-AllowedKeys `
                -Object $OperatorInput.azure.key_vault `
                -AllowedKeys @(
                    'name',
                    'resource_group',
                    'resource_id'
                ) `
                -Path 'azure.key_vault'
        }
    }

    if ($OperatorInput.Contains('network')) {
        if ($OperatorInput.network -isnot [System.Collections.IDictionary]) {
            throw 'Operator variables network section must be a YAML map.'
        }

        Assert-AllowedKeys `
            -Object $OperatorInput.network `
            -AllowedKeys @(
                'name',
                'node_number',
                'management',
                'storage'
            ) `
            -Path 'network'

        if (
            -not $OperatorInput.network.Contains('management') -or
            $OperatorInput.network.management -isnot
            [System.Collections.IDictionary]
        ) {
            throw 'Operator variables network.management section must be a YAML map.'
        }

        if (
            $OperatorInput.network.Contains('storage') -and
            $null -ne $OperatorInput.network.storage
        ) {
            if (
                $OperatorInput.network.storage -isnot
                [System.Collections.IDictionary]
            ) {
                throw 'Operator variables network.storage section must be a YAML map.'
            }

            Assert-AllowedKeys `
                -Object $OperatorInput.network.storage `
                -AllowedKeys @(
                    'networks'
                ) `
                -Path 'network.storage'

            if (
                $OperatorInput.network.storage.Contains('networks') -and
                $null -ne $OperatorInput.network.storage.networks
            ) {
                foreach (
                    $storageNetwork in
                    @($OperatorInput.network.storage.networks)
                ) {
                    if ($null -eq $storageNetwork) {
                        continue
                    }

                    if (
                        $storageNetwork -isnot
                        [System.Collections.IDictionary]
                    ) {
                        throw 'Each network.storage.networks entry must be a YAML map.'
                    }

                    $storageNetworkName = [string]$storageNetwork.name

                    if ([string]::IsNullOrWhiteSpace($storageNetworkName)) {
                        throw 'Each network.storage.networks entry requires name.'
                    }

                    Assert-AllowedKeys `
                        -Object $storageNetwork `
                        -AllowedKeys @(
                            'name',
                            'adapter',
                            'subnet',
                            'prefix',
                            'vlan_id'
                        ) `
                        -Path "network.storage.networks.$storageNetworkName"
                }
            }
        }
    }

    if ($OperatorInput.Contains('nodes')) {
        $operatorNodes = @($OperatorInput.nodes)

        if ($operatorNodes.Count -lt 1) {
            throw 'Operator variables nodes section must contain at least one node.'
        }

        foreach ($operatorNode in $operatorNodes) {
            if ($operatorNode -isnot [System.Collections.IDictionary]) {
                throw 'Each operator node entry must be a YAML map.'
            }

            $nodeName = [string]$operatorNode.name

            if ([string]::IsNullOrWhiteSpace($nodeName)) {
                throw 'Each operator node entry requires name.'
            }

            Assert-AllowedKeys `
                -Object $operatorNode `
                -AllowedKeys @(
                    'name',
                    'node_number',
                    'bootstrap_connection',
                    'management',
                    'network',
                    'storage'
                ) `
                -Path "nodes.$nodeName"

            if (
                -not $operatorNode.Contains('management') -or
                $operatorNode.management -isnot
                [System.Collections.IDictionary]
            ) {
                throw "Operator node $nodeName requires a management YAML map."
            }

            Assert-AllowedKeys `
                -Object $operatorNode.management `
                -AllowedKeys @(
                    'ip',
                    'ip_address',
                    'prefix',
                    'prefix_length',
                    'gateway',
                    'dns_servers',
                    'vlan_id',
                    'adapter'
                ) `
                -Path "nodes.$nodeName.management"

            if (
                $operatorNode.management.Contains('dns_servers') -and
                $null -ne $operatorNode.management.dns_servers
            ) {
                foreach ($dnsServer in @($operatorNode.management.dns_servers)) {
                    if ([string]::IsNullOrWhiteSpace([string]$dnsServer)) {
                        throw (
                            "Operator node $nodeName management.dns_servers " +
                            'may not contain an empty DNS server value.'
                        )
                    }
                }
            }

            if ($operatorNode.Contains('network')) {
                if (
                    $operatorNode.network -isnot
                    [System.Collections.IDictionary]
                ) {
                    throw "Operator node $nodeName network must be a YAML map."
                }

                Assert-AllowedKeys `
                    -Object $operatorNode.network `
                    -AllowedKeys @(
                        'management_adapter',
                        'physical_adapters',
                        'vlan_id'
                    ) `
                    -Path "nodes.$nodeName.network"

                if (
                    $operatorNode.network.Contains('management_adapter') -and
                    [string]::IsNullOrWhiteSpace(
                        [string]$operatorNode.network.management_adapter
                    )
                ) {
                    throw (
                        "Operator node $nodeName network.management_adapter " +
                        'must not be empty when supplied.'
                    )
                }

                if ($operatorNode.network.Contains('physical_adapters')) {
                    $physicalAdapters = @(
                        $operatorNode.network.physical_adapters
                    )

                    if ($physicalAdapters.Count -lt 1) {
                        throw (
                            "Operator node $nodeName network.physical_adapters " +
                            'must contain at least one adapter when supplied.'
                        )
                    }

                    foreach ($physicalAdapter in $physicalAdapters) {
                        if (
                            [string]::IsNullOrWhiteSpace(
                                [string]$physicalAdapter
                            )
                        ) {
                            throw (
                                "Operator node $nodeName network.physical_adapters " +
                                'may not contain an empty adapter name.'
                            )
                        }
                    }
                }

                if ($operatorNode.network.Contains('vlan_id')) {
                    $vlanId = 0

                    if (
                        -not [int]::TryParse(
                            [string]$operatorNode.network.vlan_id,
                            [ref]$vlanId
                        )
                    ) {
                        throw (
                            "Operator node $nodeName network.vlan_id " +
                            'must be an integer.'
                        )
                    }

                    if ($vlanId -lt 0 -or $vlanId -gt 4094) {
                        throw (
                            "Operator node $nodeName network.vlan_id " +
                            'must be between 0 and 4094.'
                        )
                    }
                }
            }

            if ($operatorNode.Contains('bootstrap_connection')) {
                if (
                    $operatorNode.bootstrap_connection -isnot
                    [System.Collections.IDictionary]
                ) {
                    throw (
                        "Operator node $nodeName bootstrap_connection must be a YAML map."
                    )
                }

                Assert-BootstrapConnection `
                    -BootstrapConnection $operatorNode.bootstrap_connection `
                    -NodeName $nodeName
            }

            if (
                $operatorNode.Contains('storage') -and
                $null -ne $operatorNode.storage
            ) {
                $storageAdapters = @($operatorNode.storage)

                foreach ($storageAdapter in $storageAdapters) {
                    if ($null -eq $storageAdapter) {
                        continue
                    }

                    if (
                        $storageAdapter -isnot
                        [System.Collections.IDictionary]
                    ) {
                        throw (
                            "Node $nodeName storage adapter entries must be YAML maps."
                        )
                    }

                    Assert-AllowedKeys `
                        -Object $storageAdapter `
                        -AllowedKeys @(
                            'network',
                            'adapter',
                            'adapters',
                            'ip',
                            'ip_address',
                            'prefix',
                            'prefix_length',
                            'gateway',
                            'vlan_id'
                        ) `
                        -Path "nodes.$nodeName.storage"

                    if (
                        $storageAdapter.Contains('adapters') -and
                        $null -ne $storageAdapter.adapters
                    ) {
                        foreach (
                            $storageAdapterName in
                            @($storageAdapter.adapters)
                        ) {
                            if (
                                [string]::IsNullOrWhiteSpace(
                                    [string]$storageAdapterName
                                )
                            ) {
                                throw (
                                    "Node $nodeName storage.adapters may not " +
                                    'contain an empty adapter name.'
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    if ($OperatorInput.Contains('dns')) {
        if ($OperatorInput.dns -isnot [System.Collections.IDictionary]) {
            throw 'Operator variables dns section must be a YAML map.'
        }

        Assert-AllowedKeys `
            -Object $OperatorInput.dns `
            -AllowedKeys @(
                'allowed_servers',
                'production_servers'
            ) `
            -Path 'dns'
    }

    if ($OperatorInput.Contains('ntp')) {
        if ($OperatorInput.ntp -isnot [System.Collections.IDictionary]) {
            throw 'Operator variables ntp section must be a YAML map.'
        }

        Assert-AllowedKeys `
            -Object $OperatorInput.ntp `
            -AllowedKeys @(
                'servers'
            ) `
            -Path 'ntp'
    }

    if ($OperatorInput.Contains('active_directory')) {
        if (
            $OperatorInput.active_directory -isnot
            [System.Collections.IDictionary]
        ) {
            throw 'Operator variables active_directory section must be a YAML map.'
        }

        Assert-AllowedKeys `
            -Object $OperatorInput.active_directory `
            -AllowedKeys @(
                'domain_fqdn',
                'validation_domain_controller',
                'require_prebootstrap_workgroup_state'
            ) `
            -Path 'active_directory'

        if ($OperatorInput.active_directory.Contains('domain_fqdn')) {
            $domainFqdn = [string]$OperatorInput.active_directory.domain_fqdn

            if ([string]::IsNullOrWhiteSpace($domainFqdn)) {
                throw (
                    'active_directory.domain_fqdn must not be empty when supplied.'
                )
            }

            if (
                $domainFqdn -notmatch
                '^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
            ) {
                throw (
                    'active_directory.domain_fqdn must be a valid DNS domain name.'
                )
            }
        }

        if (
            $OperatorInput.active_directory.Contains(
                'require_prebootstrap_workgroup_state'
            )
        ) {
            $workgroupState = $OperatorInput.active_directory.
                require_prebootstrap_workgroup_state

            if ($workgroupState -isnot [bool]) {
                throw (
                    'active_directory.require_prebootstrap_workgroup_state ' +
                    'must be a Boolean value.'
                )
            }
        }
    }

    if ($OperatorInput.Contains('execution_hosts')) {
        $executionHosts = @($OperatorInput.execution_hosts)

        if ($executionHosts.Count -lt 1) {
            throw (
                'operator variables execution_hosts must contain at least one host.'
            )
        }

        foreach ($executionHost in $executionHosts) {
            if (
                $executionHost -isnot
                [System.Collections.IDictionary]
            ) {
                throw 'Each execution_hosts entry must be a YAML map.'
            }

            $executionHostId = [string]$executionHost.id

            if ([string]::IsNullOrWhiteSpace($executionHostId)) {
                throw 'Each execution_hosts entry requires id.'
            }

            Assert-AllowedKeys `
                -Object $executionHost `
                -AllowedKeys @(
                    'id',
                    'display_name',
                    'computer_name',
                    'hosting_site',
                    'transport',
                    'package_root',
                    'artifacts_path',
                    'allowed_sites',
                    'require_matching_release_manifest',
                    'require_package_integrity_check'
                ) `
                -Path "execution_hosts.$executionHostId"

            if (
                -not $executionHost.Contains('transport') -or
                $executionHost.transport -isnot
                [System.Collections.IDictionary]
            ) {
                throw (
                    "execution_hosts.$executionHostId.transport must be a YAML map."
                )
            }

            Assert-AllowedKeys `
                -Object $executionHost.transport `
                -AllowedKeys @(
                    'primary',
                    'winrm_port',
                    'ssh_available'
                ) `
                -Path "execution_hosts.$executionHostId.transport"

            if (
                -not $executionHost.Contains('allowed_sites') -or
                @($executionHost.allowed_sites).Count -lt 1
            ) {
                throw (
                    "execution_hosts.$executionHostId.allowed_sites must contain at least one site."
                )
            }

            $operatorSiteName = [string]$OperatorInput.site.name

            if (
                @($executionHost.allowed_sites) -notcontains
                $operatorSiteName
            ) {
                throw (
                    "execution_hosts.$executionHostId.allowed_sites must include " +
                    "site $operatorSiteName."
                )
            }
        }
    }

    if (
        $OperatorInput.Contains('site') -and
        $OperatorInput.site.Contains('topology') -and
        $OperatorInput.Contains('nodes')
    ) {
        $declaredNodeCount = [int]$OperatorInput.site.topology.phase1_node_count
        $actualNodeCount = @($OperatorInput.nodes).Count

        if ($declaredNodeCount -ne $actualNodeCount) {
            throw (
                "site.topology.phase1_node_count $declaredNodeCount does not " +
                "match nodes count $actualNodeCount."
            )
        }
    }
}

$defaultsPath = Join-Path $PackageRoot 'protected\defaults.yaml'

$siteProfilesPath = Join-Path `
    $PackageRoot `
    'protected\site-profiles.yaml'

$adapterPath = Join-Path $PackageRoot 'protected\adapters.yaml'

$phaseManifestPath = Join-Path `
    $PackageRoot `
    'protected\phase-manifest.yaml'

$operatorInputPath = Join-Path $PackageRoot (
    "operator-inputs\$Site.variables.yaml"
)

$defaults = Read-YamlFile -Path $defaultsPath
$siteProfiles = Read-YamlFile -Path $siteProfilesPath
$adapters = Read-YamlFile -Path $adapterPath
$phaseManifest = Read-YamlFile -Path $phaseManifestPath
$operatorInput = Read-YamlFile -Path $operatorInputPath

Assert-OperatorInputAllowed -OperatorInput $operatorInput

$operatorSite = Get-ConfigValue `
    -Object $operatorInput `
    -Name 'site'

$operatorSiteName = [string](
    Get-ConfigValue `
        -Object $operatorSite `
        -Name 'name'
)

$requestedProfileName = [string](
    Get-ConfigValue `
        -Object $operatorSite `
        -Name 'profile'
)

if ([string]::IsNullOrWhiteSpace($operatorSiteName)) {
    throw 'Operator variables site.name is required.'
}

$selectedSiteProfile = Get-ResolvedSiteProfile `
    -SiteProfiles $siteProfiles `
    -SiteName $operatorSiteName `
    -RequestedProfileName $requestedProfileName

$baselineSelection = Merge-FactoryObject `
    -Base $defaults `
    -Overlay $selectedSiteProfile.Overrides

$selectedHardware = Get-ConfigValue `
    -Object $baselineSelection `
    -Name 'hardware'

if ($selectedHardware -isnot [System.Collections.IDictionary]) {
    throw 'Resolved hardware configuration must be a YAML map.'
}

$baselineFile = [string](
    Get-ConfigValue `
        -Object $selectedHardware `
        -Name 'baseline_file'
)

$hardwareBaseline = Read-HardwareBaseline `
    -PackageRoot $PackageRoot `
    -BaselineFile $baselineFile

$defaultsWithHardwareBaseline = Merge-FactoryObject `
    -Base $defaults `
    -Overlay $hardwareBaseline.Content

$effectiveDefaults = Merge-FactoryObject `
    -Base $defaultsWithHardwareBaseline `
    -Overlay $selectedSiteProfile.Overrides

$resolvedConfiguration = Merge-FactoryObject `
    -Base $effectiveDefaults `
    -Overlay $operatorInput

if (
    $effectiveDefaults.Contains('nodes') -and
    $operatorInput.Contains('nodes')
) {
    $resolvedConfiguration.nodes = Merge-NodesByName `
        -DefaultNodes @($effectiveDefaults.nodes) `
        -OperatorNodes @($operatorInput.nodes)
}

foreach ($node in @($resolvedConfiguration.nodes)) {
    if ($node -isnot [System.Collections.IDictionary]) {
        throw 'Each resolved node entry must be a YAML map.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$node.name)) {
        throw 'Each resolved node entry requires name.'
    }

    Normalize-BootstrapConnection -Node $node
    Normalize-ManagementAddress -Node $node
    Normalize-StorageIpAddress -Node $node
}

$phaseOne = @(
    $phaseManifest.workflow.phases |
        Where-Object {
            [int]$_.id -eq 1
        }
)

if ($phaseOne.Count -ne 1) {
    throw 'Phase manifest must contain exactly one Phase 1 definition.'
}

$resolvedConfiguration.site_profile = [ordered]@{
    name = $selectedSiteProfile.Name
}

$packageRootFullPath = [IO.Path]::GetFullPath(
    $PackageRoot
).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)

$resolvedConfiguration.hardware_baseline = [ordered]@{
    path = (
        [IO.Path]::GetRelativePath(
            $packageRootFullPath,
            $hardwareBaseline.Path
        ).Replace('\', '/')
    )
}

$resolvedConfiguration.adapters = $adapters.adapters

$resolvedConfiguration.workflow = [ordered]@{
    phases = $phaseManifest.workflow.phases
    stages = $phaseOne[0].stages
}

$releaseManifestPath = Join-Path `
    $PackageRoot `
    'protected\release-manifest.json'

$releaseVersionPath = Join-Path `
    $PackageRoot `
    'protected\release-version.json'

if (-not (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf)) {
    throw "Release manifest does not exist: $releaseManifestPath"
}

if (-not (Test-Path -LiteralPath $releaseVersionPath -PathType Leaf)) {
    throw "Release version file does not exist: $releaseVersionPath"
}

$releaseManifestHash = (
    Get-FileHash `
        -LiteralPath $releaseManifestPath `
        -Algorithm SHA256
).Hash

$releaseVersion = Get-Content `
    -LiteralPath $releaseVersionPath `
    -Raw |
    ConvertFrom-Json `
    -AsHashtable

$resolvedConfiguration.release = [ordered]@{
    version = $releaseVersion.releaseVersion
    manifest_sha256 = $releaseManifestHash
    manifest_path = 'protected/release-manifest.json'
}

$resolvedDirectory = Join-Path $ArtifactsPath "resolved\$Site"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $resolvedDirectory |
    Out-Null

$resolvedPath = Join-Path $resolvedDirectory (
    "resolved-$Site-$([datetime]::UtcNow.ToString('yyyyMMddTHHmmss')).yaml"
)

if ($null -eq (Get-Command -Name ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
    throw (
        'powershell-yaml ConvertTo-Yaml is required to create resolved runtime configuration.'
    )
}

$resolvedConfiguration |
    ConvertTo-Yaml |
    Set-Content `
        -LiteralPath $resolvedPath `
        -Encoding utf8

$configHash = (
    Get-FileHash `
        -LiteralPath $resolvedPath `
        -Algorithm SHA256
).Hash

return [pscustomobject]@{
    Site = $Site
    SiteProfile = $selectedSiteProfile.Name
    HardwareBaselinePath = $hardwareBaseline.Path
    OperatorInputPath = $operatorInputPath
    ResolvedConfigPath = $resolvedPath
    ResolvedConfigHash = $configHash
    PhaseManifestPath = $phaseManifestPath
    DefaultsPath = $defaultsPath
    SiteProfilesPath = $siteProfilesPath
    AdapterConfiguration = $adapterPath
}