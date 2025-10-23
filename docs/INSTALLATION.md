# Installation Guide

Complete guide for deploying the Azure Key Vault Sync Helm chart.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Azure Setup](#azure-setup)
3. [Build Container Image](#build-container-image)
4. [Configure Values](#configure-values)
5. [Install Helm Chart](#install-helm-chart)
6. [Verify Installation](#verify-installation)
7. [Configure Notifications](#configure-notifications)
8. [Testing](#testing)
9. [Troubleshooting](#troubleshooting)

## Prerequisites

### Tools Required

```bash
# Check prerequisites
az --version          # Azure CLI 2.x
kubectl version       # Kubernetes CLI
helm version          # Helm 3.x
docker --version      # Docker
```

### Azure Resources

- Azure subscription
- AKS cluster (with Workload Identity enabled for recommended setup)
- Source Key Vault(s)
- Destination region identified

## Azure Setup

### 1. Set Environment Variables

```bash
export SUBSCRIPTION_ID="your-subscription-id"
export RESOURCE_GROUP="your-resource-group"
export AKS_CLUSTER="your-aks-cluster"
export IDENTITY_NAME="akv-sync-identity"
export LOCATION="westeurope"
export DEST_LOCATION="northeurope"

# Login to Azure
az login
az account set --subscription $SUBSCRIPTION_ID
```

### 2. Create Managed Identity

```bash
# Create User-Assigned Managed Identity
az identity create \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# Get identity details
export CLIENT_ID=$(az identity show \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query clientId -o tsv)

export TENANT_ID=$(az account show --query tenantId -o tsv)

echo "Client ID: $CLIENT_ID"
echo "Tenant ID: $TENANT_ID"
```

### 3. Assign Key Vault Permissions

For each source Key Vault:

```bash
export SOURCE_KV="your-source-keyvault"

# Get Key Vault ID
SOURCE_KV_ID=$(az keyvault show \
  --name $SOURCE_KV \
  --query id -o tsv)

# Assign "Key Vault Secrets User" role (read access)
az role assignment create \
  --assignee $CLIENT_ID \
  --role "Key Vault Secrets User" \
  --scope $SOURCE_KV_ID

echo "Assigned read permissions on $SOURCE_KV"
```

For destination Key Vault:

```bash
export DEST_KV="your-dest-keyvault"

# If vault already exists
DEST_KV_ID=$(az keyvault show \
  --name $DEST_KV \
  --query id -o tsv)

az role assignment create \
  --assignee $CLIENT_ID \
  --role "Key Vault Secrets Officer" \
  --scope $DEST_KV_ID

echo "Assigned write permissions on $DEST_KV"
```

If using auto-create, assign permissions at resource group level:

```bash
# Get resource group ID
RG_ID=$(az group show \
  --name $RESOURCE_GROUP \
  --query id -o tsv)

# Assign contributor role for creating Key Vaults
az role assignment create \
  --assignee $CLIENT_ID \
  --role "Contributor" \
  --scope $RG_ID

echo "Assigned contributor permissions on resource group"
```

### 4. Configure AKS Workload Identity

```bash
# Enable OIDC issuer and Workload Identity (if not already enabled)
az aks update \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER \
  --enable-oidc-issuer \
  --enable-workload-identity

# Get OIDC issuer URL
export OIDC_ISSUER=$(az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_CLUSTER \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

echo "OIDC Issuer: $OIDC_ISSUER"
```

### 5. Create Federated Identity Credential

```bash
# Create federated credential
az identity federated-credential create \
  --name "akv-sync-federated-credential" \
  --identity-name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --issuer $OIDC_ISSUER \
  --subject "system:serviceaccount:akv-sync:akv-sync-sa" \
  --audience "api://AzureADTokenExchange"

echo "Federated credential created"
```

## Build Container Image

### 1. Build the Docker Image

```bash
# Build from repo root
export REGISTRY="yourregistry.azurecr.io"
docker build -t $REGISTRY/akv-sync:latest .
```

### 2. Push to Azure Container Registry

```bash
# Login to ACR
az acr login --name yourregistry

# Push image
docker push $REGISTRY/akv-sync:latest

# Verify
az acr repository show \
  --name yourregistry \
  --repository akv-sync
```

## Configure Values

Create your values file `my-values.yaml`:

```yaml
# Image configuration
image:
  repository: yourregistry.azurecr.io/akv-sync
  tag: "latest"

# Azure Identity
azureIdentity:
  clientId: "YOUR_CLIENT_ID"  # Replace with actual value
  tenantId: "YOUR_TENANT_ID"  # Replace with actual value
  enabled: true

authentication:
  method: "workload-identity"

# Source configuration
source:
  selectionMode: "specific"
  keyvaults:
    - name: "your-source-kv"

# Destination configuration
destination:
  region: "northeurope"
  namingPattern: "{source_name}-replica"
  autoCreate: true

# Sync configuration
sync:
  dryRun: true  # Start with dry-run
  logLevel: "INFO"

# Schedule
cronjob:
  schedule: "*/5 * * * *"

# Notifications (configure later)
notifications:
  enabled: false
```

Replace placeholders:

```bash
# Replace CLIENT_ID and TENANT_ID in values file
sed -i "s/YOUR_CLIENT_ID/$CLIENT_ID/g" my-values.yaml
sed -i "s/YOUR_TENANT_ID/$TENANT_ID/g" my-values.yaml
```

## Install Helm Chart

### 1. Create Namespace

```bash
kubectl create namespace akv-sync
```

### 2. Install with Helm

```bash
# Install the chart
helm install akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml
```

### 3. Verify Installation

```bash
# Check Helm release
helm list -n akv-sync

# Check resources
kubectl get all -n akv-sync

# Check CronJob
kubectl get cronjob -n akv-sync

# Check ServiceAccount annotations
kubectl get sa akv-sync-sa -n akv-sync -o yaml
```

## Verify Installation

### 1. Trigger Manual Job

```bash
# Create test job
kubectl create job --from=cronjob/akv-sync test-sync-$(date +%s) -n akv-sync

# Watch job
kubectl get jobs -n akv-sync -w
```

### 2. Check Logs

```bash
# Get pod name
POD=$(kubectl get pods -n akv-sync --sort-by=.metadata.creationTimestamp -o name | tail -1)

# View logs
kubectl logs -n akv-sync $POD -f
```

### 3. Verify Dry Run

You should see output like:

```
[INFO] Azure Key Vault Sync Tool v2.0
[INFO] Validating prerequisites...
[SUCCESS] Prerequisites validated successfully
[INFO] Starting Azure Key Vault synchronization...
[INFO] Destination region: northeurope
[WARNING] DRY RUN MODE - No changes will be made
[INFO] Found 1 source Key Vault(s)
[INFO] Processing source vault: your-source-kv (westeurope)
[INFO] Target destination vault: your-source-kv-replica
[INFO] [DRY RUN] Would create secret: secret1
[INFO] [DRY RUN] Would create secret: secret2
```

## Configure Notifications

### Slack Notifications

```bash
# Create Slack webhook secret
kubectl create secret generic slack-webhook \
  --from-literal=url='https://hooks.slack.com/services/YOUR/WEBHOOK/URL' \
  -n akv-sync

# Update values file
cat >> my-values.yaml <<EOF
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
    channel: "#alerts"
EOF

# Upgrade release
helm upgrade akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml
```

### Email Notifications

```bash
# Create SMTP credentials secret
kubectl create secret generic smtp-credentials \
  --from-literal=password='your-smtp-password' \
  -n akv-sync

# Add email configuration to my-values.yaml and upgrade
helm upgrade akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml
```

### Microsoft Teams

```bash
# Create Teams webhook secret
kubectl create secret generic teams-webhook \
  --from-literal=url='YOUR-TEAMS-WEBHOOK-URL' \
  -n akv-sync

# Update and upgrade
helm upgrade akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml
```

### Telegram

```bash
# Create Telegram credentials secret
kubectl create secret generic telegram-credentials \
  --from-literal=token='your-bot-token' \
  --from-literal=chatId='your-chat-id' \
  -n akv-sync

# Update and upgrade
helm upgrade akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml
```

## Testing

### 1. Test with Dry Run

Already done during installation verification.

### 2. Enable Production Mode

```bash
# Update values file
sed -i 's/dryRun: true/dryRun: false/' my-values.yaml

# Upgrade
helm upgrade akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml

# Trigger manual sync
kubectl create job --from=cronjob/akv-sync prod-test-$(date +%s) -n akv-sync

# Check logs
kubectl logs -n akv-sync -l app.kubernetes.io/name=akv-sync --tail=100
```

### 3. Verify Secrets Synced

```bash
# Check destination vault
az keyvault secret list --vault-name your-dest-kv --query "[].name" -o table

# Compare with source
az keyvault secret list --vault-name your-source-kv --query "[].name" -o table
```

## Troubleshooting

### Authentication Errors

**Error**: `Workload Identity authentication failed`

**Solutions**:

1. Verify service account annotations:
   ```bash
   kubectl get sa akv-sync-sa -n akv-sync -o yaml
   ```

2. Check federated credential exists:
   ```bash
   az identity federated-credential list \
     --identity-name $IDENTITY_NAME \
     --resource-group $RESOURCE_GROUP
   ```

3. Ensure pod has correct labels:
   ```bash
   kubectl get pod -n akv-sync -o yaml | grep "azure.workload.identity/use"
   ```

### Permission Denied

**Error**: `Failed to fetch secrets from vault`

**Solutions**:

1. Verify role assignments:
   ```bash
   az role assignment list \
     --assignee $CLIENT_ID \
     --all
   ```

2. Check Key Vault firewall allows AKS:
   ```bash
   az keyvault show --name $SOURCE_KV --query "properties.networkAcls"
   ```

3. Test manual access:
   ```bash
   az keyvault secret list --vault-name $SOURCE_KV
   ```

### Missing Destination Vault

**Warning in logs**: `Destination Key Vault does not exist`

**Solutions**:

1. Enable auto-create:
   ```bash
   helm upgrade akv-sync ./helm-chart \
     --namespace akv-sync \
     --values my-values.yaml \
     --set destination.autoCreate=true
   ```

2. Or create manually:
   ```bash
   az keyvault create \
     --name $DEST_KV \
     --resource-group $RESOURCE_GROUP \
     --location $DEST_LOCATION
   ```

### Secrets Not Syncing

**Issue**: Secrets exist in source but not in destination

**Solutions**:

1. Check dry-run is disabled:
   ```bash
   kubectl get configmap akv-sync-config -n akv-sync -o yaml | grep DRY_RUN
   ```

2. Verify exclusion patterns:
   ```bash
   kubectl get configmap akv-sync-config -n akv-sync -o yaml | grep EXCLUDE_SECRETS
   ```

3. Check logs for errors:
   ```bash
   kubectl logs -n akv-sync -l app.kubernetes.io/name=akv-sync --tail=200
   ```

### Notifications Not Working

**Issue**: No alerts received

**Solutions**:

1. Check secrets exist:
   ```bash
   kubectl get secrets -n akv-sync
   ```

2. Verify webhook/credentials are correct:
   ```bash
   kubectl get secret slack-webhook -n akv-sync -o jsonpath='{.data.url}' | base64 -d
   ```

3. Check notification configuration:
   ```bash
   kubectl get configmap akv-sync-config -n akv-sync -o yaml | grep -A5 NOTIFY
   ```

### Cross-Subscription Issues

**Error**: `Failed to set subscription context`

**Solutions**:

1. Verify subscription IDs:
   ```bash
   az account list --output table
   ```

2. Check identity has Reader role on subscription:
   ```bash
   az role assignment list \
     --assignee $CLIENT_ID \
     --scope /subscriptions/$SUBSCRIPTION_ID
   ```

3. Verify ConfigMap has correct values:
   ```bash
   kubectl get secret akv-sync-secret -n akv-sync -o yaml
   ```

## Common Operations

### Suspend CronJob

```bash
helm upgrade akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml \
  --set cronjob.suspend=true
```

### Change Schedule

```bash
helm upgrade akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml \
  --set cronjob.schedule="*/10 * * * *"
```

### Add Source Key Vault

Edit values file to add new vault, then upgrade:

```bash
helm upgrade akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml
```

### Update Image

```bash
# Build and push new image
docker build -t $REGISTRY/akv-sync:v1.1 .
docker push $REGISTRY/akv-sync:v1.1

# Upgrade with new image
helm upgrade akv-sync ./helm-chart \
  --namespace akv-sync \
  --values my-values.yaml \
  --set image.tag=v1.1
```

## Cleanup

```bash
# Uninstall Helm release
helm uninstall akv-sync -n akv-sync

# Delete namespace
kubectl delete namespace akv-sync

# Delete Azure resources
az identity delete \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP
```

## Next Steps

1. Set up monitoring/alerting for failed jobs
2. Configure backup of values file in source control
3. Document your specific vault mappings
4. Create runbooks for common scenarios
5. Schedule regular testing of DR procedures
6. Review [ADVANCED.md](ADVANCED.md) for cross-subscription and Service Principal setups
