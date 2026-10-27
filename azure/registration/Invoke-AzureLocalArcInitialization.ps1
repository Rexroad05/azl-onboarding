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

$node = Get-ArcValue `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Invoke-AzureLocalArcInitialization requires a node-scoped context.'
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

$requireConnectedMachineAgent = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'require_connected_machine_agent'
)

$requireExistingClusterBlock = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'require_existing_cluster_block'
)

$requireExistingArcRegistrationBlock = [bool](
    Get-ArcValue `
        -Object $arcRegistration `
        -Name 'require_existing_arc_registration_block'
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

if ([string]::IsNullOrWhiteSpace($agentCommand)) {
    $agentCommand = 'azcmagent'
}

if ([string]::IsNullOrWhiteSpace($himdsServiceName)) {
    $himdsServiceName = 'himds'
}

$inspectionResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Invoke-AzureLocalArcInitialization' `
    -ArgumentList @(
        $agentCommand,
        $expectedAgentPath,
        $himdsServiceName
    ) `
    -ScriptBlock {
        param(
            [string]$AgentCommand,
            [string]$ExpectedAgentPath,
            [string]$HimdsServiceName
        )

        function Resolve-AzureConnectedMachineAgentPath {
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

        function ConvertTo-NativeBootstrapSummary {
            param(
                [AllowNull()]
                [object]$InputObject
            )

            if ($null -eq $InputObject) {
                return [pscustomobject]@{
                    Status           = 'Unknown'
                    ErrorMessage     = $null
                    RebootPending    = $false
                    DetailedResponse = @()
                }
            }

            $result = $InputObject

            if ($result -is [string]) {
                try {
                    $result = $result | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    return [pscustomobject]@{
                        Status           = 'Unknown'
                        ErrorMessage     = $_.Exception.Message
                        RebootPending    = $false
                        DetailedResponse = @()
                    }
                }
            }

            $response = $result.Response

            if ($null -eq $response) {
                $response = $result
            }

            $detailedResponse = @(
                @($response.DetailedResponse) |
                    ForEach-Object {
                        [pscustomobject]@{
                            Name       = [string]$_.Name
                            Status     = [string]$_.Status
                            HasMessage = -not [string]::IsNullOrWhiteSpace(
                                [string]$_.Message
                            )
                        }
                    }
            )

            $errorMessage = @(
                @($response.Errors) |
                    ForEach-Object {
                        [string]$_.ErrorMessage
                    } |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace($_)
                    }
            ) -join '; '

            [pscustomobject]@{
                Status           = [string]$response.Status
                ErrorMessage     = $errorMessage
                RebootPending    = @(
                    @($detailedResponse) |
                        Where-Object {
                            $_.Status -eq 'RebootPending'
                        }
                ).Count -gt 0
                DetailedResponse = $detailedResponse
            }
        }

$cluster = Get-Cluster -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        $registrationStatus = $null
        $azureResourceName = $null

        $getAzureStackHciCommand = Get-Command `
            -Name Get-AzureStackHci `
            -ErrorAction SilentlyContinue

        if ($null -ne $getAzureStackHciCommand) {
            $azureStackHci = Get-AzureStackHci `
                -ErrorAction SilentlyContinue

            if ($null -ne $azureStackHci) {
                $registrationStatus = [string]$azureStackHci.RegistrationStatus
                $azureResourceName = [string]$azureStackHci.AzureResourceName
            }
        }

        $nativeBootstrapCommands = @(
            'Start-ArcBootstrap'
            'Get-ArcBootstrapStatus'
            'Collect-ArcBootstrapSupportLogs'
        )

        $nativeBootstrapAvailability = @{}

        foreach ($commandName in $nativeBootstrapCommands) {
            $nativeBootstrapAvailability[$commandName] = (
                $null -ne (
                    Get-Command `
                        -Name $commandName `
                        -ErrorAction SilentlyContinue
                )
            )
        }

        $nativeBootstrapSummary = [pscustomobject]@{
            Status           = 'Unavailable'
            ErrorMessage     = $null
            RebootPending    = $false
            DetailedResponse = @()
        }

        if ($nativeBootstrapAvailability['Get-ArcBootstrapStatus']) {
            try {
                $nativeBootstrapSummary = ConvertTo-NativeBootstrapSummary `
                    -InputObject (
                        Get-ArcBootstrapStatus `
                            -ErrorAction Stop
                    )
            }
            catch {
                $nativeBootstrapSummary = [pscustomobject]@{
                    Status           = 'Unknown'
                    ErrorMessage     = $_.Exception.Message
                    RebootPending    = $false
                    DetailedResponse = @()
                }
            }
        }

        $agentPath = Resolve-AzureConnectedMachineAgentPath `
            -ExpectedPath $ExpectedAgentPath

        $himdsService = Get-Service `
            -Name $HimdsServiceName `
            -ErrorAction SilentlyContinue

        $agentShow = $null

        if (-not [string]::IsNullOrWhiteSpace($agentPath)) {
            $agentShow = @(
                & $agentPath show -j 2>&1
            ) -join "`n"
        }

        [pscustomobject]@{
            ComputerName                 = $env:COMPUTERNAME
            Clustered                    = ($null -ne $cluster)
            ClusterName                  = if ($null -ne $cluster) {
                [string]$cluster.Name
            }
            else {
                $null
            }
            RegistrationStatus           = $registrationStatus
            AzureResourceName            = $azureResourceName
            AgentPresent                 = -not [string]::IsNullOrWhiteSpace(
                $agentPath
            )
            AgentPath                    = $agentPath
            AgentVersion                 = if (
                -not [string]::IsNullOrWhiteSpace($agentPath)
            ) {
                @(
                    & $agentPath --version 2>&1
                ) -join "`n"
            }
            else {
                $null
            }
            AgentShow                    = $agentShow
            HimdsPresent                 = ($null -ne $himdsService)
            HimdsStatus                  = if ($null -ne $himdsService) {
                [string]$himdsService.Status
            }
            else {
                $null
            }
            NativeBootstrapAvailability  = $nativeBootstrapAvailability
            NativeBootstrapStatus        = $nativeBootstrapSummary.Status
            NativeBootstrapError         = $nativeBootstrapSummary.ErrorMessage
            NativeBootstrapRebootPending = $nativeBootstrapSummary.RebootPending
            NativeBootstrapDetails       = $nativeBootstrapSummary.DetailedResponse
        }
    }

$inspection = @($inspectionResponse.Data) |
    Select-Object -First 1

$nativeBootstrapAvailability = Get-ArcValue `
    -Object $inspection `
    -Name 'NativeBootstrapAvailability'

$missingNativeCommands = @(
    'Start-ArcBootstrap'
    'Get-ArcBootstrapStatus'
) |
    Where-Object {
        -not [bool](
            Get-ArcValue `
                -Object $nativeBootstrapAvailability `
                -Name $_
        )
    }

if ($null -ne $missingNativeCommands) {
    return New-HcnEnsureResult `
        -Check 'Invoke-AzureLocalArcInitialization' `
        -Outcome 'Blocked' `
        -Summary (
            "Native Azure Local Arc bootstrap capability is incomplete on node " +
            "$nodeName. Missing command(s): $($missingNativeCommands -join ', ')."
        ) `
        -AdditionalProperties @{
            Node                   = $nodeName
            MissingNativeCommands  = $missingNativeCommands
            NativeBootstrapStatus  = $inspection.NativeBootstrapStatus
            NativeBootstrapDetails = $inspection.NativeBootstrapDetails
        }
}

if ($requireExistingClusterBlock -and $inspection.Clustered) {
    return New-HcnEnsureResult `
        -Check 'Invoke-AzureLocalArcInitialization' `
        -Outcome 'Blocked' `
        -Summary (
            "Node $nodeName is already clustered as $($inspection.ClusterName). " +
            'Arc initialization is blocked.'
        ) `
        -AdditionalProperties @{
            Node            = $nodeName
            ExistingCluster = $true
            ClusterName     = $inspection.ClusterName
        }
}

if (
    $requireExistingArcRegistrationBlock -and
    (
        $inspection.RegistrationStatus -eq 'Registered' -or
        -not [string]::IsNullOrWhiteSpace(
            [string]$inspection.AzureResourceName
        )
    )
) {
    return New-HcnEnsureResult `
        -Check 'Invoke-AzureLocalArcInitialization' `
        -Outcome 'Blocked' `
        -Summary (
            "Node $nodeName is already Azure registered. " +
            "Registration status: $($inspection.RegistrationStatus); " +
            "Azure resource: $($inspection.AzureResourceName)."
        ) `
        -AdditionalProperties @{
            Node               = $nodeName
            RegistrationStatus = $inspection.RegistrationStatus
            AzureResourceName  = $inspection.AzureResourceName
        }
}

if ($requireConnectedMachineAgent -and -not $inspection.AgentPresent) {
    return New-HcnEnsureResult `
        -Check 'Invoke-AzureLocalArcInitialization' `
        -Outcome 'Blocked' `
        -Summary (
            "Azure Connected Machine agent command $agentCommand was not found " +
            "on node $nodeName."
        ) `
        -AdditionalProperties @{
            Node         = $nodeName
            AgentCommand = $agentCommand
            AgentPresent = $false
        }
}

if (
    $requireConnectedMachineAgent -and
    (
        -not $inspection.HimdsPresent -or
        $inspection.HimdsStatus -ne 'Running'
    )
) {
    return New-HcnEnsureResult `
        -Check 'Invoke-AzureLocalArcInitialization' `
        -Outcome 'Blocked' `
        -Summary (
            "HIMDS service $himdsServiceName is not present or running on node " +
            "$nodeName."
        ) `
        -AdditionalProperties @{
            Node         = $nodeName
            AgentPresent = $inspection.AgentPresent
            AgentPath    = $inspection.AgentPath
            HimdsPresent = $inspection.HimdsPresent
            HimdsStatus  = $inspection.HimdsStatus
        }
}

if ($inspection.NativeBootstrapStatus -eq 'Failed') {
    return New-HcnEnsureResult `
        -Check 'Invoke-AzureLocalArcInitialization' `
        -Outcome 'Blocked' `
        -Summary (
            "Native Azure Local Arc bootstrap is in a Failed state on node " +
            "$nodeName. Review native bootstrap status and collect support logs " +
            'before attempting another registration.'
        ) `
        -AdditionalProperties @{
            Node                   = $nodeName
            NativeBootstrapStatus  = $inspection.NativeBootstrapStatus
            NativeBootstrapError   = $inspection.NativeBootstrapError
            NativeBootstrapDetails = $inspection.NativeBootstrapDetails
            SupportLogCommand      = 'Collect-ArcBootstrapSupportLogs'
        }
}

return New-HcnEnsureResult `
    -Check 'Invoke-AzureLocalArcInitialization' `
    -Outcome 'AlreadyCompliant' `
    -Summary (
        "Native Azure Local Arc bootstrap prerequisites are present for node " +
        "$nodeName. Native bootstrap state: $($inspection.NativeBootstrapStatus). " +
        'No registration, update, reboot, or extension deployment was performed.'
    ) `
    -AdditionalProperties @{
        Node                       = $nodeName
        AgentCommand               = $agentCommand
        AgentPresent               = $inspection.AgentPresent
        AgentPath                  = $inspection.AgentPath
        AgentVersion               = $inspection.AgentVersion
        AgentShow                  = $inspection.AgentShow
        HimdsPresent               = $inspection.HimdsPresent
        HimdsStatus                = $inspection.HimdsStatus
        RegistrationStatus         = $inspection.RegistrationStatus
        AzureResourceName          = $inspection.AzureResourceName
        NativeBootstrapStatus      = $inspection.NativeBootstrapStatus
        NativeBootstrapError       = $inspection.NativeBootstrapError
        NativeBootstrapDetails     = $inspection.NativeBootstrapDetails
        NativeBootstrapAvailability = $nativeBootstrapAvailability
    }
