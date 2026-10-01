# CI/CD Integration: Client-Side Encryption for Automated Pipelines

## 1. Ephemeral Artifact Encryption: Why Pipelines Use STET Instead of FUSE

While persistent compute workloads on Google Cloud use either the **Stage 1 HTTP Sidecar Proxy** (Confidential GKE) or the **Stage 2 Transparent OS-Level FUSE Agent** (`gocryptfs` + `gcsfuse` on Confidential VMs), **ephemeral CI/CD runners** (such as **Google Cloud Build**, **GitHub Actions**, and **GitLab CI**) have a fundamentally different execution model when encrypting build artifacts directly inside the runner.

### Why Mounting FUSE in CI/CD Runners is an Anti-Pattern
Attempting to mount OS-level FUSE filesystems (`gcsfuse` + `gocryptfs`) inside automated CI/CD containers is an architectural and security anti-pattern:
1. **Container Privilege Escalation Risk:** Mounting FUSE inside containerized CI/CD steps requires elevated Linux capabilities (`CAP_SYS_ADMIN`) and host device passthrough (`/dev/fuse`), violating least-privilege container isolation in shared or ephemeral runners.
2. **Ephemeral Lifecycle & Teardown Race Conditions:** CI/CD build steps are short-lived and stateless. Background FUSE daemons risk premature container termination before asynchronous kernel page-cache flushes (`fsync`) complete, leading to truncated or corrupted artifacts in Google Cloud Storage (GCS).
3. **Batch Artifact Workload Profile:** CI/CD pipelines do not perform random POSIX file I/O; they produce discrete, immutable build artifacts (compiled binaries, container tarballs, ML model weights, SBOMs, and compliance logs) that are encrypted once and streamed directly to object storage.

### The Recommended Pattern for Build Artifacts: Split-Trust Encryption Tool (STET)
For encrypting build outputs inside automated pipelines, use Google's open-source **Split-Trust Encryption Tool (`stet`)** CLI. `stet` performs **Client-Side Envelope Encryption** (`AES-256-GCM` Data Encryption Key generated in runner memory and wrapped via Google Cloud KMS) in a single, unprivileged user-space command—streaming ciphertext directly into `gsutil` or `gcloud storage` without writing intermediate ciphertext files or mounting FUSE filesystems.

```
+---------------------------------------------------------------------------------------+
| Ephemeral CI/CD Runner (Google Cloud Build / GitHub Actions via Workload Identity)    |
| Identity: Dedicated CI/CD Service Account (Zero JSON Keys, Short-Lived OIDC Token)    |
|                                                                                       |
|  +-----------------------+     +---------------------------------------------------+  |
|  | build_artifact.zip    | --> | ./stet encrypt --config=kms-config.yaml           |  |
|  | (Plaintext Artifact)  |     | - Generates ephemeral 256-bit AES-GCM DEK in RAM  |  |
|  +-----------------------+     | - Wraps DEK via Cloud KMS (cse-proxy-key)         |  |
|                                +-------------------------+-------------------------+  |
|                                                          | Standard Output (stdout)   |
|                                                          | Streamed Ciphertext Pipe   |
|                                                          v                            |
|                                +---------------------------------------------------+  |
|                                | gsutil cp - gs://$BUCKET_NAME/build_artifact.enc  |  |
|                                +-------------------------+-------------------------+  |
+----------------------------------------------------------|----------------------------+
                                                           | HTTPS (TLS 1.3)
                                                           v
                           +------------------------------------------------------------+
                           | Google Cloud Storage (europe-west4)                        |
                           | Stores Authenticated STET Envelope Ciphertext (.enc)       |
                           +------------------------------------------------------------+
```

---

## 2. IAM Requirements for STET Artifact Encryption

Following the **Principle of Least Privilege**, a CI/CD Service Account encrypting build artifacts via `stet` requires only two resource-scoped IAM roles:

| IAM Role | Scope Boundary | Purpose |
| :--- | :--- | :--- |
| **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** | **CryptoKey-Scoped:** `projects/${PROJECT_ID}/locations/europe-west4/keyRings/cse-keyring-mvp/cryptoKeys/cse-proxy-key` | Allows the CI/CD runner to wrap (encrypt) ephemeral DEKs during artifact upload and unwrap (decrypt) DEKs when pulling encrypted dependencies. |
| **`roles/storage.objectAdmin`** | **Bucket-Scoped:** `gs://${BUCKET_NAME}` | Allows the CI/CD runner to stream encrypted build artifacts (`*.enc`) to and from the target regional GCS bucket. |

### Granting Scoped IAM Bindings (Single-Line Commands)

```bash
gcloud kms keys add-iam-policy-binding cse-proxy-key --keyring="cse-keyring-mvp" --location="europe-west4" --project="${PROJECT_ID}" --member="serviceAccount:cse-cicd-sa@${PROJECT_ID}.iam.gserviceaccount.com" --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"
```

```bash
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" --project="${PROJECT_ID}" --member="serviceAccount:cse-cicd-sa@${PROJECT_ID}.iam.gserviceaccount.com" --role="roles/storage.objectAdmin"
```

---

## 3. Pipeline Integration: STET Configuration & YAML Sample

### 3.1 STET KMS Configuration (`kms-config.yaml`)

`stet` uses a declarative YAML configuration file (`kms-config.yaml`) to specify the Cloud KMS key URI (`gcp-kms://...`) used to wrap the ephemeral Data Encryption Key:

```yaml
encrypt_config:
  kek_infos:
    - kek_uri: "gcp-kms://projects/your-project-id/locations/europe-west4/keyRings/cse-keyring-mvp/cryptoKeys/cse-proxy-key"
  threshold: 1
decrypt_config:
  kek_infos:
    - kek_uri: "gcp-kms://projects/your-project-id/locations/europe-west4/keyRings/cse-keyring-mvp/cryptoKeys/cse-proxy-key"
```

### 3.2 Generic CI/CD Pipeline Step (YAML)

```yaml
# cloudbuild.yaml — Ephemeral CI/CD Client-Side Encryption via STET
steps:
  - name: "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
    id: "cse-encrypt-and-upload-artifact"
    entrypoint: "bash"
    env:
      - "PROJECT_ID=your-project-id"
      - "REGION=europe-west4"
      - "KMS_KEY_RING=cse-keyring-mvp"
      - "KMS_CRYPTO_KEY=cse-proxy-key"
      - "BUCKET_NAME=cse-prod-bucket-your-project-id-2993"
      - "STET_VERSION=v0.4.0"
    script: |
      set -euo pipefail

      # 1. Download the official Split-Trust Encryption Tool (stet) binary
      curl -fsSL -o ./stet "https://github.com/GoogleCloudPlatform/stet/releases/download/${STET_VERSION}/stet_linux_amd64"
      chmod +x ./stet

      # 2. Generate the KMS Envelope Encryption configuration
      cat <<EOF > kms-config.yaml
      encrypt_config:
        kek_infos:
          - kek_uri: "gcp-kms://projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KMS_KEY_RING}/cryptoKeys/${KMS_CRYPTO_KEY}"
        threshold: 1
      decrypt_config:
        kek_infos:
          - kek_uri: "gcp-kms://projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KMS_KEY_RING}/cryptoKeys/${KMS_CRYPTO_KEY}"
      EOF

      # 3. Stream-encrypt the build artifact via STET and pipe directly to GCS (Zero local ciphertext disk writes)
      ./stet encrypt --config=kms-config.yaml --input=build_artifact.zip | gsutil cp - gs://$BUCKET_NAME/build_artifact.enc

serviceAccount: "projects/your-project-id/serviceAccounts/cse-cicd-sa@your-project-id.iam.gserviceaccount.com"
options:
  logging: CLOUD_LOGGING_ONLY
```

### 3.3 Core One-Line Command Reference

To encrypt `build_artifact.zip` on the fly and stream the resulting ciphertext directly to Google Cloud Storage:

```bash
./stet encrypt --config=kms-config.yaml --input=build_artifact.zip | gsutil cp - gs://$BUCKET_NAME/build_artifact.enc
```

---

## 4. Automated Stage 2 E2E Validation via GitHub Actions & Workload Identity Federation (WIF)

In addition to encrypting build artifacts with `stet`, this repository includes a continuous verification workflow (**[`.github/workflows/stage2-ci.yml`](../.github/workflows/stage2-ci.yml)**) that automatically provisions the **Stage 2 Confidential VM (`n2d-standard-2` AMD SEV)**, executes the **4-Stage Zero-Plaintext Verification Protocol**, and tears down all ephemeral infrastructure on every push to `main` (or manual `workflow_dispatch`).

### 4.1 Keyless Authentication Architecture (Workload Identity Federation)

To eliminate long-lived Google Cloud Service Account JSON keys, the GitHub Actions pipeline authenticates using **Google Cloud Workload Identity Federation (WIF)** over OpenID Connect (OIDC):

```
+---------------------------------------------------------------------------------------+
| GitHub Actions Runner (.github/workflows/stage2-ci.yml)                               |
| Permissions: id-token: write, contents: read                                          |
|                                                                                       |
|  1. Requests OIDC JWT from https://token.actions.githubusercontent.com                |
|     (Claims: sub="repo:vFawzi/gcs-confidential-client-side-encryption:...",           |
|              repository="vFawzi/gcs-confidential-client-side-encryption")             |
+-------------------------------------------+-------------------------------------------+
                                            | OIDC JWT Assertion (HTTPS TLS 1.3)
                                            v
+---------------------------------------------------------------------------------------+
| Google Cloud Security Token Service (STS) & Workload Identity Pool                    |
| Pool     : github-actions-pool (global)                                               |
| Provider : github-oidc-provider (Issuer: https://token.actions.githubusercontent.com) |
| Mapping  : google.subject=assertion.sub, attribute.repository=assertion.repository    |
| Condition: assertion.repository == '${GITHUB_REPO}'                                   |
+-------------------------------------------+-------------------------------------------+
                                            | Impersonates via roles/iam.workloadIdentityUser
                                            v
+---------------------------------------------------------------------------------------+
| Dedicated CI/CD Service Account: cse-github-ci-sa@${PROJECT_ID}.iam.gserviceaccount.com|
| Executes:                                                                             |
|  - ./deploy_cse_vm.sh  (Provisions Confidential VM + gocryptfs/gcsfuse overlay)       |
|  - ./test_cse_vm.sh    (Runs 4-Stage Zero-Plaintext Verification Protocol)            |
|  - ./cleanup_stage2.sh (Always runs via `if: always()` to prevent orphaned VM spend)  |
+---------------------------------------------------------------------------------------+
```

### 4.2 Step 1: Run the One-Time WIF Bootstrap Script (`setup_github_wif.sh`)

> **IMPORTANT:** You **must** run [`stage2/setup_github_wif.sh`](../stage2/setup_github_wif.sh) **once** as a Project or Organization IAM Administrator before triggering the GitHub Actions pipeline.

1. Ensure `stage2/stage2_config.env` exists and defines your target `PROJECT_ID` (e.g., `cloud-cse-002`) and `GITHUB_REPO` (e.g., `vFawzi/gcs-confidential-client-side-encryption`):
   ```bash
   cd stage2 && cp stage2_config.env.example stage2_config.env && chmod +x *.sh *.env
   ```
2. Edit `stage2/stage2_config.env` to set `PROJECT_ID="cloud-cse-002"` and `GITHUB_REPO="vFawzi/gcs-confidential-client-side-encryption"`.
3. Execute the WIF bootstrap script from the `stage2/` directory:
   ```bash
   ./setup_github_wif.sh
   ```

What `setup_github_wif.sh` provisions automatically:
- Creates the dedicated CI/CD Service Account (`cse-github-ci-sa@${PROJECT_ID}.iam.gserviceaccount.com`) and grants it the exact Stage 2 deployment roles defined in [`grant_stage2_iam.sh`](../stage2/grant_stage2_iam.sh).
- Creates the Workload Identity Pool (`github-actions-pool`) and OIDC Provider (`github-oidc-provider`) for `https://token.actions.githubusercontent.com` with attribute mapping `google.subject=assertion.sub,attribute.repository=assertion.repository`.
- Binds `roles/iam.workloadIdentityUser` on `cse-github-ci-sa` strictly to `principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/${GITHUB_REPO}`.
- Outputs the exact `WIF_PROVIDER` and `CI_SA_EMAIL` strings required for GitHub Repository Secrets.

### 4.3 Step 2: Configure GitHub Repository Secrets in the GitHub UI

After running `./setup_github_wif.sh`, copy the two output values printed in your terminal and add them to your GitHub repository:

1. Open your GitHub repository in a browser (`https://github.com/<owner>/gcs-confidential-client-side-encryption`).
2. Navigate to **Settings** $\rightarrow$ **Secrets and variables** $\rightarrow$ **Actions** in the left sidebar.
3. Click **New repository secret** and add the following two secrets:

| Secret Name | Value Format (Copy from `./setup_github_wif.sh` Output) | Example Value (`cloud-cse-002`) |
| :--- | :--- | :--- |
| **`WIF_PROVIDER`** | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-actions-pool/providers/github-oidc-provider` | `projects/123456789012/locations/global/workloadIdentityPools/github-actions-pool/providers/github-oidc-provider` |
| **`CI_SA_EMAIL`** | `cse-github-ci-sa@<PROJECT_ID>.iam.gserviceaccount.com` | `cse-github-ci-sa@cloud-cse-002.iam.gserviceaccount.com` |

### 4.4 Step 3: Triggering & Monitoring the Pipeline

Once the `WIF_PROVIDER` and `CI_SA_EMAIL` secrets are saved in GitHub:
- **Automatic Trigger:** Any `git push origin main` will automatically trigger the **`Stage 2 Confidential VM CSE E2E Validation`** workflow.
- **Manual Trigger:** In the GitHub UI, navigate to **Actions** $\rightarrow$ **Stage 2 Confidential VM CSE E2E Validation** $\rightarrow$ **Run workflow** (`workflow_dispatch`).
- **FinOps Guarantee (`if: always()`):** The final step (`Teardown Stage 2 Infrastructure`) is configured with `if: always()`, guaranteeing that `./cleanup_stage2.sh` destroys the Confidential VM, IAP firewall rule, Stage 2 GCS bucket, and `cse-vm-sa` Service Account even if an earlier deployment or test assertion fails.
