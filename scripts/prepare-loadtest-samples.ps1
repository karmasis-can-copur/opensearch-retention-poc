#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceFile = "$PSScriptRoot\..\samples\dataskope-events.sample.ndjson",
    [string]$OutputDir = "$PSScriptRoot\..\samples",
    [datetime]$HotDate = (Get-Date).Date,
    [datetime]$ColdDate = (Get-Date).Date.AddDays(-1),
    [datetime]$FrozenDate = (Get-Date).Date.AddDays(-2)
)

$ErrorActionPreference = "Stop"

function New-DatedSample {
    param(
        [string]$Name,
        [datetime]$Date
    )

    $target = Join-Path $OutputDir "loadtest-$Name.ndjson"
    $dateText = $Date.ToString("yyyy-MM-dd")

    Get-Content -Path $SourceFile | ForEach-Object {
        $_ -replace "\d{4}-\d{2}-\d{2}T", "$dateText`T"
    } | Set-Content -Path $target -Encoding UTF8

    Write-Host "$Name sample: $target date=$dateText"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-DatedSample -Name "hot" -Date $HotDate
New-DatedSample -Name "cold" -Date $ColdDate
New-DatedSample -Name "frozen" -Date $FrozenDate
