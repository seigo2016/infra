# Standalone VM module outputs

output "ip" {
  description = "IP address of the VM"
  value       = var.ip_address
}

output "vm_name" {
  description = "Name of the VM (also its cloud-init hostname)"
  value       = proxmox_vm_qemu.vm.name
}

output "vm_id" {
  description = "ID of the VM"
  value       = proxmox_vm_qemu.vm.id
}
