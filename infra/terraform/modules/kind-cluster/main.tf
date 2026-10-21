# Kind cluster: the local stand-in for a managed Kubernetes cluster (EKS/GKE/AKS).
# Each "node" is a Docker container. Only the control-plane node publishes a host
# port (HTTPS for the ingress controller), bound to 127.0.0.1 so nothing on the
# LAN can reach it.

terraform {
  required_providers {
    kind = {
      source = "tehcyx/kind"
    }
  }
}

resource "kind_cluster" "this" {
  name            = var.name
  node_image      = var.node_image
  kubeconfig_path = var.kubeconfig_path
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # The ingress controller is scheduled here (nodeSelector ingress-ready=true).
      labels = {
        "ingress-ready" = "true"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = var.https_host_port
        listen_address = var.listen_address
        protocol       = "TCP"
      }
    }

    dynamic "node" {
      for_each = range(var.worker_count)
      content {
        role = "worker"
      }
    }
  }
}
