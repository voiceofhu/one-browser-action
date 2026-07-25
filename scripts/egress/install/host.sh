# shellcheck shell=bash
# Installer globals are shared across sourced modules.
# shellcheck disable=SC2034

ensure_install_directories() {
  local install_group=root

  if [ -e "$INSTALL_DIR" ] && [ -L "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR must not be a symbolic link"
  fi
  if [ "$INSTALL_MODE" = native ]; then
    ensure_native_user
    install_group=one-browser-egress
  fi
  install -d -m 0750 -o root -g "$install_group" "$INSTALL_DIR"
}

ensure_certificate_directory() {
  local cert_group

  if [ -e "$CERT_DIR" ] && [ -L "$CERT_DIR" ]; then
    die "$CERT_DIR must not be a symbolic link"
  fi
  if [ "$INSTALL_MODE" = native ]; then
    ensure_native_user
    cert_group=one-browser-egress
  else
    cert_group=65532
  fi
  install -d -m 0750 -o root -g "$cert_group" "$CERT_DIR"
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

install_base_packages() {
  local tls_enabled=${1-true}
  local missing=0
  local package
  local packages=(ca-certificates coreutils curl jq)

  if [ "$tls_enabled" = true ]; then
    packages+=(certbot dnsutils python3-minimal)
  fi
  for package in "${packages[@]}"; do
    if ! package_installed "$package"; then
      missing=1
    fi
  done
  if [ "$missing" -eq 0 ] && command -v curl >/dev/null &&
    command -v jq >/dev/null &&
    { [ "$tls_enabled" = false ] ||
      { command -v certbot >/dev/null && command -v dig >/dev/null &&
        command -v python3 >/dev/null; }; }; then
    log "Required host packages are already installed"
    return
  fi

  if [ "$tls_enabled" = true ]; then
    log "Installing curl, CA certificates, Certbot, jq, and DNS tools"
  else
    log "Installing curl, CA certificates, and jq for development enrollment"
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install --yes --no-install-recommends "${packages[@]}"
  unset DEBIAN_FRONTEND
}

verify_supported_os() {
  [ -r /etc/os-release ] || die "Only Debian and Ubuntu are supported"
  # /etc/os-release is owned by the operating system and contains assignments.
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) OS_ID=$ID ;;
    *) die "Only Debian and Ubuntu are supported" ;;
  esac
  OS_CODENAME=${VERSION_CODENAME:-}
  [[ "$OS_CODENAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Unable to determine the OS codename"
}

detect_host_platform() {
  local kernel machine
  kernel=$(uname -s)
  machine=$(uname -m)
  case "$kernel:$machine" in
    Linux:x86_64|Linux:amd64) printf 'linux-amd64' ;;
    Linux:aarch64|Linux:arm64) printf 'linux-arm64' ;;
    *) die "Unsupported Egress host platform: $kernel/$machine" ;;
  esac
}

detect_installation_state() {
  if [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] &&
    [ -f "$INSTALL_RECORD" ] && [ ! -L "$INSTALL_RECORD" ] &&
    runtime_installation_complete; then
    printf 'installed'
  elif [ -e "$ENV_FILE" ] || [ -e "$COMPOSE_FILE" ] ||
    [ -e "$NATIVE_BINARY" ] || [ -e "$NATIVE_SERVICE_FILE" ] ||
    [ -e "$SAVED_RESPONSE" ] || [ -e "$PENDING_RESPONSE" ] ||
    [ -e "$FINGERPRINT_FILE" ] || [ -e "$INSTALL_RECORD" ]; then
    printf 'partial'
  else
    printf 'fresh'
  fi
}

write_installation_record() {
  local record_tmp

  record_tmp=$(mktemp "$INSTALL_DIR/.installation.tmp.XXXXXX")
  {
    printf 'schema=2\n'
    printf 'runtime=%s\n' "$INSTALL_MODE"
    printf 'platform=%s\n' "$HOST_PLATFORM"
    printf 'version=%s\n' "$RESOLVED_VERSION"
  } >"$record_tmp"
  chown root:root "$record_tmp"
  chmod 0600 "$record_tmp"
  mv -f "$record_tmp" "$INSTALL_RECORD"
}

installed_runtime() {
  local runtime

  [ -f "$INSTALL_RECORD" ] && [ ! -L "$INSTALL_RECORD" ] || return 1
  runtime=$(read_env_value "$INSTALL_RECORD" runtime) || return 1
  validate_install_mode "$runtime" || return 1
  printf '%s' "$runtime"
}

installed_version() {
  local normalized version

  [ -f "$INSTALL_RECORD" ] && [ ! -L "$INSTALL_RECORD" ] || return 1
  version=$(read_env_value "$INSTALL_RECORD" version) || return 1
  normalized=$(normalize_version "$version") || return 1
  [ "$normalized" != latest ] || return 1
  printf '%s' "$normalized"
}

runtime_installation_complete() {
  case "$INSTALL_MODE" in
    native)
      [ -f "$NATIVE_BINARY" ] && [ ! -L "$NATIVE_BINARY" ] &&
        [ -x "$NATIVE_BINARY" ] &&
        [ -f "$NATIVE_SERVICE_FILE" ] && [ ! -L "$NATIVE_SERVICE_FILE" ]
      ;;
    docker)
      [ -f "$COMPOSE_FILE" ] && [ ! -L "$COMPOSE_FILE" ]
      ;;
    *) return 1 ;;
  esac
}
