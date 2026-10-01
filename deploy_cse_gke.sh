#!/bin/bash
# v2/deploy_cse_gke.sh - Cloud Shell-Native Master Deployment Script for Confidential GKE CSE
# Enforces Zero-Trust Identity Separation (3 dedicated SAs; zero Default Compute SA usage).

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

export USE_GKE_GCLOUD_AUTH_PLUGIN=True

echo "=========================================="
echo "🚀 Starting Zero-Trust CSE Deployment (v2)"
echo "   Project       : ${PROJECT_ID}"
echo "   Location      : ${REGION} (${ZONE})"
echo "   Network       : ${VPC_NETWORK} / ${VPC_SUBNET}"
echo "   Pod WI SA     : ${SA_EMAIL}"
echo "   GKE Node SA   : ${GKE_NODE_SA_EMAIL}"
echo "   CloudBuild SA : ${CLOUDBUILD_SA_EMAIL}"
echo "   Data Bucket   : gs://${BUCKET_NAME}"
echo "   Staging Bucket: gs://${BUILD_STAGING_BUCKET}"
echo "   KMS Key       : ${KMS_KEY_URI}"
echo "=========================================="

gcloud config set project "${PROJECT_ID}" >/dev/null

# ==========================================
# 2. ENABLE REQUIRED GCP APIS
# ==========================================
echo "📦 [1/9] Enabling required Google Cloud APIs..."
gcloud services enable \
    compute.googleapis.com \
    cloudresourcemanager.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    sts.googleapis.com \
    cloudkms.googleapis.com \
    storage.googleapis.com \
    artifactregistry.googleapis.com \
    container.googleapis.com \
    cloudbuild.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    --project="${PROJECT_ID}"

# ==========================================
# 3. VPC & SUBNET IDEMPOTENCY (WITH PGA)
# ==========================================
echo "🌐 [2/9] Verifying VPC Network '${VPC_NETWORK}' and Subnet '${VPC_SUBNET}'..."
if gcloud compute networks describe "${VPC_NETWORK}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ VPC network '${VPC_NETWORK}' already exists."
else
    echo "   🚀 Creating custom-mode VPC network '${VPC_NETWORK}'..."
    gcloud compute networks create "${VPC_NETWORK}" \
        --project="${PROJECT_ID}" \
        --subnet-mode=custom \
        --bgp-routing-mode=regional
    echo "   ✅ VPC network '${VPC_NETWORK}' created."
fi

if gcloud compute networks subnets describe "${VPC_SUBNET}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ℹ️  Subnet '${VPC_SUBNET}' already exists. Verifying Private Google Access..."
    PGA_ENABLED=$(gcloud compute networks subnets describe "${VPC_SUBNET}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --format="value(privateIpGoogleAccess)")
    if [[ "${PGA_ENABLED}" != "True" ]]; then
        gcloud compute networks subnets update "${VPC_SUBNET}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" \
            --enable-private-ip-google-access
        echo "   ✅ Private Google Access enabled on '${VPC_SUBNET}'."
    else
        echo "   ✅ Private Google Access is already enabled on '${VPC_SUBNET}'."
    fi
else
    echo "   🚀 Creating subnet '${VPC_SUBNET}' (${VPC_SUBNET_CIDR}) with Private Google Access..."
    gcloud compute networks subnets create "${VPC_SUBNET}" \
        --project="${PROJECT_ID}" \
        --network="${VPC_NETWORK}" \
        --region="${REGION}" \
        --range="${VPC_SUBNET_CIDR}" \
        --enable-private-ip-google-access
    echo "   ✅ Subnet '${VPC_SUBNET}' created with Private Google Access."
fi

# Provision Cloud Router & Cloud NAT so Private GKE Nodes (no external IPs) can pull public images
CLOUD_ROUTER_NAME="${CLOUD_ROUTER_NAME:-${VPC_NETWORK}-nat-router}"
CLOUD_NAT_NAME="${CLOUD_NAT_NAME:-${VPC_NETWORK}-nat-gateway}"

if gcloud compute routers describe "${CLOUD_ROUTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ Cloud Router '${CLOUD_ROUTER_NAME}' already exists."
else
    echo "   🚀 Creating Cloud Router '${CLOUD_ROUTER_NAME}' in ${REGION}..."
    gcloud compute routers create "${CLOUD_ROUTER_NAME}" \
        --network="${VPC_NETWORK}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}"
    echo "   ✅ Cloud Router '${CLOUD_ROUTER_NAME}' created."
fi

if gcloud compute routers nats describe "${CLOUD_NAT_NAME}" \
    --router="${CLOUD_ROUTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ Cloud NAT '${CLOUD_NAT_NAME}' already exists."
else
    echo "   🚀 Creating Cloud NAT '${CLOUD_NAT_NAME}' for Private GKE Nodes..."
    gcloud compute routers nats create "${CLOUD_NAT_NAME}" \
        --router="${CLOUD_ROUTER_NAME}" \
        --region="${REGION}" \
        --auto-allocate-nat-external-ips \
        --nat-all-subnet-ip-ranges \
        --project="${PROJECT_ID}"
    echo "   ✅ Cloud NAT '${CLOUD_NAT_NAME}' created."
fi

# ==========================================
# 4. KMS KEYRING & CRYPTOKEY (IDEMPOTENT)
# ==========================================
echo "🔐 [3/9] Verifying Cloud KMS KeyRing '${KMS_KEY_RING}' and CryptoKey '${KMS_CRYPTO_KEY}'..."
if gcloud kms keyrings describe "${KMS_KEY_RING}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ KMS KeyRing '${KMS_KEY_RING}' already exists."
else
    echo "   🚀 Creating KMS KeyRing '${KMS_KEY_RING}' in ${REGION}..."
    gcloud kms keyrings create "${KMS_KEY_RING}" \
        --location="${REGION}" \
        --project="${PROJECT_ID}"
    echo "   ✅ KMS KeyRing '${KMS_KEY_RING}' created."
fi

if gcloud kms keys describe "${KMS_CRYPTO_KEY}" \
    --keyring="${KMS_KEY_RING}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ KMS CryptoKey '${KMS_CRYPTO_KEY}' already exists."
else
    echo "   🚀 Creating KMS CryptoKey '${KMS_CRYPTO_KEY}'..."
    gcloud kms keys create "${KMS_CRYPTO_KEY}" \
        --keyring="${KMS_KEY_RING}" \
        --location="${REGION}" \
        --purpose="encryption" \
        --project="${PROJECT_ID}"
    echo "   ✅ KMS CryptoKey '${KMS_CRYPTO_KEY}' created."
fi

# ==========================================
# 5. DEDICATED SERVICE ACCOUNTS (ZERO DEFAULT SA)
# ==========================================
echo "👤 [4/9] Verifying 3 Dedicated Least-Privilege Service Accounts..."

create_sa_if_missing() {
    local sa_name="$1"
    local sa_email="$2"
    local display_name="$3"
    if gcloud iam service-accounts describe "${sa_email}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
        echo "   ✅ Service Account '${sa_email}' already exists."
    else
        echo "   🚀 Creating Service Account '${sa_name}' (${display_name})..."
        gcloud iam service-accounts create "${sa_name}" \
            --display-name="${display_name}" \
            --project="${PROJECT_ID}"
        echo "   ✅ Service Account '${sa_email}' created."
    fi
}

create_sa_if_missing "${SA_NAME}" "${SA_EMAIL}" "CSE Workload Identity Pod SA"
create_sa_if_missing "${GKE_NODE_SA_NAME}" "${GKE_NODE_SA_EMAIL}" "CSE GKE Confidential Node Pool SA"
create_sa_if_missing "${CLOUDBUILD_SA_NAME}" "${CLOUDBUILD_SA_EMAIL}" "CSE Cloud Build Worker SA"

echo "   🔑 Binding KMS CryptoKey Encrypter/Decrypter to Pod SA '${SA_EMAIL}'..."
gcloud kms keys add-iam-policy-binding "${KMS_CRYPTO_KEY}" \
    --keyring="${KMS_KEY_RING}" \
    --location="${REGION}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
    --project="${PROJECT_ID}" >/dev/null

echo "   🔑 Binding roles/container.defaultNodeServiceAccount to GKE Node SA '${GKE_NODE_SA_EMAIL}'..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${GKE_NODE_SA_EMAIL}" \
    --role="roles/container.defaultNodeServiceAccount" \
    --condition=None \
    --quiet >/dev/null

echo "   🔑 Binding roles/logging.logWriter to Cloud Build SA '${CLOUDBUILD_SA_EMAIL}'..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CLOUDBUILD_SA_EMAIL}" \
    --role="roles/logging.logWriter" \
    --condition=None \
    --quiet >/dev/null

# ==========================================
# 6. GCS DATA & BUILD STAGING BUCKETS (ISOLATED)
# ==========================================
echo "🪣 [5/9] Verifying Isolated Cloud Storage Buckets in ${REGION}..."

create_bucket_if_missing() {
    local bucket="$1"
    if gcloud storage buckets describe "gs://${bucket}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
        echo "   ✅ GCS Bucket 'gs://${bucket}' already exists."
    else
        echo "   🚀 Creating GCS Bucket 'gs://${bucket}' in ${REGION}..."
        gcloud storage buckets create "gs://${bucket}" \
            --location="${REGION}" \
            --uniform-bucket-level-access \
            --public-access-prevention \
            --project="${PROJECT_ID}"
        echo "   ✅ GCS Bucket 'gs://${bucket}' created."
    fi
}

create_bucket_if_missing "${BUCKET_NAME}"
create_bucket_if_missing "${BUILD_STAGING_BUCKET}"

echo "   🔑 Granting bucket-scoped roles/storage.objectAdmin on 'gs://${BUCKET_NAME}' ONLY to Pod SA '${SA_EMAIL}'..."
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectAdmin" \
    --project="${PROJECT_ID}" >/dev/null

echo "   🔑 Granting bucket-scoped roles/storage.admin on 'gs://${BUILD_STAGING_BUCKET}' ONLY to Cloud Build SA '${CLOUDBUILD_SA_EMAIL}' (includes storage.buckets.get required by Cloud Build)..."
gcloud storage buckets add-iam-policy-binding "gs://${BUILD_STAGING_BUCKET}" \
    --member="serviceAccount:${CLOUDBUILD_SA_EMAIL}" \
    --role="roles/storage.admin" \
    --project="${PROJECT_ID}" >/dev/null

# ==========================================
# 7. ARTIFACT REGISTRY & REPO-SCOPED IAM
# ==========================================
echo "📦 [6/9] Verifying Artifact Registry Repository '${AR_REPO}'..."
if gcloud artifacts repositories describe "${AR_REPO}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ Artifact Registry Repository '${AR_REPO}' already exists."
else
    echo "   🚀 Creating Artifact Registry Repository '${AR_REPO}' in ${REGION}..."
    gcloud artifacts repositories create "${AR_REPO}" \
        --repository-format=docker \
        --location="${REGION}" \
        --description="Docker repository for CSE Sidecar" \
        --project="${PROJECT_ID}"
    echo "   ✅ Artifact Registry Repository '${AR_REPO}' created."
fi

echo "   🔑 Granting repo-scoped roles/artifactregistry.writer on '${AR_REPO}' to Cloud Build SA '${CLOUDBUILD_SA_EMAIL}'..."
gcloud artifacts repositories add-iam-policy-binding "${AR_REPO}" \
    --location="${REGION}" \
    --member="serviceAccount:${CLOUDBUILD_SA_EMAIL}" \
    --role="roles/artifactregistry.writer" \
    --project="${PROJECT_ID}" >/dev/null

echo "   🔑 Granting repo-scoped roles/artifactregistry.reader on '${AR_REPO}' to GKE Node SA '${GKE_NODE_SA_EMAIL}'..."
gcloud artifacts repositories add-iam-policy-binding "${AR_REPO}" \
    --location="${REGION}" \
    --member="serviceAccount:${GKE_NODE_SA_EMAIL}" \
    --role="roles/artifactregistry.reader" \
    --project="${PROJECT_ID}" >/dev/null

# ==========================================
# 8. CONFIDENTIAL GKE CLUSTER & WORKLOAD IDENTITY
# ==========================================
echo "🌐 [7/9] Verifying Private Confidential GKE Cluster '${CLUSTER_NAME}' in ${ZONE}..."
if gcloud container clusters describe "${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    CLUSTER_STATUS=$(gcloud container clusters describe "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --format="value(status)")
    PRIVATE_NODES=$(gcloud container clusters describe "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --format="value(privateClusterConfig.enablePrivateNodes)")
    SECURE_BOOT=$(gcloud container clusters describe "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --format="value(nodePools[0].config.shieldedInstanceConfig.enableSecureBoot)")
    echo "   ℹ️  Confidential GKE Cluster '${CLUSTER_NAME}' exists (status: ${CLUSTER_STATUS}, privateNodes: ${PRIVATE_NODES:-False}, secureBoot: ${SECURE_BOOT:-False})."

    while [[ "${CLUSTER_STATUS}" == "PROVISIONING" || "${CLUSTER_STATUS}" == "RECONCILING" ]]; do
        echo "   ⏳ Cluster '${CLUSTER_NAME}' is currently ${CLUSTER_STATUS}. Waiting 15s for operation to settle..."
        sleep 15
        CLUSTER_STATUS=$(gcloud container clusters describe "${CLUSTER_NAME}" \
            --zone="${ZONE}" \
            --project="${PROJECT_ID}" \
            --format="value(status)")
    done

    if [[ "${PRIVATE_NODES}" != "True" || "${SECURE_BOOT}" != "True" || "${CLUSTER_STATUS}" == "ERROR" || "${CLUSTER_STATUS}" == "DEGRADED" || "${CLUSTER_STATUS}" == "STOPPING" ]]; then
        STATUS_MSG=$(gcloud container clusters describe "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" --format="value(statusMessage)")
        echo "   ⚠️  Cluster is unhealthy or missing Private Nodes / Secure Boot (status=${CLUSTER_STATUS}, privateNodes=${PRIVATE_NODES:-False}, secureBoot=${SECURE_BOOT:-False}, msg='${STATUS_MSG}')."
        echo "   🗑️  Deleting non-compliant cluster '${CLUSTER_NAME}' before recreating with Private Nodes & Secure Boot..."
        gcloud container clusters delete "${CLUSTER_NAME}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
        CLUSTER_STATUS="MISSING"
    fi
else
    CLUSTER_STATUS="MISSING"
fi

if [[ "${CLUSTER_STATUS}" == "MISSING" ]]; then
    echo "   🚀 Provisioning Private Confidential GKE Cluster '${CLUSTER_NAME}' with Node SA '${GKE_NODE_SA_EMAIL}' (~5 minutes)..."
    gcloud container clusters create "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --network="${VPC_NETWORK}" \
        --subnetwork="${VPC_SUBNET}" \
        --enable-ip-alias \
        --enable-private-nodes \
        --enable-dns-access \
        --master-ipv4-cidr="${MASTER_IPV4_CIDR:-172.16.0.0/28}" \
        --machine-type=n2d-standard-2 \
        --enable-confidential-nodes \
        --enable-shielded-nodes \
        --shielded-secure-boot \
        --shielded-integrity-monitoring \
        --service-account="${GKE_NODE_SA_EMAIL}" \
        --workload-pool="${PROJECT_ID}.svc.id.goog" \
        --num-nodes=3 \
        --project="${PROJECT_ID}"
    echo "   ✅ Private Confidential GKE Cluster '${CLUSTER_NAME}' provisioned."
else
    echo "   ✅ Private Confidential GKE Cluster '${CLUSTER_NAME}' is RUNNING."
    DNS_ACCESS=$(gcloud container clusters describe "${CLUSTER_NAME}" \
        --zone="${ZONE}" \
        --project="${PROJECT_ID}" \
        --format="value(controlPlaneEndpointsConfig.dnsEndpointConfig.enabled)")
    if [[ "${DNS_ACCESS}" != "True" ]]; then
        echo "   🌐 Enabling Control Plane DNS endpoint access on existing cluster '${CLUSTER_NAME}'..."
        gcloud container clusters update "${CLUSTER_NAME}" \
            --zone="${ZONE}" \
            --enable-dns-access \
            --project="${PROJECT_ID}"
        echo "   ✅ Control Plane DNS endpoint enabled."
    fi
fi

echo "   🔐 Fetching cluster DNS endpoint credentials for '${CLUSTER_NAME}'..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --zone="${ZONE}" \
    --dns-endpoint \
    --project="${PROJECT_ID}"

echo "   🔑 Configuring Workload Identity for Kubernetes SA '${K8S_NAMESPACE}/${K8S_SA}'..."
if kubectl get serviceaccount "${K8S_SA}" --namespace="${K8S_NAMESPACE}" >/dev/null 2>&1; then
    echo "   ✅ Kubernetes ServiceAccount '${K8S_SA}' already exists in namespace '${K8S_NAMESPACE}'."
else
    kubectl create serviceaccount "${K8S_SA}" --namespace="${K8S_NAMESPACE}"
    echo "   ✅ Kubernetes ServiceAccount '${K8S_SA}' created."
fi

gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA}]" \
    --project="${PROJECT_ID}" >/dev/null

kubectl annotate serviceaccount "${K8S_SA}" \
    --namespace="${K8S_NAMESPACE}" \
    "iam.gke.io/gcp-service-account=${SA_EMAIL}" \
    --overwrite

# ==========================================
# 9. GENERATE PROXY CODE, CLOUD BUILD & K8S ROLLOUT
# ==========================================
echo "🐳 [8/9] Generating CSE Tink Sidecar source and building image via Cloud Build ('${CLOUDBUILD_SA_EMAIL}')..."
BUILD_DIR="${SCRIPT_DIR}/cse-proxy-build"
mkdir -p "${BUILD_DIR}"

cat << 'EOF' > "${BUILD_DIR}/proxy_server.py"
import os
from fastapi import FastAPI, HTTPException, Request, Response
import tink
from tink import aead
from tink.integration import gcpkms
from google.cloud import storage

app = FastAPI()

KEY_URI = os.environ.get("KMS_KEY_URI")
if not KEY_URI:
    raise ValueError("KMS_KEY_URI environment variable is required.")

aead.register()
gcp_client = gcpkms.GcpKmsClient(KEY_URI, "")
gcp_aead = gcp_client.get_aead(KEY_URI)
key_template = aead.aead_key_templates.AES256_GCM
env_aead = aead.KmsEnvelopeAead(key_template, gcp_aead)

storage_client = storage.Client()

@app.post("/upload/{bucket_name}/{blob_name:path}")
async def upload_encrypted(bucket_name: str, blob_name: str, request: Request):
    try:
        plaintext_data = await request.body()
        if not plaintext_data:
            raise HTTPException(status_code=400, detail="Empty payload")

        ciphertext = env_aead.encrypt(plaintext_data, b"")
        bucket = storage_client.bucket(bucket_name)
        blob = bucket.blob(blob_name)
        blob.upload_from_string(ciphertext)

        return {"status": "success", "message": f"Encrypted and uploaded {blob_name} to {bucket_name}"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/download/{bucket_name}/{blob_name:path}")
async def download_decrypted(bucket_name: str, blob_name: str) -> Response:
    try:
        bucket = storage_client.bucket(bucket_name)
        blob = bucket.blob(blob_name)
        ciphertext = blob.download_as_bytes()
        plaintext = env_aead.decrypt(ciphertext, b"")
        return Response(content=plaintext, media_type="text/plain")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
EOF

cat << 'EOF' > "${BUILD_DIR}/Dockerfile"
FROM python:3.10-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn tink google-cloud-storage google-cloud-kms
COPY proxy_server.py /app/proxy_server.py
EXPOSE 8080
CMD ["uvicorn", "proxy_server:app", "--host", "127.0.0.1", "--port", "8080"]
EOF

gcloud builds submit "${BUILD_DIR}" \
    --region="${REGION}" \
    --tag="${IMAGE_NAME}" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${CLOUDBUILD_SA_EMAIL}" \
    --gcs-source-staging-dir="gs://${BUILD_STAGING_BUCKET}/source" \
    --gcs-log-dir="gs://${BUILD_STAGING_BUCKET}/logs" \
    --project="${PROJECT_ID}"

echo "🚀 [9/9] Applying Kubernetes Deployment '${DEPLOYMENT_NAME}'..."
cat << EOF > "${SCRIPT_DIR}/deployment.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${K8S_NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: secure-app
  template:
    metadata:
      labels:
        app: secure-app
    spec:
      serviceAccountName: ${K8S_SA}
      containers:
      - name: main-application
        image: ${MAIN_APP_IMAGE}
        env:
        - name: PROXY_ENDPOINT
          value: "http://127.0.0.1:8080"
      - name: cse-tink-sidecar
        image: ${IMAGE_NAME}
        imagePullPolicy: Always
        env:
        - name: KMS_KEY_URI
          value: "${KMS_KEY_URI}"
        ports:
        - containerPort: 8080
EOF

kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"
kubectl rollout restart "deployment/${DEPLOYMENT_NAME}" --namespace="${K8S_NAMESPACE}"

echo "=========================================="
echo "✅ Zero-Trust Cloud Shell CSE Deployment (v2) Complete!"
echo "   Run './test_cse_gke.sh' to execute the E2E validation suite."
echo "=========================================="
