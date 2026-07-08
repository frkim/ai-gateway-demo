# Python demo — Azure AI Gateway

`demo.py` exercises every AI Gateway capability through the single enterprise
endpoint. It uses only the Python standard library (no pip install required) and reads
all configuration from your `azd` environment, so nothing is hardcoded.

## Prerequisites

- Python 3.10+
- The infrastructure provisioned (`azd provision`) and the `ai-gateway-demo` azd
  environment selected.
- `az` CLI logged in (used once to fetch the APIM subscription key).

## Run

```bash
# from the repository root, with the azd environment selected
python samples/demo.py --from-azd
```

Run a single scenario:

```bash
python samples/demo.py --from-azd --only cache
python samples/demo.py --from-azd --only guardrail --only tokens
```

Or pass connection details explicitly (no azd needed):

```bash
python samples/demo.py \
  --gateway https://apim-xxxx.azure-api.net/ai \
  --key <APIM-subscription-key>
```

## Scenarios

| Name | Demonstrates |
| --- | --- |
| `abstraction` | One URL, many deployments (model abstraction) |
| `router` | Native Foundry model router selecting the underlying model |
| `guardrail` | Prompt-injection / jailbreak blocked with HTTP 400 |
| `cache` | `x-cache: MISS` then `HIT` with lower latency |
| `tokens` | Per-minute token budget enforced with HTTP 429 |
| `failover` | `x-served-backend` header; pair with `failover-demo.sh` |

## Failover walkthrough

```bash
python samples/demo.py --from-azd --only failover   # note the backend host
./failover-demo.sh disable                           # simulate primary outage
python samples/demo.py --from-azd --only failover   # backend host now = secondary region
./failover-demo.sh enable                            # restore the primary
```

> The native `model-router` deployment lives in the primary region only (it is not
> offered in most EU regions), so the failover scenario uses a concrete model
> (`gpt-5-mini`) that exists in both regions.
