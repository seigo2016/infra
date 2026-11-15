# research-ops Bridge クライアントの設定（Cloudflare Access 経由）

Host Bridge や運用の端末から research-ops の Control Plane
（`https://research-ops.seigo2016.com`）に届くための設定。受け口の開放は不要で、
クライアントは HTTPS で外向きに接続するだけ。

## 認証は 2 層

1. **Cloudflare Access のサービス認証**（このリポジトリが管理する）。Tunnel の前で、
   一覧にあるサービストークンだけを通す。クライアントごとに 1 つ発行するので、
   1 台だけ締め出せる。
2. **Control Plane が発行するホストごとの Bridge 認証**（research-ops 側が管理する）。
   Access はこれの代わりにならない。Access を通っても、API はホストの資格を
   別に確かめ、取り消せる。

## 1. サービストークンを発行する

`terraform/cloudflare/terraform.tfvars` の `research_ops_access_clients` に
クライアントの名前（例: `bridge-1`）を足して apply する。名前は識別用で、
個人名やホスト名を入れなくてよい。

```bash
cd terraform/cloudflare
terraform output -json access_client_ids
terraform output -json access_client_secrets   # 秘密。画面とログに残さない
terraform output -json access_client_expires_at
```

## 2. クライアントに置く

`~/.config/research-ops/access.env`（`chmod 600`）:

```
CF_ACCESS_CLIENT_ID=XXXXXXXX.access
CF_ACCESS_CLIENT_SECRET=YYYYYYYY
```

すべての要求に次のヘッダーを付ける。

```
CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID
CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET
```

## 3. 確かめる

```bash
set -a; . ~/.config/research-ops/access.env; set +a
# ヘッダーなし: Access が拒否する（401）。200 / 404 / 5xx なら origin まで届いており fail-open
curl -sS -o /dev/null -w '%{http_code}\n' https://research-ops.seigo2016.com/v1/projects/00000000-0000-0000-0000-000000000000/state-bundle
# ヘッダーあり: API が答える（存在しない ID なら 404）
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  https://research-ops.seigo2016.com/v1/projects/00000000-0000-0000-0000-000000000000/state-bundle
```

アプリには `service_auth_401_redirect = true` を設定しているので、拒否はログイン
画面へのリダイレクトではなく 401 で返る。

## long-poll の秒数

Cloudflare のプロキシは origin の応答を約 100 秒で打ち切り、524 を返す
（Free / Pro / Business の既定値。契約と Tunnel での値は導入時に確かめる）。
Bridge の long-poll は、サーバーが **60 秒以内** に応答を返す（仕事がなければ空で返す）
ように決め、クライアントはすぐに次の要求を出す。切断や 524 は通常の再接続として扱う。

## 取り消しと更新

- 1 台を締め出す: `research_ops_access_clients` から名前を外して apply する。
  そのトークンは削除され、Access は即座に拒否する。Control Plane 側のホストの資格も
  別に取り消す。
- 期限: 既定は 1 年（`research_ops_service_token_duration`）。`access_client_expires_at`
  を見て、期限前に名前を変えて新しいトークンを発行し、入れ替えてから古い名前を外す。
- 秘密を失ったら: 同じ手順で新しいトークンを発行する。値は再表示できるが（ローカルの
  state にある）、漏れた疑いがあるなら作り直す。
