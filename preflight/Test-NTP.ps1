#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

function Get-NtpConfigurationValue {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-ManagementPlaneValue `
        -Object $Object `
        -Name $Name
}

$ntp = Get-NtpConfigurationValue `
    -Object $Context.Config `
    -Name 'ntp'

if ($null -eq $ntp) {
    throw 'ntp configuration is required.'
}

$expectedNtpServers = [string[]]@(
    @(
        Get-NtpConfigurationValue `
            -Object $ntp `
            -Name 'servers'
    ) |
        ForEach-Object {
            [string]$_
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
)

if ($expectedNtpServers.Count -lt 1) {
    throw 'ntp.servers must contain at least one approved NTP server.'
}

$maximumOffsetSeconds = Get-NtpConfigurationValue `
    -Object $ntp `
    -Name 'maximum_offset_seconds'

if ($null -eq $maximumOffsetSeconds) {
    $maximumOffsetSeconds = 60
}

$maximumSyncAgeMinutes = Get-NtpConfigurationValue `
    -Object $ntp `
    -Name 'maximum_sync_age_minutes'

if ($null -eq $maximumSyncAgeMinutes) {
    $maximumSyncAgeMinutes = 60
}

if ([decimal]$maximumOffsetSeconds -le 0) {
    throw 'ntp.maximum_offset_seconds must be greater than zero.'
}

if ([int]$maximumSyncAgeMinutes -le 0) {
    throw 'ntp.maximum_sync_age_minutes must be greater than zero.'
}

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-NTP' `
    -ArgumentList @(
        [string[]]$expectedNtpServers,
        [decimal]$maximumOffsetSeconds,
        [int]$maximumSyncAgeMinutes
    ) `
    -ScriptBlock {
        param(
            [string[]]$ExpectedNtpServers,
            [decimal]$MaximumOffsetSeconds,
            [int]$MaximumSyncAgeMinutes
        )

        function Get-NormalizedNtpHost {
            param(
                [AllowNull()]
                [string]$Value
            )

            if ([string]::IsNullOrWhiteSpace($Value)) {
                return ''
            }

            $normalized = $Value.Trim()

            $normalized = $normalized -replace `
                '(?i)^source\s*:\s*',
                ''

            $normalized = $normalized -replace `
                '(?i)^peer\s*:\s*',
                ''

            $normalized = $normalized.Split(
                @(
                    ',',
                    ' ',
                    '[',
                    ']'
                ),
                [System.StringSplitOptions]::RemoveEmptyEntries
            ) |
                Select-Object -First 1

            return [string]$normalized
        }

        function Invoke-W32TmQuery {
            param(
                [Parameter(Mandatory)]
                [string[]]$Arguments,

                [Parameter(Mandatory)]
                [string]$OperationName
            )

            $output = @(
                & w32tm @Arguments 2>&1
            )

            if ($LASTEXITCODE -ne 0) {
                throw (
                    "w32tm $OperationName failed: " +
                    ($output -join '; ')
                )
            }

            return ($output -join "`n").Trim()
        }

        $statusText = Invoke-W32TmQuery `
            -Arguments @('/query', '/status') `
            -OperationName '/query /status'

        $sourceText = Invoke-W32TmQuery `
            -Arguments @('/query', '/source') `
            -OperationName '/query /source'

        $peerText = Invoke-W32TmQuery `
            -Arguments @('/query', '/peers') `
            -OperationName '/query /peers'

        if (
            $statusText -match
            '(?im)^\s*Leap Indicator:\s*3'
        ) {
            throw (
                'Windows Time reports Leap Indicator 3, indicating that the node is not synchronized.'
            )
        }

        $sourceHost = Get-NormalizedNtpHost `
            -Value $sourceText

        if (
            [string]::IsNullOrWhiteSpace($sourceHost) -or
            $sourceHost -match '(?i)local\s+cmos\s+clock' -or
            $sourceHost -match '(?i)free-running\s+system\s+clock' -or
            $sourceHost -match '(?i)unspecified'
        ) {
            throw (
                "Windows Time source is not an approved synchronized source: $sourceText"
            )
        }

        $normalizedExpectedServers = [string[]]@(
            foreach ($expectedServer in $ExpectedNtpServers) {
                $normalizedExpectedServer = Get-NormalizedNtpHost `
                    -Value $expectedServer

                if (
                    -not [string]::IsNullOrWhiteSpace(
                        $normalizedExpectedServer
                    )
                ) {
                    $normalizedExpectedServer
                }
            }
        )

        $sourceMatchesExpectedServer = @(
            $normalizedExpectedServers |
                Where-Object {
                    $sourceHost -ieq $_ -or
                    $sourceHost -like "*$_*" -or
                    $_ -like "*$sourceHost*"
                }
        ).Count -gt 0

        if (-not $sourceMatchesExpectedServer) {
            throw (
                "Windows Time source $sourceHost does not match an approved " +
                "configured NTP server: $($normalizedExpectedServers -join ', ')."
            )
        }

        $expectedPeerMatches = [string[]]@(
            $normalizedExpectedServers |
                Where-Object {
                    $peerText -match [regex]::Escape($_)
                }
        )

        if ($expectedPeerMatches.Count -lt 1) {
            throw (
                'Windows Time peer list does not contain an approved configured NTP server. ' +
                "Expected one of: $($normalizedExpectedServers -join ', ')."
            )
        }

        $lastSyncMatch = [regex]::Match(
            $statusText,
            '(?im)^\s*Last Successful Sync Time:\s*(.+?)\s*$'
        )

        if (-not $lastSyncMatch.Success) {
            throw (
                'Windows Time status does not contain Last Successful Sync Time.'
            )
        }

        $lastSyncText = $lastSyncMatch.Groups[1].Value.Trim()
        $lastSync = [datetime]::MinValue

        $parseSucceeded = [datetime]::TryParse(
            $lastSyncText,
            [ref]$lastSync
        )

        if (-not $parseSucceeded) {
            throw (
                "Unable to parse Last Successful Sync Time: $lastSyncText"
            )
        }

        $lastSyncUtc = $lastSync.ToUniversalTime()
        $syncAge = [datetime]::UtcNow - $lastSyncUtc

        if ($syncAge.TotalMinutes -lt 0) {
            throw (
                "Last Successful Sync Time $lastSyncText is in the future."
            )
        }

        if ($syncAge.TotalMinutes -gt $MaximumSyncAgeMinutes) {
            throw (
                "Last successful time synchronization is $([math]::Round($syncAge.TotalMinutes, 2)) " +
                "minutes old; maximum allowed age is $MaximumSyncAgeMinutes minutes."
            )
        }

        $stripChartOutput = @(
            & w32tm `
                /stripchart `
                "/computer:$sourceHost" `
                /samples:3 `
                /dataonly 2>&1
        )

        if ($LASTEXITCODE -ne 0) {
            throw (
                "w32tm /stripchart failed for ${sourceHost}: " +
                ($stripChartOutput -join '; ')
            )
        }

        $offsets = [System.Collections.Generic.List[decimal]]::new()

        foreach ($line in $stripChartOutput) {
            $offsetMatch = [regex]::Match(
                [string]$line,
                '([+-]?\d+(?:[.,]\d+)?)s'
            )

            if (-not $offsetMatch.Success) {
                continue
            }

            $offsetText = $offsetMatch.Groups[1].Value.Replace(',', '.')

            $offset = [decimal]0

            if (
                [decimal]::TryParse(
                    $offsetText,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$offset
                )
            ) {
                $offsets.Add($offset)
            }
        }

        if ($offsets.Count -lt 1) {
            throw (
                "No parseable time offset was returned by w32tm /stripchart for $sourceHost."
            )
        }

        $maximumObservedOffsetSeconds = @(
            $offsets |
                ForEach-Object {
                    [math]::Abs([decimal]$_)
                } |
                Sort-Object `
                    -Descending |
                Select-Object `
                    -First 1
        ) |
            Select-Object `
                -First 1

        if ($maximumObservedOffsetSeconds -gt $MaximumOffsetSeconds) {
            throw (
                "Maximum observed NTP offset was $maximumObservedOffsetSeconds seconds; " +
                "maximum allowed offset is $MaximumOffsetSeconds seconds."
            )
        }

        [pscustomobject]@{
            ComputerName                  = $env:COMPUTERNAME
            Source                        = $sourceText
            SourceHost                    = $sourceHost
            Status                        = $statusText
            Peers                         = $peerText
            LastSuccessfulSyncTime        = $lastSyncUtc.ToString('o')
            SyncAgeMinutes                = [math]::Round($syncAge.TotalMinutes, 2)
            MaximumObservedOffsetSeconds  = $maximumObservedOffsetSeconds
            MaximumAllowedOffsetSeconds   = $MaximumOffsetSeconds
            MaximumAllowedSyncAgeMinutes  = $MaximumSyncAgeMinutes
            ApprovedPeerMatches           = $expectedPeerMatches
        }
    }

$data = @($result.Data) |
    Select-Object `
        -First 1

return [pscustomobject]@{
    Passed                      = $true
    Check                       = 'Test-NTP'
    Node                        = $result.Node
    ManagementIp                = $result.ManagementIp
    Source                      = $data.Source
    SourceHost                  = $data.SourceHost
    Peers                       = $data.Peers
    LastSuccessfulSyncTime      = $data.LastSuccessfulSyncTime
    SyncAgeMinutes              = $data.SyncAgeMinutes
    MaximumObservedOffsetSeconds = $data.MaximumObservedOffsetSeconds
    MaximumAllowedOffsetSeconds = $data.MaximumAllowedOffsetSeconds
    Summary                     = (
        "NTP source $($data.SourceHost) is approved; synchronization age is " +
        "$($data.SyncAgeMinutes) minutes and maximum observed offset is " +
        "$($data.MaximumObservedOffsetSeconds) seconds."
    )
    ValidatedAt                 = [datetime]::UtcNow.ToString('o')
}