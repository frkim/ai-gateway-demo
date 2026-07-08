#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Import the AI Gateway dashboard into the Azure Managed Grafana instance created
  by `azd provision`.

.DESCRIPTION
  Reads GRAFANA_NAME + LOG_ANALYTICS_WORKSPACE_ID + AZURE_RESOURCE_GROUP from the
  azd environment, injects the workspace resource id into the dashboard JSON, and
  imports it with `az grafana dashboard create`. Requires the Azure CLI `amg`
  extension (installed automatically if missing) and Grafana Admin on the instance
  (granted to the signed-in user in main.bicep).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Require-Tool($n) { if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { throw "Required tool '$n' not found on PATH." } }
Require-Tool az
Require-Tool azd

Write-Host "==> Ensuring the Azure CLI 'amg' extension is installed..." -ForegroundColor Cyan
az extension show --name amg -o none 2>$null
if ($LASTEXITCODE -ne 0) { az extension add --name amg --only-show-errors | Out-Null }

Write-Host "==> Reading Grafana + workspace settings from the azd environment..." -ForegroundColor Cyan
$grafana = (azd env get-value GRAFANA_NAME).Trim()
$rg      = (azd env get-value AZURE_RESOURCE_GROUP).Trim()
$wsId    = (azd env get-value LOG_ANALYTICS_WORKSPACE_ID).Trim()
if ([string]::IsNullOrWhiteSpace($grafana) -or [string]::IsNullOrWhiteSpace($wsId)) {
  throw "Could not read GRAFANA_NAME / LOG_ANALYTICS_WORKSPACE_ID from azd. Run 'azd provision' first (deployGrafana must be true)."
}
Write-Host "    Grafana:   $grafana" -ForegroundColor DarkGray
Write-Host "    Workspace: $wsId" -ForegroundColor DarkGray

Write-Host "==> Preparing dashboard definition..." -ForegroundColor Cyan
$template = Get-Content -Raw -Path (Join-Path $PSScriptRoot "grafana/ai-gateway-dashboard.json")
$definition = $template.Replace("__WORKSPACE_RESOURCE_ID__", $wsId)
$tmp = Join-Path $PSScriptRoot "grafana/_dashboard.tmp.json"
Set-Content -Path $tmp -Value $definition -Encoding utf8

Write-Host "==> Importing dashboard into Grafana..." -ForegroundColor Cyan
try {
  az grafana dashboard create --name $grafana --resource-group $rg --definition $tmp --overwrite --only-show-errors | Out-Null
  Write-Host "==> Imported 'AI Gateway - Usage & Governance'." -ForegroundColor Green
} finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$endpoint = (azd env get-value GRAFANA_ENDPOINT).Trim()
Write-Host ""
Write-Host "Open Grafana:  $endpoint" -ForegroundColor Green
Write-Host "Dashboard:     $endpoint/d/ai-gateway-usage" -ForegroundColor Green
