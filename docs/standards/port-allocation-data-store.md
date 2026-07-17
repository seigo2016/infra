# Port Allocation: data-store VM

Authoritative list of TCP ports bound on the `data-store` VM (Garage S3 +
cloudflared + rclone backup).

All Garage ports are bound to `127.0.0.1` only. External access is provided
exclusively via Cloudflare Tunnel (`cloudflared` on the same VM), reachable
under `https://s3.seigo2016.com` with a Cloudflare Access Service Token.

## Reserved ranges

| Range       | Purpose                          |
|-------------|----------------------------------|
| 3900-3999   | Object storage (Garage, loopback) |

## Allocations

| Port | Service          | Bind        | Notes                                                        |
|------|------------------|-------------|--------------------------------------------------------------|
| 3900 | garage S3 API    | 127.0.0.1   | published as s3.seigo2016.com via cloudflared tunnel         |
| 3901 | garage RPC       | 127.0.0.1   | single-node, loopback only                                   |
| 3902 | garage S3 web    | 127.0.0.1   | unused                                                       |
| 3903 | garage admin API | 127.0.0.1   | metrics + admin token (see vault_garage_admin_token)         |

## Client-side loopback convention

Clients (WSL / laptop / lab PC) run `cloudflared access tcp` as a local proxy
binding to **`127.0.0.1:13900`**. DVC then talks to
`http://127.0.0.1:13900`. See `docs/clients/data-store-client-setup.md` for
setup.
