$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$profilePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\site-profiles.yaml'

$phaseManifestPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\phase-manifest.yaml'

$adapterMapPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\adapters.yaml'

$factoryPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'controller\Factory.psm1'

$installerPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'azure\registration\Install-AzureConnectedMachineAgent.ps1'

$registrationInputPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'azure\registration\Test-AzureRegistrationInputs.ps1'

$arcRegistrationPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'azure\registration\Test-ArcRegistration.ps1'

$nodeHealthPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'validation\Test-NodeHealth.ps1'

$arcHealthPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'validation\Test-ArcHealth.ps1'

Describe 'Stage 1.4 factory-managed Arc agent contract' {
    BeforeAll {
        $profileContent = Get-Content `
            -LiteralPath $profilePath `
            -Raw

        $phaseManifestContent = Get-Content `
            -LiteralPath $phaseManifestPath `
            -Raw

        $adapterMapContent = Get-Content `
            -LiteralPath $adapterMapPath `
            -Raw

        $factoryContent = Get-Content `
            -LiteralPath $factoryPath `
            -Raw

        $installerContent = Get-Content `
            -LiteralPath $installerPath `
            -Raw

        $registrationInputContent = Get-Content `
            -LiteralPath $registrationInputPath `
            -Raw

        $arcRegistrationContent = Get-Content `
            -LiteralPath $arcRegistrationPath `
            -Raw

        $nodeHealthContent = Get-Content `
            -LiteralPath $nodeHealthPath `
            -Raw

        $arcHealthContent = Get-Content `
            -LiteralPath $arcHealthPath `
            -Raw
    }

    It 'enables protected CNEF interactive Arc registration' {
        $profileContent |
            Should Match 'mode:\s*InteractiveDeviceCode'

        $profileContent |
            Should Match 'allow_registration:\s*true'

        $profileContent |
            Should Match 'allow_device_code_registration:\s*true'
    }

    It 'inserts agent installation before Arc initialization and registration' {
        $phaseManifestContent |
            Should Match 'Install-AzureConnectedMachineAgent'

        $adapterMapContent |
            Should Match 'Install-AzureConnectedMachineAgent'

        $factoryContent |
            Should Match 'Install-AzureConnectedMachineAgent'
    }

    It 'uses staged MSI transfer and approval-gated installation' {
        $installerContent |
            Should Match 'ExecutionHostStagedMsi'

        $installerContent |
            Should Match 'Copy-Item'

        $installerContent |
            Should Match 'ToSession'

        $installerContent |
            Should Match 'RequiresApproval'
    }

    It 'prohibits Arc registration and extension deployment during agent install' {
        $installerContent |
            Should Not Match 'azcmagent.exe connect'

        $installerContent |
            Should Not Match 'New-AzConnectedMachineExtension'

        $installerContent |
            Should Match 'Arc registration was not performed'
    }

    It 'uses Azure PowerShell for Arc input and resource validation' {
        $registrationInputContent |
            Should Match 'Get-AzContext'

        $registrationInputContent |
            Should Match 'AzureUSGovernment'

        $arcRegistrationContent |
            Should Match 'Get-AzResource'

        $arcRegistrationContent |
            Should Not Match 'az connectedmachine show'
    }

    It 'implements node and Arc health checks' {
        $nodeHealthContent |
            Should Match 'himds'

        $nodeHealthContent |
            Should Match 'azcmagent'

        $arcHealthContent |
            Should Match 'Microsoft.HybridCompute/machines'

        $arcHealthContent |
            Should Match 'Get-AzResource'
    }

    It 'keeps Arc initialization preflight non-mutating' {
        $pattern = (
            "'Invoke-AzureLocalArcInitialization'\s*=\s*@\{\s*" +
            "Scope\s*=\s*'Node';\s*Mutates\s*=\s*" +
            '\$false'
        )

        $factoryContent |
            Should Match $pattern
    }

    It 'uses protected Arc agent path resolution across initialization and validation adapters' {
        $arcRegistrationContent = Get-Content `
            -LiteralPath (
                Join-Path `
                    $repositoryRoot `
                    'azure\registration\Register-ArcNode.ps1'
            ) `
            -Raw

        $arcInitializationContent = Get-Content `
            -LiteralPath (
                Join-Path `
                    $repositoryRoot `
                    'azure\registration\Invoke-AzureLocalArcInitialization.ps1'
            ) `
            -Raw

        $nodeHealthContent = Get-Content `
            -LiteralPath (
                Join-Path `
                    $repositoryRoot `
                    'validation\Test-NodeHealth.ps1'
            ) `
            -Raw

        $arcHealthContent = Get-Content `
            -LiteralPath (
                Join-Path `
                    $repositoryRoot `
                    'validation\Test-ArcHealth.ps1'
            ) `
            -Raw

        foreach ($content in @(
                $arcRegistrationContent,
                $arcInitializationContent,
                $nodeHealthContent,
                $arcHealthContent
            )) {
            $content |
                Should Match 'agent_executable_path'

            $content |
                Should Match 'ProgramW6432'

            $content |
                Should Match 'AzureConnectedMachineAgent\\azcmagent.exe'
        }
    }
}