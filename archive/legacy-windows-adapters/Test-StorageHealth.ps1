param([Parameter(Mandatory)]$Context)
$r=Invoke-Command -ComputerName $Context.Config.nodes[0].management.ip -UseSSL -ScriptBlock {
 $p=@(Get-StoragePool -IsPrimordial $false)
 $v=@(Get-VirtualDisk)
 $d=@(Get-PhysicalDisk)
 [pscustomobject]@{Pools=$p.Count;VirtualDisks=$v.Count;BadPools=@($p|Where-Object HealthStatus -ne 'Healthy').Count;BadVirtualDisks=@($v|Where-Object HealthStatus -ne 'Healthy').Count;BadPhysicalDisks=@($d|Where-Object HealthStatus -ne 'Healthy').Count}
} -ErrorAction Stop
if(-not $r.Pools -or -not $r.VirtualDisks -or $r.BadPools -or $r.BadVirtualDisks -or $r.BadPhysicalDisks){throw 'Storage health failed'}
@{Passed=$true;Check='Test-StorageHealth'}
