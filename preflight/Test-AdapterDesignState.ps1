#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

function Get-AdapterValue {
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

$deployment = Get-AdapterValue `
    -Object $Context.Config `
    -Name 'deployment'

$singleServer = Get-AdapterValue `
    -Object $deployment `
    -Name 'single_server'

$isSingleServer = (
    (Get-AdapterValue `
        -Object $singleServer `
        -Name 'enabled') -eq $true
)

$profileHardware = Get-AdapterValue `
    -Object $Context.Config `
    -Name 'hardware'

$convergedSwitch = Get-AdapterValue `
    -Object $profileHardware `
    -Name 'converged_switch'

$managementVnic = Get-AdapterValue `
    -Object $profileHardware `
    -Name 'management_vnic'

if ($isSingleServer -and $null -ne $convergedSwitch) {
    $switchName = [string](
        Get-AdapterValue `
            -Object $convergedSwitch `
            -Name 'name'
    )

    $expectedUplinks = @(
        Get-AdapterValue `
            -Object $convergedSwitch `
            -Name 'uplink_adapters'
    )

    $expectedTeamMode = [string](
        Get-AdapterValue `
            -Object $convergedSwitch `
            -Name 'teaming_mode'
    )

    $expectedLoadBalancing = [string](
        Get-AdapterValue `
            -Object $convergedSwitch `
            -Name 'load_balancing_algorithm'
    )

    $managementVnicName = [string](
        Get-AdapterValue `
            -Object $managementVnic `
            -Name 'name'
    )

    $expectedVlanMode = [string](
        Get-AdapterValue `
            -Object $managementVnic `
            -Name 'vlan_mode'
    )

    $expectedVlanId = [int](
        Get-AdapterValue `
            -Object $managementVnic `
            -Name 'vlan_id'
    )

    $result = Invoke-ManagementPlaneCommand `
        -Context $Context `
        -OperationName 'Test-AdapterDesignState' `
        -ArgumentList @(
            $switchName,
            $expectedUplinks,
            $expectedTeamMode,
            $expectedLoadBalancing,
            $managementVnicName,
            $expectedVlanMode,
            $expectedVlanId
        ) `
        -ScriptBlock {
            param(
                [string]$SwitchName,
                [string[]]$ExpectedUplinks,
                [string]$ExpectedTeamMode,
                [string]$ExpectedLoadBalancing,
                [string]$ManagementVnicName,
                [string]$ExpectedVlanMode,
                [int]$ExpectedVlanId
            )

            $switchTeam = Get-VMSwitchTeam `
                -Name $SwitchName `
                -ErrorAction Stop

            $expectedAdapterRecords = @(
                foreach ($expectedUplink in $ExpectedUplinks) {
                    $adapter = Get-NetAdapter `
                        -Name $expectedUplink `
                        -ErrorAction Stop

                    [pscustomobject]@{
                        Name = $adapter.Name
                        InterfaceGuid = ([guid]$adapter.InterfaceGuid).ToString('D')
                    }
                }
            )

            $expectedGuids = @(
                $expectedAdapterRecords |
                    ForEach-Object {
                        $_.InterfaceGuid
                    } |
                    Sort-Object
            )

            $actualGuids = @(
                $switchTeam.NetAdapterInterfaceGuid |
                    ForEach-Object {
                        ([guid]$_).ToString('D')
                    } |
                    Sort-Object
            )

            $actualUplinks = @(
                foreach ($actualGuid in $actualGuids) {
                    $matchingAdapter = @(
                        $expectedAdapterRecords |
                            Where-Object {
                                $_.InterfaceGuid -eq $actualGuid
                            }
                    ) |
                        Select-Object -First 1

                    if ($null -ne $matchingAdapter) {
                        $matchingAdapter.Name
                    }
                    else {
                        "UnmappedInterfaceGuid:$actualGuid"
                    }
                }
            )

            if (
                $actualGuids.Count -ne $expectedGuids.Count -or
                @(
                    $actualGuids |
                        Where-Object {
                            $expectedGuids -notcontains $_
                        }
                ).Count -gt 0
            ) {
                throw (
                    "Converged switch $SwitchName uplinks are " +
                    "$($actualUplinks -join ', '); expected " +
                    "$($ExpectedUplinks -join ', ')."
                )
            }

            if ([string]$switchTeam.TeamingMode -ne $ExpectedTeamMode) {
                throw (
                    "Converged switch $SwitchName teaming mode is " +
                    "$($switchTeam.TeamingMode); expected $ExpectedTeamMode."
                )
            }

            if (
                [string]$switchTeam.LoadBalancingAlgorithm -ne
                $ExpectedLoadBalancing
            ) {
                throw (
                    "Converged switch $SwitchName load-balancing algorithm is " +
                    "$($switchTeam.LoadBalancingAlgorithm); expected " +
                    "$ExpectedLoadBalancing."
                )
            }

            $managementAdapter = Get-NetAdapter `
                -Name $ManagementVnicName `
                -ErrorAction Stop

            if ($managementAdapter.Status -ne 'Up') {
                throw (
                    "Management vNIC $ManagementVnicName is $($managementAdapter.Status); " +
                    'expected Up.'
                )
            }

            $vlan = Get-VMNetworkAdapterVlan `
                -ManagementOS `
                -VMNetworkAdapterName $ManagementVnicName `
                -ErrorAction Stop

            if (
                [string]$vlan.OperationMode -ne $ExpectedVlanMode -or
                [int]$vlan.AccessVlanId -ne $ExpectedVlanId
            ) {
                throw (
                    "Management vNIC $ManagementVnicName VLAN state is " +
                    "OperationMode=$($vlan.OperationMode), " +
                    "AccessVlanId=$($vlan.AccessVlanId); expected " +
                    "OperationMode=$ExpectedVlanMode, AccessVlanId=$ExpectedVlanId."
                )
            }

            [pscustomobject]@{
                ComputerName          = $env:COMPUTERNAME
                SwitchName            = $switchTeam.Name
                TeamingMode           = [string]$switchTeam.TeamingMode
                LoadBalancingAlgorithm = [string]$switchTeam.LoadBalancingAlgorithm
                Uplinks               = $actualUplinks
                ManagementVnic        = $managementAdapter.Name
                ManagementVnicStatus  = $managementAdapter.Status
                OperationMode         = [string]$vlan.OperationMode
                AccessVlanId          = [int]$vlan.AccessVlanId
            }
        }

    $data = @($result.Data) |
        Select-Object -First 1

    return [pscustomobject]@{
        Passed                          = $true
        Check                           = 'Test-AdapterDesignState'
        Node                            = $result.Node
        ManagementIp                    = $result.ManagementIp
        MappedAdapters                  = @()
        RequiredEnabledAdapters         = @(
            [pscustomobject]@{
                AdapterName = $data.ManagementVnic
                Status = $data.ManagementVnicStatus
                Enabled = ($data.ManagementVnicStatus -eq 'Up')
            }
        )
        DisabledPatternAdapters         = @()
        EmbeddedAdapters                = @()
        AcceptableDisabledAdapterStates = @()
        Summary                         = (
            "CNEF converged SET $($data.SwitchName) validated with uplinks " +
            "$($data.Uplinks -join ', '), management vNIC " +
            "$($data.ManagementVnic), and $($data.OperationMode) VLAN " +
            "$($data.AccessVlanId)."
        )
        ValidatedAt                     = [datetime]::UtcNow.ToString('o')
    }
}

$hardware = Get-AdapterValue `
    -Object $Context.Config `
    -Name 'hardware'

$nicMapping = Get-AdapterValue `
    -Object $hardware `
    -Name 'nic_mapping'

$disabledEmbeddedAdapterPattern = [string](
    Get-AdapterValue `
        -Object $hardware `
        -Name 'disabled_embedded_adapter_pattern'
)

$acceptableDisabledAdapterStatuses = @(
    Get-AdapterValue `
        -Object $hardware `
        -Name 'acceptable_disabled_adapter_statuses'
)

if ($acceptableDisabledAdapterStatuses.Count -lt 1) {
    $acceptableDisabledAdapterStatuses = @(
        'Disabled'
    )
}

$network = Get-AdapterValue `
    -Object $Context.Config `
    -Name 'network'

$adapterState = Get-AdapterValue `
    -Object $network `
    -Name 'adapter_state'

$requiredEnabled = @(
    Get-AdapterValue `
        -Object $adapterState `
        -Name 'required_enabled'
)

$requiredDisabledPatterns = @(
    Get-AdapterValue `
        -Object $adapterState `
        -Name 'required_disabled_patterns'
)

if ($null -eq $nicMapping) {
    throw 'hardware.nic_mapping is required.'
}

if ($requiredEnabled.Count -lt 1) {
    throw 'network.adapter_state.required_enabled is required.'
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-AdapterDesignState' `
    -ArgumentList @(
        $nicMapping,
        $disabledEmbeddedAdapterPattern,
        $requiredEnabled,
        $requiredDisabledPatterns,
        $acceptableDisabledAdapterStatuses
    ) `
    -ScriptBlock {
        param(
            [object]$ExpectedNicMapping,
            [string]$DisabledEmbeddedAdapterPattern,
            [string[]]$RequiredEnabled,
            [string[]]$RequiredDisabledPatterns,
            [string[]]$AcceptableDisabledAdapterStatuses
        )

        $hardwareInfo = @(
            Get-NetAdapterHardwareInfo -ErrorAction Stop
        )

        $mappedAdapters = [System.Collections.Generic.List[object]]::new()

        foreach ($mappingName in $ExpectedNicMapping.Keys) {
            $mapping = $ExpectedNicMapping[$mappingName]

            $expectedName = [string]$mapping.expected_name
            $expectedSlot = [int]$mapping.pci_slot
            $expectedFunction = [int]$mapping.pci_function
            $minimumLinkSpeedGbps = $mapping.minimum_link_speed_gbps

            $matches = @(
                $hardwareInfo |
                    Where-Object {
                        [int]$_.Slot -eq $expectedSlot -and
                        [int]$_.Function -eq $expectedFunction
                    }
            )

            if ($matches.Count -ne 1) {
                throw (
                    "NIC mapping $mappingName expected one adapter at " +
                    "slot $expectedSlot function $expectedFunction; found " +
                    "$($matches.Count)."
                )
            }

            $adapter = Get-NetAdapter `
                -Name $matches[0].Name `
                -ErrorAction Stop

            if ($adapter.Name -ne $expectedName) {
                throw (
                    "NIC mapping $mappingName at slot $expectedSlot function " +
                    "$expectedFunction is named $($adapter.Name); expected " +
                    "$expectedName."
                )
            }

            if ($adapter.Status -eq 'Disabled') {
                throw (
                    "Mapped deployment adapter $expectedName is Disabled. " +
                    'It must be enabled for deployment.'
                )
            }

            if ($null -ne $minimumLinkSpeedGbps) {
                $speedMatch = [regex]::Match(
                    [string]$adapter.LinkSpeed,
                    '(\d+(\.\d+)?)'
                )

                if (-not $speedMatch.Success) {
                    throw (
                        "Unable to parse link speed $($adapter.LinkSpeed) " +
                        "for adapter $expectedName."
                    )
                }

                $actualLinkSpeedGbps = [decimal]$speedMatch.Groups[1].Value

                if ($actualLinkSpeedGbps -lt [decimal]$minimumLinkSpeedGbps) {
                    throw (
                        "Adapter $expectedName link speed is " +
                        "$actualLinkSpeedGbps Gbps; minimum required is " +
                        "$minimumLinkSpeedGbps Gbps."
                    )
                }
            }

            $mappedAdapters.Add([pscustomobject]@{
                MappingName          = $mappingName
                AdapterName          = $adapter.Name
                Status               = $adapter.Status
                LinkSpeed            = $adapter.LinkSpeed
                InterfaceDescription = $adapter.InterfaceDescription
                Slot                 = $matches[0].Slot
                Function             = $matches[0].Function
            })
        }

        $requiredEnabledResults = [System.Collections.Generic.List[object]]::new()

        foreach ($adapterName in $RequiredEnabled) {
            $adapter = Get-NetAdapter `
                -Name $adapterName `
                -ErrorAction Stop

            if ($adapter.Status -eq 'Disabled') {
                throw (
                    "Required deployment adapter $adapterName is Disabled; " +
                    'expected enabled.'
                )
            }

            $requiredEnabledResults.Add([pscustomobject]@{
                AdapterName = $adapter.Name
                Status      = $adapter.Status
                Enabled     = ($adapter.Status -ne 'Disabled')
            })
        }

        $disabledPatternResults = [System.Collections.Generic.List[object]]::new()

        foreach ($pattern in $RequiredDisabledPatterns) {
            if ([string]::IsNullOrWhiteSpace($pattern)) {
                continue
            }

            $matchingAdapters = @(
                Get-NetAdapter -ErrorAction Stop |
                    Where-Object {
                        $_.Name -like $pattern -or
                        $_.InterfaceDescription -like $pattern
                    }
            )

            foreach ($adapter in $matchingAdapters) {
                if ($adapter.Status -notin $AcceptableDisabledAdapterStatuses) {
                    throw (
                        "Adapter design validation failed. AdapterName='$($adapter.Name)'; " +
                        "InterfaceDescription='$($adapter.InterfaceDescription)'; " +
                        "RequiredDisabledPattern='$pattern'; " +
                        "CurrentStatus='$($adapter.Status)'; " +
                        "ConfiguredAcceptableInactiveStates='$($AcceptableDisabledAdapterStatuses -join ', ')'. " +
                        "Expected the adapter to be in an approved inactive state."
                    )
                }

                $disabledPatternResults.Add([pscustomobject]@{
                    Pattern              = $pattern
                    AdapterName          = $adapter.Name
                    Status               = $adapter.Status
                    InterfaceDescription = $adapter.InterfaceDescription
                    Accepted             = $true
                })
            }
        }

        $embeddedAdapters = @()

        if (-not [string]::IsNullOrWhiteSpace(
                $DisabledEmbeddedAdapterPattern
            )) {
            $embeddedAdapters = @(
                Get-NetAdapter -ErrorAction Stop |
                    Where-Object {
                        $_.InterfaceDescription -like $DisabledEmbeddedAdapterPattern
                    }
            )

            foreach ($embeddedAdapter in $embeddedAdapters) {
                if ($embeddedAdapter.Status -notin $AcceptableDisabledAdapterStatuses) {
                    throw (
                        "Embedded adapter validation failed. AdapterName='$($embeddedAdapter.Name)'; " +
                        "InterfaceDescription='$($embeddedAdapter.InterfaceDescription)'; " +
                        "RequiredDisabledPattern='$DisabledEmbeddedAdapterPattern'; " +
                        "CurrentStatus='$($embeddedAdapter.Status)'; " +
                        "ConfiguredAcceptableInactiveStates='$($AcceptableDisabledAdapterStatuses -join ', ')'. " +
                        "Expected the embedded adapter to be in an approved inactive state."
                    )
                }
            }
        }

        [pscustomobject]@{
            ComputerName                    = $env:COMPUTERNAME
            MappedAdapters                  = $mappedAdapters.ToArray()
            RequiredEnabledAdapters         = $requiredEnabledResults.ToArray()
            DisabledPatternAdapters         = $disabledPatternResults.ToArray()
            EmbeddedAdapters                = @(
                $embeddedAdapters |
                    Select-Object Name, Status, InterfaceDescription
            )
            AcceptableDisabledAdapterStates = $AcceptableDisabledAdapterStatuses
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

return [pscustomobject]@{
    Passed                          = $true
    Check                           = 'Test-AdapterDesignState'
    Node                            = $result.Node
    ManagementIp                    = $result.ManagementIp
    MappedAdapters                  = $data.MappedAdapters
    RequiredEnabledAdapters         = $data.RequiredEnabledAdapters
    DisabledPatternAdapters         = $data.DisabledPatternAdapters
    EmbeddedAdapters                = $data.EmbeddedAdapters
    AcceptableDisabledAdapterStates = $data.AcceptableDisabledAdapterStates
    Summary                         = (
        "$(@($data.MappedAdapters).Count) NIC mapping(s), " +
        "$(@($data.RequiredEnabledAdapters).Count) required enabled adapter(s), " +
        "$(@($data.DisabledPatternAdapters).Count) required disabled-pattern " +
        "adapter(s), and $(@($data.EmbeddedAdapters).Count) embedded adapter(s) validated."
    )
    ValidatedAt                     = [datetime]::UtcNow.ToString('o')
}