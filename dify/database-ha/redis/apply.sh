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
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> rendering statefulset.yaml"
rendered="$(mktemp -d)/statefulset.yaml"
STORAGE_CLASS="$STORAGE_CLASS" SRC="$DIR/statefulset.yaml" DST="$rendered" \
python3 - <<'PY'
import os, re
src, dst = os.environ["SRC"], os.environ["DST"]
text = open(src).read()
class_name = os.environ.get("STORAGE_CLASS", "").strip()
if class_name:
    text = text.replace("CHANGE_ME_STORAGE_CLASS", class_name)
else:
    # No explicit class: drop the key so the cluster default applies.
    text = re.sub(r"^\s*storageClassName: CHANGE_ME_STORAGE_CLASS\n", "", text, flags=re.M)
if "CHANGE_ME_STORAGE_CLASS" in text:
    raise SystemExit("ERROR: unsubstituted placeholder remains")
open(dst, "w").write(text)
PY

echo "==> applying services, configmap, statefulset"
kubectl apply -f "$DIR/services.yaml"
kubectl apply -f "$DIR/configmap.yaml"
kubectl apply -f "$rendered"

cat <<EOF

Next:
  kubectl -n ${NS} rollout status statefulset/dify-redis-ha --timeout=300s

  Confirm exactly one master:
  kubectl -n ${NS} exec dify-redis-ha-0 -c redis -- \\
    redis-cli SENTINEL get-master-addr-by-name dify-redis-master

  Then flip the app config (see README.md step 3) and drain the old redis.
EOF
