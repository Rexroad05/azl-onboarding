#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\HcnEnsure.Common.psm1" -Force

$security = Get-HcnEnsureValue `
    -Object $Context.Config `
    -Name 'security'

$rdp = Get-HcnEnsureValue `
    -Object $security `
    -Name 'rdp'

if ($null -eq $rdp) {
    throw 'security.rdp configuration is required.'
}

$rdpEnabled = (
    Get-HcnEnsureValue `
        -Object $rdp `
        -Name 'enabled'
) -eq $true

$rdpPort = Get-HcnEnsureValue `
    -Object $rdp `
    -Name 'port'

if ($null -eq $rdpPort) {
    $rdpPort = 3389
}

$requireNla = (
    Get-HcnEnsureValue `
        -Object $rdp `
        -Name 'require_nla'
)

if ($null -eq $requireNla) {
    $requireNla = $true
}

if (-not $rdpEnabled) {
    return New-HcnEnsureResult `
        -Check 'Ensure-RemoteDesktop' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            'Remote Desktop desired state is disabled by protected configuration.'
        ) `
        -AdditionalProperties @{
            Node         = $Context.Node.name
            ManagementIp = $Context.Node.management.ip
            RdpEnabled   = $false
            Port         = [int]$rdpPort
            RequireNla   = [bool]$requireNla
        }
}

if ([int]$rdpPort -ne 3389) {
    throw (
        'Ensure-RemoteDesktop currently supports the approved legacy RDP port 3389 only.'
    )
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Ensure-RemoteDesktop' `
    -ArgumentList @(
        [bool]$requireNla,
        [int]$rdpPort
    ) `
    -ScriptBlock {
        param(
            [bool]$RequireNla,
            [int]$RdpPort
        )

        $changes = [System.Collections.Generic.List[string]]::new()

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
            Set-ItemProperty `
                -Path $terminalServerPath `
                -Name 'fDenyTSConnections' `
                -Value 0 `
                -ErrorAction Stop

            $changes.Add(
                'Enabled Remote Desktop connections.'
            )
        }

        $nlaValue = Get-ItemPropertyValue `
            -Path $rdpTcpPath `
            -Name 'UserAuthentication' `
            -ErrorAction Stop

        $desiredNlaValue = if ($RequireNla) {
            1
        }
        else {
            0
        }

        if ([int]$nlaValue -ne $desiredNlaValue) {
            Set-ItemProperty `
                -Path $rdpTcpPath `
                -Name 'UserAuthentication' `
                -Value $desiredNlaValue `
                -ErrorAction Stop

            if ($RequireNla) {
                $changes.Add(
                    'Required Network Level Authentication for Remote Desktop.'
                )
            }
            else {
                $changes.Add(
                    'Disabled Network Level Authentication according to configuration.'
                )
            }
        }

        $terminalService = Get-CimInstance `
            -ClassName Win32_Service `
            -Filter "Name='TermService'" `
            -ErrorAction Stop

        if ($terminalService.StartMode -ne 'Auto') {
            Set-Service `
                -Name 'TermService' `
                -StartupType Automatic `
                -ErrorAction Stop

            $changes.Add(
                'Set Remote Desktop Services startup type to Automatic.'
            )
        }

        $service = Get-Service `
            -Name 'TermService' `
            -ErrorAction Stop

        if ($service.Status -ne 'Running') {
            Start-Service `
                -Name 'TermService' `
                -ErrorAction Stop

            $changes.Add(
                'Started Remote Desktop Services.'
            )
        }

        $rdpFirewallRules = @(
            Get-NetFirewallRule `
                -DisplayGroup 'Remote Desktop' `
                -ErrorAction Stop
        )

        if ($rdpFirewallRules.Count -lt 1) {
            throw (
                'No Windows Defender Firewall rules were found in the Remote Desktop display group.'
            )
        }

        $disabledRules = @(
            $rdpFirewallRules |
                Where-Object {
                    [string]$_.Enabled -ne 'True'
                }
        )

        if ($disabledRules.Count -gt 0) {
            Enable-NetFirewallRule `
                -DisplayGroup 'Remote Desktop' `
                -ErrorAction Stop

            $changes.Add(
                "Enabled $($disabledRules.Count) Remote Desktop firewall rule(s)."
            )
        }

        $listener = $null

        for ($attempt = 1; $attempt -le 15; $attempt++) {
            $listener = @(
                Get-NetTCPConnection `
                    -LocalPort $RdpPort `
                    -State Listen `
                    -ErrorAction SilentlyContinue
            ) |
                Select-Object `
                    -First 1

            if ($null -ne $listener) {
                break
            }

            Start-Sleep `
                -Seconds 1
        }

        if ($null -eq $listener) {
            throw (
                "Remote Desktop Services is not listening on TCP port $RdpPort."
            )
        }

        $finalRdpEnabledValue = Get-ItemPropertyValue `
            -Path $terminalServerPath `
            -Name 'fDenyTSConnections' `
            -ErrorAction Stop

        $finalNlaValue = Get-ItemPropertyValue `
            -Path $rdpTcpPath `
            -Name 'UserAuthentication' `
            -ErrorAction Stop

        $finalService = Get-Service `
            -Name 'TermService' `
            -ErrorAction Stop

        $finalServiceConfig = Get-CimInstance `
            -ClassName Win32_Service `
            -Filter "Name='TermService'" `
            -ErrorAction Stop

        $finalFirewallRules = @(
            Get-NetFirewallRule `
                -DisplayGroup 'Remote Desktop' `
                -ErrorAction Stop |
                Select-Object `
                    DisplayName,
                    Enabled,
                    Profile,
                    Direction,
                    Action
        )

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Changed      = ($changes.Count -gt 0)
            Changes      = $changes.ToArray()
            RdpEnabled   = ([int]$finalRdpEnabledValue -eq 0)
            RequireNla   = ([int]$finalNlaValue -eq 1)
            ServiceState = [string]$finalService.Status
            ServiceStartMode = [string]$finalServiceConfig.StartMode
            ListenerPort = [int]$listener.LocalPort
            FirewallRules = $finalFirewallRules
        }
    }

$data = @($result.Data) |
    Select-Object `
        -First 1

$outcome = if ($data.Changed) {
    'Changed'
}
else {
    'AlreadyCompliant'
}

$summary = if ($data.Changed) {
    (
        'Remote Desktop desired state was enforced: ' +
        ($data.Changes -join ' ')
    )
}
else {
    (
        'Remote Desktop is enabled, Network Level Authentication is required, ' +
        'Remote Desktop Services is running, TCP 3389 is listening, and the ' +
        'built-in Remote Desktop firewall rules are enabled.'
    )
}

return New-HcnEnsureResult `
    -Check 'Ensure-RemoteDesktop' `
    -Outcome $outcome `
    -Changed ([bool]$data.Changed) `
    -Summary $summary `
    -AdditionalProperties @{
        Node             = $result.Node
        ManagementIp     = $result.ManagementIp
        RdpEnabled       = $data.RdpEnabled
        RequireNla       = $data.RequireNla
        ServiceState     = $data.ServiceState
        ServiceStartMode = $data.ServiceStartMode
        ListenerPort     = $data.ListenerPort
        FirewallRules    = $data.FirewallRules
        Changes          = $data.Changes
    }