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
  # LoadBalancer implementations (k3s ServiceLB, MetalLB, etc.) may leave EXTERNAL-IP empty briefly.
  kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

nextcloud_pod() {
  kubectl -n "$NS" get pod -l app=nextcloud -o jsonpath='{.items[0].metadata.name}'
}

collabora_pod() {
  kubectl -n "$NS" get pod -l app=collabora -o jsonpath='{.items[0].metadata.name}'
}

# Official Nextcloud image: run occ as www-data via php
occ() {
  local pod
  pod="$(nextcloud_pod)"
  kubectl -n "$NS" exec -u www-data "$pod" -- php occ "$@"
}

# Fetch a URL from inside the Nextcloud container (official image may lack curl)
nc_fetch() {
  local url="$1"
  local pod
  pod="$(nextcloud_pod)"
  kubectl -n "$NS" exec "$pod" -- php -r 'echo @file_get_contents($argv[1]);' "$url"
}

require_longhorn() {
  # Back-compat alias - storage is chosen at install time (.storage-class).
  require_storage_class
}

gen_password() {
  openssl rand -base64 32 | tr -d '\n/+=\n' | head -c 32
}

ensure_db_secret() {
  if kubectl -n "$NS" get secret nextcloud-db >/dev/null 2>&1; then
    echo "Using existing Secret nextcloud-db"
    return 0
  fi
  local user_pw root_pw
  user_pw="$(gen_password)"
  root_pw="$(gen_password)"
  kubectl -n "$NS" create secret generic nextcloud-db \
    --from-literal=MYSQL_DATABASE=nextcloud \
    --from-literal=MYSQL_USER=nextcloud \
    --from-literal=MYSQL_PASSWORD="${user_pw}" \
    --from-literal=MYSQL_ROOT_PASSWORD="${root_pw}"
  echo "Created Secret nextcloud-db with generated MariaDB passwords."
}

db_pod() {
  kubectl -n "$NS" get pod -l app=db -o jsonpath='{.items[0].metadata.name}'
}

parse_install_args() {
  WITH_REDIS=0
  SHOW_HELP=0
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --include-redis) WITH_REDIS=1 ;;
      -h|--help) SHOW_HELP=1 ;;
      *)
        echo "Unknown option: ${arg}" >&2
        echo "Usage: ./manage.sh install [--include-redis]" >&2
        exit 1
        ;;
    esac
  done
}

print_install_help() {
  cat <<'EOF'
Usage: ./manage.sh install [--include-redis]

  Interactive install asks whether to include Redis (arrow-key Yes/No).
  --include-redis   Skip the question and deploy official redis:alpine
                    (REDIS_HOST=redis on Nextcloud). MariaDB is always used.

Examples:
  ./manage.sh
  ./manage.sh install
  ./manage.sh install --include-redis
EOF
}

redis_deployed() {
  kubectl -n "$NS" get deploy redis >/dev/null 2>&1
}

ask_redis_preference() {
  # Interactive install asks; --include-redis forces on. Non-TTY keeps current
  # cluster state (no Redis unless already deployed).
  if [[ "${WITH_REDIS:-0}" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    return 0
  fi

  echo
  ui_info "Redis is optional. Nextcloud can use it for caching and file locking."
  local choice
  if redis_deployed; then
    ui_choose choice "Redis is already deployed. Keep it?" \
      "Yes - keep Redis" \
      "No - leave Redis as-is (does not uninstall)"
    case "${choice}" in
      Yes*) WITH_REDIS=1 ;;
    esac
    return 0
  fi
  ui_choose choice "Include Redis for Nextcloud caching and file locking?" \
    "Yes - deploy Redis" \
    "No - skip Redis"
  case "${choice}" in
    Yes*) WITH_REDIS=1 ;;
  esac
}

apply_optional_redis() {
  if [[ "${WITH_REDIS:-0}" -ne 1 ]]; then
    if redis_deployed; then
      echo "Redis Deployment already present - leaving it enabled."
      kubectl -n "$NS" set env deployment/nextcloud REDIS_HOST=redis >/dev/null
    else
      echo "Redis skipped."
    fi
    return 0
  fi

  echo "Applying optional Redis manifests..."
  if declare -F apply_manifest >/dev/null 2>&1; then
    apply_manifest "${ROOT}/deploy-redis.yaml"
  else
    kubectl apply -f "${ROOT}/deploy-redis.yaml"
  fi
  kubectl -n "$NS" rollout status deployment/redis --timeout=180s
  kubectl -n "$NS" set env deployment/nextcloud REDIS_HOST=redis
  echo "Redis enabled (REDIS_HOST=redis on Nextcloud)."
}

refuse_legacy_nextcloud_cluster() {
  if [[ "${I_UNDERSTAND_THIS_IS_A_FRESH_INSTALL:-}" == "yes" ]]; then
    echo "Override set: I_UNDERSTAND_THIS_IS_A_FRESH_INSTALL=yes - continuing."
    return 0
  fi
  if ! kubectl -n "$NS" get deploy nextcloud >/dev/null 2>&1; then
    return 0
  fi
  local img reason=""
  img="$(kubectl -n "$NS" get deploy nextcloud -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ "${img}" == *linuxserver* ]] || [[ "${img}" == *lscr.io* ]]; then
    reason="Nextcloud Deployment still uses LinuxServer image (${img})"
  fi
  if kubectl -n "$NS" get deploy nextcloud >/dev/null 2>&1 && ! kubectl -n "$NS" get deploy db >/dev/null 2>&1; then
    # Installed before MariaDB was added - likely SQLite
    if occ status 2>/dev/null | grep -q 'installed: true'; then
      local dbtype
      dbtype="$(occ config:system:get dbtype 2>/dev/null || true)"
      if [[ "${dbtype}" == "sqlite" || -z "${dbtype}" ]]; then
        reason="existing Nextcloud without MariaDB Deployment (dbtype=${dbtype:-unknown})"
      fi
    else
      reason="Nextcloud Deployment exists but MariaDB Deployment 'db' is missing"
    fi
  fi
  if kubectl -n "$NS" get deploy db >/dev/null 2>&1; then
    if occ status 2>/dev/null | grep -q 'installed: true'; then
      local dbtype
      dbtype="$(occ config:system:get dbtype 2>/dev/null || true)"
      if [[ "${dbtype}" == "sqlite" ]]; then
        reason="Nextcloud is installed with SQLite while MariaDB manifests are present"
      fi
    fi
  fi
  if [[ -n "${reason}" ]]; then
    cat <<EOF >&2
Refusing to continue: ${reason}.

git pull alone is safe. Re-applying current manifests is NOT an automatic
SQLite->MariaDB or LinuxServer->official migration.

See BREAKING-CHANGES.md

Options:
  1) Leave the cluster as-is.
  2) Backup, delete the nextcloud namespace/PVCs, install fresh.
  3) Only if you accept a fresh install:
       I_UNDERSTAND_THIS_IS_A_FRESH_INSTALL=yes ./manage.sh install
EOF
    exit 1
  fi
}

