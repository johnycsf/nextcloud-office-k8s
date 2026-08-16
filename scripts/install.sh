#!/usr/bin/env bash
# Install / reconfigure Nextcloud + Collabora + MariaDB on Kubernetes (interactive).
# Optional: ./manage.sh install --include-redis
# Re-run anytime to change StorageClass preference or Nextcloud replica count.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/deps.sh
source "${ROOT}/scripts/deps.sh"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

parse_install_args "$@"
if [[ "${SHOW_HELP}" -eq 1 ]]; then
  print_install_help
  exit 0
fi

ui_banner "Nextcloud + Office" "Kubernetes · MariaDB + Collabora · storage + replicas"
ui_steps_init 6

ui_step "Checking host dependencies"
ensure_host_deps k8s

ui_step "StorageClass"
configure_k8s_storage

ui_step "Replica count (nextcloud)"
configure_k8s_replicas nextcloud

refuse_legacy_nextcloud_cluster

ui_step "Namespace + database Secret"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: nextcloud
EOF
ensure_db_secret
ui_ok "Namespace/Secret ready"

ui_step "Applying manifests"
ui_run "core manifests" apply_manifest "${ROOT}/deploy.yaml"
ui_run "MariaDB ready" kubectl -n nextcloud rollout status deployment/db --timeout=300s
apply_optional_redis

apply_saved_replicas nextcloud

ui_step "Waiting for app pods"
ui_run "Nextcloud" kubectl -n nextcloud rollout status deployment/nextcloud --timeout=300s
ui_run "Collabora" kubectl -n nextcloud rollout status deployment/collabora --timeout=600s

NC_IP="$(svc_lb_address nextcloud || true)"
if [[ -z "${NC_IP}" ]]; then
  NC_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
fi

REDIS_NOTE="Redis skipped (re-run with --include-redis to enable)."
if redis_deployed; then
  REDIS_NOTE="Redis is enabled (REDIS_HOST=redis)."
fi

echo
ui_ok "Pods are up (replicas=${CHOSEN_REPLICAS:-1}, storage=${CHOSEN_STORAGE_CLASS:-})"
ui_info "${REDIS_NOTE}"
ui_info "Open: ${UI_BOLD}http://${NC_IP}/${UI_RESET}"
ui_info "Re-run ./manage.sh anytime to change replicas or storage preference"
echo
ui_info "Finishing Office (Collabora) setup…"
"${ROOT}/scripts/configure-office.sh"
