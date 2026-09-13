# Standalone VM for Garage (S3-compatible) DVC remote.
# Exposed externally via Cloudflare Tunnel (cloudflared on the VM); the S3 API
# itself is bound to loopback only.

module "data_store" {
  source = "../modules/data-store"

  proxmox_node     = var.proxmox_node
  template_vm_base = var.template_vm_base
  storage_pool     = var.storage_pool
  network_bridge   = var.network_bridge
  ssh_public_key   = file(var.ssh_public_key_path)

  ip_address     = var.data_store_ip
  network_prefix = var.network_prefix
  gateway        = var.gateway

  cores     = 4
  memory    = 8192
  disk_size = "1100G"
}
