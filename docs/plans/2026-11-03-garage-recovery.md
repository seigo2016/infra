# Garage の復旧性を高める計画

**目的:** 単一 Garage VM と R2 を維持し、Proxmox ホストを失っても
別マシンにデータを復元できるようにする。

1. 既存 Terraform / Ansible を現行ブランチに統合し、実機・state との整合性を確認する。
   Telmate 3.0.2-rc10 で plan は成功し、追加・削除なし、既存 4 VM の更新を表示する。
   `onboot` の変更に加えて `bootdisk` 等の差分があり、必要時の自動再起動が有効。
   復元試験と差分の検証後に apply を判断する。Debian 13 テンプレートを作成・検証し、
   既存 VM の再作成を避ける `clone` の `ignore_changes` と新しいクローン元を設定した。
   既存 VM の OS 更新は行われない。本番への apply は未実施。
   2026-11-04 の plan では `desc` から `description`、`onboot` から
   `start_at_node_boot` への移行、`bootdisk` と `startup_shutdown` の差分を表示。
   state の k8s-master メモリは 8192 MiB だが、実機と設定は 16384 MiB で一致する。
   prod の provider lock は追跡対象にし、state と plan は Git に入れない。
2. 別 VM で Garage を構築し、タイマーを無効にしたまま R2 から復元して照合する。
   本番の Tunnel には接続しない。データを本番に切り替えない。
3. ホスト外に保管した Vault パスワード、R2 アクセス情報、rclone crypt の password と
   salt から復元できることを確認する。DVC クライアントのアクセスキー更新と
   Git リポジトリを使った `dvc pull` を試す。
4. 稼働中に tar した旧 LMDB の整合性は未確認。新しいスナップショットは Garage
   標準機能でローカルに取得する。VM を失った場合は R2 からオブジェクトを復元する。
5. 別ディスクへの分離を検討する。現状 `DynamicUser` の `StateDirectory=garage` は
   `/var/lib/garage` を `/var/lib/private/garage` にリンクする。所有権、
   UUID によるマウント、起動時に目的のファイルシステムが未接続なら Garage を
   起動しない設定を検証してから、停止時間と移行手順を決める。同じ ZFS pool 内の
   別ディスクはホストや pool の故障に対するバックアップではない。
6. バックアップ成功時刻を監視し、定期的な復元試験を行う。週次コピーは障害時に
   最大約 7 日分を失い、失敗が続けばさらに長くなる。2026-11-04 に `copy --immutable`
   に変更し、旧 trash の自動削除を停止した。変更後の最初の週次成功と復元先での全件照合は確認済み。
   保存量は増え得るため、Cloudflare のアカウント全体の従量課金に月 $5 の予算通知を設定済み。

R2 の bucket lock は既存オブジェクトの上書きと削除を拒否する。現在はロックを
設定せず、`copy --immutable` と旧 trash の保持で誤削除の伝播を減らす。
認証情報を使った明示的な削除には対応しない。ロックを導入する場合は
保存方式、保持期間と削除手順を決め、検証する。

## OS とデータのディスク分離案

2026-11-03 時点の `data-store` は 1.1 TB の OS ディスクを持ち、Garage の
`data` は約 112 GiB、`meta` は約 3 GiB。Proxmox の `local-zfs` は非 sparse で、
現在のディスクだけで約 1.09 TiB を予約している。空きは約 2.02 TiB。
別の 1 TB ディスクを追加すると、実データ量だけでなく予約領域も増える。
既存の ext4 ルートディスクは縮小せず、移行後も当面そのままにする。

1. バックアップの成功を確認し、Garage とデータを使うクライアントを停止する。
2. 追加ディスクを作成・フォーマットし、UUID で永続マウントする。Garage の
   `DynamicUser` と `StateDirectory` が使う `/var/lib/private/garage` の所有権と
   マウント先を、検証 VM で先に確認する。
3. 停止中にメタデータとデータをコピーして照合し、元のコピーは切り替え後も保管する。
4. マウントがない状態では Garage が起動しないよう systemd の依存関係とマウントポイント
   の条件を設定し、ディスク未接続時に起動が拒否されることを試す。
5. 新ディスクで Garage の bucket とデータを確認してから運用に戻す。Terraform の
   VM 削除や再作成でデータディスクも削除されないよう、ディスクの管理方法と復旧手順を
   先に検証する。Telmate のディスク設定には `ignore` があるが、Terraform がその
   スロットを管理しないことと、Proxmox の VM 削除時にボリュームが残ることは別問題。
   削除時の動作を検証するまで、データを置いたディスクを VM に追加しない。
   別ディスクでも同じ ZFS pool の故障には対応できない。

2026-11-05 に試験 VM で `DynamicUser` / `StateDirectory` と追加ディスクを検証した。
`ConditionPathIsMountPoint` により未マウント時はサービスが起動せず、マウント時は
書き込みできた。また、停止した VM のディスクを `qm disk move --target-vmid` で
別 VM に移してから元 VM を削除し、付け替え先でファイルを読めた。デバイス名は
VM 間で変わったため UUID を使う。本番の Garage データや Terraform による
削除・再作成はまだ試していない。

この案は未実施。OS とデータを別ディスクにするだけで OS ディスク容量が自動的に
小さくなるわけではない。新しい小さな OS ディスクへの移行は別途検討する。

## バックアップとホストの外部監視案

Cloudflare Worker が 5 分ごとに VM の node_exporter を取得し、Discord に通知する。
Garage、容量、バックアップ最終成功時刻に加えて、Proxmox の ZFS pool の健全性と
ストレージの空き容量を監視する。ホスト停止時の到達不能とバックアップ期限切れは
別々に判定する。設定と復旧手順は [Garage 監視](../../monitoring/garage/README.md) を参照。
変更後の最初のバックアップ成功と、そのときの Discord 復旧通知は確認済み。
