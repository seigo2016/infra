# Garage 監視

`ansible/setup-garage-monitor.yml` は VM 上の node_exporter と、root 専用のバックアップ成功マーカーを読み取る systemd timer を設定する。exporter は `127.0.0.1:9100` のみで待ち受ける。成功記録がなければバックアップは未確認となる。通常の data-store セットアップにも同じ role を含む。

Worker は VM のメトリクスを 5 分ごとに pull し、3 回連続の異常と復旧を Discord に通知する。閾値は VM の空き 15%、バックアップ成功から 7 日半。通知状態は D1 に保持し、Discord への送信が失敗したときは再試行する。連続実行や D1 更新時の障害による重複通知はあり得る。

## 導入状態

VM 側、Cloudflare Worker、D1、Discord Webhook、既存 Tunnel の監視用 HTTP ルートと Access のサービス認証は導入済み。認証なしの拒否と認証ありの取得、Worker から Discord への送信、5 分間隔の定期実行を確認した。Cloudflare の Cron 変更は反映に最大 15 分かかる。Proxmox の `rpool` の健全性と `local-zfs` の空き容量も監視対象に含む。

2026-11-04 に変更後の週次バックアップが成功し、Discord への backup 復旧通知を確認した。R2 から試験 VM に復元した実データも全件一致を確認した。

Access サービス認証の有効期限は 2027-11-03。期限前に更新し、必要に応じて Worker の secret を入れ替える。期限切れも監視先への到達失敗として扱われる。Worker の secret が失われた場合は新しいサービス認証情報を作成し、Access のポリシーと Worker の secret を更新する。

## Cloudflare 側で必要な設定

1. 既存 Tunnel に監視専用のホスト名と `http://127.0.0.1:9100` への HTTP ルートを作る。Access を先に設定し、監視用サービス認証に限定する。Garage の既存 TCP ルートは変更しない。
2. D1 を作成し `schema.sql` を適用し、`wrangler.toml` に `DB` binding と監視 URL を設定する。Cloudflare 側には設定中に初期化可能な状態があるため、無認証でメトリクスが読めないことを実際に検証する。
3. Access の Client ID と Client Secret、Discord の Webhook URL を Worker の secret として設定する。Git とログには出力しない。
4. Worker をデプロイし、正常・到達不可・復旧・バックアップ期限切れ・Discord 失敗時の再試行を確認する。監視の検証にはテスト用の endpoint と Webhook を使い、本番 Garage を停止しない。

## Proxmox 監視の復旧

VM から Proxmox の HTTPS API を 5 分ごとに読み、結果を node_exporter に渡す。`rpool` が `ONLINE` でない場合、`local-zfs` の利用可能容量が 15% 未満の場合、または 20 分間取得できない場合に通知する。ストレージの空きは zvol の予約を考慮した Proxmox の値を使う。VM 自体が停止した場合は外部からの到達失敗で検知する。

Proxmox 上に専用の `garage-monitor@pve` と API token `metrics` を作成済み。ロール `GarageMonitorSystemAudit` の `Sys.Audit` は ZFS 一覧 API が `/` で要求する読み取り権限、`GarageMonitorStorageAudit` の `Datastore.Audit` は `/storage/local-zfs` の容量 API 用の読み取り権限。変更権限は付けない。VM の `/etc/garage-monitor/pve.json` と CA 証明書は root のみが読める。

VM を作り直したら、Proxmox 側で同じ専用ユーザーに新しい API token を発行し、`pve.json` に `{"token":"garage-monitor@pve!トークン名=シークレット"}` を root 所有・0600 で置く。Proxmox の `/etc/pve/pve-root-ca.pem` を VM の `/etc/garage-monitor/pve-ca.pem` に配置し、role を再適用する。既存 token の値は再表示できないため、新規発行し、古い token は不要になってから無効化する。認証情報は Git に入れない。Proxmox ホストも作り直す場合は上記ユーザー、ロールと ACL を再作成し、新しい CA を配置する。

ホストを新規構築する場合の権限作成（既存なら再作成しない）:

```bash
pveum role add GarageMonitorSystemAudit -privs Sys.Audit
pveum role add GarageMonitorStorageAudit -privs Datastore.Audit
pveum user add garage-monitor@pve
pveum acl modify / -user garage-monitor@pve -role GarageMonitorSystemAudit
pveum acl modify /storage/local-zfs -user garage-monitor@pve -role GarageMonitorStorageAudit
pveum user token add garage-monitor@pve metrics --privsep 0
```

token の発行結果には秘密が含まれる。表示された値を安全に取り扱い、VM の設定に保存したら不要な一時ファイルを消す。

接続先、ノード、ストレージ、pool が変わる場合は `pve.json` の `api_url`、`node`、`storage`、`pool` で変更できる。既定値はそれぞれ `https://172.16.0.200:8006`、`pve`、`local-zfs`、`rpool`。Proxmox CA が Python 3.13 の strict 検証に対応していないため、そのフラグのみ外し、CA チェーンと接続先ホスト名の検証は有効にしている。

実行ログと Worker のエラーも定期的に確認する。D1 や Worker 自体が動かない場合、この Worker は自身の障害を Discord に通知できない。成功した R2 同期が復元可能性を保証するわけではなく、別途復元試験が必要。

ローカル検証: `node --test monitoring/garage/*.test.mjs`。Cloudflare の設定値や secret はこのリポジトリに保存しない。
