$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$keyVaultAdapterPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'azure\validation\Test-LocalIdentityKeyVaultReadiness.ps1'

$bootstrapStatePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'bootstrap\os\Test-AzureLocalNodeBootstrapState.ps1'

$manifestPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\phase-manifest.yaml'

$adaptersPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\adapters.yaml'

$factoryPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'controller\Factory.psm1'

Describe 'Local Identity Key Vault Stage 1.3 readiness contract' {
    BeforeAll {
        foreach ($path in @(
                $keyVaultAdapterPath,
                $bootstrapStatePath,
                $manifestPath,
                $adaptersPath,
                $factoryPath
            )) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required Package 3 file was not found: $path"
            }
        }

        $keyVaultAdapterContent = Get-Content `
            -LiteralPath $keyVaultAdapterPath `
            -Raw

        $bootstrapStateContent = Get-Content `
            -LiteralPath $bootstrapStatePath `
            -Raw

        $manifestContent = Get-Content `
            -LiteralPath $manifestPath `
            -Raw

        $adaptersContent = Get-Content `
            -LiteralPath $adaptersPath `
            -Raw

        $factoryContent = Get-Content `
            -LiteralPath $factoryPath `
            -Raw
    }

    It 'adds Local Identity Key Vault readiness to Stage 1.3' {
        $manifestContent | Should Match 'Test-LocalIdentityKeyVaultReadiness'
        $adaptersContent | Should Match 'Test-LocalIdentityKeyVaultReadiness'
        $factoryContent | Should Match 'Test-LocalIdentityKeyVaultReadiness'
    }

    It 'uses a read-only Azure Resource metadata query for Key Vault validation' {
        $keyVaultAdapterContent |
            Should Match 'Get-AzResource'

        $keyVaultAdapterContent |
            Should Match 'Microsoft.KeyVault/vaults'

        $keyVaultAdapterContent |
            Should Not Match 'az keyvault secret'

        $keyVaultAdapterContent |
            Should Not Match 'Set-AzKeyVault'

        $keyVaultAdapterContent |
            Should Not Match 'Remove-AzKeyVault'
    }

    It 'validates configured Key Vault resource identity' {
        $keyVaultAdapterContent | Should Match 'KeyVaultResourceId'
        $keyVaultAdapterContent | Should Match 'Get-AzResource'
        $keyVaultAdapterContent | Should Match 'Microsoft.KeyVault/vaults'
        $keyVaultAdapterContent | Should Match 'Key Vault name mismatch'
        $keyVaultAdapterContent | Should Match 'Key Vault resource group mismatch'
        $keyVaultAdapterContent | Should Match 'LocalIdentityWithKeyVault'
    }

    It 'keeps node bootstrap readiness in validation-only mode' {
        $bootstrapStateContent | Should Match 'ReadinessOnly'
        $bootstrapStateContent | Should Match 'allow_cluster_creation must remain false'
        $bootstrapStateContent | Should Match 'allow_arc_registration must remain false'
    }

    It 'adds Local Identity Key Vault prerequisites to node bootstrap readiness' {
        $bootstrapStateContent | Should Match 'LocalIdentityWithKeyVault'
        $bootstrapStateContent | Should Match 'KeyVaultName'
        $bootstrapStateContent | Should Match 'KeyVaultResourceId'
    }
}