# Proxmox provider configuration
provider "proxmox" {
  pm_api_url          = var.api_url
  pm_http_headers     = "CF-Access-Client-Id,${var.cf_client_id},CF-Access-Client-Secret,${var.cf_client_secret}"
  pm_debug            = false # Less verbose in production
  pm_log_enable       = true
  pm_log_file         = "prod-proxmox.log"
  pm_api_token_id     = var.api_token_id
  pm_api_token_secret = var.api_token_secret
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
