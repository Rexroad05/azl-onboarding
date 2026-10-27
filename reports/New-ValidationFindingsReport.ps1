#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunDirectory,

    [Parameter(Mandatory)]
    [string]$Site,

    [Parameter(Mandatory)]
    [string]$ProfileName,

    [Parameter(Mandatory)]
    [string]$DisplayName,

    [Parameter(Mandatory)]
    [object[]]$Results,

    [Parameter(Mandatory)]
    [ValidateSet(
        'Passed',
        'PassedWithFindings',
        'Blocked',
        'Failed',
        'Paused'
    )]
    [string]$OverallOutcome,

    [hashtable]$ContextSummary = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-SafeValue {
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

        return $textValue
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $safeObject = [ordered]@{}

        foreach ($key in $Value.Keys) {
            $keyName = [string]$key

            if ($keyName -match '(?i)password|secret|token|credential|client[_-]?secret') {
                $safeObject[$keyName] = '[REDACTED]'
            }
            else {
                $safeObject[$keyName] = ConvertTo-SafeValue `
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
                ConvertTo-SafeValue `
                    -Value $item `
                    -Depth ($Depth + 1)
            }
        )
    }

    $properties = @(
        $Value.PSObject.Properties |
            Where-Object {
                $_.MemberType -in @('Property', 'NoteProperty')
            }
    )

    if ($properties.Count -gt 0) {
        $safeObject = [ordered]@{}

        foreach ($property in $properties) {
            if (
                $property.Name -match
                '(?i)password|secret|token|credential|client[_-]?secret'
            ) {
                $safeObject[$property.Name] = '[REDACTED]'
            }
            else {
                $safeObject[$property.Name] = ConvertTo-SafeValue `
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

function Get-ResultValue {
    param(
        [AllowNull()]
        [object]$Result,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Result) {
        return $null
    }

    if ($Result -is [System.Collections.IDictionary]) {
        if ($Result.Contains($Name)) {
            return $Result[$Name]
        }

        return $null
    }

    $property = $Result.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

$reportsDirectory = Join-Path `
    $RunDirectory `
    'reports'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $reportsDirectory |
    Out-Null

$safeResults = @(
    foreach ($result in $Results) {
        ConvertTo-SafeValue -Value $result
    }
)

$passedCount = @(
    $safeResults |
        Where-Object {
            [string](Get-ResultValue -Result $_ -Name 'Status') -eq 'Passed'
        }
).Count

$findingCount = @(
    $safeResults |
        Where-Object {
            [string](Get-ResultValue -Result $_ -Name 'Status') -eq 'Finding'
        }
).Count

$failedCount = @(
    $safeResults |
        Where-Object {
            [string](Get-ResultValue -Result $_ -Name 'Status') -eq 'Failed'
        }
).Count

$skippedCount = @(
    $safeResults |
        Where-Object {
            [string](Get-ResultValue -Result $_ -Name 'Status') -eq 'Skipped'
        }
).Count

$referenceCount = @(
    $safeResults |
        Where-Object {
            [string](Get-ResultValue -Result $_ -Name 'Classification') -eq 'ReferenceDifference'
        }
).Count

$reportObject = [ordered]@{
    Site = $Site
    ProfileName = $ProfileName
    DisplayName = $DisplayName
    OverallOutcome = $OverallOutcome
    ContextSummary = ConvertTo-SafeValue -Value $ContextSummary
    Summary = [ordered]@{
        Total = $safeResults.Count
        Passed = $passedCount
        Findings = $findingCount
        Failed = $failedCount
        Skipped = $skippedCount
        ReferenceDifferences = $referenceCount
    }
    Results = $safeResults
    GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
}

$jsonPath = Join-Path `
    $reportsDirectory `
    'validation-findings.json'

$reportObject |
    ConvertTo-Json `
        -Depth 50 |
    Set-Content `
        -LiteralPath $jsonPath `
        -Encoding utf8

$summaryRows = @(
    "<tr><th>Total Checks</th><td>$($reportObject.Summary.Total)</td></tr>",
    "<tr><th>Passed</th><td>$($reportObject.Summary.Passed)</td></tr>",
    "<tr><th>Findings</th><td>$($reportObject.Summary.Findings)</td></tr>",
    "<tr><th>Failed</th><td>$($reportObject.Summary.Failed)</td></tr>",
    "<tr><th>Skipped</th><td>$($reportObject.Summary.Skipped)</td></tr>",
    "<tr><th>Reference Differences</th><td>$($reportObject.Summary.ReferenceDifferences)</td></tr>"
) -join "`n"

$contextRows = @(
    foreach ($key in $reportObject.ContextSummary.Keys) {
        "<tr><th>$(ConvertTo-HtmlEncoded -Value $key)</th><td>$(ConvertTo-HtmlEncoded -Value $reportObject.ContextSummary[$key])</td></tr>"
    }
) -join "`n"

$resultRows = @(
    foreach ($result in $safeResults) {
        $operation = ConvertTo-HtmlEncoded -Value (
            Get-ResultValue `
                -Result $result `
                -Name 'Operation'
        )

        $node = ConvertTo-HtmlEncoded -Value (
            Get-ResultValue `
                -Result $result `
                -Name 'Node'
        )

        $status = ConvertTo-HtmlEncoded -Value (
            Get-ResultValue `
                -Result $result `
                -Name 'Status'
        )

        $classification = ConvertTo-HtmlEncoded -Value (
            Get-ResultValue `
                -Result $result `
                -Name 'Classification'
        )

        $summary = ConvertTo-HtmlEncoded -Value (
            Get-ResultValue `
                -Result $result `
                -Name 'Summary'
        )

        $details = Get-ResultValue `
            -Result $result `
            -Name 'Details'

        $detailsJson = if ($null -ne $details) {
            ConvertTo-SafeValue -Value $details |
                ConvertTo-Json -Depth 30
        }
        else {
            ''
        }

        $encodedDetails = ConvertTo-HtmlEncoded -Value $detailsJson

        @"
<tr>
  <td>$operation</td>
  <td>$node</td>
  <td>$status</td>
  <td>$classification</td>
  <td>$summary</td>
  <td>
    <details>
      <summary>View Details</summary>
      <pre>$encodedDetails</pre>
    </details>
  </td>
</tr>
"@
    }
) -join "`n"

$htmlPath = Join-Path `
    $reportsDirectory `
    'validation-findings.html'

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Azure Local Validation Findings Report</title>
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
    background: #e0f2fe;
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
  }
  pre {
    white-space: pre-wrap;
    word-break: break-word;
    background: #0f172a;
    color: #e2e8f0;
    padding: 12px;
    border-radius: 4px;
    max-height: 500px;
    overflow: auto;
  }
  details summary {
    cursor: pointer;
    color: #0f4c81;
    font-weight: 600;
  }
</style>
</head>
<body>
<h1>Azure Local Validation Findings Report</h1>

<p class="outcome">Overall Outcome: $(ConvertTo-HtmlEncoded -Value $OverallOutcome)</p>

<h2>Run Information</h2>
<table>
  <tr><th>Site</th><td>$(ConvertTo-HtmlEncoded -Value $Site)</td></tr>
  <tr><th>Validation Profile</th><td>$(ConvertTo-HtmlEncoded -Value $DisplayName)</td></tr>
  <tr><th>Profile Name</th><td>$(ConvertTo-HtmlEncoded -Value $ProfileName)</td></tr>
  <tr><th>Generated UTC</th><td>$(ConvertTo-HtmlEncoded -Value $reportObject.GeneratedAtUtc)</td></tr>
</table>

<h2>Context Summary</h2>
<table>
$contextRows
</table>

<h2>Validation Summary</h2>
<table>
$summaryRows
</table>

<h2>Validation Results</h2>
<table>
  <tr>
    <th>Operation</th>
    <th>Node</th>
    <th>Status</th>
    <th>Classification</th>
    <th>Summary</th>
    <th>Details</th>
  </tr>
$resultRows
</table>
</body>
</html>
"@

Set-Content `
    -LiteralPath $htmlPath `
    -Value $html `
    -Encoding utf8

return [pscustomobject]@{
    HtmlPath = $htmlPath
    JsonPath = $jsonPath
    OverallOutcome = $OverallOutcome
    Summary = $reportObject.Summary
    GeneratedAtUtc = [datetime]::UtcNow.ToString('o')
}