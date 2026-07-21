#!/usr/bin/env bash

set -Eeuo pipefail

: "${SSH_HOST:?SSH_HOST is required}"
: "${REMOTE_DIR:?REMOTE_DIR is required}"
: "${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required}"
: "${COMPOSE_SERVICE_NAME:?COMPOSE_SERVICE_NAME is required}"
: "${CONTAINER_NAME:?CONTAINER_NAME is required}"
: "${CONTROL_NETWORK:?CONTROL_NETWORK is required}"

USE_SUDO=${USE_SUDO:-0}
LOG_TAIL=${LOG_TAIL:-120}

if [ "$REMOTE_DIR" != "/opt/one-browser-egress" ]; then
  echo "REMOTE_DIR must be /opt/one-browser-egress" >&2
  exit 1
fi
case "$USE_SUDO" in
  0|1) ;;
  *)
    echo "USE_SUDO must be 0 or 1" >&2
    exit 1
    ;;
esac

shell_quote() {
  printf '%q' "$1"
}

# Values are validated locally and escaped with printf %q before remote expansion.
# shellcheck disable=SC2029
ssh "$SSH_HOST" \
  "REMOTE_DIR=$(shell_quote "$REMOTE_DIR") \
  COMPOSE_PROJECT_NAME=$(shell_quote "$COMPOSE_PROJECT_NAME") \
  COMPOSE_SERVICE_NAME=$(shell_quote "$COMPOSE_SERVICE_NAME") \
  CONTAINER_NAME=$(shell_quote "$CONTAINER_NAME") \
  CONTROL_NETWORK=$(shell_quote "$CONTROL_NETWORK") \
  USE_SUDO=$(shell_quote "$USE_SUDO") \
  LOG_TAIL=$(shell_quote "$LOG_TAIL") \
  bash -s" <<'REMOTE_ROLLBACK'
set -Eeuo pipefail

cd "$REMOTE_DIR"
previous_compose=docker-compose.yml.action-previous
rollback_image=one-browser-egress-rollback:previous

docker_run() {
  local runtime_env=(
    "DOCKER_IMAGE=$rollback_image"
    "CONTAINER_NAME=$CONTAINER_NAME"
    "CONTROL_NETWORK=$CONTROL_NETWORK"
    "SERVICE_ENV_FILE=.env"
  )
  if [ "$USE_SUDO" = "1" ]; then
    sudo -n env "${runtime_env[@]}" docker "$@"
  else
    env "${runtime_env[@]}" docker "$@"
  fi
}

if [ ! -f "$previous_compose" ]; then
  echo "No previous Egress deployment exists; removing the failed first deployment" >&2
  docker_run rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -f -- docker-compose.yml
  exit 0
fi

if ! docker_run image inspect "$rollback_image" >/dev/null 2>&1; then
  echo "Rollback image $rollback_image is unavailable" >&2
  exit 1
fi

docker_run compose \
  --project-name "$COMPOSE_PROJECT_NAME" \
  --env-file .env \
  -f "$previous_compose" \
  up -d "$COMPOSE_SERVICE_NAME"

for attempt in $(seq 1 30); do
  status=$(docker_run inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
    "$CONTAINER_NAME" 2>/dev/null || true)
  if [ "$status" = healthy ]; then
    mv -f -- "$previous_compose" docker-compose.yml
    echo "Restored previous Egress deployment"
    exit 0
  fi
  if [ "$status" = unhealthy ] || [ "$attempt" = 30 ]; then
    echo "Rollback container failed health check; last status: ${status:-unknown}" >&2
    docker_run logs --tail "$LOG_TAIL" "$CONTAINER_NAME" || true
    exit 1
  fi
  sleep 5
done
REMOTE_ROLLBACK
