#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigValue {
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
        if (@($Object.Keys) -contains $Name) {
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

function Test-EnvironmentVariableName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return ($Name -match '^[A-Za-z_][A-Za-z0-9_]*$')
}

$config = $Context.Config

if ($null -eq $config) {
    throw 'Factory context does not contain Config.'
}

$throughStage = if ($Context.ContainsKey('ThroughStage')) {
    [int]$Context.ThroughStage
}
else {
    1
}

$mode = [string]$Context.Mode

$activeDirectory = Get-ConfigValue `
    -Object $config `
    -Name 'active_directory'

$identityMode = [string](
    Get-ConfigValue `
        -Object $activeDirectory `
        -Name 'identity_mode'
)

$remoteManagement = Get-ConfigValue `
    -Object $config `
    -Name 'remote_management'

$requiredVariableNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$errors = [System.Collections.Generic.List[string]]::new()

if ($mode -ne 'Plan' -and $throughStage -ge 2) {
    if ($identityMode -eq 'LocalIdentityWithKeyVault') {
        $localUsernameVariable = [string](
            Get-ConfigValue `
                -Object $remoteManagement `
                -Name 'local_credential_username_env'
        )

        $localPasswordVariable = [string](
            Get-ConfigValue `
                -Object $remoteManagement `
                -Name 'local_credential_password_env'
        )

        foreach ($variableName in @(
                $localUsernameVariable,
                $localPasswordVariable
            )) {
            if ([string]::IsNullOrWhiteSpace($variableName)) {
                [void]$errors.Add(
                    'Local bootstrap credential environment-variable configuration is incomplete.'
                )
                continue
            }

            if (-not (Test-EnvironmentVariableName -Name $variableName)) {
                [void]$errors.Add(
                    "Invalid local credential environment variable name: $variableName"
                )
                continue
            }

            [void]$requiredVariableNames.Add($variableName)
        }

        $azure = Get-ConfigValue -Object $config -Name 'azure'
        $keyVault = Get-ConfigValue -Object $azure -Name 'key_vault'

        foreach ($propertyName in @(
                'name',
                'resource_group',
                'resource_id'
            )) {
            $value = [string](
                Get-ConfigValue `
                    -Object $keyVault `
                    -Name $propertyName
            )

            if ([string]::IsNullOrWhiteSpace($value)) {
                [void]$errors.Add(
                    "azure.key_vault.$propertyName is required for Local Identity."
                )
            }
        }
    }
    else {
        $addsUsernameVariable = [string](
            Get-ConfigValue `
                -Object $remoteManagement `
                -Name 'credential_username_env'
        )

        $addsPasswordVariable = [string](
            Get-ConfigValue `
                -Object $remoteManagement `
                -Name 'credential_password_env'
        )

        foreach ($variableName in @(
                $addsUsernameVariable,
                $addsPasswordVariable
            )) {
            if ([string]::IsNullOrWhiteSpace($variableName)) {
                [void]$errors.Add(
                    'AD DS credential environment-variable configuration is incomplete.'
                )
                continue
            }

            if (-not (Test-EnvironmentVariableName -Name $variableName)) {
                [void]$errors.Add(
                    "Invalid AD DS credential environment variable name: $variableName"
                )
                continue
            }

            [void]$requiredVariableNames.Add($variableName)
        }
    }
}

if ($mode -eq 'Apply' -and $throughStage -ge 2) {
    $security = Get-ConfigValue -Object $config -Name 'security'

    $localAdministrator = Get-ConfigValue `
        -Object $security `
        -Name 'local_administrator'

    $deploymentPasswordVariable = [string](
        Get-ConfigValue `
            -Object $localAdministrator `
            -Name 'password_env'
    )

    if ([string]::IsNullOrWhiteSpace($deploymentPasswordVariable)) {
        [void]$errors.Add(
            'security.local_administrator.password_env is required for Apply mode.'
        )
    }
    elseif (-not (
        Test-EnvironmentVariableName -Name $deploymentPasswordVariable
    )) {
        [void]$errors.Add(
            "Invalid deployment-password environment variable name: " +
            $deploymentPasswordVariable
        )
    }
    else {
        [void]$requiredVariableNames.Add(
            $deploymentPasswordVariable
        )
    }
}

foreach ($variableName in $requiredVariableNames) {
    $value = [Environment]::GetEnvironmentVariable($variableName)

    if ([string]::IsNullOrWhiteSpace($value)) {
        [void]$errors.Add(
            "Required environment variable is missing or empty: $variableName"
        )
    }
}

if ($errors.Count -gt 0) {
    throw (
        "Required secret validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

return [pscustomobject]@{
    Passed              = $true
    Check               = 'Test-RequiredSecrets'
    IdentityMode        = $identityMode
    RequiredSecretCount = $requiredVariableNames.Count
    ValidatedVariables  = @($requiredVariableNames | Sort-Object)
    ThroughStage        = $throughStage
    Mode                = $mode
    Summary             = (
        "Runtime credential variable configuration validated for identity mode $identityMode."
    )
    ValidatedAt         = [datetime]::UtcNow.ToString('o')
}