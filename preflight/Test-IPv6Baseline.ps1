#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

function Get-IPv6Value {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-ManagementPlaneValue `
        -Object $Object `
        -Name $Name
}

function Get-RequiredDeploymentAdapters {
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$AdapterScope
    )

    if ($AdapterScope -ne 'RequiredDeploymentAdapters') {
        throw (
            "Unsupported IPv6 adapter_scope: $AdapterScope. " +
            'Only RequiredDeploymentAdapters is approved.'
        )
    }

    $network = Get-IPv6Value `
        -Object $Config `
        -Name 'network'

    $adapterState = Get-IPv6Value `
        -Object $network `
        -Name 'adapter_state'

    $requiredEnabled = @(
        Get-IPv6Value `
            -Object $adapterState `
            -Name 'required_enabled'
    )

    if ($requiredEnabled.Count -lt 1) {
        throw (
            'network.adapter_state.required_enabled must contain at least ' +
            'one adapter when IPv6 binding validation is enabled.'
        )
    }

    return @(
        $requiredEnabled |
            ForEach-Object {
                [string]$_
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            } |
            Select-Object -Unique
    )
}

$ipv6Configuration = Get-IPv6Value `
    -Object $Context.Config.security `
    -Name 'ipv6'

$disableIpv6 = [bool](
    Get-IPv6Value `
        -Object $ipv6Configuration `
        -Name 'disable'
)

$expectedDisabledComponents = Get-IPv6Value `
    -Object $ipv6Configuration `
    -Name 'disabled_components'

$disableBindings = [bool](
    Get-IPv6Value `
        -Object $ipv6Configuration `
        -Name 'disable_bindings'
)

$bindingComponentId = [string](
    Get-IPv6Value `
        -Object $ipv6Configuration `
        -Name 'binding_component_id'
)

$adapterScope = [string](
    Get-IPv6Value `
        -Object $ipv6Configuration `
        -Name 'adapter_scope'
)

if (-not $disableIpv6) {
    return [pscustomobject]@{
        Passed       = $true
        Check        = 'Test-IPv6Baseline'
        Node         = $Context.Node.name
        ManagementIp = $Context.Node.management.ip
        Summary      = 'IPv6 disablement is not required by the protected baseline.'
        ValidatedAt  = [datetime]::UtcNow.ToString('o')
    }
}

if ($null -eq $expectedDisabledComponents) {
    $expectedDisabledComponents = 255
}

$expectedDisabledComponents = [int]$expectedDisabledComponents

$requiredAdapters = @()

if ($disableBindings) {
    if ([string]::IsNullOrWhiteSpace($bindingComponentId)) {
        throw (
            'security.ipv6.binding_component_id is required when ' +
            'security.ipv6.disable_bindings is true.'
        )
    }

    if ([string]::IsNullOrWhiteSpace($adapterScope)) {
        throw (
            'security.ipv6.adapter_scope is required when ' +
            'security.ipv6.disable_bindings is true.'
        )
    }

    $requiredAdapters = Get-RequiredDeploymentAdapters `
        -Config $Context.Config `
        -AdapterScope $adapterScope
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-IPv6Baseline' `
    -ArgumentList @(
        $expectedDisabledComponents,
        $disableBindings,
        $bindingComponentId,
        $requiredAdapters
    ) `
    -ScriptBlock {
        param(
            [int]$ExpectedDisabledComponents,
            [bool]$DisableBindings,
            [string]$BindingComponentId,
            [string[]]$RequiredAdapters
        )

        $ipv6State = Get-ItemProperty `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
            -Name DisabledComponents `
            -ErrorAction SilentlyContinue

        if ($null -eq $ipv6State) {
            throw (
                'IPv6 DisabledComponents registry value does not exist. ' +
                'IPv6 may be fully enabled.'
            )
        }

        if ([int]$ipv6State.DisabledComponents -ne $ExpectedDisabledComponents) {
            throw (
                "IPv6 DisabledComponents is $($ipv6State.DisabledComponents); " +
                "expected $ExpectedDisabledComponents."
            )
        }

        $bindingStates = @()

        if ($DisableBindings) {
            foreach ($adapterName in $RequiredAdapters) {
                $binding = Get-NetAdapterBinding `
                    -Name $adapterName `
                    -ComponentID $BindingComponentId `
                    -ErrorAction Stop

                $bindingStates += [pscustomobject]@{
                    AdapterName = $adapterName
                    ComponentId = $BindingComponentId
                    Enabled     = [bool]$binding.Enabled
                }
            }

            $enabledBindings = @(
                $bindingStates |
                    Where-Object {
                        $_.Enabled -eq $true
                    }
            )

            if ($enabledBindings.Count -gt 0) {
                throw (
                    "IPv6 binding $BindingComponentId remains enabled on: " +
                    ($enabledBindings.AdapterName -join ', ')
                )
            }
        }

        [pscustomobject]@{
            ComputerName       = $env:COMPUTERNAME
            DisabledComponents = [int]$ipv6State.DisabledComponents
            BindingComponentId = $BindingComponentId
            BindingStates      = $bindingStates
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

return [pscustomobject]@{
    Passed               = $true
    Check                = 'Test-IPv6Baseline'
    Node                 = $result.Node
    ManagementIp         = $result.ManagementIp
    DisabledComponents   = $data.DisabledComponents
    BindingComponentId   = $data.BindingComponentId
    ValidatedAdapters    = @(
        $data.BindingStates |
            Select-Object -ExpandProperty AdapterName
    )
    DisabledBindingAdapters = @(
        $data.BindingStates |
            Where-Object {
                $_.Enabled -eq $false
            } |
            Select-Object -ExpandProperty AdapterName
    )
    Summary              = (
        "IPv6 DisabledComponents equals $($data.DisabledComponents); " +
        "binding $($data.BindingComponentId) is disabled on " +
        "$(@($data.BindingStates).Count) required adapter(s)."
    )
    ValidatedAt          = [datetime]::UtcNow.ToString('o')
}