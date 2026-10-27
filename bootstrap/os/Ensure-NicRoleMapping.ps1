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
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    return Get-HcnEnsureValue `
        -Object $Object `
        -Name $Name
}

$config = Get-Value `
    -Object $Context `
    -Name 'Config'

$deployment = Get-Value `
    -Object $config `
    -Name 'deployment'

$singleServer = Get-Value `
    -Object $deployment `
    -Name 'single_server'

$isSingleServer = (
    (Get-Value `
        -Object $singleServer `
        -Name 'enabled') -eq $true
)

$hardware = Get-Value `
    -Object $config `
    -Name 'hardware'

$convergedSwitch = Get-Value `
    -Object $hardware `
    -Name 'converged_switch'

$managementVnic = Get-Value `
    -Object $hardware `
    -Name 'management_vnic'

if ($isSingleServer -and $null -ne $convergedSwitch) {
    $switchName = [string](
        Get-Value `
            -Object $convergedSwitch `
            -Name 'name'
    )

    $expectedTeamMode = [string](
        Get-Value `
            -Object $convergedSwitch `
            -Name 'teaming_mode'
    )

    $expectedLoadBalancing = [string](
        Get-Value `
            -Object $convergedSwitch `
            -Name 'load_balancing_algorithm'
    )

    $expectedUplinks = @(
        Get-Value `
            -Object $convergedSwitch `
            -Name 'uplink_adapters'
    )

    $managementVnicName = [string](
        Get-Value `
            -Object $managementVnic `
            -Name 'name'
    )

    if (
        [string]::IsNullOrWhiteSpace($switchName) -or
        [string]::IsNullOrWhiteSpace($managementVnicName) -or
        $expectedUplinks.Count -lt 1
    ) {
        throw (
            'Protected single-server converged-switch profile is incomplete.'
        )
    }

    $result = Invoke-ManagementPlaneCommand `
        -Context $Context `
        -OperationName 'Ensure-NicRoleMapping' `
        -ArgumentList @(
            $switchName,
            $expectedTeamMode,
            $expectedLoadBalancing,
            $expectedUplinks,
            $managementVnicName
        ) `
        -ScriptBlock {
            param(
                [string]$SwitchName,
                [string]$ExpectedTeamMode,
                [string]$ExpectedLoadBalancing,
                [string[]]$ExpectedUplinks,
                [string]$ManagementVnicName
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
                        InterfaceGuid = (
                            [guid]$adapter.InterfaceGuid
                        ).ToString('D')
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

            $isCompliant = (
                $switchTeam.Name -eq $SwitchName -and
                [string]$switchTeam.TeamingMode -eq $ExpectedTeamMode -and
                [string]$switchTeam.LoadBalancingAlgorithm -eq
                    $ExpectedLoadBalancing -and
                ($actualGuids.Count -eq $expectedGuids.Count) -and
                @(
                    $actualGuids |
                        Where-Object {
                            $expectedGuids -notcontains $_
                        }
                ).Count -eq 0
            )

            $managementVnic = Get-VMNetworkAdapter `
                -ManagementOS `
                -Name $ManagementVnicName `
                -ErrorAction Stop

            [pscustomobject]@{
                ComputerName           = $env:COMPUTERNAME
                SwitchName             = $switchTeam.Name
                TeamingMode            = [string]$switchTeam.TeamingMode
                LoadBalancingAlgorithm = (
                    [string]$switchTeam.LoadBalancingAlgorithm
                )
                ActualUplinks          = $actualUplinks
                ExpectedUplinks        = $ExpectedUplinks
                ManagementVnic         = $managementVnic.Name
                IsCompliant            = $isCompliant
            }
        }

    $data = @($result.Data) |
        Select-Object -First 1

    if (-not $data.IsCompliant) {
        return New-HcnEnsureResult `
            -Check 'Ensure-NicRoleMapping' `
            -Outcome 'Blocked' `
            -Summary (
                'CNEF converged SET state differs from the protected profile. ' +
                'No automatic physical NIC rename or SET reconfiguration is permitted.'
            ) `
            -AdditionalProperties @{
                RequiresApproval       = $true
                ApprovalReason         = (
                    'The existing converged SET does not match the protected ' +
                    'CNEF profile. Changing SET membership or switch properties ' +
                    'can interrupt management connectivity and requires an ' +
                    'approved network change.'
                )
                RequiresReboot         = $false
                ReconnectTarget        = $result.Node
                Node                   = $result.Node
                SwitchName             = $data.SwitchName
                TeamingMode            = $data.TeamingMode
                LoadBalancingAlgorithm = $data.LoadBalancingAlgorithm
                ActualUplinks          = $data.ActualUplinks
                ExpectedUplinks        = $data.ExpectedUplinks
                ManagementVnic         = $data.ManagementVnic
            }
    }

    return New-HcnEnsureResult `
        -Check 'Ensure-NicRoleMapping' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            "CNEF converged SET $($data.SwitchName) and management vNIC " +
            "$($data.ManagementVnic) match the protected profile."
        ) `
        -AdditionalProperties @{
            Node                   = $result.Node
            ManagementIp           = $result.ManagementIp
            SwitchName             = $data.SwitchName
            TeamingMode            = $data.TeamingMode
            LoadBalancingAlgorithm = $data.LoadBalancingAlgorithm
            Uplinks                = $data.ActualUplinks
            ManagementVnic         = $data.ManagementVnic
        }
}

$nicMapping = Get-Value `
    -Object $hardware `
    -Name 'nic_mapping'

if ($null -eq $nicMapping) {
    throw 'hardware.nic_mapping is required.'
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Ensure-NicRoleMapping' `
    -ArgumentList @($nicMapping) `
    -ScriptBlock {
        param(
            [object]$ExpectedNicMapping
        )

        $hardwareInfo = @(
            Get-NetAdapterHardwareInfo -ErrorAction Stop
        )

        $changes = [System.Collections.Generic.List[string]]::new()

        foreach ($mappingName in $ExpectedNicMapping.Keys) {
            $mapping = $ExpectedNicMapping[$mappingName]

            $expectedName = [string]$mapping.expected_name
            $expectedSlot = [int]$mapping.pci_slot
            $expectedFunction = [int]$mapping.pci_function

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

            $currentName = [string]$matches[0].Name

            if ($currentName -eq $expectedName) {
                continue
            }

            $nameConflict = Get-NetAdapter `
                -Name $expectedName `
                -ErrorAction SilentlyContinue

            if ($null -ne $nameConflict) {
                throw (
                    "Cannot rename $currentName to $expectedName because " +
                    'an adapter already uses that name.'
                )
            }

            Rename-NetAdapter `
                -Name $currentName `
                -NewName $expectedName `
                -Confirm:$false `
                -ErrorAction Stop

            $changes.Add("$currentName renamed to $expectedName")
        }

        $finalAdapters = @(
            Get-NetAdapter |
                Select-Object Name, Status, LinkSpeed, InterfaceDescription
        )

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Changed      = ($changes.Count -gt 0)
            Changes      = $changes.ToArray()
            Adapters     = $finalAdapters
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

if ($data.Changed) {
    return New-HcnEnsureResult `
        -Check 'Ensure-NicRoleMapping' `
        -Outcome 'Changed' `
        -Changed $true `
        -Summary (
            'NIC aliases were updated: ' +
            ($data.Changes -join '; ')
        ) `
        -AdditionalProperties @{
            Node         = $result.Node
            ManagementIp = $result.ManagementIp
            Adapters     = $data.Adapters
        }
}

return New-HcnEnsureResult `
    -Check 'Ensure-NicRoleMapping' `
    -Outcome 'AlreadyCompliant' `
    -Summary 'All NIC aliases already match the approved slot/function mapping.' `
    -AdditionalProperties @{
        Node         = $result.Node
        ManagementIp = $result.ManagementIp
        Adapters     = $data.Adapters
    }