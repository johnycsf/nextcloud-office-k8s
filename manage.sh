#!/usr/bin/env bash
# Control center for Nextcloud + Office (Kubernetes) — install, update, backup, status, uninstall.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# shellcheck source=scripts/deps.sh
source "${ROOT}/scripts/deps.sh"

TITLE="Nextcloud + Office"
NS="nextcloud"
CMD="${1:-}"
shift || true

usage() {
  cat <<EOF
${UI_BOLD}${TITLE} · manage.sh${UI_RESET} (namespace: ${NS})

Usage:
  ./manage.sh                 Interactive menu
  ./manage.sh install         Install / reconfigure (storage + replicas)
  ./manage.sh update          Safe update (pre-backup)
  ./manage.sh backup [args]   Pass-through to scripts/backup.sh
  ./manage.sh status|doctor   Health check
  ./manage.sh uninstall       Interactive uninstall
  ./manage.sh features        Show differentiators
  ./manage.sh help            This help

Non-interactive install example:
  STORAGE_CLASS=longhorn REPLICAS=1 ./manage.sh install

Tip: most people only need ${UI_BOLD}./manage.sh${UI_RESET}
EOF
}

case "${CMD}" in
  ""|menu) manage_menu_k8s "$TITLE" "$NS" ;;
  install) exec "${ROOT}/scripts/install.sh" "$@" ;;
  update) exec "${ROOT}/scripts/update.sh" "$@" ;;
  backup) exec "${ROOT}/scripts/backup.sh" "$@" ;;
  status|doctor) doctor_k8s "$TITLE" "$NS" ;;
  uninstall) uninstall_k8s_stack "$TITLE" "$NS" ;;
  features) ui_banner "$TITLE" "Features"; print_homelab_features ;;
  help|-h|--help) usage ;;
  *) ui_err "Unknown command: ${CMD}"; usage; exit 1 ;;
esac
