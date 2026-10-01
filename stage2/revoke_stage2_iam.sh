#!/bin/bash
# v2/stage2/revoke_stage2_iam.sh - Revokes Elevated Deployment IAM Roles from the Stage 2 CSE Deployer Principal
# Enforces Principle of Least Privilege (Zero Standing Privileges post-deployment).
# Run as Project / Organization IAM Admin after Stage 2 deployment & verification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/stage2_config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "❌ ERROR: Configuration file not found at ${CONFIG_FILE}" >&2
    exit 1
fi

# shellcheck source=stage2_config.env
source "${CONFIG_FILE}"

PROJECT_ID="${1:-${PROJECT_ID}}"
DEPLOYER_PRINCIPAL="${2:-${DEPLOYER_PRINCIPAL:-user:user@example.com}}"

gcloud config set project "${PROJECT_ID}" >/dev/null

ROLES=(
    "roles/serviceusage.serviceUsageAdmin"
    "roles/compute.networkAdmin"
    "roles/compute.securityAdmin"
    "roles/compute.instanceAdmin.v1"
    "roles/iap.tunnelResourceAccessor"
    "roles/cloudkms.admin"
    "roles/iam.serviceAccountAdmin"
    "roles/iam.serviceAccountUser"
    "roles/resourcemanager.projectIamAdmin"
    "roles/storage.admin"
    "roles/logging.viewer"
)

echo "=========================================="
echo "🔒 Revoking Stage 2 Elevated Deployment IAM Roles"
echo "   Project   : ${PROJECT_ID}"
echo "   Principal : ${DEPLOYER_PRINCIPAL}"
echo "=========================================="

for ROLE in "${ROLES[@]}"; do
    if gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="${DEPLOYER_PRINCIPAL}" \
        --role="${ROLE}" \
        --condition=None \
        --quiet >/dev/null 2>&1; then
        echo "✅ Revoked ${ROLE} from ${DEPLOYER_PRINCIPAL}"
    else
        echo "ℹ️  Role ${ROLE} already absent on ${DEPLOYER_PRINCIPAL}. Skipping."
    fi
done

echo "=========================================="
echo "🛡️  All Stage 2 Elevated Deployment IAM Roles Revoked!"
echo "=========================================="
