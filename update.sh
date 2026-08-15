#!/usr/bin/env bash
# Safely update Nextcloud + MariaDB + Collabora (+ Redis if present) on Kubernetes.
# Creates a local rollback backup first, then asks whether to keep it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/lib.sh"

ask_backup_retention() {
  local dir="$1"
  if [[ ! -d "${dir}" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "No interactive terminal — keeping backup at ${dir}"
    return 0
  fi
  echo
  local reply=""
  read -r -p "Update succeeded. Keep rollback backup at ${dir}? [Y/n] " reply || true
  case "${reply:-Y}" in
    n|N|no|NO)
      rm -rf "${dir}"
      rmdir "${ROOT}/backups" 2>/dev/null || true
      echo "Backup deleted."
      ;;
    *)
      echo "Backup kept."
      echo "  See ${dir}/RESTORE.txt if you need to roll back."
      ;;
  esac
}

create_backup() {
  BACKUP_DIR="${ROOT}/backups/update-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  echo "==> Creating rollback backup in ${BACKUP_DIR} ..."
  cp -a "${ROOT}/deploy.yaml" "${BACKUP_DIR}/" 2>/dev/null || true
  [[ -f "${ROOT}/deploy-redis.yaml" ]] && cp -a "${ROOT}/deploy-redis.yaml" "${BACKUP_DIR}/"
  kubectl -n "$NS" get secret nextcloud-db -o yaml >"${BACKUP_DIR}/secret-nextcloud-db.yaml" 2>/dev/null || true
  kubectl -n "$NS" get deploy,svc,pvc -o yaml >"${BACKUP_DIR}/resources.yaml" 2>/dev/null || true

  local dbpod ncpod
  dbpod="$(kubectl -n "$NS" get pod -l app=db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  ncpod="$(nextcloud_pod 2>/dev/null || true)"

  if [[ -n "${dbpod}" ]]; then
    echo "    Dumping MariaDB from ${dbpod} ..."
    local db user pass
    db="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_DATABASE}' | base64 -d)"
    user="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_USER}' | base64 -d)"
    pass="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)"
    kubectl -n "$NS" exec "${dbpod}" -- \
      mariadb-dump -u"${user}" -p"${pass}" --single-transaction --routines "${db}" \
      >"${BACKUP_DIR}/nextcloud-db.sql" \
      || echo "    Warning: MariaDB dump failed"
  fi

  if [[ -n "${ncpod}" ]]; then
    echo "    Archiving /var/www/html from ${ncpod} (may take a while)..."
    kubectl -n "$NS" exec "${ncpod}" -- tar -C /var/www/html -czf - . >"${BACKUP_DIR}/html.tar.gz" \
      || echo "    Warning: could not archive Nextcloud files"
  fi

  cat >"${BACKUP_DIR}/RESTORE.txt" <<EOF
Nextcloud k8s rollback (summary):

  kubectl -n nextcloud apply -f ${BACKUP_DIR}/secret-nextcloud-db.yaml

  # Restore DB (with db pod running):
  DBPOD=\$(kubectl -n nextcloud get pod -l app=db -o jsonpath='{.items[0].metadata.name}')
  kubectl -n nextcloud exec -i "\$DBPOD" -- mariadb -unextcloud -p"\$MYSQL_PASSWORD" nextcloud \\
    < ${BACKUP_DIR}/nextcloud-db.sql

  # Restore files:
  NCPOD=\$(kubectl -n nextcloud get pod -l app=nextcloud -o jsonpath='{.items[0].metadata.name}')
  kubectl -n nextcloud exec -i "\$NCPOD" -- tar -C /var/www/html -xzf - < ${BACKUP_DIR}/html.tar.gz
  kubectl -n nextcloud rollout restart deployment/nextcloud deployment/db
EOF
  echo "Backup ready: ${BACKUP_DIR}"
}

need kubectl
require_longhorn

if ! kubectl -n "$NS" get deploy nextcloud >/dev/null 2>&1; then
  echo "Nextcloud is not installed yet. Run ./install.sh first." >&2
  exit 1
fi

refuse_legacy_nextcloud_cluster
create_backup

echo "==> Applying core manifests..."
kubectl apply -f "${ROOT}/deploy.yaml"

if redis_deployed; then
  echo "==> Redis is present — re-applying deploy-redis.yaml..."
  kubectl apply -f "${ROOT}/deploy-redis.yaml"
fi

echo "==> Rolling out Deployments (picks up newer :latest digests)..."
kubectl -n "$NS" rollout restart deployment/db deployment/nextcloud deployment/collabora
if redis_deployed; then
  kubectl -n "$NS" rollout restart deployment/redis
fi

kubectl -n "$NS" rollout status deployment/db --timeout=300s
kubectl -n "$NS" rollout status deployment/nextcloud --timeout=300s
kubectl -n "$NS" rollout status deployment/collabora --timeout=600s
if redis_deployed; then
  kubectl -n "$NS" rollout status deployment/redis --timeout=180s
fi

echo "==> Pruning unused images on this machine (dangling/unused only)..."
if command -v k3s >/dev/null 2>&1; then
  sudo k3s crictl rmi --prune 2>/dev/null || echo "(skipped k3s prune — need sudo or crictl)"
elif command -v docker >/dev/null 2>&1; then
  docker image prune -f
fi

echo
echo "Update finished. PVCs and Secret nextcloud-db were left untouched."
echo "Optional checks:"
echo "  ./verify-office.sh"
echo "  ./configure-office.sh   # only if Office URLs/IPs changed"
ask_backup_retention "${BACKUP_DIR}"
