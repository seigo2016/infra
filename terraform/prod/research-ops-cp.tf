# research-ops Control Plane: one dedicated VM running the API, the engine and
# PostgreSQL. Public access is a Cloudflare Tunnel defined in terraform/cloudflare;
# every service on the VM binds to loopback. See
# docs/standards/port-allocation-research-ops-cp.md and
# docs/standards/research-ops-cp-restore.md.

module "research_ops_cp" {
  source = "../modules/standalone-vm"

  vm_name     = "research-ops-cp"
  description = "research-ops Control Plane (API, engine, PostgreSQL). Managed by Terraform + Ansible."

  proxmox_node     = var.proxmox_node
  template_vm_base = var.template_vm_base
  storage_pool     = var.storage_pool
  network_bridge   = var.network_bridge
  ssh_public_key   = file(var.ssh_public_key_path)

  ip_address     = var.research_ops_cp_ip
  network_prefix = var.network_prefix
  gateway        = var.gateway

  cores     = 4
  memory    = 8192
  disk_size = "64G"
}

# Isolated restore rehearsal VM. Same definition, a different IP, never booted
# with the node, and only created while research_ops_cp_restore_test_enabled is
# true. ansible/restore-test-research-ops-cp.yml refuses any host whose
# hostname is not this vm_name.
module "research_ops_cp_restore_test" {
  source = "../modules/standalone-vm"
  count  = var.research_ops_cp_restore_test_enabled ? 1 : 0

  vm_name            = "research-ops-cp-restore-test"
  description        = "Disposable restore rehearsal for research-ops-cp. No Tunnel, no backups."
  start_at_node_boot = false

  proxmox_node     = var.proxmox_node
  template_vm_base = var.template_vm_base
  storage_pool     = var.storage_pool
  network_bridge   = var.network_bridge
  ssh_public_key   = file(var.ssh_public_key_path)

  ip_address     = var.research_ops_cp_restore_test_ip
  network_prefix = var.network_prefix
  gateway        = var.gateway

  cores     = 2
  memory    = 4096
  disk_size = "64G"
}
