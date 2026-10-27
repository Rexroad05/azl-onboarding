#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-SecureBoot' `
    -ScriptBlock {
        try {
            $secureBootEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
        }
        catch {
            throw (
                'Secure Boot could not be queried. The node may not be booted ' +
                "with UEFI Secure Boot. $($_.Exception.Message)"
            )
        }

        if ($secureBootEnabled -ne $true) {
            throw 'Secure Boot is not enabled.'
        }

        [pscustomobject]@{
            ComputerName      = $env:COMPUTERNAME
            SecureBootEnabled = $secureBootEnabled
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed            = $true
    Check             = 'Test-SecureBoot'
    Node              = $result.Node
    ManagementIp      = $result.ManagementIp
    SecureBootEnabled = $data.SecureBootEnabled
    Summary           = 'Secure Boot is enabled.'
    ValidatedAt       = [datetime]::UtcNow.ToString('o')
}