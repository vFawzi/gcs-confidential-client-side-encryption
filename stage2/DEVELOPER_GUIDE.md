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
|  | Legacy POSIX Application / Unmodified COTS Binary                               |  |
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

## 3. FAQ: Why FUSE instead of STET?

A common architectural question when evaluating Client-Side Encryption (CSE) patterns on Google Cloud is: **Why does Stage 2 use a stacked FUSE overlay (`gocryptfs` + `gcsfuse`) when our CI/CD guidelines mandate the Split-Trust Encryption Tool (`stet`)?**

The answer lies in the fundamental difference between **Long-Running Application Runtimes** and **Ephemeral CI/CD Pipelines**:

| Architectural Dimension | Stage 2: Stacked FUSE (`gocryptfs` + `gcsfuse`) | CI/CD Pattern: Split-Trust Encryption Tool (`stet`) |
| :--- | :--- | :--- |
| **Target Environment** | **Long-Running, Stateful Legacy Application Runtimes** on dedicated Confidential VMs (`n2d-standard-2` AMD SEV). | **Ephemeral, Stateless CI/CD Runners** (Google Cloud Build, GitHub Actions, GitLab CI). |
| **Workload I/O Profile** | **Interactive POSIX File System I/O:** Applications hard-require a mounted POSIX directory (`/mnt/gcs_secure`) supporting `open()`, `read()`, `write()`, `lseek()`, `fsync()`, and directory traversal without code changes. | **Single-Pass Artifact Streaming:** Pipelines package discrete build artifacts (`build_artifact.zip`, container tarballs, ML weights, logs) and stream them once to GCS. |
| **Privilege & Isolation Model** | Runs inside a dedicated, single-tenant Confidential VM where mounting `/dev/fuse` in guest kernel space is isolated by AMD SEV hardware virtual machine boundaries. | Runs in unprivileged user space without `/dev/fuse` or `CAP_SYS_ADMIN`. **Mounting FUSE inside CI/CD containers is a security and operational anti-pattern.** |
| **Lifecycle & Flush Semantics** | Persistent daemon lifecycle managed by systemd/startup scripts over days or months, with explicit `fsync()` durability across ongoing POSIX operations. | Stateless single-command CLI pipe (`./stet encrypt ... \| gsutil cp - gs://...`) that eliminates background FUSE unmount race conditions before container exit. |

### Key Takeaway
- **Use Stage 2 (`gocryptfs` + `gcsfuse`)** exclusively for **long-running legacy POSIX applications and COTS binaries** executing inside a Confidential VM that require a live local filesystem mount (`/mnt/gcs_secure`).
- **Use `stet` (Split-Trust Encryption Tool)** exclusively for **ephemeral CI/CD pipelines and batch automation jobs**. Never mount FUSE inside short-lived CI/CD runners. For complete CI/CD pipeline examples, see the **[CI/CD Integration Guide](../cicd/CICD_INTEGRATION_GUIDE.md)**.

---

## 4. Developer Experience: Consuming `/mnt/gcs_secure` in POSIX Applications

In Stage 2, applications **do NOT use the Google Cloud Storage SDK** (`google-cloud-storage`) or cryptographic libraries (`tink`). Instead, they use standard OS-level file I/O operations directly on `/mnt/gcs_secure`.

### 4.1 Python POSIX File I/O Example (Standard `open()`)

```python
import os
from pathlib import Path
from typing import Final

SECURE_MOUNT_DIR: Final[Path] = Path(os.environ.get("GCS_SECURE_MOUNT", "/mnt/gcs_secure"))


def write_confidential_record(filename: str, payload: str) -> Path:
    """Writes plaintext to /mnt/gcs_secure; flushed to GCS as AES-256-GCM ciphertext."""
    if not SECURE_MOUNT_DIR.is_mount():
        raise RuntimeError(f"Secure CSE overlay is not mounted at {SECURE_MOUNT_DIR}")

    target_path: Path = SECURE_MOUNT_DIR / filename
    with open(target_path, "w", encoding="utf-8") as fh:
        fh.write(payload)
        fh.flush()
        os.fsync(fh.fileno())  # Ensures gcsfuse flushes the encrypted object to GCS

    return target_path


def read_confidential_record(filename: str) -> str:
    """Reads and transparently decrypts a file from /mnt/gcs_secure."""
    target_path: Path = SECURE_MOUNT_DIR / filename
    with open(target_path, "r", encoding="utf-8") as fh:
        return fh.read()


if __name__ == "__main__":
    # Direct standard Python file I/O on /mnt/gcs_secure:
    with open("/mnt/gcs_secure/file.txt", "w", encoding="utf-8") as f:
        f.write("CONFIDENTIAL_STAGE2_OS_AGENT_PAYLOAD_9042\n")
        f.flush()
        os.fsync(f.fileno())

    with open("/mnt/gcs_secure/file.txt", "r", encoding="utf-8") as f:
        print(f"Decrypted content: {f.read().strip()}")
```

### 4.2 Bash POSIX File I/O Example

```bash
#!/usr/bin/env bash
set -euo pipefail

# Verify /mnt/gcs_secure is mounted, write plaintext, flush via sync, and read back
mountpoint -q /mnt/gcs_secure
printf 'CONFIDENTIAL_STAGE2_OS_AGENT_PAYLOAD_9042\n' > /mnt/gcs_secure/file.txt
sync /mnt/gcs_secure/file.txt
cat /mnt/gcs_secure/file.txt
```

### 4.3 Filesystem Constraints & Debugging (`/mnt/gcs_raw` vs. `/mnt/gcs_secure`)
- **AES-EME Filename Length Constraint:** Filenames in `/mnt/gcs_secure` are encrypted via **AES-256-EME** (padded to 16-byte AES blocks) and **Base64URL-encoded** (~33% expansion). Because Linux enforces a 255-byte `NAME_MAX` limit on the encrypted filename in `/mnt/gcs_raw`, developers must **avoid extremely long filenames approaching 255 bytes** (keep plaintext filenames under ~175 bytes to prevent `ENAMETOOLONG` errors).
- **Debugging `/mnt/gcs_raw`:** If a developer inspects `/mnt/gcs_raw`, they will **never** see plaintext filenames or cleartext content. They will only see `gocryptfs.conf` (wrapped master key metadata), `gocryptfs.diriv` (16-byte per-directory IV), and Base64URL-encoded `AES-256-EME` filenames containing raw binary `AES-256-GCM` ciphertext. **Never modify or delete files directly in `/mnt/gcs_raw`.**

---

## 5. Prerequisites & Configuration

### 5.1 Prerequisites
1. **Google Cloud SDK (`gcloud`):** Installed and authenticated (`gcloud auth login`), with an SSH client available for IAP tunneling (`gcloud compute ssh --tunnel-through-iap`).
2. **Target GCP Project:** A Google Cloud project with billing enabled (e.g., `your-project-id`) and quota for `n2d-standard-2` Confidential Computing instances in `europe-west4`.
3. **IAM Administrator Privileges:** Required for Step 1 (`./grant_stage2_iam.sh`) to grant least-privilege deployment roles to your `DEPLOYER_PRINCIPAL` (and `./revoke_stage2_iam.sh` to strip them post-deployment).

### 5.2 Configuration (`stage2_config.env.example` $\rightarrow$ `stage2_config.env` & Exporting `PROJECT_ID`)

> **Important:** All Stage 2 and CI/CD scripts dynamically construct Service Account emails, Cloud KMS URIs, and GCS bucket names from `${PROJECT_ID}`. You **must** export `PROJECT_ID` in your terminal before executing local scripts (or set it in `stage2/stage2_config.env`).

Navigate to `v2/stage2/`, export your target `PROJECT_ID`, and copy the sanitized template `stage2_config.env.example` to `stage2_config.env`:

```bash
export PROJECT_ID="your-project-id" && cd stage2 && cp stage2_config.env.example stage2_config.env && chmod +x *.sh *.env
```

Review `stage2_config.env` and verify your `PROJECT_ID` and `DEPLOYER_PRINCIPAL`:

```bash
export PROJECT_ID="${PROJECT_ID:-your-project-id}"
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

Ensure `export PROJECT_ID="your-project-id"` is set in your active shell, then execute the following lifecycle phases in order from the `v2/stage2/` directory (or bootstrap keyless GitHub Actions CI/CD from the repository root via [`../cicd/setup_github_wif.sh`](../cicd/setup_github_wif.sh)):

### 6.1 IAM Bootstrap (`./grant_stage2_iam.sh`)

Grants `DEPLOYER_PRINCIPAL` the least-privilege IAM roles required to provision and verify Stage 2 (`roles/serviceusage.serviceUsageAdmin`, `roles/compute.networkAdmin`, `roles/compute.securityAdmin`, `roles/compute.instanceAdmin.v1`, `roles/iap.tunnelResourceAccessor`, `roles/cloudkms.admin`, `roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser`, `roles/resourcemanager.projectIamAdmin`, `roles/storage.admin`, `roles/logging.viewer`).

```bash
./grant_stage2_iam.sh
```

### 6.2 Infrastructure Deployment (`./deploy_cse_vm.sh`)

Provisions the Stage 2 Confidential VM environment:
- Enables required Google Cloud APIs (`compute`, `iam`, `cloudkms`, `storage`, `iap`, `logging`, `monitoring`).
- Verifies or creates the custom VPC (`test`), Private Google Access subnet (`nl`), Cloud Router/NAT, and IAP SSH ingress firewall rule (`allow-iap-ssh-cse-vm`).
- Verifies or creates the Cloud KMS key and regional ciphertext GCS bucket (`gs://cse-os-agent-bucket-your-project-id`) with Uniform Bucket-Level Access and Public Access Prevention.
- Creates the dedicated VM Service Account (`cse-vm-sa`) with bucket-scoped `roles/storage.objectAdmin` and key-scoped `roles/cloudkms.cryptoKeyEncrypterDecrypter`.
- Launches the AMD SEV Confidential VM (`cse-confidential-vm`), installs `gcsfuse` and `gocryptfs`, executes `/usr/local/sbin/cse-mount-overlay.sh`, and shreds the ephemeral DEK from `tmpfs`.

```bash
./deploy_cse_vm.sh
```

### 6.3 Threat Model Validation (`./test_cse_vm.sh`)

Executes the automated **4-Stage Zero-Plaintext Verification Protocol**:
1. **Stage 1 — Legacy POSIX Write Simulation (In-VM via IAP SSH):** Writes `CONFIDENTIAL_STAGE2_OS_AGENT_PAYLOAD_9042` to `/mnt/gcs_secure/euv_wafer_recipe_secret.txt`, calls `sync`, and verifies local decrypted readback.
2. **Stage 2 — Lower-Mount Ciphertext & Filename Inspection (In-VM `/mnt/gcs_raw`):** Confirms the plaintext filename is absent in `/mnt/gcs_raw`, verifies `gocryptfs.conf` and `gocryptfs.diriv`, and captures the `AES-256-EME` encrypted filename.
3. **Stage 3 — Out-of-Band CSP Zero-Plaintext Audit (External Runner $\rightarrow$ GCS Directly):** Queries `gs://cse-os-agent-bucket-your-project-id/` directly via `gcloud storage ls` and `gcloud storage cat` outside the VM, confirming zero plaintext filename leakage and verifying the 50-byte `gocryptfs` `AES-256-GCM` framing with zero cleartext matches.
4. **Stage 4 — Cold Unmount, Ephemeral Key Shred Verification & Remount:** Unmounts both layers via `fusermount3 -u`, verifies `/run/cse_keys/dek.pass` was shredded from `tmpfs`, re-runs `/usr/local/sbin/cse-mount-overlay.sh`, verifies post-remount key shredding, and confirms intact plaintext decryption.

```bash
./test_cse_vm.sh
```

### 6.4 FinOps Infrastructure Teardown (`./cleanup_stage2.sh`)

Destroys all Stage 2 resources (`cse-confidential-vm`, `allow-iap-ssh-cse-vm` firewall rule, `gs://cse-os-agent-bucket-your-project-id` bucket and objects, and `cse-vm-sa` Service Account) to prevent ongoing compute or storage charges.

```bash
./cleanup_stage2.sh
```

> **Post-Deployment Hardening:** To strip the deployer principal of elevated permissions after deployment or teardown (enforcing Zero Standing Privileges), execute `./revoke_stage2_iam.sh`.
