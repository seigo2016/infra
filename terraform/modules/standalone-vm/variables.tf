# Standalone VM module variables. No defaults for site-specific values: the
# caller passes node, template, pool, bridge and network explicitly.

variable "proxmox_node" {
  description = "Proxmox node to deploy the VM on"
  type        = string
}

variable "template_vm_base" {
  description = "Cloud-init VM template name to clone from"
  type        = string
}

variable "storage_pool" {
  description = "Storage pool for the VM disk and cloud-init drive"
  type        = string
}

variable "network_bridge" {
  description = "Network bridge to connect the VM to"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for the cloud-init default user"
  type        = string
}

variable "ip_address" {
  description = "Static IPv4 address of the VM"
  type        = string
  default     = null

  validation {
    condition     = var.ip_address != null && can(cidrhost("${coalesce(var.ip_address, "invalid")}/32", 0))
    error_message = "ip_address must be set to an IPv4 address (export the matching TF_VAR_* in .env)."
  }
}

variable "network_prefix" {
  description = "Network prefix length (CIDR notation)"
  type        = string
}

variable "gateway" {
  description = "Network gateway address"
  type        = string
}

variable "vm_name" {
  description = "VM name. Proxmox cloud-init also uses it as the guest hostname."
  type        = string
}

variable "description" {
  description = "VM description shown in Proxmox"
  type        = string
  default     = ""
}

variable "start_at_node_boot" {
  description = "Start the VM when the Proxmox node boots"
  type        = bool
  default     = true
}

variable "cores" {
  description = "CPU cores"
  type        = number

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

  validation {
    condition     = var.memory >= 1024
    error_message = "memory must be at least 1024 MB"
  }
}

variable "disk_size" {
  description = "Disk size (Proxmox v3 format: 'K', 'M', 'G', 'T' units)"
  type        = string
}
