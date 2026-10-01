# Stage 2: Client-Side Encryption via Transparent OS-Level Agent

## 1. Architecture Overview

The Stage 2 architecture provides **Transparent OS-Level Client-Side Encryption (CSE)** for legacy POSIX applications, commercial off-the-shelf (COTS) software, and high-throughput scientific or industrial binaries that read and write directly to local filesystem paths and cannot be refactored to use cloud storage SDKs or HTTP sidecar proxies.

Instead of modifying application code, encryption is enforced transparently at the Linux Virtual File System (VFS) / FUSE layer inside a **Google Cloud Confidential VM** (`n2d-standard-2` backed by **AMD Secure Encrypted Virtualization [SEV]**).

```
+---------------------------------------------------------------------------------------+
| Confidential VM: cse-confidential-vm (n2d-standard-2 | AMD SEV Hardware RAM Encryption)|
| Network: Private Subnet (No External IP | IAP SSH Tunnel 35.235.240.0/20 -> tcp:22)   |
| Identity: cse-vm-sa (Bucket-Scoped roles/storage.objectAdmin)                         |
|                                                                                       |
|  +---------------------------------------------------------------------------------+  |
|  | Legacy POSIX Application / Unmodified Binary                                    |  |
|  | Standard POSIX Syscalls: open(), write(), fsync(), read(), rename()             |  |
|  +----------------------------------------+----------------------------------------+  |
|                                           | Plaintext POSIX File I/O                  |
|                                           v (/mnt/gcs_secure/euv_wafer_recipe.txt)    |
|  +---------------------------------------------------------------------------------+  |
|  | Upper Mount: /mnt/gcs_secure (gocryptfs Cryptographic FUSE Overlay)             |  |
|  | - Intercepts VFS syscalls inside AMD SEV hardware-encrypted RAM                 |  |
|  | - Content Encryption : AES-256-GCM (4 KB blocks + 16B IV + 16B Auth Tag)        |  |
|  | - Filename Encryption: AES-256-EME (Wide-Block Cipher + Per-Directory DirIV)    |  |
|  | - Ephemeral Key      : /run/cse_keys/dek.pass (tmpfs in SEV RAM -> shred -u)    |  |
|  +----------------------------------------+----------------------------------------+  |
|                                           | AES-256-GCM Ciphertext + EME Filenames    |
|                                           v (/mnt/gcs_raw/oX5grluyzVGyQDGhA9c2...)    |
|  +---------------------------------------------------------------------------------+  |
|  | Lower Mount: /mnt/gcs_raw (gcsfuse --implicit-dirs)                             |  |
|  | Translates encrypted FUSE file operations into GCS HTTPS REST API calls         |  |
|  +----------------------------------------+----------------------------------------+  |
+-------------------------------------------|-------------------------------------------+
                                            | Private Google Access (TLS 1.3)
                                            v
            +---------------------------------------------------------------+
            | Google Cloud Storage (europe-west4)                           |
            | Bucket: gs://cse-os-agent-bucket-your-project-id              |
            | Receives & Stores ONLY Obfuscated Names & AES-256-GCM Blobs   |
            +---------------------------------------------------------------+
```

### How the Stacked FUSE Pipeline Works
1. **Plaintext Upper Mount (`/mnt/gcs_secure`):** Legacy applications read and write standard files and directories under `/mnt/gcs_secure` using ordinary POSIX file descriptors. The application has zero awareness of cloud storage or cryptography.
2. **In-Memory Cryptographic Interception (`gocryptfs` in AMD SEV RAM):**
   - Every write to `/mnt/gcs_secure` is intercepted by the `gocryptfs` FUSE daemon running in **AMD SEV hardware-encrypted memory**.
   - **File Content Encryption (`AES-256-GCM`):** File payloads are segmented into 4 KB blocks. Each file receives an 18-byte header, and each block is encrypted with a random 128-bit (16-byte) Initialization Vector (IV) and authenticated with a 128-bit (16-byte) Galois/Counter Mode (GCM) integrity tag (adding 50 bytes of cryptographic framing to small single-block files).
   - **Filename Encryption (`AES-256-EME`):** Filenames are encrypted using **ECB-Mix-ECB (EME)** wide-block encryption combined with a per-directory initialization vector (`gocryptfs.diriv`) and Base64URL-encoded. Plaintext filenames never appear below `/mnt/gcs_secure`.
3. **Ciphertext Lower Mount (`/mnt/gcs_raw` via `gcsfuse`):**
   - `gocryptfs` flushes the encrypted blocks and EME-obfuscated filenames into `/mnt/gcs_raw`, which is mounted via `gcsfuse --implicit-dirs -o rw,nodev,nosuid`.
   - `gcsfuse` streams only the already-encrypted ciphertext objects over Private Google Access (TLS 1.3) to the regional Google Cloud Storage bucket (`gs://cse-os-agent-bucket-your-project-id`).

---

## 2. Threat Model & The "Zero Plaintext to CSP" Guarantee

Stage 2 is engineered to enforce a strict **"Zero Plaintext to Cloud Service Provider (CSP)"** security boundary:

| Threat Vector | Cryptographic & Architectural Mitigation | Verification Guarantee |
| :--- | :--- | :--- |
| **CSP Storage Inspection / Bucket Compromise** | Data and filenames are encrypted inside the VM *before* reaching `gcsfuse`. GCS only receives `AES-256-GCM` ciphertext and `AES-256-EME` obfuscated object names. | Out-of-band `gcloud storage ls` and `gcloud storage cat` queries return zero plaintext filenames and zero cleartext payload bytes. |
| **Hypervisor / Host RAM Scraping (Data in Use)** | The VM runs on an `n2d-standard-2` Confidential VM with **AMD SEV** (`--confidential-compute-type=SEV`). DRAM pages (including Linux page cache, FUSE buffers, and key material) are encrypted with a hardware key locked inside the AMD Secure Processor. | Host hypervisor cannot read guest memory pages or extract the active `gocryptfs` master key from RAM. |
| **Persistent Boot Disk Forensics (Key at Rest)** | During `/usr/local/sbin/cse-mount-overlay.sh`, the Data Encryption Key (DEK) is staged exclusively in a 16 MB RAM-backed `tmpfs` mount (`/run/cse_keys/dek.pass`, `mode=0400`) and immediately overwritten and unlinked via `shred -u` once `gocryptfs` mounts. | The raw DEK is never written to the persistent boot disk (`pd-balanced`), and `/run/cse_keys/dek.pass` does not exist on the filesystem post-mount. |
| **Ciphertext Tampering / Bit-Rot in GCS** | Every 4 KB ciphertext block carries a 16-byte `AES-256-GCM` authentication tag, and filenames are bound to their parent directory via `gocryptfs.diriv`. | Any unauthorized bit modification in GCS causes `gocryptfs` to immediately reject the read with an `EIO` (Input/Output Error) rather than returning corrupted plaintext. |
| **Unauthorized Network Ingress / Lateral Movement** | The Confidential VM is deployed with `--no-address` (zero public IP) and Shielded VM (`Secure Boot`, `vTPM`, `Integrity Monitoring`). Administrative access is restricted to **Identity-Aware Proxy (IAP)** TCP forwarding (`35.235.240.0/20` $\rightarrow$ `tcp:22`). | Zero public attack surface; all administrative SSH commands are authenticated and audited via Google Cloud IAP. |

---

## 3. Developer Pattern: Consuming `/mnt/gcs_secure` in POSIX Applications

Because encryption and GCS synchronization happen transparently at the OS mount layer, applications require **zero Google Cloud SDKs or cryptographic libraries**. Developers simply point their application's data directory to `/mnt/gcs_secure`.

### Python POSIX File I/O Example (Zero Cloud SDKs)

```python
import os
from pathlib import Path

SECURE_MOUNT_DIR = Path(os.environ.get("GCS_SECURE_MOUNT", "/mnt/gcs_secure"))


def write_confidential_record(filename: str, payload: bytes) -> Path:
    """Writes plaintext bytes to the gocryptfs mount; flushed to GCS as AES-256-GCM ciphertext."""
    if not SECURE_MOUNT_DIR.is_mount():
        raise RuntimeError(f"Secure CSE overlay is not mounted at {SECURE_MOUNT_DIR}")

    target_path = SECURE_MOUNT_DIR / filename
    with open(target_path, "wb") as fh:
        fh.write(payload)
        fh.flush()
        os.fsync(fh.fileno())  # Ensures gcsfuse flushes the encrypted object to GCS

    return target_path


def read_confidential_record(filename: str) -> bytes:
    """Reads and transparently decrypts a file from the gocryptfs mount."""
    target_path = SECURE_MOUNT_DIR / filename
    with open(target_path, "rb") as fh:
        return fh.read()
```

> **Best Practice for FUSE + GCS Flush Semantics:** Always call `fsync()` (or `sync` in shell scripts) after completing file writes on `/mnt/gcs_secure`. In `gcsfuse`, object finalization in Google Cloud Storage occurs upon `fsync()` / `close()` of the underlying encrypted file descriptor.

---

## 4. Prerequisites

Before deploying and testing the Stage 2 architecture, ensure you have:

1. **Google Cloud SDK (`gcloud`):** Installed and authenticated (`gcloud auth login`), with an SSH client available for IAP tunneling (`gcloud compute ssh --tunnel-through-iap`).
2. **Target GCP Project:** A Google Cloud project with billing enabled (e.g., `your-project-id`) and quota for `n2d-standard-2` Confidential Computing instances in `europe-west4`.
3. **IAM Administrator Privileges:** Required solely for Step 1 (`./grant_stage2_iam.sh`) to grant least-privilege deployment roles to your `DEPLOYER_PRINCIPAL` (and optionally `./revoke_stage2_iam.sh` to strip them post-deployment).

---

## 5. Configuration (`stage2_config.env.example` $\rightarrow$ `stage2_config.env`)

Stage 2 is 100% standalone and reads all environment parameters from `v2/stage2/stage2_config.env`.

### Step 1: Copy the Sanitized Template

Navigate to `v2/stage2/` and copy `stage2_config.env.example` to `stage2_config.env`:

```bash
cd stage2 && cp stage2_config.env.example stage2_config.env && chmod +x *.sh *.env
```

### Step 2: Populate Your Environment Variables

Edit `stage2_config.env` and replace the placeholder values (`your-project-id` and `user@example.com`):

```bash
export PROJECT_ID="your-project-id"
export REGION="europe-west4"
export ZONE="europe-west4-a"
export DEPLOYER_PRINCIPAL="user:user@example.com"

export VPC_NETWORK="test"
export VPC_SUBNET="nl"
export VPC_SUBNET_CIDR="10.0.0.0/24"
export CLOUD_ROUTER_NAME="${VPC_NETWORK}-nat-router"
export CLOUD_NAT_NAME="${VPC_NETWORK}-nat-gateway"

export KMS_KEY_RING="cse-keyring-mvp"
export KMS_CRYPTO_KEY="cse-proxy-key"
export KMS_KEY_URI="gcp-kms://projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KMS_KEY_RING}/cryptoKeys/${KMS_CRYPTO_KEY}"

export VM_NAME="cse-confidential-vm"
export VM_SA_NAME="cse-vm-sa"
export VM_SA_EMAIL="${VM_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export STAGE2_BUCKET_NAME="cse-os-agent-bucket-${PROJECT_ID}"
export GCS_RAW_MOUNT="/mnt/gcs_raw"
export GCS_SECURE_MOUNT="/mnt/gcs_secure"
export IAP_FIREWALL_RULE="allow-iap-ssh-cse-vm"
export IAP_NETWORK_TAG="cse-iap-ssh"
```

---

## 6. Execution Lifecycle

Execute the following four lifecycle phases in order from the `v2/stage2/` directory.

### 6.1 IAM Bootstrap (`./grant_stage2_iam.sh`)

Grants the `DEPLOYER_PRINCIPAL` the least-privilege IAM roles required to provision and verify Stage 2 (`roles/serviceusage.serviceUsageAdmin`, `roles/compute.networkAdmin`, `roles/compute.instanceAdmin.v1`, `roles/iap.tunnelResourceAccessor`, `roles/cloudkms.admin`, `roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser`, `roles/resourcemanager.projectIamAdmin`, `roles/storage.admin`, `roles/logging.viewer`).

```bash
./grant_stage2_iam.sh
```

---

### 6.2 Infrastructure Deployment (`./deploy_cse_vm.sh`)

Provisions the complete Stage 2 Confidential VM environment:
- Enables required Google Cloud APIs (`compute`, `iam`, `cloudkms`, `storage`, `iap`, `logging`, `monitoring`).
- Verifies or creates the custom VPC (`test`), Private Google Access subnet (`nl`), Cloud Router/NAT, and IAP SSH ingress firewall rule (`allow-iap-ssh-cse-vm`).
- Verifies or creates the Cloud KMS key and regional ciphertext GCS bucket (`gs://cse-os-agent-bucket-your-project-id`) with Uniform Bucket-Level Access and Public Access Prevention.
- Creates the dedicated VM Service Account (`cse-vm-sa`) with bucket-scoped `roles/storage.objectAdmin` and key-scoped `roles/cloudkms.cryptoKeyEncrypterDecrypter`.
- Launches the AMD SEV Confidential VM (`cse-confidential-vm`), installs `gcsfuse` and `gocryptfs`, executes `/usr/local/sbin/cse-mount-overlay.sh`, and shreds the ephemeral DEK from `tmpfs`.

```bash
./deploy_cse_vm.sh
```

---

### 6.3 Threat Model Validation (`./test_cse_vm.sh`)

Executes the automated **4-Stage Zero-Plaintext Verification Protocol**:

```bash
./test_cse_vm.sh
```

#### Deep Dive: The 4-Stage Zero-Plaintext Verification Protocol

1. **Stage 1 — Legacy POSIX Application Write Simulation (In-VM via IAP SSH):**
   - Connects to `cse-confidential-vm` over IAP SSH, writes a 40-byte plaintext payload (`CONFIDENTIAL_STAGE2_OS_AGENT_PAYLOAD_9042`) to `/mnt/gcs_secure/euv_wafer_recipe_secret.txt`, calls `sync`, and verifies that reading the file back from `/mnt/gcs_secure` returns the exact plaintext.
2. **Stage 2 — Lower-Mount Ciphertext & Filename Inspection (In-VM `/mnt/gcs_raw` via IAP SSH):**
   - Inspects `/mnt/gcs_raw` inside the VM to prove that `euv_wafer_recipe_secret.txt` does **not** exist in the lower `gcsfuse` directory.
   - Verifies the presence of `gocryptfs.conf` and `gocryptfs.diriv`, and captures the `AES-256-EME` encrypted filename (e.g., `oX5grluyzVGyQDGhA9c2qjGOy10WjRbZPduw5DNDi_E`).
3. **Stage 3 — Out-of-Band CSP Zero-Plaintext Audit (External Runner $\rightarrow$ GCS Directly):**
   - **Crucial Security Proof:** This stage executes **entirely outside the Confidential VM** from the test runner environment, bypassing the VM OS, `gocryptfs`, and `gcsfuse` to simulate what a rogue storage administrator or compromised CSP control plane would see in Google Cloud Storage:
     - Runs `gcloud storage ls gs://cse-os-agent-bucket-your-project-id/` and asserts that the plaintext filename (`euv_wafer_recipe_secret.txt`) is **completely absent** from the bucket.
     - Downloads the raw object (`gs://.../oX5grluyzVGyQDGhA9c2qjGOy10WjRbZPduw5DNDi_E`) directly via `gcloud storage cat`.
     - Asserts that the stored object size includes the 50-byte `gocryptfs` cryptographic framing (18-byte header + 16-byte IV + 16-byte GCM tag) and that `grep` finds **zero occurrences** of the plaintext string inside the raw GCS object.
4. **Stage 4 — Cold Unmount, Ephemeral Key Shred Verification & Remount (In-VM via IAP SSH):**
   - Completely unmounts both `/mnt/gcs_secure` and `/mnt/gcs_raw` via `fusermount3 -u`.
   - Verifies that `/run/cse_keys/dek.pass` was previously shredded and does not exist in `tmpfs`.
   - Re-executes `/usr/local/sbin/cse-mount-overlay.sh` to re-inject the DEK in SEV `tmpfs` RAM, remounts both layers, verifies `/run/cse_keys/dek.pass` is shredded again immediately after mount, and reads `/mnt/gcs_secure/euv_wafer_recipe_secret.txt` to prove persistent cryptographic integrity across cold restarts.

---

### 6.4 FinOps Infrastructure Teardown (`./cleanup_stage2.sh`)

Destroys all Stage 2 resources (`cse-confidential-vm`, `allow-iap-ssh-cse-vm` firewall rule, `gs://cse-os-agent-bucket-your-project-id` bucket and objects, and `cse-vm-sa` Service Account) to prevent ongoing compute or storage charges.

```bash
./cleanup_stage2.sh
```

> **Note:** To strip the deployer principal of elevated permissions after deployment or teardown, run `./revoke_stage2_iam.sh`.
