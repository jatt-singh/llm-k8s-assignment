output "endpoint" {
  value = kind_cluster.this.endpoint
}

output "client_certificate" {
  value = kind_cluster.this.client_certificate
}

output "client_key" {
  value     = kind_cluster.this.client_key
  sensitive = true
}

output "cluster_ca_certificate" {
  value = kind_cluster.this.cluster_ca_certificate
}

output "kubeconfig_path" {
  value = kind_cluster.this.kubeconfig_path
}

output "name" {
  value = kind_cluster.this.name
}
