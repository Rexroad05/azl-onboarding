#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

function New-RemoteResponse {
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

function New-RemoteQueueHook {
    param(
        [Parameter(Mandatory)]
        [object[]]$Responses
    )

    $queue = New-Object System.Collections.Queue

    foreach ($response in $Responses) {
        [void]$queue.Enqueue($response)
    }

    return {
        param(
            [hashtable]$Context,

            [string]$OperationName,

            [scriptblock]$ScriptBlock,

            [object[]]$ArgumentList
        )

        if ($queue.Count -lt 1) {
            throw "No simulated response remains for $OperationName."
        }

        $nextResponse = $queue.Dequeue()

        if ($nextResponse -is [System.Exception]) {
            throw $nextResponse
        }

        return $nextResponse
    }.GetNewClosure()
}

function New-BaseTestContext {
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [scriptblock]$RemoteCommandInvoker
    )

    $node = [pscustomobject]@{
        name = 'TESTHCN01'
        node_number = '01'
        management = [pscustomobject]@{
            ip_address = '192.0.2.10'
            adapter = 'Management1'
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
    }

    return @{
        Root = Get-TestRepositoryRoot
        Mode = 'Apply'
        PhaseId = 1
        StageId = 2
        Operation = $Operation
        Node = $node
        State = @{
            approvedOperations = @{}
            pendingApproval = $null
            pendingReboot = $null
            nodes = @{
                TESTHCN01 = @{
                    name = 'TESTHCN01'
                    stages = @{}
                }
            }
        }
        TestHooks = @{
            RemoteCommandInvoker = $RemoteCommandInvoker
        }
        Config = [pscustomobject]@{
            network = [pscustomobject]@{
                management = [pscustomobject]@{
                    primary_adapter = 'Management1'
                    vlan_id = 3578
                    prefix = 26
                    gateway = '192.0.2.1'
                }
                storage = [pscustomobject]@{
                    networks = @(
                        [pscustomobject]@{
                            name = 'StorageNetwork1'
                            adapter = 'Storage1'
                            vlan_id = 711
                        },
                        [pscustomobject]@{
                            name = 'StorageNetwork2'
                            adapter = 'Storage2'
                            vlan_id = 712
                        }
                    )
                }
            }
            security = [pscustomobject]@{
                ipv6 = [pscustomobject]@{
                    disable = $true
                    disabled_components = 255
                }
            }
        }
    }
}

function Get-AdapterPath {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-TestRepositoryPath `
        -RelativePath "bootstrap\os\$Name.ps1"
}

Describe 'Batch 2B Ensure Adapter Behavioral Simulation' {
    It 'returns AlreadyCompliant for management VLAN already set to desired state' {
        $inspection = [pscustomobject]@{
            ExistingCluster = $false
            AdapterName = 'Management1'
            AdapterStatus = 'Up'
            VlanProperty = [pscustomobject]@{
                RegistryValue = '3578'
                RegistryKeyword = 'VlanID'
            }
        }

        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-ManagementVlan' `
                -Data @($inspection))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-ManagementVlan' `
            -RemoteCommandInvoker $hook

        $result = & (Get-AdapterPath -Name 'Ensure-ManagementVlan') `
            -Context $context

        $result.Passed | Should Be $true
        $result.Outcome | Should Be 'AlreadyCompliant'
        $result.Changed | Should Be $false
    }

    It 'requests approval for management VLAN drift' {
        $inspection = [pscustomobject]@{
            ExistingCluster = $false
            AdapterName = 'Management1'
            AdapterStatus = 'Up'
            VlanProperty = [pscustomobject]@{
                RegistryValue = '100'
                RegistryKeyword = 'VlanID'
            }
        }

        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-ManagementVlan' `
                -Data @($inspection))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-ManagementVlan' `
            -RemoteCommandInvoker $hook

        $result = & (Get-AdapterPath -Name 'Ensure-ManagementVlan') `
            -Context $context

        $result.Passed | Should Be $false
        $result.Outcome | Should Be 'Blocked'
        $result.RequiresApproval | Should Be $true
        $result.RequiresReboot | Should Be $false
    }

    It 'applies management VLAN drift after approval' {
        $inspection = [pscustomobject]@{
            ExistingCluster = $false
            AdapterName = 'Management1'
            AdapterStatus = 'Up'
            VlanProperty = [pscustomobject]@{
                RegistryValue = '100'
                RegistryKeyword = 'VlanID'
            }
        }

        $changeResult = [pscustomobject]@{
            AdapterName = 'Management1'
            VlanId = 3578
        }

        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-ManagementVlan' `
                -Data @($inspection)),
            (New-RemoteResponse `
                -OperationName 'Ensure-ManagementVlan' `
                -Data @($changeResult))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-ManagementVlan' `
            -RemoteCommandInvoker $hook

        $approvalKey = '1.2.TESTHCN01.Ensure-ManagementVlan'

        $context.State.approvedOperations[$approvalKey] = @{
            ApprovedAt = [datetime]::UtcNow.ToString('o')
            ApprovedBy = 'Pester'
        }

        $result = & (Get-AdapterPath -Name 'Ensure-ManagementVlan') `
            -Context $context

        $result.Passed | Should Be $true
        $result.Outcome | Should Be 'Changed'
        $result.Changed | Should Be $true
        $result.VlanId | Should Be 3578
    }

    It 'blocks management network changes on an existing cluster' {
        $inspection = [pscustomobject]@{
            ExistingCluster = $true
            AdapterName = 'Management1'
            InterfaceIndex = 12
            Addresses = @()
            DefaultRoutes = @()
        }

        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-ManagementNetwork' `
                -Data @($inspection))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-ManagementNetwork' `
            -RemoteCommandInvoker $hook

        $result = & (Get-AdapterPath -Name 'Ensure-ManagementNetwork') `
            -Context $context

        $result.Passed | Should Be $false
        $result.Outcome | Should Be 'Blocked'
        $result.ExistingCluster | Should Be $true
    }

    It 'returns AlreadyCompliant when management IP and gateway match' {
        $inspection = [pscustomobject]@{
            ExistingCluster = $false
            AdapterName = 'Management1'
            InterfaceIndex = 12
            Addresses = @(
                [pscustomobject]@{
                    IPAddress = '192.0.2.10'
                    PrefixLength = 26
                }
            )
            DefaultRoutes = @(
                [pscustomobject]@{
                    NextHop = '192.0.2.1'
                }
            )
        }

        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-ManagementNetwork' `
                -Data @($inspection))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-ManagementNetwork' `
            -RemoteCommandInvoker $hook

        $result = & (Get-AdapterPath -Name 'Ensure-ManagementNetwork') `
            -Context $context

        $result.Passed | Should Be $true
        $result.Outcome | Should Be 'AlreadyCompliant'
        $result.Changed | Should Be $false
    }

    It 'returns AlreadyCompliant when all storage addresses exist' {
        $inspection = [pscustomobject]@{
            ExistingCluster = $false
            Networks = @(
                [pscustomobject]@{
                    Name = 'StorageNetwork1'
                    AdapterName = 'Storage1'
                    IPAddress = '10.71.1.1'
                    Prefix = 24
                    AddressPresent = $true
                },
                [pscustomobject]@{
                    Name = 'StorageNetwork2'
                    AdapterName = 'Storage2'
                    IPAddress = '10.71.2.1'
                    Prefix = 24
                    AddressPresent = $true
                }
            )
        }

        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-StorageNetwork' `
                -Data @($inspection))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-StorageNetwork' `
            -RemoteCommandInvoker $hook

        $result = & (Get-AdapterPath -Name 'Ensure-StorageNetwork') `
            -Context $context

        $result.Passed | Should Be $true
        $result.Outcome | Should Be 'AlreadyCompliant'
    }

    It 'requests approval when a storage network address is missing' {
        $inspection = [pscustomobject]@{
            ExistingCluster = $false
            Networks = @(
                [pscustomobject]@{
                    Name = 'StorageNetwork1'
                    AdapterName = 'Storage1'
                    IPAddress = '10.71.1.1'
                    Prefix = 24
                    AddressPresent = $false
                },
                [pscustomobject]@{
                    Name = 'StorageNetwork2'
                    AdapterName = 'Storage2'
                    IPAddress = '10.71.2.1'
                    Prefix = 24
                    AddressPresent = $true
                }
            )
        }

        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-StorageNetwork' `
                -Data @($inspection))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-StorageNetwork' `
            -RemoteCommandInvoker $hook

        $result = & (Get-AdapterPath -Name 'Ensure-StorageNetwork') `
            -Context $context

        $result.Passed | Should Be $false
        $result.Outcome | Should Be 'Blocked'
        $result.RequiresApproval | Should Be $true
        @($result.PendingNetworks).Count | Should Be 1
    }

    It 'returns AlreadyCompliant when IPv6 baseline matches' {
        $inspection = [pscustomobject]@{
            ExistingCluster = $false
            DisabledComponents = 255
            BindingStates = @(
                [pscustomobject]@{
                    AdapterName = 'Management1'
                    ComponentId = 'ms_tcpip6'
                    Enabled = $false
                },
                [pscustomobject]@{
                    AdapterName = 'Management2'
                    ComponentId = 'ms_tcpip6'
                    Enabled = $false
                },
                [pscustomobject]@{
                    AdapterName = 'Storage1'
                    ComponentId = 'ms_tcpip6'
                    Enabled = $false
                },
                [pscustomobject]@{
                    AdapterName = 'Storage2'
                    ComponentId = 'ms_tcpip6'
                    Enabled = $false
                }
            )
        }

        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-IPv6Baseline' `
                -Data @($inspection))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-IPv6Baseline' `
            -RemoteCommandInvoker $hook

        $result = & (Get-AdapterPath -Name 'Ensure-IPv6Baseline') `
            -Context $context

        $result.Passed | Should Be $true
        $result.Outcome | Should Be 'AlreadyCompliant'
    }

    It 'returns reboot pause metadata after approved IPv6 change' {
        $inspection = [pscustomobject]@{
            ExistingCluster = $false
            DisabledComponents = 0
            BindingStates = @(
                [pscustomobject]@{
                    AdapterName = 'Management1'
                    ComponentId = 'ms_tcpip6'
                    Enabled = $true
                },
                [pscustomobject]@{
                    AdapterName = 'Management2'
                    ComponentId = 'ms_tcpip6'
                    Enabled = $false
                },
                [pscustomobject]@{
                    AdapterName = 'Storage1'
                    ComponentId = 'ms_tcpip6'
                    Enabled = $false
                },
                [pscustomobject]@{
                    AdapterName = 'Storage2'
                    ComponentId = 'ms_tcpip6'
                    Enabled = $false
                }
            )
        }

        $changeResult = [pscustomobject]@{
            DisabledComponents = 255
            BindingComponentId = 'ms_tcpip6'
            DisabledBindings = @(
                'Management1'
            )
        }

        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-IPv6Baseline' `
                -Data @($inspection)),
            (New-RemoteResponse `
                -OperationName 'Ensure-IPv6Baseline' `
                -Data @($changeResult))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-IPv6Baseline' `
            -RemoteCommandInvoker $hook

        $context.State.approvedOperations[
            '1.2.TESTHCN01.Ensure-IPv6Baseline'
        ] = @{
            ApprovedAt = [datetime]::UtcNow.ToString('o')
            ApprovedBy = 'Pester'
        }

        $result = & (Get-AdapterPath -Name 'Ensure-IPv6Baseline') `
            -Context $context

        $result.Passed | Should Be $true
        $result.Outcome | Should Be 'Changed'
        $result.RequiresReboot | Should Be $true
        $result.PauseRequested | Should Be $true
        $result.PauseType | Should Be 'Reboot'
    }

    It 'returns reboot pause metadata after approved hostname change' {
        $inspection = [pscustomobject]@{
            ExistingCluster = $false
            CurrentHostName = 'OLDHCN01'
        }

        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-HostName' `
                -Data @($inspection)),
            (New-RemoteResponse `
                -OperationName 'Ensure-HostName' `
                -Data @())
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-HostName' `
            -RemoteCommandInvoker $hook

        $context.State.approvedOperations[
            '1.2.TESTHCN01.Ensure-HostName'
        ] = @{
            ApprovedAt = [datetime]::UtcNow.ToString('o')
            ApprovedBy = 'Pester'
        }

        $result = & (Get-AdapterPath -Name 'Ensure-HostName') `
            -Context $context

        $result.Passed | Should Be $true
        $result.Outcome | Should Be 'Changed'
        $result.RequiresReboot | Should Be $true
        $result.PauseRequested | Should Be $true
        $result.PauseType | Should Be 'Reboot'
        $result.ReconnectTarget | Should Be 'TESTHCN01'
    }

    It 'throws when the management-plane remoting hook fails' {
        $hook = New-RemoteQueueHook -Responses @(
            ([System.InvalidOperationException]::new(
                'Simulated management-plane transport failure.'
            ))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-ManagementVlan' `
            -RemoteCommandInvoker $hook

        $threw = $false
        $capturedError = $null

        try {
            & (Get-AdapterPath -Name 'Ensure-ManagementVlan') `
                -Context $context
        }
        catch {
            $threw = $true
            $capturedError = $_
        }

        $threw | Should Be $true
        $capturedError | Should Not BeNullOrEmpty
    }
    It 'treats Not Present embedded adapters as compliant inactive state' {
        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-EmbeddedAdaptersDisabled' `
                -Data @(
                    [pscustomobject]@{
                        ExistingCluster = $false
                        AdapterPattern = 'Broadcom netXtreme*'
                        Adapters = @(
                            [pscustomobject]@{
                                Name = 'Embedded NIC 1'
                                Status = 'Not Present'
                                InterfaceDescription = 'Broadcom netXtreme Gigabit Ethernet'
                            }
                        )
                    }
                ))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-EmbeddedAdaptersDisabled' `
            -RemoteCommandInvoker $hook

        $context.Config | Add-Member `
            -MemberType NoteProperty `
            -Name hardware `
            -Value ([pscustomobject]@{
                disabled_embedded_adapter_pattern = 'Broadcom netXtreme*'
                acceptable_disabled_adapter_statuses = @(
                    'Disabled',
                    'Not Present'
                )
            }) `
            -Force

        $adapterPath = Get-TestRepositoryPath `
            -RelativePath 'bootstrap\os\Ensure-EmbeddedAdaptersDisabled.ps1'

        $result = & $adapterPath `
            -Context $context

        $result.Passed | Should Be $true
        $result.Outcome | Should Be 'AlreadyCompliant'
        $result.Changed | Should Be $false
    }
    It 'requests approval for an active embedded adapter' {
        $hook = New-RemoteQueueHook -Responses @(
            (New-RemoteResponse `
                -OperationName 'Ensure-EmbeddedAdaptersDisabled' `
                -Data @(
                    [pscustomobject]@{
                        ExistingCluster = $false
                        AdapterPattern = 'Broadcom netXtreme*'
                        Adapters = @(
                            [pscustomobject]@{
                                Name = 'Embedded NIC 1'
                                Status = 'Up'
                                InterfaceDescription = 'Broadcom netXtreme Gigabit Ethernet'
                            }
                        )
                    }
                ))
        )

        $context = New-BaseTestContext `
            -Operation 'Ensure-EmbeddedAdaptersDisabled' `
            -RemoteCommandInvoker $hook

        $context.Config | Add-Member `
            -MemberType NoteProperty `
            -Name hardware `
            -Value ([pscustomobject]@{
                disabled_embedded_adapter_pattern = 'Broadcom netXtreme*'
                acceptable_disabled_adapter_statuses = @(
                    'Disabled',
                    'Not Present'
                )
            }) `
            -Force

        $adapterPath = Get-TestRepositoryPath `
            -RelativePath 'bootstrap\os\Ensure-EmbeddedAdaptersDisabled.ps1'

        $result = & $adapterPath `
            -Context $context

        $result.Passed | Should Be $false
        $result.Outcome | Should Be 'Blocked'
        $result.RequiresApproval | Should Be $true
    }
}