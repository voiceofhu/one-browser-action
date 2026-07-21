#!/usr/bin/env bash

set -Eeuo pipefail

: "${SSH_HOST:?SSH_HOST is required}"

REGISTRY_ACTION=${REGISTRY_ACTION:-login}
REGISTRY_HOST=${REGISTRY_HOST:-ghcr.io}
USE_SUDO=${USE_SUDO:-0}

case "$USE_SUDO" in
  0|1) ;;
  *)
    echo "USE_SUDO must be 0 or 1" >&2
    exit 1
    ;;
esac

docker_command=(docker)
if [ "$USE_SUDO" = 1 ]; then
  docker_command=(sudo -n docker)
fi

shell_quote() {
  printf '%q' "$1"
}

remote_docker=$(printf '%q ' "${docker_command[@]}")

case "$REGISTRY_ACTION" in
  login)
    : "${GHCR_USERNAME:?GHCR_USERNAME is required}"
    : "${GHCR_READ_TOKEN:?GHCR_READ_TOKEN is required}"
    # The registry and username are escaped with printf %q before remote expansion.
    # shellcheck disable=SC2029
    printf '%s' "$GHCR_READ_TOKEN" | ssh "$SSH_HOST" \
      "$remote_docker login $(shell_quote "$REGISTRY_HOST") --username $(shell_quote "$GHCR_USERNAME") --password-stdin"
    ;;
  logout)
    # The registry is escaped with printf %q before remote expansion.
    # shellcheck disable=SC2029
    ssh "$SSH_HOST" \
      "$remote_docker logout $(shell_quote "$REGISTRY_HOST")"
    ;;
  *)
    echo "REGISTRY_ACTION must be login or logout" >&2
    exit 1
    ;;
esac
