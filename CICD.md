# CI/CD (GitHub Actions + azd)

Automate `provision` + `deploy` with GitHub Actions using `azd` and **OIDC federated
credentials** (no stored secrets).

## One-time setup

```bash
azd pipeline config --provider github
```

This creates the federated credential / app registration and sets the repository
variables used below.

## Workflow

Add the following as `.github/workflows/azure-dev.yml` (this template ships the YAML here
because the repo tooling used to scaffold it could not create the `.github/workflows`
directory; copy it verbatim):

```yaml
name: azure-dev

on:
  workflow_dispatch:
  push:
    branches: [ main ]

permissions:
  id-token: write
  contents: read

jobs:
  provision-and-deploy:
    runs-on: ubuntu-latest
    env:
      AZURE_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}
      AZURE_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
      AZURE_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      AZURE_ENV_NAME: ${{ vars.AZURE_ENV_NAME }}
      AZURE_LOCATION: ${{ vars.AZURE_LOCATION }}
    steps:
      - uses: actions/checkout@v4
      - name: Install azd
        uses: Azure/setup-azd@v2
      - name: Log in with azd (federated OIDC)
        run: |
          azd auth login \
            --client-id "$AZURE_CLIENT_ID" \
            --federated-credential-provider "github" \
            --tenant-id "$AZURE_TENANT_ID"
      - name: Validate Bicep
        run: az bicep build --file main.bicep
      - name: Provision infrastructure
        run: azd provision --no-prompt
```

## Required repository variables

| Variable | Description |
| --- | --- |
| `AZURE_CLIENT_ID` | App registration (federated) client id |
| `AZURE_TENANT_ID` | Tenant id |
| `AZURE_SUBSCRIPTION_ID` | Target subscription |
| `AZURE_ENV_NAME` | azd environment name |
| `AZURE_LOCATION` | Primary region |

No secrets are stored: authentication uses OIDC federation.
