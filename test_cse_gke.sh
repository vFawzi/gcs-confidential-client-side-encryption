#!/bin/bash
# v2/test_cse_gke.sh - Cloud Shell-Native Unified E2E Test Suite
# Validates Stateless Cross-Pod (Pod A -> GCS -> Pod B) Envelope Encryption.

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

# Allow optional CLI argument override, defaulting to BUCKET_NAME from cse_config.env
TARGET_BUCKET_NAME="${1:-${BUCKET_NAME}}"
TARGET_BUCKET_NAME="${TARGET_BUCKET_NAME#gs://}"
TARGET_BUCKET_NAME="${TARGET_BUCKET_NAME%/}"

APP_LABEL="app=secure-app"
MAIN_CONTAINER="main-application"
PLAINTEXT_PAYLOAD="CONFIDENTIAL_GKE_TEST_PAYLOAD"
OBJECT_NAME="gke_test_payload.enc"
GCS_URI="gs://${TARGET_BUCKET_NAME}/${OBJECT_NAME}"

export USE_GKE_GCLOUD_AUTH_PLUGIN=True

echo "=========================================="
echo "🧪 Starting Unified CSE Test Suite (v2 - Cloud Shell Native)"
echo "   Project : ${PROJECT_ID}"
echo "   Region  : ${REGION} (${ZONE})"
echo "   Cluster : ${CLUSTER_NAME}"
echo "   Target  : ${GCS_URI}"
echo "=========================================="

# Ensure kubeconfig points to the target GKE cluster DNS endpoint
echo "🔐 Ensuring kubectl context is authenticated to '${CLUSTER_NAME}' (DNS endpoint)..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --dns-endpoint \
    --project="${PROJECT_ID}" >/dev/null

# ==========================================
# STEP 1: READINESS CHECK & CROSS-POD SELECTION
# ==========================================
echo "⏳ [Step 1/4] Waiting for '${DEPLOYMENT_NAME}' pods in namespace '${K8S_NAMESPACE}' to reach 'Running' state..."

kubectl rollout status "deployment/${DEPLOYMENT_NAME}" \
    --namespace="${K8S_NAMESPACE}" \
    --timeout=300s

kubectl wait --for=condition=Ready pod \
    --selector="${APP_LABEL}" \
    --namespace="${K8S_NAMESPACE}" \
    --timeout=180s

POD_A=$(kubectl get pods \
    --namespace="${K8S_NAMESPACE}" \
    --selector="${APP_LABEL}" \
    --field-selector=status.phase=Running \
    --output=jsonpath='{.items[0].metadata.name}')

POD_B=$(kubectl get pods \
    --namespace="${K8S_NAMESPACE}" \
    --selector="${APP_LABEL}" \
    --field-selector=status.phase=Running \
    --output=jsonpath='{.items[1].metadata.name}')

if [[ -z "${POD_A}" || -z "${POD_B}" || "${POD_A}" == "${POD_B}" ]]; then
    echo "❌ ERROR: Expected two distinct Running pods for selector '${APP_LABEL}' in namespace '${K8S_NAMESPACE}' (found POD_A='${POD_A}', POD_B='${POD_B}')." >&2
    exit 1
fi

echo "✅ Pod A (Encryption): ${POD_A}"
echo "✅ Pod B (Decryption): ${POD_B}"

# ==========================================
# STEP 2: INGRESS EXECUTION (ENCRYPT VIA POD_A)
# ==========================================
echo "🚀 [Step 2/4] Sending plaintext payload from Pod A ('${POD_A}') '${MAIN_CONTAINER}' to CSE Tink sidecar (127.0.0.1:8080)..."

UPLOAD_URL="http://127.0.0.1:8080/upload/${TARGET_BUCKET_NAME}/${OBJECT_NAME}"

HTTP_RESPONSE=$(kubectl exec \
    --namespace="${K8S_NAMESPACE}" \
    "${POD_A}" \
    --container="${MAIN_CONTAINER}" \
    -- curl --silent --show-error --write-out "\n%{http_code}" \
       -X POST \
       --data-binary "${PLAINTEXT_PAYLOAD}" \
       "${UPLOAD_URL}")

HTTP_BODY=$(echo "${HTTP_RESPONSE}" | sed '$d')
HTTP_STATUS=$(echo "${HTTP_RESPONSE}" | tail -n 1)

echo "   Pod A Sidecar Response (HTTP ${HTTP_STATUS}): ${HTTP_BODY}"

if [[ "${HTTP_STATUS}" != "200" ]]; then
    echo "❌ ERROR: Sidecar upload on Pod A ('${POD_A}') failed with HTTP status ${HTTP_STATUS}." >&2
    exit 1
fi

# ==========================================
# STEP 3: ASSERTION (VERIFY GCS CIPHERTEXT DIRECTLY)
# ==========================================
echo "🔍 [Step 3/4] Inspecting uploaded object '${GCS_URI}' directly via gcloud storage cat..."

TMP_CIPHERTEXT=$(mktemp)
trap 'rm -f "${TMP_CIPHERTEXT}"' EXIT

gcloud storage cat "${GCS_URI}" --project="${PROJECT_ID}" > "${TMP_CIPHERTEXT}"

FILE_SIZE=$(wc -c < "${TMP_CIPHERTEXT}" | tr -d ' ')
if [[ "${FILE_SIZE}" -eq 0 ]]; then
    echo "❌ ASSERTION FAILED: Uploaded object '${GCS_URI}' is empty (0 bytes)!" >&2
    exit 1
fi

if grep -Fq "${PLAINTEXT_PAYLOAD}" "${TMP_CIPHERTEXT}"; then
    echo "❌ SECURITY ASSERTION FAILED: Plaintext '${PLAINTEXT_PAYLOAD}' was found in '${GCS_URI}'!" >&2
    exit 1
fi

echo "✅ ASSERTION PASSED: '${GCS_URI}' (${FILE_SIZE} bytes) is binary ciphertext and does NOT contain plaintext '${PLAINTEXT_PAYLOAD}'."

# ==========================================
# STEP 4: EGRESS VALIDATION (DECRYPT VIA POD_B)
# ==========================================
echo "🔓 [Step 4/4] Requesting decrypted payload from Pod B ('${POD_B}') CSE Tink sidecar (GET /download)..."

DOWNLOAD_URL="http://127.0.0.1:8080/download/${TARGET_BUCKET_NAME}/${OBJECT_NAME}"

DOWNLOAD_RESPONSE=$(kubectl exec \
    --namespace="${K8S_NAMESPACE}" \
    "${POD_B}" \
    --container="${MAIN_CONTAINER}" \
    -- curl --silent --show-error --write-out "\n%{http_code}" \
       -X GET \
       "${DOWNLOAD_URL}")

DECRYPTED_PAYLOAD=$(echo "${DOWNLOAD_RESPONSE}" | sed '$d')
DOWNLOAD_STATUS=$(echo "${DOWNLOAD_RESPONSE}" | tail -n 1)

if [[ "${DOWNLOAD_STATUS}" != "200" ]]; then
    echo "❌ ERROR: Sidecar download on Pod B ('${POD_B}') failed with HTTP status ${DOWNLOAD_STATUS}: ${DECRYPTED_PAYLOAD}" >&2
    exit 1
fi

if [[ "${DECRYPTED_PAYLOAD}" != "${PLAINTEXT_PAYLOAD}" ]]; then
    echo "❌ DECRYPTION ASSERTION FAILED: Expected '${PLAINTEXT_PAYLOAD}', but received '${DECRYPTED_PAYLOAD}' from Pod B ('${POD_B}')." >&2
    exit 1
fi

echo "✅ DECRYPTION ASSERTION PASSED: Egress payload from Pod B ('${POD_B}') exactly matches original plaintext injected into Pod A ('${POD_A}'): '${DECRYPTED_PAYLOAD}'."
echo "=========================================="
echo "🎉 All Stateless Cross-Pod Confidential GKE CSE Tests Passed!"
echo "=========================================="
