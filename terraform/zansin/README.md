# ZANSIN セキュリティトレーニング環境

ZANSINは、サイバーセキュリティトレーニングプラットフォームです。この環境は**一時的なトレーニング用**として構築されます。
本スタックでは、Terraform は VM の作成までを担当し、構成 (Ansible) は Kubernetes 環境と同様に Terraform とは分離して実行します。

## 概要

- **Control Server**: 攻撃の制御と管理を行うサーバー
- **Training Server**: 実際の攻撃対象となるサーバー
- 両サーバー間はSSHで通信し、Ansibleによる自動構築を実行

## 前提条件

- Proxmox VE環境
- 基本的なProxmox設定(.env)が完了済み
- インターネット接続
- 必要リソース: RAM 8GB以上、vCPU 4コア以上、ストレージ 40GB以上

## Ubuntu テンプレート作成手順

### 方法1: Proxmox WebUI
1. **ISOダウンロード**
   - Ubuntu Server 22.04.4 LTSを[公式サイト](https://ubuntu.com/download/server)からダウンロード
   - Proxmox → local → ISO Images → Upload

2. **ベースVMの作成**
   ```
   VM ID: 999（任意）
   Name: ubuntu-22.04-base
   OS: Linux 6.x - 2.6 Kernel
   ISO: ubuntu-22.04.4-live-server-amd64.iso
   System: Default
   Hard Disk: 20GB, local-zfs
   CPU: 2 cores
   Memory: 2048 MB
   Network: vmbr0
   ```

3. **OS インストール**
   - 言語: English
   - Network: DHCP
   - Storage: デフォルト設定を使用
   - Profile: 
     - Name: ubuntu
     - Username: ubuntu
     - Password: ubuntu（後でcloud-initで変更）
   - SSH: Install OpenSSH server (チェック)
   - 追加パッケージ: なし

4. **テンプレート準備**
   ```bash
   # VM起動後、以下を実行：
   sudo apt update && sudo apt upgrade -y
   sudo apt install -y cloud-init
   sudo cloud-init clean
   sudo shutdown -h now
   ```

5. **テンプレート化**
   - VM停止後
   - Hardware → Add → CloudInit Drive
   - Convert to Template
   - 名前を `ubuntu-22.04-template` に変更

### 方法2: CLI（高速）
```bash
# Proxmox host上で実行
wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img
qm create 999 --memory 2048 --cores 2 --name ubuntu-22.04-template --net0 virtio,bridge=vmbr0
qm importdisk 999 ubuntu-22.04-server-cloudimg-amd64.img local-zfs
qm set 999 --scsihw virtio-scsi-pci --scsi0 local-zfs:vm-999-disk-0
qm set 999 --boot c --bootdisk scsi0
qm set 999 --ide2 local-zfs:cloudinit
qm set 999 --serial0 socket --vga serial0
qm set 999 --agent enabled=1
qm template 999
```

## デプロイ手順

### 1. 環境変数設定

ルートディレクトリの`.env`ファイルに以下を追加：

```bash
# ZANSIN Environment
TF_VAR_control_ip=192.168.1.100
TF_VAR_training_ip=192.168.1.101
TF_VAR_ssh_password=secure-password
```

### 2. デプロイ実行（Terraform: インフラのみ）

#### 自動デプロイ（推奨）
```bash
# ルートディレクトリから実行
./deploy-zansin.sh deploy
```

#### 手動デプロイ
```bash
cd terraform/zansin
terraform init
terraform plan
terraform apply
```

## VM仕様

各VMの構成：
- OS: Ubuntu Server 22.04 LTS
- RAM: 4GB
- CPU: 2vCPU
- ディスク: 20GB
- ネットワーク: ブリッジアダプター（vmbr0）

## 構成（Ansible）実行

Kubernetes と同様に、Ansible は環境変数からホスト情報を参照します。`.env` もしくはシェルで `TF_VAR_control_ip` / `TF_VAR_training_ip` / `TF_VAR_ssh_password` 等をエクスポートしてください。

```bash
# ドライラン（推奨）
ansible-playbook -i ansible/inventory.zansin.yml ansible/playbooks/zansin-setup.yml --check

# 実行
ansible-playbook -i ansible/inventory.zansin.yml ansible/playbooks/zansin-setup.yml
```

## 管理コマンド

```bash
# 環境確認
./deploy-zansin.sh status

# 環境削除（一時的な環境のため、使用後は削除推奨）
./deploy-zansin.sh destroy
```

## トラブルシューティング

### SSH接続エラー
```bash
# SSH設定確認
sudo nano /etc/ssh/sshd_config
# PasswordAuthentication yes であることを確認
sudo systemctl restart ssh
```

### テンプレートが見つからないエラー
```bash
# Proxmoxでテンプレート確認
pvesh get /nodes/<node>/qemu --type template

# テンプレートの名前を確認
# terraform/zansin/variables.tfのtemplate_vm_baseと一致する必要がある
```

### Ansible接続エラー
```bash
# 手動SSH確認
ssh zansin@<target-ip>

# インベントリ確認
ansible-inventory -i ansible/inventory.zansin.yml --graph
```

### Cloud-init関連エラー
```bash
# VMでcloud-init状態確認
sudo cloud-init status
sudo cloud-init logs

# cloud-init再実行（必要に応じて）
sudo cloud-init clean
sudo cloud-init init
```

## 注意事項

- **一時的な環境**: この環境はトレーニング目的の一時的なものです
- **セキュリティ**: 本番ネットワークから分離することを推奨
- **リソース管理**: トレーニング終了後は`./deploy-zansin.sh destroy`で削除してください
- **教育目的**: 不正アクセスやサイバー攻撃に悪用することは禁止されています

## ファイル構成

```
terraform/zansin/
├── main.tf              # メイン設定
├── variables.tf         # 変数定義
├── outputs.tf           # 出力定義
└── README.md           # このファイル

../modules/zansin/
├── main.tf              # モジュール本体（provisioner/生成物なし）
├── variables.tf         # モジュール変数
├── outputs.tf           # モジュール出力
└── templates/           # （未使用）

ansible/
├── inventory.yml        # k8s 用
├── inventory.zansin.yml # ZANSIN 用（環境変数参照）
└── group_vars/
    └── all.yml          # ZANSIN 変数（環境変数参照）
```
