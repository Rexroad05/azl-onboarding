#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

Describe 'Environment Configuration Topology Validation' {
    It 'parses environment configuration adapter' {
        @(Get-TestParseErrors `
            -RelativePath 'preflight\Test-EnvironmentConfiguration.ps1').Count |
            Should Be 0
    }

    It 'parses factory module' {
        @(Get-TestParseErrors `
            -RelativePath 'controller\Factory.psm1').Count |
            Should Be 0
    }

    It 'supports protected Phase 1 topology configuration' {
        $content = Get-TestFileContent `
            -RelativePath 'preflight\Test-EnvironmentConfiguration.ps1'

        $content |
            Should Match 'phase1_topology'

        $content |
            Should Match 'minimum_nodes'

        $content |
            Should Match 'maximum_nodes'

        $content |
            Should Match 'phase1_node_count'

        $content |
            Should Match 'TopologyIntent'
    }

    It 'does not enforce exactly two nodes in Phase 1 configuration validation' {
        $content = Get-TestFileContent `
            -RelativePath 'preflight\Test-EnvironmentConfiguration.ps1'

        $content |
            Should Not Match 'Phase 1 requires exactly two nodes'
    }

    It 'validates unique node names and node numbers' {
        $content = Get-TestFileContent `
            -RelativePath 'preflight\Test-EnvironmentConfiguration.ps1'

        $content |
            Should Match 'Duplicate node name'

        $content |
            Should Match 'Duplicate node_number'
    }

    It 'keeps four internal onboarding stages' {
        $content = Get-TestFileContent `
            -RelativePath 'preflight\Test-EnvironmentConfiguration.ps1'

        $content |
            Should Match 'exactly four onboarding workflow stages'
    }
}