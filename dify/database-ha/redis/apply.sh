#!/usr/bin/env bash
# ============================================================================
# Deployer for the Redis HA StatefulSet (3 nodes + 3 Sentinels).
#
# The password comes from the environment so it never lands in git, and the
# StorageClass is substituted into the StatefulSet, mirroring the CNPG setup in
# ../cnpg/apply.sh.
#
# Required env:
#   REDIS_PASSWORD   password for the redis instances AND the sentinels
#
# Optional env:
#   STORAGE_CLASS    StorageClass for the data volumes
#                     (default: dify-local-path from ../cnpg/storage.yaml)
#   NS               target namespace (default: dify)
#
# Example:
#   REDIS_PASSWORD='...' ./apply.sh
#
# Idempotent: safe to re-run.
# ============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

: "${REDIS_PASSWORD:?REDIS_PASSWORD is required}"
STORAGE_CLASS="${STORAGE_CLASS:-dify-local-path}"
NS="${NS:-dify}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

echo "==> creating secret dify-redis-credentials in namespace ${NS}"
kubectl -n "$NS" create secret generic dify-redis-credentials \
  --from-literal=redis-password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f -

echo "==> rendering manifests for namespace ${NS}"
rendered="$(mktemp -d)"
# Rendered with python3 rather than sed -i: one implementation for macOS and
# Linux, and no chance of mangling YAML.
#
# The namespace is rewritten too, not just the StorageClass: the manifests pin
# `namespace: dify`, so without this NS=staging would deploy into dify anyway.
export NS
NS="$NS" STORAGE_CLASS="$STORAGE_CLASS" SRC_DIR="$DIR" DST_DIR="$rendered" \
python3 - <<'PY'
import os, re, pathlib

src, dst = pathlib.Path(os.environ["SRC_DIR"]), pathlib.Path(os.environ["DST_DIR"])
ns = os.environ["NS"]
storage_class = os.environ.get("STORAGE_CLASS", "").strip()
# kustomization.yaml is a kustomize index, not a resource: kubectl apply
# rejects it. Kept identical to ../cnpg/apply.sh so there is one implementation.
SKIP_APPLY = {"kustomization.yaml", "storage.yaml"}
out = []

for f in sorted(src.glob("*.yaml")):
    if f.name in SKIP_APPLY or re.search(r"^kind:\s*Kustomization\s*$", f.read_text(), re.M):
        continue
    text = f.read_text()
    text = re.sub(r"^(\s*namespace:\s*)\S+", rf"\g<1>{ns}", text, flags=re.M)

    # An explicitly cleared STORAGE_CLASS means "use the cluster default", so
    # the key has to disappear rather than be set to "".
    if not storage_class:
        text = re.sub(r"^\s*storageClass(?:Name)?:\s*CHANGE_ME_STORAGE_CLASS\s*\n",
                      "", text, flags=re.M)

    for key, val in os.environ.items():
        if key in ("SRC_DIR", "DST_DIR"):
            continue
        text = text.replace(f"CHANGE_ME_{key}", val)

    left = sorted(set(re.findall(r"CHANGE_ME_[A-Z_]+", text)))
    if left:
        raise SystemExit(f"ERROR: unsubstituted placeholders in {f.name}: {left}")

    (dst / f.name).write_text(text)
    out.append(f.name)

print("  rendered: " + ", ".join(out))
PY

echo "==> applying services, configmap, statefulset"
for f in "$rendered"/*.yaml; do kubectl -n "$NS" apply -f "$f"; done

cat <<EOF

Next:
  kubectl -n ${NS} rollout status statefulset/dify-redis-ha --timeout=300s

  Confirm exactly one master:
  kubectl -n ${NS} exec dify-redis-ha-0 -c redis -- \\
    redis-cli SENTINEL get-master-addr-by-name dify-redis-master

  Then flip the app config (see README.md step 3) and drain the old redis.
EOF
