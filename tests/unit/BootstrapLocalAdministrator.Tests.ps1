$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent

$defaultsPath = Join-Path -Path $repositoryRoot -ChildPath 'protected\defaults.yaml'
$siteTemplatePath = Join-Path -Path $repositoryRoot -ChildPath 'operator-inputs\SITE.variables.example.yaml'
$mergeScriptPath = Join-Path -Path $repositoryRoot -ChildPath 'launcher\Merge-FactoryConfiguration.ps1'
$operatorSessionPath = Join-Path -Path $repositoryRoot -ChildPath 'launcher\Initialize-OperatorSession.ps1'
$readOnlyLauncherPath = Join-Path -Path $repositoryRoot -ChildPath 'launcher\Start-ReadOnlyValidation.ps1'
$managerPath = Join-Path -Path $repositoryRoot -ChildPath 'launcher\Start-AzureLocalDeploymentManager.ps1'

Describe 'Bootstrap-local administrator credential routing' {
    It 'defines approved bootstrap local-credential environment variable names' {
        $defaultsContent = Get-Content -LiteralPath $defaultsPath -Raw

        $defaultsContent | Should Match 'bootstrap_authentication_mode:\s*LocalAdministrator'
        $defaultsContent | Should Match 'local_credential_username_env:\s*FACTORY_LOCAL_ADMIN_USER'
        $defaultsContent | Should Match 'local_credential_password_env:\s*FACTORY_LOCAL_ADMIN_PASSWORD'
    }

    It 'documents bootstrap_connection in the approved site-variable template' {
        $templateContent = Get-Content -LiteralPath $siteTemplatePath -Raw

        $templateContent | Should Match 'bootstrap_connection:'
        $templateContent | Should Match 'host:\s*"<APPROVED_BOOTSTRAP_WINRM_FQDN>"'
        $templateContent | Should Match 'port:\s*5986'
    }

    It 'allows only approved HTTPS bootstrap connection fields' {
        $mergeContent = Get-Content `
            -LiteralPath $mergeScriptPath `
            -Raw

        $mergeContent | Should Match "'bootstrap_connection'"
        $mergeContent | Should Match "'host'"
        $mergeContent | Should Match "'port'"
        $mergeContent | Should Match "'protocol'"

        $mergeContent | Should Match 'certificate-matching hostname'
        $mergeContent | Should Match 'raw IP address'
        $mergeContent | Should Match 'HTTPS or WinRM-HTTPS'
    }

    It 'requests local-administrator credentials without placing secrets in YAML' {
        $operatorSessionContent = Get-Content -LiteralPath $operatorSessionPath -Raw

        $operatorSessionContent | Should Match 'RequireLocalAdministratorCredentials'
        $operatorSessionContent | Should Match 'FACTORY_LOCAL_ADMIN_USER'
        $operatorSessionContent | Should Match 'FACTORY_LOCAL_ADMIN_PASSWORD'
    }

    It 'routes read-only validation through bootstrap-local credential handling when needed' {
        $readOnlyLauncherContent = Get-Content -LiteralPath $readOnlyLauncherPath -Raw

        $readOnlyLauncherContent | Should Match 'RequireLocalAdministratorCredentials'
        $readOnlyLauncherContent | Should Match 'bootstrap_connection'
    }

    It 'routes Phase 1 onboarding actions by actual node connection mode' {
        $managerContent = Get-Content -LiteralPath $managerPath -Raw

        $managerContent | Should Match 'Get-OperatorCredentialRequirements'
        $managerContent | Should Match 'RequireLocalAdministratorCredentials'
        $managerContent | Should Match 'bootstrap_connection'
    }
}