$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$adapterPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-AzureLocalOfficialHardwareValidation.ps1'

Describe 'Official Azure Local hardware validation result handling' {
    BeforeAll {
        if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
            throw "Required adapter file was not found: $adapterPath"
        }

        $adapterContent = Get-Content `
            -LiteralPath $adapterPath `
            -Raw
    }

    It 'accepts a node-scoped factory context' {
        $adapterContent | Should Match '\[hashtable\]\$Context'
    }

    It 'requires structured official validation output' {
        $adapterContent | Should Match 'PassThru'
        $adapterContent | Should Match 'returned no structured'
    }

    It 'does not treat console-only completion as a passing hardware result' {
        $adapterContent | Should Match (
            'factory will not treat'
        )

        $adapterContent | Should Match (
            'console-only validation output as a passing result'
        )

        $adapterContent | Should Match (
            'returned no structured'
        )
    }

    It 'uses validation outcome fields rather than severity alone for findings' {
        $adapterContent | Should Match '\$severity'
        $adapterContent | Should Match '\$status'
        $adapterContent | Should Match '\$healthState'
        $adapterContent | Should Match '\$outcome'
        $adapterContent | Should Match '\$resultValue'

        $adapterContent | Should Match 'failed'
        $adapterContent | Should Match 'unhealthy'
        $adapterContent | Should Match 'needs\\s\*remediation'
    }

    It 'throws when official validation returns critical or failed conditions' {
        $adapterContent | Should Match (
            'official hardware validation reported critical'
        )
    }

    It 'does not contain disk, pool, or storage mutation commands' {
        $adapterContent | Should Not Match 'Clear-Disk'
        $adapterContent | Should Not Match 'Reset-PhysicalDisk'
        $adapterContent | Should Not Match 'Remove-StoragePool'
        $adapterContent | Should Not Match 'Initialize-Disk'
        $adapterContent | Should Not Match 'New-StoragePool'
    }

    It 'uses dictionary key collections rather than ambiguous Contains overloads' {
    $adapterContent | Should Match 'Object\.Keys'
    $adapterContent | Should Not Match '\$Object\.Contains\(\$Name\)'
    }
}