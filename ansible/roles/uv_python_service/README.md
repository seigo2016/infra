# Role: `uv_python_service`

Deploy a `uv`-managed Python application as a hardened systemd service. Designed
for MCP servers and similar long-lived Python daemons on the `hermes-agent` VM.

The role contract is documented in
`docs/standards/ansible-role-boundaries.md` (in the `hermes-agent` repository).
The systemd hardening flags it applies are in
`docs/standards/systemd-hardening.md`.

## Required parameters

| Variable | Example |
|---|---|
| `service_name` | `google-workspace-mcp` |
| `service_user` | `gwmcp` |
| `service_home` | `/opt/google-workspace-mcp` |
| `git_repo` | `https://github.com/taylorwilsdon/google_workspace_mcp.git` |
| `git_version` | `v1.20.0` (must follow `docs/standards/upstream-pinning.md`) |
| `exec_start` | `{{ service_venv_dir }}/bin/python {{ service_app_dir }}/main.py --transport streamable-http --tools calendar tasks` |
| `read_write_paths` | `["/opt/google-workspace-mcp", "/var/lib/google-workspace-mcp"]` |

## Optional parameters

| Variable | Default | Notes |
|---|---|---|
| `python_version` | `"3.11"` | passed to `uv venv --python` |
| `install_command` | `'uv pip install -e "."'` | run inside venv |
| `state_dir` | `/var/lib/{{ service_name }}` | created with mode 0700 |
| `env_dir` | `/etc/{{ service_name }}` | created with mode 0750 |
| `hardening_profile` | `python-mcp-server` | also: `python-agent-runtime` (no extras beyond baseline) |
| `restart_policy` | `on-failure` | systemd Restart= |
| `restart_sec` | `10` | systemd RestartSec= |
| `service_description` | `"{{ service_name }} (uv-managed Python service)"` | unit Description= |
| `extra_environment` | `{}` | dict of `Environment=` entries on the unit |
| `after_targets` | `["network-online.target"]` | systemd After= |
| `wants_targets` | `["network-online.target"]` | systemd Wants= |

## Example call

```yaml
- name: Provision Google Workspace MCP
  ansible.builtin.include_role:
    name: uv_python_service
  vars:
    service_name: google-workspace-mcp
    service_user: gwmcp
    service_home: /opt/google-workspace-mcp
    git_repo: https://github.com/taylorwilsdon/google_workspace_mcp.git
    git_version: v1.20.0
    exec_start: >-
      /opt/google-workspace-mcp/app/venv/bin/python
      /opt/google-workspace-mcp/app/main.py
      --transport streamable-http
      --tools calendar tasks
    read_write_paths:
      - /opt/google-workspace-mcp
      - /var/lib/google-workspace-mcp
    extra_environment:
      WORKSPACE_MCP_HOST: "127.0.0.1"
      WORKSPACE_MCP_PORT: "8080"
      GOOGLE_MCP_CREDENTIALS_DIR: "/var/lib/google-workspace-mcp/credentials"
```

Secrets in the unit's `EnvironmentFile=` (`/etc/{{ service_name }}/.env`) are
populated separately. Today this is manual; the ToBe is SOPS-decrypted templating
per `docs/standards/secrets-management.md`.
