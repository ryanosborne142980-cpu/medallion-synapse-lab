<#
.SYNOPSIS
    Uploads local data/landing/<dataset>/ingest_date=... folders to the lake container's landing/ folder.
    Uses your Entra login (Storage Blob Data Contributor), never account keys.
.EXAMPLE
    ./scripts/upload_landing.ps1                       # everything under data/landing
    ./scripts/upload_landing.ps1 -Dataset nfip_claims  # one dataset
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'rg-medallion-lab',
    [string]$Dataset
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$localLanding = Join-Path $repoRoot 'data/landing'

$account = az storage account list -g $ResourceGroupName --query '[0].name' -o tsv
if (-not $account) { throw "No storage account in $ResourceGroupName; deploy first." }

$datasets = if ($Dataset) { @(Get-Item (Join-Path $localLanding $Dataset)) } else { Get-ChildItem $localLanding -Directory }
foreach ($ds in $datasets) {
    foreach ($snapshot in Get-ChildItem $ds.FullName -Directory -Filter 'ingest_date=*') {
        if (-not (Test-Path (Join-Path $snapshot.FullName '_manifest.json'))) {
            Write-Warning "Skipping $($ds.Name)/$($snapshot.Name): no _manifest.json (download incomplete)."
            continue
        }
        $dest = "landing/$($ds.Name)"
        Write-Host "Uploading $($ds.Name)/$($snapshot.Name) -> lake/$dest/$($snapshot.Name)"
        az storage fs directory upload --account-name $account --file-system lake `
            --source $snapshot.FullName --destination-path $dest --recursive --auth-mode login --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Upload failed for $($snapshot.FullName)" }
    }
}

# Count in PowerShell: az.cmd passes args through cmd.exe, which mangles JMESPath like length([?!x]).
$isDir = az storage fs file list --account-name $account --file-system lake --path landing --auth-mode login `
    --query '[].isDirectory' -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Listing lake/landing failed' }
Write-Host "Files under lake/landing: $(@($isDir | Where-Object { -not $_ }).Count)"
