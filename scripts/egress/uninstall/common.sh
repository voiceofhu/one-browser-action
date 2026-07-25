#!/usr/bin/env bash

# Shared configuration and mode detection for the Egress uninstaller.
# Uninstaller globals are shared across sourced modules.
# shellcheck disable=SC2034

set +x
set -Eeuo pipefail

INSTALL_DIR=/opt/one-browser-egress
INSTALL_RECORD=$INSTALL_DIR/.installation
ENV_FILE=$INSTALL_DIR/.env
COMPOSE_FILE=$INSTALL_DIR/docker-compose.yml
NATIVE_BINARY=/usr/local/bin/one-browser-egress
NATIVE_SERVICE_FILE=/etc/systemd/system/one-browser-egress.service
RENEWAL_HOOK=/etc/letsencrypt/renewal-hooks/deploy/one-browser-egress.sh
RUN_DIR=/run/one-browser-egress-installer

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

show_help() {
  cat <<'EOF'
Uninstall One Browser Egress.

Usage:
  uninstall.sh [--mode <native|docker>]

Options:
  --mode       Optional safety check. When omitted, detect the installed mode.
  -h, --help   Show this help.

The Egress service, binary/container, and /opt/one-browser-egress state are
removed. Docker itself and certificates managed by Certbot are preserved.
EOF
}

validate_mode() {
  [ "${1-}" = native ] || [ "${1-}" = docker ]
}

read_record_value() {
  local key=$1

  [ -f "$INSTALL_RECORD" ] && [ ! -L "$INSTALL_RECORD" ] || return 1
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
  ' "$INSTALL_RECORD"
}

detect_mode() {
  local recorded

  recorded=$(read_record_value runtime 2>/dev/null || true)
  if validate_mode "$recorded"; then
    printf '%s' "$recorded"
  elif [ -e "$NATIVE_SERVICE_FILE" ] || [ -e "$NATIVE_BINARY" ]; then
    printf 'native'
  elif [ -e "$COMPOSE_FILE" ]; then
    printf 'docker'
  elif [ -f "$ENV_FILE" ] && grep -q '^DOCKER_IMAGE=' "$ENV_FILE"; then
    printf 'docker'
  elif [ -e "$ENV_FILE" ]; then
    printf 'native'
  fi
}
