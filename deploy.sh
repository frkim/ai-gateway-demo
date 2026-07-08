#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-command deploy for the Azure AI Foundry v2 + APIM AI Gateway demo.
#
# Wraps the Azure Developer CLI (azd) to provision all infrastructure defined in
# main.bicep. Creates/selects the azd environment, sets regions, provisions, then
# prints the gateway endpoint and fetches the APIM subscription key.
#
# No manual Azure Portal steps. Idempotent: safe to re-run.
#
# Usage:
#   ./deploy.sh
#   ENV_NAME=ai-gateway-demo LOCATION=swedencentral SECONDARY_LOCATION=westeurope ./deploy.sh
#   SUBSCRIPTION_ID=<sub-id> ./deploy.sh
# -----------------------------------------------------------------------------
set -euo pipefail

ENV_NAME="${ENV_NAME:-ai-gateway-demo}"
LOCATION="${LOCATION:-swedencentral}"
SECONDARY_LOCATION="${SECONDARY_LOCATION:-westeurope}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"

cd "$(dirname "$0")"

require() { command -v "$1" >/dev/null 2>&1 || { echo "Required tool '$1' not found on PATH." >&2; exit 1; }; }
require azd
require az

echo "==> Ensuring azd is authenticated..."
if ! azd auth login --check-status >/dev/null 2>&1; then
  azd auth login
fi

echo "==> Selecting/creating azd environment '${ENV_NAME}'..."
if azd env list --output json 2>/dev/null | grep -q "\"${ENV_NAME}\""; then
  azd env select "${ENV_NAME}"
else
  if [[ -n "${SUBSCRIPTION_ID}" ]]; then
    azd env new "${ENV_NAME}" --location "${LOCATION}" --subscription "${SUBSCRIPTION_ID}"
  else
    azd env new "${ENV_NAME}" --location "${LOCATION}"
  fi
fi

azd env set AZURE_LOCATION "${LOCATION}"
azd env set SECONDARY_LOCATION "${SECONDARY_LOCATION}"
[[ -n "${SUBSCRIPTION_ID}" ]] && azd env set AZURE_SUBSCRIPTION_ID "${SUBSCRIPTION_ID}"

echo "==> Provisioning infrastructure (this can take ~30-45 min for APIM)..."
azd provision --no-prompt

echo ""
echo "==> Deployment outputs:"
GATEWAY="$(azd env get-value APIM_GATEWAY_URL 2>/dev/null || true)"
RG="$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || true)"
SVC="$(azd env get-value APIM_SERVICE_NAME 2>/dev/null || true)"
ROUTER="$(azd env get-value MODEL_ROUTER_NAME 2>/dev/null || true)"
SEARCH="$(azd env get-value AZURE_SEARCH_ENDPOINT 2>/dev/null || true)"

echo "  Gateway URL : ${GATEWAY}"
echo "  Router      : ${ROUTER}"
echo "  Search      : ${SEARCH}"
echo "  Resource RG : ${RG}"

if [[ -n "${RG}" && -n "${SVC}" ]]; then
  echo ""
  echo "==> Fetching APIM subscription key (not stored in source)..."
  KEY="$(az apim subscription show --resource-group "${RG}" --service-name "${SVC}" \
    --sid ai-gateway-demo --query primaryKey -o tsv)"
  echo "  Subscription key: ${KEY}"
  echo ""
  echo "Next:"
  echo "  python samples/demo.py --from-azd"
  echo "  # or open webapp.html and paste the gateway URL + key above"
fi
