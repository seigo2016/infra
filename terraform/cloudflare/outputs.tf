# Sensitive outputs are copied into ansible-vault (tunnel token) or into the
# client's local secret file (service tokens). They live only in the local,
# git-ignored state; read them with `terraform output -raw <name>`.

output "tunnel_id" {
  description = "ID of the research-ops Cloudflare Tunnel"
  value       = cloudflare_zero_trust_tunnel_cloudflared.research_ops.id
}

output "tunnel_token" {
  description = "Connector token for cloudflared on research-ops-cp (vault_research_ops_cloudflared_tunnel_token)"
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.research_ops.token
  sensitive   = true
}

output "access_client_ids" {
  description = "CF-Access-Client-Id per client"
  value       = { for name, token in cloudflare_zero_trust_access_service_token.research_ops : name => token.client_id }
}

output "access_client_secrets" {
  description = "CF-Access-Client-Secret per client"
  value       = { for name, token in cloudflare_zero_trust_access_service_token.research_ops : name => token.client_secret }
  sensitive   = true
}

output "access_client_expires_at" {
  description = "Expiry of each Access service token"
  value       = { for name, token in cloudflare_zero_trust_access_service_token.research_ops : name => token.expires_at }
}

output "backup_bucket" {
  description = "R2 bucket for the Control Plane backups"
  value       = cloudflare_r2_bucket.research_ops_backup.name
}
