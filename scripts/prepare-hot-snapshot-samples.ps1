#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceFile = "$PSScriptRoot\..\samples\dataskope-events.sample.ndjson",
    [string]$OutputDir = "$PSScriptRoot\..\samples",
    [datetime]$HotDate = (Get-Date).Date,
    [datetime]$SnapshotDate = (Get-Date).Date.AddDays(-10),
    [int]$VariantsPerTemplate = 2000
)

$ErrorActionPreference = "Stop"

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

function New-VariantSample {
    param(
        [string]$Name,
        [datetime]$Date
    )

    $target = Join-Path $OutputDir "loadtest-$Name.ndjson"
    $writer = [System.IO.StreamWriter]::new($target, $false, [System.Text.UTF8Encoding]::new($false))

    try {
        $templates = Get-Content -Path $SourceFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $sequence = 0

        foreach ($line in $templates) {
            for ($i = 0; $i -lt $VariantsPerTemplate; $i++) {
                $sequence++
                $lineWithDate = $line -replace "\d{4}-\d{2}-\d{2}T", "$($Date.ToString('yyyy-MM-dd'))T"
                $event = $lineWithDate | ConvertFrom-Json
                $source = $event
                if ($null -ne $event.PSObject.Properties["_source"]) {
                    $source = $event._source
                }
                $second = $sequence % 86400
                $timestamp = [DateTimeOffset]::new($Date.AddSeconds($second), [TimeSpan]::Zero).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

                Set-IfExists -Object $source -Name "TimeCreated" -Value $timestamp
                Set-IfExists -Object $source -Name "TimeInserted" -Value $timestamp
                Set-IfExists -Object $source -Name "@timestamp" -Value $timestamp
                Set-IfExists -Object $source -Name "EventTime" -Value $timestamp
                Set-IfExists -Object $source -Name "Timestamp" -Value $timestamp
                Set-IfExists -Object $source -Name "Computer" -Value ("ds-node-{0:D3}.dataskope.local" -f ($sequence % 128))
                Set-IfExists -Object $source -Name "MachineName" -Value ("ds-node-{0:D3}" -f ($sequence % 128))
                Set-IfExists -Object $source -Name "EventRecordID" -Value (1000000000 + $sequence)
                Set-IfExists -Object $source -Name "ProcessID" -Value (1000 + ($sequence % 60000))
                Set-IfExists -Object $source -Name "ThreadID" -Value (100 + ($sequence % 8000))
                Set-IfExists -Object $source -Name "EventID" -Value (4624 + ($sequence % 12))
                Set-IfExists -Object $source -Name "Severity" -Value ($sequence % 5)
                Set-IfExists -Object $source -Name "Level" -Value ($sequence % 6)

                $writer.WriteLine(($event | ConvertTo-Json -Depth 100 -Compress))
            }
        }
    }
    finally {
        $writer.Dispose()
    }

    $count = (Get-Content -Path $target | Measure-Object).Count
    Write-Host "$Name sample: $target date=$($Date.ToString('yyyy-MM-dd')) count=$count"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-VariantSample -Name "hot-snapshot-hot" -Date $HotDate
New-VariantSample -Name "hot-snapshot-snapshot" -Date $SnapshotDate
