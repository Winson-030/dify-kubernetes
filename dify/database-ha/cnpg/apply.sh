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
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic dify-postgres-app \
  --from-literal=username=dify \
  --from-literal=password="$PG_APP_PASSWORD" \
  --from-literal=dbname=dify \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic dify-postgres-backup \
  --from-literal=accessKeyId="$S3_ACCESS_KEY" \
  --from-literal=secretAccessKey="$S3_SECRET_KEY" \
  --from-literal=AWS_REGION="$S3_REGION" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> rendering cluster.yaml"
rendered="$(mktemp -d)/cluster.yaml"
# Rendered with python3 rather than sed -i: one implementation for macOS and
# Linux, and no chance of mangling YAML.
STORAGE_CLASS="$STORAGE_CLASS" S3_BUCKET="$S3_BUCKET" \
S3_ENDPOINT="$S3_ENDPOINT" SRC="$DIR/cluster.yaml" DST="$rendered" \
python3 - <<'PY'
import os, re
src, dst = os.environ["SRC"], os.environ["DST"]
text = open(src).read()
text = text.replace("CHANGE_ME_BUCKET", os.environ["S3_BUCKET"])
text = text.replace("CHANGE_ME_ENDPOINT", os.environ["S3_ENDPOINT"])
class_name = os.environ.get("STORAGE_CLASS", "").strip()
if class_name:
    text = text.replace("CHANGE_ME_STORAGE_CLASS", class_name)
else:
    # No explicit class: drop the key so the cluster default StorageClass wins.
    text = re.sub(r"^\s*storageClass: CHANGE_ME_STORAGE_CLASS\n", "", text, flags=re.M)
left = re.findall(r"CHANGE_ME_(?:BUCKET|ENDPOINT|STORAGE_CLASS)", text)
if left:
    raise SystemExit(f"ERROR: unsubstituted placeholders remain: {sorted(set(left))}")
open(dst, "w").write(text)
PY

echo "==> applying cluster"
kubectl apply -f "$rendered"

echo "==> applying pooler and scheduled backups"
kubectl apply -f "$DIR/pooler.yaml"
kubectl apply -f "$DIR/backup.yaml"

cat <<EOF

Next:
  kubectl -n ${NS} get cluster dify-postgres -w
    -> wait for 3/3 instances Running with exactly one primary,
       then run migrate.sh and flip dify-shared-config (see README.md).
EOF
