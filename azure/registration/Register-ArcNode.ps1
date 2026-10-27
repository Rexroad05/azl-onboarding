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

function Find-DeviceCode {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return $null
        }

        try {
            $parsedValue = $Value |
                ConvertFrom-Json `
                    -ErrorAction Stop

            return Find-DeviceCode `
                -Value $parsedValue
        }
        catch {
            return $null
        }
    }

    $userCode = Get-ObjectValue `
        -Object $Value `
        -Name 'UserCode'

    $verificationUri = Get-ObjectValue `
        -Object $Value `
        -Name 'VerificationUri'

    if (
        -not [string]::IsNullOrWhiteSpace(
            [string]$userCode
        ) -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$verificationUri
        )
    ) {
        return [pscustomobject]@{
            UserCode = [string]$userCode
            VerificationUri = [string]$verificationUri
            ExpiresOn = [string](
                Get-ObjectValue `
                    -Object $Value `
                    -Name 'ExpiresOn'
            )
        }
    }

    if (
        $Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [string]
    ) {
        foreach ($item in @($Value)) {
            $deviceCode = Find-DeviceCode `
                -Value $item

            if ($null -ne $deviceCode) {
                return $deviceCode
            }
        }

        return $null
    }

    foreach ($property in @($Value.PSObject.Properties)) {
        $deviceCode = Find-DeviceCode `
            -Value $property.Value

        if ($null -ne $deviceCode) {
            return $deviceCode
        }
    }

    return $null
}

function ConvertTo-NativeBootstrapResult {
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return [pscustomobject]@{
            Status = 'Unknown'
            ErrorMessage = $null
            RebootPending = $false
            DetailedResponse = @()
            DeviceCode = $null
        }
    }

    $result = $InputObject

    if (
        $result -is [System.Collections.IEnumerable] -and
        $result -isnot [string]
    ) {
        $result = @($result) |
            Select-Object -Last 1
    }

    if ($result -is [string]) {
        try {
            $result = $result |
                ConvertFrom-Json `
                    -ErrorAction Stop
        }
        catch {
            return [pscustomobject]@{
                Status = 'Unknown'
                ErrorMessage = $_.Exception.Message
                RebootPending = $false
                DetailedResponse = @()
                DeviceCode = $null
            }
        }
    }

    $response = Get-ObjectValue `
        -Object $result `
        -Name 'Response'

    if ($null -eq $response) {
        $response = $result
    }

    $details = @(
        @(
            Get-ObjectValue `
                -Object $response `
                -Name 'DetailedResponse'
        ) |
            ForEach-Object {
                [pscustomobject]@{
                    Name = [string](
                        Get-ObjectValue `
                            -Object $_ `
                            -Name 'Name'
                    )
                    Status = [string](
                        Get-ObjectValue `
                            -Object $_ `
                            -Name 'Status'
                    )
                }
            }
    )

    $errorMessage = @(
        @(
            Get-ObjectValue `
                -Object $response `
                -Name 'Errors'
        ) |
            ForEach-Object {
                [string](
                    Get-ObjectValue `
                        -Object $_ `
                        -Name 'ErrorMessage'
                )
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    ) -join '; '

    return [pscustomobject]@{
        Status = [string](
            Get-ObjectValue `
                -Object $response `
                -Name 'Status'
        )
        ErrorMessage = $errorMessage
        RebootPending = @(
            $details |
                Where-Object {
                    $_.Status -eq 'RebootPending'
                }
        ).Count -gt 0
        DetailedResponse = $details
        DeviceCode = Find-DeviceCode `
            -Value $response
    }
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
            $statusCommand = Get-Command `
                -Name Get-ArcBootstrapStatus `
                -ErrorAction SilentlyContinue

            if ($null -eq $statusCommand) {
                return [pscustomobject]@{
                    CommandAvailable = $false
                    ErrorMessage = (
                        'Get-ArcBootstrapStatus is unavailable on the target node.'
                    )
                    RawStatus = $null
                }
            }

            try {
                return [pscustomobject]@{
                    CommandAvailable = $true
                    ErrorMessage = $null
                    RawStatus = (
                        Get-ArcBootstrapStatus `
                            -ErrorAction Stop
                    )
                }
            }
            catch {
                return [pscustomobject]@{
                    CommandAvailable = $true
                    ErrorMessage = $_.Exception.Message
                    RawStatus = $null
                }
            }
        }

    $data = @($response.Data) |
        Select-Object -First 1

    if ($null -eq $data) {
        throw 'Native Azure Local bootstrap status query returned no data.'
    }

    if (-not [bool]$data.CommandAvailable) {
        return [pscustomobject]@{
            CommandAvailable = $false
            Status = 'Unavailable'
            ErrorMessage = [string]$data.ErrorMessage
            RebootPending = $false
            DetailedResponse = @()
            DeviceCode = $null
        }
    }

    $bootstrapResult = ConvertTo-NativeBootstrapResult `
        -InputObject $data.RawStatus

    if (
        -not [string]::IsNullOrWhiteSpace(
            [string]$data.ErrorMessage
        )
    ) {
        $bootstrapResult.ErrorMessage = [string]$data.ErrorMessage
    }

    $bootstrapResult |
        Add-Member `
            -MemberType NoteProperty `
            -Name CommandAvailable `
            -Value $true `
            -Force

    return $bootstrapResult
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
        [string]$NodeName
    )

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
            $NodeName
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
                [string]$NodeName
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
                        ArmAccessToken = $null
                        AccountId = $null
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

            try {
                return [pscustomobject]@{
                    AgentPath = $agentPath
                    BootstrapConfigPath = $bootstrapConfigPath
                    RawBootstrapStatus = (
                        Start-ArcBootstrap `
                            -ConfigFilePath $bootstrapConfigPath `
                            -ErrorAction Stop
                    )
                }
            }
            catch {
                Remove-Item `
                    -LiteralPath $bootstrapConfigPath `
                    -Force `
                    -ErrorAction SilentlyContinue

                throw
            }
        }

    $data = @($response.Data) |
        Select-Object -First 1

    if ($null -eq $data) {
        throw 'Native Azure Local bootstrap start returned no data.'
    }

    return [pscustomobject]@{
        AgentPath = [string]$data.AgentPath
        BootstrapConfigPath = [string]$data.BootstrapConfigPath
        BootstrapStatus = ConvertTo-NativeBootstrapResult `
            -InputObject $data.RawBootstrapStatus
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

    # Deliberately excludes DeviceCode and raw nested service messages.
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
    $lastDeviceCodeFingerprint = $null

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

        if ($nativeStatus -ne $lastStatus) {
            Write-Host (
                "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
                "Native Arc bootstrap status for ${NodeName}: $nativeStatus"
            ) -ForegroundColor Cyan

            $lastStatus = $nativeStatus
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

if (-not $currentBootstrapStatus.CommandAvailable) {
    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary (
            "Native Azure Local bootstrap status command is unavailable on node " +
            "$nodeName. $($currentBootstrapStatus.ErrorMessage)"
        ) `
        -AdditionalProperties @{
            Node = $nodeName
        }
}

if ($currentBootstrapStatus.RebootPending) {
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

if ($currentBootstrapStatus.Status -eq 'Succeeded') {
    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            "Native Azure Local Arc bootstrap already reports Succeeded for " +
            "node $nodeName."
        ) `
        -AdditionalProperties @{
            Node = $nodeName
            Workflow = 'NativeAzureLocalBootstrap'
            BootstrapStatus = 'Succeeded'
        }
}

if ($currentBootstrapStatus.Status -eq 'Failed') {
    $nativeError = [string]$currentBootstrapStatus.ErrorMessage

    if ([string]::IsNullOrWhiteSpace($nativeError)) {
        $nativeError = 'No native bootstrap error detail was returned.'
    }

    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary (
            "Native Azure Local Arc bootstrap is Failed on node $nodeName. " +
            "Do not automatically retry. $nativeError"
        ) `
        -AdditionalProperties @{
            Node = $nodeName
            BootstrapStatus = 'Failed'
            BootstrapError = $nativeError
            SupportLogCommand = 'Collect-ArcBootstrapSupportLogs'
        }
}

$approvalKey = Get-ApprovalKey `
    -Context $Context `
    -NodeName $nodeName

if (-not (Test-ApprovedOperation -Context $Context -ApprovalKey $approvalKey)) {
    return New-HcnEnsureResult `
        -Check 'Register-ArcNode' `
        -Outcome 'Blocked' `
        -Summary (
            "Native Azure Local Arc bootstrap is required for node $nodeName."
        ) `
        -AdditionalProperties @{
            RequiresApproval = $true
            ApprovalKey = $approvalKey
            ApprovalReason = (
                'The factory will start native Azure Local bootstrap and present ' +
                'Azure Government device-code authentication in the active ' +
                'registration session. This action does not authorize automatic ' +
                'updates, reboots, or extension deployment.'
            )
            RequiresReboot = $false
            ReconnectTarget = $nodeName
            Node = $nodeName
        }
}

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
    -NodeName $nodeName

return Invoke-NativeBootstrapSession `
    -Context $Context `
    -NodeName $nodeName `
    -InitialBootstrapStatus $startResult.BootstrapStatus `
    -BootstrapConfigPath $startResult.BootstrapConfigPath `
    -StatusRecordPath $null `
    -PollIntervalSeconds $statusPollIntervalSeconds `
    -SessionTimeoutMinutes $sessionTimeoutMinutes