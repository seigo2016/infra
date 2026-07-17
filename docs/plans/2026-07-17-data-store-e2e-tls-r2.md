# data-store E2E TLS + R2 Backup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 稼働中の data-store VM (Garage S3) を、Cloudflare にも平文を見せないエンドツーエンド TLS 化し、バックアップ先を Dropbox から Cloudflare R2（rclone crypt・週次）に置き換える。

**Architecture:** VM 上に Caddy（cloudflare-dns モジュール入り）を追加して `127.0.0.1:3904` で TLS 終端し Garage (`127.0.0.1:3900`) へ reverse_proxy。Tunnel ingress を `tcp://localhost:3904` の生 TCP パススルーに変更。クライアントは公開 A レコード `s3-local.seigo2016.com → 127.0.0.1` を使い正規の証明書検証を通す。バックアップは rclone crypt レイヤを流用しリモートだけ R2 に差し替え、タイマーを週次化。

**Tech Stack:** Ansible / Terraform (変更なし・ベースラインのみ) / Caddy + Let's Encrypt DNS-01 / rclone crypt / Cloudflare R2, Tunnel, Access

**Design doc:** `docs/plans/2026-07-17-data-store-e2e-tls-r2-design.md`

**前提となる現状:**
- VM 172.16.0.220 稼働中（`ssh -i ~/.ssh/id_ed25519_k8s -o ProxyJump=ss debian@172.16.0.220`）
- Garage v2.0.0 active、バケット `depth-auth-dvc` はほぼ空（移行リスクなし）
- 前回セッションの成果物（roles/module/docs）が**未コミット**でワークツリーにある
- ブランチ `feat/data-store-e2e-tls-r2` 上で作業（設計書コミット済み）

---

## Phase 0: ベースライン整理

### Task 0: 前回セッション成果物のベースラインコミット

zansin 関連（`ansible/group_vars/all.yml`, `ansible/inventory.zansin.yml`,
`ansible/setup-zansin.yml`, `deploy-zansin.sh`, `terraform/zansin/`,
`terraform/modules/zansin/`, `.env.example`）は**含めない**。

**Step 1: 暗号化 vault をコミット対象から外す**

`.gitignore` 末尾に追記:

```
ansible/group_vars/*/vault.yml
```

**Step 2: data-store 関連ファイルのみ add**

```bash
git add .gitignore \
  terraform/prod/variables.tf terraform/prod/data-store.tf terraform/prod/outputs.tf \
  terraform/modules/data-store/ \
  ansible/roles/garage/ ansible/roles/cloudflared/ ansible/roles/rclone-backup/ \
  ansible/group_vars/data-store/vars.yml ansible/group_vars/data-store/vault.yml.example \
  ansible/inventory.data-store.yml ansible/setup-data-store.yml \
  deploy-data-store.sh \
  docs/clients/data-store-client-setup.md docs/standards/port-allocation-data-store.md
```

**Step 3: `git status` で vault.yml が untracked に残っていないこと・zansin が staged されていないことを確認**

Expected: staged は上記のみ。`ansible/group_vars/data-store/vault.yml` は ignored。

**Step 4: Commit**

```bash
git commit -m "feat: add data-store baseline (Garage S3 + cloudflared + Dropbox backup)"
```

---

## Phase 1: コード変更

### Task 1: caddy ロール新規作成

**Files:**
- Create: `ansible/roles/caddy/defaults/main.yml`
- Create: `ansible/roles/caddy/tasks/main.yml`
- Create: `ansible/roles/caddy/templates/Caddyfile.j2`
- Create: `ansible/roles/caddy/templates/caddy.env.j2`
- Create: `ansible/roles/caddy/templates/caddy.service.j2`
- Create: `ansible/roles/caddy/handlers/main.yml`

**Step 1: `defaults/main.yml`**

```yaml
---
# Caddy binary is downloaded from the official build service with the
# cloudflare DNS module compiled in (needed for DNS-01 without opening ports).
# NOTE: the build service always serves the latest release and get_url uses
# force: no, so the binary is frozen at first deploy. To upgrade Caddy:
#   ssh data-store 'sudo rm /usr/local/bin/caddy' && re-run the playbook.
caddy_download_url: "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fcaddy-dns%2Fcloudflare"
caddy_bin: /usr/local/bin/caddy

caddy_user: caddy
caddy_group: caddy
caddy_config_dir: /etc/caddy
caddy_data_dir: /var/lib/caddy

caddy_tls_bind: 127.0.0.1
caddy_tls_port: 3904
caddy_upstream: 127.0.0.1:3900

caddy_hostnames:
  - s3.seigo2016.com
  - s3-local.seigo2016.com
caddy_acme_email: mail@seigo2016.com
```

**Step 2: `tasks/main.yml`**

```yaml
---
- name: Create caddy group
  ansible.builtin.group:
    name: "{{ caddy_group }}"
    system: yes

- name: Create caddy user
  ansible.builtin.user:
    name: "{{ caddy_user }}"
    group: "{{ caddy_group }}"
    system: yes
    home: "{{ caddy_data_dir }}"
    create_home: no
    shell: /usr/sbin/nologin

- name: Download caddy with cloudflare-dns module
  ansible.builtin.get_url:
    url: "{{ caddy_download_url }}"
    dest: "{{ caddy_bin }}"
    mode: "0755"
    owner: root
    group: root
    force: no

- name: Create caddy directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: "{{ caddy_user }}"
    group: "{{ caddy_group }}"
    mode: "0750"
  loop:
    - "{{ caddy_config_dir }}"
    - "{{ caddy_data_dir }}"

- name: Render caddy environment file (Cloudflare DNS token)
  ansible.builtin.template:
    src: caddy.env.j2
    dest: "{{ caddy_config_dir }}/caddy.env"
    owner: root
    group: "{{ caddy_group }}"
    mode: "0640"
  no_log: true
  notify: Restart caddy

- name: Render Caddyfile
  ansible.builtin.template:
    src: Caddyfile.j2
    dest: "{{ caddy_config_dir }}/Caddyfile"
    owner: root
    group: "{{ caddy_group }}"
    mode: "0644"
    # validate provisions the config, so the Cloudflare token must be present:
    # pass the envfile rendered by the previous task.
    validate: "{{ caddy_bin }} validate --envfile {{ caddy_config_dir }}/caddy.env --adapter caddyfile --config %s"
  notify: Restart caddy

- name: Install caddy systemd unit
  ansible.builtin.template:
    src: caddy.service.j2
    dest: /etc/systemd/system/caddy.service
    owner: root
    group: root
    mode: "0644"
  notify:
    - Reload systemd
    - Restart caddy

- name: Flush handlers
  ansible.builtin.meta: flush_handlers

- name: Ensure caddy is enabled and started
  ansible.builtin.systemd_service:
    name: caddy
    enabled: yes
    state: started
```

**Step 3: `templates/Caddyfile.j2`**

```
{
	admin off
	email {{ caddy_acme_email }}
}

{% for host in caddy_hostnames %}{{ host }}:{{ caddy_tls_port }}{{ ", " if not loop.last }}{% endfor %} {
	bind {{ caddy_tls_bind }}
	tls {
		dns cloudflare {env.CF_DNS_API_TOKEN}
	}
	reverse_proxy {{ caddy_upstream }}
}
```

（Caddyfile はタブインデントが慣例。ホストごとに SNI で証明書が選択される。）

**Step 4: `templates/caddy.env.j2`**

```
CF_DNS_API_TOKEN="{{ vault_cloudflare_dns_api_token }}"
```

**Step 5: `templates/caddy.service.j2`**

```
[Unit]
Description=Caddy TLS terminator for Garage S3
After=network-online.target
Wants=network-online.target

[Service]
User={{ caddy_user }}
Group={{ caddy_group }}
EnvironmentFile={{ caddy_config_dir }}/caddy.env
Environment=XDG_DATA_HOME={{ caddy_data_dir }}
Environment=XDG_CONFIG_HOME={{ caddy_data_dir }}
ExecStart={{ caddy_bin }} run --config {{ caddy_config_dir }}/Caddyfile
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths={{ caddy_data_dir }}

[Install]
WantedBy=multi-user.target
```

**Step 6: `handlers/main.yml`**

```yaml
---
- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: yes

- name: Restart caddy
  ansible.builtin.systemd_service:
    name: caddy
    state: restarted
```

**Step 7: playbook に組み込み + 構文チェック**

`ansible/setup-data-store.yml` の roles を以下に変更（caddy を garage の後に追加）:

```yaml
  roles:
    - role: garage
    - role: caddy
    - role: cloudflared
    - role: rclone-backup
```

冒頭コメントの `rclone backup to Dropbox (crypt)` も
`TLS termination (Caddy) + rclone backup to R2 (crypt)` に更新。

Run: `cd ansible && ansible-playbook -i inventory.data-store.yml setup-data-store.yml --syntax-check`
Expected: `playbook: setup-data-store.yml`（エラーなし）

**Step 8: Commit**

```bash
git add ansible/roles/caddy/ ansible/setup-data-store.yml
git commit -m "feat: add caddy role for e2e TLS termination on data-store"
```

### Task 2: rclone-backup を R2 週次化

**Files:**
- Modify: `ansible/roles/rclone-backup/defaults/main.yml`
- Modify: `ansible/roles/rclone-backup/templates/rclone.conf.j2`
- Modify: `ansible/roles/rclone-backup/templates/garage-backup.service.j2`
- Modify: `ansible/roles/rclone-backup/templates/garage-backup.timer.j2`

**Step 1: `defaults/main.yml` — dropbox 変数を R2 に差し替え**

```yaml
---
rclone_config_dir: /etc/rclone
rclone_config_path: "{{ rclone_config_dir }}/rclone.conf"

garage_bucket: depth-auth-dvc
backup_r2_remote: r2-raw
backup_crypt_remote: r2-crypt
r2_bucket: depth-auth-backup
backup_dest_path: "{{ backup_crypt_remote }}:dvc-cache"
backup_trash_path_template: "{{ backup_crypt_remote }}:trash"

meta_snapshot_dir: /var/backups/garage-meta
meta_snapshot_retention_count: 7
trash_retention_days: 30
```

**Step 2: `templates/rclone.conf.j2` — dropbox セクションを R2 に置換**

```
[garage-s3]
type = s3
provider = Other
endpoint = http://127.0.0.1:3900
region = garage
access_key_id = {{ garage_local_access_key }}
secret_access_key = {{ garage_local_secret_key }}
acl = private

[{{ backup_r2_remote }}]
type = s3
provider = Cloudflare
endpoint = https://{{ vault_r2_account_id }}.r2.cloudflarestorage.com
region = auto
access_key_id = {{ vault_r2_access_key_id }}
secret_access_key = {{ vault_r2_secret_access_key }}
acl = private
no_check_bucket = true

[{{ backup_crypt_remote }}]
type = crypt
remote = {{ backup_r2_remote }}:{{ r2_bucket }}
filename_encryption = standard
directory_name_encryption = true
password = {{ rclone_crypt_password_obscured.stdout }}
password2 = {{ rclone_crypt_salt_obscured.stdout }}
```

（`no_check_bucket = true`: トークンがバケットスコープだと bucket 作成権限が
なく、存在チェックが 403 になるのを回避。）

**Step 3: `garage-backup.service.j2` — Description のみ変更**

`Description=Weekly rclone sync of Garage bucket to encrypted Cloudflare R2`

ExecStart は変数参照のため変更不要。

**Step 4: `garage-backup.timer.j2` — 週次化**

```
[Unit]
Description=Weekly garage-backup timer

[Timer]
OnCalendar=Sun *-*-* 03:30:00
Persistent=true
RandomizedDelaySec=30m
Unit=garage-backup.service

[Install]
WantedBy=timers.target
```

**Step 5: 構文チェック**

Run: `cd ansible && ansible-playbook -i inventory.data-store.yml setup-data-store.yml --syntax-check`
Expected: エラーなし

**Step 6: Commit**

```bash
git add ansible/roles/rclone-backup/
git commit -m "feat: switch backup destination from Dropbox to R2, weekly schedule"
```

**追補（レビュー反映）: retention 系テンプレートの修正**

上記に加え、レビュー指摘により同ロールの以下 3 点も変更済み:

- `garage-trash-cleanup.service.j2`: `rclone delete --min-age`（オブジェクト
  mtime 基準で削除日と無関係）をやめ、`trash/YYYY-MM-DD/` の日付ディレクトリ名
  を cutoff 日付と辞書順比較して `rclone purge` する方式に変更。
- `garage-trash-cleanup.timer.j2`: 日曜のバックアップ sync と重ならないよう
  `OnCalendar=Mon *-*-* 04:00:00` に変更。
- `garage-meta-snapshot.service.j2`: R2 側 `meta-snapshots/` も
  `meta_snapshot_retention_count` 世代で世代プルーニングを追加
  （ローカルのみ削除で、リモートが無制限に肥大するのを修正）。

### Task 3: vault.yml.example 更新

**Files:**
- Modify: `ansible/group_vars/data-store/vault.yml.example`

**Step 1: 全面書き換え**

```yaml
---
# Example secrets file. Copy to vault.yml and encrypt with:
#   ansible-vault encrypt ansible/group_vars/data-store/vault.yml
#
# Generate vault_garage_rpc_secret with:  openssl rand -hex 32
# Generate vault_garage_admin_token with: openssl rand -hex 32
# rclone crypt password & salt: any high-entropy strings; back up in 1Password.
# vault_cloudflared_tunnel_token: from Cloudflare Zero Trust dashboard when
# creating the data-store tunnel.
# vault_cloudflare_dns_api_token: API token with Zone:DNS:Edit on seigo2016.com
# only (used by Caddy for Let's Encrypt DNS-01).
# vault_r2_*: from Cloudflare dashboard > R2 > Manage R2 API Tokens
# (Object Read & Write, scoped to the depth-auth-backup bucket).

vault_garage_rpc_secret: "REPLACE_ME_64_HEX_CHARS"
vault_garage_admin_token: "REPLACE_ME_64_HEX_CHARS"
vault_rclone_crypt_password: "REPLACE_ME_HIGH_ENTROPY"
vault_rclone_crypt_salt: "REPLACE_ME_HIGH_ENTROPY"
vault_cloudflared_tunnel_token: "REPLACE_ME_FROM_CLOUDFLARE_DASHBOARD"
vault_cloudflare_dns_api_token: "REPLACE_ME_ZONE_DNS_EDIT_TOKEN"
vault_r2_account_id: "REPLACE_ME_CLOUDFLARE_ACCOUNT_ID"
vault_r2_access_key_id: "REPLACE_ME_R2_ACCESS_KEY"
vault_r2_secret_access_key: "REPLACE_ME_R2_SECRET_KEY"
```

**Step 2: Commit**

```bash
git add ansible/group_vars/data-store/vault.yml.example
git commit -m "docs: update vault example for R2 + Caddy DNS-01 secrets"
```

### Task 4: ドキュメント更新

**Files:**
- Modify: `docs/standards/port-allocation-data-store.md`
- Modify: `docs/clients/data-store-client-setup.md`
- Modify: `deploy-data-store.sh`（バナー・destroy 警告文の Dropbox 表記）

**Step 1: ポート表に 3904 追加・前提の書き換え**

Allocations 表に追記:

```
| 3904 | caddy TLS (S3)   | 127.0.0.1   | TLS terminator; tunnel ingress tcp://localhost:3904          |
```

冒頭説明を「Tunnel ingress は `tcp://localhost:3904`（Caddy TLS 終端）。
Cloudflare エッジには暗号文のみ流れる」に更新。
Client-side loopback convention の節を
「DVC は `https://s3-local.seigo2016.com:13900` を使用（公開 A レコードが
127.0.0.1 を指す）」に更新。

**Step 2: クライアント手順書を HTTPS 前提に書き換え**

`docs/clients/data-store-client-setup.md` の変更点:

- 前提節: Tunnel ingress が `tcp://localhost:3904` であること、
  `s3-local.seigo2016.com` → `127.0.0.1` (DNS only) の A レコードが
  存在することを追記
- §4 `~/.aws/config` に `addressing_style = path` を追加
  （virtual-hosted style だと `depth-auth-dvc.s3-local...` を引きに行き失敗する）:

```ini
[profile garage]
s3 =
    multipart_threshold = 64MB
    multipart_chunksize = 64MB
    max_concurrent_requests = 8
    addressing_style = path
```

  100MB 制限の回避という記述は「生 TCP パススルーのため 100MB 制限は
  適用外だが、再開性・並列性のため multipart を維持」に変更
- §5 `.dvc/config`:

```ini
['remote "garage"']
    url = s3://depth-auth-dvc
    endpointurl = https://s3-local.seigo2016.com:13900
    region = garage
[core]
    remote = garage
```

  （`use_ssl = false` を削除。https なので不要。）
- §6 動作確認の endpoint を `https://s3-local.seigo2016.com:13900` に変更し、
  証明書検証が通ること（`--no-verify-ssl` を付けないこと）を明記

**Step 3: `deploy-data-store.sh` の表記更新**

- バナー: `Garage S3 / caddy TLS / cloudflared / rclone-crypt → R2`
- destroy 警告: `Dropbox crypt バックアップ` → `R2 crypt バックアップ`
- ヘルプ: `destroy - VM を削除（バックアップは R2 に残ります）`

**Step 4: Commit**

```bash
git add docs/standards/port-allocation-data-store.md docs/clients/data-store-client-setup.md deploy-data-store.sh
git commit -m "docs: update port allocation, client setup and deploy script for e2e TLS + R2"
```

---

## Phase 2: 手作業（Cloudflare ダッシュボード + vault）

### Task 5: Cloudflare 側リソース作成（ユーザー作業）

**Step 1: R2 バケット**
dash.cloudflare.com → R2 → Create bucket
- Name: `depth-auth-backup`, Location: Asia-Pacific (APAC)

**Step 2: R2 API トークン**
R2 → Manage R2 API Tokens → Create API Token
- Permissions: **Object Read & Write**、Specify bucket: `depth-auth-backup` のみ
- 控える: Access Key ID / Secret Access Key / Account ID
  （エンドポイント `https://<account_id>.r2.cloudflarestorage.com` に表示）

**Step 3: DNS 編集用 API トークン（Caddy 用）**
My Profile → API Tokens → Create Token → "Edit zone DNS" テンプレート
- Zone Resources: Include → Specific zone → `seigo2016.com` のみ

**Step 4: `s3-local` A レコード**
seigo2016.com ゾーン → DNS → Add record
- Type: A, Name: `s3-local`, IPv4: `127.0.0.1`, **Proxy status: DNS only**

**Step 5: Tunnel ingress は まだ変更しない**（Task 7 で Caddy 稼働確認後に切替）

### Task 6: vault.yml に秘密情報を登録

**Step 1:**

```bash
ansible-vault edit ansible/group_vars/data-store/vault.yml
```

- 追加: `vault_cloudflare_dns_api_token`, `vault_r2_account_id`,
  `vault_r2_access_key_id`, `vault_r2_secret_access_key`
- 削除: `vault_dropbox_token_json`

**Step 2: 検証**

```bash
ansible-vault view ansible/group_vars/data-store/vault.yml | grep -c "vault_"
```

Expected: `9`

---

## Phase 3: デプロイと検証

### Task 7: Ansible 適用 + Caddy 証明書確認

**Step 1: 適用**（`--check` は `rclone obscure` 等の command 依存で失敗するため
構文チェック済みならそのまま適用。冪等なので再実行安全）

```bash
./deploy-data-store.sh ansible
```

Expected: failed=0

**Step 2: Caddy 証明書取得を確認**

```bash
ssh -i ~/.ssh/id_ed25519_k8s -o ProxyJump=ss debian@172.16.0.220 \
  'sudo journalctl -u caddy --no-pager | grep -iE "certificate obtained|error" | tail -10'
```

Expected: 両ホスト名で `certificate obtained successfully`、error なし

**Step 3: TLS 応答を検証（VM 上から）**

```bash
ssh -i ~/.ssh/id_ed25519_k8s -o ProxyJump=ss debian@172.16.0.220 \
  'echo | openssl s_client -connect 127.0.0.1:3904 -servername s3-local.seigo2016.com 2>/dev/null | openssl x509 -noout -subject -dates'
```

Expected: `subject=CN=s3-local.seigo2016.com`、有効期限が未来

### Task 8: Tunnel ingress 切替（ユーザー作業）+ 疎通確認

**Step 1:** Zero Trust → Networks → Tunnels → `data-store` → Public Hostname
`s3.seigo2016.com` を編集 → Service: **TCP** / URL: `localhost:3904`
（Access アプリケーションと Service Token ポリシーは変更しない）

**Step 2: クライアント（この WSL）から疎通確認**

`cloudflared-garage` プロキシ稼働状態で:

```bash
curl -sv https://s3-local.seigo2016.com:13900/ -o /dev/null 2>&1 | grep -E "subject:|SSL certificate verify"
```

Expected: `SSL certificate verify ok`（HTTP ステータスは 4xx でよい —
匿名リクエストなので S3 のエラー XML が返る）

### Task 9: DVC クライアント設定 + push 検証

**Step 1:** `docs/clients/data-store-client-setup.md` の手順どおり
`depth-auth` リポジトリの `.dvc/config` を新 endpointurl に更新、
`~/.aws/config` に `addressing_style = path` を追加

**Step 2: S3 操作確認**

```bash
AWS_PROFILE=garage aws --endpoint-url=https://s3-local.seigo2016.com:13900 s3 ls s3://depth-auth-dvc
```

Expected: エラーなし（空リスト可）

**Step 3: 小さい .dvc ファイルで push → pull 検証**

```bash
AWS_PROFILE=garage dvc push -r garage <small>.dvc
AWS_PROFILE=garage dvc pull -r garage <small>.dvc
```

Expected: 成功。以後、本番データの push を開始してよい

### Task 10: R2 バックアップ検証

**Step 1: 手動起動**

```bash
ssh -i ~/.ssh/id_ed25519_k8s -o ProxyJump=ss debian@172.16.0.220 \
  'sudo systemctl start garage-backup.service && sudo tail -5 /var/log/rclone-backup.log'
```

Expected: エラーなし・転送完了ログ

**Step 2: R2 側の内容確認（復号ビュー + 暗号化確認）**

```bash
ssh -i ~/.ssh/id_ed25519_k8s -o ProxyJump=ss debian@172.16.0.220 \
  'sudo rclone --config /etc/rclone/rclone.conf ls r2-crypt:dvc-cache | head -5; \
   sudo rclone --config /etc/rclone/rclone.conf lsd r2-raw:depth-auth-backup'
```

Expected: crypt 経由では平文ファイル名、raw 経由ではランダム暗号名
（= クライアント側暗号化が効いている証拠）

**Step 3: 整合性チェック**

```bash
ssh -i ~/.ssh/id_ed25519_k8s -o ProxyJump=ss debian@172.16.0.220 \
  'sudo rclone --config /etc/rclone/rclone.conf check garage-s3:depth-auth-dvc r2-crypt:dvc-cache'
```

Expected: `0 differences found`

### Task 11: Dropbox 残骸の掃除（ユーザー作業）

- Dropbox の `depth-auth-backup` フォルダを削除
- Dropbox App Console でトークン/アプリを revoke
- （vault からは Task 6 で削除済み、rclone.conf からは Task 7 の適用で消えている）

### Task 12: 仕上げ

**Step 1:** `git status` がクリーンであること（zansin 関連の untracked を除く）を確認

**Step 2:** superpowers:finishing-a-development-branch で PR 作成
（PR 本文に Terraform 変更なし・Ansible 適用済み・検証ログを記載）
