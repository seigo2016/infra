# Proxmox provider configuration module

terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.1-rc9"
    }
  }
}

provider "proxmox" {
  pm_api_url          = var.api_url
  pm_http_headers     = "CF-Access-Client-Id,${var.cf_client_id},CF-Access-Client-Secret,${var.cf_client_secret}"
  pm_debug            = var.debug_enabled
  pm_log_enable       = var.logging_enabled
  pm_log_levels       = var.log_levels
  pm_log_file         = var.log_file
  pm_api_token_id     = var.api_token_id
  pm_api_token_secret = var.api_token_secret
}
