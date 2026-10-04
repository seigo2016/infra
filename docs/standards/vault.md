# Vault / External Secrets Operator

シークレット 저장소。`k8s/apps/vault/helm.yaml`（chart `vault` 0.34.1）と
`k8s/apps/external-secrets/helm.yaml` が定義元（Flux 管理）。

ESO は SecretStore ごとに Kubernetes auth で Vault にログインし、
ExternalSecret が Kubernetes Secret を生成する。

## 現構成

| 項目 | 値 |
|---|---|
| バージョン | `hashicorp/vault:2.0.4`（chart 0.34.1） |
| モード | `server.dev.enabled: false` / `server.ha.enabled: false`（**単独ノード**） |
| storage | `file` ストレージ、Longhorn の `data-vault-vault-0`（3Gi）上 |
| seal | `shamir`、key share 5 / threshold 3 |
| auto-unseal | **無し** |
| init / unseal Job | **無し** |
| injector / ui | 無効 |

Longhorn の冗長化により `data-vault-vault-0` の replica は 2 ノードに 1 本ずつ
ある（`docs/standards/longhorn.md` 参照）。

## Pod 再起動で必ず sealed になる

auto-unseal 機構がないため、**Pod を一度でも再起動すると sealed になり、
人手での unseal が必要になる**。`vault operator unseal` に 5 個の unseal key の
うち 3 個が必要で、うち 1 個もクラスタ内に保存されていない。

回避策:

- Pod 再起動を伴わない範囲の保守しか行わない
- Vault を触る前に unseal key を手元に用意する
- auto-unseal を導入する（`docs/known-issues.md` 参照）

## unseal 手順

```bash
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

$K exec -n vault vault-vault-0 -- sh -c 'wget -qO- http://127.0.0.1:8200/v1/sys/seal-status'

$K exec -it -n vault vault-vault-0 -- vault operator unseal
# unseal key を 3 回入力する
```

`progress` は投入した key 数、`nonce` は発行中かを示す。

```
sealed 状態で 1 個目: {"sealed":true,"t":3,"n":5,"progress":1,"nonce":"..."}
sealed 状態で 3 個目: {"sealed":false,"t":3,"n":5,"progress":0,"nonce":""}
```

Pod の readiness probe は seal-status を見るので、unseal すると
readiness が立つ（`kubectl get pod vault-vault-0 -n vault` の READY が `true` になる）。

## unseal 後は ESO を明示的に再 reconcile させる

ESO は **Vault の seal 解除を検知しない**。SecretStore が `InvalidProviderConfig`
のまま、外部の `SecretStore` 変更時と refresh interval 到来時にしか再試行しない。

```bash
$K annotate secretstore --all -A reconcile.external-secrets.io/requestedAt="$(date +%s)" --overwrite
$K annotate externalsecret --all reconcile.external-secrets.io/requestedAt="$(date +%s)" --overwrite
```

`kubectl annotate` は namespace 跨界が必要なので、`secretstore` は `--all -A`、
`externalsecret` は各 namespace で `--all` の 2 回実行する。

## 状態確認

```bash
K="sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"

$K get secretstores -A          # 全件 STATUS=Valid / READY=True が正常
$K get externalsecrets -A \
  -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
```

失敗時は ESO のログに原因が出る:

```bash
$K logs -n external-secrets-system deploy/external-secrets -c external-secrets --tail=50 \
  | grep -iE 'vault|auth'
```

`Code: 503 ... * Vault is sealed` は未 unseal、`SecretStore "..." is not ready` は
SecretStore がまだ `Valid` になっていない状態。

## 注意点

- `data-vault-vault-0` は Longhorn の PVC なので、PVC が `Bound` でも
  Longhorn 側の replica が schedule できるまで Pod は起動しない。
  `ROBUSTNESS=degraded` / `SCHEDULED=False` のままなら、Pod 側の問題ではない。
  `kubectl get volumes.longhorn.io -n longhorn-system` で確認する。
- `status.conditions[].lastTransitionTime` が未来になることがある（ノードの
  時計が飛ぶため）。**時刻だけで状態を判断しない。**
- ESO が Secret を作るのは ExternalSecret の `spec.target.name` で、
  ExternalSecret 名とは限らない（例: ExternalSecret `ps2bot-external-secret` が
  Secret `ps2bot-secrets` を作る）。Secret の存在確認は target 名で行う。
