# CI/CD (GitHub Actions + azd)

Automate `provision` with GitHub Actions using `azd` and a **service-principal secret**
stored in GitHub. The workflow lives at
[.github/workflows/azure-dev.yml](.github/workflows/azure-dev.yml) and defaults to the
**Sweden Central** region.

## Credentials (already configured)

An Azure service principal (`ai-gateway-demo-github`) with **Contributor** and **User
Access Administrator** on the subscription authenticates the pipeline. Its credentials are
stored as GitHub repository **secrets**:

| Secret | Description |
| --- | --- |
| `AZURE_CREDENTIALS` | Full SP credential JSON (used by `azure/login` and `azd`) |
| `AZURE_CLIENT_ID` | App (client) id |
| `AZURE_TENANT_ID` | Tenant id |
| `AZURE_SUBSCRIPTION_ID` | Target subscription |

And repository **variables** (defaults; override per run via `workflow_dispatch`):

| Variable | Default |
| --- | --- |
| `AZURE_ENV_NAME` | `ai-gateway-demo` |
| `AZURE_LOCATION` | `swedencentral` |
| `SECONDARY_LOCATION` | `westeurope` |

## Workflow

The committed workflow logs in with the service principal and runs `azd provision`:

- `on: workflow_dispatch` (with optional `location` / `secondaryLocation` inputs) and
  `push` to `main` when infra files change.
- `AZURE_LOCATION` defaults to **swedencentral**.

Trigger it manually:

```bash
gh workflow run azure-dev.yml --repo <owner>/<repo>
# or override the region for a single run
gh workflow run azure-dev.yml --repo <owner>/<repo> -f location=swedencentral
```

## Re-creating the credentials

If you need to recreate the service principal and secrets:

```bash
SUB=<subscription-id>
REPO=<owner>/<repo>

# 1) Create the SP with Contributor, capture the credential JSON
CREDS=$(az ad sp create-for-rbac --name ai-gateway-demo-github \
  --role Contributor --scopes "/subscriptions/$SUB" --json-auth)
APP_ID=$(echo "$CREDS" | jq -r .clientId)

# 2) Add User Access Administrator (the template creates role assignments)
az role assignment create --assignee "$APP_ID" \
  --role "User Access Administrator" --scope "/subscriptions/$SUB"

# 3) Store the secrets
echo "$CREDS"  | gh secret set AZURE_CREDENTIALS     --repo "$REPO"
echo "$APP_ID" | gh secret set AZURE_CLIENT_ID       --repo "$REPO"
az account show --query tenantId -o tsv | gh secret set AZURE_TENANT_ID --repo "$REPO"
echo "$SUB"    | gh secret set AZURE_SUBSCRIPTION_ID --repo "$REPO"

# 4) Set default region variables (Sweden Central primary)
gh variable set AZURE_ENV_NAME     --body ai-gateway-demo --repo "$REPO"
gh variable set AZURE_LOCATION     --body swedencentral   --repo "$REPO"
gh variable set SECONDARY_LOCATION --body westeurope      --repo "$REPO"
```

> **OIDC alternative (more secure):** replace the SP secret with federated credentials via
> `azd pipeline config --provider github --auth-type federated`. That stores only
> `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` (no password) and uses
> `permissions: id-token: write` with `azure/login` in OIDC mode.
