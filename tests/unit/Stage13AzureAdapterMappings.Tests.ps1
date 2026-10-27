$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$adapterMapPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\adapters.yaml'

$factoryPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'controller\Factory.psm1'

$azureStage3AdapterPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'azure\validation\Invoke-AzureStage3Validation.ps1'

$nodeConnectivityAdapterPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'azure\validation\Test-AzureLocalNodeConnectivity.ps1'

Describe 'Stage 1.3 Azure adapter mapping contract' {
    BeforeAll {
        $adapterMapContent = Get-Content `
            -LiteralPath $adapterMapPath `
            -Raw

        $factoryContent = Get-Content `
            -LiteralPath $factoryPath `
            -Raw

        $azureStage3AdapterContent = Get-Content `
            -LiteralPath $azureStage3AdapterPath `
            -Raw

        $nodeConnectivityAdapterContent = Get-Content `
            -LiteralPath $nodeConnectivityAdapterPath `
            -Raw
    }

    It 'maps Stage 1.3 site Azure operations to an adapter' {
        foreach ($operation in @(
                'Connect-Azure',
                'Test-Subscription',
                'Test-Permissions',
                'Test-ResourceProviders',
                'Test-ResourceGroup'
            )) {
            $adapterMapContent |
                Should Match (
                    [regex]::Escape($operation)
                )
        }
    }

    It 'maps Stage 1.3 node Azure connectivity operations to an adapter' {
        $adapterMapContent |
            Should Match 'Test-AzureConnectivity'

        $adapterMapContent |
            Should Match 'Test-AzureGovEndpoints'
    }

    It 'keeps all Stage 1.3 Azure readiness operations non-mutating' {
        foreach ($operation in @(
                'Connect-Azure',
                'Test-Subscription',
                'Test-Permissions',
                'Test-ResourceProviders',
                'Test-ResourceGroup',
                'Test-AzureConnectivity',
                'Test-AzureGovEndpoints'
            )) {
            $pattern = (
                "'" +
                [regex]::Escape($operation) +
                "'\s*=\s*@\{\s*Scope\s*=\s*'[^']+';\s*Mutates\s*=\s*" +
                '\$false'
            )

            $factoryContent |
                Should Match $pattern
        }
    }

    It 'uses Azure Government PowerShell context validation' {
        $azureStage3AdapterContent |
            Should Match 'AzureUSGovernment'

        $azureStage3AdapterContent |
            Should Match 'Get-AzContext'

        $azureStage3AdapterContent |
            Should Match 'Get-AzSubscription'
    }

    It 'uses read-only Azure resource-provider and resource-group queries' {
        $azureStage3AdapterContent |
            Should Match 'Get-AzResourceProvider'

        $azureStage3AdapterContent |
            Should Match 'Get-AzResourceGroup'

        $azureStage3AdapterContent |
            Should Not Match 'Register-AzResourceProvider'

        $azureStage3AdapterContent |
            Should Not Match 'New-AzResourceGroup'
    }

    It 'tests node Azure endpoints over DNS and HTTPS TCP 443' {
        $nodeConnectivityAdapterContent |
            Should Match 'Resolve-DnsName'

        $nodeConnectivityAdapterContent |
            Should Match 'Test-NetConnection'

        $nodeConnectivityAdapterContent |
            Should Match 'Port 443'
    }
}