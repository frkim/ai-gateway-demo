# Contoso — Sample Enterprise Knowledge Base

This file is sample content for the Azure AI Search index `enterprise-kb` used by the
RAG demo. Ingest it into the index after provisioning (see below). Content is fictional.

## Return policy

Customers may return most items within 30 days of delivery for a full refund. Items must
be unused and in original packaging. Final-sale and personalized items are not eligible
for return. Refunds are issued to the original payment method within 5–7 business days.

## Support SLAs

- Standard: response within 8 business hours.
- Premium: response within 2 hours, 24x7.
- Sev-1 incidents (production down): 15-minute acknowledgement, continuous updates.

## Security & compliance

Contoso follows a zero-trust model: every request is authenticated and authorized, least
privilege is enforced, and data is encrypted in transit and at rest. Access to customer
data requires managed-identity based authentication; long-lived keys are prohibited.

## Model usage policy

Only Microsoft/OpenAI models exposed through Azure AI Foundry are approved. All model
calls must go through the enterprise AI Gateway, which enforces guardrails, token quotas,
and regional failover.

---

## Ingesting into Azure AI Search

After `azd up`, create the index and push these documents (chunked by heading). Using
managed identity, no admin keys required if you are assigned a Search data role:

```bash
SEARCH=$(azd env get-value AZURE_SEARCH_ENDPOINT)
INDEX=$(azd env get-value AZURE_SEARCH_INDEX_NAME)
# Use the Azure AI Search REST API or the Python SDK to create the "enterprise-kb"
# index (fields: id, title, content, content_vector) and upload the sections above.
echo "Target index: $INDEX at $SEARCH"
```
