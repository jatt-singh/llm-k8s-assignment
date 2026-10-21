output "cluster_name" {
  value = module.cluster.name
}

output "kubeconfig_path" {
  value = module.cluster.kubeconfig_path
}

output "gateway_url" {
  value = "https://${var.hostname}:${var.https_host_port}"
}

output "ingress_ca_file" {
  value = local_file.ingress_ca.filename
}

output "app_namespace" {
  value = kubernetes_namespace_v1.app.metadata[0].name
}

output "grafana_admin_password" {
  value     = module.platform.grafana_admin_password
  sensitive = true
}
