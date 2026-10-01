#!/bin/bash
# v2/grant_deployer_iam.sh - Grants Least-Privilege IAM Roles to the CSE Deployer Principal
# Run as Project / Organization IAM Admin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/cse_config.env" ]]; then
    # shellcheck source=cse_config.env
    source "${SCRIPT_DIR}/cse_config.env"
fi

PROJECT_ID="${1:-${PROJECT_ID}}"
DEPLOYER_PRINCIPAL="${2:-${DEPLOYER_PRINCIPAL:-user:user@example.com}}"

gcloud config set project "${PROJECT_ID}" >/dev/null

ROLES=(
    "roles/serviceusage.serviceUsageAdmin"
    "roles/compute.networkAdmin"
    "roles/cloudkms.admin"
    "roles/iam.serviceAccountAdmin"
    "roles/iam.serviceAccountUser"
    "roles/resourcemanager.projectIamAdmin"
    "roles/storage.admin"
    "roles/artifactregistry.admin"
    "roles/container.admin"
    "roles/cloudbuild.builds.editor"
    "roles/logging.viewer"
)

echo "=========================================="
echo "🔑 Granting Least-Privilege Deployment Roles"
echo "   Project   : ${PROJECT_ID}"
echo "   Principal : ${DEPLOYER_PRINCIPAL}"
echo "=========================================="

for ROLE in "${ROLES[@]}"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="${DEPLOYER_PRINCIPAL}" --role="${ROLE}" --condition=None --quiet >/dev/null
    echo "✅ Granted ${ROLE} to ${DEPLOYER_PRINCIPAL}"
done

echo "=========================================="
echo "🎉 All Least-Privilege IAM Roles Granted!"
echo "=========================================="
