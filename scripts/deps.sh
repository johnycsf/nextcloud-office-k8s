#!/usr/bin/env bash
# Host dependency helper - sourced by install.sh in johnycsf homelab app repos.
# Detects the OS/package manager and installs missing binaries (with sudo when needed).
# shellcheck shell=bash

# Usage from install.sh:
#   # shellcheck source=scripts/deps.sh
#   source "${ROOT}/scripts/deps.sh"
#   ensure_host_deps docker          # docker stacks
#   ensure_host_deps k8s             # kubernetes stacks
#   ensure_host_deps heimdall-k8s    # k8s + local image build (docker|podman)


# --- Pretty terminal UI (colors, steps, prompts) ---
_ui_setup() {
  if [[ -t 1 && "${NO_COLOR:-}" != "1" ]]; then
    UI_RESET=$'[0m'
    UI_BOLD=$'[1m'
    UI_DIM=$'[2m'
    # Soft pastel palette - standard for johnycsf interactive install / manage UIs
    if [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* || "${TERM:-}" == *-direct ]]; then
      UI_RED=$'[38;2;243;139;168m'     # rose
      UI_GREEN=$'[38;2;166;227;161m'   # green
      UI_YELLOW=$'[38;2;249;226;175m'  # yellow
      UI_BLUE=$'[38;2;137;180;250m'    # blue
      UI_MAGENTA=$'[38;2;203;166;247m' # mauve
      UI_CYAN=$'[38;2;137;220;235m'    # sky
      UI_WHITE=$'[38;2;205;214;244m'   # text
      UI_PEACH=$'[38;2;250;179;135m'
      UI_TEAL=$'[38;2;148;226;213m'
      UI_PINK=$'[38;2;245;194;231m'
    else
      # 256-color pastel approximations
      UI_RED=$'[38;5;211m'
      UI_GREEN=$'[38;5;151m'
      UI_YELLOW=$'[38;5;223m'
      UI_BLUE=$'[38;5;117m'
      UI_MAGENTA=$'[38;5;183m'
      UI_CYAN=$'[38;5;116m'
      UI_WHITE=$'[38;5;189m'
      UI_PEACH=$'[38;5;216m'
      UI_TEAL=$'[38;5;152m'
      UI_PINK=$'[38;5;218m'
    fi
  else
    UI_RESET= UI_BOLD= UI_DIM=
    UI_RED= UI_GREEN= UI_YELLOW= UI_BLUE= UI_MAGENTA= UI_CYAN= UI_WHITE=
    UI_PEACH= UI_TEAL= UI_PINK=
  fi
  UI_STEP_N=0
  UI_STEP_TOTAL=0
}
_ui_setup

# Displayed glyphs are built from escapes so this file stays pure ASCII.
# Literal UTF-8 here has been silently rewritten as cp1252 more than once,
# which destroys these characters and ships broken output to users.
UI_SYM_HLINE=$'\u2550'     # BOX DRAWINGS DOUBLE HORIZONTAL
UI_SYM_STEP=$'\u25b8'      # BLACK RIGHT-POINTING SMALL TRIANGLE
UI_SYM_INFO=$'\u2139'      # INFORMATION SOURCE
UI_SYM_OK=$'\u2714'        # HEAVY CHECK MARK
UI_SYM_WARN=$'\u26a0'      # WARNING SIGN
UI_SYM_ERR=$'\u2716'       # HEAVY MULTIPLICATION X
UI_SYM_BULLET=$'\u2022'    # BULLET
UI_SYM_DOT=$'\u00b7'       # MIDDLE DOT
UI_SYM_ELLIPSIS=$'\u2026'  # HORIZONTAL ELLIPSIS
UI_SYM_UP=$'\u2191'        # UPWARDS ARROW
UI_SYM_DOWN=$'\u2193'      # DOWNWARDS ARROW
UI_SYM_GE=$'\u2265'        # GREATER-THAN OR EQUAL TO

ui_banner() {
  local title="$1"
  local subtitle="${2:-}"
  local line
  line="$(printf "${UI_SYM_HLINE}%.0s" {1..56})"
  echo
  echo "${UI_CYAN}${UI_BOLD}${line}${UI_RESET}"
  echo "${UI_CYAN}${UI_BOLD}  ${title}${UI_RESET}"
  if [[ -n "${subtitle}" ]]; then
    echo "${UI_DIM}  ${subtitle}${UI_RESET}"
  fi
  echo "${UI_CYAN}${UI_BOLD}${line}${UI_RESET}"
  echo
}

ui_steps_init() { UI_STEP_N=0; UI_STEP_TOTAL="${1:-0}"; }

ui_step() {
  local msg="$1"
  UI_STEP_N=$((UI_STEP_N + 1))
  if [[ "${UI_STEP_TOTAL}" -gt 0 ]]; then
    echo "${UI_BLUE}${UI_BOLD}${UI_SYM_STEP} Step ${UI_STEP_N}/${UI_STEP_TOTAL}${UI_RESET}  ${UI_BOLD}${msg}${UI_RESET}"
  else
    echo "${UI_BLUE}${UI_BOLD}${UI_SYM_STEP}${UI_RESET} ${UI_BOLD}${msg}${UI_RESET}"
  fi
}

ui_info() { echo "${UI_CYAN}${UI_SYM_INFO}${UI_RESET} $*"; }
ui_ok() { echo "${UI_GREEN}${UI_SYM_OK}${UI_RESET} $*"; }
ui_warn() { echo "${UI_YELLOW}${UI_SYM_WARN}${UI_RESET} $*" >&2; }
ui_err() { echo "${UI_RED}${UI_SYM_ERR}${UI_RESET} $*" >&2; }

ui_ask() {
  # ui_ask VAR "Prompt" "default"
  local __var="$1" __prompt="$2" __def="${3:-}" __ans
  if [[ ! -t 0 ]]; then
    printf -v "${__var}" '%s' "${__def}"
    return 0
  fi
  if [[ -n "${__def}" ]]; then
    read -r -p "$(printf '%s [%s]: ' "${__prompt}" "${__def}")" __ans || true
    __ans="${__ans:-$__def}"
  else
    read -r -p "$(printf '%s: ' "${__prompt}")" __ans || true
  fi
  printf -v "${__var}" '%s' "${__ans}"
}

ui_ask_yn() {
  # ui_ask_yn VAR "Prompt" y|n
  local __var="$1" __prompt="$2" __def="${3:-y}" __ans __hint
  if [[ "${__def}" == "y" ]]; then __hint="Y/n"; else __hint="y/N"; fi
  if [[ ! -t 0 ]]; then
    printf -v "${__var}" '%s' "${__def}"
    return 0
  fi
  read -r -p "$(printf '%s (%s): ' "${__prompt}" "${__hint}")" __ans || true
  __ans="$(printf '%s' "${__ans:-$__def}" | tr '[:upper:]' '[:lower:]')"
  case "${__ans}" in
    y|yes) printf -v "${__var}" '%s' y ;;
    n|no) printf -v "${__var}" '%s' n ;;
    *) printf -v "${__var}" '%s' "${__def}" ;;
  esac
}

ui_ask_int() {
  # ui_ask_int VAR "Prompt" default min max
  local __var="$1" __prompt="$2" __def="${3:-1}" __min="${4:-1}" __max="${5:-50}" __ans
  while true; do
    if [[ ! -t 0 ]]; then
      __ans="${__def}"
    else
      read -r -p "$(printf '%s [%s]: ' "${__prompt}" "${__def}")" __ans || true
      __ans="${__ans:-$__def}"
    fi
    if [[ "${__ans}" =~ ^[0-9]+$ ]] && (( __ans >= __min && __ans <= __max )); then
      printf -v "${__var}" '%s' "${__ans}"
      return 0
    fi
    ui_warn "Enter a number between ${__min} and ${__max}."
    [[ -t 0 ]] || { printf -v "${__var}" '%s' "${__def}"; return 0; }
  done
}

ui_run() {
  # ui_run [--stream] "Label" cmd...
  # Default: hide command output until done/fail (keeps menus tidy).
  # --stream: show live stdout/stderr (use for long pulls/builds).
  local stream=0
  if [[ "${1:-}" == "--stream" ]]; then
    stream=1
    shift
  fi
  local label="$1"
  shift
  local logfile status
  if [[ "${stream}" -eq 1 ]]; then
    echo "${UI_DIM}${UI_SYM_ELLIPSIS}${UI_RESET} ${label}"
    ui_info "Showing live progress (large images can take several minutes)${UI_SYM_ELLIPSIS}"
    set +e
    "$@"
    status=$?
    set -e
    if [[ "${status}" -eq 0 ]]; then
      ui_ok "${label} done"
      return 0
    fi
    ui_err "${label} failed"
    return "${status}"
  fi
  logfile="$(mktemp)"
  echo -n "${UI_DIM}${UI_SYM_ELLIPSIS}${UI_RESET} ${label} "
  set +e
  "$@" >"${logfile}" 2>&1
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    echo "${UI_GREEN}done${UI_RESET}"
    rm -f "${logfile}"
    return 0
  fi
  echo "${UI_RED}failed${UI_RESET}"
  ui_err "${label} failed - last output:"
  tail -n 40 "${logfile}" >&2 || true
  rm -f "${logfile}"
  return "${status}"
}



# --- Native arrow-key menus ---

ui_choose() {
  # ui_choose VAR "Header" "Option A" "Option B" ...
  # Terminal: Up/Down (or j/k) to move, Enter to select. Cursor is ">".
  # Digits 1-9 jump/select when they match an option index.
  # Non-TTY: picks the first option.
  local __var="$1" __header="$2"
  shift 2
  local -a __opts=("$@")
  local __idx=0 __n __key __key2 __key3 __i __lines __stty=""

  if [[ ${#__opts[@]} -lt 1 ]]; then
    echo "ui_choose: need at least one option" >&2
    return 1
  fi
  __n=${#__opts[@]}

  if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
    printf -v "${__var}" '%s' "${__opts[0]}"
    return 0
  fi

  _ui_choose_render() {
    local i
    printf '%s%s%s\n' "${UI_BOLD}" "${__header}" "${UI_RESET}"
    printf "%s  ${UI_SYM_UP}/${UI_SYM_DOWN} or j/k ${UI_SYM_DOT} Enter to select%s\n" "${UI_DIM}" "${UI_RESET}"
    for i in "${!__opts[@]}"; do
      if ((i == __idx)); then
        printf '  %s>%s %s%s%s\n' "${UI_GREEN}" "${UI_RESET}" "${UI_BOLD}" "${__opts[i]}" "${UI_RESET}"
      else
        printf '    %s\n' "${__opts[i]}"
      fi
    done
  }

  __lines=$((2 + __n))
  __stty="$(stty -g 2>/dev/null || true)"
  tput civis 2>/dev/null || true
  stty -echo -icanon time 0 min 1 2>/dev/null || stty -echo -icanon 2>/dev/null || true

  _ui_choose_restore() {
    [[ -n "${__stty}" ]] && stty "${__stty}" 2>/dev/null || true
    tput cnorm 2>/dev/null || true
  }

  echo
  _ui_choose_render
  while true; do
    IFS= read -r -n 1 __key || true
    case "${__key}" in
      "") # Enter (newline often read as empty with -n 1)
        break
        ;;
      $'\n' | $'\r')
        break
        ;;
      $'\x1b')
        __key2="" __key3=""
        IFS= read -r -n 1 -t 0.05 __key2 || true
        IFS= read -r -n 1 -t 0.05 __key3 || true
        case "${__key2}${__key3}" in
          "[A" | "OA") ((__idx > 0)) && ((__idx--)) || true ;;
          "[B" | "OB") ((__idx < __n - 1)) && ((__idx++)) || true ;;
        esac
        ;;
      k | K)
        ((__idx > 0)) && ((__idx--)) || true
        ;;
      j | J)
        ((__idx < __n - 1)) && ((__idx++)) || true
        ;;
      q | Q)
        _ui_choose_restore
        echo
        return 1
        ;;
      [1-9])
        if ((__key >= 1 && __key <= __n)); then
          __idx=$((__key - 1))
          break
        fi
        ;;
    esac
    printf '\033[%dA' "${__lines}"
    _ui_choose_render
  done

  _ui_choose_restore
  printf -v "${__var}" '%s' "${__opts[__idx]}"
  printf '\n  %s>%s %s\n' "${UI_GREEN}" "${UI_RESET}" "${__opts[__idx]}"
  return 0
}

# --- Host port selection / conflict checks (docker publishes) ---

env_file_get() {
  # env_file_get KEY [default] [file]
  local key="$1" def="${2:-}" file="${3:-.env}"
  if [[ -f "${file}" ]] && grep -qE "^${key}=" "${file}"; then
    grep -E "^${key}=" "${file}" | head -1 | cut -d= -f2-
  else
    printf '%s\n' "${def}"
  fi
}

env_file_set() {
  # env_file_set KEY value [file]
  local key="$1" val="$2" file="${3:-.env}"
  if [[ ! -f "${file}" ]]; then
    printf '%s=%s\n' "${key}" "${val}" >"${file}"
    return 0
  fi
  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${val}" >>"${file}"
  fi
}

host_tcp_port_in_use() {
  local port="$1"
  {
    ss -H -ltn 2>/dev/null || true
    ss -H -lun 2>/dev/null || true
  } | awk '{print $4}' | awk -F: '{print $NF}' | grep -qx "${port}"
}

this_compose_publishes_port() {
  local port="$1"
  # Uses remembered CONTAINER_ENGINE via compose(); no hard docker requirement.
  compose ps --format '{{.Ports}}' 2>/dev/null \
    | grep -E "(^|[, ])([0-9.]+|\[::\]|\*|0\.0\.0\.0):${port}->" >/dev/null 2>&1
}

port_conflict_with_others() {
  # True if something else on the host already owns this port (not this compose project).
  local port="$1"
  if this_compose_publishes_port "${port}"; then
    return 1
  fi
  host_tcp_port_in_use "${port}"
}



# --- Cross-stack host port registry --------------------------------------
# Default host ports are kept unique across the johnycsf stacks so several can
# be installed on one host without fighting over a port:
#   heimdall-docker          HTTP_PORT       8080
#   vaultwarden-docker       PORT            8081
#   nextcloud-office-docker  NEXTCLOUD_PORT  8082
#   nextcloud-office-docker  COLLABORA_PORT  9980
#   immich-docker            IMMICH_PORT     2283
_STACK_PORT_ENV_KEYS=(HTTP_PORT PORT IMMICH_PORT NEXTCLOUD_PORT COLLABORA_PORT)

sibling_stack_claiming_port() {
  # sibling_stack_claiming_port PORT
  # Echo "<dir> (<KEY>)" when another stack checked out beside this one already
  # claims PORT in its .env. Catches stacks that are installed but stopped,
  # which a listening-socket check cannot see.
  local port="$1" parent d k v
  [[ -n "${port}" ]] || return 1
  parent="$(dirname "${ROOT}")"
  [[ -d "${parent}" ]] || return 1
  for d in "${parent}"/*/; do
    d="${d%/}"
    [[ "${d}" != "${ROOT}" ]] || continue
    [[ -f "${d}/manage.sh" && -f "${d}/.env" ]] || continue
    for k in "${_STACK_PORT_ENV_KEYS[@]}"; do
      v="$(env_file_get "${k}" "" "${d}/.env")"
      if [[ -n "${v}" && "${v}" == "${port}" ]]; then
        printf '%s (%s)\n' "$(basename "${d}")" "${k}"
        return 0
      fi
    done
  done
  return 1
}

next_free_host_port() {
  # next_free_host_port START - first port that is neither listening nor claimed
  # by a sibling stack. Uses the cheap socket check (not compose ps) so the scan
  # stays fast.
  local p="$1" limit
  [[ "${p}" =~ ^[0-9]+$ ]] || return 1
  limit=$(( p + 200 ))
  while (( p <= limit && p <= 65535 )); do
    if ! host_tcp_port_in_use "${p}" && ! sibling_stack_claiming_port "${p}" >/dev/null; then
      printf '%s\n' "${p}"
      return 0
    fi
    p=$(( p + 1 ))
  done
  printf '%s\n' "$1"
  return 1
}

_ufw_status_text() {
  # ufw status needs root on most systems. Try unprivileged first, then a
  # non-interactive sudo, so detection never blocks on a password prompt.
  local out
  out="$(ufw status 2>/dev/null || true)"
  if [[ -z "${out}" ]] && command -v sudo >/dev/null 2>&1; then
    out="$(sudo -n ufw status 2>/dev/null || true)"
  fi
  printf '%s\n' "${out}"
}

host_firewall_backend() {
  # Echo the active host firewall: firewalld | ufw | unknown | none
  # "unknown" means a firewall is installed but its state could not be read.
  local state
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    printf 'firewalld\n'
    return 0
  fi
  if command -v ufw >/dev/null 2>&1; then
    state="$(_ufw_status_text)"
    if [[ "${state}" == *"Status: active"* ]]; then
      printf 'ufw\n'
      return 0
    fi
    if [[ -z "${state}" ]]; then
      printf 'unknown\n'
      return 0
    fi
  fi
  printf 'none\n'
}

_firewall_open_firewalld() {
  local port="$1"
  if firewall-cmd --quiet --query-port="${port}/tcp" 2>/dev/null; then
    ui_ok "firewalld already allows ${port}/tcp"
    return 0
  fi
  echo "==> Opening firewalld port ${port}/tcp for LAN access..."
  if command -v sudo >/dev/null 2>&1 \
    && sudo firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 \
    && sudo firewall-cmd --reload >/dev/null 2>&1; then
    ui_ok "firewalld: ${port}/tcp open"
    return 0
  fi
  ui_warn "Could not open firewalld ${port}/tcp - LAN access may fail."
  ui_info "Run: sudo firewall-cmd --permanent --add-port=${port}/tcp && sudo firewall-cmd --reload"
}

_firewall_open_ufw() {
  local port="$1" rules
  rules="$(_ufw_status_text)"
  # Anchored match: a plain substring test would see 80/tcp inside 8080/tcp.
  if grep -qE "(^|[[:space:]])${port}/tcp([[:space:]]|\$)" <<<"${rules}"; then
    ui_ok "ufw already allows ${port}/tcp"
    return 0
  fi
  echo "==> Opening ufw port ${port}/tcp for LAN access..."
  if command -v sudo >/dev/null 2>&1 && sudo ufw allow "${port}/tcp" >/dev/null 2>&1; then
    ui_ok "ufw: ${port}/tcp open"
    return 0
  fi
  ui_warn "Could not open ufw ${port}/tcp - LAN access may fail."
  ui_info "Run: sudo ufw allow ${port}/tcp"
}

ensure_host_firewall_tcp_port() {
  # Open the TCP port on whichever host firewall is active. Rootless Podman does
  # not auto-open host firewall ports the way Docker often does - without this
  # the app is healthy on localhost while LAN browsers get "no route to host",
  # which reads as a failed install.
  local port="$1"
  [[ -n "${port}" ]] || return 0
  local backend
  backend="$(host_firewall_backend)"
  case "${backend}" in
    firewalld)
      _firewall_open_firewalld "${port}"
      ;;
    ufw)
      _firewall_open_ufw "${port}"
      ;;
    unknown)
      ui_warn "ufw is installed but its status could not be read without a password."
      ui_info "If ${port} is unreachable from other machines: sudo ufw allow ${port}/tcp"
      ;;
    *)
      # No higher-level firewall detected. Try to open the port directly via nft or iptables.
      ui_info "No firewalld/ufw detected - attempting to open ${port}/tcp via nft/iptables (may require sudo)."
      if command -v nft >/dev/null 2>&1; then
        ui_info "Attempting: sudo nft add rule inet filter input tcp dport ${port} accept"
        if sudo nft add rule inet filter input tcp dport "${port}" accept >/dev/null 2>&1; then
          ui_ok "Opened ${port}/tcp via nft (temporary)."
          return 0
        fi
      fi
      if command -v iptables >/dev/null 2>&1; then
        ui_info "Attempting: sudo iptables -I INPUT -p tcp --dport ${port} -j ACCEPT"
        if sudo iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1; then
          ui_ok "Opened ${port}/tcp via iptables (temporary)."
          return 0
        fi
      fi
      ui_warn "Could not open ${port}/tcp automatically - LAN access may fail."
      ui_info "Run: sudo firewall-cmd --permanent --add-port=${port}/tcp && sudo firewall-cmd --reload  OR sudo ufw allow ${port}/tcp"
      ;;
  esac
  return 0
}


unprivileged_port_start() {
  # Lowest TCP port a non-root process may bind (sysctl; usually 1024).
  local n
  n="$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || true)"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=1024
  printf '%s\n' "${n}"
}

rootless_podman_bind_restricted() {
  # Rootless Podman cannot publish host ports below unprivileged_port_start.
  load_container_engine
  [[ "${CONTAINER_ENGINE}" == podman ]] || return 1
  [[ "${EUID}" -ne 0 ]] || return 1
  return 0
}

port_is_privileged() {
  local port="$1" start
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  start="$(unprivileged_port_start)"
  (( port < start ))
}

suggest_unprivileged_port() {
  # Map common privileged defaults to well-known high ports.
  local port="$1" start suggested
  start="$(unprivileged_port_start)"
  case "${port}" in
    80) suggested=8080 ;;
    443) suggested=8443 ;;
    *) suggested="${port}" ;;
  esac
  if [[ "${suggested}" =~ ^[0-9]+$ ]] && (( suggested < start )); then
    suggested="${start}"
  fi
  printf '%s\n' "${suggested}"
}

adjust_port_for_rootless_podman() {
  # Echo a usable host port; warn if we remapped a privileged default.
  local port="$1" label="$2" suggested
  if ! rootless_podman_bind_restricted; then
    printf '%s\n' "${port}"
    return 0
  fi
  if ! port_is_privileged "${port}"; then
    printf '%s\n' "${port}"
    return 0
  fi
  suggested="$(suggest_unprivileged_port "${port}")"
  ui_warn "Rootless Podman cannot publish host port ${port} (need >= $(unprivileged_port_start))."
  # stdout is this function's return channel, so the notice must go to stderr or
  # the caller captures the message text as the port number.
  ui_info "Using ${suggested} for ${label}. Pick another high port if that is taken." >&2
  printf '%s\n' "${suggested}"
}

configure_host_port() {
  # configure_host_port ENV_KEY "Human label" default
  # Writes KEY=port into .env and exports KEY for the current shell.
  local key="$1" label="$2" default="$3"
  local current chosen keep min_port=1 start sibling

  load_container_engine
  current="$(env_file_get "${key}" "${default}")"
  [[ -n "${current}" ]] || current="${default}"
  current="$(adjust_port_for_rootless_podman "${current}" "${label}")"
  if sibling="$(sibling_stack_claiming_port "${current}")"; then
    ui_warn "Host port ${current} is already claimed by ${sibling}"
    current="$(next_free_host_port "${current}")"
    ui_info "Using ${current} for ${label} instead."
  fi
  default="${current}"
  if rootless_podman_bind_restricted; then
    start="$(unprivileged_port_start)"
    min_port="${start}"
  fi

  if [[ "${SKIP_PORT_PROMPTS:-}" == "1" ]] || [[ ! -t 0 ]]; then
    if rootless_podman_bind_restricted && port_is_privileged "${current}"; then
      ui_err "Host port ${current} (${label} / ${key}) is below ${min_port}; rootless Podman cannot bind it."
      ui_info "Set ${key} to a free port >= ${min_port} in .env, or re-run interactively."
      return 1
    fi
    if port_conflict_with_others "${current}"; then
      ui_err "Host port ${current} (${label} / ${key}) is already in use"
      ui_info "Free the port, set ${key} to a free value in .env, or re-run interactively."
      if [[ "${FORCE_PORT_IN_USE:-}" == "1" ]]; then
        ui_warn "FORCE_PORT_IN_USE=1 - continuing anyway"
      else
        return 1
      fi
    else
      ui_ok "${label}: host port ${current}"
    fi
    env_file_set "${key}" "${current}"
    printf -v "${key}" '%s' "${current}"
    export "${key?}"
    ensure_host_firewall_tcp_port "${current}"
    return 0
  fi

  echo
  ui_info "${label} - host port (default ${current})"
  ui_choose keep "Host port for ${label}"     "Use default/current (${current})"     "Choose a different port"
  if [[ "${keep}" == Use* ]]; then
    chosen="${current}"
  else
    ui_ask_int chosen "Enter host port for ${label}" "${current}" "${min_port}" 65535
  fi

  while true; do
    if rootless_podman_bind_restricted && port_is_privileged "${chosen}"; then
      ui_warn "Rootless Podman cannot bind port ${chosen} (need >= ${min_port})"
      ui_ask_int chosen "Pick a host port >= ${min_port} for ${label}" "$(suggest_unprivileged_port "${chosen}")" "${min_port}" 65535
      continue
    fi
    if sibling="$(sibling_stack_claiming_port "${chosen}")"; then
      ui_warn "Port ${chosen} is already claimed by ${sibling}"
      ui_ask_int chosen "Pick a different host port for ${label}" "$(next_free_host_port "${chosen}")" "${min_port}" 65535
      continue
    fi
    if port_conflict_with_others "${chosen}"; then
      ui_warn "Port ${chosen} is already in use on this host"
      ui_ask_int chosen "Pick a different host port for ${label}" "$(next_free_host_port "${chosen}")" "${min_port}" 65535
      continue
    fi
    break
  done

  env_file_set "${key}" "${chosen}"
  printf -v "${key}" '%s' "${chosen}"
  export "${key?}"
  ui_ok "${label}: host port ${chosen} (saved to .env as ${key})"
  ensure_host_firewall_tcp_port "${chosen}"
}


ui_progress_wait() {
  # ui_progress_wait "Label" timeout_secs check_command...
  local label="$1" timeout="$2"
  shift 2
  local i=0 spin='|/-\' frame
  echo -n "${UI_DIM}${UI_SYM_ELLIPSIS}${UI_RESET} ${label} "
  while (( i < timeout )); do
    if "$@" >/dev/null 2>&1; then
      echo "${UI_GREEN}ready${UI_RESET}"
      return 0
    fi
    frame="${spin:i%4:1}"
    printf '\r%s %s %s ' "${UI_DIM}${UI_SYM_ELLIPSIS}${UI_RESET}" "${label}" "${UI_CYAN}${frame}${UI_RESET}"
    sleep 1
    i=$((i + 1))
  done
  printf '\r'
  echo "${UI_YELLOW}timeout${UI_RESET} - continuing anyway"
  return 1
}


_deps_have() { command -v "$1" >/dev/null 2>&1; }

_deps_run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif _deps_have sudo; then
    sudo "$@"
  else
    echo "Need root to install packages (install sudo, or re-run as root)." >&2
    return 1
  fi
}

_deps_detect_os() {
  # Sets: DEPS_OS_ID DEPS_OS_LIKE DEPS_PKG (apt|dnf|yum|pacman|zypper|apk|brew|unknown)
  DEPS_OS_ID=unknown
  DEPS_OS_LIKE=
  DEPS_PKG=unknown

  if [[ "$(uname -s)" == "Darwin" ]]; then
    DEPS_OS_ID=macos
    DEPS_OS_LIKE=macos
    if _deps_have brew; then
      DEPS_PKG=brew
    else
      DEPS_PKG=unknown
    fi
    return 0
  fi

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DEPS_OS_ID="${ID:-unknown}"
    DEPS_OS_LIKE="${ID_LIKE:-}"
  fi

  if _deps_have apt-get; then
    DEPS_PKG=apt
  elif _deps_have dnf; then
    DEPS_PKG=dnf
  elif _deps_have yum; then
    DEPS_PKG=yum
  elif _deps_have pacman; then
    DEPS_PKG=pacman
  elif _deps_have zypper; then
    DEPS_PKG=zypper
  elif _deps_have apk; then
    DEPS_PKG=apk
  fi
}

_deps_pkg_install() {
  # Install one or more distro packages. Ignores already-installed.
  [[ $# -gt 0 ]] || return 0
  _deps_detect_os
  echo "Installing packages via ${DEPS_PKG}: $*"
  case "${DEPS_PKG}" in
    apt)
      _deps_run_root apt-get update -y
      DEBIAN_FRONTEND=noninteractive _deps_run_root apt-get install -y "$@"
      ;;
    dnf)
      _deps_run_root dnf install -y "$@"
      ;;
    yum)
      _deps_run_root yum install -y "$@"
      ;;
    pacman)
      _deps_run_root pacman -Sy --noconfirm "$@"
      ;;
    zypper)
      _deps_run_root zypper --non-interactive install "$@"
      ;;
    apk)
      _deps_run_root apk add --no-cache "$@"
      ;;
    brew)
      brew install "$@"
      ;;
    *)
      echo "Unsupported OS/package manager - install manually: $*" >&2
      return 1
      ;;
  esac
}

# Map a command name to distro package name(s).
_deps_packages_for_cmd() {
  local cmd="$1"
  _deps_detect_os
  case "${cmd}" in
    curl)
      echo curl
      ;;
    openssl)
      case "${DEPS_PKG}" in
        apk) echo openssl ;;
        *) echo openssl ;;
      esac
      ;;
    rsync)
      echo rsync
      ;;
    age)
      echo age
      ;;
    zip)
      echo zip
      ;;
    unzip)
      echo unzip
      ;;
    xz)
      echo xz
      ;;
    tar)
      case "${DEPS_PKG}" in
        apt) echo tar ;;
        *) echo tar ;;
      esac
      ;;
    sha256sum)
      case "${DEPS_PKG}" in
        brew) echo coreutils ;;
        apt) echo coreutils ;;
        *) echo coreutils ;;
      esac
      ;;
    sqlite3)
      case "${DEPS_PKG}" in
        apt) echo sqlite3 ;;
        dnf|yum) echo sqlite ;;
        pacman) echo sqlite ;;
        zypper) echo sqlite3 ;;
        apk) echo sqlite ;;
        brew) echo sqlite ;;
        *) echo sqlite3 ;;
      esac
      ;;
    ca-certificates)
      case "${DEPS_PKG}" in
        brew) ;; # not needed as a brew formula for this flow
        *) echo ca-certificates ;;
      esac
      ;;
    kubectl)
      case "${DEPS_PKG}" in
        dnf|yum) echo kubernetes-client ;;
        pacman) echo kubectl ;;
        zypper) echo kubernetes-client ;;
        brew) echo kubectl ;;
        apt) echo kubectl ;; # may need kubernetes apt repo; fallback downloads binary
        *) echo kubectl ;;
      esac
      ;;
    helm)
      case "${DEPS_PKG}" in
        dnf|yum|pacman|zypper|brew|apt) echo helm ;;
        *) echo helm ;;
      esac
      ;;
    *)
      echo "${cmd}"
      ;;
  esac
}

_deps_ensure_cmd() {
  local cmd="$1"
  if _deps_have "${cmd}"; then
    return 0
  fi
  local pkgs
  pkgs="$(_deps_packages_for_cmd "${cmd}")"
  if [[ -z "${pkgs}" ]]; then
    return 0
  fi
  # shellcheck disable=SC2086
  if ! _deps_pkg_install ${pkgs}; then
    # kubectl/helm often missing from default apt - try official binaries
    if [[ "${cmd}" == "kubectl" ]]; then
      _deps_install_kubectl_binary || return 1
    elif [[ "${cmd}" == "helm" ]]; then
      _deps_install_helm_binary || return 1
    else
      return 1
    fi
  fi
  if ! _deps_have "${cmd}"; then
    if [[ "${cmd}" == "kubectl" ]]; then
      _deps_install_kubectl_binary || return 1
    elif [[ "${cmd}" == "helm" ]]; then
      _deps_install_helm_binary || return 1
    else
      echo "Installed packages for ${cmd}, but command still not on PATH." >&2
      return 1
    fi
  fi
}

_deps_install_kubectl_binary() {
  _deps_have kubectl && return 0
  _deps_ensure_cmd curl || true
  local arch ver url tmp
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l) arch=arm ;;
    *)
      echo "Unsupported arch for kubectl binary: ${arch}" >&2
      return 1
      ;;
  esac
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  url="https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    url="https://dl.k8s.io/release/${ver}/bin/darwin/${arch}/kubectl"
  fi
  tmp="$(mktemp)"
  echo "Downloading kubectl ${ver}..."
  curl -fsSL -o "${tmp}" "${url}"
  chmod +x "${tmp}"
  if [[ -w /usr/local/bin ]]; then
    mv "${tmp}" /usr/local/bin/kubectl
  else
    _deps_run_root mv "${tmp}" /usr/local/bin/kubectl
  fi
  _deps_have kubectl
}

_deps_install_helm_binary() {
  _deps_have helm && return 0
  _deps_ensure_cmd curl || true
  echo "Installing Helm via official get.helm.sh script..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  _deps_have helm
}


# --- Container engine (Docker | Podman) ---

_container_engine() {
  local eng="${CONTAINER_ENGINE:-}"
  if [[ -z "${eng}" && -f "${ROOT:-.}/.env" ]]; then
    eng="$(env_file_get CONTAINER_ENGINE "" "${ROOT:-.}/.env" 2>/dev/null || true)"
  fi
  case "${eng}" in
    podman|Podman|PODMAN) printf '%s\n' "podman" ;;
    *) printf '%s\n' "docker" ;;
  esac
}

compose_engine() {
  # Low-level compose runner for the selected engine.
  case "$(_container_engine)" in
    podman)
      # Prefer podman-compose (Podman-native). Plain `podman compose` often wraps
      # the docker-compose CLI plugin and prints a banner about docker.
      if command -v podman-compose >/dev/null 2>&1; then
        podman-compose "$@"
      elif podman compose version >/dev/null 2>&1; then
        # Still Podman socket; silence the external-provider warning.
        PODMAN_COMPOSE_WARNING_LOGS=false podman compose "$@"
      else
        echo "Podman Compose is required (podman-compose or podman compose)." >&2
        return 1
      fi
      ;;
    *)
      docker compose "$@"
      ;;
  esac
}

# Default wrapper - Nextcloud overrides this in lib.sh for Redis overlays.
compose() {
  compose_engine "$@"
}


load_container_engine() {
  # Read remembered engine from .env (set at install) into the current shell.
  CONTAINER_ENGINE="$(_container_engine)"
  export CONTAINER_ENGINE
}

container_engine_label() {
  # Human label for UI: Docker | Podman (from remembered CONTAINER_ENGINE).
  load_container_engine
  case "${CONTAINER_ENGINE}" in
    podman) printf '%s\n' "Podman" ;;
    *) printf '%s\n' "Docker" ;;
  esac
}

compose_stack_subtitle() {
  # compose_stack_subtitle "official images + Postgres"
  printf "%s Compose ${UI_SYM_DOT} %s\n" "$(container_engine_label)" "$1"
}


need_container_engine() {
  # Require the runtime matching CONTAINER_ENGINE in .env (not always docker).
  load_container_engine
  case "${CONTAINER_ENGINE}" in
    podman)
      if ! command -v podman >/dev/null 2>&1; then
        echo "Missing: podman (CONTAINER_ENGINE=podman in .env - re-run ./manage.sh install or install Podman)." >&2
        return 1
      fi
      _deps_ensure_podman_api >/dev/null 2>&1 || true
      if ! command -v podman-compose >/dev/null 2>&1 && ! podman compose version >/dev/null 2>&1; then
        echo "Missing: podman-compose (preferred) or podman compose." >&2
        return 1
      fi
      ;;
    *)
      if ! command -v docker >/dev/null 2>&1; then
        echo "Missing: docker (CONTAINER_ENGINE=docker in .env)." >&2
        return 1
      fi
      if ! docker compose version >/dev/null 2>&1; then
        echo "Missing: docker compose." >&2
        return 1
      fi
      ;;
  esac
}

container_image_prune() {
  load_container_engine
  case "${CONTAINER_ENGINE}" in
    podman) podman image prune -f "$@" ;;
    *) docker image prune -f "$@" ;;
  esac
}

# Host-side install choices that must survive restoring .env from a backup snapshot.
_HOST_INSTALL_ENV_KEYS=(CONTAINER_ENGINE IMMICH_PORT HTTP_PORT PORT NEXTCLOUD_PORT COLLABORA_PORT)

save_host_install_env() {
  _HOST_INSTALL_ENV_SAVED=()
  local k v
  for k in "${_HOST_INSTALL_ENV_KEYS[@]}"; do
    v="$(env_file_get "${k}" "" 2>/dev/null || true)"
    # Use if/fi - with set -e, a failing [[ ]] && ... aborts the script.
    if [[ -n "${v}" ]]; then
      _HOST_INSTALL_ENV_SAVED+=("${k}=${v}")
    fi
  done
}

apply_host_install_env() {
  # Re-apply saved host choices after a snapshot .env overwrite.
  local kv k v
  for kv in "${_HOST_INSTALL_ENV_SAVED[@]:-}"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    [[ -n "${k}" ]] || continue
    env_file_set "${k}" "${v}"
    printf -v "${k}" '%s' "${v}"
    export "${k?}"
  done
  load_container_engine
  if [[ "${#_HOST_INSTALL_ENV_SAVED[@]}" -gt 0 ]]; then
    echo "==> Preserved host install choices: ${_HOST_INSTALL_ENV_SAVED[*]}"
  fi
}



ensure_host_owned_dir() {
  # ensure_host_owned_dir DIR [DIR...]
  # Docker/Podman bind mounts are often created as root; make them writable for the
  # invoking user so backup/restore rsync from the host does not fail with EACCES.
  local d uid gid
  uid="$(id -u)"
  gid="$(id -g)"
  for d in "$@"; do
    [[ -n "${d}" ]] || continue
    mkdir -p "${d}"
    if [[ -O "${d}" ]] && [[ -w "${d}" ]]; then
      # Fast path: dir owned by us; still fix nested root-owned children if present.
      # -print -quit rather than `| head -1 | grep`: under pipefail the SIGPIPE
      # from head reads as "nothing found" and silently skips the chown.
      if [[ -z "$(find "${d}" -maxdepth 4 \( ! -user "${uid}" -o ! -writable \) -print -quit 2>/dev/null)" ]]; then
        continue
      fi
    fi
    if command -v sudo >/dev/null 2>&1; then
      echo "==> Fixing ownership on ${d} (container runtime may have created root-owned files)..."
      sudo chown -R "${uid}:${gid}" "${d}" || true
    else
      echo "Warning: ${d} may not be writable by $(id -un) and sudo is unavailable." >&2
    fi
  done
}


configure_container_engine() {
  # Prompt once (or keep existing). Writes CONTAINER_ENGINE into .env.
  local current choice
  if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then
      cp .env.example .env
    else
      touch .env
    fi
  fi
  current="$(env_file_get CONTAINER_ENGINE docker)"
  case "${current}" in
    podman|docker) ;;
    *) current=docker ;;
  esac

  if [[ "${SKIP_CONTAINER_ENGINE_PROMPT:-}" == "1" ]] || [[ ! -t 0 ]]; then
    env_file_set CONTAINER_ENGINE "${current}"
    CONTAINER_ENGINE="${current}"
    export CONTAINER_ENGINE
    return 0
  fi

  ui_choose choice "Container engine (currently: ${current})" \
    "Docker (Docker Engine + Compose)" \
    "Podman (rootless-friendly)"

  case "${choice}" in
    Podman*) CONTAINER_ENGINE=podman ;;
    *) CONTAINER_ENGINE=docker ;;
  esac

  env_file_set CONTAINER_ENGINE "${CONTAINER_ENGINE}"
  export CONTAINER_ENGINE
  ui_ok "Container engine: ${CONTAINER_ENGINE}"
  if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
    ui_info "Podman is typically rootless - prefer host ports ${UI_SYM_GE}1024 unless you configure privileges."
  fi
}

_deps_ensure_podman_api() {
  # docker-compose invoked via `podman compose` talks to the Podman API socket.
  # Rootless installs need the user socket (and often linger for SSH/non-login sessions).
  local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
  if [[ -S "${sock}" ]]; then
    return 0
  fi
  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || \
      sudo loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user enable --now podman.socket >/dev/null 2>&1 || true
  fi
  if [[ ! -S "${sock}" ]] && command -v podman >/dev/null 2>&1; then
    # Last resort: start API service in background for this session
    podman system service --time=0 "unix://${sock}" >/dev/null 2>&1 &
    sleep 1
  fi
  if [[ ! -S "${sock}" ]]; then
    echo "Podman API socket missing (${sock})." >&2
    echo "Try: systemctl --user enable --now podman.socket" >&2
    echo "And: loginctl enable-linger $(id -un)" >&2
    return 1
  fi
}

_deps_ensure_podman() {
  _deps_detect_os

  if ! _deps_have podman; then
    echo "Podman not found - installing..."
    case "${DEPS_PKG}" in
      dnf|yum)
        _deps_pkg_install podman podman-compose || _deps_pkg_install podman || true
        ;;
      apt)
        _deps_pkg_install podman podman-compose || _deps_pkg_install podman || true
        ;;
      pacman)
        _deps_pkg_install podman podman-compose || _deps_pkg_install podman || true
        ;;
      zypper)
        _deps_pkg_install podman podman-compose || true
        ;;
      apk)
        _deps_pkg_install podman || true
        ;;
      brew)
        _deps_pkg_install podman || true
        echo "On macOS, start the Podman machine: podman machine init && podman machine start" >&2
        ;;
      *)
        echo "Cannot auto-install Podman on this OS. Install podman + compose, then re-run." >&2
        return 1
        ;;
    esac
  fi

  if ! _deps_have podman; then
    echo "Podman install failed." >&2
    return 1
  fi

  if ! podman info >/dev/null 2>&1; then
    echo "Podman is installed but not usable yet (try: podman info)." >&2
    if [[ "$(uname -s)" == "Darwin" ]]; then
      echo "macOS: podman machine init && podman machine start" >&2
    fi
    return 1
  fi

  _deps_ensure_podman_api || return 1

  # Prefer the podman-compose package (avoids docker-compose plugin via `podman compose`).
  if ! _deps_have podman-compose; then
    echo "Installing podman-compose (Podman-native Compose)..."
    case "${DEPS_PKG}" in
      dnf|yum|apt|pacman|zypper) _deps_pkg_install podman-compose || true ;;
      pip|pip3) ;;
      *) ;;
    esac
  fi

  if ! _deps_have podman-compose && ! podman compose version >/dev/null 2>&1; then
    echo "podman-compose (preferred) or podman compose is required but not available." >&2
    return 1
  fi

  if _deps_have podman-compose; then
    echo "Using podman-compose for Compose under Podman."
  elif podman compose version >/dev/null 2>&1; then
    echo "podman-compose not installed - falling back to podman compose (may wrap docker-compose plugin; warnings silenced)."
  fi
}


_deps_docker_usable() {
  docker info >/dev/null 2>&1
}

_deps_wrap_docker_sudo() {
  # Current shell only - lets install continue without re-login after usermod.
  docker() { command sudo docker "$@"; }
  export -f docker
}

_deps_ensure_docker() {
  _deps_detect_os

  if ! _deps_have docker; then
    echo "Docker not found - installing..."
    case "${DEPS_PKG}" in
      apt)
        # Prefer distro packages (simple). Fall back to Docker's convenience script.
        if ! _deps_pkg_install docker.io docker-compose-v2; then
          _deps_pkg_install docker.io docker-compose-plugin || true
        fi
        if ! _deps_have docker; then
          echo "Falling back to get.docker.com..."
          curl -fsSL https://get.docker.com | _deps_run_root sh
        fi
        ;;
      dnf)
        _deps_pkg_install moby-engine docker-compose || _deps_pkg_install docker docker-compose
        ;;
      yum)
        _deps_pkg_install docker docker-compose || true
        if ! _deps_have docker; then
          curl -fsSL https://get.docker.com | _deps_run_root sh
        fi
        ;;
      pacman)
        _deps_pkg_install docker docker-compose
        ;;
      zypper)
        _deps_pkg_install docker docker-compose
        ;;
      apk)
        _deps_pkg_install docker docker-cli-compose
        ;;
      brew)
        _deps_pkg_install docker docker-compose
        echo "On macOS, start Docker Desktop (or Colima) before continuing." >&2
        ;;
      *)
        echo "Cannot auto-install Docker on this OS. Install Docker Engine + Compose, then re-run." >&2
        return 1
        ;;
    esac
  fi

  if ! _deps_have docker; then
    echo "Docker install failed." >&2
    return 1
  fi

  # Start service on systemd hosts
  if [[ "$(uname -s)" == "Linux" ]] && _deps_have systemctl; then
    _deps_run_root systemctl enable --now docker >/dev/null 2>&1 || \
      _deps_run_root systemctl start docker >/dev/null 2>&1 || true
  fi

  # Group membership for non-root use
  if [[ "$(uname -s)" == "Linux" ]] && [[ "${EUID}" -ne 0 ]]; then
    if getent group docker >/dev/null 2>&1; then
      if ! id -nG "${USER}" 2>/dev/null | grep -qw docker; then
        echo "Adding ${USER} to the docker group (one-time)..."
        _deps_run_root usermod -aG docker "${USER}" || true
      fi
    fi
  fi

  if _deps_docker_usable; then
    :
  elif _deps_have sudo && sudo docker info >/dev/null 2>&1; then
    echo "Docker works with sudo in this session (log out/in once to use docker without sudo)."
    _deps_wrap_docker_sudo
  else
    echo "Docker is installed but not usable yet. Try: sudo systemctl start docker" >&2
    echo "Or log out/in after being added to the docker group, then re-run ./manage.sh" >&2
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin missing - installing..."
    case "${DEPS_PKG}" in
      apt) _deps_pkg_install docker-compose-v2 || _deps_pkg_install docker-compose-plugin || true ;;
      dnf|yum) _deps_pkg_install docker-compose || true ;;
      pacman) _deps_pkg_install docker-compose || true ;;
      brew) _deps_pkg_install docker-compose || true ;;
      *) ;;
    esac
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "docker compose is required but not available." >&2
    return 1
  fi
}

_deps_ensure_container_builder() {
  if _deps_have docker || _deps_have podman; then
    if _deps_have docker; then
      _deps_ensure_docker || true
    fi
    return 0
  fi
  echo "Neither docker nor podman found - installing Docker for image builds..."
  _deps_ensure_docker
}

# --- Kubernetes storage selection (PVC StorageClass) ---
# Install prompts (or STORAGE_CLASS=name for non-interactive). Choice saved to .storage-class.

storage_class_file() {
  echo "${ROOT:-.}/.storage-class"
}

save_storage_class() {
  local sc="$1"
  printf '%s\n' "${sc}" >"$(storage_class_file)"
  echo "Saved storage choice: ${sc} ($(storage_class_file))"
}

load_storage_class() {
  local f sc
  f="$(storage_class_file)"
  if [[ -f "${f}" ]]; then
    sc="$(tr -d '[:space:]' <"${f}")"
    [[ -n "${sc}" ]] && { printf '%s' "${sc}"; return 0; }
  fi
  return 1
}

cluster_default_storage_class() {
  kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1
}

list_storage_classes() {
  kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

ensure_longhorn_storage() {
  if kubectl get storageclass longhorn >/dev/null 2>&1; then
    return 0
  fi
  _deps_ensure_cmd helm || return 1
  echo "Longhorn StorageClass not found - installing Longhorn (one-time cluster setup)..."
  helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
  helm repo update
  helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system --create-namespace --wait --timeout 15m
  echo "Waiting for Longhorn StorageClass..."
  local i
  for i in $(seq 1 60); do
    if kubectl get storageclass longhorn >/dev/null 2>&1; then
      echo "Longhorn is ready."
      return 0
    fi
    sleep 5
  done
  echo "Longhorn install did not expose StorageClass 'longhorn' in time." >&2
  echo "Check: kubectl -n longhorn-system get pod" >&2
  return 1
}

ensure_storage_class_ready() {
  local sc="$1"
  case "${sc}" in
    longhorn)
      ensure_longhorn_storage || return 1
      ;;
    *)
      if ! kubectl get storageclass "${sc}" >/dev/null 2>&1; then
        echo "StorageClass '${sc}' was not found in this cluster." >&2
        echo "Create it first, or re-run and pick Longhorn / another available class." >&2
        echo "Existing classes:" >&2
        list_storage_classes | sed 's/^/  - /' >&2 || true
        return 1
      fi
      ;;
  esac
  return 0
}

# Interactive (or STORAGE_CLASS=) picker. Sets CHOSEN_STORAGE_CLASS and saves .storage-class.
choose_storage_class() {
  local sc="" default_sc choice custom
  local -a existing=()

  if [[ -n "${STORAGE_CLASS:-}" ]]; then
    sc="${STORAGE_CLASS}"
    ui_info "Using StorageClass from STORAGE_CLASS=${sc}"
    ensure_storage_class_ready "${sc}" || return 1
    CHOSEN_STORAGE_CLASS="${sc}"
    save_storage_class "${sc}"
    return 0
  fi

  default_sc="$(cluster_default_storage_class || true)"
  existing=()
  while IFS= read -r _sc_line; do
    [[ -n "${_sc_line}" ]] && existing+=("${_sc_line}")
  done < <(list_storage_classes)

  if [[ ! -t 0 ]]; then
    sc="longhorn"
    echo "No TTY and STORAGE_CLASS unset - defaulting to Longhorn."
    ensure_storage_class_ready "${sc}" || return 1
    CHOSEN_STORAGE_CLASS="${sc}"
    save_storage_class "${sc}"
    return 0
  fi

  echo
  ui_info "Which Kubernetes storage should PersistentVolumeClaims use?"
  echo "  (You can also set STORAGE_CLASS=name for a non-interactive install.)"
  echo
  echo "  1) Longhorn          - replicated block storage (recommended; can auto-install)"
  if [[ -n "${default_sc}" ]]; then
    echo "  2) Cluster default   - currently: ${default_sc}"
  else
    echo "  2) Cluster default   - (no default StorageClass annotated on this cluster)"
  fi
  echo "  3) local-path        - typical for k3s single-node"
  echo "  4) Pick from classes already installed on this cluster"
  echo "  5) Type a custom StorageClass name"
  echo
  if ((${#existing[@]})); then
    echo "StorageClasses currently in the cluster:"
    local name
    for name in "${existing[@]}"; do
      if [[ "${name}" == "${default_sc}" ]]; then
        echo "  - ${name} (default)"
      else
        echo "  - ${name}"
      fi
    done
    echo
  else
    echo "No StorageClasses found yet (Longhorn install can create one)."
    echo
  fi

  read -r -p "Choice [1]: " choice
  choice="${choice:-1}"

  case "${choice}" in
    1)
      sc="longhorn"
      ;;
    2)
      if [[ -z "${default_sc}" ]]; then
        echo "No default StorageClass - pick another option or install a provisioner." >&2
        return 1
      fi
      sc="${default_sc}"
      ;;
    3)
      sc="local-path"
      ;;
    4)
      if ((${#existing[@]} == 0)); then
        echo "No StorageClasses to pick from." >&2
        return 1
      fi
      echo "Enter the exact StorageClass name from the list above:"
      read -r -p "StorageClass: " sc
      sc="$(printf '%s' "${sc}" | tr -d '[:space:]')"
      ;;
    5)
      read -r -p "Custom StorageClass name: " custom
      sc="$(printf '%s' "${custom}" | tr -d '[:space:]')"
      ;;
    *)
      echo "Invalid choice: ${choice}" >&2
      return 1
      ;;
  esac

  if [[ -z "${sc}" ]]; then
    echo "StorageClass name cannot be empty." >&2
    return 1
  fi

  ensure_storage_class_ready "${sc}" || return 1
  CHOSEN_STORAGE_CLASS="${sc}"
  save_storage_class "${sc}"
}

# Install entrypoint: prompt + ensure provisioner if needed (keeps prior choice on re-run).
configure_k8s_storage() {
  local keep sc
  if [[ -z "${STORAGE_CLASS:-}" ]] && sc="$(load_storage_class 2>/dev/null || true)" && [[ -n "${sc}" ]]; then
    ui_ask_yn keep "Keep current StorageClass '${sc}'?" y
    if [[ "${keep}" == "y" ]]; then
      ensure_storage_class_ready "${sc}" || return 1
      CHOSEN_STORAGE_CLASS="${sc}"
      ui_ok "StorageClass: ${sc}"
      return 0
    fi
  fi
  choose_storage_class || return 1
  ui_ok "PVCs will use StorageClass: ${CHOSEN_STORAGE_CLASS}"
}

# Update/backup entrypoint: reuse saved choice (or STORAGE_CLASS / prompt once).
require_storage_class() {
  local sc=""
  if [[ -n "${STORAGE_CLASS:-}" ]]; then
    sc="${STORAGE_CLASS}"
    save_storage_class "${sc}"
  elif sc="$(load_storage_class)"; then
    echo "Using saved StorageClass: ${sc}"
  else
    echo "No saved storage choice (.storage-class) - asking now..."
    choose_storage_class || return 1
    sc="${CHOSEN_STORAGE_CLASS}"
  fi
  ensure_storage_class_ready "${sc}" || return 1
  CHOSEN_STORAGE_CLASS="${sc}"
}

# Apply a manifest file with storageClassName rewritten to the chosen class.
apply_manifest() {
  local file="$1"
  local sc="${CHOSEN_STORAGE_CLASS:-}"
  [[ -n "${sc}" ]] || sc="$(load_storage_class || true)"
  [[ -n "${sc}" ]] || sc="${STORAGE_CLASS:-longhorn}"
  if [[ ! -f "${file}" ]]; then
    echo "Manifest not found: ${file}" >&2
    return 1
  fi
  # Only rewrite storageClassName lines (PVC templates in this repo).
  sed -E "s/^([[:space:]]*storageClassName:[[:space:]]*).*/\\1${sc}/" "${file}" | kubectl apply -f -
}


# --- Replica selection (Kubernetes app Deployments) ---
replicas_file() { echo "${ROOT:-.}/.replicas"; }

save_replicas() {
  local n="$1"
  printf '%s\n' "${n}" >"$(replicas_file)"
  ui_ok "Saved replica count: ${n} ($(replicas_file))"
}

load_replicas() {
  local f n
  f="$(replicas_file)"
  [[ -f "${f}" ]] || return 1
  n="$(tr -dc '0-9' <"${f}" || true)"
  [[ -n "${n}" ]] || return 1
  printf '%s' "${n}"
}

# Returns "namespace/deployment" for the user-facing scalable workload.
k8s_replica_target() {
  case "$1" in
    heimdall) echo "heimdall/heimdall" ;;
    vaultwarden) echo "vaultwarden/vaultwarden" ;;
    nextcloud) echo "nextcloud/nextcloud" ;;
    immich) echo "immich/immich-server" ;;
    *) return 1 ;;
  esac
}

k8s_replica_suggestion() {
  # suggested_count|reason
  case "$1" in
    heimdall)
      echo "1|Heimdall uses a local SQLite DB on a single PVC (RWO) - 1 replica is safest."
      ;;
    vaultwarden)
      echo "1|Vaultwarden uses SQLite on a single PVC (RWO) - 1 replica is safest."
      ;;
    nextcloud)
      echo "1|Nextcloud files PVC is typically RWO; start with 1. Only raise replicas if you know your storage supports multi-attach."
      ;;
    immich)
      echo "1|Immich library PVC is typically RWO; scale the API server carefully. DB/Redis/ML stay at 1."
      ;;
    *)
      echo "1|Default to 1 unless you know the app is safe to scale."
      ;;
  esac
}

current_deploy_replicas() {
  local ns="$1" deploy="$2"
  kubectl -n "${ns}" get deploy "${deploy}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true
}

# configure_k8s_replicas <profile>
# profile: heimdall|vaultwarden|nextcloud|immich
configure_k8s_replicas() {
  local profile="$1"
  local target ns deploy suggested reason cur def n warn
  target="$(k8s_replica_target "${profile}")" || {
    ui_err "Unknown replica profile: ${profile}"
    return 1
  }
  ns="${target%%/*}"
  deploy="${target##*/}"

  IFS='|' read -r suggested reason <<<"$(k8s_replica_suggestion "${profile}")"
  def="${suggested}"
  if cur="$(load_replicas 2>/dev/null || true)" && [[ -n "${cur}" ]]; then
    def="${cur}"
  fi
  cur="$(current_deploy_replicas "${ns}" "${deploy}" || true)"
  if [[ -n "${cur}" ]]; then
    def="${cur}"
  fi

  if [[ -n "${REPLICAS:-}" ]]; then
    n="${REPLICAS}"
    ui_info "Using REPLICAS=${n} from environment"
  else
    echo
    ui_info "Replica suggestion for ${profile}: ${UI_BOLD}${suggested}${UI_RESET}"
    ui_info "${reason}"
    ui_ask_int n "How many replicas for Deployment/${deploy}?" "${def}" 1 20
  fi

  if ! [[ "${n}" =~ ^[0-9]+$ ]] || (( n < 1 )); then
    ui_err "Invalid replica count: ${n}"
    return 1
  fi

  if (( n > 1 )); then
    ui_warn "Replicas > 1 with ReadWriteOnce storage can fail if pods land on different nodes."
    ui_ask_yn warn "Continue with ${n} replicas?" y
    [[ "${warn}" == "y" ]] || { ui_info "Keeping 1 replica."; n=1; }
  fi

  CHOSEN_REPLICAS="${n}"
  save_replicas "${n}"
}

apply_saved_replicas() {
  local profile="$1"
  local target ns deploy n
  target="$(k8s_replica_target "${profile}")" || return 1
  ns="${target%%/*}"
  deploy="${target##*/}"
  n="${CHOSEN_REPLICAS:-}"
  [[ -n "${n}" ]] || n="$(load_replicas || true)"
  [[ -n "${n}" ]] || n=1
  if ! kubectl -n "${ns}" get deploy "${deploy}" >/dev/null 2>&1; then
    ui_warn "Deployment ${ns}/${deploy} not found yet - skip scale"
    return 0
  fi
  ui_run "Scaling ${ns}/${deploy} to ${n} replica(s)" \
    kubectl -n "${ns}" scale deployment/"${deploy}" --replicas="${n}"
  CHOSEN_REPLICAS="${n}"
}


# ensure_host_deps <profile> [extra commands...]
# Profiles:
#   docker       - Docker Engine + Compose + common tools
#   k8s          - kubectl + helm + common tools
#   heimdall-k8s - k8s + docker|podman for local image build
ensure_host_deps() {
  local profile="${1:-}"
  shift || true
  local extras=("$@")

  _deps_detect_os
  ui_info "Host: ${DEPS_OS_ID} (package manager: ${DEPS_PKG})"

  # Always useful for HTTPS package/index fetches
  if [[ "${DEPS_PKG}" != "brew" ]] && ! _deps_have update-ca-certificates && [[ -f /etc/debian_version || -f /etc/fedora-release || -f /etc/redhat-release ]]; then
    _deps_pkg_install ca-certificates 2>/dev/null || true
  fi

  local base=(curl openssl rsync tar)
  local c
  for c in "${base[@]}"; do
    _deps_ensure_cmd "${c}" || {
      echo "Failed to ensure dependency: ${c}" >&2
      return 1
    }
  done

  # sha256sum comes from coreutils (usually present); ensure on macOS via brew coreutils
  if ! _deps_have sha256sum && ! _deps_have shasum; then
    _deps_ensure_cmd sha256sum || true
  fi

  case "${profile}" in
    docker)
      # Profile name is historical; engine comes from CONTAINER_ENGINE (.env).
      CONTAINER_ENGINE="$(_container_engine)"
      export CONTAINER_ENGINE
      case "${CONTAINER_ENGINE}" in
        podman) _deps_ensure_podman || return 1 ;;
        *) _deps_ensure_docker || return 1 ;;
      esac
      ;;
    k8s)
      _deps_ensure_cmd kubectl || return 1
      _deps_ensure_cmd helm || return 1
      ;;
    heimdall-k8s)
      _deps_ensure_cmd kubectl || return 1
      _deps_ensure_cmd helm || return 1
      _deps_ensure_container_builder || return 1
      ;;
    *)
      echo "ensure_host_deps: unknown profile '${profile}' (use docker|k8s|heimdall-k8s)" >&2
      return 1
      ;;
  esac

  for c in "${extras[@]}"; do
    [[ -n "${c}" ]] || continue
    _deps_ensure_cmd "${c}" || {
      echo "Failed to ensure dependency: ${c}" >&2
      return 1
    }
  done

  ui_ok "Host dependencies ready"
}


# --- Doctor / control-center helpers (feature-rich manage.sh) ---

print_homelab_features() {
  cat <<EOF
${UI_BOLD}What makes this stack different${UI_RESET}
  ${UI_GREEN}${UI_SYM_BULLET}${UI_RESET} Interactive install with colors, steps, and progress
  ${UI_GREEN}${UI_SYM_BULLET}${UI_RESET} Detects your OS and installs missing host tools (Docker/kubectl/helm/${UI_SYM_ELLIPSIS})
  ${UI_GREEN}${UI_SYM_BULLET}${UI_RESET} Kubernetes: choose StorageClass + replica count (re-run to change)
  ${UI_GREEN}${UI_SYM_BULLET}${UI_RESET} Docker or Podman at install (CONTAINER_ENGINE in .env) + host port checks
  ${UI_GREEN}${UI_SYM_BULLET}${UI_RESET} Safe updates with automatic pre-update backups
  ${UI_GREEN}${UI_SYM_BULLET}${UI_RESET} Incremental hardlink snapshots + restore (./manage.sh)
  ${UI_GREEN}${UI_SYM_BULLET}${UI_RESET} Official upstream images only (no random third-party app images)
  ${UI_GREEN}${UI_SYM_BULLET}${UI_RESET} Control center: ${UI_BOLD}./manage.sh${UI_RESET} (install / update / backup / status / uninstall)
EOF
}

doctor_docker() {
  local title="${1:-App}"
  load_container_engine
  ui_banner "${title}" "Doctor ${UI_SYM_DOT} $(container_engine_label) stack health"
  if [[ ! -f "${ROOT}/docker-compose.yml" && ! -f "${ROOT}/compose.yaml" ]]; then
    ui_err "No docker-compose.yml / compose.yaml in ${ROOT}"
    return 1
  fi


  ui_step "Published host ports (.env)"
  local _pk _pv
  for _pk in HTTP_PORT PORT IMMICH_PORT NEXTCLOUD_PORT COLLABORA_PORT; do
    _pv="$(env_file_get "${_pk}" "" "${ROOT}/.env" 2>/dev/null || true)"
    if [[ -n "${_pv}" ]]; then
      if port_conflict_with_others "${_pv}" 2>/dev/null; then
        ui_warn "${_pk}=${_pv} - in use by another process"
      else
        ui_ok "${_pk}=${_pv}"
      fi
    fi
  done

  ui_step "Compose services"
  if compose ps 2>/dev/null; then
    ui_ok "compose ps OK"
  else
    ui_warn "Could not query compose status (is the stack installed?)"
  fi

  echo
  ui_step "Disk (data/)"
  if [[ -d "${ROOT}/data" ]]; then
    du -sh "${ROOT}/data" 2>/dev/null || true
    df -h "${ROOT}/data" 2>/dev/null | tail -1 || true
    ui_ok "data/ present"
  else
    ui_warn "No data/ directory yet - run ./manage.sh first"
  fi

  echo
  ui_step "Backups"
  if [[ -d "${ROOT}/backups/snapshots" ]]; then
    local n
    n="$(ls -1d "${ROOT}/backups/snapshots"/* 2>/dev/null | wc -l | tr -d ' ')"
    ui_ok "Local snapshots: ${n}"
    ls -1dt "${ROOT}/backups/snapshots"/* 2>/dev/null | head -3 | sed 's/^/  /' || true
  else
    ui_info "No local backups/ yet - use ./manage.sh backup --dest /mnt/backup (creates /mnt/backup/<stack>/)"
  fi

  if [[ -f "${ROOT}/.env" ]]; then
    ui_ok ".env present"
  else
    ui_warn ".env missing"
  fi
  echo
  print_homelab_features
}

doctor_k8s() {
  local title="$1" ns="$2"
  ui_banner "${title}" "Doctor ${UI_SYM_DOT} Kubernetes health (ns=${ns})"
  if ! command -v kubectl >/dev/null 2>&1; then
    ui_err "kubectl not found"
    return 1
  fi

  ui_step "Cluster"
  kubectl cluster-info 2>/dev/null | head -3 || ui_warn "cluster-info failed"
  kubectl get nodes -o wide 2>/dev/null | head -5 || true

  echo
  ui_step "Namespace ${ns}"
  if kubectl get ns "${ns}" >/dev/null 2>&1; then
    kubectl -n "${ns}" get deploy,sts,svc,pvc 2>/dev/null || kubectl -n "${ns}" get all,pvc 2>/dev/null || true
    ui_ok "Namespace exists"
  else
    ui_warn "Namespace ${ns} not found - run ./manage.sh"
  fi

  echo
  ui_step "Saved install choices"
  if [[ -f "${ROOT}/.storage-class" ]]; then
    ui_ok "StorageClass: $(tr -d '[:space:]' <"${ROOT}/.storage-class")"
  else
    ui_info "No .storage-class yet"
  fi
  if [[ -f "${ROOT}/.replicas" ]]; then
    ui_ok "Replicas: $(tr -dc '0-9' <"${ROOT}/.replicas")"
  else
    ui_info "No .replicas yet"
  fi

  echo
  ui_step "Backups"
  if [[ -d "${ROOT}/backups/snapshots" ]]; then
    local n
    n="$(ls -1d "${ROOT}/backups/snapshots"/* 2>/dev/null | wc -l | tr -d ' ')"
    ui_ok "Local snapshots: ${n}"
  else
    ui_info "No local backups/ yet"
  fi
  echo
  print_homelab_features
}

confirm_destructive() {
  local phrase="$1"
  local typed
  ui_warn "This can delete running apps and/or data."
  ui_ask typed "Type ${phrase} to confirm" ""
  [[ "${typed}" == "${phrase}" ]]
}

uninstall_docker_stack() {
  local title="$1"
  load_container_engine
  ui_banner "${title}" "Uninstall ${UI_SYM_DOT} $(container_engine_label)"
  ui_warn "This stops containers. You choose whether to delete ./data"
  confirm_destructive "uninstall" || { ui_info "Cancelled."; return 1; }

  if [[ -f "${ROOT}/docker-compose.yml" || -f "${ROOT}/compose.yaml" ]]; then
    ui_run "compose down" compose down || true
  fi

  local wipe
  ui_ask_yn wipe "Also DELETE ./data (permanent)?" n
  if [[ "${wipe}" == "y" ]]; then
    confirm_destructive "delete-data" || { ui_info "Left data/ in place."; return 0; }
    if rm -rf "${ROOT}/data"; then
      ui_ok "Deleted ./data"
    else
      ui_warn "Failed to delete ./data due to permissions. Trying with sudo..."
      if command -v sudo >/dev/null 2>&1; then
        ui_info "You may be asked for your sudo password."
        if sudo rm -rf "${ROOT}/data"; then
          ui_ok "Deleted ./data (via sudo)"
        else
          ui_err "sudo rm failed; left ./data in place. Fix ownership or remove manually."
        fi
      else
        ui_err "sudo not available. Cannot delete ./data. Run: sudo rm -rf ${ROOT}/data"
      fi
    fi
  else
    ui_ok "Left ./data in place"
  fi
  ui_ok "Uninstall finished"
}

uninstall_k8s_stack() {
  local title="$1" ns="$2"
  ui_banner "${title}" "Uninstall ${UI_SYM_DOT} Kubernetes (ns=${ns})"
  ui_warn "This deletes the namespace workloads. PVCs/data may remain until you delete them."
  confirm_destructive "uninstall" || { ui_info "Cancelled."; return 1; }

  if [[ -f "${ROOT}/deploy.yaml" ]]; then
    # Best-effort delete of app resources; namespace deletion is optional
    kubectl delete -f "${ROOT}/deploy.yaml" --ignore-not-found >/dev/null 2>&1 || true
    if [[ -f "${ROOT}/deploy-redis.yaml" ]]; then
      kubectl delete -f "${ROOT}/deploy-redis.yaml" --ignore-not-found >/dev/null 2>&1 || true
    fi
  fi

  local wipe
  ui_ask_yn wipe "Also DELETE namespace ${ns} (removes PVCs in that namespace)?" n
  if [[ "${wipe}" == "y" ]]; then
    confirm_destructive "delete-namespace" || { ui_info "Left namespace in place."; return 0; }
    kubectl delete namespace "${ns}" --wait=false 2>/dev/null || true
    ui_ok "Namespace ${ns} delete requested"
  else
    ui_ok "Left namespace ${ns} / PVCs in place"
  fi
  ui_ok "Uninstall finished"
}


default_backup_dest() {
  # Prefer shared backup disk when mounted; stack id is appended later.
  if [[ -d /mnt/backup && -w /mnt/backup ]]; then
    printf '%s\n' "/mnt/backup"
  else
    printf '%s\n' "${ROOT}/backups"
  fi
}

resolve_stack_backup_dest() {
  # resolve_stack_backup_dest STACK_ID USER_PATH
  # Always use .../STACK_ID so multiple apps can share one --dest root tidy.
  local stack_id="$1" dest="$2"
  [[ -n "${stack_id}" && -n "${dest}" ]] || return 1
  dest="${dest%/}"
  if [[ "$(basename "${dest}")" == "${stack_id}" ]]; then
    printf '%s\n' "${dest}"
    return 0
  fi
  printf '%s\n' "${dest}/${stack_id}"
}

resolve_stack_backup_from() {
  # resolve_stack_backup_from STACK_ID USER_PATH
  # Accept parent root (/mnt/backup) or stack root (/mnt/backup/STACK_ID) or snapshot.
  local stack_id="$1" path="$2" nested
  [[ -n "${path}" ]] || return 1
  path="${path%/}"
  if [[ -e "${path}" ]]; then
    # Already a snapshot / stack backup root / archive
    if [[ -f "${path}/META.txt" || -L "${path}/latest" || -d "${path}/snapshots" || -f "${path}" ]]; then
      printf '%s\n' "${path}"
      return 0
    fi
  fi
  nested="${path}/${stack_id}"
  if [[ -d "${nested}" ]]; then
    printf '%s\n' "${nested}"
    return 0
  fi
  printf '%s\n' "${path}"
}

manage_menu_docker() {
  local title="$1" choice dest from
  load_container_engine
  ui_banner "${title}" "Control center ${UI_SYM_DOT} $(container_engine_label)"
  print_homelab_features
  echo
  ui_choose choice "What do you want to do?" \
    "Install / reconfigure" \
    "Update" \
    "Backup" \
    "Restore" \
    "Status / doctor" \
    "Uninstall" \
    "Exit"
  case "${choice}" in
    "Install / reconfigure") exec "${ROOT}/scripts/install.sh" ;;
    "Update") exec "${ROOT}/scripts/update.sh" ;;
    "Backup")
      ui_ask dest "Backup destination (stack folder created under this path)" "$(default_backup_dest)"
      exec "${ROOT}/scripts/backup.sh" --dest "${dest}"
      ;;
    "Restore")
      ui_ask from "Restore from (backup root, stack folder, snapshot, or archive)" "$(default_backup_dest)"
      exec "${ROOT}/scripts/backup.sh" --restore --from "${from}"
      ;;
    "Status / doctor") doctor_docker "${title}" ;;
    "Uninstall") uninstall_docker_stack "${title}" ;;
    *) ui_info "Bye." ;;
  esac
}


manage_menu_k8s() {
  local title="$1" ns="$2" choice dest from
  ui_banner "${title}" "Control center ${UI_SYM_DOT} Kubernetes"
  print_homelab_features
  echo
  ui_choose choice "What do you want to do?" \
    "Install / reconfigure (storage + replicas)" \
    "Update" \
    "Backup" \
    "Restore" \
    "Status / doctor" \
    "Uninstall" \
    "Exit"
  case "${choice}" in
    "Install / reconfigure (storage + replicas)") exec "${ROOT}/scripts/install.sh" ;;
    "Update") exec "${ROOT}/scripts/update.sh" ;;
    "Backup")
      ui_ask dest "Backup destination (stack folder created under this path)" "$(default_backup_dest)"
      exec "${ROOT}/scripts/backup.sh" --dest "${dest}"
      ;;
    "Restore")
      ui_ask from "Restore from (backup root, stack folder, snapshot, or archive)" "$(default_backup_dest)"
      exec "${ROOT}/scripts/backup.sh" --restore --from "${from}"
      ;;
    "Status / doctor") doctor_k8s "${title}" "${ns}" ;;
    "Uninstall") uninstall_k8s_stack "${title}" "${ns}" ;;
    *) ui_info "Bye." ;;
  esac
}
