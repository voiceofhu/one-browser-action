# shellcheck shell=bash

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
