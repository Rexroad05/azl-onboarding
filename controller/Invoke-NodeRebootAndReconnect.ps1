#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context,

    [Parameter(Mandatory)]
    [object]$RebootRequest,

    [ValidateRange(60, 3600)]
    [int]$ReconnectTimeoutSeconds = 900,

    [ValidateRange(1, 60)]
    [int]$RetryIntervalSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\preflight\ManagementPlane.Common.psm1" -Force

function Get-RebootValue {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

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

$nodeName = [string](Get-RebootValue -Object $RebootRequest -Name 'Node')

if ([string]::IsNullOrWhiteSpace($nodeName)) {
    throw 'Pending reboot request does not contain a Node value.'
}

$node = @(
    $Context.Config.nodes |
        Where-Object {
            [string]$_.name -eq $nodeName
        }
) | Select-Object -First 1

if ($null -eq $node) {
    throw "Pending reboot target node does not exist in resolved configuration: $nodeName"
}

$nodeContext = @{}

foreach ($key in $Context.Keys) {
    $nodeContext[$key] = $Context[$key]
}

$nodeContext.Node = $node
$nodeContext.NodeState = $Context.State.nodes[$nodeName]

$reconnectTarget = [string](
    Get-RebootValue `
        -Object $RebootRequest `
        -Name 'ReconnectTarget'
)

if ([string]::IsNullOrWhiteSpace($reconnectTarget)) {
    $reconnectTarget = [string]$node.name
}

$rebootReason = [string](
    Get-RebootValue `
        -Object $RebootRequest `
        -Name 'Reason'
)

if ([string]::IsNullOrWhiteSpace($rebootReason)) {
    $rebootReason = 'Approved Azure Local workflow reboot.'
}

Write-Host (
    "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
    "$nodeName | Requesting approved reboot."
) -ForegroundColor Yellow

$shutdownResponse = Invoke-ManagementPlaneCommand `
    -Context $nodeContext `
    -OperationName 'Invoke-ApprovedNodeReboot' `
    -ScriptBlock {
        param($Reason)

        $arguments = @(
            '/r',
            '/t', '5',
            '/f',
            '/c', $Reason
        )

        $process = Start-Process `
            -FilePath "$env:SystemRoot\System32\shutdown.exe" `
            -ArgumentList $arguments `
            -WindowStyle Hidden `
            -PassThru `
            -ErrorAction Stop

        [pscustomobject]@{
            Requested = $true
            ProcessId = $process.Id
            RequestedAtUtc = [datetime]::UtcNow.ToString('o')
        }
    } `
    -ArgumentList @($rebootReason)

$shutdownResult = @($shutdownResponse.Data) |
    Select-Object -First 1

$deadline = (Get-Date).ToUniversalTime().
    AddSeconds($ReconnectTimeoutSeconds)

$firstAttempt = $true
$lastError = $null

while ((Get-Date).ToUniversalTime() -lt $deadline) {
    Start-Sleep -Seconds $RetryIntervalSeconds

    try {
        $connection = New-ManagementPlaneSession `
            -Context $nodeContext

        try {
            $verification = Invoke-Command `
                -Session $connection.Session `
                -ScriptBlock {
                    [pscustomobject]@{
                        ComputerName = $env:COMPUTERNAME
                        BootTime = (
                            Get-CimInstance Win32_OperatingSystem
                        ).LastBootUpTime
                    }
                } `
                -ErrorAction Stop

            if ($firstAttempt) {
                Write-Host (
                    "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
                    "$nodeName | WinRM reconnect succeeded."
                ) -ForegroundColor Green
            }

            return [pscustomobject]@{
                Passed          = $true
                Node            = $nodeName
                ReconnectTarget = $reconnectTarget
                ShutdownResult  = $shutdownResult
                Verification    = $verification
                ReconnectedAt   = [datetime]::UtcNow.ToString('o')
            }
        }
        finally {
            Remove-PSSession `
                -Session $connection.Session `
                -ErrorAction SilentlyContinue
        }
    }
    catch {
        $firstAttempt = $false
        $lastError = $_.Exception.Message

        Write-Host (
            "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
            "$nodeName | Waiting for reboot/reconnect."
        ) -ForegroundColor DarkYellow
    }
}

throw (
    "$nodeName did not reconnect through WinRM within " +
    "$ReconnectTimeoutSeconds seconds. Last error: $lastError"
)