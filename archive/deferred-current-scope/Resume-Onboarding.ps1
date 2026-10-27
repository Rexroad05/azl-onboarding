#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$RunId,

    [ValidateSet('Validate', 'Apply')]
    [string]$Mode,

    [ValidateRange(1, 4)]
    [int]$PhaseId = 1,

    [ValidateRange(1, 99)]
    [int]$ThroughStage,

    [string]$ArtifactsPath = (Join-Path $PSScriptRoot '..\artifacts')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\Invoke-AzureLocalFactory.ps1" `
    -Environment $Environment `
    -Mode $Mode `
    -PhaseId $PhaseId `
    -ThroughStage $ThroughStage `
    -ArtifactsPath $ArtifactsPath `
    -RunId $RunId `
    -Resume