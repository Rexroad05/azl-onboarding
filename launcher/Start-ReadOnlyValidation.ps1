#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PackageRoot,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ArtifactsPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Site,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RunnerProfile,

    [Parameter()]
    [ValidateSet(
        'HcnDiscoveryReadiness',
        'HcnComplianceValidation'
    )]
    [string]$Profile = 'HcnDiscoveryReadiness',

    [Parameter()]
    [switch]$NonInteractive,

    [Parameter()]
    [switch]$UseApprovedTemporaryWinRmCertificateException
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop

$packageRoot = [IO.Path]::GetFullPath($PackageRoot)
$artifactsPath = [IO.Path]::GetFullPath($ArtifactsPath)

$manifestPath = Join-Path `
    -Path $packageRoot `
    -ChildPath 'protected\read-only-validation-manifest.yaml'

$mergeScriptPath = Join-Path `
    -Path $packageRoot `
    -ChildPath 'launcher\Merge-FactoryConfiguration.ps1'

$initializeOperatorSessionPath = Join-Path `
    -Path $packageRoot `
    -ChildPath 'launcher\Initialize-OperatorSession.ps1'

$invokeReadOnlyValidationPath = Join-Path `
    -Path $packageRoot `
    -ChildPath 'controller\Invoke-ReadOnlyValidation.ps1'

function Get-FactoryObjectValue {
    [CmdletBinding()]
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

function Test-NodeUsesBootstrapConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Node
    )

    $bootstrapConnection = Get-FactoryObjectValue `
        -Object $Node `
        -Name 'bootstrap_connection'

    return ($null -ne $bootstrapConnection)
}

function Get-OperatorCredentialRequirements {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Configuration,

        [Parameter(Mandatory)]
        [ValidateSet(
            'HcnDiscoveryReadiness',
            'HcnComplianceValidation'
        )]
        [string]$ValidationProfile
    )

    $profileRequiresRemoteSession = $ValidationProfile -in @(
        'HcnDiscoveryReadiness',
        'HcnComplianceValidation'
    )

    if (-not $profileRequiresRemoteSession) {
        return [pscustomobject]@{
            RequireAddsCredentials               = $false
            RequireLocalAdministratorCredentials = $false
            HasBootstrapNodes                    = $false
            ConnectionSummary                    = (
                'No remote management session is required for this profile.'
            )
        }
    }

    $nodes = @(
        Get-FactoryObjectValue `
            -Object $Configuration `
            -Name 'nodes'
    )

    if ($nodes.Count -lt 1) {
        throw 'Resolved configuration does not contain any nodes.'
    }

    $bootstrapNodes = @(
        $nodes |
            Where-Object {
                Test-NodeUsesBootstrapConnection -Node $_
            }
    )

    $standardNodes = @(
        $nodes |
            Where-Object {
                -not (Test-NodeUsesBootstrapConnection -Node $_)
            }
    )

    return [pscustomobject]@{
        RequireAddsCredentials               = ($standardNodes.Count -gt 0)
        RequireLocalAdministratorCredentials = ($bootstrapNodes.Count -gt 0)
        HasBootstrapNodes                    = ($bootstrapNodes.Count -gt 0)
        ConnectionSummary                    = (
            'Bootstrap-local nodes: {0}; standard AD DS nodes: {1}.' -f
            $bootstrapNodes.Count,
            $standardNodes.Count
        )
    }
}

function Assert-NonInteractiveCredentialAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$CredentialRequirements
    )

    if ($CredentialRequirements.RequireAddsCredentials) {
        $addsUser = [Environment]::GetEnvironmentVariable(
            'FACTORY_ADDS_ADMIN_USER'
        )

        $addsPassword = [Environment]::GetEnvironmentVariable(
            'FACTORY_ADDS_ADMIN_PASSWORD'
        )

        if (
            [string]::IsNullOrWhiteSpace($addsUser) -or
            [string]::IsNullOrWhiteSpace($addsPassword)
        ) {
            throw (
                'Non-interactive read-only validation requires both ' +
                'FACTORY_ADDS_ADMIN_USER and FACTORY_ADDS_ADMIN_PASSWORD.'
            )
        }
    }

    if ($CredentialRequirements.RequireLocalAdministratorCredentials) {
        $localUser = [Environment]::GetEnvironmentVariable(
            'FACTORY_LOCAL_ADMIN_USER'
        )

        $localPassword = [Environment]::GetEnvironmentVariable(
            'FACTORY_LOCAL_ADMIN_PASSWORD'
        )

        if (
            [string]::IsNullOrWhiteSpace($localUser) -or
            [string]::IsNullOrWhiteSpace($localPassword)
        ) {
            throw (
                'Non-interactive read-only validation requires both ' +
                'FACTORY_LOCAL_ADMIN_USER and FACTORY_LOCAL_ADMIN_PASSWORD.'
            )
        }
    }
}

function Get-WinRmCertificateExceptionAuthorization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Configuration
    )

    $remoteManagement = Get-FactoryObjectValue `
        -Object $Configuration `
        -Name 'remote_management'

    if ($null -eq $remoteManagement) {
        throw 'Resolved configuration does not contain remote_management.'
    }

    $allowTemporaryCertificateException = Get-FactoryObjectValue `
        -Object $remoteManagement `
        -Name 'allow_temporary_certificate_exception'

    return ($allowTemporaryCertificateException -eq $true)
}

function Set-WorkflowWinRmCertificateValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Configuration,

        [Parameter(Mandatory)]
        [pscustomobject]$CredentialRequirements,

        [Parameter(Mandatory)]
        [bool]$IsNonInteractive,

        [Parameter(Mandatory)]
        [bool]$RequestedTemporaryException
    )

    $previousCertificateMode = [Environment]::GetEnvironmentVariable(
        'FACTORY_WINRM_CERTIFICATE_MODE'
    )

    $previousTemporaryApproval = [Environment]::GetEnvironmentVariable(
        'FACTORY_ALLOW_UNTRUSTED_WINRM'
    )

    $state = [pscustomobject]@{
        PreviousCertificateMode = $previousCertificateMode
        PreviousTemporaryApproval = $previousTemporaryApproval
        CertificateValidationMode = 'Strict'
        TemporaryExceptionActive = $false
    }

    if (-not $CredentialRequirements.HasBootstrapNodes) {
        return $state
    }

    $temporaryExceptionAuthorized = `
        Get-WinRmCertificateExceptionAuthorization `
            -Configuration $Configuration

    $useTemporaryException = $false

    if ($RequestedTemporaryException) {
        if (-not $temporaryExceptionAuthorized) {
            throw (
                'The requested temporary WinRM certificate exception is not ' +
                'authorized by protected package configuration.'
            )
        }

        $useTemporaryException = $true
    }
    elseif (-not $IsNonInteractive -and $temporaryExceptionAuthorized) {
        Write-Host ''
        Write-Host (
            'WinRM certificate validation is Strict by default.'
        ) -ForegroundColor Yellow

        Write-Host (
            'The selected bootstrap endpoint may require an approved temporary ' +
            'CA-chain and certificate-revocation exception.'
        ) -ForegroundColor Yellow

        Write-Host (
            'Certificate hostname/CN validation remains enforced.'
        ) -ForegroundColor Yellow

        Write-Host ''

        $confirmation = Read-Host (
            'Type TEMPORARY-CERTIFICATE-EXCEPTION to enable the exception ' +
            'for this run only, or press ENTER to retain Strict validation'
        )

        if ($confirmation -ceq 'TEMPORARY-CERTIFICATE-EXCEPTION') {
            $useTemporaryException = $true
        }
    }

    if ($useTemporaryException) {
        [Environment]::SetEnvironmentVariable(
            'FACTORY_WINRM_CERTIFICATE_MODE',
            'ApprovedTemporaryException',
            'Process'
        )

        [Environment]::SetEnvironmentVariable(
            'FACTORY_ALLOW_UNTRUSTED_WINRM',
            'APPROVED_TEMPORARY_EXCEPTION',
            'Process'
        )

        $state.CertificateValidationMode = `
            'ApprovedTemporaryException'

        $state.TemporaryExceptionActive = $true

        Write-Host (
            'Approved temporary WinRM certificate exception enabled for ' +
            'this read-only validation run only.'
        ) -ForegroundColor Yellow
    }
    else {
        [Environment]::SetEnvironmentVariable(
            'FACTORY_WINRM_CERTIFICATE_MODE',
            'Strict',
            'Process'
        )

        [Environment]::SetEnvironmentVariable(
            'FACTORY_ALLOW_UNTRUSTED_WINRM',
            $null,
            'Process'
        )

        Write-Host (
            'WinRM certificate validation mode: Strict.'
        ) -ForegroundColor Cyan
    }

    return $state
}

function Restore-WorkflowWinRmCertificateValidation {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [pscustomobject]$State
    )

    if ($null -eq $State) {
        return
    }

    [Environment]::SetEnvironmentVariable(
        'FACTORY_WINRM_CERTIFICATE_MODE',
        $State.PreviousCertificateMode,
        'Process'
    )

    [Environment]::SetEnvironmentVariable(
        'FACTORY_ALLOW_UNTRUSTED_WINRM',
        $State.PreviousTemporaryApproval,
        'Process'
    )
}

foreach ($requiredPath in @(
        $manifestPath,
        $mergeScriptPath,
        $initializeOperatorSessionPath,
        $invokeReadOnlyValidationPath
    )) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required factory component was not found: $requiredPath"
    }
}

if (-not (Test-Path -LiteralPath $artifactsPath)) {
    New-Item `
        -ItemType Directory `
        -Path $artifactsPath `
        -Force |
        Out-Null
}

$mergeResult = & $mergeScriptPath `
    -PackageRoot $packageRoot `
    -Site $Site `
    -ArtifactsPath $artifactsPath

if ($null -eq $mergeResult) {
    throw 'Resolved configuration generation did not return a result object.'
}

if (
    [string]::IsNullOrWhiteSpace(
        [string]$mergeResult.ResolvedConfigPath
    )
) {
    throw 'Resolved configuration generation did not return ResolvedConfigPath.'
}

if (
    [string]::IsNullOrWhiteSpace(
        [string]$mergeResult.ResolvedConfigHash
    )
) {
    throw 'Resolved configuration generation did not return ResolvedConfigHash.'
}

if (
    -not (
        Test-Path `
            -LiteralPath $mergeResult.ResolvedConfigPath `
            -PathType Leaf
    )
) {
    throw (
        'Resolved configuration file was not created: ' +
        $mergeResult.ResolvedConfigPath
    )
}

$resolvedConfiguration = Get-Content `
    -LiteralPath $mergeResult.ResolvedConfigPath `
    -Raw |
    ConvertFrom-Yaml `
    -Ordered

if ($resolvedConfiguration -isnot [System.Collections.IDictionary]) {
    throw 'The resolved configuration did not deserialize to a YAML map.'
}

$credentialRequirements = Get-OperatorCredentialRequirements `
    -Configuration $resolvedConfiguration `
    -ValidationProfile $Profile

Write-Host ''
Write-Host 'Read-Only Validation Credential Routing' -ForegroundColor Cyan
Write-Host ("  Site:           {0}" -f $Site)
Write-Host ("  Runner Profile: {0}" -f $RunnerProfile)
Write-Host ("  Profile:        {0}" -f $Profile)
Write-Host ("  {0}" -f $credentialRequirements.ConnectionSummary)
Write-Host ''

if ($credentialRequirements.RequireAddsCredentials) {
    Write-Host '  AD DS credential initialization: required.'
}
else {
    Write-Host '  AD DS credential initialization: not required.'
}

if ($credentialRequirements.RequireLocalAdministratorCredentials) {
    Write-Host '  Bootstrap-local administrator credential initialization: required.'
}
else {
    Write-Host '  Bootstrap-local administrator credential initialization: not required.'
}

Write-Host ''

if ($NonInteractive) {
    Assert-NonInteractiveCredentialAvailability `
        -CredentialRequirements $credentialRequirements
}

$operatorSession = $null
$certificateValidationState = $null

try {
    $certificateValidationState = `
        Set-WorkflowWinRmCertificateValidation `
            -Configuration $resolvedConfiguration `
            -CredentialRequirements $credentialRequirements `
            -IsNonInteractive ([bool]$NonInteractive) `
            -RequestedTemporaryException (
                [bool]$UseApprovedTemporaryWinRmCertificateException
            )

    $operatorSession = & $initializeOperatorSessionPath `
        -RequireAddsCredentials:$credentialRequirements.RequireAddsCredentials `
        -RequireLocalAdministratorCredentials:$credentialRequirements.RequireLocalAdministratorCredentials

    if ($null -eq $operatorSession) {
        throw 'Operator credential initialization did not return a session object.'
    }

    $validationResult = & $invokeReadOnlyValidationPath `
        -Environment $mergeResult.ResolvedConfigPath `
        -ValidationManifestPath $manifestPath `
        -ValidationProfile $Profile `
        -ArtifactsPath $artifactsPath

    if ($null -eq $validationResult) {
        throw 'Read-only validation did not return a result object.'
    }

    return $validationResult
}
finally {
    if (
        $null -ne $operatorSession -and
        $null -ne $operatorSession.Cleanup
    ) {
        & $operatorSession.Cleanup `
            $operatorSession.CreatedEnvironmentVariables
    }

    Restore-WorkflowWinRmCertificateValidation `
        -State $certificateValidationState
}