#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$PackageRoot = (
        [IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..')
        )
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PackageRoot = [IO.Path]::GetFullPath($PackageRoot).
    TrimEnd([char[]]@('\', '/'))

$releaseVersionPath = Join-Path $PackageRoot 'protected\release-version.json'
$manifestPath = Join-Path $PackageRoot 'protected\release-manifest.json'

if (-not (Test-Path -LiteralPath $releaseVersionPath -PathType Leaf)) {
    throw "Missing release-version.json: $releaseVersionPath"
}

$releaseVersion = Get-Content `
    -LiteralPath $releaseVersionPath `
    -Raw |
    ConvertFrom-Json `
        -AsHashtable

$excludedDirectories = @(
    '.git',
    'archive',
    'artifacts',
    'operator-inputs'
)

$excludedFiles = @(
    'protected/release-manifest.json'
)

function Get-FactoryRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FullPath,

        [Parameter(Mandatory)]
        [string]$RootPath
    )

    return $FullPath.Substring($RootPath.Length).
        TrimStart([char[]]@('\', '/')).
        Replace('\', '/')
}

$files = @(
    Get-ChildItem `
        -LiteralPath $PackageRoot `
        -Recurse `
        -File |
        Where-Object {
            $relativePath = Get-FactoryRelativePath `
                -FullPath $_.FullName `
                -RootPath $PackageRoot

            $directoryExcluded = $false

            foreach ($excludedDirectory in $excludedDirectories) {
                if (
                    $relativePath.StartsWith(
                        "$excludedDirectory/",
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                ) {
                    $directoryExcluded = $true
                    break
                }
            }

            -not $directoryExcluded -and
            $relativePath -notin $excludedFiles
        } |
        Sort-Object FullName
)

$manifestFiles = foreach ($file in $files) {
    $relativePath = Get-FactoryRelativePath `
        -FullPath $file.FullName `
        -RootPath $PackageRoot

    [ordered]@{
        path   = $relativePath
        sha256 = (
            Get-FileHash `
                -LiteralPath $file.FullName `
                -Algorithm SHA256
        ).Hash
    }
}

$manifest = [ordered]@{
    releaseVersion = $releaseVersion.releaseVersion
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    files          = @($manifestFiles)
}

$manifest |
    ConvertTo-Json `
        -Depth 10 |
    Set-Content `
        -LiteralPath $manifestPath `
        -Encoding utf8

Write-Output "Release manifest created: $manifestPath"