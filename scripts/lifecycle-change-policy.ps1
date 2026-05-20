#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexPattern = "events_*",
    [string]$PolicyId = "events-hot-cold",
    [string]$State,
    [string]$IncludeState
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

$body = @{
    policy_id = $PolicyId
}

if (-not [string]::IsNullOrWhiteSpace($State)) {
    $body["state"] = $State
}

if (-not [string]::IsNullOrWhiteSpace($IncludeState)) {
    $body["include"] = @(
        @{
            state = $IncludeState
        }
    )
}

Invoke-OsRequest -Method POST -Path "_plugins/_ism/change_policy/$IndexPattern" -BaseUrl $BaseUrl -Body $body
