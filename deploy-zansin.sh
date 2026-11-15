#!/bin/bash

# ZANSIN自動デプロイスクリプト
# このスクリプトはZANSINサイバーセキュリティトレーニング環境を自動的にデプロイします

set -e

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ロゴ表示
echo -e "${BLUE}"
cat << 'EOF'
 _____  _    _   _ ____  ___ _   _ 
|__  / / \  | \ | / ___|_ _| \ | |
  / / / _ \ |  \| \___ \| ||  \| |
 / /_/ ___ \| |\  |___) | || |\  |
/____/_/   \_\_| \_|____/___|_| \_|
                                  
Automated Deployment System
EOF
echo -e "${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform/zansin"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"

# 関数定義
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_requirements() {
    log_info "必要なツールを確認しています..."
    
    # Terraform確認
    if ! command -v terraform &> /dev/null; then
        log_error "Terraformが見つかりません。インストールしてください。"
        exit 1
    fi
    
    # Ansible確認
    if ! command -v ansible &> /dev/null; then
        log_error "Ansibleが見つかりません。インストールしてください。"
        exit 1
    fi
    
    log_success "必要なツールが揃っています"
}

check_config() {
    log_info "設定ファイルを確認しています..."
    
    if [ ! -f "$SCRIPT_DIR/.env" ]; then
        log_error ".envファイルが見つかりません。"
        log_info "サンプルファイルからコピーして設定してください："
        log_info "cp $SCRIPT_DIR/.env.example $SCRIPT_DIR/.env"
        log_info "その後、設定値を編集してください。"
        exit 1
    fi
    
    log_info ".envファイルを読み込んでいます..."
    # 値にスペースを含む環境変数にも対応するため、allexportで読み込む
    set -a
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
    set +a

    # 重要なTerraform変数の確認表示
    # OSディスクバスはモジュール内でSCSI固定に統一（k8sと同一レイアウト）
    
    log_success "設定ファイルが見つかりました"
}

deploy_infrastructure() {
    log_info "インフラストラクチャをデプロイしています..."
    
    cd "$TERRAFORM_DIR"
    
    # Terraform初期化
    if [ ! -d ".terraform" ]; then
        log_info "Terraformを初期化しています..."
        terraform init
    fi
    
    # プラン実行
    log_info "Terraformプランを確認しています..."
    terraform plan -out=tfplan
    
    # ユーザー確認
    echo ""
    log_warning "上記のプランでデプロイを実行しますか？"
    read -p "続行するには 'yes' と入力してください: " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "デプロイをキャンセルしました"
        exit 0
    fi
    
    # デプロイ実行
    log_info "デプロイを実行しています（これには10-15分かかる場合があります）..."
    terraform apply tfplan
    
    log_success "インフラストラクチャのデプロイが完了しました"
}

show_results() {
    log_info "デプロイ結果を表示しています..."
    
    cd "$TERRAFORM_DIR"
    terraform output -json > /tmp/zansin_output.json
    
    # 結果を表示
    echo ""
    echo "=============================================="
    echo -e "${GREEN}ZANSIN環境のデプロイが完了しました！${NC}"
    echo "=============================================="
    
    # 接続情報を表示
    terraform output setup_instructions
    
    echo ""
    log_info "デプロイされたリソース："
    terraform state list
}

cleanup() {
    log_info "一時ファイルをクリーンアップしています..."
    rm -f /tmp/zansin_output.json
    rm -f "$TERRAFORM_DIR/tfplan"
}

show_help() {
    echo "ZANSIN自動デプロイスクリプト"
    echo ""
    echo "使用方法:"
    echo "  $0 [オプション]"
    echo ""
    echo "オプション:"
    echo "  deploy    - ZANSIN環境をデプロイ"
    echo "  destroy   - ZANSIN環境を削除"
    echo "  status    - 現在の状態を表示"
    echo "  ansible   - Ansibleで構成のみ実行（Terraformと分離）"
    echo "  help      - このヘルプを表示"
    echo ""
    echo "例:"
    echo "  $0 deploy   # 環境をデプロイ"
    echo "  $0 destroy  # 環境を削除"
}

destroy_infrastructure() {
    log_warning "ZANSIN環境を削除しようとしています..."
    echo ""
    log_warning "この操作は取り消せません。すべてのVMとデータが削除されます。"
    read -p "本当に削除しますか？ 'DELETE' と入力してください: " confirm
    
    if [ "$confirm" != "DELETE" ]; then
        log_info "削除をキャンセルしました"
        exit 0
    fi
    
    cd "$TERRAFORM_DIR"
    log_info "環境を削除しています..."
    terraform destroy -auto-approve
    
    log_success "ZANSIN環境が削除されました"
}

show_status() {
    log_info "ZANSIN環境の状態を確認しています..."
    
    cd "$TERRAFORM_DIR"
    
    if [ ! -f "terraform.tfstate" ]; then
        log_info "まだデプロイされていません"
        exit 0
    fi
    
    echo "現在のリソース:"
    terraform state list
    
    echo ""
    echo "出力情報:"
    terraform output
}

# メイン処理
case "${1:-deploy}" in
    "deploy")
        log_info "ZANSIN自動デプロイを開始します..."
        check_requirements
        check_config
        deploy_infrastructure
        show_results
        cleanup
        ;;
    "destroy")
        destroy_infrastructure
        cleanup
        ;;
    "status")
        show_status
        ;;
    "ansible")
        log_info "Ansible構成（Terraformと分離）を実行します..."
        check_requirements
        # Ansible は環境変数 TF_VAR_* を参照
        ansible-playbook -i ansible/inventory.zansin.yml ansible/playbooks/zansin-setup.yml --check || true
        read -p "本実行しますか？ 'yes' と入力: " go
        if [ "$go" = "yes" ]; then
          ansible-playbook -i ansible/inventory.zansin.yml ansible/playbooks/zansin-setup.yml
        else
          log_info "Ansible本実行をスキップしました"
        fi
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        log_error "不明なコマンド: $1"
        show_help
        exit 1
        ;;
esac

log_success "処理が完了しました！"
