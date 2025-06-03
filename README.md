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
export TF_VAR_network_prefix="24"
export TF_VAR_gateway="192.168.1.1"
```
