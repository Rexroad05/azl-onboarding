Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ClusterDeploymentValue {
    [CmdletBinding()]
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

function New-ClusterDeploymentResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [bool]$Passed,

        [Parameter(Mandatory)]
        [string]$Summary,

        [hashtable]$AdditionalProperties = @{}
    )

    $result = [ordered]@{
        Passed      = $Passed
        Check       = $Check
        Summary     = $Summary
        ValidatedAt = [datetime]::UtcNow.ToString('o')
    }

    foreach ($key in $AdditionalProperties.Keys) {
        $result[$key] = $AdditionalProperties[$key]
    }

    return [pscustomobject]$result
}

function Get-ClusterDeploymentSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $clusterDeployment = Get-ClusterDeploymentValue `
        -Object $Config `
        -Name 'cluster_deployment'

    if ($null -eq $clusterDeployment) {
        throw 'cluster_deployment configuration is required.'
    }

    return $clusterDeployment
}

function Test-ClusterDeploymentReadinessMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ClusterDeployment
    )

    $mode = [string](
        Get-ClusterDeploymentValue `
            -Object $ClusterDeployment `
            -Name 'mode'
    )

    $allowClusterCreation = [bool](
        Get-ClusterDeploymentValue `
            -Object $ClusterDeployment `
            -Name 'allow_cluster_creation'
    )

    $allowResourceDeployment = [bool](
        Get-ClusterDeploymentValue `
            -Object $ClusterDeployment `
            -Name 'allow_resource_deployment'
    )

    $executionMethod = [string](
        Get-ClusterDeploymentValue `
            -Object $ClusterDeployment `
            -Name 'approved_execution_method'
    )

    if ($mode -ne 'ReadinessOnly') {
        throw (
            "Unsupported cluster_deployment.mode: $mode. " +
            'Only ReadinessOnly is approved.'
        )
    }

    if ($allowClusterCreation) {
        throw (
            'cluster_deployment.allow_cluster_creation must remain false ' +
            'during Package 5.'
        )
    }

    if ($allowResourceDeployment) {
        throw (
            'cluster_deployment.allow_resource_deployment must remain false ' +
            'during Package 5.'
        )
    }

    if ($executionMethod -ne 'NotApproved') {
        throw (
            "Unsupported cluster_deployment.approved_execution_method: " +
            "$executionMethod. Expected NotApproved."
        )
    }

    return [pscustomobject]@{
        Mode                    = $mode
        AllowClusterCreation    = $allowClusterCreation
        AllowResourceDeployment = $allowResourceDeployment
        ExecutionMethod         = $executionMethod
    }
}

function Test-ClusterDeploymentIPv4Address {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Address,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $parsedAddress = $null

    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsedAddress)) {
        throw "$Label is not a valid IP address: $Address"
    }

    if (
        $parsedAddress.AddressFamily -ne
        [System.Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw "$Label must be an IPv4 address: $Address"
    }

    return $parsedAddress
}

Export-ModuleMember -Function @(
    'Get-ClusterDeploymentSettings',
    'Get-ClusterDeploymentValue',
    'New-ClusterDeploymentResult',
    'Test-ClusterDeploymentIPv4Address',
    'Test-ClusterDeploymentReadinessMode'
)