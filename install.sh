#!/usr/bin/env bash
# Install Nextcloud on a k3s cluster with Longhorn storage.
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

echo "Applying Nextcloud manifests..."
kubectl apply -f "${ROOT}/deploy.yaml"

echo "Waiting for Nextcloud to become ready (first start can take a few minutes)..."
kubectl -n nextcloud rollout status deployment/nextcloud --timeout=300s

echo
echo "Nextcloud is installed."
echo "Get the service address with:"
echo "  kubectl -n nextcloud get svc nextcloud"
echo
echo "Open https://<EXTERNAL-IP>/ in your browser."
echo "Accept the self-signed certificate warning, then create your admin account."
echo
echo "If Nextcloud complains about an untrusted domain, add your IP/hostname"
echo "under Settings → Administration → Overview, or edit config.php as described"
echo "in the README."
