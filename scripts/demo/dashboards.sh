#!/usr/bin/env bash
# Open Grafana / Prometheus / Alertmanager on localhost via port-forward.
# shellcheck source=scripts/demo/common.sh
source "$(dirname "$0")/common.sh"
echo "Grafana      http://localhost:3000   (user admin, password: run"
echo "             'terraform -chdir=infra/terraform output -raw grafana_admin_password' with TF_DATA_DIR=.terraform-$ENV_NAME)"
echo "Prometheus   http://localhost:9090/alerts"
echo "Alertmanager http://localhost:9093"
echo "Ctrl-C to stop."
kubectl -n monitoring port-forward svc/kps-grafana 3000:80 >/dev/null &
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 >/dev/null &
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-alertmanager 9093:9093 >/dev/null &
trap 'kill $(jobs -p) 2>/dev/null' EXIT
wait
