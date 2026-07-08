# Configuration — no hardcoded models

All model names, regions and endpoints are **configuration-driven**. Nothing about the
model catalog is hardcoded in business logic: the app receives the deployment names and
the gateway endpoint from `azd` outputs / environment variables, and the Bicep template
receives the model catalog through the `chatModelDeployments` parameter.

## `azd` environment variables

Set these with `azd env set <NAME> <VALUE>` before `azd up`, or accept the defaults.

| Variable | Purpose | Default |
| --- | --- | --- |
| `AZURE_LOCATION` | Primary region + primary Foundry account | `swedencentral` (prompted) |
| `SECONDARY_LOCATION` | Secondary / failover region | `westeurope` |
| `MODEL_ROUTER_NAME` | Native Foundry model router deployment name | `model-router` |
| `APIM_PUBLISHER_EMAIL` | Required APIM publisher email | `admin@contoso.com` |
| `APIM_PUBLISHER_NAME` | APIM publisher org name | `Contoso AI Platform` |

## Model catalog (`chatModelDeployments`)

The default catalog (see `main.bicep`) deploys the `model-router` in the **primary**
region and the gpt-5 family in **both** regions:

| Deployment | Model | Region(s) | Purpose |
| --- | --- | --- | --- |
| `model-router` | `model-router` (2025-11-18) | Primary only | Native Foundry routing across the family |
| `gpt-5-mini` | `gpt-5-mini` (2025-08-07) | Primary + Secondary | Fast / cheap |
| `gpt-5` | `gpt-5` (2025-08-07) | Primary + Secondary | Balanced |
| `gpt-5-nano` | `gpt-5-nano` (2025-08-07) | Primary + Secondary | Ultra-low latency |

> The native `model-router` is only offered in Sweden Central among EU-residency regions.
> It is deployed in the primary region only; set `routerInSecondary=true` if your
> secondary region offers it. Multi-region failover uses `gpt-5-mini` (present in both).

> **No Mistral is used anywhere in this demo.** Only Microsoft/OpenAI models available
> through Microsoft Foundry are deployed.

### Overriding the catalog / regional fallbacks

If a preferred model or version is not available in your subscription or target region,
override the catalog. Because it is an array parameter, edit the default in
`main.bicep`, or pass a parameter file / inline parameters at deploy time. Documented
fallbacks (all non-Mistral):

| Preferred | Fallback options |
| --- | --- |
| `gpt-5` | `gpt-4.1` |
| `gpt-5-mini` | `gpt-4.1-mini` |
| `gpt-5-nano` | `o4-mini` |
| `model-router` | any single chat deployment above |

Model **versions** in the default catalog are examples; set the `version` for each entry
to a value returned by:

```bash
az cognitiveservices account list-models \
  --name <foundry-account> --resource-group <rg> \
  --query "[].{model:name, version:version}" -o table
```

## Semantic caching

For simplicity and zero-secret deployment, the gateway uses APIM's **built-in cache**
(`cache-store-value` / `cache-lookup-value`) keyed on a SHA-256 hash of the prompt.
Responses carry an `x-cache: HIT|MISS` header so the UI and dashboards can show cache
effectiveness.

To upgrade to **true semantic (embedding-similarity) caching**:

1. Provision an Azure Cache for Redis and wire it as an APIM external cache
   (`Microsoft.ApiManagement/service/caches`).
2. Keep the embedding deployment (`text-embedding-3-small` by default).
3. Replace the built-in cache policy fragments with
   `azure-openai-semantic-cache-lookup` / `azure-openai-semantic-cache-store`
   referencing an `embeddings-backend`.

## Guardrails

The gateway policy includes a lightweight prompt-injection / jailbreak guardrail. For
production, replace it with the `llm-content-safety` policy backed by an Azure AI Content
Safety resource (add the resource + an APIM backend, then reference it in the policy).

## Secrets

No secrets are committed. Service-to-service auth uses **managed identity**
(`authentication-managed-identity` in the APIM policy; user-assigned identity for the
app). The APIM subscription key is generated at deploy time and can be stored in Key
Vault; it is never written to source.
