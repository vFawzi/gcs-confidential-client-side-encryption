#!/bin/bash
# v2/stage2/setup_github_wif.sh - Bootstrap Keyless Workload Identity Federation (WIF) for Stage 2 GitHub Actions CI/CD
# Run once as a Project / Organization IAM Administrator before triggering the GitHub Actions workflow.

set -euo pipefail

# ==========================================
# 1. SOURCE STAGE 2 CONFIGURATION
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/stage2_config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "❌ ERROR: Configuration file not found at ${CONFIG_FILE}" >&2
    echo "   Copy 'stage2_config.env.example' to 'stage2_config.env' and configure PROJECT_ID and GITHUB_REPO first." >&2
    exit 1
fi

# shellcheck source=stage2_config.env
source "${CONFIG_FILE}"

PROJECT_ID="${1:-${PROJECT_ID:-}}"
GITHUB_REPO="${2:-${GITHUB_REPO:-}}"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "your-project-id" ]]; then
    echo "❌ ERROR: PROJECT_ID must be set to a valid GCP project ID (e.g., cloud-cse-002) in ${CONFIG_FILE}." >&2
    exit 1
fi

if [[ -z "${GITHUB_REPO}" || "${GITHUB_REPO}" == "username/gcs-confidential-client-side-encryption" ]]; then
    echo "❌ ERROR: GITHUB_REPO must be set in ${CONFIG_FILE} (e.g., vFawzi/gcs-confidential-client-side-encryption)." >&2
    exit 1
fi

CI_SA_NAME="${CI_SA_NAME:-cse-github-ci-sa}"
CI_SA_EMAIL="${CI_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
WIF_POOL_NAME="${WIF_POOL_NAME:-github-actions-pool}"
WIF_PROVIDER_NAME="${WIF_PROVIDER_NAME:-github-oidc-provider}"
OIDC_ISSUER_URI="https://token.actions.githubusercontent.com"

echo "=========================================="
echo "🔐 Bootstrapping GitHub Actions Workload Identity Federation (WIF)"
echo "   Project        : ${PROJECT_ID}"
echo "   GitHub Repo    : ${GITHUB_REPO}"
echo "   CI/CD SA       : ${CI_SA_EMAIL}"
echo "   WIF Pool       : ${WIF_POOL_NAME}"
echo "   OIDC Provider  : ${WIF_PROVIDER_NAME}"
echo "=========================================="

gcloud config set project "${PROJECT_ID}" >/dev/null

# ==========================================
# 2. ENABLE REQUIRED IAM & STS APIS
# ==========================================
echo "📦 [1/5] Enabling IAM, Security Token Service (STS), and Resource Manager APIs..."
gcloud services enable \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    sts.googleapis.com \
    cloudresourcemanager.googleapis.com \
    serviceusage.googleapis.com \
    --project="${PROJECT_ID}"

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
echo "   ℹ️  Resolved Project Number: ${PROJECT_NUMBER}"

# ==========================================
# 3. CREATE CI/CD SERVICE ACCOUNT & GRANT STAGE 2 DEPLOYMENT ROLES
# ==========================================
echo "👤 [2/5] Creating/Verifying Dedicated CI/CD Service Account '${CI_SA_EMAIL}'..."
if gcloud iam service-accounts describe "${CI_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ Service Account '${CI_SA_EMAIL}' already exists."
else
    gcloud iam service-accounts create "${CI_SA_NAME}" \
        --display-name="Stage 2 GitHub Actions CI/CD Service Account" \
        --project="${PROJECT_ID}"
    echo "   ✅ Service Account '${CI_SA_EMAIL}' created."
fi

# Exact least-privilege deployment roles matching v2/stage2/grant_stage2_iam.sh
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

echo "🔑 [3/5] Granting Stage 2 Deployment IAM Roles to '${CI_SA_EMAIL}'..."
for ROLE in "${ROLES[@]}"; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${CI_SA_EMAIL}" \
        --role="${ROLE}" \
        --condition=None \
        --quiet >/dev/null
    echo "   ✅ Granted ${ROLE} to serviceAccount:${CI_SA_EMAIL}"
done

# ==========================================
# 4. CREATE WORKLOAD IDENTITY POOL & GITHUB OIDC PROVIDER
# ==========================================
echo "🌐 [4/5] Configuring Workload Identity Pool '${WIF_POOL_NAME}' and OIDC Provider '${WIF_PROVIDER_NAME}'..."
if gcloud iam workload-identity-pools describe "${WIF_POOL_NAME}" \
    --location="global" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ✅ Workload Identity Pool '${WIF_POOL_NAME}' already exists."
else
    gcloud iam workload-identity-pools create "${WIF_POOL_NAME}" \
        --location="global" \
        --display-name="GitHub Actions WIF Pool" \
        --description="Keyless Workload Identity Federation Pool for Stage 2 CI/CD" \
        --project="${PROJECT_ID}"
    echo "   ✅ Workload Identity Pool '${WIF_POOL_NAME}' created."
fi

if gcloud iam workload-identity-pools providers describe "${WIF_PROVIDER_NAME}" \
    --workload-identity-pool="${WIF_POOL_NAME}" \
    --location="global" \
    --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "   ℹ️  OIDC Provider '${WIF_PROVIDER_NAME}' already exists. Updating attribute mapping and condition..."
    gcloud iam workload-identity-pools providers update-oidc "${WIF_PROVIDER_NAME}" \
        --workload-identity-pool="${WIF_POOL_NAME}" \
        --location="global" \
        --issuer-uri="${OIDC_ISSUER_URI}" \
        --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
        --attribute-condition="assertion.repository == '${GITHUB_REPO}'" \
        --project="${PROJECT_ID}" >/dev/null
    echo "   ✅ OIDC Provider '${WIF_PROVIDER_NAME}' updated."
else
    gcloud iam workload-identity-pools providers create-oidc "${WIF_PROVIDER_NAME}" \
        --workload-identity-pool="${WIF_POOL_NAME}" \
        --location="global" \
        --display-name="GitHub Actions OIDC Provider" \
        --issuer-uri="${OIDC_ISSUER_URI}" \
        --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
        --attribute-condition="assertion.repository == '${GITHUB_REPO}'" \
        --project="${PROJECT_ID}"
    echo "   ✅ OIDC Provider '${WIF_PROVIDER_NAME}' created."
fi

# ==========================================
# 5. BIND WORKLOAD IDENTITY USER TO REPOSITORY PRINCIPALSETS
# ==========================================
PRINCIPAL_SET="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_NAME}/attribute.repository/${GITHUB_REPO}"
WIF_PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_NAME}/providers/${WIF_PROVIDER_NAME}"

echo "🔗 [5/5] Binding roles/iam.workloadIdentityUser on '${CI_SA_EMAIL}' to '${PRINCIPAL_SET}'..."
for WIF_BIND_ATTEMPT in {1..6}; do
    if gcloud iam service-accounts add-iam-policy-binding "${CI_SA_EMAIL}" \
        --project="${PROJECT_ID}" \
        --role="roles/iam.workloadIdentityUser" \
        --member="${PRINCIPAL_SET}" >/dev/null 2>&1; then
        echo "   ✅ Bound roles/iam.workloadIdentityUser on '${CI_SA_EMAIL}'."
        break
    fi
    if [[ "${WIF_BIND_ATTEMPT}" -eq 6 ]]; then
        echo "❌ ERROR: Failed to bind roles/iam.workloadIdentityUser on '${CI_SA_EMAIL}' after 6 attempts." >&2
        exit 1
    fi
    echo "   ⏳ Waiting for Service Account '${CI_SA_EMAIL}' IAM propagation (attempt ${WIF_BIND_ATTEMPT}/6)..."
    sleep 5
done

echo "=========================================="
echo "🎉 Workload Identity Federation (WIF) Setup Complete!"
echo "=========================================="
echo "Add the following two Repository Secrets in GitHub (Settings -> Secrets and variables -> Actions):"
echo ""
echo "  1. WIF_PROVIDER : ${WIF_PROVIDER_RESOURCE}"
echo "  2. CI_SA_EMAIL  : ${CI_SA_EMAIL}"
echo "=========================================="
