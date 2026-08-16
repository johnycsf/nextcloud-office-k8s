#!/usr/bin/env bash
# Safely update Nextcloud + MariaDB + Collabora (+ Redis if present) on Kubernetes.
# Creates a local rollback backup first, then asks whether to keep it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deps.sh
source "${ROOT}/deps.sh"
# shellcheck source=lib.sh
source "${ROOT}/lib.sh"
cd "$ROOT"


KEEP_FILE=".backup-keep-count"
DEFAULT_KEEP=3
BACKUP_ROOT="${ROOT}/backups"

need() { command -v "$1" >/dev/null || { echo "Missing: $1" >&2; exit 1; }; }

print_offsite_tip() {
  cat <<'EOF'

Tip: Local backups under backups/ can fill your disk over time.
Copy important snapshots to an external drive, NAS, or cloud
(rclone, Backblaze B2, S3, Nextcloud, etc.), then keep fewer copies here.
Restore later with:
  ./backup.sh --restore --from ./backups
  ./backup.sh --restore --from /mnt/usb/my-backups
EOF
}

prune_old_backups() {
  local keep="$1"
  mkdir -p "${BACKUP_ROOT}/snapshots"
  mapfile -t dirs < <(ls -1dt "${BACKUP_ROOT}"/snapshots/* 2>/dev/null || true)
  # Also prune any leftover legacy update-* tarball folders from older scripts
  mapfile -t legacy < <(ls -1dt "${BACKUP_ROOT}"/update-* 2>/dev/null || true)
  local total="${#dirs[@]}"
  if (( total > keep )); then
    local i
    for (( i = keep; i < total; i++ )); do
      echo "Removing old snapshot: ${dirs[$i]}"
      rm -rf "${dirs[$i]}"
    done
    echo "Backup retention: kept ${keep} newest snapshot(s); removed $((total - keep)) older one(s)."
  else
    echo "Backup retention: keeping all ${total} snapshot(s) (limit ${keep})."
  fi
  if ((${#legacy[@]} > 0)); then
    echo "Note: found ${#legacy[@]} legacy backups/update-* folder(s)."
    echo "  Restore those manually via their RESTORE.txt, or delete them to free space."
  fi
  # Refresh latest symlink if needed
  if [[ -d "${BACKUP_ROOT}/snapshots" ]]; then
    local newest
    newest="$(ls -1dt "${BACKUP_ROOT}"/snapshots/* 2>/dev/null | head -1 || true)"
    if [[ -n "$newest" ]]; then
      ln -sfn "snapshots/$(basename "$newest")" "${BACKUP_ROOT}/latest"
    fi
  fi
}

ask_backup_retention() {
  local dir="$1"
  if [[ -z "${dir}" || ! -e "${dir}" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "No interactive terminal — keeping backup at ${dir}"
    local keep="${DEFAULT_KEEP}"
    [[ -f "${KEEP_FILE}" ]] && keep="$(tr -dc '0-9' <"${KEEP_FILE}" || true)"
    [[ -z "${keep}" ]] && keep="${DEFAULT_KEEP}"
    echo "${keep}" >"${KEEP_FILE}"
    prune_old_backups "${keep}"
    print_offsite_tip
    return 0
  fi
  echo
  local reply=""
  read -r -p "Update succeeded. Keep rollback backup at ${dir}? [Y/n] " reply || true
  case "${reply:-Y}" in
    n|N|no|NO)
      rm -rf "${dir}"
      # fix latest pointer
      if [[ -L "${BACKUP_ROOT}/latest" ]]; then
        local cur
        cur="$(readlink -f "${BACKUP_ROOT}/latest" 2>/dev/null || true)"
        if [[ "$cur" == "$dir" ]]; then
          rm -f "${BACKUP_ROOT}/latest"
          local newest
          newest="$(ls -1dt "${BACKUP_ROOT}"/snapshots/* 2>/dev/null | head -1 || true)"
          [[ -n "$newest" ]] && ln -sfn "snapshots/$(basename "$newest")" "${BACKUP_ROOT}/latest"
        fi
      fi
      rmdir "${BACKUP_ROOT}/snapshots" 2>/dev/null || true
      rmdir "${BACKUP_ROOT}" 2>/dev/null || true
      echo "Backup deleted."
      ;;
    *)
      echo "Backup kept."
      local default="${DEFAULT_KEEP}"
      [[ -f "${KEEP_FILE}" ]] && default="$(tr -dc '0-9' <"${KEEP_FILE}" || true)"
      [[ -z "${default}" ]] && default="${DEFAULT_KEEP}"
      local keep=""
      read -r -p "How many local backups should we keep on this disk? [${default}] " keep || true
      keep="$(printf '%s' "${keep:-$default}" | tr -dc '0-9')"
      [[ -z "${keep}" || "${keep}" -lt 1 ]] && keep="${default}"
      echo "${keep}" >"${KEEP_FILE}"
      prune_old_backups "${keep}"
      print_offsite_tip
      echo "  This snapshot: ${dir}"
      echo "  Manual restore: ./backup.sh --restore --from ./backups"
      ;;
  esac
}

create_backup() {
  if [[ ! -x "${ROOT}/backup.sh" ]]; then
    echo "Missing executable backup.sh (required for pre-update snapshots)." >&2
    exit 1
  fi
  local keep="${DEFAULT_KEEP}"
  [[ -f "${KEEP_FILE}" ]] && keep="$(tr -dc '0-9' <"${KEEP_FILE}" || true)"
  [[ -z "${keep}" ]] && keep="${DEFAULT_KEEP}"
  echo "==> Pre-update snapshot via ./backup.sh --dest ${BACKUP_ROOT} ..."
  "${ROOT}/backup.sh" --dest "${BACKUP_ROOT}" --keep "${keep}"
  if [[ -L "${BACKUP_ROOT}/latest" ]]; then
    BACKUP_DIR="$(readlink -f "${BACKUP_ROOT}/latest")"
  else
    BACKUP_DIR="$(ls -1dt "${BACKUP_ROOT}"/snapshots/* 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "${BACKUP_DIR}" || ! -d "${BACKUP_DIR}" ]]; then
    echo "Pre-update backup did not produce a snapshot." >&2
    exit 1
  fi
  echo "Backup ready: ${BACKUP_DIR}"
}


need kubectl
require_storage_class

if ! kubectl -n "$NS" get deploy nextcloud >/dev/null 2>&1; then
  echo "Nextcloud is not installed yet. Run ./install.sh first." >&2
  exit 1
fi

refuse_legacy_nextcloud_cluster
create_backup

echo "==> Applying core manifests..."
apply_manifest "${ROOT}/deploy.yaml"
apply_saved_replicas nextcloud

if redis_deployed; then
  echo "==> Redis is present — re-applying deploy-redis.yaml..."
  apply_manifest "${ROOT}/deploy-redis.yaml"
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
