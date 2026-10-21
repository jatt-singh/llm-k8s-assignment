# Demo guide: step by step

A copy-paste script for the live demo. Every step shows the **make shortcut** and the **raw commands** behind it, plus **what to say**. Run everything from the repo root.

---

## 0. Before the call (~15 min, do it early)

```bash
cd /Users/kubemac/work/project/self-task/assignment
open -a Docker                      # Docker Desktop must be running (6+ GB memory)
make apply ENV=dev                  # creates the Kind cluster + platform (skip if already up)
make release ENV=dev                # build, scan, SBOM, deploy, smoke test, cronjob check
export KUBECONFIG=$PWD/.kube/llm-dev.yaml
kubectl -n llm-app get pods         # all Running, model-download Completed
```

Keep two terminals open: one for commands, one for `kubectl -n llm-app get pods -w`.

---

## 1. Architecture (2 min, talk only)

Open `README.md` and show the diagram.

> "Three Go microservices and a llama.cpp server running Qwen2.5-0.5B on CPU. Only the gateway is exposed, through Traefik with TLS and an IP allowlist. Everything else is ClusterIP behind default-deny network policies. Terraform builds the cluster and platform, and Helm deploys the app. One bash script is the CI/CD pipeline."

## 2. Infrastructure as Code: plan and apply

```bash
make plan ENV=dev
# raw:
cd infra/terraform
export TF_DATA_DIR=.terraform-dev
terraform init -reconfigure -backend-config=envs/dev.backend.hcl
terraform plan -var-file=envs/dev.tfvars
cd ../..
```

> "Same code for every environment. Only the tfvars and the state file differ. dev has state/dev.tfstate and prod has state/prod.tfstate, so they can never touch each other."

Show `infra/terraform/envs/` (dev.tfvars, prod.tfvars). **Third env:** copy the two env files plus a values file, as described in README §Environments.

## 3. One-command pipeline

```bash
make release ENV=dev
```

> "check mode runs lint, unit tests, build, a Trivy scan with a CRITICAL gate, and SBOMs. release mode adds terraform apply, loads images into Kind, runs helm upgrade --atomic, a smoke test through TLS, and the CronJob check. Release refuses to run unless I'm on main or a tag."

Show the gate code in `scripts/ci.sh` (the `scan()` function) and the reports in `reports/`.

## 4. End to end through TLS, reaching the LLM

```bash
curl --cacert .kube/llm-dev-ca.pem --resolve app.dev.llmstack.local:8443:127.0.0.1 \
  -H 'Content-Type: application/json' \
  -d '{"question":"Summarize this item","item_id":"item-1"}' \
  https://app.dev.llmstack.local:8443/api/v1/ask

curl --cacert .kube/llm-dev-ca.pem --resolve app.dev.llmstack.local:8443:127.0.0.1 \
  https://app.dev.llmstack.local:8443/api/v1/items
```

> "The request goes gateway → assistant, which fetches item-1 from the catalog for context, then calls the LLM with an API key from a Kubernetes Secret."

## 5. Blocked source + network policies

```bash
make demo-blocked ENV=dev      # laptop = 200, another host = 403
make demo-netpol  ENV=dev      # only allowed service-to-service paths connect
```

> "The allowlist is a Traefik middleware. Docker forwards my laptop's traffic from 172.24.0.1, which is allowed. Another machine on the same network gets 403. Inside the cluster, a pod with no matching rule can reach nothing, and only the download job can reach the internet."

## 6. Autoscaling

```bash
kubectl -n llm-app get hpa,pdb
make demo-hpa ENV=dev          # gateway goes 1 → 3 replicas
```

> "HPA on CPU at 70%, a PDB on every deployment, and rolling updates with maxUnavailable 0. For the LLM I would scale on queue depth with KEDA rather than CPU, because CPU is always at 100% while generating."

## 7. Scheduled job

```bash
kubectl -n llm-app get cronjob model-verify       # schedule 0 3 * * * UTC
make cronjob-check ENV=dev
# raw:
kubectl -n llm-app create job verify-now --from=cronjob/model-verify
kubectl -n llm-app logs -f job/verify-now
```

> "Every day it re-checks the model SHA-256 and runs 3 fixed prompts. If it fails, the ModelVerifyJobFailed alert fires."

## 8. Observability and alert

```bash
scripts/demo/dashboards.sh dev     # Grafana :3000, Prometheus :9090, Alertmanager :9093
# Grafana password (do not paste it in chat):
(cd infra/terraform && TF_DATA_DIR=.terraform-dev terraform output -raw grafana_admin_password)
```

In Grafana, open the dashboard **LLM Stack - Overview** (uptime, error rate, latency, HPA, job status, logs).

```bash
make demo-alert ENV=dev            # LLM scaled to 0 → 5xx → alerts fire (~3-4 min)
```

Verified while preparing: with the LLM at 0 replicas, `LLMUnavailable` went **firing** after 2 min and Alertmanager routed it to the `incident-channel` receiver. Quick manual version:

```bash
kubectl -n llm-app scale deploy/llm --replicas=0
# wait ~2-3 min, then open http://localhost:9090/alerts (dashboards.sh) or:
kubectl get --raw "/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1/alerts" | jq '.data.alerts[] | {alert: .labels.alertname, state}'
kubectl -n llm-app scale deploy/llm --replicas=1     # restore
```

> "Alertmanager routes to an incident-channel receiver. The Slack or PagerDuty webhook URL is a Secret set via TF_VAR_incident_webhook_url, so it is never in Git or logs."

## 9. Bad release and rollback

```bash
make demo-bad-release ENV=dev
# raw:
helm -n llm-app upgrade llm-app deploy/helm/llm-app --reuse-values \
  --set services.gateway.imageTag=does-not-exist --wait --timeout 60s
kubectl -n llm-app get pods        # new pod ImagePullBackOff, old pods still Running
helm -n llm-app history llm-app
helm -n llm-app rollback llm-app
```

> "maxUnavailable 0 means the broken version never takes traffic. In the release path --atomic would roll back automatically."

## 10. Destroy and recreate (only if asked; ~10 min)

```bash
make destroy ENV=dev && kind get clusters
make apply ENV=dev && make deploy ENV=dev && make smoke ENV=dev
```

---

## Likely questions and short answers

| Question | Answer |
|---|---|
| Why Kind, not minikube? | The brief names Kind. It runs nodes as Docker containers, supports multi-node, and has a Terraform provider |
| Why Traefik, not nginx? | ingress-nginx is retired upstream. Traefik has a built-in IP allowlist |
| Why llama.cpp? | CPU-optimised, 4-bit model is ~470 MB, OpenAI-compatible API, no Python stack |
| Why Go services? | Static binaries on distroless, ~21 MB, almost no CVEs, so the gate is realistic |
| Where are secrets? | Generated by Terraform into K8s Secrets, never in Git. Cloud: Secrets Manager + External Secrets Operator |
| Image signing? | Documented, not implemented (no registry). Cloud: cosign with a KMS key + Kyverno verifyImages |
| How to add staging? | 2 Terraform env files + 1 Helm values file, no code change |
| How does it map to cloud? | `docs/CLOUD_PORTABILITY.md`: EKS, ECR, ALB + ACM, EBS/EFS, CloudWatch, S3 state |
| How did you use AI? | `AI_USAGE.md`, with the bugs testing caught: alert ratio diluted by health checks, CI tag changing mid-run, a loop variable leaking so release hit the wrong env |
| What would you do next? | Local registry + signing, KEDA for the LLM, cert-manager, canary rollouts, SLO burn-rate alerts |
