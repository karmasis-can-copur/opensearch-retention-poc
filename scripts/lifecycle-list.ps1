#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexPattern = "events_*"
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

Write-Host "Cluster health:"
Invoke-OsRequest -Method GET -Path "_cluster/health" -BaseUrl $BaseUrl

Write-Host ""
Write-Host "Nodes:"
Invoke-OsText -Path "_cat/nodes?v&h=name,ip,node.role,heap.percent,ram.percent,cpu,load_1m,disk.used_percent" -BaseUrl $BaseUrl

Write-Host ""
Write-Host "Node attrs:"
Invoke-OsText -Path "_cat/nodeattrs?v" -BaseUrl $BaseUrl

Write-Host ""
Write-Host "Indexes:"
Invoke-OsText -Path "_cat/indices/${IndexPattern}?v&s=index" -BaseUrl $BaseUrl

Write-Host ""
Write-Host "Shards:"
Invoke-OsText -Path "_cat/shards/${IndexPattern}?v&h=index,shard,prirep,state,docs,store,node&s=index,shard,prirep" -BaseUrl $BaseUrl

Write-Host ""
Write-Host "Repositories:"
Invoke-OsText -Path "_cat/repositories?v" -BaseUrl $BaseUrl

Write-Host ""
Write-Host "Snapshots:"
Invoke-OsText -Path "_cat/snapshots/dataskope_lifecycle_repo?v&s=id" -BaseUrl $BaseUrl
