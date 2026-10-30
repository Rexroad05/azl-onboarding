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

$hardware = Get-AdapterValue `
    -Object $Context.Config `
    -Name 'hardware'

$network = Get-AdapterValue `
    -Object $Context.Config `
    -Name 'network'

$adapterValidation = Get-AdapterValue `
    -Object $hardware `
    -Name 'adapter_validation'

$validationMode = [string](
    Get-AdapterValue `
        -Object $adapterValidation `
        -Name 'mode'
)

if ($validationMode -notin @(
    'RoleMapped',
    'ConvergedSwitch'
)) {
    throw (
        'hardware.adapter_validation.mode must be RoleMapped or ConvergedSwitch.'
    )
}

$requireStorageMappingWhenEnabled = (
    Get-AdapterValue `
        -Object $adapterValidation `
        -Name 'require_storage_mapping_when_storage_enabled'
) -eq $true

$networkAdapter = Get-AdapterValue `
    -Object $hardware `
    -Name 'network_adapter'

$minimumPhysicalLinkSpeedGbps = Get-AdapterValue `
    -Object $networkAdapter `
    -Name 'minimum_link_speed_gbps'

if ($null -eq $minimumPhysicalLinkSpeedGbps) {
    $minimumPhysicalLinkSpeedGbps = 1
}

$nicMapping = Get-AdapterValue `
    -Object $hardware `
    -Name 'nic_mapping'

$storageNicMapping = Get-AdapterValue `
    -Object $hardware `
    -Name 'storage_nic_mapping'

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
        'Disabled',
        'Not Present'
    )
}

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

$storage = Get-AdapterValue `
    -Object $network `
    -Name 'storage'

$storageIntent = [string](
    Get-AdapterValue `
        -Object $storage `
        -Name 'intent'
)

if ([string]::IsNullOrWhiteSpace($storageIntent)) {
    $storageIntent = 'None'
}

$convergedSwitch = Get-AdapterValue `
    -Object $hardware `
    -Name 'converged_switch'

$managementVnic = Get-AdapterValue `
    -Object $hardware `
    -Name 'management_vnic'

if ($validationMode -eq 'RoleMapped') {
    if (
        $null -eq $nicMapping -or
        @($nicMapping.Keys).Count -lt 1
    ) {
        throw (
            'RoleMapped adapter validation requires hardware.nic_mapping.'
        )
    }
}

if ($validationMode -eq 'ConvergedSwitch') {
    if ($null -eq $convergedSwitch) {
        throw (
            'ConvergedSwitch adapter validation requires hardware.converged_switch.'
        )
    }

    if ($null -eq $managementVnic) {
        throw (
            'ConvergedSwitch adapter validation requires hardware.management_vnic.'
        )
    }
}

if (
    $validationMode -eq 'ConvergedSwitch' -and
    $storageIntent -ne 'None' -and
    $requireStorageMappingWhenEnabled -and
    (
        $null -eq $storageNicMapping -or
        @($storageNicMapping.Keys).Count -lt 1
    )
) {
    throw (
        "Storage intent $storageIntent requires hardware.storage_nic_mapping " +
        'for the selected ConvergedSwitch hardware baseline.'
    )
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-AdapterDesignState' `
    -ArgumentList @(
        $validationMode,
        $nicMapping,
        $storageNicMapping,
        [string[]]$requiredEnabled,
        [string[]]$requiredDisabledPatterns,
        [string[]]$acceptableDisabledAdapterStatuses,
        $disabledEmbeddedAdapterPattern,
        [decimal]$minimumPhysicalLinkSpeedGbps,
        $storageIntent,
        [bool]$requireStorageMappingWhenEnabled,
        $convergedSwitch,
        $managementVnic
    ) `
    -ScriptBlock {
        param(
            [string]$ValidationMode,
            [object]$ExpectedNicMapping,
            [object]$StorageNicMapping,
            [string[]]$RequiredEnabled,
            [string[]]$RequiredDisabledPatterns,
            [string[]]$AcceptableDisabledAdapterStatuses,
            [string]$DisabledEmbeddedAdapterPattern,
            [decimal]$MinimumPhysicalLinkSpeedGbps,
            [string]$StorageIntent,
            [bool]$RequireStorageMappingWhenEnabled,
            [object]$ConvergedSwitch,
            [object]$ManagementVnic
        )

        function Get-LinkSpeedGbps {
            param(
                [Parameter(Mandatory)]
                [object]$Adapter
            )

            $speedMatch = [regex]::Match(
                [string]$Adapter.LinkSpeed,
                '(\d+(\.\d+)?)'
            )

            if (-not $speedMatch.Success) {
                throw (
                    "Unable to parse link speed $($Adapter.LinkSpeed) " +
                    "for adapter $($Adapter.Name)."
                )
            }

            return [decimal]$speedMatch.Groups[1].Value
        }

        function Test-RoleMappedNicSet {
            param(
                [Parameter(Mandatory)]
                [object]$Mapping,

                [Parameter(Mandatory)]
                [string]$MappingLabel
            )

            $hardwareInfo = @(
                Get-NetAdapterHardwareInfo `
                    -ErrorAction Stop
            )

            $results = [System.Collections.Generic.List[object]]::new()

            foreach ($mappingName in $Mapping.Keys) {
                $mappingEntry = $Mapping[$mappingName]

                $expectedName = [string]$mappingEntry.expected_name
                $expectedSlot = [int]$mappingEntry.pci_slot
                $expectedFunction = [int]$mappingEntry.pci_function
                $minimumLinkSpeedGbps = $mappingEntry.minimum_link_speed_gbps

                $matches = @(
                    $hardwareInfo |
                        Where-Object {
                            [int]$_.Slot -eq $expectedSlot -and
                            [int]$_.Function -eq $expectedFunction
                        }
                )

                if ($matches.Count -ne 1) {
                    throw (
                        "$MappingLabel mapping $mappingName expected one adapter at " +
                        "slot $expectedSlot function $expectedFunction; found " +
                        "$($matches.Count)."
                    )
                }

                $adapter = Get-NetAdapter `
                    -Name $matches[0].Name `
                    -ErrorAction Stop

                if ($adapter.Name -ne $expectedName) {
                    throw (
                        "$MappingLabel mapping $mappingName at slot $expectedSlot " +
                        "function $expectedFunction is named $($adapter.Name); " +
                        "expected $expectedName."
                    )
                }

                if ($adapter.Status -ne 'Up') {
                    throw (
                        "$MappingLabel adapter $expectedName is $($adapter.Status); " +
                        'expected Up.'
                    )
                }

                $actualLinkSpeedGbps = Get-LinkSpeedGbps `
                    -Adapter $adapter

                if (
                    $null -ne $minimumLinkSpeedGbps -and
                    $actualLinkSpeedGbps -lt [decimal]$minimumLinkSpeedGbps
                ) {
                    throw (
                        "$MappingLabel adapter $expectedName link speed is " +
                        "$actualLinkSpeedGbps Gbps; minimum required speed is " +
                        "$minimumLinkSpeedGbps Gbps."
                    )
                }

                $results.Add([pscustomobject]@{
                    MappingLabel         = $MappingLabel
                    MappingName          = $mappingName
                    AdapterName          = $adapter.Name
                    Status               = $adapter.Status
                    LinkSpeed            = $adapter.LinkSpeed
                    LinkSpeedGbps        = $actualLinkSpeedGbps
                    InterfaceDescription = $adapter.InterfaceDescription
                    Slot                 = $matches[0].Slot
                    Function             = $matches[0].Function
                })
            }

            return $results.ToArray()
        }

        $mappedAdapters = @()
        $storageMappedAdapters = @()
        $convergedSwitchResult = $null

        if ($ValidationMode -eq 'RoleMapped') {
            $mappedAdapters = Test-RoleMappedNicSet `
                -Mapping $ExpectedNicMapping `
                -MappingLabel 'RoleMapped'
        }

        $requiredEnabledResults = [System.Collections.Generic.List[object]]::new()

        foreach ($adapterName in $RequiredEnabled) {
            $adapter = Get-NetAdapter `
                -Name $adapterName `
                -ErrorAction Stop

            if ($adapter.Status -ne 'Up') {
                throw (
                    "Required deployment adapter $adapterName is " +
                    "$($adapter.Status); expected Up."
                )
            }

            $requiredEnabledResults.Add([pscustomobject]@{
                AdapterName = $adapter.Name
                Status      = $adapter.Status
                Enabled     = $true
                LinkSpeed   = $adapter.LinkSpeed
            })
        }

        if ($ValidationMode -eq 'ConvergedSwitch') {
            $switchName = [string]$ConvergedSwitch.name
            $expectedUplinks = @($ConvergedSwitch.uplink_adapters)
            $expectedTeamMode = [string]$ConvergedSwitch.teaming_mode
            $expectedLoadBalancing = [string]$ConvergedSwitch.load_balancing_algorithm

            $managementVnicName = [string]$ManagementVnic.name
            $expectedVlanMode = [string]$ManagementVnic.vlan_mode
            $expectedVlanId = [int]$ManagementVnic.vlan_id

            if ([string]::IsNullOrWhiteSpace($switchName)) {
                throw 'ConvergedSwitch validation requires a switch name.'
            }

            if ($expectedUplinks.Count -lt 1) {
                throw 'ConvergedSwitch validation requires one or more uplink adapters.'
            }

            $switchTeam = Get-VMSwitchTeam `
                -Name $switchName `
                -ErrorAction Stop

            $expectedAdapterRecords = @(
                foreach ($expectedUplink in $expectedUplinks) {
                    $adapter = Get-NetAdapter `
                        -Name $expectedUplink `
                        -ErrorAction Stop

                    if ($adapter.Status -ne 'Up') {
                        throw (
                            "Expected converged-switch uplink $expectedUplink is " +
                            "$($adapter.Status); expected Up."
                        )
                    }

                    $actualLinkSpeedGbps = Get-LinkSpeedGbps `
                        -Adapter $adapter

                    if ($actualLinkSpeedGbps -lt $MinimumPhysicalLinkSpeedGbps) {
                        throw (
                            "Converged-switch uplink $expectedUplink link speed is " +
                            "$actualLinkSpeedGbps Gbps; minimum required speed is " +
                            "$MinimumPhysicalLinkSpeedGbps Gbps."
                        )
                    }

                    [pscustomobject]@{
                        Name          = $adapter.Name
                        InterfaceGuid = ([guid]$adapter.InterfaceGuid).ToString('D')
                        LinkSpeed     = $adapter.LinkSpeed
                        LinkSpeedGbps = $actualLinkSpeedGbps
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
                    "Converged switch $switchName does not contain the expected " +
                    "uplinks: $($expectedUplinks -join ', ')."
                )
            }

            if ([string]$switchTeam.TeamingMode -ne $expectedTeamMode) {
                throw (
                    "Converged switch $switchName teaming mode is " +
                    "$($switchTeam.TeamingMode); expected $expectedTeamMode."
                )
            }

            if (
                [string]$switchTeam.LoadBalancingAlgorithm -ne
                $expectedLoadBalancing
            ) {
                throw (
                    "Converged switch $switchName load-balancing algorithm is " +
                    "$($switchTeam.LoadBalancingAlgorithm); expected " +
                    "$expectedLoadBalancing."
                )
            }

            $managementAdapter = Get-NetAdapter `
                -Name $managementVnicName `
                -ErrorAction Stop

            if ($managementAdapter.Status -ne 'Up') {
                throw (
                    "Management vNIC $managementVnicName is " +
                    "$($managementAdapter.Status); expected Up."
                )
            }

            $vlan = Get-VMNetworkAdapterVlan `
                -ManagementOS `
                -VMNetworkAdapterName $managementVnicName `
                -ErrorAction Stop

            if (
                [string]$vlan.OperationMode -ne $expectedVlanMode -or
                [int]$vlan.AccessVlanId -ne $expectedVlanId
            ) {
                throw (
                    "Management vNIC $managementVnicName VLAN state is " +
                    "OperationMode=$($vlan.OperationMode), " +
                    "AccessVlanId=$($vlan.AccessVlanId); expected " +
                    "OperationMode=$expectedVlanMode, AccessVlanId=$expectedVlanId."
                )
            }

            if (
                $StorageIntent -ne 'None' -and
                $RequireStorageMappingWhenEnabled
            ) {
                if (
                    $null -eq $StorageNicMapping -or
                    @($StorageNicMapping.Keys).Count -lt 1
                ) {
                    throw (
                        "Storage intent $StorageIntent requires an explicit " +
                        'hardware.storage_nic_mapping.'
                    )
                }

                $storageMappedAdapters = Test-RoleMappedNicSet `
                    -Mapping $StorageNicMapping `
                    -MappingLabel 'Storage'
            }

            $convergedSwitchResult = [pscustomobject]@{
                SwitchName             = $switchTeam.Name
                TeamingMode            = [string]$switchTeam.TeamingMode
                LoadBalancingAlgorithm = [string]$switchTeam.LoadBalancingAlgorithm
                Uplinks                = $expectedAdapterRecords
                ManagementVnic         = $managementAdapter.Name
                ManagementVnicStatus   = $managementAdapter.Status
                OperationMode          = [string]$vlan.OperationMode
                AccessVlanId           = [int]$vlan.AccessVlanId
            }
        }

        $disabledPatternResults = [System.Collections.Generic.List[object]]::new()

        foreach ($pattern in $RequiredDisabledPatterns) {
            if ([string]::IsNullOrWhiteSpace($pattern)) {
                continue
            }

            $matchingAdapters = @(
                Get-NetAdapter `
                    -ErrorAction Stop |
                    Where-Object {
                        $_.Name -like $pattern -or
                        $_.InterfaceDescription -like $pattern
                    }
            )

            foreach ($adapter in $matchingAdapters) {
                if ($adapter.Status -notin $AcceptableDisabledAdapterStatuses) {
                    throw (
                        "Adapter design validation failed. AdapterName='$($adapter.Name)'; " +
                        "CurrentStatus='$($adapter.Status)'; RequiredDisabledPattern='$pattern'; " +
                        "ConfiguredAcceptableInactiveStates='$($AcceptableDisabledAdapterStatuses -join ', ')'."
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

        if (
            -not [string]::IsNullOrWhiteSpace(
                $DisabledEmbeddedAdapterPattern
            )
        ) {
            $embeddedAdapters = @(
                Get-NetAdapter `
                    -ErrorAction Stop |
                    Where-Object {
                        $_.InterfaceDescription -like $DisabledEmbeddedAdapterPattern
                    }
            )

            foreach ($embeddedAdapter in $embeddedAdapters) {
                if (
                    $embeddedAdapter.Status -notin
                    $AcceptableDisabledAdapterStatuses
                ) {
                    throw (
                        "Embedded adapter $($embeddedAdapter.Name) is " +
                        "$($embeddedAdapter.Status); expected an approved inactive state."
                    )
                }
            }
        }

        [pscustomobject]@{
            ComputerName                    = $env:COMPUTERNAME
            ValidationMode                  = $ValidationMode
            StorageIntent                   = $StorageIntent
            MappedAdapters                  = $mappedAdapters
            StorageMappedAdapters           = $storageMappedAdapters
            RequiredEnabledAdapters         = $requiredEnabledResults.ToArray()
            DisabledPatternAdapters         = $disabledPatternResults.ToArray()
            EmbeddedAdapters                = @(
                $embeddedAdapters |
                    Select-Object `
                        Name,
                        Status,
                        InterfaceDescription
            )
            AcceptableDisabledAdapterStates = $AcceptableDisabledAdapterStatuses
            ConvergedSwitch                = $convergedSwitchResult
        }
    }

$data = @($result.Data) |
    Select-Object `
        -First 1

$convergedSummary = ''

if ($null -ne $data.ConvergedSwitch) {
    $convergedSummary = (
        " Converged switch $($data.ConvergedSwitch.SwitchName) validated " +
        "with uplinks $((@($data.ConvergedSwitch.Uplinks).Name) -join ', ') and " +
        "management vNIC $($data.ConvergedSwitch.ManagementVnic)."
    )
}

return [pscustomobject]@{
    Passed                          = $true
    Check                           = 'Test-AdapterDesignState'
    Node                            = $result.Node
    ManagementIp                    = $result.ManagementIp
    ValidationMode                  = $data.ValidationMode
    StorageIntent                   = $data.StorageIntent
    MappedAdapters                  = $data.MappedAdapters
    StorageMappedAdapters           = $data.StorageMappedAdapters
    RequiredEnabledAdapters         = $data.RequiredEnabledAdapters
    DisabledPatternAdapters         = $data.DisabledPatternAdapters
    EmbeddedAdapters                = $data.EmbeddedAdapters
    AcceptableDisabledAdapterStates = $data.AcceptableDisabledAdapterStates
    ConvergedSwitch                 = $data.ConvergedSwitch
    Summary                         = (
        "Adapter validation mode $($data.ValidationMode) completed. " +
        "$(@($data.MappedAdapters).Count) role-mapped adapter(s), " +
        "$(@($data.StorageMappedAdapters).Count) storage-mapped adapter(s), " +
        "$(@($data.RequiredEnabledAdapters).Count) required Up adapter(s), and " +
        "$(@($data.EmbeddedAdapters).Count) embedded adapter(s) validated." +
        $convergedSummary
    )
    ValidatedAt                     = [datetime]::UtcNow.ToString('o')
}