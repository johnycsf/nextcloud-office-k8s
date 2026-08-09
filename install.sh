#!/usr/bin/env bash
# Install Nextcloud + Collabora Online (LibreOffice) on a k3s cluster with Longhorn.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need kubectl

if ! kubectl get storageclass longhorn >/dev/null 2>&1; then
  cat <<'EOF' >&2
Longhorn storage class not found.

Install Longhorn first (one-time, shared by these homelab apps):

  helm repo add longhorn https://charts.longhorn.io
  helm repo update
  helm install longhorn longhorn/longhorn \
    --namespace longhorn-system --create-namespace

Wait until pods are ready:

  kubectl -n longhorn-system get pod

Then re-run this script.
EOF
  exit 1
fi

echo "Applying Nextcloud + Collabora manifests..."
kubectl apply -f "${ROOT}/deploy.yaml"

echo "Waiting for Nextcloud to become ready (first start can take a few minutes)..."
kubectl -n nextcloud rollout status deployment/nextcloud --timeout=300s

echo "Waiting for Collabora (LibreOffice Online) to become ready..."
kubectl -n nextcloud rollout status deployment/collabora --timeout=300s

cat <<'EOF'

Pods are up.

Next steps:
  1. Open Nextcloud, accept the self-signed certificate warning, create your admin account
  2. This script will finish Office (LibreOffice/Collabora) setup automatically

EOF

# Resolve addresses for a clearer message before configure-office waits on the wizard
NC_IP="$(kubectl -n nextcloud get svc nextcloud -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -z "${NC_IP}" ]]; then
  NC_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
fi
echo "Nextcloud URL hint: https://${NC_IP}/"
echo

"${ROOT}/configure-office.sh"
