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

$phaseOne = @(
    $phaseManifest.workflow.phases |
        Where-Object {
            [int]$_.id -eq 1
        }
) | Select-Object -First 1

$stageOneThree = @(
    $phaseOne.stages |
        Where-Object {
            [int]$_.id -eq 3
        }
) | Select-Object -First 1

$stageOneThreeOperations = @(
    $stageOneThree.operations
) -join "`n"

$bootstrapStateContent = Get-TestFileContent `
    -RelativePath 'bootstrap\os\Test-AzureLocalNodeBootstrapState.ps1'

$bootstrapInvokeContent = Get-TestFileContent `
    -RelativePath 'bootstrap\os\Invoke-AzureLocalNodeBootstrap.ps1'

Describe 'Phase 1.3 Azure Local Node Bootstrap Readiness Contract' {
    It 'defines the Phase 1.3 bootstrap safety configuration' {
        $defaults.deployment.node_bootstrap |
            Should Not BeNullOrEmpty

        $defaults.deployment.node_bootstrap.mode |
            Should Be 'ReadinessOnly'

        $defaults.deployment.node_bootstrap.approved_execution_method |
            Should Be 'NotApproved'

        [bool]$defaults.deployment.node_bootstrap.allow_cluster_creation |
            Should Be $false

        [bool]$defaults.deployment.node_bootstrap.allow_arc_registration |
            Should Be $false
    }

    It 'defines Stage 1.3 as a validation-only readiness stage' {
        $stageOneThree.mode |
            Should Be 'Validate'
    }

    It 'includes Azure readiness prerequisites before bootstrap invocation' {
        $requiredOperations = @(
            'Connect-Azure',
            'Test-Subscription',
            'Test-Permissions',
            'Test-ResourceProviders',
            'Test-ResourceGroup',
            'Test-AzureConnectivity',
            'Test-AzureGovEndpoints',
            'Test-AzureLocalNodeBootstrapState'
        )

        foreach ($operation in $requiredOperations) {
            $escapedOperation = [regex]::Escape($operation)

            $stageOneThreeOperations |
                Should Match "(?m)^$escapedOperation$"
        }
    }

    It 'does not invoke node bootstrap during the current Phase 1 scope' {
        $operations = @($stageOneThree.operations)

        $stateIndex = [array]::IndexOf(
            [string[]]$operations,
            'Test-AzureLocalNodeBootstrapState'
        )

        $invokeIndex = [array]::IndexOf(
            [string[]]$operations,
            'Invoke-AzureLocalNodeBootstrap'
        )

        $stateIndex | Should BeGreaterThan 0
        $invokeIndex | Should Be -1
    }

    It 'maps Phase 1.3 operations to bootstrap OS paths' {
        $adapterMap['Invoke-AzureLocalNodeBootstrap'] |
            Should Be 'bootstrap/os/Invoke-AzureLocalNodeBootstrap.ps1'

        $adapterMap['Test-AzureLocalNodeBootstrapState'] |
            Should Be 'bootstrap/os/Test-AzureLocalNodeBootstrapState.ps1'
    }

    It 'contains existing-cluster and existing-registration blocks' {
        $bootstrapStateContent |
            Should Match 'Get\-Cluster'

        $bootstrapStateContent |
            Should Match 'Get\-AzureStackHci'

        $bootstrapStateContent |
            Should Match 'already clustered'

        $bootstrapStateContent |
            Should Match 'already Azure registered'
    }

    It 'requires a Stage 1.2 PASS record before bootstrap readiness succeeds' {
        $bootstrapStateContent |
            Should Match 'Stage 1\.2'

        $bootstrapStateContent |
            Should Match 'status.*PASS'
    }

    It 'does not implement a real bootstrap execution method yet' {
        $bootstrapInvokeContent |
            Should Match 'ReadinessOnly'

        $bootstrapInvokeContent |
            Should Match 'approved_execution_method'

        [string]$defaults.deployment.node_bootstrap.approved_execution_method |
            Should Be 'NotApproved'

        $bootstrapInvokeContent |
            Should Match 'Blocked'

        $bootstrapInvokeContent |
            Should Not Match 'New\-AzStackHciCluster'

        $bootstrapInvokeContent |
            Should Not Match 'New\-AzStackHciDeployment'

        $bootstrapInvokeContent |
            Should Not Match 'Register\-ArcNode'
    }

    It 'parses both Phase 1.3 adapters' {
        @(Get-TestParseErrors `
            -RelativePath 'bootstrap\os\Test-AzureLocalNodeBootstrapState.ps1').Count |
            Should Be 0

        @(Get-TestParseErrors `
            -RelativePath 'bootstrap\os\Invoke-AzureLocalNodeBootstrap.ps1').Count |
            Should Be 0
    }
}