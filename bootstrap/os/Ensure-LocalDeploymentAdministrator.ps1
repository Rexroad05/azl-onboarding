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

function Test-ApprovedOperation {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$ApprovalKey
    )

    $approvedOperations = Get-Value `
        -Object $Context `
        -Name 'State'

    $approvedOperations = Get-Value `
        -Object $approvedOperations `
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

function Get-ApprovalKey {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$NodeName
    )

    $phaseId = Get-Value `
        -Object $Context `
        -Name 'PhaseId'

    $stageId = Get-Value `
        -Object $Context `
        -Name 'StageId'

    $operationName = [string](
        Get-Value `
            -Object $Context `
            -Name 'Operation'
    )

    if ($null -eq $phaseId) {
        $phaseId = 1
    }

    if ($null -eq $stageId) {
        $stageId = 2
    }

    if ([string]::IsNullOrWhiteSpace($operationName)) {
        $operationName = 'Ensure-LocalDeploymentAdministrator'
    }

    return (
        "$phaseId." +
        "$stageId." +
        "$NodeName." +
        "$operationName"
    )
}

$config = Get-Value `
    -Object $Context `
    -Name 'Config'

$security = Get-Value `
    -Object $config `
    -Name 'security'

$localAdministrator = Get-Value `
    -Object $security `
    -Name 'local_administrator'

if ($null -eq $localAdministrator) {
    throw 'security.local_administrator configuration is required.'
}

$deploymentAccount = [string](
    Get-Value `
        -Object $localAdministrator `
        -Name 'name'
)

$passwordEnvironmentVariable = [string](
    Get-Value `
        -Object $localAdministrator `
        -Name 'password_env'
)

$lifecycle = Get-Value `
    -Object $localAdministrator `
    -Name 'lifecycle'

if ([string]::IsNullOrWhiteSpace($deploymentAccount)) {
    throw 'security.local_administrator.name is required.'
}

if ($null -eq $lifecycle) {
    throw 'security.local_administrator.lifecycle configuration is required.'
}

$createIfMissing = (
    (Get-Value `
        -Object $lifecycle `
        -Name 'create_if_missing_for_1_2b') -eq $true
)

$validatePassword = (
    (Get-Value `
        -Object $lifecycle `
        -Name 'validate_password_for_1_2b') -eq $true
)

$resetExistingPassword = (
    (Get-Value `
        -Object $lifecycle `
        -Name 'reset_existing_password') -eq $true
)

if ($resetExistingPassword) {
    throw (
        'reset_existing_password=true is not approved. Existing local ' +
        'deployment account passwords must not be reset automatically.'
    )
}

$node = Get-Value `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Ensure-LocalDeploymentAdministrator requires a node-scoped context.'
}

$nodeName = [string](
    Get-Value `
        -Object $node `
        -Name 'name'
)

$password = $null

if ($createIfMissing -or $validatePassword) {
    if ([string]::IsNullOrWhiteSpace($passwordEnvironmentVariable)) {
        throw (
            'security.local_administrator.password_env is required when ' +
            'bootstrap account creation or password validation is enabled.'
        )
    }

    $password = [Environment]::GetEnvironmentVariable(
        $passwordEnvironmentVariable
    )

    if ([string]::IsNullOrWhiteSpace($password)) {
        throw (
            "Required deployment password environment variable is unavailable: " +
            $passwordEnvironmentVariable
        )
    }
}

$approvalKey = Get-ApprovalKey `
    -Context $Context `
    -NodeName $nodeName

$inspectionResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Ensure-LocalDeploymentAdministrator' `
    -ArgumentList @($deploymentAccount) `
    -ScriptBlock {
        param(
            [string]$DeploymentAccount
        )

        $cluster = Get-Cluster -ErrorAction SilentlyContinue

        $account = Get-LocalUser `
            -Name $DeploymentAccount `
            -ErrorAction SilentlyContinue

        $administratorsGroup = Get-LocalGroup |
            Where-Object {
                $_.SID.Value -eq 'S-1-5-32-544'
            } |
            Select-Object -First 1

        if ($null -eq $administratorsGroup) {
            throw 'Unable to identify the local Administrators group.'
        }

        $isAdministrator = $false

        if ($null -ne $account) {
            $members = @(
                Get-LocalGroupMember `
                    -Group $administratorsGroup.Name `
                    -ErrorAction Stop
            )

            $isAdministrator = @(
                $members |
                    Where-Object {
                        $_.Name -match (
                            "(^|\\)$([regex]::Escape($DeploymentAccount))$"
                        )
                    }
            ).Count -gt 0
        }

        [pscustomobject]@{
            ExistingCluster    = ($null -ne $cluster)
            AccountPresent     = ($null -ne $account)
            AccountName        = $DeploymentAccount
            Enabled            = if ($null -ne $account) {
                [bool]$account.Enabled
            }
            else {
                $false
            }
            IsAdministrator    = $isAdministrator
            AdministratorsGroup = $administratorsGroup.Name
        }
    }

$inspection = @($inspectionResponse.Data) |
    Select-Object -First 1

if ($inspection.ExistingCluster) {
    return New-HcnEnsureResult `
        -Check 'Ensure-LocalDeploymentAdministrator' `
        -Outcome 'Blocked' `
        -Summary (
            "Node $nodeName is already clustered. Local deployment account " +
            'changes are blocked.'
        ) `
        -AdditionalProperties @{
            Node            = $nodeName
            ExistingCluster = $true
            Account         = $deploymentAccount
        }
}

if (
    -not $inspection.AccountPresent -and
    -not $createIfMissing
) {
    throw (
        "Required local deployment account $deploymentAccount does not exist " +
        "on node $nodeName and creation is not authorized by protected policy."
    )
}

if (
    -not $inspection.AccountPresent -and
    -not (Test-ApprovedOperation -Context $Context -ApprovalKey $approvalKey)
) {
    return New-HcnEnsureResult `
        -Check 'Ensure-LocalDeploymentAdministrator' `
        -Outcome 'Blocked' `
        -Summary (
            "Local deployment account $deploymentAccount is missing on node " +
            "$nodeName. Explicit approval is required before creation."
        ) `
        -AdditionalProperties @{
            RequiresApproval = $true
            ApprovalReason   = (
                "Creating local deployment account $deploymentAccount and adding " +
                'it to the local Administrators group is a security-sensitive ' +
                'change. Approval is required before creation.'
            )
            RequiresReboot   = $false
            ReconnectTarget  = $nodeName
            Node             = $nodeName
            Account          = $deploymentAccount
            CreateIfMissing  = $createIfMissing
        }
}

$changeResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Ensure-LocalDeploymentAdministrator' `
    -ArgumentList @(
        $deploymentAccount,
        $password,
        [bool]$createIfMissing,
        [bool]$validatePassword
    ) `
    -ScriptBlock {
        param(
            [string]$DeploymentAccount,
            [string]$Password,
            [bool]$CreateIfMissing,
            [bool]$ValidatePassword
        )

        $account = Get-LocalUser `
            -Name $DeploymentAccount `
            -ErrorAction SilentlyContinue

        $created = $false
        $enabledChanged = $false
        $membershipChanged = $false

        if ($null -eq $account) {
            if (-not $CreateIfMissing) {
                throw (
                    "Local deployment account $DeploymentAccount does not exist " +
                    'and creation is not authorized.'
                )
            }

            if ([string]::IsNullOrWhiteSpace($Password)) {
                throw (
                    "A deployment password is required to create local account " +
                    "$DeploymentAccount."
                )
            }

            $securePassword = ConvertTo-SecureString `
                -String $Password `
                -AsPlainText `
                -Force

            $account = New-LocalUser `
                -Name $DeploymentAccount `
                -Password $securePassword `
                -FullName $DeploymentAccount `
                -Description 'Azure Local factory deployment administrator.' `
                -ErrorAction Stop

            $created = $true
        }

        if (-not $account.Enabled) {
            Enable-LocalUser `
                -Name $DeploymentAccount `
                -ErrorAction Stop

            $enabledChanged = $true
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
                        "(^|\\)$([regex]::Escape($DeploymentAccount))$"
                    )
                }
        ).Count -gt 0

        if (-not $isAdministrator) {
            Add-LocalGroupMember `
                -Group $administratorsGroup.Name `
                -Member $DeploymentAccount `
                -ErrorAction Stop

            $membershipChanged = $true
        }

        $credentialValid = $null

        if ($ValidatePassword) {
            if ([string]::IsNullOrWhiteSpace($Password)) {
                throw (
                    "A deployment password is required to validate local account " +
                    "$DeploymentAccount."
                )
            }

            Add-Type `
                -AssemblyName System.DirectoryServices.AccountManagement `
                -ErrorAction Stop

            $machineContext = New-Object `
                System.DirectoryServices.AccountManagement.PrincipalContext(
                    [System.DirectoryServices.AccountManagement.ContextType]::Machine
                )

            $credentialValid = $machineContext.ValidateCredentials(
                $DeploymentAccount,
                $Password
            )

            if (-not $credentialValid) {
                throw (
                    "Credential validation failed for existing local deployment " +
                    "account $DeploymentAccount. The account password was not reset."
                )
            }
        }

        $finalAccount = Get-LocalUser `
            -Name $DeploymentAccount `
            -ErrorAction Stop

        [pscustomobject]@{
            ComputerName      = $env:COMPUTERNAME
            Account           = $DeploymentAccount
            Created           = $created
            EnabledChanged    = $enabledChanged
            MembershipChanged  = $membershipChanged
            Enabled           = [bool]$finalAccount.Enabled
            IsAdministrator   = $true
            CredentialValid   = $credentialValid
        }
    }

$changeResult = @($changeResponse.Data) |
    Select-Object -First 1

$changed = (
    $changeResult.Created -or
    $changeResult.EnabledChanged -or
    $changeResult.MembershipChanged
)

if ($changed) {
    return New-HcnEnsureResult `
        -Check 'Ensure-LocalDeploymentAdministrator' `
        -Outcome 'Changed' `
        -Changed $true `
        -Summary (
            "Local deployment account $($changeResult.Account) was remediated. " +
            "Created=$($changeResult.Created); " +
            "EnabledChanged=$($changeResult.EnabledChanged); " +
            "MembershipChanged=$($changeResult.MembershipChanged); " +
            "CredentialValidated=$($changeResult.CredentialValid)."
        ) `
        -AdditionalProperties @{
            Node            = $inspectionResponse.Node
            ManagementIp    = $changeResponse.ManagementIp
            Account         = $changeResult.Account
            Created         = $changeResult.Created
            EnabledChanged  = $changeResult.EnabledChanged
            MembershipChanged = $changeResult.MembershipChanged
            CredentialValid = $changeResult.CredentialValid
        }
}

return New-HcnEnsureResult `
    -Check 'Ensure-LocalDeploymentAdministrator' `
    -Outcome 'AlreadyCompliant' `
    -Summary (
        "Local deployment account $($changeResult.Account) is enabled, is a " +
        "local administrator, and CredentialValidated=$($changeResult.CredentialValid)."
    ) `
    -AdditionalProperties @{
        Node            = $changeResponse.Node
        ManagementIp    = $changeResponse.ManagementIp
        Account         = $changeResult.Account
        CredentialValid = $changeResult.CredentialValid
    }