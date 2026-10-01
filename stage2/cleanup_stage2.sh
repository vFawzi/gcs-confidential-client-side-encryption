#!/bin/bash
# v2/stage2/cleanup_stage2.sh - Standalone FinOps Teardown Script for Stage 2 OS-Level Agent CSE
#
# Destroys Stage 2 Confidential VM, IAP SSH Firewall Rule, Stage 2 GCS Bucket,
# and Stage 2 Service Account (including project-level logging/monitoring bindings).

set -euo pipefail

# ==========================================
# 1. SOURCE STAGE 2 CONFIGURATION
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/stage2_config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "❌ ERROR: Configuration file not found at ${CONFIG_FILE}" >&2
    exit 1
fi

ENV_PROJECT_ID="${PROJECT_ID:-}"
# shellcheck source=stage2_config.env
source "${CONFIG_FILE}"
export PROJECT_ID="${ENV_PROJECT_ID:-${PROJECT_ID:-}}"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "your-project-id" ]]; then
    echo "❌ ERROR: PROJECT_ID must be exported (e.g., export PROJECT_ID=\"your-gcp-project-id\") or configured in ${CONFIG_FILE}." >&2
    exit 1
fi

export VM_SA_EMAIL="${VM_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export STAGE2_BUCKET_NAME="cse-os-agent-bucket-${PROJECT_ID}"

gcloud config set project "${PROJECT_ID}" >/dev/null

echo "=========================================="
echo "🧹 Starting Stage 2 FinOps Teardown in ${PROJECT_ID}"
echo "   Confidential VM: ${VM_NAME} (${ZONE})"
echo "   IAP Firewall   : ${IAP_FIREWALL_RULE}"
echo "   Stage 2 Bucket : gs://${STAGE2_BUCKET_NAME}"
echo "   Stage 2 VM SA  : ${VM_SA_EMAIL}"
echo "=========================================="

# ==========================================
# 2. DELETE STAGE 2 CONFIDENTIAL VM
# ==========================================
echo "🗑️  [1/4] Checking Stage 2 Confidential VM '${VM_NAME}' in ${ZONE}..."
if gcloud compute instances describe "${VM_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   Deleting Confidential VM '${VM_NAME}'..."
    gcloud compute instances delete "${VM_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --quiet
    echo "   ✅ Confidential VM '${VM_NAME}' deleted."
else
    echo "   ℹ️  Confidential VM '${VM_NAME}' not found. Skipping."
fi

# ==========================================
# 3. DELETE STAGE 2 IAP SSH FIREWALL RULE
# ==========================================
echo "🗑️  [2/4] Checking Stage 2 IAP SSH firewall rule '${IAP_FIREWALL_RULE}'..."
if gcloud compute firewall-rules describe "${IAP_FIREWALL_RULE}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   Deleting firewall rule '${IAP_FIREWALL_RULE}'..."
    gcloud compute firewall-rules delete "${IAP_FIREWALL_RULE}" \
        --project="${PROJECT_ID}" \
        --quiet
    echo "   ✅ Firewall rule '${IAP_FIREWALL_RULE}' deleted."
else
    echo "   ℹ️  Firewall rule '${IAP_FIREWALL_RULE}' not found. Skipping."
fi

# ==========================================
# 4. DELETE STAGE 2 GCS BUCKET
# ==========================================
echo "🗑️  [3/4] Checking Stage 2 GCS Bucket 'gs://${STAGE2_BUCKET_NAME}'..."
if gcloud storage buckets describe "gs://${STAGE2_BUCKET_NAME}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   Removing 'gs://${STAGE2_BUCKET_NAME}' and all objects recursively..."
    gcloud storage rm --recursive "gs://${STAGE2_BUCKET_NAME}" \
        --project="${PROJECT_ID}" \
        --quiet
    echo "   ✅ Stage 2 GCS Bucket 'gs://${STAGE2_BUCKET_NAME}' deleted."
else
    echo "   ℹ️  Stage 2 GCS Bucket 'gs://${STAGE2_BUCKET_NAME}' not found. Skipping."
fi

# ==========================================
# 5. DELETE STAGE 2 SERVICE ACCOUNT & IAM BINDINGS
# ==========================================
echo "👤 [4/4] Cleaning up Stage 2 Service Account '${VM_SA_EMAIL}'..."
for OBS_ROLE in "roles/logging.logWriter" "roles/monitoring.metricWriter"; do
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${VM_SA_EMAIL}" \
        --role="${OBS_ROLE}" \
        --condition=None \
        --quiet >/dev/null 2>&1 || true
done

if gcloud iam service-accounts describe "${VM_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud iam service-accounts delete "${VM_SA_EMAIL}" \
        --project="${PROJECT_ID}" \
        --quiet
    echo "   ✅ Deleted Stage 2 Service Account '${VM_SA_EMAIL}'."
else
    echo "   ℹ️  Service Account '${VM_SA_EMAIL}' not found. Skipping."
fi

echo "=========================================="
echo "✅ Stage 2 FinOps Teardown Complete!"
echo "=========================================="
