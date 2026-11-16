# Garage の復元

Garage の正本は data-store VM の `dvc` バケット。週次で rclone crypt を通じて
Cloudflare R2 にコピーする。VM と Proxmox の両方が失われた場合も、別のマシンから
R2 にアクセスし、新しい Garage にオブジェクトを復元する。

## 復元に必要なもの

- このリポジトリと Ansible Vault の復号パスワード。プロジェクトの DVC 設定と
  Git リポジトリも必要。DVC のキャッシュだけではデータセットの構成は戻らない。
- R2 のアカウント ID、バケット、読み取り可能な API キー、および rclone crypt の
  password と salt。Vault のほかに、ホストから独立した場所に保存し、取得できることを確認する。
- Garage 2.0.0 と rclone 1.74.4、または互換性を検証したバージョン。
- 操作端末には Python 3.12 以上と `requirements-ansible-data-store.txt` の
  ansible-core。Debian 13 の Python 3.13 に対応する版を使う。
- 既存のサービスに戻す場合は Cloudflare Tunnel、Access、DNS、Caddy の設定と
  各認証情報。復元試験では本番 Tunnel を起動しない。

Vault の内容は KeePassXC にも保存済み。KeePassXC のデータベースとそのマスター
パスワードをホスト外で利用できるようにする。KeePassXC から取得した値を使った
復元試験は未実施。

2026-11-04 の試験で判明した Vault 内の crypt パスワードの不一致は修正済み。
稼働中の正しい R2 と crypt の設定は KeePassXC の添付に保管済み。以前 Vault から
KeePassXC のメモに転記した crypt パスワードは古いため、修正した値への更新が必要。
試験では修正前に稼働中の設定を読み取って暗号化情報を用意したため、修正後の Vault と
KeePassXC の添付から直接設定を取り出す手順は別途確認する。

## 直近の復元試験

2026-11-04 の試験では別 VM の Garage に R2 からコピーし、`rclone check --download` で
622,859 ファイルが一致、差異とエラーは 0 件だった。新しい Garage のキーを使って
Git 管理下の DVC ファイルから 1 件を `dvc pull` し、サイズと MD5 の一致も確認した。
R2 の認証情報はバケット限定の読み取り専用トークンを使った。**この比べ方は R2 の写しが壊れていても一致になる**（2026-11-17 に、7 月から途中で切れていた object が見つかった）。次からは戻した object の md5 を DVC の名前と照らす（`docs/plans/2026-11-17-garage-backup-to-be.md`）。試験 VM は本番と同じ
Proxmox ホスト上にあるため、別の物理ホストでの復旧手順は未検証。

操作端末で `uv` を使って Ansible 環境を用意する例（リポジトリのルートで実行）:

```bash
uv venv --python 3.13 .venv-ansible
uv pip install --python .venv-ansible/bin/python -r requirements-ansible-data-store.txt
```

`deploy-data-store.sh` はこの環境の `ansible-playbook` を使う。別の対応環境を
使うときは `ANSIBLE_PLAYBOOK` にその実行ファイルのパスを指定する。

## 新しい Garage に復元する

1. 新しい VM または別マシンで Garage を構築し、空の `dvc` バケットを用意する。
   検証用なら別 IP を使い、本番の Tunnel を接続しない。
2. バックアップのタイマーを無効にする。旧 trash 削除や旧メタデータ取得タイマーが
   残っている環境では、それも停止する。
   Ansible に `-e backup_timers_enabled=false` を指定して明示的に停止する。
   復元完了前に有効にすると、未確認のデータが R2 に追加され得る。
   復元に使う R2 キーは読み取り専用を推奨する。
3. 復元用 rclone 設定を安全に用意し、`r2-crypt:dvc-cache` が読めること、
   `garage-s3:dvc` が新しい空バケットであることを確認する。
4. コピーする。`sync` は使わない。対象の容量に余裕を持たせる。

   ```bash
   sudo rclone --config /etc/rclone/rclone.conf copy \
     r2-crypt:dvc-cache garage-s3:dvc --transfers 4 --fast-list
   ```

5. コピー元と復元先を照合し、結果にエラーや照合できない項目がないか確認する。
   また、元の Git リポジトリと DVC 設定を使って実際に `dvc pull` する。

   ```bash
   sudo rclone --config /etc/rclone/rclone.conf check \
     r2-crypt:dvc-cache garage-s3:dvc --download --fast-list
   ```

6. 新しい Garage ではアクセスキーが変わる。`/root/.garage-credentials` を安全に
   取得し、各クライアントの DVC ローカル設定を更新する。必要なクライアントの
   読み書きを確認してから本番への切り替えと、タイマーの有効化を行う。

復元後、Ansible を `-e backup_timers_enabled=true` で実行するとバックアップタイマーを有効化する。
旧 trash 削除タイマーは無効のままにする。
値を指定しない再実行ではタイマーの既存状態を維持する。新規 VM のタイマーは
明示的に有効化するまで停止している。
古い Garage がまだ稼働している場合は、二重書き込みを避けて切り替える。

## 隔離 VM での試験準備

`ansible/setup-garage-restore-test.yml` は Garage と復元用 rclone を構成する。
Cloudflare Tunnel と Caddy はインストールせず、バックアップタイマーを停止する。
実行前に、専用 VM 上で `/etc/garage-restore-test-target` を root 所有で作る。
既存の `/etc/systemd/system/cloudflared.service` が見つかった場合や、マーカーが
ない場合は、Garage の構成に入る前に停止する。この確認は対象 VM の取り違えを
防ぐ補助であり、接続先の IP と本番からの隔離も確認する。

インベントリは `garage-restore-test` グループに専用 VM だけを登録する。
Vault の実際の値を使う場合、リポジトリのルートから次を実行する。

```bash
.venv-ansible/bin/ansible-playbook -i <試験用インベントリ> \
  ansible/setup-garage-restore-test.yml \
  -e @ansible/group_vars/data-store/vault.yml --ask-vault-pass
```

この playbook は R2 からデータをコピーしない。復元用の資格情報は可能なら
読み取り専用の R2 キーを使う。準備後、上の手順に従ってコピー・照合する。
同じ物理ホスト上の試験 VM は、VM 作り直しと R2 からの復元の確認にはなるが、
ホスト故障時に別の物理マシンを使えることまでは確認できない。

## メタデータのスナップショット

Garage 自身が LMDB のスナップショットを 24 時間ごとに取得し、
`/var/lib/garage/meta/snapshots/` に最新 2 世代を保持する。Ansible は初回に
スナップショットが存在しなければ 1 回取得する。新しいメタデータの
スナップショットは R2 に送らない。

旧方式で R2 や Dropbox に保存した tar は、稼働中の LMDB を直接取得したもので、
整合性は未検証。この tar を新規クラスタに展開したり、データと対にせず単独で
巻き戻したりしない。旧 tar の取得タイマーは停止済み。

ディスクとデータが残り、LMDB のみが壊れた場合は、Garage を停止して現在の
`db.lmdb` を退避し、同一アーキテクチャのスナップショットを `db.lmdb` にコピーして
起動する。単一ノードのためスナップショット以降の変更は失われ、過去のメタデータと
現在のブロックが一致する保証もない。まず現在のファイルを保全し、復旧後に必要な
データを確認する。VM またはディスクを失った場合は R2 からのオブジェクト復元を使う。
手順の詳細は [Garage 2.0 の復旧手順](https://github.com/deuxfleurs-org/garage/blob/v2.0.0/doc/book/operations/recovering.md) を参照。

## バックアップの限界

週次コピーのため、正常な場合でも最後の成功後に書かれたデータは失われ得る。
失敗が続けば期間は長くなる。`copy --immutable` は通常のコピー操作では保存先の削除や
更新を行わず、検出可能な不一致はエラーにする。既存の `trash/YYYY-MM-DD/` は自動削除せず残す。
コピー先は増え続けるため R2 の利用量と請求を確認し、削除が必要なら復元への影響を個別に調べる。
R2 の認証情報や暗号化情報を失うと復元できない。
コピー中の変更、失敗、検出できない破損に備え、実行結果の監視と定期的な
復元試験が必要。RAID や別ディスクは R2 バックアップの代わりにはならない。

バックアップが正常終了した時刻は `/var/lib/garage-backup/last-success` の更新時刻で
確認できる。このファイルは設定導入後の最初の成功時に作られる。それ以前の実行結果は
`journalctl -u garage-backup.service` で確認する。ファイルを確認するだけでは通知されず、
ホスト停止も検知できないため、外部からの監視は別途必要。
