# GitHub Agents — Azure AI Gateway Demo

This directory contains the GitHub custom agents that implement the
**Azure AI Foundry v2 + Azure API Management (APIM) AI Gateway** demo described in
[issue #1](https://github.com/frkim/ai-gateway-demo/issues/1). Each agent is a Markdown
file with YAML frontmatter (`name`, `description`, `tools`) followed by its operating
instructions.

## Main orchestrator

- [`orchestrator`](./orchestrator.md) — the entry point. Plans the end-to-end build,
  delegates to the specialized agents, and enforces the cross-cutting constraints
  (deployable with `azd`, Bicep IaC, no manual portal steps, configurable model names,
  **no Mistral**, secrets in Key Vault, managed identity).

## Specialized agents

| Agent | Responsibility |
| --- | --- |
| [`infrastructure`](./infrastructure.md) | `azd` project + Bicep modules; core platform resources and shared outputs |
| [`ai-foundry-models`](./ai-foundry-models.md) | Foundry v2 accounts, multi-region model deployments, native model router, configurable models & fallbacks |
| [`apim-ai-gateway`](./apim-ai-gateway.md) | Single gateway endpoint; policies for routing, load balancing/failover, semantic caching, token limits & metrics |
| [`security-guardrails`](./security-guardrails.md) | Content safety, jailbreak/PII protection, token-level governance, secrets hygiene |
| [`knowledge-grounding`](./knowledge-grounding.md) | Foundry IQ / Azure AI Search RAG over a sample enterprise knowledge base |
| [`backend-api`](./backend-api.md) | Backend API that calls the gateway and serves the frontend |
| [`frontend-react`](./frontend-react.md) | React + TypeScript UI with demo controls for each capability |
| [`observability`](./observability.md) | Azure Monitor / App Insights / Log Analytics dashboards; failover simulation |
| [`cicd-github-actions`](./cicd-github-actions.md) | GitHub Actions + `azd` deployment with OIDC federated auth |

## Recommended build order

1. `infrastructure` → 2. `ai-foundry-models` → 3. `apim-ai-gateway` →
4. `security-guardrails` → 5. `knowledge-grounding` → 6. `backend-api` →
7. `frontend-react` → 8. `observability` → 9. `cicd-github-actions`.

Start every task with the [`orchestrator`](./orchestrator.md), which coordinates the
above.
