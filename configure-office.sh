#!/usr/bin/env bash
# Wire Nextcloud → Collabora Online (LibreOffice) after the Nextcloud admin account exists.
# Docs:
#   https://docs.nextcloud.com/server/latest/admin_manual/office/example-docker.html
#   https://github.com/nextcloud/richdocuments/blob/main/docs/install.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/lib.sh"

need kubectl

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
# Browser-facing Collabora URL (must be reachable from your PC)
COLLABORA_PUBLIC_URL="http://${COLLABORA_HOST}:9980"
# In-cluster Collabora URL (avoids hairpin NAT when Nextcloud talks to Collabora)
COLLABORA_INTERNAL_URL="http://collabora.${NS}.svc.cluster.local:9980"
DOMAIN_REGEX="$(escape_regex_dots "${NC_HOST}")"
NC_CLUSTER_IP="$(kubectl -n "$NS" get svc nextcloud -o jsonpath='{.spec.clusterIP}')"

echo "Nextcloud URL           : ${NC_URL}"
echo "Collabora (browser)    : ${COLLABORA_PUBLIC_URL}"
echo "Collabora (in-cluster) : ${COLLABORA_INTERNAL_URL}"
echo "Nextcloud ClusterIP     : ${NC_CLUSTER_IP}"

echo "Updating Collabora for this Nextcloud host..."
# hostAliases: Collabora must reach the *public* Nextcloud host/IP. On many home
# routers, pod → LAN-IP hairpin NAT fails; map the public host to ClusterIP instead.
kubectl -n "$NS" patch deployment collabora --type=strategic -p "{
  \"spec\": {
    \"template\": {
      \"spec\": {
        \"hostAliases\": [
          {
            \"ip\": \"${NC_CLUSTER_IP}\",
            \"hostnames\": [\"${NC_HOST}\"]
          }
        ]
      }
    }
  }
}"

kubectl -n "$NS" set env deployment/collabora \
  "aliasgroup1=${NC_URL}:443" \
  "domain=${DOMAIN_REGEX}" \
  "server_name=${COLLABORA_HOST}:9980"

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

# Install is idempotent enough for homelab use; ignore "already installed".
occ app:install richdocuments 2>/dev/null || true
occ app:enable richdocuments

# Split URLs: Nextcloud server uses in-cluster DNS; browsers use the LoadBalancer.
occ config:app:set richdocuments wopi_url --value="${COLLABORA_INTERNAL_URL}"
occ config:app:set richdocuments public_wopi_url --value="${COLLABORA_PUBLIC_URL}"
occ config:app:set richdocuments disable_certificate_verification --type=string --value="yes"
# Homelab: allow WOPI callbacks from cluster / LAN ranges
occ config:app:set richdocuments wopi_allowlist --value="0.0.0.0/0,::/0"

if occ richdocuments:activate-config >/dev/null 2>&1; then
  echo "richdocuments:activate-config OK"
else
  echo "Note: richdocuments:activate-config returned non-zero (often still OK on first run)."
fi

echo
echo "Running connectivity checks..."
"${ROOT}/verify-office.sh" || {
  echo
  echo "configure-office.sh finished, but verify-office.sh reported problems." >&2
  echo "See the messages above before testing in the browser." >&2
  exit 1
}

cat <<EOF

Office editing is configured (Collabora / LibreOffice Online).

Nextcloud:  ${NC_URL}
Collabora:  ${COLLABORA_PUBLIC_URL}/hosting/discovery

In Nextcloud, try:  + New → Document / Spreadsheet / Presentation

EOF
