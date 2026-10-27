#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object[]]$Results,

    [Parameter(Mandatory)]
    [int]$PhaseId,

    [Parameter(Mandatory)]
    [int]$StageId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Results.Count -lt 1) {
    throw "Phase $PhaseId Stage $StageId returned no operation results."
}

$failures = @(
    $Results |
        Where-Object {
            $null -eq $_.PSObject.Properties['Passed'] -or
            $_.Passed -isnot [bool] -or
            -not $_.Passed
        }
)

if ($failures.Count -gt 0) {
    $failedOperations = @(
        $failures |
            ForEach-Object {
                if ($null -ne $_.PSObject.Properties['Operation']) {
                    [string]$_.Operation
                }
                else {
                    'UnknownOperation'
                }
            } |
            Sort-Object -Unique
    )

    throw (
        "Phase $PhaseId Stage $StageId failed validation for operation(s): " +
        ($failedOperations -join ', ')
    )
}

$nodesChecked = @(
    $Results |
        Where-Object {
            $null -ne $_.PSObject.Properties['Node'] -and
            -not [string]::IsNullOrWhiteSpace([string]$_.Node)
        } |
        Select-Object -ExpandProperty Node -Unique
)

return [pscustomobject]@{
    Passed       = $true
    Check        = "Phase-$PhaseId-Stage-$StageId"
    PhaseId      = $PhaseId
    StageId      = $StageId
    Checks       = $Results.Count
    NodesChecked = $nodesChecked
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}