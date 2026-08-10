#!/usr/bin/env bash
# Shared helpers for nextcloud-office-k8s scripts.
# shellcheck shell=bash

NS="${NS:-nextcloud}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

escape_regex_dots() {
  # Collabora's domain= value is a regex; dots must be escaped.
  # shellcheck disable=SC2001
  printf '%s' "$1" | sed 's/\./\\\\./g'
}

svc_lb_address() {
  local name="$1"
  local ip host
  ip="$(kubectl -n "$NS" get svc "$name" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "${ip}" ]]; then
    printf '%s' "${ip}"
    return 0
  fi
  host="$(kubectl -n "$NS" get svc "$name" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    printf '%s' "${host}"
    return 0
  fi
  return 1
}

wait_svc_address() {
  local name="$1"
  local tries="${2:-60}"
  local addr=""
  for _ in $(seq 1 "${tries}"); do
    if addr="$(svc_lb_address "${name}")"; then
      printf '%s' "${addr}"
      return 0
    fi
    sleep 2
  done
  # a LoadBalancer implementation (e.g. k3s ServiceLB, MetalLB) often leaves EXTERNAL-IP empty briefly; node IP still works.
  kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

nextcloud_pod() {
  kubectl -n "$NS" get pod -l app=nextcloud -o jsonpath='{.items[0].metadata.name}'
}

collabora_pod() {
  kubectl -n "$NS" get pod -l app=collabora -o jsonpath='{.items[0].metadata.name}'
}

occ() {
  local pod
  pod="$(nextcloud_pod)"
  kubectl -n "$NS" exec "$pod" -- occ "$@"
}

require_longhorn() {
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
}
