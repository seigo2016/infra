# research-ops-cp の構築・バックアップ・復元

research-ops の Control Plane（API、engine、PostgreSQL 18）は専用 VM
`research-ops-cp` に置く。状態は PostgreSQL にだけあり、その本体は Cloudflare R2 の
バックアップにある。VM はいつ捨ててもよく、作り直しはコマンド 3 つで済む。

## 構成

| 層 | 場所 | 中身 |
|---|---|---|
| VM | `terraform/prod/research-ops-cp.tf`、`terraform/modules/standalone-vm` | `research-ops-cp`（4 コア、8 GiB、64 GB）と、必要なときだけ作る `research-ops-cp-restore-test` |
| 入口 | `terraform/cloudflare` | Tunnel、DNS、Access のアプリとサービストークン、R2 バケット（Control Plane の分だけ） |
| ホスト | `ansible/setup-research-ops-cp.yml` | OS、PostgreSQL（PGDG）、pgBackRest、pg_dump、API と engine、cloudflared、監視 |
| 復元 | `ansible/restore-research-ops-cp.yml`、`ansible/restore-test-research-ops-cp.yml` | 本番の復元と、隔離した VM での復元の試験 |

ポートは [`port-allocation-research-ops-cp.md`](port-allocation-research-ops-cp.md)、
クライアントの設定は [`../clients/research-ops-bridge-client-setup.md`](../clients/research-ops-bridge-client-setup.md)。

### 別の場所に移すとき

サイトに依存する値はすべて変数にある。VM の中に手で置くファイルはない。

| 値 | 置き場所 |
|---|---|
| ノード、ストレージ、ブリッジ、テンプレート | `terraform/prod/terraform.tfvars` |
| IP、ネットワーク、SSH 公開鍵 | `.env` の `TF_VAR_research_ops_cp_ip` ほか |
| SSH の秘密鍵、踏み台 | `.env` の `SSH_PRIVATE_KEY_PATH`、`ANSIBLE_JUMP_HOST`（`none` で直接接続） |
| ホスト名、Tunnel、バケット | `terraform/cloudflare/terraform.tfvars` |
| 秘密 | `ansible/group_vars/research-ops-cp/vault.yml`、`.env` |

Tunnel の経路は IP にもノードにも依存しないので、移した先でもホスト名は変わらない。
Proxmox がない別のマシンでも、Debian 13 のホストに inventory を向ければ同じ playbook で戻せる。

## 初回に手で行うこと（秘密の投入だけ）

1. **Cloudflare の API トークン**を作り、`.env` に `TF_VAR_cloudflare_api_token`、
   `TF_VAR_cloudflare_account_id`、`TF_VAR_cloudflare_zone_id`、`TF_VAR_cloudflare_team_name`
   （Zero Trust のチーム名。cloudflared が Access のトークンを確かめるのに使う）を入れる。権限:
   - Account: Cloudflare Tunnel Edit、Access: Apps and Policies Edit、
     Access: Service Tokens Edit、Workers R2 Storage Edit
   - Zone（対象のゾーンだけ）: DNS Edit
2. `terraform -chdir=terraform/cloudflare init && terraform -chdir=terraform/cloudflare apply`。
   初回の init で作られる `.terraform.lock.hcl` は commit する。
3. **R2 の API トークン**を 2 つ、ダッシュボードの R2 > Manage R2 API Tokens で作る。
   どちらも `research-ops-cp-backup` バケットだけに絞る。
   - Object Read & Write（本番の pgBackRest と pg_dump 用）
   - Object Read only（復元の試験用）
4. `ansible/group_vars/research-ops-cp/vault.yml.example` を `vault.yml` に写して値を入れ、
   `ansible-vault encrypt` する。Tunnel の token は
   `terraform -chdir=terraform/cloudflare output -raw tunnel_token`。
5. `.env` に `TF_VAR_research_ops_cp_ip` を入れる（入れるまで prod の plan は通らない）。
6. `group_vars/research-ops-cp/vars.yml` の `research_ops_git_version` に、配る
   research-ops の commit SHA を書き、`.env` か shell で `RESEARCH_OPS_REPO` に
   research-ops のローカルの clone を指す。

vault の全項目と Cloudflare / R2 のトークンは KeePassXC にも保存する。復元に要るのは
このリポジトリ、vault のパスワード、R2 の鍵、pgBackRest の cipher pass だけ。
cipher pass を失うとバックアップは読めない。

## 新しく作る

```bash
cd terraform/prod && terraform plan && terraform apply   # research-ops-cp を作る
cd ../..
.venv-ansible/bin/ansible-playbook -i ansible/inventory.research-ops-cp.yml \
  ansible/setup-research-ops-cp.yml --ask-vault-pass
```

初回の playbook は stanza を作り、WAL のアーカイブを始める（`pgbackrest check`
で確かめる）。backup の timer は止まったまま。最初の full を取ってから timer を有効にする。

```bash
ssh -J ss debian@"$TF_VAR_research_ops_cp_ip" 'sudo systemctl start pgbackrest-full.service'
.venv-ansible/bin/ansible-playbook -i ansible/inventory.research-ops-cp.yml \
  ansible/setup-research-ops-cp.yml --ask-vault-pass -e backup_timers_enabled=true
```

## バックアップ

| もの | 頻度 | 保持 | 置き場所 |
|---|---|---|---|
| pgBackRest full | 毎週日曜 02:30 | full 4 世代（約 4 週） | R2 `research-ops-cp-backup/pgbackrest`、pgBackRest の aes-256-cbc |
| pgBackRest diff | 月〜土 02:30 | 対応する full まで | 同上 |
| WAL | 随時、静かでも 60 秒ごと（`archive_timeout`） | full の保持に従う | 同上 |
| `pg_dump -Fc` と globals | 毎週日曜 04:30 | 35 日 | R2 `research-ops-cp-backup/pg_dump`、rclone crypt |

- 保持の範囲なら任意の時点に戻せる（PITR）。`pg_dump` は版の違う PostgreSQL に
  戻すための保険。
- 各 backup の直前に、`backup_check` データベースの `backup_manifest` に、全テーブルの
  行数と適用済み migration を記録する。この行は backup に含まれ、復元の照合に使う。
- timer は `rclone-backup` と同じ決まり。値を渡さない実行は状態を変えず、新しい timer は
  `-e backup_timers_enabled=true` を渡すまで止まっている。WAL のアーカイブは timer ではなく
  `pgbackrest_archive_enabled`（本番は true）で決まる。
- 成功の時刻は `/var/lib/pgbackrest-backup/last-success-{full,diff}` と
  `/var/lib/pg-dump-backup/last-success`。`127.0.0.1:9100` の node_exporter が、これと
  `pg_stat_archiver`（最後のアーカイブ、失敗の回数）、未送信の WAL セグメント数を出す。
  外からの監視（Worker）はまだない（[`../known-issues.md`](../known-issues.md)）。

## 復元の試験（隔離した VM）

月に 1 回と、PostgreSQL や pgBackRest の版を上げるときに行う。RFC の、本番に入れる前の
関門（backup + WAL + 復元 + 突き合わせ）に当たる。

```bash
# .env: TF_VAR_research_ops_cp_restore_test_enabled=true と TF_VAR_research_ops_cp_restore_test_ip
cd terraform/prod && terraform apply && cd ../..
.venv-ansible/bin/ansible-playbook -i ansible/inventory.research-ops-cp.yml \
  ansible/restore-test-research-ops-cp.yml --ask-vault-pass
# 終わったら TF_VAR_research_ops_cp_restore_test_enabled=false にして apply し、VM を消す
```

playbook がすること:

1. 隔離を確かめる。ホスト名が `research-ops-cp-restore-test`（Terraform が cloud-init で付ける）、
   IP が本番と違う、cloudflared も API も engine も入っていない、WAL のアーカイブと
   stanza の作成と backup の unit が無効、R2 の鍵が読み取り専用。どれかが崩れていれば何もせず止まる。
2. 最新の backup を `--archive-mode=off` で復元する。復元したクラスタは、本番と同じ
   system identifier を持っていても WAL を送らない。
3. PostgreSQL を起動し、promote されるまで待つ。
4. 復元した `research_ops` を、backup の直前の manifest と照合する。manifest にある
   migration がすべて適用済みで、各テーブルの行数が manifest 以上であること。
5. 突き合わせ（reconciliation）の dry-run。終わっていない attempt の `lease_epoch` を上げて
   締め出す件数、止めておく dispatch_intents と outbox の件数を数え、すべて rollback する。
   engine を入れないので dispatch は起きない。Control Plane の epoch はまだスキーマにないので
   `NOT RUN` と出る。Bridge の journal との照合は Bridge が要るので含まない。
6. 結果を VM の `/var/lib/pgbackrest-restore/report-*.json` に書く。

同じ Proxmox ホストの上の試験は、VM の作り直しと R2 からの復元は確かめるが、
ホストが壊れたときに別の物理マシンで戻せることまでは確かめない。別のホストでの初回の試験は手で行う。

## 本番を復元する、作り直す

VM ごと失ったときも、データベースだけを戻すときも同じ手順で、順番は
**apply → 復元の playbook → 構築の playbook**。構築の playbook を先に流すと、新しい空の
クラスタが stanza を作ろうとし、pgBackRest が「別のクラスタの repository」として拒否する
（repository は汚れないが playbook が止まる）。

```bash
cd terraform/prod && terraform apply && cd ../..        # VM がなければ作る
.venv-ansible/bin/ansible-playbook -i ansible/inventory.research-ops-cp.yml \
  ansible/restore-research-ops-cp.yml --ask-vault-pass \
  -e research_ops_cp_confirm_restore=research-ops-cp
# 時点を指定するとき: -e "pgbackrest_restore_target_time='2026-11-20 03:00:00+09'"
.venv-ansible/bin/ansible-playbook -i ansible/inventory.research-ops-cp.yml \
  ansible/setup-research-ops-cp.yml --ask-vault-pass -e backup_timers_enabled=true
ssh -J ss debian@"$TF_VAR_research_ops_cp_ip" 'sudo systemctl start pgbackrest-full.service'
```

復元の playbook は、最初に `/etc/research-ops-dispatch-suspended` を置いてから、API、engine、
backup の timer を止め、復元と照合と dry-run を行う。`archive_mode` は on のままにする。
off のまま promote すると、新しい timeline の `.history` と直後の WAL が repository に送られず、
次の復元で時点の指定が効かなくなる。復元の前に新しい VM の空のクラスタが送る WAL は、
system-id が違うので pgBackRest が拒む。構築の playbook は API と backup の timer を戻す
（`-e backup_timers_enabled=true` がないと timer は無効のまま）。engine はこの印がある間は
起動しない（unit の `ConditionPathExists`）。

RFC §9 の残りは Control Plane 側で行う。epoch を上げ、各 Bridge の journal を問い合わせ、
古い attempt を締め出して突き合わせる。終わったら dispatch を再開する。

```bash
ssh -J ss debian@"$TF_VAR_research_ops_cp_ip" \
  'sudo rm /etc/research-ops-dispatch-suspended && sudo systemctl start research-ops-engine'
```

復元の後は新しい timeline の WAL が同じ repository に送られる。上の手順の最後で full を 1 回取っておく。

## 限界

- 単一の VM で、HA ではない。WAL は最長 60 秒ぶん失われ得る（`archive_timeout`）。
  アーカイブが失敗し続ければ、失われ得る範囲は伸び、`pg_wal` が膨らむ。
- R2 の鍵か cipher pass を失うと戻せない。pg_dump は別の crypt の鍵で守っている。
- 照合は「manifest 以上の行数」で見る。行を消す処理が入ったら、この条件を見直す。
