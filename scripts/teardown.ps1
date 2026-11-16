<#
.SYNOPSIS
    Deletes the lab resource group (storage, workspace, Spark pool, and Synapse's managed RG).
    The subscription-level budget is kept; pass -RemoveBudget to delete it too.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ResourceGroupName = 'rg-medallion-lab',
    [switch]$RemoveBudget
)

$ErrorActionPreference = 'Stop'

$exists = az group exists --name $ResourceGroupName
if ($exists -ne 'true') {
    Write-Host "Resource group $ResourceGroupName does not exist; nothing to delete."
}
elseif ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete resource group and all data in it')) {
    az group delete --name $ResourceGroupName --yes --no-wait
    if ($LASTEXITCODE -ne 0) { throw "az group delete failed" }
    Write-Host "Deletion of $ResourceGroupName started (runs in the background, takes a few minutes)."
}

if ($RemoveBudget -and $PSCmdlet.ShouldProcess('budget-medallion-lab', 'Delete subscription budget')) {
    az consumption budget delete --budget-name budget-medallion-lab
}
