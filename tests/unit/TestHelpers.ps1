Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TestRepositoryRoot {
    return [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\..')
    )
}

function Get-TestRepositoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    return Join-Path `
        (Get-TestRepositoryRoot) `
        $RelativePath
}

function Get-TestFileContent {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $path = Get-TestRepositoryPath -RelativePath $RelativePath

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required repository file does not exist: $RelativePath"
    }

    return Get-Content `
        -LiteralPath $path `
        -Raw
}

function Get-TestParseErrors {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $path = Get-TestRepositoryPath -RelativePath $RelativePath
    $tokens = $null
    $errors = $null

    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    )

    return @($errors)
}

function Get-TestYamlDocument {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ($null -eq (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        Import-Module powershell-yaml -ErrorAction Stop
    }

    return (
        Get-TestFileContent -RelativePath $RelativePath |
            ConvertFrom-Yaml -Ordered
    )
}

function Get-TestReleaseManifest {
    return (
        Get-TestFileContent `
            -RelativePath 'protected\release-manifest.json' |
            ConvertFrom-Json
    )
}