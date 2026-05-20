#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexPattern = "events_*",
    [switch]$ShowPolicy,
    [switch]$ValidateAction
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

$query = @()
if ($ShowPolicy) {
    $query += "show_policy=true"
}

if ($ValidateAction) {
    $query += "validate_action=true"
}

$path = "_plugins/_ism/explain/$IndexPattern"
if ($query.Count -gt 0) {
    $path = "$path`?$($query -join '&')"
}

$result = Invoke-OsRequest -Method GET -Path $path -BaseUrl $BaseUrl
$result | ConvertTo-Json -Depth 80
