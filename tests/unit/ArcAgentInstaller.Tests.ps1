$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$manifestPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\arc-agent-manifest.yaml'

$installerPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'azure\registration\Install-AzureConnectedMachineAgent.ps1'

$phaseManifestPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\phase-manifest.yaml'

$adapterMapPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\adapters.yaml'

$factoryPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'controller\Factory.psm1'

Describe 'Factory-managed Azure Connected Machine agent installation' {
    BeforeAll {
        $manifestContent = Get-Content `
            -LiteralPath $manifestPath `
            -Raw

        $installerContent = Get-Content `
            -LiteralPath $installerPath `
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
    }

    It 'defines the protected execution-workstation staged MSI source' {
        $manifestContent |
            Should Match 'source_type:\s*ExecutionHostStagedMsi'

        $manifestContent |
            Should Match 'execution_host_path:'

        $manifestContent |
            Should Match 'expected_sha256:'

        $manifestContent |
            Should Match 'require_valid_authenticode_signature:\s*true'
    }

    It 'requires explicit approval and disables automatic agent upgrade' {
        $manifestContent |
            Should Match 'require_explicit_approval:\s*true'

        $manifestContent |
            Should Match 'allow_automatic_upgrade:\s*false'

        $manifestContent |
            Should Match 'allow_reinstall_when_agent_present:\s*false'
    }

    It 'adds the installer before Arc initialization and registration' {
        $phaseManifestContent |
            Should Match 'Install-AzureConnectedMachineAgent'

        $adapterMapContent |
            Should Match 'Install-AzureConnectedMachineAgent'

        $factoryContent |
            Should Match 'Install-AzureConnectedMachineAgent'
    }

    It 'transfers the verified MSI over a management-plane PSSession' {
        $installerContent |
            Should Match 'New-ManagementPlaneSession'

        $installerContent |
            Should Match 'Copy-Item'

        $installerContent |
            Should Match 'ToSession'
    }

    It 'verifies source and transferred MSI hash and signature' {
        $installerContent |
            Should Match 'Get-FileHash'

        $installerContent |
            Should Match 'Get-AuthenticodeSignature'

        $installerContent |
            Should Match 'expected_sha256'

        $installerContent |
            Should Match 'expected_signer_subject'
    }

    It 'installs the MSI without Arc registration or extension deployment' {
        $installerContent |
            Should Match 'msiexec.exe'

        $installerContent |
            Should Not Match 'azcmagent.exe connect'

        $installerContent |
            Should Not Match 'New-AzConnectedMachineExtension'

        $installerContent |
            Should Match 'Arc registration was not performed'
    }

    It 'validates azcmagent and HIMDS after installation' {
        $installerContent |
            Should Match 'azcmagent'

        $installerContent |
            Should Match 'Get-Service'

        $installerContent |
            Should Match 'himds'
    }

    It 'creates remote staging and install-log directories before MSI transfer' {
        $installerContent |
            Should Match 'NodeStagingDirectory'

        $installerContent |
            Should Match 'InstallLogDirectory'

        $installerContent |
            Should Match 'New-Item'

        $installerContent |
            Should Match 'ToSession'
    }

    It 'uses protected agent path resolution before PATH discovery' {
        $installerContent |
            Should Match 'agent_executable_path'

        $installerContent |
            Should Match 'ProgramW6432'

        $installerContent |
            Should Match 'AzureConnectedMachineAgent\\azcmagent.exe'
    }
}