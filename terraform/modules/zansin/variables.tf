# ZANSIN Module Variables

# Proxmox Configuration
variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
}

variable "template_vm_base" {
  description = "Base template for cloning VMs"
  type        = string
}

variable "storage_pool" {
  description = "Storage pool for VM disks"
  type        = string
}

variable "network_bridge" {
  description = "Network bridge for VMs"
  type        = string
  default     = "vmbr0"
}

# VM Configuration
variable "control_vm_name" {
  description = "Name for the control server VM"
  type        = string
  default     = "zansin-control"
}

variable "training_vm_name" {
  description = "Name for the training server VM"
  type        = string
  default     = "zansin-training"
}

variable "vm_cores" {
  description = "Number of CPU cores for each VM"
  type        = number
  default     = 2
}

variable "vm_memory" {
  description = "Memory in MB for each VM"
  type        = number
  default     = 4096
}

variable "disk_size" {
  description = "Disk size for each VM"
  type        = string
  default     = "20G"
}

# Network Configuration
variable "control_ip" {
  description = "IP address for control server"
  type        = string
}

variable "training_ip" {
  description = "IP address for training server"
  type        = string
}

variable "network_prefix" {
  description = "Network prefix (CIDR notation)"
  type        = number
  default     = 24
}

variable "gateway" {
  description = "Network gateway"
  type        = string
}

# SSH Configuration
variable "ssh_user" {
  description = "SSH username (must be 'zansin' for ZANSIN)"
  type        = string
  default     = "zansin"
}

variable "ssh_password" {
  description = "SSH password for zansin user"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key content"
  type        = string
}
