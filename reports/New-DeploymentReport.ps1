#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reportDirectory = Join-Path $Context.RunDirectory 'reports'
New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null

$reportPath = Join-Path $reportDirectory 'deployment-report.json'

$report = @{
    reportVersion  = 'phase-package-v1'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    site           = $Context.State.site
    cluster        = $Context.State.cluster
    runId          = $Context.State.runId
    mode           = $Context.State.mode
    status         = $Context.State.status
    currentPhase   = $Context.State.currentPhase
    currentStage   = $Context.State.currentStage
    startedAt      = $Context.State.startedAt
    completedAt    = $Context.State.completedAt
    phases         = $Context.State.phases
    stages         = $Context.State.stages
    nodes          = $Context.State.nodes
    evidenceRoot   = (Join-Path $Context.RunDirectory 'evidence')
}

$report |
    ConvertTo-Json -Depth 50 |
    Set-Content -LiteralPath $reportPath -Encoding utf8

return [pscustomobject]@{
    Passed      = $true
    Check       = 'New-DeploymentReport'
    ReportPath  = $reportPath
    GeneratedAt = [datetime]::UtcNow.ToString('o')
}