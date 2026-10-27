$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$launcherPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'launcher\Start-ReadOnlyValidation.ps1'

$managementPlaneModulePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\ManagementPlane.Common.psm1'

$defaultsPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\defaults.yaml'

Describe 'Read-only temporary WinRM certificate exception workflow' {
    BeforeAll {
        foreach ($requiredPath in @(
                $launcherPath,
                $managementPlaneModulePath,
                $defaultsPath
            )) {
            if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
                throw "Required test path was not found: $requiredPath"
            }
        }

        $launcherContent = Get-Content `
            -LiteralPath $launcherPath `
            -Raw

        $managementPlaneContent = Get-Content `
            -LiteralPath $managementPlaneModulePath `
            -Raw

        $defaultsContent = Get-Content `
            -LiteralPath $defaultsPath `
            -Raw
    }

    It 'defines an explicit temporary certificate exception switch' {
        $launcherContent | Should Match (
            'UseApprovedTemporaryWinRmCertificateException'
        )
    }

    It 'requires protected package authorization for a temporary exception' {
        $launcherContent | Should Match (
            'allow_temporary_certificate_exception'
        )

        $defaultsContent | Should Match (
            'allow_temporary_certificate_exception:\s*true'
        )
    }

    It 'requires explicit interactive operator acknowledgment' {
        $launcherContent | Should Match (
            'TEMPORARY-CERTIFICATE-EXCEPTION'
        )
    }

    It 'defaults the workflow certificate-validation mode to Strict' {
        $launcherContent | Should Match (
            "CertificateValidationMode = 'Strict'"
        )

        $launcherContent | Should Match (
            "'FACTORY_WINRM_CERTIFICATE_MODE',\s*'Strict'"
        )
    }

    It 'uses only the approved runtime exception variables' {
        $launcherContent | Should Match (
            'FACTORY_WINRM_CERTIFICATE_MODE'
        )

        $launcherContent | Should Match (
            'FACTORY_ALLOW_UNTRUSTED_WINRM'
        )

        $launcherContent | Should Match (
            'ApprovedTemporaryException'
        )

        $launcherContent | Should Match (
            'APPROVED_TEMPORARY_EXCEPTION'
        )
    }

    It 'restores prior certificate-validation environment values after the run' {
        $launcherContent | Should Match 'PreviousCertificateMode'
        $launcherContent | Should Match 'PreviousTemporaryApproval'
        $launcherContent | Should Match (
            'Restore-WorkflowWinRmCertificateValidation'
        )
    }

    It 'does not permit certificate hostname or CN validation bypass' {
        $launcherContent | Should Not Match 'SkipCNCheck'
        $managementPlaneContent | Should Not Match 'SkipCNCheck'
    }

    It 'uses the current read-only controller parameter contract' {
        $launcherContent | Should Match (
            '-Environment \$mergeResult\.ResolvedConfigPath'
        )

        $launcherContent | Should Match (
            '-ValidationManifestPath \$manifestPath'
        )

        $launcherContent | Should Match (
            '-ValidationProfile \$Profile'
        )

        $launcherContent | Should Match (
            '-ArtifactsPath \$artifactsPath'
        )
    }
}