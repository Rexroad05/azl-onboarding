#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\HcnEnsure.Common.psm1" -Force

$desiredNtpServers = @($Context.Config.ntp.servers)

if ($desiredNtpServers.Count -lt 1) {
    throw 'ntp.servers must contain at least one NTP server.'
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Ensure-NTP' `
    -ArgumentList @($desiredNtpServers) `
    -ScriptBlock {
        param(
            [string[]]$DesiredNtpServers
        )

        $desiredPeerList = $DesiredNtpServers -join ' '

        $peerOutput = @(
            & w32tm /query /peers 2>&1
        )

        $peerQueryExitCode = $LASTEXITCODE
        $peerText = ($peerOutput -join "`n").Trim()

        $alreadyConfigured = $true

        foreach ($desiredServer in $DesiredNtpServers) {
            if ($peerText -notmatch [regex]::Escape($desiredServer)) {
                $alreadyConfigured = $false
                break
            }
        }

        $changed = $false

        if (-not $alreadyConfigured -or $peerQueryExitCode -ne 0) {
            $configOutput = @(
                & w32tm `
                    /config `
                    "/manualpeerlist:$desiredPeerList" `
                    /syncfromflags:manual `
                    /update 2>&1
            )

            if ($LASTEXITCODE -ne 0) {
                throw (
                    "w32tm configuration failed: " +
                    ($configOutput -join '; ')
                )
            }

            $resyncOutput = @(
                & w32tm /resync /force 2>&1
            )

            if ($LASTEXITCODE -ne 0) {
                throw (
                    "w32tm resync failed: " +
                    ($resyncOutput -join '; ')
                )
            }

            $changed = $true
        }

        $finalPeers = @(
            & w32tm /query /peers 2>&1
        )

        if ($LASTEXITCODE -ne 0) {
            throw (
                "w32tm peer query failed after configuration: " +
                ($finalPeers -join '; ')
            )
        }

        $finalPeerText = ($finalPeers -join "`n").Trim()

        foreach ($desiredServer in $DesiredNtpServers) {
            if ($finalPeerText -notmatch [regex]::Escape($desiredServer)) {
                throw (
                    "Configured NTP peers do not include required source " +
                    "$desiredServer. Current peers: $finalPeerText"
                )
            }
        }

        $sourceOutput = @(
            & w32tm /query /source 2>&1
        )

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Changed      = $changed
            Peers        = $finalPeerText
            Source       = ($sourceOutput -join "`n").Trim()
        }
    }

$data = $result.Data | Select-Object -First 1

if ($data.Changed) {
    return New-HcnEnsureResult `
        -Check 'Ensure-NTP' `
        -Outcome 'Changed' `
        -Changed $true `
        -Summary (
            "NTP peers configured to $($desiredNtpServers -join ', ') and revalidated."
        ) `
        -AdditionalProperties @{
            Node         = $result.Node
            ManagementIp = $result.ManagementIp
            Source       = $data.Source
            Peers        = $data.Peers
        }
}

return New-HcnEnsureResult `
    -Check 'Ensure-NTP' `
    -Outcome 'AlreadyCompliant' `
    -Summary (
        "NTP peers already include $($desiredNtpServers -join ', ')."
    ) `
    -AdditionalProperties @{
        Node         = $result.Node
        ManagementIp = $result.ManagementIp
        Source       = $data.Source
        Peers        = $data.Peers
    }