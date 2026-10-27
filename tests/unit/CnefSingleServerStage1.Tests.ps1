$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$siteProfilePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'protected\site-profiles.yaml'

$cnefVariablesPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'operator-inputs\CNEF.variables.yaml'

$environmentConfigurationPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-EnvironmentConfiguration.ps1'

$storageConfigurationPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-StorageNetworkConfiguration.ps1'

$activeDirectoryConfigurationPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-ActiveDirectoryConfiguration.ps1'

$requiredSecretsPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-RequiredSecrets.ps1'

Describe 'CNEF single-server Stage 1.1 profile contract' {
    BeforeAll {
        foreach ($path in @(
                $siteProfilePath,
                $cnefVariablesPath,
                $environmentConfigurationPath,
                $storageConfigurationPath,
                $activeDirectoryConfigurationPath,
                $requiredSecretsPath
            )) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required Package 1 file was not found: $path"
            }
        }

        $siteProfileContent = Get-Content `
            -LiteralPath $siteProfilePath `
            -Raw

        $cnefVariablesContent = Get-Content `
            -LiteralPath $cnefVariablesPath `
            -Raw

        $environmentConfigurationContent = Get-Content `
            -LiteralPath $environmentConfigurationPath `
            -Raw

        $storageConfigurationContent = Get-Content `
            -LiteralPath $storageConfigurationPath `
            -Raw

        $activeDirectoryConfigurationContent = Get-Content `
            -LiteralPath $activeDirectoryConfigurationPath `
            -Raw

        $requiredSecretsContent = Get-Content `
            -LiteralPath $requiredSecretsPath `
            -Raw
    }

    It 'authorizes CNEF to request the protected PacStar single-server profile' {
        $siteProfileContent | Should Match 'site_profile_authorizations'

        $siteProfileContent | Should Match (
            'cnef:\s*\r?\n\s*-\s*PacStar451SingleServer'
        )

        $siteProfileContent | Should Match 'PacStar451SingleServer'
    }

    It 'defines storage intent None only in protected profile configuration' {
        $siteProfileContent | Should Match 'storage_intent:\s*None'
        $siteProfileContent | Should Match 'networks:\s*\[\]'
        $cnefVariablesContent | Should Match 'storage:\s*\[\]'
    }

    It 'defines Local Identity with Azure Key Vault for CNEF' {
        $siteProfileContent | Should Match 'LocalIdentityWithKeyVault'
        $cnefVariablesContent | Should Match 'key_vault:'
        $cnefVariablesContent | Should Match 'kv-necc-poc'
    }

    It 'defines Intel, one-gigabit, RDMA-disabled, and SR-IOV-disabled CNEF requirements' {
        $siteProfileContent | Should Match 'expected_driver_pattern:\s*"\*Intel\*"'
        $siteProfileContent | Should Match 'minimum_link_speed_gbps:\s*1'
        $siteProfileContent | Should Match 'require_rdma:\s*false'
        $siteProfileContent | Should Match 'require_sriov:\s*false'
    }

    It 'defines the existing CNEF Port0 and Port1 converged SET' {
        $siteProfileContent | Should Match 'ConvergedSwitch\(compute_management\)'
        $siteProfileContent | Should Match 'Port0'
        $siteProfileContent | Should Match 'Port1'
        $siteProfileContent | Should Match 'SwitchIndependent'
        $siteProfileContent | Should Match 'HyperVPort'
    }

    It 'allows storage-intent-none configuration validation' {
        $environmentConfigurationContent | Should Match 'isStorageIntentNone'
        $storageConfigurationContent | Should Match "storageIntent -eq 'None'"
    }

    It 'uses Local Identity rather than a validation domain controller' {
        $activeDirectoryConfigurationContent | Should Match 'LocalIdentityWithKeyVault'
        $requiredSecretsContent | Should Match 'local_credential_username_env'
        $requiredSecretsContent | Should Match 'local_credential_password_env'
    }
}