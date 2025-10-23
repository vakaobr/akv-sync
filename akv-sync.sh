#!/bin/bash

#############################################
# Azure Key Vault Multi-Region Sync Script
# Version: 2.1 (Autodiscovery Fixed)
#############################################

set -euo pipefail

# Script version - can be overridden at build time
SCRIPT_VERSION="${SCRIPT_VERSION:-2.1-dev}"
SCRIPT_BUILD_DATE="${SCRIPT_BUILD_DATE:-$(date -u +"%Y-%m-%d %H:%M:%S UTC")}"

# Configuration - can be overridden by environment variables

# Subscription configuration
SOURCE_SUBSCRIPTION_ID="${SOURCE_SUBSCRIPTION_ID:-}"  # Source subscription ID (optional, uses current if not set)
DESTINATION_SUBSCRIPTION_ID="${DESTINATION_SUBSCRIPTION_ID:-}"  # Destination subscription (defaults to source if not set)

# Authentication configuration
AUTH_METHOD="${AUTH_METHOD:-workload-identity}"  # workload-identity or service-principal
SERVICE_PRINCIPAL_ID="${SERVICE_PRINCIPAL_ID:-}"  # Required for service-principal auth
SERVICE_PRINCIPAL_SECRET="${SERVICE_PRINCIPAL_SECRET:-}"  # Required for service-principal auth
SERVICE_PRINCIPAL_TENANT_ID="${SERVICE_PRINCIPAL_TENANT_ID:-}"  # Required for service-principal auth

# Source configuration
SOURCE_SELECTION_MODE="${SOURCE_SELECTION_MODE:-specific}"  # all, specific, allExcept
SOURCE_KEYVAULTS="${SOURCE_KEYVAULTS:-}"  # Comma-separated list for "specific" mode
SOURCE_EXCLUDE_KEYVAULTS="${SOURCE_EXCLUDE_KEYVAULTS:-}"  # Comma-separated list for "allExcept" mode
SOURCE_RESOURCE_GROUP="${SOURCE_RESOURCE_GROUP:-}"  # Optional: limit to specific RG
SOURCE_TAGS="${SOURCE_TAGS:-}"  # Optional: JSON string of tags for filtering

# Destination configuration
DESTINATION_REGION="${DESTINATION_REGION:-}"
# Default pattern should match Helm chart values.yaml default
DESTINATION_NAMING_PATTERN="${DESTINATION_NAMING_PATTERN:-\{source_name\}-replica}"
DESTINATION_KEYVAULTS="${DESTINATION_KEYVAULTS:-}"  # Mapping of source:destination names
DESTINATION_RESOURCE_GROUP="${DESTINATION_RESOURCE_GROUP:-}"
DESTINATION_AUTO_CREATE="${DESTINATION_AUTO_CREATE:-false}"
DESTINATION_SKU="${DESTINATION_SKU:-standard}"

DRY_RUN="${DRY_RUN:-false}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
EXCLUDE_SECRETS="${EXCLUDE_SECRETS:-}"  # Comma-separated list of secret patterns
SYNC_DISABLED_SECRETS="${SYNC_DISABLED_SECRETS:-true}"
ENABLE_DELETION="${ENABLE_DELETION:-false}"

# Notification configuration
NOTIFY_ENABLED="${NOTIFY_ENABLED:-false}"
NOTIFY_ON_SUCCESS="${NOTIFY_ON_SUCCESS:-false}"
NOTIFY_ON_FAILURE="${NOTIFY_ON_FAILURE:-true}"
NOTIFY_ON_WARNING="${NOTIFY_ON_WARNING:-true}"

# Email notifications
EMAIL_ENABLED="${EMAIL_ENABLED:-false}"
SMTP_SERVER="${SMTP_SERVER:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
EMAIL_FROM="${EMAIL_FROM:-}"
EMAIL_TO="${EMAIL_TO:-}"  # Comma-separated
EMAIL_USE_TLS="${EMAIL_USE_TLS:-true}"

# Slack notifications
SLACK_ENABLED="${SLACK_ENABLED:-false}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-#alerts}"
SLACK_USERNAME="${SLACK_USERNAME:-AKV Sync Bot}"
SLACK_ICON_EMOJI="${SLACK_ICON_EMOJI:-:key:}"

# Teams notifications
TEAMS_ENABLED="${TEAMS_ENABLED:-false}"
TEAMS_WEBHOOK_URL="${TEAMS_WEBHOOK_URL:-}"

# Telegram notifications
TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-false}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global statistics
TOTAL_VAULTS_PROCESSED=0
TOTAL_SECRETS_CREATED=0
TOTAL_SECRETS_UPDATED=0
TOTAL_SECRETS_DELETED=0
TOTAL_SECRETS_SKIPPED=0
TOTAL_ERRORS=0
TOTAL_WARNINGS=0
MISSING_DESTINATION_VAULTS=()

# Logging functions - ALL output to stderr to avoid capturing in command substitution
log_debug() {
    if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
    fi
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
    ((TOTAL_WARNINGS++))
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
    ((TOTAL_ERRORS++))
}

# Authentication function
authenticate_azure() {
    # Additional diagnostic information
    log_info "Checking Azure CLI version:"
    az version >&2
    log_info "Authenticating to Azure (method: $AUTH_METHOD)..."
    log_info "Creating azure cache directory..."
    mkdir -p "$AZURE_CONFIG_DIR"

    case "$AUTH_METHOD" in
        "workload-identity")
            log_info "Using Azure Workload Identity authentication"

            # Check for required environment variables
            for var in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_FEDERATED_TOKEN_FILE; do
                if [ -z "${!var}" ]; then
                    log_error "Error: $var is not set"
                    return 1
                fi
            done

            # Check if token file exists and is readable
            if [ ! -r "$AZURE_FEDERATED_TOKEN_FILE" ]; then
                log_error "Error: Cannot read token file: $AZURE_FEDERATED_TOKEN_FILE"
                return 1
            else
                log_debug "Token file found: $AZURE_FEDERATED_TOKEN_FILE"
            fi

            # Explicitly login using the federated token
            # This is needed since az cli don't support WI by default to auth
            # https://github.com/Azure/azure-cli/issues/26858
            log_info "Logging in with federated token..."
            if ! az login --service-principal \
                -u "$AZURE_CLIENT_ID" \
                -t "$AZURE_TENANT_ID" \
                --federated-token "$(cat "$AZURE_FEDERATED_TOKEN_FILE")" \
                --allow-no-subscriptions \
                --output none 2>&1; then
                log_error "Workload Identity login failed"
                log_error "Ensure the federated credential is correctly configured"

                # Additional diagnostic information
                log_info "Checking Azure CLI version:"
                az version
                return 1
            fi

            log_success "Azure login successful with workload identity"

            # Verify we're authenticated
            if ! az account show &> /dev/null; then
                log_error "Workload Identity authentication failed after login"
                log_error "Ensure pod has correct labels and service account annotations"
                return 1
            fi

            # Get the first Key Vault from SOURCE_KEYVAULTS if it's set
            if [ -n "$SOURCE_KEYVAULTS" ]; then
                KEY_VAULT_NAME=$(echo "$SOURCE_KEYVAULTS" | awk -F',' '{print $1}')
                log_info "Using Key Vault from SOURCE_KEYVAULTS: $KEY_VAULT_NAME"
            else
                log_warning "SOURCE_KEYVAULTS is not set. Skipping specific Key Vault check."
            fi

            # Check if we can access the specific Key Vault
            if [ -n "$KEY_VAULT_NAME" ]; then
                if ! az keyvault secret list --vault-name "$KEY_VAULT_NAME" --query "[].name" -o tsv &> /dev/null; then
                    log_error "Unable to list secrets in Key Vault: $KEY_VAULT_NAME"
                    log_error "Check if the Managed Identity has appropriate permissions on the Key Vault"
                    return 1
                fi
                log_success "Successfully accessed Key Vault: $KEY_VAULT_NAME"
            else
                log_info "No specific Key Vault to check. Skipping Key Vault access test."
            fi

            log_success "Workload Identity authentication successful"
            ;;

        "service-principal")
            log_info "Using Service Principal authentication"

            if [[ -z "$SERVICE_PRINCIPAL_ID" ]]; then
                log_error "SERVICE_PRINCIPAL_ID is required for service-principal auth"
                return 1
            fi

            if [[ -z "$SERVICE_PRINCIPAL_SECRET" ]]; then
                log_error "SERVICE_PRINCIPAL_SECRET is required for service-principal auth"
                return 1
            fi

            if [[ -z "$SERVICE_PRINCIPAL_TENANT_ID" ]]; then
                log_error "SERVICE_PRINCIPAL_TENANT_ID is required for service-principal auth"
                return 1
            fi

            log_debug "Logging in with Service Principal: $SERVICE_PRINCIPAL_ID"

            if ! az login \
                --service-principal \
                --username "$SERVICE_PRINCIPAL_ID" \
                --password "$SERVICE_PRINCIPAL_SECRET" \
                --tenant "$SERVICE_PRINCIPAL_TENANT_ID" \
                --output none 2>&1; then
                log_error "Service Principal authentication failed"
                return 1
            fi

            log_success "Service Principal authentication successful"
            ;;

        *)
            log_error "Invalid AUTH_METHOD: $AUTH_METHOD (must be 'workload-identity' or 'service-principal')"
            return 1
            ;;
    esac

    return 0
}

# Set Azure subscription context
set_subscription_context() {
    local context_type="$1"  # "source" or "destination"
    local subscription_id="$2"

    if [[ -z "$subscription_id" ]]; then
        log_debug "No explicit subscription specified for $context_type, using current subscription"
        return 0
    fi

    log_info "Setting $context_type subscription context: $subscription_id"

    # Try to set subscription context, but don't fail if using Workload Identity without subscription access
    local set_output
    set_output=$(az account set --subscription "$subscription_id" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        if [[ "$AUTH_METHOD" == "workload-identity" ]]; then
            log_warning "Cannot set subscription context (service principal may not have subscription-level permissions)"
            log_debug "Error: $set_output"
            log_info "Will access resources directly by name/ID instead"
            # This is expected for Workload Identity with resource-level RBAC only
            return 0
        else
            log_error "Failed to set subscription context to: $subscription_id"
            log_error "$set_output"
            return 1
        fi
    fi

    log_success "Subscription context set to: $subscription_id"
    return 0
}

# Notification functions
send_email_notification() {
    local subject="$1"
    local body="$2"

    if [[ "$EMAIL_ENABLED" != "true" ]]; then
        return 0
    fi

    log_debug "Sending email notification: $subject"

    # Create email body file
    local email_file="/tmp/email_body_$$.txt"
    echo "$body" > "$email_file"

    # Send email using Python (available in Azure CLI container)
    python3 <<EOF
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

try:
    msg = MIMEMultipart()
    msg['From'] = "${EMAIL_FROM}"
    msg['To'] = "${EMAIL_TO}"
    msg['Subject'] = "${subject}"

    with open("${email_file}", "r") as f:
        body = f.read()

    msg.attach(MIMEText(body, 'plain'))

    server = smtplib.SMTP("${SMTP_SERVER}", ${SMTP_PORT})
    if "${EMAIL_USE_TLS}" == "true":
        server.starttls()

    if "${SMTP_PASSWORD}":
        server.login("${SMTP_USER}", "${SMTP_PASSWORD}")

    server.send_message(msg)
    server.quit()
    print("Email sent successfully")
except Exception as e:
    print(f"Failed to send email: {e}")
EOF

    rm -f "$email_file"
}

send_slack_notification() {
    local title="$1"
    local message="$2"
    local color="$3"  # good, warning, danger

    if [[ "$SLACK_ENABLED" != "true" ]] || [[ -z "$SLACK_WEBHOOK_URL" ]]; then
        return 0
    fi

    log_debug "Sending Slack notification: $title"

    # Use jq to properly escape JSON values
    local payload
    payload=$(jq -n \
        --arg channel "$SLACK_CHANNEL" \
        --arg username "$SLACK_USERNAME" \
        --arg icon "$SLACK_ICON_EMOJI" \
        --arg color "$color" \
        --arg title "$title" \
        --arg text "$message" \
        '{
            channel: $channel,
            username: $username,
            icon_emoji: $icon,
            attachments: [{
                color: $color,
                title: $title,
                text: $text,
                footer: "AKV Sync",
                ts: now
            }]
        }')

    curl -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "$SLACK_WEBHOOK_URL" 2>/dev/null || log_warning "Failed to send Slack notification"
}

send_teams_notification() {
    local title="$1"
    local message="$2"
    local color="$3"  # good=00FF00, warning=FFB900, danger=FF0000

    if [[ "$TEAMS_ENABLED" != "true" ]] || [[ -z "$TEAMS_WEBHOOK_URL" ]]; then
        return 0
    fi

    log_debug "Sending Teams notification: $title"

    # Convert color names to hex
    case "$color" in
        "good") color="00FF00" ;;
        "warning") color="FFB900" ;;
        "danger") color="FF0000" ;;
    esac

    # Use jq to properly escape JSON values
    local payload
    payload=$(jq -n \
        --arg color "$color" \
        --arg title "$title" \
        --arg text "$message" \
        '{
            "@type": "MessageCard",
            "@context": "http://schema.org/extensions",
            themeColor: $color,
            summary: $title,
            sections: [{
                activityTitle: $title,
                activitySubtitle: "Azure Key Vault Sync",
                text: $text,
                markdown: true
            }]
        }')

    curl -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "$TEAMS_WEBHOOK_URL" 2>/dev/null || log_warning "Failed to send Teams notification"
}

send_telegram_notification() {
    local message="$1"

    if [[ "$TELEGRAM_ENABLED" != "true" ]] || [[ -z "$TELEGRAM_BOT_TOKEN" ]] || [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        return 0
    fi

    log_debug "Sending Telegram notification"

    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

    # Use jq to properly escape JSON values
    local payload
    payload=$(jq -n \
        --arg chat_id "$TELEGRAM_CHAT_ID" \
        --arg text "$message" \
        '{
            chat_id: $chat_id,
            text: $text,
            parse_mode: "Markdown"
        }')

    curl -X POST "$url" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        2>/dev/null || log_warning "Failed to send Telegram notification"
}

send_notification() {
    local level="$1"  # success, warning, error
    local title="$2"
    local message="$3"

    if [[ "$NOTIFY_ENABLED" != "true" ]]; then
        return 0
    fi

    # Check if we should notify for this level
    case "$level" in
        "success")
            if [[ "$NOTIFY_ON_SUCCESS" != "true" ]]; then
                return 0
            fi
            ;;
        "warning")
            if [[ "$NOTIFY_ON_WARNING" != "true" ]]; then
                return 0
            fi
            ;;
        "error")
            if [[ "$NOTIFY_ON_FAILURE" != "true" ]]; then
                return 0
            fi
            ;;
    esac

    # Determine color
    local color
    case "$level" in
        "success") color="good" ;;
        "warning") color="warning" ;;
        "error") color="danger" ;;
    esac

    # Send to all enabled channels
    send_email_notification "$title" "$message"
    send_slack_notification "$title" "$message" "$color"
    send_teams_notification "$title" "$message" "$color"
    send_telegram_notification "*${title}*\n\n${message}"
}

# Validate prerequisites
validate_prerequisites() {
    log_info "Validating prerequisites..."

    if ! command -v az &> /dev/null; then
        log_error "Azure CLI not found. Please install it first."
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install it first."
        exit 1
    fi

    if [[ -z "$DESTINATION_REGION" ]]; then
        log_error "DESTINATION_REGION environment variable is not set"
        exit 1
    fi

    # Authenticate to Azure
    if ! authenticate_azure; then
        log_error "Azure authentication failed"
        exit 1
    fi

    # Set destination subscription (defaults to source if not specified)
    if [[ -z "$DESTINATION_SUBSCRIPTION_ID" ]]; then
        if [[ -n "$SOURCE_SUBSCRIPTION_ID" ]]; then
            DESTINATION_SUBSCRIPTION_ID="$SOURCE_SUBSCRIPTION_ID"
            log_info "Destination subscription not specified, using source subscription"
        else
            # Get current subscription
            DESTINATION_SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)
            if [[ -z "$DESTINATION_SUBSCRIPTION_ID" ]]; then
                log_warning "Could not determine current subscription ID"
                log_warning "This is expected for Workload Identity with resource-level permissions"
            else
                log_info "Using current subscription for destination: $DESTINATION_SUBSCRIPTION_ID"
            fi
        fi
    fi

    # Display subscription configuration
    log_info "Subscription configuration:"
    if [[ -n "$SOURCE_SUBSCRIPTION_ID" ]]; then
        log_info "  Source subscription: $SOURCE_SUBSCRIPTION_ID"
    else
        log_info "  Source subscription: (current)"
    fi
    log_info "  Destination subscription: $DESTINATION_SUBSCRIPTION_ID"

    log_success "Prerequisites validated successfully"
}

# Get list of source Key Vaults based on selection mode
get_source_keyvaults() {
    log_info "========================================="
    log_info "GET_SOURCE_KEYVAULTS - START"
    log_info "Discovering source Key Vaults (mode: $SOURCE_SELECTION_MODE)..."
    log_info "SOURCE_KEYVAULTS=$SOURCE_KEYVAULTS"
    log_info "SOURCE_RESOURCE_GROUP=$SOURCE_RESOURCE_GROUP"

    # Set source subscription context if specified
    if [[ -n "$SOURCE_SUBSCRIPTION_ID" ]]; then
        set_subscription_context "source" "$SOURCE_SUBSCRIPTION_ID"
    fi

    local keyvaults_json

    case "$SOURCE_SELECTION_MODE" in
        "all")
            # Get all Key Vaults in subscription or resource group
            if [[ -n "$SOURCE_RESOURCE_GROUP" ]]; then
                keyvaults_json=$(az keyvault list --resource-group "$SOURCE_RESOURCE_GROUP" -o json 2>&1)
            else
                keyvaults_json=$(az keyvault list -o json 2>&1)
            fi

            # Check if the command failed (e.g., due to lack of subscription-level permissions)
            if ! echo "$keyvaults_json" | jq empty 2>/dev/null; then
                if [[ "$AUTH_METHOD" == "workload-identity" ]]; then
                    log_error "Cannot list Key Vaults at subscription level with Workload Identity"
                    log_error "Please use selectionMode: 'specific' and set SOURCE_KEYVAULTS in your configuration"
                    log_error "Example: SOURCE_KEYVAULTS='vault1,vault2'"
                else
                    log_error "Failed to list Key Vaults: $keyvaults_json"
                fi
                exit 1
            fi
            ;;

        "specific")
            # Get only specified Key Vaults
            if [[ -z "$SOURCE_KEYVAULTS" ]]; then
                log_error "SOURCE_KEYVAULTS not set for 'specific' mode"
                exit 1
            fi

            local vault_names=()
            IFS=',' read -ra vault_names <<< "$SOURCE_KEYVAULTS"

            keyvaults_json="[]"
            for vault_name in "${vault_names[@]}"; do
                vault_name=$(echo "$vault_name" | xargs)  # Trim whitespace
                log_info "Fetching Key Vault details: $vault_name"

                local vault_info
                local exit_code

                # If resource group is specified, use it for more efficient query
                if [[ -n "$SOURCE_RESOURCE_GROUP" ]]; then
                    log_debug "Using configured resource group: $SOURCE_RESOURCE_GROUP"
                    vault_info=$(az keyvault show --name "$vault_name" --resource-group "$SOURCE_RESOURCE_GROUP" -o json 2>&1)
                    exit_code=$?
                else
                    # Auto-discover by fetching vault info directly (no resource group needed)
                    log_debug "Auto-discovering vault: $vault_name"
                    vault_info=$(az keyvault show --name "$vault_name" -o json 2>&1)
                    exit_code=$?

                    # Extract and log the discovered resource group for debugging
                    if [[ $exit_code -eq 0 ]]; then
                        local vault_rg
                        vault_rg=$(echo "$vault_info" | jq -r '.resourceGroup' 2>/dev/null)
                        if [[ -n "$vault_rg" && "$vault_rg" != "null" ]]; then
                            log_debug "Auto-discovered resource group: $vault_rg"
                        fi
                    fi
                fi

                # Validate we got valid JSON
                if [[ $exit_code -eq 0 ]] && echo "$vault_info" | jq empty 2>/dev/null; then
                    log_info "DEBUG: About to append vault to array"
                    log_info "DEBUG: Current keyvaults_json length: $(echo "$keyvaults_json" | jq 'length' 2>/dev/null || echo 'INVALID')"
                    log_info "DEBUG: vault_info first 100 chars: ${vault_info:0:100}"

                    # Append vault_info to keyvaults_json array using jq with proper JSON streaming
                    local jq_exit=0
                    keyvaults_json=$(printf '%s\n%s' "$keyvaults_json" "$vault_info" | jq -s '.[0] + [.[1]]' 2>&1)
                    jq_exit=$?

                    if [[ $jq_exit -ne 0 ]]; then
                        log_error "JQ FAILED! Exit code: $jq_exit"
                        log_error "JQ output: $keyvaults_json"
                        keyvaults_json="[]"
                    else
                        log_success "Successfully retrieved vault: $vault_name"
                    fi
                else
                    log_error "Failed to retrieve Key Vault '$vault_name'"
                    log_error "Error: $vault_info"
                    log_info "Please verify:"
                    log_info "  1. The vault name is correct"
                    log_info "  2. The managed identity has 'Reader' permission"
                    log_info "  3. The vault exists in the subscription"
                fi
            done
            ;;

        "allExcept")
            # Get all Key Vaults except excluded ones
            if [[ -n "$SOURCE_RESOURCE_GROUP" ]]; then
                keyvaults_json=$(az keyvault list --resource-group "$SOURCE_RESOURCE_GROUP" -o json 2>&1)
            else
                keyvaults_json=$(az keyvault list -o json 2>&1)
            fi

            # Check if the command failed
            if ! echo "$keyvaults_json" | jq empty 2>/dev/null; then
                if [[ "$AUTH_METHOD" == "workload-identity" ]]; then
                    log_error "Cannot list Key Vaults at subscription level with Workload Identity"
                    log_error "Please use selectionMode: 'specific' instead of 'allExcept'"
                else
                    log_error "Failed to list Key Vaults: $keyvaults_json"
                fi
                exit 1
            fi

            # Filter out excluded vaults
            if [[ -n "$SOURCE_EXCLUDE_KEYVAULTS" ]]; then
                local exclude_names=()
                IFS=',' read -ra exclude_names <<< "$SOURCE_EXCLUDE_KEYVAULTS"

                for exclude_name in "${exclude_names[@]}"; do
                    exclude_name=$(echo "$exclude_name" | xargs)
                    log_debug "Excluding Key Vault: $exclude_name"
                    keyvaults_json=$(echo "$keyvaults_json" | jq "map(select(.name != \"$exclude_name\"))")
                done
            fi
            ;;

        *)
            log_error "Invalid SOURCE_SELECTION_MODE: $SOURCE_SELECTION_MODE"
            exit 1
            ;;
    esac

    # Apply tag filters if specified
    if [[ -n "$SOURCE_TAGS" ]]; then
        log_debug "Applying tag filters: $SOURCE_TAGS"
        # TODO: Implement tag filtering
    fi

    # Debug: Check if keyvaults_json is valid
    log_info "DEBUG: Final keyvaults_json content (first 200 chars): ${keyvaults_json:0:200}..."

    # Validate JSON before processing
    if ! echo "$keyvaults_json" | jq empty 2>/dev/null; then
        log_error "Invalid JSON in keyvaults_json at end of function"
        log_error "Content: $keyvaults_json"
        keyvaults_json="[]"
    fi

    local jq_exit=0
    local vault_count
    vault_count=$(echo "$keyvaults_json" | jq 'length' 2>&1)
    jq_exit=$?

    if [[ $jq_exit -ne 0 ]]; then
        log_error "JQ FAILED when getting vault_count!"
        log_error "JQ output: $vault_count"
        vault_count=0
    fi

    log_info "Found $vault_count source Key Vault(s)"
    log_info "GET_SOURCE_KEYVAULTS - END"
    log_info "========================================="

    echo "$keyvaults_json"
}

# Generate destination Key Vault name
get_destination_vault_name() {
    local source_name="$1"
    local source_region="$2"

    log_info "DEBUG: get_destination_vault_name called with: source_name=$source_name, source_region=$source_region"
    log_info "DEBUG: DESTINATION_NAMING_PATTERN='$DESTINATION_NAMING_PATTERN'"
    log_info "DEBUG: DESTINATION_REGION='$DESTINATION_REGION'"

    # Check if explicit destination name is provided in mapping
    if [[ -n "$DESTINATION_KEYVAULTS" ]]; then
        # Parse the mapping format: "vault1:dest1,vault2:,vault3:dest3"
        IFS=',' read -ra mappings <<< "$DESTINATION_KEYVAULTS"
        for mapping in "${mappings[@]}"; do
            IFS=':' read -r src_vault dest_vault <<< "$mapping"
            if [[ "$src_vault" == "$source_name" ]] && [[ -n "$dest_vault" ]]; then
                log_debug "Using explicit destination name: $dest_vault for source: $source_name"
                echo "$dest_vault"
                return 0
            fi
        done
    fi

    # If no explicit mapping, use naming pattern
    local dest_name="$DESTINATION_NAMING_PATTERN"
    log_info "DEBUG: Before replacement: dest_name='$dest_name'"

    dest_name="${dest_name//\{source_name\}/$source_name}"
    log_info "DEBUG: After {source_name} replacement: dest_name='$dest_name'"

    dest_name="${dest_name//\{source_region\}/$source_region}"
    log_info "DEBUG: After {source_region} replacement: dest_name='$dest_name'"

    dest_name="${dest_name//\{dest_region\}/$DESTINATION_REGION}"
    log_info "DEBUG: After {dest_region} replacement: dest_name='$dest_name'"

    log_info "Using naming pattern for destination: $dest_name"
    echo "$dest_name"
}

# Check if destination Key Vault exists, optionally create it
ensure_destination_vault() {
    local dest_vault_name="$1"
    local source_rg="$2"

    local dest_rg="${DESTINATION_RESOURCE_GROUP:-$source_rg}"

    # Set destination subscription context
    set_subscription_context "destination" "$DESTINATION_SUBSCRIPTION_ID"

    log_info "Checking destination Key Vault: $dest_vault_name (subscription: $DESTINATION_SUBSCRIPTION_ID)"

    if az keyvault show --name "$dest_vault_name" &> /dev/null; then
        log_success "Destination Key Vault exists: $dest_vault_name"
        return 0
    else
        log_warning "Destination Key Vault does not exist: $dest_vault_name"
        MISSING_DESTINATION_VAULTS+=("$dest_vault_name (region: $DESTINATION_REGION, subscription: $DESTINATION_SUBSCRIPTION_ID)")

        if [[ "$DESTINATION_AUTO_CREATE" == "true" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would create Key Vault: $dest_vault_name in $dest_rg"
                return 0
            fi

            log_info "Creating destination Key Vault: $dest_vault_name"

            if az keyvault create \
                --name "$dest_vault_name" \
                --resource-group "$dest_rg" \
                --location "$DESTINATION_REGION" \
                --sku "$DESTINATION_SKU" \
                --output none 2>/dev/null; then
                log_success "Created destination Key Vault: $dest_vault_name"
                return 0
            else
                log_error "Failed to create destination Key Vault: $dest_vault_name"
                return 1
            fi
        else
            return 1
        fi
    fi
}

# Check if a secret matches exclusion patterns
is_secret_excluded() {
    local secret_name="$1"

    if [[ -z "$EXCLUDE_SECRETS" ]]; then
        return 1  # Not excluded
    fi

    local patterns=()
    IFS=',' read -ra patterns <<< "$EXCLUDE_SECRETS"

    for pattern in "${patterns[@]}"; do
        pattern=$(echo "$pattern" | xargs)  # Trim whitespace

        # Simple wildcard matching
        if [[ "$secret_name" == "$pattern" ]]; then
            return 0  # Excluded
        fi
    done

    return 1  # Not excluded
}

# Sync secrets between two Key Vaults
sync_vault_secrets() {
    local source_vault="$1"
    local dest_vault="$2"

    log_info "Syncing secrets: $source_vault → $dest_vault"

    local created=0
    local updated=0
    local deleted=0
    local skipped=0
    local errors=0

    # Set source subscription context
    if [[ -n "$SOURCE_SUBSCRIPTION_ID" ]]; then
        set_subscription_context "source" "$SOURCE_SUBSCRIPTION_ID"
    fi

    # Get secrets from source vault
    local source_secrets
    if ! source_secrets=$(az keyvault secret list --vault-name "$source_vault" --query "[].{name:name, enabled:attributes.enabled}" -o json 2>/dev/null); then
        log_error "Failed to retrieve secrets from source vault: $source_vault"
        return 1
    fi

    # Set destination subscription context
    set_subscription_context "destination" "$DESTINATION_SUBSCRIPTION_ID"

    # Get secrets from destination vault
    local dest_secrets
    if ! dest_secrets=$(az keyvault secret list --vault-name "$dest_vault" --query "[].{name:name, enabled:attributes.enabled}" -o json 2>/dev/null); then
        log_error "Failed to retrieve secrets from destination vault: $dest_vault"
        return 1
    fi

    local source_secret_names
    local dest_secret_names

    source_secret_names=$(echo "$source_secrets" | jq -r '.[].name' | sort)
    dest_secret_names=$(echo "$dest_secrets" | jq -r '.[].name' | sort)

    # Process secrets from source
    while IFS= read -r secret_name; do
        if [[ -z "$secret_name" ]]; then
            continue
        fi

        # Check if excluded
        if is_secret_excluded "$secret_name"; then
            log_debug "Skipping excluded secret: $secret_name"
            ((skipped++))
            continue
        fi

        log_debug "Processing secret: $secret_name"

        # Set source subscription context for fetching secret details
        if [[ -n "$SOURCE_SUBSCRIPTION_ID" ]]; then
            set_subscription_context "source" "$SOURCE_SUBSCRIPTION_ID"
        fi

        # Get source secret details
        local source_secret_details
        if ! source_secret_details=$(az keyvault secret show --vault-name "$source_vault" --name "$secret_name" -o json 2>/dev/null); then
            log_error "Failed to get details for secret '$secret_name' from $source_vault"
            ((errors++))
            continue
        fi

        local source_value
        local source_enabled

        source_value=$(echo "$source_secret_details" | jq -r '.value')
        source_enabled=$(echo "$source_secret_details" | jq -r '.attributes.enabled')

        # Skip disabled secrets if configured
        if [[ "$SYNC_DISABLED_SECRETS" == "false" && "$source_enabled" == "false" ]]; then
            log_debug "Skipping disabled secret: $secret_name"
            ((skipped++))
            continue
        fi

        # Check if secret exists in destination
        if echo "$dest_secret_names" | grep -qx "$secret_name"; then
            # Set destination subscription context
            set_subscription_context "destination" "$DESTINATION_SUBSCRIPTION_ID"

            # Secret exists - check if update is needed
            local dest_secret_details
            if ! dest_secret_details=$(az keyvault secret show --vault-name "$dest_vault" --name "$secret_name" -o json 2>/dev/null); then
                log_error "Failed to get details for destination secret '$secret_name'"
                ((errors++))
                continue
            fi

            local dest_value
            local dest_enabled

            dest_value=$(echo "$dest_secret_details" | jq -r '.value')
            dest_enabled=$(echo "$dest_secret_details" | jq -r '.attributes.enabled')

            # Compare values and enabled status
            if [[ "$source_value" != "$dest_value" || "$source_enabled" != "$dest_enabled" ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY RUN] Would update secret: $secret_name"
                else
                    log_debug "Updating secret: $secret_name"

                    # Ensure destination subscription context
                    set_subscription_context "destination" "$DESTINATION_SUBSCRIPTION_ID"

                    if az keyvault secret set --vault-name "$dest_vault" --name "$secret_name" --value "$source_value" --output none 2>/dev/null; then
                        if [[ "$source_enabled" == "false" ]]; then
                            if ! az keyvault secret set-attributes --vault-name "$dest_vault" --name "$secret_name" --enabled false --output none 2>/dev/null; then
                                log_warning "Updated secret value but failed to set enabled=false for: $secret_name"
                            fi
                        fi
                        log_success "Updated secret: $secret_name"
                        ((updated++))
                    else
                        log_error "Failed to update secret: $secret_name"
                        ((errors++))
                    fi
                fi
            fi
        else
            # Secret doesn't exist - create it
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would create secret: $secret_name"
            else
                log_debug "Creating new secret: $secret_name"

                # Ensure destination subscription context
                set_subscription_context "destination" "$DESTINATION_SUBSCRIPTION_ID"

                if az keyvault secret set --vault-name "$dest_vault" --name "$secret_name" --value "$source_value" --output none 2>/dev/null; then
                    if [[ "$source_enabled" == "false" ]]; then
                        if ! az keyvault secret set-attributes --vault-name "$dest_vault" --name "$secret_name" --enabled false --output none 2>/dev/null; then
                            log_warning "Created secret but failed to set enabled=false for: $secret_name"
                        fi
                    fi
                    log_success "Created secret: $secret_name"
                    ((created++))
                else
                    log_error "Failed to create secret: $secret_name"
                    ((errors++))
                fi
            fi
        fi
    done <<< "$source_secret_names"

    # Handle deletion if enabled
    if [[ "$ENABLE_DELETION" == "true" ]]; then
        while IFS= read -r secret_name; do
            if [[ -z "$secret_name" ]]; then
                continue
            fi

            if is_secret_excluded "$secret_name"; then
                continue
            fi

            if ! echo "$source_secret_names" | grep -qx "$secret_name"; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY RUN] Would delete secret: $secret_name"
                else
                    log_warning "Deleting secret (not in source): $secret_name"

                    if az keyvault secret delete --vault-name "$dest_vault" --name "$secret_name" --output none 2>/dev/null; then
                        log_success "Deleted secret: $secret_name"
                        ((deleted++))
                    else
                        log_error "Failed to delete secret: $secret_name"
                        ((errors++))
                    fi
                fi
            fi
        done <<< "$dest_secret_names"
    fi

    # Update global statistics
    TOTAL_SECRETS_CREATED=$((TOTAL_SECRETS_CREATED + created))
    TOTAL_SECRETS_UPDATED=$((TOTAL_SECRETS_UPDATED + updated))
    TOTAL_SECRETS_DELETED=$((TOTAL_SECRETS_DELETED + deleted))
    TOTAL_SECRETS_SKIPPED=$((TOTAL_SECRETS_SKIPPED + skipped))

    log_info "Vault sync complete - Created: $created, Updated: $updated, Deleted: $deleted, Skipped: $skipped, Errors: $errors"

    return $errors
}

# Main sync function
sync_keyvaults() {
    log_info "Starting Azure Key Vault synchronization..."
    log_info "Destination region: $DESTINATION_REGION"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warning "DRY RUN MODE - No changes will be made"
    fi

    # Get source Key Vaults
    log_info "DEBUG: About to call get_source_keyvaults()"
    local source_vaults_json
    source_vaults_json=$(get_source_keyvaults)
    log_info "DEBUG: get_source_keyvaults() returned, parsing result..."
    log_info "DEBUG: source_vaults_json first 200 chars: ${source_vaults_json:0:200}"

    local jq_exit=0
    local vault_count
    vault_count=$(echo "$source_vaults_json" | jq 'length' 2>&1)
    jq_exit=$?

    if [[ $jq_exit -ne 0 ]]; then
        log_error "JQ FAILED in sync_keyvaults when getting vault_count!"
        log_error "JQ output: $vault_count"
        log_error "source_vaults_json: $source_vaults_json"
        vault_count=0
    fi

    if [[ $vault_count -eq 0 ]]; then
        log_warning "No source Key Vaults found"
        send_notification "warning" "AKV Sync: No Source Vaults" "No source Key Vaults found for synchronization."
        return 0
    fi

    # Process each source vault
    # Use process substitution to avoid subshell issue with variable updates
    while IFS= read -r vault_json; do
        local source_vault_name
        local source_vault_region
        local source_vault_rg

        source_vault_name=$(echo "$vault_json" | jq -r '.name')
        source_vault_region=$(echo "$vault_json" | jq -r '.location')
        source_vault_rg=$(echo "$vault_json" | jq -r '.resourceGroup')

        log_info "========================================="
        log_info "Processing source vault: $source_vault_name ($source_vault_region)"

        # Generate destination vault name
        local dest_vault_name
        dest_vault_name=$(get_destination_vault_name "$source_vault_name" "$source_vault_region")

        log_info "Target destination vault: $dest_vault_name"

        # Ensure destination vault exists
        if ensure_destination_vault "$dest_vault_name" "$source_vault_rg"; then
            # Sync secrets
            sync_vault_secrets "$source_vault_name" "$dest_vault_name"
            ((TOTAL_VAULTS_PROCESSED++))
        else
            log_error "Skipping vault due to missing destination: $source_vault_name"
        fi
    done < <(echo "$source_vaults_json" | jq -c '.[]')
}

# Generate summary report
generate_summary() {
    local summary=""

    summary+="========================================="$'\n'
    summary+="Azure Key Vault Sync - Summary Report"$'\n'
    summary+="========================================="$'\n'
    summary+="Vaults processed: $TOTAL_VAULTS_PROCESSED"$'\n'
    summary+="Secrets created: $TOTAL_SECRETS_CREATED"$'\n'
    summary+="Secrets updated: $TOTAL_SECRETS_UPDATED"$'\n'
    summary+="Secrets deleted: $TOTAL_SECRETS_DELETED"$'\n'
    summary+="Secrets skipped: $TOTAL_SECRETS_SKIPPED"$'\n'
    summary+="Warnings: $TOTAL_WARNINGS"$'\n'
    summary+="Errors: $TOTAL_ERRORS"$'\n'

    if [[ ${#MISSING_DESTINATION_VAULTS[@]} -gt 0 ]]; then
        summary+=$'\n'"Missing destination vaults:"$'\n'
        for missing_vault in "${MISSING_DESTINATION_VAULTS[@]}"; do
            summary+="  - $missing_vault"$'\n'
        done
    fi

    echo "$summary"

    # Send notification
    if [[ $TOTAL_ERRORS -gt 0 ]]; then
        send_notification "error" "AKV Sync Failed" "$summary"
    elif [[ $TOTAL_WARNINGS -gt 0 ]] || [[ ${#MISSING_DESTINATION_VAULTS[@]} -gt 0 ]]; then
        send_notification "warning" "AKV Sync Completed with Warnings" "$summary"
    else
        send_notification "success" "AKV Sync Completed Successfully" "$summary"
    fi
}

# Main execution
main() {
    log_info "========================================="
    log_info "Azure Key Vault Sync Tool v${SCRIPT_VERSION}"
    log_info "Build Date: ${SCRIPT_BUILD_DATE}"
    log_info "========================================="
    echo ""

    validate_prerequisites
    sync_keyvaults

    echo ""
    generate_summary

    if [[ $TOTAL_ERRORS -gt 0 ]]; then
        exit 1
    fi
}

# Run main function
main
