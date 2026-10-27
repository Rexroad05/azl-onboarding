#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\preflight\ManagementPlane.Common.psm1" -Force

function Get-NodeHealthValue {
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

$azure = Get-NodeHealthValue `
    -Object $Context.Config `
    -Name 'azure'

$arcAgent = Get-NodeHealthValue `
    -Object $azure `
    -Name 'arc_agent'

$expectedAgentPath = [string](
    Get-NodeHealthValue `
        -Object $arcAgent `
        -Name 'agent_executable_path'
)

$himdsServiceName = [string](
    Get-NodeHealthValue `
        -Object $arcAgent `
        -Name 'himds_service_name'
)

if ([string]::IsNullOrWhiteSpace($himdsServiceName)) {
    $himdsServiceName = 'himds'
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-NodeHealth' `
    -ArgumentList @(
        $expectedAgentPath,
        $himdsServiceName
    ) `
    -ScriptBlock {
        param(
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
                -Name 'azcmagent.exe', 'azcmagent' `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($null -ne $agent) {
                return [string]$agent.Source
            }

            return $null
        }

        $computerSystem = Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop

        $agentPath = Resolve-AzureConnectedMachineAgentPath `
            -ExpectedPath $ExpectedAgentPath

        $himds = Get-Service `
            -Name $HimdsServiceName `
            -ErrorAction SilentlyContinue

        if ([string]::IsNullOrWhiteSpace($agentPath)) {
            throw 'Azure Connected Machine agent is not installed.'
        }

        if ($null -eq $himds) {
            throw 'Azure Arc HIMDS service is not installed.'
        }

        if ($himds.Status -ne 'Running') {
            throw (
                "Azure Arc HIMDS service is $($himds.Status); expected Running."
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Domain       = $computerSystem.Domain
            PartOfDomain = [bool]$computerSystem.PartOfDomain
            AgentPath    = $agentPath
            AgentVersion = @(
                & $agentPath --version 2>&1
            ) -join "`n"
            AgentShow    = @(
                & $agentPath show -j 2>&1
            ) -join "`n"
            HimdsStatus  = [string]$himds.Status
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-NodeHealth'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    ComputerName = $data.ComputerName
    Domain       = $data.Domain
    PartOfDomain = $data.PartOfDomain
    AgentPath    = $data.AgentPath
    AgentVersion = $data.AgentVersion
    HimdsStatus  = $data.HimdsStatus
    Summary      = (
        "Node $($data.ComputerName) health validated. Azure Connected Machine " +
        'agent and HIMDS are present and running.'
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}