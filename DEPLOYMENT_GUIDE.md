# Stage 1 Operational Deployment Guide: Confidential GKE Client-Side Encryption (CSE) Sidecar Proxy

## 1. Architecture Overview & Security Posture

Stage 1 implements **Client-Side Envelope Encryption (CSE)** for containerized workloads using **Google Kubernetes Engine (GKE) Confidential Nodes** and a **Localhost Loopback HTTP Cryptographic Sidecar Proxy** (`127.0.0.1:8080`). Plaintext data is encrypted inside AMD SEV hardware-encrypted memory before it ever traverses the network or reaches Google Cloud Storage (GCS).

```
+-----------------------------------------------------------------------------------+
| Confidential GKE Node (n2d-standard-2 | AMD SEV RAM Encryption | Shielded VM)     |
|                                                                                   |
|  +-----------------------------------------------------------------------------+  |
|  | Kubernetes Pod (Workload Identity: cse-k8s-sa -> cse-proxy-sa)              |  |
|  |                                                                             |  |
|  |  +------------------------+   Loopback HTTP    +-------------------------+  |  |
|  |  | Main Application       | (127.0.0.1:8080)   | CSE Tink Sidecar Proxy  |  |  |
|  |  | (Zero KMS/GCS Access)  | -----------------> | (FastAPI + Google Tink) |  |  |
|  |  +------------------------+   Plaintext I/O    +------------+------------+  |  |
|  +-------------------------------------------------------------|---------------+  |
+----------------------------------------------------------------|------------------+
                                                                 |
                      +------------------------------------------+------------------+
                      | Private Google Access / Cloud NAT                           |
                      v                                                             v
     +----------------------------------+                 +----------------------------------+
     | Cloud KMS (europe-west4)         |                 | Cloud Storage (europe-west4)     |
     | KeyRing: cse-keyring-mvp         |                 | Bucket: cse-prod-bucket-...      |
     | Key:     cse-proxy-key (KEK)     |                 | Stores ONLY Tink AES256_GCM      |
     | Wraps/Unwraps Ephemeral DEKs     |                 | Envelope Ciphertext              |
     +----------------------------------+                 +----------------------------------+
```

### Key Architectural Controls
1. **Hardware Memory Encryption (Confidential Computing):** GKE nodes run on `n2d-standard-2` instances with **AMD Secure Encrypted Virtualization (SEV)** and **Shielded GKE Nodes** (`Secure Boot`, `vTPM`, `Integrity Monitoring`), protecting in-use Data Encryption Keys (DEKs) and plaintext payloads in RAM.
2. **Envelope AEAD Cryptography (Google Tink):** The FastAPI sidecar uses Google Tink `KmsEnvelopeAead` (`AES256_GCM` DEK wrapped by a Cloud KMS KEK) with deterministic Associated Data (`bucket/object` URI binding) to prevent cross-object ciphertext substitution attacks.
3. **Zero-Trust Identity Separation (3 Dedicated Service Accounts):**
   - **Pod Workload Identity SA (`cse-proxy-sa`):** Bound strictly to `serviceAccount:${PROJECT_ID}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA}]`. Granted **key-scoped** `roles/cloudkms.cryptoKeyEncrypterDecrypter` on `cse-proxy-key` and **bucket-scoped** `roles/storage.objectAdmin` on the target ciphertext bucket.
   - **GKE Node Pool SA (`cse-gke-node-sa`):** Granted `roles/container.defaultNodeServiceAccount` and **repository-scoped** `roles/artifactregistry.reader`. Zero access to KMS keys or GCS data buckets.
   - **Cloud Build SA (`cse-build-sa`):** Granted `roles/logging.logWriter`, **bucket-scoped** `roles/storage.admin` on the build staging bucket, and **repository-scoped** `roles/artifactregistry.writer`.
4. **Private Network Topology:** Private GKE nodes (`--enable-private-nodes`, `--enable-dns-access`) operate without public IP addresses inside a custom VPC subnet with **Private Google Access (PGA)** and **Cloud NAT**, satisfying `constraints/compute.vmExternalIpAccess`.

---

## 2. Prerequisites

Before executing the Stage 1 lifecycle scripts, ensure the following requirements are met:

- **Google Cloud Platform Project:** An active GCP project with billing enabled (e.g., `your-project-id`).
- **Command-Line Tooling (Google Cloud Shell Recommended):**
  - `gcloud` SDK installed and authenticated (`gcloud auth login`).
  - `kubectl` and `gke-gcloud-auth-plugin` installed (pre-installed in Google Cloud Shell).
- **Administrative Bootstrap Permissions:**
  - A Project or Organization IAM Administrator account is required solely to run Step 1 (`./grant_deployer_iam.sh`) and Step 4 (`./revoke_deployer_iam.sh`).
  - All deployment and verification operations (Steps 2, 3, and 5) can be executed by the least-privilege `DEPLOYER_PRINCIPAL` (no `roles/owner` or `roles/editor` required).

---

## 3. Configuration Phase (`cse_config.env.example` -> `cse_config.env`)

All Stage 1 scripts source their environment variables from `v2/cse_config.env`.

### 3.1 Copy the Configuration Template

Before running any script, copy the sanitized template `cse_config.env.example` to `cse_config.env`:

```bash
cp cse_config.env.example cse_config.env && chmod +x *.sh *.env
```

### 3.2 Customize Environment Variables

Open `cse_config.env` and update the placeholders (`your-project-id`, `user@example.com`) to match your target GCP environment:

| Variable | Template Default | Description |
| :--- | :--- | :--- |
| `PROJECT_ID` | `your-project-id` | Target Google Cloud Project ID. **Modify this first** for your target environment. |
| `REGION` | `europe-west4` | Target GCP region (enforces EU data residency for GCS, KMS, and Artifact Registry). |
| `ZONE` | `europe-west4-a` | Target GCP compute zone for the Confidential GKE cluster. |
| `DEPLOYER_PRINCIPAL` | `user:user@example.com` | IAM member (`user:...` or `serviceAccount:...`) granted temporary deployment permissions. |
| `VPC_NETWORK` | `test` | Custom-mode VPC network name (created automatically if absent). |
| `VPC_SUBNET` | `nl` | Regional VPC subnet name with Private Google Access enabled. |
| `VPC_SUBNET_CIDR` | `10.0.0.0/24` | Primary IPv4 CIDR range for `VPC_SUBNET`. |
| `MASTER_IPV4_CIDR` | `172.16.0.0/28` | `/28` CIDR block reserved for the GKE private control plane. |
| `SA_NAME` | `cse-proxy-sa` | Dedicated Workload Identity Service Account for the CSE sidecar pod. |
| `GKE_NODE_SA_NAME` | `cse-gke-node-sa` | Dedicated least-privilege Service Account for Confidential GKE nodes. |
| `CLOUDBUILD_SA_NAME` | `cse-build-sa` | Dedicated least-privilege Service Account for Cloud Build image builds. |
| `KMS_KEY_RING` | `cse-keyring-mvp` | Cloud KMS KeyRing name in `REGION` (preserved across teardowns). |
| `KMS_CRYPTO_KEY` | `cse-proxy-key` | Cloud KMS symmetric encryption key (KEK) name (preserved across teardowns). |
| `BUCKET_NAME` | `cse-prod-bucket-${PROJECT_ID}-2993` | Globally unique GCS bucket name storing envelope-encrypted ciphertext objects. |
| `BUILD_STAGING_BUCKET` | `${PROJECT_ID}-cse-build-staging` | GCS staging bucket used exclusively by Cloud Build to upload container build sources. |
| `CLUSTER_NAME` | `cse-confidential-cluster` | Confidential GKE cluster name (`n2d-standard-2`, AMD SEV). |
| `AR_REPO` | `cse-repo` | Regional Artifact Registry Docker repository name. |

---

## 4. Step-by-Step Execution Lifecycle

Execute the following steps from the `v2/` directory.

### Step 1: Grant Least-Privilege Deployment IAM Roles

Run `./grant_deployer_iam.sh` as a Project/Organization IAM Administrator to grant the `DEPLOYER_PRINCIPAL` the exact set of roles required to provision Stage 1 infrastructure (`serviceUsageAdmin`, `networkAdmin`, `cloudkms.admin`, `serviceAccountAdmin`, `serviceAccountUser`, `projectIamAdmin`, `storage.admin`, `artifactregistry.admin`, `container.admin`, `cloudbuild.builds.editor`, `logging.viewer`).

```bash
./grant_deployer_iam.sh
```

*(Optional CLI override for a specific project and principal)*:

```bash
./grant_deployer_iam.sh "your-project-id" "user:user@example.com"
```

---

### Step 2: Deploy Stage 1 Infrastructure & Sidecar Proxy

Run the deployment script to enable APIs, verify/create the VPC/Subnet/Cloud NAT, provision the 3 dedicated Service Accounts, create the Cloud KMS KeyRing/Key and GCS buckets, build the `cse-sidecar` container image via Cloud Build, provision the Confidential GKE cluster (`cse-confidential-cluster`), and deploy the 2-replica `secure-app-deployment`.

```bash
./deploy_cse_gke.sh
```

> **Note:** If your automation wrapper references `./deploy_cse_env.sh`, invoke `./deploy_cse_gke.sh` directly.

---

### Step 3: Execute the 4-Step Cross-Pod Zero-Plaintext Verification Suite

Run the automated verification suite to prove end-to-end stateless envelope encryption across two distinct Confidential GKE pods:
1. **Step 1 (Readiness & Cross-Pod Selection):** Selects two distinct running pods (`POD_A` for encryption, `POD_B` for decryption).
2. **Step 2 (Ingress Encryption via `POD_A`):** Sends plaintext payload `CONFIDENTIAL_GKE_TEST_PAYLOAD` from `main-application` to `http://127.0.0.1:8080/upload/...` inside `POD_A`.
3. **Step 3 (Out-of-Band GCS Ciphertext Assertion):** Downloads the raw object directly from GCS (`gcloud storage cat`) outside the cluster and asserts that the file is non-empty binary Tink ciphertext containing zero plaintext substrings.
4. **Step 4 (Stateless Egress Decryption via `POD_B`):** Requests `http://127.0.0.1:8080/download/...` from `POD_B` (proving no local pod state dependency) and verifies exact plaintext recovery.

```bash
./test_cse_gke.sh
```

> **Note:** If your automation wrapper references `./test_cse_env.sh`, invoke `./test_cse_gke.sh` directly. For application SDK integration details (Python, Go, Node.js), refer to [`DEVELOPER_GUIDE.md`](./DEVELOPER_GUIDE.md).

---

### Step 4: Revoke Elevated Deployment IAM Roles (Post-Deployment Hardening)

Immediately after deployment and verification are complete, strip the `DEPLOYER_PRINCIPAL` of all elevated provisioning roles (`roles/container.admin`, `roles/compute.networkAdmin`, `roles/cloudkms.admin`, etc.) to enforce **Zero Standing Privileges (ZSP)**. Workload runtime operations remain unaffected because the GKE pods authenticate independently via Workload Identity (`cse-proxy-sa`).

```bash
./revoke_deployer_iam.sh
```

*(Optional CLI override for a specific project and principal)*:

```bash
./revoke_deployer_iam.sh "your-project-id" "user:user@example.com"
```

---

### Step 5: FinOps Environment Teardown

When de-provisioning the Stage 1 environment, run `./cleanup_cse_env.sh`. Note that if you revoked deployer IAM roles in Step 4, you must re-grant them via `./grant_deployer_iam.sh` (or run as an administrator) before executing teardown.

- **Destroyed:** Confidential GKE cluster (`cse-confidential-cluster`), Artifact Registry repository (`cse-repo`), Workload Identity binding on `cse-proxy-sa`, and ephemeral Node/Build Service Accounts (`cse-gke-node-sa`, `cse-build-sa`).
- **Preserved (Data Loss Prevention):** Cloud KMS KeyRing/CryptoKey (`cse-keyring-mvp/cse-proxy-key`), Pod Service Account (`cse-proxy-sa`), and GCS buckets (`gs://cse-prod-bucket-...`).

```bash
./cleanup_cse_env.sh
```
