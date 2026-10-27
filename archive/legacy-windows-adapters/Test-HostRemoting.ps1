param([Parameter(Mandatory)]$Context)
foreach($node in $Context.Config.nodes){
 $r=Invoke-Command -ComputerName $node.management.ip -UseSSL -ScriptBlock {
  [pscustomobject]@{ComputerName=$env:COMPUTERNAME;OS=(Get-CimInstance Win32_OperatingSystem).Caption}
 } -ErrorAction Stop
 if($r.ComputerName -ne $node.name){throw 'Remote host identity mismatch'}
}
@{Passed=$true;Check='Test-RemoteManagement'}
