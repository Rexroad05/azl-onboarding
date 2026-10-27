#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

function Get-LocalCredentialValue {
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
        Get-LocalCredentialValue `
            -Object $Context `
            -Name 'ReadOnlyValidation'
    )

    $validationProfile = [string](
        Get-LocalCredentialValue `
            -Object $Context `
            -Name 'ValidationProfile'
    )

    $allowAbsentInCompliance = [bool](
        Get-LocalCredentialValue `
            -Object $Lifecycle `
            -Name 'allow_absent_in_1_2c'
    )

    return (
        $isReadOnlyValidation -and
        $validationProfile -eq 'HcnComplianceValidation' -and
        $allowAbsentInCompliance
    )
}

$security = Get-LocalCredentialValue `
    -Object $Context.Config `
    -Name 'security'

$localAdministrator = Get-LocalCredentialValue `
    -Object $security `
    -Name 'local_administrator'

if ($null -eq $localAdministrator) {
    throw 'security.local_administrator configuration is required.'
}

$accountName = [string](
    Get-LocalCredentialValue `
        -Object $localAdministrator `
        -Name 'name'
)

$passwordEnvironmentVariable = [string](
    Get-LocalCredentialValue `
        -Object $localAdministrator `
        -Name 'password_env'
)

$lifecycle = Get-LocalCredentialValue `
    -Object $localAdministrator `
    -Name 'lifecycle'

$validateCredentials = [bool](
    Get-LocalCredentialValue `
        -Object $security `
        -Name 'validate_credentials'
)

if ([string]::IsNullOrWhiteSpace($accountName)) {
    throw 'security.local_administrator.name is required.'
}

if ($null -eq $lifecycle) {
    throw 'security.local_administrator.lifecycle configuration is required.'
}

$nodeName = [string](
    Get-LocalCredentialValue `
        -Object $Context.Node `
        -Name 'name'
)

$allowPostBootstrapAbsence = Test-PostBootstrapAccountAbsenceAllowed `
    -Context $Context `
    -Lifecycle $lifecycle

$accountResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-LocalAdministratorCredentialAccountState' `
    -ArgumentList @($accountName) `
    -ScriptBlock {
        param(
            [string]$AccountName
        )

        $account = Get-LocalUser `
            -Name $AccountName `
            -ErrorAction SilentlyContinue

        return [pscustomobject]@{
            AccountPresent = ($null -ne $account)
            AccountName    = $AccountName
            Enabled        = if ($null -ne $account) {
                [bool]$account.Enabled
            }
            else {
                $false
            }
        }
    }

$accountState = @($accountResponse.Data) |
    Select-Object -First 1

if (-not $accountState.AccountPresent) {
    if ($allowPostBootstrapAbsence) {
        return [pscustomobject]@{
            Passed         = $true
            Check          = 'Test-LocalAdministratorCredential'
            Outcome        = 'NotApplicable'
            Classification = 'ExpectedLifecycleState'
            Node           = $accountResponse.Node
            ManagementIp   = $accountResponse.ManagementIp
            Account        = $accountName
            Summary        = (
                "Credential validation for $accountName is not applicable on " +
                "node $nodeName because the bootstrap account is absent under " +
                'the approved post-bootstrap lifecycle policy.'
            )
            ValidatedAt    = [datetime]::UtcNow.ToString('o')
        }
    }

    throw (
        "Required local deployment account $accountName does not exist on " +
        "node $nodeName."
    )
}

if (-not $accountState.Enabled) {
    throw (
        "Local deployment account $accountName exists on node $nodeName " +
        'but is disabled.'
    )
}

if (-not $validateCredentials) {
    return [pscustomobject]@{
        Passed         = $true
        Check          = 'Test-LocalAdministratorCredential'
        Outcome        = 'Skipped'
        Classification = 'ConfigurationDeferred'
        Node           = $accountResponse.Node
        ManagementIp   = $accountResponse.ManagementIp
        Account        = $accountName
        Summary        = (
            "Credential validation for $accountName is deferred by " +
            'security.validate_credentials=false.'
        )
        ValidatedAt    = [datetime]::UtcNow.ToString('o')
    }
}

if ([string]::IsNullOrWhiteSpace($passwordEnvironmentVariable)) {
    throw (
        'security.local_administrator.password_env is required when ' +
        'security.validate_credentials=true.'
    )
}

$password = [Environment]::GetEnvironmentVariable(
    $passwordEnvironmentVariable
)

if ([string]::IsNullOrWhiteSpace($password)) {
    throw (
        "Required password environment variable is unavailable: " +
        "$passwordEnvironmentVariable"
    )
}

$credentialResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-LocalAdministratorCredential' `
    -ArgumentList @(
        $accountName,
        $password
    ) `
    -ScriptBlock {
        param(
            [string]$AccountName,
            [string]$Password
        )

        Add-Type `
            -AssemblyName System.DirectoryServices.AccountManagement `
            -ErrorAction Stop

        $machineContext = New-Object `
            System.DirectoryServices.AccountManagement.PrincipalContext(
                [System.DirectoryServices.AccountManagement.ContextType]::Machine
            )

        $validCredential = $machineContext.ValidateCredentials(
            $AccountName,
            $Password
        )

        return [pscustomobject]@{
            Account = $AccountName
            CredentialValid = [bool]$validCredential
        }
    }

$credentialState = @($credentialResponse.Data) |
    Select-Object -First 1

if (-not $credentialState.CredentialValid) {
    throw (
        "Credential validation failed for local deployment account $accountName " +
        "on node $nodeName."
    )
}

return [pscustomobject]@{
    Passed         = $true
    Check          = 'Test-LocalAdministratorCredential'
    Outcome        = 'AlreadyCompliant'
    Classification = 'Compliant'
    Node           = $credentialResponse.Node
    ManagementIp   = $credentialResponse.ManagementIp
    Account        = $accountName
    CredentialValid = $credentialState.CredentialValid
    Summary        = (
        "Credential validation succeeded for local deployment account $accountName."
    )
    ValidatedAt    = [datetime]::UtcNow.ToString('o')
}