# Client-Side Encryption (CSE) within a Trusted Execution Environment (TEE) on Google Cloud

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](./LICENSE)

## 1. Overview

This repository provides production-grade reference architectures and automated deployment suites for implementing **Client-Side Encryption (CSE) inside Hardware-Enforced Trusted Execution Environments (TEEs)** on Google Cloud Platform (GCP).

In regulated enterprise and public-sector environments (such as PCI DSS v4.0, DORA, and sovereign cloud frameworks), organizations often require cryptographic guarantees that **sensitive data is encrypted before it leaves the compute boundary**—ensuring that the Cloud Storage Layer (`Google Cloud Storage`) only ever receives and stores authenticated ciphertext.

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
├── .github/workflows/
│   └── stage2-ci.yml                # Automated Stage 2 E2E validation via Workload Identity Federation
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
├── cicd/
│   ├── CICD_INTEGRATION_GUIDE.md    # STET artifact encryption & GitHub Actions WIF CI/CD guide
│   └── setup_github_wif.sh          # One-time Workload Identity Federation (WIF) bootstrap script
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

### 4.1 Step 1: Clone the Repository & Export Your GCP Project ID

Clone the repository, navigate into the project root directory, and export your target `PROJECT_ID` (all scripts dynamically construct Service Account emails, Cloud KMS URIs, and GCS bucket names from `${PROJECT_ID}`):

```bash
git clone https://github.com/vFawzi/gcs-confidential-client-side-encryption.git && cd gcs-confidential-client-side-encryption
```

```bash
export PROJECT_ID="your-project-id"
```

---

### 4.2 Stage 1: Stateless Envelope Encryption via HTTP Sidecar Proxy (Confidential GKE — Root `./`)

Stage 1 scripts reside at the **root of the repository**:

1. Copy the Stage 1 configuration template, make scripts executable, and update `DEPLOYER_PRINCIPAL` in `cse_config.env`:
   ```bash
   cp cse_config.env.example cse_config.env && chmod +x *.sh *.env
   ```
2. Bootstrap least-privilege deployer IAM roles, deploy the Confidential GKE cluster + Tink sidecar, and run the 4-step cross-pod verification suite:
   ```bash
   ./grant_deployer_iam.sh
   ```
   ```bash
   source ./cse_config.env && ./deploy_cse_gke.sh
   ```
   ```bash
   ./test_cse_gke.sh
   ```
3. Enforce Zero Standing Privileges (revoke deployer IAM) and run FinOps teardown when finished:
   ```bash
   ./revoke_deployer_iam.sh
   ```
   ```bash
   ./cleanup_cse_env.sh
   ```
4. **Stage 1 Documentation:**
   - **[Stage 1 Deployment Guide (`DEPLOYMENT_GUIDE.md`)](./DEPLOYMENT_GUIDE.md)** — Full operational runbook.
   - **[Stage 1 Developer Guide (`DEVELOPER_GUIDE.md`)](./DEVELOPER_GUIDE.md)** — GCS SDK endpoint override examples (`http://127.0.0.1:8080`) for Python, Go, and Node.js.

---

### 4.3 Stage 2: Transparent OS-Level Agent via `gocryptfs` + `gcsfuse` (Confidential VM — `./stage2/`)

Stage 2 scripts reside in the **`stage2/`** folder and operate 100% independently of Stage 1:

1. Navigate into `stage2/`, copy the Stage 2 configuration template, make scripts executable, and verify `DEPLOYER_PRINCIPAL` in `stage2_config.env`:
   ```bash
   cd stage2 && cp stage2_config.env.example stage2_config.env && chmod +x *.sh *.env
   ```
2. Bootstrap Stage 2 deployer IAM roles, deploy the AMD SEV Confidential VM + cryptographic FUSE overlay (`/mnt/gcs_secure` over `/mnt/gcs_raw`), and execute the 4-Stage Zero-Plaintext verification suite:
   ```bash
   ./grant_stage2_iam.sh
   ```
   ```bash
   ./deploy_cse_vm.sh
   ```
   ```bash
   ./test_cse_vm.sh
   ```
3. Enforce Zero Standing Privileges (revoke deployer IAM) and tear down all Stage 2 resources when finished:
   ```bash
   ./revoke_stage2_iam.sh
   ```
   ```bash
   ./cleanup_stage2.sh
   ```
4. **Stage 2 Documentation:**
   - **[Stage 2 Deployment Guide (`stage2/DEPLOYMENT_GUIDE.md`)](./stage2/DEPLOYMENT_GUIDE.md)** — Full Confidential VM & FUSE operational runbook.
   - **[Stage 2 Developer Guide (`stage2/DEVELOPER_GUIDE.md`)](./stage2/DEVELOPER_GUIDE.md)** — Stacked FUSE architecture, threat model, Runtime FUSE vs. CI/CD STET FAQ, and POSIX file I/O examples.

---

### 4.4 CI/CD Integration: Keyless Workload Identity Federation (WIF) & STET (`./cicd/`)

CI/CD automation assets reside in the **`cicd/`** folder and **[`.github/workflows/stage2-ci.yml`](./.github/workflows/stage2-ci.yml)**:

1. From the repository root, ensure `PROJECT_ID` and `GITHUB_REPO` are configured, make the CI/CD script executable, and run the one-time WIF bootstrap script [`cicd/setup_github_wif.sh`](./cicd/setup_github_wif.sh):
   ```bash
   export PROJECT_ID="your-project-id" && export GITHUB_REPO="owner/gcs-confidential-client-side-encryption" && chmod +x cicd/setup_github_wif.sh && ./cicd/setup_github_wif.sh
   ```
2. Configure the printed `PROJECT_ID`, `WIF_PROVIDER`, and `CI_SA_EMAIL` values in your GitHub repository under **Settings $\rightarrow$ Secrets and variables $\rightarrow$ Actions** (or via the `gh` CLI):
   ```bash
   gh secret set PROJECT_ID --body "${PROJECT_ID}" && gh secret set WIF_PROVIDER --body "<WIF_PROVIDER_OUTPUT>" && gh secret set CI_SA_EMAIL --body "cse-github-ci-sa@${PROJECT_ID}.iam.gserviceaccount.com"
   ```
3. Push to `main` (or trigger `workflow_dispatch` in the GitHub Actions UI) to automatically deploy the Stage 2 Confidential VM, run the 4-Stage Zero-Plaintext E2E test, and execute FinOps teardown (`if: always()`).
4. **CI/CD Documentation:**
   - **[CI/CD Integration Guide (`cicd/CICD_INTEGRATION_GUIDE.md`)](./cicd/CICD_INTEGRATION_GUIDE.md)** — Ephemeral runner encryption with Google's Split-Trust Encryption Tool (`stet`) and keyless GitHub Actions WIF E2E pipeline setup.
   - **[WIF Bootstrap Script (`cicd/setup_github_wif.sh`)](./cicd/setup_github_wif.sh)** — Automated Workload Identity Pool, OIDC Provider, and CI/CD Service Account bootstrap.

---

## 5. Security & Compliance Principles

- **Zero Standing Privileges (ZSP):** Both stages provide automated IAM grant (`grant_*.sh`) and revocation (`revoke_*.sh`) scripts so human/CI deployer principals hold elevated permissions only during active provisioning windows.
- **No Default Service Accounts:** Neither GKE nodes, Cloud Build jobs, nor Confidential VMs use the default Compute Engine service account.
- **Zero External IP Exposure:** All compute instances and GKE nodes are provisioned with `--no-address` / `--enable-private-nodes`, utilizing Private Google Access, Cloud NAT, and Identity-Aware Proxy (IAP) TCP forwarding.
- **EU Data Residency Ready:** Default configurations target `europe-west4` and enforce regional storage and cryptographic key boundaries.

---

## 6. License

This project is licensed under the **Apache License 2.0** — see the [LICENSE](./LICENSE) file for details.
