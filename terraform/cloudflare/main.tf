# Cloudflare edge for the research-ops Control Plane only: a remotely managed
# Tunnel with one HTTP route to the API on the VM's loopback, its DNS record,
# an Access application that admits only the listed service tokens, and the R2
# bucket that holds the backups. Existing services are not managed here.
#
# Access is the outer gate. It does not replace the per-host Bridge credential
# that the Control Plane API issues and revokes itself.

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

resource "random_bytes" "tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "research_ops" {
  account_id    = var.cloudflare_account_id
  name          = var.research_ops_tunnel_name
  config_src    = "cloudflare"
  tunnel_secret = random_bytes.tunnel_secret.base64
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "research_ops" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.research_ops.id

  # Route traffic only once Access guards the hostname.
  depends_on = [cloudflare_zero_trust_access_application.research_ops]

  config = {
    ingress = [
      {
        hostname = var.research_ops_hostname
        service  = var.research_ops_origin_service
        # cloudflared itself refuses requests without a valid Access token, so
        # traffic stays closed even if the Access application is removed.
        origin_request = {
          access = {
            required  = true
            team_name = var.cloudflare_team_name
            aud_tag   = [cloudflare_zero_trust_access_application.research_ops.aud]
          }
        }
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "research_ops" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.research_ops.id
}

resource "cloudflare_dns_record" "research_ops" {
  zone_id = var.cloudflare_zone_id
  name    = var.research_ops_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.research_ops.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "research-ops Control Plane (Cloudflare Tunnel). Managed by terraform/cloudflare."

  depends_on = [cloudflare_zero_trust_access_application.research_ops]
}

resource "cloudflare_zero_trust_access_service_token" "research_ops" {
  for_each = var.research_ops_access_clients

  account_id = var.cloudflare_account_id
  name       = "research-ops-${each.key}"
  duration   = var.research_ops_service_token_duration
}

resource "cloudflare_zero_trust_access_policy" "research_ops_clients" {
  account_id = var.cloudflare_account_id
  name       = "research-ops service tokens"
  decision   = "non_identity"

  include = [
    for token in cloudflare_zero_trust_access_service_token.research_ops : {
      service_token = {
        token_id = token.id
      }
    }
  ]
}

resource "cloudflare_zero_trust_access_application" "research_ops" {
  account_id = var.cloudflare_account_id
  name       = "research-ops"
  type       = "self_hosted"
  domain     = var.research_ops_hostname

  destinations = [
    {
      type = "public"
      uri  = var.research_ops_hostname
    },
  ]

  # Non-browser clients get 401 instead of a login redirect.
  service_auth_401_redirect = true
  app_launcher_visible      = false
  session_duration          = "24h"

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.research_ops_clients.id
      precedence = 1
    },
  ]
}

resource "cloudflare_r2_bucket" "research_ops_backup" {
  account_id = var.cloudflare_account_id
  name       = var.research_ops_backup_bucket
  location   = var.research_ops_backup_bucket_location

  # The only off-host copy of the Control Plane database. Remove this guard
  # deliberately, never as part of a routine change.
  lifecycle {
    prevent_destroy = true
  }
}
