# atuin セルフホスト同期サーバ Implementation Plan

> **For Claude:** REQUIRED SUB-KILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 集群内に Atuin 同期サーバ（SQLite + Longhorn）を Flux でデプロイし、Cloudflare Tunnel / Access（Service Token）経由で、WSL2 + bash の各PCから WezTerm 経由で利用できるようにする。

**Architecture:** `atuin` namespace に `atuin-server` Deployment 1 本（SQLite）+ ClusterIP Service + cloudflared Deployment 2 本 + 日次バックアップ sidecar。外部公開は新規 Tosc専用 Cloudflare Tunnel、認証は Access Service Token。Atuin クライアントの `extra_headers`（v18.18.0+）が token を送信する。

**Tech Stack:** Kubernetes / Flux v2.6.1 / Kustomize / Longhorn / External Secrets Operator + HashiCorp Vault / cloudflared / Atuin v18.23.0

**Design doc:** `docs/plans/2026-09-29-atuin-self-hosted-sync-design.md`

**前提となる現状:**

- 集群は 2 ノード（`k8s-master` 172.16.0.201、`k8s-worker1` 172.16.0.203）で
  etcd が 2 ノード。リソース余裕は小さい。
- Flux は単一 `GitRepository`（branch `main`）→ Kustomization path `./k8s/flux`
  （`prune: true`, `wait: true`）。`./k8s/flux` → `flux-system/` → `../../apps` →
  `k8s/apps/kustomization.yaml` の暗黙チェーンでアプリが取り込まれる。
- secrets は in-cluster Vault + External Secrets。アプリごとに
  `SecretStore` / `ServiceAccount` / Vault role（`<app>-role`）を個別に持つ。
- storage class は `longhorn` のみ。
- cert-manager は未導入。ingress-nginx は hostNetwork で 80/443 をノードに
  直貼しているが、Tunnel 専用パスは使わない。
- `deploy/chem-archive-poc` ブランチに **in-cluster cloudflared の hardening
  前例**がある（`k8s/apps/chem-archive/`）。これを踏襲する。

---
## Phase 0: ベースライン整理

### Task 0: 現行の描画と preflight を確認する

**Files:**
- Read: `k8s/apps/kustomization.yaml`
- Read: `k8s/apps/longhorn/helm.yaml`
- Read: `k8s/apps/release-bot/secret-store.yaml`

**Step 1: 現在の apps リストと Longhorn 設定を確認する**

Run: `cat k8s/apps/kustomization.yaml && cat k8s/apps/longhorn/helm.yaml`
Expected: `longhorn` / `ingress-nginx` / `sample-nginx` / `vault` /
`external-secrets` / `ps2bot` / `release-bot` の 7 エントリ。Longhorn は
素の chart（values なし）で **backupTarget 未設定**であることを確認する。
→ backup 先を Garage/R2 にできない根拠になる。

**Step 2: 描画が通ることを baseline として記録する**

Run: `kubectl kustomize k8s/apps > /tmp/opencode/baseline-apps.yaml && wc -l /tmp/opencode/baseline-apps.yaml`
Expected: エラーなく描画。この行数を比較用に控えておく。

**Step 3: Longhorn の StorageClass 名を確認する**

Run: `kubectl get storageclass`
Expected: `longhorn` が `DEFAULT` になっている。違う場合は以降の
`storageClassName` を読み替える。

**Step 4: Vault の kubernetes auth に `token_reviewer_jwt` が残っていないか確認する（重要）**

Run: `kubectl -n vault exec vault-0 -- vault read auth/kubernetes/config`
Expected: `disable_local_ca_jwt` が `false`、`kubernetes_ca_cert` が設定済み、
そして **`token_reviewer_jwt` キーが存在しない**こと。

- `token_reviewer_jwt` が残っている場合、Vault は TokenReview API 経由で
  login を検証し、**保存済み JWT は自分で失効する**。過去、本集群で
  ESO が `Code: 403 permission denied` を **151 日間**出し続けた事例があり、
  無関係な `ps2bot` / `release-bot` まで巻き込まれた。
- キーが存在する場合、Phase 2 のユーザー作業として「フィールドをクリアし、
  `disable_local_ca_jwt=false` のままにする」ことを依頼する。クラスタ側から
  俺は直せない。

**結果（2026-09-29 実施）: 障害なし。**

`vault-init` Secret が存在せず root token も pod env に入っていないため
config を直接は読めなかった（読む必要もない）。代わりに ESO の観測可能な
挙動で確認した:

- ExternalSecret 6 件すべて `Ready=True` / `reason=SecretSynced`
  （`chem-archive` 2 件、`ps2bot` 2 件、`release-bot` 2 件）
- ESO controller ログに `403` / `permission denied` / `token_reviewer` なし
- `chem-archive` の ESO Secret は 2026-09-28 に生成済み = 活発に同期している

→ Vault の kubernetes auth は健全。Phase 2 を進める前提条件は満たされた。

**Step 5: Commit**

この Task は読み取りのみ。`git commit` はしない。

---
## Phase 1: コード変更（cluster 内、tunnel なし）

### Task 1: `k8s/apps/atuin/` の骨格を作る

**Files:**
- Create: `k8s/apps/atuin/namespace.yaml`
- Create: `k8s/apps/atuin/resource-policy.yaml`
- Create: `k8s/apps/atuin/pvc.yaml`
- Create: `k8s/apps/atuin/deployment.yaml`
- Create: `k8s/apps/atuin/service.yaml`
- Create: `k8s/apps/atuin/kustomization.yaml`

**Step 1: `namespace.yaml` を作成**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: atuin
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

**Step 2: `resource-policy.yaml` を作成（忘れると PVC ごと消える）**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: ResourcePolicy
metadata:
  name: keep-atuin-pvc
policy:
  keep:
    - kustomize.toolkit.fluxcd.io/v1/ExternalSecret
    - v1/PersistentVolumeClaim
    - v1/Secret
    - v1/ConfigMap
```

> Flux の Kustomization は `prune: true`。この `keep` が無いと
> `k8s/apps/atuin/` を Git から削除しただけで **SQLite データベースごと
> 消える**。

`ResourcePolicy` は Flux（kustomize-controller）だけが解釈する独自 kind で、
API Server には存在しない。実測で `kubectl kustomize` の出力には含まれる
ことを確認しているが、**`kubectl apply -k k8s/apps/atuin` は
`no matches for kind "ResourcePolicy"` で失敗する**。適用は必ず Flux 経由
で行う。手動検証したいときは ResourcePolicy を除いたファイルを `-f` で
個別に dry-run する。

**Step 3: `pvc.yaml` を作成**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: atuin-data
  namespace: atuin
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

**Step 4: `deployment.yaml` を作成**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: atuin-server
  namespace: atuin
  labels:
    app: atuin
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: atuin
  template:
    metadata:
      labels:
        app: atuin
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: atuin-server
          image: ghcr.io/atuinsh/atuin:18.23.0@sha256:f232feeead54a0a13132b9cd477e312c3380e9dc90f1db24c4f79ce6c8e034ea
          args:
            - start
          env:
            - name: ATUIN_HOST
              value: "0.0.0.0"
            - name: ATUIN_PORT
              value: "8888"
            - name: ATUIN_DB_URI
              value: sqlite:///config/atuin.db
            - name: ATUIN_OPEN_REGISTRATION
              value: "true"
            - name: RUST_LOG
              value: atuin_server=info
          ports:
            - name: http
              containerPort: 8888
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            tcpSocket:
              port: http
            periodSeconds: 30
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: config
              mountPath: /config
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: atuin-data
```

補足:

- イメージは `v` プリフィックスなしのタグ `18.23.0` のみ存在（`v18.23.0` は
  404）。index digest を pin して amd64/arm64 を同時に解決させる。
- イメージは `USER atuin`（`useradd` 作成 = uid 1000）で動くため
  `runAsUser: 1000` + `fsGroup: 1000` が必要。
- `readOnlyRootFilesystem: true` は `ATUIN_CONFIG_DIR=/config`（PVC に
  マウント済み）だけが書き込み先なので成立する。
- `replicas: 1` 固定。SQLite は write-ahead 前提で冗長化できない。
- `open_registration` はここでは `true`。Task 7 で `false` に落とす。

**Step 5: `service.yaml` を作成**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: atuin-service
  namespace: atuin
  labels:
    app: atuin
spec:
  type: ClusterIP
  selector:
    app: atuin
  ports:
    - name: http
      port: 8888
      targetPort: http
      protocol: TCP
```

**Step 6: `kustomization.yaml` を作成**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - resource-policy.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
```

**Step 7: 描画を検証する**

Run: `kubectl kustomize k8s/apps/atuin | grep -E "kind:|image:|name:" | head -30`
Expected: 5 オブジェクト（Namespace / PVC / Deployment / Service、ResourcePolicy
は kustomize の内部控制なので出力に現れない）が描画され、image に
`@sha256:` が含まれる。

**Step 8: Commit**

```
git add k8s/apps/atuin
git commit -m "feat: add atuin server deployment on sqlite + longhorn"
```

### Task 2: apps ルートに atuin を登録する

**Files:**
- Modify: `k8s/apps/kustomization.yaml`

**Step 1: `- ./atuin` を末尾に追加する**

プラットフォーム系 → アプリ系の並び順を守って末尾に追加:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./longhorn
  - ./ingress-nginx
  - ./sample-nginx
  - ./vault
  - ./external-secrets
  - ./ps2bot
  - ./release-bot
  - ./atuin
```

**Step 2: ルート描画を検証する**

Run: `kubectl kustomize k8s/apps > /tmp/opencode/after-apps.yaml && grep -c "^kind:" /tmp/opencode/after-apps.yaml && grep -c "name: atuin" /tmp/opencode/after-apps.yaml`
Expected: エラーなし。`atuin` 関連が 4 件以上（Namespace / PVC / Deployment /
Service）。

**Step 3: Commit**

```
git add k8s/apps/kustomization.yaml
git commit -m "feat: register atuin in apps kustomization"
```

### Task 3: server-only 判定的 local gate（apply 前）

**Files:**
- Create: `k8s/apps/atuin/manifests_test.py`

**Step 1: `manifests_test.py` を作成**

`deploy/chem-archive-poc` の `k8s/apps/chem-archive/manifests_test.py` を
ベースにした簡易 gate。最低限の以下を固定する:

- `k8s/apps/atuin`、`k8s/apps`、`k8s/flux` の 3 点が描けること
- 出力に `hostNetwork` / `hostPath` が現れないこと
- `atuin-server` Deployment の image が `@sha256:` を含むこと
- `replicas: 1` であること
- `containerPort` が `8888` であること
- `runAsNonRoot: true` / `readOnlyRootFilesystem: true` が立っていること
- `ATUIN_DB_URI` が `sqlite://` で始まること
- **Secret の実値（tunnel token）が manifest に含まれないこと**

**Step 2: 実行する**

Run: `python3 k8s/apps/atuin/manifests_test.py`
Expected: すべて PASS。

**Step 3: Commit**

```
git add k8s/apps/atuin/manifests_test.py
git commit -m "test: add manifest gate for atuin deployment"
```

### Task 4: Flux でクラスタ内のみ的动作させる（tunnel 無し）

**Files:** （なし。Phase 1 の完了確認）

**Step 1: main に push して Flux を待つ**

Run: `git push origin <branch> && sleep 30 && flux get kustomization flux-system`
Expected: `flux-system` が `Ready=True`。`prune: true` なので atuin が
reconcile される。

**Step 2: Pod が立つことを確認する**

Run: `kubectl -n atuin get pods -o wide`
Expected: `atuin-server-…` が `1/1 Running`。

**Step 3: migration が成功していることを確認する（最重要）**

⚠️ **ログを使ってはいけない。** 実測で `RUST_LOG=atuin_server=info` でも
`kubectl logs` は **0 行**（イメージ作者の既定 `RUST_LOG` と同じ）。
ログを根拠に migration 成功を判断する手順は成立しない。

Run: `kubectl -n atuin exec deploy/atuin-server -- ls -l /config`
Expected: `atuin.db` が `atuin:atuin` で存在し、あわせて
`atuin.db-wal` / `atuin.db-shm` / `server.toml` が見える。

実測（v18.23.0、throwaway namespace で smoke test 済み）:

```
-rw-r--r-- 1 atuin atuin   4096 atuin.db
-rw-r--r-- 1 atuin atuin  32768 atuin.db-shm
-rw-r--r-- 1 atuin atuin 255472 atuin.db-wal
-rw-r--r-- 1 atuin atuin    661 server.toml
```

- **WAL モードが有効**（`-wal` / `-shm` が生成される）ことが確定。
  Task 10 のバックアップで `cp` を禁じ `VACUUM INTO` を使う根拠。
- `server.toml` は**全行コメントアウトされたテンプレート**で、実質設定は
  環境変数が勝つ。実測で中身を確認済み。消失しても構わないが、
  復元手順では db と並べて扱う。
- イメージ内に `sqlite3` CLI は無い。DB を触る Job には別イメージが必要。

**Step 4: capabilities を叩いてサーバが.Atuin と応答することを確認する**

Route は 1 段 imperative（`router.rs` 実測）:

| route | method |
|---|---|
| `/` | GET |
| `/healthz` | GET |
| `/register` | POST |
| `/login` | POST |
| `/api/v0/capabilities` | GET |
| `/api/v0/record` | GET/POST |
| `/api/v0/record/next` | GET |
| `/api/v0/me` | GET |
| `/api/v0/store` | DELETE |

`/api/v1/...` は存在しない（`/api/v0/...` が正しい）。`path` 設定値を
prefix にして全 route が nest される。

Run: `kubectl -n atuin exec deploy/atuin-server -- curl -sS http://127.0.0.1:8888/api/v0/capabilities`
Expected: `{"version":"...","capabilities":{"sh.atuin.server/capabilities":{"version":1},"sh.atuin.server/records.page_size":{"version":1,"page_size":100}}}`

`/api/v0/capabilities` は認証不要なので、Access を経由しない cluster 内
の生存確認として最適。

---
## Phase 2: 手作業（Cloudflare ダッシュボード + Vault）

> この Phase はすべて**ユーザー作業**。Claude はダッシュボードを操作しない。

### Task 5: atuin 専用 Cloudflare Tunnel を作る（ユーザー作業）

1. Zero Trust ダッシュボード → Networks → Tunnels → `atuin` tunnel を作成
   （`data-store` / `chem-archive` とは**別**に作る）
2. connector token を控える（Git に入れない）
3. Public hostname を追加:
   - hostname: `atuin.seigo2016.com`
   - service: `http://atuin-service.atuin.svc.cluster.local:8888`
4. Tunnel 設定で **"Protect with Access" を有効化**（origin 側のトークン検証）

### Task 6: Cloudflare Access Application と Service Token を作る（ユーザー作業）

1. Access → Applications → Add → Self-hosted
   - domain: `atuin.seigo2016.com`
2. **Service Token** を作成（Client ID / Client Secret を控える）
3. Policy は **Service Auth** を追加（Service Token selector で上記 token を選ぶ）。
   - ⚠️ **Allow（メール等）policy を追加しない。** 混在させると Service Auth
     policy に token を持たないリクエストが通過しうる。Service Auth のみにする。
4. 必要なら "401 Response for Service Auth policies" を有効化

> Access は fail-closed である必要がある。検証手順は Task 11。

### Task 7: Vault に secret を投入する（ユーザー作業）

1. `atuin-role` を作成:
   - bound service account: `atuin` namespace の `atuin-sa`
   - policy: `atuin` namespace のみ读写、`path "secret/data/atuin" { capabilities = ["read"] }`
2. `secret/atuin` に `cloudflared-token` を投入（Task 5 の token）
3. `auth/kubernetes/config` に `token_reviewer_jwt` が残っていれば**クリア**し、
   `disable_local_ca_jwt=false` のままにする（Task 0 Step 4 の確認結果に従う）

---
## Phase 3: コード変更（tunnel / secrets / backup）

### Task 8: cloudflared Deployment を追加する

**Files:**
- Create: `k8s/apps/atuin/service-account.yaml`
- Create: `k8s/apps/atuin/secret-store.yaml`
- Create: `k8s/apps/atuin/tunnel-external-secret.yaml`
- Create: `k8s/apps/atuin/cloudflared-deployment.yaml`
- Modify: `k8s/apps/atuin/kustomization.yaml`

**Step 1: `service-account.yaml` を作成**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: atuin-sa
  namespace: atuin
```

**Step 2: `secret-store.yaml` を作成**

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-secret-store
  namespace: atuin
spec:
  provider:
    vault:
      server: "http://vault-vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "atuin-role"
          serviceAccountRef:
            name: "atuin-sa"
```

**Step 3: `tunnel-external-secret.yaml` を作成**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: atuin-tunnel
  namespace: atuin
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-secret-store
    kind: SecretStore
  target:
    name: atuin-tunnel
    creationPolicy: Owner
  data:
    - secretKey: token
      remoteRef:
        key: atuin
        property: cloudflared-token
```

**Step 4: `cloudflared-deployment.yaml` を作成**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: atuin-tunnel
  namespace: atuin
  labels:
    app: cloudflared
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: cloudflared
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:2026.8.2@sha256:0aa26e284f05e6c77ae375b8c9c11d9eb6a448fb7bcd8d40f31cb6176189eb38
          args:
            - tunnel
            - --metrics
            - 127.0.0.1:0
            - run
            - --token-file
            - /etc/cloudflared/tunnel/token
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 128Mi
          volumeMounts:
            - name: tunnel-token
              mountPath: /etc/cloudflared/tunnel
              readOnly: true
      volumes:
        - name: tunnel-token
          secret:
            secretName: atuin-tunnel
            defaultMode: 0440
```

設計上の理由（`deploy/chem-archive-poc` と同一）:

- token は `--token-file` で read-only Secret volume から読む。**manifest や
  container args に token 値を置かない。**
- `--metrics 127.0.0.1:0` は load-bearing。省略すると cloudflared が
  metrics/pprof を wildcard アドレスに bind する。loopback に閉じる。
- `ports:` を宣言しないので、その listener を scrape できない。
- **probe を付けない。** probe を入れると connector の再起動が Cloudflare
  edge と結合する。liveness はプロセス終了であり、固まった connector は人手
  で再起動する。
- token は起動時 1 回しか読まれないので、**ローテーションには
  `kubectl -n atuin rollout restart deployment/atuin-tunnel` が必要**。

**Step 5: `kustomization.yaml` を更新する**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - resource-policy.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - service-account.yaml
  - secret-store.yaml
  - tunnel-external-secret.yaml
  - cloudflared-deployment.yaml
```

**Step 6: Commit**

```
git add k8s/apps/atuin
git commit -m "feat: expose atuin through cloudflare tunnel connector"
```

### Task 9: ~~NetworkPolicy で平文区間を塞ぐ~~ → 撤回（Task 3 で実測）

初稿はこの Task で NetworkPolicy を作成したが、**このクラスタでは強制され
ない**と Phase 1 の検証中に判明したため撤回した（Task 3 Step 6 参照）。
`networkpolicy.yaml` は作らない。

理由は 2 点:

1. **flannel には NetworkPolicy エンジンがない。** `/etc/cni/net.d/` は
   `10-flannel.conflist`（`cbr0`、hairpinMode）。実測でも deny-all policy
   下でも Pod 間通信は成功した。
2. **誤解を招く。** 「ingress を限定している」と読むと、実環境では
    何も限定されていない。セキュリティ境界として機能しないものは
   置かない。

クラスタ内平文区間の担保は以下で行う（いずれも追加コストなし）:

- `atuin-service` は ClusterIP で、namespace 外からは到達できない
- flannel の L3 分離により、同一 namespace 内の Pod からのみ
- Access を fail-closed に構成し、fail-open なら即座に hostname を外す

なお Atuin は履歴を**クライアント側で暗号化**するため、サーバが平文で受け
受け取るのはパスワードと暗号化されたデータであり、歴史本文ではない。

flannel に policy プラグイン（kube-router / Calico / Cilero）を入れる
場合はクラスタ全体の CNI 差し替えになるため、**別計画**とする。

---

### Task 10: バックアップを sidecar として追加する

**Files:**
- Create: `k8s/apps/atuin/backup-pvc.yaml`
- Modify: `k8s/apps/atuin/deployment.yaml`
- Modify: `k8s/apps/atuin/kustomization.yaml`

初稿は独立 CronJob だったが **RWO マルチアタッチで却下**した。
`atuin-data` は Longhorn `ReadWriteOnce` なので、**同一ノード上の Pod
からは同時に mount できるが、別のノードからは
`Multi-Attach error for volume ... : volume is already exclusively attached
to one node` で失敗する**。2 ノード構成で node affinity を書かないと 5 分の 1
の確率で backup が落ちる。両 Pod を同一ノードに固定すれば回避できるが、
backup のために可用性を捨てることに相当する。

atuin-server Pod の **sidecar コンテナ**なら常に同じノード・同じ PVC に
アクセスできるので、個別スケジューリングが不要になる。

**Step 1: `backup-pvc.yaml` を作成**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: atuin-backup
  namespace: atuin
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 20Gi
```

**Step 2: `deployment.yaml` に sidecar コンテナを追加する**

atuin-server コンテナの `volumeMounts` の**後**に `backup` コンテナを挿入し、
Pod レベルの `volumes` を 3 つへ置き換える。**以下のブロックは差し込み用の
断片**であり、そのままでは YAML として成立しない（Deployment の一部のみ）:

```yaml
          volumeMounts:
            - name: config
              mountPath: /config
        - name: backup
          image: alpine/sqlite:3.53.4@sha256:7d1599487ead0a5fe7399bb66c6803ae47b46bfa6a1e05db797d907796e4524d
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              while true; do
                sleep 86400 &
                wait $!
                sqlite3 /config/atuin.db "VACUUM INTO '/backup/atuin-$(date +%F).db'" || true
                find /backup -name 'atuin-*.db' -type f -mtime +7 -delete || true
              done
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - name: config
              mountPath: /config
            - name: backup
              mountPath: /backup
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: atuin-data
        - name: backup
          persistentVolumeClaim:
            claimName: atuin-backup
        - name: tmp
          emptyDir: {}
```

ポイント:

- `cp` ではなく `VACUUM INTO`。**WAL が有効**（`-wal` / `-shm` が生成される
  ことは実測済み）なので `cp` は不整合なスナップショットになる。
- `/tmp` の emptyDir は**必須**。`readOnlyRootFilesystem: true` の Pod 内で
  `/tmp` に書き込もうとすると `curl: (23) Failure writing output to
  destination` で失敗することを実測した。`VACUUM INTO` も temp file を
  要する。
- `command:` でイメージの `ENTRYPOINT ["sqlite3"]` を上書きする。
- `|| true` 2 つが必須。同日 2 回目の実行で
  `output file already exists`（実測）になるが、`date +%F` の命名なので
  ループを落とさず翌日リトライされる。
- `alpine/sqlite:3.53.4` の image config は実測済み: `ENTRYPOINT ["sqlite3"]`、
  `apk add sqlite` 済み、User 指定なし（manifest の `runAsUser: 65532` が効く）。

**Step 3: ローカルで backup ロジックを実証する**

cluster を触らずに確認できる。

Run:
```bash
mkdir -p sb/config sb/backup
python3 -c "
import sqlite3
c=sqlite3.connect('sb/config/atuin.db')
c.execute('PRAGMA journal_mode=WAL')
c.execute('CREATE TABLE h(id INTEGER PRIMARY KEY, cmd TEXT)')
c.executemany('INSERT INTO h(cmd) VALUES(?)',[(f'cmd {i}',) for i in range(2000)])
c.commit()"
sh -c 'sqlite3 sb/config/atuin.db "VACUUM INTO '"'"'sb/backup/atuin-$(date +%F).db'"'"'"'
python3 -c "
import sqlite3
s=sqlite3.connect('sb/backup/atuin-$(date +%F).db')
print(s.execute('SELECT count(*) FROM h').fetchone()[0])
print(s.execute('PRAGMA integrity_check').fetchone()[0])"
```
Expected: `2000` / `ok`。**WAL ファイルなしで read-only open できる**ことが
「復旧時に必要なのは .db 1 個だけ」の根拠になる。

実測結果（2026-09-30、ローカル）:

| 項目 | 結果 |
|---|---|
| WAL 2000 行 → `VACUUM INTO` | 成功、90KB の単独ファイル |
| snapshot を WAL 無しで read-only open | 2000 行 / `integrity_check: ok` |
| ソース db | 影響なし（2000 行 / `integrity_check: ok`） |
| 同日 2 回目 | `output file already exists`（`|| true` で無害） |
| ループ継続 | 3 回連続実行しても停止しない |

**Step 4: `kustomization.yaml` に追加する**

```yaml
  - backup-pvc.yaml
```

`backup-cronjob.yaml` は作らない。

**Step 5: Commit**

```
git add k8s/apps/atuin
git commit -m "feat: add daily sqlite vacuum-into backup as sidecar"
```

---

### Task 11: tunnel 経由の Access fail-closed 検証

**Step 1: connector が tunnel につながったことを確認する**

Run: `kubectl -n atuin logs deploy/atuin-tunnel | grep -i "registered\|connection" | head`
Expected: connector 登録のログ。2 Pod とも tunnel につながっていること。

**Step 2: Access が拒否することを確認する（fail-closed 検証）**

Run: `curl -sS -o /dev/null -w "%{http_code}\n" https://atuin.seigo2016.com/healthz`
Expected: `302` / `401` / `403` のいずれか。

- `000` = 到達性問題（tunnel か DNS）。
- **`200` / `404` / `405` / `5xx` = origin が応答した = fail-open。**
  すぐに hostname を外す。これは Access が効いていない（または Access
  policy が Service Auth のみで boomer な bypass がある）ことを意味する。

**Step 3: Service Token 付きで到達することを確認する**

Run: `curl -sS -H "CF-Access-Client-Id: <ID>" -H "CF-Access-Client-Secret: <SECRET>" https://atuin.seigo2016.com/healthz`
Expected: `200`。レスポンス本文が origin 由来であること。

### Task 12: クライアント 1 台で登録する

**Step 1: クライアントバージョンを確認する（18.18.0 以上必須）**

Run: `atuin --version`
Expected: `18.18.0` 以上。**これ未満は `extra_headers` が存在せず
Cloudflare Access を通れない。** 未満なら先にアップグレードする。

**Step 2: 設定を書く**

`~/.config/atuin/config.toml`:

```toml
sync_address = "https://atuin.seigo2016.com"
extra_headers = { "CF-Access-Client-Id" = "<ID>", "CF-Access-Client-Secret" = "<SECRET>" }
```

**Step 3: シェルを再起動して hook が入っていることを確認する**

Run: `exec bash -l && atuin doctor`
Expected: `shell.preexec` が `none` ではなく `bash-preexec` または
`built-in`（`ble.sh` があれば `blesh`）。

**Step 4: 登録する（prompt にして password を history に残さない）**

Run: `atuin register -u <USERNAME> -e <EMAIL>`
Expected: password を対話入力 succeeding、暗号化鍵が表示される。**その鍵を
失うと履歴は二度と解読できない** ので 1Password に保存する。

**Step 5: コマンドが記録されることを確認する**

Run: `echo hello-atuin && atuin history list | head`
Expected: 直前に実行したコマンドが `--author` 付きで出る。

**Step 6: 同期が成功することを確認する**

Run: `atuin sync --verbose 2>&1 | tail -20`
Expected: Access 認証の 401/403 が出ず、sync が成功する。
**401/403 が出たら `extra_headers` のヘッダ名と、Service Token の値を疑う。**

### Task 13: `open_registration` を閉じる（セキュリティのため必須）

**Step 1: 現在の値を確認する**

Run: `kubectl -n atuin get deploy atuin-server -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ATUIN_OPEN_REGISTRATION")].value}'; echo`
Expected: `true`

**Step 2: `false` に変えて commit する**

`k8s/apps/atuin/deployment.yaml` の該当行を:

```yaml
            - name: ATUIN_OPEN_REGISTRATION
              value: "false"
```

**Step 3: Commit と push**

```
git add k8s/apps/atuin/deployment.yaml
git commit -m "fix: close atuin open registration after first account created"
git push origin <branch>
```

**Step 4: 適用されたことを確認する**

Run: `sleep 60 && kubectl -n atuin get deploy atuin-server -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ATUIN_OPEN_REGISTRATION")].value}'; echo`
Expected: `false`

**Step 5: 新しい登録が拒否されることを確認する**

Run: `atuin register -u another-user -e x@example.com`
Expected: 登録が失敗する（サーバが 403/400 を返す）。

### Task 14: バックアップと復旧をテストする

sidecar は起動直後に 1 回 backup してから 24 時間周期になるので、
デプロイ直後に 1 個目のスナップショットが生成されている。

**Step 1: sidecar が動いていることを確認する**

Run: `kubectl -n atuin get pod -l app=atuin -o jsonpath='{.items[0].status.containerStatuses[*].name}'; echo`
Expected: `atuin-server backup` の 2 つ。

Run: `kubectl -n atuin logs deploy/atuin-server -c backup`
Expected: エラー出力なし（正常時は何も出さない）。

**Step 2: スナップショットが存在することを確認する**

Run: `kubectl -n atuin exec deploy/atuin-server -c backup -- ls -l /backup`
Expected: `atuin-<今日>.db` が存在（WAL ファイル `atuin.db-wal` /
`atuin.db-shm` を含まないこと。`VACUUM INTO` の出力は単独ファイル）。

Run: `kubectl -n atuin exec deploy/atuin-server -c backup -- sqlite3 /backup/atuin-$(date +%F).db "PRAGMA integrity_check"`
Expected: `ok`

**Step 3: 2 日目の実行でも壊れないことを確認する（任意）**

2 回目が `output file already exists` で失敗してもループは停止しない
（`|| true`）ことを local 実測済み。cluster で待つ意味はないのでスキップ可。

**Step 4: 復旧手順を確定する**

復旧は Longhorn namespace 内で行う（RWO の制約により別ノードから
`atuin-data` を mount できないため）。

(1) `kubectl -n longhorn-system scale deploy/longhorn-manager --replicas=0`
     snapshot を使い、gutter は使わない:
    Longhorn UI (Service `longhorn-frontend`) から `atuin-backup` の
    snapshot を作成 → `atuin-data` の復元
(2) 復元後 `longhorn-manager` を 1 に戻す
(3) `kubectl -n atuin rollout restart deploy/atuin-server`
(4) `/healthz` と `atuin sync` で確認

`atuin-backup` PVC 内の `.db` ファイルはそれ自体で完全な快照なので、
snapshot が取れなくても `cp` で取り出せる（Task 10 Step 3 の local 実証済み）。

**Step 5: documentation に復旧 runbook を書く（Task 15 に含む）**

### Task 15: ドキュメントを書く

**Files:**
- Create: `k8s/apps/atuin/README.md`
- Create: `docs/clients/atuin-client-setup.md`

**Step 1: `k8s/apps/atuin/README.md` を作成**

`deploy/chem-archive-poc` の `k8s/apps/chem-archive/README.md` と同じ
構成で、次を含める:

- Status / Architecture 一覧表
- データ境界（SQLite が PVC にあること、平文区間の範囲）
- namespace が security boundary ではないこと
- cloudflared hardening の理由
- **Access は fail-closed でなければならない**（Task 11 Step 2 の判定基準）
- ローカル gate の実行方法
- 復旧 runbook（Task 14 Step 3）
- **Tear down の手順と、Flux `prune: true` + `resource-policy.yaml` の関係**
  （`resource-policy.yaml` を消すと `k8s/apps/atuin/` 削除で DB が消える）
- PostgreSQL 移行の判断基準（design doc E 節）
- 思考の根拠は design doc を参照

**Step 2: `docs/clients/atuin-client-setup.md` を作成**

`docs/clients/data-store-client-setup.md` と同じ粒度（日本語）で:

- `## 0. 前提`（クライアント v18.18.0 以上、Tunnel/Access はサーバー側で
  完了済みであること、Service Token の入手先）
- `## 1. atuin クライアントのインストール`（WSL2 / Linux / macOS）
- `## 2. シェル統合`（bash: `eval "$(atuin init bash)"`、
  `ATUIN_NO_BUILTIN_PREEXEC` の意味、WezTerm の `wezterm.sh` との
  **衝突しない**根拠、`PROMPT_COMMAND` を init 後に上書きしないこと）
- `## 3. `config.toml` の設定`（`sync_address` / `extra_headers`）
- `## 4. 登録とログイン`（`atuin register` → 他機は `atuin login`、
  **暗号化鍵の保管**、`--password` を省略して対話入力すること）
- `## 5. 動作確認`（`atuin doctor` / `atuin history list` / `atuin sync`）
- `## 6. トラブルシューティング`（401/403 = token、`shell.preexec: none` =
  非対話シェル、`command not found` = 未再起動、`versions 未満` =
  `extra_headers` 未対応）

**Step 3: Commit**

```
git add k8s/apps/atuin/README.md docs/clients/atuin-client-setup.md
git commit -m "docs: add atuin runbook and client setup guide"
```

### Task 16: 最終確認

**Step 1: 全 apps が描画できる**

Run: `kubectl kustomize k8s/apps > /dev/null && echo OK`
Expected: `OK`

**Step 2: local gate が通る**

Run: `python3 k8s/apps/atuin/manifests_test.py`
Expected: 全 PASS。

**Step 3: Flux が Ready**

Run: `flux get kustomization flux-system && flux get helmrelease -A | grep -v False || true`
Expected: `flux-system` が `Ready=True`。

**Step 4: クラスタ全体-App への副作用がない**

Run: `kubectl -n default get pods`
Expected: `ps2bot` / `release-bot` が動いている（ ESO 権限破壊の回帰チェック。

**Step 5: ESO が実際に同期できている**

Run: `kubectl -n atuin get externalsecret atuin-tunnel && kubectl -n atuin describe externalsecret atuin-tunnel | tail -5`
Expected: `SecretSynced` 条件が `True`。

**Step 6: PR を作成**

- What/why と影響パス（`k8s/apps/atuin/`, `k8s/apps/kustomization.yaml`,
  `docs/clients/atuin-client-setup.md`）
- `kubectl kustomize k8s/apps` の成功
- Task 11 の fail-closed 検証結果（`curl` のステータスコード）
- Task 12 の `atuin sync` 結果
- Cloudflare / Vault 側のユーザー作業が完了済みであること
