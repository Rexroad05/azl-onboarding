[CmdletBinding()]
param([Parameter(Mandatory)]$Context)
Import-Module (Join-Path $PSScriptRoot '../controller/Factory.psm1') -Force
Invoke-FactoryOperation -Operation 'Test-StorageHealth' -Context $Context
