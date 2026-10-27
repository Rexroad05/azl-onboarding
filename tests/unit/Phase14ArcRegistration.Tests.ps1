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
) |
    Select-Object -First 1

$stageOneFour = @(
    $phaseOne.stages |
        Where-Object {
            [int]$_.id -eq 4
        }
) |
    Select-Object -First 1

$stageOneFourOperations = @(
    $stageOneFour.operations
) -join "`n"

$inputTestContent = Get-TestFileContent `
    -RelativePath 'azure\registration\Test-AzureRegistrationInputs.ps1'

$initializationContent = Get-TestFileContent `
    -RelativePath 'azure\registration\Invoke-AzureLocalArcInitialization.ps1'

$registrationContent = Get-TestFileContent `
    -RelativePath 'azure\registration\Register-ArcNode.ps1'

$validationContent = Get-TestFileContent `
    -RelativePath 'azure\registration\Test-ArcRegistration.ps1'

Describe 'Phase 1.4 Arc Registration Readiness Contract' {
    It 'defines safe interactive-user Arc registration defaults' {
        $defaults.azure.arc_registration |
            Should Not BeNullOrEmpty

        $defaults.azure.arc_registration.mode |
            Should Be 'ReadinessOnly'

        [bool]$defaults.azure.arc_registration.allow_registration |
            Should Be $false

        $defaults.azure.arc_registration.authentication_method |
            Should Be 'DeviceCode'

        $defaults.azure.arc_registration.required_account_type |
            Should Be 'user'

        [bool]$defaults.azure.arc_registration.require_interactive_user |
            Should Be $true

        [bool]$defaults.azure.arc_registration.use_azure_cli_credentials_on_node |
            Should Be $false

        $defaults.azure.arc_registration.connected_machine_agent_command |
            Should Be 'azcmagent'
    }

    It 'defines protected native bootstrap session controls' {
        [int]$defaults.azure.arc_registration.native_bootstrap_status_poll_interval_seconds |
            Should BeGreaterThan 0

        [int]$defaults.azure.arc_registration.native_bootstrap_session_timeout_minutes |
            Should BeGreaterThan 0

        [int]$defaults.azure.arc_registration.azure_resource_visibility_timeout_minutes |
            Should BeGreaterThan 0

        [int]$defaults.azure.arc_registration.azure_resource_visibility_poll_interval_seconds |
            Should BeGreaterThan 0

        [bool]$defaults.azure.arc_registration.allow_automatic_update |
            Should Be $false

        [bool]$defaults.azure.arc_registration.allow_automatic_reboot |
            Should Be $false

        [bool]$defaults.azure.arc_registration.require_explicit_approval_after_reboot |
            Should Be $true
    }

    It 'contains native interactive device-code registration support without secrets' {
        $registrationContent |
            Should Match 'InteractiveDeviceCode'

        $registrationContent |
            Should Match 'Start-ArcBootstrap'

        $registrationContent |
            Should Match 'Get-ArcBootstrapStatus'

        $registrationContent |
            Should Match 'Invoke-NativeBootstrapSession'

        $registrationContent |
            Should Match 'Write-NativeBootstrapDeviceCode'

        $registrationContent |
            Should Match 'InteractiveAuthentication'

        $registrationContent |
            Should Match 'allow_device_code_registration'

        $registrationContent |
            Should Not Match 'azcmagent\s+connect'

        $registrationContent |
            Should Not Match 'use-device-code'

        $registrationContent |
            Should Not Match 'DeviceCodeUserCode'

        $registrationContent |
            Should Not Match 'DeviceCodeVerificationUri'

        $registrationContent |
            Should Not Match 'DeviceCodeExpiresOn'

        $registrationContent |
            Should Not Match 'service_principal_secret'

        $registrationContent |
            Should Not Match 'client_secret'

        $registrationContent |
            Should Not Match 'keyvault'
    }

    It 'does not use the Azure Local wrapper update path' {
        $registrationContent |
            Should Not Match 'Invoke-AzStackHciArcInitialization'

        $registrationContent |
            Should Not Match 'Start-ArcZeroDaySolutionUpdate'

        $registrationContent |
            Should Match 'allow_automatic_update'

        $registrationContent |
            Should Match 'allow_automatic_reboot'
    }

    It 'uses AzureUSGovernment as the Arc registration cloud' {
        $defaults.azure.cloud |
            Should Be 'AzureUSGovernment'
    }

    It 'defines Phase 1.4 as an Apply stage' {
        $stageOneFour.mode |
            Should Be 'Apply'
    }

    It 'includes Azure validation before Arc registration operations' {
        $requiredOperations = @(
            'Connect-Azure',
            'Test-Subscription',
            'Test-Permissions',
            'Test-ResourceProviders',
            'Test-ResourceGroup',
            'Test-AzureRegistrationInputs',
            'Install-AzureConnectedMachineAgent',
            'Invoke-AzureLocalArcInitialization',
            'Register-ArcNode',
            'Test-ArcRegistration',
            'Test-NodeHealth',
            'Test-ArcHealth'
        )

        foreach ($operation in $requiredOperations) {
            $escapedOperation = [regex]::Escape($operation)

            $stageOneFourOperations |
                Should Match "(?m)^$escapedOperation$"
        }
    }

    It 'maps all Phase 1.4 Arc adapters to existing paths' {
        $requiredMappings = @(
            'Test-AzureRegistrationInputs',
            'Invoke-AzureLocalArcInitialization',
            'Register-ArcNode',
            'Test-ArcRegistration'
        )

        foreach ($mapping in $requiredMappings) {
            $adapterMap[$mapping] |
                Should Not BeNullOrEmpty

            $path = Get-TestRepositoryPath `
                -RelativePath ([string]$adapterMap[$mapping])

            Test-Path `
                -LiteralPath $path `
                -PathType Leaf |
                Should Be $true
        }
    }

    It 'validates user device-code registration inputs without secrets' {
        $inputTestContent |
            Should Match 'DeviceCode'

        $inputTestContent |
            Should Match 'AzureUSGovernment'

        $inputTestContent |
            Should Match 'required_account_type'

        $inputTestContent |
            Should Not Match 'service_principal_secret'

        $inputTestContent |
            Should Not Match 'keyvault'
    }

    It 'blocks initialization on an existing cluster or registration' {
        $initializationContent |
            Should Match 'Get\-Cluster'

        $initializationContent |
            Should Match 'Get\-AzureStackHci'

        $initializationContent |
            Should Match 'ExistingCluster'

        $initializationContent |
            Should Match 'RegistrationStatus'
    }

    It 'checks for the Connected Machine agent without installing it' {
        $initializationContent |
            Should Match 'azcmagent'

        $initializationContent |
            Should Match 'himds'

        $initializationContent |
            Should Not Match 'Install\-Module'

        $initializationContent |
            Should Not Match 'msiexec'
    }

    It 'does not recursively invoke the factory from Register-ArcNode' {
        $registrationContent |
            Should Not Match 'Invoke\-FactoryOperation'

        $registrationContent |
            Should Match 'ReadinessOnly'

        $registrationContent |
            Should Match 'Blocked'
    }

    It 'uses bounded Azure Resource Manager validation after bootstrap success' {
        $validationContent |
            Should Match 'Get-AzResource'

        $validationContent |
            Should Match 'Microsoft.HybridCompute/machines'

        $validationContent |
            Should Match 'azure_resource_visibility_timeout_minutes'

        $validationContent |
            Should Match 'azure_resource_visibility_poll_interval_seconds'

        $validationContent |
            Should Match 'Get-ArcBootstrapStatus'

        $validationContent |
            Should Match 'Start-Sleep'

        $validationContent |
            Should Not Match 'az connectedmachine show'
    }

    It 'parses all Arc registration adapters' {
        $files = @(
            'azure\registration\Test-AzureRegistrationInputs.ps1',
            'azure\registration\Invoke-AzureLocalArcInitialization.ps1',
            'azure\registration\Register-ArcNode.ps1',
            'azure\registration\Test-ArcRegistration.ps1'
        )

        foreach ($file in $files) {
            @(Get-TestParseErrors -RelativePath $file).Count |
                Should Be 0
        }
    }
}