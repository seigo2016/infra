#!/bin/bash
# data-store (Garage S3 + cloudflared + rclone backup) 自動デプロイスクリプト

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
cat << 'EOF'
 ____        _          ____  _
|  _ \  __ _| |_ __ _  / ___|| |_ ___  _ __ ___
| | | |/ _` | __/ _` | \___ \| __/ _ \| '__/ _ \
| |_| | (_| | || (_| |  ___) | || (_) | | |  __/
|____/ \__,_|\__\__,_| |____/ \__\___/|_|  \___|

Garage S3 / caddy TLS / cloudflared / rclone-crypt → R2
EOF
echo -e "${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform/prod"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
TARGET_MODULE="module.data_store"

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_requirements() {
    log_info "必要なツールを確認しています..."
    for tool in terraform ansible ansible-playbook ssh; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool が見つかりません。インストールしてください。"
            exit 1
        fi
    done
    log_success "必要なツールが揃っています"
}

check_config() {
    log_info "設定ファイルを確認しています..."
    if [ ! -f "$SCRIPT_DIR/.env" ]; then
        log_error ".envファイルが見つかりません。"
        log_info "cp $SCRIPT_DIR/.env.example $SCRIPT_DIR/.env のうえ TF_VAR_data_store_ip 等を設定してください。"
        exit 1
    fi
    set -a
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
    set +a
    if [ -z "${TF_VAR_data_store_ip:-}" ]; then
        log_error "TF_VAR_data_store_ip が .env に設定されていません。"
        exit 1
    fi
    log_success "設定ファイルOK (data_store_ip=${TF_VAR_data_store_ip})"
}

deploy_infrastructure() {
    log_info "Terraform (target=${TARGET_MODULE}) を実行します..."
    cd "$TERRAFORM_DIR"
    if [ ! -d ".terraform" ]; then
        terraform init
    fi
    terraform plan -target="$TARGET_MODULE" -out=tfplan
    echo ""
    log_warning "上記プランで data-store VM をデプロイしますか？"
    read -p "続行するには 'yes' と入力してください: " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "デプロイをキャンセルしました"
        exit 0
    fi
    terraform apply tfplan
    rm -f tfplan
    log_success "VM デプロイ完了"
}

run_ansible() {
    log_info "Ansible (setup-data-store.yml) を実行します..."
    cd "$ANSIBLE_DIR"
    # ip 到達待ち
    log_info "SSH 到達を待機 (${TF_VAR_data_store_ip}) ..."
    for _ in $(seq 1 30); do
        if nc -z -w 2 "${TF_VAR_data_store_ip}" 22 2>/dev/null; then
            break
        fi
        sleep 5
    done
    ansible-playbook \
        -i inventory.data-store.yml \
        setup-data-store.yml \
        --ask-vault-pass
    log_success "Ansible 完了"
}

show_credentials() {
    log_info "Garage アクセスキーを取得します (data-store VM の /root/.garage-credentials)..."
    echo ""
    echo "================================================="
    echo -e "${GREEN}以下を depth-auth/.dvc/config.local に貼り付けてください${NC}"
    echo "================================================="
    ssh -i ~/.ssh/id_ed25519_k8s \
        -o ProxyJump=ss -o StrictHostKeyChecking=accept-new \
        debian@"${TF_VAR_data_store_ip}" \
        "sudo cat /root/.garage-credentials"
    echo "================================================="
}

show_help() {
    cat << EOF
data-store 自動デプロイスクリプト

使用方法:
  $0 [オプション]

オプション:
  deploy      - VM を作成し Garage / cloudflared / rclone-backup を構成
  ansible     - Ansible のみ再実行（VM はそのまま）
  credentials - Garage アクセスキーを表示
  destroy     - VM を削除（バックアップは R2 に残ります）
  help        - このヘルプを表示
EOF
}

destroy_infrastructure() {
    log_warning "data-store VM を削除しようとしています。"
    log_warning "R2 crypt バックアップは残りますが、Garage 上のデータ・メタDBは失われます。"
    read -p "本当に削除しますか？ 'DELETE' と入力してください: " confirm
    if [ "$confirm" != "DELETE" ]; then
        log_info "削除をキャンセルしました"
        exit 0
    fi
    cd "$TERRAFORM_DIR"
    terraform destroy -target="$TARGET_MODULE" -auto-approve
    log_success "削除完了"
}

case "${1:-help}" in
    deploy)
        check_requirements
        check_config
        deploy_infrastructure
        run_ansible
        show_credentials
        ;;
    ansible)
        check_requirements
        check_config
        run_ansible
        ;;
    credentials)
        check_config
        show_credentials
        ;;
    destroy)
        check_requirements
        check_config
        destroy_infrastructure
        ;;
    help|--help|-h|*)
        show_help
        ;;
esac
