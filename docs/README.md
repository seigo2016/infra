# docs

このリポジトリとクラスタの**現行の事実と運用手順**の SSoT（single source of truth）。

- 完了した作業の経緯は git 履歴と merged PR にある。**ここには書かない**
- 未対応の作業は [`known-issues.md`](known-issues.md) に集約する

## クラスタの全体構成

```bash
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"
$K get nodes -o wide
$K get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" taints="}{.spec.taints}{"\n"}{end}'
```

| ノード | IP | role | taint | CPU / MEM | ディスク |
|---|---|---|---|---|---|
| `k8s-master` | 172.16.0.201 | control-plane | なし | 4C / 15.5Gi | 34G（Longhorn とコンテナ image を共有、残り少ない） |
| `k8s-worker-1` | 172.16.0.203 | control-plane | `node-role.kubernetes.io/control-plane:NoSchedule` | 4C / 7.7Gi | 34G（Longhorn 用、29G 空き） |

- Kubernetes `v1.32.13` / CRI-O / **flannel**（CNI）
- **flannel は NetworkPolicy を強制しない**（`KUBE-NEWPOLICY` chain が 0 件。
  deny-all policy を張っても Pod 間通信が成功することを実測済み）。
  NetworkPolicy を書いても効果がない
- etcd は 2 ノード構成。`k8s-worker-1` は Ansible inventory 上は `k8s-workers`
  グループだが実体は完全なコントロールプレーン
- ディスクは両ノードともルートディスク（`/dev/sda1`, 34G）。**専用ディスクは無い**

## ドキュメント一覧

| ファイル | 内容 |
|---|---|
| [`known-issues.md`](known-issues.md) | 未対応作業の一覧 |
| [`standards/longhorn.md`](standards/longhorn.md) | Longhorn の現構成と、detach と manager 再起動が必要な保守作業の手順 |
| [`standards/vault.md`](standards/vault.md) | Vault / ESO の unseal 手順と状態確認 |
| [`standards/k8s-cert-renewal.md`](standards/k8s-cert-renewal.md) | kubeadm 証明書の期限切れとクラスタ全断からの復旧 |

## よく使う確認コマンド

```bash
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

$K get nodes                       # 両ノード Ready が正常
$K get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
$K get deploy,sts -A               # READY 列が desired と一致していること
$K get volumes.longhorn.io -n longhorn-system
$K get secretstores -A             # 全件 Valid が正常
$K get externalsecrets -A
```

- **`sudo kubectl` を裸で使わない。** root に kubeconfig が無く
  `localhost:8080` にフォールバックして `connection refused` を返す
- Flux は `wait: false`。リポジトリ全体が健康状態でなくても apply は進む。
  health は `kubectl` で個別に確認する
- Flux は revision が同じでも `interval: 10m` ごとに manifest を再 apply する。
  `kubectl` での手動変更は 10 分以内に戻る
- HelmRelease の `version` pin は必須。pin しないと最新 chart を掴んで
  `kubeVersion` 不一致で失敗する（実際に longhorn 1.13.0 で发生过）
