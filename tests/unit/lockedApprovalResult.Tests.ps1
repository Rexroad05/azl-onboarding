$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$factoryPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'controller\Factory.psm1'

Describe 'Factory blocked approval result handling' {
    BeforeAll {
        $factoryContent = Get-Content `
            -LiteralPath $factoryPath `
            -Raw
    }

    It 'returns blocked approval-gated adapter results to Invoke-Stage' {
        $factoryContent |
            Should Match '\$outcome\s*-eq\s*''Blocked'''

        $factoryContent |
            Should Match 'RequiresApproval'

        $factoryContent |
            Should Match 'PauseRequested'

        $factoryContent |
            Should Match 'return \$result'
    }

    It 'uses Summary as fallback failure evidence' {
        $factoryContent |
            Should Match "Name 'Summary'"

        $factoryContent |
            Should Match 'without a Reason or Summary property'
    }
}