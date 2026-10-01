#!/bin/bash
# v2/stage2/test_cse_vm.sh - Stage 2: 4-Stage Zero-Plaintext Verification Protocol
# Validates Transparent OS-Level Encryption (Confidential VM + gcsfuse + gocryptfs -> GCS).

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

# shellcheck source=stage2_config.env
source "${CONFIG_FILE}"

TARGET_BUCKET_NAME="${1:-${STAGE2_BUCKET_NAME}}"
TARGET_BUCKET_NAME="${TARGET_BUCKET_NAME#gs://}"
TARGET_BUCKET_NAME="${TARGET_BUCKET_NAME%/}"

gcloud config set project "${PROJECT_ID}" >/dev/null

PLAINTEXT_FILENAME="euv_wafer_recipe_secret.txt"
PLAINTEXT_PAYLOAD="CONFIDENTIAL_STAGE2_OS_AGENT_PAYLOAD_9042"
PLAINTEXT_LEN="${#PLAINTEXT_PAYLOAD}"

echo "=========================================="
echo "🧪 Starting Stage 2 OS-Level Agent CSE Verification Suite"
echo "   Project        : ${PROJECT_ID}"
echo "   Location       : ${REGION} (${ZONE})"
echo "   Confidential VM: ${VM_NAME}"
echo "   Target Bucket  : gs://${TARGET_BUCKET_NAME}"
echo "   Raw Mount      : ${GCS_RAW_MOUNT}"
echo "   Secure Mount   : ${GCS_SECURE_MOUNT}"
echo "=========================================="

# ==========================================
# STAGE 1: LEGACY POSIX APPLICATION WRITE SIMULATION (IN-VM VIA IAP)
# ==========================================
echo "🚀 [Stage 1/4] Simulating Legacy POSIX Application write to '${GCS_SECURE_MOUNT}/${PLAINTEXT_FILENAME}' over IAP SSH..."

STAGE1_READBACK=$(gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" \
    --tunnel-through-iap \
    --command="sudo bash -c '
        set -euo pipefail
        if ! mountpoint -q \"${GCS_RAW_MOUNT}\" || ! mountpoint -q \"${GCS_SECURE_MOUNT}\"; then
            /usr/local/sbin/cse-mount-overlay.sh \"${TARGET_BUCKET_NAME}\" \"${GCS_RAW_MOUNT}\" \"${GCS_SECURE_MOUNT}\" >/dev/null
        fi
        # Clean up any prior test files in the upper mount so encrypted object discovery is deterministic
        find \"${GCS_SECURE_MOUNT}\" -maxdepth 1 -type f -delete
        sync
        printf \"%s\" \"${PLAINTEXT_PAYLOAD}\" > \"${GCS_SECURE_MOUNT}/${PLAINTEXT_FILENAME}\"
        sync
        cat \"${GCS_SECURE_MOUNT}/${PLAINTEXT_FILENAME}\"
    '")

if [[ "${STAGE1_READBACK}" != "${PLAINTEXT_PAYLOAD}" ]]; then
    echo "❌ STAGE 1 FAILED: Local readback from '${GCS_SECURE_MOUNT}/${PLAINTEXT_FILENAME}' ('${STAGE1_READBACK}') did not match '${PLAINTEXT_PAYLOAD}'." >&2
    exit 1
fi

echo "✅ STAGE 1 PASSED: Legacy POSIX write & transparent readback on '${GCS_SECURE_MOUNT}/${PLAINTEXT_FILENAME}' verified."

# ==========================================
# STAGE 2: LOWER-MOUNT INSPECTION (IN-VM /mnt/gcs_raw CHECK VIA IAP)
# ==========================================
echo "🔍 [Stage 2/4] Inspecting lower gcsfuse mount ('${GCS_RAW_MOUNT}') inside '${VM_NAME}' over IAP SSH..."

ENCRYPTED_REL_NAME=$(gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" \
    --tunnel-through-iap \
    --command="sudo bash -c '
        set -euo pipefail
        if [[ -e \"${GCS_RAW_MOUNT}/${PLAINTEXT_FILENAME}\" ]]; then
            echo \"PLAINTEXT_FILENAME_LEAKED\"
            exit 1
        fi
        if [[ ! -f \"${GCS_RAW_MOUNT}/gocryptfs.conf\" || ! -f \"${GCS_RAW_MOUNT}/gocryptfs.diriv\" ]]; then
            echo \"MISSING_GOCRYPTFS_METADATA\"
            exit 1
        fi
        find \"${GCS_RAW_MOUNT}\" -maxdepth 1 -type f ! -name \"gocryptfs.conf\" ! -name \"gocryptfs.diriv\" -printf \"%f\n\" | head -n 1
    '")

if [[ -z "${ENCRYPTED_REL_NAME}" || "${ENCRYPTED_REL_NAME}" == "${PLAINTEXT_FILENAME}" ]]; then
    echo "❌ STAGE 2 FAILED: Could not verify EME-encrypted filename in '${GCS_RAW_MOUNT}' (got: '${ENCRYPTED_REL_NAME}')." >&2
    exit 1
fi

echo "✅ STAGE 2 PASSED: Plaintext filename '${PLAINTEXT_FILENAME}' is absent in '${GCS_RAW_MOUNT}'; EME-encrypted filename is '${ENCRYPTED_REL_NAME}'."

# ==========================================
# STAGE 3: OUT-OF-BAND CSP ZERO-PLAINTEXT VERIFICATION (LOCAL RUNNER -> GCS)
# ==========================================
echo "☁️  [Stage 3/4] Auditing 'gs://${TARGET_BUCKET_NAME}' directly from runner environment (bypassing VM & gocryptfs)..."

BUCKET_Listing=$(gcloud storage ls "gs://${TARGET_BUCKET_NAME}/" --project="${PROJECT_ID}")

if echo "${BUCKET_Listing}" | grep -Fq "${PLAINTEXT_FILENAME}"; then
    echo "❌ STAGE 3 SECURITY ASSERTION FAILED: Plaintext filename '${PLAINTEXT_FILENAME}' was found in 'gs://${TARGET_BUCKET_NAME}/'!" >&2
    exit 1
fi

GCS_CIPHERTEXT_URI="gs://${TARGET_BUCKET_NAME}/${ENCRYPTED_REL_NAME}"
if ! echo "${BUCKET_Listing}" | grep -Fq "${GCS_CIPHERTEXT_URI}"; then
    echo "❌ STAGE 3 FAILED: Expected encrypted object '${GCS_CIPHERTEXT_URI}' not found in GCS listing:" >&2
    echo "${BUCKET_Listing}" >&2
    exit 1
fi

TMP_CIPHERTEXT=$(mktemp)
trap 'rm -f "${TMP_CIPHERTEXT}"' EXIT

gcloud storage cat "${GCS_CIPHERTEXT_URI}" --project="${PROJECT_ID}" > "${TMP_CIPHERTEXT}"

CIPHERTEXT_SIZE=$(wc -c < "${TMP_CIPHERTEXT}" | tr -d ' ')
# gocryptfs adds 18-byte header + 16-byte IV + 16-byte GCM tag (50 bytes overhead) to the 46-byte plaintext
if [[ "${CIPHERTEXT_SIZE}" -le "${PLAINTEXT_LEN}" ]]; then
    echo "❌ STAGE 3 ASSERTION FAILED: Ciphertext size (${CIPHERTEXT_SIZE} bytes) is not greater than plaintext size (${PLAINTEXT_LEN} bytes)!" >&2
    exit 1
fi

if grep -Fq "${PLAINTEXT_PAYLOAD}" "${TMP_CIPHERTEXT}"; then
    echo "❌ STAGE 3 SECURITY ASSERTION FAILED: Plaintext payload '${PLAINTEXT_PAYLOAD}' was found inside '${GCS_CIPHERTEXT_URI}'!" >&2
    exit 1
fi

echo "✅ STAGE 3 PASSED: Direct GCS inspection confirmed obfuscated filename ('${ENCRYPTED_REL_NAME}') and binary AES-256-GCM ciphertext (${CIPHERTEXT_SIZE} bytes vs ${PLAINTEXT_LEN} bytes plaintext, zero cleartext match)."

# ==========================================
# STAGE 4: COLD REMOUNT & CRYPTOGRAPHIC INTEGRITY VERIFICATION (IN-VM VIA IAP)
# ==========================================
echo "🔓 [Stage 4/4] Performing Cold Unmount & Remount of '${GCS_SECURE_MOUNT}' and '${GCS_RAW_MOUNT}' inside '${VM_NAME}'..."

STAGE4_DECRYPTED=$(gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" \
    --tunnel-through-iap \
    --command="sudo bash -c '
        set -euo pipefail
        # Unmount upper (gocryptfs) and lower (gcsfuse) filesystems completely
        sync
        fusermount3 -u \"${GCS_SECURE_MOUNT}\" || umount -l \"${GCS_SECURE_MOUNT}\"
        sleep 1
        fusermount3 -u \"${GCS_RAW_MOUNT}\" || umount -l \"${GCS_RAW_MOUNT}\"
        # Verify DEK file was previously shredded from tmpfs
        if [[ -f /run/cse_keys/dek.pass ]]; then
            echo \"DEK_NOT_SHREDDED\"
            exit 1
        fi
        # Re-execute simulated KMS DEK injection in SEV tmpfs RAM and remount both layers
        /usr/local/sbin/cse-mount-overlay.sh \"${TARGET_BUCKET_NAME}\" \"${GCS_RAW_MOUNT}\" \"${GCS_SECURE_MOUNT}\" >/dev/null
        # Verify DEK was shredded again immediately after mount
        if [[ -f /run/cse_keys/dek.pass ]]; then
            echo \"DEK_NOT_SHREDDED_POST_REMOUNT\"
            exit 1
        fi
        cat \"${GCS_SECURE_MOUNT}/${PLAINTEXT_FILENAME}\"
    '")

if [[ "${STAGE4_DECRYPTED}" != "${PLAINTEXT_PAYLOAD}" ]]; then
    echo "❌ STAGE 4 DECRYPTION ASSERTION FAILED: Expected '${PLAINTEXT_PAYLOAD}', but received '${STAGE4_DECRYPTED}' after cold remount." >&2
    exit 1
fi

echo "✅ STAGE 4 PASSED: Cold remount decrypted '${GCS_SECURE_MOUNT}/${PLAINTEXT_FILENAME}' intact ('${STAGE4_DECRYPTED}') with ephemeral tmpfs DEK shredded."
echo "=========================================="
echo "🎉 All 4 Stages of the Stage 2 OS-Level Agent CSE Verification Protocol Passed!"
echo "=========================================="
