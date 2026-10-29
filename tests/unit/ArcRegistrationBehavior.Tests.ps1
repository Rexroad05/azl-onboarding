#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

function New-ArcRemoteResponse {
    param(
        [Parameter(Mandatory)]
        [string]$OperationName,

        [AllowEmptyCollection()]
        [object[]]$Data = @()
    )

    return [pscustomobject]@{
        Node = 'TESTHCN01'
        ManagementIp = '192.0.2.10'
        RemoteComputerName = 'TESTHCN01.example.test'
        Operation = $OperationName
        Data = $Data
    }
}

function New-ArcQueueHook {
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
            throw "No simulated Arc response remains for $OperationName."
        }

        return $queue.Dequeue()
    }.GetNewClosure()
}

function New-NativeBootstrapStatusResponse {
    param(
        [Parameter(Mandatory)]
        [string]$Status,

        [AllowNull()]
        [string]$ErrorMessage = $null,

        [bool]$RebootPending = $false,

        [AllowNull()]
        [object]$DeviceCode = $null
    )

    $details = @()

    if ($RebootPending) {
        $details = @(
            [pscustomobject]@{
                Name = 'ArcRegistration'
                Status = 'RebootPending'
            }
        )
    }

    return [pscustomobject]@{
        CommandAvailable = $true
        Status = $Status
        ErrorMessage = $ErrorMessage
        RebootPending = $RebootPending
        DetailedResponse = $details
        DeviceCode = $DeviceCode
    }
}

function New-NativeBootstrapStartResponse {
    param(
        [bool]$AlreadyInProgress = $false
    )

    return [pscustomobject]@{
        AgentPath = (
            'C:\Program Files\AzureConnectedMachineAgent\' +
            'azcmagent.exe'
        )
        BootstrapConfigPath = (
            'C:\Windows\Temp\' +
            'NativeArcBootstrap-TESTHCN01.json'
        )
        AlreadyInProgress = $AlreadyInProgress
        AuthorizationDelegated = $true
    }
}

function New-ArcTestContext {
    param(
        [scriptblock]$RemoteCommandInvoker,

        [string]$Mode = 'ReadinessOnly',

        [bool]$AllowRegistration = $false,

        [bool]$AllowDeviceCodeRegistration = $false,

        [hashtable]$StateOverride = @{}
    )

    $state = @{
        approvedOperations = @{}
        pendingApproval = $null
        pendingReboot = $null
        pendingInteractiveAuthentication = $null
        operationCheckpoints = @{}
        nodes = @{
            TESTHCN01 = @{
                name = 'TESTHCN01'
                stages = @{}
            }
        }
    }

    foreach ($key in $StateOverride.Keys) {
        $state[$key] = $StateOverride[$key]
    }

    $runDirectory = Join-Path `
        $TestDrive `
        (
            'ArcRegistration-' +
            [guid]::NewGuid().ToString('N')
        )

    New-Item `
        -ItemType Directory `
        -Path $runDirectory `
        -Force |
        Out-Null

    return @{
        Root = Get-TestRepositoryRoot
        RunDirectory = $runDirectory
        Mode = 'Apply'
        PhaseId = 1
        StageId = 4
        Operation = 'Register-ArcNode'
        State = $state
        NativeArcAuthorization = @{
            ArmAccessToken = (
                ConvertTo-SecureString `
                    -String 'PesterEphemeralArmToken' `
                    -AsPlainText `
                    -Force
            )
            AccountId = 'pester@example.us'
        }
        Node = [pscustomobject]@{
            name = 'TESTHCN01'
            node_number = '01'
            management = [pscustomobject]@{
                ip = '192.0.2.10'
            }
        }
        TestHooks = @{
            RemoteCommandInvoker = $RemoteCommandInvoker
        }
        Config = [pscustomobject]@{
            azure = [pscustomobject]@{
                cloud = 'AzureUSGovernment'
                tenant_id = '00000000-0000-0000-0000-000000000001'
                subscription_id = '00000000-0000-0000-0000-000000000002'
                resource_group = 'TESTARC-rg'
                location = 'usgovvirginia'
                arc_agent = [pscustomobject]@{
                    agent_executable_path = (
                        'C:\Program Files\AzureConnectedMachineAgent\' +
                        'azcmagent.exe'
                    )
                    himds_service_name = 'himds'
                }
                arc_registration = [pscustomobject]@{
                    mode = $Mode
                    allow_registration = $AllowRegistration
                    allow_device_code_registration = $AllowDeviceCodeRegistration
                    authentication_method = 'DeviceCode'
                    connected_machine_agent_command = 'azcmagent'
                    native_bootstrap_status_poll_interval_seconds = 5
                    native_bootstrap_session_timeout_minutes = 1
                    azure_resource_visibility_timeout_minutes = 10
                    azure_resource_visibility_poll_interval_seconds = 15
                    allow_automatic_update = $false
                    allow_automatic_reboot = $false
                    require_explicit_approval_after_reboot = $true
                }
            }
        }
    }
}

$registerArcPath = Get-TestRepositoryPath `
    -RelativePath 'azure\registration\Register-ArcNode.ps1'

Describe 'Interactive Arc Registration Behavior' {
    It 'blocks Arc registration in ReadinessOnly mode' {
        $context = New-ArcTestContext `
            -Mode 'ReadinessOnly' `
            -AllowRegistration $false `
            -AllowDeviceCodeRegistration $false

        $result = & $registerArcPath `
            -Context $context

        $result.Passed |
            Should Be $false

        $result.Outcome |
            Should Be 'Blocked'

        $result.ArcRegistrationMode |
            Should Be 'ReadinessOnly'
    }

    It 'requests approval before starting native Azure Local bootstrap' {
        $hook = New-ArcQueueHook -Responses @(
            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapPrecheck' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'NotStarted')
                ))
        )

        $context = New-ArcTestContext `
            -RemoteCommandInvoker $hook `
            -Mode 'InteractiveDeviceCode' `
            -AllowRegistration $true `
            -AllowDeviceCodeRegistration $true

        $result = & $registerArcPath `
            -Context $context

        $result.Passed |
            Should Be $false

        $result.Outcome |
            Should Be 'Blocked'

        $result.RequiresApproval |
            Should Be $true

        $result.ApprovalKey |
            Should Be '1.4.TESTHCN01.NativeAzureLocalArcBootstrap'
    }

    It 'runs native bootstrap to success after registration approval' {
        $hook = New-ArcQueueHook -Responses @(
            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapPrecheck' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'NotStarted')
                )),

            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapStart' `
                -Data @(
                    (New-NativeBootstrapStartResponse)
                )),

            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapStatus' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'Succeeded')
                )),

            (New-ArcRemoteResponse `
                -OperationName 'RemoveNativeArcBootstrapConfiguration')
        )

        $context = New-ArcTestContext `
            -RemoteCommandInvoker $hook `
            -Mode 'InteractiveDeviceCode' `
            -AllowRegistration $true `
            -AllowDeviceCodeRegistration $true

        $context.State.approvedOperations[
            '1.4.TESTHCN01.NativeAzureLocalArcBootstrap'
        ] = @{
            ApprovedAt = [datetime]::UtcNow.ToString('o')
            ApprovedBy = 'Pester'
        }

        $result = & $registerArcPath `
            -Context $context

        $result.Passed |
            Should Be $true

        $result.Outcome |
            Should Be 'Changed'

        $result.Workflow |
            Should Be 'NativeAzureLocalBootstrap'

        $result.BootstrapStatus |
            Should Be 'Succeeded'

        ($null -eq $result.PSObject.Properties['PauseRequested']) |
            Should Be $true

        ($null -eq $result.PSObject.Properties['ArmAccessToken']) |
            Should Be $true

        ($null -eq $result.PSObject.Properties['AccountId']) |
            Should Be $true
    }

    It 'treats duplicate native work-item response as existing bootstrap' {
        $hook = New-ArcQueueHook -Responses @(
            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapPrecheck' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'NotStarted')
                )),

            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapStart' `
                -Data @(
                    (New-NativeBootstrapStartResponse `
                        -AlreadyInProgress $true)
                )),

            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapStatus' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'Succeeded')
                )),

            (New-ArcRemoteResponse `
                -OperationName 'RemoveNativeArcBootstrapConfiguration')
        )

        $context = New-ArcTestContext `
            -RemoteCommandInvoker $hook `
            -Mode 'InteractiveDeviceCode' `
            -AllowRegistration $true `
            -AllowDeviceCodeRegistration $true

        $context.State.approvedOperations[
            '1.4.TESTHCN01.NativeAzureLocalArcBootstrap'
        ] = @{
            ApprovedAt = [datetime]::UtcNow.ToString('o')
            ApprovedBy = 'Pester'
        }

        $result = & $registerArcPath `
            -Context $context

        $result.Passed |
            Should Be $true

        $result.Outcome |
            Should Be 'Changed'

        $result.BootstrapStatus |
            Should Be 'Succeeded'
    }

    It 'resumes an existing native session without starting bootstrap again' {
        $hook = New-ArcQueueHook -Responses @(
            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapStatus' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'Succeeded')
                )),

            (New-ArcRemoteResponse `
                -OperationName 'RemoveNativeArcBootstrapConfiguration')
        )

        $pendingInteractiveAuthentication = @{
            ApprovalKey = (
                '1.4.TESTHCN01.Register-ArcNode.' +
                'InteractiveAuthentication'
            )
            ApprovalType = 'InteractiveAuthentication'
            AuthenticationMethod = 'DeviceCode'
            Node = 'TESTHCN01'
            Operation = 'Register-ArcNode'
            Workflow = 'NativeAzureLocalBootstrap'
            BootstrapStatus = 'InProgress'
            BootstrapConfigPath = (
                'C:\Windows\Temp\' +
                'NativeArcBootstrap-TESTHCN01.json'
            )
            StatusRecordPath = (
                'C:\Build_log\' +
                'NativeArcBootstrap-TESTHCN01-status.json'
            )
            SessionStartedAtUtc = (
                [datetime]::UtcNow.AddMinutes(-1).ToString('o')
            )
            ReturnToOperation = 'Register-ArcNode'
        }

        $context = New-ArcTestContext `
            -RemoteCommandInvoker $hook `
            -Mode 'InteractiveDeviceCode' `
            -AllowRegistration $true `
            -AllowDeviceCodeRegistration $true `
            -StateOverride @{
                pendingInteractiveAuthentication = `
                    $pendingInteractiveAuthentication
            }

        $result = & $registerArcPath `
            -Context $context

        $result.Passed |
            Should Be $true

        $result.Outcome |
            Should Be 'Changed'

        $result.BootstrapStatus |
            Should Be 'Succeeded'

        $result.Workflow |
            Should Be 'NativeAzureLocalBootstrap'
    }

    It 'returns a separately approved reboot pause for native RebootPending' {
        $hook = New-ArcQueueHook -Responses @(
            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapPrecheck' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'NotStarted')
                )),

            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapStart' `
                -Data @(
                    (New-NativeBootstrapStartResponse)
                )),

            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapStatus' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'InProgress' `
                        -RebootPending $true)
                ))
        )

        $context = New-ArcTestContext `
            -RemoteCommandInvoker $hook `
            -Mode 'InteractiveDeviceCode' `
            -AllowRegistration $true `
            -AllowDeviceCodeRegistration $true

        $context.State.approvedOperations[
            '1.4.TESTHCN01.NativeAzureLocalArcBootstrap'
        ] = @{
            ApprovedAt = [datetime]::UtcNow.ToString('o')
            ApprovedBy = 'Pester'
        }

        $result = & $registerArcPath `
            -Context $context

        $result.Passed |
            Should Be $false

        $result.Outcome |
            Should Be 'Blocked'

        $result.PauseRequested |
            Should Be $true

        $result.PauseType |
            Should Be 'Reboot'

        $result.RequiresReboot |
            Should Be $true

        $result.NativeBootstrapRebootPending |
            Should Be $true
    }

    It 'requires a fresh retry approval after device-code expiration' {
        $hook = New-ArcQueueHook -Responses @(
            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapPrecheck' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'Failed' `
                        -ErrorMessage (
                            'Authentication to Azure Arc failed. ' +
                            'Verification code expired.'
                        ))
                ))
        )

        $context = New-ArcTestContext `
            -RemoteCommandInvoker $hook `
            -Mode 'InteractiveDeviceCode' `
            -AllowRegistration $true `
            -AllowDeviceCodeRegistration $true

        $result = & $registerArcPath `
            -Context $context

        $result.Passed |
            Should Be $false

        $result.Outcome |
            Should Be 'Blocked'

        $result.RequiresApproval |
            Should Be $true

        $result.ApprovalKey |
            Should Be (
                '1.4.TESTHCN01.NativeAzureLocalArcBootstrap.DeviceCodeRetry'
            )
    }

    It 'treats historical native Succeeded state without agent identity as reset state' {
        $hook = New-ArcQueueHook -Responses @(
            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapPrecheck' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'Succeeded')
                )),

            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeAgentRegistrationInspection' `
                -Data @(
                    [pscustomobject]@{
                        AgentPresent = $false
                        AgentPath = $null
                        AgentStatus = $null
                        ResourceId = $null
                        SubscriptionId = $null
                        ResourceGroup = $null
                    }
                ))
        )

        $context = New-ArcTestContext `
            -RemoteCommandInvoker $hook `
            -Mode 'InteractiveDeviceCode' `
            -AllowRegistration $true `
            -AllowDeviceCodeRegistration $true

        $result = & $registerArcPath `
            -Context $context

        $result.Passed |
            Should Be $false

        $result.Outcome |
            Should Be 'Blocked'

        $result.RequiresApproval |
            Should Be $true

        $result.ApprovalKey |
            Should Be '1.4.TESTHCN01.NativeAzureLocalArcBootstrap'
    }

    It 'blocks automatic retry when native bootstrap is already failed' {
        $hook = New-ArcQueueHook -Responses @(
            (New-ArcRemoteResponse `
                -OperationName 'Register-ArcNodeNativeBootstrapPrecheck' `
                -Data @(
                    (New-NativeBootstrapStatusResponse `
                        -Status 'Failed' `
                        -ErrorMessage 'Simulated native bootstrap failure.')
                ))
        )

        $context = New-ArcTestContext `
            -RemoteCommandInvoker $hook `
            -Mode 'InteractiveDeviceCode' `
            -AllowRegistration $true `
            -AllowDeviceCodeRegistration $true

        $result = & $registerArcPath `
            -Context $context

        $result.Passed |
            Should Be $false

        $result.Outcome |
            Should Be 'Blocked'

        $result.BootstrapStatus |
            Should Be 'Failed'

        $result.BootstrapError |
            Should Be 'Simulated native bootstrap failure.'

        $result.SupportLogCommand |
            Should Be 'Collect-ArcBootstrapSupportLogs'
    }

    It 'uses execution-host ARM token delegation without token persistence' {
        $registrationContent = Get-TestFileContent `
            -RelativePath 'azure\registration\Register-ArcNode.ps1'

        $registrationContent |
            Should Match 'Get-ExecutionHostArmAuthorization'

        $registrationContent |
            Should Match 'Get-AzAccessToken'

        $registrationContent |
            Should Match 'Convert-SecureTokenToPlainText'

        $registrationContent |
            Should Match 'ArmAccessToken = \$PlainAccessToken'

        $registrationContent |
            Should Match 'AccountId = \$AccountId'

        $registrationContent |
            Should Match 'SetAccessRuleProtection'

        $registrationContent |
            Should Match 'BUILTIN\\Administrators'

        $registrationContent |
            Should Match 'Remove-Item'

        $registrationContent |
            Should Not Match 'DeviceCodeUserCode'

        $registrationContent |
            Should Not Match 'DeviceCodeVerificationUri'

        $registrationContent |
            Should Not Match 'DeviceCodeExpiresOn'
    }

    It 'contains same-console native session polling and clipboard support' {
        $registrationContent = Get-TestFileContent `
            -RelativePath 'azure\registration\Register-ArcNode.ps1'

        $registrationContent |
            Should Match 'Invoke-NativeBootstrapSession'

        $registrationContent |
            Should Match 'Start-ArcBootstrap'

        $registrationContent |
            Should Match 'Get-ArcBootstrapStatus'

        $registrationContent |
            Should Match 'Start-Sleep'

        $registrationContent |
            Should Match 'Write-NativeBootstrapDeviceCode'

        $registrationContent |
            Should Match 'Set-Clipboard'

        $registrationContent |
            Should Match 'native_bootstrap_session_timeout_minutes'
    }
}