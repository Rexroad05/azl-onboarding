#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

Describe 'IP Address Allocation Topology Validation' {
    It 'parses IP allocation adapter' {
        @(Get-TestParseErrors `
            -RelativePath 'preflight\Test-IPAddressAllocation.ps1').Count |
            Should Be 0
    }

    It 'allows one or more Phase 1 nodes' {
        $content = Get-TestFileContent `
            -RelativePath 'preflight\Test-IPAddressAllocation.ps1'

        $content |
            Should Match 'At least one node is required'

        $content |
            Should Not Match 'requires exactly two nodes'
    }

    It 'validates unique management addresses' {
        $content = Get-TestFileContent `
            -RelativePath 'preflight\Test-IPAddressAllocation.ps1'

        $content |
            Should Match 'Duplicate management IP address'
    }

    It 'reports management subnet gateway and VLAN values' {
        $content = Get-TestFileContent `
            -RelativePath 'preflight\Test-IPAddressAllocation.ps1'

        $content |
            Should Match 'ManagementSubnet'

        $content |
            Should Match 'ManagementGateway'

        $content |
            Should Match 'ManagementVlan'
    }
}