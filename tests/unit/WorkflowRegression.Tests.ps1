#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

Import-Module powershell-yaml -ErrorAction Stop

$phaseManifest = Get-TestYamlDocument `
    -RelativePath 'protected\phase-manifest.yaml'

$phaseOne = @(
    $phaseManifest.workflow.phases |
        Where-Object {
            [int]$_.id -eq 1
        }
) |
    Select-Object -First 1

$phaseTwo = @(
    $phaseManifest.workflow.phases |
        Where-Object {
            [int]$_.id -eq 2
        }
) |
    Select-Object -First 1

$releaseManifest = Get-TestReleaseManifest
$releasePaths = @($releaseManifest.files.path)
$releasePathText = $releasePaths -join "`n"

$factoryContent = Get-TestFileContent `
    -RelativePath 'controller\Factory.psm1'

$invokeStageContent = Get-TestFileContent `
    -RelativePath 'controller\Invoke-Stage.ps1'

$invokeFactoryContent = Get-TestFileContent `
    -RelativePath 'controller\Invoke-AzureLocalFactory.ps1'

$statusContent = Get-TestFileContent `
    -RelativePath 'launcher\Get-DeploymentManagerStatus.ps1'

$managerContent = Get-TestFileContent `
    -RelativePath 'launcher\Start-AzureLocalDeploymentManager.ps1'

$approvalContent = Get-TestFileContent `
    -RelativePath 'launcher\Set-DeploymentApproval.ps1'

$stateSchema = Get-TestFileContent `
    -RelativePath 'state\state.schema.json' |
    ConvertFrom-Json

$batch2BAdapters = @(
    'bootstrap/os/Ensure-ManagementVlan.ps1',
    'bootstrap/os/Ensure-ManagementNetwork.ps1',
    'bootstrap/os/Ensure-StorageNetwork.ps1',
    'bootstrap/os/Ensure-IPv6Baseline.ps1',
    'bootstrap/os/Ensure-HostName.ps1'
)

Describe 'Azure Local Factory Workflow Regression Suite' {
    Context 'PowerShell source validity' {
        It 'parses controller and launcher runtime files' {
            $files = @(
                'controller\Factory.psm1',
                'controller\Invoke-Stage.ps1',
                'controller\Invoke-AzureLocalFactory.ps1',
                'controller\Invoke-NodeRebootAndReconnect.ps1',
                'launcher\Set-DeploymentApproval.ps1',
                'launcher\Get-DeploymentManagerStatus.ps1',
                'launcher\Start-AzureLocalDeploymentManager.ps1',
                'preflight\ManagementPlane.Common.psm1'
            )

            foreach ($file in $files) {
                @(Get-TestParseErrors -RelativePath $file).Count |
                    Should Be 0
            }
        }

        It 'parses Batch 2B Ensure adapters' {
            foreach ($adapter in $batch2BAdapters) {
                @(Get-TestParseErrors -RelativePath $adapter).Count |
                    Should Be 0
            }
        }
    }

    Context 'Phase 1 manifest safety' {
        It 'contains implemented Phase 1 with exactly four stages' {
            [bool]$phaseOne.implemented |
                Should Be $true

            @($phaseOne.stages).Count |
                Should Be 4
        }

        It 'defines Stage 1.1 as Validate' {
            $stage = @(
                $phaseOne.stages |
                    Where-Object {
                        [int]$_.id -eq 1
                    }
            ) |
                Select-Object -First 1

            $stage.mode |
                Should Be 'Validate'
        }

        It 'defines Stage 1.2 as Apply' {
            $stage = @(
                $phaseOne.stages |
                    Where-Object {
                        [int]$_.id -eq 2
                    }
            ) |
                Select-Object -First 1

            $stage.mode |
                Should Be 'Apply'
        }

        It 'defines Stage 1.3 as validation-only readiness' {
            $stage = @(
                $phaseOne.stages |
                    Where-Object {
                        [int]$_.id -eq 3
                    }
            ) |
                Select-Object -First 1

            $operations = @($stage.operations) -join "`n"

            $stage.mode |
                Should Be 'Validate'

            $operations |
                Should Match '(?m)^Test-AzureLocalNodeBootstrapState$'

            $operations |
                Should Not Match 'Invoke-AzureLocalNodeBootstrap'
        }

        It 'places existing-cluster detection first in Stage 1.2' {
            $stage = @(
                $phaseOne.stages |
                    Where-Object {
                        [int]$_.id -eq 2
                    }
            ) |
                Select-Object -First 1

            @($stage.operations)[0] |
                Should Be 'Test-AzureLocalDeploymentState'
        }
    }

    Context 'Phase 1 variable topology support' {
        It 'includes protected Phase 1 topology settings' {
            $factoryContent |
                Should Match 'phase1_topology'

            $factoryContent |
                Should Match 'minimum_nodes'

            $factoryContent |
                Should Match 'maximum_nodes'

            $factoryContent |
                Should Match 'phase1_node_count'
        }

        It 'does not require exactly two Phase 1 nodes' {
            $factoryContent |
                Should Not Match 'Phase 1 requires exactly two nodes'
        }

        It 'keeps Phase 2 cluster deployment deferred' {
            [bool]$phaseTwo.implemented |
                Should Be $false
        }
    }

    Context 'Phase 2 readiness-only contract' {
        It 'keeps Phase 2 disabled for execution' {
            [bool]$phaseTwo.implemented |
                Should Be $false
        }

        It 'does not include executable Phase 2.2 operations' {
            $stageTwoTwo = @(
                $phaseTwo.stages |
                    Where-Object {
                        [int]$_.id -eq 2
                    }
            ) |
                Select-Object -First 1

            @($stageTwoTwo.operations).Count |
                Should Be 0
        }

        It 'includes shared Phase 2 validation module in release manifest' {
            $releasePathText |
                Should Match '(?m)^preflight/ClusterDeployment\.Common\.psm1$'
        }
    }

    Context 'Release package integrity scope' {
        It 'excludes archive content' {
            @(
                $releasePaths |
                    Where-Object {
                        $_ -like 'archive/*'
                    }
            ).Count |
                Should Be 0
        }

        It 'excludes artifacts and operator inputs' {
            @(
                $releasePaths |
                    Where-Object {
                        $_ -like 'artifacts/*'
                    }
            ).Count |
                Should Be 0

            @(
                $releasePaths |
                    Where-Object {
                        $_ -like 'operator-inputs/*'
                    }
            ).Count |
                Should Be 0
        }

        It 'excludes release manifest self-reference' {
            $releasePathText |
                Should Not Match '(?m)^protected/release-manifest\.json$'
        }

        It 'includes all Batch 2B adapters' {
            foreach ($path in $batch2BAdapters) {
                $escapedPath = [regex]::Escape($path)

                $releasePathText |
                    Should Match "(?m)^$escapedPath$"
            }
        }
    }

    Context 'Factory controller safety' {
        It 'initializes approval, reboot, interactive, and operation checkpoint state' {
            $invokeFactoryContent |
                Should Match 'approvedOperations\s*=\s*@\{\}'

            $invokeFactoryContent |
                Should Match 'pendingApproval\s*=\s*\$null'

            $invokeFactoryContent |
                Should Match 'pendingReboot\s*=\s*\$null'

            $invokeFactoryContent |
                Should Match 'pendingInteractiveAuthentication\s*=\s*\$null'

            $invokeFactoryContent |
                Should Match 'operationCheckpoints\s*=\s*@\{\}'

            $invokeFactoryContent |
                Should Match 'returnToOperation\s*=\s*\$null'
        }

        It 'supports focused operation resume without full stage reset' {
            $invokeFactoryContent |
                Should Match '\[string\]\$StartOperation'

            $invokeFactoryContent |
                Should Match 'Resolve-FocusedOperation'

            $invokeFactoryContent |
                Should Match 'focusedResume'

            $invokeFactoryContent |
                Should Match 'AllowPendingOperationResume'
        }

        It 'passes operation name to adapter context' {
            $factoryContent |
                Should Match '\$adapterContext\.Operation\s*=\s*\$Operation'
        }

        It 'invokes an adapter exactly once' {
            $count = (
                [regex]::Matches(
                    $factoryContent,
                    '(?m)^\s*&\s+\$adapterPath\s+\-Context\s+\$adapterContext\s*$'
                )
            ).Count

            $count |
                Should Be 1
        }

        It 'blocks mutating operations in Validate mode' {
            $factoryContent |
                Should Match 'Validate mode blocks mutating operation'
        }
    }

    Context 'Approval, reboot, and interactive authentication lifecycle' {
        It 'defines reboot state in the schema' {
            $stateSchema.properties.pendingReboot |
                Should Not BeNullOrEmpty
        }

        It 'defines interactive authentication state in the schema' {
            $stateSchema.properties.pendingInteractiveAuthentication |
                Should Not BeNullOrEmpty
        }

        It 'defines focused operation and checkpoint state in the schema' {
            $stateSchema.properties.returnToOperation |
                Should Not BeNullOrEmpty

            $stateSchema.properties.operationCheckpoints |
                Should Not BeNullOrEmpty
        }

        It 'supports reboot, reboot-pending, and interactive pause types in Invoke-Stage' {
            $invokeStageContent |
                Should Match 'InteractiveAuthentication'

            $invokeStageContent |
                Should Match 'RebootPending'

            $invokeStageContent |
                Should Match 'Get-FactoryInteractiveAuthenticationRequest'

            $invokeStageContent |
                Should Match 'Get-FactoryRebootApprovalRequest'
        }

        It 'persists focused interactive authentication state in the factory controller' {
            $invokeFactoryContent |
                Should Match 'pendingInteractiveAuthentication'

            $invokeFactoryContent |
                Should Match 'resumeInteractiveAuthentication'

            $invokeFactoryContent |
                Should Match 'returnToOperation'
        }

        It 'shows native Arc session resume behavior in deployment status and manager' {
            $statusContent |
                Should Match 'NativeArcRegistrationSession'

            $statusContent |
                Should Match 'FocusedOperation'

            $managerContent |
                Should Match 'Native Arc Registration Session'

            $managerContent |
                Should Match 'Invoke-NativeArcRegistrationSession'

            $managerContent |
                Should Match 'StartOperation'
        }

        It 'prevents approval script from approving device-code completion' {
            $approvalContent |
                Should Match (
                    'Interactive authentication does not use Approve or Deny'
                )
        }
    }

    Context 'Validation findings reporting' {
        It 'includes the validation findings report engine in the release manifest' {
            $releasePathText |
                Should Match '(?m)^reports/New-ValidationFindingsReport\.ps1$'
        }

        It 'includes the read-only validation controller in the release manifest' {
            $releasePathText |
                Should Match '(?m)^controller/Invoke-ReadOnlyValidation\.ps1$'
        }

        It 'includes the read-only validation launcher in the release manifest' {
            $releasePathText |
                Should Match '(?m)^launcher/Start-ReadOnlyValidation\.ps1$'
        }
    }
}