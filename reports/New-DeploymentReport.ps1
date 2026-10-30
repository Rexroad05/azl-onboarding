#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ReportValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

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

function ConvertTo-SafeDeploymentValue {
    param(
        [AllowNull()]
        [object]$Value,

        [int]$Depth = 0
    )

    if ($Depth -gt 20) {
        return '[MaximumDepthReached]'
    }

    if ($null -eq $Value) {
        return $null
    }

    if (
        $Value -is [string] -or
        $Value -is [char] -or
        $Value -is [bool] -or
        $Value -is [int] -or
        $Value -is [long] -or
        $Value -is [decimal] -or
        $Value -is [double] -or
        $Value -is [datetime]
    ) {
        $textValue = [string]$Value

        $textValue = $textValue -replace `
            '(?i)bearer\s+[a-z0-9\-_\.\=]+',
            'Bearer [REDACTED]'

        $textValue = $textValue -replace `
            '(?i)(password|secret|token|credential|client[_-]?secret)\s*[:=]\s*\S+',
            '$1=[REDACTED]'

        return $textValue
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $safeObject = [ordered]@{}

        foreach ($key in $Value.Keys) {
            $keyName = [string]$key

            if (
                $keyName -match
                '(?i)password|secret|token|credential|client[_-]?secret|device[_-]?code'
            ) {
                $safeObject[$keyName] = '[REDACTED]'
            }
            else {
                $safeObject[$keyName] = ConvertTo-SafeDeploymentValue `
                    -Value $Value[$key] `
                    -Depth ($Depth + 1)
            }
        }

        return $safeObject
    }

    if (
        $Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [string]
    ) {
        return @(
            foreach ($item in $Value) {
                ConvertTo-SafeDeploymentValue `
                    -Value $item `
                    -Depth ($Depth + 1)
            }
        )
    }

    $properties = @(
        $Value.PSObject.Properties |
            Where-Object {
                $_.MemberType -in @(
                    'Property',
                    'NoteProperty'
                )
            }
    )

    if ($properties.Count -gt 0) {
        $safeObject = [ordered]@{}

        foreach ($property in $properties) {
            if (
                $property.Name -match
                '(?i)password|secret|token|credential|client[_-]?secret|device[_-]?code'
            ) {
                $safeObject[$property.Name] = '[REDACTED]'
            }
            else {
                $safeObject[$property.Name] = ConvertTo-SafeDeploymentValue `
                    -Value $property.Value `
                    -Depth ($Depth + 1)
            }
        }

        return $safeObject
    }

    return [string]$Value
}

function ConvertTo-HtmlEncoded {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return [System.Net.WebUtility]::HtmlEncode(
        [string]$Value
    )
}

function Get-DeploymentReportOutcome {
    param(
        [Parameter(Mandatory)]
        [object]$State,

        [Parameter(Mandatory)]
        [object[]]$Events
    )

    $workflowStatus = [string](
        Get-ReportValue `
            -Object $State `
            -Name 'status'
    )

    if ($workflowStatus -in @(
        'BLOCKED',
        'DENIED',
        'FAILED'
    )) {
        return 'FAILED'
    }

    if ($workflowStatus -eq 'PAUSED') {
        return 'PAUSED'
    }

    $hasChanged = @(
        $Events |
            Where-Object {
                [string](
                    Get-ReportValue `
                        -Object $_ `
                        -Name 'Outcome'
                ) -eq 'CHANGED'
            }
    ).Count -gt 0

    if ($hasChanged) {
        return 'CHANGED'
    }

    return 'PASSED'
}

function Get-OutcomeCssClass {
    param(
        [AllowNull()]
        [string]$Outcome
    )

    switch ([string]$Outcome) {
        'PASSED'  { return 'passed' }
        'SKIPPED' { return 'skipped' }
        'CHANGED' { return 'changed' }
        'PAUSED'  { return 'paused' }
        'FAILED'  { return 'failed' }
        default   { return 'unknown' }
    }
}

$reportDirectory = Join-Path `
    $Context.RunDirectory `
    'reports'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $reportDirectory |
    Out-Null

$eventPath = Join-Path `
    $Context.RunDirectory `
    'execution-events.jsonl'

$events = @()

if (Test-Path -LiteralPath $eventPath -PathType Leaf) {
    foreach (
        $line in @(
            Get-Content `
                -LiteralPath $eventPath `
                -ErrorAction Stop
        )
    ) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $events += (
                $line |
                    ConvertFrom-Json `
                        -AsHashtable
            )
        }
        catch {
            # Preserve report generation if one incomplete line exists.
            continue
        }
    }
}

$safeEvents = @(
    foreach ($event in $events) {
        ConvertTo-SafeDeploymentValue `
            -Value $event
    }
)

$passedCount = @(
    $safeEvents |
        Where-Object {
            [string](
                Get-ReportValue `
                    -Object $_ `
                    -Name 'Outcome'
            ) -eq 'PASSED'
        }
).Count

$skippedCount = @(
    $safeEvents |
        Where-Object {
            [string](
                Get-ReportValue `
                    -Object $_ `
                    -Name 'Outcome'
            ) -eq 'SKIPPED'
        }
).Count

$changedCount = @(
    $safeEvents |
        Where-Object {
            [string](
                Get-ReportValue `
                    -Object $_ `
                    -Name 'Outcome'
            ) -eq 'CHANGED'
        }
).Count

$pausedCount = @(
    $safeEvents |
        Where-Object {
            [string](
                Get-ReportValue `
                    -Object $_ `
                    -Name 'Outcome'
            ) -eq 'PAUSED'
        }
).Count

$failedCount = @(
    $safeEvents |
        Where-Object {
            [string](
                Get-ReportValue `
                    -Object $_ `
                    -Name 'Outcome'
            ) -eq 'FAILED'
        }
).Count

$overallOutcome = Get-DeploymentReportOutcome `
    -State $Context.State `
    -Events $safeEvents

$report = [ordered]@{
    ReportVersion = 'phase-package-v2'
    GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
    OverallOutcome = $overallOutcome
    Run = [ordered]@{
        Site = $Context.State.site
        Cluster = $Context.State.cluster
        RunId = $Context.State.runId
        Mode = $Context.State.mode
        WorkflowStatus = $Context.State.status
        CurrentPhase = $Context.State.currentPhase
        CurrentStage = $Context.State.currentStage
        ReturnToPhase = $Context.State.returnToPhase
        ReturnToStage = $Context.State.returnToStage
        ReturnToOperation = $Context.State.returnToOperation
        StartedAtUtc = $Context.State.startedAt
        CompletedAtUtc = $Context.State.completedAt
        ConfigHash = $Context.State.configHash
    }
    Summary = [ordered]@{
        TotalEvents = $safeEvents.Count
        Passed = $passedCount
        Skipped = $skippedCount
        Changed = $changedCount
        Paused = $pausedCount
        Failed = $failedCount
    }
    State = ConvertTo-SafeDeploymentValue `
        -Value $Context.State
    Events = $safeEvents
}

$jsonPath = Join-Path `
    $reportDirectory `
    'deployment-report.json'

$report |
    ConvertTo-Json `
        -Depth 50 |
    Set-Content `
        -LiteralPath $jsonPath `
        -Encoding utf8

$summaryRows = @(
    "<tr><th>Total Events</th><td>$($report.Summary.TotalEvents)</td></tr>",
    "<tr><th>Passed</th><td class=""passed"">$($report.Summary.Passed)</td></tr>",
    "<tr><th>Skipped</th><td class=""skipped"">$($report.Summary.Skipped)</td></tr>",
    "<tr><th>Changed</th><td class=""changed"">$($report.Summary.Changed)</td></tr>",
    "<tr><th>Paused</th><td class=""paused"">$($report.Summary.Paused)</td></tr>",
    "<tr><th>Failed</th><td class=""failed"">$($report.Summary.Failed)</td></tr>"
) -join "`n"

$runRows = @(
    "<tr><th>Site</th><td>$(ConvertTo-HtmlEncoded -Value $report.Run.Site)</td></tr>",
    "<tr><th>Cluster</th><td>$(ConvertTo-HtmlEncoded -Value $report.Run.Cluster)</td></tr>",
    "<tr><th>Run ID</th><td>$(ConvertTo-HtmlEncoded -Value $report.Run.RunId)</td></tr>",
    "<tr><th>Mode</th><td>$(ConvertTo-HtmlEncoded -Value $report.Run.Mode)</td></tr>",
    "<tr><th>Workflow Status</th><td>$(ConvertTo-HtmlEncoded -Value $report.Run.WorkflowStatus)</td></tr>",
    "<tr><th>Current Position</th><td>Phase $(ConvertTo-HtmlEncoded -Value $report.Run.CurrentPhase), Stage $(ConvertTo-HtmlEncoded -Value $report.Run.CurrentStage)</td></tr>",
    "<tr><th>Return Operation</th><td>$(ConvertTo-HtmlEncoded -Value $report.Run.ReturnToOperation)</td></tr>",
    "<tr><th>Started UTC</th><td>$(ConvertTo-HtmlEncoded -Value $report.Run.StartedAtUtc)</td></tr>",
    "<tr><th>Completed UTC</th><td>$(ConvertTo-HtmlEncoded -Value $report.Run.CompletedAtUtc)</td></tr>",
    "<tr><th>Generated UTC</th><td>$(ConvertTo-HtmlEncoded -Value $report.GeneratedAtUtc)</td></tr>"
) -join "`n"

$eventRows = @(
    foreach ($event in $safeEvents) {
        $outcome = [string](
            Get-ReportValue `
                -Object $event `
                -Name 'Outcome'
        )

        $eventType = ConvertTo-HtmlEncoded -Value (
            Get-ReportValue `
                -Object $event `
                -Name 'EventType'
        )

        $timestamp = ConvertTo-HtmlEncoded -Value (
            Get-ReportValue `
                -Object $event `
                -Name 'TimestampUtc'
        )

        $phaseId = ConvertTo-HtmlEncoded -Value (
            Get-ReportValue `
                -Object $event `
                -Name 'PhaseId'
        )

        $stageId = ConvertTo-HtmlEncoded -Value (
            Get-ReportValue `
                -Object $event `
                -Name 'StageId'
        )

        $operation = ConvertTo-HtmlEncoded -Value (
            Get-ReportValue `
                -Object $event `
                -Name 'Operation'
        )

        $scope = ConvertTo-HtmlEncoded -Value (
            Get-ReportValue `
                -Object $event `
                -Name 'Scope'
        )

        $node = ConvertTo-HtmlEncoded -Value (
            Get-ReportValue `
                -Object $event `
                -Name 'Node'
        )

        $summary = ConvertTo-HtmlEncoded -Value (
            Get-ReportValue `
                -Object $event `
                -Name 'Summary'
        )

        $reason = ConvertTo-HtmlEncoded -Value (
            Get-ReportValue `
                -Object $event `
                -Name 'Reason'
        )

        $evidence = ConvertTo-HtmlEncoded -Value (
            Get-ReportValue `
                -Object $event `
                -Name 'Evidence'
        )

        $outcomeText = ConvertTo-HtmlEncoded `
            -Value $outcome

        $outcomeClass = Get-OutcomeCssClass `
            -Outcome $outcome

@"
<tr>
  <td>$timestamp</td>
  <td>$eventType</td>
  <td>$phaseId.$stageId</td>
  <td>$operation</td>
  <td>$scope</td>
  <td>$node</td>
  <td class="$outcomeClass">$outcomeText</td>
  <td>$summary</td>
  <td>$reason</td>
  <td>$evidence</td>
</tr>
"@
    }
) -join "`n"

$htmlPath = Join-Path `
    $reportDirectory `
    'deployment-report.html'

$overallClass = Get-OutcomeCssClass `
    -Outcome $overallOutcome

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Azure Local Deployment Report</title>
<style>
  body {
    font-family: Segoe UI, Arial, sans-serif;
    margin: 24px;
    color: #1f2937;
    background: #f8fafc;
  }
  h1, h2 {
    color: #0f4c81;
  }
  .outcome {
    font-size: 1.2em;
    font-weight: 700;
    padding: 10px;
    border-radius: 4px;
    display: inline-block;
  }
  table {
    border-collapse: collapse;
    width: 100%;
    margin-bottom: 24px;
    background: #ffffff;
  }
  th {
    text-align: left;
    background: #e2e8f0;
    padding: 8px;
    border: 1px solid #cbd5e1;
  }
  td {
    vertical-align: top;
    padding: 8px;
    border: 1px solid #cbd5e1;
    word-break: break-word;
  }
  .passed {
    color: #166534;
    font-weight: 700;
    background: #dcfce7;
  }
  .skipped {
    color: #1f2937;
    background: #ffffff;
  }
  .changed {
    color: #854d0e;
    font-weight: 700;
    background: #fef3c7;
  }
  .paused {
    color: #854d0e;
    font-weight: 700;
    background: #fef9c3;
  }
  .failed {
    color: #991b1b;
    font-weight: 700;
    background: #fee2e2;
  }
  .unknown {
    color: #334155;
    background: #e2e8f0;
  }
</style>
</head>
<body>
<h1>Azure Local Deployment Report</h1>

<p class="outcome $overallClass">
  Overall Outcome: $(ConvertTo-HtmlEncoded -Value $overallOutcome)
</p>

<h2>Run Information</h2>
<table>
$runRows
</table>

<h2>Execution Summary</h2>
<table>
$summaryRows
</table>

<h2>Execution Timeline</h2>
<table>
  <tr>
    <th>Timestamp UTC</th>
    <th>Event</th>
    <th>Phase.Stage</th>
    <th>Operation</th>
    <th>Scope</th>
    <th>Node</th>
    <th>Outcome</th>
    <th>Summary</th>
    <th>Reason</th>
    <th>Evidence</th>
  </tr>
$eventRows
</table>
</body>
</html>
"@

Set-Content `
    -LiteralPath $htmlPath `
    -Value $html `
    -Encoding utf8

return [pscustomobject]@{
    Passed = $true
    Check = 'New-DeploymentReport'
    ReportPath = $jsonPath
    HtmlPath = $htmlPath
    EventPath = $eventPath
    OverallOutcome = $overallOutcome
    Summary = $report.Summary
    GeneratedAt = [datetime]::UtcNow.ToString('o')
}