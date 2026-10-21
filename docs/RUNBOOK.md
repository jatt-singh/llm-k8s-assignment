# Runbook

All commands run from the repository root. `ENV` is `dev` or `prod` (or any environment with `infra/terraform/envs/<env>.tfvars`).

- [1. Prerequisites](#1-prerequisites)
- [2. Infrastructure: plan, apply](#2-infrastructure-plan-apply)
- [3. Deploy the application](#3-deploy-the-application)
- [4. Verification / live demo](#4-verification--live-demo)
- [5. Rollback](#5-rollback)
- [6. Teardown and recreate](#6-teardown-and-recreate)
- [7. Alert runbooks](#7-alert-runbooks)
- [8. Troubleshooting](#8-troubleshooting)

---

## 1. Prerequisites

- Docker Desktop (or Docker Engine) running, with **≥ 4 CPUs and ≥ 6 GB memory** for one environment (Settings → Resources), or ~10 GB for dev and prod together.
- Tools: `brew install kind terraform helm kubectl trivy syft cosign shellcheck hadolint go`
- Internet access for the first run: base images, Helm charts, Terraform providers, and the ~470 MB model from Hugging Face.
- Free host ports: `8443` (dev) and `9443` (prod), bound to 127.0.0.1 only.

```bash
docker info --format 'CPUs={{.NCPU}} Mem={{.MemTotal}}'
make help
```

## 2. Infrastructure: plan, apply

```bash
make plan  ENV=dev     # terraform init (dev backend) + plan -out dev.tfplan
make apply ENV=dev     # plan + apply that saved plan
```

What gets created: the Kind cluster `llm-dev`, namespaces `ingress` / `monitoring` / `llm-app` (with PSS labels), Traefik, metrics-server, kube-prometheus-stack, Loki, Alloy, the Secrets `llm-api-key`, `gateway-tls`, `grafana-admin`, `incident-webhook`, and the files `.kube/llm-dev.yaml` (kubeconfig) and `.kube/llm-dev-ca.pem` (TLS cert for curl).

The first apply takes ~6-10 min (image pulls). Later plans show *No changes*.

Under the hood (equivalent manual commands):

```bash
cd infra/terraform
export TF_DATA_DIR=.terraform-dev                       # separate provider/plugin dir per env
terraform init -reconfigure -backend-config=envs/dev.backend.hcl   # state -> state/dev.tfstate
terraform plan  -var-file=envs/dev.tfvars -out=dev.tfplan
terraform apply dev.tfplan
```

Use the cluster: `export KUBECONFIG=$PWD/.kube/llm-dev.yaml`

## 3. Deploy the application

**One-time per environment: allowlist the laptop's source address.** Docker Desktop forwards `127.0.0.1:8443` into the Kind node from its own gateway address, so that is the IP Traefik sees. Detect it once:

```bash
curl -sk --resolve app.dev.llmstack.local:8443:127.0.0.1 https://app.dev.llmstack.local:8443/ -o /dev/null   # 404 from Traefik, but it is logged
scripts/ci.sh detect-source-ip dev        # writes .kube/allowed-cidrs-dev (e.g. 192.168.65.1/32)
```

Or set it explicitly: `export ALLOWED_CIDRS=10.0.0.0/8,192.168.65.1/32`.

**Deploy:**

```bash
make check                 # builds images tagged with the git sha
make deploy ENV=dev        # kind load + helm upgrade --install --atomic --wait (first time: ~3-5 min for the model download)
make status ENV=dev
```

**Or the full release pipeline** (main branch / tag only):

```bash
make release ENV=dev
```

## 4. Verification / live demo

Run in this order for the interview demo (~15 min).

| # | Demo item | Command | Expected |
|---|---|---|---|
| 1 | IaC plan + apply | `make plan ENV=dev` then `make apply ENV=dev` | plan output; `No changes` if already applied |
| 2 | One-command build + deploy | `make release ENV=dev` | check → apply → load → deploy → smoke → cronjob, all ✓ |
| 3 | End to end via TLS incl. LLM | `make smoke ENV=dev` (or the curl below) | `{"answer":"...","item_id":"item-1",...}` |
| 4 | Disallowed source blocked | `make demo-blocked ENV=dev` | laptop `HTTP 200`, other host `HTTP 403` |
| 5 | HPA | `kubectl -n llm-app get hpa`, then `make demo-hpa ENV=dev` | replicas rise above the minimum under load |
| 6 | Scheduled job | `make cronjob-check ENV=dev` | JSON log lines `"result":"pass"`, job Complete |
| 7 | Alert rule loaded / firing | `make demo-alert ENV=dev` (~5 min) | rules listed; `GatewayHighErrorRate: firing` |
| 8 | Rollback of a bad release | `make demo-bad-release ENV=dev` | new pod `ErrImagePull`, old pods serve 200, rollback → healthy |
| 9 | Destroy + recreate | `make destroy ENV=dev && make apply ENV=dev && make deploy ENV=dev` | see §6 |

Manual end-to-end request:

```bash
curl --cacert .kube/llm-dev-ca.pem --resolve app.dev.llmstack.local:8443:127.0.0.1 \
  -H 'Content-Type: application/json' \
  -d '{"question":"Summarize this item","item_id":"item-1"}' \
  https://app.dev.llmstack.local:8443/api/v1/ask
```

Dashboards (Grafana dashboard **"LLM Stack - Overview"**, Prometheus alerts, Alertmanager):

```bash
scripts/demo/dashboards.sh dev            # port-forwards 3000 / 9090 / 9093
TF_DATA_DIR=.terraform-dev terraform -chdir=infra/terraform output -raw grafana_admin_password   # run it yourself; not printed by scripts
```

Logs in Loki (Grafana → Explore → Loki): `{namespace="llm-app", app="assistant"} | json | level="WARN"`

Show internal services are not exposed: `kubectl -n llm-app get svc,ingress` shows only `gateway` behind the Ingress, and everything is `ClusterIP`.

Show security settings: `kubectl get ns llm-app --show-labels` (PSS restricted), `kubectl -n llm-app get netpol`, and `kubectl -n llm-app get pod -l app.kubernetes.io/name=gateway -o jsonpath='{.items[0].spec.containers[0].securityContext}'`.

## 5. Rollback

| Situation | Action |
|---|---|
| Release failed during rollout | Nothing to do: `--atomic` already rolled back. Check `helm -n llm-app history llm-app` |
| Release succeeded but smoke test failed | `scripts/ci.sh release` rolls back automatically |
| Problem found later | `make rollback ENV=prod` (previous revision) or `make rollback ENV=prod REV=7` |
| Bad infrastructure change | `git revert` the change, `make plan ENV=prod`, review, `make apply ENV=prod` |
| Bad model revision | Revert `model.revision`/`sha256` in values.yaml and redeploy. The old file is still on the PVC under its own revision path |

```bash
helm -n llm-app history llm-app            # with KUBECONFIG=.kube/llm-<env>.yaml
make rollback ENV=dev
kubectl -n llm-app rollout status deploy/gateway
make smoke ENV=dev
```

## 6. Teardown and recreate

```bash
make destroy ENV=dev        # terraform destroy: deletes the Kind cluster and everything in it
kind get clusters           # llm-dev is gone
docker ps | grep llm-dev    # no node containers left

make apply ENV=dev && make deploy ENV=dev && make smoke ENV=dev   # full recreate (~10 min, model re-downloaded)
```

Local files that remain after destroy are `infra/terraform/state/dev.tfstate` (now empty), `.kube/allowed-cidrs-dev` and built images in Docker. To remove everything: `rm -rf .kube infra/terraform/state infra/terraform/.terraform-*`.

## 7. Alert runbooks

### alert-GatewayHighErrorRate
More than 5% of gateway responses are 5xx for 2 minutes.
1. Dashboard: which service/route returns 5xx? (`Request rate by service` panel)
2. Logs: `{namespace="llm-app"} | json | status >= 500` and `level="WARN"` in assistant ("llm call failed", "catalog lookup failed").
3. Recent release? `helm -n llm-app history llm-app`. If yes, `make rollback ENV=<env>`.
4. LLM down or slow? `kubectl -n llm-app get pods -l app.kubernetes.io/name=llm`, `kubectl -n llm-app logs deploy/llm`.

### alert-GatewayDown
No gateway target is up. Check `kubectl -n llm-app get pods,deploy,hpa`, then `describe pod` for image pull or probe failures, then roll back.

### alert-LLMUnavailable
`kubectl -n llm-app describe pod -l app.kubernetes.io/name=llm`. Typical causes:
- Stuck in `Init` → the model is not verified yet (see the model-download Job).
- `OOMKilled` → raise the memory limit or reduce `contextSize`/`parallel`.
- Startup probe failing → check the `llama-server` logs.

### alert-ModelVerifyJobFailed
`kubectl -n llm-app logs job/<job_name>` shows which check failed.
- **checksum fail**: the model file changed on disk. Treat it as a possible integrity incident. Scale the llm to 0, delete the file and its `.verified` marker, and re-run the download Job (`kubectl -n llm-app delete job -l app.kubernetes.io/name=model-download && make deploy`).
- **prompt fail**: the LLM is unreachable or answering wrongly. Check `LLMUnavailable` and the llm logs.

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `terraform apply` fails on a helm_release with "values don't meet the specifications of the schema" | Chart values key changed between chart versions. Compare with `helm show values <chart> --version <v>` |
| Traefik release hangs on install | Service type `LoadBalancer` never gets an IP on Kind. Values must set `service.spec.type: ClusterIP` |
| `terraform apply`: `cannot re-use a name that is still in use` | A previous apply timed out and left a *failed* Helm release that Terraform no longer tracks. `helm -n <ns> uninstall <release>` (with the env's KUBECONFIG), then re-apply |
| `curl` gets `403 Forbidden` from the laptop | The laptop's source IP is not in the allowlist. Run `scripts/ci.sh detect-source-ip <env>`, then `make deploy` |
| `curl: (60) SSL certificate problem` | Use `--cacert .kube/llm-<env>-ca.pem` and `--resolve host:port:127.0.0.1` (the cert is issued for the hostname) |
| `llm` pod stuck in `Init:0/1` | The model Job is still downloading, or failed: `kubectl -n llm-app logs job/model-download-...` (checksum mismatch, or no egress) |
| Pods rejected with `violates PodSecurity "restricted"` | The manifest is missing a security setting. Fix the chart, never relax the namespace label |
| HPA shows `<unknown>` targets | metrics-server not ready yet (wait ~1 min) or the pod has no CPU request |
| `kind load` is slow / out of disk | `docker system prune`, then check Docker Desktop disk size |
| Port 8443 already in use | Change `https_host_port` in `envs/<env>.tfvars` (forces cluster recreation) |
| Out of memory with both envs up | Give Docker ≥ 10 GB, or set `enable_monitoring = false` for one environment |
| `release` refuses to run | Not on `main` / a tag, or uncommitted changes. Commit first. Break-glass: `RELEASE_OVERRIDE=1` (logged) |
