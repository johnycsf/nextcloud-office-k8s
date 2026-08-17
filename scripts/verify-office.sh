#!/usr/bin/env bash
# Smoke-test Nextcloud <-> Collabora wiring. Exit 0 only if checks pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

need kubectl

FAIL=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*" >&2; FAIL=1; }

echo "=== Office verification ==="

if ! kubectl -n "$NS" get deploy nextcloud collabora db >/dev/null 2>&1; then
  fail "nextcloud/collabora/db Deployments not found in namespace ${NS}"
  exit 1
fi

kubectl -n "$NS" rollout status deployment/db --timeout=60s >/dev/null
kubectl -n "$NS" rollout status deployment/nextcloud --timeout=60s >/dev/null
kubectl -n "$NS" rollout status deployment/collabora --timeout=60s >/dev/null
pass "Deployments are rolled out (db + nextcloud + collabora)"

NC_HOST="${NEXTCLOUD_HOST:-$(wait_svc_address nextcloud)}"
COLLABORA_HOST="${COLLABORA_HOST:-$(wait_svc_address collabora)}"
COLLABORA_PUBLIC_URL="http://${COLLABORA_HOST}:9980"
COLLABORA_INTERNAL_URL="http://collabora.${NS}.svc.cluster.local:9980"
NC_URL="http://${NC_HOST}"
NC_CLUSTER_IP="$(kubectl -n "$NS" get svc nextcloud -o jsonpath='{.spec.clusterIP}')"

if nc_fetch "${COLLABORA_INTERNAL_URL}/hosting/discovery" | grep -q 'urlsrc'; then
  pass "Nextcloud pod can reach Collabora discovery (${COLLABORA_INTERNAL_URL})"
else
  fail "Nextcloud pod cannot reach Collabora discovery at ${COLLABORA_INTERNAL_URL}"
fi

if nc_fetch "${COLLABORA_PUBLIC_URL}/hosting/discovery" | grep -q 'urlsrc'; then
  pass "Collabora public discovery responds (${COLLABORA_PUBLIC_URL})"
else
  fail "Collabora public discovery failed at ${COLLABORA_PUBLIC_URL} (your browser must reach this URL)"
fi

VERIFY_POD="office-verify-${RANDOM}"
if kubectl -n "$NS" run "${VERIFY_POD}" --rm --restart=Never --image=curlimages/curl:8.5.0 \
  --overrides='{"spec":{"restartPolicy":"Never"}}' \
  --command -- curl -fsS --max-time 20 \
  --resolve "${NC_HOST}:80:${NC_CLUSTER_IP}" "${NC_URL}/status.php" \
  | grep -q 'installed'; then
  pass "Nextcloud is reachable the way Collabora will call it (${NC_HOST} -> ${NC_CLUSTER_IP})"
else
  fail "Nextcloud not reachable via ${NC_HOST}->${NC_CLUSTER_IP} (Collabora WOPI callbacks will fail)"
fi

if ! occ status 2>/dev/null | grep -q 'installed: true'; then
  fail "Nextcloud is not installed yet - finish the web wizard, then re-run configure-office.sh"
  exit 1
fi
pass "Nextcloud is installed"

DBTYPE="$(occ config:system:get dbtype 2>/dev/null || true)"
if [[ "${DBTYPE}" == "mysql" ]]; then
  pass "Database is MariaDB/MySQL (dbtype=${DBTYPE})"
else
  fail "Expected MariaDB/MySQL (dbtype=mysql), got: ${DBTYPE:-empty} - wipe PVCs and reinstall with MYSQL_* auto-config"
fi

if kubectl -n "$NS" get deploy db >/dev/null 2>&1; then
  kubectl -n "$NS" rollout status deployment/db --timeout=60s >/dev/null
  pass "MariaDB Deployment is rolled out"
else
  fail "MariaDB Deployment 'db' not found"
fi

if redis_deployed; then
  kubectl -n "$NS" rollout status deployment/redis --timeout=60s >/dev/null && pass "Redis Deployment is rolled out" || fail "Redis Deployment not ready"
  RH="$(kubectl -n "$NS" get deploy nextcloud -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="REDIS_HOST")]}{.value}{end}' 2>/dev/null || true)"
  if [[ "${RH}" == "redis" ]]; then
    pass "Nextcloud has REDIS_HOST=redis"
  else
    fail "Redis is deployed but Nextcloud REDIS_HOST is '${RH:-empty}'"
  fi
  RPOD="$(kubectl -n "$NS" get pod -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${RPOD}" ]] && kubectl -n "$NS" exec "${RPOD}" -- redis-cli ping 2>/dev/null | grep -q PONG; then
    pass "Redis responds to PING"
  else
    fail "Redis pod did not respond to PING"
  fi
else
  pass "Redis not deployed (optional; use ./manage.sh install --include-redis)"
fi

WOPI_URL="$(occ config:app:get richdocuments wopi_url 2>/dev/null || true)"
PUBLIC_WOPI="$(occ config:app:get richdocuments public_wopi_url 2>/dev/null || true)"

if [[ -n "${WOPI_URL}" ]]; then
  pass "richdocuments is configured"
else
  fail "richdocuments wopi_url is empty - run ./scripts/configure-office.sh"
fi

if [[ "${WOPI_URL}" == "${COLLABORA_INTERNAL_URL}" ]]; then
  pass "wopi_url is in-cluster (${WOPI_URL})"
else
  fail "wopi_url should be ${COLLABORA_INTERNAL_URL} (got: ${WOPI_URL:-empty})"
fi

if [[ "${PUBLIC_WOPI}" == "${COLLABORA_PUBLIC_URL}" ]]; then
  pass "public_wopi_url is browser-facing (${PUBLIC_WOPI})"
else
  fail "public_wopi_url should be ${COLLABORA_PUBLIC_URL} (got: ${PUBLIC_WOPI:-empty})"
fi

ENABLED_APPS="$(occ app:list --enabled 2>/dev/null || true)"
if printf '%s\n' "${ENABLED_APPS}" | grep -qi 'richdocumentscode'; then
  fail "Built-in richdocumentscode is enabled - prefer the external Collabora service in this repo"
else
  pass "Built-in richdocumentscode is not enabled"
fi

echo
if [[ "${FAIL}" -eq 0 ]]; then
  echo "All checks passed."
  echo "Manual check: open ${NC_URL} -> + New -> Document"
  exit 0
fi

echo "One or more checks failed." >&2
echo "Re-run: NEXTCLOUD_HOST=${NC_HOST} COLLABORA_HOST=${COLLABORA_HOST} ./scripts/configure-office.sh" >&2
exit 1
