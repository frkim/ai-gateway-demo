#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Failover demo helper for the Azure AI Foundry + APIM AI Gateway demo.
#
# Simulates a primary-region outage by toggling public network access on the
# primary Foundry account. The APIM gateway policy retries throttled/5xx calls
# against the secondary region, so traffic keeps flowing.
#
# Usage:
#   ./failover-demo.sh disable   # simulate primary-region outage
#   ./failover-demo.sh enable    # restore the primary region
#   ./failover-demo.sh status    # show current state
# -----------------------------------------------------------------------------
set -euo pipefail

ACTION="${1:-status}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
require az
require azd

RG="$(azd env get-value AZURE_RESOURCE_GROUP)"
PRIMARY="$(azd env get-value PRIMARY_FOUNDRY_NAME)"

if [[ -z "${RG}" || -z "${PRIMARY}" ]]; then
  echo "Could not read AZURE_RESOURCE_GROUP / PRIMARY_FOUNDRY_NAME from the azd environment." >&2
  echo "Run 'azd up' first." >&2
  exit 1
fi

case "${ACTION}" in
  disable)
    echo "Simulating primary-region outage on ${PRIMARY} ..."
    az cognitiveservices account update \
      --name "${PRIMARY}" --resource-group "${RG}" \
      --custom-domain "${PRIMARY}" \
      --api-properties publicNetworkAccess=Disabled >/dev/null
    echo "Primary disabled. Send a request from the demo client — traffic fails over to the secondary region."
    ;;
  enable)
    echo "Restoring primary region ${PRIMARY} ..."
    az cognitiveservices account update \
      --name "${PRIMARY}" --resource-group "${RG}" \
      --custom-domain "${PRIMARY}" \
      --api-properties publicNetworkAccess=Enabled >/dev/null
    echo "Primary restored."
    ;;
  status)
    az cognitiveservices account show \
      --name "${PRIMARY}" --resource-group "${RG}" \
      --query "{name:name, publicNetworkAccess:properties.publicNetworkAccess}" -o table
    ;;
  *)
    echo "Usage: $0 {disable|enable|status}" >&2
    exit 1
    ;;
esac
