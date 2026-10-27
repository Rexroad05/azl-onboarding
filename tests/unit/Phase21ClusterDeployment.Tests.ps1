#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

Import-Module powershell-yaml -ErrorAction Stop

$defaults = Get-TestYamlDocument `
    -RelativePath 'protected\defaults.yaml'

$phaseManifest = Get-TestYamlDocument `
    -RelativePath 'protected\phase-manifest.yaml'

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

$phaseTwo = @(
    $phaseManifest.workflow.phases |
        Where-Object {
            [int]$_.id -eq 2
        }
) | Select-Object -First 1

$stageTwoOne = @(
    $phaseTwo.stages |
        Where-Object {
            [int]$_.id -eq 1
        }
) | Select-Object -First 1

$stageTwoOneOperations = @(
    $stageTwoOne.operations
) -join "`n"

$bicepContent = Get-TestFileContent `
    -RelativePath 'azure\deployment\main.bicep'

$bicepParameterContent = Get-TestFileContent `
    -RelativePath 'azure\deployment\main.bicepparam'

$phase21Adapters = @(
    'Test-ClusterDeploymentConfiguration',
    'Test-ClusterDeploymentNaming',
    'Test-ClusterDeploymentNetwork',
    'Test-ClusterDeploymentStorage',
    'Test-ClusterDeploymentAzurePrerequisites',
    'Test-ClusterDeploymentTemplateInputs',
    'Test-ClusterDeploymentSafetyState'
)

Describe 'Phase 2.1 Cluster Deployment Input Validation Contract' {
    It 'keeps Phase 2 disabled for execution' {
        [bool]$phaseTwo.implemented |
            Should Be $false
    }

    It 'defines Phase 2.1 as a Validate stage' {
        $stageTwoOne.mode |
            Should Be 'Validate'
    }

    It 'defines all required Phase 2.1 validation operations' {
        foreach ($operation in $phase21Adapters) {
            $escapedOperation = [regex]::Escape($operation)

            $stageTwoOneOperations |
                Should Match "(?m)^$escapedOperation$"
        }
    }

    It 'keeps Phase 2.2 and 2.3 without executable operations' {
        $stageTwoTwo = @(
            $phaseTwo.stages |
                Where-Object {
                    [int]$_.id -eq 2
                }
        ) | Select-Object -First 1

        $stageTwoThree = @(
            $phaseTwo.stages |
                Where-Object {
                    [int]$_.id -eq 3
                }
        ) | Select-Object -First 1

        @($stageTwoTwo.operations).Count |
            Should Be 0

        @($stageTwoThree.operations).Count |
            Should Be 0
    }

    It 'defines ReadinessOnly cluster deployment defaults' {
        $defaults.cluster_deployment |
            Should Not BeNullOrEmpty

        $defaults.cluster_deployment.mode |
            Should Be 'ReadinessOnly'

        [bool]$defaults.cluster_deployment.allow_cluster_creation |
            Should Be $false

        [bool]$defaults.cluster_deployment.allow_resource_deployment |
            Should Be $false

        $defaults.cluster_deployment.approved_execution_method |
            Should Be 'NotApproved'
    }

    It 'defines future cluster deployment safety controls' {
        $safety = $defaults.cluster_deployment.safety

        [bool]$safety.block_existing_cluster |
            Should Be $true

        [bool]$safety.block_existing_registration |
            Should Be $true

        [bool]$safety.block_existing_azure_resource |
            Should Be $true

        [bool]$safety.require_phase_14_success |
            Should Be $true
    }

    It 'maps all Phase 2.1 operations to existing adapter files' {
        foreach ($operation in $phase21Adapters) {
            $relativePath = [string]$adapterMap[$operation]

            $relativePath |
                Should Not BeNullOrEmpty

            $adapterPath = Get-TestRepositoryPath `
                -RelativePath $relativePath

            Test-Path `
                -LiteralPath $adapterPath `
                -PathType Leaf |
                Should Be $true
        }
    }

    It 'parses all Phase 2.1 adapters and shared module' {
        $files = @(
            'preflight\ClusterDeployment.Common.psm1',
            'preflight\Test-ClusterDeploymentConfiguration.ps1',
            'preflight\Test-ClusterDeploymentNaming.ps1',
            'preflight\Test-ClusterDeploymentNetwork.ps1',
            'preflight\Test-ClusterDeploymentStorage.ps1',
            'preflight\Test-ClusterDeploymentAzurePrerequisites.ps1',
            'preflight\Test-ClusterDeploymentTemplateInputs.ps1',
            'preflight\Test-ClusterDeploymentSafetyState.ps1'
        )

        foreach ($file in $files) {
            @(Get-TestParseErrors -RelativePath $file).Count |
                Should Be 0
        }
    }

    It 'uses AzureUSGovernment as the Phase 2 cloud' {
        $defaults.azure.cloud |
            Should Be 'AzureUSGovernment'
    }

    It 'contains a subscription-scope supporting resource group template' {
        $bicepContent |
            Should Match "targetScope\s*=\s*'subscription'"

        $bicepContent |
            Should Match 'Microsoft\.Resources\/resourceGroups'

        $bicepContent |
            Should Match 'param\s+resourceGroupName\s+string'

        $bicepContent |
            Should Match 'param\s+location\s+string'
    }

    It 'does not contain an Azure Local cluster deployment resource' {
        $bicepContent |
            Should Not Match 'Microsoft\.AzureStackHCI\/clusters'

        $bicepContent |
            Should Not Match 'New\-AzStackHciCluster'

        $bicepContent |
            Should Not Match 'Microsoft\.HybridCompute\/machines'
    }

    It 'uses a real Bicep parameter file' {
        $bicepParameterContent |
            Should Match "using\s+'\.\/main\.bicep'"

        $bicepParameterContent |
            Should Match 'param\s+resourceGroupName'

        $bicepParameterContent |
            Should Match 'param\s+location'
    }

    It 'keeps Phase 2 topology validation separate from Phase 1 topology flexibility' {
        $namingAdapter = Get-TestFileContent `
            -RelativePath 'preflight\Test-ClusterDeploymentNaming.ps1'

        $namingAdapter |
            Should Match 'requires exactly two nodes'

        $namingAdapter |
            Should Not Match 'phase1_topology'
    }
}