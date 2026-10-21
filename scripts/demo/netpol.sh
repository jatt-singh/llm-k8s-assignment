#!/usr/bin/env bash
# Prove the default-deny NetworkPolicies: start throwaway pods that impersonate
# a workload (by label) and try every edge. Only allowed edges answer.
# shellcheck source=scripts/demo/common.sh
source "$(dirname "$0")/common.sh"

probe() {  # $1 = label to impersonate
  local overrides
  overrides=$(cat <<JSON
{"spec":{"automountServiceAccountToken":false,
 "securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"probe","image":"$TOOLS_IMAGE",
  "command":["sh","-c","for u in http://catalog:8080/healthz http://assistant:8080/healthz http://llm:8080/health https://huggingface.co; do c=\$(curl -s -o /dev/null -m 5 -w '%{http_code}' \$u); [ \"\$c\" = 000 ] && c=BLOCKED; echo \"\$u -> \$c\"; done"],
  "securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},
  "resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"32Mi"}}}]}}
JSON
)
  say "As a pod labelled app.kubernetes.io/name=$1"
  kubectl -n "$NS" run "np-$1-$RANDOM" --rm -i --restart=Never --quiet \
    --labels="app.kubernetes.io/name=$1" --image="$TOOLS_IMAGE" --overrides="$overrides" 2>/dev/null
}

kubectl -n "$NS" get networkpolicy
probe intruder     # matches no allow rule: everything blocked
probe gateway      # may reach catalog + assistant only
probe assistant    # may reach catalog + llm only
