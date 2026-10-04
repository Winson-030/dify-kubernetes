#!/usr/bin/env bash
# ============================================================================
# Cutover helper: copy both Dify databases from the legacy single-replica
# StatefulSet (dify-postgres, hostPath) into the CloudNativePG cluster
# (dify-postgres), then verify.
#
# Usage:  ./migrate.sh <backup-dir>
#
# Assumes:
#   - the CNPG cluster is already running and healthy
#   - kubectl context points at the target cluster
#   - you run the "freeze" step from README.md first (scale api/worker to 0)
# ============================================================================
set -euo pipefail

BACKUP_DIR="${1:-./pgdump}"
NS=dify
LEGACY_POD="${LEGACY_POD:-dify-postgres-0}"
LEGACY_DB="${LEGACY_DB:-dify}"
PLUGIN_DB="${PLUGIN_DB:-dify_plugin}"
APP_ROLE="${APP_ROLE:-dify}"

# Pod that currently holds the primary on the CNPG cluster.
primary_pod() {
  kubectl -n "$NS" get pod -l cnpg.io/cluster=dify-postgres,cnpg.io/role=primary \
    -o jsonpath='{.items[0].metadata.name}'
}

dump() {
  local db="$1" file="$2"
  echo "==> dumping ${db} from ${LEGACY_POD}"
  kubectl -n "$NS" exec "$LEGACY_POD" -- \
    pg_dump -U postgres -Fc --no-owner --no-acl "$db" > "${BACKUP_DIR}/${file}"
  ls -lh "${BACKUP_DIR}/${file}"
}

restore() {
  local primary="$1" db="$2" file="$3"
  echo "==> restoring ${file} into ${db} on ${primary}"
  # Restore as the app role so every object is owned by it and Dify's own
  # migrations (flask db upgrade / plugin-daemon) keep working without
  # superuser access. CREATE DATABASE is done as superuser beforehand.
  kubectl -n "$NS" exec -i "$primary" -- \
    psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS ${db};" \
                              -c "CREATE DATABASE ${db} OWNER ${APP_ROLE};"
  kubectl -n "$NS" exec -i "$primary" -- \
    psql -U postgres -d postgres -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='${APP_ROLE}';" | grep -q 1 \
    || kubectl -n "$NS" exec -i "$primary" -- psql -U postgres -d postgres \
         -c "CREATE ROLE ${APP_ROLE} LOGIN PASSWORD '${APP_ROLE}';"
  kubectl -n "$NS" exec -i "$primary" -- \
    pg_restore -U postgres -d "$db" --no-owner --role "${APP_ROLE}" \
      --exit-on-error < "${BACKUP_DIR}/${file}"
}

verify() {
  local primary="$1" db="$2"
  echo "==> verifying ${db}"
  kubectl -n "$NS" exec -i "$primary" -- psql -U postgres -d "$db" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
  # Dify writes nothing useful into these on a fresh DB, so a non-zero row
  # count here is the cheapest proof that data actually moved.
  kubectl -n "$NS" exec -i "$primary" -- psql -U postgres -d "$db" -tAc \
    "SELECT 'accounts=' || count(*) FROM accounts;" || true
}

mkdir -p "$BACKUP_DIR"
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }

primary="$(primary_pod)"
[ -n "$primary" ] || { echo "no primary pod found; is the cluster healthy?"; exit 1; }
echo "primary: $primary"

dump "$LEGACY_DB" "${LEGACY_DB}.dump"
dump "$PLUGIN_DB" "${PLUGIN_DB}.dump"

restore "$primary" "$LEGACY_DB" "${LEGACY_DB}.dump"
restore "$primary" "$PLUGIN_DB" "${PLUGIN_DB}.dump"

verify "$primary" "$LEGACY_DB"
verify "$primary" "$PLUGIN_DB"

echo
echo "DONE. Next: flip dify-shared-config to the new endpoint, then scale"
echo "dify-api / dify-worker back up (see README.md)."
