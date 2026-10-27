#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

Import-Module powershell-yaml -ErrorAction Stop

$manifest = Get-TestYamlDocument `
    -RelativePath 'protected\read-only-validation-manifest.yaml'

$adapterDocument = Get-TestYamlDocument `
    -RelativePath 'protected\adapters.yaml'

$adapterMap = if (
    $adapterDocument -is [System.Collections.IDictionary] -and
    $adapterDocument.Contains('adapters')
) {
    $adapterDocument['adapters']
}
else {
    $adapterDocument
}

$profiles = @($manifest.validation_profiles)

Describe 'Read-Only Validation Profiles' {
    It 'defines 1.2A discovery/readiness validation' {
        $profile = @(
            $profiles |
                Where-Object {
                    [string]$_.name -eq 'HcnDiscoveryReadiness'
                }
        ) | Select-Object -First 1

        $profile |
            Should Not BeNullOrEmpty

        $profile.display_name |
            Should Match '1\.2A'

        @($profile.operations) |
            Should Not BeNullOrEmpty
    }

    It 'defines 1.2C compliance validation' {
        $profile = @(
            $profiles |
                Where-Object {
                    [string]$_.name -eq 'HcnComplianceValidation'
                }
        ) | Select-Object -First 1

        $profile |
            Should Not BeNullOrEmpty

        $profile.display_name |
            Should Match '1\.2C'

        @($profile.operations) |
            Should Not BeNullOrEmpty
    }

    It 'contains no mutating Ensure operation in any read-only profile' {
        foreach ($profile in $profiles) {
            foreach ($operation in @($profile.operations)) {
                ([string]$operation -like 'Ensure-*') |
                    Should Be $false
            }
        }
    }

    It 'uses non-blocking Azure Local state discovery in 1.2A' {
    $profile = @(
        $profiles |
            Where-Object {
                [string]$_.name -eq 'HcnDiscoveryReadiness'
            }
    ) | Select-Object -First 1

    $operationText = @(
        $profile.operations
    ) -join "`n"

    $operationText |
        Should Match '(?m)^Get-AzureLocalDeploymentState$'

    $operationText |
        Should Not Match '(?m)^Test-AzureLocalDeploymentState$'
}

    It 'maps Azure Local state discovery to an existing adapter' {
        $adapterMap['Get-AzureLocalDeploymentState'] |
            Should Be 'preflight/Get-AzureLocalDeploymentState.ps1'

        Test-Path `
            -LiteralPath (
                Get-TestRepositoryPath `
                    -RelativePath $adapterMap['Get-AzureLocalDeploymentState']
            ) `
            -PathType Leaf |
            Should Be $true
    }

    It 'parses read-only validation controller and launcher' {
        $files = @(
            'controller\Invoke-ReadOnlyValidation.ps1',
            'launcher\Start-ReadOnlyValidation.ps1',
            'preflight\Get-AzureLocalDeploymentState.ps1'
        )

        foreach ($file in $files) {
            @(Get-TestParseErrors -RelativePath $file).Count |
                Should Be 0
        }
    }

    It 'keeps onboarding Stage 1.2B in Apply mode' {
        $phaseManifest = Get-TestYamlDocument `
            -RelativePath 'protected\phase-manifest.yaml'

        $phaseOne = @(
            $phaseManifest.workflow.phases |
                Where-Object {
                    [int]$_.id -eq 1
                }
        ) | Select-Object -First 1

        $stage = @(
            $phaseOne.stages |
                Where-Object {
                    [int]$_.id -eq 2
                }
        ) | Select-Object -First 1

        $stage.mode |
            Should Be 'Apply'

        $stage.display_name |
            Should Match '1\.2B'
    }
}