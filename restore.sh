#!/usr/bin/env bash
# Restore Nextcloud k8s (files + MariaDB dump) from a backups/update-* snapshot.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/lib.sh"
cd "$ROOT"

need kubectl

if [[ ! -d backups ]]; then
  echo "No backups/ directory found. Run ./update.sh at least once first." >&2
  exit 1
fi

mapfile -t DIRS < <(ls -1dt backups/update-* 2>/dev/null || true)
if ((${#DIRS[@]} == 0)); then
  echo "No backups/update-* snapshots found." >&2
  exit 1
fi

echo "Available backups (newest first):"
i=1
for d in "${DIRS[@]}"; do
  size="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
  extras=""
  [[ -f "$d/html.tar.gz" ]] && extras+=" html"
  [[ -f "$d/nextcloud-db.sql" ]] && extras+=" sql"
  echo "  ${i}) ${d}  (${size}${extras})"
  i=$((i + 1))
done

choice=""
if [[ -t 0 ]]; then
  read -r -p "Restore which backup number? [1] " choice || true
else
  echo "Non-interactive: use ./restore.sh with a TTY to choose a backup." >&2
  exit 1
fi
choice="${choice:-1}"
if ! [[ "${choice}" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#DIRS[@]} )); then
  echo "Invalid selection." >&2
  exit 1
fi
SRC="${DIRS[$((choice - 1))]}"

if [[ ! -f "${SRC}/html.tar.gz" && ! -f "${SRC}/nextcloud-db.sql" ]]; then
  echo "Backup ${SRC} has neither html.tar.gz nor nextcloud-db.sql" >&2
  exit 1
fi

echo
echo "This will REPLACE Nextcloud files and/or DB from ${SRC}."
read -r -p "Type 'restore' to continue: " confirm || true
if [[ "${confirm}" != "restore" ]]; then
  echo "Aborted."
  exit 1
fi

if [[ -f "${SRC}/secret-nextcloud-db.yaml" ]]; then
  echo "==> Restoring DB Secret..."
  kubectl -n "$NS" apply -f "${SRC}/secret-nextcloud-db.yaml"
fi

dbpod="$(kubectl -n "$NS" get pod -l app=db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
ncpod="$(nextcloud_pod 2>/dev/null || true)"

if [[ -f "${SRC}/nextcloud-db.sql" ]]; then
  if [[ -z "${dbpod}" ]]; then
    echo "No DB pod running — cannot import SQL." >&2
    exit 1
  fi
  echo "==> Importing SQL into ${dbpod} ..."
  db="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_DATABASE}' | base64 -d)"
  user="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_USER}' | base64 -d)"
  pass="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)"
  kubectl -n "$NS" exec -i "${dbpod}" -- \
    mariadb -u"${user}" -p"${pass}" "${db}" \
    <"${SRC}/nextcloud-db.sql"
fi

if [[ -f "${SRC}/html.tar.gz" ]]; then
  if [[ -z "${ncpod}" ]]; then
    echo "No Nextcloud pod running — cannot restore files." >&2
    exit 1
  fi
  echo "==> Restoring /var/www/html into ${ncpod} (may take a while)..."
  kubectl -n "$NS" exec "${ncpod}" -- sh -c \
    'rm -rf /var/www/html/* /var/www/html/.[!.]* /var/www/html/..?* 2>/dev/null || true'
  kubectl -n "$NS" exec -i "${ncpod}" -- tar -C /var/www/html -xzf - <"${SRC}/html.tar.gz"
fi

echo "==> Restarting deployments..."
kubectl -n "$NS" rollout restart deployment/db deployment/nextcloud
kubectl -n "$NS" rollout status deployment/db --timeout=300s
kubectl -n "$NS" rollout status deployment/nextcloud --timeout=300s
echo
echo "Restore finished from ${SRC}."
echo "Optional: ./verify-office.sh"
