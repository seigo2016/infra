# Longhorn

クラスタのブロックストレージ。`k8s/apps/longhorn/helm.yaml` が唯一の定義元（Flux 管理）。

## 現構成

| 項目 | 値 |
|---|---|
| chart | `longhorn` 1.12.1（pin 必須。1.13.0 は `kubeVersion >=1.34.0-0` を要求し v1.32.13 では不可） |
| Longhorn ノード | `k8s-master` / `k8s-worker-1` の **2 ノード** |
| ディスク | 各ノード `/var/lib/longhorn/`（`ext4`、ノードルートディスク上）。各 33.3 GiB 中 14.0 GiB を replica が使用 |
| `default-replica-count` | `{"v1":"2","v2":"2"}` |
| StorageClass `longhorn` | `numberOfReplicas: "2"`、`reclaimPolicy: Delete`、`allowVolumeExpansion: true`（default class） |
| `replica-disk-soft-anti-affinity` | `true` → 同じディスクに 1 ボリュームの replica を 2 本置かない。**replica 数の上限 = ディスク数 = 2** |

### 使用中の Volume

| PVC | namespace | サイズ |
|---|---|---|
| `nginx-pvc` | default | 1Gi |
| `data-vault-vault-0` | vault | 3Gi |
| `chem-archive-runtime` | chem-archive | 5Gi |
| `atuin-data` | atuin | 5Gi |

すべて replica 2（各ノードに 1 本ずつ）。`robustness` が `healthy` であることが正常状態。

## taint と toleration

`k8s-worker-1` は `kubeadm join --control-plane` で参加しているため
`node-role.kubernetes.io/control-plane:NoSchedule` taint がある。Longhorn は
taint 除去ではなく **toleration** で対処している（taint は
`/home/debian/kubeadm-join.sh` 経由で `ansible/setup-worker.yml` が再現するため、
手で除去しても VM 再構築で復活する）。

toleration は 2 系統に分かれ、**両方が要る**:

| values | 適用対象 |
|---|---|
| `global.tolerations` | user-deployed 成分（`longhorn-manager` / `longhorn-driver-deployer` / `longhorn-ui` / install job） |
| `defaultSettings.taintToleration` | system-managed 成分（`instance-manager` / CSI DaemonSet / `engine-image-ei`） |

`defaultSettings.taintToleration` は `taint-toleration` Setting CR に書き込まれる。
chart 1.12 では `tolerations` ではなく **`taint-toleration`** が正しいキー。

## ノードの前提条件

Longhorn ノードにするホストは **`open-iscsi` が必須**。CSI の iSCSI login と、
障害時の failover で**ホスト側**の `iscsiadm` を呼ぶため（コンテナ image には
含まれない。`longhorn-manager` コンテナ内で `iscsiadm` を実行すると
`command not found` になる）。

`ansible/setup-worker.yml` に `iscsi_tcp` modprobe → `open-iscsi` → `iscsid` enable
が入っている。**この 3 つが無いと replica は組めるが、そのノードで failover できない。**

## 状態確認

```bash
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

# ノードとディスク（2 ノードであること、ディスクが schedulable であること）
$K get nodes.longhorn.io -n longhorn-system -o wide

# ボリューム（ROBUSTNESS=healthy / SCHEDULED=True が正常）
$K get volumes.longhorn.io -n longhorn-system

# 設定値
$K get settings.longhorn.io -n longhorn-system | grep -E 'taint-toleration|default-replica'

# toleration が全 DaemonSet に入っていること
$K get ds -n longhorn-system \
  -o 'custom-columns=NAME:.metadata.name,TOL:.spec.template.spec.tolerations'
```

## メンテナンスで Volume の detach が必要な場合

`taint-toleration` や replica 数を変更する場合、system-managed 成分への反映は
**全 Volume が detached のときだけ即時適用**される。attached のままだと
`setting_controller.go` が次で保留する:

```
failed to apply taint-toleration setting to Longhorn components when there are
attached volumes. It will be eventually applied
```

### detach が必要な作業

- `taint-toleration` / toleration の変更
- replica 数の増減
- engine image の更新
- ノードの Longhorn からの離脱

該当 Pod:

```bash
$K scale deploy nginx-deployment  -n default       --replicas=0
$K scale statefulset vault-vault  -n vault         --replicas=0
$K scale deploy chem-archive      -n chem-archive  --replicas=0
$K scale deploy atuin-server      -n atuin         --replicas=0
```

`nginx-pvc` / `data-vault-vault-0` / `chem-archive-runtime` / `atuin-data` の
4 だけが Longhorn を使っている。`*-tunnel`（cloudflared）、`ps2bot`、
`release-bot` は Longhorn PVC を持っていないので止めなくてよい。

### detach したら必ず longhorn-manager を再起動する

**Setting CR の sync が通っても、runtime 管理の DaemonSet の
`spec.template.spec.tolerations` は空のままになる。** detached だけでは反映せず、
longhorn-manager の再起動が必要:

```bash
$K rollout restart ds/longhorn-manager -n longhorn-system
$K rollout status  ds/longhorn-manager -n longhorn-system
```

再起動後、`engine-image-ei-*` / `longhorn-csi-plugin` / `instance-manager` が
worker-1 にも Pod を作る。`kubectl get ds -n longhorn-system` の
`DESIRED` が 2 になっていることで確認できる。

worker-1 で `longhorn-engine` image の pull に数分かかる（image が大きい）。
`ImagePullBackOff` は出ることがあるので、待って再試行に任せる。

## Flux は revision が同じでも manifest を再 apply する

`k8s/flux/kustomization.yaml` の flux-system Kustomization は `interval: 10m`。
**revision が変わらなくても 10 分ごとに manifest を apply する**ので、
`kubectl scale` などの手動変更は 10 分以内に戻される。

作業用の scale down をするなら、窓を短くして完了させるか、
Flux リポジトリに push してから行う。

## 未導入でも問題ないもの

| 項目 | 用途 | 判定 |
|---|---|---|
| `cryptsetup` / `dm_crypt` | ボリューム暗号化時のみ | 暗号化しないなら不要 |
| `nfs-common` | NFS backup target / RWX ボリューム | backup を入れるなら必須 |

`kubectl get nodes.longhorn.io -o yaml` で
`RequiredPackages` / `KernelModulesLoaded` が `False` になるのはこのためで、
異常ではない。
