param([Parameter(Mandatory)][string]$Operation,[Parameter(Mandatory)]$Context)
if($Operation -notmatch '^Repair-'){throw 'Expected remediation operation'}
if($Context.Mode -ne 'Apply'){throw 'Remediation requires Apply'}
Import-Module "$PSScriptRoot/Factory.psm1" -Force
Invoke-FactoryOperation -Operation $Operation -Context $Context
