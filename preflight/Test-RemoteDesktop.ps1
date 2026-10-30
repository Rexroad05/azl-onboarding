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
    throw 'Test-RemoteDesktop requires a node-scoped Context.Node.'
}

$security = Get-ManagementPlaneValue `
    -Object $Context.Config `
    -Name 'security'

$rdp = Get-ManagementPlaneValue `
    -Object $security `
    -Name 'rdp'

if ($null -eq $rdp) {
    throw 'security.rdp configuration is required.'
}

$rdpEnabled = (
    Get-ManagementPlaneValue `
        -Object $rdp `
        -Name 'enabled'
) -eq $true

$rdpPort = Get-ManagementPlaneValue `
    -Object $rdp `
    -Name 'port'

if ($null -eq $rdpPort) {
    $rdpPort = 3389
}

$requireNla = Get-ManagementPlaneValue `
    -Object $rdp `
    -Name 'require_nla'

if ($null -eq $requireNla) {
    $requireNla = $true
}

$requireExecutionHostConnectivity = Get-ManagementPlaneValue `
    -Object $rdp `
    -Name 'require_execution_host_connectivity_validation'

if ($null -eq $requireExecutionHostConnectivity) {
    $requireExecutionHostConnectivity = $true
}

if (-not $rdpEnabled) {
    return [pscustomobject]@{
        Passed       = $true
        Check        = 'Test-RemoteDesktop'
        Node         = $Context.Node.name
        ManagementIp = $Context.Node.management.ip
        Outcome      = 'Skipped'
        Changed      = $false
        Summary      = (
            'Remote Desktop validation is skipped because protected configuration disables RDP.'
        )
        ValidatedAt  = [datetime]::UtcNow.ToString('o')
    }
}

if ([int]$rdpPort -ne 3389) {
    throw (
        'Test-RemoteDesktop currently supports the approved legacy RDP port 3389 only.'
    )
}

$settings = Get-ManagementPlaneSettings `
    -Context $Context

$target = Get-ManagementPlaneTarget `
    -Context $Context

$connection = $null
$tcpClient = [System.Net.Sockets.TcpClient]::new()

try {
    $connection = New-ManagementPlaneSession `
        -Context $Context

    $remoteState = Invoke-Command `
        -Session $connection.Session `
        -ErrorAction Stop `
        -ArgumentList @(
            [bool]$requireNla,
            [int]$rdpPort
        ) `
        -ScriptBlock {
            param(
                [bool]$RequireNla,
                [int]$RdpPort
            )

            $terminalServerPath = (
                'HKLM:\System\CurrentControlSet\Control\Terminal Server'
            )

            $rdpTcpPath = (
                'HKLM:\System\CurrentControlSet\Control\Terminal Server\' +
                'WinStations\RDP-Tcp'
            )

            $rdpEnabledValue = Get-ItemPropertyValue `
                -Path $terminalServerPath `
                -Name 'fDenyTSConnections' `
                -ErrorAction Stop

            if ([int]$rdpEnabledValue -ne 0) {
                throw 'Remote Desktop is disabled by fDenyTSConnections.'
            }

            $nlaValue = Get-ItemPropertyValue `
                -Path $rdpTcpPath `
                -Name 'UserAuthentication' `
                -ErrorAction Stop

            $actualNla = ([int]$nlaValue -eq 1)

            if ($RequireNla -and -not $actualNla) {
                throw 'Remote Desktop Network Level Authentication is not enabled.'
            }

            $service = Get-Service `
                -Name 'TermService' `
                -ErrorAction Stop

            if ($service.Status -ne 'Running') {
                throw (
                    "Remote Desktop Services is $($service.Status); expected Running."
                )
            }

            $serviceConfig = Get-CimInstance `
                -ClassName Win32_Service `
                -Filter "Name='TermService'" `
                -ErrorAction Stop

            if ($serviceConfig.StartMode -ne 'Auto') {
                throw (
                    "Remote Desktop Services startup mode is $($serviceConfig.StartMode); expected Auto."
                )
            }

            $firewallRules = @(
                Get-NetFirewallRule `
                    -DisplayGroup 'Remote Desktop' `
                    -ErrorAction Stop
            )

            if ($firewallRules.Count -lt 1) {
                throw (
                    'No Windows Defender Firewall rules were found in the Remote Desktop display group.'
                )
            }

            $disabledFirewallRules = @(
                $firewallRules |
                    Where-Object {
                        [string]$_.Enabled -ne 'True'
                    }
            )

            if ($disabledFirewallRules.Count -gt 0) {
                throw (
                    "Remote Desktop firewall group contains $($disabledFirewallRules.Count) disabled rule(s)."
                )
            }

            $listener = @(
                Get-NetTCPConnection `
                    -LocalPort $RdpPort `
                    -State Listen `
                    -ErrorAction SilentlyContinue
            ) |
                Select-Object `
                    -First 1

            if ($null -eq $listener) {
                throw (
                    "Remote Desktop Services is not listening on TCP port $RdpPort."
                )
            }

            [pscustomobject]@{
                ComputerName      = $env:COMPUTERNAME
                RdpEnabled        = $true
                RequireNla        = $actualNla
                ServiceState      = [string]$service.Status
                ServiceStartMode  = [string]$serviceConfig.StartMode
                ListenerPort      = [int]$listener.LocalPort
                FirewallRuleCount = $firewallRules.Count
                FirewallRules     = @(
                    $firewallRules |
                        Select-Object `
                            DisplayName,
                            Enabled,
                            Profile,
                            Direction,
                            Action
                )
            }
        }

    $tcpReachable = $null

    if ($requireExecutionHostConnectivity) {
        Write-Host (
            "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
            "$($target.NodeName) | Testing RDP TCP connectivity on " +
            "$($target.ConnectionHost):$rdpPort"
        ) -ForegroundColor DarkCyan

        $connectTask = $tcpClient.ConnectAsync(
            $target.ConnectionHost,
            [int]$rdpPort
        )

        if (
            -not $connectTask.Wait(
                $settings.ConnectionTimeoutSecond * 1000
            )
        ) {
            throw (
                "$($target.NodeName) | TCP connection to RDP endpoint " +
                "$($target.ConnectionHost):$rdpPort timed out after " +
                "$($settings.ConnectionTimeoutSecond) seconds."
            )
        }

        if (-not $tcpClient.Connected) {
            throw (
                "$($target.NodeName) | Unable to establish TCP connectivity to " +
                "RDP endpoint $($target.ConnectionHost):$rdpPort."
            )
        }

        $tcpReachable = $true
    }

    return [pscustomobject]@{
        Passed                    = $true
        Check                     = 'Test-RemoteDesktop'
        Node                      = $target.NodeName
        ManagementIp              = $target.ManagementIp
        RemoteConnectionHost      = $target.ConnectionHost
        Port                      = [int]$rdpPort
        RdpEnabled                = $remoteState.RdpEnabled
        RequireNla                = $remoteState.RequireNla
        ServiceState              = $remoteState.ServiceState
        ServiceStartMode          = $remoteState.ServiceStartMode
        ListenerPort              = $remoteState.ListenerPort
        FirewallRuleCount         = $remoteState.FirewallRuleCount
        FirewallRules             = $remoteState.FirewallRules
        ExecutionHostTcpReachable = $tcpReachable
        Summary                   = (
            "Remote Desktop is enabled with NLA=$($remoteState.RequireNla), " +
            "TermService=$($remoteState.ServiceState), TCP $rdpPort listening, " +
            "and $($remoteState.FirewallRuleCount) Remote Desktop firewall rule(s) enabled."
        )
        ValidatedAt               = [datetime]::UtcNow.ToString('o')
    }
}
catch {
    throw (
        "$($target.NodeName) | Remote Desktop validation failed for " +
        "$($target.ConnectionHost):$rdpPort. " +
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