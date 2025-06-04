# Production environment configuration

module "proxmox_provider" {
  source = "../modules/proxmox"

  api_url          = var.api_url
  cf_client_id     = var.cf_client_id
  cf_client_secret = var.cf_client_secret
  api_token_id     = var.api_token_id
  api_token_secret = var.api_token_secret
  debug_enabled    = false # Less verbose in production
  logging_enabled  = true
  log_file         = "prod-proxmox.log"
}

# Create Kubernetes cluster VMs
module "kubernetes_cluster" {
  source = "../modules/kubernetes"

  proxmox_node     = var.proxmox_node
  template_vm_base = var.template_vm_base
  storage_pool     = var.storage_pool
  network_bridge   = var.network_bridge
  ssh_public_key   = file(var.ssh_public_key_path)

  # Network
  master_ip      = var.master_ip
  worker_ips     = var.worker_ips
  network_prefix = var.network_prefix
  gateway        = var.gateway

  # VM spec
  master_name    = "k8s-master"
  master_cores   = 4
  master_memory  = 8192
  worker_name_prefix = "k8s-worker"
  worker_cores   = 4
  worker_memory  = 8192
}
