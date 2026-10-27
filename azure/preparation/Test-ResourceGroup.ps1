#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\..\controller\Factory.psm1" -Force

$resourceGroup = Invoke-FactoryAz @(
    'group',
    'show',
    '--name',
    $Context.Config.azure.resource_group
)

if ($resourceGroup.properties.provisioningState -ne 'Succeeded') {
    throw (
        "Resource group $($Context.Config.azure.resource_group) is not ready. " +
        "Provisioning state: $($resourceGroup.properties.provisioningState)"
    )
}

return [pscustomobject]@{
    Passed            = $true
    Check             = 'Test-ResourceGroup'
    ResourceGroup     = $resourceGroup.name
    Location          = $resourceGroup.location
    ProvisioningState = $resourceGroup.properties.provisioningState
    ValidatedAt       = [datetime]::UtcNow.ToString('o')
}