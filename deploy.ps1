#!/usr/bin/env pwsh
<#
.SYNOPSIS
  One-command deploy for the Azure AI Foundry v2 + APIM AI Gateway demo.

.DESCRIPTION
  Wraps the Azure Developer CLI (azd) to provision all infrastructure defined in
  main.bicep. Creates/selects the azd environment, sets regions, provisions, then
  prints the gateway endpoint and fetches the APIM subscription key.

  No manual Azure Portal steps. Idempotent: safe to re-run.

.PARAMETER EnvName
  azd environment name. Default: ai-gateway-demo

.PARAMETER Location
  Primary Azure region (also the primary Foundry region). Default: swedencentral

.PARAMETER SecondaryLocation
  Secondary / failover region. Default: westeurope

.PARAMETER SubscriptionId
  Target subscription id. If omitted, uses the current az/azd default.

.EXAMPLE
  ./deploy.ps1

.EXAMPLE
  ./deploy.ps1 -Location swedencentral -SecondaryLocation westeurope
#>
[CmdletBinding()]
param(
  [string]$EnvName = "ai-gateway-demo",
  [string]$Location = "swedencentral",
  [string]$SecondaryLocation = "westeurope",
  [string]$SubscriptionId
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Require-Tool($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Required tool '$name' not found on PATH."
  }
}

Require-Tool azd
Require-Tool az

Write-Host "==> Ensuring azd is authenticated..." -ForegroundColor Cyan
if (-not (azd auth login --check-status 2>$null)) {
  azd auth login
}

Write-Host "==> Selecting/creating azd environment '$EnvName'..." -ForegroundColor Cyan
$envs = (azd env list --output json 2>$null | ConvertFrom-Json)
if ($envs.Name -contains $EnvName) {
  azd env select $EnvName | Out-Null
} else {
  $newArgs = @("env", "new", $EnvName, "--location", $Location)
  if ($SubscriptionId) { $newArgs += @("--subscription", $SubscriptionId) }
  azd @newArgs | Out-Null
}

azd env set AZURE_LOCATION $Location | Out-Null
azd env set SECONDARY_LOCATION $SecondaryLocation | Out-Null
if ($SubscriptionId) { azd env set AZURE_SUBSCRIPTION_ID $SubscriptionId | Out-Null }

Write-Host "==> Provisioning infrastructure (this can take ~30-45 min for APIM)..." -ForegroundColor Cyan
azd provision --no-prompt

Write-Host "`n==> Deployment outputs:" -ForegroundColor Green
$vals = @{}
azd env get-values | ForEach-Object {
  if ($_ -match '^(.*?)=(.*)$') { $vals[$Matches[1]] = $Matches[2].Trim('"') }
}
$gateway = $vals["APIM_GATEWAY_URL"]
$rg      = $vals["AZURE_RESOURCE_GROUP"]
$svc     = $vals["APIM_SERVICE_NAME"]

Write-Host "  Gateway URL : $gateway"
Write-Host "  Router      : $($vals['MODEL_ROUTER_NAME'])"
Write-Host "  Search      : $($vals['AZURE_SEARCH_ENDPOINT'])"
Write-Host "  Resource RG : $rg"

if ($rg -and $svc) {
  Write-Host "`n==> Fetching APIM subscription key (not stored in source)..." -ForegroundColor Cyan
  $key = az apim subscription show --resource-group $rg --service-name $svc `
    --sid ai-gateway-demo --query primaryKey -o tsv
  Write-Host "  Subscription key: $key"
  Write-Host "`nNext:" -ForegroundColor Green
  Write-Host "  python samples/demo.py --from-azd"
  Write-Host "  # or open webapp.html and paste the gateway URL + key above"
}
