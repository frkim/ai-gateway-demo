# Demo runbook

A ~15 minute walkthrough for enterprise architects / platform teams / CIO stakeholders.

## 0. Provision

```bash
azd auth login
azd env new ai-gateway-demo
azd env set SECONDARY_LOCATION westeurope
azd up           # pick the primary region when prompted (e.g. swedencentral)
```

After provisioning, capture the outputs:

```bash
azd env get-values | grep -E 'APIM_GATEWAY_URL|MODEL_ROUTER_NAME|AZURE_SEARCH_ENDPOINT'
```

Get an APIM subscription key (kept out of source):

```bash
az apim subscription show \
  --resource-group $(azd env get-value AZURE_RESOURCE_GROUP) \
  --service-name  $(azd env get-value APIM_SERVICE_NAME) \
  --sid ai-gateway-demo --query primaryKey -o tsv
```

## 1. Model abstraction & the single endpoint

Open `webapp.html`, paste the `APIM_GATEWAY_URL` and subscription key. Send a prompt to
`model-router`. Show that the client only ever calls **one** URL regardless of model.

## 2. Native Foundry model router

Keep the deployment as `model-router`. Ask a hard reasoning question then a trivial one;
show (via the response `model` field) that Foundry routed to different underlying models.

## 3. Token governance

Send several large prompts quickly. Show the `x-remaining-tokens` /
`x-consumed-tokens` response headers and, once the per-minute budget is exceeded, the
`429` returned by the `azure-openai-token-limit` policy.

## 4. Guardrails

Send a prompt containing `ignore previous instructions`. The gateway returns
`400 content_safety_blocked` — blocked before reaching the model.

## 5. Caching

Ask the same question twice. The first response has `x-cache: MISS`, the second
`x-cache: HIT` with much lower latency.

## 6. Multi-region failover

Run the failover demo to disable the primary Foundry account and watch traffic move to
the secondary region (the `x-served-backend` header changes). Use a concrete model that
exists in both regions (`gpt-5-mini`) — the native `model-router` is primary-region only:

```bash
./failover-demo.sh disable   # blocks the primary account
# send a gpt-5-mini request from webapp.html or:
#   python samples/demo.py --from-azd --only failover
# -> x-served-backend now points to the secondary region
./failover-demo.sh enable    # restore the primary account
```

## 7. Knowledge grounding (RAG)

Toggle **RAG** in the client. Answers are grounded in the sample enterprise knowledge
base served by Azure AI Search (index `enterprise-kb`).

## 8. Observability

Open Application Insights for the resource group and view the `ai-gateway` custom token
metrics (dimensions: Deployment, Backend, Subscription), request latency, and failover
events.
