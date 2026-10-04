#!/usr/bin/env bash
# ============================================================================
# One-shot deployer for the Dify Postgres HA cluster.
#
# Creates the three secrets from environment variables (so no credential ever
# lands in git), substitutes the CHANGE_ME_* tokens in cluster.yaml, then
# applies everything.
#
# Required env:
#   PG_SUPERUSER_PASSWORD   superuser "postgres" password
#   PG_APP_PASSWORD         password for the "dify" application role
#   S3_BUCKET               backup bucket name
#   S3_ACCESS_KEY           S3-compatible access key
#   S3_SECRET_KEY           S3-compatible secret key
#
# Optional env:
#   S3_ENDPOINT             https endpoint for MinIO / OSS / COS; empty for AWS
#   S3_REGION               AWS region (ignored by non-AWS endpoints)
#   STORAGE_CLASS           StorageClass name; defaults to dify-local-path
#                           (created from storage.yaml). Set to "" to use the
#                           cluster default class, or to an existing one.
#   NS                      target namespace (default: dify)
#
# Example:
#   PG_SUPERUSER_PASSWORD=... PG_APP_PASSWORD=... \
#   S3_BUCKET=dify-pg-backup S3_ACCESS_KEY=... S3_SECRET_KEY=... \
#   S3_ENDPOINT=https://oss-cn-hangzhou.aliyuncs.com \
#   STORAGE_CLASS=local-path ./apply.sh
#
# Idempotent: re-running updates secrets in place and re-applies the cluster.
# ============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

: "${PG_SUPERUSER_PASSWORD:?PG_SUPERUSER_PASSWORD is required}"
: "${PG_APP_PASSWORD:?PG_APP_PASSWORD is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY is required}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY is required}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-}"
STORAGE_CLASS="${STORAGE_CLASS-dify-local-path}"
NS="${NS:-dify}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

# Only create our StorageClass when we are the ones going to use it, so a
# cluster that already has a real one is never polluted with a duplicate.
if [ "$STORAGE_CLASS" = "dify-local-path" ]; then
  echo "==> applying StorageClass ${STORAGE_CLASS}"
  kubectl apply -f "$DIR/storage.yaml"
else
  echo "==> using existing StorageClass ${STORAGE_CLASS:-<cluster default>}"
fi

echo "==> creating secrets in namespace ${NS}"
kubectl -n "$NS" create secret generic dify-postgres-superuser \
  --from-literal=username=postgres \
  --from-literal=password="$PG_SUPERUSER_PASSWORD" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f -

kubectl -n "$NS" create secret generic dify-postgres-app \
  --from-literal=username=dify \
  --from-literal=password="$PG_APP_PASSWORD" \
  --from-literal=dbname=dify \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f -

kubectl -n "$NS" create secret generic dify-postgres-backup \
  --from-literal=accessKeyId="$S3_ACCESS_KEY" \
  --from-literal=secretAccessKey="$S3_SECRET_KEY" \
  --from-literal=AWS_REGION="$S3_REGION" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f -

echo "==> rendering manifests for namespace ${NS}"
rendered="$(mktemp -d)"
# Rendered with python3 rather than sed -i: one implementation for macOS and
# Linux, and no chance of mangling YAML.
#
# Two substitutions happen here, and both are load-bearing:
#   - the namespace, because every manifest in this repo pins `namespace: dify`
#     while the scripts advertise an NS variable. Without this, NS=staging
#     would silently deploy everything into dify anyway.
#   - the CHANGE_ME_* tokens, so no credential or environment-specific value
#     is ever committed.
export NS
NS="$NS" BUCKET="$S3_BUCKET" ENDPOINT="$S3_ENDPOINT" STORAGE_CLASS="$STORAGE_CLASS" \
SRC_DIR="$DIR" DST_DIR="$rendered" \
python3 - <<'PY'
import os, re, pathlib

src, dst = pathlib.Path(os.environ["SRC_DIR"]), pathlib.Path(os.environ["DST_DIR"])
ns = os.environ["NS"]
storage_class = os.environ.get("STORAGE_CLASS", "").strip()
# kustomization.yaml is a kustomize index, not a resource: kubectl apply
# rejects it. storage.yaml is handled separately below, because this script
# only creates that StorageClass when it is the one actually in use.
SKIP_APPLY = {"kustomization.yaml", "storage.yaml"}
out = []

for f in sorted(src.glob("*.yaml")):
    if f.name in SKIP_APPLY or re.search(r"^kind:\s*Kustomization\s*$", f.read_text(), re.M):
        continue
    text = f.read_text()
    text = re.sub(r"^(\s*namespace:\s*)\S+", rf"\g<1>{ns}", text, flags=re.M)

    # A caller who explicitly clears STORAGE_CLASS wants the cluster default,
    # so the key has to disappear rather than be set to "".
    if not storage_class:
        text = re.sub(r"^\s*storageClass(?:Name)?:\s*CHANGE_ME_STORAGE_CLASS\s*\n",
                      "", text, flags=re.M)

    for key, val in os.environ.items():
        if key.startswith("CHANGE_ME_") or key in ("SRC_DIR", "DST_DIR"):
            continue
        text = text.replace(f"CHANGE_ME_{key}", val)

    left = sorted(set(re.findall(r"CHANGE_ME_[A-Z_]+", text)))
    if left:
        raise SystemExit(f"ERROR: unsubstituted placeholders in {f.name}: {left}")

    (dst / f.name).write_text(text)
    out.append(f.name)

print("  rendered: " + ", ".join(out))
PY

echo "==> applying rendered manifests"
for f in "$rendered"/*.yaml; do kubectl -n "$NS" apply -f "$f"; done

cat <<EOF

Next:
  kubectl -n ${NS} get cluster dify-postgres -w
    -> wait for 3/3 instances Running with exactly one primary,
       then run migrate.sh and flip dify-shared-config (see README.md).
EOF
