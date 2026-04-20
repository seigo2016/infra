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

ansible-vault / SOPS での秘密管理化は TODO。
