#!/usr/bin/env bash
# Install Nextcloud + Collabora Online (LibreOffice) on a k3s cluster with Longhorn.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/lib.sh"

need kubectl
require_longhorn

echo "Applying Nextcloud + Collabora manifests..."
kubectl apply -f "${ROOT}/deploy.yaml"

echo "Waiting for Nextcloud to become ready (first start can take a few minutes)..."
kubectl -n nextcloud rollout status deployment/nextcloud --timeout=300s

echo "Waiting for Collabora (LibreOffice Online) to become ready (image is large)..."
kubectl -n nextcloud rollout status deployment/collabora --timeout=600s

NC_IP="$(svc_lb_address nextcloud || true)"
if [[ -z "${NC_IP}" ]]; then
  NC_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
fi

cat <<EOF

Pods are up.

Next steps:
  1. Open Nextcloud, accept the self-signed certificate warning, create your admin account:
       https://${NC_IP}/
  2. This script will finish Office (LibreOffice/Collabora) setup and verify connectivity

EOF

"${ROOT}/configure-office.sh"
