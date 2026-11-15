variable "api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "cf_client_id" {
  description = "CloudFlare Client ID for authentication"
  type        = string
  sensitive   = true
}

variable "cf_client_secret" {
  description = "CloudFlare Client Secret for authentication"
  type        = string
  sensitive   = true
}

variable "api_token_id" {
  description = "Proxmox API token ID"
  type        = string
  sensitive   = true
}

variable "api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "template_vm_base" {
  description = "Base template for cloning VMs"
  type        = string
  default     = "ubuntu-22.04-base"
}

variable "storage_pool" {
  description = "Storage pool for VM disks"
  type        = string
  default     = "local-zfs"
}

variable "network_bridge" {
  description = "Network bridge for VMs"
  type        = string
  default     = "vmbr0"
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

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
  type        = string
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
  default     = 4
}

variable "vm_memory" {
  description = "Memory in MB for each VM"
  type        = number
  default     = 8192
}

variable "disk_size" {
  description = "Disk size for each VM"
  type        = string
  default     = "20G"
}

# Network Configuration
variable "control_ip" {
  description = "Static IP address for control server"
  type        = string
}

variable "training_ip" {
  description = "Static IP address for training server"
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
