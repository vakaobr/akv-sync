# Advanced Configuration Guide

This guide covers advanced scenarios including cross-subscription sync, Service Principal authentication, and security best practices.

## Table of Contents

1. [Cross-Subscription Synchronization](#cross-subscription-synchronization)
2. [Service Principal Authentication](#service-principal-authentication)
3. [Security & Secrets Management](#security--secrets-management)
4. [Advanced Use Cases](#advanced-use-cases)

## Cross-Subscription Synchronization

### Use Cases

Common cross-subscription sync scenarios:
1. **Different Business Units**: Sync from shared services subscription to BU-specific subscription
2. **Hub-Spoke Architecture**: Sync from hub subscription to spoke subscriptions
3. **Disaster Recovery**: Sync to DR subscription in different geographic region
4. **Development Isolation**: Sync from production subscription to isolated dev/test subscription

### Configuration Options

#### Same Subscription (Default)

```yaml
azure:
  # Only specify source, destination defaults to same
  sourceSubscriptionId: "11111111-1111-1111-1111-111111111111"
```

#### Explicit Destination Subscription

```yaml
azure:
  sourceSubscriptionId: "11111111-1111-1111-1111-111111111111"
  destinationSubscriptionId: "22222222-2222-2222-2222-222222222222"
```

#### Current Subscription

```yaml
azure:
  sourceSubscriptionId: ""  # Uses current
  destinationSubscriptionId: ""  # Uses current
```

### Setup Instructions

#### Prerequisites

- Access to both subscriptions
- Appropriate permissions to create identities and assign roles
- AKS cluster (can be in either subscription or a third subscription)

#### Assign Permissions

**For Workload Identity (Single Tenant):**

```bash
export MANAGED_IDENTITY_NAME="akv-sync-identity"
export SOURCE_SUB_ID="11111111-1111-1111-1111-111111111111"
export DEST_SUB_ID="22222222-2222-2222-2222-222222222222"

# Get Client ID
CLIENT_ID=$(az identity show \
  --name $MANAGED_IDENTITY_NAME \
  --resource-group your-rg \
  --query clientId -o tsv)

# Assign permissions on source subscription
az account set --subscription $SOURCE_SUB_ID

az role assignment create \
  --assignee $CLIENT_ID \
  --role "Key Vault Secrets User" \
  --scope /subscriptions/$SOURCE_SUB_ID/resourceGroups/source-rg/providers/Microsoft.KeyVault/vaults/source-kv

# Switch to destination subscription
az account set --subscription $DEST_SUB_ID

az role assignment create \
  --assignee $CLIENT_ID \
  --role "Key Vault Secrets Officer" \
  --scope /subscriptions/$DEST_SUB_ID/resourceGroups/dest-rg/providers/Microsoft.KeyVault/vaults/dest-kv
```

**For Service Principal (Any Scenario):**

```bash
export SP_APP_ID="your-service-principal-app-id"
export SOURCE_SUB_ID="11111111-1111-1111-1111-111111111111"
export DEST_SUB_ID="22222222-2222-2222-2222-222222222222"

# Assign permissions on source subscription
az account set --subscription $SOURCE_SUB_ID
az role assignment create \
  --assignee $SP_APP_ID \
  --role "Key Vault Secrets User" \
  --scope /subscriptions/$SOURCE_SUB_ID/resourceGroups/source-rg/providers/Microsoft.KeyVault/vaults/source-kv

# Assign permissions on destination subscription
az account set --subscription $DEST_SUB_ID
az role assignment create \
  --assignee $SP_APP_ID \
  --role "Key Vault Secrets Officer" \
  --scope /subscriptions/$DEST_SUB_ID/resourceGroups/dest-rg/providers/Microsoft.KeyVault/vaults/dest-kv
```

#### Configure Helm Values

Example cross-subscription configuration:

```yaml
# cross-sub-values.yaml

image:
  repository: yourregistry.azurecr.io/akv-sync
  tag: "latest"

# Cross-subscription configuration
azure:
  sourceSubscriptionId: "11111111-1111-1111-1111-111111111111"
  destinationSubscriptionId: "22222222-2222-2222-2222-222222222222"

authentication:
  method: "service-principal"
  servicePrincipal:
    clientId: "service-principal-app-id"
    tenantId: "your-tenant-id"
    secretRef:
      name: "service-principal-secret"
      key: "client-secret"

source:
  selectionMode: "specific"
  keyvaults:
    - name: "shared-secrets-westeu"

destination:
  region: "northeurope"
  namingPattern: "{source_name}-replica"
  autoCreate: false  # Create manually for cross-sub
  resourceGroup: "dest-rg"

sync:
  dryRun: false
  logLevel: "INFO"

cronjob:
  schedule: "*/10 * * * *"

notifications:
  enabled: true
  events:
    onFailure: true
    onWarning: true
  slack:
    enabled: true
    webhookSecret:
      name: "slack-webhook"
      key: "url"
```

### Advanced Scenarios

#### Hub-Spoke with Multiple Destinations

Sync from one hub subscription to multiple spoke subscriptions by deploying separate Helm releases:

```bash
# Deploy sync to Spoke 1
helm install akv-sync-spoke1 ./helm-chart \
  --namespace akv-sync \
  --values spoke1-values.yaml

# Deploy sync to Spoke 2
helm install akv-sync-spoke2 ./helm-chart \
  --namespace akv-sync \
  --values spoke2-values.yaml
```

#### Cascading Sync

Sync from Prod → DR → Archive subscriptions by deploying two separate sync instances.

### Cost Considerations

**Azure Costs:**
1. **Key Vault Operations**: ~$0.03/10,000 operations
2. **Cross-Subscription Data Transfer**: Usually free within same region, charged for cross-region
3. **Additional Vaults**: Standard ($0.03/vault/month), Premium ($1/vault/month)

**Optimization Tips:**
- Adjust frequency based on RPO requirements
- Use exclusions to sync only necessary secrets
- Use batch operations ("all" or "allExcept" mode)

## Service Principal Authentication

Use Service Principal when:
- Your AKS cluster doesn't have Workload Identity enabled
- Running on Kubernetes cluster outside Azure
- Need cross-tenant synchronization
- Organization security policies require it

### Setup

#### 1. Create Service Principal

```bash
export APP_NAME="akv-sync-sp"
export SOURCE_SUBSCRIPTION_ID="11111111-1111-1111-1111-111111111111"
export DEST_SUBSCRIPTION_ID="22222222-2222-2222-2222-222222222222"

# Create Service Principal
SP_OUTPUT=$(az ad sp create-for-rbac \
  --name $APP_NAME \
  --skip-assignment \
  --output json)

# Extract credentials
export SP_APP_ID=$(echo $SP_OUTPUT | jq -r '.appId')
export SP_PASSWORD=$(echo $SP_OUTPUT | jq -r '.password')
export SP_TENANT_ID=$(echo $SP_OUTPUT | jq -r '.tenant')

echo "Service Principal created:"
echo "  App ID: $SP_APP_ID"
echo "  Tenant ID: $SP_TENANT_ID"
echo "  Password: $SP_PASSWORD"
echo ""
echo "⚠️  IMPORTANT: Save the password securely - it cannot be retrieved later!"
```

#### 2. Assign Permissions

For source subscription:

```bash
az account set --subscription $SOURCE_SUBSCRIPTION_ID

# For each source vault
export SOURCE_KV="your-source-keyvault"
SOURCE_KV_ID=$(az keyvault show --name $SOURCE_KV --query id -o tsv)

az role assignment create \
  --assignee $SP_APP_ID \
  --role "Key Vault Secrets User" \
  --scope $SOURCE_KV_ID
```

For destination subscription:

```bash
az account set --subscription $DEST_SUBSCRIPTION_ID

export DEST_KV="your-dest-keyvault"
DEST_KV_ID=$(az keyvault show --name $DEST_KV --query id -o tsv)

az role assignment create \
  --assignee $SP_APP_ID \
  --role "Key Vault Secrets Officer" \
  --scope $DEST_KV_ID
```

#### 3. Create Kubernetes Secret

```bash
kubectl create secret generic service-principal-secret \
  --from-literal=client-secret="$SP_PASSWORD" \
  --namespace akv-sync
```

**Important**: Never commit the Service Principal password to source control!

#### 4. Configure Helm Values

```yaml
authentication:
  method: "service-principal"
  servicePrincipal:
    clientId: "your-sp-app-id"
    tenantId: "your-tenant-id"
    secretRef:
      name: "service-principal-secret"
      key: "client-secret"
```

### Security Best Practices for Service Principal

1. **Rotate credentials regularly** (e.g., quarterly):
   ```bash
   # Reset credential
   NEW_PASSWORD=$(az ad sp credential reset \
     --id $SP_APP_ID \
     --query password -o tsv)

   # Update Kubernetes Secret
   kubectl create secret generic service-principal-secret \
     --from-literal=client-secret="$NEW_PASSWORD" \
     --namespace akv-sync \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

2. **Use Secrets**: Never put the Service Principal password in ConfigMap or values.yaml

3. **Least Privilege**: Only assign necessary permissions on specific vaults

4. **Enable audit logging** on Key Vaults

5. **Monitor**: Set up alerts for failed authentication attempts

### Cross-Tenant Sync

For syncing across Azure AD tenants:

```bash
# Create Service Principal in source tenant
az login --tenant $SOURCE_TENANT_ID
SP_OUTPUT=$(az ad sp create-for-rbac --name akv-sync-cross-tenant)

# Grant access in destination tenant (requires admin privileges)
# The SP will need to be added as a guest user in the destination tenant
```

### Migration to Workload Identity

If your cluster gains Workload Identity support:

1. Enable Workload Identity on AKS
2. Create Managed Identity and assign Key Vault permissions
3. Create federated credential
4. Update values.yaml:
   ```yaml
   authentication:
     method: "workload-identity"
   azureIdentity:
     clientId: "managed-identity-client-id"
     tenantId: "your-tenant-id"
   ```
5. Upgrade Helm release
6. Remove Service Principal secret (optional)
7. Delete Service Principal (optional)

## Security & Secrets Management

### Sensitive Data

The following values are **sensitive** and must be stored in Kubernetes Secrets:
1. **Subscription IDs** (if specified)
2. **Service Principal Credentials** (Client ID, Tenant ID, Client Secret)
3. **Notification Webhooks** (Slack, Teams - contain secret tokens)
4. **Bot Tokens** (Telegram)
5. **Email Credentials** (SMTP passwords)

### Security Architecture

```
Helm Chart Values
  ├─> ConfigMap (non-sensitive configuration)
  │   • Selection mode
  │   • Vault names
  │   • Regions
  │   • Schedules
  │
  └─> Kubernetes Secrets (sensitive data)
      ├─> Auto-created Secret (akv-sync-secret)
      │   • Subscription IDs (from values)
      │   • SP Client ID/Tenant (from values)
      │
      └─> External Secrets (user-created)
          • SP Client Secret
          • Webhook URLs
          • SMTP passwords
          • Bot tokens
```

### Best Practices

#### 1. Use External Secrets (Recommended)

Create Kubernetes Secrets manually and reference them:

```bash
# Create external secrets
kubectl create secret generic sp-secret \
  --from-literal=client-secret=YOUR_SECRET \
  -n akv-sync

kubectl create secret generic slack-webhook \
  --from-literal=url=https://hooks.slack.com/services/YOUR/WEBHOOK \
  -n akv-sync

# Reference in values.yaml
authentication:
  servicePrincipal:
    secretRef:
      name: "sp-secret"
      key: "client-secret"

notifications:
  slack:
    webhookSecret:
      name: "slack-webhook"
      key: "url"
```

#### 2. Never Commit Secrets

**Bad:**
```yaml
# values-prod.yaml - NEVER DO THIS!
azure:
  sourceSubscriptionId: "11111111-1111-1111-1111-111111111111"
authentication:
  servicePrincipal:
    clientSecret: "actual-secret-here"  # NEVER!
```

**Good:**
```yaml
# values-prod.yaml
azure:
  sourceSubscriptionId: ""  # Provide via --set
authentication:
  servicePrincipal:
    secretRef:
      name: "service-principal-secret"
      key: "client-secret"
```

#### 3. Use --set for Sensitive Values

```bash
helm install akv-sync ./helm-chart \
  --namespace akv-sync \
  --values values-prod.yaml \
  --set azure.sourceSubscriptionId=$SOURCE_SUB \
  --set azure.destinationSubscriptionId=$DEST_SUB \
  --set authentication.servicePrincipal.clientId=$SP_CLIENT_ID \
  --set authentication.servicePrincipal.tenantId=$SP_TENANT_ID
```

#### 4. Use External Secret Management

Consider using:
- **Sealed Secrets**: Encrypt secrets that can be stored in git
- **External Secrets Operator**: Sync from external secret stores (Azure Key Vault, etc.)

**Sealed Secrets Example:**
```bash
# Install sealed-secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Create sealed secret
echo -n "your-secret" | kubectl create secret generic sp-secret \
  --dry-run=client --from-file=client-secret=/dev/stdin -o yaml | \
  kubeseal -o yaml > sp-secret-sealed.yaml

# Safe to commit sp-secret-sealed.yaml
git add sp-secret-sealed.yaml
```

**External Secrets Operator Example:**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: akv-sync-secrets
  namespace: akv-sync
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault-store
    kind: SecretStore
  target:
    name: service-principal-secret
  data:
  - secretKey: client-secret
    remoteRef:
      key: sp-client-secret
```

#### 5. Use RBAC to Limit Secret Access

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: akv-sync-secret-reader
  namespace: akv-sync
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["service-principal-secret", "slack-webhook"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: akv-sync-secret-reader
  namespace: akv-sync
subjects:
- kind: ServiceAccount
  name: akv-sync-sa
  namespace: akv-sync
roleRef:
  kind: Role
  name: akv-sync-secret-reader
  apiGroup: rbac.authorization.k8s.io
```

### Security Checklist

**Before Deployment:**
- [ ] All sensitive values are in Kubernetes Secrets, not values.yaml
- [ ] External secrets created before Helm install
- [ ] values.yaml does not contain any actual credentials
- [ ] values.yaml is safe to commit to source control
- [ ] RBAC policies limit secret access

**During Deployment:**
- [ ] Use `--set` for subscription IDs if needed
- [ ] Verify secrets exist: `kubectl get secrets -n akv-sync`
- [ ] Check secret references in values.yaml are correct
- [ ] Use `helm template` to preview before install

**After Deployment:**
- [ ] Verify pod can mount secrets
- [ ] Check logs for authentication success
- [ ] Confirm no secrets in pod describe output
- [ ] Set up secret rotation schedule
- [ ] Document which secrets exist and where

**Ongoing:**
- [ ] Rotate Service Principal credentials quarterly
- [ ] Audit secret access regularly
- [ ] Monitor for failed authentication attempts
- [ ] Keep webhook URLs updated if regenerated
- [ ] Review and update RBAC policies

## Advanced Use Cases

### Multi-Region DR Strategy

Deploy multiple sync instances for comprehensive DR:

```bash
# Primary to DR region
helm install akv-sync-dr1 ./helm-chart \
  --namespace akv-sync \
  --values dr1-values.yaml

# Primary to second DR region
helm install akv-sync-dr2 ./helm-chart \
  --namespace akv-sync \
  --values dr2-values.yaml
```

### Environment Promotion

Use different sync configurations for each environment:

```yaml
# prod-to-staging.yaml
source:
  selectionMode: "specific"
  keyvaults:
    - name: "prod-secrets"
destination:
  region: "westeurope"
  namingPattern: "staging-{source_name}"
sync:
  excludeSecrets:
    - "*-prod-only"
```

### Compliance and Auditing

Enable comprehensive logging and monitoring:

```bash
# Enable audit logging on all Key Vaults
az monitor diagnostic-settings create \
  --name akv-audit \
  --resource <keyvault-resource-id> \
  --logs '[{"category": "AuditEvent", "enabled": true}]' \
  --workspace <log-analytics-id>

# Set up alerts for sync failures
# (Use your monitoring solution of choice)
```

### High-Frequency Sync

For critical applications requiring minimal RPO:

```yaml
cronjob:
  schedule: "* * * * *"  # Every minute
  activeDeadlineSeconds: 50  # Must complete in 50 seconds
resources:
  limits:
    cpu: 1000m
    memory: 1Gi
  requests:
    cpu: 500m
    memory: 512Mi
```

## Troubleshooting

### Service Principal Authentication Failed

```bash
# Test SP login manually
az login --service-principal \
  --username $SP_APP_ID \
  --password $SP_PASSWORD \
  --tenant $TENANT_ID

# Check secret value is correct
kubectl get secret service-principal-secret -n akv-sync \
  -o jsonpath='{.data.client-secret}' | base64 -d

# Verify SP hasn't expired
az ad sp show --id $SP_APP_ID \
  --query "passwordCredentials[].endDateTime" -o tsv
```

### Cross-Subscription Access Denied

```bash
# Verify role assignments in both subscriptions
az role assignment list \
  --assignee $CLIENT_ID \
  --all

# Check subscription access
az account show --subscription $SOURCE_SUB_ID
az account show --subscription $DEST_SUB_ID
```

### Secret Changes Not Picked Up

Pods don't auto-reload secrets. Trigger a new job:

```bash
kubectl create job --from=cronjob/akv-sync manual-$(date +%s) -n akv-sync
```

## Additional Resources

- [Kubernetes Secrets Documentation](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Azure Workload Identity](https://azure.github.io/azure-workload-identity/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [External Secrets Operator](https://external-secrets.io/)
- [Azure RBAC for Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide)
