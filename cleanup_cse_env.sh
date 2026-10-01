#!/bin/bash
# v2/cleanup_cse_env.sh - Cloud Shell-Native FinOps Teardown Script
#
# SAFETY GUARANTEE:
# This script strictly destroys ephemeral GKE, Artifact Registry, Workload Identity bindings,
# and ephemeral Node/Build Service Accounts.
# It NEVER deletes or modifies Cloud KMS KeyRings, CryptoKeys, or Cloud Storage (GCS) buckets.

set -euo pipefail

# ==========================================
# 1. SOURCE CENTRALIZED CONFIGURATION
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/cse_config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "❌ ERROR: Configuration file not found at ${CONFIG_FILE}" >&2
    exit 1
fi

# shellcheck source=cse_config.env
source "${CONFIG_FILE}"

WI_MEMBER="serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA}]"

echo "=========================================="
echo "🧹 Starting FinOps Teardown (v2) in ${PROJECT_ID}"
echo "   GKE Cluster : ${CLUSTER_NAME} (${ZONE})"
echo "   AR Repo     : ${AR_REPO} (${REGION})"
echo "   Preserved   : KMS (${KMS_KEY_RING}/${KMS_CRYPTO_KEY}) & GCS (gs://${BUCKET_NAME})"
echo "=========================================="

# ==========================================
# 2. DELETE CONFIDENTIAL GKE CLUSTER
# ==========================================
echo "🗑️  [1/4] Checking GKE cluster '${CLUSTER_NAME}' in ${ZONE}..."
if gcloud container clusters describe "${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   Deleting GKE cluster '${CLUSTER_NAME}'..."
    gcloud container clusters delete "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --quiet
    echo "   ✅ GKE cluster '${CLUSTER_NAME}' deleted."
else
    echo "   ℹ️  GKE cluster '${CLUSTER_NAME}' not found. Skipping."
fi

# ==========================================
# 3. DELETE ARTIFACT REGISTRY REPOSITORY
# ==========================================
echo "🗑️  [2/4] Checking Artifact Registry repository '${AR_REPO}' in ${REGION}..."
if gcloud artifacts repositories describe "${AR_REPO}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   Deleting Artifact Registry repository '${AR_REPO}'..."
    gcloud artifacts repositories delete "${AR_REPO}" \
        --location="${REGION}" \
        --project="${PROJECT_ID}" \
        --quiet
    echo "   ✅ Artifact Registry repository '${AR_REPO}' deleted."
else
    echo "   ℹ️  Artifact Registry repository '${AR_REPO}' not found. Skipping."
fi

# ==========================================
# 4. REMOVE WORKLOAD IDENTITY IAM BINDING
# ==========================================
echo "🔑 [3/4] Removing roles/iam.workloadIdentityUser binding from '${SA_EMAIL}'..."
gcloud iam service-accounts remove-iam-policy-binding "${SA_EMAIL}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="${WI_MEMBER}" \
    --project="${PROJECT_ID}" \
    --quiet >/dev/null 2>&1 || echo "   ℹ️  Binding already absent or service account not modified."
echo "   ✅ Workload Identity binding cleanup complete (Service Account '${SA_EMAIL}' preserved)."

# ==========================================
# 5. CLEAN UP EPHEMERAL NODE & BUILD SERVICE ACCOUNTS
# ==========================================
echo "👤 [4/4] Cleaning up ephemeral Node & Build Service Accounts ('${GKE_NODE_SA_EMAIL}', '${CLOUDBUILD_SA_EMAIL}')..."
for EPHEMERAL_SA in "${GKE_NODE_SA_EMAIL}" "${CLOUDBUILD_SA_EMAIL}"; do
    if gcloud iam service-accounts describe "${EPHEMERAL_SA}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
        gcloud iam service-accounts delete "${EPHEMERAL_SA}" --project="${PROJECT_ID}" --quiet
        echo "   ✅ Deleted ephemeral Service Account '${EPHEMERAL_SA}'."
    else
        echo "   ℹ️  Service Account '${EPHEMERAL_SA}' not found. Skipping."
    fi
done

echo "=========================================="
echo "✅ FinOps Teardown Complete!"
echo "🔒 Preserved intact: KMS KeyRing (${KMS_KEY_RING}), CryptoKey (${KMS_CRYPTO_KEY}), Pod SA (${SA_EMAIL}), and GCS Bucket (gs://${BUCKET_NAME})."
echo "=========================================="

