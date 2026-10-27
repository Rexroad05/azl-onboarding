#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ArtifactsPath,

    [Parameter(Mandatory)]
    [string]$Site,

    [string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$siteArtifactsPath = Join-Path $ArtifactsPath $Site

if (-not (Test-Path -LiteralPath $siteArtifactsPath -PathType Container)) {
    throw "No artifact directory exists for site: $Site"
}

if (-not [string]::IsNullOrWhiteSpace($RunId)) {
    $statePath = Join-Path $siteArtifactsPath "$RunId\deployment-state.json"

    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Deployment state does not exist for RunId: $RunId"
    }

    return (
        Get-Content -LiteralPath $statePath -Raw |
            ConvertFrom-Json -AsHashtable
    )
}

$stateFiles = @(
    Get-ChildItem `
        -LiteralPath $siteArtifactsPath `
        -Filter deployment-state.json `
        -Recurse `
        -File |
        Sort-Object LastWriteTimeUtc -Descending
)

if ($stateFiles.Count -lt 1) {
    throw "No deployment-state.json files exist for site: $Site"
}

return (
    Get-Content -LiteralPath $stateFiles[0].FullName -Raw |
        ConvertFrom-Json -AsHashtable
)