#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop
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
        }
    }

    $result = $InputObject

    if (
        $result -is [System.Collections.IEnumerable] -and
        $result -isnot [string]
    ) {
        $statusCandidates = @(
            foreach ($candidate in @($result)) {
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
        )

        $result = $statusCandidates |
            Select-Object -Last 1

        if ($null -eq $result) {
            $result = @($InputObject) |
                Select-Object -Last 1
        }
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
                    Status = [string](
                        Get-ObjectValue `
                            -Object $_ `
                            -Name 'Status'
                    )
                }
            }
    )

    $errors = @(
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
        ErrorMessage = $errors
        RebootPending = @(
            $details |
                Where-Object {
                    $_.Status -eq 'RebootPending'
                }
        ).Count -gt 0
    }
}

$node = Get-ArcValue `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Test-ArcRegistration requires a node-scoped context.'
}

$config = Get-ArcValue `
    -Object $Context `
    -Name 'Config'

$azure = Get-ArcValue `
    -Object $config `
    -Name 'azure'

$arcAgent = Get-ArcValue `
    -Object $azure `
    -Name 'arc_agent'

$arcRegistration = Get-ArcValue `
    -Object $azure `
    -Name 'arc_registration'

$resourceGroup = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'resource_group'
)

$subscriptionId = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'subscription_id'
)

$tenantId = [string](
    Get-ArcValue `
        -Object $azure `
        -Name 'tenant_id'
)

$nodeName = [string](
    Get-ArcValue `
        -Object $node `
        -Name 'name'
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

$visibilityTimeoutMinutes = Get-ArcValue `
    -Object $arcRegistration `
    -Name 'azure_resource_visibility_timeout_minutes'

$visibilityPollIntervalSeconds = Get-ArcValue `
    -Object $arcRegistration `
    -Name 'azure_resource_visibility_poll_interval_seconds'

if ([string]::IsNullOrWhiteSpace($himdsServiceName)) {
    $himdsServiceName = 'himds'
}

if ($null -eq $visibilityTimeoutMinutes) {
    $visibilityTimeoutMinutes = 10
}

if ($null -eq $visibilityPollIntervalSeconds) {
    $visibilityPollIntervalSeconds = 15
}

$visibilityTimeoutMinutes = [Math]::Max(
    1,
    [int]$visibilityTimeoutMinutes
)

$visibilityPollIntervalSeconds = [Math]::Max(
    5,
    [int]$visibilityPollIntervalSeconds
)

$azContext = Get-AzContext

if ($null -eq $azContext) {
    throw 'Azure PowerShell context is unavailable for Arc registration validation.'
}

if ($azContext.Environment.Name -ne 'AzureUSGovernment') {
    throw (
        "Azure environment mismatch. Expected AzureUSGovernment; current " +
        "environment is $($azContext.Environment.Name)."
    )
}

if ($azContext.Tenant.Id -ne $tenantId) {
    throw (
        "Azure tenant mismatch. Expected $tenantId; current tenant is " +
        "$($azContext.Tenant.Id)."
    )
}

if ($azContext.Subscription.Id -ne $subscriptionId) {
    throw (
        "Azure subscription mismatch. Expected $subscriptionId; current " +
        "subscription is $($azContext.Subscription.Id)."
    )
}

$nodeStateResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-ArcRegistration' `
    -ArgumentList @(
        $expectedAgentPath,
        $himdsServiceName
    ) `
    -ScriptBlock {
        param(
            [string]$ExpectedAgentPath,
            [string]$HimdsServiceName
        )

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
                -Name 'azcmagent.exe', 'azcmagent' `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($null -ne $agent) {
                return [string]$agent.Source
            }

            return $null
        }

                function ConvertTo-NativeBootstrapSummary {
            param(
                [AllowNull()]
                [object]$InputObject
            )

            if ($null -eq $InputObject) {
                return [pscustomobject]@{
                    Status = 'Unknown'
                    ErrorMessage = $null
                    RebootPending = $false
                }
            }

            $result = $InputObject

            if (
                $result -is [System.Collections.IEnumerable] -and
                $result -isnot [string]
            ) {
                $statusCandidates = @(
                    foreach ($candidate in @($result)) {
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
                )

                $result = $statusCandidates |
                    Select-Object -Last 1

                if ($null -eq $result) {
                    $result = @($InputObject) |
                        Select-Object -Last 1
                }
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
                    }
                }
            }

            $response = Get-RemoteValue `
                -Object $result `
                -Name 'Response'

            if ($null -eq $response) {
                $response = $result
            }

            $details = @(
                @(
                    Get-RemoteValue `
                        -Object $response `
                        -Name 'DetailedResponse'
                ) |
                    ForEach-Object {
                        [pscustomobject]@{
                            Status = [string](
                                Get-RemoteValue `
                                    -Object $_ `
                                    -Name 'Status'
                            )
                        }
                    }
            )

            $errors = @(
                @(
                    Get-RemoteValue `
                        -Object $response `
                        -Name 'Errors'
                ) |
                    ForEach-Object {
                        [string](
                            Get-RemoteValue `
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
                    Get-RemoteValue `
                        -Object $response `
                        -Name 'Status'
                )
                ErrorMessage = $errors
                RebootPending = @(
                    $details |
                        Where-Object {
                            $_.Status -eq 'RebootPending'
                        }
                ).Count -gt 0
            }
        }

        $agentPath = Resolve-AgentPath `
            -ExpectedPath $ExpectedAgentPath

        $himds = Get-Service `
            -Name $HimdsServiceName `
            -ErrorAction SilentlyContinue

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

                $statusCommand = Get-Command `
                    -Name Get-ArcBootstrapStatus `
                    -ErrorAction SilentlyContinue

                $nativeBootstrapSummary = [pscustomobject]@{
                    Status = 'Unavailable'
                    ErrorMessage = $null
                    RebootPending = $false
                }

                if ($null -ne $statusCommand) {
                    try {
                        $nativeBootstrapSummary = ConvertTo-NativeBootstrapSummary `
                            -InputObject (
                                Get-ArcBootstrapStatus `
                                    -ErrorAction Stop
                            )
                    }
                    catch {
                        $nativeBootstrapSummary = [pscustomobject]@{
                            Status = 'Unknown'
                            ErrorMessage = $_.Exception.Message
                            RebootPending = $false
                        }
                    }
                }
                else {
                    $nativeBootstrapSummary = [pscustomobject]@{
                        Status = 'Unavailable'
                        ErrorMessage = (
                            'Get-ArcBootstrapStatus is unavailable on the target node.'
                        )
                        RebootPending = $false
                    }
                }

        [pscustomobject]@{
            AgentPresent = -not [string]::IsNullOrWhiteSpace($agentPath)
            AgentPath = $agentPath
            HimdsPresent = ($null -ne $himds)
            HimdsStatus = if ($null -ne $himds) {
                [string]$himds.Status
            }
            else {
                $null
            }
            AgentShow = $agentShow
            AgentStatus = [string](
                Get-RemoteValue `
                    -Object $agentShowObject `
                    -Name 'status'
            )
            AgentResourceId = [string](
                Get-RemoteValue `
                    -Object $agentShowObject `
                    -Name 'resourceId'
            )
            
            NativeBootstrapStatus = $nativeBootstrapSummary.Status
            NativeBootstrapError = $nativeBootstrapSummary.ErrorMessage
            NativeBootstrapRebootPending = (
                $nativeBootstrapSummary.RebootPending
            )
        }
    }

$nodeState = @($nodeStateResponse.Data) |
    Select-Object -First 1

if (-not $nodeState.AgentPresent) {
    throw "Azure Connected Machine agent is not present on node $nodeName."
}

if (-not $nodeState.HimdsPresent) {
    throw "Azure Arc HIMDS service is not present on node $nodeName."
}

if ($nodeState.HimdsStatus -ne 'Running') {
    throw (
        "Azure Arc HIMDS service is $($nodeState.HimdsStatus) on node " +
        "$nodeName; expected Running."
    )
}

$nativeBootstrapStatus = [pscustomobject]@{
    Status = [string]$nodeState.NativeBootstrapStatus
    ErrorMessage = [string]$nodeState.NativeBootstrapError
    RebootPending = [bool]$nodeState.NativeBootstrapRebootPending
}

if ($nativeBootstrapStatus.RebootPending) {
    throw (
        "Native Azure Local Arc bootstrap reports RebootPending on node " +
        "$nodeName. Complete the separately approved reboot before Arc " +
        'resource validation.'
    )
}

if ($nativeBootstrapStatus.Status -ne 'Succeeded') {
    $nativeError = [string]$nativeBootstrapStatus.ErrorMessage

    if ([string]::IsNullOrWhiteSpace($nativeError)) {
        $nativeError = 'No native bootstrap error detail was returned.'
    }

    throw (
        "Native Azure Local Arc bootstrap is $($nativeBootstrapStatus.Status) " +
        "on node $nodeName; expected Succeeded. $nativeError"
    )
}

$visibilityDeadline = [datetime]::UtcNow.AddMinutes(
    $visibilityTimeoutMinutes
)

$arcResource = $null
$provisioningState = $null
$attempt = 0

do {
    $attempt++

    $arcResource = Get-AzResource `
        -ResourceGroupName $resourceGroup `
        -Name $nodeName `
        -ResourceType 'Microsoft.HybridCompute/machines' `
        -ErrorAction SilentlyContinue

    if ($null -ne $arcResource) {
        $provisioningState = [string](
            $arcResource.Properties.provisioningState
        )

        if (
            [string]::IsNullOrWhiteSpace($provisioningState) -or
            $provisioningState -eq 'Succeeded'
        ) {
            break
        }

        Write-Host (
            "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
            "Azure Arc resource $nodeName is visible, but provisioning state " +
            "is $provisioningState. Waiting for Succeeded."
        ) -ForegroundColor Yellow
    }
    else {
        Write-Host (
            "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
            "Waiting for Azure Arc resource $nodeName to appear in resource " +
            "group $resourceGroup."
        ) -ForegroundColor Yellow
    }

    if ([datetime]::UtcNow -ge $visibilityDeadline) {
        break
    }

    Start-Sleep `
        -Seconds $visibilityPollIntervalSeconds
}
while ([datetime]::UtcNow -lt $visibilityDeadline)

if ($null -eq $arcResource) {
    throw (
        "Azure Arc machine resource $nodeName was not visible in resource group " +
        "$resourceGroup after $visibilityTimeoutMinutes minute(s). Local native " +
        "bootstrap succeeded; recheck Azure Resource Manager visibility and " +
        'configured Azure connectivity before retrying validation.'
    )
}

if (
    -not [string]::IsNullOrWhiteSpace($provisioningState) -and
    $provisioningState -ne 'Succeeded'
) {
    throw (
        "Azure Arc machine resource $nodeName provisioning state remained " +
        "$provisioningState after $visibilityTimeoutMinutes minute(s); expected Succeeded."
    )
}

return [pscustomobject]@{
    Passed = $true
    Check = 'Test-ArcRegistration'
    Node = $nodeName
    ManagementIp = $nodeStateResponse.ManagementIp
    ResourceGroup = $resourceGroup
    ArcResourceId = $arcResource.ResourceId
    ArcResourceName = $arcResource.Name
    ArcProvisioningState = $provisioningState
    AgentPresent = $nodeState.AgentPresent
    AgentPath = $nodeState.AgentPath
    AgentStatus = $nodeState.AgentStatus
    AgentResourceId = $nodeState.AgentResourceId
    HimdsStatus = $nodeState.HimdsStatus
    NativeBootstrapStatus = $nativeBootstrapStatus.Status
    VisibilityAttempts = $attempt
    Summary = (
        "Native Azure Local Arc bootstrap, local HIMDS state, and Azure Arc " +
        "machine resource $($arcResource.Name) were validated."
    )
    ValidatedAt = [datetime]::UtcNow.ToString('o')
}