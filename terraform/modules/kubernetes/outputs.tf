# Kubernetes module outputs

output "master_ip" {
  description = "IP address of the Kubernetes master node"
  value       = var.master_ip
}

output "worker_ips" {
  description = "IP addresses of the Kubernetes worker nodes"
  value       = var.worker_ips
}

output "master_node_id" {
  description = "ID of the master node VM"
  value       = proxmox_vm_qemu.k8s_master.id
}

output "worker_node_ids" {
  description = "IDs of the worker node VMs"
  value       = proxmox_vm_qemu.k8s_worker.*.id
}
