#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

$defaults = Get-TestYamlDocument `
    -RelativePath 'protected\defaults.yaml'

$readinessContent = Get-TestFileContent `
    -RelativePath 'preflight\Test-LocalAdministratorReadiness.ps1'

$credentialContent = Get-TestFileContent `
    -RelativePath 'preflight\Test-LocalAdministratorCredential.ps1'

$readOnlyControllerContent = Get-TestFileContent `
    -RelativePath 'controller\Invoke-ReadOnlyValidation.ps1'

Describe 'Local Deployment Administrator Lifecycle' {
    It 'defines protected bootstrap account lifecycle policy' {
        $lifecycle = $defaults.security.local_administrator.lifecycle

        $lifecycle |
            Should Not BeNullOrEmpty

        [bool]$lifecycle.bootstrap_account |
            Should Be $true

        [bool]$lifecycle.require_for_1_2b |
            Should Be $true

        [bool]$lifecycle.allow_absent_in_1_2c |
            Should Be $true

        $lifecycle.post_bootstrap_behavior |
            Should Be 'MayBeRemoved'
    }

    It 'parses local administrator validation adapters' {
        @(Get-TestParseErrors `
            -RelativePath 'preflight\Test-LocalAdministratorReadiness.ps1').Count |
            Should Be 0

        @(Get-TestParseErrors `
            -RelativePath 'preflight\Test-LocalAdministratorCredential.ps1').Count |
            Should Be 0
    }

    It 'supports expected lifecycle absence in 1.2C readiness validation' {
        $readinessContent |
            Should Match 'ExpectedLifecycleState'

        $readinessContent |
            Should Match 'allow_absent_in_1_2c'

        $readinessContent |
            Should Match 'HcnComplianceValidation'
    }

    It 'supports expected lifecycle absence in 1.2C credential validation' {
        $credentialContent |
            Should Match 'ExpectedLifecycleState'

        $credentialContent |
            Should Match 'allow_absent_in_1_2c'

        $credentialContent |
            Should Match 'HcnComplianceValidation'
    }

    It 'does not silently create bootstrap account after lifecycle transition' {
        $readinessContent |
            Should Not Match 'New\-LocalUser'

        $credentialContent |
            Should Not Match 'New\-LocalUser'
    }

    It 'renders expected lifecycle state as a non-failing read-only result' {
        $readOnlyControllerContent |
            Should Match 'ExpectedLifecycleState'

        $readOnlyControllerContent |
            Should Match 'NotApplicable'

        $readOnlyControllerContent |
            Should Match 'NOT APPLICABLE'
    }

        It 'keeps account creation out of read-only validation adapters' {
        $readinessContent |
            Should Not Match 'New\-LocalUser'

        $credentialContent |
            Should Not Match 'New\-LocalUser'
    }

    It 'defines CNEF protected bootstrap account creation and password validation policy' {
        $siteProfileContent = Get-TestFileContent `
            -RelativePath 'protected\site-profiles.yaml'

        $siteProfileContent |
            Should Match 'create_if_missing_for_1_2b:\s*true'

        $siteProfileContent |
            Should Match 'validate_password_for_1_2b:\s*true'

        $siteProfileContent |
            Should Match 'reset_existing_password:\s*false'
    }

    It 'keeps automatic password reset prohibited' {
        $siteProfileContent = Get-TestFileContent `
            -RelativePath 'protected\site-profiles.yaml'

        $siteProfileContent |
            Should Match 'reset_existing_password:\s*false'
    }
}