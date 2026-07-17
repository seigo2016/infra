# Port Allocation: data-store VM

Authoritative list of TCP ports bound on the `data-store` VM (Garage S3 +
Caddy TLS + cloudflared + rclone backup).

All Garage ports are bound to `127.0.0.1` only. External access is provided
exclusively via Cloudflare Tunnel (`cloudflared` on the same VM), whose ingress
for `s3.seigo2016.com` is `tcp://localhost:3904` — a Caddy TLS terminator on
the VM — so Cloudflare's edge only carries ciphertext. Access is still gated
by a Cloudflare Access Service Token.

## Reserved ranges

| Range       | Purpose                          |
|-------------|----------------------------------|
| 3900-3999   | Object storage (Garage, loopback) |

## Allocations

| Port | Service          | Bind        | Notes                                                        |
|------|------------------|-------------|--------------------------------------------------------------|
| 3900 | garage S3 API    | 127.0.0.1   | upstream of caddy (3904); not exposed directly               |
| 3901 | garage RPC       | 127.0.0.1   | single-node, loopback only                                   |
| 3902 | garage S3 web    | 127.0.0.1   | unused                                                       |
| 3903 | garage admin API | 127.0.0.1   | metrics + admin token (see vault_garage_admin_token)         |
| 3904 | caddy TLS (S3)   | 127.0.0.1   | TLS terminator; tunnel ingress tcp://localhost:3904          |

## Client-side loopback convention

Clients (WSL / laptop / lab PC) run `cloudflared access tcp` as a local proxy
binding to **`127.0.0.1:13900`**. DVC then talks to
`https://s3-local.seigo2016.com:13900` — a public A record pointing at
`127.0.0.1` (DNS only), so the hostname resolves to the local proxy while the
certificate validates against the Caddy-served SAN. See
`docs/clients/data-store-client-setup.md` for setup.
