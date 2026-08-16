#!/usr/bin/env bash
# Disaster-recovery backup/restore with incremental rsync snapshots (k8s).
# Restores HTML + MariaDB and runs occ repair/scan on a fresh cluster.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/deps.sh
source "${ROOT}/scripts/deps.sh"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
cd "$ROOT"
# shellcheck source=scripts/backup-encrypt.sh
source "${ROOT}/scripts/backup-encrypt.sh"
STACK_ID="nextcloud-office-k8s"

need_rsync() {
  command -v rsync >/dev/null 2>&1 || {
    echo "Missing: rsync (needed for incremental snapshots)." >&2
    exit 1
  }
}

usage() {
  cat <<EOF
Usage:
  ./manage.sh backup --dest /mnt/backup [--keep N]
  ./manage.sh backup --restore --from /path/to/backup-root-or-snapshot
  ./manage.sh backup --help

Disaster-recovery backups (also used by ./manage.sh update for pre-update snapshots into ./backups).

  --dest DIR    Backup root; writes to DIR/<stack-id>/snapshots/...
                Uses rsync hardlinks against the previous snapshot so
                unchanged files are not duplicated on disk.
  --keep N      After backup, keep only the newest N snapshots (default: no prune).
  --restore     Restore into this deployment from --from.
  --from PATH   Backup root (uses latest/) or a specific snapshots/TIMESTAMP dir.

  --archive FMT      After snapshot, also write a compressed export (tar.gz|tar.xz|zip).
                     Local hardlink snapshots stay uncompressed for --link-dest.
  --archive-password Password-protect that archive:
                       zip   → zip -e (ZipCrypto; casual protection)
                       tar.* → compress then age -p (strong passphrase)
  --encrypt          Advanced: age-encrypted .tar.age export (recipient key).
  --export-dir DIR   Where to put exports (default: DEST/exports for --archive,
                     DEST/encrypted for --encrypt).
  --age-recipient R  age1… public key or path to recipients file (repeatable).
  --age-identity F   Private key file for decrypt (default: ~/.config/johnycsf/backup.age.key).
  --passphrase       With --encrypt: age -p instead of a recipient key.

  SHA256SUMS = integrity. Archives/age = smaller or confidential offsite copies.
  Restore: --from may be a snapshot dir/root OR *.tar.gz / *.tar.xz / *.zip /
  *.tar.gz.age / *.tar.xz.age / *.tar.age / *.age.

Fresh-machine workflow:
  1) Install this stack on the new host (./manage.sh) so runtime exists.
  2) ./manage.sh backup --restore --from /mnt/usb/my-backups
  3) Script replaces data/secrets and finishes app-specific repair (e.g. Nextcloud scan).

Database safety:
  MariaDB/Nextcloud  — logical dump (--single-transaction), never live datadir copy.
  SQLite apps       — service stopped/scaled down, WAL checkpoint, then file copy.
  Incremental rsync applies to files; each MariaDB dump is a full verified SQL file.
EOF
}

MODE=""
DEST=""
FROM=""
KEEP=""

ENCRYPT="${BACKUP_ENCRYPT:-0}"
EXPORT_DIR="${BACKUP_EXPORT_DIR:-}"
ENCRYPT_PASSPHRASE=0
ARCHIVE_FORMAT="${BACKUP_ARCHIVE:-}"
ARCHIVE_PASSWORD="${BACKUP_ARCHIVE_PASSWORD:-0}"
AGE_RECIPIENTS=()
AGE_IDENTITY="${BACKUP_AGE_IDENTITY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || { echo "--dest needs a path" >&2; exit 1; }
      DEST="$2"; MODE="${MODE:-backup}"; shift 2 ;;
    --from)
      [[ $# -ge 2 ]] || { echo "--from needs a path" >&2; exit 1; }
      FROM="$2"; shift 2 ;;
    --restore)
      MODE="restore"; shift ;;
    --archive)
      [[ $# -ge 2 ]] || { echo "--archive needs tar.gz|tar.xz|zip" >&2; exit 1; }
      ARCHIVE_FORMAT="$2"; shift 2 ;;
    --archive-password)
      ARCHIVE_PASSWORD=1; shift ;;
    --encrypt)
      ENCRYPT=1; shift ;;
    --export-dir)
      [[ $# -ge 2 ]] || { echo "--export-dir needs a path" >&2; exit 1; }
      EXPORT_DIR="$2"; shift 2 ;;
    --age-recipient)
      [[ $# -ge 2 ]] || { echo "--age-recipient needs a value" >&2; exit 1; }
      AGE_RECIPIENTS+=("$2"); shift 2 ;;
    --age-identity)
      [[ $# -ge 2 ]] || { echo "--age-identity needs a path" >&2; exit 1; }
      AGE_IDENTITY="$2"; shift 2 ;;
    --passphrase)
      ENCRYPT=1; ENCRYPT_PASSPHRASE=1; shift ;;
    --keep)
      [[ $# -ge 2 ]] || { echo "--keep needs a number" >&2; exit 1; }
      KEEP="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

stamp_now() { date +%Y%m%d-%H%M%S; }

resolve_snapshot_dir() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Not found: $path" >&2
    exit 1
  fi
  path="$(cd "$path" && pwd)"
  if [[ -f "${path}/META.txt" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  if [[ -L "${path}/latest" ]]; then
    local target=""
    if target="$(readlink -f "${path}/latest" 2>/dev/null)"; then
      :
    else
      target="$(readlink "${path}/latest")"
      [[ "$target" == /* ]] || target="${path}/${target}"
    fi
    if [[ -f "${target}/META.txt" ]]; then
      printf '%s\n' "$(cd "$target" && pwd)"
      return 0
    fi
  fi
  # newest snapshots/*
  local newest
  newest="$(ls -1dt "${path}"/snapshots/* 2>/dev/null | head -1 || true)"
  if [[ -n "$newest" && -f "${newest}/META.txt" ]]; then
    printf '%s\n' "$(cd "$newest" && pwd)"
    return 0
  fi
  echo "No usable snapshot under: $path" >&2
  echo "Expected META.txt in a snapshot dir, or a backup root with latest/ / snapshots/." >&2
  exit 1
}

prepare_snapshot_dirs() {
  local dest="$1"
  mkdir -p "${dest}/snapshots"
  SNAP_NAME="$(stamp_now)"
  SNAP_DIR="${dest}/snapshots/${SNAP_NAME}"
  mkdir -p "${SNAP_DIR}"
  PREV_LINK=""
  if [[ -L "${dest}/latest" ]]; then
    PREV_LINK="$(readlink "${dest}/latest")"
    if [[ "${PREV_LINK}" != /* ]]; then
      PREV_LINK="${dest}/${PREV_LINK}"
    fi
  fi
}

finalize_snapshot() {
  local dest="$1"
  ln -sfn "snapshots/${SNAP_NAME}" "${dest}/latest"
  echo "Snapshot ready: ${SNAP_DIR}"
  echo "Latest pointer: ${dest}/latest -> snapshots/${SNAP_NAME}"
}

prune_snapshots() {
  local dest="$1"
  local keep="$2"
  [[ -n "$keep" ]] || return 0
  keep="$(printf '%s' "$keep" | tr -dc '0-9')"
  [[ -n "$keep" && "$keep" -ge 1 ]] || return 0
  mapfile -t snaps < <(ls -1dt "${dest}"/snapshots/* 2>/dev/null || true)
  local total="${#snaps[@]}"
  if (( total <= keep )); then
    echo "Retention: keeping all ${total} snapshot(s) (limit ${keep})."
    return 0
  fi
  local i
  for (( i = keep; i < total; i++ )); do
    echo "Pruning old snapshot: ${snaps[$i]}"
    rm -rf "${snaps[$i]}"
  done
}

rsync_incremental() {
  # rsync_incremental SRC_DIR DEST_FILES_DIR PREV_FILES_DIR_OR_EMPTY
  local src="$1"
  local dst="$2"
  local prev="${3:-}"
  mkdir -p "$dst"
  local -a args=(-aH --delete --info=stats2)
  if [[ -n "$prev" && -d "$prev" ]]; then
    args+=(--link-dest="$prev")
    echo "    Incremental vs: $prev"
  else
    echo "    Full copy (first snapshot or no previous files/)."
  fi
  rsync "${args[@]}" "${src}/" "${dst}/"
}

write_meta() {
  local snap="$1"
  local stack="$2"
  local note="$3"
  cat >"${snap}/META.txt" <<EOF
stack=${stack}
created=$(date -Iseconds)
host=$(hostname 2>/dev/null || echo unknown)
note=${note}
EOF
}





# --- MariaDB safety (logical dump only; never rsync live datadir) ---
verify_mariadb_dump() {
  local f="$1"
  if [[ ! -s "$f" ]]; then
    echo "SQL dump missing or empty: $f" >&2
    return 1
  fi
  if ! grep -q 'Dump completed' "$f"; then
    echo "SQL dump looks incomplete (no 'Dump completed' marker): $f" >&2
    return 1
  fi
  if ! grep -qE 'CREATE TABLE|INSERT INTO' "$f"; then
    echo "SQL dump has no CREATE TABLE/INSERT INTO — refusing: $f" >&2
    return 1
  fi
  local bytes
  bytes="$(wc -c <"$f" | tr -d ' ')"
  echo "    Verified MariaDB dump (${bytes} bytes)."
}


# --- Snapshot integrity (SHA256) ---
# Payload files are listed in SHA256SUMS. META.txt holds snapshot_sha256 (hash of SHA256SUMS).
# Restore verifies and WARNS on mismatch but does not abort.
sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    echo "unavailable"
  fi
}

seal_snapshot() {
  local snap="$1"
  echo "==> Sealing snapshot with SHA256 manifests..."
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "WARNING: sha256sum/shasum not found — snapshot will lack integrity key." >&2
    return 0
  fi
  (
    cd "$snap" || exit 1
    rm -f SHA256SUMS
    if command -v sha256sum >/dev/null 2>&1; then
      find . -type f ! -name SHA256SUMS ! -name META.txt -print0 \
        | sort -z \
        | xargs -0 -r sha256sum >SHA256SUMS
    else
      : >SHA256SUMS
      find . -type f ! -name SHA256SUMS ! -name META.txt -print0 | sort -z | while IFS= read -r -d '' f; do
        printf '%s  %s
' "$(shasum -a 256 "$f" | awk '{print $1}')" "$f" >>SHA256SUMS
      done
    fi
    if [[ ! -s SHA256SUMS ]]; then
      echo "WARNING: SHA256SUMS is empty (no payload files?)." >&2
    fi
  )
  local sum
  sum="$(sha256_file "${snap}/SHA256SUMS")"
  if [[ ! -f "${snap}/META.txt" ]]; then
    printf 'stack=unknown
created=%s
' "$(date -Iseconds)" >"${snap}/META.txt"
  fi
  if grep -q '^snapshot_sha256=' "${snap}/META.txt" 2>/dev/null; then
    sed -i "s|^snapshot_sha256=.*|snapshot_sha256=${sum}|" "${snap}/META.txt"
  else
    printf 'snapshot_sha256=%s
' "$sum" >>"${snap}/META.txt"
  fi
  echo "    snapshot_sha256=${sum}"
  echo "    Wrote SHA256SUMS + META snapshot_sha256 key."
}

verify_snapshot_integrity() {
  local snap="$1"
  local warn=0
  echo "==> Checking snapshot integrity (SHA256)..."
  if [[ ! -f "${snap}/SHA256SUMS" ]]; then
    echo "WARNING: No SHA256SUMS manifest — cannot verify integrity (legacy or incomplete backup)." >&2
    echo "         Restore will continue, but corruption cannot be ruled out." >&2
    return 0
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "WARNING: sha256sum not found — skipping per-file check." >&2
    warn=1
  else
    local out
    set +e
    out="$(cd "$snap" && sha256sum -c SHA256SUMS 2>&1)"
    local rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      echo "WARNING: SHA256 file verification FAILED — integrity is lost; restore may cause issues." >&2
      printf '%s
' "$out" | grep -v ': OK$' | head -n 40 >&2 || true
      warn=1
    fi
  fi
  local expected actual
  expected="$(grep -E '^snapshot_sha256=' "${snap}/META.txt" 2>/dev/null | cut -d= -f2- || true)"
  actual="$(sha256_file "${snap}/SHA256SUMS")"
  if [[ -z "$expected" || "$expected" == "unavailable" ]]; then
    echo "WARNING: META.txt has no snapshot_sha256 key." >&2
    warn=1
  elif [[ "$actual" != "$expected" ]]; then
    echo "WARNING: SHA256SUMS does not match META snapshot_sha256 — integrity is lost; restore may cause issues." >&2
    echo "         expected=${expected}" >&2
    echo "         actual=${actual}" >&2
    warn=1
  fi
  if [[ "$warn" -eq 0 ]]; then
    echo "    Integrity OK (snapshot_sha256=${actual})."
  else
    echo "    Continuing restore despite integrity warnings (not aborting)." >&2
  fi
  return 0
}


verify_dump_checksum() {
  local f="$1"
  local meta="$2"
  local expected=""
  expected="$(grep -E '^db_sha256=' "$meta" 2>/dev/null | cut -d= -f2- || true)"
  [[ -n "$expected" && "$expected" != "unavailable" ]] || return 0
  local actual
  actual="$(sha256_file "$f")"
  if [[ "$actual" != "$expected" ]]; then
    echo "WARNING: SQL dump checksum mismatch (expected ${expected}, got ${actual})." >&2
    echo "         Integrity is lost for the database dump; restore may cause issues." >&2
    echo "         Continuing anyway (will not abort)." >&2
    return 0
  fi
  echo "    DB dump checksum OK (${actual})."
}


wait_nextcloud_ready() {
  echo "Waiting for Nextcloud to become ready..."
  local i
  for i in $(seq 1 90); do
    if occ status 2>/dev/null | grep -q 'installed: true'; then
      echo "Nextcloud is installed and reachable via occ."
      return 0
    fi
    sleep 2
  done
  echo "Nextcloud did not report installed:true in time." >&2
  exit 1
}

print_scan_pct() {
  local label="$1" count="$2" total="$3"
  local pct=0 width=30 filled empty bar
  if (( total > 0 )); then
    pct=$((count * 100 / total))
    (( pct > 100 )) && pct=100
  fi
  filled=$((pct * width / 100))
  printf -v bar '%*s' "$filled" ''
  bar=${bar// /#}
  printf -v empty '%*s' "$((width - filled))" ''
  empty=${empty// /-}
  printf '\r==> %s: [%s%s] %3d%% (%s/%s)   ' \
    "$label" "$bar" "$empty" "$pct" "$count" "$total" >&2
}

count_nc_data_entries() {
  local pod
  pod="$(nextcloud_pod)"
  kubectl -n "$NS" exec "$pod" -- sh -c \
    'find /var/www/html/data \( -type f -o -type d \) 2>/dev/null | wc -l' \
    | tr -d ' \r\n'
}

occ_files_scan_with_progress() {
  local label="${1:-files:scan}"
  shift || true
  local total=0 count=0 last_print=0 line pipe_rc=0
  echo "==> ${label} (progress below; large libraries can take a long time)..."
  total="$(count_nc_data_entries 2>/dev/null || echo 0)"
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  if (( total > 0 )); then
    echo "    Estimated entries under data/: ${total}"
  else
    echo "    Could not pre-count entries — showing per-user progress when available."
  fi
  print_scan_pct "$label" 0 "$total"

  set +e
  occ "$@" -v 2>&1 | while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ [Uu]ser[[:space:]]+([0-9]+)[[:space:]]+out[[:space:]]+of[[:space:]]+([0-9]+) ]]; then
      printf '\n    %s\n' "$line" >&2
      if (( total <= 0 )); then
        print_scan_pct "$label" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      fi
      continue
    fi
    if [[ "$line" == Completed* ]] || [[ "$line" == +* ]] || [[ "$line" == Entry\ exclusions* ]]; then
      printf '\n    %s\n' "$line" >&2
      continue
    fi
    if [[ "$line" == $'\t'* ]] || [[ "$line" == /* ]]; then
      count=$((count + 1))
      if (( total > 0 )); then
        if (( count - last_print >= 25 || count >= total || count == 1 )); then
          print_scan_pct "$label" "$count" "$total"
          last_print=$count
        fi
      fi
    fi
  done
  pipe_rc=${PIPESTATUS[0]}
  set -e
  if (( total > 0 )); then
    print_scan_pct "$label" "$total" "$total"
  fi
  printf '\n' >&2
  return "${pipe_rc:-0}"
}

post_restore_nextcloud() {
  echo "==> Repair / reindex..."
  occ maintenance:mode --off || true
  occ db:add-missing-indices || true
  occ db:add-missing-columns || true
  occ db:add-missing-primary-keys || true
  occ maintenance:repair --include-expensive || true
  occ_files_scan_with_progress "files:scan" files:scan --all || {
    echo "WARNING: files:scan reported an error — check output above." >&2
  }
  echo "==> Scanning app data..."
  occ files:scan-app-data || true
  if [[ -x "${ROOT}/scripts/configure-office.sh" ]]; then
    echo "==> Re-applying Collabora / trusted domains for this cluster..."
    "${ROOT}/scripts/configure-office.sh" || echo "Warning: configure-office.sh had errors." >&2
  fi
}

pull_pod_tree() {
  local pod="$1" remote="$2" dest="$3"
  mkdir -p "$dest"
  kubectl -n "$NS" exec "$pod" -- tar -C "$remote" -cf - . | tar -C "$dest" -xf -
}

push_pod_tree() {
  local pod="$1" remote="$2" src="$3"
  kubectl -n "$NS" exec "$pod" -- sh -c "rm -rf ${remote}/* ${remote}/.[!.]* ${remote}/..?* 2>/dev/null || true"
  tar -C "$src" -cf - . | kubectl -n "$NS" exec -i "$pod" -- tar -C "$remote" -xf -
}


do_backup() {
  need kubectl
  need_rsync
  [[ -n "$DEST" ]] || { echo "Provide --dest /path" >&2; exit 1; }
  DEST="$(resolve_stack_backup_dest "${STACK_ID}" "${DEST}")"
  DEST="$(mkdir -p "$DEST" && cd "$DEST" && pwd)"
  echo "==> Stack backup root: ${DEST}"
  prepare_snapshot_dirs "$DEST"
  echo "==> Snapshot ${SNAP_NAME} -> ${SNAP_DIR}"
  echo "==> DB strategy: logical MariaDB dump (safe). HTML files use incremental rsync."
  echo "    Never snapshotting live PVC InnoDB files."

  local ncpod dbpod
  ncpod="$(nextcloud_pod)"
  dbpod="$(kubectl -n "$NS" get pod -l app=db -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$ncpod" && -n "$dbpod" ]] || { echo "Need running nextcloud + db pods." >&2; rm -rf "${SNAP_DIR}"; exit 1; }

  maintenance_off() { occ maintenance:mode --off >/dev/null 2>&1 || true; }
  cleanup_failed_snap() {
    maintenance_off
    rm -rf "${SNAP_DIR}"
  }
  trap cleanup_failed_snap EXIT

  echo "==> Enabling Nextcloud maintenance mode..."
  occ maintenance:mode --on

  echo "==> Dumping MariaDB from ${dbpod}..."
  local db user pass dump
  db="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_DATABASE}' | base64 -d)"
  user="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_USER}' | base64 -d)"
  pass="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)"
  dump="${SNAP_DIR}/nextcloud-db.sql"
  kubectl -n "$NS" exec "${dbpod}" -- \
    mariadb-dump -u"${user}" -p"${pass}" \
      --single-transaction --quick --routines --triggers --events --hex-blob \
      --add-drop-table --default-character-set=utf8mb4 \
      "${db}" \
    >"${dump}"
  verify_mariadb_dump "${dump}"
  local sum
  sum="$(sha256_file "${dump}")"

  echo "==> Archiving /var/www/html from ${ncpod}..."
  local staging
  staging="$(mktemp -d)"
  pull_pod_tree "$ncpod" /var/www/html "${staging}/files"
  local prev_files=""
  [[ -n "${PREV_LINK}" && -d "${PREV_LINK}/files" ]] && prev_files="${PREV_LINK}/files"
  rsync_incremental "${staging}/files" "${SNAP_DIR}/files" "${prev_files}"
  rm -rf "$staging"

  kubectl -n "$NS" get secret nextcloud-db -o yaml >"${SNAP_DIR}/secret-nextcloud-db.yaml"
  cp -a "${ROOT}/deploy.yaml" "${SNAP_DIR}/" 2>/dev/null || true
  [[ -f "${ROOT}/deploy-redis.yaml" ]] && cp -a "${ROOT}/deploy-redis.yaml" "${SNAP_DIR}/"
  cat >"${SNAP_DIR}/META.txt" <<EOF
stack=${STACK_ID}
created=$(date -Iseconds)
host=$(hostname 2>/dev/null || echo unknown)
note=nextcloud html + verified mariadb logical dump
db_engine=mariadb
db_method=mariadb-dump --single-transaction
db_sha256=${sum}
files=/var/www/html
datadir_excluded=PVC nextcloud-db raw files
EOF

  trap - EXIT
  maintenance_off
  seal_snapshot "${SNAP_DIR}"
  maybe_encrypt_after_seal
  finalize_snapshot "$DEST"
  prune_snapshots "$DEST" "${KEEP}"
  echo "Backup OK. Tip: store on external drive/NAS (hardlinks need one filesystem)."
}

do_restore() {
  need kubectl
  need_rsync
  [[ -n "$FROM" ]] || { echo "Provide --from /path" >&2; exit 1; }
  FROM="$(resolve_stack_backup_from "${STACK_ID}" "${FROM}")"
  local snap src
  src="$(prepare_restore_from_arg "$FROM")"
  trap cleanup_restore_tmp EXIT
  snap="$(resolve_snapshot_dir "$src")"
  echo "Restoring from: $snap"
  verify_snapshot_integrity "$snap"
  [[ -d "${snap}/files" ]] || { echo "Missing files/" >&2; exit 1; }

  if [[ ! -f "${snap}/nextcloud-db.sql" ]]; then
    if [[ "${FORCE_FILES_ONLY:-}" == "yes" ]]; then
      echo "FORCE_FILES_ONLY=yes — restoring files without DB (dangerous)." >&2
    else
      echo "Refusing restore: no nextcloud-db.sql in snapshot." >&2
      exit 1
    fi
  else
    verify_mariadb_dump "${snap}/nextcloud-db.sql"
    verify_dump_checksum "${snap}/nextcloud-db.sql" "${snap}/META.txt"
  fi

  echo
  cat <<'EOF'
This replaces Nextcloud files + DB so a new cluster matches the backup,
then runs occ repair and files:scan --all.

Nextcloud will be scaled down during SQL import so the app cannot write mid-restore.
EOF
  read -r -p "Type 'restore' to continue: " confirm || true
  [[ "${confirm}" == "restore" ]] || { echo "Aborted."; exit 1; }

  if ! kubectl -n "$NS" get deploy nextcloud >/dev/null 2>&1; then
    echo "==> Applying manifests..."
    apply_manifest "${ROOT}/deploy.yaml"
  fi
  if [[ -f "${snap}/secret-nextcloud-db.yaml" ]]; then
    echo "==> Restoring DB secret..."
    kubectl -n "$NS" apply -f "${snap}/secret-nextcloud-db.yaml"
  fi

  echo "==> Scaling Nextcloud to 0 during DB import..."
  kubectl -n "$NS" scale deployment/nextcloud --replicas=0
  kubectl -n "$NS" wait --for=delete pod -l app=nextcloud --timeout=180s 2>/dev/null || true

  kubectl -n "$NS" rollout status deployment/db --timeout=300s
  local dbpod
  dbpod="$(kubectl -n "$NS" get pod -l app=db -o jsonpath='{.items[0].metadata.name}')"

  if [[ -f "${snap}/nextcloud-db.sql" ]]; then
    echo "==> Importing verified SQL into ${dbpod}..."
    local db user pass
    db="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_DATABASE}' | base64 -d)"
    user="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_USER}' | base64 -d)"
    pass="$(kubectl -n "$NS" get secret nextcloud-db -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d)"
    if ! kubectl -n "$NS" exec -i "${dbpod}" -- \
        mariadb -u"${user}" -p"${pass}" "${db}" \
        <"${snap}/nextcloud-db.sql"; then
      echo "SQL IMPORT FAILED — leaving Nextcloud scaled to 0. Fix dump and retry." >&2
      exit 1
    fi
    echo "    SQL import completed."
  fi

  echo "==> Scaling Nextcloud back up and restoring HTML..."
  kubectl -n "$NS" scale deployment/nextcloud --replicas=1
  kubectl -n "$NS" rollout status deployment/nextcloud --timeout=300s
  local ncpod
  ncpod="$(nextcloud_pod)"
  push_pod_tree "$ncpod" /var/www/html "${snap}/files"

  kubectl -n "$NS" rollout restart deployment/nextcloud
  kubectl -n "$NS" rollout status deployment/nextcloud --timeout=300s
  wait_nextcloud_ready
  post_restore_nextcloud
  echo
  echo "Restore finished from ${snap}."
}

case "${MODE}" in
  backup) do_backup ;;
  restore) do_restore ;;
  *) usage >&2; exit 1 ;;
esac
