# Kubernetes module variables

# General settings
variable "proxmox_node" {
  description = "Proxmox node to deploy VMs on"
  default     = "pve"
}

variable "template_vm_base" {
  description = "Base VM template name to clone from"
  default     = "Debian12CloudInit"
}

variable "storage_pool" {
  description = "Storage pool to use for VM disks"
  default     = "local-zfs"
}

variable "network_bridge" {
  description = "Network bridge to connect VMs to"
  default     = "vmbr0"
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

# Network settings
variable "master_ip" {
  description = "IP address for the master node"
  type        = string
}

variable "worker_ips" {
  description = "List of IP addresses for worker nodes"
  type        = list(string)
}

variable "network_prefix" {
  description = "Network prefix (CIDR notation)"
  default     = "24"
}

variable "gateway" {
  description = "Network gateway address"
  type        = string
}

# Control plane node
variable "master_name" {
  description = "Name for the master node"
  default     = "k8s-master"
}

variable "master_cores" {
  description = "CPU cores for master node"
  default     = 4
}

variable "master_sockets" {
  description = "CPU sockets for master node"
  default     = 1
}

variable "master_memory" {
  description = "Memory in MB for master node"
  default     = 8192
}

variable "master_disk_size" {
  description = "Disk size in GB for master node"
  default     = 34
}

# Worker node
variable "worker_name_prefix" {
  description = "Name prefix for worker nodes"
  default     = "k8s-worker"
}

variable "worker_cores" {
  description = "CPU cores for worker nodes"
  default     = 4
}

variable "worker_sockets" {
  description = "CPU sockets for worker nodes"
  default     = 1
}

variable "worker_memory" {
  description = "Memory in MB for worker nodes"
  default     = 8192
}

variable "worker_disk_size" {
  description = "Disk size in GB for worker nodes"
  default     = 34
}
