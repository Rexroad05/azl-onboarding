#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

Import-Module powershell-yaml -ErrorAction Stop

$defaults = Get-TestYamlDocument `
    -RelativePath 'protected\defaults.yaml'

$phaseManifest = Get-TestYamlDocument `
    -RelativePath 'protected\phase-manifest.yaml'

$adapters = Get-TestYamlDocument `
    -RelativePath 'protected\adapters.yaml'

$phaseOne = @(
    $phaseManifest.workflow.phases |
        Where-Object {
            [int]$_.id -eq 1
        }
) | Select-Object -First 1

$stageOneTwo = @(
    $phaseOne.stages |
        Where-Object {
            [int]$_.id -eq 2
        }
) | Select-Object -First 1

$stageOneTwoOperationText = @(
    $stageOneTwo.operations
) -join "`n"

$requiredEnabledAdapterText = @(
    $defaults.network.adapter_state.required_enabled
) -join "`n"

$acceptableDisabledAdapterStatuses = @(
    $defaults.hardware.acceptable_disabled_adapter_statuses
)

$acceptableDisabledAdapterStatusText = @(
    $acceptableDisabledAdapterStatuses
) -join "`n"

$adapterMap = if (
    $adapters -is [System.Collections.IDictionary] -and
    $adapters.Contains('adapters')
) {
    $adapters['adapters']
}
elseif ($null -ne $adapters.PSObject.Properties['adapters']) {
    $adapters.adapters
}
else {
    $adapters
}

$ipv6EnsureContent = Get-TestFileContent `
    -RelativePath 'bootstrap\os\Ensure-IPv6Baseline.ps1'

$ipv6TestContent = Get-TestFileContent `
    -RelativePath 'preflight\Test-IPv6Baseline.ps1'

$storageEnsureContent = Get-TestFileContent `
    -RelativePath 'bootstrap\os\Ensure-StorageNetwork.ps1'

$storageTestContent = Get-TestFileContent `
    -RelativePath 'preflight\Test-StorageNetworkReadiness.ps1'

$nicEnsureContent = Get-TestFileContent `
    -RelativePath 'bootstrap\os\Ensure-NicRoleMapping.ps1'

$embeddedAdapterEnsureContent = Get-TestFileContent `
    -RelativePath 'bootstrap\os\Ensure-EmbeddedAdaptersDisabled.ps1'

$adapterDesignTestContent = Get-TestFileContent `
    -RelativePath 'preflight\Test-AdapterDesignState.ps1'

$localAdminEnsureContent = Get-TestFileContent `
    -RelativePath 'bootstrap\os\Ensure-LocalDeploymentAdministrator.ps1'

$localAdminReadinessContent = Get-TestFileContent `
    -RelativePath 'preflight\Test-LocalAdministratorReadiness.ps1'

$localAdminCredentialContent = Get-TestFileContent `
    -RelativePath 'preflight\Test-LocalAdministratorCredential.ps1'

$activeBootstrapFiles = @(
    'bootstrap\os\Ensure-NicRoleMapping.ps1',
    'bootstrap\os\Ensure-EmbeddedAdaptersDisabled.ps1',
    'bootstrap\os\Ensure-DhcpDisabled.ps1',
    'bootstrap\os\Ensure-ManagementVlan.ps1',
    'bootstrap\os\Ensure-ManagementNetwork.ps1',
    'bootstrap\os\Ensure-DNS.ps1',
    'bootstrap\os\Ensure-NTP.ps1',
    'bootstrap\os\Ensure-StorageNetwork.ps1',
    'bootstrap\os\Ensure-IPv6Baseline.ps1',
    'bootstrap\os\Ensure-LocalDeploymentAdministrator.ps1',
    'bootstrap\os\Ensure-PowerShellRemoting.ps1',
    'bootstrap\os\Ensure-HostName.ps1'
)

$activeBootstrapContent = @(
    foreach ($file in $activeBootstrapFiles) {
        Get-TestFileContent -RelativePath $file
    }
) -join "`n"

Describe 'Legacy SBASE Workflow Coverage' {
    Context 'Configuration model' {
        It 'defines IPv6 desired-state configuration' {
            $defaults.security |
                Should Not BeNullOrEmpty

            $defaults.security.ipv6 |
                Should Not BeNullOrEmpty

            [bool]$defaults.security.ipv6.disable |
                Should Be $true

            [int]$defaults.security.ipv6.disabled_components |
                Should Be 255
        }

        It 'defines IPv6 binding desired-state configuration' {
            [bool]$defaults.security.ipv6.disable_bindings |
                Should Be $true

            [string]$defaults.security.ipv6.binding_component_id |
                Should Be 'ms_tcpip6'

            [string]$defaults.security.ipv6.adapter_scope |
                Should Be 'RequiredDeploymentAdapters'
        }

        It 'defines required adapter final-state configuration' {
            $defaults.network.adapter_state |
                Should Not BeNullOrEmpty

            @($defaults.network.adapter_state.required_enabled).Count |
                Should BeGreaterThan 0

            $requiredEnabledAdapterText |
                Should Match '(?m)^Management1$'

            $requiredEnabledAdapterText |
                Should Match '(?m)^Management2$'

            $requiredEnabledAdapterText |
                Should Match '(?m)^Storage1$'

            $requiredEnabledAdapterText |
                Should Match '(?m)^Storage2$'

            @($defaults.network.adapter_state.required_disabled_patterns).Count |
                Should BeGreaterThan 0
        }

        It 'defines accepted inactive embedded adapter states' {
            @($acceptableDisabledAdapterStatuses).Count |
                Should BeGreaterThan 0

            $acceptableDisabledAdapterStatusText |
                Should Match '(?m)^Disabled$'

            $acceptableDisabledAdapterStatusText |
                Should Match '(?m)^Not Present$'
        }

        It 'defines storage VLAN desired-state enforcement' {
            $defaults.network.storage |
                Should Not BeNullOrEmpty

            [bool]$defaults.network.storage.require_vlan_configuration |
                Should Be $true
        }
    }

    Context 'Stage 1.2B operation coverage' {
        It 'includes IPv6 Ensure and validation operations' {
            $stageOneTwoOperationText |
                Should Match '(?m)^Ensure-IPv6Baseline$'

            $stageOneTwoOperationText |
                Should Match '(?m)^Test-IPv6Baseline$'
        }

        It 'includes storage Ensure and validation operations' {
            $stageOneTwoOperationText |
                Should Match '(?m)^Ensure-StorageNetwork$'

            $stageOneTwoOperationText |
                Should Match '(?m)^Test-StorageNetworkReadiness$'
        }

        It 'includes NIC role, embedded adapter, and adapter design operations' {
            $stageOneTwoOperationText |
                Should Match '(?m)^Ensure-NicRoleMapping$'

            $stageOneTwoOperationText |
                Should Match '(?m)^Ensure-EmbeddedAdaptersDisabled$'

            $stageOneTwoOperationText |
                Should Match '(?m)^Test-AdapterDesignState$'
        }

        It 'includes local deployment administrator validation operations' {
            $stageOneTwoOperationText |
                Should Match '(?m)^Ensure-LocalDeploymentAdministrator$'

            $stageOneTwoOperationText |
                Should Match '(?m)^Test-LocalAdministratorReadiness$'

            $stageOneTwoOperationText |
                Should Match '(?m)^Test-LocalAdministratorCredential$'
        }

        It 'includes management network, DNS, NTP, hostname, RDMA, and SR-IOV operations' {
            $requiredOperations = @(
                'Ensure-ManagementVlan',
                'Ensure-ManagementNetwork',
                'Ensure-DNS',
                'Ensure-NTP',
                'Ensure-HostName',
                'Test-RdmaState',
                'Test-SriovState'
            )

            foreach ($operation in $requiredOperations) {
                $escapedOperation = [regex]::Escape($operation)

                $stageOneTwoOperationText |
                    Should Match "(?m)^$escapedOperation$"
            }
        }
    }

    Context 'Protected adapter mappings' {
        It 'maps every legacy-coverage adapter to an existing path' {
            $requiredMappings = @(
                'Ensure-NicRoleMapping',
                'Ensure-EmbeddedAdaptersDisabled',
                'Ensure-ManagementVlan',
                'Ensure-ManagementNetwork',
                'Ensure-StorageNetwork',
                'Ensure-IPv6Baseline',
                'Ensure-LocalDeploymentAdministrator',
                'Test-AdapterDesignState',
                'Test-IPv6Baseline',
                'Test-StorageNetworkReadiness',
                'Test-LocalAdministratorReadiness',
                'Test-LocalAdministratorCredential'
            )

            foreach ($mapping in $requiredMappings) {
                $adapterMap[$mapping] |
                    Should Not BeNullOrEmpty

                $adapterPath = Get-TestRepositoryPath `
                    -RelativePath ([string]$adapterMap[$mapping])

                Test-Path `
                    -LiteralPath $adapterPath `
                    -PathType Leaf |
                    Should Be $true
            }
        }
    }

    Context 'IPv6 legacy coverage' {
        It 'parses IPv6 Ensure and validation adapters' {
            @(Get-TestParseErrors `
                -RelativePath 'bootstrap\os\Ensure-IPv6Baseline.ps1').Count |
                Should Be 0

            @(Get-TestParseErrors `
                -RelativePath 'preflight\Test-IPv6Baseline.ps1').Count |
                Should Be 0
        }

        It 'enforces DisabledComponents desired state' {
            $ipv6EnsureContent |
                Should Match 'DisabledComponents'

            $ipv6EnsureContent |
                Should Match 'disabled_components'
        }

        It 'enforces configured IPv6 adapter binding disablement' {
            $ipv6EnsureContent |
                Should Match 'Disable\-NetAdapterBinding'

            $ipv6EnsureContent |
                Should Match 'Get\-NetAdapterBinding'

            $ipv6EnsureContent |
                Should Match 'binding_component_id'

            [string]$defaults.security.ipv6.binding_component_id |
                Should Be 'ms_tcpip6'
        }

        It 'validates both IPv6 registry and configured binding state' {
            $ipv6TestContent |
                Should Match 'DisabledComponents'

            $ipv6TestContent |
                Should Match 'Get\-NetAdapterBinding'

            $ipv6TestContent |
                Should Match 'binding_component_id'

            [string]$defaults.security.ipv6.binding_component_id |
                Should Be 'ms_tcpip6'
        }

        It 'returns reboot pause metadata after required IPv6 changes' {
            $ipv6EnsureContent |
                Should Match 'RequiresReboot'

            $ipv6EnsureContent |
                Should Match 'PauseRequested'

            $ipv6EnsureContent |
                Should Match 'PauseType'
        }
    }

    Context 'Adapter role and final-state legacy coverage' {
        It 'parses adapter Ensure and validation scripts' {
            @(Get-TestParseErrors `
                -RelativePath 'bootstrap\os\Ensure-NicRoleMapping.ps1').Count |
                Should Be 0

            @(Get-TestParseErrors `
                -RelativePath 'bootstrap\os\Ensure-EmbeddedAdaptersDisabled.ps1').Count |
                Should Be 0

            @(Get-TestParseErrors `
                -RelativePath 'preflight\Test-AdapterDesignState.ps1').Count |
                Should Be 0
        }

        It 'uses approved hardware NIC mapping configuration' {
            $defaults.hardware.nic_mapping |
                Should Not BeNullOrEmpty

            $nicEnsureContent |
                Should Match 'nic_mapping'

            $nicEnsureContent |
                Should Match 'expected_name'

            $nicEnsureContent |
                Should Match 'pci_slot'

            $nicEnsureContent |
                Should Match 'pci_function'
        }

        It 'enforces configured embedded adapter inactive states' {
            $embeddedAdapterEnsureContent |
                Should Match 'disabled_embedded_adapter_pattern'

            $embeddedAdapterEnsureContent |
                Should Match 'acceptable_disabled_adapter_statuses'

            $embeddedAdapterEnsureContent |
                Should Match 'Disable\-NetAdapter'

            $embeddedAdapterEnsureContent |
                Should Match 'acceptable_disabled_adapter_statuses'
        }

        It 'validates required adapter design and accepted inactive states' {
            $adapterDesignTestContent |
                Should Match 'required_enabled'

            $adapterDesignTestContent |
                Should Match 'required_disabled_patterns'

            $adapterDesignTestContent |
                Should Match 'acceptable_disabled_adapter_statuses'

            $embeddedAdapterEnsureContent |
                Should Match 'acceptable_disabled_adapter_statuses'
        }
    }

    Context 'Storage network and VLAN legacy coverage' {
        It 'parses storage Ensure and validation scripts' {
            @(Get-TestParseErrors `
                -RelativePath 'bootstrap\os\Ensure-StorageNetwork.ps1').Count |
                Should Be 0

            @(Get-TestParseErrors `
                -RelativePath 'preflight\Test-StorageNetworkReadiness.ps1').Count |
                Should Be 0
        }

        It 'uses configured storage network VLAN information' {
            $storageEnsureContent |
                Should Match 'vlan_id'

            $storageEnsureContent |
                Should Match 'Vlan'
        }

        It 'validates storage address and VLAN readiness' {
            $storageTestContent |
                Should Match 'Storage'

            $storageTestContent |
                Should Match 'Vlan'
        }
    }

        Context 'Local deployment administrator legacy coverage' {
            It 'parses local administrator adapters' {
                @(Get-TestParseErrors `
                    -RelativePath 'bootstrap\os\Ensure-LocalDeploymentAdministrator.ps1').Count |
                    Should Be 0

                @(Get-TestParseErrors `
                    -RelativePath 'preflight\Test-LocalAdministratorReadiness.ps1').Count |
                    Should Be 0

                @(Get-TestParseErrors `
                    -RelativePath 'preflight\Test-LocalAdministratorCredential.ps1').Count |
                    Should Be 0
            }

            It 'defines approved post-bootstrap deployment account lifecycle behavior' {
                $lifecycle = $defaults.security.local_administrator.lifecycle

                [bool]$lifecycle.bootstrap_account |
                    Should Be $true

                [bool]$lifecycle.require_for_1_2b |
                    Should Be $true

                [bool]$lifecycle.allow_absent_in_1_2c |
                    Should Be $true

                $lifecycle.post_bootstrap_behavior |
                    Should Be 'MayBeRemoved'
            }

            It 'tracks the configured deployment administrator account' {
                [string]$defaults.security.local_administrator.name |
                    Should Be 'fseadm'

                $localAdminEnsureContent |
                    Should Match 'local_administrator'

                $localAdminReadinessContent |
                    Should Match 'local_administrator'

                $localAdminCredentialContent |
                    Should Match 'local_administrator'
            }

            It 'creates the deployment account only when protected lifecycle policy permits it' {
                $localAdminEnsureContent |
                    Should Match 'create_if_missing_for_1_2b'

                $localAdminEnsureContent |
                    Should Match 'CreateIfMissing'

                $localAdminEnsureContent |
                    Should Match 'New-LocalUser'

                $localAdminEnsureContent |
                    Should Match 'Explicit approval is required before creation'

                $localAdminEnsureContent |
                    Should Match 'reset_existing_password=true is not approved'
            }
    }

    Context 'Legacy security exception exclusions' {
        It 'does not automate broad firewall disablement' {
            $activeBootstrapContent |
                Should Not Match 'netsh\s+advfirewall\s+set\s+allprofiles\s+state\s+off'
        }

        It 'does not automate RDP enablement' {
            $activeBootstrapContent |
                Should Not Match 'fDenyTSConnections'

            $activeBootstrapContent |
                Should Not Match 'Enable\-NetFirewallRule.*Remote Desktop'
        }
    }
}