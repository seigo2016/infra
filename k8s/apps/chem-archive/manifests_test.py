import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:
    sys.exit(f"FAIL PyYAML is required to parse the rendered manifests: {exc}")

APP = "k8s/apps/chem-archive"
APPS = "k8s/apps"
FLUX = "k8s/flux"
REPO = Path(__file__).resolve().parents[3]
ROOT_KUSTOMIZATION = REPO / "k8s" / "apps" / "kustomization.yaml"
GATE = "REQUIRE_DEPLOYABLE"
NS = "chem-archive"
APP_NAME = "chem-archive"
TUNNEL_NAME = "chem-archive-tunnel"
TUNNEL_SECRET = "chem-archive-tunnel"
REGISTRY_SECRET = "ghcr-registry-secret-chem-archive"
VAULT_STORE = "vault-secret-store"
VAULT_KEY = "chem-archive"
TOKEN_DIR = "/etc/cloudflared/tunnel"
TOKEN_FILE = f"{TOKEN_DIR}/token"
RUNTIME_MOUNT = "/app/runtime"
PUBLIC_BASE_URL = "https://chem.seigo2016.com"
ZEROS = "0" * 64

VAULT_FIELDS = (("server", "http://vault-vault.vault.svc.cluster.local:8200"), ("path", "secret"), ("version", "v2"))
REMOTE_MAPPINGS = (
    (TUNNEL_SECRET, "token", "cloudflared-token"),
    (REGISTRY_SECRET, "github_username", "github-username"), (REGISTRY_SECRET, "github_token", "github-token"),
)
POD_KINDS = ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "ReplicationController", "Job", "CronJob")
POD_SECURITY = (
    ("securityContext.runAsNonRoot", True), ("securityContext.seccompProfile.type", "RuntimeDefault"),
    ("automountServiceAccountToken", False),
)
CONTAINER_SECURITY = (
    ("securityContext.allowPrivilegeEscalation", False), ("securityContext.readOnlyRootFilesystem", True),
    ("securityContext.capabilities.drop", ["ALL"]),
)
HOST_KEYS = ("hostNetwork", "hostPID", "hostIPC", "hostPort", "hostPath")
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")
CREDENTIAL = re.compile(r"ghp_\w{16,}|github_pat_\w{16,}|eyJhIjoi[\w.-]{16,}")


class Report:
    def __init__(self):
        self.passed = 0
        self.failures = []

    def check(self, name, ok, detail=""):
        if ok:
            self.passed += 1
            return True
        self.failures.append(f"{name}: {detail}" if detail else name)
        return False

    def equal(self, name, actual, expected):
        return self.check(name, actual == expected, f"expected {expected!r}, got {actual!r}")

    def absent(self, name, found):
        return self.check(name, not found, f"found {found!r}")

    def only(self, name, found):
        return self.equal(f"{name} exists exactly once", len(found), 1)

    def emit(self):
        for failure in self.failures:
            print(f"FAIL {failure}")
        print(f"{self.passed} checks passed, {len(self.failures)} failed")


def render(path):
    try:
        done = subprocess.run(["kubectl", "kustomize", path], cwd=str(REPO), capture_output=True, text=True, timeout=120)
    except OSError as exc:
        return None, None, f"`kubectl kustomize {path}` could not run: {exc}"
    if done.returncode != 0:
        detail = (done.stderr or done.stdout or "").strip()
        return None, None, f"`kubectl kustomize {path}` exited {done.returncode}: {detail}"
    try:
        docs = [d for d in yaml.safe_load_all(done.stdout) if isinstance(d, dict)]
    except yaml.YAMLError as exc:
        return None, None, f"rendered output is not valid YAML: {exc}"
    if not docs:
        return None, None, "rendered output contains no documents"
    return docs, done.stdout, None


def dig(node, *keys, default=None):
    for key in keys:
        if not isinstance(node, dict):
            return default
        node = node.get(key)
    return node if node is not None else default


def res_name(doc):
    return dig(doc, "metadata", "name", default="")


def kinds(docs, kind, wanted=None):
    return [d for d in docs if d.get("kind") == kind and (wanted is None or res_name(d) == wanted)]


def tpl(doc):
    for path in (("template", "spec"), ("jobTemplate", "spec", "template", "spec")):
        pod = dig(doc, "spec", *path, default={})
        if "containers" in pod:
            return pod
    return {}


def pod_specs(docs):
    found = [(f"{d['kind']} {res_name(d)}", tpl(d)) for d in docs if d.get("kind") in POD_KINDS]
    found += [(f"Pod {res_name(d)}", dig(d, "spec", default={})) for d in docs if d.get("kind") == "Pod"]
    return found


def containers(pod):
    return [c for c in pod.get("containers") or [] if isinstance(c, dict)]


def mounts(pod):
    return {m["mountPath"]: m for c in containers(pod) for m in c.get("volumeMounts") or [] if "mountPath" in m}


def volumes(pod):
    return {v["name"]: v for v in pod.get("volumes") or [] if "name" in v}


def scan(node, keys, truthy=False):
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key in keys and (not truthy or value):
                found.append(f"{key}={value!r}")
            found += scan(value, keys, truthy)
    elif isinstance(node, list):
        for value in node:
            found += scan(value, keys, truthy)
    return sorted(found)


def check_namespaces(report, docs):
    report.absent(
        f"1 every non-Namespace document is in {NS}",
        [f"{d.get('kind')} {res_name(d)}" for d in docs if d.get("kind") != "Namespace" and dig(d, "metadata", "namespace") != NS],
    )
    found = kinds(docs, "Namespace", NS)
    if not report.only(f"1 Namespace {NS}", found):
        return
    for level in ("enforce", "audit", "warn"):
        label = dig(found[0], "metadata", "labels", f"pod-security.kubernetes.io/{level}")
        report.equal(f"1 Namespace {NS} pod-security {level}", label, "restricted")


def check_exposure(report, docs):
    report.absent("2 no Ingress exposes the app", [res_name(d) for d in kinds(docs, "Ingress")])
    for service in kinds(docs, "Service"):
        report.equal(f"2 Service {res_name(service)} is ClusterIP", dig(service, "spec", "type", default="ClusterIP"), "ClusterIP")
    for label, pod in pod_specs(docs):
        report.absent(f"2 {label} uses no host namespace, port or path", scan(pod, HOST_KEYS))
        report.absent(f"2 {label} containers are not privileged", scan(pod, ("privileged",), True))


def check_images(report, docs):
    for label, pod in pod_specs(docs):
        for container in containers(pod):
            image = str(container.get("image") or "")
            report.check(
                f"3 {label} container {container.get('name')} image is pinned by digest",
                bool(DIGEST.search(image)), f"image is {image!r}",
            )
    if os.environ.get(GATE) != "1":
        return
    app = kinds(docs, "Deployment", APP_NAME)
    placeholders = [c.get("name") for c in containers(tpl(app[0])) if ZEROS in str(c.get("image") or "")] if app else [APP_NAME]
    report.check(f"3 {GATE}=1 rejects placeholder image digests", not placeholders,
                 f"deployment.yaml still pins @sha256:{ZEROS} on {placeholders}; publish a real digest first")


def check_app(report, docs):
    found = kinds(docs, "Deployment", APP_NAME)
    if not report.only(f"4 app Deployment {APP_NAME}", found):
        return
    report.equal("4 app replicas is 1", dig(found[0], "spec", "replicas"), 1)
    report.equal("4 app strategy is Recreate", dig(found[0], "spec", "strategy", "type"), "Recreate")
    pod, vol_map, mount_map = tpl(found[0]), volumes(tpl(found[0])), mounts(tpl(found[0]))
    claims = [dig(vol_map.get(mount_map.get(p, {}).get("name"), {}), "persistentVolumeClaim", "claimName")
              for p in mount_map if p == RUNTIME_MOUNT]
    if not report.equal(f"4 one volume is mounted at {RUNTIME_MOUNT}", len(claims), 1):
        return
    declared = {res_name(d) for d in kinds(docs, "PersistentVolumeClaim")}
    report.check(
        f"4 the volume at {RUNTIME_MOUNT} is a PVC declared in this overlay", claims[0] in declared,
        f"claimName is {claims[0]!r}, declared claims are {sorted(declared)!r}",
    )
    labels = dig(found[0], "spec", "template", "metadata", "labels", default={})
    selected = [s for s in kinds(docs, "Service") if dig(s, "spec", "selector", default={}).items() <= labels.items()]
    if not report.only("4 one Service selects the app pods", selected):
        return
    report.equal(f"4 Service {res_name(selected[0])} is ClusterIP", dig(selected[0], "spec", "type"), "ClusterIP")
    ports = [dig(p, "port") for p in dig(selected[0], "spec", "ports", default=[]) or []]
    report.check(f"4 Service {res_name(selected[0])} serves 8080", 8080 in ports, f"ports are {ports!r}")
    configmaps = [res_name(d) for d in kinds(docs, "ConfigMap") if dig(d, "data", "CHEM_PUBLIC_BASE_URL") == PUBLIC_BASE_URL]
    if not report.only("4 one ConfigMap sets CHEM_PUBLIC_BASE_URL", configmaps):
        return
    refs = [dig(s, "configMapRef", "name") for s in pod.get("envFrom") or [] if isinstance(s, dict)]
    report.check(
        f"4 the app pod loads ConfigMap {configmaps[0]} through envFrom", configmaps[0] in refs,
        f"envFrom configMapRefs are {refs!r}",
    )


def check_pod_security(report, docs):
    for doc in kinds(docs, "Deployment"):
        label, pod = f"Deployment {res_name(doc)}", tpl(doc)
        for field, expected in POD_SECURITY:
            report.equal(f"5 {label} pod {field}", dig(pod, *field.split(".")), expected)
        for container in containers(pod):
            who = f"{label} container {container.get('name')}"
            for field, expected in CONTAINER_SECURITY:
                report.equal(f"5 {who} {field}", dig(container, *field.split(".")), expected)


def check_secrets(report, docs, text):
    report.absent("6 no kind Secret is committed", [res_name(d) for d in kinds(docs, "Secret")])
    report.absent("6 no credential literal in the rendered manifests", CREDENTIAL.findall(text))
    found = kinds(docs, "ExternalSecret", REGISTRY_SECRET)
    if not report.only(f"6 ExternalSecret {REGISTRY_SECRET}", found):
        return
    template = dig(found[0], "spec", "target", "template", default={})
    report.equal(f"6 {REGISTRY_SECRET} writes a dockerconfigjson", template.get("type"), "kubernetes.io/dockerconfigjson")
    blob = str(dig(template, "data", ".dockerconfigjson", default=""))
    for placeholder in ("{{ .github_username }}", "{{ .github_token }}"):
        report.check(f"6 {REGISTRY_SECRET} keeps the {placeholder} placeholder", placeholder in blob, f"template is {blob!r}")
    target = dig(found[0], "spec", "target", "name")
    app = kinds(docs, "Deployment", APP_NAME)
    pulls = [dig(ref, "name") for ref in dig(tpl(app[0]), "imagePullSecrets", default=[]) if isinstance(ref, dict)] if app else []
    report.check(f"6 the app pod pulls with the {REGISTRY_SECRET} target", pulls == [target],
                 f"imagePullSecrets are {pulls!r} and the ExternalSecret target is {target!r}")


def check_secret_store(report, docs):
    found = kinds(docs, "SecretStore", VAULT_STORE)
    if not report.only(f"7 SecretStore {VAULT_STORE}", found):
        return
    provider = dig(found[0], "spec", "provider", "vault", default={})
    for field, expected in VAULT_FIELDS:
        report.equal(f"7 SecretStore {field}", provider.get(field), expected)
    auth = provider.get("auth", {}).get("kubernetes") or {}
    report.equal("7 SecretStore role", auth.get("role"), "chem-archive-role")
    report.equal("7 SecretStore service account", dig(auth, "serviceAccountRef", "name"), "chem-archive-sa")
    for target, key, prop in REMOTE_MAPPINGS:
        externals = kinds(docs, "ExternalSecret", target)
        if not report.only(f"7 ExternalSecret {target}", externals):
            continue
        mapping = {d.get("secretKey"): d.get("remoteRef") for d in dig(externals[0], "spec", "data", default=[]) or []}
        report.equal(
            f"7 {target} reads {VAULT_KEY}/{prop} into {key}", mapping.get(key), {"key": VAULT_KEY, "property": prop}
        )


def check_cloudflared(report, docs):
    found = kinds(docs, "Deployment", TUNNEL_NAME)
    if not report.only(f"8 tunnel Deployment {TUNNEL_NAME}", found):
        return
    pod = tpl(found[0])
    running = containers(pod)
    if not report.equal("8 the tunnel pod runs exactly one container", len(running), 1):
        return
    container, args = running[0], [str(arg) for arg in running[0].get("args") or []]
    report.check(f"8 cloudflared reads its token from {TOKEN_FILE} with --token-file",
                 "--token-file" in args and TOKEN_FILE in args, f"args are {args!r}")
    report.absent("8 no connector token literal in the cloudflared args", [a for a in args if CREDENTIAL.search(a)])
    after = args.index("--metrics") + 1 if "--metrics" in args else 0
    report.equal("8 cloudflared metrics stay on pod loopback", args[after] if 0 < after < len(args) else None, "127.0.0.1:0")
    report.absent("8 cloudflared declares no container ports", container.get("ports"))
    mount = mounts(pod).get(TOKEN_DIR)
    if not report.check(
        f"8 the tunnel token is mounted read-only at {TOKEN_DIR}",
        isinstance(mount, dict) and mount.get("readOnly") is True, f"volumeMounts are {container.get('volumeMounts')!r}",
    ):
        return
    volume = volumes(pod).get(mount.get("name"), {})
    report.check(
        f"8 the token volume is the projected secret {TUNNEL_SECRET}", dig(volume, "secret", "secretName") == TUNNEL_SECRET,
        f"volume {mount.get('name')!r} is {volume!r}",
    )
    report.check(
        "8 the tunnel secret volume is mode 0440", dig(volume, "secret", "defaultMode") in (0o440, "0440"),
        f"defaultMode is {dig(volume, 'secret', 'defaultMode')!r}",
    )


def check_flux_tree(report):
    try:
        document = yaml.safe_load(ROOT_KUSTOMIZATION.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        report.check("9 root kustomization is readable YAML", False, str(exc))
    else:
        resources = (document or {}).get("resources") or []
        report.check("9 root kustomization includes ./chem-archive", "./chem-archive" in resources, f"resources are {resources!r}")
    for path in (APPS, FLUX):
        docs, _, error = render(path)
        report.check(f"9 render {path}", error is None, error or "")
        if path != FLUX or error is not None:
            continue
        for kind, name in (("Namespace", NS), ("Deployment", APP_NAME)):
            report.check(f"9 the Flux tree carries {kind} {name}", bool(kinds(docs, kind, name)), "not in the rendered Flux tree")


def main():
    report = Report()
    docs, text, error = render(APP)
    if error is not None:
        report.check(f"render {APP}", False, error)
        report.emit()
        return 1
    report.check(f"render {APP}", True)
    for group in (check_namespaces, check_exposure, check_images, check_app, check_pod_security, check_cloudflared):
        group(report, docs)
    check_secrets(report, docs, text)
    check_secret_store(report, docs)
    check_flux_tree(report)
    report.emit()
    return 1 if report.failures else 0


if __name__ == "__main__":
    sys.exit(main())
