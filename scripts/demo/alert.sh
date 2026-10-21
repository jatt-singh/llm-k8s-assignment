#!/usr/bin/env bash
# Make the alert fire for real: take the LLM away, send traffic so the gateway
# returns 5xx, wait for GatewayHighErrorRate, then restore.
# shellcheck source=scripts/demo/common.sh
source "$(dirname "$0")/common.sh"
PROM="/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy"

alerts() {
  kubectl get --raw "$PROM/api/v1/alerts" \
    | grep -o '"alertname":"[^"]*"[^}]*"state":"[^"]*"' | grep -v Watchdog \
    | sed -E 's/.*"alertname":"([^"]*)".*"state":"([^"]*)".*/  \1: \2/' || echo "  (no alerts)"
}

say "Alert rules loaded in Prometheus"
kubectl get --raw "$PROM/api/v1/rules" | grep -o '"name":"[A-Z][A-Za-z0-9]*"' | sort -u | sed 's/"name"://'

say "Scaling the LLM to 0 replicas (simulated outage)"
kubectl -n "$NS" scale deploy/llm --replicas=0

say "Sending /api/v1/ask traffic for ~4 minutes; GatewayHighErrorRate needs >5% 5xx for 2m"
end=$((SECONDS + 240))
while (( SECONDS < end )); do
  "${CURL[@]}" -o /dev/null -w '%{http_code} ' -H 'Content-Type: application/json' \
    -d '{"question":"ping"}' "$BASE/api/v1/ask" || true
  if (( SECONDS % 30 < 2 )); then echo; alerts; fi
  sleep 2
done
echo
say "Alert state"
alerts

say "Restoring the LLM"
kubectl -n "$NS" scale deploy/llm --replicas=1
kubectl -n "$NS" rollout status deploy/llm --timeout=300s
