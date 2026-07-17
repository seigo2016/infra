# data-store クライアントセットアップ (DVC over Cloudflare Tunnel)

メインWSL機 / 作業用ノート / 大学PC など、`depth-auth` の DVC を使う全マシン
で必要な手順。インバウンドポート開放ゼロで `s3.seigo2016.com` 経由に到達する。

## 0. 前提

- Cloudflare Zero Trust ダッシュボードで
  1. Tunnel `data-store` を作成し VM 側で `cloudflared` が `Healthy`
  2. Public hostname `s3.seigo2016.com` → Service **TCP** `localhost:3904` で公開（Caddy TLS 終端への raw TCP パススルー）
  3. Access Application `s3.seigo2016.com` に Service Token (`depth-auth-dvc-client`) 必須ポリシーを付与
- 上記 Service Token (Client ID / Secret) を取得済み
- Cloudflare DNS に A レコード `s3-local.seigo2016.com → 127.0.0.1`（Proxy status: **DNS only**）が存在する
- VM 上の Caddy が `s3.seigo2016.com` / `s3-local.seigo2016.com` 両方の有効な Let's Encrypt 証明書を保持している

## 1. cloudflared インストール

### Linux (Debian/Ubuntu/WSL)

```bash
sudo mkdir -p /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install -y cloudflared
```

### macOS

```bash
brew install cloudflared
```

### Windows

[公式インストーラ](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) を使用。

## 2. Service Token を保管

`~/.config/cloudflared/depth-auth-dvc.env` (chmod 600):

```
TUNNEL_SERVICE_TOKEN_ID=XXXXXXXXXXXXXXXXXXXXXXXX
TUNNEL_SERVICE_TOKEN_SECRET=YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY
```

```bash
chmod 600 ~/.config/cloudflared/depth-auth-dvc.env
```

## 3. ローカルプロキシを常駐させる (Linux / WSL)

`~/.config/systemd/user/cloudflared-garage.service`:

```ini
[Unit]
Description=cloudflared TCP proxy to s3.seigo2016.com (Garage)
After=network-online.target

[Service]
EnvironmentFile=%h/.config/cloudflared/depth-auth-dvc.env
ExecStart=/usr/bin/cloudflared access tcp \
  --hostname s3.seigo2016.com \
  --url 127.0.0.1:13900 \
  --service-token-id ${TUNNEL_SERVICE_TOKEN_ID} \
  --service-token-secret ${TUNNEL_SERVICE_TOKEN_SECRET}
Restart=on-failure

[Install]
WantedBy=default.target
```

有効化:

```bash
systemctl --user daemon-reload
systemctl --user enable --now cloudflared-garage
systemctl --user status cloudflared-garage
```

macOS は `launchd` plist、Windows は タスクスケジューラまたは `nssm` で同等の常駐化を行う。

## 4. boto3 設定（multipart + path-style）

raw TCP パススルーになったため Cloudflare の 100MB HTTP ボディ制限は適用され
なくなったが、multipart は再開可能性・並列化のため維持する。また
virtual-hosted style だと `depth-auth-dvc.s3-local.seigo2016.com` を解決しよ
うとして失敗するため、`addressing_style = path` を必ず指定する。

`~/.aws/config` に追加:

```ini
[profile garage]
s3 =
    multipart_threshold = 64MB
    multipart_chunksize = 64MB
    max_concurrent_requests = 8
    addressing_style = path
```

DVC 実行時は `AWS_PROFILE=garage` を強制する。`depth-auth/scripts/dvc-garage`
ラッパーを用意済みであれば、それを使う:

```bash
AWS_PROFILE=garage dvc push -r garage
```

## 5. depth-auth 側 DVC 設定

`.dvc/config` (リポジトリにコミット):

```ini
['remote "garage"']
    url = s3://depth-auth-dvc
    endpointurl = https://s3-local.seigo2016.com:13900
    region = garage
[core]
    remote = garage
```

`.dvc/config.local` (gitignored, deploy script の出力からコピー):

```ini
['remote "garage"']
    access_key_id = GK...........
    secret_access_key = ...........
```

## 6. 動作確認

```bash
# プロキシ生存
systemctl --user status cloudflared-garage

# S3 list
AWS_PROFILE=garage \
  aws --endpoint-url=https://s3-local.seigo2016.com:13900 s3 ls s3://depth-auth-dvc

# DVC push (小さなものから)
AWS_PROFILE=garage dvc push -r garage <some-small.dvc>
```

証明書検証は必ず通ること。`--no-verify-ssl` は絶対に付けないこと — 検証に失
敗する場合は構成のどこかが壊れている（`s3-local.seigo2016.com` の A レコード
と VM 側 Caddy の証明書を確認する）。

LAN外（大学 / モバイル回線）からも同じコマンドで動くこと（Tunnel経由なので
ネットワーク場所に依存しない）を必ず確認すること。
