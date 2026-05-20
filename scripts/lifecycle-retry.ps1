#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexPattern = "events_*",
    [string]$State
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

$body = @{}
if (-not [string]::IsNullOrWhiteSpace($State)) {
    $body["state"] = $State
}

Invoke-OsRequest -Method POST -Path "_plugins/_ism/retry/$IndexPattern" -BaseUrl $BaseUrl -Body $body
