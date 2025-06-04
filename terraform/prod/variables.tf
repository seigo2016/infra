# Production environment variables

# Proxmox config
variable "api_url" {
  description = "The URL of the Proxmox API"
}

variable "cf_client_id" {
  description = "Cloudflare Access Client ID"
  sensitive   = true
}

variable "cf_client_secret" {
  description = "Cloudflare Access Client Secret"
  sensitive   = true
}

variable "api_token_id" {
  description = "Proxmox API Token ID"
  sensitive   = true
}

variable "api_token_secret" {
  description = "Proxmox API Token Secret"
  sensitive   = true
}

# VM config
variable "proxmox_node" {
  description = "Proxmox node to deploy VMs on"
  default     = "pve"
}

variable "template_vm_base" {
  description = "Base VM template name to clone from"
}

variable "storage_pool" {
  description = "Storage pool to use for VM disks"
  default     = "local-zfs"
}

variable "network_bridge" {
  description = "Network bridge to connect VMs to"
  default     = "vmbr0"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
}

# Network config
variable "master_ip" {
  description = "IP address for the master node"
}

variable "worker_ips" {
  description = "List of IP addresses for worker nodes"
  type        = list(string)
}

variable "network_prefix" {
  description = "Network prefix (CIDR notation)"
}

variable "gateway" {
  description = "Network gateway address"
}
