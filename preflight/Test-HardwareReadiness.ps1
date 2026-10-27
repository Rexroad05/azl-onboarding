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
    -OperationName 'Test-HardwareReadiness' `
    -ScriptBlock {
        $computerSystem = Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop

        $processors = @(
            Get-CimInstance `
                -ClassName Win32_Processor `
                -ErrorAction Stop
        )

        $memory = @(
            Get-CimInstance `
                -ClassName Win32_PhysicalMemory `
                -ErrorAction Stop
        )

        $physicalDisks = @(
            Get-PhysicalDisk -ErrorAction Stop
        )

        if ($processors.Count -lt 1) {
            throw 'No processors were detected.'
        }

        if ($memory.Count -lt 1) {
            throw 'No physical memory modules were detected.'
        }

        if ($physicalDisks.Count -lt 1) {
            throw 'No physical disks were detected.'
        }

        [pscustomobject]@{
            ComputerName      = $env:COMPUTERNAME
            Manufacturer      = $computerSystem.Manufacturer
            Model             = $computerSystem.Model
            ProcessorCount    = $processors.Count
            TotalMemoryBytes  = [int64]$computerSystem.TotalPhysicalMemory
            PhysicalDiskCount = $physicalDisks.Count
            DiskHealth        = @(
                $physicalDisks |
                    Select-Object FriendlyName, HealthStatus, OperationalStatus
            )
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed            = $true
    Check             = 'Test-HardwareReadiness'
    Node              = $result.Node
    ManagementIp      = $result.ManagementIp
    Manufacturer      = $data.Manufacturer
    Model             = $data.Model
    ProcessorCount    = $data.ProcessorCount
    TotalMemoryBytes  = $data.TotalMemoryBytes
    PhysicalDiskCount = $data.PhysicalDiskCount
    DiskHealth        = $data.DiskHealth
    ValidatedAt       = [datetime]::UtcNow.ToString('o')
}