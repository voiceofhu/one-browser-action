# shellcheck shell=bash
# Installer globals are shared across sourced modules.
# shellcheck disable=SC2034,SC2153

claim_enrollment() {
  local requested_control_url=$1
  local token_file=$2
  local requested_tls_enabled=$3
  local enroll_url header_size http_code response_size token
  local -a curl_transport

  CLAIM_OUTCOME=
  [ -f "$token_file" ] && [ ! -L "$token_file" ] || die "Enrollment token state is unavailable"
  token=$(<"$token_file")
  validate_secret_token "$token" || die "Enrollment token is invalid"
  enroll_url="${requested_control_url}/internal/egress/v1/enroll"
  CURL_CONFIG_FILE=$(mktemp "$RUN_DIR/curl-config.XXXXXX")
  RESPONSE_HEADER_FILE=$(mktemp "$RUN_DIR/response-headers.XXXXXX")
  chmod 0600 "$CURL_CONFIG_FILE"
  chmod 0600 "$RESPONSE_HEADER_FILE"
  cat >"$CURL_CONFIG_FILE" <<EOF
silent
show-error
connect-timeout = 10
max-time = 60
request = "POST"
header = "Authorization: Bearer ${token}"
header = "Accept: application/json"
EOF
  token=

  if [ -e "$CLAIM_RESPONSE_FILE" ] && [ -L "$CLAIM_RESPONSE_FILE" ]; then
    die "$CLAIM_RESPONSE_FILE must not be a symbolic link"
  fi
  : >"$CLAIM_RESPONSE_FILE"
  chmod 0600 "$CLAIM_RESPONSE_FILE"
  log "Claiming the one-time enrollment"
  if [ "$requested_tls_enabled" = true ]; then
    curl_transport=(--proto '=https' --tlsv1.2)
  else
    curl_transport=(--proto '=http,https')
  fi
  if ! http_code=$(curl -q "${curl_transport[@]}" --config "$CURL_CONFIG_FILE" \
    --no-location \
    --url "$enroll_url" \
    --dump-header "$RESPONSE_HEADER_FILE" \
    --max-filesize 65536 \
    --output "$CLAIM_RESPONSE_FILE" \
    --write-out '%{http_code}'); then
    die "Enrollment request failed; fix connectivity and run the generated command again"
  fi
  rm -f "$CURL_CONFIG_FILE" "$token_file"
  CURL_CONFIG_FILE=
  TOKEN_FILE=
  response_size=$(stat -c '%s' "$CLAIM_RESPONSE_FILE")
  validate_positive_integer "$response_size" 1 65536 || {
    rm -f "$CLAIM_RESPONSE_FILE" "$RESPONSE_HEADER_FILE"
    RESPONSE_HEADER_FILE=
    die "Enrollment response exceeds the 64 KiB limit"
  }
  header_size=$(stat -c '%s' "$RESPONSE_HEADER_FILE")
  validate_positive_integer "$header_size" 1 65536 || {
    rm -f "$CLAIM_RESPONSE_FILE" "$RESPONSE_HEADER_FILE"
    RESPONSE_HEADER_FILE=
    die "Enrollment response headers exceed the 64 KiB limit"
  }
  response_has_no_store "$RESPONSE_HEADER_FILE" || {
    rm -f "$CLAIM_RESPONSE_FILE" "$RESPONSE_HEADER_FILE"
    RESPONSE_HEADER_FILE=
    die "Enrollment response is missing Cache-Control: no-store"
  }
  rm -f "$RESPONSE_HEADER_FILE"
  RESPONSE_HEADER_FILE=
  if [ "$http_code" = 200 ]; then
    validate_enrollment_file "$CLAIM_RESPONSE_FILE" || {
      rm -f "$CLAIM_RESPONSE_FILE"
      die "Enrollment response is not valid v1 JSON"
    }
    CLAIM_OUTCOME=claimed
    return 0
  fi
  if [ "$http_code" = 409 ] && validate_already_connected_file "$CLAIM_RESPONSE_FILE"; then
    rm -f "$CLAIM_RESPONSE_FILE"
    CLAIM_OUTCOME=already_connected
    return 0
  fi
  rm -f "$CLAIM_RESPONSE_FILE"
  if [ "$http_code" = 401 ]; then
    die "Enrollment token is invalid, expired, or cancelled"
  fi
  if [ "$http_code" = 409 ]; then
    die "Enrollment request returned an unsupported conflict response"
  fi
  die "Enrollment request returned HTTP $http_code"
}

commit_claim_response() {
  [ -f "$CLAIM_RESPONSE_FILE" ] && [ ! -L "$CLAIM_RESPONSE_FILE" ] ||
    die "Validated enrollment response is unavailable"
  mv -f "$CLAIM_RESPONSE_FILE" "$SAVED_RESPONSE"
  chmod 0600 "$SAVED_RESPONSE"
  CLAIM_RESPONSE_FILE=
}

write_enrollment_fingerprint() {
  local fingerprint=$1
  local fingerprint_tmp

  [[ "$fingerprint" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Enrollment fingerprint is invalid"
  fingerprint_tmp=$(mktemp "$INSTALL_DIR/.enrollment-fingerprint.tmp.XXXXXX")
  printf '%s\n' "$fingerprint" >"$fingerprint_tmp"
  chown root:root "$fingerprint_tmp"
  chmod 0600 "$fingerprint_tmp"
  mv -f "$fingerprint_tmp" "$FINGERPRINT_FILE"
}

require_matching_fingerprint() {
  local requested_fingerprint=$1
  local saved_fingerprint

  [ -f "$FINGERPRINT_FILE" ] && [ ! -L "$FINGERPRINT_FILE" ] ||
    die "This host already has Egress state from another installation; refusing to consume a new enrollment"
  chown root:root "$FINGERPRINT_FILE"
  chmod 0600 "$FINGERPRINT_FILE"
  saved_fingerprint=$(<"$FINGERPRINT_FILE")
  [ "$saved_fingerprint" = "$requested_fingerprint" ] ||
    die "This host is already configured with a different enrollment; the new token was not consumed"
}

fingerprint_matches() {
  local requested_fingerprint=$1
  local saved_fingerprint

  [ -f "$FINGERPRINT_FILE" ] && [ ! -L "$FINGERPRINT_FILE" ] || return 1
  chown root:root "$FINGERPRINT_FILE" || return 1
  chmod 0600 "$FINGERPRINT_FILE" || return 1
  saved_fingerprint=$(<"$FINGERPRINT_FILE") || return 1
  [ "$saved_fingerprint" = "$requested_fingerprint" ]
}

existing_enrollment_mode() {
  local requested_fingerprint=$1
  local allow_replacement=$2

  if fingerprint_matches "$requested_fingerprint"; then
    printf 'renew'
    return 0
  fi
  if [ "$allow_replacement" = 1 ]; then
    printf 'replace'
    return 0
  fi
  return 1
}

claim_matches_existing_config() {
  local mode=$1
  local existing_egress_id=$2
  local existing_domain=$3
  local existing_control_token=$4
  local existing_tls_enabled=${5-true}

  [ "$CONFIG_EGRESS_ID" = "$existing_egress_id" ] || return 1
  [ "$CONFIG_DOMAIN" = "$existing_domain" ] || return 1
  [ "$CONFIG_TLS_ENABLED" = "$existing_tls_enabled" ] || return 1
  if [ "$mode" = renew ]; then
    [ "$CONFIG_CONTROL_TOKEN" = "$existing_control_token" ] || return 1
  fi
}

load_partial_enrollment_identity() {
  local candidate

  PARTIAL_EGRESS_ID=
  PARTIAL_DOMAIN=
  PARTIAL_TLS_ENABLED=
  for candidate in "$SAVED_RESPONSE" "$PENDING_RESPONSE"; do
    [ -e "$candidate" ] || continue
    [ -f "$candidate" ] && [ ! -L "$candidate" ] ||
      die "$candidate must be a regular file"
    if ! jq -e '
      type == "object" and
      (.egress_id | type == "string") and
      (.domain | type == "string") and
      (.tls_enabled | type == "boolean")
    ' "$candidate" >/dev/null 2>&1; then
      continue
    fi
    PARTIAL_EGRESS_ID=$(jq -r '.egress_id' "$candidate")
    PARTIAL_DOMAIN=$(jq -r '.domain' "$candidate")
    PARTIAL_TLS_ENABLED=$(jq -r '.tls_enabled' "$candidate")
    if validate_egress_id "$PARTIAL_EGRESS_ID" &&
      validate_domain "$PARTIAL_DOMAIN" &&
      validate_boolean "$PARTIAL_TLS_ENABLED"; then
      return 0
    fi
    PARTIAL_EGRESS_ID=
    PARTIAL_DOMAIN=
    PARTIAL_TLS_ENABLED=
  done
  return 1
}

refresh_existing_enrollment() {
  local requested_control_url=$1
  local token_file=$2
  local requested_fingerprint=$3
  local mode=$4
  local existing_control_token existing_domain existing_egress_id existing_tls_enabled

  load_existing_env "$ENV_FILE"
  prepare_runtime_config
  existing_egress_id=$CONFIG_EGRESS_ID
  existing_domain=$CONFIG_DOMAIN
  existing_control_token=$CONFIG_CONTROL_TOKEN
  existing_tls_enabled=$CONFIG_TLS_ENABLED
  claim_enrollment "$requested_control_url" "$token_file" "$REQUESTED_TLS_ENABLED"
  if [ "$CLAIM_OUTCOME" = already_connected ]; then
    if [ "$mode" != renew ]; then
      CONFIG_CONTROL_TOKEN=
      existing_control_token=
      die "Replacement enrollment is already connected; existing configuration was not changed"
    fi
    rm -f "$SAVED_RESPONSE" "$PENDING_RESPONSE"
    write_service_env
    CONFIG_CONTROL_TOKEN=
    existing_control_token=
    log "Server confirms this matching enrollment is already connected; continuing with existing configuration"
    return 0
  fi
  [ "$CLAIM_OUTCOME" = claimed ] || die "Enrollment claim returned an invalid outcome"
  load_enrollment_file "$CLAIM_RESPONSE_FILE"
  prepare_runtime_config
  if ! claim_matches_existing_config \
    "$mode" \
    "$existing_egress_id" \
    "$existing_domain" \
    "$existing_control_token" \
    "$existing_tls_enabled"; then
    rm -f "$CLAIM_RESPONSE_FILE"
    CONFIG_CONTROL_TOKEN=
    existing_control_token=
    if [ "$mode" = renew ]; then
      die "Renewed enrollment does not match the existing node ID, domain, and control token; existing configuration was not changed"
    fi
    die "Replacement enrollment does not match the existing node ID and domain; existing configuration was not changed"
  fi
  write_service_env
  write_enrollment_fingerprint "$requested_fingerprint"
  rm -f "$CLAIM_RESPONSE_FILE" "$SAVED_RESPONSE" "$PENDING_RESPONSE"
  CONFIG_CONTROL_TOKEN=
  existing_control_token=
}

install_unconfigured_enrollment() {
  local requested_control_url=$1
  local token_file=$2
  local requested_fingerprint=$3
  local replace_existing=$4
  local partial_identity=0

  if [ "$replace_existing" = 1 ] && load_partial_enrollment_identity; then
    partial_identity=1
    log "Protected partial enrollment identity found; replacement must match its node ID and domain"
  fi
  if [ "$replace_existing" = 0 ] && [ ! -e "$FINGERPRINT_FILE" ]; then
    write_enrollment_fingerprint "$requested_fingerprint"
  fi
  claim_enrollment "$requested_control_url" "$token_file" "$REQUESTED_TLS_ENABLED"
  [ "$CLAIM_OUTCOME" = claimed ] ||
    die "Server reports this enrollment is already connected, but no protected local configuration exists"
  load_enrollment_file "$CLAIM_RESPONSE_FILE"
  prepare_runtime_config
  if [ "$partial_identity" = 1 ] &&
    ! claim_matches_existing_config \
      replace "$PARTIAL_EGRESS_ID" "$PARTIAL_DOMAIN" "" "$PARTIAL_TLS_ENABLED"; then
    rm -f "$CLAIM_RESPONSE_FILE"
    CONFIG_CONTROL_TOKEN=
    die "Replacement enrollment does not match the protected partial node ID and domain; local state was not changed"
  fi
  commit_claim_response
  write_service_env
  write_enrollment_fingerprint "$requested_fingerprint"
  rm -f "$SAVED_RESPONSE" "$PENDING_RESPONSE"
}

write_service_env() {
  local bind_addr endpoint_port per_ip_limit per_connection_limit publish_addr env_tmp

  endpoint_port=${CONFIG_PUBLIC_ENDPOINT##*:}
  bind_addr=0.0.0.0:27600
  publish_addr=0.0.0.0
  if [ "$CONFIG_TLS_ENABLED" = false ]; then
    bind_addr='[::]:27600'
    publish_addr='[::]'
  fi
  per_ip_limit=64
  if [ "$CONFIG_MAX_CONNECTIONS" -lt "$per_ip_limit" ]; then
    per_ip_limit=$CONFIG_MAX_CONNECTIONS
  fi
  per_connection_limit=256
  if [ "$CONFIG_MAX_STREAMS" -lt "$per_connection_limit" ]; then
    per_connection_limit=$CONFIG_MAX_STREAMS
  fi

  env_tmp=$(mktemp "$INSTALL_DIR/.env.tmp.XXXXXX")
  chmod 0600 "$env_tmp"
  {
    if [ "$INSTALL_MODE" = docker ]; then
      printf 'DOCKER_IMAGE=%s\n' "$CONFIG_IMAGE"
      printf 'CONTAINER_NAME=one-browser-egress\n'
      printf 'CONTROL_NETWORK=one-browser-control\n\n'
    fi
    printf 'EGRESS_ID=%s\n' "$CONFIG_EGRESS_ID"
    printf 'EGRESS_PUBLIC_ENDPOINT=%s\n' "$CONFIG_PUBLIC_ENDPOINT"
    printf 'EGRESS_CONTROL_URL=%s\n' "$CONFIG_CONTROL_URL"
    printf 'EGRESS_CONTROL_TOKEN=%s\n\n' "$CONFIG_CONTROL_TOKEN"
    printf 'EGRESS_PUBLISH_ADDR=%s\n' "$publish_addr"
    printf 'EGRESS_HOST_PORT=%s\n' "$endpoint_port"
    printf 'EGRESS_BIND_ADDR=%s\n' "$bind_addr"
    printf 'EGRESS_HEALTHCHECK_ADDR=127.0.0.1:27600\n'
    printf 'EGRESS_TLS_ENABLED=%s\n' "$CONFIG_TLS_ENABLED"
    if [ "$CONFIG_TLS_ENABLED" = true ]; then
      if [ "$INSTALL_MODE" = docker ]; then
        printf 'EGRESS_CERT_DIR=./certs\n'
        printf 'EGRESS_TLS_CERT_FILE=/app/tls/fullchain.pem\n'
        printf 'EGRESS_TLS_KEY_FILE=/app/tls/privkey.pem\n'
      else
        printf 'EGRESS_TLS_CERT_FILE=%s/fullchain.pem\n' "$CERT_DIR"
        printf 'EGRESS_TLS_KEY_FILE=%s/privkey.pem\n' "$CERT_DIR"
      fi
    fi
    printf '\n'
    printf 'EGRESS_MAX_CONNECTIONS=%s\n' "$CONFIG_MAX_CONNECTIONS"
    printf 'EGRESS_MAX_CONNECTIONS_PER_IP=%s\n' "$per_ip_limit"
    printf 'EGRESS_MAX_STREAMS_PER_CONNECTION=%s\n' "$per_connection_limit"
    printf 'EGRESS_MAX_STREAMS_GLOBAL=%s\n' "$CONFIG_MAX_STREAMS"
    printf 'EGRESS_AUTHORIZATION_TIMEOUT_SECONDS=5\n'
    printf 'RUST_LOG=one_browser_egress=info\n'
  } >"$env_tmp"
  chown root:root "$env_tmp"
  mv -f "$env_tmp" "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
}
