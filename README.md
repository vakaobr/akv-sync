# Azure Key Vault Multi-Region Sync

A production-ready Helm chart for synchronizing Azure Key Vault secrets across multiple regions and subscriptions, enabling disaster recovery and high availability strategies.

> **Note**: This code was automatically generated using AI (Claude Sonnet 4.5) and reviewed/adjusted by a human **(me)**. Please review carefully and test in a safe environment before deploying to production.

## Features

### 🔄 Flexible Source Selection
- **Specific Vaults**: Sync only named Key Vaults
- **All Vaults**: Sync all accessible vaults in a subscription or resource group
- **All Except**: Sync all vaults except explicitly excluded ones

### 🌐 Multi-Subscription Support
- **Cross-Subscription Sync**: Sync between different Azure subscriptions
- **Same Subscription**: Sync within same subscription to different regions
- **Automatic Context Switching**: Seamlessly handles subscription changes

### 🔐 Flexible Authentication
- **Workload Identity**: Azure Workload Identity (recommended, no credentials stored)
- **Service Principal**: Traditional SP authentication for clusters without Workload Identity

### 📢 Multi-Channel Notifications
- **Email**: SMTP-based notifications with TLS support
- **Slack**: Webhook-based alerts to Slack channels
- **Microsoft Teams**: Native Teams webhook integration
- **Telegram**: Bot-based notifications

### 🔒 Enterprise Security
- **No Stored Credentials**: Azure Workload Identity support
- **RBAC Integration**: Least-privilege access with separate read/write roles
- **Pod Security**: Non-root execution, read-only filesystem, dropped capabilities

## Quick Start

### Prerequisites

- Azure subscription with Key Vaults
- AKS cluster (with Workload Identity enabled for recommended auth method)
- Helm 3.x
- Azure CLI
- Docker (for building the image)

### 1. Setup Azure Resources

```bash
# Set variables
export SUBSCRIPTION_ID="your-subscription-id"
export RESOURCE_GROUP="your-resource-group"
export IDENTITY_NAME="akv-sync-identity"
export SOURCE_KV="your-source-keyvault"
export DEST_KV="your-dest-keyvault"

# Create User-Assigned Managed Identity
az identity create \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP

# Get identity details
export CLIENT_ID=$(az identity show \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query clientId -o tsv)

export TENANT_ID=$(az account show --query tenantId -o tsv)

# Assign read permissions on source vault
az role assignment create \
  --assignee $CLIENT_ID \
  --role "Key Vault Secrets User" \
  --scope $(az keyvault show --name $SOURCE_KV --query id -o tsv)

# Assign write permissions on destination vault
az role assignment create \
  --assignee $CLIENT_ID \
  --role "Key Vault Secrets Officer" \
  --scope $(az keyvault show --name $DEST_KV --query id -o tsv)

# Configure Workload Identity (for AKS)
# See docs/INSTALLATION.md for complete setup
```

### 2. Build and Push Container Image

```bash
# Build from repo root
docker build -t yourregistry.azurecr.io/akv-sync:latest .
docker push yourregistry.azurecr.io/akv-sync:latest
```

### 3. Create Values File

```yaml
# my-values.yaml
image:
  repository: yourregistry.azurecr.io/akv-sync
  tag: "latest"

azureIdentity:
  clientId: "your-managed-identity-client-id"
  tenantId: "your-tenant-id"
  enabled: true

authentication:
  method: "workload-identity"

source:
  selectionMode: "specific"
  keyvaults:
    - name: "your-source-kv"

destination:
  region: "northeurope"
  namingPattern: "{source_name}-replica"
  autoCreate: true

sync:
  dryRun: true  # Start with dry run
  logLevel: "INFO"

cronjob:
  schedule: "*/5 * * * *"

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

### 4. Install with Helm

```bash
# Create namespace
kubectl create namespace akv-sync

# Create Slack webhook secret (if using notifications)
kubectl create secret generic slack-webhook \
  --from-literal=url='https://hooks.slack.com/services/YOUR/WEBHOOK/URL' \
  -n akv-sync

# Install the chart
helm install akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml
```

### 5. Verify Installation

```bash
# Trigger manual test
kubectl create job --from=cronjob/akv-sync test-$(date +%s) -n akv-sync

# Watch logs
kubectl logs -n akv-sync -l app.kubernetes.io/name=akv-sync --tail=100 -f

# Check that dry-run worked
# Then disable dry-run for production
helm upgrade akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml \
  --set sync.dryRun=false
```

## Configuration Reference

### Source Selection Modes

**Specific vaults:**
```yaml
source:
  selectionMode: "specific"
  keyvaults:
    - name: "vault1"
    - name: "vault2"
    # Optional: specify explicit destination name
    - name: "vault3"
      destinationName: "custom-dest-vault"
```

**All vaults:**
```yaml
source:
  selectionMode: "all"
  resourceGroup: "production-rg"  # Optional
```

**All except excluded:**
```yaml
source:
  selectionMode: "allExcept"
  excludeKeyvaults:
    - "dev-vault"
    - "test-vault"
```

### Subscription Configuration

**Same subscription (different regions):**
```yaml
azure:
  sourceSubscriptionId: "11111111-1111-1111-1111-111111111111"
  # destinationSubscriptionId not specified - uses source subscription
```

**Cross-subscription sync:**
```yaml
azure:
  sourceSubscriptionId: "11111111-1111-1111-1111-111111111111"
  destinationSubscriptionId: "22222222-2222-2222-2222-222222222222"
```

### Authentication Methods

**Workload Identity (Recommended):**
```yaml
authentication:
  method: "workload-identity"

azureIdentity:
  clientId: "managed-identity-client-id"
  tenantId: "your-tenant-id"
  enabled: true
```

**Service Principal:**
```yaml
authentication:
  method: "service-principal"
  servicePrincipal:
    clientId: "service-principal-app-id"
    tenantId: "your-tenant-id"
    secretRef:
      name: "service-principal-secret"
      key: "client-secret"
```

### Notifications

All notification channels support event filtering:
```yaml
notifications:
  enabled: true
  events:
    onSuccess: false  # Don't spam on success
    onFailure: true   # Alert on failures
    onWarning: true   # Alert on warnings
```

**Slack:**
```yaml
notifications:
  slack:
    enabled: true
    webhookSecret:
      name: "slack-webhook"
      key: "url"
    channel: "#alerts"
```

**Email:**
```yaml
notifications:
  email:
    enabled: true
    smtpServer: "smtp.gmail.com"
    smtpPort: 587
    smtpUser: "notifications@example.com"
    smtpPasswordSecret:
      name: "smtp-credentials"
      key: "password"
    from: "akv-sync@example.com"
    to:
      - "ops@example.com"
```

**Microsoft Teams:**
```yaml
notifications:
  teams:
    enabled: true
    webhookSecret:
      name: "teams-webhook"
      key: "url"
```

**Telegram:**
```yaml
notifications:
  telegram:
    enabled: true
    botTokenSecret:
      name: "telegram-credentials"
      key: "token"
    chatIdSecret:
      name: "telegram-credentials"
      key: "chatId"
```

## Common Operations

```bash
# Check status
kubectl get cronjob,jobs -n akv-sync

# View logs
kubectl logs -n akv-sync -l app.kubernetes.io/name=akv-sync --tail=100

# Trigger manual sync
kubectl create job --from=cronjob/akv-sync manual-$(date +%s) -n akv-sync

# Upgrade configuration
helm upgrade akv-sync ./helm-chart -n akv-sync -f my-values.yaml

# Suspend/resume
helm upgrade akv-sync ./helm-chart -n akv-sync --reuse-values --set cronjob.suspend=true

# Change schedule
helm upgrade akv-sync ./helm-chart -n akv-sync --reuse-values --set cronjob.schedule="*/10 * * * *"
```

### Destination Management

**Flexible Naming Options**:
1. **Use naming pattern** - Automatically generate names based on placeholders
2. **Keep same name** - Use `{source_name}` pattern to keep the same name
3. **Explicit names** - Specify `destinationName` per vault for full control

```yaml
# Option 1: Keep same name (useful for cross-region in same subscription)
destination:
  namingPattern: "{source_name}"

# Option 2: Add suffix
destination:
  namingPattern: "{source_name}-replica"

# Option 3: Mix of pattern and explicit names
source:
  keyvaults:
    - name: "prod-vault-1"  # Will use naming pattern
    - name: "prod-vault-2"  # Will use naming pattern
    - name: "special-vault"
      destinationName: "custom-target-name"  # Explicit override

# Option 4: All explicit names
source:
  keyvaults:
    - name: "source-vault-a"
      destinationName: "dest-vault-a"
    - name: "source-vault-b"
      destinationName: "dest-vault-b"
```

**Other Features**:
- **Auto-Create**: Automatically create missing destination vaults
- **Validation**: Alerts if destination doesn't exist
- **Custom Resource Group**: Specify different RG for destinations

## Use Cases

### Use Case 1: Same-Subscription DR
Replicate vaults to different region within same subscription for disaster recovery.

**Example**: See `helm-chart/examples/same-subscription-workload-identity.yaml`

### Use Case 2: Cross-Subscription Sync
Sync from one subscription to another (e.g., shared services to business units).

**Example**: See `helm-chart/examples/cross-subscription-service-principal.yaml`

### Use Case 3: Multiple Vaults with Exclusions
Sync all production vaults except dev/test.

**Example**: See `helm-chart/examples/all-except.yaml`

### Use Case 4: Enterprise Multi-Vault
Critical infrastructure with all notification channels.

**Example**: See `helm-chart/examples/multiple-vaults-full-notifications.yaml`

## Authentication Comparison

| Feature | Workload Identity | Service Principal |
|---------|-------------------|-------------------|
| Setup complexity | Simple (on Azure) | Moderate |
| Credential management | Automatic | Manual rotation needed |
| Security | Excellent | Good (if managed properly) |
| Cross-subscription | ✅ Yes (same tenant) | ✅ Yes (any tenant) |
| Cross-tenant | ❌ No | ✅ Yes |
| Non-Azure clusters | ❌ No | ✅ Yes |
| **Recommended for** | Azure AKS | Legacy/cross-tenant/non-Azure |

**Recommendation**: Use Workload Identity when available. Use Service Principal only when:
- Your AKS cluster doesn't have Workload Identity enabled
- You need cross-tenant synchronization
- Running on non-Azure Kubernetes clusters

## Documentation

- **[docs/INSTALLATION.md](docs/INSTALLATION.md)** - Complete installation guide with troubleshooting
- **[docs/ADVANCED.md](docs/ADVANCED.md)** - Advanced scenarios (cross-subscription, service principal, security)
- **[helm-chart/values.yaml](helm-chart/values.yaml)** - All configuration options with detailed comments
- **[helm-chart/examples/](helm-chart/examples/)** - Ready-to-use configurations for common scenarios

## Security Best Practices

### For Workload Identity
1. Use separate managed identities for different environments
2. Assign least-privilege roles (Secrets User on source, Secrets Officer on destination)
3. Enable diagnostic logging on Key Vaults
4. Regular access reviews

### For Service Principal
1. **Store credentials securely**: Always use Kubernetes Secrets, never in values.yaml
2. **Rotate credentials regularly**: Set up rotation schedule (e.g., quarterly)
3. **Monitor access**: Enable audit logging and set up alerts
4. **Least privilege**: Only assign necessary permissions on specific vaults
5. **Migrate when possible**: Move to Workload Identity when cluster supports it

### For Notifications
- **Never commit webhook URLs or tokens** to source control
- Store all sensitive notification credentials in Kubernetes Secrets
- Use secret references in values.yaml, not direct values

## Troubleshooting

### Authentication Errors

**Workload Identity:**
```bash
# Check service account annotations
kubectl get sa akv-sync-sa -n akv-sync -o yaml

# Check federated credential
az identity federated-credential list \
  --identity-name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP
```

**Service Principal:**
```bash
# Test SP login manually
az login --service-principal \
  --username $SP_APP_ID \
  --password $SP_PASSWORD \
  --tenant $TENANT_ID
```

### Missing Destination Vault
- Enable `destination.autoCreate: true` in values
- Or create destination vault manually
- Check logs for warnings about missing vaults

### Secrets Not Syncing
```bash
# Check exclusion patterns
kubectl get configmap -n akv-sync akv-sync-config -o yaml | grep EXCLUDE_SECRETS

# Verify dry-run is disabled
kubectl get configmap -n akv-sync akv-sync-config -o yaml | grep DRY_RUN

# Check RBAC permissions
az keyvault secret list --vault-name $SOURCE_KV
```

### Cross-Subscription Issues
- Verify subscription IDs in ConfigMap
- Check role assignments in both subscriptions
- Ensure identity has access to both subscriptions

## Project Structure

```
akv-sync/
├── README.md                           # This file
├── Dockerfile                          # Container image
├── akv-sync.sh                         # Sync script
├── .dockerignore                       # Docker build exclusions
├── .gitignore                          # Git exclusions
├── docs/
│   ├── INSTALLATION.md                 # Detailed installation guide
│   └── ADVANCED.md                     # Advanced scenarios
│
└── helm-chart/                         # Helm Chart
    ├── Chart.yaml                      # Chart metadata
    ├── values.yaml                     # Configuration options
    ├── templates/                      # Kubernetes manifests
    │   ├── _helpers.tpl
    │   ├── namespace.yaml
    │   ├── serviceaccount.yaml
    │   ├── configmap.yaml
    │   ├── secret.yaml
    │   ├── cronjob.yaml
    │   └── NOTES.txt
    └── examples/                       # Example configurations
        ├── same-subscription-workload-identity.yaml
        ├── cross-subscription-service-principal.yaml
        ├── single-vault.yaml
        ├── all-except.yaml
        └── multiple-vaults-full-notifications.yaml
```

## Performance Considerations

- **Subscription Context Switching**: Minimal overhead (<1 second per switch)
- **Service Principal Login**: Initial login adds 1-2 seconds to job startup
- **Network Latency**: Depends on regions
- **API Rate Limits**: Apply per subscription

Consider sync frequency based on RPO requirements:
- Every 5 minutes = ~8,640 syncs/month
- Every 30 minutes = ~1,440 syncs/month

## License

This Helm chart is provided as-is for use in your Azure environment.

## Support

For issues and questions:
1. Check logs: `kubectl logs -n akv-sync <pod>`
2. Verify configuration: `helm get values akv-sync -n akv-sync`
3. Review documentation in `docs/` directory
4. Check Azure permissions and audit logs
