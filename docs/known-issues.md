# 未対応作業

このリポジトリ／クラスタで**まだやっていない作業**の SSoT。完了した作業の経緯は
git 履歴と merged PR に残っているので、ここには載せない。

優先度の高い順に並べる。

## Garage の復元と監視

- 2026-11-04 の復元試験で見つかった rclone crypt パスワードの不一致は Vault を
  修正済み。正しい R2 と crypt の設定は KeePassXC に添付済みだが、以前 Vault から
  転記したパスワードのメモは更新が必要。Ansible は既存 crypt キーとの不一致を
  検出すると設定を上書きせず停止する。
- R2 から試験 VM への復元は全 622,859 ファイルが一致し、DVC から 1 ファイルを
  取り出せた。KeePassXC から直接設定を取り出す手順の通し確認は残っている。
  週次バックアップの最終成功以降のデータは失われ得る。
- Cloudflare Worker から Garage、バックアップ時刻、ZFS と空き容量を監視する。
  本番のバックアップ成功に伴う Discord 復旧通知は確認済み。
- Garage 標準のメタデータスナップショットはローカルに保持される。
  旧方式で R2 や Dropbox に保存した tar の整合性は未検証。
- OS と Garage は同一 VM ディスク上。ディスク分離は OS 更新や VM 再作成を
  容易にするが、単一 Proxmox ホストの故障には別の復旧先と R2 が必要。
- Debian 13 更新前のローカル VM スナップショットを保持中。更新後の確認と、
  保持期間・削除時期を決める。スナップショットは同じ ZFS pool 上にある。
- data-store 用の ansible-core は 2.21.6 を使用する。修正後の Vault を使った本番 VM の
  check mode は成功し、Caddy のダウンロードと rclone 設定が変更候補として表示された。
  check mode では crypt キー不一致の上書き防止処理を実行しないため、別途照合し、
  現在の crypt パスワード・salt と R2 接続情報が Vault と一致することを確認した。
  復元時は `backup_timers_enabled=false` を明示し、復元完了後に有効化する。
- 復元手順は [`standards/data-store-restore.md`](standards/data-store-restore.md)。

## research-ops Control Plane（`research-ops-cp`）

コードは揃ったが、まだ apply も playbook も流していない。
手順は [`standards/research-ops-cp-restore.md`](standards/research-ops-cp-restore.md)。

- **未検証の前提。** 初回の構築と復元の試験で確かめる。
  - pgBackRest と R2 の組み合わせ（S3 互換、`repo1-s3-uri-style=path`、region `auto`）。
  - Bun の unit が、この hardening（`SystemCallFilter=@system-service`、
    `ProtectSystem=strict` など）の下で動くか。
    `systemd-analyze security research-ops-api` でも見る。
  - `npm ci` で lockfile の Bun が入ること。Debian 13 の nodejs と npm で足りるか。
  - Cloudflare provider 5.28.1 での plan。オフラインでは `terraform fmt` しか通していない。
  - Proxmox の cloud-init が VM 名をホスト名にすること。復元の試験の隔離はこれに頼る。
  - Cloudflare の応答の打ち切り（約 100 秒）。long-poll は 60 秒以内で返す前提。
- **API にまだ認証がない。** WS1 の API は `x-actor-id` を信じるだけで、ホストごとの
  Bridge 認証（RFC §8）がない。今は Access のサービストークンが唯一の門。Bridge を
  つなぐ前に API 側で実装する。
- **engine は FakeRunner だけ。** WS1 の engine は `CP_RUNNER_DIR` の FakeRunner しか
  持たない。本物の runner が入るまで、本番で dispatch させる仕事はない。
- **Control Plane の epoch がスキーマにない。** 復元の dry-run は `lease_epoch` の
  締め出しを数えるだけで、epoch は `NOT RUN` と出す。epoch と、Bridge の journal との
  突き合わせのコマンドを research-ops 側に作り、復元の playbook から呼ぶ。
- **監視は VM の中まで。** node_exporter（`127.0.0.1:9100`）はバックアップと WAL の
  指標を出すが、Tunnel の経路も Worker もない。garage-monitor の Worker を 2 つ目の
  対象に広げ、最後の backup と WAL の遅れの閾値で Discord に知らせる。
- **復元の試験は手で始める。** 月 1 回の目安で、VM の作成から playbook までを
  人が流す。別の物理ホストでの初回の試験も残っている。
- **ダッシュボードの入口。** Access は今サービストークンだけを通す。PI がブラウザで
  使う SPA ができたら、identity の policy を足す。
- **既存への展開。** data-store は OS の baseline を inline で持ち、`host_baseline`
  role を使っていない。data-store と hermes の VM も `standalone-vm` モジュールに
  寄せられるが、state の移動（`moved`）が要るので今はしない。
- **pg_dump の crypt の鍵。** rclone-backup のような、既存の鍵との不一致を検出する
  仕組みはない。鍵を変えると古いダンプは新しい設定では読めない。
- Terraform の state は prod と同じくローカル（`terraform/cloudflare/terraform.tfstate`）。
  Tunnel token とサービストークンの秘密を含むので、Git に入れず暗号化して保管する。

## Proxmox の Terraform provider

当面は Telmate を使う。3.0.2-rc10 への設定名の移行（`onboot` → `start_at_node_boot`、
`vm_state` → `power_state`、`desc` → `description`）は既存 4 VM に apply 済みで、
再起動はなく、plan は差分なし。provider は既定で必要時に自動再起動するため、
Garage への送信中は apply しない。

Debian 13 の `Debian13CloudInitAgent`（VMID 9003）を別途作成し、クローンの SSH と
guest agent を確認した。共有クローン元の単純な変更は既存 4 VM の再作成を招くため、
各 VM の `clone` に `ignore_changes` を設定し、新規作成用のテンプレートを切り替えた。
plan は既存 4 VM の更新のみで、再作成はない。既存 VM の OS はこの設定では更新されない。
新テンプレートのクローンでは cloud-init が完了するが、Proxmox の生成設定にある
非推奨の `user` 指定によって `degraded done` を報告する。実害と対応方法は未確認。

別 state の試験 VM では、旧 `desc` / `onboot` から新設定への更新は再起動せず成功した。
`bootdisk` を `boot` にし、既定の `startup_shutdown` と `power_state` を明示すると
再 plan は差分なしになったため、本番設定にも反映した。`power_state = "running"` は
停止中 VM の apply で起動させる。試験が本番の全条件を再現するわけではない。

prod の Terraform state はローカルの `terraform/prod/terraform.tfstate` にある。
秘密情報を含み得るため Git に追加せず、端末外で利用できる暗号化バックアップを
確認する。state を失った場合は VM の import と実機照合が必要になる。

将来の移行候補として [bpg/proxmox](https://github.com/bpg/terraform-provider-proxmox)
がある。Proxmox 9 と Cloudflare Access のヘッダーに対応する一方、移行には VM 定義と
state の扱いを検証する必要がある。現時点では移行しない。

---

## 1. atuin の匿名登録が開いている（セキュリティ）

`k8s/apps/atuin/deployment.yaml` の `ATUIN_OPEN_REGISTRATION` が `"true"`。

外部からは Cloudflare Access が `403` を返すため匿名では到達できないが、
**Access 認証を通った人は誰でも atuin アカウントを自動作成できる。**

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://atuin.seigo2016.com/healthz
# 302 / 401 / 403 のみが Access の拒否（fail-closed）。
# 200 / 404 / 405 / 5xx は origin が応答しているので fail-open。hostname を外すこと。
```

対処: `"false"` に変更して commit する。アカウント登録が完了していることを確認した
上で実施する。

```
k8s/apps/atuin/deployment.yaml
  - name: ATUIN_OPEN_REGISTRATION
    value: "true"      →  "false"
```

---

## 2. release-bot が ImagePullBackOff

`default/release-bot-deployment` が `ImagePullBackOff`。

```
ghcr.io/ps2-localization-jp/release-bot:latest → 403（認証ありでも）
```

- ソースリポジトリ `PS2-Localization-JP/PlanetSide2-nihongo-mod-management` が **private**
- `ImageRepository` に `secretRef` が無い（`provider: generic` で匿名 pull）
- org の public repo は `-mod-api` / `-mod-ui` のみ。`release-bot` package は 404
- クラスタ内の pull secret（`seigo2016`）でも 403

選択肢（判断待ち）:

- **A**: 上流で image を public 化、または再 publish
- **B**: `k8s/apps/release-bot/` を削除（Flux が prune）
- **C**: `deployment.yaml` を `replicas: 0` にして health check を外す

付随:

- `k8s/apps/release-bot/` は `docker-registry-secret.yaml`（`ghcr-registry-secret`）、
  `external-secret.yaml`（`release-bot-secrets`）、`secret-store.yaml`、
  `service-account.yaml`、`image-automation.yaml` を含む
- B を選ぶ場合は Vault の `secret/release-bot-secrets` も消すか判断する
- B を選んだ場合、`ImageUpdateAutomation` の `update.path` への push が止まることを確認する

---

## 3. Vault に auto-unseal がない

`k8s/apps/vault/helm.yaml` に auto-unseal / init-unseal の設定も Job もない。
Pod を再起動すると必ず sealed になり、`vault operator unseal`（5 key 中 3 key）の
人手が必要。

backup タスクと併せて、Transit / GCP KMS / Kubernetes どれかでの auto-unseal
導入を検討する。運用手順は `docs/standards/vault.md`。

---

## 4. Longhorn の backup target が無い

`StorageClass longhorn` は `backupTargetName: default` を指定しているが、
backup target は **0 件**、`recurringjob` も **0 件**。設定が宙に浮いている。

- 2 ノード構成では両ノードが同時に落ちると replica を失う。backup は唯一の対策
- backup target を入れる場合、`nfs-common` が `k8s-worker-1` に未導入
- `docs/standards/longhorn.md` の「未導入でも問題ないもの」参照

---

## 5. 2 ノード etcd（quorum=2）

`k8s-master` と `k8s-worker-1` の両方がコントロールプレーンで etcd を持つため
**etcd が 2 ノード構成**。quorum=2 なので **1 ノード停止で etcd が機能停止**し、
可用性は 1 ノードクラスタ以下になる。

`k8s-worker-1` は Ansible inventory 上は `k8s-workers` グループだが実体は完全な
コントロールプレーン（apiserver / etcd を持つ）。

3 ノード化するか、単一コントロールプレーンに寄せるか。前提の整理は
`docs/standards/k8s-cert-renewal.md` の「クラスタ構成上の前提」。

---

## 完了済み（参考）

- Longhorn の 2 ノード化と replica 数の 2 への変更（2026-10-04）— 経緯は
  git 履歴と PR
- `open-iscsi` の `ansible/setup-worker.yml` への追加
- kubeadm リーフ証明書の更新（`check-expiration` の残りは 340 日、CA は 2035 年まで）
