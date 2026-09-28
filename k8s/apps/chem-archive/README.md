# chem-archive

Kubernetes and Flux manifests for the chemistry-lab Word-centered record service,
deployed into the existing Proxmox Kubernetes cluster and published at
`https://chem.seigo2016.com` through a Cloudflare Tunnel.

**Status: staged, not live.** Flux is *intended* to reconcile these files from the
infrastructure repository, never by hand; see **Flux path** before assuming it does.
The application image is still pinned to a placeholder digest, so nothing works yet
and nothing is in front of the client. Staged means exactly that: a reconciled build
still creates the Deployment and its pod sits in `ErrImagePull`, so this state depends
on replacing the digest, not on withholding the root kustomization. Namespace
`chem-archive`, synthetic data, no backup, no ownership outside that namespace.

## Architecture

| Resource | Role |
| --- | --- |
| Namespace | Pod Security `restricted` at enforce, audit, and warn |
| ConfigMap `chem-archive-env` | Application environment, consumed through `envFrom` |
| PersistentVolumeClaim `chem-archive-runtime` | Longhorn, ReadWriteOnce, at `/app/runtime` |
| Service `chem-archive-service` | ClusterIP on 8080 |
| ServiceAccount `chem-archive-sa` | Vault auth identity, no API token mounted |
| SecretStore `vault-secret-store` | In-cluster Vault, Kubernetes auth as `chem-archive-role` |
| ExternalSecret `chem-archive-tunnel` | Cloudflare connector token |
| ExternalSecret `ghcr-registry-secret-chem-archive` | Private GHCR pull credentials |
| Deployment `chem-archive` | The application, one replica, `Recreate` |
| Deployment `chem-archive-tunnel` | Two Cloudflare Tunnel connectors (current manifest) |
| ResourceQuota, LimitRange | Namespace guard rails, values not asserted by the test |

## Data boundary

A proof of concept for client alignment, not a production service, and repository
contents and application data are confidential to the client.

- Every record, attachment, and document is disposable: seed only with the
  synthetic generator, and treat nothing entered here as a real experimental record.
- The PersistentVolumeClaim holds a SQLite database and uploaded files. If the
  volume is deleted, the data is gone and must be re-seeded from scratch.
- Longhorn keeps **three replicas of the volume on three nodes in the same
  cluster**. That is replication for availability, not a backup: no snapshots, no
  off-cluster copy, one shared failure domain, so any of those failures loses data.

## The namespace is not a security boundary

**This cluster runs Flannel, which does not enforce NetworkPolicy.** Adding one
here would not change that: the API server accepts a NetworkPolicy and nothing
evaluates it. It is left available as future remediation.

- Pod Security `restricted` is a **workload hardening** control, not network
  isolation.
- **Any pod in the cluster can reach `chem-archive-service` on 8080**, and the
  application has no authentication of its own, so reaching it is being a user.
- Cloudflare Access is the only access control in the path: it guards the public
  hostname, not the ClusterIP Service from inside the cluster.

Accepted because the data is synthetic; real records would need a policy-capable
CNI, or a dedicated cluster.

## Cloudflared hardening

- The connector reads its token from `/etc/cloudflared/tunnel/token` with
  `--token-file`, from a read-only secret volume at mode `0440`; no token value
  appears in the manifests or in the container arguments.
- `--metrics 127.0.0.1:0` is load-bearing. cloudflared's default binds metrics to a
  wildcard address, and that one listener also serves pprof and debug endpoints, so
  the flag confines it all to pod loopback. Dropping it restores the wildcard bind.
- The container declares no ports, so nothing can scrape that listener. There are
  no probes, because a probe would couple connector restarts to Cloudflare's edge;
  liveness is process exit, so a wedged connector needs a human restart.

Two connectors, no Service in front of the tunnel, and no probes describe the
current manifest, not invariants. The test checks the token wiring, the loopback
metrics address, a single container, the mode `0440` read-only volume, and that no
port is declared. It does not check the connector count, probes, spread, or Service.

## Deploy prerequisites

Nothing in this list lives in this repository.

1. **Architecture.** Confirm the published digest is `linux/amd64` and matches
   the cluster nodes; another architecture produces `ErrImagePull`.
2. **Vault role.** Kubernetes auth must be enabled at `kubernetes/`, and
   `chem-archive-role` must exist bound to `chem-archive-sa` in the `chem-archive`
   namespace.

   `auth/kubernetes/config` must **not** carry a `token_reviewer_jwt`. With a stored
   reviewer JWT, Vault validates logins through the TokenReview API, and a stored
   JWT expires on its own: this cluster reached ESO `Code: 403 permission denied` on
   every sync for 151 days because of it, and the outage affected the unrelated
   `ps2bot` and `release-bot` workloads too. Clear the field and leave
   `disable_local_ca_jwt=false`, so Vault validates the presented service account JWT
   against `kubernetes_ca_cert`. That path makes no Kubernetes API call and needs no
   RBAC binding for `chem-archive-sa` or for the Vault server account. A
   `system:auth-delegator` binding does not repair a stale reviewer JWT; it only
   satisfies a reviewer token that is still valid.
3. **Registry credentials.** `secret/chem-archive` must hold `github-username` and
   `github-token` as a dedicated classic PAT scoped `read:packages`, not a
   workstation token. The `{{ .github_username }}` and `{{ .github_token }}` strings
   in `registry-external-secret.yaml` are template placeholders, not credentials.
   No value belongs in this repository.
4. **Application image.** `deployment.yaml` pins the published `linux/amd64` digest
   from `seigo2016/chem-archive`. Application CI publishes to GHCR only on branch
   `web-native`, and digest updates here stay manual: there is deliberately no
   `ImageRepository` or `ImageUpdateAutomation`, so Flux will not rewrite the digest.

## Local gate

**This infrastructure repository has no CI.** `manifests_test.py` is an advisory
local gate, so run it and read the result. It renders `k8s/apps/chem-archive`,
`k8s/apps`, and `k8s/flux`, and requires the chem-archive Namespace and Deployment
in that Flux render.

```bash
python3 k8s/apps/chem-archive/manifests_test.py
REQUIRE_DEPLOYABLE=1 python3 k8s/apps/chem-archive/manifests_test.py
```

The plain run is the normal pre-commit check and allows the placeholder digest. The
gated run is the pre-publish check: it **fails on the placeholder on purpose**, so it
is expected to fail until a real digest replaces the zeros; run it before publishing.

## Access must be fail-closed

The application implements no authentication of its own, so Cloudflare Access is
the only thing in front of the public hostname. Its application for
`chem.seigo2016.com` must exist and be enforced **before** the hostname is handed
to the client: self-hosted on that domain, Allow by email listing only the
addresses that may see the PoC, one-time PIN, Access JWT validation on the origin
request, no bypass policy, and a short session.

The commands and the verdict table are deliberately not restated here: the app
repository's `docs/DEMO_HOSTING.md`, section "The Access deny check", is canonical
for both. The rule in one line: probe with an unauthenticated `GET` and `curl -sS`,
and only a real `302`, `401`, or `403` counts as Access denying the request. `000`
means no response arrived at all, so it is a reachability problem and not a verdict;
`200`, `404`, `405`, and `5xx` mean the application answered, which is fail-open and
needs investigating. Any fail-open result means the hostname goes down.

## Cloudflare Tunnel

The public hostname's origin in the Cloudflare dashboard must be:

```text
http://chem-archive-service.chem-archive.svc.cluster.local:8080
```

The tunnel is remote-managed, so nothing identifying it is stored here; the connector
token exists only in Vault. Rotating that token needs `kubectl -n chem-archive
rollout restart deployment/chem-archive-tunnel`, since the connectors read it once at
startup, then `rollout status`.

**Cutover.** Verify privately through a port-forward first, with no DNS or tunnel
change. Only then point the hostname at this tunnel, confirm the Access policy
bites, and keep the previous connector until the client accepts.

**Rollback.** Revert the image digest in `deployment.yaml` to the previous
known-good value and let Flux reconcile; the Deployment uses `Recreate`, so the old
pod stops before the new one starts and the runtime volume is reattached, not
recreated. For a hostname problem, remove the hostname from this tunnel and restore
the previous route. Vault changes are additive, so rollback does not touch Vault.

## Flux path

**Read this before merging.** `k8s/flux/kustomization.yaml` is new; the `flux-system`
files beside it are Flux-generated and untouched here. `gotk-sync.yaml` points the
Kustomization at `./k8s/flux`, where no root kustomization existed and no YAML file
sits at that level, so what the path rendered was implicit. The new root routes
through `flux-system` and `../../apps`, producing the same 81 resources the
`flux-system` path already builds.

Whether this application is in a Flux build depends on the live path. Under
`./k8s/flux/flux-system`, the existing `flux-system` -> `../../apps` chain already
includes the `./chem-archive` entry, and the new root is inert there. Under
`./k8s/flux`, the new root is required for any build at all, and it also brings in
the other seven apps (Longhorn, Vault, ingress-nginx, External Secrets Operator,
ps2bot, release-bot, sample-nginx). `prune: true` means the build result decides
what is applied and what is deleted, so review and merge deliberately and check the
live path with the command under **Verification**. Nothing here claims it has
reconciled this path.

## Verification

```bash
kubectl kustomize k8s/apps/chem-archive >/dev/null
kubectl kustomize k8s/apps >/dev/null
kubectl kustomize k8s/flux >/dev/null
kubectl -n flux-system get kustomization flux-system -o jsonpath='{.spec.path}{"\n"}'
kubectl -n chem-archive get externalsecret,secret,pvc
kubectl -n chem-archive describe externalsecret
kubectl -n chem-archive rollout status deployment/chem-archive
kubectl -n chem-archive rollout status deployment/chem-archive-tunnel
kubectl -n chem-archive logs -l app=cloudflared --tail=50
```

Both ExternalSecrets reporting `SecretSynced` and both Secrets existing means
Vault, the role, the binding, and the key names are correct; check readiness only,
never print a value. The connector logs are the tunnel health check. Then verify
the application privately:

```bash
kubectl -n chem-archive port-forward svc/chem-archive-service 8080:8080
```

Confirm the frontend loads, a record can be created, an attachment uploads and
downloads, and a PDF export renders with the Japanese font. Then prove the volume is
attached by deleting the pod and checking that the records come back:

```bash
kubectl -n chem-archive delete pod -l app=chem-archive
```

## Teardown

**Teardown happens through Flux prune, and it is not selective.** The Flux
Kustomization has `prune: true`, so when this directory disappears from Git and Flux
reconciles, it deletes every resource it owned, namespace and PVC included. Removing
these files is a destructive teardown, not a cleanup: **warn and get explicit
confirmation first**.

Once removal is authorized:

1. Remove the public hostname from the tunnel.
2. Remove the Access application if the hostname is no longer needed.
3. Delete the dedicated tunnel, revoke the connector token in Vault, then remove
   `secret/chem-archive` and the `chem-archive-role` binding.
4. Remove `k8s/apps/chem-archive/` and the `./chem-archive` entry from
   `k8s/apps/kustomization.yaml`, and let Flux reconcile.
5. Optionally delete the private GHCR package and revoke the dedicated PAT.

Do not run `terraform destroy`, and do not modify the Proxmox VMs, the shared
ingress, Longhorn, Vault, the External Secrets Operator, or the data-store tunnel.

## Where the reasoning lives

This file is the runbook. Longer rationale lives with the design documents in the
application repository: `docs/ARCHITECTURE.md`, `docs/REQUIREMENTS.md`,
`docs/HANDOFF.md`, `docs/DEMO_HOSTING.md` (hosting model, Access policy,
`web-native` branch), and `docs/WEB_NATIVE_PROPOSAL.md` with `docs/DECISIONS.md` for
the undecided parts.
