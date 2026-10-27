$repositoryRoot = Split-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -Parent

$nicRoleEnsurePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'bootstrap\os\Ensure-NicRoleMapping.ps1'

$managementVlanEnsurePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'bootstrap\os\Ensure-ManagementVlan.ps1'

$managementNetworkEnsurePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'bootstrap\os\Ensure-ManagementNetwork.ps1'

$storageEnsurePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'bootstrap\os\Ensure-StorageNetwork.ps1'

$adapterDesignPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-AdapterDesignState.ps1'

$storageReadinessPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-StorageNetworkReadiness.ps1'

$activeDirectoryReadinessPath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-ActiveDirectoryReadiness.ps1'

$deploymentStatePath = Join-Path `
    -Path $repositoryRoot `
    -ChildPath 'preflight\Test-AzureLocalDeploymentState.ps1'

Describe 'CNEF Stage 1.2B Apply safety contract' {
    BeforeAll {
        $nicRoleEnsureContent = Get-Content `
            -LiteralPath $nicRoleEnsurePath `
            -Raw

        $managementVlanEnsureContent = Get-Content `
            -LiteralPath $managementVlanEnsurePath `
            -Raw

        $managementNetworkEnsureContent = Get-Content `
            -LiteralPath $managementNetworkEnsurePath `
            -Raw

        $storageEnsureContent = Get-Content `
            -LiteralPath $storageEnsurePath `
            -Raw

        $adapterDesignContent = Get-Content `
            -LiteralPath $adapterDesignPath `
            -Raw

        $storageReadinessContent = Get-Content `
            -LiteralPath $storageReadinessPath `
            -Raw

        $activeDirectoryReadinessContent = Get-Content `
            -LiteralPath $activeDirectoryReadinessPath `
            -Raw

        $deploymentStateContent = Get-Content `
            -LiteralPath $deploymentStatePath `
            -Raw
    }

    It 'preserves the CNEF converged SET rather than renaming physical adapters' {
        $nicRoleEnsureContent | Should Match 'Get-VMSwitchTeam'
        $nicRoleEnsureContent | Should Match 'Converged'
        $nicRoleEnsureContent | Should Match 'No automatic physical NIC rename'
    }

    It 'validates the CNEF management vNIC through Hyper-V VLAN state' {
        $managementVlanEnsureContent | Should Match 'Get-VMNetworkAdapterVlan'
        $managementVlanEnsureContent | Should Match 'OperationMode'
        $managementVlanEnsureContent | Should Match 'AccessVlanId'
    }

    It 'does not automatically modify a noncompliant CNEF management vNIC IP state' {
        $managementNetworkEnsureContent | Should Match (
            'automatic vNIC IP change is permitted'
        )
        $managementNetworkEnsureContent | Should Match 'Get-NetIPAddress'
        $managementNetworkEnsureContent | Should Match 'Get-NetRoute'
    }

    It 'does not create CNEF storage networks when storage intent is None' {
        $storageEnsureContent | Should Match "storageIntent -eq 'None'"
        $storageEnsureContent | Should Match 'Storage network configuration is not applicable'
    }

    It 'validates the CNEF SET and management vNIC post-Ensure' {
        $adapterDesignContent | Should Match 'Get-VMSwitchTeam'
        $adapterDesignContent | Should Match 'Get-VMNetworkAdapterVlan'
        $adapterDesignContent | Should Match 'Converged switch'
    }

    It 'treats storage validation as not applicable for storage intent None' {
        $storageReadinessContent | Should Match "storageIntent -eq 'None'"
        $storageReadinessContent | Should Match 'not applicable'
    }

    It 'uses Local Identity and Key Vault metadata instead of AD DS readiness for CNEF' {
        $activeDirectoryReadinessContent | Should Match 'LocalIdentityWithKeyVault'
        $activeDirectoryReadinessContent | Should Match 'KeyVaultResourceId'
    }

    It 'blocks Apply when existing storage pools or virtual disks are present' {
        $deploymentStateContent | Should Match 'NonPrimordialStoragePools'
        $deploymentStateContent | Should Match 'Get-VirtualDisk'
        $deploymentStateContent | Should Match 'blocks Apply'
    }
}