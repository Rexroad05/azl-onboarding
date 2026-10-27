param([Parameter(Mandatory)]$Context)
Import-Module "$PSScriptRoot/../controller/Factory.psm1" -Force
foreach($op in @('Test-NICState','Test-IPConfiguration','Test-Gateway','Test-DNS','Test-NTP','Test-AzureGovEndpoints','Test-AzureLocalReadiness')) { Invoke-FactoryOperation -Operation $op -Context $Context }
