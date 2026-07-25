#!/usr/bin/env bash

set +x
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export ONE_BROWSER_UNINSTALLER_LIBRARY_ONLY=1
# shellcheck source=../uninstall.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../uninstall.sh"

tests_run=0

expect_mode() {
  local expected=$1
  local actual

  actual=$(detect_mode)
  [ "$actual" = "$expected" ] || {
    printf 'FAIL: expected mode %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  }
  tests_run=$((tests_run + 1))
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM HUP
INSTALL_DIR=$tmp_dir/opt
INSTALL_RECORD=$INSTALL_DIR/.installation
# shellcheck disable=SC2034
ENV_FILE=$INSTALL_DIR/.env
COMPOSE_FILE=$INSTALL_DIR/docker-compose.yml
NATIVE_BINARY=$tmp_dir/usr/local/bin/one-browser-egress
NATIVE_SERVICE_FILE=$tmp_dir/etc/systemd/system/one-browser-egress.service
mkdir -p "$INSTALL_DIR" "$(dirname "$NATIVE_BINARY")" "$(dirname "$NATIVE_SERVICE_FILE")"

[ -z "$(detect_mode)" ] || {
  printf 'FAIL: empty state should not have an installed mode\n' >&2
  exit 1
}
tests_run=$((tests_run + 1))

printf 'runtime=docker\n' >"$INSTALL_RECORD"
expect_mode docker
printf 'runtime=native\n' >"$INSTALL_RECORD"
expect_mode native
printf 'runtime=invalid\n' >"$INSTALL_RECORD"
: >"$COMPOSE_FILE"
expect_mode docker
rm -f "$COMPOSE_FILE"
: >"$NATIVE_SERVICE_FILE"
expect_mode native
rm -f "$NATIVE_SERVICE_FILE" "$INSTALL_RECORD"
: >"$ENV_FILE"
expect_mode native
printf 'DOCKER_IMAGE=ghcr.io/voiceofhu/one-browser-egress:latest\n' >"$ENV_FILE"
expect_mode docker

validate_mode docker
validate_mode native
if validate_mode invalid; then
  printf 'FAIL: invalid runtime was accepted\n' >&2
  exit 1
fi
tests_run=$((tests_run + 3))

main --help >/dev/null
tests_run=$((tests_run + 1))

printf 'PASS: %d uninstaller tests\n' "$tests_run"
