# Architecture

```text
User
  -> React + TypeScript frontend (webapp.html single-file demo client)
    -> Azure API Management AI Gateway  (single HTTPS endpoint: {apim}/ai)
        - managed-identity auth to Foundry (no keys)
        - prompt-injection / jailbreak guardrail
        - token-per-minute governance (azure-openai-token-limit)
        - response caching (x-cache HIT/MISS)
        - token metrics (azure-openai-emit-token-metric)
        - primary -> secondary failover (retry + circuit breaker)
      -> Azure AI Foundry (Primary region)   -- native model-router + gpt-5 family
      -> Azure AI Foundry (Secondary region) -- native model-router + gpt-5 family
    -> Azure AI Search (enterprise knowledge base, RAG)
  -> Azure Monitor / Application Insights / Log Analytics
```

## Components (all in `main.bicep`, resourceGroup-scoped)

| Resource | Role |
| --- | --- |
| Log Analytics + Application Insights | Observability backbone |
| User-assigned managed identity | App-tier identity (RAG + Key Vault) |
| Key Vault (RBAC) | Demo secret store (e.g. APIM subscription key) |
| Azure AI Foundry (AIServices) x2 | Primary + secondary regions, `disableLocalAuth` |
| Model deployments | `model-router`, `gpt-5-mini`, `gpt-5`, `gpt-5-chat`, `gpt-5-nano` in each region |
| Azure AI Search | Enterprise knowledge grounding (RAG) |
| API Management (Developer) | The AI Gateway (single endpoint + policy) |
| Role assignments | APIM->Foundry (OpenAI User), app->Search/Key Vault |

## Why a single gateway endpoint

- **Model abstraction:** clients always call `{apim}/ai/deployments/{deployment-id}/...`.
  The `deployment-id` can be `model-router` (native routing) or a specific model.
- **Governance:** token limits, guardrails, caching, metrics and failover are enforced
  centrally — not in every client.
- **Reliability:** the policy retries throttled/5xx calls against the secondary region.

## Managed identity flow

APIM has a system-assigned identity granted **Cognitive Services OpenAI User** on both
Foundry accounts. The inbound policy calls
`authentication-managed-identity resource="https://cognitiveservices.azure.com"` and sets
the `Authorization: Bearer` header — so no API keys are used or stored.

## Directory note

This template intentionally keeps the Bicep as a single self-contained,
`resourceGroup`-scoped `main.bicep` at the repository root. `azd` creates the resource
group automatically and provisions everything with `azd up` — no manual Azure Portal
steps.
