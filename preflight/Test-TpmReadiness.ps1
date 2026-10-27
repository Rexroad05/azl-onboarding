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
    -OperationName 'Test-TpmReadiness' `
    -ScriptBlock {
        $tpm = Get-Tpm -ErrorAction Stop

        if (-not $tpm.TpmPresent) {
            throw 'TPM is not present.'
        }

        if (-not $tpm.TpmReady) {
            throw 'TPM is present but not ready.'
        }

        [pscustomobject]@{
            ComputerName  = $env:COMPUTERNAME
            TpmPresent    = $tpm.TpmPresent
            TpmReady      = $tpm.TpmReady
            TpmEnabled    = $tpm.TpmEnabled
            TpmActivated  = $tpm.TpmActivated
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-TpmReadiness'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    TpmPresent   = $data.TpmPresent
    TpmReady     = $data.TpmReady
    TpmEnabled   = $data.TpmEnabled
    TpmActivated = $data.TpmActivated
    Summary      = 'TPM is present and ready.'
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}