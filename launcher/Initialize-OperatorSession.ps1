#Requires -Version 7.4
[CmdletBinding()]
param(
    [switch]$RequireAddsCredentials,

    [switch]$RequireLocalAdministratorCredentials,

    [switch]$RequireDeploymentPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$createdEnvironmentVariables = [System.Collections.Generic.List[string]]::new()

function Set-ProcessEnvironmentVariable {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    [Environment]::SetEnvironmentVariable(
        $Name,
        $Value,
        'Process'
    )

    [void]$createdEnvironmentVariables.Add($Name)
}

function ConvertTo-PlainTextPassword {
    param(
        [Parameter(Mandatory)]
        [securestring]$Password
    )

    return (
        [System.Net.NetworkCredential]::new(
            '',
            $Password
        )
    ).Password
}

function Request-AddsCredential {
    $existingUser = [Environment]::GetEnvironmentVariable(
        'FACTORY_ADDS_ADMIN_USER'
    )

    $existingPassword = [Environment]::GetEnvironmentVariable(
        'FACTORY_ADDS_ADMIN_PASSWORD'
    )

    if (
        -not [string]::IsNullOrWhiteSpace($existingUser) -and
        -not [string]::IsNullOrWhiteSpace($existingPassword)
    ) {
        return
    }

    $credential = Get-Credential `
        -Message 'Enter approved ADDS credentials for Azure Local WinRM access.'

    if ($null -eq $credential) {
        throw 'ADDS credential prompt was canceled.'
    }

    if ([string]::IsNullOrWhiteSpace($credential.UserName)) {
        throw 'ADDS credential username is required.'
    }

    $plainTextPassword = ConvertTo-PlainTextPassword `
        -Password $credential.Password

    if ([string]::IsNullOrWhiteSpace($plainTextPassword)) {
        throw 'ADDS credential password is required.'
    }

    Set-ProcessEnvironmentVariable `
        -Name 'FACTORY_ADDS_ADMIN_USER' `
        -Value $credential.UserName

    Set-ProcessEnvironmentVariable `
        -Name 'FACTORY_ADDS_ADMIN_PASSWORD' `
        -Value $plainTextPassword
}

function Request-LocalAdministratorCredential {
    $existingUser = [Environment]::GetEnvironmentVariable(
        'FACTORY_LOCAL_ADMIN_USER'
    )

    $existingPassword = [Environment]::GetEnvironmentVariable(
        'FACTORY_LOCAL_ADMIN_PASSWORD'
    )

    if (
        -not [string]::IsNullOrWhiteSpace($existingUser) -and
        -not [string]::IsNullOrWhiteSpace($existingPassword)
    ) {
        return
    }

    $credential = Get-Credential `
        -Message (
            'Enter approved local Administrator or sysadm credentials ' +
            'for Azure Local bootstrap WinRM access.'
        )

    if ($null -eq $credential) {
        throw 'Local Administrator credential prompt was canceled.'
    }

    if ([string]::IsNullOrWhiteSpace($credential.UserName)) {
        throw 'Local Administrator username is required.'
    }

    $plainTextPassword = ConvertTo-PlainTextPassword `
        -Password $credential.Password

    if ([string]::IsNullOrWhiteSpace($plainTextPassword)) {
        throw 'Local Administrator password is required.'
    }

    Set-ProcessEnvironmentVariable `
        -Name 'FACTORY_LOCAL_ADMIN_USER' `
        -Value $credential.UserName

    Set-ProcessEnvironmentVariable `
        -Name 'FACTORY_LOCAL_ADMIN_PASSWORD' `
        -Value $plainTextPassword
}

function Request-DeploymentPassword {
    $existingPassword = [Environment]::GetEnvironmentVariable(
        'FACTORY_DEPLOYMENT_PASSWORD'
    )

    if (-not [string]::IsNullOrWhiteSpace($existingPassword)) {
        return
    }

    $securePassword = Read-Host `
        -Prompt 'Enter approved deployment password' `
        -AsSecureString

    $plainTextPassword = ConvertTo-PlainTextPassword `
        -Password $securePassword

    if ([string]::IsNullOrWhiteSpace($plainTextPassword)) {
        throw 'Deployment password is required.'
    }

    Set-ProcessEnvironmentVariable `
        -Name 'FACTORY_DEPLOYMENT_PASSWORD' `
        -Value $plainTextPassword
}

if ($RequireAddsCredentials) {
    Request-AddsCredential
}

if ($RequireLocalAdministratorCredentials) {
    Request-LocalAdministratorCredential
}

if ($RequireDeploymentPassword) {
    Request-DeploymentPassword
}

return [pscustomobject]@{
    CreatedEnvironmentVariables = $createdEnvironmentVariables.ToArray()

    Cleanup = {
        param(
            [string[]]$EnvironmentVariableNames
        )

        foreach ($environmentVariableName in $EnvironmentVariableNames) {
            [Environment]::SetEnvironmentVariable(
                $environmentVariableName,
                $null,
                'Process'
            )
        }
    }
}