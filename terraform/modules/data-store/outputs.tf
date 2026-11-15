# Data Store module outputs

output "ip" {
  description = "IP address of the data-store VM"
  value       = var.ip_address
}

output "vm_name" {
  description = "Name of the data-store VM"
  value       = proxmox_vm_qemu.data_store.name
}

output "vm_id" {
  description = "ID of the data-store VM"
  value       = proxmox_vm_qemu.data_store.id
}
