variable "name" {
  description = "Cluster name; also the prefix of the node container names."
  type        = string
}

variable "node_image" {
  description = "kindest/node image, pinned by digest."
  type        = string
}

variable "worker_count" {
  description = "Number of worker nodes (the stand-in for a node pool size)."
  type        = number

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 4
    error_message = "worker_count must be between 1 and 4 on a laptop."
  }
}

variable "https_host_port" {
  description = "Port on the laptop that maps to the ingress controller's HTTPS port."
  type        = number
}

variable "listen_address" {
  description = "Host address the HTTPS port binds to. 127.0.0.1 keeps the cluster off the LAN."
  type        = string
  default     = "127.0.0.1"
}

variable "kubeconfig_path" {
  description = "Where to write this cluster's kubeconfig (one file per environment)."
  type        = string
}
