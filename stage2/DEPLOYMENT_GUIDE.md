# Stage 2 Operational Deployment Guide: Confidential VM Transparent OS-Level Agent CSE (`gcsfuse` + `gocryptfs`)

## 1. Architecture Overview & Security Posture

Stage 2 implements **Transparent OS-Level Client-Side Encryption (CSE)** for legacy POSIX applications that write directly to local filesystem paths and cannot be refactored to call HTTP proxies or cloud SDKs. It runs on an **AMD SEV Confidential VM** (`n2d-standard-2`) and stacks a **`gocryptfs` cryptographic FUSE overlay** (`AES-256-GCM` content encryption + `EME` filename encryption) on top of a **`gcsfuse` Cloud Storage mount**.

```
+---------------------------------------------------------------------------------------+
| Confidential VM: cse-confidential-vm (n2d-standard-2 | AMD SEV | Shielded Boot)       |
| Network: test / nl (No External IP | IAP SSH Tunnel 35.235.240.0/20 -> tcp:22)        |
| Identity: cse-vm-sa (Bucket-Scoped objectAdmin + Key-Scoped cryptoKeyEncrypter...)    |
|                                                                                       |
|  +---------------------------------------------------------------------------------+  |
|  | Legacy POSIX Application / User Process                                         |  |
|  | Reads & Writes Standard Plaintext POSIX Files                                   |  |
|  +----------------------------------------+----------------------------------------+  |
|                                           | Plaintext File I/O                        |
|                                           v (/mnt/gcs_secure/euv_wafer_recipe.txt)    |
|  +---------------------------------------------------------------------------------+  |
|  | Upper Mount: /mnt/gcs_secure (gocryptfs FUSE Cryptographic Overlay)             |  |
|  | - Content Encryption : AES-256-GCM (4 KB blocks + 16B IV + 16B GCM Auth Tag)   |  |
|  | - Filename Encryption: AES-256-EME (Wide-Block Tweakable Cipher + DirIV)        |  |
|  | - Key Staging        : /run/cse_keys/dek.pass (AMD SEV tmpfs RAM -> shred -u)   |  |
|  +----------------------------------------+----------------------------------------+  |
|                                           | Obfuscated Names + Binary Ciphertext      |
|                                           v (/mnt/gcs_raw/oX5grluyzVGyQDGhA9c2...)    |
|  +---------------------------------------------------------------------------------+  |
|  | Lower Mount: /mnt/gcs_raw (gcsfuse --implicit-dirs)                             |  |
|  | Translates local encrypted FUSE operations into GCS HTTPS REST API calls        |  |
|  +----------------------------------------+----------------------------------------+  |
+-------------------------------------------|-------------------------------------------+
                                            | Private Google Access (HTTPS TLS 1.3)
                                            v
            +---------------------------------------------------------------+
            | Google Cloud Storage (europe-west4)                           |
            | Bucket: gs://cse-os-agent-bucket-your-project-id              |
            | Stores ONLY EME-Encrypted Object Names & AES-256-GCM Blobs    |
            | (Zero Plaintext Content, Zero Plaintext Filenames)            |
            +---------------------------------------------------------------+
```

### Key Architectural Controls
1. **Hardware-Enforced Memory Isolation (AMD SEV):** The VM runs on `n2d-standard-2` with `--confidential-compute-type=SEV` and Shielded VM integrity (`--shielded-secure-boot`, `--shielded-vtpm`, `--shielded-integrity-monitoring`). All FUSE buffers, page caches, and cryptographic keys remain encrypted in RAM via a hardware-protected per-VM key managed by the AMD Secure Processor.
2. **In-Memory Ephemeral Key Staging & Shredding (`tmpfs` + `shred -u`):** During startup and remounts (`/usr/local/sbin/cse-mount-overlay.sh`), a 16 MB RAM-backed `tmpfs` (`mode=0700`) is mounted at `/run/cse_keys`. The Data Encryption Key (DEK) is injected strictly into `/run/cse_keys/dek.pass` in SEV-protected RAM, passed to `gocryptfs`, and immediately destroyed with `shred -u` once the FUSE daemon initializes. The key never touches persistent disk.
3. **Dual-Layer Content & Metadata Protection:**
   - **File Contents:** Encrypted via `AES-256-GCM` (50-byte cryptographic overhead per small file: 18-byte header + 16-byte IV + 16-byte GCM authentication tag).
   - **Filenames & Directory Structure:** Encrypted via `EME` (ECB-Mix-ECB wide-block encryption) with per-directory initialization vectors (`gocryptfs.diriv`), preventing filename metadata leakage in GCS bucket listings.
4. **Zero Public Exposure & Least-Privilege Identity:** The VM is provisioned with `--no-address` (no external IP) and accessed strictly via **Identity-Aware Proxy (IAP) TCP Forwarding** (`allow-iap-ssh-cse-vm`: `35.235.240.0/20` -> `tcp:22` on tag `cse-iap-ssh`). The VM attaches dedicated Service Account `cse-vm-sa` with bucket-scoped `roles/storage.objectAdmin` on `gs://${STAGE2_BUCKET_NAME}`.

---

## 2. Prerequisites

Before executing the Stage 2 lifecycle scripts, verify the following:

- **Google Cloud Platform Project:** An active GCP project with billing enabled (e.g., `your-project-id`).
- **Command-Line Tooling:**
  - `gcloud` CLI authenticated and configured (`gcloud auth login`).
  - SSH client available (standard in Google Cloud Shell and macOS/Linux terminals) for `gcloud compute ssh --tunnel-through-iap`.
- **Administrative Bootstrap Permissions:**
  - A Project or Organization IAM Administrator account is required solely to run Step 1 (`./grant_stage2_iam.sh`) and Step 4 (`./revoke_stage2_iam.sh`).
  - Steps 2, 3, and 5 are designed to run under the least-privilege `DEPLOYER_PRINCIPAL`.

---

## 3. Configuration Phase (`stage2_config.env.example` -> `stage2_config.env`)

Stage 2 is 100% decoupled from Stage 1 and sources all configuration parameters from `v2/stage2/stage2_config.env`.

### 3.1 Copy the Configuration Template

Before running any Stage 2 script, copy the sanitized template `stage2_config.env.example` to `stage2_config.env`:

```bash
cd stage2 && cp stage2_config.env.example stage2_config.env && chmod +x *.sh *.env
```

### 3.2 Customize Environment Variables

Open `stage2_config.env` and update the placeholders (`your-project-id`, `user@example.com`) to match your target GCP environment:

| Variable | Template Default | Description |
| :--- | :--- | :--- |
| `PROJECT_ID` | `your-project-id` | Target Google Cloud Project ID. **Modify this first** if deploying to a new project. |
| `REGION` | `europe-west4` | Target GCP region (enforces EU data residency for GCS, KMS, and Cloud NAT). |
| `ZONE` | `europe-west4-a` | Target GCP zone for the AMD SEV Confidential VM (`n2d-standard-2`). |
| `DEPLOYER_PRINCIPAL` | `user:user@example.com` | IAM principal granted temporary Stage 2 deployment permissions. |
| `VPC_NETWORK` | `test` | Custom-mode VPC network name (created automatically if absent). |
| `VPC_SUBNET` | `nl` | Regional VPC subnet name with Private Google Access enabled. |
| `VPC_SUBNET_CIDR` | `10.0.0.0/24` | Primary IPv4 CIDR range for `VPC_SUBNET`. |
| `CLOUD_ROUTER_NAME` | `${VPC_NETWORK}-nat-router` | Cloud Router name for outbound package installation over Cloud NAT. |
| `CLOUD_NAT_NAME` | `${VPC_NETWORK}-nat-gateway` | Cloud NAT gateway name allowing the private VM to reach Debian/Google apt mirrors. |
| `KMS_KEY_RING` | `cse-keyring-mvp` | Cloud KMS KeyRing name in `REGION`. |
| `KMS_CRYPTO_KEY` | `cse-proxy-key` | Cloud KMS CryptoKey name in `KMS_KEY_RING`. |
| `VM_NAME` | `cse-confidential-vm` | Name of the Confidential VM instance (`n2d-standard-2`, AMD SEV, Debian 12). |
| `VM_SA_NAME` | `cse-vm-sa` | Dedicated least-privilege Service Account attached to the Confidential VM. |
| `STAGE2_BUCKET_NAME` | `cse-os-agent-bucket-${PROJECT_ID}` | Regional GCS bucket storing raw `gocryptfs` ciphertext and encrypted filenames. |
| `GCS_RAW_MOUNT` | `/mnt/gcs_raw` | Lower mount point inside the VM backed by `gcsfuse --implicit-dirs`. |
| `GCS_SECURE_MOUNT` | `/mnt/gcs_secure` | Upper mount point inside the VM backed by `gocryptfs` (plaintext POSIX view). |
| `IAP_FIREWALL_RULE` | `allow-iap-ssh-cse-vm` | VPC ingress firewall rule permitting IAP TCP forwarding (`35.235.240.0/20` -> `tcp:22`). |
| `IAP_NETWORK_TAG` | `cse-iap-ssh` | Network tag applied to `VM_NAME` to scope the IAP SSH firewall rule. |

---

## 4. Step-by-Step Execution Lifecycle

Execute the following commands from `v2/stage2/`.

### Step 1: Grant Stage 2 Least-Privilege IAM Roles

Run `./grant_stage2_iam.sh` as a Project/Organization IAM Administrator to grant `DEPLOYER_PRINCIPAL` the exact roles required for Stage 2 deployment and verification (`serviceUsageAdmin`, `networkAdmin`, `instanceAdmin.v1`, `iap.tunnelResourceAccessor`, `cloudkms.admin`, `serviceAccountAdmin`, `serviceAccountUser`, `projectIamAdmin`, `storage.admin`, `logging.viewer`).

```bash
./grant_stage2_iam.sh
```

*(Optional CLI override for a specific project and principal)*:

```bash
./grant_stage2_iam.sh "your-project-id" "user:user@example.com"
```

---

### Step 2: Deploy Confidential VM & Cryptographic FUSE Overlay

Run `./deploy_cse_vm.sh` to enable required APIs, verify/create the VPC, Subnet (with PGA), Cloud NAT, and IAP SSH firewall rule, create the Stage 2 GCS bucket (`gs://cse-os-agent-bucket-your-project-id`), configure the dedicated `cse-vm-sa` Service Account with bucket-scoped IAM, launch the AMD SEV Confidential VM (`cse-confidential-vm`), and wait for `/usr/local/sbin/cse-mount-overlay.sh` to mount `/mnt/gcs_raw` and `/mnt/gcs_secure` and shred the ephemeral DEK.

```bash
./deploy_cse_vm.sh
```

---

### Step 3: Execute the 4-Stage Zero-Plaintext Verification Protocol

Run `./test_cse_vm.sh` to validate the threat model end-to-end across both the in-VM mounts (over IAP SSH) and out-of-band GCS inspection:
1. **Stage 1 (Legacy POSIX Write & Readback):** Writes `CONFIDENTIAL_STAGE2_OS_AGENT_PAYLOAD_9042` to `/mnt/gcs_secure/euv_wafer_recipe_secret.txt` inside the VM and verifies transparent local readback.
2. **Stage 2 (Lower-Mount Inspection):** Inspects `/mnt/gcs_raw` inside the VM to confirm the plaintext filename is absent and extracts the `EME`-encrypted filename alongside `gocryptfs.conf` and `gocryptfs.diriv`.
3. **Stage 3 (Out-of-Band CSP Audit):** Queries `gs://cse-os-agent-bucket-your-project-id/` directly from the runner outside the VM using `gcloud storage ls` and `gcloud storage cat`, verifying zero plaintext filename leakage and confirming binary `AES-256-GCM` ciphertext with zero cleartext matches.
4. **Stage 4 (Cold Remount & Ephemeral Key Shredding):** Unmounts both `/mnt/gcs_secure` and `/mnt/gcs_raw` via `fusermount3 -u`, verifies `/run/cse_keys/dek.pass` was shredded from `tmpfs`, re-runs `/usr/local/sbin/cse-mount-overlay.sh`, verifies post-remount DEK shredding, and confirms intact plaintext decryption.

```bash
./test_cse_vm.sh
```

---

### Step 4: Revoke Elevated Deployment IAM Roles (Post-Deployment Hardening)

Once Stage 2 is deployed and verified, execute `./revoke_stage2_iam.sh` as an IAM Administrator to strip all elevated deployment roles (`roles/compute.instanceAdmin.v1`, `roles/iap.tunnelResourceAccessor`, `roles/storage.admin`, etc.) from `DEPLOYER_PRINCIPAL`, enforcing **Zero Standing Privileges (ZSP)**. The Confidential VM continues operating autonomously using its attached least-privilege `cse-vm-sa` identity.

```bash
./revoke_stage2_iam.sh
```

*(Optional CLI override for a specific project and principal)*:

```bash
./revoke_stage2_iam.sh "your-project-id" "user:user@example.com"
```

---

### Step 5: Stage 2 FinOps Teardown

To cleanly destroy all Stage 2 resources when testing concludes, run `./cleanup_stage2.sh`. (If deployer IAM roles were revoked in Step 4, re-run `./grant_stage2_iam.sh` first or run as an administrator.)

- **Destroyed:** Confidential VM (`cse-confidential-vm`), IAP SSH firewall rule (`allow-iap-ssh-cse-vm`), Stage 2 GCS bucket and all objects (`gs://cse-os-agent-bucket-your-project-id`), and Stage 2 Service Account (`cse-vm-sa`).
- **Preserved:** Shared VPC network (`test`/`nl`), Cloud NAT, and Cloud KMS KeyRing/CryptoKey (`cse-keyring-mvp/cse-proxy-key`).

```bash
./cleanup_stage2.sh
```
