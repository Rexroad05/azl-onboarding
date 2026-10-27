$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$modulePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\ManagementPlane.Common.psm1'

$defaultsPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\defaults.yaml'

$remoteManagementTestPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-RemoteManagement.ps1'

$certificateTrustTestPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-WinRMCertificateTrust.ps1'

$nodeIdentityTestPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-NodeIdentity.ps1'

Describe 'Management-plane bootstrap connection support' {
    BeforeAll {
        foreach ($requiredPath in @(
                $modulePath,
                $defaultsPath,
                $remoteManagementTestPath,
                $certificateTrustTestPath,
                $nodeIdentityTestPath
            )) {
            if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
                throw "Required test path was not found: $requiredPath"
            }
        }

        $moduleContent = Get-Content `
            -LiteralPath $modulePath `
            -Raw

        $defaultsContent = Get-Content `
            -LiteralPath $defaultsPath `
            -Raw

        $remoteManagementTestContent = Get-Content `
            -LiteralPath $remoteManagementTestPath `
            -Raw

        $certificateTrustTestContent = Get-Content `
            -LiteralPath $certificateTrustTestPath `
            -Raw

        $nodeIdentityTestContent = Get-Content `
            -LiteralPath $nodeIdentityTestPath `
            -Raw
    }

    It 'defines bootstrap external endpoint targeting' {
        $moduleContent | Should Match 'BootstrapExternalEndpoint'
        $moduleContent | Should Match 'bootstrap_connection'
        $moduleContent | Should Match 'LocalAdministrator'
    }

    It 'obtains local administrator credential variable names from protected configuration' {
        $moduleContent | Should Match 'local_credential_username_env'
        $moduleContent | Should Match 'local_credential_password_env'

        $defaultsContent | Should Match (
            'local_credential_username_env:\s*FACTORY_LOCAL_ADMIN_USER'
        )

        $defaultsContent | Should Match (
            'local_credential_password_env:\s*FACTORY_LOCAL_ADMIN_PASSWORD'
        )
    }

    It 'retains HTTPS-only bootstrap authentication requirements' {
        $moduleContent | Should Match 'WinRM-HTTPS'
        $moduleContent | Should Match 'UseSSL'
        $moduleContent | Should Match 'BootstrapAuthenticationMethod'
        $moduleContent | Should Match 'Negotiate'
    }

    It 'does not disable certificate hostname or CN validation' {
        $moduleContent | Should Not Match 'SkipCNCheck'

        $moduleContent | Should Match 'SkipCACheck'
        $moduleContent | Should Match 'SkipRevocationCheck'

        $moduleContent | Should Match (
            'Hostname/CN validation remains enforced'
        )

        $defaultsContent | Should Match (
            'require_hostname_match:\s*true'
        )

        $defaultsContent | Should Match (
            'allow_skip_cn_check:\s*false'
        )
    }

    It 'requires explicit runtime approval before a temporary certificate exception' {
        $moduleContent | Should Match (
            'FACTORY_ALLOW_UNTRUSTED_WINRM'
        )

        $moduleContent | Should Match (
            'APPROVED_TEMPORARY_EXCEPTION'
        )

        $moduleContent | Should Match (
            'ApprovedTemporaryException'
        )
    }

    It 'uses the selected bootstrap hostname and port for remote-management testing' {
        $remoteManagementTestContent | Should Match 'ConnectionHost'
        $remoteManagementTestContent | Should Match 'ConnectionPort'
    }

    It 'parses the WinRM certificate-trust validation adapter' {
        {
            [scriptblock]::Create(
                $certificateTrustTestContent
            ) | Out-Null
        } | Should Not Throw
    }

    It 'keeps certificate-hostname bypass absent from the certificate-trust adapter' {
        $certificateTrustTestContent | Should Not Match 'SkipCNCheck'
    }

    It 'supports an approved pre-domain workgroup readiness state' {
        $nodeIdentityTestContent | Should Match (
            'require_prebootstrap_workgroup_state'
        )

        $nodeIdentityTestContent | Should Match 'PartOfDomain'
    }
}