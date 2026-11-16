<#
.SYNOPSIS
    Deploys (or previews) the medallion lab: resource group, ADLS Gen2, Synapse workspace.
.EXAMPLE
    ./scripts/deploy.ps1 -WhatIf          # preview only, creates nothing
    ./scripts/deploy.ps1                  # deploy
    ./scripts/deploy.ps1 -DeploySparkPool # deploy with the optional Spark pool
#>
[CmdletBinding()]
param(
    [string]$Location = 'eastus2',
    [switch]$WhatIf,
    [switch]$DeploySparkPool,
    [switch]$SkipBudget
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$paramFile = Join-Path $repoRoot 'infra/main.bicepparam'

function Invoke-Az {
    & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

# Confirm who and where we are deploying.
$account = Invoke-Az account show --query '{sub:name, id:id}' -o json | ConvertFrom-Json
Write-Host "Subscription: $($account.sub) ($($account.id))"

# New subscriptions often lack these registrations; deployment fails without them.
if (-not $WhatIf) {
    foreach ($ns in 'Microsoft.Storage', 'Microsoft.Synapse', 'Microsoft.Sql') {
        $state = Invoke-Az provider show --namespace $ns --query registrationState -o tsv
        if ($state -ne 'Registered') {
            Write-Host "Registering resource provider $ns ..."
            Invoke-Az provider register --namespace $ns --wait | Out-Null
        }
    }
}

$env:LAB_LOCATION = $Location
$env:LAB_CLIENT_IP = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
$env:LAB_USER_OBJECT_ID = Invoke-Az ad signed-in-user show --query id -o tsv
$env:LAB_DEPLOY_SPARK = if ($DeploySparkPool) { 'true' } else { 'false' }
$env:LAB_DEPLOY_BUDGET = if ($SkipBudget) { 'false' } else { 'true' }

# Random password that meets Synapse complexity rules. Never printed or saved; Entra-only auth is enforced.
$bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
$env:LAB_SQL_ADMIN_PASSWORD = [Convert]::ToBase64String($bytes) + 'Aa1!'

try {
    $deploymentName = "medallion-lab-$(Get-Date -Format 'yyyyMMddHHmmss')"
    if ($WhatIf) {
        Invoke-Az deployment sub what-if --name $deploymentName --location $Location --parameters $paramFile
    }
    else {
        Invoke-Az deployment sub create --name $deploymentName --location $Location --parameters $paramFile `
            --query 'properties.outputs' -o json
    }
}
finally {
    Remove-Item Env:LAB_SQL_ADMIN_PASSWORD, Env:LAB_CLIENT_IP, Env:LAB_USER_OBJECT_ID, `
        Env:LAB_DEPLOY_SPARK, Env:LAB_DEPLOY_BUDGET, Env:LAB_LOCATION -ErrorAction SilentlyContinue
}
