#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [object]$Phase,

    [Parameter(Mandatory)]
    [int]$StartStage,

    [Parameter(Mandatory)]
    [int]$ThroughStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [bool]$Phase.implemented) {
    throw "Phase $($Phase.id) is not implemented."
}

$stages = @($Phase.stages)

if ($stages.Count -lt 1) {
    throw "Phase $($Phase.id) contains no stages."
}

$eligibleStages = @(
    $stages |
        Sort-Object { [int]$_.id } |
        Where-Object {
            [int]$_.id -ge $StartStage -and
            [int]$_.id -le $ThroughStage
        }
)

if ($eligibleStages.Count -lt 1) {
    throw (
        "No eligible stages found for Phase $($Phase.id). " +
        "StartStage=$StartStage; ThroughStage=$ThroughStage."
    )
}

return $eligibleStages