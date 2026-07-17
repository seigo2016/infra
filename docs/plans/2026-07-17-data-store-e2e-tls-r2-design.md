# data-store 改修設計: エンドツーエンドTLS化 + R2暗号化バックアップ

Date: 2026-07-17
Status: Approved

## 背景と現状

`data-store` VM (172.16.0.220) は 2026-05-25 にデプロイ済みで、以下が稼働中:

- Garage v2.0.0 シングルノード、バケット `depth-auth-dvc`（データはほぼ空、実運用前）
- cloudflared Tunnel: `s3.seigo2016.com` → `http://localhost:3900`、Cloudflare
  Access Service Token で保護
- rclone crypt による日次バックアップ → **Dropbox**

今回の要件との差分:

1. **Cloudflare に対しても暗号化されていない** — Tunnel 入口が平文 HTTP
   のため、Cloudflare エッジで S3 ペイロードが平文で見える。
2. **バックアップ先が R2 ではない** — 要件は Cloudflare R2 への
   クライアント側暗号化バックアップ。

DVC 想定データ総量は 100〜500GB。現行ディスク (1.1TB) で足りる。

## A. エンドツーエンドTLS化

VM 上に Caddy（cloudflare-dns モジュール入りビルド）を追加し、TLS 終端を
VM 内に移す。

- **Caddy**: `127.0.0.1:3904` で TLS 待ち受け → `127.0.0.1:3900`（Garage S3）
  へ reverse_proxy。証明書は Let's Encrypt **DNS-01**（Cloudflare API
  トークン、Zone DNS 編集権限のみのスコープ）で自動取得・更新。
- **Tunnel ingress 変更**（ダッシュボード手作業）: `s3.seigo2016.com` の
  service を `http://localhost:3900` → **`tcp://localhost:3904`**。
  生 TCP パススルーになるため Cloudflare エッジでは暗号文のみ。副産物として
  Cloudflare の 100MB リクエストボディ制限も適用外になる。
  Access (Service Token) のゲートは維持。
- **クライアント側の証明書検証**: `/etc/hosts` 改変は `cloudflared access tcp`
  自身の名前解決を壊すため使わない。代わりに
  **`s3-local.seigo2016.com` → `127.0.0.1` のパブリック A レコード（DNS only）**
  を作成し、Caddy が `s3.seigo2016.com` と `s3-local.seigo2016.com`
  それぞれの証明書を取得する（SNI で選択される）。クライアントは:
  - `cloudflared access tcp --hostname s3.seigo2016.com --url 127.0.0.1:13900`
    （従来どおり）
  - DVC endpointurl = `https://s3-local.seigo2016.com:13900`、`use_ssl = true`
    → 正規の証明書検証が通る。

## B. バックアップ: Dropbox → R2 置き換え

rclone crypt レイヤ（クライアント側暗号化）は流用し、リモート定義のみ差し替え。

- R2 バケット `depth-auth-backup` + バケットスコープの S3 API トークンを
  手動作成（手順は実装計画に記載）。
- `rclone.conf`: `dropbox-raw` / `dropbox-crypt` を削除し、
  `r2-raw`（type s3, provider Cloudflare,
  endpoint `https://<account_id>.r2.cloudflarestorage.com`）+
  `r2-crypt`（crypt over `r2-raw:depth-auth-backup`）に置換。
  crypt パスワード/salt は**既存値を流用**（1Password にバックアップ済み）。
- systemd timer 群は宛先を `r2-crypt:dvc-cache` に変更。
  バックアップ sync は**日次 → 週次（日曜 03:30）**に変更（RPO 最大7日を
  許容。頻度はコストにほぼ影響せず、R2 コストは保存容量で決まる）。
  meta-snapshot（Garage メタDB）は**日次のまま、暗号化して R2 の
  `meta-snapshots/` にもアップロードする**（メタDBの RPO は1日。
  ローカル・リモートとも 7 世代保持でプルーニング）。
  trash は日付ディレクトリ名（`trash/YYYY-MM-DD/`）ベースで
  30日経過分を purge（月曜 04:00 実行）。
- vault 変更:
  - 削除: `vault_dropbox_token_json`
  - 追加: `vault_r2_access_key_id`, `vault_r2_secret_access_key`,
    `vault_r2_account_id`, `vault_cloudflare_dns_api_token`（Caddy 用）
- コスト: 100〜500GB で月 $1.5〜7.5、egress 無料。
- 復元手順（R2 → Garage 逆 sync）をドキュメント化する。

## C. 変更対象と移行手順

### コード変更

- 新ロール `ansible/roles/caddy/`
- `ansible/roles/rclone-backup/` 改修（リモート定義・unit 宛先）
- `ansible/group_vars/data-store/vault.yml.example` 更新
- `ansible/setup-data-store.yml` に caddy ロール追加
- `docs/standards/port-allocation-data-store.md` に 3904 追加
- `docs/clients/data-store-client-setup.md` を HTTPS 前提に書き直し

### 手作業（Cloudflare ダッシュボード）

1. R2 バケット + S3 API トークン作成
2. DNS 編集用 API トークン作成（Zone: seigo2016.com, DNS:Edit のみ）
3. `s3-local.seigo2016.com` → `127.0.0.1` の A レコード（DNS only）
4. Tunnel ingress を `tcp://localhost:3904` に変更

### 移行順序（データが空なのでリスク低）

1. Ansible 適用（caddy 追加・rclone 差し替え）
2. Caddy の証明書取得を確認
3. Tunnel ingress 切り替え
4. クライアントから DVC push 検証
5. `systemctl start garage-backup.service` で R2 到達確認
6. Dropbox 側の残骸（リモート定義・既存バックアップフォルダ）を掃除

## 却下した代替案

- **自前CA / 自己署名証明書**: 外部依存ゼロだがクライアント台数分の CA 配布
  と更新の手間が増えるため却下。
- **R2 + Dropbox 併用**: 管理対象が倍になるため R2 一本化。
- **Terraform での R2 管理**: アカウントレベル API トークンを Terraform に
  渡す必要があり管理対象が増えるため、一度きりの作業として手動作成。
- **クライアント /etc/hosts 改変**: `cloudflared access tcp` の名前解決を
  壊すため `s3-local` パブリック A レコード方式を採用。
