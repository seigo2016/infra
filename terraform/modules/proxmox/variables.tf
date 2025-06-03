# Proxmox provider variables

variable "api_url" {
  description = "The URL of the Proxmox API"
  default     = "https://proxmox.seigo2016.com/api2/json/"
}

variable "cf_client_id" {
  description = "Cloudflare Access Client ID"
  default     = ""
  sensitive   = true
}

variable "cf_client_secret" {
  description = "Cloudflare Access Client Secret"
  default     = ""
  sensitive   = true
}

variable "api_token_id" {
  description = "Proxmox API Token ID"
  default     = ""
  sensitive   = true
}

variable "api_token_secret" {
  description = "Proxmox API Token Secret"
  default     = ""
  sensitive   = true
}

variable "debug_enabled" {
  description = "Enable debug mode"
  default     = true
  type        = bool
}

variable "logging_enabled" {
  description = "Enable logging"
  default     = true
  type        = bool
}

variable "log_levels" {
  description = "Log levels configuration"
  default = {
    _default    = "trace"
    _capturelog = ""
  }
  type = map(string)
}

variable "log_file" {
  description = "Path to log file"
  default     = "proxmox.log"
}
