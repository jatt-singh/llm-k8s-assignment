# Model delivery

## What runs

| | |
|---|---|
| Model | **Qwen2.5-0.5B-Instruct** (494M parameters, instruction-tuned) |
| Format | GGUF, `Q4_K_M` quantisation (~470 MB on disk, ~0.6 GB RSS with a 2k context) |
| Source | https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF |
| File | `qwen2.5-0.5b-instruct-q4_k_m.gguf` |
| Pinned revision | `9217f5db79a29953eb74d5343926648285ec7e67` (repo commit, not `main`) |
| SHA-256 | `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db` |
| Size | 491,400,032 bytes |
| Model license | **Apache-2.0** (`LICENSE` file in the HF repo; `license: apache-2.0` in the model card) |
| Runtime | llama.cpp `llama-server`, build **b11223** (2026-09-28), image `ghcr.io/ggml-org/llama.cpp:server-b11223@sha256:8fdfad18…64ed` |
| Runtime license | **MIT** |

Why GGUF Q4_K_M on llama.cpp instead of the safetensors model on vLLM or TGI: on CPU, llama.cpp with a 4-bit quant is the fastest and smallest option, about 1/4 the memory of the FP16 weights. It needs no Python or PyTorch, and it ships an OpenAI-compatible API, health and metrics endpoints, and API-key auth. The quantised GGUF is published by the Qwen team in its own repo, so this is not a third-party conversion.

## How the pinned values were obtained

```bash
# Revision (commit sha) of the repo
curl -s https://huggingface.co/api/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF | jq -r .sha
# SHA-256 of the file at that revision (Git LFS object id = sha256 of content)
curl -s https://huggingface.co/api/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/tree/9217f5db79a29953eb74d5343926648285ec7e67 \
  | jq -r '.[] | select(.path=="qwen2.5-0.5b-instruct-q4_k_m.gguf") | .lfs.oid'
```

To bump the model, change `model.revision`, `model.sha256` (and `model.file` if needed) in `deploy/helm/llm-app/values.yaml`. Nothing else needs to change.

## How the weights reach the cluster

```
Hugging Face ──HTTPS──▶ Job model-download-<rev8>-<sha8> ──▶ PVC model-store ──(read-only)──▶ llm pod
  (one time)            curl + sha256sum                     /models/<revision>/<file>      /models/...
```

1. The Helm release creates the PVC `model-store` (2 Gi, `helm.sh/resource-policy: keep`) and the Job.
2. The Job (`curlimages/curl` pinned by digest, non-root, read-only rootfs) downloads `resolve/<revision>/<file>` to a `.part` file. It then **verifies the SHA-256**. On a match it renames the file and writes a `.verified` marker. On a mismatch it deletes the file and fails. The Job is idempotent: if a verified file is already present it exits immediately.
3. The `llm` pod has an init container that waits for the `.verified` marker, then starts `llama-server` with the PVC mounted **read-only**.
4. NetworkPolicy `model-download` is the only rule in the namespace that allows egress outside the cluster. It allows TCP 443 to public IPs only (RFC 1918 and link-local are excluded).

Hugging Face is **not a runtime dependency**. Once the file is on the volume, the LLM pod has no egress at all, and inference keeps working with the internet disconnected.

The weights are never in an image. `llm/Dockerfile` only adds `USER 65532` to the upstream server image.

## Ongoing verification (CronJob `model-verify`)

- Schedule: `0 3 * * *`, `timeZone: Etc/UTC`, `concurrencyPolicy: Forbid`.
- It re-computes the SHA-256 of the file on the volume and sends three fixed prompts to the LLM with `temperature 0`: "capital of France" → `Paris`, "2 plus 2" → `4`, "reply pong" → `pong`.
- It logs JSON results (in Loki under `{namespace="llm-app", app="model-verify"}`) and exits non-zero on any failure.
- Monitored by the alerts `ModelVerifyJobFailed` and `ModelVerifyNotSucceededRecently` (26h), and by the "model-verify last success" panel in Grafana.
- `scripts/ci.sh cronjob-check <env>` runs it on demand and fails the release if it fails.
