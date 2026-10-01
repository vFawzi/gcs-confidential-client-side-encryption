# CI/CD Integration: Client-Side Encryption for Automated Pipelines

## 1. Architecture: Why Ephemeral CI/CD Pipelines Use STET Instead of FUSE

While persistent compute workloads on Google Cloud use either the **Stage 1 HTTP Sidecar Proxy** (Confidential GKE) or the **Stage 2 Transparent OS-Level FUSE Agent** (`gocryptfs` + `gcsfuse` on Confidential VMs), **ephemeral CI/CD runners** (such as **Google Cloud Build**, **GitHub Actions**, and **GitLab CI**) have a fundamentally different execution model.

### Why Mounting FUSE in CI/CD is an Anti-Pattern
Attempting to mount OS-level FUSE filesystems (`gcsfuse` + `gocryptfs`) inside automated CI/CD steps is an architectural and security anti-pattern:
1. **Container Privilege Escalation Risk:** Mounting FUSE inside containerized CI/CD steps requires elevated Linux capabilities (`CAP_SYS_ADMIN`) and host device passthrough (`/dev/fuse`), violating least-privilege container isolation in shared or ephemeral runners.
2. **Ephemeral Lifecycle & Teardown Race Conditions:** CI/CD build steps are short-lived and stateless. Background FUSE daemons risk premature container termination before asynchronous kernel page-cache flushes (`fsync`) complete, leading to truncated or corrupted artifacts in Google Cloud Storage (GCS).
3. **Batch Artifact Workload Profile:** CI/CD pipelines do not perform random POSIX file I/O; they produce discrete, immutable build artifacts (compiled binaries, container tarballs, ML model weights, SBOMs, and compliance logs) that are encrypted once and streamed directly to object storage.

### The Recommended Pattern: Split-Trust Encryption Tool (STET)
For automated pipelines, use Google's open-source **Split-Trust Encryption Tool (`stet`)** CLI. `stet` performs **Client-Side Envelope Encryption** (`AES-256-GCM` Data Encryption Key generated in runner memory and wrapped via Google Cloud KMS) in a single, unprivileged user-space command—streaming ciphertext directly into `gsutil` or `gcloud storage` without writing intermediate ciphertext files or mounting FUSE filesystems.

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

## 2. IAM Requirements (Least Privilege)

Following the **Principle of Least Privilege**, the dedicated CI/CD Service Account (e.g., `cse-cicd-sa@${PROJECT_ID}.iam.gserviceaccount.com` authenticated via **Workload Identity Federation** or attached to a private **Google Cloud Build** worker pool) requires only two resource-scoped IAM roles:

| IAM Role | Scope Boundary | Purpose |
| :--- | :--- | :--- |
| **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** | **CryptoKey-Scoped:** `projects/${PROJECT_ID}/locations/europe-west4/keyRings/cse-keyring-mvp/cryptoKeys/cse-proxy-key` | Allows the CI/CD runner to wrap (encrypt) ephemeral DEKs during artifact upload and unwrap (decrypt) DEKs when pulling encrypted dependencies. |
| **`roles/storage.objectAdmin`** | **Bucket-Scoped:** `gs://${BUCKET_NAME}` | Allows the CI/CD runner to stream encrypted build artifacts (`*.enc`) to and from the target regional GCS bucket. |

### Granting Scoped IAM Bindings (Single-Line Commands)

Execute the following single-line commands to bind the required permissions to your CI/CD Service Account without granting broad project-wide roles:

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

Below is a portable CI/CD pipeline configuration (shown for **Google Cloud Build** and easily adaptable to **GitHub Actions** / **GitLab CI**) that downloads the `stet` binary, generates `kms-config.yaml`, encrypts `build_artifact.zip` in memory, and pipes the ciphertext directly to Google Cloud Storage:

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

To encrypt `build_artifact.zip` on the fly and stream the resulting ciphertext directly to Google Cloud Storage inside any CI/CD shell runner:

```bash
./stet encrypt --config=kms-config.yaml --input=build_artifact.zip | gsutil cp - gs://$BUCKET_NAME/build_artifact.enc
```

To download and decrypt `build_artifact.enc` in a downstream deployment pipeline stage:

```bash
gsutil cp gs://$BUCKET_NAME/build_artifact.enc - | ./stet decrypt --config=kms-config.yaml --input=- --output=build_artifact.zip
```
