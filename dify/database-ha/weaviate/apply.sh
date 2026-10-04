#!/usr/bin/env bash
# ============================================================================
# Phase 1 of the vector-DB work: give Weaviate an S3 backup.
#
# No version bump, no re-embedding, no data migration. This only makes the
# existing data recoverable, which today it is not at all.
#
# Required env:
#   S3_BUCKET         bucket for the backups (may be shared with the CNPG
#                     backups; weaviate/ is used as its own prefix)
#   S3_ACCESS_KEY     credentials with write access to that prefix
#   S3_SECRET_KEY
#   WEAVIATE_API_KEY  the key Weaviate already accepts. MUST match what
#                     dify-api / dify-worker present, or those break.
#
# Optional env:
#   S3_ENDPOINT       leave empty for AWS S3; set for MinIO etc.
#   S3_REGION         (default: us-east-1)
#   S3_PATH           prefix inside the bucket (default: weaviate/)
#   S3_USE_SSL        true|false  (default: true; MinIO usually false)
#   SCHEDULE          cron schedule (default: "17 2 * * *")
#   NS                namespace (default: dify)
#
# Example:
#   S3_BUCKET=dify-backups S3_ACCESS_KEY=... S3_SECRET_KEY=... \
#   WEAVIATE_API_KEY=... ./apply.sh
#
# Idempotent.
# ============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY is required}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY is required}"
: "${WEAVIATE_API_KEY:?WEAVIATE_API_KEY is required}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_PATH="${S3_PATH:-weaviate/}"
S3_USE_SSL="${S3_USE_SSL:-true}"
SCHEDULE="${SCHEDULE:-17 2 * * *}"
NS="${NS:-dify}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

echo "==> creating secret dify-weaviate-backup in namespace ${NS}"
kubectl -n "$NS" create secret generic dify-weaviate-backup \
  --from-literal=s3-bucket="$S3_BUCKET" \
  --from-literal=s3-path="$S3_PATH" \
  --from-literal=s3-endpoint="$S3_ENDPOINT" \
  --from-literal=s3-use-ssl="$S3_USE_SSL" \
  --from-literal=aws-access-key-id="$S3_ACCESS_KEY" \
  --from-literal=aws-secret-access-key="$S3_SECRET_KEY" \
  --from-literal=aws-region="$S3_REGION" \
  --from-literal=weaviate-api-key="$WEAVIATE_API_KEY" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f -

echo "==> rendering manifests for namespace ${NS}"
rendered="$(mktemp -d)"
export NS
NS="$NS" SCHEDULE="$SCHEDULE" SRC_DIR="$DIR" DST_DIR="$rendered" \
python3 - <<'PY'
import os, re, pathlib

src, dst = pathlib.Path(os.environ["SRC_DIR"]), pathlib.Path(os.environ["DST_DIR"])
ns = os.environ["NS"]
out = []

for f in sorted(src.glob("*.yaml")):
    # Patches target an existing object; kubectl ignores the namespace inside
    # them, so rewriting it would be misleading noise. kustomization.yaml is a
    # kustomize index, not a resource: kubectl apply rejects it.
    if f.name.endswith("-patch.yaml") or f.name == "kustomization.yaml" \
       or re.search(r"^kind:\s*Kustomization\s*$", f.read_text(), re.M):
        continue
    text = f.read_text()
    text = re.sub(r"^(\s*namespace:\s*)\S+", rf"\g<1>{ns}", text, flags=re.M)

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

echo "==> applying cronjob (schedule: ${SCHEDULE})"
for f in "$rendered"/*.yaml; do kubectl -n "$NS" apply -f "$f"; done

# Secret first, patch second: the patched StatefulSet references the Secret, and
# a pod referencing a missing Secret key will not start.
echo "==> patching statefulset/dify-weaviate to enable the backup-s3 module"
kubectl -n "$NS" patch statefulset dify-weaviate \
  --patch-file "$DIR/weaviate-statefulset-patch.yaml"

echo "==> waiting for rollout"
kubectl -n "$NS" rollout status statefulset/dify-weaviate --timeout=300s

cat <<EOF

==> VERIFY BEFORE YOU TRUST THIS

  A wrong bucket or key does NOT stop Weaviate from starting — it only makes
  backups fail. So confirm one actually succeeded:

  kubectl -n ${NS} create job --from=cronjob/dify-weaviate-backup weaviate-backup-test
  kubectl -n ${NS} logs -f job/weaviate-backup-test

  Look for: "SUCCESS". If it says FAILED, the credentials or bucket are wrong.

  Then set an S3 lifecycle rule on the ${S3_BUCKET} bucket to expire the
  ${S3_PATH} prefix — Weaviate 1.19 has no delete endpoint, so retention is the
  bucket's job, not ours. See README.md step 5.
EOF
