#!/usr/bin/env bash

# Public One Browser Egress installation entrypoint for Debian and Ubuntu.
# This source lives at the public one-browser-action repository root. Keep it
# self-contained: every invocation detects local state before a fresh install
# or an in-place update.

set +x
set -Eeuo pipefail

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

print_uninstall_command() {
  cat <<'EOF'
( set -o pipefail; r=; if [ "$(id -u)" -ne 0 ]; then command -v sudo >/dev/null 2>&1 || { echo 'root privileges or sudo are required' >&2; exit 1; }; r=sudo; fi; curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 'https://raw.githubusercontent.com/voiceofhu/one-browser-action/main/uninstall.sh' | $r bash )
EOF
}

die_runtime_switch() {
  local existing_runtime=$1
  local requested_runtime=$2

  printf 'Error: Egress is installed in %s mode; uninstall it before switching to %s mode.\n' \
    "$existing_runtime" "$requested_runtime" >&2
  printf 'Run the complete uninstall command:\n' >&2
  print_uninstall_command >&2
  exit 1
}

show_help() {
  cat <<'EOF'
Install and enroll one One Browser Egress node.

Usage:
  ONE_BROWSER_ENROLLMENT_TOKEN=<one-time-token> \
    install.sh --mode <native|docker> --control-url <origin> \
      --tls-enabled <true|false> [--version <version>]

Compatibility:
  install.sh --mode <native|docker> --control-url <origin> \
    --tls-enabled <true|false> \
    --enrollment-token <one-time-token>

Options:
  --mode              native installs a systemd service; docker installs a
                      Docker Compose service
  --version           Optional Egress version such as 26.724.1. When omitted
                      or set to latest, install the latest published version.
  --control-url       Public One Browser Server origin, for example
                      https://browser.example.com
  --tls-enabled       Expected data-plane mode from the generated command.
                      true requires production HTTPS/DNS/Certbot; false permits
                      explicit development HTTP and plaintext H2.
  --enrollment-token Compatibility input; mutually exclusive with the
                     ONE_BROWSER_ENROLLMENT_TOKEN environment variable
  --replace-existing-enrollment
                     Explicitly replace an expired or cancelled local
                     enrollment. The new claim must have the same node ID and
                     domain. Disabled by default.
  -h, --help          Show this help

Run as root. The generated Web command uses sudo automatically.
Running the generated command again keeps the enrolled node identity. It exits
without changing the runtime when the requested version is already installed,
or updates the existing runtime in place when the requested version differs.
EOF
}

validate_secret_token() {
  local value=${1-}
  [ "${#value}" -ge 32 ] &&
    [ "${#value}" -le 4096 ] &&
    [[ "$value" =~ ^[A-Za-z0-9._~-]+$ ]]
}

validate_domain() {
  local domain=${1-}
  local label
  local old_ifs

  [ -n "$domain" ] || return 1
  [ "${#domain}" -le 253 ] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1

  old_ifs=$IFS
  IFS=.
  # shellcheck disable=SC2206
  local labels=($domain)
  IFS=$old_ifs
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

validate_ipv4() {
  local value=${1-}
  local octet
  local old_ifs=$IFS

  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=.
  # shellcheck disable=SC2206
  local octets=($value)
  IFS=$old_ifs
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
}

validate_boolean() {
  [ "${1-}" = true ] || [ "${1-}" = false ]
}

validate_lower_sha256() {
  local value=${1-}
  [ "${#value}" -eq 64 ] && [[ "$value" =~ ^[a-f0-9]+$ ]]
}

validate_install_mode() {
  [ "${1-}" = native ] || [ "${1-}" = docker ]
}

normalize_version() {
  local value=${1-latest}

  value=${value#egress-}
  value=${value#v}
  if [ -z "$value" ] || [ "$value" = latest ]; then
    printf 'latest'
    return 0
  fi
  [[ "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$ ]] ||
    return 1
  printf '%s' "$value"
}

validate_control_url() {
  local url=${1-}
  local tls_enabled=${2-true}
  local authority host port scheme

  validate_boolean "$tls_enabled" || return 1
  case "$url" in
    https://*) scheme=https; authority=${url#https://} ;;
    http://*)
      [ "$tls_enabled" = false ] || return 1
      scheme=http
      authority=${url#http://}
      ;;
    *) return 1 ;;
  esac
  authority=${authority%/}
  [ -n "$authority" ] || return 1
  [[ "$authority" != */* && "$authority" != *\?* && "$authority" != *\#* ]] || return 1
  [[ "$authority" != *@* ]] || return 1

  host=$authority
  if [[ "$authority" == *:* ]]; then
    host=${authority%:*}
    port=${authority##*:}
    validate_positive_integer "$port" 1 65535 || return 1
  fi
  if [ "$tls_enabled" = true ]; then
    [ "$scheme" = https ] && validate_domain "$host"
  else
    validate_domain "$host" || validate_ipv4 "$host" ||
      [[ "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
  fi
}

normalize_control_url() {
  printf '%s' "${1%/}"
}

validate_egress_id() {
  local value=${1-}
  [ "${#value}" -ge 1 ] &&
    [ "${#value}" -le 128 ] &&
    [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]]
}

validate_positive_integer() {
  local value=${1-}
  local minimum=${2-}
  local maximum=${3-}
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ]
}

validate_public_endpoint() {
  local domain=${1-}
  local endpoint=${2-}
  local host port

  [[ "$endpoint" == *:* ]] || return 1
  host=${endpoint%:*}
  port=${endpoint##*:}
  [ "$host" = "$domain" ] || return 1
  validate_positive_integer "$port" 1 65535
}

validate_image_reference() {
  local image=${1-}
  local last_component tag

  [ "${#image}" -ge 3 ] && [ "${#image}" -le 512 ] || return 1
  [[ "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]+$ ]] || return 1
  [[ "$image" != */ && "$image" != *//* && "$image" != *..* ]] || return 1

  if [[ "$image" == *@* ]]; then
    [[ "$image" =~ @sha256:[a-f0-9]{64}$ ]] || return 1
  else
    last_component=${image##*/}
    [[ "$last_component" == *:* ]] || return 1
    tag=${last_component##*:}
    [ -n "$tag" ] || return 1
  fi
}

all_addresses_equal() {
  local records=${1-}
  local expected=${2-}
  local record
  local found=0

  [ -n "$records" ] && [ -n "$expected" ] || return 1
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    [ "$record" = "$expected" ] || return 1
    found=1
  done <<<"$records"
  [ "$found" -eq 1 ]
}

validate_enrollment_file() {
  local file=$1

  jq -e '
    type == "object" and
    keys == [
      "control_token",
      "control_url",
      "domain",
      "egress_id",
      "image",
      "max_connections",
      "max_streams",
      "public_endpoint",
      "tls_enabled",
      "version"
    ] and
    .version == "v1" and
    (.egress_id | type == "string") and
    (.domain | type == "string") and
    (.public_endpoint | type == "string") and
    (.tls_enabled | type == "boolean") and
    (.control_url | type == "string") and
    (.control_token | type == "string") and
    (.image | type == "string") and
    (.max_connections | type == "number" and . == floor) and
    (.max_streams | type == "number" and . == floor)
  ' "$file" >/dev/null
}

validate_already_connected_file() {
  local file=$1

  jq -e '
    type == "object" and
    keys == ["code", "message"] and
    .code == "already_connected" and
    (.message | type == "string")
  ' "$file" >/dev/null
}

response_has_no_store() {
  local file=$1

  awk '
    {
      line = tolower($0)
      sub(/\r$/, "", line)
      if (line ~ /^http\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]([[:space:]]|$)/) {
        saw_status = 1
        in_headers = 1
        found = 0
        next
      }
      if (in_headers && line == "") {
        in_headers = 0
        next
      }
      if (in_headers && line ~ /^cache-control:[[:space:]]*/ &&
          line ~ /(^|[,:;[:space:]])no-store([,;[:space:]]|$)/) {
        found = 1
      }
    }
    END { exit(saw_status && found ? 0 : 1) }
  ' "$file"
}

load_enrollment_file() {
  local file=$1

  validate_enrollment_file "$file" || die "Enrollment response is not valid v1 JSON"
  CONFIG_EGRESS_ID=$(jq -r '.egress_id' "$file")
  CONFIG_DOMAIN=$(jq -r '.domain' "$file")
  CONFIG_PUBLIC_ENDPOINT=$(jq -r '.public_endpoint' "$file")
  CONFIG_TLS_ENABLED=$(jq -r '.tls_enabled' "$file")
  CONFIG_CONTROL_URL=$(jq -r '.control_url' "$file")
  CONFIG_CONTROL_TOKEN=$(jq -r '.control_token' "$file")
  CONFIG_IMAGE=$(jq -r '.image' "$file")
  CONFIG_MAX_CONNECTIONS=$(jq -r '.max_connections' "$file")
  CONFIG_MAX_STREAMS=$(jq -r '.max_streams' "$file")
  validate_loaded_config
}

validate_loaded_config() {
  validate_egress_id "$CONFIG_EGRESS_ID" || die "Server returned an invalid egress_id"
  validate_domain "$CONFIG_DOMAIN" || die "Server returned an invalid lowercase domain"
  validate_public_endpoint "$CONFIG_DOMAIN" "$CONFIG_PUBLIC_ENDPOINT" ||
    die "Server public_endpoint must be the enrolled domain plus a valid port"
  validate_boolean "$CONFIG_TLS_ENABLED" || die "Server returned an invalid tls_enabled"
  if [ -n "${REQUESTED_TLS_ENABLED:-}" ] &&
    [ "$CONFIG_TLS_ENABLED" != "$REQUESTED_TLS_ENABLED" ]; then
    die "Server tls_enabled does not match the generated installation command"
  fi
  validate_control_url "$CONFIG_CONTROL_URL" "$CONFIG_TLS_ENABLED" ||
    die "Server returned a control_url that is invalid for tls_enabled=$CONFIG_TLS_ENABLED"
  validate_secret_token "$CONFIG_CONTROL_TOKEN" || die "Server returned an invalid control_token"
  validate_image_reference "$CONFIG_IMAGE" || die "Server returned an invalid image reference"
  validate_positive_integer "$CONFIG_MAX_CONNECTIONS" 1 16384 ||
    die "Server max_connections must be between 1 and 16384"
  validate_positive_integer "$CONFIG_MAX_STREAMS" 1 65535 ||
    die "Server max_streams must be between 1 and 65535"
}

read_env_value() {
  local file=$1
  local key=$2

  awk -F= -v wanted="$key" '
    $1 == wanted {
      if (found) exit 2
      found = 1
      sub(/^[^=]*=/, "")
      value = $0
    }
    END {
      if (!found) exit 1
      print value
    }
  ' "$file"
}

load_existing_env() {
  local file=$1

  [ -f "$file" ] && [ ! -L "$file" ] || die "$file must be a regular file"
  chown root:root "$file"
  chmod 0600 "$file"
  CONFIG_IMAGE=$(read_env_value "$file" DOCKER_IMAGE 2>/dev/null ||
    printf '%s:latest' "$EGRESS_IMAGE_REPOSITORY")
  CONFIG_EGRESS_ID=$(read_env_value "$file" EGRESS_ID) || die "Existing .env is missing EGRESS_ID"
  CONFIG_PUBLIC_ENDPOINT=$(read_env_value "$file" EGRESS_PUBLIC_ENDPOINT) ||
    die "Existing .env is missing EGRESS_PUBLIC_ENDPOINT"
  CONFIG_TLS_ENABLED=$(read_env_value "$file" EGRESS_TLS_ENABLED 2>/dev/null || printf true)
  CONFIG_DOMAIN=${CONFIG_PUBLIC_ENDPOINT%:*}
  CONFIG_CONTROL_URL=$(read_env_value "$file" EGRESS_CONTROL_URL) ||
    die "Existing .env is missing EGRESS_CONTROL_URL"
  CONFIG_CONTROL_TOKEN=$(read_env_value "$file" EGRESS_CONTROL_TOKEN) ||
    die "Existing .env is missing EGRESS_CONTROL_TOKEN"
  CONFIG_MAX_CONNECTIONS=$(read_env_value "$file" EGRESS_MAX_CONNECTIONS) ||
    die "Existing .env is missing EGRESS_MAX_CONNECTIONS"
  CONFIG_MAX_STREAMS=$(read_env_value "$file" EGRESS_MAX_STREAMS_GLOBAL) ||
    die "Existing .env is missing EGRESS_MAX_STREAMS_GLOBAL"
  validate_loaded_config
}

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
  if [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ]; then
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

configure_docker_repository() {
  local architecture key_tmp source_tmp

  architecture=$(dpkg --print-architecture)
  [[ "$architecture" =~ ^[a-z0-9]+$ ]] || die "Unable to determine the package architecture"
  install -d -m 0755 -o root -g root /etc/apt/keyrings
  key_tmp=$(mktemp /etc/apt/keyrings/docker.asc.tmp.XXXXXX)
  curl -q --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "https://download.docker.com/linux/${OS_ID}/gpg" --output "$key_tmp"
  grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$key_tmp" || {
    rm -f "$key_tmp"
    die "Docker repository signing key is invalid"
  }
  chmod 0644 "$key_tmp"
  mv -f "$key_tmp" /etc/apt/keyrings/docker.asc

  source_tmp=$(mktemp /etc/apt/sources.list.d/docker.sources.tmp.XXXXXX)
  cat >"$source_tmp" <<EOF
Types: deb
URIs: https://download.docker.com/linux/${OS_ID}
Suites: ${OS_CODENAME}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  chmod 0644 "$source_tmp"
  mv -f "$source_tmp" /etc/apt/sources.list.d/docker.sources
}

enable_docker_service() {
  if command -v systemctl >/dev/null; then
    systemctl enable --now docker
  elif command -v service >/dev/null; then
    service docker start
  else
    die "Docker was installed but no service manager is available"
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon is not available"
}

install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    log "Docker Engine and Compose plugin are already installed"
    enable_docker_service
    return
  fi

  export DEBIAN_FRONTEND=noninteractive
  if command -v docker >/dev/null; then
    log "Installing a Compose plugin without replacing the existing Docker Engine"
    apt-get update
    if package_installed docker-ce-cli; then
      configure_docker_repository
      apt-get update
      apt-get install --yes --no-install-recommends docker-compose-plugin
    elif package_installed docker.io; then
      apt-get install --yes --no-install-recommends docker-compose-v2 ||
        die "The existing distro Docker Engine has no compatible Compose v2 package"
    else
      die "An unsupported Docker Engine is installed; refusing to replace it automatically"
    fi
  else
    log "Installing Docker from Docker's signed APT repository"
    configure_docker_repository
    apt-get update
    apt-get install --yes --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  unset DEBIAN_FRONTEND
  command -v docker >/dev/null || die "Docker Engine installation failed"
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin installation failed"
  enable_docker_service
}

ensure_native_user() {
  if id one-browser-egress >/dev/null 2>&1; then
    return
  fi
  command -v useradd >/dev/null ||
    die "The required useradd command is unavailable"
  useradd --system --user-group --home-dir /nonexistent \
    --shell /usr/sbin/nologin one-browser-egress
}

resolve_latest_version() {
  local releases version

  releases=$(mktemp "$RUN_DIR/releases.XXXXXX")
  curl -q --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 30 \
    'https://api.github.com/repos/voiceofhu/one-browser-action/releases?per_page=100' \
    --output "$releases"
  version=$(jq -er '
    [
      .[]
      | select(.draft == false and .prerelease == false)
      | .tag_name
      | select(startswith("egress-v"))
    ][0]
    | sub("^egress-v"; "")
  ' "$releases") || {
    rm -f "$releases"
    die "Unable to resolve the latest Egress version from GitHub Releases"
  }
  rm -f "$releases"
  normalize_version "$version" ||
    die "GitHub returned an invalid latest Egress version"
}

prepare_runtime_config() {
  if [ "$INSTALL_MODE" = docker ] && [[ "$REQUESTED_VERSION" == *+* ]]; then
    die "Docker image versions cannot contain semantic-version build metadata"
  fi
  if [ -n "${RESOLVED_VERSION:-}" ]; then
    if [ "$INSTALL_MODE" = docker ]; then
      CONFIG_IMAGE="$EGRESS_IMAGE_REPOSITORY:$RESOLVED_VERSION"
    fi
    return
  fi
  if [ "$REQUESTED_VERSION" = latest ]; then
    RESOLVED_VERSION=$(resolve_latest_version)
  else
    RESOLVED_VERSION=$REQUESTED_VERSION
  fi
  if [ "$INSTALL_MODE" = docker ]; then
    CONFIG_IMAGE="$EGRESS_IMAGE_REPOSITORY:$RESOLVED_VERSION"
  fi
}

download_native_binary() {
  local asset checksum binary_tmp checksums_tmp release_base target_tmp

  asset="one-browser-egress-$HOST_PLATFORM"
  release_base="https://github.com/voiceofhu/one-browser-action/releases/download/egress-v$RESOLVED_VERSION"
  binary_tmp=$(mktemp "$RUN_DIR/one-browser-egress.XXXXXX")
  checksums_tmp=$(mktemp "$RUN_DIR/SHA256SUMS.XXXXXX")
  curl -q --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 300 \
    "$release_base/$asset" --output "$binary_tmp"
  curl -q --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 30 \
    "$release_base/SHA256SUMS" --output "$checksums_tmp"
  checksum=$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$checksums_tmp")
  validate_lower_sha256 "$checksum" ||
    die "Release checksums do not contain a valid digest for $asset"
  printf '%s  %s\n' "$checksum" "$binary_tmp" | sha256sum -c - >/dev/null ||
    die "Downloaded Egress binary checksum does not match"
  target_tmp=$(mktemp "$(dirname "$NATIVE_BINARY")/.one-browser-egress.tmp.XXXXXX")
  install -m 0755 -o root -g root "$binary_tmp" "$target_tmp"
  mv -f "$target_tmp" "$NATIVE_BINARY"
  rm -f "$binary_tmp" "$checksums_tmp"
}

write_native_service() {
  local service_tmp

  ensure_native_user
  service_tmp=$(mktemp "$RUN_DIR/one-browser-egress.service.XXXXXX")
  cat >"$service_tmp" <<EOF
[Unit]
Description=One Browser Egress
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=one-browser-egress
Group=one-browser-egress
EnvironmentFile=$ENV_FILE
ExecStart=$NATIVE_BINARY
Restart=always
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$INSTALL_DIR
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 -o root -g root "$service_tmp" "$NATIVE_SERVICE_FILE"
  rm -f "$service_tmp"
  systemctl daemon-reload
}

run_native_command() (
  set -a
  # Values in this file are validated before they are written.
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  "$NATIVE_BINARY" "$@"
)

wait_for_native_health() {
  local attempt

  for ((attempt = 1; attempt <= 36; attempt++)); do
    if run_native_command healthcheck >/dev/null 2>&1; then
      if [ "$CONFIG_TLS_ENABLED" = true ]; then
        log "Egress configuration, TLS listener, and Server readiness are healthy"
      else
        log "Egress configuration, plaintext H2 listener, and Server readiness are healthy"
      fi
      return 0
    fi
    if ! systemctl is-active --quiet one-browser-egress; then
      die "Egress service stopped; inspect with: journalctl -u one-browser-egress"
    fi
    if [ "$attempt" -lt 36 ]; then
      sleep 5
    fi
  done
  die "Egress did not become healthy within 180 seconds; inspect with: journalctl -u one-browser-egress"
}

start_native_egress() {
  command -v systemctl >/dev/null ||
    die "Native installation requires systemd"
  log "Installing One Browser Egress $RESOLVED_VERSION for $HOST_PLATFORM"
  download_native_binary
  run_native_command validate-config
  write_native_service
  systemctl enable --now one-browser-egress
  systemctl restart one-browser-egress
  wait_for_native_health
}

claim_enrollment() {
  local requested_control_url=$1
  local token_file=$2
  local requested_tls_enabled=$3
  local enroll_url header_size http_code response_size token
  local -a curl_transport

  CLAIM_OUTCOME=
  [ -f "$token_file" ] && [ ! -L "$token_file" ] || die "Enrollment token state is unavailable"
  token=$(<"$token_file")
  validate_secret_token "$token" || die "Enrollment token is invalid"
  enroll_url="${requested_control_url}/internal/egress/v1/enroll"
  CURL_CONFIG_FILE=$(mktemp "$RUN_DIR/curl-config.XXXXXX")
  RESPONSE_HEADER_FILE=$(mktemp "$RUN_DIR/response-headers.XXXXXX")
  chmod 0600 "$CURL_CONFIG_FILE"
  chmod 0600 "$RESPONSE_HEADER_FILE"
  cat >"$CURL_CONFIG_FILE" <<EOF
silent
show-error
connect-timeout = 10
max-time = 60
request = "POST"
header = "Authorization: Bearer ${token}"
header = "Accept: application/json"
EOF
  token=

  if [ -e "$CLAIM_RESPONSE_FILE" ] && [ -L "$CLAIM_RESPONSE_FILE" ]; then
    die "$CLAIM_RESPONSE_FILE must not be a symbolic link"
  fi
  : >"$CLAIM_RESPONSE_FILE"
  chmod 0600 "$CLAIM_RESPONSE_FILE"
  log "Claiming the one-time enrollment"
  if [ "$requested_tls_enabled" = true ]; then
    curl_transport=(--proto '=https' --tlsv1.2)
  else
    curl_transport=(--proto '=http,https')
  fi
  if ! http_code=$(curl -q "${curl_transport[@]}" --config "$CURL_CONFIG_FILE" \
    --no-location \
    --url "$enroll_url" \
    --dump-header "$RESPONSE_HEADER_FILE" \
    --max-filesize 65536 \
    --output "$CLAIM_RESPONSE_FILE" \
    --write-out '%{http_code}'); then
    die "Enrollment request failed; fix connectivity and run the generated command again"
  fi
  rm -f "$CURL_CONFIG_FILE" "$token_file"
  CURL_CONFIG_FILE=
  TOKEN_FILE=
  response_size=$(stat -c '%s' "$CLAIM_RESPONSE_FILE")
  validate_positive_integer "$response_size" 1 65536 || {
    rm -f "$CLAIM_RESPONSE_FILE" "$RESPONSE_HEADER_FILE"
    RESPONSE_HEADER_FILE=
    die "Enrollment response exceeds the 64 KiB limit"
  }
  header_size=$(stat -c '%s' "$RESPONSE_HEADER_FILE")
  validate_positive_integer "$header_size" 1 65536 || {
    rm -f "$CLAIM_RESPONSE_FILE" "$RESPONSE_HEADER_FILE"
    RESPONSE_HEADER_FILE=
    die "Enrollment response headers exceed the 64 KiB limit"
  }
  response_has_no_store "$RESPONSE_HEADER_FILE" || {
    rm -f "$CLAIM_RESPONSE_FILE" "$RESPONSE_HEADER_FILE"
    RESPONSE_HEADER_FILE=
    die "Enrollment response is missing Cache-Control: no-store"
  }
  rm -f "$RESPONSE_HEADER_FILE"
  RESPONSE_HEADER_FILE=
  if [ "$http_code" = 200 ]; then
    validate_enrollment_file "$CLAIM_RESPONSE_FILE" || {
      rm -f "$CLAIM_RESPONSE_FILE"
      die "Enrollment response is not valid v1 JSON"
    }
    CLAIM_OUTCOME=claimed
    return 0
  fi
  if [ "$http_code" = 409 ] && validate_already_connected_file "$CLAIM_RESPONSE_FILE"; then
    rm -f "$CLAIM_RESPONSE_FILE"
    CLAIM_OUTCOME=already_connected
    return 0
  fi
  rm -f "$CLAIM_RESPONSE_FILE"
  if [ "$http_code" = 401 ]; then
    die "Enrollment token is invalid, expired, or cancelled"
  fi
  if [ "$http_code" = 409 ]; then
    die "Enrollment request returned an unsupported conflict response"
  fi
  die "Enrollment request returned HTTP $http_code"
}

commit_claim_response() {
  [ -f "$CLAIM_RESPONSE_FILE" ] && [ ! -L "$CLAIM_RESPONSE_FILE" ] ||
    die "Validated enrollment response is unavailable"
  mv -f "$CLAIM_RESPONSE_FILE" "$SAVED_RESPONSE"
  chmod 0600 "$SAVED_RESPONSE"
  CLAIM_RESPONSE_FILE=
}

write_enrollment_fingerprint() {
  local fingerprint=$1
  local fingerprint_tmp

  [[ "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Enrollment fingerprint is invalid"
  fingerprint_tmp=$(mktemp "$INSTALL_DIR/.enrollment-fingerprint.tmp.XXXXXX")
  printf '%s\n' "$fingerprint" >"$fingerprint_tmp"
  chown root:root "$fingerprint_tmp"
  chmod 0600 "$fingerprint_tmp"
  mv -f "$fingerprint_tmp" "$FINGERPRINT_FILE"
}

require_matching_fingerprint() {
  local requested_fingerprint=$1
  local saved_fingerprint

  [ -f "$FINGERPRINT_FILE" ] && [ ! -L "$FINGERPRINT_FILE" ] ||
    die "This host already has Egress state from another installation; refusing to consume a new enrollment"
  chown root:root "$FINGERPRINT_FILE"
  chmod 0600 "$FINGERPRINT_FILE"
  saved_fingerprint=$(<"$FINGERPRINT_FILE")
  [ "$saved_fingerprint" = "$requested_fingerprint" ] ||
    die "This host is already configured with a different enrollment; the new token was not consumed"
}

fingerprint_matches() {
  local requested_fingerprint=$1
  local saved_fingerprint

  [ -f "$FINGERPRINT_FILE" ] && [ ! -L "$FINGERPRINT_FILE" ] || return 1
  chown root:root "$FINGERPRINT_FILE" || return 1
  chmod 0600 "$FINGERPRINT_FILE" || return 1
  saved_fingerprint=$(<"$FINGERPRINT_FILE") || return 1
  [ "$saved_fingerprint" = "$requested_fingerprint" ]
}

existing_enrollment_mode() {
  local requested_fingerprint=$1
  local allow_replacement=$2

  if fingerprint_matches "$requested_fingerprint"; then
    printf 'renew'
    return 0
  fi
  if [ "$allow_replacement" = 1 ]; then
    printf 'replace'
    return 0
  fi
  return 1
}

claim_matches_existing_config() {
  local mode=$1
  local existing_egress_id=$2
  local existing_domain=$3
  local existing_control_token=$4
  local existing_tls_enabled=${5-true}

  [ "$CONFIG_EGRESS_ID" = "$existing_egress_id" ] || return 1
  [ "$CONFIG_DOMAIN" = "$existing_domain" ] || return 1
  [ "$CONFIG_TLS_ENABLED" = "$existing_tls_enabled" ] || return 1
  if [ "$mode" = renew ]; then
    [ "$CONFIG_CONTROL_TOKEN" = "$existing_control_token" ] || return 1
  fi
}

load_partial_enrollment_identity() {
  local candidate

  PARTIAL_EGRESS_ID=
  PARTIAL_DOMAIN=
  PARTIAL_TLS_ENABLED=
  for candidate in "$SAVED_RESPONSE" "$PENDING_RESPONSE"; do
    [ -e "$candidate" ] || continue
    [ -f "$candidate" ] && [ ! -L "$candidate" ] ||
      die "$candidate must be a regular file"
    if ! jq -e '
      type == "object" and
      (.egress_id | type == "string") and
      (.domain | type == "string") and
      (.tls_enabled | type == "boolean")
    ' "$candidate" >/dev/null 2>&1; then
      continue
    fi
    PARTIAL_EGRESS_ID=$(jq -r '.egress_id' "$candidate")
    PARTIAL_DOMAIN=$(jq -r '.domain' "$candidate")
    PARTIAL_TLS_ENABLED=$(jq -r '.tls_enabled' "$candidate")
    if validate_egress_id "$PARTIAL_EGRESS_ID" &&
      validate_domain "$PARTIAL_DOMAIN" &&
      validate_boolean "$PARTIAL_TLS_ENABLED"; then
      return 0
    fi
    PARTIAL_EGRESS_ID=
    PARTIAL_DOMAIN=
    PARTIAL_TLS_ENABLED=
  done
  return 1
}

refresh_existing_enrollment() {
  local requested_control_url=$1
  local token_file=$2
  local requested_fingerprint=$3
  local mode=$4
  local existing_control_token existing_domain existing_egress_id existing_tls_enabled

  load_existing_env "$ENV_FILE"
  prepare_runtime_config
  existing_egress_id=$CONFIG_EGRESS_ID
  existing_domain=$CONFIG_DOMAIN
  existing_control_token=$CONFIG_CONTROL_TOKEN
  existing_tls_enabled=$CONFIG_TLS_ENABLED
  claim_enrollment "$requested_control_url" "$token_file" "$REQUESTED_TLS_ENABLED"
  if [ "$CLAIM_OUTCOME" = already_connected ]; then
    if [ "$mode" != renew ]; then
      CONFIG_CONTROL_TOKEN=
      existing_control_token=
      die "Replacement enrollment is already connected; existing configuration was not changed"
    fi
    rm -f "$SAVED_RESPONSE" "$PENDING_RESPONSE"
    write_service_env
    CONFIG_CONTROL_TOKEN=
    existing_control_token=
    log "Server confirms this matching enrollment is already connected; continuing with existing configuration"
    return 0
  fi
  [ "$CLAIM_OUTCOME" = claimed ] || die "Enrollment claim returned an invalid outcome"
  load_enrollment_file "$CLAIM_RESPONSE_FILE"
  prepare_runtime_config
  if ! claim_matches_existing_config \
    "$mode" \
    "$existing_egress_id" \
    "$existing_domain" \
    "$existing_control_token" \
    "$existing_tls_enabled"; then
    rm -f "$CLAIM_RESPONSE_FILE"
    CONFIG_CONTROL_TOKEN=
    existing_control_token=
    if [ "$mode" = renew ]; then
      die "Renewed enrollment does not match the existing node ID, domain, and control token; existing configuration was not changed"
    fi
    die "Replacement enrollment does not match the existing node ID and domain; existing configuration was not changed"
  fi
  write_service_env
  write_enrollment_fingerprint "$requested_fingerprint"
  rm -f "$CLAIM_RESPONSE_FILE" "$SAVED_RESPONSE" "$PENDING_RESPONSE"
  CONFIG_CONTROL_TOKEN=
  existing_control_token=
}

install_unconfigured_enrollment() {
  local requested_control_url=$1
  local token_file=$2
  local requested_fingerprint=$3
  local replace_existing=$4
  local partial_identity=0

  if [ "$replace_existing" = 1 ] && load_partial_enrollment_identity; then
    partial_identity=1
    log "Protected partial enrollment identity found; replacement must match its node ID and domain"
  fi
  if [ "$replace_existing" = 0 ] && [ ! -e "$FINGERPRINT_FILE" ]; then
    write_enrollment_fingerprint "$requested_fingerprint"
  fi
  claim_enrollment "$requested_control_url" "$token_file" "$REQUESTED_TLS_ENABLED"
  [ "$CLAIM_OUTCOME" = claimed ] ||
    die "Server reports this enrollment is already connected, but no protected local configuration exists"
  load_enrollment_file "$CLAIM_RESPONSE_FILE"
  prepare_runtime_config
  if [ "$partial_identity" = 1 ] &&
    ! claim_matches_existing_config \
      replace "$PARTIAL_EGRESS_ID" "$PARTIAL_DOMAIN" "" "$PARTIAL_TLS_ENABLED"; then
    rm -f "$CLAIM_RESPONSE_FILE"
    CONFIG_CONTROL_TOKEN=
    die "Replacement enrollment does not match the protected partial node ID and domain; local state was not changed"
  fi
  commit_claim_response
  write_service_env
  write_enrollment_fingerprint "$requested_fingerprint"
  rm -f "$SAVED_RESPONSE" "$PENDING_RESPONSE"
}

write_service_env() {
  local endpoint_port per_ip_limit per_connection_limit env_tmp

  endpoint_port=${CONFIG_PUBLIC_ENDPOINT##*:}
  per_ip_limit=64
  if [ "$CONFIG_MAX_CONNECTIONS" -lt "$per_ip_limit" ]; then
    per_ip_limit=$CONFIG_MAX_CONNECTIONS
  fi
  per_connection_limit=256
  if [ "$CONFIG_MAX_STREAMS" -lt "$per_connection_limit" ]; then
    per_connection_limit=$CONFIG_MAX_STREAMS
  fi

  env_tmp=$(mktemp "$INSTALL_DIR/.env.tmp.XXXXXX")
  chmod 0600 "$env_tmp"
  {
    if [ "$INSTALL_MODE" = docker ]; then
      printf 'DOCKER_IMAGE=%s\n' "$CONFIG_IMAGE"
      printf 'CONTAINER_NAME=one-browser-egress\n'
      printf 'CONTROL_NETWORK=one-browser-control\n\n'
    fi
    printf 'EGRESS_ID=%s\n' "$CONFIG_EGRESS_ID"
    printf 'EGRESS_PUBLIC_ENDPOINT=%s\n' "$CONFIG_PUBLIC_ENDPOINT"
    printf 'EGRESS_CONTROL_URL=%s\n' "$CONFIG_CONTROL_URL"
    printf 'EGRESS_CONTROL_TOKEN=%s\n\n' "$CONFIG_CONTROL_TOKEN"
    printf 'EGRESS_PUBLISH_ADDR=0.0.0.0\n'
    printf 'EGRESS_HOST_PORT=%s\n' "$endpoint_port"
    printf 'EGRESS_BIND_ADDR=0.0.0.0:27600\n'
    printf 'EGRESS_HEALTHCHECK_ADDR=127.0.0.1:27600\n'
    printf 'EGRESS_TLS_ENABLED=%s\n' "$CONFIG_TLS_ENABLED"
    if [ "$CONFIG_TLS_ENABLED" = true ]; then
      if [ "$INSTALL_MODE" = docker ]; then
        printf 'EGRESS_CERT_DIR=./certs\n'
        printf 'EGRESS_TLS_CERT_FILE=/app/tls/fullchain.pem\n'
        printf 'EGRESS_TLS_KEY_FILE=/app/tls/privkey.pem\n'
      else
        printf 'EGRESS_TLS_CERT_FILE=%s/fullchain.pem\n' "$CERT_DIR"
        printf 'EGRESS_TLS_KEY_FILE=%s/privkey.pem\n' "$CERT_DIR"
      fi
    fi
    printf '\n'
    printf 'EGRESS_MAX_CONNECTIONS=%s\n' "$CONFIG_MAX_CONNECTIONS"
    printf 'EGRESS_MAX_CONNECTIONS_PER_IP=%s\n' "$per_ip_limit"
    printf 'EGRESS_MAX_STREAMS_PER_CONNECTION=%s\n' "$per_connection_limit"
    printf 'EGRESS_MAX_STREAMS_GLOBAL=%s\n' "$CONFIG_MAX_STREAMS"
    printf 'EGRESS_AUTHORIZATION_TIMEOUT_SECONDS=5\n'
    printf 'RUST_LOG=one_browser_egress=info\n'
  } >"$env_tmp"
  chown root:root "$env_tmp"
  mv -f "$env_tmp" "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
}

write_compose_file() {
  local compose_tmp

  compose_tmp=$(mktemp "$INSTALL_DIR/docker-compose.yml.tmp.XXXXXX")
  cat >"$compose_tmp" <<'EOF'
services:
  egress:
    image: ${DOCKER_IMAGE}
    container_name: ${CONTAINER_NAME:-one-browser-egress}
    restart: unless-stopped
    init: true
    read_only: true
    ports:
      - "${EGRESS_PUBLISH_ADDR:-127.0.0.1}:${EGRESS_HOST_PORT:-27600}:27600"
    env_file:
      - .env
    environment:
      EGRESS_BIND_ADDR: 0.0.0.0:27600
      EGRESS_TLS_ENABLED: ${EGRESS_TLS_ENABLED:-true}
      EGRESS_HEALTHCHECK_ADDR: 127.0.0.1:27600
EOF
  if [ "$CONFIG_TLS_ENABLED" = true ]; then
    cat >>"$compose_tmp" <<'EOF'
      EGRESS_TLS_CERT_FILE: /app/tls/fullchain.pem
      EGRESS_TLS_KEY_FILE: /app/tls/privkey.pem
    volumes:
      - ${EGRESS_CERT_DIR:-./certs}:/app/tls:ro
EOF
  fi
  cat >>"$compose_tmp" <<'EOF'
    networks:
      - control
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    pids_limit: 1024
    tmpfs:
      - /tmp:size=16m,mode=1777
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    stop_grace_period: 20s
    healthcheck:
      test: ["CMD", "one-browser-egress", "healthcheck"]
      interval: 30s
      timeout: 10s
      start_period: 20s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"

networks:
  control:
    name: ${CONTROL_NETWORK:-one-browser-control}
    external: true
EOF
  chown root:root "$compose_tmp"
  chmod 0644 "$compose_tmp"
  mv -f "$compose_tmp" "$COMPOSE_FILE"
}

discover_public_ip() {
  local family=$1
  local candidate url

  for url in https://api.ipify.org https://ifconfig.me/ip; do
    candidate=$(curl -q --proto '=https' --tlsv1.2 "-$family" \
      --fail --silent --show-error --noproxy '*' \
      --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)
    candidate=${candidate//$'\r'/}
    candidate=${candidate//$'\n'/}
    if [ "$family" = 4 ] && [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    if [ "$family" = 6 ] && [[ "$candidate" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$candidate" == *:* ]]; then
      if canonicalize_ipv6 "$candidate"; then
        return 0
      fi
    fi
  done
  return 1
}

canonicalize_ipv6() {
  local value=$1

  python3 -c '
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if address.version != 6:
    raise SystemExit(1)
print(address.compressed)
' "$value"
}

resolve_ipv4() {
  dig +time=5 +tries=2 +short "$1" A 2>/dev/null |
    awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print}' | sort -u
}

resolve_ipv6() {
  local normalized record

  dig +time=5 +tries=2 +short "$1" AAAA 2>/dev/null |
    awk '/^[0-9A-Fa-f:]+$/ && /:/ {print tolower($0)}' |
    while IFS= read -r record; do
      normalized=$(canonicalize_ipv6 "$record" 2>/dev/null || true)
      [ -n "$normalized" ] && printf '%s\n' "$normalized"
    done | sort -u
}

verify_domain_points_here() {
  local domain=$1
  local dns_v4 dns_v6 public_v4

  dns_v4=$(resolve_ipv4 "$domain" || true)
  dns_v6=$(resolve_ipv6 "$domain" || true)
  [ -z "$dns_v6" ] ||
    die "$domain publishes AAAA records, but one-click enrollment currently supports IPv4 only"
  [ -n "$dns_v4" ] || die "$domain must publish at least one IPv4 A record"
  public_v4=$(discover_public_ip 4 || true)
  [ -n "$public_v4" ] || die "Unable to determine this host's public IPv4 address"
  all_addresses_equal "$dns_v4" "$public_v4" ||
    die "$domain has an A record that does not point to this host; fix DNS before requesting TLS"
  log "Every DNS A record points to this host's public IPv4 address"
}

issue_and_install_certificate() {
  local cert_group live_dir

  log "Requesting or reusing the Let's Encrypt certificate for $CONFIG_DOMAIN"
  if ! certbot certonly \
    --standalone \
    --preferred-challenges http \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --keep-until-expiring \
    --cert-name "$CONFIG_DOMAIN" \
    -d "$CONFIG_DOMAIN"; then
    die "Certificate issuance failed; ensure inbound TCP 80 is open and not in use"
  fi
  live_dir="/etc/letsencrypt/live/$CONFIG_DOMAIN"
  [ -r "$live_dir/fullchain.pem" ] && [ -r "$live_dir/privkey.pem" ] ||
    die "Certbot succeeded but certificate files are unavailable"
  if [ "$INSTALL_MODE" = native ]; then
    cert_group=one-browser-egress
  else
    cert_group=65532
  fi
  install -m 0644 -o root -g "$cert_group" "$live_dir/fullchain.pem" "$CERT_DIR/fullchain.pem"
  install -m 0640 -o root -g "$cert_group" "$live_dir/privkey.pem" "$CERT_DIR/privkey.pem"
}

write_renewal_hook() {
  local hook_dir=/etc/letsencrypt/renewal-hooks/deploy
  local hook_file=$hook_dir/one-browser-egress.sh
  local cert_group hook_tmp restart_command

  if [ "$INSTALL_MODE" = native ]; then
    cert_group=one-browser-egress
    restart_command="systemctl restart one-browser-egress"
  else
    cert_group=65532
    restart_command="docker compose --project-name one-browser-egress --env-file '$ENV_FILE' -f '$COMPOSE_FILE' restart egress"
  fi

  install -d -m 0755 -o root -g root "$hook_dir"
  hook_tmp=$(mktemp "$hook_dir/one-browser-egress.sh.tmp.XXXXXX")
  cat >"$hook_tmp" <<EOF
#!/usr/bin/env bash
set +x
set -Eeuo pipefail

domain='$CONFIG_DOMAIN'
case " \${RENEWED_DOMAINS:-} " in
  *" \${domain} "*) ;;
  *) exit 0 ;;
esac

install -d -m 0750 -o root -g '$cert_group' '$CERT_DIR'
install -m 0644 -o root -g '$cert_group' \
  "/etc/letsencrypt/live/\${domain}/fullchain.pem" \
  '$CERT_DIR/fullchain.pem'
install -m 0640 -o root -g '$cert_group' \
  "/etc/letsencrypt/live/\${domain}/privkey.pem" \
  '$CERT_DIR/privkey.pem'
$restart_command
EOF
  chown root:root "$hook_tmp"
  chmod 0755 "$hook_tmp"
  mv -f "$hook_tmp" "$hook_file"
}

compose() {
  docker compose \
    --project-name one-browser-egress \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    "$@"
}

wait_for_health() {
  local attempt status

  for ((attempt = 1; attempt <= 36; attempt++)); do
    status=$(docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
      one-browser-egress 2>/dev/null || true)
    case "$status" in
      healthy)
        if [ "$CONFIG_TLS_ENABLED" = true ]; then
          log "Egress configuration, TLS listener, and Server readiness are healthy"
        else
          log "Egress configuration, plaintext H2 listener, and Server readiness are healthy"
        fi
        return 0
        ;;
      unhealthy)
        die "Egress became unhealthy; inspect with: docker logs one-browser-egress"
        ;;
    esac
    if [ "$attempt" -lt 36 ]; then
      sleep 5
    fi
  done
  die "Egress did not become healthy within 180 seconds; inspect with: docker logs one-browser-egress"
}

start_docker_egress() {
  if ! docker network inspect one-browser-control >/dev/null 2>&1; then
    docker network create one-browser-control >/dev/null
  fi
  log "Validating and pulling $CONFIG_IMAGE"
  compose config --quiet
  if [ "$CONFIG_TLS_ENABLED" = false ] &&
    docker image inspect "$CONFIG_IMAGE" >/dev/null 2>&1; then
    log "Using the preloaded development Egress image"
  else
    compose pull egress
  fi
  compose run --rm --no-deps egress validate-config </dev/null
  compose up -d egress
  wait_for_health
}

update_existing_installation() {
  local installed=

  load_existing_env "$ENV_FILE"
  prepare_runtime_config
  installed=$(installed_version 2>/dev/null || true)
  if [ "$installed" = "$RESOLVED_VERSION" ] &&
    runtime_installation_complete; then
    CONFIG_CONTROL_TOKEN=
    log "One Browser Egress $RESOLVED_VERSION is already the requested version"
    printf 'One Browser Egress %s (%s, %s) is already up to date at %s.\n' \
      "$CONFIG_EGRESS_ID" "$INSTALL_MODE" "$RESOLVED_VERSION" "$CONFIG_PUBLIC_ENDPOINT"
    return 0
  fi

  if [ "$installed" = "$RESOLVED_VERSION" ]; then
    log "The requested version is recorded, but runtime files are incomplete; repairing it in place"
  elif [ -n "$installed" ]; then
    log "Updating One Browser Egress from $installed to $RESOLVED_VERSION in place"
  else
    log "The installed Egress version is unknown; overwriting the runtime with $RESOLVED_VERSION"
  fi
  write_service_env
  CONFIG_CONTROL_TOKEN=
  if [ "$INSTALL_MODE" = native ]; then
    start_native_egress
  else
    write_compose_file
    install_docker
    start_docker_egress
  fi
  write_installation_record
  printf 'One Browser Egress %s (%s) was updated in place to %s and is healthy at %s.\n' \
    "$CONFIG_EGRESS_ID" "$INSTALL_MODE" "$RESOLVED_VERSION" "$CONFIG_PUBLIC_ENDPOINT"
}

cleanup_sensitive_files() {
  set +e
  if [ -n "${CURL_CONFIG_FILE:-}" ]; then
    rm -f "$CURL_CONFIG_FILE"
  fi
  if [ -n "${TOKEN_FILE:-}" ]; then
    rm -f "$TOKEN_FILE"
  fi
  if [ -n "${RESPONSE_HEADER_FILE:-}" ]; then
    rm -f "$RESPONSE_HEADER_FILE"
  fi
  if [ -n "${CLAIM_RESPONSE_FILE:-}" ]; then
    rm -f "$CLAIM_RESPONSE_FILE"
  fi
}

installer_main() {
  local requested_control_url=$1
  local token_file=$2
  local requested_fingerprint=$3
  local replace_existing=$4
  local requested_tls_enabled=$5
  local install_mode=$6
  local requested_version=$7
  local existing_mode existing_runtime installation_state

  set +x
  set -Eeuo pipefail
  umask 077
  INSTALL_DIR=/opt/one-browser-egress
  CERT_DIR=$INSTALL_DIR/certs
  ENV_FILE=$INSTALL_DIR/.env
  COMPOSE_FILE=$INSTALL_DIR/docker-compose.yml
  NATIVE_BINARY=/usr/local/bin/one-browser-egress
  NATIVE_SERVICE_FILE=/etc/systemd/system/one-browser-egress.service
  SAVED_RESPONSE=$INSTALL_DIR/.enrollment-response.json
  PENDING_RESPONSE=$INSTALL_DIR/.enrollment-response.json.pending
  CLAIM_RESPONSE_FILE=$INSTALL_DIR/.enrollment-response.json.candidate
  FINGERPRINT_FILE=$INSTALL_DIR/.enrollment-fingerprint
  INSTALL_RECORD=$INSTALL_DIR/.installation
  RUN_DIR=/run/one-browser-egress-installer
  TOKEN_FILE=$token_file
  CURL_CONFIG_FILE=
  RESPONSE_HEADER_FILE=
  CLAIM_OUTCOME=
  CONFIG_EGRESS_ID=
  CONFIG_DOMAIN=
  CONFIG_PUBLIC_ENDPOINT=
  CONFIG_TLS_ENABLED=
  CONFIG_CONTROL_URL=
  CONFIG_CONTROL_TOKEN=
  CONFIG_IMAGE=
  CONFIG_MAX_CONNECTIONS=
  CONFIG_MAX_STREAMS=
  PARTIAL_EGRESS_ID=
  PARTIAL_DOMAIN=
  PARTIAL_TLS_ENABLED=
  REQUESTED_TLS_ENABLED=$requested_tls_enabled
  INSTALL_MODE=$install_mode
  REQUESTED_VERSION=$requested_version
  RESOLVED_VERSION=
  EGRESS_IMAGE_REPOSITORY=ghcr.io/voiceofhu/one-browser-egress
  [ "$replace_existing" = 0 ] || [ "$replace_existing" = 1 ] ||
    die "Internal replacement mode is invalid"
  validate_boolean "$REQUESTED_TLS_ENABLED" ||
    die "Internal TLS mode is invalid"
  validate_install_mode "$INSTALL_MODE" || die "Internal install mode is invalid"
  [ "$(normalize_version "$REQUESTED_VERSION")" = "$REQUESTED_VERSION" ] ||
    die "Internal Egress version is invalid"
  trap cleanup_sensitive_files EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP

  install -d -m 0700 -o root -g root "$RUN_DIR"
  exec 9>"$RUN_DIR/install.lock"
  flock -n 9 || die "Another Egress installation is already running"
  verify_supported_os
  HOST_PLATFORM=$(detect_host_platform)
  installation_state=$(detect_installation_state)
  if existing_runtime=$(installed_runtime 2>/dev/null); then
    [ "$existing_runtime" = "$INSTALL_MODE" ] ||
      die_runtime_switch "$existing_runtime" "$INSTALL_MODE"
  elif [ -e "$COMPOSE_FILE" ]; then
    [ "$INSTALL_MODE" = docker ] ||
      die_runtime_switch docker native
  elif [ -e "$NATIVE_SERVICE_FILE" ] || [ -e "$NATIVE_BINARY" ]; then
    [ "$INSTALL_MODE" = native ] ||
      die_runtime_switch native docker
  fi
  ensure_install_directories
  case "$installation_state" in
    fresh)
      log "No existing Egress installation detected; starting a fresh install for $HOST_PLATFORM"
      ;;
    installed)
      log "Existing Egress installation detected; checking its runtime version"
      ;;
    partial)
      log "Partial Egress installation state detected; resuming protected installation"
      ;;
    *) die "Internal installation state is invalid" ;;
  esac
  install_base_packages "$REQUESTED_TLS_ENABLED"
  if [ "$installation_state" = installed ] && [ "$replace_existing" = 0 ]; then
    log "Preserving the existing node enrollment while checking its runtime version;" \
      "the supplied enrollment token will not be consumed"
    update_existing_installation
    return 0
  fi

  if [ -e "$ENV_FILE" ]; then
    if ! existing_mode=$(existing_enrollment_mode \
      "$requested_fingerprint" "$replace_existing"); then
      die "This host is already configured with a different enrollment; the new token was not consumed. Use --replace-existing-enrollment only for a replacement issued for this same node"
    fi
    if [ "$existing_mode" = replace ]; then
      log "Explicit enrollment replacement requested; existing configuration stays unchanged until node ID and domain match"
    fi
  elif [ -e "$SAVED_RESPONSE" ] || [ -e "$PENDING_RESPONSE" ] ||
    [ -e "$FINGERPRINT_FILE" ]; then
    if [ "$replace_existing" = 0 ]; then
      require_matching_fingerprint "$requested_fingerprint"
    else
      log "Explicit replacement requested for interrupted local enrollment state"
    fi
  elif [ "$replace_existing" = 1 ]; then
    log "No local enrollment state exists; proceeding as a fresh installation"
  fi

  if [ -e "$ENV_FILE" ]; then
    if [ "$existing_mode" = renew ]; then
      log "Renewing the claimed installation lease before resuming"
    else
      log "Claiming the explicit replacement enrollment"
    fi
    refresh_existing_enrollment \
      "$requested_control_url" \
      "$TOKEN_FILE" \
      "$requested_fingerprint" \
      "$existing_mode"
  else
    install_unconfigured_enrollment \
      "$requested_control_url" \
      "$TOKEN_FILE" \
      "$requested_fingerprint" \
      "$replace_existing"
  fi
  CONFIG_CONTROL_TOKEN=

  if [ "$CONFIG_TLS_ENABLED" = true ]; then
    ensure_certificate_directory
    verify_domain_points_here "$CONFIG_DOMAIN"
    issue_and_install_certificate
  fi
  if [ "$CONFIG_TLS_ENABLED" = true ]; then
    write_renewal_hook
  fi
  if [ "$INSTALL_MODE" = native ]; then
    start_native_egress
  else
    write_compose_file
    install_docker
    start_docker_egress
  fi
  write_installation_record
  printf 'One Browser Egress %s (%s, %s) is installed and healthy at %s.\n' \
    "$CONFIG_EGRESS_ID" "$INSTALL_MODE" "$RESOLVED_VERSION" "$CONFIG_PUBLIC_ENDPOINT"
}

bootstrap() {
  local environment_token_present=${ONE_BROWSER_ENROLLMENT_TOKEN+x}
  local enrollment_token=${ONE_BROWSER_ENROLLMENT_TOKEN-}
  unset ONE_BROWSER_ENROLLMENT_TOKEN
  local control_url=
  local install_mode=
  local tls_enabled=
  local requested_version=latest
  local version_argument_seen=0
  local enrollment_fingerprint token_file stage_code
  local replace_existing=0
  local token_argument_seen=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        [ "$#" -ge 2 ] || die "--mode requires a value"
        [ -z "$install_mode" ] || die "--mode may be supplied only once"
        install_mode=$2
        shift 2
        ;;
      --version)
        [ "$#" -ge 2 ] || die "--version requires a value"
        [ "$version_argument_seen" -eq 0 ] ||
          die "--version may be supplied only once"
        requested_version=$(normalize_version "$2") ||
          die "--version must be latest or a semantic version such as 26.724.1"
        version_argument_seen=1
        shift 2
        ;;
      --control-url)
        [ "$#" -ge 2 ] || die "--control-url requires a value"
        [ -z "$control_url" ] || die "--control-url may be supplied only once"
        control_url=$2
        shift 2
        ;;
      --tls-enabled)
        [ "$#" -ge 2 ] || die "--tls-enabled requires a value"
        [ -z "$tls_enabled" ] || die "--tls-enabled may be supplied only once"
        tls_enabled=$2
        shift 2
        ;;
      --enrollment-token)
        [ "$#" -ge 2 ] || die "--enrollment-token requires a value"
        [ "$token_argument_seen" -eq 0 ] || die "--enrollment-token may be supplied only once"
        [ -z "$environment_token_present" ] ||
          die "Use either ONE_BROWSER_ENROLLMENT_TOKEN or --enrollment-token, not both"
        enrollment_token=$2
        token_argument_seen=1
        shift 2
        ;;
      --replace-existing-enrollment)
        [ "$replace_existing" -eq 0 ] ||
          die "--replace-existing-enrollment may be supplied only once"
        replace_existing=1
        shift
        ;;
      -h|--help)
        show_help
        return 0
        ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  validate_install_mode "$install_mode" || die "--mode must be native or docker"
  validate_boolean "$tls_enabled" || die "--tls-enabled must be true or false"
  validate_control_url "$control_url" "$tls_enabled" ||
    die "--control-url is invalid for --tls-enabled $tls_enabled"
  control_url=$(normalize_control_url "$control_url")
  validate_secret_token "$enrollment_token" || die "--enrollment-token is invalid"
  [ "${EUID:-$(id -u)}" -eq 0 ] ||
    die "Run this installer as root (the generated command uses sudo)"
  command -v flock >/dev/null || die "The required flock command is unavailable"
  command -v sha256sum >/dev/null || die "The required sha256sum command is unavailable"

  umask 077
  install -d -m 0700 -o root -g root /run/one-browser-egress-installer
  token_file=$(mktemp /run/one-browser-egress-installer/enrollment-token.XXXXXX)
  trap 'rm -f "$token_file"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  printf '%s' "$enrollment_token" >"$token_file"
  chmod 0600 "$token_file"
  enrollment_fingerprint="sha256:$(printf '%s' "$enrollment_token" | sha256sum | awk '{print $1}')"
  enrollment_token=
  set --

  # Replace the downloaded installer process immediately. The second-stage
  # command line contains only the token-file path, one-way fingerprint,
  # replacement bit, and validated non-secret options.
  stage_code=$(declare -f \
    die log validate_secret_token validate_domain validate_ipv4 validate_boolean validate_lower_sha256 \
    validate_install_mode normalize_version validate_control_url \
    normalize_control_url validate_egress_id validate_positive_integer \
    validate_public_endpoint validate_image_reference all_addresses_equal \
    validate_enrollment_file validate_already_connected_file response_has_no_store \
    load_enrollment_file validate_loaded_config \
    read_env_value load_existing_env ensure_install_directories ensure_certificate_directory \
    package_installed install_base_packages verify_supported_os detect_host_platform \
    detect_installation_state write_installation_record installed_runtime \
    installed_version runtime_installation_complete \
    configure_docker_repository enable_docker_service install_docker \
    ensure_native_user resolve_latest_version prepare_runtime_config \
    download_native_binary write_native_service run_native_command \
    wait_for_native_health start_native_egress \
    claim_enrollment commit_claim_response write_enrollment_fingerprint \
    require_matching_fingerprint \
    fingerprint_matches existing_enrollment_mode claim_matches_existing_config \
    load_partial_enrollment_identity refresh_existing_enrollment \
    install_unconfigured_enrollment \
    write_service_env write_compose_file \
    discover_public_ip canonicalize_ipv6 resolve_ipv4 resolve_ipv6 \
    verify_domain_points_here \
    issue_and_install_certificate write_renewal_hook compose wait_for_health \
    start_docker_egress update_existing_installation cleanup_sensitive_files installer_main)
  exec -a one-browser-egress-installer /bin/bash -c \
    "${stage_code}"$'\n''installer_main "$@"' \
    one-browser-egress-installer-stage2 \
    "$control_url" "$token_file" "$enrollment_fingerprint" "$replace_existing" "$tls_enabled" \
    "$install_mode" "$requested_version"
}

if [ "${ONE_BROWSER_INSTALLER_LIBRARY_ONLY:-0}" != 1 ]; then
  bootstrap "$@"
fi
