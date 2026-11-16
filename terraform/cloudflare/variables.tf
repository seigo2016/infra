# Cloudflare root variables. Account ID, zone ID and the API token are
# TF_VAR_* in .env and never committed.

variable "cloudflare_api_token" {
  description = "Cloudflare API token (see docs/standards/research-ops-cp-restore.md for the required permissions)"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the Tunnel, Access objects and R2 bucket"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Zone ID of the zone that holds research_ops_hostname"
  type        = string
  sensitive   = true
}

variable "cloudflare_team_name" {
  description = "Zero Trust team name (the <team> in <team>.cloudflareaccess.com). Set via TF_VAR_cloudflare_team_name."
  type        = string
}

variable "research_ops_hostname" {
  description = "Public hostname of the research-ops Control Plane"
  type        = string
}

variable "research_ops_origin_service" {
  description = "Origin the Tunnel forwards to, on the Control Plane VM's loopback"
  type        = string
}

variable "research_ops_tunnel_name" {
  description = "Name of the Cloudflare Tunnel for the Control Plane"
  type        = string
}

variable "research_ops_access_clients" {
  description = "One Access service token per client (e.g. one per Bridge host). Removing a name and applying revokes that client at the edge."
  type        = set(string)
}

variable "research_ops_service_token_duration" {
  description = "Validity of each Access service token"
  type        = string
  default     = "8760h"
}

variable "research_ops_backup_bucket" {
  description = "R2 bucket for pgBackRest and pg_dump backups of the Control Plane"
  type        = string
}

variable "research_ops_backup_bucket_location" {
  description = "R2 location hint for the backup bucket (honoured only on first creation)"
  type        = string
  default     = "apac"
}
