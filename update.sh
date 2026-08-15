#!/usr/bin/env bash
# Safely update Nextcloud + MariaDB + Collabora (+ Redis if present) on Kubernetes.
# Safe to run while the stack is live. Does NOT wipe PVCs or regenerate DB passwords.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/lib.sh"

need kubectl
require_longhorn

if ! kubectl -n "$NS" get deploy nextcloud >/dev/null 2>&1; then
  echo "Nextcloud is not installed yet. Run ./install.sh first." >&2
  exit 1
fi

# Refuse LinuxServer / SQLite legacy stacks (same rules as install)
refuse_legacy_nextcloud_cluster

echo "==> Applying core manifests..."
kubectl apply -f "${ROOT}/deploy.yaml"

if redis_deployed; then
  echo "==> Redis is present — re-applying deploy-redis.yaml..."
  kubectl apply -f "${ROOT}/deploy-redis.yaml"
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
