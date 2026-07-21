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
    : "${GH_TOKEN:?GH_TOKEN is required}"
    registry_username=$(gh api user --jq .login)
    if [ -z "$registry_username" ]; then
      echo "Could not resolve the GitHub username for GH_TOKEN" >&2
      exit 1
    fi
    # The registry and username are escaped with printf %q before remote expansion.
    # shellcheck disable=SC2029
    printf '%s' "$GH_TOKEN" | ssh "$SSH_HOST" \
      "$remote_docker login $(shell_quote "$REGISTRY_HOST") --username $(shell_quote "$registry_username") --password-stdin"
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
