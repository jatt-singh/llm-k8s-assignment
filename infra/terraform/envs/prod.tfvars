# prod: an extra worker so replicas spread across nodes; separate host port so
# it can run next to dev. Reachable at https://app.prod.llmstack.local:9443
environment       = "prod"
worker_count      = 2
https_host_port   = 9443
hostname          = "app.prod.llmstack.local"
enable_monitoring = true
