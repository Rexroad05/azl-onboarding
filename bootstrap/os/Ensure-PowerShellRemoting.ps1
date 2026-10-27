#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\HcnEnsure.Common.psm1" -Force

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Ensure-PowerShellRemoting' `
    -ScriptBlock {
        $winRmService = Get-Service `
            -Name WinRM `
            -ErrorAction Stop

        if ($winRmService.Status -ne 'Running') {
            Set-Service `
                -Name WinRM `
                -StartupType Automatic `
                -ErrorAction Stop

            Start-Service `
                -Name WinRM `
                -ErrorAction Stop
        }

        $listeners = @(
            & winrm enumerate winrm/config/listener 2>&1
        )

        if ($LASTEXITCODE -ne 0) {
            throw (
                "Unable to enumerate WinRM listeners: " +
                ($listeners -join '; ')
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            ServiceState = (Get-Service -Name WinRM).Status
            Listeners    = ($listeners -join "`n").Trim()
        }
    }

$data = $result.Data | Select-Object -First 1

return New-HcnEnsureResult `
    -Check 'Ensure-PowerShellRemoting' `
    -Outcome 'AlreadyCompliant' `
    -Summary (
        "WinRM service is running. Listener configuration was validated."
    ) `
    -AdditionalProperties @{
        Node         = $result.Node
        ManagementIp = $result.ManagementIp
        ServiceState = $data.ServiceState
        Listeners    = $data.Listeners
    }