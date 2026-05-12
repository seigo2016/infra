# Port Allocation: hermes-agent VM (172.16.0.210)

Authoritative list of TCP ports bound on the `hermes-agent` VM. When adding a
new MCP server (or any long-lived daemon) via `ansible/setup-mcp-servers.yml`,
allocate the next free port from the MCP range below and add a row here in the
same change.

All MCP servers bind to `127.0.0.1` only; Hermes itself reaches them over
loopback. Do not expose these ports on the VM's external interface.

## Reserved ranges

| Range       | Purpose                          |
|-------------|----------------------------------|
| 8080-8099   | MCP servers (loopback)           |
| 8600-8699   | Hermes platforms (webhook etc.)  |

## Allocations

| Port | Service              | Bind        | Notes                                   |
|------|----------------------|-------------|-----------------------------------------|
| 8080 | google-workspace-mcp | 127.0.0.1   | calendar + tasks                        |
| 8081 | arxiv-mcp-server     | 127.0.0.1   | arXiv search/download, Streamable HTTP  |
| 8644 | hermes webhook       | 0.0.0.0     | mail-ingest route (see hermes config)   |
