#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\..\controller\Factory.psm1" -Force

$providers = @($Context.Config.azure.providers)

if ($providers.Count -lt 1) {
    throw 'azure.providers must contain at least one provider.'
}

$providerResults = [System.Collections.Generic.List[object]]::new()
$unregisteredProviders = [System.Collections.Generic.List[string]]::new()

foreach ($providerName in $providers) {
    $provider = Invoke-FactoryAz @(
        'provider',
        'show',
        '--namespace',
        [string]$providerName
    )

    $registrationState = [string]$provider.registrationState

    $providerResults.Add([pscustomobject]@{
        Provider          = [string]$providerName
        RegistrationState = $registrationState
    })

    if ($registrationState -ne 'Registered') {
        $unregisteredProviders.Add([string]$providerName)
    }
}

if ($unregisteredProviders.Count -gt 0) {
    throw (
        'Required Azure resource providers are not registered: ' +
        ($unregisteredProviders -join ', ')
    )
}

return [pscustomobject]@{
    Passed        = $true
    Check         = 'Test-ResourceProviders'
    ProviderCount = $providers.Count
    Providers     = $providerResults.ToArray()
    ValidatedAt   = [datetime]::UtcNow.ToString('o')
}