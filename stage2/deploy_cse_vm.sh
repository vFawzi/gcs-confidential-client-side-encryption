#!/bin/bash
# v2/stage2/deploy_cse_vm.sh - Stage 2: Client-Side Encryption via Transparent OS-Level Agent
# Provisions a Confidential VM (n2d-standard-2, AMD SEV) with gcsfuse + gocryptfs POSIX overlay.

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

echo "=========================================="
echo "🚀 Starting Stage 2 OS-Level Agent CSE Deployment"
echo "   Project        : ${PROJECT_ID}"
echo "   Location       : ${REGION} (${ZONE})"
echo "   Network        : ${VPC_NETWORK} / ${VPC_SUBNET}"
echo "   Confidential VM: ${VM_NAME} (n2d-standard-2, AMD SEV)"
echo "   VM Identity    : ${VM_SA_EMAIL}"
echo "   Stage 2 Bucket : gs://${STAGE2_BUCKET_NAME}"
echo "   Raw Mount      : ${GCS_RAW_MOUNT}"
echo "   Secure Mount   : ${GCS_SECURE_MOUNT}"
echo "=========================================="

gcloud config set project "${PROJECT_ID}" >/dev/null

# ==========================================
# 2. ENABLE REQUIRED APIS & VERIFY NETWORK / KMS PREREQUISITES
# ==========================================
echo "📦 [1/6] Ensuring required Google Cloud APIs are enabled..."
gcloud services enable \
    compute.googleapis.com \
    iam.googleapis.com \
    cloudkms.googleapis.com \
    storage.googleapis.com \
    iap.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    --project="${PROJECT_ID}"

echo "🌐 [2/6] Verifying VPC Network '${VPC_NETWORK}', Subnet '${VPC_SUBNET}' (PGA), Cloud NAT & IAP Firewall..."
if ! gcloud compute networks describe "${VPC_NETWORK}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   🚀 Creating custom-mode VPC network '${VPC_NETWORK}'..."
    gcloud compute networks create "${VPC_NETWORK}" \
        --project="${PROJECT_ID}" \
        --subnet-mode=custom \
        --bgp-routing-mode=regional
fi

if ! gcloud compute networks subnets describe "${VPC_SUBNET}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   🚀 Creating subnet '${VPC_SUBNET}' (${VPC_SUBNET_CIDR}) with Private Google Access..."
    gcloud compute networks subnets create "${VPC_SUBNET}" \
        --project="${PROJECT_ID}" \
        --network="${VPC_NETWORK}" \
        --region="${REGION}" \
        --range="${VPC_SUBNET_CIDR}" \
        --enable-private-ip-google-access
else
    PGA_ENABLED=$(gcloud compute networks subnets describe "${VPC_SUBNET}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="value(privateIpGoogleAccess)")
    if [[ "${PGA_ENABLED}" != "True" ]]; then
        gcloud compute networks subnets update "${VPC_SUBNET}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --enable-private-ip-google-access
    fi
fi

if ! gcloud compute routers describe "${CLOUD_ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute routers create "${CLOUD_ROUTER_NAME}" \
        --network="${VPC_NETWORK}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}"
fi

if ! gcloud compute routers nats describe "${CLOUD_NAT_NAME}" --router="${CLOUD_ROUTER_NAME}" --region="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute routers nats create "${CLOUD_NAT_NAME}" \
        --router="${CLOUD_ROUTER_NAME}" \
        --region="${REGION}" \
        --auto-allocate-nat-external-ips \
        --nat-all-subnet-ip-ranges \
        --project="${PROJECT_ID}"
fi

if gcloud compute firewall-rules describe "${IAP_FIREWALL_RULE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ IAP SSH firewall rule '${IAP_FIREWALL_RULE}' already exists."
else
    echo "   🚀 Creating IAP SSH firewall rule '${IAP_FIREWALL_RULE}' (35.235.240.0/20 -> tcp:22, tag: ${IAP_NETWORK_TAG})..."
    gcloud compute firewall-rules create "${IAP_FIREWALL_RULE}" \
        --network="${VPC_NETWORK}" \
        --direction=INGRESS \
        --action=ALLOW \
        --rules=tcp:22 \
        --source-ranges=35.235.240.0/20 \
        --target-tags="${IAP_NETWORK_TAG}" \
        --project="${PROJECT_ID}"
    echo "   ✅ IAP SSH firewall rule '${IAP_FIREWALL_RULE}' created."
fi

# ==========================================
# 3. VERIFY KMS KEY & CREATE STAGE 2 GCS BUCKET
# ==========================================
echo "🪣 [3/6] Verifying Cloud KMS Key and Stage 2 Ciphertext Bucket 'gs://${STAGE2_BUCKET_NAME}'..."
if ! gcloud kms keyrings describe "${KMS_KEY_RING}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud kms keyrings create "${KMS_KEY_RING}" --location="${REGION}" --project="${PROJECT_ID}"
fi

if ! gcloud kms keys describe "${KMS_CRYPTO_KEY}" --keyring="${KMS_KEY_RING}" --location="${REGION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud kms keys create "${KMS_CRYPTO_KEY}" \
        --keyring="${KMS_KEY_RING}" \
        --location="${REGION}" \
        --purpose="encryption" \
        --project="${PROJECT_ID}"
fi

if gcloud storage buckets describe "gs://${STAGE2_BUCKET_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ Stage 2 GCS Bucket 'gs://${STAGE2_BUCKET_NAME}' already exists."
else
    echo "   🚀 Creating Stage 2 GCS Bucket 'gs://${STAGE2_BUCKET_NAME}' in ${REGION}..."
    gcloud storage buckets create "gs://${STAGE2_BUCKET_NAME}" \
        --location="${REGION}" \
        --uniform-bucket-level-access \
        --public-access-prevention \
        --project="${PROJECT_ID}"
    echo "   ✅ Stage 2 GCS Bucket 'gs://${STAGE2_BUCKET_NAME}' created."
fi

# ==========================================
# 4. DEDICATED STAGE 2 VM SERVICE ACCOUNT & LEAST-PRIVILEGE IAM
# ==========================================
echo "👤 [4/6] Verifying Dedicated Stage 2 VM Service Account '${VM_SA_EMAIL}'..."
if gcloud iam service-accounts describe "${VM_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ Service Account '${VM_SA_EMAIL}' already exists."
else
    echo "   🚀 Creating Service Account '${VM_SA_NAME}'..."
    gcloud iam service-accounts create "${VM_SA_NAME}" \
        --display-name="Stage 2 CSE Confidential VM Service Account" \
        --project="${PROJECT_ID}"
    echo "   ✅ Service Account '${VM_SA_EMAIL}' created. Waiting briefly for IAM propagation..."
    sleep 10
fi

echo "   🔑 Granting bucket-scoped roles/storage.objectAdmin on 'gs://${STAGE2_BUCKET_NAME}' to '${VM_SA_EMAIL}'..."
for SA_PROP_ATTEMPT in {1..6}; do
    if gcloud storage buckets add-iam-policy-binding "gs://${STAGE2_BUCKET_NAME}" \
        --member="serviceAccount:${VM_SA_EMAIL}" \
        --role="roles/storage.objectAdmin" \
        --project="${PROJECT_ID}" >/dev/null 2>&1; then
        break
    fi
    if [[ "${SA_PROP_ATTEMPT}" -eq 6 ]]; then
        echo "❌ ERROR: Failed to bind roles/storage.objectAdmin to '${VM_SA_EMAIL}' after 6 attempts." >&2
        exit 1
    fi
    echo "   ⏳ Waiting for Service Account '${VM_SA_EMAIL}' IAM propagation (attempt ${SA_PROP_ATTEMPT}/6)..."
    sleep 5
done

echo "   🔑 Granting key-scoped roles/cloudkms.cryptoKeyEncrypterDecrypter on '${KMS_CRYPTO_KEY}' to '${VM_SA_EMAIL}'..."
gcloud kms keys add-iam-policy-binding "${KMS_CRYPTO_KEY}" \
    --keyring="${KMS_KEY_RING}" \
    --location="${REGION}" \
    --member="serviceAccount:${VM_SA_EMAIL}" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
    --project="${PROJECT_ID}" >/dev/null

for OBS_ROLE in "roles/logging.logWriter" "roles/monitoring.metricWriter"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${VM_SA_EMAIL}" \
        --role="${OBS_ROLE}" \
        --condition=None \
        --quiet >/dev/null
done

# ==========================================
# 5. GENERATE METADATA STARTUP SCRIPT (GCSFUSE + GOCRYPTFS + TMPFS DEK)
# ==========================================
echo "📝 [5/6] Generating Confidential VM Startup Script (gcsfuse + gocryptfs + tmpfs DEK purge)..."
STARTUP_SCRIPT_FILE=$(mktemp)
trap 'rm -f "${STARTUP_SCRIPT_FILE}"' EXIT

cat << EOF > "${STARTUP_SCRIPT_FILE}"
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
STAGE2_BUCKET_NAME="${STAGE2_BUCKET_NAME}"
GCS_RAW_MOUNT="${GCS_RAW_MOUNT}"
GCS_SECURE_MOUNT="${GCS_SECURE_MOUNT}"
READY_MARKER="/var/run/cse_stage2_ready"

rm -f "\${READY_MARKER}" /etc/apt/sources.list.d/gcsfuse.list

echo "[CSE-Stage2] Installing base dependencies, gocryptfs, and gcsfuse..."
apt-get update -y
apt-get install -y curl gnupg lsb-release fuse3 gocryptfs jq coreutils util-linux

if ! command -v gcsfuse >/dev/null 2>&1; then
    CODENAME=\$(lsb_release -c -s)
    mkdir -p /usr/share/keyrings
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
    chmod a+r /usr/share/keyrings/cloud.google.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt gcsfuse-\${CODENAME} main" > /etc/apt/sources.list.d/gcsfuse.list
    apt-get update -y
    apt-get install -y gcsfuse
fi

# Create reusable mount helper for both initial boot and Stage 4 remount validation
cat << 'HELPER_EOF' > /usr/local/sbin/cse-mount-overlay.sh
#!/bin/bash
set -euo pipefail

STAGE2_BUCKET_NAME="\${1:-${STAGE2_BUCKET_NAME}}"
GCS_RAW_MOUNT="\${2:-${GCS_RAW_MOUNT}}"
GCS_SECURE_MOUNT="\${3:-${GCS_SECURE_MOUNT}}"
KEY_TMPFS_DIR="/run/cse_keys"
DEK_FILE="\${KEY_TMPFS_DIR}/dek.pass"

mkdir -p "\${GCS_RAW_MOUNT}" "\${GCS_SECURE_MOUNT}" "\${KEY_TMPFS_DIR}"
chmod 0700 "\${GCS_RAW_MOUNT}" "\${GCS_SECURE_MOUNT}" "\${KEY_TMPFS_DIR}"

# 1. Mount isolated RAM-backed tmpfs in AMD SEV encrypted memory for key staging
if ! mountpoint -q "\${KEY_TMPFS_DIR}"; then
    mount -t tmpfs -o size=16m,mode=0700 tmpfs "\${KEY_TMPFS_DIR}"
fi

# 2. Simulate External KMS (HYOK / CipherTrust) DEK injection strictly into SEV tmpfs RAM
printf '%s' "SIMULATED_EXTERNAL_KMS_DEK_${PROJECT_ID}_${KMS_KEY_RING}_${KMS_CRYPTO_KEY}_AES256GCM" > "\${DEK_FILE}"
chmod 0400 "\${DEK_FILE}"

# 3. Mount lower layer (gcsfuse -> GCS ciphertext bucket) with --implicit-dirs
if ! mountpoint -q "\${GCS_RAW_MOUNT}"; then
    gcsfuse --implicit-dirs -o rw,nodev,nosuid "\${STAGE2_BUCKET_NAME}" "\${GCS_RAW_MOUNT}" >/dev/null
fi

# 4. Initialize gocryptfs in /mnt/gcs_raw if not already initialized
if [[ ! -f "\${GCS_RAW_MOUNT}/gocryptfs.conf" ]]; then
    echo "[CSE-Stage2] Initializing new gocryptfs AES-256-GCM + EME overlay in \${GCS_RAW_MOUNT}..."
    gocryptfs -init -q -passfile "\${DEK_FILE}" -scryptn 16 "\${GCS_RAW_MOUNT}"
    sync
fi

# 5. Mount upper layer (gocryptfs transparent plaintext view -> /mnt/gcs_secure)
if ! mountpoint -q "\${GCS_SECURE_MOUNT}"; then
    gocryptfs -q -passfile "\${DEK_FILE}" "\${GCS_RAW_MOUNT}" "\${GCS_SECURE_MOUNT}"
fi

# 6. Immediately shred and unlink the DEK from tmpfs RAM
if [[ -f "\${DEK_FILE}" ]]; then
    shred -u "\${DEK_FILE}"
fi
HELPER_EOF

chmod 0700 /usr/local/sbin/cse-mount-overlay.sh
/usr/local/sbin/cse-mount-overlay.sh "\${STAGE2_BUCKET_NAME}" "\${GCS_RAW_MOUNT}" "\${GCS_SECURE_MOUNT}"

touch "\${READY_MARKER}"
echo "[CSE-Stage2] Transparent OS-Level Encryption Overlay is mounted and ready."
EOF

# ==========================================
# 6. DEPLOY CONFIDENTIAL VM (N2D + AMD SEV + SHIELDED + NO EXTERNAL IP)
# ==========================================
echo "🖥️  [6/6] Verifying Confidential VM '${VM_NAME}' in ${ZONE}..."
if gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    VM_STATUS=$(gcloud compute instances describe "${VM_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --format="value(status)")
    echo "   ℹ️  Confidential VM '${VM_NAME}' already exists (status: ${VM_STATUS}). Updating startup-script metadata..."
    gcloud compute instances add-metadata "${VM_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --metadata-from-file="startup-script=${STARTUP_SCRIPT_FILE}" >/dev/null
    if [[ "${VM_STATUS}" != "RUNNING" ]]; then
        gcloud compute instances start "${VM_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}"
    fi
    echo "   🔄 Re-applying startup script on running VM '${VM_NAME}' via IAP SSH..."
    gcloud compute ssh "${VM_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --tunnel-through-iap \
        --command="sudo bash -s" < "${STARTUP_SCRIPT_FILE}"
else
    echo "   🚀 Provisioning Confidential VM '${VM_NAME}' (n2d-standard-2, AMD SEV, Shielded Boot, No External IP)..."
    gcloud compute instances create "${VM_NAME}" \
        --zone="${ZONE}" \
        --machine-type=n2d-standard-2 \
        --confidential-compute-type=SEV \
        --maintenance-policy=TERMINATE \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --boot-disk-size=20GB \
        --boot-disk-type=pd-balanced \
        --shielded-secure-boot \
        --shielded-vtpm \
        --shielded-integrity-monitoring \
        --network="${VPC_NETWORK}" \
        --subnet="${VPC_SUBNET}" \
        --no-address \
        --tags="${IAP_NETWORK_TAG}" \
        --service-account="${VM_SA_EMAIL}" \
        --scopes="https://www.googleapis.com/auth/cloud-platform" \
        --metadata-from-file="startup-script=${STARTUP_SCRIPT_FILE}" \
        --labels="environment=mvp,data_classification=strictly_confidential,cost_center=sec_arch,stage=stage2_os_agent" \
        --project="${PROJECT_ID}"
    echo "   ✅ Confidential VM '${VM_NAME}' created."
fi

echo "⏳ Waiting for Confidential VM '${VM_NAME}' startup script to finish mounting gcsfuse + gocryptfs over IAP..."
MAX_ATTEMPTS=30
ATTEMPT=1
until gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" \
    --tunnel-through-iap \
    --command="sudo test -f /var/run/cse_stage2_ready && sudo mountpoint -q '${GCS_RAW_MOUNT}' && sudo mountpoint -q '${GCS_SECURE_MOUNT}'" >/dev/null 2>&1; do
    if [[ "${ATTEMPT}" -ge "${MAX_ATTEMPTS}" ]]; then
        echo "❌ ERROR: Timed out waiting for '${VM_NAME}' mounts ('${GCS_RAW_MOUNT}' and '${GCS_SECURE_MOUNT}') to become ready." >&2
        exit 1
    fi
    echo "   ⏳ [Attempt ${ATTEMPT}/${MAX_ATTEMPTS}] Bootstrap in progress (installing packages / mounting overlay)... sleeping 10s"
    sleep 10
    ATTEMPT=$((ATTEMPT + 1))
done

echo "=========================================="
echo "✅ Stage 2 OS-Level Agent CSE Deployment Complete!"
echo "   Run './stage2/test_cse_vm.sh' to execute the 4-Stage Zero-Plaintext Verification Protocol."
echo "=========================================="
