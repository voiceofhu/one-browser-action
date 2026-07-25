#!/usr/bin/env bash

# Public One Browser Egress uninstaller for Debian and Ubuntu.

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

uninstall_native() {
  command -v systemctl >/dev/null 2>&1 ||
    die "systemctl is required to remove the native Egress service"
  systemctl stop one-browser-egress >/dev/null 2>&1 || true
  if systemctl is-active --quiet one-browser-egress; then
    die "The native Egress service could not be stopped"
  fi
  systemctl disable one-browser-egress >/dev/null 2>&1 || true
  rm -f -- "$NATIVE_SERVICE_FILE" "$NATIVE_BINARY"
  systemctl daemon-reload
  systemctl reset-failed one-browser-egress >/dev/null 2>&1 || true
  if id one-browser-egress >/dev/null 2>&1 && command -v userdel >/dev/null 2>&1; then
    userdel one-browser-egress >/dev/null 2>&1 || true
  fi
}

uninstall_docker() {
  command -v docker >/dev/null 2>&1 ||
    die "Docker is required to remove the Docker Egress container"
  docker info >/dev/null 2>&1 ||
    die "Docker daemon is unavailable; start it before uninstalling Egress"
  if [ -f "$COMPOSE_FILE" ] && [ -f "$ENV_FILE" ] &&
    docker compose version >/dev/null 2>&1; then
    docker compose --project-name one-browser-egress \
      --env-file "$ENV_FILE" -f "$COMPOSE_FILE" \
      down --remove-orphans >/dev/null ||
      die "Docker Compose could not remove Egress"
  elif docker container inspect one-browser-egress >/dev/null 2>&1; then
    docker rm --force one-browser-egress >/dev/null ||
      die "Docker could not remove the Egress container"
  fi
  docker container inspect one-browser-egress >/dev/null 2>&1 &&
    die "The Docker Egress container still exists after uninstall"
  return 0
}

main() {
  local detected_mode requested_mode=

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        [ "$#" -ge 2 ] || die "--mode requires a value"
        [ -z "$requested_mode" ] || die "--mode may be supplied only once"
        requested_mode=$2
        shift 2
        ;;
      -h|--help)
        show_help
        return 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  if [ -n "$requested_mode" ]; then
    validate_mode "$requested_mode" || die "--mode must be native or docker"
  fi
  [ "${EUID:-$(id -u)}" -eq 0 ] ||
    die "Run this uninstaller as root (the generated command uses sudo)"
  umask 077
  install -d -m 0700 -o root -g root "$RUN_DIR"
  exec 9>"$RUN_DIR/install.lock"
  flock -n 9 || die "An Egress installation or uninstall is already running"

  detected_mode=$(detect_mode)
  if [ -z "$detected_mode" ]; then
    log "No One Browser Egress installation was found"
    return 0
  fi
  if [ -n "$requested_mode" ] && [ "$requested_mode" != "$detected_mode" ]; then
    die "Installed mode is $detected_mode, not $requested_mode"
  fi

  log "Stopping and removing the $detected_mode Egress runtime"
  if [ "$detected_mode" = native ]; then
    uninstall_native
  else
    uninstall_docker
  fi
  rm -f -- "$RENEWAL_HOOK"
  rm -rf -- "$INSTALL_DIR"
  log "One Browser Egress was uninstalled; Docker and Certbot certificates were preserved"
}

if [ "${ONE_BROWSER_UNINSTALLER_LIBRARY_ONLY:-0}" != 1 ]; then
  main "$@"
fi
