#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexPattern = "events_*"
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

Invoke-OsRequest -Method POST -Path "_plugins/_ism/remove/$IndexPattern" -BaseUrl $BaseUrl
