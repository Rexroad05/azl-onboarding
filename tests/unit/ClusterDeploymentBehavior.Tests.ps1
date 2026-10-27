#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

function New-PhaseTwoRemoteResponse {
    param(
        [Parameter(Mandatory)]
        [string]$OperationName,

        [AllowEmptyCollection()]
        [object[]]$Data = @()
    )

    return [pscustomobject]@{
        Node               = 'TESTHCN01'
        ManagementIp       = '192.0.2.10'
        RemoteComputerName = 'TESTHCN01.example.test'
        Operation          = $OperationName
        Data               = $Data
    }
}

function New-PhaseTwoTestContext {
    param(
        [scriptblock]$RemoteCommandInvoker
    )

    return @{
        Root = Get-TestRepositoryRoot
        Mode = 'Validate'
        PhaseId = 2
        StageId = 1
        State = @{
            approvedOperations = @{}
            pendingApproval = $null
            pendingReboot = $null
            stages = @{
                '1' = @{
                    status = 'PASS'
                }
            }
            nodes = @{
                TESTHCN01 = @{
                    name = 'TESTHCN01'
                    stages = @{}
                }
            }
        }
        Node = [pscustomobject]@{
            name = 'TESTHCN01'
            node_number = '01'
            management = [pscustomobject]@{
                ip = '192.0.2.10'
                adapter = 'Management1'
            }
            storage = @(
                [pscustomobject]@{
                    network = 'StorageNetwork1'
                    adapter = 'Storage1'
                    ip_address = '10.71.1.1'
                    prefix = 24
                    vlan_id = 711
                },
                [pscustomobject]@{
                    network = 'StorageNetwork2'
                    adapter = 'Storage2'
                    ip_address = '10.71.2.1'
                    prefix = 24
                    vlan_id = 712
                }
            )
        }
        TestHooks = @{
            RemoteCommandInvoker = $RemoteCommandInvoker
        }
        Config = [pscustomobject]@{
            site = [pscustomobject]@{
                name = 'TEST'
            }
            cluster = [pscustomobject]@{
                name = 'TESTAZCLUSTER01'
            }
            azure = [pscustomobject]@{
                cloud = 'AzureUSGovernment'
                subscription_id = '00000000-0000-0000-0000-000000000001'
                resource_group = 'TESTAZCLUSTER01-rg'
                location = 'usgovvirginia'
            }
            network = [pscustomobject]@{
                management = [pscustomobject]@{
                    subnet = '192.0.2.0/26'
                    prefix = 26
                    gateway = '192.0.2.1'
                    vlan_id = 3578
                }
                storage = [pscustomobject]@{
                    networks = @(
                        [pscustomobject]@{
                            name = 'StorageNetwork1'
                            adapter = 'Storage1'
                            subnet = '10.71.1.0/24'
                            prefix = 24
                            vlan_id = 711
                        },
                        [pscustomobject]@{
                            name = 'StorageNetwork2'
                            adapter = 'Storage2'
                            subnet = '10.71.2.0/24'
                            prefix = 24
                            vlan_id = 712
                        }
                    )
                }
            }
            nodes = @(
                [pscustomobject]@{
                    name = 'TESTHCN01'
                    node_number = '01'
                    management = [pscustomobject]@{
                        ip = '192.0.2.10'
                    }
                    storage = @(
                        [pscustomobject]@{
                            network = 'StorageNetwork1'
                            ip_address = '10.71.1.1'
                            prefix = 24
                        },
                        [pscustomobject]@{
                            network = 'StorageNetwork2'
                            ip_address = '10.71.2.1'
                            prefix = 24
                        }
                    )
                },
                [pscustomobject]@{
                    name = 'TESTHCN02'
                    node_number = '02'
                    management = [pscustomobject]@{
                        ip = '192.0.2.11'
                    }
                    storage = @(
                        [pscustomobject]@{
                            network = 'StorageNetwork1'
                            ip_address = '10.71.1.2'
                            prefix = 24
                        },
                        [pscustomobject]@{
                            network = 'StorageNetwork2'
                            ip_address = '10.71.2.2'
                            prefix = 24
                        }
                    )
                }
            )
            cluster_deployment = [pscustomobject]@{
                mode = 'ReadinessOnly'
                allow_cluster_creation = $false
                allow_resource_deployment = $false
                approved_execution_method = 'NotApproved'
                cluster_name = 'TESTAZCLUSTER01'
                azure = [pscustomobject]@{
                    subscription_id = '00000000-0000-0000-0000-000000000001'
                    resource_group = 'TESTAZCLUSTER01-rg'
                    location = 'usgovvirginia'
                }
                network = [pscustomobject]@{
                    management_network_name = 'Management'
                    storage_network_count = 2
                    require_rdma = $true
                    require_sriov = $true
                }
                storage = [pscustomobject]@{
                    required_networks = @(
                        'StorageNetwork1',
                        'StorageNetwork2'
                    )
                    require_rdma = $true
                    require_sriov = $true
                    require_storage_spaces_direct = $true
                }
                deployment_template = [pscustomobject]@{
                    bicep_file = 'azure/deployment/main.bicep'
                    bicep_parameter_file = 'azure/deployment/main.bicepparam'
                }
                safety = [pscustomobject]@{
                    block_existing_cluster = $true
                    block_existing_registration = $true
                    block_existing_azure_resource = $true
                    require_phase_14_success = $true
                }
            }
        }
    }
}

function Invoke-PhaseTwoAdapter {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $path = Get-TestRepositoryPath `
        -RelativePath "preflight\$FileName.ps1"

    return & $path -Context $Context
}

function Test-ExpectedThrow {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $threw = $false

    try {
        & $ScriptBlock
    }
    catch {
        $threw = $true
    }

    return $threw
}

Describe 'Phase 2.1 Cluster Deployment Behavior' {
    It 'accepts a valid readiness-only cluster deployment configuration' {
        $context = New-PhaseTwoTestContext

        $result = Invoke-PhaseTwoAdapter `
            -FileName 'Test-ClusterDeploymentConfiguration' `
            -Context $context

        $result.Passed | Should Be $true
        $result.Mode | Should Be 'ReadinessOnly'
        $result.AllowClusterCreation | Should Be $false
        $result.AllowResourceDeployment | Should Be $false
    }

    It 'blocks a duplicate node name configuration' {
        $context = New-PhaseTwoTestContext

        $context.Config.nodes[1].name = 'TESTHCN01'

        $threw = Test-ExpectedThrow -ScriptBlock {
            Invoke-PhaseTwoAdapter `
                -FileName 'Test-ClusterDeploymentNaming' `
                -Context $context
        }

        $threw | Should Be $true
    }

    It 'blocks an invalid management VLAN' {
        $context = New-PhaseTwoTestContext

        $context.Config.network.management.vlan_id = 5000

        $threw = Test-ExpectedThrow -ScriptBlock {
            Invoke-PhaseTwoAdapter `
                -FileName 'Test-ClusterDeploymentNetwork' `
                -Context $context
        }

        $threw | Should Be $true
    }

    It 'blocks missing storage network definitions' {
        $context = New-PhaseTwoTestContext

        $context.Config.network.storage.networks = @(
            $context.Config.network.storage.networks[0]
        )

        $threw = Test-ExpectedThrow -ScriptBlock {
            Invoke-PhaseTwoAdapter `
                -FileName 'Test-ClusterDeploymentStorage' `
                -Context $context
        }

        $threw | Should Be $true
    }

    It 'blocks mismatched deployment Azure subscription values' {
        $context = New-PhaseTwoTestContext

        $context.Config.cluster_deployment.azure.subscription_id = (
            '00000000-0000-0000-0000-000000000099'
        )

        $threw = Test-ExpectedThrow -ScriptBlock {
            Invoke-PhaseTwoAdapter `
                -FileName 'Test-ClusterDeploymentAzurePrerequisites' `
                -Context $context
        }

        $threw | Should Be $true
    }

    It 'blocks a missing Bicep parameter file' {
        $context = New-PhaseTwoTestContext

        $context.Config.cluster_deployment.deployment_template.bicep_parameter_file = (
            'azure/deployment/missing.bicepparam'
        )

        $threw = Test-ExpectedThrow -ScriptBlock {
            Invoke-PhaseTwoAdapter `
                -FileName 'Test-ClusterDeploymentTemplateInputs' `
                -Context $context
        }

        $threw | Should Be $true
    }

    It 'blocks an existing cluster safety state' {
        $hook = {
            param(
                [hashtable]$Context,
                [string]$OperationName,
                [scriptblock]$ScriptBlock,
                [object[]]$ArgumentList
            )

            return New-PhaseTwoRemoteResponse `
                -OperationName $OperationName `
                -Data @(
                    [pscustomobject]@{
                        Clustered = $true
                        ClusterName = 'EXISTINGCLUSTER01'
                        RegistrationStatus = 'Registered'
                        AzureResourceName = 'EXISTINGCLUSTER01'
                    }
                )
        }

        $context = New-PhaseTwoTestContext `
            -RemoteCommandInvoker $hook

        $result = Invoke-PhaseTwoAdapter `
            -FileName 'Test-ClusterDeploymentSafetyState' `
            -Context $context

        $result.Passed | Should Be $false
        $result.Clustered | Should Be $true
    }

    It 'accepts an unclustered and unregistered safety state' {
        $hook = {
            param(
                [hashtable]$Context,
                [string]$OperationName,
                [scriptblock]$ScriptBlock,
                [object[]]$ArgumentList
            )

            return New-PhaseTwoRemoteResponse `
                -OperationName $OperationName `
                -Data @(
                    [pscustomobject]@{
                        Clustered = $false
                        ClusterName = $null
                        RegistrationStatus = $null
                        AzureResourceName = $null
                    }
                )
        }

        $context = New-PhaseTwoTestContext `
            -RemoteCommandInvoker $hook

        $result = Invoke-PhaseTwoAdapter `
            -FileName 'Test-ClusterDeploymentSafetyState' `
            -Context $context

        $result.Passed | Should Be $true
        $result.Clustered | Should Be $false
    }
}