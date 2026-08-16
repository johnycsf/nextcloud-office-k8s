#!/usr/bin/env bash
# Optional at-rest encryption for disaster-recovery exports (age).
# Sourced by backup.sh — keep local hardlink snapshots plaintext for --link-dest.
#
# Industry note: SHA256 (already used in SHA256SUMS) is integrity only.
# Confidentiality uses age (X25519 + ChaCha20-Poly1305). Prefer age over
# OpenSSL "enc" or casual GPG recipes for scripted backup exports.
#
# Env (optional, never put secrets on argv):
#   BACKUP_ENCRYPT=1
#   BACKUP_EXPORT_DIR=/path          # default: ${DEST}/encrypted
#   BACKUP_AGE_RECIPIENT=age1...|/path/to.pub   (repeat via multiple --age-recipient)
#   BACKUP_AGE_IDENTITY=/path/to/keys.txt
#   BACKUP_AGE_PASSPHRASE_FILE=/path  # 0600 file with passphrase (passphrase mode)

# Optional defaults (backup.sh may override after source)
ENCRYPT="${ENCRYPT:-${BACKUP_ENCRYPT:-0}}"
EXPORT_DIR="${EXPORT_DIR:-${BACKUP_EXPORT_DIR:-}}"
ENCRYPT_PASSPHRASE="${ENCRYPT_PASSPHRASE:-0}"
AGE_IDENTITY="${AGE_IDENTITY:-${BACKUP_AGE_IDENTITY:-}}"
AGE_PASSPHRASE_FILE="${AGE_PASSPHRASE_FILE:-${BACKUP_AGE_PASSPHRASE_FILE:-}}"
if ! declare -p AGE_RECIPIENTS >/dev/null 2>&1; then
  AGE_RECIPIENTS=()
fi

need_age() {
  if command -v age >/dev/null 2>&1; then
    return 0
  fi
  if declare -F _deps_ensure_cmd >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    _deps_ensure_cmd age || true
  fi
  command -v age >/dev/null 2>&1 || {
    echo "Missing: age (needed for encrypted backup exports)." >&2
    echo "Install: dnf/apt/pacman/brew package 'age', then re-run." >&2
    exit 1
  }
}

_backup_encrypt_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

_age_identity_default() {
  printf '%s\n' "${HOME}/.config/johnycsf/backup.age.key"
}

ensure_backup_age_identity() {
  # Creates a local age identity if missing; prints the public recipient once.
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
  # Builds age -r args into global array AGE_R_ARGS
  AGE_R_ARGS=()
  local r
  if [[ ${#AGE_RECIPIENTS[@]} -gt 0 ]]; then
    for r in "${AGE_RECIPIENTS[@]}"; do
      [[ -n "$r" ]] || continue
      if [[ -f "$r" ]]; then
        AGE_R_ARGS+=(-R "$r")
      else
        AGE_R_ARGS+=(-r "$r")
      fi
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
  # Default: encrypt to the local johnycsf backup identity
  ensure_backup_age_identity
  local pub
  pub="$(age-keygen -y "${AGE_IDENTITY}")"
  AGE_R_ARGS+=(-r "$pub")
}

export_snapshot_encrypted() {
  # export_snapshot_encrypted SNAP_DIR STACK_ID [EXPORT_ROOT]
  local snap="$1"
  local stack_id="$2"
  local export_root="${3:-}"
  local stamp name partial out tmpdir
  need_age
  need tar

  [[ -d "$snap" ]] || { echo "Snapshot not found: $snap" >&2; return 1; }
  stamp="$(basename "$snap")"
  if [[ -z "$export_root" ]]; then
    # Prefer sibling of snapshots/: DEST/encrypted
    export_root="$(cd "$(dirname "$snap")/.." && pwd)/encrypted"
  fi
  mkdir -p "$export_root"
  chmod 700 "$export_root" 2>/dev/null || true
  name="${stack_id}-${stamp}.tar.age"
  partial="${export_root}/${name}.partial"
  out="${export_root}/${name}"
  rm -f "$partial"

  _append_age_recipient_args

  echo "==> Encrypting offsite export with age -> ${out}"
  echo "    Local hardlink snapshot stays plaintext for incremental backups / update rollback."
  umask 077
  # Stream tar into age — no plaintext tar left on disk.
  local enc_ok=0
  if [[ "${ENCRYPT_PASSPHRASE:-0}" == "1" ]]; then
    # Symmetric passphrase (TTY prompts from age -p)
    if tar -C "$snap" -cf - . | age -p >"$partial"; then
      enc_ok=1
    fi
  else
    _append_age_recipient_args
    if tar -C "$snap" -cf - . | age "${AGE_R_ARGS[@]}" >"$partial"; then
      enc_ok=1
    fi
  fi
  if [[ "$enc_ok" -ne 1 ]]; then
    rm -f "$partial"
    echo "age encryption failed." >&2
    return 1
  fi
  mv -f "$partial" "$out"
  chmod 600 "$out" 2>/dev/null || true

  local export_sha=""
  if command -v sha256sum >/dev/null 2>&1; then
    export_sha="$(sha256sum "$out" | awk '{print $1}')"
  fi
  {
    echo "encrypted_export=age"
    echo "encrypted_file=${out}"
    [[ -n "$export_sha" ]] && echo "encrypted_sha256=${export_sha}"
  } >>"${snap}/META.txt"

  echo "Encrypted export OK: ${out}"
  [[ -n "$export_sha" ]] && echo "encrypted_sha256=${export_sha}"
  echo "Reminder: losing the age identity/passphrase means this export cannot be restored."
}

decrypt_age_export_to_dir() {
  # decrypt_age_export_to_dir ARCHIVE OUT_DIR
  local archive="$1"
  local out="$2"
  local id="${AGE_IDENTITY:-}"
  need_age
  need tar
  mkdir -p "$out"
  chmod 700 "$out" 2>/dev/null || true

  if [[ -z "$id" ]]; then
    id="$(_age_identity_default)"
  fi

  echo "==> Decrypting age export: $archive" >&2
  umask 077
  if [[ -f "$id" ]]; then
    age -d -i "$id" "$archive" | tar -C "$out" -xf -
  else
    echo "No identity at ${id}; prompting for passphrase (age -d)..." >&2
    age -d "$archive" | tar -C "$out" -xf -
  fi
  [[ -f "${out}/META.txt" ]] || {
    echo "Decrypted archive missing META.txt — not a johnycsf snapshot export?" >&2
    return 1
  }
  printf '%s\n' "$(cd "$out" && pwd)"
}

maybe_encrypt_after_seal() {
  # Call after seal_snapshot; DEST and SNAP_DIR / STACK_ID expected in caller scope.
  if ! _backup_encrypt_truthy "${ENCRYPT:-0}"; then
    return 0
  fi
  local export_root="${EXPORT_DIR:-}"
  if [[ -z "$export_root" && -n "${DEST:-}" ]]; then
    export_root="${DEST}/encrypted"
  fi
  export_snapshot_encrypted "${SNAP_DIR}" "${STACK_ID}" "${export_root}"
}

prepare_restore_from_arg() {
  # Echoes a usable snapshot directory. Decrypts *.tar.age / *.age into a temp dir.
  # Sets global RESTORE_TMP_DIR if decryption happened (caller should trap-clean).
  local path="$1"
  RESTORE_TMP_DIR=""
  if [[ -f "$path" && "$path" == *.age ]]; then
    need_age
    RESTORE_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/johnycsf-restore.XXXXXX")"
    chmod 700 "$RESTORE_TMP_DIR"
    decrypt_age_export_to_dir "$path" "$RESTORE_TMP_DIR" >/dev/null
    printf '%s\n' "$RESTORE_TMP_DIR"
    return 0
  fi
  printf '%s\n' "$path"
}

cleanup_restore_tmp() {
  if [[ -n "${RESTORE_TMP_DIR:-}" && -d "${RESTORE_TMP_DIR}" ]]; then
    rm -rf "${RESTORE_TMP_DIR}"
    RESTORE_TMP_DIR=""
  fi
}
