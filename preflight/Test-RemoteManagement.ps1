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
    throw 'Test-RemoteManagement requires a node-scoped Context.Node.'
}

$settings = Get-ManagementPlaneSettings -Context $Context
$target = Get-ManagementPlaneTarget -Context $Context

Write-Host (
    "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
    "$($target.NodeName) | Testing WinRM HTTPS TCP connectivity on " +
    "$($target.ConnectionHost):$($target.ConnectionPort)"
) -ForegroundColor DarkCyan

$tcpClient = [System.Net.Sockets.TcpClient]::new()
$connection = $null

try {
    $connectTask = $tcpClient.ConnectAsync(
        $target.ConnectionHost,
        $target.ConnectionPort
    )

    if (
        -not $connectTask.Wait(
            $settings.ConnectionTimeoutSecond * 1000
        )
    ) {
        throw (
            "$($target.NodeName) | TCP connection to WinRM HTTPS " +
            "$($target.ConnectionHost):$($target.ConnectionPort) timed out after " +
            "$($settings.ConnectionTimeoutSecond) seconds."
        )
    }

    if (-not $tcpClient.Connected) {
        throw (
            "$($target.NodeName) | Unable to establish TCP connectivity to " +
            "$($target.ConnectionHost):$($target.ConnectionPort)."
        )
    }

    Write-Host (
        "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
        "$($target.NodeName) | TCP connectivity established; opening PSSession " +
        "to $($target.ConnectionHost)."
    ) -ForegroundColor DarkCyan

    $connection = New-ManagementPlaneSession -Context $Context

    $remoteIdentity = Invoke-Command `
        -Session $connection.Session `
        -ErrorAction Stop `
        -ScriptBlock {
            $operatingSystem = Get-CimInstance `
                -ClassName Win32_OperatingSystem `
                -ErrorAction Stop

            $computerSystem = Get-CimInstance `
                -ClassName Win32_ComputerSystem `
                -ErrorAction Stop

            [pscustomobject]@{
                ComputerName    = $env:COMPUTERNAME
                UserName        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                PowerShell      = $PSVersionTable.PSVersion.ToString()
                OperatingSystem = $operatingSystem.Caption
                OSVersion       = $operatingSystem.Version
                Domain          = $computerSystem.Domain
                PartOfDomain    = $computerSystem.PartOfDomain
            }
        }

    Write-Host (
        "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
        "$($target.NodeName) | PSSession established successfully."
    ) -ForegroundColor Green

    return [pscustomobject]@{
        Passed                    = $true
        Check                     = 'Test-RemoteManagement'
        Node                      = $target.NodeName
        ManagementIp              = $target.ManagementIp
        RemoteConnectionHost      = $target.ConnectionHost
        ConnectionPort            = $target.ConnectionPort
        ConnectionMode            = $target.ConnectionMode
        AuthenticationMode        = $target.AuthenticationMode
        CertificateValidationMode = $connection.Settings.CertificateValidationMode
        RemoteComputerName        = $remoteIdentity.ComputerName
        RemoteUserName            = $remoteIdentity.UserName
        RemotePowerShellVersion   = $remoteIdentity.PowerShell
        RemoteOperatingSystem     = $remoteIdentity.OperatingSystem
        RemoteOSVersion           = $remoteIdentity.OSVersion
        RemoteDomain              = $remoteIdentity.Domain
        RemotePartOfDomain        = $remoteIdentity.PartOfDomain
        Summary                   = (
            "WinRM HTTPS PSSession established to " +
            "$($target.ConnectionHost):$($target.ConnectionPort) using " +
            "$($target.AuthenticationMode) authentication."
        )
        ValidatedAt               = [datetime]::UtcNow.ToString('o')
    }
}
catch {
    throw (
        "$($target.NodeName) | WinRM/PSSession validation failed for " +
        "$($target.ConnectionHost):$($target.ConnectionPort). " +
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

    $tcpClient.Dispose()
}