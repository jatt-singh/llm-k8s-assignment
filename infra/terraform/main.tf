# Root module: one Kind cluster per environment, its platform add-ons, and the
# application namespace with its secrets. The application itself is deployed by
# Helm from scripts/ci.sh (release mode) so app rollouts and rollbacks do not
# require touching infrastructure state.

locals {
  cluster_name    = "llm-${var.environment}"
  kubeconfig_path = abspath("${path.root}/../../.kube/${local.cluster_name}.yaml")
}

module "cluster" {
  source = "./modules/kind-cluster"

  name            = local.cluster_name
  node_image      = var.kind_node_image
  worker_count    = var.worker_count
  https_host_port = var.https_host_port
  kubeconfig_path = local.kubeconfig_path
}

provider "kubernetes" {
  host                   = module.cluster.endpoint
  client_certificate     = module.cluster.client_certificate
  client_key             = module.cluster.client_key
  cluster_ca_certificate = module.cluster.cluster_ca_certificate
}

provider "helm" {
  kubernetes = {
    host                   = module.cluster.endpoint
    client_certificate     = module.cluster.client_certificate
    client_key             = module.cluster.client_key
    cluster_ca_certificate = module.cluster.cluster_ca_certificate
  }
}

module "platform" {
  source = "./modules/platform"

  chart_versions       = var.chart_versions
  enable_monitoring    = var.enable_monitoring
  incident_webhook_url = var.incident_webhook_url
}
