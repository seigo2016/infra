# ZANSIN Module Outputs

output "control_vm_id" {
  description = "Control server VM ID"
  value       = proxmox_vm_qemu.zansin_control.id
}

output "training_vm_id" {
  description = "Training server VM ID"
  value       = proxmox_vm_qemu.zansin_training.id
}

output "control_ip" {
  description = "Control server IP address"
  value       = var.control_ip
}

output "training_ip" {
  description = "Training server IP address"
  value       = var.training_ip
}

output "control_vm_name" {
  description = "Control server VM name"
  value       = proxmox_vm_qemu.zansin_control.name
}

output "training_vm_name" {
  description = "Training server VM name"
  value       = proxmox_vm_qemu.zansin_training.name
}

output "ssh_user" {
  description = "SSH username"
  value       = var.ssh_user
}
