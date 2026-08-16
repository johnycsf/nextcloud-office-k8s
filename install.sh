#!/usr/bin/env bash
# Install Nextcloud + Collabora Online (LibreOffice) + MariaDB on Kubernetes with Longhorn.
# Optional: ./install.sh --include-redis
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deps.sh
source "${ROOT}/deps.sh"
# shellcheck source=lib.sh
source "${ROOT}/lib.sh"

parse_install_args "$@"
if [[ "${SHOW_HELP}" -eq 1 ]]; then
  print_install_help
  exit 0
fi

ensure_host_deps k8s
configure_k8s_storage

refuse_legacy_nextcloud_cluster

echo "Ensuring namespace + MariaDB Secret exist..."
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: nextcloud
EOF

ensure_db_secret

echo "Applying Nextcloud + MariaDB + Collabora manifests..."
apply_manifest "${ROOT}/deploy.yaml"

echo "Waiting for MariaDB to become ready..."
kubectl -n nextcloud rollout status deployment/db --timeout=300s

apply_optional_redis

echo "Waiting for Nextcloud to become ready (first start can take a few minutes)..."
kubectl -n nextcloud rollout status deployment/nextcloud --timeout=300s

echo "Waiting for Collabora (LibreOffice Online) to become ready (image is large)..."
kubectl -n nextcloud rollout status deployment/collabora --timeout=600s

NC_IP="$(svc_lb_address nextcloud || true)"
if [[ -z "${NC_IP}" ]]; then
  NC_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
fi

REDIS_NOTE="Redis skipped (re-run with --include-redis to enable)."
if redis_deployed; then
  REDIS_NOTE="Redis is enabled (REDIS_HOST=redis)."
fi

cat <<EOF

Pods are up (MariaDB + Nextcloud + Collabora).
${REDIS_NOTE}

Next steps:
  1. Open Nextcloud and create your admin account (database is already configured):
       http://${NC_IP}/
  2. This script will finish Office (LibreOffice/Collabora) setup and verify connectivity

EOF

"${ROOT}/configure-office.sh"
