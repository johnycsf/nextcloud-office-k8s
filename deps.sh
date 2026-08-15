#!/usr/bin/env bash
# Host dependency helper — sourced by install.sh in johnycsf homelab app repos.
# Detects the OS/package manager and installs missing binaries (with sudo when needed).
# shellcheck shell=bash

# Usage from install.sh:
#   # shellcheck source=deps.sh
#   source "${ROOT}/deps.sh"
#   ensure_host_deps docker          # docker stacks
#   ensure_host_deps k8s             # kubernetes stacks
#   ensure_host_deps heimdall-k8s    # k8s + local image build (docker|podman)

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
      echo "Unsupported OS/package manager — install manually: $*" >&2
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
    # kubectl/helm often missing from default apt — try official binaries
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

_deps_docker_usable() {
  docker info >/dev/null 2>&1
}

_deps_wrap_docker_sudo() {
  # Current shell only — lets install continue without re-login after usermod.
  docker() { command sudo docker "$@"; }
  export -f docker
}

_deps_ensure_docker() {
  _deps_detect_os

  if ! _deps_have docker; then
    echo "Docker not found — installing..."
    case "${DEPS_PKG}" in
      apt)
        # Prefer distro packages (simple). Fall back to Docker’s convenience script.
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
    echo "Or log out/in after being added to the docker group, then re-run ./install.sh" >&2
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin missing — installing..."
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
  echo "Neither docker nor podman found — installing Docker for image builds..."
  _deps_ensure_docker
}

ensure_longhorn_storage() {
  # Optional helper for k8s install.sh — installs Longhorn when StorageClass missing.
  if kubectl get storageclass longhorn >/dev/null 2>&1; then
    return 0
  fi
  _deps_ensure_cmd helm || return 1
  echo "Longhorn StorageClass not found — installing Longhorn (one-time cluster setup)..."
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

# ensure_host_deps <profile> [extra commands...]
# Profiles:
#   docker       — Docker Engine + Compose + common tools
#   k8s          — kubectl + helm + common tools
#   heimdall-k8s — k8s + docker|podman for local image build
ensure_host_deps() {
  local profile="${1:-}"
  shift || true
  local extras=("$@")

  _deps_detect_os
  echo "Host: ${DEPS_OS_ID} (package manager: ${DEPS_PKG})"

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
      _deps_ensure_docker || return 1
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

  echo "Host dependencies OK."
}
