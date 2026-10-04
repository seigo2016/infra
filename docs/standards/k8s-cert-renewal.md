# Runbook: k8s 証明書の期限切れとクラスタ全断からの復旧

kubeadm が発行するリーフ証明書は**有効期限1年**。放置すると全ノードで一斉に
期限切れし、クラスタが全断する。2026-06-07 に実際に発生した。

## クラスタ構成上の前提（重要）

- **`k8s-worker1` (172.16.0.203) は名前に反して完全なコントロールプレーン**。
  `/etc/kubernetes/manifests/` に kube-apiserver / controller-manager / scheduler
  の静的 Pod マニフェスト一式を持ち、PKI も `ca.key` まで保持している。
  `ansible/inventory.yml` 上は `k8s-workers` グループなので、**名前だけ見ると誤診する**。
- したがって etcd は **master + worker1 の2ノード構成**。
- **2ノード etcd は quorum=2 なので、1台の停止で全断する**。単独ノードより可用性が低い。
  3ノード化するか単一コントロールプレーンに寄せるか、別途見直しが必要。

## 症状と切り分け

全断時は SSH すら到達しないため、外側から順に切り分ける。

### 1. Cloudflare Access / トンネルの生死

踏み台 `ss` は **Proxmox ホスト (pve) 自身**で、Cloudflare Access 配下にある。

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://ssh.seigo2016.com/
```

- `302` → Access は生存。ログイン画面まで出ている。
- `530` → origin 到達不能。Proxmox ホストごと落ちている。

JWT を付けて `200` が返るなら Access は無罪で、トンネルの origin 側を疑う。

```bash
TOK=$(cat ~/.cloudflared/ssh.seigo2016.com-*-token)
curl -s -o /dev/null -w "%{http_code}\n" -H "cf-access-token: $TOK" https://ssh.seigo2016.com/
```

注意:

- `~/.cloudflared/` に `.lock` と `.url` しか無く実体トークンが無い場合は認証切れ。
  `cloudflared access login https://ssh.seigo2016.com` が必要だが、
  **非対話セッションではブラウザ認証ができず詰む**。
- `websocket: bad handshake` は Access 通過後にトンネルが張れていない状態。

### 2. 証明書の期限確認

```bash
ssh k8s-master 'sudo kubeadm certs check-expiration'
```

`RESIDUAL TIME` が `<invalid>` なら期限切れ。**CA (`ca` / `etcd-ca` / `front-proxy-ca`)
が有効なら renew で復旧できる**。CA まで切れている場合はこの手順では戻せない。

### 3. 障害の連鎖（典型パターン）

```
リーフ証明書の一斉期限切れ
  → etcd peer 間 TLS が相互に拒否 (remote error: tls: bad certificate)
  → quorum 不成立、リーダー選出が空転 (starting a new election at term N)
  → apiserver が etcd に到達できず fatal
     (Error creating leases: context deadline exceeded)
  → apiserver が繰り返しリスタート、全ワークロード停止
```

etcd コンテナは `crictl ps` 上 **Running に見えるが応答していない**点に注意。
apiserver だけが `Exited` で ATTEMPT が二桁になっていたら、まず etcd のログを見る。

```bash
ssh k8s-master 'sudo crictl ps -a | head'
ssh k8s-master 'ID=$(sudo crictl ps --name etcd -q | head -1); sudo crictl logs --tail 30 "$ID"'
```

## 復旧手順

### 手順0: バックアップ（必須）

```bash
for h in k8s-master k8s-worker1; do
  ssh $h 'sudo cp -a /etc/kubernetes/pki /root/pki-backup-$(date +%Y%m%d)
          sudo cp -a /var/lib/etcd    /root/etcd-datadir-backup-$(date +%Y%m%d)'
done
```

注意:

- etcd データは1ノードあたり約 400M。事前に `df -h /` で空きを確認する。
- apiserver が死んでいると `etcdctl snapshot save` は使えないため、
  **データディレクトリごとコピーする**。停止中のコピーなので整合性は取れている。

### 手順1: 両ノードで証明書を更新（この時点では再起動しない）

```bash
ssh k8s-master  'sudo kubeadm certs renew all'
ssh k8s-worker1 'sudo kubeadm certs renew all'
```

注意:

- **必ず両ノードを先に更新しきること**。片方ずつ完結させると新旧の証明書が混在し、
  peer 接続が張れないまま再起動が空振りする。
- `check-expiration` が kubeadm-config ConfigMap を読めず警告を出すが、
  デフォルト設定にフォールバックするだけで問題ない（apiserver が死んでいるため）。

### 手順2: 両ノードで静的 Pod を再起動

```bash
for h in k8s-master k8s-worker1; do ssh $h 'sudo systemctl restart kubelet'; done
```

kubelet 再起動で静的 Pod が拾われない場合は、manifests を一時退避して戻す:

```bash
ssh k8s-master 'sudo mv /etc/kubernetes/manifests /tmp/m && sleep 20 && sudo mv /tmp/m /etc/kubernetes/manifests'
```

### 手順3: 確認

```bash
ssh k8s-master 'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes'
```

注意:

- **`sudo kubectl` を裸で使わない**。root に kubeconfig が無く `localhost:8080` に
  フォールバックして `connection refused` を返し、誤診を招く。
  必ず `--kubeconfig=/etc/kubernetes/admin.conf` を付ける。
  （`debian` ユーザの `~/.kube/config` は permission denied で読めない）
- etcd の quorum 回復には両ノード再起動後 1〜2 分かかることがある。
- `kubeadm certs renew` は `/etc/kubernetes/*.conf` を更新するが
  **`~/.kube/config` は自動更新されない**。必要なら
  `sudo cp /etc/kubernetes/admin.conf ~/.kube/config` で差し替える。
- **kubelet 自身のクライアント証明書は別系統**で自動ローテーションされる
  (`/var/lib/kubelet/pki/kubelet-client-current.pem`)。ノードが `NotReady` の
  ままならそちらを疑う。

## 再発防止

- リーフ証明書は1年で切れる。**`kubeadm certs check-expiration` を定期的に確認する**。
  コントロールプレーンを毎年再起動していれば kubeadm が自動更新するが、
  長期稼働させると切れる。
- 2ノード etcd 構成そのものが単一障害点。構成見直しを検討する。
