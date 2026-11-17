<#
.SYNOPSIS
    Uploads local data/landing/<dataset>/ingest_date=... folders to the lake container's landing/ folder.
    Uses your Entra login (Storage Blob Data Contributor), never account keys.
    After each snapshot uploads, verifies file names and sizes match the lake exactly; throws on any difference.
    Re-running is safe: files are overwritten with identical content.
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

function Test-SnapshotUpload {
    <# Fails unless every local file exists in the lake with the same size, and the lake holds no extra files. #>
    param([string]$Account, [string]$LocalPath, [string]$LakePath)
    $root = (Resolve-Path $LocalPath).Path
    $local = @{}
    foreach ($f in Get-ChildItem $root -File -Recurse) {
        $local[$f.FullName.Substring($root.Length + 1).Replace('\', '/')] = $f.Length
    }
    # Plain JSON, filtered in PowerShell: az.cmd passes args through cmd.exe, which mangles JMESPath.
    $listing = az storage fs file list --account-name $Account --file-system lake --path $LakePath `
        --auth-mode login -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Listing lake/$LakePath failed" }
    $lake = @{}
    foreach ($f in $listing | Where-Object { -not $_.isDirectory }) {
        $lake[$f.name.Substring($LakePath.Length + 1)] = [long]$f.contentLength
    }
    $problems = @(
        foreach ($k in $local.Keys) {
            if (-not $lake.ContainsKey($k)) { "missing in lake: $k" }
            elseif ($lake[$k] -ne $local[$k]) { "size differs: $k (local $($local[$k]), lake $($lake[$k]))" }
        }
        foreach ($k in $lake.Keys) { if (-not $local.ContainsKey($k)) { "extra in lake: $k" } }
    )
    if ($problems.Count) { throw "Upload verification FAILED for lake/${LakePath}:`n  " + ($problems -join "`n  ") }
    Write-Host "  verified: $($local.Count) files, names and sizes match lake/$LakePath"
}

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
        Test-SnapshotUpload -Account $account -LocalPath $snapshot.FullName -LakePath "$dest/$($snapshot.Name)"
    }
}

