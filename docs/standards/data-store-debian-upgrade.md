# data-store の Debian メジャーバージョン更新

Garage のデータは `/var/lib/garage`、OS と同じディスクにある。Debian 12 から 13
への更新は、[Debian 公式の更新手順](https://www.debian.org/releases/trixie/release-notes/upgrading.en.html)
と[既知の問題](https://www.debian.org/releases/trixie/release-notes/issues.en.html)に従う。

## 事前確認

- Garage への書き込みを停止し、R2 の最終バックアップの日時を確認する。
  最後の成功後に追加したデータは R2 にない可能性がある。
- KeePassXC のデータベースとパスワードを Proxmox 障害時にも使えることを確認する。
- Proxmox のコンソールを使える状態にする。SSH は切断される場合がある。
- VM 全体の別媒体へのバックアップがない場合は、その制約を認識する。
  `before-debian13-20261103` は VM 105 の **同一 ZFS pool 内**のローカル
  スナップショットであり、ホストや pool の故障に対するバックアップではない。
  取得時 Garage は停止済みだが、guest agent が稼働しておらずファイルシステムの
  freeze は行っていない。
- VM 上で `df -h /`、`dpkg --audit`、`apt-mark showhold` と、
  `systemctl is-active garage caddy cloudflared` を確認する。
- bookworm の更新を完了し、backports と Cloudflare など Debian 以外の
  APT ソースを一時的に無効化する。cloudflared の公式 APT ソースは
  `https://pkg.cloudflare.com/cloudflared any main`。更新後に再有効化する。

## 更新

1. 長時間使える端末を用意し、`script` 等で更新の記録を取る。パスワードや秘密を記録しない。
2. Debian 公式手順に従って APT ソースを `bookworm` から `trixie` に切り替える。
   `bookworm-backports` は外す。`/etc/apt/sources.list.d/debian.sources` だけでなく
   有効なすべてのソースを確認する。
3. `apt update` の結果と `apt -s full-upgrade` の削除対象を確認する。予期せぬ削除が
   あれば続行しない。
4. 公式手順の `apt upgrade --without-new-pkgs`、`apt full-upgrade` の順に実行する。
   対話的な設定変更には内容を確認して応答する。
5. 再起動後、`cat /etc/debian_version`、`dpkg --audit` と SSH 接続を確認する。
   次いで Garage、Caddy、cloudflared、R2 バックアップタイマーが正常か調べる。
   Garage の bucket と代表的な DVC クライアントの読み書きも確認する。
6. 更新後に十分確認できたら、ローカルスナップショットの保持期間を決める。
   放置すると変更されたディスクブロックに応じて ZFS の使用量が増える。

スナップショットへのロールバックは取得後の VM ディスク上の変更を失う。
Garage への新規書き込みを止め、対象と影響を確認してから実行する。
