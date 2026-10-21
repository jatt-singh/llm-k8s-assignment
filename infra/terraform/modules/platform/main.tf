# Cluster add-ons that the application relies on: ingress controller,
# metrics-server (for the HPA) and the observability stack.
# Every chart is pinned to an exact version.

terraform {
  required_providers {
    helm       = { source = "hashicorp/helm" }
    kubernetes = { source = "hashicorp/kubernetes" }
    random     = { source = "hashicorp/random" }
  }
}

locals {
  # Pod Security Standards. The ingress namespace needs "privileged" only because
  # Kind exposes the controller through a hostPort; on a managed cluster it would
  # sit behind a cloud LoadBalancer Service and run "restricted".
  namespaces = {
    ingress    = "privileged"
    monitoring = "baseline"
  }
}

resource "kubernetes_namespace_v1" "this" {
  for_each = local.namespaces

  metadata {
    name = each.key
    labels = {
      "pod-security.kubernetes.io/enforce" = each.value
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }
}

# ---------------------------------------------------------------- ingress ---

resource "helm_release" "traefik" {
  name       = "traefik"
  namespace  = kubernetes_namespace_v1.this["ingress"].metadata[0].name
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = var.chart_versions.traefik
  wait       = true
  timeout    = 600

  values = [yamlencode({
    deployment = { replicas = 1 }
    # Pin to the node that owns the host port mapping.
    nodeSelector = { "ingress-ready" = "true" }
    tolerations = [{
      key      = "node-role.kubernetes.io/control-plane"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
    # No cloud LB on Kind: the controller is reached through its hostPort.
    service = { spec = { type = "ClusterIP" } }
    ports = {
      # Plain HTTP is not published on the host at all: TLS only.
      web = { expose = { default = false } }
      websecure = {
        hostPort = 443
        http     = { tls = { enabled = true } }
      }
    }
    providers = {
      kubernetesIngress = { enabled = true }
      kubernetesCRD     = { enabled = true }
    }
    ingressClass = { enabled = true, isDefaultClass = true, name = "traefik" }
    log          = { format = "json", level = "INFO" }
    accessLog    = { enabled = true, format = "json" }
    metrics = {
      prometheus = {
        service        = { enabled = true }
        serviceMonitor = { enabled = var.enable_monitoring }
      }
    }
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "500m", memory = "256Mi" }
    }
  })]

  # ServiceMonitor CRD must exist before Traefik creates its ServiceMonitor.
  depends_on = [helm_release.kube_prometheus_stack]
}

# --------------------------------------------------------- metrics-server ---

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = var.chart_versions.metrics_server
  wait       = true

  values = [yamlencode({
    # Kind kubelets use self-signed serving certs.
    args = ["--kubelet-insecure-tls"]
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "250m", memory = "128Mi" }
    }
  })]
}

# ------------------------------------------------------------ monitoring ---

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  count = var.enable_monitoring ? 1 : 0

  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  }
  data = {
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin.result
  }
}

# Incident channel webhook (e.g. a Slack/Teams/PagerDuty URL). Kept in a Secret
# and read by Alertmanager via url_file, so it never appears in Helm values.
resource "kubernetes_secret_v1" "incident_webhook" {
  count = var.enable_monitoring ? 1 : 0

  metadata {
    name      = "incident-webhook"
    namespace = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  }
  data = {
    url = var.incident_webhook_url
  }
}

locals {
  # Only the URL is secret; whether one is set is not.
  has_incident_webhook = nonsensitive(var.incident_webhook_url != "")
  incident_receiver = {
    name = "incident-channel"
    webhook_configs = local.has_incident_webhook ? [{
      url_file      = "/etc/alertmanager/secrets/incident-webhook/url"
      send_resolved = true
    }] : []
  }
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.enable_monitoring ? 1 : 0

  name       = "kps"
  namespace  = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_versions.kube_prometheus_stack
  wait       = true
  timeout    = 900

  values = [yamlencode({
    # Control-plane components are not scrapeable on Kind; turning them off
    # avoids permanently-firing "target down" alerts. Node exporter needs
    # hostNetwork/hostPID which the namespace's PSS level does not allow.
    kubeEtcd              = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeProxy             = { enabled = false }
    nodeExporter          = { enabled = false }

    prometheus = {
      prometheusSpec = {
        # Pick up ServiceMonitors / PrometheusRules from every namespace.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        retention                               = "3d"
        evaluationInterval                      = "30s"
        resources = {
          requests = { cpu = "100m", memory = "400Mi" }
          limits   = { cpu = "1", memory = "1Gi" }
        }
      }
    }

    alertmanager = {
      alertmanagerSpec = {
        secrets = ["incident-webhook"]
        resources = {
          requests = { cpu = "20m", memory = "32Mi" }
          limits   = { cpu = "200m", memory = "128Mi" }
        }
      }
      config = {
        route = {
          receiver        = "incident-channel"
          group_by        = ["alertname", "namespace"]
          group_wait      = "30s"
          group_interval  = "5m"
          repeat_interval = "4h"
          routes = [
            # Watchdog is the always-firing "pipeline is alive" heartbeat.
            { receiver = "null", matchers = ["alertname = Watchdog"] },
            { receiver = "null", matchers = ["alertname = InfoInhibitor"] },
          ]
        }
        receivers = [{ name = "null" }, local.incident_receiver]
      }
    }

    grafana = {
      admin = {
        existingSecret = "grafana-admin"
        userKey        = "admin-user"
        passwordKey    = "admin-password"
      }
      additionalDataSources = [{
        name   = "Loki"
        type   = "loki"
        uid    = "loki"
        url    = "http://loki.monitoring.svc:3100"
        access = "proxy"
      }]
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "384Mi" }
      }
    }

    prometheusOperator = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    }
  })]

  depends_on = [kubernetes_secret_v1.grafana_admin, kubernetes_secret_v1.incident_webhook]
}

# Central log store: Loki in single-binary mode with filesystem storage.
resource "helm_release" "loki" {
  count = var.enable_monitoring ? 1 : 0

  name       = "loki"
  namespace  = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.chart_versions.loki
  wait       = true
  timeout    = 600

  values = [yamlencode({
    deploymentMode = "SingleBinary"
    loki = {
      auth_enabled  = false
      commonConfig  = { replication_factor = 1 }
      storage       = { type = "filesystem" }
      limits_config = { retention_period = "72h" }
      compactor = {
        retention_enabled    = true
        delete_request_store = "filesystem"
      }
      schemaConfig = {
        configs = [{
          from         = "2024-04-01"
          store        = "tsdb"
          object_store = "filesystem"
          schema       = "v13"
          index        = { prefix = "index_", period = "24h" }
        }]
      }
    }
    singleBinary = {
      replicas    = 1
      persistence = { enabled = true, size = "2Gi" }
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }
    read         = { replicas = 0 }
    write        = { replicas = 0 }
    backend      = { replicas = 0 }
    gateway      = { enabled = false }
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    lokiCanary   = { enabled = false }
    test         = { enabled = false }
    minio        = { enabled = false }
    sidecar      = { rules = { enabled = false } }
    memberlist   = { service = { publishNotReadyAddresses = true } }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

# Log shipper: Alloy tails container logs through the Kubernetes API
# (no hostPath mounts needed) and pushes them to Loki.
resource "helm_release" "alloy" {
  count = var.enable_monitoring ? 1 : 0

  name       = "alloy"
  namespace  = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.chart_versions.alloy
  wait       = true

  values = [yamlencode({
    # One replica tails all pods through the API; a DaemonSet would duplicate lines.
    controller = { type = "deployment", replicas = 1 }
    alloy = {
      configMap = { content = file("${path.module}/alloy.river") }
      resources = {
        requests = { cpu = "50m", memory = "96Mi" }
        limits   = { cpu = "500m", memory = "256Mi" }
      }
    }
  })]

  depends_on = [helm_release.loki]
}
