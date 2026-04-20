# Hermes Agent module variables

variable "proxmox_node" {
  description = "Proxmox node to deploy VM on"
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
  description = "Network bridge to connect VM to"
  default     = "vmbr0"
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

# Network settings
variable "ip_address" {
  description = "IP address for the Hermes Agent VM"
  type        = string
}

variable "network_prefix" {
  description = "Network prefix (CIDR notation)"
  default     = "24"
}

variable "gateway" {
  description = "Network gateway address"
  type        = string
}

# VM spec
variable "vm_name" {
  description = "Name for the Hermes Agent VM"
  default     = "hermes-agent"
}

variable "cores" {
  description = "CPU cores for the Hermes Agent VM"
  default     = 2
}

variable "sockets" {
  description = "CPU sockets for the Hermes Agent VM"
  default     = 1
}

variable "memory" {
  description = "Memory in MB for the Hermes Agent VM"
  default     = 4096
}

variable "disk_size" {
  description = "Disk size in GB for the Hermes Agent VM"
  default     = 20
}
