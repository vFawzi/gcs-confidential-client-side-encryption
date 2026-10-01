# Stage 2 Developer Guide: Consuming the Transparent POSIX Encryption Mount (`/mnt/gcs_secure`)

## 1. Developer Experience Overview

In the Stage 2 architecture (**Transparent OS-Level Agent on Confidential VM**), Client-Side Encryption (CSE) and Google Cloud Storage (GCS) synchronization are enforced transparently at the Linux Virtual File System (VFS) / FUSE layer inside an **AMD SEV Confidential VM** (`n2d-standard-2`).

> **For Infrastructure Engineers:** Looking to provision the Confidential VM, configure IAM, or run the 4-stage verification suite? Refer to the **[Stage 2 Operational Deployment Guide](./DEPLOYMENT_GUIDE.md)**. This guide is strictly for **Application Developers** writing or operating workloads on the Confidential VM.

### Zero Cloud SDKs, Zero Cryptographic Libraries
As an application developer targeting Stage 2, **your application code must NOT use the Google Cloud Storage SDK** (`google-cloud-storage`, `cloud.google.com/go/storage`, `@google-cloud/storage`) or embed cryptographic libraries (`tink`, `cryptography`, `openssl`).

Instead, your application interacts exclusively with the local POSIX filesystem at **`/mnt/gcs_secure`** using standard OS-level file I/O operations (`open()`, `read()`, `write()`, `fsync()`, `close()`, `rename()`).

```
+---------------------------------------------------------------------------------------+
| Application Process (Python, C/C++, Go, Java, Bash, or COTS Binary)                   |
| Standard POSIX Syscalls: open('/mnt/gcs_secure/file.txt', 'w'), write(), read()       |
+-------------------------------------------+-------------------------------------------+
                                            | Plaintext POSIX File I/O (In AMD SEV RAM)
                                            v
+---------------------------------------------------------------------------------------+
| Upper Mount: /mnt/gcs_secure (gocryptfs FUSE Overlay)  <-- DEVELOPERS READ/WRITE HERE |
| - Encrypts file contents via AES-256-GCM (4 KB blocks + 16B IV + 16B GCM Auth Tag)    |
| - Encrypts filenames via AES-256-EME (Wide-Block Cipher + Per-Directory DirIV)        |
+-------------------------------------------+-------------------------------------------+
                                            | Ciphertext Blocks + Obfuscated Filenames
                                            v
+---------------------------------------------------------------------------------------+
| Lower Mount: /mnt/gcs_raw (gcsfuse)                    <-- DO NOT TOUCH DIRECTLY      |
| - Streams encrypted objects over Private Google Access (TLS 1.3) to GCS               |
+---------------------------------------------------------------------------------------+
```

---

## 2. Code Samples: Standard OS-Level File I/O on `/mnt/gcs_secure`

### 2.1 Python Example (Standard `open()` I/O — No GCS SDK)

Applications use Python's built-in `open()` function targeting `/mnt/gcs_secure`. No GCP credentials, bucket names, or KMS keys are required in application code.

```python
import os
from pathlib import Path
from typing import Final

SECURE_MOUNT_PATH: Final[Path] = Path(os.environ.get("GCS_SECURE_MOUNT", "/mnt/gcs_secure"))


def write_encrypted_file(relative_filename: str, content: str) -> Path:
    """Writes plaintext text to /mnt/gcs_secure using standard POSIX file I/O."""
    if not SECURE_MOUNT_PATH.is_mount():
        raise OSError(f"Cryptographic mount {SECURE_MOUNT_PATH} is not active.")

    target_file: Path = SECURE_MOUNT_PATH / relative_filename
    target_file.parent.mkdir(parents=True, exist_ok=True)

    try:
        with open(target_file, "w", encoding="utf-8") as file_handle:
            file_handle.write(content)
            file_handle.flush()
            os.fsync(file_handle.fileno())
    except OSError as exc:
        raise RuntimeError(f"Failed to write to secure mount path {target_file}: {exc}") from exc

    return target_file


def read_decrypted_file(relative_filename: str) -> str:
    """Reads and transparently decrypts a file from /mnt/gcs_secure."""
    target_file: Path = SECURE_MOUNT_PATH / relative_filename

    try:
        with open(target_file, "r", encoding="utf-8") as file_handle:
            return file_handle.read()
    except FileNotFoundError as exc:
        raise FileNotFoundError(f"Encrypted file not found at {target_file}") from exc
    except OSError as exc:
        raise RuntimeError(
            f"I/O or GCM authentication error reading {target_file}: {exc}"
        ) from exc


if __name__ == "__main__":
    # Simple one-liner usage with standard Python file I/O:
    with open("/mnt/gcs_secure/file.txt", "w", encoding="utf-8") as f:
        f.write("CONFIDENTIAL_LITHOGRAPHY_CALIBRATION_VECTOR_9042\n")
        f.flush()
        os.fsync(f.fileno())

    with open("/mnt/gcs_secure/file.txt", "r", encoding="utf-8") as f:
        print(f"Decrypted content: {f.read().strip()}")
```

### 2.2 Bash / Shell Script Example

Legacy scripts, cron jobs, and COTS wrappers can read and write directly to `/mnt/gcs_secure` using standard POSIX utilities (`cat`, `tee`, `cp`, `dd`, `sync`):

```bash
#!/usr/bin/env bash
set -euo pipefail

SECURE_DIR="/mnt/gcs_secure"
TARGET_FILE="${SECURE_DIR}/file.txt"

# Verify the cryptographic FUSE overlay is mounted before writing
if ! mountpoint -q "${SECURE_DIR}"; then
  echo "ERROR: ${SECURE_DIR} is not mounted. Aborting to prevent unencrypted local writes." >&2
  exit 1
fi

# 1. Write plaintext directly to /mnt/gcs_secure (transparently encrypted via AES-256-GCM)
printf 'CONFIDENTIAL_WAFER_BATCH_TELEMETRY_9042\n' > "${TARGET_FILE}"

# 2. Flush kernel page cache so gcsfuse finalizes the ciphertext object in GCS
sync "${TARGET_FILE}"

# 3. Read back and transparently decrypt from /mnt/gcs_secure
DECRYPTED_CONTENT="$(cat "${TARGET_FILE}")"
echo "Read back from ${TARGET_FILE}: ${DECRYPTED_CONTENT}"
```

---

## 3. Filesystem Constraints & Operational Behavior

### 3.1 Filename Length Limit (`AES-256-EME` Overhead)
Every file and directory name created inside `/mnt/gcs_secure` is encrypted by `gocryptfs` using **AES-256-EME (ECB-Mix-ECB wide-block encryption)** combined with a per-directory initialization vector (`gocryptfs.diriv`) and **Base64URL-encoded** before being written to `/mnt/gcs_raw`.

- **Byte Expansion Overhead:** AES-EME pads plaintext filenames to a 16-byte AES block boundary, and Base64URL encoding expands the resulting binary ciphertext by **~33%** (`4/3` ratio).
- **Avoid Long Filenames Approaching 255 Bytes:** Because the lower POSIX mount (`/mnt/gcs_raw`) enforces the standard Linux `NAME_MAX` limit of **255 bytes** for encrypted filenames, **plaintext filenames in `/mnt/gcs_secure` must not exceed ~175 bytes** (and developers should stay well below 150 characters as a safe engineering margin).
- **Failure Mode:** Attempting to create a file with a plaintext name approaching 255 bytes will raise `OSError: [Errno 36] File name too long` (`ENAMETOOLONG`).

### 3.2 `fsync()` and Close-to-Open Flush Semantics
Because the lower layer (`/mnt/gcs_raw`) is backed by `gcsfuse`, Google Cloud Storage objects are finalized and uploaded only when the file descriptor is flushed and closed (`fsync()` / `close()`).
- Always call `os.fsync(fd)` in Python (or `sync` in Bash) after completing critical writes to ensure the encrypted payload is durably persisted to the GCS bucket before your process exits.
- Avoid high-frequency, single-byte random in-place file mutations; prefer streaming sequential writes or writing a complete temporary file and atomically renaming it (`os.replace()`) within `/mnt/gcs_secure`.

### 3.3 Mount Point Guardrails (`mountpoint` Check)
Applications should verify that `/mnt/gcs_secure` is an active mount point (`Path("/mnt/gcs_secure").is_mount()` in Python or `mountpoint -q /mnt/gcs_secure` in Bash) before writing sensitive data. If the FUSE overlay is unmounted, writing to `/mnt/gcs_secure` would otherwise fail or write to the root disk depending on directory permissions.

---

## 4. Debugging & Inspecting `/mnt/gcs_raw` vs. `/mnt/gcs_secure`

When troubleshooting on the Confidential VM, understanding the distinction between the upper mount (`/mnt/gcs_secure`) and the lower mount (`/mnt/gcs_raw`) is essential:

| Mount Path | Layer Role | What You See (`ls -la` / `cat`) | Developer Rule |
| :--- | :--- | :--- | :--- |
| **`/mnt/gcs_secure`** | **Upper Mount (`gocryptfs`)** | Plaintext filenames (`file.txt`) and decrypted file contents. | **Read and write all application files here.** |
| **`/mnt/gcs_raw`** | **Lower Mount (`gcsfuse`)** | Base64URL `AES-256-EME` obfuscated filenames, binary `AES-256-GCM` ciphertext, and `gocryptfs` metadata files. | **Read-only inspection for debugging ONLY. NEVER modify or delete files here.** |

### What You Will See Inside `/mnt/gcs_raw`
If you run `ls -la /mnt/gcs_raw` during debugging, **you will never see `file.txt` or any plaintext data**. Instead, you will observe:

1. **`gocryptfs.conf`:** The filesystem configuration header located at the root of `/mnt/gcs_raw` containing the encrypted master key blob wrapped by the ephemeral key.
2. **`gocryptfs.diriv`:** A 16-byte per-directory Initialization Vector file present in `/mnt/gcs_raw` and every subdirectory. It ensures that two files with the exact same plaintext name in different directories produce completely different encrypted filenames.
3. **Encrypted Filename Blobs (e.g., `oX5grluyzVGyQDGhA9c2qjGOy10WjRbZPduw5DNDi_E`):** Each application file appears as an opaque Base64URL string. Inspecting its contents (`cat` or `xxd`) reveals raw binary `AES-256-GCM` ciphertext (which is exactly 50 bytes larger than a small single-block plaintext file due to the 18-byte `gocryptfs` header, 16-byte block IV, and 16-byte GCM authentication tag).

### Diagnosing Integrity Errors (`EIO` / `Input/output error`)
If reading a file from `/mnt/gcs_secure` fails with `Errno 5 (Input/output error / EIO)`:
- **Cause:** `gocryptfs` detected that the underlying ciphertext block or GCM authentication tag in Google Cloud Storage (visible via `/mnt/gcs_raw`) was modified, truncated, or corrupted out-of-band.
- **Security Guarantee:** By design, `gocryptfs` refuses to return unauthenticated or tampered bytes to the application process.
