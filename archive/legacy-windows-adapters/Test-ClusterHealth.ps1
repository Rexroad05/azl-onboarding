param([Parameter(Mandatory)]$Context)
$seed=$Context.Config.nodes[0].management.ip
$r=Invoke-Command -ComputerName $seed -UseSSL -ScriptBlock {
 Import-Module FailoverClusters
 $nodes=@(Get-ClusterNode)
 $groups=@(Get-ClusterGroup)
 [pscustomobject]@{Nodes=$nodes.Count;BadNodes=@($nodes|Where-Object State -ne 'Up').Count;BadGroups=@($groups|Where-Object State -ne 'Online').Count}
} -ErrorAction Stop
if($r.Nodes -ne @($Context.Config.nodes).Count -or $r.BadNodes -or $r.BadGroups){throw 'Cluster health checks failed'}
@{Passed=$true;Check='Test-ClusterHealth'}
