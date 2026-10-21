#!/usr/bin/env bash
# Make the alert fire for real: take the LLM away, send traffic so the gateway
# returns 5xx, wait for GatewayHighErrorRate to go pending -> firing, then restore.
# shellcheck source=scripts/demo/common.sh
source "$(dirname "$0")/common.sh"
PROM="/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy"
AM="/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-alertmanager:9093/proxy"

alerts() {
  kubectl get --raw "$PROM/api/v1/alerts" \
    | jq -r '.data.alerts[] | select(.labels.namespace=="'"$NS"'") | "  \(.labels.alertname) [\(.labels.severity)]: \(.state)"' \
    | sort -u | grep . || echo "  (no llmstack alerts)"
}

say "Alert rules loaded in Prometheus (llmstack groups)"
kubectl get --raw "$PROM/api/v1/rules" \
  | jq -r '.data.groups[] | select(.name|startswith("llmstack")) | .rules[] | "  \(.name): \(.state)"'

say "Scaling the LLM to 0 replicas (simulated outage)"
kubectl -n "$NS" scale deploy/llm --replicas=0

say "Sending /api/v1/ask traffic until GatewayHighErrorRate fires (>5% 5xx for 2m)"
end=$((SECONDS + ${MAX_WAIT:-420}))
while (( SECONDS < end )); do
  for _ in 1 2 3 4 5; do
    "${CURL[@]}" --max-time 5 -o /dev/null -w '%{http_code} ' -H 'Content-Type: application/json' \
      -d '{"question":"ping"}' "$BASE/api/v1/ask" 2>/dev/null || printf 'timeout '
  done
  echo; alerts
  alerts | grep -q 'GatewayHighErrorRate.*firing' && break
  sleep 10
done

say "Alert as received by Alertmanager (routed to receiver incident-channel)"
kubectl get --raw "$AM/api/v2/alerts?filter=alertname%3DGatewayHighErrorRate" \
  | jq -r '.[] | "  \(.labels.alertname) state=\(.status.state) receivers=\([.receivers[].name]|join(",")) summary=\(.annotations.summary)"'

say "Restoring the LLM"
kubectl -n "$NS" scale deploy/llm --replicas=1
kubectl -n "$NS" rollout status deploy/llm --timeout=300s
echo "The alert resolves once the 2m error window clears (send_resolved notifies the channel)."
