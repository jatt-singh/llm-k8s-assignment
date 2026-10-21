#!/usr/bin/env bash
# Allowed vs. blocked source: the laptop is in the allowlist, another machine
# on the same network (a container on Docker's "kind" network) is not.
# shellcheck source=scripts/demo/common.sh
source "$(dirname "$0")/common.sh"

say "Allowlist configured on the ingress"
kubectl -n "$NS" get middleware ip-allowlist -o jsonpath='{.spec.ipAllowList.sourceRange}'; echo

say "From the laptop (allowed source)"
"${CURL[@]}" -o /dev/null -w 'HTTP %{http_code}\n' "$BASE/healthz"

NODE_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "llm-$ENV_NAME-control-plane")"
say "From another host on the network (container -> $NODE_IP:443, not in the allowlist)"
docker run --rm --network kind "$TOOLS_IMAGE" --silent --insecure \
  --resolve "$HOST:443:$NODE_IP" -o /dev/null -w 'HTTP %{http_code}\n' "https://$HOST/healthz"

say "Internal services are not reachable from outside at all (ClusterIP only)"
kubectl -n "$NS" get svc -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP
