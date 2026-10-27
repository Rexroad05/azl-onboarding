#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$PackageRoot = (
        [IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..')
        )
    ),

    [ValidateRange(1, 4)]
    [int[]]$Stages = @(1, 2)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop

$factoryModulePath = Join-Path $PackageRoot 'controller\Factory.psm1'
$phaseManifestPath = Join-Path $PackageRoot 'protected\phase-manifest.yaml'
$adapterMapPath = Join-Path $PackageRoot 'protected\adapters.yaml'

if (-not (Test-Path -LiteralPath $factoryModulePath -PathType Leaf)) {
    throw "Factory module does not exist: $factoryModulePath"
}

if (-not (Test-Path -LiteralPath $phaseManifestPath -PathType Leaf)) {
    throw "Phase manifest does not exist: $phaseManifestPath"
}

if (-not (Test-Path -LiteralPath $adapterMapPath -PathType Leaf)) {
    throw "Adapter map does not exist: $adapterMapPath"
}

Import-Module $factoryModulePath -Force -ErrorAction Stop

$phaseManifest = Get-Content `
    -LiteralPath $phaseManifestPath `
    -Raw |
    ConvertFrom-Yaml `
    -Ordered

$adapterMap = Get-Content `
    -LiteralPath $adapterMapPath `
    -Raw |
    ConvertFrom-Yaml `
    -Ordered

$phaseOne = @(
    $phaseManifest.workflow.phases |
        Where-Object {
            [int]$_.id -eq 1
        }
)[0]

if ($null -eq $phaseOne) {
    throw 'Phase 1 was not found in protected/phase-manifest.yaml.'
}

$selectedStages = @(
    $phaseOne.stages |
        Where-Object {
            $Stages -contains [int]$_.id
        } |
        Sort-Object {
            [int]$_.id
        }
)

if ($selectedStages.Count -lt 1) {
    throw (
        "No Phase 1 stages found for requested stages: " +
        ($Stages -join ', ')
    )
}

$operations = @(
    foreach ($stage in $selectedStages) {
        foreach ($operation in @($stage.operations)) {
            [pscustomobject]@{
                StageId       = [int]$stage.id
                StageName     = [string]$stage.display_name
                Operation     = [string]$operation
            }
        }
    }
)

$recursionPatterns = @(
    'Invoke-FactoryOperation',
    'Invoke-Stage',
    'Invoke-AzureLocalFactory'
)

$results = foreach ($entry in $operations) {
    $adapterMapped = $false
    $adapterExists = $false
    $catalogEntry = $false
    $parseValid = $false
    $recursiveReference = $false
    $adapterPath = $null
    $parseErrors = @()
    $notes = [System.Collections.Generic.List[string]]::new()

    try {
        Get-FactoryOperationMetadata `
            -Operation $entry.Operation |
            Out-Null

        $catalogEntry = $true
    }
    catch {
        [void]$notes.Add('Missing Factory operation catalog entry.')
    }

    if ($adapterMap.adapters.Contains($entry.Operation)) {
        $adapterMapped = $true

        $relativePath = [string]$adapterMap.adapters[$entry.Operation]
        $adapterPath = [IO.Path]::GetFullPath(
            (Join-Path $PackageRoot $relativePath)
        )

        $adapterExists = Test-Path `
            -LiteralPath $adapterPath `
            -PathType Leaf

        if (-not $adapterExists) {
            [void]$notes.Add("Adapter file missing: $relativePath")
        }
    }
    else {
        [void]$notes.Add('Missing protected/adapters.yaml mapping.')
    }

    if ($adapterExists) {
        $tokens = $null
        $errors = $null

        [System.Management.Automation.Language.Parser]::ParseFile(
            $adapterPath,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null

        $parseErrors = @($errors)
        $parseValid = ($parseErrors.Count -eq 0)

        if (-not $parseValid) {
            [void]$notes.Add(
                "PowerShell syntax errors: $($parseErrors.Count)"
            )
        }

        $recursiveMatches = @(
            Select-String `
                -LiteralPath $adapterPath `
                -Pattern $recursionPatterns `
                -CaseSensitive:$false |
                Where-Object {
                    $_.Line -notmatch '^\s*#'
                }
        )

        $recursiveReference = ($recursiveMatches.Count -gt 0)

        if ($recursiveReference) {
            [void]$notes.Add(
                'Potential recursive orchestration reference found.'
            )
        }
    }

    $ready = (
        $catalogEntry -and
        $adapterMapped -and
        $adapterExists -and
        $parseValid -and
        -not $recursiveReference
    )

    [pscustomobject]@{
        Stage              = "$($entry.StageId) - $($entry.StageName)"
        Operation          = $entry.Operation
        CatalogEntry       = $catalogEntry
        AdapterMapped      = $adapterMapped
        AdapterExists      = $adapterExists
        ParseValid         = $parseValid
        RecursiveReference = $recursiveReference
        Ready              = $ready
        AdapterPath        = $adapterPath
        Notes              = ($notes -join ' ')
    }
}

Write-Host ''
Write-Host 'Phase 1 / Stage 1.1 and 1.2 Adapter Readiness Audit' -ForegroundColor Cyan
Write-Host ''

$results |
    Format-Table `
        Stage,
        Operation,
        CatalogEntry,
        AdapterMapped,
        AdapterExists,
        ParseValid,
        RecursiveReference,
        Ready,
        Notes `
        -Wrap `
        -AutoSize

$notReady = @(
    $results |
        Where-Object {
            -not $_.Ready
        }
)

Write-Host ''

if ($notReady.Count -gt 0) {
    Write-Host (
        "FAILED: $($notReady.Count) Phase 1 adapter operation(s) are not ready."
    ) -ForegroundColor Red

    Write-Host ''
    Write-Host 'Operations requiring correction:' -ForegroundColor Yellow

    $notReady |
        Select-Object Stage, Operation, Notes, AdapterPath |
        Format-List

    throw (
        'Phase 1 / Stage 1.1 and 1.2 adapter readiness audit failed. ' +
        'Do not run validation until all required operations report Ready=True.'
    )
}

Write-Host (
    'PASSED: All Phase 1 / Stage 1.1 and 1.2 operations have catalog entries, ' +
    'adapter mappings, existing files, valid PowerShell syntax, and no obvious ' +
    'recursive factory invocation references.'
) -ForegroundColor Green