#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

if (-not $Context.ContainsKey('Node')) {
    throw 'Test-WinRMCertificateTrust requires a node-scoped Context.Node.'
}

$settings = Get-ManagementPlaneSettings -Context $Context
$target = Get-ManagementPlaneTarget -Context $Context
$connection = $null

try {
    Write-Host (
        "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
        "$($target.NodeName) | Validating WinRM HTTPS certificate trust for " +
        "$($target.ConnectionHost):$($target.ConnectionPort)."
    ) -ForegroundColor DarkCyan

    $connection = New-ManagementPlaneSession -Context $Context

    $remoteIdentity = Invoke-Command `
        -Session $connection.Session `
        -ErrorAction Stop `
        -ScriptBlock {
            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            }
        }

    $temporaryExceptionActive = (
        $connection.Settings.CertificateValidationMode -eq
        'ApprovedTemporaryException'
    )

    $summary = if ($temporaryExceptionActive) {
        (
            "WinRM HTTPS PSSession established to " +
            "$($target.ConnectionHost):$($target.ConnectionPort) with an approved " +
            'temporary CA-chain and revocation exception. ' +
            'Certificate hostname/CN validation remains enforced.'
        )
    }
    else {
        (
            "WinRM HTTPS PSSession established to " +
            "$($target.ConnectionHost):$($target.ConnectionPort) with strict " +
            'certificate validation and certificate hostname/CN validation enforced.'
        )
    }

    Write-Host (
        "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
        "$($target.NodeName) | WinRM HTTPS certificate trust validation passed."
    ) -ForegroundColor Green

    return [pscustomobject]@{
        Passed                               = $true
        Check                                = 'Test-WinRMCertificateTrust'
        Node                                 = $target.NodeName
        ManagementIp                         = $target.ManagementIp
        RemoteConnectionHost                 = $target.ConnectionHost
        ConnectionPort                       = $target.ConnectionPort
        ConnectionMode                       = $target.ConnectionMode
        AuthenticationMode                   = $target.AuthenticationMode
        CertificateValidationMode            = $connection.Settings.CertificateValidationMode
        TemporaryExceptionActive             = $temporaryExceptionActive
        CertificateHostnameValidationEnforced = $true
        RemoteComputerName                   = $remoteIdentity.ComputerName
        RemoteUserName                       = $remoteIdentity.UserName
        Summary                              = $summary
        ValidatedAt                          = [datetime]::UtcNow.ToString('o')
    }
}
catch {
    throw (
        "$($target.NodeName) | WinRM HTTPS certificate trust validation failed " +
        "for $($target.ConnectionHost):$($target.ConnectionPort). " +
        "$($_.Exception.Message)"
    )
}
finally {
    if (
        $null -ne $connection -and
        $null -ne $connection.Session
    ) {
        Remove-PSSession `
            -Session $connection.Session `
            -ErrorAction SilentlyContinue
    }
}