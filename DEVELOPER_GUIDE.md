# Developer Guide: Using the CSE Sidecar on Confidential GKE

## 1. Overview

The **Client-Side Encryption (CSE) Sidecar Proxy** (`cse-tink-sidecar`) provides transparent, zero-trust envelope encryption for workloads running on **Confidential Google Kubernetes Engine (GKE)** (`n2d-standard-2` AMD SEV Trusted Execution Environment nodes).

As an application developer, **you do not need to**:
- Manage or rotate cryptographic keys (KEKs or DEKs).
- Import or configure **Google Tink** in your application dependencies.
- Write custom AES-GCM encryption/decryption or Cloud KMS envelope logic.
- Manage GCP Service Account credentials for Cloud KMS or Cloud Storage inside your application code.

All cryptographic operations—generating ephemeral 256-bit `AES256_GCM` Data Encryption Keys (DEKs), wrapping/unwrapping DEKs via Cloud KMS (`cse-keyring-mvp/cse-proxy-key` in `europe-west4`), and authenticating via GKE Workload Identity (`cse-proxy-sa`)—are offloaded to the local sidecar container running inside the same Confidential GKE Pod.

To consume the sidecar, you only need to **override the Google Cloud Storage (GCS) SDK endpoint** (or point your HTTP client) to the local loopback proxy.

---

## 2. The "One Rule": Point Exclusively to `http://127.0.0.1:8080`

> **The One Rule:** The CSE Sidecar Proxy listens strictly on the pod-local loopback interface at **`http://127.0.0.1:8080`** (also injected into your container via the `PROXY_ENDPOINT` environment variable). All GCS SDK clients must be initialized with this custom API endpoint.

### Why `127.0.0.1:8080`?
1. **Hardware Memory Encryption in Use (AMD SEV):** By communicating strictly over `127.0.0.1` within the shared Kubernetes Pod network namespace, plaintext payloads remain inside AMD SEV-encrypted RAM and never traverse the VPC network in cleartext.
2. **Zero-Trust Identity Isolation:** Your application container does not need direct IAM permissions to Cloud KMS or Cloud Storage. The sidecar handles downstream GCP authentication using the Pod's Workload Identity Service Account (`default/cse-k8s-sa` $\rightarrow$ `cse-proxy-sa`).
3. **Stateless Cross-Pod Compatibility:** Any pod replica in `secure-app-deployment` can decrypt objects encrypted by any other pod replica, because the KMS-wrapped DEK is stored within the Tink ciphertext envelope in Cloud Storage.

---

## 3. Code Examples: Overriding the GCS SDK Endpoint

Below are production-ready examples in **Python**, **Go**, and **Node.js** demonstrating how to initialize the Google Cloud Storage SDK with the custom sidecar endpoint (`http://127.0.0.1:8080`) to upload and download files.

### 3.1 Python (`google-cloud-storage`)

Install the standard GCS client library:

```bash
pip install google-cloud-storage google-api-core
```

Initialize `storage.Client` using `ClientOptions(api_endpoint="http://127.0.0.1:8080")`:

```python
import os
from typing import Final
from google.api_core.client_options import ClientOptions
from google.api_core.exceptions import GoogleAPICallError, RetryError
from google.cloud import storage
from google.cloud.storage.retry import DEFAULT_RETRY

# The sidecar listens strictly on the pod loopback interface
PROXY_ENDPOINT: Final[str] = os.environ.get("PROXY_ENDPOINT", "http://127.0.0.1:8080")
PROJECT_ID: Final[str] = os.environ.get("PROJECT_ID", "your-project-id")
BUCKET_NAME: Final[str] = os.environ.get(
    "BUCKET_NAME", f"cse-prod-bucket-{PROJECT_ID}-2993"
)


def get_cse_storage_client(endpoint: str = PROXY_ENDPOINT) -> storage.Client:
    """Initializes a GCS client routed through the local CSE Tink Sidecar."""
    client_options = ClientOptions(api_endpoint=endpoint)
    return storage.Client(
        project=PROJECT_ID,
        client_options=client_options,
    )


def upload_sensitive_file(
    bucket_name: str,
    source_file_path: str,
    destination_blob_name: str,
) -> None:
    """Uploads a file via the local CSE sidecar for transparent envelope encryption."""
    client = get_cse_storage_client()
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(destination_blob_name)

    try:
        blob.upload_from_filename(
            source_file_path,
            retry=DEFAULT_RETRY,
            timeout=60,
        )
        print(f"Encrypted and uploaded {source_file_path} -> gs://{bucket_name}/{destination_blob_name}")
    except (GoogleAPICallError, RetryError) as exc:
        raise RuntimeError(
            f"CSE Sidecar upload failed for gs://{bucket_name}/{destination_blob_name}: {exc}"
        ) from exc


def download_sensitive_file(
    bucket_name: str,
    source_blob_name: str,
    destination_file_path: str,
) -> None:
    """Downloads and transparently decrypts an object via the local CSE sidecar."""
    client = get_cse_storage_client()
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(source_blob_name)

    try:
        blob.download_to_filename(
            destination_file_path,
            retry=DEFAULT_RETRY,
            timeout=60,
        )
        print(f"Downloaded and decrypted gs://{bucket_name}/{source_blob_name} -> {destination_file_path}")
    except (GoogleAPICallError, RetryError) as exc:
        raise RuntimeError(
            f"CSE Sidecar download failed for gs://{bucket_name}/{source_blob_name}: {exc}"
        ) from exc


if __name__ == "__main__":
    sample_file = "/tmp/wafer_telemetry.json"
    decrypted_file = "/tmp/wafer_telemetry_decrypted.json"
    object_key = "telemetry/wafer_telemetry.json.enc"

    with open(sample_file, "w", encoding="utf-8") as f:
        f.write('{"batch_id": "BATCH-EUV-9042", "classification": "STRICTLY_CONFIDENTIAL"}')

    upload_sensitive_file(BUCKET_NAME, sample_file, object_key)
    download_sensitive_file(BUCKET_NAME, object_key, decrypted_file)
```

> **Note on Direct Sidecar REST Endpoints (`v2` FastAPI Sidecar):**
> If your Python service uses lightweight HTTP calls (`httpx` or `requests`) instead of the full GCS JSON API, the sidecar also exposes direct streaming endpoints on `http://127.0.0.1:8080`:
> - **Encrypt & Upload:** `POST http://127.0.0.1:8080/upload/{bucket_name}/{blob_name}` (raw plaintext bytes in request body)
> - **Download & Decrypt:** `GET http://127.0.0.1:8080/download/{bucket_name}/{blob_name}` (returns decrypted bytes in response body)

---

### 3.2 Go (`cloud.google.com/go/storage`)

Install the Go Cloud Storage and API option packages:

```bash
go get cloud.google.com/go/storage google.golang.org/api/option
```

Initialize `storage.NewClient` using `option.WithEndpoint("http://127.0.0.1:8080")` and `option.WithoutAuthentication()` (because the sidecar proxy authenticates to Cloud KMS and GCS via GKE Workload Identity on the Pod's behalf):

```go
package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"time"

	"cloud.google.com/go/storage"
	"google.golang.org/api/option"
)

const (
	defaultProxyEndpoint = "http://127.0.0.1:8080"
	defaultBucketName    = "cse-prod-bucket-your-project-id-2993"
)

// newCSEStorageClient initializes a GCS client pointed strictly at the local CSE sidecar.
func newCSEStorageClient(ctx context.Context) (*storage.Client, error) {
	endpoint := os.Getenv("PROXY_ENDPOINT")
	if endpoint == "" {
		endpoint = defaultProxyEndpoint
	}

	// The local sidecar handles downstream Workload Identity authentication to KMS and GCS.
	// If your sidecar configuration passes client bearer tokens through, omit option.WithoutAuthentication().
	client, err := storage.NewClient(
		ctx,
		option.WithEndpoint(endpoint),
		option.WithoutAuthentication(),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create CSE storage client: %w", err)
	}
	return client, nil
}

func uploadFile(ctx context.Context, client *storage.Client, bucketName, objectName, filePath string) error {
	f, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("os.Open: %w", err)
	}
	defer f.Close()

	uploadCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	wc := client.Bucket(bucketName).Object(objectName).NewWriter(uploadCtx)
	if _, err := io.Copy(wc, f); err != nil {
		_ = wc.Close()
		return fmt.Errorf("io.Copy: %w", err)
	}
	if err := wc.Close(); err != nil {
		return fmt.Errorf("Writer.Close: %w", err)
	}

	log.Printf("Encrypted and uploaded %s -> gs://%s/%s", filePath, bucketName, objectName)
	return nil
}

func downloadFile(ctx context.Context, client *storage.Client, bucketName, objectName, destPath string) error {
	downloadCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	rc, err := client.Bucket(bucketName).Object(objectName).NewReader(downloadCtx)
	if err != nil {
		return fmt.Errorf("Object(%q).NewReader: %w", objectName, err)
	}
	defer rc.Close()

	outFile, err := os.Create(destPath)
	if err != nil {
		return fmt.Errorf("os.Create: %w", err)
	}
	defer outFile.Close()

	if _, err := io.Copy(outFile, rc); err != nil {
		return fmt.Errorf("io.Copy: %w", err)
	}

	log.Printf("Downloaded and decrypted gs://%s/%s -> %s", bucketName, objectName, destPath)
	return nil
}

func main() {
	ctx := context.Background()
	client, err := newCSEStorageClient(ctx)
	if err != nil {
		log.Fatalf("Initialization error: %v", err)
	}
	defer client.Close()

	bucketName := defaultBucketName
	objectName := "telemetry/wafer_batch_01.bin.enc"
	sourceFile := "/tmp/wafer_batch_01.bin"
	destFile := "/tmp/wafer_batch_01_decrypted.bin"

	if err := os.WriteFile(sourceFile, []byte("CONFIDENTIAL_EUV_CALIBRATION_DATA"), 0600); err != nil {
		log.Fatalf("WriteFile error: %v", err)
	}

	if err := uploadFile(ctx, client, bucketName, objectName, sourceFile); err != nil {
		log.Fatalf("Upload failed: %v", err)
	}

	if err := downloadFile(ctx, client, bucketName, objectName, destFile); err != nil {
		log.Fatalf("Download failed: %v", err)
	}
}
```

---

### 3.3 Node.js (`@google-cloud/storage`)

Install the official Node.js GCS SDK:

```bash
npm install @google-cloud/storage
```

Pass `{ apiEndpoint: 'http://127.0.0.1:8080' }` into `new Storage()`:

```javascript
'use strict';

const { Storage } = require('@google-cloud/storage');
const fs = require('fs');

const PROXY_ENDPOINT = process.env.PROXY_ENDPOINT || 'http://127.0.0.1:8080';
const PROJECT_ID = process.env.PROJECT_ID || 'your-project-id';
const BUCKET_NAME = process.env.BUCKET_NAME || `cse-prod-bucket-${PROJECT_ID}-2993`;

// Initialize the GCS SDK pointing strictly to the in-pod CSE Sidecar
const storage = new Storage({
  projectId: PROJECT_ID,
  apiEndpoint: PROXY_ENDPOINT,
});

async function uploadEncryptedFile(bucketName, localFilePath, destinationBlobName) {
  await storage.bucket(bucketName).upload(localFilePath, {
    destination: destinationBlobName,
    resumable: false,
  });
  console.log(`Encrypted and uploaded ${localFilePath} -> gs://${bucketName}/${destinationBlobName}`);
}

async function downloadDecryptedFile(bucketName, sourceBlobName, destinationFilePath) {
  await storage
    .bucket(bucketName)
    .file(sourceBlobName)
    .download({ destination: destinationFilePath });
  console.log(`Downloaded and decrypted gs://${bucketName}/${sourceBlobName} -> ${destinationFilePath}`);
}

async function main() {
  const sampleFile = '/tmp/litho_recipe.json';
  const decryptedFile = '/tmp/litho_recipe_decrypted.json';
  const destinationBlob = 'recipes/litho_recipe.json.enc';

  fs.writeFileSync(
    sampleFile,
    JSON.stringify({ recipeId: 'EUV-NXE-3800E', status: 'CONFIDENTIAL' })
  );

  await uploadEncryptedFile(BUCKET_NAME, sampleFile, destinationBlob);
  await downloadDecryptedFile(BUCKET_NAME, destinationBlob, decryptedFile);
}

main().catch((err) => {
  console.error('CSE Sidecar operation failed:', err);
  process.exit(1);
});
```

---

## 4. Local Testing Limitations (TEE & Pod Network Boundary)

> **WARNING: You CANNOT connect to `http://127.0.0.1:8080` from your local laptop, workstation, or IDE.**

### Why Local Laptop Testing Fails by Design
1. **Strict Trusted Execution Environment (TEE) Boundary:** The CSE Sidecar (`cse-tink-sidecar`) runs exclusively inside a Confidential GKE Pod (`cse-confidential-cluster`) backed by AMD SEV hardware-encrypted memory. It does not exist on your local machine's `127.0.0.1:8080`, nor is it exposed via a Kubernetes `Service`, `Ingress`, or external load balancer.
2. **Loopback-Only Binding (`--host 127.0.0.1`):** Even within the GKE cluster, the sidecar binds strictly to `127.0.0.1:8080` inside the Pod's network namespace. Other pods on the same node or VPC cannot reach your pod's sidecar over the network; only containers co-located within the **same Pod** (such as `main-application`) can communicate with it.
3. **Workload Identity Binding:** The sidecar relies on the GKE metadata server (`169.254.169.254`) and Workload Identity federation (`your-project-id.svc.id.goog[default/cse-k8s-sa]` $\rightarrow$ `cse-proxy-sa@your-project-id.iam.gserviceaccount.com`) to obtain short-lived OAuth2 tokens for Cloud KMS (`roles/cloudkms.cryptoKeyEncrypterDecrypter`) and GCS (`roles/storage.objectAdmin`).

### Recommended Development & Testing Workflow
- **Local Unit Tests:** Make the `api_endpoint` configurable via the `PROXY_ENDPOINT` environment variable. In local unit tests outside GKE, either mock the GCS client or point `PROXY_ENDPOINT` to a local mock server (`fake-gcs-server`).
- **Integration Testing in Confidential GKE (Cloud Shell):** To validate end-to-end encryption and decryption against real Cloud KMS and GCS resources, execute your code inside the deployed GKE Pod (`secure-app-deployment`) or run the Cloud Shell validation suite (`./test_cse_gke.sh`).
