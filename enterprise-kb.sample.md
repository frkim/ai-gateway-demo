# Contoso — Sample Enterprise Knowledge Base

This file is sample content for the Azure AI Search index `enterprise-kb` used by the
RAG demo. Ingest it into the index after provisioning (`./ingest-kb.ps1`). Each `##`
section below becomes one document (fields: id, title, content, category). Content is
fictional and for demonstration only.

## Return policy

Customers may return most items within 30 days of delivery for a full refund. Items must
be unused and in original packaging. Final-sale and personalized items are not eligible
for return. Refunds are issued to the original payment method within 5–7 business days.
To start a return, open the order in the Contoso portal and select "Return items", then
print the prepaid label. Contoso covers return shipping for defective or incorrect items.

## Shipping and delivery

Standard shipping is free on orders over $50 and takes 3–5 business days. Expedited
(2-day) and overnight options are available at checkout for an additional fee. Orders
placed before 2 PM local time ship the same business day. Contoso ships to the US, EU,
UK, and Canada. International orders may be subject to customs duties paid by the
recipient. Tracking numbers are emailed once the carrier scans the package.

## Warranty and repairs

Hardware products include a 2-year limited warranty covering manufacturing defects.
Accidental damage is not covered unless a Contoso Care+ plan was purchased. To file a
warranty claim, provide the serial number and proof of purchase. Approved claims are
repaired or replaced within 10 business days. Batteries and consumable accessories carry
a 90-day warranty.

## Support SLAs

- Standard: response within 8 business hours, Monday–Friday.
- Premium: response within 2 hours, 24x7.
- Sev-1 incidents (production down): 15-minute acknowledgement with continuous updates
  until mitigated.
Support tiers are set by the customer's contract. Premium customers also receive a named
Technical Account Manager and quarterly service reviews.

## Refunds and billing

Subscriptions are billed monthly or annually and renew automatically. Annual plans can be
cancelled for a prorated refund within the first 30 days. Monthly plans are non-refundable
but can be cancelled anytime to stop future charges. Invoices are available in the billing
portal; VAT/GST is applied based on the billing address. Failed payments are retried for
7 days before the account is suspended.

## Security and compliance

Contoso follows a zero-trust model: every request is authenticated and authorized, least
privilege is enforced, and data is encrypted in transit (TLS 1.2+) and at rest (AES-256).
Access to customer data requires managed-identity based authentication; long-lived keys
are prohibited. Contoso maintains SOC 2 Type II, ISO 27001, and ISO 27018 certifications.
Penetration tests are performed at least annually by an independent third party.

## Data privacy and GDPR

Contoso processes personal data as a data processor on behalf of customers. Data subjects
may request access, correction, or deletion of their data via privacy@contoso.example.
Contoso responds to verified requests within 30 days. Customer data is stored in the
region selected at signup (EU data stays in the EU). Contoso does not sell personal data
and uses sub-processors only under a signed Data Processing Agreement (DPA).

## Model usage policy

Only Microsoft/OpenAI models exposed through Azure AI Foundry are approved for production
use. All model calls must go through the enterprise AI Gateway, which enforces guardrails,
token quotas, content safety, and regional failover. Sending secrets, credentials, or
regulated personal data in prompts is prohibited. Model outputs must be reviewed before
being used in customer-facing decisions. Shadow use of unapproved third-party LLM APIs is
not permitted.

## Acceptable use policy

Contoso services may not be used for unlawful, harmful, or abusive activity, including
generating malware, phishing content, or disinformation. Automated scraping of the service
beyond published rate limits is prohibited. Violations may result in suspension. Report
suspected abuse to abuse@contoso.example.

## Password reset and account access

To reset a password, use "Forgot password" on the sign-in page; a reset link is valid for
30 minutes. Accounts lock for 15 minutes after 5 failed attempts. Multi-factor
authentication (MFA) is mandatory for all employees and admin accounts. Account recovery
for a locked admin account requires verification by the IT service desk. Never share
credentials; use the corporate SSO instead.

## VPN and remote access

Employees connect to internal resources through the corporate VPN using SSO and MFA.
Split tunneling is disabled; all traffic is inspected. Personal devices must be enrolled
in mobile device management (MDM) and meet the minimum patch level before access is
granted. VPN sessions expire after 12 hours and require re-authentication.

## Expense and travel policy

Employees may expense reasonable, business-related travel. Economy airfare is the default;
premium classes require director approval. Hotel stays are reimbursed up to the city cap.
Meals are reimbursed up to $75/day domestic and $100/day international. Receipts are
required for any expense over $25. Submit expenses in the finance portal within 30 days of
the trip. Personal entertainment and alcohol are not reimbursable.

## Paid time off (PTO)

Full-time employees accrue 20 days of PTO per year plus public holidays. PTO accrues
monthly and up to 5 unused days carry over to the next year. Sick leave is separate and
capped at 10 days per year. Submit PTO requests at least 2 weeks in advance for approval
by your manager. Parental leave is 16 weeks fully paid.

## Onboarding new employees

New hires complete identity verification, security training, and device enrollment on day
one. Access to systems is granted based on role via the access-request portal and requires
manager approval. Mandatory security awareness training must be completed within the first
week. A buddy is assigned for the first 30 days. Equipment is shipped to arrive before the
start date.

## Incident management

Incidents are classified Sev-1 (critical/production down) to Sev-4 (low). Sev-1 triggers
an immediate page to the on-call engineer and creation of a bridge call. A post-incident
review (blameless postmortem) is required for all Sev-1 and Sev-2 incidents within 5
business days. Customer-impacting incidents are communicated on the public status page.

## Procurement and vendor management

Purchases over $5,000 require a purchase order and manager approval; over $50,000 require
finance and legal review. New vendors must pass a security and privacy assessment before
onboarding. Software must be on the approved list or go through architecture review.
Renewals are reviewed 60 days before expiry to avoid auto-renewal lock-in.

---

## Ingesting into Azure AI Search

After `azd provision`, run `./ingest-kb.ps1` to create the `enterprise-kb` index and
upload each section above as a document. The script uses the Search admin key for the
one-time seed; the runtime RAG path uses a read-only query key (see `serve-local.ps1`).

```bash
SEARCH=$(azd env get-value AZURE_SEARCH_ENDPOINT)
INDEX=$(azd env get-value AZURE_SEARCH_INDEX_NAME)
echo "Target index: $INDEX at $SEARCH"
```
