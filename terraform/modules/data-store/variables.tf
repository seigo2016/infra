# Data Store module variables

variable "proxmox_node" {
  description = "Proxmox node to deploy VM on"
  type        = string
  default     = "pve"
}

variable "template_vm_base" {
  description = "Base VM template name to clone from"
  type        = string
  default     = "Debian12CloudInit"
}

variable "storage_pool" {
  description = "Storage pool to use for VM disks"
  type        = string
  default     = "local-zfs"
}

variable "network_bridge" {
  description = "Network bridge to connect VM to"
  type        = string
  default     = "vmbr0"
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

variable "ip_address" {
  description = "IP address for the data-store VM"
  type        = string
}

variable "network_prefix" {
  description = "Network prefix (CIDR notation)"
  type        = string
  default     = "24"
}

variable "gateway" {
  description = "Network gateway address"
  type        = string
}

variable "vm_name" {
  description = "Name for the data-store VM"
  type        = string
  default     = "data-store"
}

variable "cores" {
  description = "CPU cores"
  type        = number
  default     = 4

  validation {
    condition     = var.cores > 0
    error_message = "cores must be greater than 0"
  }
}

variable "sockets" {
  description = "CPU sockets"
  type        = number
  default     = 1
}

variable "memory" {
  description = "Memory in MB"
  type        = number
  default     = 8192

  validation {
    condition     = var.memory >= 1024
    error_message = "memory must be at least 1024 MB (Garage recommends 1GB+)"
  }
}

variable "disk_size" {
  description = "Disk size (Proxmox v3 format: 'K', 'M', 'G', 'T' units)"
  type        = string
  default     = "1100G"
}
