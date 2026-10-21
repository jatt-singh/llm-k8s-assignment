#!/usr/bin/env bash
# Shared settings for the demo scripts. Sourced, not executed.
# shellcheck disable=SC2034
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_NAME="${1:-dev}"
TFVARS="$ROOT/infra/terraform/envs/$ENV_NAME.tfvars"
[[ -f "$TFVARS" ]] || { echo "unknown environment $ENV_NAME" >&2; exit 1; }
tfvar() { sed -nE "s/^$1[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?.*/\1/p" "$TFVARS"; }
HOST="$(tfvar hostname)"
PORT="$(tfvar https_host_port)"
BASE="https://$HOST:$PORT"
CA="$ROOT/.kube/llm-$ENV_NAME-ca.pem"
export KUBECONFIG="$ROOT/.kube/llm-$ENV_NAME.yaml"
NS=llm-app
TOOLS_IMAGE="curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"
CURL=(curl --silent --show-error --cacert "$CA" --resolve "$HOST:$PORT:127.0.0.1")
say() { printf '\n\033[1;36m### %s\033[0m\n' "$*"; }
