# Hermes Agent module outputs

output "ip" {
  description = "IP address of the Hermes Agent VM"
  value       = var.ip_address
}

output "vm_name" {
  description = "Name of the Hermes Agent VM"
  value       = proxmox_vm_qemu.hermes_agent.name
}

output "vm_id" {
  description = "ID of the Hermes Agent VM"
  value       = proxmox_vm_qemu.hermes_agent.id
}
