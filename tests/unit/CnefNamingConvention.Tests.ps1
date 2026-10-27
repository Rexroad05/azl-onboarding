$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$namingAdapterPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-NamingConvention.ps1'

$siteProfilesPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\site-profiles.yaml'

$cnefVariablesPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'operator-inputs\CNEF.variables.yaml'

Describe 'CNEF site-variable-driven naming contract' {
    BeforeAll {
        $namingAdapterContent = Get-Content `
            -LiteralPath $namingAdapterPath `
            -Raw

        $siteProfilesContent = Get-Content `
            -LiteralPath $siteProfilesPath `
            -Raw

        $cnefVariablesContent = Get-Content `
            -LiteralPath $cnefVariablesPath `
            -Raw
    }

    It 'keeps CNEF site identity in site variables' {
        $cnefVariablesContent | Should Match 'name:\s*cnef'
        $cnefVariablesContent | Should Match 'name:\s*azl-cnef-c1'
        $cnefVariablesContent | Should Match 'name:\s*azl-cnef-n1'
    }

    It 'keeps immutable CNEF profile free of site cluster and node identity' {
        $siteProfilesContent | Should Not Match 'azl-cnef-c1'
        $siteProfilesContent | Should Not Match 'azl-cnef-n1'
        $siteProfilesContent | Should Not Match 'expected_cluster_name'
        $siteProfilesContent | Should Not Match 'expected_nodes'
    }

    It 'uses a generic protected host-name validation mode for CNEF' {
        $siteProfilesContent | Should Match (
            'validation_mode:\s*GeneralWindowsHost'
        )

        $siteProfilesContent | Should Match (
            'allow_hyphenated_node_names:\s*true'
        )
    }

    It 'validates profile-driven generic Windows host names' {
        $namingAdapterContent | Should Match (
            "validationMode -eq 'GeneralWindowsHost'"
        )

        $namingAdapterContent | Should Match (
            'Test-ValidWindowsComputerName'
        )
    }

    It 'retains strict NRFT naming validation' {
        $namingAdapterContent | Should Match 'Expected site.name NRFT'
        $namingAdapterContent | Should Match 'NRFTAZCLUSTER01'
        $namingAdapterContent | Should Match 'NAEANRFTHCN01'
        $namingAdapterContent | Should Match 'NAEANRFTHCN02'
    }
}