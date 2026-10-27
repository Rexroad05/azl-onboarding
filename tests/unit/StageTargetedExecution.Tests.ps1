$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$controllerPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'controller\Invoke-AzureLocalFactory.ps1'

$invokeStagePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'controller\Invoke-Stage.ps1'

$managerPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'launcher\Start-AzureLocalDeploymentManager.ps1'

Describe 'Stage-targeted Phase 1 execution contract' {
    BeforeAll {
        $controllerContent = Get-Content `
            -LiteralPath $controllerPath `
            -Raw

        $invokeStageContent = Get-Content `
            -LiteralPath $invokeStagePath `
            -Raw

        $managerContent = Get-Content `
            -LiteralPath $managerPath `
            -Raw
    }

    It 'defines controller StartStage and StartOperation parameters' {
        $controllerContent |
            Should Match '\[int\]\$StartStage'

        $controllerContent |
            Should Match '\[string\]\$StartOperation'

        $controllerContent |
            Should Match 'StartStage cannot be greater than'

        $controllerContent |
            Should Match 'Focused operation'
    }

    It 'requires matching prerequisite PASS evidence for a targeted stage run' {
        $controllerContent |
            Should Match 'Get-FactoryPrerequisiteState'

        $controllerContent |
            Should Match 'requires PASS evidence'

        $controllerContent |
            Should Match 'prerequisiteStatePath'
    }

    It 'copies prerequisite PASS records into a targeted run state' {
        $controllerContent |
            Should Match 'priorStageRecord'

        $controllerContent |
            Should Match 'prerequisiteRunId'

        $controllerContent |
            Should Match 'startStage -gt 1'
    }

    It 'stores operation-level checkpoints for focused resume' {
        $invokeStageContent |
            Should Match 'operationCheckpoints'

        $invokeStageContent |
            Should Match 'Set-OperationCheckpoint'

        $invokeStageContent |
            Should Match 'Test-OperationCheckpoint'

        $invokeStageContent |
            Should Match 'Assert-PriorOperationCheckpoints'
    }

    It 'requires valid prior operation checkpoints before focused resume' {
        $invokeStageContent |
            Should Match 'Focused resume requires valid Stage'

        $invokeStageContent |
            Should Match 'OperationsBeforeStart'

        $invokeStageContent |
            Should Match 'StartOperation'
    }

    It 'supports same-run pending approval migration for focused resume' {
        $invokeStageContent |
            Should Match 'SameRunPendingApprovalMigration'

        $invokeStageContent |
            Should Match 'AllowPendingOperationResume'
    }

    It 'preserves normal full-stage reset behavior outside focused resume' {
        $controllerContent |
            Should Match 'Reset-FactoryStateFromStage'

        $controllerContent |
            Should Match 'operationCheckpoints.Remove'

        $controllerContent |
            Should Match 'returnToOperation = \$null'
    }

    It 'passes selected ready stage as StartStage from manager validation action' {
        $managerContent |
            Should Match (
                '-StartStage \(\[int\]\$nextReadyStage\.StageId\)'
            )
    }

    It 'passes selected ready stage as StartStage from manager apply action' {
        $managerContent |
            Should Match (
                '-Mode Apply\s*`\s*-StartStage \(\[int\]\$nextReadyStage\.StageId\)'
            )
    }

    It 'passes Register-ArcNode as focused operation for native session resume' {
        $managerContent |
            Should Match (
                "-StartOperation 'Register-ArcNode'"
            )

        $managerContent |
            Should Match 'Invoke-NativeArcRegistrationSession'

        $managerContent |
            Should Match 'Start or Resume Native Arc Registration Session'
    }

    It 'keeps Phase 1.1 through 1.3 planning separate from targeted execution' {
        $managerContent |
            Should Match '-ThroughStage 3'

        $controllerContent |
            Should Match 'if \(\$Mode -eq ''Plan''\)'
    }
}