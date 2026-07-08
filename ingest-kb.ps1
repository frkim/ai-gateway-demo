#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Create the `enterprise-kb` Azure AI Search index and upload the sample knowledge
  base so the RAG (Azure OpenAI "On Your Data") demo returns grounded answers.

.DESCRIPTION
  Reads AZURE_SEARCH_ENDPOINT / AZURE_SEARCH_INDEX_NAME from the current azd
  environment, retrieves the Search admin key via the management plane (a one-time
  admin task), creates a small text index, parses the sections of
  enterprise-kb.sample.md and uploads one document per heading.

  The admin key is used only for this seeding step. The RUNTIME grounding path
  uses no keys — the Foundry account queries the index with its managed identity
  (granted "Search Index Data Reader" in main.bicep).

  Requires: az CLI (logged in) with rights to list the Search admin key
  (Owner/Contributor or Search Service Contributor on the resource group).

.PARAMETER ApiVersion
  Azure AI Search REST API version. Default 2024-07-01.
#>
[CmdletBinding()]
param([string]$ApiVersion = "2024-07-01")

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Require-Tool($n) { if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { throw "Required tool '$n' not found on PATH." } }
Require-Tool az
Require-Tool azd

Write-Host "==> Reading Search settings from the azd environment..." -ForegroundColor Cyan
$endpoint = (azd env get-value AZURE_SEARCH_ENDPOINT).Trim()
$index    = (azd env get-value AZURE_SEARCH_INDEX_NAME).Trim()
if ([string]::IsNullOrWhiteSpace($endpoint) -or [string]::IsNullOrWhiteSpace($index)) {
  throw "Could not read AZURE_SEARCH_ENDPOINT / AZURE_SEARCH_INDEX_NAME from azd. Run 'azd provision' first."
}
Write-Host "    Endpoint: $endpoint" -ForegroundColor DarkGray
Write-Host "    Index:    $index" -ForegroundColor DarkGray

# Seeding is a one-time admin task: use the Search admin key (retrieved via the
# management plane) so it works immediately without waiting for data-plane RBAC
# propagation. The *runtime* RAG path never uses a key — the Foundry account
# queries the index with its managed identity (see main.bicep).
Write-Host "==> Retrieving Search service + admin key..." -ForegroundColor Cyan
$rg = (azd env get-value AZURE_RESOURCE_GROUP).Trim()
$svc = ($endpoint -replace 'https://', '' -replace '\.search\.windows\.net.*', '')
$adminKey = az search admin-key show --service-name $svc --resource-group $rg --query primaryKey -o tsv
if ([string]::IsNullOrWhiteSpace($adminKey)) { throw "Failed to retrieve the Search admin key (need Microsoft.Search/searchServices/listAdminKeys)." }
$headers = @{ "api-key" = $adminKey; "Content-Type" = "application/json" }

# --- 1. Create (or update) the index --------------------------------------------------
Write-Host "==> Creating/updating index '$index'..." -ForegroundColor Cyan
# Drop the index first so re-seeding is clean (removes any stale/renamed documents).
try { Invoke-RestMethod -Method Delete -Uri "$endpoint/indexes/$index`?api-version=$ApiVersion" -Headers $headers | Out-Null } catch { }
$indexDef = @{
  name   = $index
  fields = @(
    @{ name = "id";       type = "Edm.String"; key = $true;  searchable = $false; filterable = $true  }
    @{ name = "title";    type = "Edm.String"; searchable = $true;  filterable = $false; sortable = $false; analyzer = "en.microsoft" }
    @{ name = "content";  type = "Edm.String"; searchable = $true;  filterable = $false; sortable = $false; analyzer = "en.microsoft" }
    @{ name = "category"; type = "Edm.String"; searchable = $true;  filterable = $true                  }
  )
  # Allow the browser demo (served from 127.0.0.1) to query the index directly for
  # client-side retrieval (retrieve-then-read RAG), which works with any model.
  corsOptions = @{ allowedOrigins = @("*"); maxAgeInSeconds = 300 }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Method Put -Uri "$endpoint/indexes/$index`?api-version=$ApiVersion" -Headers $headers -Body $indexDef | Out-Null
Write-Host "    Index ready." -ForegroundColor Green

# --- 2. Parse enterprise-kb.sample.md into one document per '## ' heading --------------
Write-Host "==> Parsing enterprise-kb.sample.md..." -ForegroundColor Cyan
$md = Get-Content -Raw -Path (Join-Path $PSScriptRoot "enterprise-kb.sample.md")
$lines = $md -split "`r?`n"

$docs = @()
$curTitle = $null
$curBody  = New-Object System.Collections.Generic.List[string]

function Add-Doc {
  param($title, $bodyList)
  if (-not $title) { return }
  # Skip the ingestion how-to section (it isn't knowledge-base content).
  if ($title -match '^Ingesting into') { return }
  $body = ($bodyList -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($body)) { return }
  $slug = ($title.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
  $script:docs += [ordered]@{
    "@search.action" = "mergeOrUpload"
    id       = $slug
    title    = $title
    content  = $body
    category = "enterprise-kb"
  }
}

foreach ($line in $lines) {
  if ($line -match '^\#\#\s+(.*)$' -and $line -notmatch '^\#\#\#') {
    Add-Doc $curTitle $curBody
    $curTitle = $Matches[1].Trim()
    $curBody  = New-Object System.Collections.Generic.List[string]
  }
  elseif ($line -match '^\#\s+') { continue }   # top-level H1 title
  elseif ($line -match '^---\s*$') { Add-Doc $curTitle $curBody; $curTitle = $null; $curBody = New-Object System.Collections.Generic.List[string] }
  else { if ($curTitle) { [void]$curBody.Add($line) } }
}
Add-Doc $curTitle $curBody

if ($docs.Count -eq 0) { throw "No documents parsed from enterprise-kb.sample.md." }
Write-Host "    Parsed $($docs.Count) document(s): $([string]::Join(', ', ($docs | ForEach-Object { $_.title })))" -ForegroundColor DarkGray

# --- 3. Upload the documents ----------------------------------------------------------
Write-Host "==> Uploading documents to '$index'..." -ForegroundColor Cyan
$payload = @{ value = $docs } | ConvertTo-Json -Depth 6
Invoke-RestMethod -Method Post -Uri "$endpoint/indexes/$index/docs/index`?api-version=$ApiVersion" -Headers $headers -Body $payload | Out-Null

Write-Host "==> Done. Seeded '$index' with $($docs.Count) documents." -ForegroundColor Green
Write-Host "    Now run ./serve-local.ps1, tick 'RAG grounding' in Chat, pick a gpt-5* model, and ask about the return policy." -ForegroundColor Green
