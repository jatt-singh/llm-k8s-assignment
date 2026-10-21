variable "chart_versions" {
  description = "Exact Helm chart versions for the platform add-ons."
  type = object({
    traefik               = string
    metrics_server        = string
    kube_prometheus_stack = string
    loki                  = string
    alloy                 = string
  })
}

variable "enable_monitoring" {
  description = "Install Prometheus, Alertmanager, Grafana, Loki and Alloy."
  type        = bool
  default     = true
}

variable "incident_webhook_url" {
  description = "Alertmanager webhook for the incident channel. Empty = alerts are visible in Alertmanager only."
  type        = string
  default     = ""
  sensitive   = true
}
