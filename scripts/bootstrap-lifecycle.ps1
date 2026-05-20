#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$PolicyId = "events-hot-cold-snapshot-10-10",
    [string]$PolicyFile,
    [string]$IndexTemplateName = "events-template",
    [string]$IndexTemplateFile,
    [string]$RepositoryName = "dataskope_lifecycle_repo",
    [string]$RepositoryFile,
    [int]$ExpectedNodes = 3,
    [int]$TimeoutSec = 240,
    [switch]$KeepDefaultIsmInterval
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

if ([string]::IsNullOrWhiteSpace($PolicyFile)) {
    $PolicyFile = Join-Path $PSScriptRoot "..\opensearch\lifecycle\dataskope-ism-policy.hot-cold-snapshot-10-10.poc.json"
}

if ([string]::IsNullOrWhiteSpace($IndexTemplateFile)) {
    $IndexTemplateFile = Join-Path $PSScriptRoot "..\opensearch\lifecycle\dataskope-index-template.json"
}

if ([string]::IsNullOrWhiteSpace($RepositoryFile)) {
    $RepositoryFile = Join-Path $PSScriptRoot "..\opensearch\lifecycle\snapshot-repository.s3-minio.json"
}

Wait-OpenSearch -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec | Out-Null

$deadline = (Get-Date).AddSeconds($TimeoutSec)
do {
    $health = Invoke-OsRequest -Method GET -Path "_cluster/health" -BaseUrl $BaseUrl -TimeoutSec 10
    if ([int]$health.number_of_nodes -ge $ExpectedNodes) {
        Write-Host "Expected node count is ready. nodes=$($health.number_of_nodes)"
        break
    }

    Write-Host "Waiting for all OpenSearch nodes... nodes=$($health.number_of_nodes)/$ExpectedNodes"
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)

if ([int]$health.number_of_nodes -lt $ExpectedNodes) {
    throw "OpenSearch did not reach $ExpectedNodes nodes within $TimeoutSec seconds. Current nodes=$($health.number_of_nodes)."
}

if (-not $KeepDefaultIsmInterval) {
    Invoke-OsRequest -Method PUT -Path "_cluster/settings" -BaseUrl $BaseUrl -Body @{
        persistent = @{
            plugins = @{
                index_state_management = @{
                    enabled = $true
                    job_interval = 1
                    jitter = 0.0
                    action_validation = @{
                        enabled = $false
                    }
                }
            }
        }
    } | Out-Null
}

Invoke-OsRequest -Method PUT -Path "_snapshot/$RepositoryName" -BodyPath $RepositoryFile -BaseUrl $BaseUrl | Out-Null
Set-IsmPolicyFromFile -PolicyId $PolicyId -PolicyFile $PolicyFile -BaseUrl $BaseUrl | Out-Null
Invoke-OsRequest -Method PUT -Path "_index_template/$IndexTemplateName" -BodyPath $IndexTemplateFile -BaseUrl $BaseUrl | Out-Null

Write-Host ""
Write-Host "Node attributes:"
Invoke-OsText -Path "_cat/nodeattrs?v" -BaseUrl $BaseUrl

Write-Host ""
Write-Host "Lifecycle policy:"
Invoke-OsRequest -Method GET -Path "_plugins/_ism/policies/$PolicyId" -BaseUrl $BaseUrl

Write-Host ""
Write-Host "Bootstrap complete. Repository, ISM policy template, and index template are ready. Daily hot indexes must be created with index.creation_date set from their name."
