#!/usr/bin/env bash
# Wire Nextcloud → Collabora Online (LibreOffice) after the Nextcloud admin account exists.
# Docs:
#   https://docs.nextcloud.com/server/latest/admin_manual/office/example-docker.html
#   https://github.com/nextcloud/richdocuments/blob/main/docs/install.md
set -euo pipefail

NS=nextcloud

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need kubectl

escape_regex_dots() {
  # Collabora's domain= value is a regex; dots must be escaped.
  # shellcheck disable=SC2001
  printf '%s' "$1" | sed 's/\./\\\\./g'
}

svc_address() {
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
    if addr="$(svc_address "${name}")"; then
      printf '%s' "${addr}"
      return 0
    fi
    sleep 2
  done
  # k3s ServiceLB fallback: first node InternalIP
  kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

occ() {
  local pod
  pod="$(kubectl -n "$NS" get pod -l app=nextcloud -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n "$NS" exec "$pod" -- occ "$@"
}

echo "Waiting for Nextcloud and Collabora pods..."
kubectl -n "$NS" rollout status deployment/nextcloud --timeout=300s
kubectl -n "$NS" rollout status deployment/collabora --timeout=300s

NC_HOST="${NEXTCLOUD_HOST:-$(wait_svc_address nextcloud)}"
COLLABORA_HOST="${COLLABORA_HOST:-$(wait_svc_address collabora)}"

if [[ -z "${NC_HOST}" || -z "${COLLABORA_HOST}" ]]; then
  echo "Could not determine service addresses. Set them explicitly:" >&2
  echo "  NEXTCLOUD_HOST=192.168.1.50 COLLABORA_HOST=192.168.1.50 ./configure-office.sh" >&2
  exit 1
fi

NC_URL="https://${NC_HOST}"
# Collabora is exposed over HTTP on 9980 in this homelab layout (ssl.enable=false)
COLLABORA_URL="http://${COLLABORA_HOST}:9980"
DOMAIN_REGEX="$(escape_regex_dots "${NC_HOST}")"

echo "Nextcloud URL : ${NC_URL}"
echo "Collabora URL: ${COLLABORA_URL}"

echo "Updating Collabora allow-list for this Nextcloud host..."
kubectl -n "$NS" set env deployment/collabora \
  "aliasgroup1=${NC_URL}:443" \
  "domain=${DOMAIN_REGEX}"
kubectl -n "$NS" rollout status deployment/collabora --timeout=300s

echo "Waiting until Nextcloud setup wizard is finished (create your admin user in the browser)..."
echo "Open: ${NC_URL}"
for i in $(seq 1 180); do
  if occ status 2>/dev/null | grep -q 'installed: true'; then
    echo "Nextcloud is installed."
    break
  fi
  if [[ "$i" -eq 180 ]]; then
    echo "Timed out waiting for Nextcloud installation." >&2
    echo "Create the admin account at ${NC_URL}, then re-run: ./configure-office.sh" >&2
    exit 1
  fi
  sleep 5
done

echo "Configuring trusted domain / URL overrides..."
occ config:system:set trusted_domains 1 --value="${NC_HOST}" >/dev/null
occ config:system:set overwrite.cli.url --value="${NC_URL}" >/dev/null
occ config:system:set overwriteprotocol --value="https" >/dev/null
occ config:system:set allow_local_remote_servers --type=boolean --value=true >/dev/null

echo "Installing Nextcloud Office (richdocuments) and pointing it at Collabora..."
# Built-in CODE apps do not work on the LinuxServer image — keep them off.
occ app:disable richdocumentscode 2>/dev/null || true
occ app:disable richdocumentscode_arm64 2>/dev/null || true

if ! occ app:list 2>/dev/null | grep -q 'richdocuments'; then
  occ app:install richdocuments
fi
occ app:enable richdocuments

occ config:app:set richdocuments wopi_url --value="${COLLABORA_URL}"
occ config:app:set richdocuments public_wopi_url --value="${COLLABORA_URL}"
occ config:app:set richdocuments disable_certificate_verification --type=string --value="yes"
# Homelab: allow WOPI callbacks from cluster / LAN ranges
occ config:app:set richdocuments wopi_allowlist --value="0.0.0.0/0,::/0"

if occ richdocuments:activate-config >/dev/null 2>&1; then
  echo "richdocuments:activate-config OK"
else
  echo "Note: richdocuments:activate-config returned non-zero (often still OK on first run)."
fi

cat <<EOF

Office editing is configured (Collabora / LibreOffice Online).

Nextcloud:  ${NC_URL}
Collabora:  ${COLLABORA_URL}/hosting/discovery

In Nextcloud, try:  + New → Document / Spreadsheet / Presentation

If a document still fails to open:
  1. Confirm both URLs are reachable from your browser (not only from the cluster)
  2. Re-run this script after changing IPs/DNS:
       NEXTCLOUD_HOST=... COLLABORA_HOST=... ./configure-office.sh
  3. For a proper domain + HTTPS reverse proxy later, set those hosts to your DNS names

EOF
