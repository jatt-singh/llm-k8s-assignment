#!/usr/bin/env bash
# CI/CD entry point. CI-product agnostic: any runner (or a laptop) calls this.
#
#   scripts/ci.sh check                 lint, unit tests, build, scan, SBOM  (every change)
#   scripts/ci.sh release <env>         check + terraform apply + load images + helm deploy
#                                       + smoke test + scheduled-job check   (main / tags only)
#
#   scripts/ci.sh plan|apply|destroy <env>   Terraform for one environment
#   scripts/ci.sh deploy <env>               load images + helm upgrade (no checks)
#   scripts/ci.sh smoke <env>                end-to-end test through the TLS ingress
#   scripts/ci.sh cronjob-check <env>        run the scheduled job now and assert it passed
#   scripts/ci.sh rollback <env> [revision]  helm rollback (default: previous revision)
#   scripts/ci.sh status <env>               what is running
#
# Environment variables:
#   SEVERITY_THRESHOLD  vulnerability gate (default CRITICAL). Fixed vulns at or
#                       above this severity fail the build.
#   IMAGE_TAG           override the image tag (default: git short sha)
#   ALLOWED_CIDRS       comma-separated source ranges allowed through the ingress
#   RELEASE_OVERRIDE=1  break-glass: allow release from a non-main branch (logged)
#
# Secrets: this script never prints secret values and never runs with `set -x`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/infra/terraform"
CHART="$ROOT/deploy/helm/llm-app"
REPORTS="$ROOT/reports"
APP_NS="llm-app"
SERVICES=(gateway catalog assistant)
SEVERITY_THRESHOLD="${SEVERITY_THRESHOLD:-CRITICAL}"
TOOLS_IMAGE="curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"

# ------------------------------------------------------------------ helpers --

log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

need() {
  local missing=()
  for t in "$@"; do command -v "$t" >/dev/null || missing+=("$t"); done
  [[ ${#missing[@]} -eq 0 ]] || die "missing tools: ${missing[*]} (see README prerequisites)"
}

image_tag() {
  if [[ -n "${IMAGE_TAG:-}" ]]; then echo "$IMAGE_TAG"; return; fi
  local sha
  sha="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo "nogit")"
  if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then sha="$sha-dirty"; fi
  echo "$sha"
}

all_images() {
  local tag; tag="$(image_tag)"
  for s in "${SERVICES[@]}" llm; do echo "llmstack/$s:$tag"; done
}

check_env() {
  [[ -n "${1:-}" ]] || die "environment required (e.g. dev, prod)"
  [[ -f "$TF_DIR/envs/$1.tfvars" ]] || die "unknown environment '$1': no infra/terraform/envs/$1.tfvars"
  [[ -f "$CHART/values-$1.yaml" ]]  || die "unknown environment '$1': no deploy/helm/llm-app/values-$1.yaml"
}

# Each environment gets its own .terraform dir and state file, so dev and prod
# never share a backend and can be applied independently.
tf() {
  local env="$1"; shift
  ( cd "$TF_DIR" && TF_DATA_DIR=".terraform-$env" terraform "$@" )
}

tf_init() {
  tf "$1" init -input=false -reconfigure -backend-config="envs/$1.backend.hcl" >/dev/null
}

kube() {
  local env="$1"; shift
  KUBECONFIG="$ROOT/.kube/llm-$env.yaml" "$@"
}

tfvar() {  # read a simple string/number from envs/<env>.tfvars
  sed -nE "s/^$2[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?.*/\1/p" "$TF_DIR/envs/$1.tfvars"
}

# --------------------------------------------------------------- check mode --

lint() {
  log "Lint and static checks"
  need go helm terraform shellcheck hadolint trivy

  ( cd "$ROOT/services"
    unformatted="$(gofmt -l .)"
    [[ -z "$unformatted" ]] || die "gofmt needed on: $unformatted"
    go vet ./... )
  ok "go fmt / go vet"

  shellcheck -x "$ROOT"/scripts/*.sh "$ROOT"/scripts/demo/*.sh
  ok "shellcheck"

  hadolint "$ROOT/services/Dockerfile" "$ROOT/llm/Dockerfile"
  ok "hadolint"

  terraform -chdir="$TF_DIR" fmt -check -recursive >/dev/null || die "terraform fmt needed (run: terraform -chdir=infra/terraform fmt -recursive)"
  ( cd "$TF_DIR" && TF_DATA_DIR=.terraform-validate terraform init -backend=false -input=false >/dev/null \
      && TF_DATA_DIR=.terraform-validate terraform validate -no-color >/dev/null )
  ok "terraform fmt / validate"

  for env in dev prod; do
    helm lint "$CHART" -f "$CHART/values-$env.yaml" --set image.tag=lint \
      --set "ingress.allowedSourceRanges={127.0.0.1/32}" >/dev/null
  done
  ok "helm lint (dev, prod)"

  # IaC misconfiguration scan of Terraform and the rendered chart.
  mkdir -p "$REPORTS/scans"
  local rendered; rendered="$(mktemp -d)"
  helm template llm-app "$CHART" -n "$APP_NS" -f "$CHART/values-prod.yaml" --set image.tag=scan \
    --set "ingress.allowedSourceRanges={127.0.0.1/32}" > "$rendered/llm-app.yaml"
  trivy config --quiet --severity HIGH,CRITICAL --exit-code 1 \
    --ignorefile "$ROOT/.trivyignore" "$rendered" > "$REPORTS/scans/k8s-manifests-misconfig.txt" \
    || { cat "$REPORTS/scans/k8s-manifests-misconfig.txt"; die "HIGH/CRITICAL misconfiguration in Kubernetes manifests"; }
  trivy config --quiet --severity HIGH,CRITICAL --exit-code 0 \
    --ignorefile "$ROOT/.trivyignore" "$TF_DIR" > "$REPORTS/scans/terraform-misconfig.txt"
  rm -rf "$rendered"
  ok "trivy config (manifests gated on HIGH, terraform report only)"
}

unit_tests() {
  log "Unit tests"
  ( cd "$ROOT/services" && go test -race -cover ./... )
  ok "go test"
  python3 "$ROOT/scripts/test_chart.py"
  ok "chart policy tests"
}

build() {
  log "Build images (tag $(image_tag))"
  need docker
  local tag; tag="$(image_tag)"
  for s in "${SERVICES[@]}"; do
    docker build --quiet --build-arg "SERVICE=$s" -t "llmstack/$s:$tag" "$ROOT/services" >/dev/null
    ok "llmstack/$s:$tag"
  done
  docker build --quiet -t "llmstack/llm:$tag" "$ROOT/llm" >/dev/null
  ok "llmstack/llm:$tag"
}

scan() {
  log "Vulnerability scan (gate: fixed vulnerabilities >= $SEVERITY_THRESHOLD)"
  need trivy
  mkdir -p "$REPORTS/scans"
  local sev failed=()
  case "$SEVERITY_THRESHOLD" in
    CRITICAL) sev="CRITICAL" ;;
    HIGH)     sev="HIGH,CRITICAL" ;;
    MEDIUM)   sev="MEDIUM,HIGH,CRITICAL" ;;
    *) die "SEVERITY_THRESHOLD must be CRITICAL, HIGH or MEDIUM" ;;
  esac

  for img in $(all_images) "$TOOLS_IMAGE"; do
    local name; name="$(echo "$img" | sed -E 's#^llmstack/##; s#[:@/].*##')"
    [[ "$img" == "$TOOLS_IMAGE" ]] && name="tools-curl"
    # Full report (all severities) for the record...
    trivy image --quiet --scanners vuln --format table -o "$REPORTS/scans/$name.txt" "$img"
    trivy image --quiet --scanners vuln --format json  -o "$REPORTS/scans/$name.json" "$img"
    # ...and the gate: only vulnerabilities that have a fix available count.
    if trivy image --quiet --scanners vuln --ignore-unfixed --severity "$sev" \
         --ignorefile "$ROOT/.trivyignore" --exit-code 1 --format table "$img" > "/tmp/gate-$name.txt" 2>&1; then
      ok "$name: no fixable $sev vulnerabilities"
    else
      failed+=("$name"); cat "/tmp/gate-$name.txt"
    fi
    rm -f "/tmp/gate-$name.txt"
  done
  [[ ${#failed[@]} -eq 0 ]] || die "vulnerability gate: fixable $sev findings in: ${failed[*]}. Fix (bump base image / dependency) or, with justification, add the CVE to .trivyignore."
}

sbom() {
  log "SBOM (SPDX JSON)"
  need syft
  mkdir -p "$REPORTS/sbom"
  for img in $(all_images); do
    local name; name="$(echo "$img" | sed -E 's#^llmstack/##; s#:.*##')"
    syft -q "$img" -o "spdx-json=$REPORTS/sbom/$name.spdx.json"
    ok "$name -> reports/sbom/$name.spdx.json"
  done
  {
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "image_tag: $(image_tag)"
    echo "trivy: $(trivy --version 2>/dev/null | head -1)"
    echo "trivy_db: $(trivy --version 2>/dev/null | grep -A1 'Vulnerability DB' | sed -n 's/.*Version: //p' | head -1)"
    echo "syft: $(syft version 2>/dev/null | awk '/^Version/{print $2}')"
    echo "severity_threshold: $SEVERITY_THRESHOLD"
    echo "images:"
    for img in $(all_images) "$TOOLS_IMAGE"; do
      echo "  - $img $(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null || true)"
    done
  } > "$REPORTS/tool-versions.txt"
}

cmd_check() {
  lint
  unit_tests
  build
  scan
  sbom
  log "check passed"
}

# ------------------------------------------------------------- release mode --

release_gate() {
  local branch tag
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo none)"
  tag="$(git -C "$ROOT" describe --exact-match --tags 2>/dev/null || true)"
  if [[ "$branch" == "main" || -n "$tag" ]]; then
    ok "release allowed (branch=$branch tag=${tag:-none})"
  elif [[ "${RELEASE_OVERRIDE:-0}" == "1" ]]; then
    printf '\033[1;33m  ! RELEASE_OVERRIDE=1: releasing from branch %s (break-glass, audited in this log)\033[0m\n' "$branch"
  else
    die "release runs only on main or a tagged commit (current branch: $branch)"
  fi
  if [[ "$(image_tag)" == *-dirty && -z "${IMAGE_TAG:-}" ]]; then
    die "working tree has uncommitted changes; commit before releasing so the image tag identifies the code"
  fi
}

cmd_plan()    { check_env "$1"; tf_init "$1"; tf "$1" plan -input=false -var-file="envs/$1.tfvars" -out="$1.tfplan"; }
cmd_apply()   {
  check_env "$1"; tf_init "$1"
  tf "$1" plan -input=false -var-file="envs/$1.tfvars" -out="$1.tfplan" >/dev/null
  tf "$1" apply -input=false "$1.tfplan"
}
cmd_destroy() {
  check_env "$1"; tf_init "$1"
  tf "$1" destroy -input=false -auto-approve -var-file="envs/$1.tfvars"
  # The model PVC uses helm.sh/resource-policy=keep, but it lives in the cluster
  # that was just deleted, so nothing is left behind.
}

allowed_cidrs_values() {
  # Default: the address Docker Desktop uses when forwarding the laptop's
  # 127.0.0.1:<port> into the Kind node (see docs/RUNBOOK.md for how to find it).
  local cidrs="${ALLOWED_CIDRS:-$(cat "$ROOT/.kube/allowed-cidrs-$1" 2>/dev/null || echo "")}"
  [[ -n "$cidrs" ]] || die "ALLOWED_CIDRS not set and no detected value; run: scripts/ci.sh detect-source-ip $1"
  echo "{${cidrs}}"
}

cmd_deploy() {
  local env="$1"; check_env "$env"
  need kind helm kubectl
  local tag cluster="llm-$env"
  tag="$(image_tag)"
  kind get clusters 2>/dev/null | grep -qx "$cluster" || die "cluster $cluster not found; run: scripts/ci.sh apply $env"

  log "Load images into Kind ($cluster)"
  for img in $(all_images); do
    kind load docker-image "$img" --name "$cluster" >/dev/null
    ok "$img"
  done

  log "Helm upgrade (atomic: a failed rollout is rolled back automatically)"
  kube "$env" helm upgrade --install llm-app "$CHART" \
    --namespace "$APP_NS" \
    -f "$CHART/values-$env.yaml" \
    --set "image.tag=$tag" \
    --set "ingress.allowedSourceRanges=$(allowed_cidrs_values "$env")" \
    --atomic --wait --timeout 20m \
    --history-max 10
  ok "deployed llm-app $tag to $env"
}

cmd_smoke() {
  local env="$1"; check_env "$env"
  local host port ca base
  host="$(tfvar "$env" hostname)"; port="$(tfvar "$env" https_host_port)"
  ca="$ROOT/.kube/llm-$env-ca.pem"
  base="https://$host:$port"
  local c=(curl --silent --show-error --fail --max-time 120 --cacert "$ca" --resolve "$host:$port:127.0.0.1")

  log "Smoke test via TLS ingress: $base"
  "${c[@]}" "$base/healthz" >/dev/null && ok "GET /healthz"
  "${c[@]}" "$base/api/v1/items" | grep -q '"item-1"' && ok "GET /api/v1/items"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$ca" --resolve "$host:$port:127.0.0.1" "$base/api/v1/items/nope")"
  if [[ "$code" == "404" ]]; then ok "GET /api/v1/items/nope -> 404"; else die "expected 404, got $code"; fi
  local answer
  answer="$("${c[@]}" -H 'Content-Type: application/json' \
    -d '{"question":"Summarize this item in one sentence.","item_id":"item-1"}' "$base/api/v1/ask")"
  echo "$answer" | grep -q '"answer":"[^"]' || die "LLM answer missing: $answer"
  ok "POST /api/v1/ask reached the LLM: $answer"
}

cmd_cronjob_check() {
  local env="$1"; check_env "$env"
  local job
  job="model-verify-manual-$(date +%s)"
  log "Run scheduled job now: $job"
  kube "$env" kubectl -n "$APP_NS" get cronjob model-verify -o jsonpath='{.spec.schedule}{" ("}{.spec.timeZone}{")"}' \
    | sed 's/^/  schedule: /'; echo
  kube "$env" kubectl -n "$APP_NS" create job "$job" --from=cronjob/model-verify >/dev/null
  if kube "$env" kubectl -n "$APP_NS" wait --for=condition=complete "job/$job" --timeout=300s >/dev/null 2>&1; then
    kube "$env" kubectl -n "$APP_NS" logs "job/$job"
    ok "scheduled job passed"
  else
    kube "$env" kubectl -n "$APP_NS" logs "job/$job" || true
    die "scheduled job $job did not complete successfully"
  fi
}

cmd_rollback() {
  local env="$1" rev="${2:-}"; check_env "$env"
  log "Helm history"
  kube "$env" helm history llm-app -n "$APP_NS" --max 5
  log "Rolling back llm-app in $env to ${rev:-previous revision}"
  # shellcheck disable=SC2086
  kube "$env" helm rollback llm-app $rev -n "$APP_NS" --wait --timeout 10m
  ok "rolled back"
  kube "$env" kubectl -n "$APP_NS" get deploy -o wide
}

cmd_status() {
  local env="$1"; check_env "$env"
  kube "$env" helm list -n "$APP_NS"
  kube "$env" kubectl -n "$APP_NS" get deploy,hpa,pdb,cronjob,jobs,pvc,ingress
}

# Find which source address the ingress sees for requests from this laptop.
cmd_detect_source_ip() {
  local env="$1"; check_env "$env"
  local ip
  ip="$(kube "$env" kubectl -n ingress logs deploy/traefik --tail=200 2>/dev/null \
        | grep -o '"ClientHost":"[^"]*"' | tail -1 | cut -d'"' -f4)"
  [[ -n "$ip" ]] || die "no access log line found; send one request to the ingress first"
  mkdir -p "$ROOT/.kube"
  echo "$ip/32" > "$ROOT/.kube/allowed-cidrs-$env"
  ok "laptop traffic arrives from $ip; saved $ip/32 as the $env allowlist"
}

cmd_release() {
  local env="$1"; check_env "$env"
  log "Release to $env"
  release_gate
  cmd_check
  log "Infrastructure (terraform plan + apply, $env)"
  cmd_apply "$env"
  cmd_deploy "$env"
  if ! cmd_smoke "$env"; then
    log "Smoke test failed: rolling back"
    cmd_rollback "$env"
    die "release to $env failed its smoke test and was rolled back"
  fi
  cmd_cronjob_check "$env"
  log "release to $env complete (tag $(image_tag))"
}

# ---------------------------------------------------------------------- main --

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  check)            cmd_check ;;
  lint)             lint ;;
  test)             unit_tests ;;
  build)            build ;;
  scan)             build; scan ;;
  sbom)             build; sbom ;;
  release)          cmd_release "${1:-}" ;;
  plan)             cmd_plan "${1:-}" ;;
  apply)            cmd_apply "${1:-}" ;;
  destroy)          cmd_destroy "${1:-}" ;;
  deploy)           cmd_deploy "${1:-}" ;;
  smoke)            cmd_smoke "${1:-}" ;;
  cronjob-check)    cmd_cronjob_check "${1:-}" ;;
  rollback)         cmd_rollback "${1:-}" "${2:-}" ;;
  status)           cmd_status "${1:-}" ;;
  detect-source-ip) cmd_detect_source_ip "${1:-}" ;;
  *)                usage ;;
esac
