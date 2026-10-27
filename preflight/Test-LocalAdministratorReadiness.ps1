#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

function Get-LocalAdminValue {
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

function Test-PostBootstrapAccountAbsenceAllowed {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [object]$Lifecycle
    )

    $isReadOnlyValidation = [bool](
        Get-LocalAdminValue `
            -Object $Context `
            -Name 'ReadOnlyValidation'
    )

    $validationProfile = [string](
        Get-LocalAdminValue `
            -Object $Context `
            -Name 'ValidationProfile'
    )

    $allowAbsentInCompliance = [bool](
        Get-LocalAdminValue `
            -Object $Lifecycle `
            -Name 'allow_absent_in_1_2c'
    )

    return (
        $isReadOnlyValidation -and
        $validationProfile -eq 'HcnComplianceValidation' -and
        $allowAbsentInCompliance
    )
}

$security = Get-LocalAdminValue `
    -Object $Context.Config `
    -Name 'security'

$localAdministrator = Get-LocalAdminValue `
    -Object $security `
    -Name 'local_administrator'

if ($null -eq $localAdministrator) {
    throw 'security.local_administrator configuration is required.'
}

$accountName = [string](
    Get-LocalAdminValue `
        -Object $localAdministrator `
        -Name 'name'
)

$lifecycle = Get-LocalAdminValue `
    -Object $localAdministrator `
    -Name 'lifecycle'

if ([string]::IsNullOrWhiteSpace($accountName)) {
    throw 'security.local_administrator.name is required.'
}

if ($null -eq $lifecycle) {
    throw 'security.local_administrator.lifecycle configuration is required.'
}

$nodeName = [string](
    Get-LocalAdminValue `
        -Object $Context.Node `
        -Name 'name'
)

$allowPostBootstrapAbsence = Test-PostBootstrapAccountAbsenceAllowed `
    -Context $Context `
    -Lifecycle $lifecycle

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-LocalAdministratorReadiness' `
    -ArgumentList @($accountName) `
    -ScriptBlock {
        param(
            [string]$AccountName
        )

        $account = Get-LocalUser `
            -Name $AccountName `
            -ErrorAction SilentlyContinue

        if ($null -eq $account) {
            return [pscustomobject]@{
                AccountPresent = $false
                AccountName    = $AccountName
                Enabled        = $false
                IsAdministrator = $false
            }
        }

        $administratorsGroup = Get-LocalGroup |
            Where-Object {
                $_.SID.Value -eq 'S-1-5-32-544'
            } |
            Select-Object -First 1

        if ($null -eq $administratorsGroup) {
            throw 'Unable to identify the local Administrators group.'
        }

        $members = @(
            Get-LocalGroupMember `
                -Group $administratorsGroup.Name `
                -ErrorAction Stop
        )

        $isAdministrator = @(
            $members |
                Where-Object {
                    $_.Name -match (
                        "(^|\\)$([regex]::Escape($AccountName))$"
                    )
                }
        ).Count -gt 0

        return [pscustomobject]@{
            AccountPresent  = $true
            AccountName     = $AccountName
            Enabled         = [bool]$account.Enabled
            IsAdministrator = $isAdministrator
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

if (-not $data.AccountPresent) {
    if ($allowPostBootstrapAbsence) {
        return [pscustomobject]@{
            Passed         = $true
            Check          = 'Test-LocalAdministratorReadiness'
            Outcome        = 'NotApplicable'
            Classification = 'ExpectedLifecycleState'
            Node           = $result.Node
            ManagementIp   = $result.ManagementIp
            Account        = $accountName
            Summary        = (
                "Local deployment account $accountName is absent on node $nodeName. " +
                'This is allowed by the protected post-bootstrap lifecycle policy.'
            )
            ValidatedAt    = [datetime]::UtcNow.ToString('o')
        }
    }

    throw (
        "Required local deployment account $accountName does not exist on " +
        "node $nodeName."
    )
}

if (-not $data.Enabled) {
    throw (
        "Local deployment account $accountName exists on node $nodeName " +
        'but is disabled.'
    )
}

if (-not $data.IsAdministrator) {
    throw (
        "Local deployment account $accountName exists on node $nodeName " +
        'but is not a member of the local Administrators group.'
    )
}

return [pscustomobject]@{
    Passed         = $true
    Check          = 'Test-LocalAdministratorReadiness'
    Outcome        = 'AlreadyCompliant'
    Classification = 'Compliant'
    Node           = $result.Node
    ManagementIp   = $result.ManagementIp
    Account        = $accountName
    Enabled        = $data.Enabled
    IsAdministrator = $data.IsAdministrator
    Summary        = (
        "Local deployment account $accountName is enabled and is a local administrator."
    )
    ValidatedAt    = [datetime]::UtcNow.ToString('o')
}