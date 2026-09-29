# atuin セルフホスト同期サーバ Implementation Plan

> **For Claude:** REQUIRED SUB-KILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 集群内に Atuin 同期サーバ（SQLite + Longhorn）を Flux でデプロイし、Cloudflare Tunnel / Access（Service Token）経由で、WSL2 + bash の各PCから WezTerm 経由で利用できるようにする。

**Architecture:** `atuin` namespace に `atuin-server` Deployment 1 本（SQLite）+ ClusterIP Service + cloudflared Deployment 2 本 + 日次バックアップ CronJob。外部公開は新規 Tosc専用 Cloudflare Tunnel、認証は Access Service Token。Atuin クライアントの `extra_headers`（v18.18.0+）が token を送信する。

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

Run: `kubectl -n atuin logs deploy/atuin-server | tail -30`
Expected: schema migration 完了のログ、panic なし。

Run: `kubectl -n atuin exec deploy/atuin-server -- ls -l /config`
Expected: `atuin.db` が `atuin:atuin` で存在（WAL ファイル、
`atuin.db-wal`、`atuin.db-shm` も）。

**Step 4: healthz を確認する**

Run: `kubectl -n atuin run healthz --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- curl -sS -o /dev/null -w "%{http_code}\n" http://atuin-service.atuin.svc.cluster.local:8888/healthz`
Expected: `200`。

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

### Task 9: NetworkPolicy で平文区間を塞ぐ

**Files:**
- Create: `k8s/apps/atuin/networkpolicy.yaml`
- Modify: `k8s/apps/atuin/kustomization.yaml`

Atuin の組み込み `[tls]` は削除済みなので、`atuin-server` ↔ cloudflared の
区間は**平文 HTTP**（パスワードが平文で飛ぶ）。ingress を cloudflared Pod
だけに限定する。

**Step 1: `networkpolicy.yaml` を作成**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: atuin-allow-tunnel-only
  namespace: atuin
spec:
  podSelector:
    matchLabels:
      app: atuin
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: cloudflared
      ports:
        - protocol: TCP
          port: 8888
```

**Step 2: `kustomization.yaml` に追加する**

```yaml
  - networkpolicy.yaml
```

**Step 3: Commit**

```
git add k8s/apps/atuin
git commit -m "feat: restrict atuin ingress to cloudflared connector"
```

### Task 10: バックアップ CronJob を追加する

**Files:**
- Create: `k8s/apps/atuin/backup-pvc.yaml`
- Create: `k8s/apps/atuin/backup-cronjob.yaml`
- Modify: `k8s/apps/atuin/kustomization.yaml`

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

**Step 2: `backup-cronjob.yaml` を作成**

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: atuin-backup
  namespace: atuin
spec:
  schedule: "17 3 * * *"
  timeZone: Asia/Tokyo
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        metadata:
          labels:
            app: atuin-backup
        spec:
          restartPolicy: OnFailure
          automountServiceAccountToken: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            runAsGroup: 65532
            fsGroup: 65532
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: backup
              image: alpine/sqlite:3.53.4@sha256:7d1599487ead0a5fe7399bb66c6803ae47b46bfa6a1e05db797d907796e4524d
              command:
                - /bin/sh
                - -c
                - |
                  set -eu
                  d=/backup
                  mkdir -p "$d"
                  sqlite3 /data/atuin.db "VACUUM INTO '$d/atuin-$(date +%F).db'"
                  find "$d" -name 'atuin-*.db' -type f -mtime +7 -delete
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
                  cpu: 500m
                  memory: 512Mi
              volumeMounts:
                - name: data
                  mountPath: /data
                  readOnly: true
                - name: backup
                  mountPath: /backup
          volumes:
            - name: data
              persistentVolumeClaim:
                claimName: atuin-data
            - name: backup
              persistentVolumeClaim:
                claimName: atuin-backup
```

`cp` ではなく `VACUUM INTO` を使う。SQLite は WAL 書き込み中なので
`cp` は不整合なスナップショットになる。`VACUUM INTO` は
SQLite 3.27+ で一貫したコピーを作る。

**Step 3: `kustomization.yaml` に追加する**

```yaml
  - backup-pvc.yaml
  - backup-cronjob.yaml
```

**Step 4: Commit**

```
git add k8s/apps/atuin
git commit -m "feat: add daily sqlite backup cronjob for atuin"
```

---
## Phase 4: デプロイと検証

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

**Step 1: CronJob を手動で起動する**

Run: `kubectl -n atuin create job --from=cronjob/atuin-backup backup-test-1`
Expected: Job が `Complete`。

Run: `kubectl -n atuin logs job/backup-test-1`
Expected: エラーなし。

**Step 2: スナップショットが存在することを確認する**

Run: `kubectl -n atuin run backup-ls --rm -it --restart=Never --image=alpine:3.22 -- ls -l /backup`
Expected: `atuin-<今日>.db` が存在。

**Step 3: 復旧手順を wiki 化できる形で確認する**

復旧手順（Longhorn 上で直接行う）:

(1) `atuin-backup` PVC を新しい Pod に mount して `/backup/atuin-<日付>.db` を取り出す
(2) `atuin-data` の `/config/atuin.db` を退避
(3) 取り出した `.db` を `atuin-data` の `/config/atuin.db` に配置して
    owner を 1000:1000 にする
(4) `kubectl -n atuin rollout restart deploy/atuin-server`
(5) `/healthz` と `atuin sync` で確認

実際は Longhorn の namespace 内でコンテナを起動して cp する方が安全。

**Step 4: documentation に復旧 runbook を書く（Task 15 に含む）**

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
