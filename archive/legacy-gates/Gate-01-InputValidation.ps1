param([Parameter(Mandatory)]$Context)
Import-Module "$PSScriptRoot/../controller/Factory.psm1" -Force
foreach($op in @('Test-BootstrapNetwork','Find-iDRAC')) { Invoke-FactoryOperation -Operation $op -Context $Context }
