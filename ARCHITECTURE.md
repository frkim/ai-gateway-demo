# Architecture

The demo exposes an enterprise **AI Gateway** — a single, governed HTTPS endpoint on
**Azure API Management (APIM)** in front of **Azure AI Foundry v2** (Azure OpenAI) across
two regions. Clients never talk to Foundry directly; the gateway centrally enforces model
abstraction, safety, token governance, caching, observability and multi-region failover.

Everything is provisioned by a single self-contained `main.bicep` via `azd` — no manual
Azure Portal steps.

## System overview

```mermaid
flowchart TB
  subgraph Clients
    WEB["webapp.html<br/>(React demo dashboard)"]
    PY["samples/demo.py<br/>(Python demo)"]
    REST["requests.http<br/>(REST Client)"]
  end

  subgraph APIM["Azure API Management — AI Gateway"]
    API["ai-gateway API<br/>path: /ai · single endpoint"]
    POL["Inbound/Backend/Outbound policy:<br/>CORS · guardrail · token-limit<br/>managed-identity auth · cache · emit-metric<br/>retry → secondary"]
    subgraph BE["Backends"]
      BP["foundry-primary<br/>(circuit breaker)"]
      BS["foundry-secondary"]
    end
  end

  subgraph Primary["Foundry — Primary (Sweden Central)"]
    FP["AIServices account<br/>disableLocalAuth"]
    MP["model-router · gpt-5 · gpt-5-mini<br/>gpt-5-nano · text-embedding-3-small"]
  end
  subgraph Secondary["Foundry — Secondary (West Europe)"]
    FS["AIServices account<br/>disableLocalAuth"]
    MS["gpt-5 · gpt-5-mini · gpt-5-nano"]
  end

  SRCH["Azure AI Search<br/>index: enterprise-kb (RAG)"]
  OBS["Log Analytics +<br/>Application Insights"]
  KV["Key Vault (RBAC)"]
  MI["User-assigned<br/>Managed Identity"]

  WEB & PY & REST -->|"Ocp-Apim-Subscription-Key"| API
  API --> POL
  POL --> BP --> FP --> MP
  POL -.->|"429 / 5xx / 403 / unreachable"| BS --> FS --> MS
  POL -->|"managed identity (no keys)"| FP
  API -. RAG .-> SRCH
  APIM -->|token metrics · traces| OBS
  MI --> SRCH
  MI --> KV

  classDef region fill:#0f2a1f,stroke:#1f7a3f,color:#d7f5e3;
  classDef gw fill:#122036,stroke:#34508c,color:#cfe0ff;
  class Primary,Secondary region;
  class APIM gw;
```

## Request lifecycle

```mermaid
sequenceDiagram
  autonumber
  participant C as Client
  participant G as APIM AI Gateway
  participant P as Foundry Primary
  participant S as Foundry Secondary

  C->>G: POST /ai/deployments/{id}/chat/completions
  Note over G: CORS (browser)
  Note over G: Guardrail regex → 400 if jailbreak/prompt-injection
  Note over G: azure-openai-token-limit → 429 if over budget
  Note over G: cache-lookup → return cached (x-cache: HIT) if present
  Note over G: authentication-managed-identity → Bearer token (no keys)
  G->>P: forward (Authorization: Bearer, api-version)
  alt Primary healthy
    P-->>G: 200 + completion
  else Primary 429/5xx/403/unreachable
    G->>S: retry on secondary backend
    S-->>G: 200 + completion
  end
  Note over G: emit token metric (Deployment/Backend/Subscription)
  Note over G: cache-store (x-cache: MISS) · set x-served-backend
  G-->>C: response + headers (x-cache, x-served-backend, x-remaining-tokens)
```

## Multi-region failover

```mermaid
sequenceDiagram
  autonumber
  participant Ops as Operator
  participant AZ as azd / failover-demo.sh
  participant G as APIM Gateway
  participant P as Foundry Primary
  participant S as Foundry Secondary

  Ops->>AZ: ./failover-demo.sh disable
  AZ->>G: repoint foundry-primary backend → unreachable URL
  Note over G: circuit breaker trips on repeated failures
  G->>P: forward (fails)
  G->>S: retry → secondary (x-served-backend = secondary host)
  S-->>G: 200
  Ops->>AZ: ./failover-demo.sh enable
  AZ->>G: restore foundry-primary backend URL
```

> The native `model-router` is only offered in Sweden Central among EU-residency regions,
> so it is deployed in the **primary** region only. Failover therefore uses a concrete
> model present in both regions (`gpt-5-mini`). Set `routerInSecondary=true` if your
> secondary region offers the router.

## Components (all in `main.bicep`, resourceGroup-scoped)

| Resource | Role |
| --- | --- |
| Log Analytics + Application Insights | Observability backbone (token metrics, traces) |
| User-assigned managed identity | App-tier identity (Search + Key Vault) |
| Key Vault (RBAC) | Demo secret store (e.g. APIM subscription key) |
| Azure AI Foundry (AIServices) ×2 | Primary + secondary regions, `disableLocalAuth: true` |
| Model deployments | `model-router` (primary), `gpt-5` / `gpt-5-mini` / `gpt-5-nano` (both), `text-embedding-3-small` (primary) |
| Azure AI Search | Enterprise knowledge grounding (RAG), index `enterprise-kb` |
| API Management (Developer) | The AI Gateway — single endpoint + policy + backends |
| Role assignments | APIM→Foundry (Cognitive Services OpenAI User), app→Search / Key Vault |

## Gateway policy pipeline

The single API policy (built inline in `main.bicep`) runs, in order:

| Stage | Policy | Purpose |
| --- | --- | --- |
| inbound | `cors` | Let the browser client call the gateway and read custom headers |
| inbound | `set-variable deployment-id` | Default to the native router when no model is specified |
| inbound | guardrail `choose` + `return-response` | Block prompt-injection / jailbreak → `400` |
| inbound | `azure-openai-token-limit` | Per-subscription tokens-per-minute budget → `429` |
| inbound | `cache-lookup-value` | Return cached response → `x-cache: HIT` |
| inbound | `authentication-managed-identity` | Bearer token to Foundry (no keys) |
| inbound | `set-backend-service foundry-primary` | Start on the primary region |
| inbound | `azure-openai-emit-token-metric` | Token metrics to Application Insights |
| backend | `retry` + `set-backend-service foundry-secondary` | Failover on unreachable/403/429/5xx |
| outbound | `cache-store-value` | Populate cache → `x-cache: MISS` |
| outbound | `set-header x-served-backend` | Expose which region answered |

## Managed identity flow

APIM has a system-assigned identity granted **Cognitive Services OpenAI User** on both
Foundry accounts. The inbound policy calls
`authentication-managed-identity resource="https://cognitiveservices.azure.com"` and sets
the `Authorization: Bearer` header — so **no API keys** are used or stored. Foundry
accounts have `disableLocalAuth: true`.

## Configuration & regions

- Primary region defaults to **Sweden Central**, secondary to **West Europe** (both
  EU-residency compliant).
- Model names are **never hardcoded** in logic — they flow from the `chatModelDeployments`
  parameter in `main.bicep` to the clients via `azd` outputs.
- See [CONFIGURATION.md](CONFIGURATION.md) for overrides, fallbacks and semantic caching.

## Design notes

- **Single self-contained template.** `main.bicep` is `resourceGroup`-scoped; `azd`
  creates the resource group and provisions everything with `azd provision`.
- **Built-in cache** (hash of the prompt) is used for zero-secret response caching; swap
  to `azure-openai-semantic-cache-*` with Azure Cache for Redis for true semantic caching.
- **Guardrail** is a lightweight regex for the demo; replace with the `llm-content-safety`
  policy backed by Azure AI Content Safety for production.
