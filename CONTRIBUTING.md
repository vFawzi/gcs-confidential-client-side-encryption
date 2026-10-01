# Contributing Guidelines

Thank you for your interest in contributing to the **Confidential Computing Client-Side Encryption (CSE)** reference architecture suite. This document outlines the standards and workflow for submitting issues and pull requests.

---

## 1. Security & Sanitization Standards (CRITICAL)

Before opening an issue or submitting a pull request, verify that your changes strictly adhere to the following security and privacy baselines:

1. **Zero Customer or Environment Secrets:**
   - **NEVER** commit real Google Cloud Project IDs, organization IDs, billing accounts, internal LDAPs/emails, cryptographic keys, or customer-identifiable names.
   - Always use sanitized placeholders (`your-project-id`, `user@example.com`) inside `*.env.example` templates and Markdown documentation.
   - Active configuration files (`cse_config.env`, `stage2/stage2_config.env`) must remain untracked in version control.
2. **Principle of Least Privilege (IAM):**
   - Never introduce broad primitive roles (`roles/owner`, `roles/editor`, `roles/viewer`) or default Compute Engine service accounts.
   - Any new IAM role added to `grant_deployer_iam.sh` or `stage2/grant_stage2_iam.sh` **must** have a matching removal entry in `revoke_deployer_iam.sh` or `stage2/revoke_stage2_iam.sh`.
3. **Architectural Decoupling:**
   - Maintain a strict separation between **Stage 1** (`v2/` — Confidential GKE Sidecar Proxy) and **Stage 2** (`v2/stage2/` — Confidential VM OS-Level Agent). Each stage must remain 100% independently configurable, deployable, testable, and tear-down capable.
4. **Defensive Shell Scripting:**
   - All Bash scripts must begin with `set -euo pipefail`.
   - Validate all modified scripts with `bash -n <script.sh>` and `shellcheck` prior to submitting a pull request.

---

## 2. Pull Request Process

1. **Branching:** Create a descriptive feature or bugfix branch from `main` (e.g., `feat/stage1-cmek-rotation` or `fix/stage2-fuse-unmount`).
2. **Configuration Templates:** If introducing a new environment variable, add it with a sanitized default to `cse_config.env.example` or `stage2/stage2_config.env.example` and document it in the corresponding `DEPLOYMENT_GUIDE.md` table.
3. **Validation Checklist:**
   - [ ] `bash -n` passes on all `.sh` and `.env.example` files.
   - [ ] End-to-end verification suite (`./test_cse_gke.sh` or `./stage2/test_cse_vm.sh`) passes all security assertions in an isolated test project.
   - [ ] Post-deployment IAM revocation (`./revoke_deployer_iam.sh` or `./stage2/revoke_stage2_iam.sh`) and FinOps teardown (`./cleanup_cse_env.sh` or `./stage2/cleanup_stage2.sh`) execute cleanly.
   - [ ] `grep` confirms zero real Project IDs, LDAPs, or credentials exist in the diff.
4. **Review:** Submit your Pull Request with a clear summary of architectural trade-offs, security implications, and verification output.

---

## 3. Reporting Issues & Security Concerns

- **Bug Reports & Feature Requests:** Open an issue in the repository tracker detailing:
  - Target Stage (Stage 1 GKE Sidecar or Stage 2 Confidential VM Agent).
  - Steps to reproduce (with sanitized logs—strip all project numbers and user identities).
  - Expected vs. actual behavior.
- **Security Vulnerabilities:** Do **not** disclose potential cryptographic, IAM, or TEE isolation vulnerabilities in public issue trackers. Report security findings directly to the repository maintainers via internal security channels.
