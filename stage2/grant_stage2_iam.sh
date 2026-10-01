#!/bin/bash
# v2/stage2/grant_stage2_iam.sh - Grants Least-Privilege IAM Roles for Stage 2 OS-Level Agent CSE
# Run as Project / Organization IAM Admin.

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
DEPLOYER_PRINCIPAL="${2:-${DEPLOYER_PRINCIPAL}}"

gcloud config set project "${PROJECT_ID}" >/dev/null

ROLES=(
    "roles/serviceusage.serviceUsageAdmin"
    "roles/compute.networkAdmin"
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
echo "🔑 Granting Stage 2 Least-Privilege Deployment Roles"
echo "   Project   : ${PROJECT_ID}"
echo "   Principal : ${DEPLOYER_PRINCIPAL}"
echo "=========================================="

for ROLE in "${ROLES[@]}"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="${DEPLOYER_PRINCIPAL}" \
        --role="${ROLE}" \
        --condition=None \
        --quiet >/dev/null
    echo "✅ Granted ${ROLE} to ${DEPLOYER_PRINCIPAL}"
done

echo "=========================================="
echo "🎉 All Stage 2 Least-Privilege IAM Roles Granted!"
echo "=========================================="
