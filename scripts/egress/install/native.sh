# shellcheck shell=bash
# Installer globals are shared across sourced modules.
# shellcheck disable=SC2034

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
