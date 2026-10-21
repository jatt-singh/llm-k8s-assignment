#!/usr/bin/env bash
# Simulate a bad release (a gateway image tag that was never built), show that
# the readiness-gated rollout stalls while the old pods keep serving, then roll back.
# shellcheck source=scripts/demo/common.sh
source "$(dirname "$0")/common.sh"
CHART="$ROOT/deploy/helm/llm-app"

say "Current release"
helm -n "$NS" history llm-app --max 3

say "Deploying a broken gateway (image llmstack/gateway:does-not-exist) without --atomic"
helm -n "$NS" upgrade llm-app "$CHART" --reuse-values \
  --set services.gateway.imageTag=does-not-exist --wait --timeout 60s \
  || echo ">>> helm reports the release FAILED (new pods never became ready)"

say "New pod is stuck, old pods are still Ready (maxUnavailable=0)"
kubectl -n "$NS" get pods -l app.kubernetes.io/name=gateway

say "Traffic is still served by the previous version"
"${CURL[@]}" -o /dev/null -w 'GET /api/v1/items -> HTTP %{http_code}\n' "$BASE/api/v1/items"

say "Roll back to the last good revision"
"$ROOT/scripts/ci.sh" rollback "$ENV_NAME"
helm -n "$NS" history llm-app --max 4
"${CURL[@]}" -o /dev/null -w 'after rollback: GET /api/v1/items -> HTTP %{http_code}\n' "$BASE/api/v1/items"
