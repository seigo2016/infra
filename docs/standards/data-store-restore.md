# Restore Runbook: data-store VM

data-store VM（Garage S3）が失われた / 巻き戻したい場合の復元手順。

## 前提

- rclone crypt の password / salt は vault
  (`ansible/group_vars/data-store/vault.yml`) と 1Password の両方にある。
- vault を失った場合は 1Password の値で `/etc/rclone/rclone.conf` を
  手動再構成する。復号には password / salt の**両方**が必須。

## ケース1: バケットデータの復元（VM / Garage 再構築後）

新 VM を Terraform + Ansible でプロビジョニングした後、VM 上で:

```bash
sudo rclone --config /etc/rclone/rclone.conf sync r2-crypt:dvc-cache garage-s3:depth-auth-dvc --transfers 8 --fast-list
sudo rclone --config /etc/rclone/rclone.conf cryptcheck garage-s3:depth-auth-dvc r2-crypt:dvc-cache
```

注意:

- 逆 sync は必ず `r2-crypt:`（復号ビュー）から行うこと。`r2-raw:` から
  コピーすると暗号化ゴミが入る。
- DVC キャッシュは content-addressed なので、これだけで `dvc pull` が通る。

## ケース2: メタDBスナップショットからの復元（同一クラスタの巻き戻し）

```bash
sudo systemctl stop garage
sudo rclone --config /etc/rclone/rclone.conf copy r2-crypt:meta-snapshots/meta-YYYY-MM-DD.tar.gz /tmp/
sudo tar -xzf /tmp/meta-YYYY-MM-DD.tar.gz -C /var/lib/garage   # 展開先: /var/lib/garage/meta
sudo systemctl start garage
```

注意:

- garage 停止中に行うこと。
- メタとデータの不整合が出た場合は `garage repair` を検討。
- 新規クラスタ構築時はケース1のみでよい（メタ復元は不要）。

## 誤削除ファイルの救出

削除されたファイルは `r2-crypt:trash/YYYY-MM-DD/` に 30 日残っている。

```bash
sudo rclone --config /etc/rclone/rclone.conf ls r2-crypt:trash/
sudo rclone --config /etc/rclone/rclone.conf copy r2-crypt:trash/YYYY-MM-DD/<path> garage-s3:depth-auth-dvc/<path>
```
