# Client-Side Encryption (CSE) within a Trusted Execution Environment (TEE) on Google Cloud

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](./LICENSE)

## 1. Overview

This repository provides production-grade reference architectures and automated deployment suites for implementing **Client-Side Encryption (CSE) inside Hardware-Enforced Trusted Execution Environments (TEEs)** on Google Cloud Platform (GCP).

In regulated enterprise and public-sector environments (such as BIO, PCI DSS v4.0, DORA, and sovereign cloud frameworks), organizations often require cryptographic guarantees that **sensitive data is encrypted before it leaves the compute boundary**—ensuring that the Cloud Storage Layer (`Google Cloud Storage`) only ever receives and stores authenticated ciphertext.

By combining **Google Cloud Confidential Computing** (**AMD SEV** hardware memory encryption on `n2d-standard-2` instances with **Shielded VM** `Secure Boot`, `vTPM`, and `Integrity Monitoring`) with client-side cryptographic primitives, this suite protects sensitive workloads across all three data states:
- **Data in Use:** Protected in RAM via AMD Secure Encrypted Virtualization (SEV) hardware memory encryption.
- **Data in Transit:** Encrypted at the application/OS layer prior to TLS 1.3 transport over Private Google Access.
- **Data at Rest:** Stored exclusively as `AES-256-GCM` authenticated ciphertext in Google Cloud Storage (GCS), with zero plaintext content or metadata exposed to the storage control plane.

---

## 2. Architectural Patterns: Stage 1 vs. Stage 2

This repository contains two **100% independent, self-contained** CSE reference implementations designed for different application modernization profiles:

| Dimension | Stage 1: Stateless HTTP Sidecar Proxy (`v2/`) | Stage 2: Transparent OS-Level Agent (`v2/stage2/`) |
| :--- | :--- | :--- |
| **Target Workload Profile** | **Modern Cloud-Native & Containerized Applications** that use HTTP REST APIs or Google Cloud Storage SDKs (Python, Go, Node.js). | **Legacy POSIX Applications & Commercial Off-The-Shelf (COTS) Binaries** that read/write local filesystem paths and cannot be refactored. |
| **Compute TEE Platform** | **Confidential GKE** (`n2d-standard-2` AMD SEV Private Nodes, Shielded GKE Nodes, Workload Identity). | **Confidential Compute Engine VM** (`n2d-standard-2` AMD SEV, Shielded VM, No External IP, IAP SSH Tunneling). |
| **Cryptographic Engine** | **Google Tink (`KmsEnvelopeAead`)** running inside a pod-local FastAPI sidecar bound strictly to `http://127.0.0.1:8080`. | **`gocryptfs` + `gcsfuse` Stacked FUSE Overlay** (`/mnt/gcs_secure` plaintext POSIX view layered over `/mnt/gcs_raw` ciphertext mount). |
| **Cipher & Metadata Protection** | `AES256_GCM` Envelope Encryption (unique DEK per object wrapped by Cloud KMS KEK + URI Associated Data binding). | `AES-256-GCM` 4 KB block content encryption + `AES-256-EME` wide-block filename encryption with per-directory IVs (`gocryptfs.diriv`). |
| **Key Management & Lifecycle** | Stateless KMS Envelope AEAD via GKE Workload Identity (`roles/cloudkms.cryptoKeyEncrypterDecrypter`). Any pod replica can decrypt objects written by any other pod. | Ephemeral DEK injected strictly into AMD SEV RAM-backed `tmpfs` (`/run/cse_keys/dek.pass`) at mount time and immediately destroyed via `shred -u`. |
| **Identity Isolation** | 3-Way Zero-Trust Service Account separation (`cse-proxy-sa`, `cse-gke-node-sa`, `cse-build-sa`) + post-deployment deployer IAM revocation. | Dedicated VM Service Account (`cse-vm-sa`) with bucket-scoped `roles/storage.objectAdmin` + post-deployment deployer IAM revocation. |

---

## 3. Repository Structure

```text
gcs-confidential-client-side-encryption/
├── .gitignore                       # Ignores active *.env files while tracking *.env.example
├── README.md                        # Architectural overview & repository landing page
├── DEPLOYMENT_GUIDE.md              # Stage 1 (Confidential GKE Sidecar Proxy) operational runbook
├── DEVELOPER_GUIDE.md               # Stage 1 developer SDK integration guide (Python, Go, Node.js)
├── CONTRIBUTING.md                  # Contribution, PR, and security reporting guidelines
├── LICENSE                          # Apache 2.0 License
├── cse_config.env.example           # Stage 1 sanitized configuration template
├── grant_deployer_iam.sh            # Stage 1 least-privilege IAM bootstrap script
├── deploy_cse_gke.sh                # Stage 1 automated Confidential GKE & sidecar deployment
├── test_cse_gke.sh                  # Stage 1 4-step cross-pod E2E verification suite
├── revoke_deployer_iam.sh           # Stage 1 post-deployment IAM revocation script (Zero Standing Privilege)
├── cleanup_cse_env.sh               # Stage 1 FinOps infrastructure teardown script
└── stage2/
    ├── DEPLOYMENT_GUIDE.md          # Stage 2 (Confidential VM OS-Level Agent) operational runbook
    ├── DEVELOPER_GUIDE.md           # Stage 2 architecture, threat model & POSIX developer guide
    ├── stage2_config.env.example    # Stage 2 sanitized configuration template
    ├── grant_stage2_iam.sh          # Stage 2 least-privilege IAM bootstrap script
    ├── deploy_cse_vm.sh             # Stage 2 automated Confidential VM & FUSE overlay deployment
    ├── test_cse_vm.sh               # Stage 2 4-stage zero-plaintext verification suite
    ├── revoke_stage2_iam.sh         # Stage 2 post-deployment IAM revocation script (Zero Standing Privilege)
    └── cleanup_stage2.sh            # Stage 2 FinOps infrastructure teardown script
```

---

## 4. Quick Start & Documentation Links

### Stage 1: Stateless Envelope Encryption via HTTP Sidecar Proxy (Confidential GKE)
1. Copy the configuration template and populate your target GCP Project ID and deployer identity:
   ```bash
   cp cse_config.env.example cse_config.env
   ```
2. Follow the complete operational lifecycle in the **[Stage 1 Deployment Guide](./DEPLOYMENT_GUIDE.md)**.
3. Review SDK integration patterns (Python, Go, Node.js) in the **[Stage 1 Developer Guide](./DEVELOPER_GUIDE.md)**.

### Stage 2: Transparent OS-Level Agent via `gocryptfs` + `gcsfuse` (Confidential VM)
1. Copy the Stage 2 configuration template and populate your target GCP Project ID and deployer identity:
   ```bash
   cp stage2/stage2_config.env.example stage2/stage2_config.env
   ```
2. Follow the complete operational lifecycle in the **[Stage 2 Deployment Guide](./stage2/DEPLOYMENT_GUIDE.md)**.
3. Review the OS-level FUSE overlay architecture, threat model, and POSIX integration patterns in the **[Stage 2 Developer Guide](./stage2/DEVELOPER_GUIDE.md)**.

---

## 5. Security & Compliance Principles

- **Zero Standing Privileges (ZSP):** Both stages provide automated IAM grant (`grant_*.sh`) and revocation (`revoke_*.sh`) scripts so human/CI deployer principals hold elevated permissions only during active provisioning windows.
- **No Default Service Accounts:** Neither GKE nodes, Cloud Build jobs, nor Confidential VMs use the default Compute Engine service account.
- **Zero External IP Exposure:** All compute instances and GKE nodes are provisioned with `--no-address` / `--enable-private-nodes`, utilizing Private Google Access, Cloud NAT, and Identity-Aware Proxy (IAP) TCP forwarding.
- **EU Data Residency Ready:** Default configurations target `europe-west4` and enforce regional storage and cryptographic key boundaries.

---

## 6. License

This project is licensed under the **Apache License 2.0** — see the [LICENSE](./LICENSE) file for details.
