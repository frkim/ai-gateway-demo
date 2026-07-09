#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build & deploy the Foundry multi-agent backend to Azure Container Apps, grant its
  managed identity access to the Foundry project, and register its URL for the demo.

.DESCRIPTION
  Uses `az containerapp up --source ./backend` (ACR cloud build — no local Docker),
  enables a system-assigned identity, grants it "Azure AI Developer" on the Foundry
  account (so it can create + run agents), sets the backend env vars, and writes
  backendUrl into the local (git-ignored) config.json the webapp reads.

  Requires: az CLI logged in, and the infra already provisioned (`azd provision`).
#>
[CmdletBinding()]
param([string]$AppName = "ca-agents")

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Require-Tool($n) { if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { throw "Required tool '$n' not found on PATH." } }
Require-Tool az
Require-Tool azd

Write-Host "==> Ensuring the Azure CLI 'containerapp' extension is installed..." -ForegroundColor Cyan
az extension show --name containerapp -o none 2>$null
if ($LASTEXITCODE -ne 0) { az extension add --name containerapp --only-show-errors | Out-Null }

Write-Host "==> Reading settings from the azd environment..." -ForegroundColor Cyan
$rg      = (azd env get-value AZURE_RESOURCE_GROUP).Trim()
$loc     = (azd env get-value SECONDARY_LOCATION).Trim()
if ([string]::IsNullOrWhiteSpace($loc)) { $loc = "westeurope" }
$ep      = (azd env get-value FOUNDRY_PROJECT_ENDPOINT_AIS).Trim()
$conn    = (azd env get-value SEARCH_CONNECTION_NAME).Trim()
$acct    = (azd env get-value PRIMARY_FOUNDRY_NAME).Trim()
if ([string]::IsNullOrWhiteSpace($ep) -or [string]::IsNullOrWhiteSpace($rg)) {
  throw "Missing FOUNDRY_PROJECT_ENDPOINT_AIS / AZURE_RESOURCE_GROUP. Run 'azd provision' first."
}
$env:PYTHONUTF8 = "1"; $env:PYTHONIOENCODING = "utf-8"   # avoid the az CLI Windows charmap crash
$envName = "cae-agents-we"
Write-Host "    RG: $rg   Region: $loc   Project: $ep" -ForegroundColor DarkGray

# --- Container Apps environment (secondary region avoids swedencentral capacity limits) ---
Write-Host "==> Ensuring Container Apps environment '$envName' ($loc)..." -ForegroundColor Cyan
az containerapp env show -n $envName -g $rg -o none 2>$null
if ($LASTEXITCODE -ne 0) { az containerapp env create -n $envName -g $rg --location $loc --logs-destination none -o none }

# --- ACR + image (cloud build; no local Docker) ---
$acr = az acr list -g $rg --query "[0].name" -o tsv
if ([string]::IsNullOrWhiteSpace($acr)) {
  $acr = "acragents$((az account show --query id -o tsv).Replace('-','').Substring(0,10))"
  az acr create -n $acr -g $rg --sku Basic --location $loc --admin-enabled true -o none
}
az acr update -n $acr --admin-enabled true -o none
Write-Host "==> Building image with ACR cloud build ($acr)..." -ForegroundColor Cyan
$image = "$acr.azurecr.io/agents-backend:v3"
az acr build --registry $acr --image "agents-backend:v3" ./backend 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0 -and -not (az acr repository show-tags -n $acr --repository agents-backend --query "contains(@,'v3')" -o tsv 2>$null)) {
  throw "ACR build failed."
}

# --- Container App (system identity) ---
Write-Host "==> Creating/updating the Container App '$AppName'..." -ForegroundColor Cyan
$acrUser = az acr credential show -n $acr --query username -o tsv
$acrPwd  = az acr credential show -n $acr --query "passwords[0].value" -o tsv
$appInsightsCs = az monitor app-insights component show -g $rg --query "[0].connectionString" -o tsv 2>$null
$envArgs = @("PROJECT_ENDPOINT=$ep", "MODEL_DEPLOYMENT_NAME=gpt-5-mini", "SEARCH_CONNECTION_NAME=$conn", "SEARCH_INDEX_NAME=enterprise-kb")
if (-not [string]::IsNullOrWhiteSpace($appInsightsCs)) {
  $envArgs += "APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsCs"
}
az containerapp show -n $AppName -g $rg -o none 2>$null
if ($LASTEXITCODE -ne 0) {
  az containerapp create -n $AppName -g $rg --environment $envName --image $image `
    --target-port 8000 --ingress external `
    --registry-server "$acr.azurecr.io" --registry-username $acrUser --registry-password $acrPwd `
    --system-assigned --min-replicas 1 --max-replicas 1 --env-vars @envArgs -o none
} else {
  az containerapp update -n $AppName -g $rg --image $image --set-env-vars @envArgs -o none
}

Write-Host "==> Granting the backend identity Foundry data-plane roles..." -ForegroundColor Cyan
$mi = az containerapp show -n $AppName -g $rg --query "identity.principalId" -o tsv
$acctId = az cognitiveservices account show --name $acct --resource-group $rg --query id -o tsv
# Cognitive Services User = base data-plane access; Azure AI Developer = agent CRUD.
az role assignment create --assignee-object-id $mi --assignee-principal-type ServicePrincipal `
  --role "Cognitive Services User" --scope $acctId 2>$null | Out-Null
az role assignment create --assignee-object-id $mi --assignee-principal-type ServicePrincipal `
  --role "64702f94-c441-49e6-a78b-ef80e0188fee" --scope $acctId 2>$null | Out-Null
Write-Host "    Granted. (Data-plane RBAC can take a few minutes to take effect.)" -ForegroundColor DarkGray

$rev = az containerapp revision list --name $AppName --resource-group $rg --query "[-1].name" -o tsv
az containerapp revision restart --name $AppName --resource-group $rg --revision $rev 2>$null | Out-Null

$fqdn = az containerapp show --name $AppName --resource-group $rg --query "properties.configuration.ingress.fqdn" -o tsv
$backendUrl = "https://$fqdn"
Write-Host "==> Backend URL: $backendUrl" -ForegroundColor Green

# Merge backendUrl into the local (git-ignored) config.json the webapp reads.
$cfgPath = Join-Path $PSScriptRoot "config.json"
$cfg = (Test-Path $cfgPath) ? (Get-Content -Raw $cfgPath | ConvertFrom-Json) : [pscustomobject]@{}
$cfg | Add-Member -NotePropertyName backendUrl -NotePropertyValue $backendUrl -Force
$cfg | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding utf8
Write-Host "==> Wrote backendUrl into config.json. Reload the webapp -> 'Multi-agent (Foundry)' tab." -ForegroundColor Green
Write-Host "    Health check: $backendUrl/health" -ForegroundColor DarkGray
