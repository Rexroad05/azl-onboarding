#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageRoot,

    [ValidateSet('AzureLocalExecution')]
    [string]$RunnerProfile,

    [switch]$RequireAzureCli,

    [switch]$RequireBicep,

    [switch]$RequireConfiguredModules
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-YamlValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Test-JsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label
    )

    try {
        Get-Content `
            -LiteralPath $Path `
            -Raw |
            ConvertFrom-Json |
            Out-Null

        return $true
    }
    catch {
        [void]$errors.Add(
            "$Label is not valid JSON: $Path"
        )

        return $false
    }
}

function Test-YamlFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label
    )

    try {
        Get-Content `
            -LiteralPath $Path `
            -Raw |
            ConvertFrom-Yaml `
            -Ordered |
            Out-Null

        return $true
    }
    catch {
        [void]$errors.Add(
            "$Label is not valid YAML: $Path"
        )

        return $false
    }
}

$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)

$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
    throw "Package root does not exist: $PackageRoot"
}

if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    [void]$errors.Add(
        "PowerShell 7.4 or later is required. Current version: " +
        "$($PSVersionTable.PSVersion)"
    )
}

if ($null -eq (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    try {
        Import-Module powershell-yaml -ErrorAction Stop
    }
    catch {
        [void]$errors.Add(
            'Required PowerShell module powershell-yaml is unavailable.'
        )
    }
}

$requiredDirectories = @(
    'artifacts',
    'azure',
    'bootstrap',
    'controller',
    'launcher',
    'operator-inputs',
    'preflight',
    'protected',
    'reports',
    'state',
    'tools',
    'validation'
)

foreach ($relativePath in $requiredDirectories) {
    $fullPath = Join-Path $PackageRoot $relativePath

    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        [void]$errors.Add(
            "Required package directory is missing: $relativePath"
        )
    }
}

$requiredFiles = @{
    'Protected defaults' = 'protected\defaults.yaml'
    'Phase manifest' = 'protected\phase-manifest.yaml'
    'Adapter map' = 'protected\adapters.yaml'
    'Release manifest' = 'protected\release-manifest.json'
    'Release version' = 'protected\release-version.json'
    'Factory controller' = 'controller\Factory.psm1'
    'Factory orchestrator' = 'controller\Invoke-AzureLocalFactory.ps1'
    'Deployment manager' = 'launcher\Start-AzureLocalDeploymentManager.ps1'
}

foreach ($label in $requiredFiles.Keys) {
    $path = Join-Path $PackageRoot $requiredFiles[$label]

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [void]$errors.Add(
            "$label file is missing: $($requiredFiles[$label])"
        )
    }
}

$defaultsPath = Join-Path $PackageRoot 'protected\defaults.yaml'
$phaseManifestPath = Join-Path $PackageRoot 'protected\phase-manifest.yaml'
$adaptersPath = Join-Path $PackageRoot 'protected\adapters.yaml'
$releaseManifestPath = Join-Path $PackageRoot 'protected\release-manifest.json'
$releaseVersionPath = Join-Path $PackageRoot 'protected\release-version.json'

$defaults = $null

if (Test-Path -LiteralPath $defaultsPath -PathType Leaf) {
    if (Test-YamlFile -Path $defaultsPath -Label 'Protected defaults') {
        $defaults = Get-Content `
            -LiteralPath $defaultsPath `
            -Raw |
            ConvertFrom-Yaml `
            -Ordered
    }
}

if (Test-Path -LiteralPath $phaseManifestPath -PathType Leaf) {
    Test-YamlFile `
        -Path $phaseManifestPath `
        -Label 'Phase manifest' |
        Out-Null
}

if (Test-Path -LiteralPath $adaptersPath -PathType Leaf) {
    Test-YamlFile `
        -Path $adaptersPath `
        -Label 'Adapter map' |
        Out-Null
}

if (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf) {
    Test-JsonFile `
        -Path $releaseManifestPath `
        -Label 'Release manifest' |
        Out-Null
}

if (Test-Path -LiteralPath $releaseVersionPath -PathType Leaf) {
    Test-JsonFile `
        -Path $releaseVersionPath `
        -Label 'Release version' |
        Out-Null
}

$runnerProfileConfigured = $false

if ($null -ne $defaults) {
    $runnerProfiles = Get-YamlValue `
        -Object $defaults `
        -Name 'runner_profiles'

    if ($null -eq $runnerProfiles) {
        [void]$errors.Add(
            'Protected defaults do not contain runner_profiles.'
        )
    }
    elseif ($runnerProfiles -is [System.Collections.IDictionary]) {
        $runnerProfileConfigured = $runnerProfiles.Contains($RunnerProfile)
    }
    else {
        $runnerProfileConfigured = (
            $null -ne $runnerProfiles.PSObject.Properties[$RunnerProfile]
        )
    }

    if (-not $runnerProfileConfigured) {
        [void]$errors.Add(
            "Runner profile is not configured in protected defaults: $RunnerProfile"
        )
    }
}

$artifactsDirectory = Join-Path $PackageRoot 'artifacts'

try {
    $testPath = Join-Path $artifactsDirectory (
        ".write-test-$([guid]::NewGuid().ToString('N')).tmp"
    )

    Set-Content `
        -LiteralPath $testPath `
        -Value 'test' `
        -Encoding utf8

    Remove-Item `
        -LiteralPath $testPath `
        -Force
}
catch {
    [void]$errors.Add(
        'Operator does not have write access to the artifacts directory.'
    )
}

$azureCliAvailable = (
    $null -ne (
        Get-Command `
            -Name az `
            -ErrorAction SilentlyContinue
    )
)

$azureCliProbePerformed = (
    $RequireAzureCli -or
    $RequireBicep
)

$azureCliVersion = $null
$bicepAvailable = $false
$bicepVersion = $null

if ($azureCliProbePerformed) {
    if ($azureCliAvailable) {
        try {
            $azureCliVersion = @(
                & az version `
                    --only-show-errors `
                    --output json 2>$null
            ) -join "`n" |
                ConvertFrom-Json `
                -AsHashtable

            $bicepVersionOutput = @(
                & az bicep version 2>$null
            ) -join "`n"

            if (
                $LASTEXITCODE -eq 0 -and
                -not [string]::IsNullOrWhiteSpace($bicepVersionOutput)
            ) {
                $bicepAvailable = $true
                $bicepVersion = $bicepVersionOutput.Trim()
            }
        }
        catch {
            [void]$warnings.Add(
                'Azure CLI is present but version or Bicep capability could not be determined.'
            )
        }
    }
    else {
        [void]$warnings.Add(
            'Azure CLI is not installed or is not available through PATH.'
        )
    }
}
else {
    [void]$warnings.Add(
        'Azure CLI/Bicep version probe was deferred because the selected action does not require Azure tooling.'
    )
}

if ($RequireAzureCli -and -not $azureCliAvailable) {
    [void]$errors.Add(
        'Azure CLI is required for the selected workflow stage but is unavailable.'
    )
}

if ($RequireBicep -and -not $bicepAvailable) {
    [void]$errors.Add(
        'Azure CLI Bicep capability is required for the selected workflow stage but is unavailable.'
    )
}

$missingConfiguredModules = [System.Collections.Generic.List[string]]::new()

if ($null -ne $defaults) {
    $moduleBaseline = Get-YamlValue `
        -Object $defaults `
        -Name 'module_baseline'

    $requiredModules = @(
        Get-YamlValue `
            -Object $moduleBaseline `
            -Name 'required_modules'
    )

    foreach ($requiredModule in $requiredModules) {
        $moduleName = [string](
            Get-YamlValue `
                -Object $requiredModule `
                -Name 'name'
        )

        if ([string]::IsNullOrWhiteSpace($moduleName)) {
            continue
        }

        $moduleAvailable = $null -ne (
            Get-Module `
                -ListAvailable `
                -Name $moduleName |
                Select-Object -First 1
        )

        if (-not $moduleAvailable) {
            $missingConfiguredModules.Add($moduleName)
        }
    }
}

if ($missingConfiguredModules.Count -gt 0) {
    $moduleMessage = (
        'Configured PowerShell module(s) are unavailable: ' +
        ($missingConfiguredModules -join ', ')
    )

    if ($RequireConfiguredModules) {
        [void]$errors.Add($moduleMessage)
    }
    else {
        [void]$warnings.Add($moduleMessage)
    }
}

if ($errors.Count -gt 0) {
    throw (
        "Operator workstation prerequisite validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

return [pscustomobject]@{
    Passed                  = $true
    RunnerProfile           = $RunnerProfile
    PowerShell              = $PSVersionTable.PSVersion.ToString()
    PowerShellEdition       = $PSVersionTable.PSEdition
    PackageRoot             = $PackageRoot
    ArtifactsPath           = $artifactsDirectory
    AzureCliAvailable       = $azureCliAvailable
    AzureCliVersion         = if ($null -ne $azureCliVersion) {
        [string]$azureCliVersion.'azure-cli'
    }
    BicepAvailable          = $bicepAvailable
    BicepVersion            = $bicepVersion
    MissingConfiguredModules = $missingConfiguredModules.ToArray()
    Warnings                = $warnings.ToArray()
    ValidatedAtUtc          = [datetime]::UtcNow.ToString('o')
}