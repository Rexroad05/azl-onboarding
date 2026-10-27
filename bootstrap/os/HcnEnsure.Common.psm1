Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\..\preflight\ManagementPlane.Common.psm1" -Force

function New-HcnEnsureResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [ValidateSet('AlreadyCompliant', 'Changed', 'Blocked')]
        [string]$Outcome,

        [Parameter(Mandatory)]
        [string]$Summary,

        [bool]$Changed = $false,

        [hashtable]$AdditionalProperties = @{}
    )

    $result = [ordered]@{
        Passed       = ($Outcome -ne 'Blocked')
        Check        = $Check
        Outcome      = $Outcome
        Changed      = $Changed
        Summary      = $Summary
        ValidatedAt  = [datetime]::UtcNow.ToString('o')
    }

    foreach ($key in $AdditionalProperties.Keys) {
        $result[$key] = $AdditionalProperties[$key]
    }

    return [pscustomobject]$result
}

function Get-HcnEnsureValue {
    [CmdletBinding()]
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

Export-ModuleMember -Function @(
    'Get-HcnEnsureValue',
    'Invoke-ManagementPlaneCommand',
    'New-HcnEnsureResult'
)