terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "0.11.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.4.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.9.1"
    }
  }

  # Partial configuration: the state path comes from envs/<env>.backend.hcl,
  # so every environment has its own state file.
  # In the cloud this becomes an S3 (+ lock table) or GCS backend.
  backend "local" {}
}
