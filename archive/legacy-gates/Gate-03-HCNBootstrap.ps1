param([Parameter(Mandatory)]$Context)
Import-Module "$PSScriptRoot/../controller/Factory.psm1" -Force
foreach($op in @('Wait-ForAzureLocalOS','Find-AzureLocalHost','Test-RemoteManagement')) { Invoke-FactoryOperation -Operation $op -Context $Context }
