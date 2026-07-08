#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run the webapp.html demo locally with the gateway URL + APIM key pre-populated.

.DESCRIPTION
  Reads the gateway URL and (via ARM listSecrets) the APIM subscription key from the
  current azd environment, writes them to an untracked config.json next to webapp.html
  (which the page auto-loads), then serves the folder on http://127.0.0.1:8000.

  config.json is git-ignored — the subscription key is never committed.

.PARAMETER Port
  Local port to serve on. Default 8000.
#>
[CmdletBinding()]
param([int]$Port = 8000)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Require-Tool($n) { if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { throw "Required tool '$n' not found on PATH." } }
Require-Tool az
Require-Tool azd
Require-Tool python

Write-Host "==> Reading connection settings from the azd environment..." -ForegroundColor Cyan
$gw   = azd env get-value APIM_GATEWAY_URL
$rg   = azd env get-value AZURE_RESOURCE_GROUP
$svc  = azd env get-value APIM_SERVICE_NAME
$sub  = azd env get-value AZURE_SUBSCRIPTION_ID
$ver  = azd env get-value OPENAI_API_VERSION
if ([string]::IsNullOrWhiteSpace($ver)) { $ver = "2024-10-21" }

if ([string]::IsNullOrWhiteSpace($gw) -or [string]::IsNullOrWhiteSpace($svc)) {
  throw "Could not read APIM_GATEWAY_URL / APIM_SERVICE_NAME from azd. Run 'azd provision' first."
}

Write-Host "==> Fetching APIM subscription key (ARM listSecrets)..." -ForegroundColor Cyan
$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$svc/subscriptions/ai-gateway-demo/listSecrets?api-version=2023-05-01-preview"
$key = az rest --method post --uri $uri --query primaryKey -o tsv

$cfg = [ordered]@{
  gatewayUrl  = $gw
  apiKey      = $key
  apiVersion  = $ver
  deployments = "model-router,gpt-5-mini,gpt-5,gpt-5-nano"
}
$cfg | ConvertTo-Json | Set-Content -Path (Join-Path $PSScriptRoot "config.json") -Encoding utf8
Write-Host "==> Wrote config.json (git-ignored)." -ForegroundColor Green

Write-Host "==> Serving on http://127.0.0.1:$Port/webapp.html  (Ctrl+C to stop)" -ForegroundColor Green
python -m http.server $Port --bind 127.0.0.1
