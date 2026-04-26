# Infra
seigo2016.workの次期インフラ構成を管理するリポジトリ

## リポジトリ構造
```
proxmox-terraform/
├── terraform/            # Terraform設定
│   ├── prod/             # 本番環境
│   ├── modules/          # 再利用可能なTerraformモジュール
│       ├── kubernetes/   # K8sクラスター設定
│       ├── proxmox/      # Proxmox設定
├── ansible/              # クラスター設定用Ansible
```

## セキュリティと環境変数の設定
以下の環境変数を設定
### Proxmox API設定

```bash
export TF_VAR_api_url="https://your-proxmox-server.example.com/api2/json/"
export TF_VAR_cf_client_id="your-cloudflare-client-id"
export TF_VAR_cf_client_secret="your-cloudflare-client-secret"
export TF_VAR_api_token_id="your-proxmox-api-token-id"
export TF_VAR_api_token_secret="your-proxmox-api-token-secret"
```

### ネットワーク設定

```bash
export TF_VAR_master_ip="192.168.1.100"
export TF_VAR_worker_ips='["192.168.1.101", "192.168.1.102", "192.168.1.103"]'
export TF_VAR_hermes_agent_ip="192.168.1.110"
export TF_VAR_network_prefix="24"
export TF_VAR_gateway="192.168.1.1"
```

### Hermes Agent プロビジョニング

`ansible/setup-hermes.yml` は NousResearch/hermes-agent を標準 VM に導入する。
共通 OS baseline (timezone / NTP / unattended-upgrades / 共通 apt パッケージ /
Python 3.11 アサート) は `ansible/base.yml` に切り出されており、本 playbook が
`import_playbook` で先に呼ぶ。
playbook は VM 上の `/etc/hermes-agent/.env` に upstream の `.env.example` をシード
（既存ファイルは上書きしない）するのみで、API キーの埋め込みは行わない。
デプロイ後に運用者が SSH で `.env` を編集するか、VM 内で `hermes setup` / `hermes config set`
を使って設定し、`sudo systemctl restart hermes-agent` する。

```bash
# 1. VM を作成（terraform apply 済み前提）
ansible-playbook -i ansible/inventory.yml ansible/setup-hermes.yml

# 2. API キーを投入して再起動
ssh -J ss debian@"$TF_VAR_hermes_agent_ip" \
  'sudo -u hermes editor /etc/hermes-agent/.env && sudo systemctl restart hermes-agent'
```

秘密管理は SOPS+age への移行が ToBe (`hermes-agent` repo の
`docs/standards/secrets-management.md` 参照)、現状は手動投入が暫定措置。

### MCP サーバプロビジョニング

`ansible/setup-mcp-servers.yml` は Hermes VM 上に MCP server 群を `uv_python_service`
role でデプロイする。各 MCP server は localhost (`127.0.0.1`) bind の HTTP 常駐
サービスとして展開される。設計と運用標準は `hermes-agent` repo の
`docs/plans/google-integration.md` および `docs/standards/*.md` を参照。

```bash
# 1. base.yml + Hermes 本体が既に流れていること
ansible-playbook -i ansible/inventory.yml ansible/setup-hermes.yml

# 2. MCP server 群をデプロイ
ansible-playbook -i ansible/inventory.yml ansible/setup-mcp-servers.yml

# 3. /etc/<service>/.env に OAuth client credentials を投入 (現状は手動、ToBe は SOPS)
ssh -J ss debian@"$TF_VAR_hermes_agent_ip" \
  'sudo -u gwmcp editor /etc/google-workspace-mcp/.env'
ssh -J ss debian@"$TF_VAR_hermes_agent_ip" \
  'sudo systemctl restart google-workspace-mcp'

# 4. 初回 OAuth は SSH port forward + Hermes / workspace-cli から発火
ssh -L 8080:127.0.0.1:8080 -J ss debian@"$TF_VAR_hermes_agent_ip"
# ブラウザで Google 承認 (詳細は hermes-agent の docs/plans/google-integration.md)
```

新しい MCP server を追加する時は `ansible/setup-mcp-servers.yml` の
`mcp_servers` リストに 1 エントリ追加し、`hermes-agent` repo の
`docs/standards/port-allocation.md` から空き port を割当てる。
