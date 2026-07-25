# shellcheck shell=bash
# Installer globals are shared across sourced modules.
# shellcheck disable=SC2034

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
  ensure_tls_configuration
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
