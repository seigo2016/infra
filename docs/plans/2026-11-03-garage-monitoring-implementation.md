# Garage monitoring implementation plan

**Goal:** Detect host reachability, Garage availability, capacity and stale R2 backups outside the physical host, with Discord alerts.

**Architecture:** A Cloudflare Worker polls a node_exporter endpoint protected by Access, persists alert state in D1, and sends transitions to Discord. Ansible installs the exporter and publishes backup timestamps. Proxmox ZFS metrics are added after host-specific collection is verified.

**Spec:** `docs/plans/2026-11-03-garage-monitoring-design.md`

1. Test and implement parsing, missing-metric handling, backup age, capacity and three-poll transitions. Verify failed Discord sends remain retryable and recovery is notified.
2. Install and configure Debian node_exporter through Ansible, publish the last-success timestamp without exposing root-only directories, and validate configuration and check mode.
3. Configure Worker, D1, Access and a monitoring route on the existing Tunnel; store credentials as secrets. Verify denied unauthenticated requests, health polling, simulated failure, recovery, and delivery retry.
4. Investigate the Proxmox host and implement its ZFS pool health and free-capacity metrics with restricted privileges. Verify degraded-state handling without changing the actual pool.
5. Record deployment, notification testing, limitations and recovery instructions. Run relevant tests and report any access or deployment blockers.
