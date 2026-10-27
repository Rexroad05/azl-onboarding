#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

Import-Module powershell-yaml -ErrorAction Stop

$toolPath = Get-TestRepositoryPath `
    -RelativePath 'tools\Test-NRFTReadOnlyRegression.ps1'

$defaults = Get-TestYamlDocument `
    -RelativePath 'protected\defaults.yaml'

$phaseManifest = Get-TestYamlDocument `
    -RelativePath 'protected\phase-manifest.yaml'

$phaseOne = @(
    $phaseManifest.workflow.phases |
        Where-Object {
            [int]$_.id -eq 1
        }
) | Select-Object -First 1

$stageOneTwo = @(
    $phaseOne.stages |
        Where-Object {
            [int]$_.id -eq 2
        }
) | Select-Object -First 1

Describe 'NRFT Read-Only Regression Discipline' {
    It 'parses the NRFT regression tool' {
        @(Get-TestParseErrors `
            -RelativePath 'tools\Test-NRFTReadOnlyRegression.ps1').Count |
            Should Be 0
    }

    It 'requires the existing registered cluster mutation block' {
        [bool]$defaults.deployment.block_existing_registered_cluster_changes |
            Should Be $true
    }

    It 'places existing cluster detection first in Stage 1.2' {
        @($stageOneTwo.operations)[0] |
            Should Be 'Test-AzureLocalDeploymentState'
    }

    It 'does not place an Ensure operation before the Stage 1.2 guard' {
        $operations = @($stageOneTwo.operations)

        $guardIndex = [array]::IndexOf(
            [string[]]$operations,
            'Test-AzureLocalDeploymentState'
        )

        foreach ($operation in $operations) {
            if ([string]$operation -like 'Ensure-*') {
                $operationIndex = [array]::IndexOf(
                    [string[]]$operations,
                    [string]$operation
                )

                ($operationIndex -gt $guardIndex) |
                    Should Be $true
            }
        }
    }

    It 'does not contain remote management or mutation commands in the regression tool' {
        $toolContent = Get-TestFileContent `
            -RelativePath 'tools\Test-NRFTReadOnlyRegression.ps1'

        $toolContent |
            Should Not Match 'New\-PSSession'

        $toolContent |
            Should Not Match 'Invoke\-ManagementPlaneCommand'

        $toolContent |
            Should Not Match 'Invoke\-FactoryOperation'
    }

    It 'checks Stage 1.1 PASS evidence' {
        $toolContent = Get-TestFileContent `
            -RelativePath 'tools\Test-NRFTReadOnlyRegression.ps1'

        $toolContent |
            Should Match 'NRFT Stage 1\.1 Passed'

        $toolContent |
            Should Match 'status.*PASS'
    }

    It 'checks Stage 1.2 existing-cluster and registration block evidence' {
        $toolContent = Get-TestFileContent `
            -RelativePath 'tools\Test-NRFTReadOnlyRegression.ps1'

        $toolContent |
            Should Match 'Existing Registered Cluster'

        $toolContent |
            Should Match 'registered'

        $toolContent |
            Should Match 'clustered'
    }

    It 'checks that no Ensure execution evidence exists' {
        $toolContent = Get-TestFileContent `
            -RelativePath 'tools\Test-NRFTReadOnlyRegression.ps1'

        $toolContent |
            Should Match 'Contains No Ensure Execution Evidence'

        $toolContent |
            Should Match 'Ensure-\*'
    }

    It 'checks that NRFT has no pending approval or reboot state' {
        $toolContent = Get-TestFileContent `
            -RelativePath 'tools\Test-NRFTReadOnlyRegression.ps1'

        $toolContent |
            Should Match 'No Pending Approval'

        $toolContent |
            Should Match 'No Pending Reboot'
    }
}