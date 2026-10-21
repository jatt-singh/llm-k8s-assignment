#!/usr/bin/env bash
# Drive CPU on the gateway through the ingress and watch the HPA react.
# shellcheck source=scripts/demo/common.sh
source "$(dirname "$0")/common.sh"
DURATION="${DURATION:-120}"
CLIENTS="${CLIENTS:-12}"

say "HPA before load"
kubectl -n "$NS" get hpa gateway

say "Generating load for ${DURATION}s ($CLIENTS clients, keep-alive, GET /api/v1/items)"
end=$((SECONDS + DURATION))
# Each client reuses one TLS connection for 200 requests (curl URL globbing),
# so the load lands on the gateway rather than on TLS handshakes.
worker() {
  while (( SECONDS < end )); do
    "${CURL[@]}" -o /dev/null -o /dev/null "$BASE/api/v1/items?[1-200]" 2>/dev/null || true
  done
}
for _ in $(seq "$CLIENTS"); do worker & done

while (( SECONDS < end )); do
  printf '%s  ' "$(date +%H:%M:%S)"
  kubectl -n "$NS" get hpa gateway --no-headers | awk '{print "cpu", $3, "replicas", $(NF-1)}'
  sleep 10
done
wait

say "HPA after load (scale-down waits for the 120s stabilization window)"
kubectl -n "$NS" get hpa gateway
kubectl -n "$NS" get pods -l app.kubernetes.io/name=gateway
