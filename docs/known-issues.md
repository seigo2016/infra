# 未対応作業

このリポジトリ／クラスタで**まだやっていない作業**の SSoT。完了した作業の経緯は
git 履歴と merged PR に残っているので、ここには載せない。

優先度の高い順に並べる。

---

## 1. atuin の匿名登録が開いている（セキュリティ）

`k8s/apps/atuin/deployment.yaml` の `ATUIN_OPEN_REGISTRATION` が `"true"`。

外部からは Cloudflare Access が `403` を返すため匿名では到達できないが、
**Access 認証を通った人は誰でも atuin アカウントを自動作成できる。**

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://atuin.seigo2016.com/healthz
# 302 / 401 / 403 のみが Access の拒否（fail-closed）。
# 200 / 404 / 405 / 5xx は origin が応答しているので fail-open。hostname を外すこと。
```

対処: `"false"` に変更して commit する。アカウント登録が完了していることを確認した
上で実施する。

```
k8s/apps/atuin/deployment.yaml
  - name: ATUIN_OPEN_REGISTRATION
    value: "true"      →  "false"
```

---

## 2. release-bot が ImagePullBackOff

`default/release-bot-deployment` が `ImagePullBackOff`。

```
ghcr.io/ps2-localization-jp/release-bot:latest → 403（認証ありでも）
```

- ソースリポジトリ `PS2-Localization-JP/PlanetSide2-nihongo-mod-management` が **private**
- `ImageRepository` に `secretRef` が無い（`provider: generic` で匿名 pull）
- org の public repo は `-mod-api` / `-mod-ui` のみ。`release-bot` package は 404
- クラスタ内の pull secret（`seigo2016`）でも 403

選択肢（判断待ち）:

- **A**: 上流で image を public 化、または再 publish
- **B**: `k8s/apps/release-bot/` を削除（Flux が prune）
- **C**: `deployment.yaml` を `replicas: 0` にして health check を外す

付随:

- `k8s/apps/release-bot/` は `docker-registry-secret.yaml`（`ghcr-registry-secret`）、
  `external-secret.yaml`（`release-bot-secrets`）、`secret-store.yaml`、
  `service-account.yaml`、`image-automation.yaml` を含む
- B を選ぶ場合は Vault の `secret/release-bot-secrets` も消すか判断する
- B を選んだ場合、`ImageUpdateAutomation` の `update.path` への push が止まることを確認する

---

## 3. Vault に auto-unseal がない

`k8s/apps/vault/helm.yaml` に auto-unseal / init-unseal の設定も Job もない。
Pod を再起動すると必ず sealed になり、`vault operator unseal`（5 key 中 3 key）の
人手が必要。

backup タスクと併せて、Transit / GCP KMS / Kubernetes どれかでの auto-unseal
導入を検討する。運用手順は `docs/standards/vault.md`。

---

## 4. Longhorn の backup target が無い

`StorageClass longhorn` は `backupTargetName: default` を指定しているが、
backup target は **0 件**、`recurringjob` も **0 件**。設定が宙に浮いている。

- 2 ノード構成では両ノードが同時に落ちると replica を失う。backup は唯一の対策
- backup target を入れる場合、`nfs-common` が `k8s-worker-1` に未導入
- `docs/standards/longhorn.md` の「未導入でも問題ないもの」参照

---

## 5. 2 ノード etcd（quorum=2）

`k8s-master` と `k8s-worker-1` の両方がコントロールプレーンで etcd を持つため
**etcd が 2 ノード構成**。quorum=2 なので **1 ノード停止で etcd が機能停止**し、
可用性は 1 ノードクラスタ以下になる。

`k8s-worker-1` は Ansible inventory 上は `k8s-workers` グループだが実体は完全な
コントロールプレーン（apiserver / etcd を持つ）。

3 ノード化するか、単一コントロールプレーンに寄せるか。前提の整理は
`docs/standards/k8s-cert-renewal.md` の「クラスタ構成上の前提」。

---

## 完了済み（参考）

- Longhorn の 2 ノード化と replica 数の 2 への変更（2026-10-04）— 経緯は
  git 履歴と PR
- `open-iscsi` の `ansible/setup-worker.yml` への追加
- kubeadm リーフ証明書の更新（`check-expiration` の残りは 340 日、CA は 2035 年まで）
