#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\..\bootstrap\os\HcnEnsure.Common.psm1" -Force
Import-Module "$PSScriptRoot\..\..\preflight\ManagementPlane.Common.psm1" -Force
Import-Module Az.Accounts -ErrorAction Stop

function Get-ArcValue {
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

function Get-ObjectValue {
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

function Get-ApprovalKey {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$NodeName
    )

    $phaseId = Get-ArcValue `
        -Object $Context `
        -Name 'PhaseId'

    $stageId = Get-ArcValue `
        -Object $Context `
        -Name 'StageId'

    if ($null -eq $phaseId) {
        $phaseId = 1
    }

    if ($null -eq $stageId) {
        $stageId = 4
    }

    return (
        "$phaseId." +
        "$stageId." +
        "$NodeName.NativeAzureLocalArcBootstrap"
    )
}

function Test-ApprovedOperation {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$ApprovalKey
    )

    $state = Get-ArcValue `
        -Object $Context `
        -Name 'State'

    $approvedOperations = Get-ArcValue `
        -Object $state `
        -Name 'approvedOperations'

    if ($null -eq $approvedOperations) {
        return $false
    }

    if ($approvedOperations -is [System.Collections.IDictionary]) {
        return (@($approvedOperations.Keys) -contains $ApprovalKey)
    }

    return (
        $null -ne $approvedOperations.PSObject.Properties[$ApprovalKey]
    )
}

function Get-ExecutionHostArmAuthorization {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    $contextAuthorization = Get-ObjectValue `
        -Object $Context `
        -Name 'NativeArcAuthorization'

    if ($null -ne $contextAuthorization) {
        $contextToken = Get-ObjectValue `
            -Object $contextAuthorization `
            -Name 'ArmAccessToken'

        $contextAccountId = [string](
            Get-ObjectValue `
                -Object $contextAuthorization `
                -Name 'AccountId'
        )

        if (
            $null -ne $contextToken -and
            -not [string]::IsNullOrWhiteSpace($contextAccountId)
        ) {
            return [pscustomobject]@{
                ArmAccessToken = $contextToken
                AccountId = $contextAccountId
                Source = 'RuntimeContext'
            }
        }
    }

    $azContext = Get-AzContext `
        -ErrorAction SilentlyContinue

    if ($null -eq $azContext) {
        throw (
            'Azure PowerShell context is unavailable. Complete Azure Government ' +
            'device authentication before native Arc registration.'
        )
    }

    if ($azContext.Environment.Name -ne 'AzureUSGovernment') {
        throw (
            'Azure PowerShell environment mismatch. Expected AzureUSGovernment; ' +
            "current environment is $($azContext.Environment.Name)."
        )
    }

    if ($azContext.Tenant.Id -ne $TenantId) {
        throw (
            "Azure PowerShell tenant mismatch. Expected $TenantId; current " +
            "tenant is $($azContext.Tenant.Id)."
        )
    }

    if ($azContext.Subscription.Id -ne $SubscriptionId) {
        throw (
            "Azure PowerShell subscription mismatch. Expected $SubscriptionId; " +
            "current subscription is $($azContext.Subscription.Id)."
        )
    }

    if ([string]::IsNullOrWhiteSpace([string]$azContext.Account.Id)) {
        throw 'Azure PowerShell context does not contain an account identifier.'
    }

    $accessToken = Get-AzAccessToken `
        -AsSecureString `
        -ErrorAction Stop

    if ($null -eq $accessToken.Token) {
        throw 'Azure PowerShell did not return an ARM access token.'
    }

    return [pscustomobject]@{
        ArmAccessToken = $accessToken.Token
        AccountId = [string]$azContext.Account.Id
        Source = 'AzContext'
    }
}

function Convert-SecureTokenToPlainText {
    param(
        [Parameter(Mandatory)]
        [object]$Token
    )

    if ($Token -is [string]) {
        return [string]$Token
    }

    if ($Token -isnot [System.Security.SecureString]) {
        throw (
            'ARM access token must be a SecureString or plaintext string runtime value.'
        )
    }

    $bstr = [IntPtr]::Zero

    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $Token
        )

        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $bstr
        )
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
                $bstr
            )
        }
    }
}

function Get-PendingNativeArcSession {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$NodeName
    )

    $state = Get-ArcValue `
        -Object $Context `
        -Name 'State'

    $pending = Get-ArcValue `
        -Object $state `
        -Name 'pendingInteractiveAuthentication'

    if ($null -eq $pending) {
        return $null
    }

    $pendingNode = [string](
        Get-ObjectValue `
            -Object $pending `
            -Name 'Node'
    )

    $pendingOperation = [string](
        Get-ObjectValue `
            -Object $pending `
            -Name 'Operation'
    )

    $workflow = [string](
        Get-ObjectValue `
            -Object $pending `
            -Name 'Workflow'
    )

    if (
        $pendingNode -eq $NodeName -and
        $pendingOperation -eq 'Register-ArcNode' -and
        $workflow -eq 'NativeAzureLocalBootstrap'
    ) {
        return $pending
    }

    return $null
}

function Get-NativeBootstrapStatus {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$OperationName
    )

    $response = Invoke-ManagementPlaneCommand `
        -Context $Context `
        -OperationName $OperationName `
        -ScriptBlock {
            function Get-RemoteValue {
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

            function Add-ErrorMessages {
                param(
                    [AllowNull()]
                    [object]$Errors,

                    [Parameter(Mandatory)]
                    [AllowEmptyCollection()]
                    [System.Collections.Generic.List[string]]$Target
                )

                foreach ($errorRecord in @($Errors)) {
                    $message = [string](
                        Get-RemoteValue `
                            -Object $errorRecord `
                            -Name 'ErrorMessage'
                    )

                    if (-not [string]::IsNullOrWhiteSpace($message)) {
                        $Target.Add($message)
                    }
                }
            }

            $statusCommand = Get-Command `
                -Name Get-ArcBootstrapStatus `
                -ErrorAction SilentlyContinue

            if ($null -eq $statusCommand) {
                return [pscustomobject]@{
                    CommandAvailable = $false
                    Status = 'Unavailable'
                    ErrorMessage = (
                        'Get-ArcBootstrapStatus is unavailable on the target node.'
                    )
                    RebootPending = $false
                    DetailedResponse = @()
                    DeviceCode = $null
                }
            }

                        try {
                            $rawStatusResults = @(
                                Get-ArcBootstrapStatus `
                                    -ErrorAction Stop
                            )

                            $rawStatus = @(
                                foreach ($candidate in $rawStatusResults) {
                                    if ($null -eq $candidate) {
                                        continue
                                    }

                                    if (
                                        $candidate -is [System.Collections.IDictionary] -and
                                        $candidate.Contains('Response')
                                    ) {
                                        $candidate
                                        continue
                                    }

                                    if (
                                        $candidate -isnot [System.Collections.IDictionary] -and
                                        $null -ne $candidate.PSObject.Properties['Response']
                                    ) {
                                        $candidate
                                    }
                                }
                            ) |
                                Select-Object -Last 1

                            if ($null -eq $rawStatus) {
                                $rawStatus = $rawStatusResults |
                                    Select-Object -Last 1
                            }
                        }
                        catch {
                return [pscustomobject]@{
                    CommandAvailable = $true
                    Status = 'Unknown'
                    ErrorMessage = $_.Exception.Message
                    RebootPending = $false
                    DetailedResponse = @()
                    DeviceCode = $null
                }
            }

            $responseObject = Get-RemoteValue `
                -Object $rawStatus `
                -Name 'Response'

            if ($null -eq $responseObject) {
                $responseObject = $rawStatus
            }

            $errorMessages = [System.Collections.Generic.List[string]]::new()

            Add-ErrorMessages `
                -Errors (
                    Get-RemoteValue `
                        -Object $responseObject `
                        -Name 'Errors'
                ) `
                -Target $errorMessages

            $queue = [System.Collections.Queue]::new()

            foreach (
                $detail in @(
                    Get-RemoteValue `
                        -Object $responseObject `
                        -Name 'DetailedResponse'
                )
            ) {
                if ($null -ne $detail) {
                    $queue.Enqueue($detail)
                }
            }

            $details = [System.Collections.Generic.List[object]]::new()
            $arcRegistration = $null
            $rebootPending = $false

            while ($queue.Count -gt 0) {
                $detail = $queue.Dequeue()

                if ($null -eq $detail) {
                    continue
                }

                $detailName = [string](
                    Get-RemoteValue `
                        -Object $detail `
                        -Name 'Name'
                )

                $detailStatus = [string](
                    Get-RemoteValue `
                        -Object $detail `
                        -Name 'Status'
                )

                $details.Add([pscustomobject]@{
                    Name = $detailName
                    Status = $detailStatus
                })

                if ($detailStatus -eq 'RebootPending') {
                    $rebootPending = $true
                }

                Add-ErrorMessages `
                    -Errors (
                        Get-RemoteValue `
                            -Object $detail `
                            -Name 'Errors'
                    ) `
                    -Target $errorMessages

                if ($detailName -eq 'ArcRegistration') {
                    $arcRegistration = $detail
                }

                foreach (
                    $child in @(
                        Get-RemoteValue `
                            -Object $detail `
                            -Name 'DetailedResponse'
                    )
                ) {
                    if ($null -ne $child) {
                        $queue.Enqueue($child)
                    }
                }
            }

            $deviceCode = $null

            if ($null -ne $arcRegistration) {
                $arcRegistrationMessage = [string](
                    Get-RemoteValue `
                        -Object $arcRegistration `
                        -Name 'Message'
                )

                if (
                    -not [string]::IsNullOrWhiteSpace(
                        $arcRegistrationMessage
                    )
                ) {
                    try {
                        $messageObject = $arcRegistrationMessage |
                            ConvertFrom-Json `
                                -ErrorAction Stop

                        $userCode = [string](
                            Get-RemoteValue `
                                -Object $messageObject `
                                -Name 'UserCode'
                        )

                        $verificationUri = [string](
                            Get-RemoteValue `
                                -Object $messageObject `
                                -Name 'VerificationUri'
                        )

                        if (
                            -not [string]::IsNullOrWhiteSpace($userCode) -and
                            -not [string]::IsNullOrWhiteSpace($verificationUri)
                        ) {
                            $deviceCode = [pscustomobject]@{
                                UserCode = $userCode
                                VerificationUri = $verificationUri
                                ExpiresOn = [string](
                                    Get-RemoteValue `
                                        -Object $messageObject `
                                        -Name 'ExpiresOn'
                                )
                            }
                        }
                    }
                    catch {
                        # ArcRegistration.Message is not always device-code JSON.
                    }
                }
            }

            return [pscustomobject]@{
                CommandAvailable = $true
                Status = [string](
                    Get-RemoteValue `
                        -Object $responseObject `
                        -Name 'Status'
                )
                ErrorMessage = (
                    @($errorMessages | Select-Object -Unique) -join '; '
                )
                RebootPending = $rebootPending
                DetailedResponse = $details.ToArray()
                DeviceCode = $deviceCode
            }
        }

    $data = @($response.Data) |
        Select-Object -First 1

    if ($null -eq $data) {
        throw 'Native Azure Local bootstrap status query returned no data.'
    }

    return $data
}

function Start-NativeBootstrap {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$AgentCommand,

        [Parameter(Mandatory)]
        [string]$ExpectedAgentPath,

        [Parameter(Mandatory)]
        [string]$HimdsServiceName,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$ResourceGroup,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter(Mandatory)]
        [string]$Cloud,

        [Parameter(Mandatory)]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [object]$ArmAccessToken,

        [Parameter(Mandatory)]
        [string]$AccountId
    )

    $plainAccessToken = Convert-SecureTokenToPlainText `
        -Token $ArmAccessToken

    try {
        $response = Invoke-ManagementPlaneCommand `
            -Context $Context `
            -OperationName 'Register-ArcNodeNativeBootstrapStart' `
            -ArgumentList @(
                $AgentCommand,
                $ExpectedAgentPath,
                $HimdsServiceName,
                $TenantId,
                $SubscriptionId,
                $ResourceGroup,
                $Location,
                $Cloud,
                $NodeName,
                $plainAccessToken,
                $AccountId
            ) `
            -ScriptBlock {
                param(
                    [string]$AgentCommand,
                    [string]$ExpectedAgentPath,
                    [string]$HimdsServiceName,
                    [string]$TenantId,
                    [string]$SubscriptionId,
                    [string]$ResourceGroup,
                    [string]$Location,
                    [string]$Cloud,
                    [string]$NodeName,
                    [string]$PlainAccessToken,
                    [string]$AccountId
                )

                function Resolve-AgentPath {
                    param(
                        [AllowNull()]
                        [string]$ExpectedPath
                    )

                    $candidatePaths = @(
                        $ExpectedPath
                        "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
                        "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
                    ) |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace($_)
                        } |
                        Select-Object -Unique

                    foreach ($candidatePath in $candidatePaths) {
                        if (
                            Test-Path `
                                -LiteralPath $candidatePath `
                                -PathType Leaf
                        ) {
                            return $candidatePath
                        }
                    }

                    $agent = Get-Command `
                        -Name "$AgentCommand.exe", $AgentCommand `
                        -ErrorAction SilentlyContinue |
                        Select-Object -First 1

                    if ($null -ne $agent) {
                        return [string]$agent.Source
                    }

                    return $null
                }

                foreach ($commandName in @(
                    'Start-ArcBootstrap'
                    'Get-ArcBootstrapStatus'
                )) {
                    if (
                        $null -eq (
                            Get-Command `
                                -Name $commandName `
                                -ErrorAction SilentlyContinue
                        )
                    ) {
                        throw (
                            "Native Azure Local Arc command $commandName is unavailable."
                        )
                    }
                }

                $agentPath = Resolve-AgentPath `
                    -ExpectedPath $ExpectedAgentPath

                if ([string]::IsNullOrWhiteSpace($agentPath)) {
                    throw 'Azure Connected Machine agent executable was not found.'
                }

                $himds = Get-Service `
                    -Name $HimdsServiceName `
                    -ErrorAction Stop

                if ($himds.Status -ne 'Running') {
                    throw (
                        "HIMDS service $HimdsServiceName is $($himds.Status); " +
                        'expected Running.'
                    )
                }

                $bootstrapConfigPath = Join-Path `
                    $env:TEMP `
                    (
                        "NativeArcBootstrap-$NodeName-" +
                        (Get-Date -Format 'yyyyMMdd-HHmmss') +
                        '.json'
                    )

                $bootstrapConfiguration = @{
                    ArcConfiguration = @{
                        ArcMultiServerConfiguration = @{
                            ResourceGroup = $ResourceGroup
                            TenantId = $TenantId
                            Location = $Location
                            SubscriptionId = $SubscriptionId
                            Cloud = $Cloud
                            GatewayId = $null
                            ArmAccessToken = $PlainAccessToken
                            AccountId = $AccountId
                            AzureLocalCloudFQDN = $null
                            AuthenticationScope = $null
                            AuthorityHost = $null
                        }
                    }
                }

                $bootstrapConfiguration |
                    ConvertTo-Json -Depth 8 |
                    Set-Content `
                        -LiteralPath $bootstrapConfigPath `
                        -Encoding utf8

                $acl = Get-Acl `
                    -LiteralPath $bootstrapConfigPath

                $acl.SetAccessRuleProtection(
                    $true,
                    $false
                )

                $systemRule = New-Object `
                    System.Security.AccessControl.FileSystemAccessRule(
                        'SYSTEM',
                        'FullControl',
                        'Allow'
                    )

                $administratorsRule = New-Object `
                    System.Security.AccessControl.FileSystemAccessRule(
                        'BUILTIN\Administrators',
                        'FullControl',
                        'Allow'
                    )

                $acl.AddAccessRule($systemRule)
                $acl.AddAccessRule($administratorsRule)

                Set-Acl `
                    -LiteralPath $bootstrapConfigPath `
                    -AclObject $acl

                try {
                    $null = Start-ArcBootstrap `
                        -ConfigFilePath $bootstrapConfigPath `
                        -ErrorAction Stop

                    Remove-Item `
                        -LiteralPath $bootstrapConfigPath `
                        -Force `
                        -ErrorAction SilentlyContinue

                    return [pscustomobject]@{
                        AgentPath = $agentPath
                        BootstrapConfigPath = $null
                        AlreadyInProgress = $false
                        AuthorizationDelegated = $true
                    }
                }
                catch {
                    $startError = $_.Exception.Message

                    Remove-Item `
                        -LiteralPath $bootstrapConfigPath `
                        -Force `
                        -ErrorAction SilentlyContinue

                    if (
                        $startError -match
                        '(?i)workitem\s+already\s+submi\w*\s+with\s+different\s+taskid'
                    ) {
                        return [pscustomobject]@{
                            AgentPath = $agentPath
                            BootstrapConfigPath = $null
                            AlreadyInProgress = $true
                            AuthorizationDelegated = $true
                        }
                    }

                    throw
                }
                finally {
                    $PlainAccessToken = $null
                }
            }

        $data = @($response.Data) |
            Select-Object -First 1

        if ($null -eq $data) {
            throw 'Native Azure Local bootstrap start returned no data.'
        }

        return [pscustomobject]@{
            AgentPath = [string](
                Get-ObjectValue `
                    -Object $data `
                    -Name 'AgentPath'
            )
            BootstrapConfigPath = [string](
                Get-ObjectValue `
                    -Object $data `
                    -Name 'BootstrapConfigPath'
            )
            AlreadyInProgress = [bool](
                Get-ObjectValue `
                    -Object $data `
                    -Name 'AlreadyInProgress'
            )
            AuthorizationDelegated = [bool](
                Get-ObjectValue `
                    -Object $data `
                    -Name 'AuthorizationDelegated'
            )
        }
    }
    finally {
        $plainAccessToken = $null
    }
}

function Remove-NativeBootstrapConfiguration {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [AllowNull()]
        [string]$BootstrapConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($BootstrapConfigPath)) {
        return
    }

    Invoke-ManagementPlaneCommand `
        -Context $Context `
        -OperationName 'RemoveNativeArcBootstrapConfiguration' `
        -ArgumentList @(
            $BootstrapConfigPath
        ) `
        -ScriptBlock {
            param(
                [string]$BootstrapConfigPath
            )

            Remove-Item `
                -LiteralPath $BootstrapConfigPath `
                -Force `
                -ErrorAction SilentlyContinue
        } |
        Out-Null
}

function Write-NativeBootstrapStatusRecord {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [object]$BootstrapStatus,

        [AllowNull()]
        [string]$ExistingPath
    )

    $statusRecordPath = $ExistingPath

    if ([string]::IsNullOrWhiteSpace($statusRecordPath)) {
        $runDirectory = [string](
            Get-ArcValue `
                -Object $Context `
                -Name 'RunDirectory'
        )

        if ([string]::IsNullOrWhiteSpace($runDirectory)) {
            throw 'Register-ArcNode requires Context.RunDirectory.'
        }

        $statusRecordPath = Join-Path `
            $runDirectory `
            (
                "evidence\native-arc-bootstrap-$NodeName-" +
                (Get-Date -Format 'yyyyMMdd-HHmmss') +
                '-status.json'
            )
    }

    $parentPath = Split-Path `
        -Path $statusRecordPath `
        -Parent

    New-Item `
        -ItemType Directory `
        -Path $parentPath `
        -Force |
        Out-Null

    # DeviceCode is deliberately excluded.
    $record = [ordered]@{
        TimestampUtc = [datetime]::UtcNow.ToString('o')
        Node = $NodeName
        Status = [string](
            Get-ObjectValue `
                -Object $BootstrapStatus `
                -Name 'Status'
        )
        ErrorMessage = [string](
            Get-ObjectValue `
                -Object $BootstrapStatus `
                -Name 'ErrorMessage'
        )
        RebootPending = [bool](
            Get-ObjectValue `
                -Object $BootstrapStatus `
                -Name 'RebootPending'
        )
        DetailedResponse = @(
            Get-ObjectValue `
                -Object $BootstrapStatus `
                -Name 'DetailedResponse'
        )
    }

    $record |
        ConvertTo-Json -Depth 8 |
        Set-Content `
            -LiteralPath $statusRecordPath `
            -Encoding utf8

    return $statusRecordPath
}

function Write-NativeBootstrapDeviceCode {
    param(
        [Parameter(Mandatory)]
        [object]$BootstrapStatus
    )

    $deviceCode = Get-ObjectValue `
        -Object $BootstrapStatus `
        -Name 'DeviceCode'

    if ($null -eq $deviceCode) {
        return $null
    }

    $userCode = [string](
        Get-ObjectValue `
            -Object $deviceCode `
            -Name 'UserCode'
    )

    $verificationUri = [string](
        Get-ObjectValue `
            -Object $deviceCode `
            -Name 'VerificationUri'
    )

    $expiresOn = [string](
        Get-ObjectValue `
            -Object $deviceCode `
            -Name 'ExpiresOn'
    )

    if (
        [string]::IsNullOrWhiteSpace($userCode) -or
        [string]::IsNullOrWhiteSpace($verificationUri)
    ) {
        return $null
    }

    Write-Host ''
    Write-Host 'AZURE GOVERNMENT DEVICE-CODE AUTHENTICATION REQUIRED' `
        -ForegroundColor Yellow
    Write-Host "  Open: $verificationUri" -ForegroundColor Yellow
    Write-Host "  Code: $userCode" -ForegroundColor Yellow

    if (-not [string]::IsNullOrWhiteSpace($expiresOn)) {
        Write-Host "  Expires: $expiresOn" -ForegroundColor Yellow
    }

    $clipboardValue = @(
        "URL: $verificationUri"
        "Code: $userCode"
        "Expires: $expiresOn"
    ) -join [Environment]::NewLine

    try {
        Set-Clipboard `
            -Value $clipboardValue

        Write-Host (
            '  The device-code URL and code were copied to the execution-host clipboard.'
        ) -ForegroundColor Yellow
    }
    catch {
        Write-Host (
            '  Clipboard copy was unavailable. Copy the displayed URL and code manually.'
        ) -ForegroundColor Yellow
    }

    Write-Host (
        '  Complete authentication in the browser. The factory session will ' +
        'continue polling native Azure Local bootstrap status.'
    ) -ForegroundColor Yellow
    Write-Host ''

    return "$verificationUri|$userCode|$expiresOn"
}

function New-NativeBootstrapPauseResult {
    param(
        [Parameter(Mandatory)]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [object]$BootstrapStatus,

        [AllowNull()]
        [string]$BootstrapConfigPath,

        [Parameter(Mandatory)]
        [string]$StatusRecordPath,

        [Parameter(Mandatory)]
        [ValidateSet('InteractiveAuthentication', 'Reboot')]
        [string]$PauseType,

        [Parameter(Mandatory)]
        [bool]$Changed
    )

    $rebootPending = (
        $PauseType -eq 'Reboot'
    )

    $reason = if ($rebootPending) {
        (
            'Native Azure Local Arc bootstrap reports RebootPending. ' +
            'Do not restart automatically. Obtain separate reboot approval, ' +
            'then resume the focused native registration session.'
        )
    }
    else {
        (
            'Native Azure Local Arc bootstrap session timed out while status ' +
            'remained in progress. Resume the focused registration session to ' +
            'continue polling without replaying Stage 4 readiness.'
        )
    }

    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Changed $Changed `
        -Summary $reason `
        -AdditionalProperties @{
            PauseRequested = $true
            PauseType = $PauseType
            AuthenticationMethod = 'DeviceCode'
            Workflow = 'NativeAzureLocalBootstrap'
            Node = $NodeName
            BootstrapStatus = [string](
                Get-ObjectValue `
                    -Object $BootstrapStatus `
                    -Name 'Status'
            )
            BootstrapConfigPath = $BootstrapConfigPath
            StatusRecordPath = $StatusRecordPath
            LogPath = $StatusRecordPath
            LastCheckedAtUtc = [datetime]::UtcNow.ToString('o')
            SessionStartedAtUtc = [datetime]::UtcNow.ToString('o')
            ReconnectTarget = $NodeName
            RequiresReboot = $rebootPending
            NativeBootstrapRebootPending = $rebootPending
            RebootReason = if ($rebootPending) {
                $reason
            }
            else {
                $null
            }
            Reason = $reason
            BootstrapDetails = @(
                Get-ObjectValue `
                    -Object $BootstrapStatus `
                    -Name 'DetailedResponse'
            )
        }
}

function New-NativeBootstrapSuccessResult {
    param(
        [Parameter(Mandatory)]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [string]$StatusRecordPath
    )

    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Changed' `
        -Changed $true `
        -Summary (
            "Native Azure Local Arc bootstrap succeeded for node $NodeName. " +
            'Proceeding to Azure Arc resource validation.'
        ) `
        -AdditionalProperties @{
            Node = $NodeName
            Workflow = 'NativeAzureLocalBootstrap'
            BootstrapStatus = 'Succeeded'
            StatusRecordPath = $StatusRecordPath
            AuthenticationMethod = 'DeviceCode'
            LastCheckedAtUtc = [datetime]::UtcNow.ToString('o')
        }
}

function Write-NativeBootstrapProgress {
    param(
        [Parameter(Mandatory)]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [object]$BootstrapStatus
    )

    $steps = @(
        Get-ObjectValue `
            -Object $BootstrapStatus `
            -Name 'DetailedResponse'
    )

    $terminalStatuses = @(
        'Succeeded'
        'NotApplicable'
        'Failed'
        'RebootPending'
    )

    $stepCount = $steps.Count

    $completedStepCount = @(
        $steps |
            Where-Object {
                $_.Status -in $terminalStatuses
            }
    ).Count

    $percentComplete = if ($stepCount -gt 0) {
        [math]::Floor(
            ($completedStepCount / $stepCount) * 100
        )
    }
    else {
        0
    }

    $bootstrapStatusName = [string](
        Get-ObjectValue `
            -Object $BootstrapStatus `
            -Name 'Status'
    )

    if (
        $bootstrapStatusName -eq 'InProgress' -and
        $percentComplete -ge 100
    ) {
        $percentComplete = 99
    }

    $keySteps = @(
        $steps |
            Where-Object {
                $_.Name -in @(
                    'ConnectivityValidation'
                    'ArcRegistration'
                    'ArcExtensionInstall'
                )
            }
    )

    if ($keySteps.Count -eq 0) {
        $keySteps = $steps
    }

    $summary = @(
        $keySteps |
            ForEach-Object {
                "$($_.Name)=$($_.Status)"
            }
    ) -join '; '

    if ([string]::IsNullOrWhiteSpace($summary)) {
        $summary = "Bootstrap=$bootstrapStatusName"
    }

    $signature = @(
        $steps |
            Sort-Object Name |
            ForEach-Object {
                "$($_.Name)=$($_.Status)"
            }
    ) -join '|'

    if ([string]::IsNullOrWhiteSpace($signature)) {
        $signature = "Bootstrap=$bootstrapStatusName"
    }

    Write-Progress `
        -Id 42 `
        -Activity "Native Azure Local Arc Bootstrap - $NodeName" `
        -Status $summary `
        -PercentComplete $percentComplete

    return [pscustomobject]@{
        Signature = $signature
        Summary = $summary
        PercentComplete = $percentComplete
        StepCount = $stepCount
        CompletedStepCount = $completedStepCount
    }
}
function Invoke-NativeBootstrapSession {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$NodeName,

        [Parameter(Mandatory)]
        [object]$InitialBootstrapStatus,

        [AllowNull()]
        [string]$BootstrapConfigPath,

        [AllowNull()]
        [string]$StatusRecordPath,

        [Parameter(Mandatory)]
        [int]$PollIntervalSeconds,

        [Parameter(Mandatory)]
        [int]$SessionTimeoutMinutes
    )

    $sessionDeadline = [datetime]::UtcNow.AddMinutes(
        $SessionTimeoutMinutes
    )

    $bootstrapStatus = $InitialBootstrapStatus
    $lastStatus = $null
    $lastProgressSignature = $null
    $lastDeviceCodeFingerprint = $null

    try {
        while ($true) {
            $statusRecordPath = Write-NativeBootstrapStatusRecord `
                -Context $Context `
                -NodeName $NodeName `
                -BootstrapStatus $bootstrapStatus `
                -ExistingPath $StatusRecordPath

            $nativeStatus = [string](
                Get-ObjectValue `
                    -Object $bootstrapStatus `
                    -Name 'Status'
            )

            $nativeError = [string](
                Get-ObjectValue `
                    -Object $bootstrapStatus `
                    -Name 'ErrorMessage'
            )

            $rebootPending = [bool](
                Get-ObjectValue `
                    -Object $bootstrapStatus `
                    -Name 'RebootPending'
            )

            if ([string]::IsNullOrWhiteSpace($nativeStatus)) {
                $nativeStatus = 'Unknown'
            }

            if ($nativeStatus -ne $lastStatus) {
                Write-Host (
                    "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
                    "Native Arc bootstrap status for ${NodeName}: $nativeStatus"
                ) -ForegroundColor Cyan

                $lastStatus = $nativeStatus
            }

            $progress = Write-NativeBootstrapProgress `
                -NodeName $NodeName `
                -BootstrapStatus $bootstrapStatus

            if ($progress.Signature -ne $lastProgressSignature) {
                Write-Host (
                    "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
                    "$NodeName | NativeBootstrap | " +
                    "$($progress.PercentComplete)% | " +
                    "$($progress.Summary)"
                ) -ForegroundColor Cyan

                $lastProgressSignature = $progress.Signature
            }

            $deviceCode = Get-ObjectValue `
                -Object $bootstrapStatus `
                -Name 'DeviceCode'

            $deviceCodeFingerprint = $null

            if ($null -ne $deviceCode) {
                $deviceCodeFingerprint = (
                    "$(
                        Get-ObjectValue `
                            -Object $deviceCode `
                            -Name 'VerificationUri'
                    )|$(
                        Get-ObjectValue `
                            -Object $deviceCode `
                            -Name 'UserCode'
                    )|$(
                        Get-ObjectValue `
                            -Object $deviceCode `
                            -Name 'ExpiresOn'
                    )"
                )
            }

            if (
                -not [string]::IsNullOrWhiteSpace($deviceCodeFingerprint) -and
                $deviceCodeFingerprint -ne $lastDeviceCodeFingerprint
            ) {
                [void](
                    Write-NativeBootstrapDeviceCode `
                        -BootstrapStatus $bootstrapStatus
                )

                $lastDeviceCodeFingerprint = $deviceCodeFingerprint
            }

            if ($rebootPending) {
                return New-NativeBootstrapPauseResult `
                    -NodeName $NodeName `
                    -BootstrapStatus $bootstrapStatus `
                    -BootstrapConfigPath $BootstrapConfigPath `
                    -StatusRecordPath $statusRecordPath `
                    -PauseType 'Reboot' `
                    -Changed $true
            }

            if ($nativeStatus -eq 'Succeeded') {
                Remove-NativeBootstrapConfiguration `
                    -Context $Context `
                    -BootstrapConfigPath $BootstrapConfigPath

                return New-NativeBootstrapSuccessResult `
                    -NodeName $NodeName `
                    -StatusRecordPath $statusRecordPath
            }

            if ($nativeStatus -eq 'Failed') {
                Remove-NativeBootstrapConfiguration `
                    -Context $Context `
                    -BootstrapConfigPath $BootstrapConfigPath

                if ([string]::IsNullOrWhiteSpace($nativeError)) {
                    $nativeError = (
                        'Native bootstrap returned Failed without an error message.'
                    )
                }

                throw (
                    "Native Azure Local Arc bootstrap failed for node $NodeName. " +
                    "Error: $nativeError. Review $statusRecordPath and use " +
                    'Collect-ArcBootstrapSupportLogs if directed by support.'
                )
            }

            if ([datetime]::UtcNow -ge $sessionDeadline) {
                return New-NativeBootstrapPauseResult `
                    -NodeName $NodeName `
                    -BootstrapStatus $bootstrapStatus `
                    -BootstrapConfigPath $BootstrapConfigPath `
                    -StatusRecordPath $statusRecordPath `
                    -PauseType 'InteractiveAuthentication' `
                    -Changed $true
            }

            Start-Sleep `
                -Seconds $PollIntervalSeconds

            $bootstrapStatus = Get-NativeBootstrapStatus `
                -Context $Context `
                -OperationName 'Register-ArcNodeNativeBootstrapStatus'
        }
    }
    finally {
        Write-Progress `
            -Id 42 `
            -Activity "Native Azure Local Arc Bootstrap - $NodeName" `
            -Completed
    }
}

$node = Get-ArcValue `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Register-ArcNode requires a node-scoped context.'
}

$config = Get-ArcValue `
    -Object $Context `
    -Name 'Config'

$azure = Get-ArcValue `
    -Object $config `
    -Name 'azure'

$arcRegistration = Get-ArcValue `
    -Object $azure `
    -Name 'arc_registration'

$arcAgent = Get-ArcValue `
    -Object $azure `
    -Name 'arc_agent'

$nodeName = [string](
    Get-ArcValue `
        -Object $node `
        -Name 'name'
)

$tenantId = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'tenant_id'
)

$subscriptionId = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'subscription_id'
)

$resourceGroup = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'resource_group'
)

$location = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'location'
)

$cloud = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'cloud'
)

$mode = [string](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'mode'
)

$allowRegistration = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'allow_registration'
)

$allowDeviceCodeRegistration = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'allow_device_code_registration'
)

$authenticationMethod = [string](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'authentication_method'
)

$agentCommand = [string](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'connected_machine_agent_command'
)

$expectedAgentPath = [string](
    Get-ArcValue `
        -Object $arcAgent `
        -Name 'agent_executable_path'
)

$himdsServiceName = [string](
    Get-ArcValue `
        -Object $arcAgent `
        -Name 'himds_service_name'
)

$statusPollIntervalSeconds = Get-ArcValue `
    -Object $arcRegistration `
    -Name 'native_bootstrap_status_poll_interval_seconds'

$sessionTimeoutMinutes = Get-ArcValue `
    -Object $arcRegistration `
    -Name 'native_bootstrap_session_timeout_minutes'

$allowAutomaticUpdate = (
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'allow_automatic_update'
) -eq $true

$allowAutomaticReboot = (
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'allow_automatic_reboot'
) -eq $true

if ([string]::IsNullOrWhiteSpace($agentCommand)) {
    $agentCommand = 'azcmagent'
}

if ([string]::IsNullOrWhiteSpace($himdsServiceName)) {
    $himdsServiceName = 'himds'
}

if ($null -eq $statusPollIntervalSeconds) {
    $statusPollIntervalSeconds = 15
}

if ($null -eq $sessionTimeoutMinutes) {
    $sessionTimeoutMinutes = 15
}

$statusPollIntervalSeconds = [Math]::Max(
    5,
    [int]$statusPollIntervalSeconds
)

$sessionTimeoutMinutes = [Math]::Max(
    1,
    [int]$sessionTimeoutMinutes
)

if ($allowAutomaticUpdate -or $allowAutomaticReboot) {
    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary (
            'Protected Arc registration policy must disable automatic update ' +
            'and automatic reboot before native bootstrap can start.'
        ) `
        -AdditionalProperties @{
            Node = $nodeName
            AllowAutomaticUpdate = $allowAutomaticUpdate
            AllowAutomaticReboot = $allowAutomaticReboot
        }
}

$requiredAzureValues = [ordered]@{
    tenant_id = $tenantId
    subscription_id = $subscriptionId
    resource_group = $resourceGroup
    location = $location
    cloud = $cloud
}

$missingAzureValues = @(
    $requiredAzureValues.GetEnumerator() |
        Where-Object {
            [string]::IsNullOrWhiteSpace(
                [string]$_.Value
            )
        } |
        ForEach-Object {
            $_.Key
        }
)

if ($missingAzureValues.Count -gt 0) {
    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary (
            "Native Azure Local Arc bootstrap cannot start for node $nodeName. " +
            "Missing Azure configuration value(s): " +
            "$($missingAzureValues -join ', ')."
        ) `
        -AdditionalProperties @{
            Node = $nodeName
            MissingAzureValues = $missingAzureValues
        }
}

if ($mode -eq 'ReadinessOnly') {
    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary (
            "Arc registration readiness is complete for node $nodeName, but " +
            'ReadinessOnly mode blocks live registration.'
        ) `
        -AdditionalProperties @{
            Node = $nodeName
            ArcRegistrationMode = $mode
            AllowRegistration = $allowRegistration
            AuthenticationMethod = $authenticationMethod
        }
}

if ($mode -ne 'InteractiveDeviceCode') {
    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary "Unsupported Arc registration mode $mode for node $nodeName." `
        -AdditionalProperties @{
            Node = $nodeName
        }
}

if (-not $allowRegistration -or -not $allowDeviceCodeRegistration) {
    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary "Arc registration is not enabled for node $nodeName." `
        -AdditionalProperties @{
            Node = $nodeName
        }
}

if ($authenticationMethod -ne 'DeviceCode') {
    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary (
            "Arc authentication method $authenticationMethod is not approved."
        ) `
        -AdditionalProperties @{
            Node = $nodeName
        }
}

$pendingSession = Get-PendingNativeArcSession `
    -Context $Context `
    -NodeName $nodeName

if ($null -ne $pendingSession) {
    $bootstrapConfigPath = [string](
        Get-ObjectValue `
            -Object $pendingSession `
            -Name 'BootstrapConfigPath'
    )

    $statusRecordPath = [string](
        Get-ObjectValue `
            -Object $pendingSession `
            -Name 'StatusRecordPath'
    )

    $bootstrapStatus = Get-NativeBootstrapStatus `
        -Context $Context `
        -OperationName 'Register-ArcNodeNativeBootstrapStatus'

    return Invoke-NativeBootstrapSession `
        -Context $Context `
        -NodeName $nodeName `
        -InitialBootstrapStatus $bootstrapStatus `
        -BootstrapConfigPath $bootstrapConfigPath `
        -StatusRecordPath $statusRecordPath `
        -PollIntervalSeconds $statusPollIntervalSeconds `
        -SessionTimeoutMinutes $sessionTimeoutMinutes
}

$currentBootstrapStatus = Get-NativeBootstrapStatus `
    -Context $Context `
    -OperationName 'Register-ArcNodeNativeBootstrapPrecheck'

$currentCommandAvailable = [bool](
    Get-ObjectValue `
        -Object $currentBootstrapStatus `
        -Name 'CommandAvailable'
)

$currentNativeStatus = [string](
    Get-ObjectValue `
        -Object $currentBootstrapStatus `
        -Name 'Status'
)

$currentNativeError = [string](
    Get-ObjectValue `
        -Object $currentBootstrapStatus `
        -Name 'ErrorMessage'
)

$currentRebootPending = [bool](
    Get-ObjectValue `
        -Object $currentBootstrapStatus `
        -Name 'RebootPending'
)

if (-not $currentCommandAvailable) {
    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary (
            "Native Azure Local bootstrap status command is unavailable on node " +
            "$nodeName. $currentNativeError"
        ) `
        -AdditionalProperties @{
            Node = $nodeName
        }
}

if ($currentRebootPending) {
    $reason = (
        'Native Azure Local Arc bootstrap requires a controlled reboot before ' +
        'registration validation can continue.'
    )

    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary $reason `
        -AdditionalProperties @{
            PauseRequested = $true
            PauseType = 'Reboot'
            Node = $nodeName
            ReconnectTarget = $nodeName
            RequiresReboot = $true
            NativeBootstrapRebootPending = $true
            RebootReason = $reason
            Reason = $reason
        }
}

$deviceCodeExpired = (
    $currentNativeStatus -eq 'Failed' -and
    $currentNativeError -match (
        '(?i)DeviceCodeExpiredException|verification code expired'
    )
)

if (
    $currentNativeStatus -eq 'Failed' -and
    -not $deviceCodeExpired
) {
    if ([string]::IsNullOrWhiteSpace($currentNativeError)) {
        $currentNativeError = 'No native bootstrap error detail was returned.'
    }

    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary (
            "Native Azure Local Arc bootstrap is Failed on node $nodeName. " +
            "Do not automatically retry. $currentNativeError"
        ) `
        -AdditionalProperties @{
            Node = $nodeName
            BootstrapStatus = 'Failed'
            BootstrapError = $currentNativeError
            SupportLogCommand = 'Collect-ArcBootstrapSupportLogs'
        }
}
if ($currentNativeStatus -eq 'Succeeded') {
    $agentRegistrationResponse = Invoke-ManagementPlaneCommand `
        -Context $Context `
        -OperationName 'Register-ArcNodeAgentRegistrationInspection' `
        -ArgumentList @(
            $expectedAgentPath,
            $agentCommand
        ) `
        -ScriptBlock {
            param(
                [string]$ExpectedAgentPath,
                [string]$AgentCommand
            )

            $candidatePaths = @(
                $ExpectedAgentPath
                "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
                "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
            ) |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Select-Object -Unique

            $agentPath = $null

            foreach ($candidatePath in $candidatePaths) {
                if (
                    Test-Path `
                        -LiteralPath $candidatePath `
                        -PathType Leaf
                ) {
                    $agentPath = $candidatePath
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($agentPath)) {
                $agent = Get-Command `
                    -Name "$AgentCommand.exe", $AgentCommand `
                    -ErrorAction SilentlyContinue |
                    Select-Object -First 1

                if ($null -ne $agent) {
                    $agentPath = [string]$agent.Source
                }
            }

            $agentShow = $null
            $agentShowObject = $null

            if (-not [string]::IsNullOrWhiteSpace($agentPath)) {
                $agentShow = @(
                    & $agentPath show -j 2>&1
                ) -join "`n"

                try {
                    $agentShowObject = $agentShow |
                        ConvertFrom-Json `
                            -ErrorAction Stop
                }
                catch {
                    $agentShowObject = $null
                }
            }

            [pscustomobject]@{
                AgentPresent = -not [string]::IsNullOrWhiteSpace($agentPath)
                AgentPath = $agentPath
                AgentStatus = if ($null -ne $agentShowObject) {
                    [string]$agentShowObject.status
                }
                else {
                    $null
                }
                ResourceId = if ($null -ne $agentShowObject) {
                    [string]$agentShowObject.resourceId
                }
                else {
                    $null
                }
                SubscriptionId = if ($null -ne $agentShowObject) {
                    [string]$agentShowObject.subscriptionId
                }
                else {
                    $null
                }
                ResourceGroup = if ($null -ne $agentShowObject) {
                    [string]$agentShowObject.resourceGroup
                }
                else {
                    $null
                }
            }
        }

    $agentRegistrationState = @(
        $agentRegistrationResponse.Data
    ) |
        Select-Object -First 1

    $agentCurrentlyRegistered = (
        $agentRegistrationState.AgentPresent -and
        $agentRegistrationState.AgentStatus -eq 'Connected' -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$agentRegistrationState.ResourceId
        ) -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$agentRegistrationState.SubscriptionId
        ) -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$agentRegistrationState.ResourceGroup
        )
    )

    if ($agentCurrentlyRegistered) {
        return New-HcnEnsureResult `
            -Check 'Register-ArcNode' `
            -Outcome 'AlreadyCompliant' `
            -Summary (
                "Native Azure Local Arc bootstrap and Connected Machine agent " +
                "both confirm current registration for node $nodeName."
            ) `
            -AdditionalProperties @{
                Node = $nodeName
                Workflow = 'NativeAzureLocalBootstrap'
                BootstrapStatus = 'Succeeded'
                AgentStatus = $agentRegistrationState.AgentStatus
                AgentResourceId = $agentRegistrationState.ResourceId
                AgentResourceGroup = $agentRegistrationState.ResourceGroup
                AgentSubscriptionId = $agentRegistrationState.SubscriptionId
            }
    }

    Write-Host (
        "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
        "$nodeName | Native bootstrap reports historical Succeeded state, " +
        'but no current Connected Machine agent identity exists. ' +
        'Treating the node as reset and eligible for fresh registration.'
    ) -ForegroundColor Yellow

    $currentNativeStatus = 'NotStarted'
}

if ($currentNativeStatus -eq 'InProgress') {
    return Invoke-NativeBootstrapSession `
        -Context $Context `
        -NodeName $nodeName `
        -InitialBootstrapStatus $currentBootstrapStatus `
        -BootstrapConfigPath $null `
        -StatusRecordPath $null `
        -PollIntervalSeconds $statusPollIntervalSeconds `
        -SessionTimeoutMinutes $sessionTimeoutMinutes
}

$approvalKey = Get-ApprovalKey `
    -Context $Context `
    -NodeName $nodeName

if ($deviceCodeExpired) {
    $approvalKey = "$approvalKey.DeviceCodeRetry"
}

if (-not (Test-ApprovedOperation -Context $Context -ApprovalKey $approvalKey)) {
    $approvalReason = if ($deviceCodeExpired) {
        (
            'The prior native Azure Local device code expired before authentication ' +
            'completed. The factory will request a new native bootstrap work item ' +
            'and present a fresh Azure Government device code. This action does not ' +
            'authorize automatic updates, reboots, or extension deployment.'
        )
    }
    else {
        (
            'The factory will start native Azure Local bootstrap and present ' +
            'Azure Government device-code authentication in the active ' +
            'registration session. This action does not authorize automatic ' +
            'updates, reboots, or extension deployment.'
        )
    }

    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary (
            "Native Azure Local Arc bootstrap is required for node $nodeName."
        ) `
        -AdditionalProperties @{
            RequiresApproval = $true
            ApprovalKey = $approvalKey
            ApprovalReason = $approvalReason
            RequiresReboot = $false
            ReconnectTarget = $nodeName
            Node = $nodeName
        }
}

$armAuthorization = Get-ExecutionHostArmAuthorization `
    -Context $Context `
    -TenantId $tenantId `
    -SubscriptionId $subscriptionId

$startResult = Start-NativeBootstrap `
    -Context $Context `
    -AgentCommand $agentCommand `
    -ExpectedAgentPath $expectedAgentPath `
    -HimdsServiceName $himdsServiceName `
    -TenantId $tenantId `
    -SubscriptionId $subscriptionId `
    -ResourceGroup $resourceGroup `
    -Location $location `
    -Cloud $cloud `
    -NodeName $nodeName `
    -ArmAccessToken $armAuthorization.ArmAccessToken `
    -AccountId $armAuthorization.AccountId
    
$armAuthorization = $null

$bootstrapStatus = Get-NativeBootstrapStatus `
    -Context $Context `
    -OperationName 'Register-ArcNodeNativeBootstrapStatus'

return Invoke-NativeBootstrapSession `
    -Context $Context `
    -NodeName $nodeName `
    -InitialBootstrapStatus $bootstrapStatus `
    -BootstrapConfigPath $startResult.BootstrapConfigPath `
    -StatusRecordPath $null `
    -PollIntervalSeconds $statusPollIntervalSeconds `
    -SessionTimeoutMinutes $sessionTimeoutMinutes