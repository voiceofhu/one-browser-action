# shellcheck shell=bash

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
