# atuin 設計: セルフホスト同期サーバ + Cloudflare Tunnel/Access

Date: 2026-09-29
Status: Approved

## 背景と現状

シェル履歴の共有・検索に Atuin を使いたい。WSL2 + bash を含む手元の各PCで
WezTerm を使うため、**クライアント側の設定が変わらない**同期サーバが要る。

現状の制約:

- `seigo2016.com` は Cloudflare Zero Trust 配下にあり、外部公開は
  Cloudflare Tunnel 経由が原則（`docs/standards/port-allocation-data-store.md`
  が「external access is exclusively via Cloudflare Tunnel」と明言）。
- 認証は Cloudflare Access（既存は Service Token方式）。
- クライアントはブラウザ認証フローを必要としない（0.5 参照）。

公式ドキュメント（v18.23.0 時点）を精査した結果、**4件の重大な誤り/欠落**を
確認した。これが本設計の前提になる。

## 0. 公式ドキュメント精査（重要）

### 0.1 公式 k8s ドキュメントは陳腐化している

`docs.atuin.sh/latest/self-hosting/kubernetes/` と `k8s/atuin.yaml` は、
`atuin-server` バイナリ分離（v18.12.0〜）之前的構成を前提にしている。

v18.23.0 の `Dockerfile` 実測:

```
cargo build --release --bin atuin-server      # atuin 本体はビルドしない
ENTRYPOINT ["/usr/local/bin/atuin-server"]
USER atuin                                    # useradd 作成 → uid 1000
ENV ATUIN_CONFIG_DIR=/config
HEALTHCHECK CMD curl -fsS -o /dev/null "http://localhost:${ATUIN_PORT:-8888}/healthz"
```

したがって:

- `args: ["start"]` は**動作する**（ENTRYPOINT が `atuin-server` なので
  `atuin-server start` として実行される）。
- ただし**同一 Pod に postgres サイドカーを置く構成**と
  `io.kompose.service` ラベル、`containerPort: &port 8888` の YAML アンカー、
  `kubectl apply -n atuin-namespace`（マニフェストの namespace は `atuin`）
  は現行の流儀から乖離している。採用しない。
- `strategy: type: Recreate` で「重複 Pod による破損を防ぐ」注解も、
  Deployment ではなく StatefulSet を推奨する更适合に置き換える。

### 0.2 画像タグに `v` プリフィックスが付かない

GHCR で実測（匿名トークン）:

| タグ | HTTP |
|-----|------|
| `18.23.0` | 200 |
| `v18.23.0` | 404 |
| `latest` | 200 |

ドキュメントの `<LATEST TAGGED RELEASE>` は **GitHub の release タグ名
（`v18.23.0`）ではなく、コンテナタグ名**を指す。混同すると 404 になる。

 Platforms は `linux/amd64` / `linux/arm64` の両対応（multi-arch index）。

### 0.3 組み込み TLS 設定が削除された

`[tls]` セクションは**削除済み**。TLS 終端は reverse proxy に委譲する
のが公式推奨（nginx / Caddy / Traefik）。

→ **Cloudflare Tunnel は本要件において任意ではなく必須**になる。反復プロキシを
当作する。Tunnel は Cloudflare エッジで TLS を終端するため、
`https://atuin.seigo2016.com` がそのまま Atuin クライアントの
`sync_address` になる。

### 0.4 SQLite が tier-one でサポートされている（k8s ページに記載なし）

`server-setup.md` 的人格記述: 「You must have either a PostgreSQL, MySQL or
SQLite database」。tier-one は PostgreSQL と SQLite（MySQL が tier-two）。

```
ATUIN_DB_URI="sqlite:///config/atuin.db"
```

「Note that atuin will create this file if it does not exist.」

→ **postgres Pod を不要にできる。** 2ノード構成のリソース制約下では
これが効く。ここが Phase 1 を SQLite 単一 Pod にする根拠。

### 0.5 Cloudflare Access に対するクライアント側の公式解がある

これが本設計の最も重要な発見。Atuin クライアント v18.18.0 で
`extra_headers` が追加されている（`crates/atuin-client/src/settings.rs` を
tag 実測: 18.17.0 に不在 / 18.18.0 以降に存在）。

`configuration/config.md` の記述:

> Extra HTTP headers to send on every request to the sync server. This is
> useful when a self-hosted server sits behind a proxy or access gateway that
> requires its own authentication header — **for example Cloudflare Access**.

```toml
extra_headers = { "CF-Access-Client-Id" = "...", "CF-Access-Client-Secret" = "..." }
```

適用範囲は sync / login / register（ユーザー名重複チェック含む）/
パスワード変更・アカウント削除。付随する2つの性質が好都合:

- Atuin 自身が管理するヘッダ（`Authorization` 等）は上書き不可
  → `CF-Access-*` を使うのが正しい（`Authorization` 方式ではない）。
- `extra_headers` 設定時、**cross-origin リダイレクトを追わない**。
  資格情報が別オリジンへ送られない。

**したがって Atuin のクライアントは Service Token で非対話認証できる。
ブラウザ OTP は不要。** クライアント側制約は「v18.18.0 以上」のみ。

## A. サーバ構成

**namespace `atuin` を新設する。** `default` に置かない。理由:

- Flux の Kustomization に `prune: true` が入っているため、`k8s/apps/atuin`
  を Git から削除して reconcile すると **PVC ごと消える**。独立 namespace に
  閉じ込め、寿命を意図的に限定する。
- 都有するアプリ（`ps2bot` / `release-bot`）と混ざると `app:` ラベルの
  選択子空間が混ざる。

構成要素:

| オブジェクト | 名前 | 要点 |
|---|---|---|
| Namespace | `atuin` | 独立。`resource-policy.yaml` により PVC は keep |
| Deployment | `atuin-server` | 1 replica 固定。SQLite は write-ahead 前提で冗長化不可 |
| PVC | `atuin-data` | Longhorn 5Gi RWO |
| Service | `atuin-service` | ClusterIP 8888。Tunnel の宛先 |
| Deployment | `atuin-tunnel` | cloudflared、2 replicas |
| CronJob | `atuin-backup` | SQLite スナップショット |
| SecretStore / SA / ExternalSecret | `vault-secret-store` / `atuin-sa` / `atuin-server-tunnel` | 既存アプリのパターンに準拠 |

### A.1 イメージの固定

```
ghcr.io/atuinsh/atuin:18.23.0@sha256:f232feeead54a0a13132b9cd477e312c3380e9dc90f1db24c4f79ce6c8e034ea
```

index digest を pin する。理由:

- 上流のドキュメントが「`main` / `latest` を追うな」と明示している
  （「We cannot guarantee that all updates apply cleanly」）。
- 同じ digest なら amd64 / arm64 で同一ビルドに解決される。
- 既存の `chem-archive`（`deploy/chem-archive-poc` ブランチ）も digest pin を
  採用しており、リポジトリ内の newest な慣習に揃える。

更新は手動（digest 差し替え + commit）。Flux ImageUpdateAutomation は
**意図的に付けない** — 上流が警告している Upgrade 間の手動步骤を
自動 commit にはさせないため。

### A.2 セキュリティ強化

イメージは `USER atuin`（uid 1000）で動作する。Longhorn PVC が root 所有の
ままだと書けないため `fsGroup: 1000` + `fsGroupChangePolicy: OnRootMismatch`。

`readOnlyRootFilesystem: true` + `drop: [ALL]` + `allowPrivilegeEscalation: false`。
`atuin-server` は `/config`（→ `ATUIN_CONFIG_DIR`）にだけ書き込むので成立する。

probe は `/healthz` を使う（イメージの HEALTHCHECK と同じ）。
readiness は tcpSocket、startup は httpGet `/healthz`（初回 migration
考慮し `failureThreshold` を大きめに取る）。

### A.3 smoke test 実測結果（2026-09-29）

Phase 1 の manifest を Flux に入れる前に、throwaway namespace
（PSA `restricted` 同等ラベル + 同一 securityContext + emptyDir を `/config` に
使用）で実 image を動かして検証した。結果はすべて期待どおり:

| 項目 | 結果 |
|---|---|
| image pull / `atuin-server start` | 成功、Pod Ready |
| コンテナ内 uid | `uid=1000(atuin) gid=1000(atuin)` |
| `readOnlyRootFilesystem` | 問題なし（migration 完走） |
| `GET /healthz` | `200` |
| `GET /api/v0/capabilities` | JSON 返却（version + capabilities） |
| `POST /register` | route 存在（`422 missing field email` = 到達、`404` ではない） |
| `kubectl logs` | **0 行** |
| `[metrics]` port 9001 | 待ち受けなし（既定で無効） |

この実行から得られた計画への修正:

1. **ログで migration 成功を判断できない。** `RUST_LOG=atuin_server=info` でも
   出力 0 行。イメージ作者の既定 `RUST_LOG` と同じで、上流の挙動。
   検証は `/config` のファイル生成と `/api/v0/capabilities` で行う。
2. **WAL モードが有効**。`atuin.db-wal` / `atuin.db-shm` が生成される。
   バックアップは `cp` ではなく `VACUUM INTO`。
3. **`server.toml` は自動生成されるが全行コメントアウト**されたテンプレート。
   設定は環境変数が勝つので実害はない。
4. **route は `/api/v0/...` 系**。`/api/v1/...` は存在しない。実測した `router.rs`
   の一覧を Task 4 Step 4 に記載。
5. **`/tmp` は書き込み不可**（`readOnlyRootFilesystem` の帰結）。
   バックアップ Job では emptyDir を `/tmp` に mount する。
6. **イメージ内に `sqlite3` CLI は無い**。DB 操作 Job には別イメージが必要。

### A.4 クラスタ内 Ingress の平文区間

`[tls]` 廃止（0.3）の結果、**atuin-server ↔ cloudflared の区間は平文 HTTP**。
Atuin のパスワードはこの区間を平文で飛ぶ。

対策として NetworkPolicy を置き、atuin-server への ingress を
`app: cloudflared` の Pod のみに限定する。cloudflared は edge 側で TLS を
終端するため、Internet に出る区間は暗号化される。

`deploy/chem-archive-poc` の README が定める「Access must be fail-closed」
の判定条件もそのまま適用する。

## B. 公開経路: Tunnel + Access

| 項目 | 値 |
|---|---|
| Tunnel | **新規、atuin 専用**（`data-store` / `chem-archive` と共有しない） |
| Public hostname | `atuin.seigo2016.com` |
| Service | `http://atuin-service.atuin.svc.cluster.local:8888` |
| Access policy | **Service Auth** + Service Token（Service Token selector） |
| origin のトークン検証 | Tunnel 設定の "Protect with Access" を有効化 |

専用 tunnel に分離する理由:

- hostname 単位の Access policy とトークン失効を、data-store の S3 経路から
  独立に扱える。
- `data-store` tunnel を共有すると、Atuin 側の Access 設定変更が S3/DVC の
  可用性に波及する。

cloudflared Deployment は `deploy/chem-archive-poc` の pattern を踏襲する
（`--token-file` で Secret をマウント、`--metrics 127.0.0.1:0`、
runAsNonRoot 65532、`drop: [ALL]`、readOnlyRootFilesystem、probe 無し、
`topologySpreadConstraints`）。**token 値を Git に置かない。**

## C. クライアント（WSL2 + bash）

**bash のままで問題ない。zsh 移行は不要。** 実測で確認済み。

`atuin init bash` は v18.18.0 以降、同梱の bash-preexec を
preexec backend 未検出なら自動ロードする。ソースのコメントが明示している:

> We can simply load bash-preexec.sh without caring existing preexec-backend
> because duplicate detection is already properly implemented in bash-preexec itself

WezTerm 公式の `wezterm.sh` も**同一の bash-preexec を同梱**しており、
`__bp_install` は `PROMPT_COMMAND` に `__bp_precmd_invoke_cmd` が既にあれば
`return 1` する（`wezterm.sh:334-337`）。二重導入は no-op で、両者は同じ
`preexec_functions` / `precmd_functions` 配列に append するだけ。したがって
**WezTerm shell-integration と Atuin は衝突しない**。

守るべきこと:

1. シェル初期化**後**に `PROMPT_COMMAND` や `trap ... DEBUG` を上書きしない。
   （WezTerm 公式も同じ警告を出している）
2. 精度差は bash-preexec 由来（サブシェル `(...)`、関数定義、
   空の `for ... in; do ...; done` の記録漏れ、`ignorespace` 付きで bash 履歴に
   残る件）。**zsh に移しても消えない。** ble.sh ≥ 0.4 なら改善する。

クライアント設定（`~/.config/atuin/config.toml`）:

```toml
sync_address = "https://atuin.seigo2016.com"
extra_headers = { "CF-Access-Client-Id" = "<id>", "CF-Access-Client-Secret" = "<secret>" }
```

手順書は `docs/clients/atuin-client-setup.md` に
`docs/clients/data-store-client-setup.md` と同じ粒度で作る。

注意: Service Token は**端末ごとではなく同じものを共有**してよいが、
失効時は全端末が落ちる。失効時の影響を小さくするため、トークン値は手順書に
書かず 1Password 等の secret manager に置かせる。

## D. バックアップ

**判断保留方針**: Phase 1 は SQLite で PoC し、負荷を見てから PostgreSQL
へ移行する。移行の判断基準は E. に記す。

バックアップ先は当初 Garage S3 / R2 を候補として検討したが、
現状どちらもクラスタから直接到達できない:

- Garage S3 は data-store VM 上の `127.0.0.1:3900` 束縛のみで、
  cluster からは到達不能（`docs/standards/port-allocation-data-store.md`）。
- Longhorn の HelmRelease には **backupTarget を設定していない**
  （`k8s/apps/longhorn/helm.yaml` は素の chart、values なし）。

Phase 1 では**新しいネットワーク経路や新しい資格情報をクラスタに持ち込まず**、
2つ目の Longhorn PVC へ日次スナップショットを落とす方式にする:

- `VACUUM INTO` で `.db` を整合した状態で複製する（WAL 中の `cp` は不可）。
- 保持 7 日、`find -mtime +7 -delete` でプルーン。
- `sqlite3` CLI 同梱の `alpine/sqlite:3.53.4` を digest pin で使う。

### D.1 実行主体は CronJob ではなく sidecar

初稿は独立 CronJob だったが、**RWO マルチアタッチの問題で却下**した。

`atuin-data` は Longhorn の `ReadWriteOnce` で、**同一ノード上的 Pod からは
同時に mount できる**。別 Pod の CronJob が別のノードにスケジュールされると

```
Multi-Attach error for volume pvc-... : volume is already exclusively attached to one node
```

で失敗する。2 ノード構成で node affinity を書かないと 5 分の 1 の確率で
backup が落ちる。両 Pod を同じノードに固定すれば回避できるが、それは
バックアップのために可用性を捨てる相当于である。

そこで **atuin-server Pod の sidecar コンテナ**で実行する。同一 Pod なので
常に同じノード・同じ PVC にアクセスでき、別途スケジュールする必要もない。
代償は sidecar が常に居る（32Mi リクエスト）ことだけ。

### D.2 実測（local、2026-09-30）

同じ shell をローカルで実行して確認した:

| 項目 | 結果 |
|---|---|
| WAL 2000 行の db → `VACUUM INTO` | 成功、90KB の単独ファイル |
| snapshot を **WAL 無しで** read-only open | 2000 行 / `integrity_check: ok` |
| ソース db | 影響なし（2000 行 / `integrity_check: ok`） |
| 同日 2 回目 | `output file already exists` を stderr に出すが無害（`|| true`） |
| ループ継続 | 3 回連続実行してもループは停止しない |

`alpine/sqlite:3.53.4` の image config も確認した:
`ENTRYPOINT ["sqlite3"]`（manifest の `command:` が上書きする）、
`apk add sqlite` 済み、User 指定なし（manifest の `runAsUser: 65532` が効く）。

R2 へのオフロードは Phase 4 の任意課題とする（その時点で R2 資格情報を
Vault 経由でクラスタに配る判断が要るため、別計画に分ける）。

## E. PostgreSQL へ移行する判断基準

SQLite がボトルネックになったら移行する。 quantitative な目安:

- `atuin-server` の CPU 使用率が常用で 500m を超える、または
- PVC の I/O wait が常態化する、または
- 履歴データ量が 5Gi PVC の 70% を超える、または
- クライアント 수가 10 端末を超え sync が遅延する

移行時は:

- postgres を StatefulSet 化（Deployment + `Recreate` ではなく）
- `pg_dump` による日次 CronJob
- `ATUIN_DB_URI` を postgres に差し替え、`/config` PVC は廃止
- SQLite の `.db` を pq の upsert 経路で取り込む
  （`atuin import` はローカルの SQLite を使うため、サーバ側データは
  SQL レベルでの移行が必要 — 移行前に必ず検証すること）

## F. 変更対象と移行手順

### コード変更

- 新規 `k8s/apps/atuin/`（namespace / deployment / pvc / service /
  secret-store / external-secret / networkpolicy / cronjob /
  resource-policy / kustomization）
- `k8s/apps/kustomization.yaml` に `- ./atuin` を追加
- 新規 `k8s/apps/atuin/README.md`（運用 runbook）
- 新規 `docs/clients/atuin-client-setup.md`（クライアント手順）
- Vault に `atuin` の secret と `atuin-role` を追加（手作業）

### 手作業（Cloudflare ダッシュボード / Vault）

1. atuin 専用 tunnel の作成、connector token 取得
2. Public hostname `atuin.seigo2016.com` → `atuin-service.atuin.svc.cluster.local:8888`
3. Access Application（self-hosted、`atuin.seigo2016.com`）作成
4. Service Token 作成 + **Service Auth** policy を追加
5. Tunnel 設定で "Protect with Access" を有効化
6. Vault: `atuin-role` 作成（`atuin-sa` に bound、`atuin` namespace）
7. Vault: `secret/atuin` に `cloudflared-token` を投入
8. Vault の `auth/kubernetes/config` に **`token_reviewer_jwt` が残っていない
   を確認**（残っていると ESO が 403 で沈黙し、本件を含めて過去 151 日
   停止インシデントの再現になる。`disable_local_ca_jwt=false` のまま
   `kubernetes_ca_cert` 検証経路を使う）

### 移行順序

1. namespace / Pod / Service だけ適用（tunnel なし、cluster 内だけで検証）
2. `/healthz` 応答と `kubectl logs` で migration 成功を確認
3. cloudflared Pod 適用 → connector が tunnel に接続したことを確認
4. Public hostname + Access Application 作成
5. Service Token 発行 → クライアント 1 台で `atuin register`
6. `open_registration` を `false` に落とす（**セキュリティのため必須**）
7. 全クライアントへ手順书的配布
8. backup CronJob を実際に 1 回走らせて復旧テスト

## 却下した代替案

- **PostgreSQL 2 Pod 構成**: 公式ドキュメントの構成。リソース消費が大きく、
  まず SQLite で試して、必要になったら移行する方が速い。
- **ingress-nginx 経由**: `ingress-nginx` は hostNetwork + hostPorts で
  ノード IP に 80/443 を直貼りしており、cert-manager も無い。Tunnel 専用
  path のほうが境界が明確（既存の `chem-archive` も同じ判断）。
- **Pod 内 reverse proxy（Caddy/nginx）**: `[tls]` 廃止への対処に見えますが、
  Cloudflare エッジが既に TLS を終端しており、Pod 内に 1 プロセス増える
  だけで冗長。却下。
- **Access のメール OTP**: Atuin クライアントはブラウザフローを持たないため
  成立しない。`extra_headers` による Service Token のみ採る。
- **Pod 内から Garage/R2 へ直接 push**: 新たな資格情報をクラスタに持ち込む
  ことになる。Phase 1 では望ましくない。
- **既存 data-store tunnel の再利用**: 影響範囲が S3/DVC まで波及するため却下。
- **Service Token を手順書に平文記載**: 失効時の blast radius が全端末に
  広がる。secret manager に置かせる。
