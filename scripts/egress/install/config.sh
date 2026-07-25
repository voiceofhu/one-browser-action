# shellcheck shell=bash

validate_enrollment_file() {
  local file=$1

  jq -e '
    type == "object" and
    keys == [
      "control_token",
      "control_url",
      "domain",
      "egress_id",
      "image",
      "max_connections",
      "max_streams",
      "public_endpoint",
      "tls_enabled",
      "version"
    ] and
    .version == "v1" and
    (.egress_id | type == "string") and
    (.domain | type == "string") and
    (.public_endpoint | type == "string") and
    (.tls_enabled | type == "boolean") and
    (.control_url | type == "string") and
    (.control_token | type == "string") and
    (.image | type == "string") and
    (.max_connections | type == "number" and . == floor) and
    (.max_streams | type == "number" and . == floor)
  ' "$file" >/dev/null
}

validate_already_connected_file() {
  local file=$1

  jq -e '
    type == "object" and
    keys == ["code", "message"] and
    .code == "already_connected" and
    (.message | type == "string")
  ' "$file" >/dev/null
}

response_has_no_store() {
  local file=$1

  awk '
    {
      line = tolower($0)
      sub(/\r$/, "", line)
      if (line ~ /^http\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]([[:space:]]|$)/) {
        saw_status = 1
        in_headers = 1
        found = 0
        next
      }
      if (in_headers && line == "") {
        in_headers = 0
        next
      }
      if (in_headers && line ~ /^cache-control:[[:space:]]*/ &&
          line ~ /(^|[,:;[:space:]])no-store([,;[:space:]]|$)/) {
        found = 1
      }
    }
    END { exit(saw_status && found ? 0 : 1) }
  ' "$file"
}

load_enrollment_file() {
  local file=$1

  validate_enrollment_file "$file" || die "Enrollment response is not valid v1 JSON"
  CONFIG_EGRESS_ID=$(jq -r '.egress_id' "$file")
  CONFIG_DOMAIN=$(jq -r '.domain' "$file")
  CONFIG_PUBLIC_ENDPOINT=$(jq -r '.public_endpoint' "$file")
  CONFIG_TLS_ENABLED=$(jq -r '.tls_enabled' "$file")
  CONFIG_CONTROL_URL=$(jq -r '.control_url' "$file")
  CONFIG_CONTROL_TOKEN=$(jq -r '.control_token' "$file")
  CONFIG_IMAGE=$(jq -r '.image' "$file")
  CONFIG_MAX_CONNECTIONS=$(jq -r '.max_connections' "$file")
  CONFIG_MAX_STREAMS=$(jq -r '.max_streams' "$file")
  validate_loaded_config
}

validate_loaded_config() {
  validate_egress_id "$CONFIG_EGRESS_ID" || die "Server returned an invalid egress_id"
  validate_domain "$CONFIG_DOMAIN" || die "Server returned an invalid lowercase domain"
  validate_public_endpoint "$CONFIG_DOMAIN" "$CONFIG_PUBLIC_ENDPOINT" ||
    die "Server public_endpoint must be the enrolled domain plus a valid port"
  validate_boolean "$CONFIG_TLS_ENABLED" || die "Server returned an invalid tls_enabled"
  if [ -n "${REQUESTED_TLS_ENABLED:-}" ] &&
    [ "$CONFIG_TLS_ENABLED" != "$REQUESTED_TLS_ENABLED" ]; then
    die "Server tls_enabled does not match the generated installation command"
  fi
  validate_control_url "$CONFIG_CONTROL_URL" "$CONFIG_TLS_ENABLED" ||
    die "Server returned a control_url that is invalid for tls_enabled=$CONFIG_TLS_ENABLED"
  validate_secret_token "$CONFIG_CONTROL_TOKEN" || die "Server returned an invalid control_token"
  validate_image_reference "$CONFIG_IMAGE" || die "Server returned an invalid image reference"
  validate_positive_integer "$CONFIG_MAX_CONNECTIONS" 1 16384 ||
    die "Server max_connections must be between 1 and 16384"
  validate_positive_integer "$CONFIG_MAX_STREAMS" 1 65535 ||
    die "Server max_streams must be between 1 and 65535"
}

read_env_value() {
  local file=$1
  local key=$2

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
  ' "$file"
}

load_existing_env() {
  local file=$1

  [ -f "$file" ] && [ ! -L "$file" ] || die "$file must be a regular file"
  chown root:root "$file"
  chmod 0600 "$file"
  CONFIG_IMAGE=$(read_env_value "$file" DOCKER_IMAGE 2>/dev/null ||
    printf '%s:latest' "$EGRESS_IMAGE_REPOSITORY")
  CONFIG_EGRESS_ID=$(read_env_value "$file" EGRESS_ID) || die "Existing .env is missing EGRESS_ID"
  CONFIG_PUBLIC_ENDPOINT=$(read_env_value "$file" EGRESS_PUBLIC_ENDPOINT) ||
    die "Existing .env is missing EGRESS_PUBLIC_ENDPOINT"
  CONFIG_TLS_ENABLED=$(read_env_value "$file" EGRESS_TLS_ENABLED 2>/dev/null || printf true)
  CONFIG_DOMAIN=${CONFIG_PUBLIC_ENDPOINT%:*}
  CONFIG_CONTROL_URL=$(read_env_value "$file" EGRESS_CONTROL_URL) ||
    die "Existing .env is missing EGRESS_CONTROL_URL"
  CONFIG_CONTROL_TOKEN=$(read_env_value "$file" EGRESS_CONTROL_TOKEN) ||
    die "Existing .env is missing EGRESS_CONTROL_TOKEN"
  CONFIG_MAX_CONNECTIONS=$(read_env_value "$file" EGRESS_MAX_CONNECTIONS) ||
    die "Existing .env is missing EGRESS_MAX_CONNECTIONS"
  CONFIG_MAX_STREAMS=$(read_env_value "$file" EGRESS_MAX_STREAMS_GLOBAL) ||
    die "Existing .env is missing EGRESS_MAX_STREAMS_GLOBAL"
  validate_loaded_config
}
