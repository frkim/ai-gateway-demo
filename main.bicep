targetScope = 'resourceGroup'

// =============================================================================
// Azure AI Foundry v2 + APIM AI Gateway demo — self-contained infrastructure.
// Deployable end-to-end with `azd up` (azd creates the resource group).
// No model names are hardcoded in business logic: they are driven by the
// `chatModelDeployments` parameter and surfaced to the app via outputs.
// =============================================================================

@minLength(1)
@maxLength(64)
@description('Name of the environment; used to derive a short unique resource token.')
param environmentName string

@description('Primary Azure region (also the resource group / primary Foundry region).')
param location string = resourceGroup().location

@description('Secondary Azure region used for multi-region operations and failover.')
param secondaryLocation string = 'westeurope'

@description('Object id of the signed-in user/service principal for local data-plane access.')
param principalId string = ''

@description('Native Foundry model router deployment name. Configuration-driven.')
param modelRouterName string = 'model-router'

@description('''
Set true only when the SECONDARY region also offers the native Foundry model router.
Most EU regions do not (only Sweden Central does today), so the router is deployed in the
primary region only and the gpt-5 family is used for multi-region failover.
''')
param routerInSecondary bool = false

@description('APIM publisher email (required by APIM).')
param publisherEmail string = 'admin@contoso.com'

@description('APIM publisher organization name.')
param publisherName string = 'Contoso AI Platform'

@description('Deploy Azure API Management (the AI Gateway). Set false to skip for a quick infra-only run.')
param deployApim bool = true

@description('Enable APIM semantic caching (provisions Azure Cache for Redis + wires it as external cache).')
param enableSemanticCache bool = true

@description('Embedding model deployment used by the semantic cache lookup policy.')
param embeddingDeploymentName string = 'text-embedding-3-small'

@description('Embedding model version (configurable — set to a version available in your region).')
param embeddingModelVersion string = '1'

@description('Azure OpenAI data-plane API version used by the gateway API.')
param openAiApiVersion string = '2024-10-21'

@description('''
Chat/completions model deployments created in BOTH Foundry regions.
Model names are NEVER hardcoded in application logic — change them here or via
deployment parameters. If a preferred model is unavailable in a region, replace it
with a documented fallback (see docs/CONFIGURATION.md).
''')
param chatModelDeployments array = [
  {
    name: 'model-router'
    model: { name: 'model-router', version: '2025-11-18' }
    sku: { name: 'GlobalStandard', capacity: 50 }
  }
  {
    name: 'gpt-5-mini'
    model: { name: 'gpt-5-mini', version: '2025-08-07' }
    sku: { name: 'GlobalStandard', capacity: 50 }
  }
  {
    name: 'gpt-5'
    model: { name: 'gpt-5', version: '2025-08-07' }
    sku: { name: 'GlobalStandard', capacity: 30 }
  }
  {
    name: 'gpt-5-nano'
    model: { name: 'gpt-5-nano', version: '2025-08-07' }
    sku: { name: 'GlobalStandard', capacity: 50 }
  }
]

@description('Tokens-per-minute budget enforced per subscription key by the APIM token-limit policy. Kept intentionally low so the demo reaches the 429 limit after a couple of calls.')
param tokensPerMinute int = 2000

// -----------------------------------------------------------------------------
// Naming & tags
// -----------------------------------------------------------------------------
var resourceToken = toLower(uniqueString(resourceGroup().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
  solution: 'ai-gateway-demo'
}

// Well-known role definition ids
var roleCognitiveServicesOpenAiUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var roleSearchIndexDataReader = '1407120a-92aa-4202-b7e9-c0e197c71c8f'
var roleSearchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var roleKeyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'

// -----------------------------------------------------------------------------
// Observability: Log Analytics + Application Insights
// -----------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${resourceToken}'
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: { name: 'PerGB2018' }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${resourceToken}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// -----------------------------------------------------------------------------
// User-assigned managed identity for the application tier
// -----------------------------------------------------------------------------
resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${resourceToken}'
  location: location
  tags: tags
}

// -----------------------------------------------------------------------------
// Key Vault (RBAC) for demo secrets (e.g. APIM subscription key)
// -----------------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${resourceToken}'
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    publicNetworkAccess: 'Enabled'
  }
}

// -----------------------------------------------------------------------------
// Azure AI Foundry (AIServices) — primary & secondary regions.
// allowProjectManagement + a child `projects` resource use the new Foundry format
// (an account of Type "Foundry" that contains a proper Foundry project).
// -----------------------------------------------------------------------------
resource foundryPrimary 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: 'aif-primary-${resourceToken}'
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: 'aif-primary-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
    allowProjectManagement: true
  }
}

// Default Foundry project under the primary account (new Foundry format).
resource foundryPrimaryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundryPrimary
  name: 'proj-${resourceToken}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'AI Gateway Demo (primary)'
    description: 'Default Foundry project for the AI Gateway demo — primary region.'
  }
}

resource foundrySecondary 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: 'aif-secondary-${resourceToken}'
  location: secondaryLocation
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: 'aif-secondary-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
    allowProjectManagement: true
  }
}

// Default Foundry project under the secondary account (new Foundry format).
resource foundrySecondaryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundrySecondary
  name: 'proj-${resourceToken}'
  location: secondaryLocation
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'AI Gateway Demo (secondary)'
    description: 'Default Foundry project for the AI Gateway demo — secondary region.'
  }
}

// Chat/router model deployments must be created serially per account (batchSize 1).
@batchSize(1)
resource primaryChatDeployments 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [
  for deployment in chatModelDeployments: {
    parent: foundryPrimary
    name: deployment.name
    sku: deployment.sku
    properties: {
      model: {
        format: 'OpenAI'
        name: deployment.model.name
        version: deployment.model.version
      }
    }
  }
]

// The secondary region may not offer the native model router; deploy only the models
// it supports so failover works with the gpt-5 family.
var secondaryChatModelDeployments = routerInSecondary ? chatModelDeployments : filter(chatModelDeployments, d => d.name != modelRouterName)

@batchSize(1)
resource secondaryChatDeployments 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [
  for deployment in secondaryChatModelDeployments: {
    parent: foundrySecondary
    name: deployment.name
    sku: deployment.sku
    properties: {
      model: {
        format: 'OpenAI'
        name: deployment.model.name
        version: deployment.model.version
      }
    }
  }
]

// Embedding deployment (primary) used by the semantic-cache lookup policy.
resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (enableSemanticCache) {
  parent: foundryPrimary
  name: embeddingDeploymentName
  sku: { name: 'GlobalStandard', capacity: 50 }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingDeploymentName
      version: embeddingModelVersion
    }
  }
  dependsOn: [
    primaryChatDeployments
  ]
}

// -----------------------------------------------------------------------------
// Azure AI Search — enterprise knowledge grounding (RAG)
// -----------------------------------------------------------------------------
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: 'srch-${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'basic' }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    semanticSearch: 'free'
  }
}

var searchIndexName = 'enterprise-kb'

// -----------------------------------------------------------------------------
// Gateway caching note: this demo uses APIM's built-in cache (cache-store /
// cache-lookup) for response caching keyed on a hash of the prompt — no external
// cache or secret required. To enable *true* semantic caching, provision an
// Azure Cache for Redis, wire it as an APIM external cache, and switch the policy
// to azure-openai-semantic-cache-lookup/store (see docs/CONFIGURATION.md).
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Azure API Management — the AI Gateway (single endpoint, multi-region backends)
// -----------------------------------------------------------------------------
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = if (deployApim) {
  name: 'apim-${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'Developer', capacity: 1 }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = if (deployApim) {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: appInsights.id
    credentials: {
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
  }
}

// (No external APIM cache resource: built-in cache is used for response caching.)

// Backends: primary + secondary Foundry, plus an embeddings backend for the cache.
resource backendPrimary 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = if (deployApim) {
  parent: apim
  name: 'foundry-primary'
  properties: {
    protocol: 'http'
    url: '${foundryPrimary.properties.endpoint}openai'
    circuitBreaker: {
      rules: [
        {
          name: 'primaryBreaker'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [ { min: 429, max: 429 }, { min: 500, max: 599 } ]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

resource backendSecondary 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = if (deployApim) {
  parent: apim
  name: 'foundry-secondary'
  properties: {
    protocol: 'http'
    url: '${foundrySecondary.properties.endpoint}openai'
  }
}

resource backendEmbeddings 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = if (deployApim && enableSemanticCache) {
  parent: apim
  name: 'embeddings-backend'
  properties: {
    protocol: 'http'
    url: '${foundryPrimary.properties.endpoint}openai/deployments/${embeddingDeploymentName}'
  }
}

// The single AI Gateway API (Azure OpenAI-compatible surface).
resource gatewayApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = if (deployApim) {
  parent: apim
  name: 'ai-gateway'
  properties: {
    displayName: 'AI Gateway'
    description: 'Single enterprise AI Gateway endpoint fronting multi-region Azure AI Foundry.'
    path: 'ai'
    protocols: [ 'https' ]
    subscriptionRequired: true
    serviceUrl: '${foundryPrimary.properties.endpoint}openai'
    apiType: 'http'
  }
}

resource opChatCompletions 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = if (deployApim) {
  parent: gatewayApi
  name: 'chat-completions'
  properties: {
    displayName: 'Create chat completion'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/chat/completions'
    templateParameters: [
      { name: 'deployment-id', required: true, type: 'string' }
    ]
  }
}

resource opEmbeddings 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = if (deployApim) {
  parent: gatewayApi
  name: 'embeddings'
  properties: {
    displayName: 'Create embeddings'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/embeddings'
    templateParameters: [
      { name: 'deployment-id', required: true, type: 'string' }
    ]
  }
}

// Inline AI Gateway policy: managed-identity auth, token governance, semantic
// caching, lightweight guardrails, token metrics, and primary->secondary failover.
var semanticCacheLookup = enableSemanticCache ? '<set-variable name="cacheKey" value="@("aigw-" + Convert.ToBase64String(System.Security.Cryptography.SHA256.Create().ComputeHash(System.Text.Encoding.UTF8.GetBytes((string)context.Variables["promptText"]))))" /><cache-lookup-value key="@((string)context.Variables["cacheKey"])" variable-name="cachedResponse" /><choose><when condition="@(context.Variables.ContainsKey("cachedResponse"))"><return-response><set-status code="200" reason="OK" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-header name="x-cache" exists-action="override"><value>HIT</value></set-header><set-body>@((string)context.Variables["cachedResponse"])</set-body></return-response></when></choose>' : ''
var semanticCacheStore = enableSemanticCache ? '<choose><when condition="@(!context.Variables.ContainsKey("cachedResponse"))"><cache-store-value key="@((string)context.Variables["cacheKey"])" value="@(context.Response.Body.As<String>(preserveContent: true))" duration="120" /><set-header name="x-cache" exists-action="override"><value>MISS</value></set-header></when></choose>' : ''

var apiPolicyXml = '''
<policies>
  <inbound>
    <base />
    <!-- CORS: allow the single-file browser demo client (webapp.html) to call the
         gateway and read the custom demo headers (x-cache, x-served-backend, token
         headers). Origins are unrestricted for the demo; scope them for production. -->
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>*</origin>
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>POST</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>*</header>
      </allowed-headers>
      <expose-headers>
        <header>x-cache</header>
        <header>x-served-backend</header>
        <header>x-remaining-tokens</header>
        <header>x-consumed-tokens</header>
      </expose-headers>
    </cors>
    <!-- Model abstraction: default to the native Foundry model router when the
         caller does not specify a deployment. Never hardcode model names here. -->
    <set-variable name="deployment-id" value="@(context.Request.MatchedParameters.ContainsKey("deployment-id") ? context.Request.MatchedParameters["deployment-id"] : "__MODEL_ROUTER__")" />
    <!-- Lightweight prompt-injection / jailbreak guardrail. Upgrade to the
         llm-content-safety policy (Azure AI Content Safety) for production. -->
    <set-variable name="promptText" value="@(context.Request.Body?.As<string>(preserveContent: true) ?? "")" />
    <choose>
      <when condition="@(System.Text.RegularExpressions.Regex.IsMatch(((string)context.Variables["promptText"]).ToLower(), "ignore (all|previous) instructions|jailbreak|dan mode|system prompt"))">
        <return-response>
          <set-status code="400" reason="Blocked by AI guardrail" />
          <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
          <set-body>{"error":{"code":"content_safety_blocked","message":"Request blocked by AI Gateway guardrails."}}</set-body>
        </return-response>
      </when>
    </choose>
    <!-- Token-level governance: per-subscription tokens-per-minute budget. -->
    <azure-openai-token-limit counter-key="@(context.Subscription?.Id ?? "anonymous")" tokens-per-minute="__TOKENS_PER_MINUTE__" estimate-prompt-tokens="false" remaining-tokens-header-name="x-remaining-tokens" tokens-consumed-header-name="x-consumed-tokens" />
    __SEMANTIC_CACHE_LOOKUP__
    <!-- Managed-identity auth to Azure AI Foundry (no keys). -->
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
    <set-query-parameter name="api-version" exists-action="override">
      <value>__OPENAI_API_VERSION__</value>
    </set-query-parameter>
    <!-- Multi-region routing: start on the primary region backend. -->
    <set-backend-service backend-id="foundry-primary" />
    <!-- Observability: emit token metrics dimensioned by served model & region.
         (emit-token-metric is only valid in the inbound section.) -->
    <azure-openai-emit-token-metric namespace="ai-gateway">
      <dimension name="Deployment" value="@((string)context.Variables["deployment-id"])" />
      <dimension name="Backend" value="@(context.Request.Url.Host)" />
      <dimension name="Subscription" value="@(context.Subscription?.Name ?? "unknown")" />
    </azure-openai-emit-token-metric>
  </inbound>
  <backend>
    <!-- Reliability & failover: retry on an unreachable primary (null response),
         403 (region disabled / access blocked), throttling (429) or 5xx, and fail
         over to the secondary region backend. -->
    <retry condition="@(context.Response == null || context.Response.StatusCode == 403 || context.Response.StatusCode == 429 || context.Response.StatusCode >= 500)" count="2" interval="1" first-fast-retry="true">
      <choose>
        <when condition="@(context.Response == null || context.Response.StatusCode == 403 || context.Response.StatusCode == 429 || context.Response.StatusCode >= 500)">
          <set-backend-service backend-id="foundry-secondary" />
        </when>
      </choose>
      <forward-request buffer-request-body="true" />
    </retry>
  </backend>
  <outbound>
    <base />
    __SEMANTIC_CACHE_STORE__
    <set-header name="x-served-backend" exists-action="override">
      <value>@(context.Request.Url.Host)</value>
    </set-header>
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''

var apiPolicyResolved = replace(replace(replace(replace(replace(apiPolicyXml, '__MODEL_ROUTER__', modelRouterName), '__TOKENS_PER_MINUTE__', string(tokensPerMinute)), '__OPENAI_API_VERSION__', openAiApiVersion), '__SEMANTIC_CACHE_LOOKUP__', semanticCacheLookup), '__SEMANTIC_CACHE_STORE__', semanticCacheStore)

resource gatewayApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = if (deployApim) {
  parent: gatewayApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: apiPolicyResolved
  }
  dependsOn: [
    backendPrimary
    backendSecondary
  ]
}

// APIM diagnostics -> Application Insights
resource gatewayApiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2023-05-01-preview' = if (deployApim) {
  parent: gatewayApi
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    loggerId: apimLogger.id
    sampling: { samplingType: 'fixed', percentage: 100 }
    verbosity: 'information'
  }
}

// Demo subscription so the app/frontend has a subscription key.
resource gatewaySubscription 'Microsoft.ApiManagement/service/subscriptions@2023-05-01-preview' = if (deployApim) {
  parent: apim
  name: 'ai-gateway-demo'
  properties: {
    displayName: 'AI Gateway demo subscription'
    scope: gatewayApi.id
    state: 'active'
  }
}

// -----------------------------------------------------------------------------
// RBAC — managed identity everywhere; no keys in app config.
// -----------------------------------------------------------------------------

// APIM system identity -> Cognitive Services OpenAI User on both Foundry accounts
resource apimToFoundryPrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployApim) {
  name: guid(foundryPrimary.id, 'apim', roleCognitiveServicesOpenAiUser)
  scope: foundryPrimary
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAiUser)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource apimToFoundrySecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployApim) {
  name: guid(foundrySecondary.id, 'apim', roleCognitiveServicesOpenAiUser)
  scope: foundrySecondary
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAiUser)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// App identity -> Search data reader + service contributor (RAG)
resource appToSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, appIdentity.id, roleSearchIndexDataReader)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataReader)
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource appToSearchContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, appIdentity.id, roleSearchServiceContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchServiceContributor)
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// App identity -> Key Vault secrets user
resource appToKeyVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, appIdentity.id, roleKeyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Local developer access (optional): grant the signed-in principal the same roles.
resource userToFoundryPrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(foundryPrimary.id, principalId, roleCognitiveServicesOpenAiUser)
  scope: foundryPrimary
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAiUser)
    principalId: principalId
  }
}

resource userToSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(search.id, principalId, roleSearchIndexDataReader)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataReader)
    principalId: principalId
  }
}

resource userToKeyVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(keyVault.id, principalId, roleKeyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: principalId
  }
}

// -----------------------------------------------------------------------------
// Outputs consumed by azd env / the application (no secrets emitted).
// -----------------------------------------------------------------------------
output AZURE_LOCATION string = location
output SECONDARY_LOCATION string = secondaryLocation
output AZURE_RESOURCE_GROUP string = resourceGroup().name
output AZURE_TENANT_ID string = subscription().tenantId
output AZURE_KEY_VAULT_NAME string = keyVault.name
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.properties.vaultUri
output AZURE_CLIENT_ID string = appIdentity.properties.clientId
output APIM_SERVICE_NAME string = deployApim ? apim.name : ''
output APIM_GATEWAY_URL string = deployApim ? '${apim.properties.gatewayUrl}/ai' : ''
output MODEL_ROUTER_NAME string = modelRouterName
output OPENAI_API_VERSION string = openAiApiVersion
output PRIMARY_FOUNDRY_ENDPOINT string = foundryPrimary.properties.endpoint
output SECONDARY_FOUNDRY_ENDPOINT string = foundrySecondary.properties.endpoint
output PRIMARY_FOUNDRY_NAME string = foundryPrimary.name
output SECONDARY_FOUNDRY_NAME string = foundrySecondary.name
output CHAT_MODEL_DEPLOYMENT_NAMES array = [for d in chatModelDeployments: d.name]
output EMBEDDING_DEPLOYMENT_NAME string = enableSemanticCache ? embeddingDeploymentName : ''
output AZURE_SEARCH_ENDPOINT string = 'https://${search.name}.search.windows.net'
output AZURE_SEARCH_INDEX_NAME string = searchIndexName
output APPLICATIONINSIGHTS_CONNECTION_STRING string = appInsights.properties.ConnectionString
