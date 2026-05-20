#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceFile,
    [Parameter(Mandatory = $true)]
    [datetime]$EventDate,
    [string]$OutputPath,
    [int]$VariantsPerTemplate = 2000
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SourceFile)) {
    $SourceFile = Join-Path $PSScriptRoot "..\samples\dataskope-events.sample.ndjson"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "..\samples\retention-day.ndjson"
}

function Set-IfExists {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [object]$Value
    )

    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    }
}

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$templates = Get-Content -Path $SourceFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$writer = [System.IO.StreamWriter]::new($OutputPath, $false, [System.Text.UTF8Encoding]::new($false))
$sequence = 0

try {
    foreach ($line in $templates) {
        for ($i = 0; $i -lt $VariantsPerTemplate; $i++) {
            $sequence++
            $lineWithDate = $line -replace "\d{4}-\d{2}-\d{2}T", "$($EventDate.ToString('yyyy-MM-dd'))T"
            $event = $lineWithDate | ConvertFrom-Json
            $source = $event
            if ($null -ne $event.PSObject.Properties["_source"]) {
                $source = $event._source
            }

            $second = $sequence % 86400
            $timestamp = [DateTimeOffset]::new($EventDate.Date.AddSeconds($second), [TimeSpan]::Zero).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

            Set-IfExists -Object $source -Name "TimeCreated" -Value $timestamp
            Set-IfExists -Object $source -Name "TimeInserted" -Value $timestamp
            Set-IfExists -Object $source -Name "@timestamp" -Value $timestamp
            Set-IfExists -Object $source -Name "EventTime" -Value $timestamp
            Set-IfExists -Object $source -Name "Timestamp" -Value $timestamp
            Set-IfExists -Object $source -Name "Computer" -Value ("ds-node-{0:D3}.dataskope.local" -f ($sequence % 256))
            Set-IfExists -Object $source -Name "MachineName" -Value ("ds-node-{0:D3}" -f ($sequence % 256))
            Set-IfExists -Object $source -Name "EventRecordID" -Value (1000000000 + $sequence)
            Set-IfExists -Object $source -Name "ProcessID" -Value (1000 + ($sequence % 60000))
            Set-IfExists -Object $source -Name "ThreadID" -Value (100 + ($sequence % 8000))
            Set-IfExists -Object $source -Name "EventID" -Value (4624 + ($sequence % 64))
            Set-IfExists -Object $source -Name "Severity" -Value ($sequence % 5)
            Set-IfExists -Object $source -Name "Level" -Value ($sequence % 6)

            $writer.WriteLine(($event | ConvertTo-Json -Depth 100 -Compress))
        }
    }
}
finally {
    $writer.Dispose()
}

Write-Host "Generated $sequence sample rows. path=$OutputPath date=$($EventDate.ToString('yyyy-MM-dd'))"
