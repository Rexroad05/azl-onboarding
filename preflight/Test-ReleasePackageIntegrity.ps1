#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $Context.Root 'protected\release-manifest.json'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Release manifest does not exist: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw |
    ConvertFrom-Json -AsHashtable

if (
    -not $manifest.Contains('releaseVersion') -or
    [string]::IsNullOrWhiteSpace([string]$manifest.releaseVersion)
) {
    throw 'Release manifest is missing releaseVersion.'
}

$files = @($manifest.files)

if ($files.Count -lt 1) {
    throw (
        'Release manifest contains no protected file hashes. ' +
        'Generate it with tools\New-ReleaseManifest.ps1 before deployment.'
    )
}

$errors = [System.Collections.Generic.List[string]]::new()

foreach ($file in $files) {
    $relativePath = [string]$file.path
    $expectedHash = [string]$file.sha256

    if (
        [string]::IsNullOrWhiteSpace($relativePath) -or
        [string]::IsNullOrWhiteSpace($expectedHash)
    ) {
        [void]$errors.Add('Release manifest contains an invalid file entry.')
        continue
    }

    if ([IO.Path]::IsPathRooted($relativePath)) {
        [void]$errors.Add(
            "Release manifest contains an absolute path: $relativePath"
        )
        continue
    }

    $fullPath = [IO.Path]::GetFullPath(
        (Join-Path $Context.Root $relativePath)
    )

    $rootPath = (
        [IO.Path]::GetFullPath($Context.Root)
    ).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )

    if (
        -not $fullPath.StartsWith(
            $rootPath + [IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        [void]$errors.Add(
            "Release manifest path escapes package root: $relativePath"
        )
        continue
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        [void]$errors.Add(
            "Protected package file is missing: $relativePath"
        )
        continue
    }

    $actualHash = (
        Get-FileHash -LiteralPath $fullPath -Algorithm SHA256
    ).Hash

    if (-not $actualHash.Equals(
        $expectedHash,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        [void]$errors.Add(
            "Protected package file hash mismatch: $relativePath"
        )
    }
}

if ($errors.Count -gt 0) {
    throw (
        "Release package integrity validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

return [pscustomobject]@{
    Passed         = $true
    Check          = 'Test-ReleasePackageIntegrity'
    ReleaseVersion = $manifest.releaseVersion
    ProtectedFiles = $files.Count
    ManifestPath   = $manifestPath
    ValidatedAt    = [datetime]::UtcNow.ToString('o')
}