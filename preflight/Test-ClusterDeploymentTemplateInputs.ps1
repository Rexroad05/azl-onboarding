#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ClusterDeployment.Common.psm1" -Force

$clusterDeployment = Get-ClusterDeploymentSettings `
    -Config $Context.Config

$template = Get-ClusterDeploymentValue `
    -Object $clusterDeployment `
    -Name 'deployment_template'

$bicepFile = [string](
    Get-ClusterDeploymentValue `
        -Object $template `
        -Name 'bicep_file'
)

$bicepParameterFile = [string](
    Get-ClusterDeploymentValue `
        -Object $template `
        -Name 'bicep_parameter_file'
)

if ([string]::IsNullOrWhiteSpace($bicepFile)) {
    throw 'cluster_deployment.deployment_template.bicep_file is required.'
}

if ([string]::IsNullOrWhiteSpace($bicepParameterFile)) {
    throw 'cluster_deployment.deployment_template.bicep_parameter_file is required.'
}

$root = [IO.Path]::GetFullPath([string]$Context.Root)
$bicepPath = Join-Path $root $bicepFile
$bicepParameterPath = Join-Path $root $bicepParameterFile

if (-not (Test-Path -LiteralPath $bicepPath -PathType Leaf)) {
    throw "Bicep template does not exist: $bicepFile"
}

if (-not (Test-Path -LiteralPath $bicepParameterPath -PathType Leaf)) {
    throw "Bicep parameter file does not exist: $bicepParameterFile"
}

$bicepContent = Get-Content `
    -LiteralPath $bicepPath `
    -Raw

$bicepParameterContent = Get-Content `
    -LiteralPath $bicepParameterPath `
    -Raw

if ($bicepContent -notmatch "targetScope\s*=\s*'subscription'") {
    throw 'Phase 2 Bicep template must use subscription target scope.'
}

if ($bicepContent -notmatch 'param\s+resourceGroupName\s+string') {
    throw 'Phase 2 Bicep template must define resourceGroupName string parameter.'
}

if ($bicepContent -notmatch 'param\s+location\s+string') {
    throw 'Phase 2 Bicep template must define location string parameter.'
}

if ($bicepParameterContent -notmatch "using\s+'\.\/main\.bicep'") {
    throw 'Phase 2 Bicep parameter file must reference ./main.bicep.'
}

if ($bicepParameterContent -notmatch 'param\s+resourceGroupName') {
    throw 'Phase 2 Bicep parameter file must define resourceGroupName.'
}

if ($bicepParameterContent -notmatch 'param\s+location') {
    throw 'Phase 2 Bicep parameter file must define location.'
}

return New-ClusterDeploymentResult `
    -Check 'Test-ClusterDeploymentTemplateInputs' `
    -Passed $true `
    -Summary (
        "Phase 2 Bicep template and parameter file are present and match " +
        'the readiness-only supporting resource-group contract.'
    ) `
    -AdditionalProperties @{
        BicepFile = $bicepFile
        BicepParameterFile = $bicepParameterFile
    }