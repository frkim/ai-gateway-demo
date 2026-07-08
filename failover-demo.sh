#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Failover demo helper for the Azure AI Foundry + APIM AI Gateway demo.
#
# Simulates a primary-region outage by repointing the APIM 'foundry-primary'
# backend to an unreachable URL. The gateway policy retries an unreachable/failed
# primary against the secondary region, so traffic keeps flowing — the
# 'x-served-backend' response header flips to the secondary Foundry host.
#
# Usage:
#   ./failover-demo.sh disable   # simulate primary-region outage
#   ./failover-demo.sh enable    # restore the primary region
#   ./failover-demo.sh status    # show the current primary backend URL
# -----------------------------------------------------------------------------
set -euo pipefail

ACTION="${1:-status}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
require az
require azd

SUB="$(azd env get-value AZURE_SUBSCRIPTION_ID 2>/dev/null || true)"
RG="$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || true)"
APIM="$(azd env get-value APIM_SERVICE_NAME 2>/dev/null || true)"
PRIMARY_ENDPOINT="$(azd env get-value PRIMARY_FOUNDRY_ENDPOINT 2>/dev/null || true)"

if [[ -z "${SUB}" || -z "${RG}" || -z "${APIM}" || -z "${PRIMARY_ENDPOINT}" ]]; then
  echo "Could not read AZURE_SUBSCRIPTION_ID / AZURE_RESOURCE_GROUP / APIM_SERVICE_NAME / PRIMARY_FOUNDRY_ENDPOINT" >&2
  echo "from the azd environment. Run 'azd provision' first." >&2
  exit 1
fi

API_VERSION="2023-05-01-preview"
BASE="https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM}/backends/foundry-primary?api-version=${API_VERSION}"
GOOD_URL="${PRIMARY_ENDPOINT%/}/openai"
BAD_URL="https://aif-primary-unreachable-000000.cognitiveservices.azure.com/openai"

set_backend_url() {
  az rest --method patch --uri "${BASE}" \
    --headers "Content-Type=application/json" \
    --body "{\"properties\":{\"url\":\"$1\",\"protocol\":\"http\"}}" \
    --query "properties.url" -o tsv
}

case "${ACTION}" in
  disable)
    echo "Simulating primary-region outage (repointing foundry-primary backend) ..."
    set_backend_url "${BAD_URL}" >/dev/null
    echo "Primary disabled. Send a gpt-5-mini request (e.g. python samples/demo.py --from-azd --only failover)"
    echo "-> x-served-backend now points to the secondary region."
    ;;
  enable)
    echo "Restoring primary region backend ..."
    set_backend_url "${GOOD_URL}" >/dev/null
    echo "Primary restored to ${GOOD_URL}."
    ;;
  status)
    CURRENT="$(az rest --method get --uri "${BASE}" --query "properties.url" -o tsv)"
    echo "foundry-primary backend URL: ${CURRENT}"
    if [[ "${CURRENT}" == "${GOOD_URL}" ]]; then echo "state: PRIMARY (healthy)"; else echo "state: FAILED-OVER (primary unreachable)"; fi
    ;;
  *)
    echo "Usage: $0 {disable|enable|status}" >&2
    exit 1
    ;;
esac
