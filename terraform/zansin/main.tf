# ZANSIN Cybersecurity Training Environment
# This configuration creates the complete ZANSIN infrastructure

terraform {
  required_version = ">= 1.0"
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.1-rc9"
    }
  }
}


# Proxmox provider configuration
provider "proxmox" {
  pm_api_url          = var.api_url
  pm_http_headers     = "CF-Access-Client-Id,${var.cf_client_id},CF-Access-Client-Secret,${var.cf_client_secret}"
  pm_log_file         = "zansin-proxmox.log"
  pm_api_token_id     = var.api_token_id
  pm_api_token_secret = var.api_token_secret
}

# Create ZANSIN VMs
module "zansin_environment" {
  source = "../modules/zansin"

  # Proxmox Configuration
  proxmox_node     = var.proxmox_node
  template_vm_base = var.template_vm_base
  storage_pool     = var.storage_pool
  network_bridge   = var.network_bridge

  # VM Configuration
  control_vm_name  = var.control_vm_name
  training_vm_name = var.training_vm_name
  vm_cores         = var.vm_cores
  vm_memory        = var.vm_memory
  disk_size        = var.disk_size

  # Network Configuration
  control_ip     = var.control_ip
  training_ip    = var.training_ip
  network_prefix = var.network_prefix
  gateway        = var.gateway

  # SSH Configuration
  ssh_user       = var.ssh_user
  ssh_password   = var.ssh_password
  ssh_public_key = file(var.ssh_public_key_path)
}

