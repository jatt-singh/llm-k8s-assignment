variable "environment" {
  description = "Environment name (dev, prod, ...). Drives the cluster name and state file."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.environment))
    error_message = "environment must be lowercase alphanumeric, 2-16 chars."
  }
}

variable "kind_node_image" {
  description = "kindest/node image pinned by digest; must match the kind library inside the provider (v0.32)."
  type        = string
  default     = "kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5"
}

variable "worker_count" {
  description = "Worker nodes in the cluster."
  type        = number
  default     = 1
}

variable "https_host_port" {
  description = "Laptop port for HTTPS ingress. Must be unique per environment so they can run side by side."
  type        = number
}

variable "hostname" {
  description = "Public hostname of the gateway (used for the TLS cert and the Ingress rule)."
  type        = string
}

variable "app_namespace" {
  description = "Namespace for the application workloads."
  type        = string
  default     = "llm-app"
}

variable "enable_monitoring" {
  description = "Install the observability stack (Prometheus, Grafana, Loki, Alloy)."
  type        = bool
  default     = true
}

variable "incident_webhook_url" {
  description = "Optional Alertmanager webhook (Slack/Teams/PagerDuty). Pass via TF_VAR_incident_webhook_url, never in tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "chart_versions" {
  description = "Exact Helm chart versions for the platform add-ons."
  type = object({
    traefik               = string
    metrics_server        = string
    kube_prometheus_stack = string
    loki                  = string
    alloy                 = string
  })
  default = {
    traefik               = "41.6.1"
    metrics_server        = "3.14.0"
    kube_prometheus_stack = "91.9.0"
    loki                  = "7.3.0"
    alloy                 = "1.13.0"
  }
}
