#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\HcnEnsure.Common.psm1" -Force

function Get-Value {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-HcnEnsureValue `
        -Object $Object `
        -Name $Name
}

function Test-ApprovedOperation {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$ApprovalKey
    )

    $approvedOperations = Get-Value `
        -Object $Context.State `
        -Name 'approvedOperations'

    if ($null -eq $approvedOperations) {
        return $false
    }

    if ($approvedOperations -is [System.Collections.IDictionary]) {
        return $approvedOperations.Contains($ApprovalKey)
    }

    return (
        $null -ne $approvedOperations.PSObject.Properties[$ApprovalKey]
    )
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

    $network = Get-Value `
        -Object $Config `
        -Name 'network'

    $adapterState = Get-Value `
        -Object $network `
        -Name 'adapter_state'

    $requiredEnabled = @(
        Get-Value `
            -Object $adapterState `
            -Name 'required_enabled'
    )

    if ($requiredEnabled.Count -lt 1) {
        throw (
            'network.adapter_state.required_enabled must contain at least ' +
            'one adapter when IPv6 binding disablement is enabled.'
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

$node = Get-Value `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Ensure-IPv6Baseline requires a node-scoped execution context.'
}

$config = Get-Value `
    -Object $Context `
    -Name 'Config'

$security = Get-Value `
    -Object $config `
    -Name 'security'

$ipv6 = Get-Value `
    -Object $security `
    -Name 'ipv6'

$nodeName = [string](
    Get-Value `
        -Object $node `
        -Name 'name'
)

$disableIpv6 = [bool](
    Get-Value `
        -Object $ipv6 `
        -Name 'disable'
)

$disabledComponents = [int](
    Get-Value `
        -Object $ipv6 `
        -Name 'disabled_components'
)

$disableBindings = [bool](
    Get-Value `
        -Object $ipv6 `
        -Name 'disable_bindings'
)

$bindingComponentId = [string](
    Get-Value `
        -Object $ipv6 `
        -Name 'binding_component_id'
)

$adapterScope = [string](
    Get-Value `
        -Object $ipv6 `
        -Name 'adapter_scope'
)

if (-not $disableIpv6) {
    return New-HcnEnsureResult `
        -Check 'Ensure-IPv6Baseline' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            "IPv6 disablement is not required by the resolved " +
            "configuration for node $nodeName."
        ) `
        -AdditionalProperties @{
            Node = $nodeName
        }
}

if ($disabledComponents -lt 0 -or $disabledComponents -gt 255) {
    throw (
        "security.ipv6.disabled_components value $disabledComponents is invalid. " +
        'Expected a DWORD value between 0 and 255.'
    )
}

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
        -Config $config `
        -AdapterScope $adapterScope
}

$approvalKey = (
    "$($Context.PhaseId)." +
    "$($Context.StageId)." +
    "$nodeName." +
    "$($Context.Operation)"
)

$inspectionResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param(
            [string]$BindingComponentId,
            [bool]$DisableBindings,
            [string[]]$RequiredAdapters
        )

        $cluster = Get-Cluster -ErrorAction SilentlyContinue

        $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'

        $ipv6RegistryState = Get-ItemProperty `
            -Path $registryPath `
            -Name 'DisabledComponents' `
            -ErrorAction SilentlyContinue

        $bindingStates = @()

        if ($DisableBindings) {
            foreach ($adapterName in $RequiredAdapters) {
                $adapter = Get-NetAdapter `
                    -Name $adapterName `
                    -ErrorAction Stop

                $binding = Get-NetAdapterBinding `
                    -Name $adapter.Name `
                    -ComponentID $BindingComponentId `
                    -ErrorAction Stop

                $bindingStates += [pscustomobject]@{
                    AdapterName = $adapter.Name
                    ComponentId = $BindingComponentId
                    Enabled     = [bool]$binding.Enabled
                }
            }
        }

        [pscustomobject]@{
            ExistingCluster    = ($null -ne $cluster)
            DisabledComponents = if ($null -ne $ipv6RegistryState) {
                [int]$ipv6RegistryState.DisabledComponents
            }
            else {
                $null
            }
            BindingStates      = $bindingStates
        }
    } `
    -ArgumentList @(
        $bindingComponentId,
        $disableBindings,
        $requiredAdapters
    )

$inspection = @($inspectionResponse.Data) |
    Select-Object -First 1

if ($inspection.ExistingCluster) {
    return New-HcnEnsureResult `
        -Check 'Ensure-IPv6Baseline' `
        -Outcome 'Blocked' `
        -Summary (
            "Node $nodeName is already clustered. IPv6 baseline " +
            'changes are blocked.'
        ) `
        -AdditionalProperties @{
            Node            = $nodeName
            ExistingCluster = $true
        }
}

$registryCompliant = (
    $inspection.DisabledComponents -eq $disabledComponents
)

$enabledBindings = @()

if ($disableBindings) {
    $enabledBindings = @(
        $inspection.BindingStates |
            Where-Object {
                $_.Enabled -eq $true
            }
    )
}

$bindingCompliant = (
    -not $disableBindings -or
    $enabledBindings.Count -eq 0
)

if ($registryCompliant -and $bindingCompliant) {
    return New-HcnEnsureResult `
        -Check 'Ensure-IPv6Baseline' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            "IPv6 DisabledComponents equals $disabledComponents and " +
            "binding $bindingComponentId is disabled on all required " +
            "deployment adapters for node $nodeName."
        ) `
        -AdditionalProperties @{
            Node               = $nodeName
            DisabledComponents = $disabledComponents
            BindingComponentId = $bindingComponentId
            BindingStates      = $inspection.BindingStates
        }
}

if (-not (Test-ApprovedOperation -Context $Context -ApprovalKey $approvalKey)) {
    $bindingDriftSummary = if ($enabledBindings.Count -gt 0) {
        (
            ' Enabled IPv6 binding adapters: ' +
            ($enabledBindings.AdapterName -join ', ') + '.'
        )
    }
    else {
        ''
    }

    return New-HcnEnsureResult `
        -Check 'Ensure-IPv6Baseline' `
        -Outcome 'Blocked' `
        -Summary (
            "IPv6 baseline correction is required on node $nodeName. " +
            "DisabledComponents target is $disabledComponents." +
            $bindingDriftSummary
        ) `
        -AdditionalProperties @{
            RequiresApproval = $true
            ApprovalReason   = (
                'Changing IPv6 registry and adapter binding state can affect ' +
                'network connectivity and requires a controlled reboot.'
            )
            RequiresReboot   = $true
            ReconnectTarget  = $nodeName
            Node             = $nodeName
            BindingComponentId = $bindingComponentId
            EnabledBindings  = $enabledBindings
        }
}

$changeResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName ([string]$Context.Operation) `
    -ScriptBlock {
        param(
            [int]$DisabledComponents,
            [string]$BindingComponentId,
            [bool]$DisableBindings,
            [string[]]$RequiredAdapters
        )

        Set-ItemProperty `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
            -Name 'DisabledComponents' `
            -Type DWord `
            -Value $DisabledComponents `
            -Force `
            -ErrorAction Stop

        $disabledBindings = @()

        if ($DisableBindings) {
            foreach ($adapterName in $RequiredAdapters) {
                $binding = Get-NetAdapterBinding `
                    -Name $adapterName `
                    -ComponentID $BindingComponentId `
                    -ErrorAction Stop

                if ($binding.Enabled) {
                    Disable-NetAdapterBinding `
                        -Name $adapterName `
                        -ComponentID $BindingComponentId `
                        -Confirm:$false `
                        -ErrorAction Stop

                    $disabledBindings += $adapterName
                }
            }
        }

        [pscustomobject]@{
            DisabledComponents = $DisabledComponents
            BindingComponentId = $BindingComponentId
            DisabledBindings   = $disabledBindings
        }
    } `
    -ArgumentList @(
        $disabledComponents,
        $bindingComponentId,
        $disableBindings,
        $requiredAdapters
    )

$changeResult = @($changeResponse.Data) |
    Select-Object -First 1

return New-HcnEnsureResult `
    -Check 'Ensure-IPv6Baseline' `
    -Outcome 'Changed' `
    -Changed $true `
    -Summary (
        "Set IPv6 DisabledComponents to $disabledComponents and ensured " +
        "binding $bindingComponentId is disabled on required deployment " +
        "adapters for node $nodeName. Reboot approval and reconnect are required."
    ) `
    -AdditionalProperties @{
        Node               = $nodeName
        DisabledComponents = $changeResult.DisabledComponents
        BindingComponentId = $changeResult.BindingComponentId
        DisabledBindings   = $changeResult.DisabledBindings
        RequiresReboot     = $true
        ReconnectTarget    = $nodeName
        PauseRequested     = $true
        PauseType          = 'Reboot'
        RebootReason       = (
            'IPv6 DisabledComponents and/or adapter binding state changed. ' +
            'A reboot and post-reboot validation are required.'
        )
    }