#!/usr/bin/env bash
# Optional offsite archive / encrypted export after a sealed hardlink snapshot.
# Local snapshots stay uncompressed so rsync --link-dest incrementals keep working.
#
# Archives (under DEST/exports/ by default):
#   --archive tar.gz|tar.xz|zip
#   --archive-password   password-protect
#       zip  → zip -e (traditional ZipCrypto; casual/offsite, not bank-grade)
#       tar.* → compress then age -p (strong passphrase AEAD)
#   --encrypt            advanced: age recipient/passphrase → *.tar.age
#                        (default dir: DEST/encrypted/)
#
# Restore accepts snapshot dirs, *.tar.gz, *.tar.xz, *.zip,
# *.tar.gz.age, *.tar.xz.age, *.tar.age / *.age

# Optional defaults (backup.sh may override after source)
ENCRYPT="${ENCRYPT:-${BACKUP_ENCRYPT:-0}}"
EXPORT_DIR="${EXPORT_DIR:-${BACKUP_EXPORT_DIR:-}}"
ENCRYPT_PASSPHRASE="${ENCRYPT_PASSPHRASE:-0}"
ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-${BACKUP_ARCHIVE:-}}"
ARCHIVE_PASSWORD="${ARCHIVE_PASSWORD:-${BACKUP_ARCHIVE_PASSWORD:-0}}"
AGE_IDENTITY="${AGE_IDENTITY:-${BACKUP_AGE_IDENTITY:-}}"
AGE_PASSPHRASE_FILE="${AGE_PASSPHRASE_FILE:-${BACKUP_AGE_PASSPHRASE_FILE:-}}"
if ! declare -p AGE_RECIPIENTS >/dev/null 2>&1; then
  AGE_RECIPIENTS=()
fi

if ! declare -F need >/dev/null 2>&1; then
  need() { command -v "$1" >/dev/null || { echo "Missing: $1" >&2; exit 1; }; }
fi

_backup_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Back-compat alias
_backup_encrypt_truthy() { _backup_truthy "$@"; }

need_age() {
  if command -v age >/dev/null 2>&1; then
    return 0
  fi
  if declare -F _deps_ensure_cmd >/dev/null 2>&1; then
    _deps_ensure_cmd age || true
  fi
  command -v age >/dev/null 2>&1 || {
    echo "Missing: age (needed for password-protected tar archives / .tar.age)." >&2
    echo "Install the 'age' package, then re-run." >&2
    exit 1
  }
}

need_zip() {
  if command -v zip >/dev/null 2>&1; then
    return 0
  fi
  if declare -F _deps_ensure_cmd >/dev/null 2>&1; then
    _deps_ensure_cmd zip || true
  fi
  command -v zip >/dev/null 2>&1 || {
    echo "Missing: zip (Info-ZIP). Install 'zip' and re-run." >&2
    exit 1
  }
}

need_unzip() {
  if command -v unzip >/dev/null 2>&1; then
    return 0
  fi
  if declare -F _deps_ensure_cmd >/dev/null 2>&1; then
    _deps_ensure_cmd unzip || true
  fi
  command -v unzip >/dev/null 2>&1 || {
    echo "Missing: unzip. Install 'unzip' and re-run." >&2
    exit 1
  }
}

need_xz() {
  if command -v xz >/dev/null 2>&1; then
    return 0
  fi
  if declare -F _deps_ensure_cmd >/dev/null 2>&1; then
    _deps_ensure_cmd xz || true
  fi
  command -v xz >/dev/null 2>&1 || {
    echo "Missing: xz (for tar.xz). Install 'xz' / xz-utils and re-run." >&2
    exit 1
  }
}

_age_identity_default() {
  printf '%s\n' "${HOME}/.config/johnycsf/backup.age.key"
}

ensure_backup_age_identity() {
  need_age
  command -v age-keygen >/dev/null 2>&1 || {
    echo "Missing: age-keygen (usually shipped with age)." >&2
    exit 1
  }
  local id
  id="$(_age_identity_default)"
  mkdir -p "$(dirname "$id")"
  chmod 700 "$(dirname "$id")" 2>/dev/null || true
  if [[ ! -f "$id" ]]; then
    umask 077
    age-keygen -o "$id" >/dev/null
    chmod 600 "$id"
    echo "==> Created age identity: $id"
    echo "    Public recipient (save this; needed to encrypt without the private key):"
    age-keygen -y "$id" | sed 's/^/    /'
    echo "    Keep the private key offline and separate from encrypted exports."
  else
    chmod 600 "$id" 2>/dev/null || true
  fi
  AGE_IDENTITY="$id"
}

_append_age_recipient_args() {
  AGE_R_ARGS=()
  local r
  if [[ ${#AGE_RECIPIENTS[@]} -gt 0 ]]; then
    for r in "${AGE_RECIPIENTS[@]}"; do
      [[ -n "$r" ]] || continue
      if [[ -f "$r" ]]; then AGE_R_ARGS+=(-R "$r"); else AGE_R_ARGS+=(-r "$r"); fi
    done
    return 0
  fi
  if [[ -n "${BACKUP_AGE_RECIPIENT:-}" ]]; then
    if [[ -f "${BACKUP_AGE_RECIPIENT}" ]]; then
      AGE_R_ARGS+=(-R "${BACKUP_AGE_RECIPIENT}")
    else
      AGE_R_ARGS+=(-r "${BACKUP_AGE_RECIPIENT}")
    fi
    return 0
  fi
  ensure_backup_age_identity
  AGE_R_ARGS+=(-r "$(age-keygen -y "${AGE_IDENTITY}")")
}

_normalize_archive_format() {
  case "${1:-}" in
    tar.gz|tgz|gzip) printf '%s\n' "tar.gz" ;;
    tar.xz|txz|xz) printf '%s\n' "tar.xz" ;;
    zip) printf '%s\n' "zip" ;;
    ""|none|off) printf '%s\n' "" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

_export_root_for_snap() {
  local snap="$1" kind="${2:-archive}"
  local root="${EXPORT_DIR:-}"
  if [[ -z "$root" && -n "${DEST:-}" ]]; then
    if [[ "$kind" == "age" ]]; then
      root="${DEST}/encrypted"
    else
      root="${DEST}/exports"
    fi
  fi
  if [[ -z "$root" ]]; then
    if [[ "$kind" == "age" ]]; then
      root="$(cd "$(dirname "$snap")/.." && pwd)/encrypted"
    else
      root="$(cd "$(dirname "$snap")/.." && pwd)/exports"
    fi
  fi
  mkdir -p "$root"
  chmod 700 "$root" 2>/dev/null || true
  printf '%s\n' "$root"
}

_record_export_meta() {
  local snap="$1" kind="$2" file="$3"
  local export_sha=""
  if command -v sha256sum >/dev/null 2>&1 && [[ -f "$file" ]]; then
    export_sha="$(sha256sum "$file" | awk '{print $1}')"
  fi
  {
    echo "export_kind=${kind}"
    echo "export_file=${file}"
    [[ -n "$export_sha" ]] && echo "export_sha256=${export_sha}"
  } >>"${snap}/META.txt"
}

_age_decrypt_stream() {
  # Reads encrypted bytes from stdin; writes plaintext to stdout.
  local id="${AGE_IDENTITY:-}"
  [[ -n "$id" ]] || id="$(_age_identity_default)"
  if [[ -f "$id" ]]; then
    age -d -i "$id"
  else
    echo "No identity at ${id}; prompting for passphrase..." >&2
    age -d
  fi
}

export_snapshot_archive() {
  # export_snapshot_archive SNAP_DIR STACK_ID FORMAT
  local snap="$1" stack_id="$2" fmt
  local export_root stamp base partial out
  fmt="$(_normalize_archive_format "$3")"
  need tar
  [[ -d "$snap" ]] || { echo "Snapshot not found: $snap" >&2; return 1; }
  [[ -n "$fmt" ]] || { echo "Archive format required" >&2; return 1; }
  stamp="$(basename "$snap")"
  export_root="$(_export_root_for_snap "$snap" archive)"
  base="${stack_id}-${stamp}"
  umask 077

  echo "==> Creating ${fmt} archive of snapshot (local hardlink tree stays in place)"
  case "$fmt" in
    tar.gz)
      if _backup_truthy "${ARCHIVE_PASSWORD}"; then
        need_age
        partial="${export_root}/${base}.tar.gz.age.partial"
        out="${export_root}/${base}.tar.gz.age"
        rm -f "$partial"
        echo "    Password-protecting with age passphrase → $(basename "$out")"
        tar -C "$snap" -cf - . | gzip -c | age -p >"$partial"
        mv -f "$partial" "$out"
        _record_export_meta "$snap" "tar.gz+age-passphrase" "$out"
      else
        partial="${export_root}/${base}.tar.gz.partial"
        out="${export_root}/${base}.tar.gz"
        rm -f "$partial"
        tar -C "$snap" -czf "$partial" .
        mv -f "$partial" "$out"
        _record_export_meta "$snap" "tar.gz" "$out"
      fi
      ;;
    tar.xz)
      need_xz
      if _backup_truthy "${ARCHIVE_PASSWORD}"; then
        need_age
        partial="${export_root}/${base}.tar.xz.age.partial"
        out="${export_root}/${base}.tar.xz.age"
        rm -f "$partial"
        echo "    Password-protecting with age passphrase → $(basename "$out")"
        tar -C "$snap" -cf - . | xz -c | age -p >"$partial"
        mv -f "$partial" "$out"
        _record_export_meta "$snap" "tar.xz+age-passphrase" "$out"
      else
        partial="${export_root}/${base}.tar.xz.partial"
        out="${export_root}/${base}.tar.xz"
        rm -f "$partial"
        tar -C "$snap" -cJf "$partial" .
        mv -f "$partial" "$out"
        _record_export_meta "$snap" "tar.xz" "$out"
      fi
      ;;
    zip)
      need_zip
      out="${export_root}/${base}.zip"
      rm -f "$out"
      (
        cd "$snap"
        if _backup_truthy "${ARCHIVE_PASSWORD}"; then
          echo "    Password-protecting zip (zip -e; ZipCrypto — fine for casual/offsite, not bank-grade)"
          zip -erq "$out" .
        else
          zip -rq "$out" .
        fi
      )
      if _backup_truthy "${ARCHIVE_PASSWORD}"; then
        _record_export_meta "$snap" "zip+password" "$out"
      else
        _record_export_meta "$snap" "zip" "$out"
      fi
      ;;
    *)
      echo "Unknown archive format: $3 (use tar.gz, tar.xz, or zip)" >&2
      return 1
      ;;
  esac

  chmod 600 "$out" 2>/dev/null || true
  echo "Archive OK: ${out}"
  if _backup_truthy "${ARCHIVE_PASSWORD}"; then
    echo "Reminder: losing the password/passphrase means this archive cannot be restored."
  fi
}

export_snapshot_encrypted() {
  # Advanced: streamed tar | age → *.tar.age (recipient key or --passphrase)
  local snap="$1" stack_id="$2" export_root="${3:-}"
  local stamp name partial out
  need_age
  need tar
  [[ -d "$snap" ]] || { echo "Snapshot not found: $snap" >&2; return 1; }
  stamp="$(basename "$snap")"
  [[ -n "$export_root" ]] || export_root="$(_export_root_for_snap "$snap" age)"
  mkdir -p "$export_root"
  name="${stack_id}-${stamp}.tar.age"
  partial="${export_root}/${name}.partial"
  out="${export_root}/${name}"
  rm -f "$partial"
  echo "==> Encrypting offsite export with age -> ${out}"
  umask 077
  local enc_ok=0
  if [[ "${ENCRYPT_PASSPHRASE:-0}" == "1" ]]; then
    if tar -C "$snap" -cf - . | age -p >"$partial"; then enc_ok=1; fi
  else
    _append_age_recipient_args
    if tar -C "$snap" -cf - . | age "${AGE_R_ARGS[@]}" >"$partial"; then enc_ok=1; fi
  fi
  if [[ "$enc_ok" -ne 1 ]]; then
    rm -f "$partial"
    echo "age encryption failed." >&2
    return 1
  fi
  mv -f "$partial" "$out"
  chmod 600 "$out" 2>/dev/null || true
  _record_export_meta "$snap" "age" "$out"
  echo "Encrypted export OK: ${out}"
  echo "Reminder: keep the age private key / passphrase separate from this file."
}

decrypt_age_export_to_dir() {
  local archive="$1" out="$2"
  need_age
  need tar
  mkdir -p "$out"
  chmod 700 "$out" 2>/dev/null || true
  echo "==> Decrypting age export: $archive" >&2
  umask 077
  _age_decrypt_stream <"$archive" | tar -C "$out" -xf -
  [[ -f "${out}/META.txt" ]] || {
    echo "Decrypted archive missing META.txt" >&2
    return 1
  }
  printf '%s\n' "$(cd "$out" && pwd)"
}

extract_archive_to_dir() {
  local archive="$1" out="$2"
  mkdir -p "$out"
  chmod 700 "$out" 2>/dev/null || true
  echo "==> Extracting archive: $archive" >&2
  umask 077
  case "$archive" in
    *.tar.gz.age|*.tgz.age)
      need_age
      need tar
      _age_decrypt_stream <"$archive" | gzip -dc | tar -C "$out" -xf -
      ;;
    *.tar.xz.age|*.txz.age)
      need_age
      need tar
      need_xz
      _age_decrypt_stream <"$archive" | xz -dc | tar -C "$out" -xf -
      ;;
    *.tar.age|*.age)
      decrypt_age_export_to_dir "$archive" "$out" >/dev/null
      ;;
    *.tar.gz|*.tgz)
      need tar
      tar -C "$out" -xzf "$archive"
      ;;
    *.tar.xz|*.txz)
      need tar
      tar -C "$out" -xJf "$archive"
      ;;
    *.zip)
      need_unzip
      unzip -q "$archive" -d "$out"
      ;;
    *)
      echo "Unsupported archive: $archive" >&2
      return 1
      ;;
  esac
  [[ -f "${out}/META.txt" ]] || {
    echo "Archive missing META.txt — not a johnycsf snapshot export?" >&2
    return 1
  }
  printf '%s\n' "$(cd "$out" && pwd)"
}

maybe_encrypt_after_seal() {
  # Back-compat name used by backup.sh after seal_snapshot.
  maybe_export_after_seal
}

maybe_export_after_seal() {
  local fmt export_root
  fmt="$(_normalize_archive_format "${ARCHIVE_FORMAT:-}")"
  if [[ -n "$fmt" ]]; then
    export_snapshot_archive "${SNAP_DIR}" "${STACK_ID}" "$fmt"
  fi
  if _backup_truthy "${ENCRYPT:-0}"; then
    export_root="${EXPORT_DIR:-}"
    if [[ -z "$export_root" && -n "${DEST:-}" ]]; then
      export_root="${DEST}/encrypted"
    fi
    export_snapshot_encrypted "${SNAP_DIR}" "${STACK_ID}" "${export_root}"
  fi
}

prepare_restore_from_arg() {
  local path="$1"
  RESTORE_TMP_DIR=""
  if [[ -f "$path" ]]; then
    case "$path" in
      *.tar.gz|*.tgz|*.tar.xz|*.txz|*.zip|*.tar.age|*.age|*.tar.gz.age|*.tar.xz.age|*.tgz.age|*.txz.age)
        RESTORE_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/johnycsf-restore.XXXXXX")"
        chmod 700 "$RESTORE_TMP_DIR"
        extract_archive_to_dir "$path" "$RESTORE_TMP_DIR" >/dev/null
        printf '%s\n' "$RESTORE_TMP_DIR"
        return 0
        ;;
    esac
  fi
  printf '%s\n' "$path"
}

cleanup_restore_tmp() {
  if [[ -n "${RESTORE_TMP_DIR:-}" && -d "${RESTORE_TMP_DIR}" ]]; then
    rm -rf "${RESTORE_TMP_DIR}"
    RESTORE_TMP_DIR=""
  fi
}
