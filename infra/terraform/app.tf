# Application namespace and the secrets the Helm chart consumes.
# Secret values are generated here, never committed. They do live in the local
# state file (git-ignored); in the cloud the state backend is encrypted and the
# values would come from a managed secret store via External Secrets Operator.

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = var.app_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "environment"                        = var.environment
    }
  }
}

# Shared secret between the assistant and the LLM server (llama.cpp --api-key).
resource "random_password" "llm_api_key" {
  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "llm_api_key" {
  metadata {
    name      = "llm-api-key"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    LLM_API_KEY = random_password.llm_api_key.result
  }
}

# Self-signed certificate for the public hostname. In the cloud: cert-manager
# with Let's Encrypt, or the provider's managed certificates (ACM, GCP certs).
resource "tls_private_key" "ingress" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ingress" {
  private_key_pem       = tls_private_key.ingress.private_key_pem
  validity_period_hours = 24 * 90
  early_renewal_hours   = 24 * 14
  dns_names             = [var.hostname]
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]

  subject {
    common_name  = var.hostname
    organization = "llmstack ${var.environment}"
  }
}

resource "kubernetes_secret_v1" "ingress_tls" {
  metadata {
    name      = "gateway-tls"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = tls_self_signed_cert.ingress.cert_pem
    "tls.key" = tls_private_key.ingress.private_key_pem
  }
}

# The CA bundle the demo scripts use with curl --cacert (no -k needed).
resource "local_file" "ingress_ca" {
  filename        = abspath("${path.root}/../../.kube/${local.cluster_name}-ca.pem")
  content         = tls_self_signed_cert.ingress.cert_pem
  file_permission = "0644"
}
