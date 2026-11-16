# Non-secret values for the research-ops Control Plane edge. Secrets and IDs are
# TF_VAR_cloudflare_api_token / _account_id / _zone_id / _team_name in .env.
research_ops_hostname       = "research-ops.seigo2016.com"
research_ops_origin_service = "http://127.0.0.1:4100"
research_ops_tunnel_name    = "research-ops-cp"
research_ops_access_clients = ["bridge-1", "chair-1", "pi-1"]
research_ops_backup_bucket  = "research-ops-cp-backup"
