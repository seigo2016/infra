# Port Allocation: research-ops-cp VM

Authoritative list of TCP ports bound on the `research-ops-cp` VM (research-ops
Control Plane: API, engine, PostgreSQL, cloudflared, backup metrics). Add a row
here in the same change that binds a new port.

Every port is bound to `127.0.0.1`. The only way in from outside is the
Cloudflare Tunnel (`cloudflared` on the VM, outbound only), whose single
ingress rule for `research-ops.seigo2016.com` is `http://127.0.0.1:4100`
(`terraform/cloudflare`). Access admits only the listed service tokens; the
Control Plane's own per-host Bridge credential is checked by the API behind it.

No Caddy: the Tunnel terminates TLS at Cloudflare's edge and reaches the API
over loopback on the same VM. Add a local TLS hop only if a client must reach
the VM without the Tunnel.

## Reserved ranges

| Range     | Purpose                                 |
|-----------|-----------------------------------------|
| 4100-4199 | research-ops Control Plane (loopback)   |

## Allocations

| Port | Service              | Bind      | Notes                                                    |
|------|----------------------|-----------|----------------------------------------------------------|
| 4100 | research-ops-api     | 127.0.0.1 | Elysia API (`CP_PORT`); Tunnel ingress `http://127.0.0.1:4100` |
| 5432 | PostgreSQL 18        | 127.0.0.1 | `listen_addresses = 'localhost'`; API and engine use scram over loopback |
| 9100 | node_exporter        | 127.0.0.1 | systemd + textfile backup metrics; not routed through the Tunnel yet |

`research-ops-engine` binds no port. The restore rehearsal VM
(`research-ops-cp-restore-test`) binds only PostgreSQL on loopback.
