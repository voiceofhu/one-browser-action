#!/usr/bin/env bash

set +x
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALLER=$SCRIPT_DIR/../install.sh
export ONE_BROWSER_INSTALLER_LIBRARY_ONLY=1
# shellcheck source=../install.sh
# shellcheck disable=SC1091
. "$INSTALLER"

tests_run=0

pass() {
  tests_run=$((tests_run + 1))
}

expect_success() {
  local description=$1
  shift
  if ! "$@"; then
    printf 'FAIL: expected success: %s\n' "$description" >&2
    exit 1
  fi
  pass
}

expect_failure() {
  local description=$1
  shift
  if ("$@" >/dev/null 2>&1); then
    printf 'FAIL: expected failure: %s\n' "$description" >&2
    exit 1
  fi
  pass
}

expect_success "lowercase public domain" validate_domain egress.example.com
expect_failure "single-label domain" validate_domain localhost
expect_failure "uppercase domain" validate_domain Egress.example.com
expect_failure "leading label hyphen" validate_domain -egress.example.com
expect_failure "domain with shell characters" validate_domain 'egress.example.com;id'

# shellcheck disable=SC2329
mock_commit_pinned_installer_base() (
  curl() {
    printf '%s\n' \
      '{"ref":"refs/heads/main","object":{"type":"commit","sha":"0123456789abcdef0123456789abcdef01234567"}}'
  }
  egress_entrypoint_resolve_default_base_url 2>/dev/null
)
[ "$(mock_commit_pinned_installer_base)" = \
  'https://raw.githubusercontent.com/voiceofhu/one-browser-action/0123456789abcdef0123456789abcdef01234567/scripts/egress' ] || {
  printf 'FAIL: public installer modules were not pinned to one commit\n' >&2
  exit 1
}
pass

expect_success "HTTPS origin" validate_control_url https://browser.example.com
expect_success "HTTPS origin with port and slash" validate_control_url https://browser.example.com:8443/
expect_failure "plaintext control URL" validate_control_url http://browser.example.com
expect_success "development HTTP origin" \
  validate_control_url http://host.orb.internal:27512 false
expect_success "development HTTP IPv4 origin" \
  validate_control_url http://192.168.139.1:27512 false
expect_failure "production rejects development HTTP origin" \
  validate_control_url http://host.orb.internal:27512 true
expect_failure "control URL credentials" validate_control_url https://user@browser.example.com
expect_failure "control URL path" validate_control_url https://browser.example.com/app

expect_success "native install mode" validate_install_mode native
expect_success "Docker install mode" validate_install_mode docker
expect_failure "unknown install mode" validate_install_mode package
[ "$(normalize_version latest)" = latest ] || exit 1
pass
[ "$(normalize_version egress-v26.724.1)" = 26.724.1 ] || exit 1
pass
expect_failure "invalid semantic version" normalize_version 26.latest
valid_installer_sha=$(printf 'a%.0s' {1..64})
expect_success "lowercase binary checksum" validate_lower_sha256 "$valid_installer_sha"
expect_failure "uppercase installer checksum" validate_lower_sha256 \
  "$(printf 'A%.0s' {1..64})"

valid_token=abcdefghijklmnopqrstuvwxyz0123456789._~-
expect_success "URL-safe token" validate_secret_token "$valid_token"
expect_failure "short token" validate_secret_token too-short
expect_failure "token with whitespace" validate_secret_token 'abcdefghijklmnopqrstuvwxyz 0123456789'

both_token_sources() {
  ONE_BROWSER_ENROLLMENT_TOKEN=$valid_token bootstrap \
    --mode native \
    --control-url https://browser.example.com \
    --tls-enabled true \
    --enrollment-token "$valid_token"
}
expect_failure "environment and argument token inputs are mutually exclusive" both_token_sources
duplicate_replace_flags() {
  ONE_BROWSER_ENROLLMENT_TOKEN=$valid_token bootstrap \
    --mode native \
    --control-url https://browser.example.com \
    --tls-enabled true \
    --replace-existing-enrollment \
    --replace-existing-enrollment
}
expect_failure "replacement flag must be explicit and unique" duplicate_replace_flags
duplicate_versions() {
  ONE_BROWSER_ENROLLMENT_TOKEN=$valid_token bootstrap \
    --mode native \
    --control-url https://browser.example.com \
    --tls-enabled true \
    --version 26.724.1 \
    --version 26.724.2
}
expect_failure "version may be supplied only once" duplicate_versions
ONE_BROWSER_ENROLLMENT_TOKEN=$valid_token
bootstrap --help >/dev/null
[ -z "${ONE_BROWSER_ENROLLMENT_TOKEN+x}" ] || {
  printf 'FAIL: bootstrap did not unset the environment token\n' >&2
  exit 1
}
pass

expect_success "matching endpoint" validate_public_endpoint egress.example.com egress.example.com:27600
expect_failure "different endpoint host" validate_public_endpoint egress.example.com other.example.com:27600
expect_failure "invalid endpoint port" validate_public_endpoint egress.example.com egress.example.com:70000

expect_success "immutable SHA image tag" validate_image_reference \
  ghcr.io/voiceofhu/one-browser-egress:sha-0123456789abcdef
expect_success "digest image" validate_image_reference \
  "ghcr.io/voiceofhu/one-browser-egress@sha256:$(printf 'a%.0s' {1..64})"
expect_success "latest image" validate_image_reference ghcr.io/voiceofhu/one-browser-egress:latest
# shellcheck disable=SC2016
expect_failure "image interpolation" validate_image_reference 'ghcr.io/voiceofhu/egress:${TAG}'

expect_success "all DNS addresses match" all_addresses_equal $'203.0.113.8\n203.0.113.8' 203.0.113.8
expect_failure "one DNS address differs" all_addresses_equal $'203.0.113.8\n203.0.113.9' 203.0.113.8
normalized_ipv6=$(canonicalize_ipv6 2001:0db8:0:0:0:0:0:1)
[ "$normalized_ipv6" = '2001:db8::1' ] || {
  printf 'FAIL: equivalent IPv6 forms were not canonicalized\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_ipv4_dns_ready() (
  resolve_ipv4() { printf '8.8.8.8\n'; }
  resolve_ipv6() { :; }
  discover_public_ip() { printf '8.8.8.8'; }
  verify_domain_points_here egress.example.com >/dev/null
)
expect_success "IPv4-only DNS matching this host" mock_ipv4_dns_ready

# shellcheck disable=SC2329
mock_aaaa_dns_rejected() (
  resolve_ipv4() { printf '8.8.8.8\n'; }
  resolve_ipv6() { printf '2606:4700:4700::1111\n'; }
  discover_public_ip() { printf '8.8.8.8'; }
  verify_domain_points_here egress.example.com
)
expect_failure "AAAA records are rejected until dual-stack publishing is supported" \
  mock_aaaa_dns_rejected

# shellcheck disable=SC2329
mock_aaaa_only_dns_rejected() (
  resolve_ipv4() { :; }
  resolve_ipv6() { printf '2606:4700:4700::1111\n'; }
  discover_public_ip() { printf '8.8.8.8'; }
  verify_domain_points_here egress.example.com
)
expect_failure "AAAA-only DNS is rejected" mock_aaaa_only_dns_rejected

# shellcheck disable=SC2329
mock_portable_ipv4_filtering() (
  dig() {
    printf '%s\n' \
      104.194.67.193 \
      104.194.67.193 \
      999.194.67.193 \
      not-an-address
  }
  query_ipv4_records egress-1.aicbe.com
)
[ "$(mock_portable_ipv4_filtering)" = 104.194.67.193 ] || {
  printf 'FAIL: portable IPv4 query filtering did not retain only valid unique addresses\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_public_dns_fallback() (
  query_ipv4_records() { return 0; }
  query_public_ipv4_records() { printf '104.194.67.193\n'; }
  log() { :; }
  resolve_ipv4 egress-1.aicbe.com
)
[ "$(mock_public_dns_fallback)" = 104.194.67.193 ] || {
  printf 'FAIL: public DNS fallback did not recover from a stale system resolver\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_public_aaaa_fallback() (
  query_ipv6_records() { return 0; }
  query_public_ipv6_records() { printf '2001:db8::1\n'; }
  resolve_ipv6 egress.example.com
)
[ "$(mock_public_aaaa_fallback)" = 2001:db8::1 ] || {
  printf 'FAIL: public DNS fallback did not preserve IPv6 rejection checks\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_doh_json_response() (
  curl() {
    printf '%s\n' \
      '{"Status":0,"Answer":[{"name":"egress-1.aicbe.com.","type":1,"TTL":300,"data":"104.194.67.193"},{"name":"egress-1.aicbe.com.","type":28,"TTL":300,"data":"2001:db8::1"}]}'
  }
  query_public_dns_records \
    egress-1.aicbe.com \
    1 \
    https://dns.google/resolve
)
[ "$(mock_doh_json_response)" = 104.194.67.193 ] || {
  printf 'FAIL: DNS-over-HTTPS JSON response was not parsed by record type\n' >&2
  exit 1
}
pass

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM HUP

# shellcheck disable=SC2329
mock_linux_amd64_platform() (
  uname() {
    case "$1" in
      -s) printf 'Linux\n' ;;
      -m) printf 'x86_64\n' ;;
      *) return 1 ;;
    esac
  }
  detect_host_platform
)
[ "$(mock_linux_amd64_platform)" = linux-amd64 ] || {
  printf 'FAIL: x86_64 platform was not normalized\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_linux_arm64_platform() (
  uname() {
    case "$1" in
      -s) printf 'Linux\n' ;;
      -m) printf 'aarch64\n' ;;
      *) return 1 ;;
    esac
  }
  detect_host_platform
)
[ "$(mock_linux_arm64_platform)" = linux-arm64 ] || {
  printf 'FAIL: aarch64 platform was not normalized\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_prepare_latest_docker_runtime() (
  resolve_latest_version() { printf '26.725.1317'; }
  INSTALL_MODE=docker
  REQUESTED_VERSION=latest
  RESOLVED_VERSION=
  EGRESS_IMAGE_REPOSITORY=ghcr.io/voiceofhu/one-browser-egress
  CONFIG_IMAGE=server-selected-image:unused
  prepare_runtime_config
  [ "$RESOLVED_VERSION" = 26.725.1317 ] &&
    [ "$CONFIG_IMAGE" = ghcr.io/voiceofhu/one-browser-egress:26.725.1317 ]
)
expect_success "default Docker install resolves latest to a concrete version" \
  mock_prepare_latest_docker_runtime
INSTALL_MODE=docker
# shellcheck disable=SC2034
REQUESTED_VERSION=26.724.1
RESOLVED_VERSION=
EGRESS_IMAGE_REPOSITORY=ghcr.io/voiceofhu/one-browser-egress
CONFIG_IMAGE=server-selected-image:unused
prepare_runtime_config
[ "$RESOLVED_VERSION" = 26.724.1 ] &&
  [ "$CONFIG_IMAGE" = ghcr.io/voiceofhu/one-browser-egress:26.724.1 ] || {
  printf 'FAIL: versioned Docker install did not select the requested image\n' >&2
  exit 1
}
pass
# shellcheck disable=SC2329
docker_build_metadata_version() (
  INSTALL_MODE=docker
  # shellcheck disable=SC2034
  REQUESTED_VERSION=26.724.1+build.1
  RESOLVED_VERSION=
  EGRESS_IMAGE_REPOSITORY=ghcr.io/voiceofhu/one-browser-egress
  prepare_runtime_config
)
expect_failure "Docker version rejects build metadata unsupported by image tags" \
  docker_build_metadata_version

state_dir=$tmp_dir/state
mkdir -p "$state_dir"
ENV_FILE=$state_dir/.env
COMPOSE_FILE=$state_dir/docker-compose.yml
SAVED_RESPONSE=$state_dir/.enrollment-response.json
PENDING_RESPONSE=$state_dir/.enrollment-response.json.pending
FINGERPRINT_FILE=$state_dir/.enrollment-fingerprint
INSTALL_RECORD=$state_dir/.installation
# shellcheck disable=SC2034
NATIVE_BINARY=$state_dir/one-browser-egress
# shellcheck disable=SC2034
NATIVE_SERVICE_FILE=$state_dir/one-browser-egress.service
[ "$(detect_installation_state)" = fresh ] || {
  printf 'FAIL: empty install directory was not detected as fresh\n' >&2
  exit 1
}
pass
: >"$COMPOSE_FILE"
[ "$(detect_installation_state)" = partial ] || {
  printf 'FAIL: incomplete install directory was not detected as partial\n' >&2
  exit 1
}
pass
: >"$ENV_FILE"
[ "$(detect_installation_state)" = partial ] || {
  printf 'FAIL: environment without an installation record was not detected as partial\n' >&2
  exit 1
}
pass
cat >"$INSTALL_RECORD" <<'EOF'
schema=2
runtime=docker
platform=linux-amd64
version=26.725.1317
EOF
[ "$(installed_version)" = 26.725.1317 ] || {
  printf 'FAIL: concrete installed version was not detected\n' >&2
  exit 1
}
pass
sed 's/version=26.725.1317/version=latest/' "$INSTALL_RECORD" \
  >"$state_dir/.installation-latest"
INSTALL_RECORD=$state_dir/.installation-latest
expect_failure "legacy latest marker is not a concrete installed version" \
  installed_version
INSTALL_RECORD=$state_dir/.installation

INSTALL_MODE=docker
expect_success "complete Docker runtime files are detected" runtime_installation_complete
[ "$(detect_installation_state)" = installed ] || {
  printf 'FAIL: recorded complete Docker installation was not detected as installed\n' >&2
  exit 1
}
pass
INSTALL_MODE=native
expect_failure "missing native runtime files are incomplete" runtime_installation_complete
: >"$NATIVE_BINARY"
: >"$NATIVE_SERVICE_FILE"
chmod 0755 "$NATIVE_BINARY"
expect_success "complete native runtime files are detected" runtime_installation_complete

response_file=$tmp_dir/enrollment.json
cat >"$response_file" <<EOF
{
  "version": "v1",
  "egress_id": "hk-egress-01",
  "domain": "egress.example.com",
  "public_endpoint": "egress.example.com:27600",
  "tls_enabled": true,
  "control_url": "https://browser.example.com",
  "control_token": "$valid_token",
  "image": "ghcr.io/voiceofhu/one-browser-egress:sha-0123456789abcdef",
  "max_connections": 256,
  "max_streams": 2048
}
EOF
REQUESTED_TLS_ENABLED=true
expect_success "complete v1 enrollment response" validate_enrollment_file "$response_file"
jq '.unexpected = true' "$response_file" >"$tmp_dir/unknown-field.json"
expect_failure "v1 enrollment response rejects unknown fields" \
  validate_enrollment_file "$tmp_dir/unknown-field.json"
expect_success "load and validate response values" load_enrollment_file "$response_file"
[ "$CONFIG_EGRESS_ID" = hk-egress-01 ] || {
  printf 'FAIL: loaded egress_id differs\n' >&2
  exit 1
}
pass
[ "$CONFIG_MAX_CONNECTIONS" = 256 ] && [ "$CONFIG_MAX_STREAMS" = 2048 ] || {
  printf 'FAIL: loaded capacity differs\n' >&2
  exit 1
}
pass

test_control_token=$CONFIG_CONTROL_TOKEN

cat >"$tmp_dir/already-connected.json" <<'EOF'
{"code":"already_connected","message":"The Egress node is already connected."}
EOF
expect_success "exact already_connected error envelope" \
  validate_already_connected_file "$tmp_dir/already-connected.json"
jq '.detail = "unexpected"' "$tmp_dir/already-connected.json" \
  >"$tmp_dir/already-connected-extra.json"
expect_failure "already_connected rejects additional fields" \
  validate_already_connected_file "$tmp_dir/already-connected-extra.json"
jq 'del(.message)' "$tmp_dir/already-connected.json" \
  >"$tmp_dir/already-connected-no-message.json"
expect_failure "already_connected requires message" \
  validate_already_connected_file "$tmp_dir/already-connected-no-message.json"
jq '.message = 409' "$tmp_dir/already-connected.json" \
  >"$tmp_dir/already-connected-number-message.json"
expect_failure "already_connected requires a string message" \
  validate_already_connected_file "$tmp_dir/already-connected-number-message.json"

expect_success "same-token resume requires matching identity and control token" \
  claim_matches_existing_config renew hk-egress-01 egress.example.com "$test_control_token"
expect_failure "same-token resume rejects a changed control token" \
  claim_matches_existing_config renew hk-egress-01 egress.example.com different-control-token-value-123456
expect_success "explicit replacement permits a rotated control token for the same node" \
  claim_matches_existing_config replace hk-egress-01 egress.example.com different-control-token-value-123456
expect_failure "explicit replacement rejects a different node ID" \
  claim_matches_existing_config replace other-egress egress.example.com "$test_control_token"
expect_failure "explicit replacement rejects a different domain" \
  claim_matches_existing_config replace hk-egress-01 other.example.com "$test_control_token"

# shellcheck disable=SC2329
mock_same_token_refresh() {
  local calls=
  load_existing_env() {
    calls="${calls}load "
    CONFIG_EGRESS_ID=hk-egress-01
    CONFIG_DOMAIN=egress.example.com
    CONFIG_CONTROL_TOKEN=$test_control_token
    CONFIG_TLS_ENABLED=true
  }
  claim_enrollment() {
    calls="${calls}claim "
    CLAIM_OUTCOME=claimed
  }
  load_enrollment_file() {
    calls="${calls}response "
    CONFIG_EGRESS_ID=hk-egress-01
    CONFIG_DOMAIN=egress.example.com
    CONFIG_CONTROL_TOKEN=$test_control_token
    CONFIG_TLS_ENABLED=true
  }
  write_service_env() {
    calls="${calls}env "
  }
  write_enrollment_fingerprint() {
    [ "$1" = "$old_fingerprint" ] || return 1
    calls="${calls}fingerprint"
  }
  ENV_FILE=$tmp_dir/mock.env
  SAVED_RESPONSE=$tmp_dir/mock-response.json
  PENDING_RESPONSE=$tmp_dir/mock-response.pending
  CLAIM_RESPONSE_FILE=$tmp_dir/mock-response.candidate
  refresh_existing_enrollment \
    https://browser.example.com \
    "$tmp_dir/mock-token" \
    "$old_fingerprint" \
    renew
  printf '%s' "$calls"
}

old_fingerprint="sha256:$(printf 'a%.0s' {1..64})"
[ "$(mock_same_token_refresh)" = 'load claim response env fingerprint' ] || {
  printf 'FAIL: same-token resume did not claim before updating protected state\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_already_connected_resume() (
  load_existing_env() {
    CONFIG_EGRESS_ID=hk-egress-01
    CONFIG_DOMAIN=egress.example.com
    CONFIG_CONTROL_TOKEN=$test_control_token
    CONFIG_TLS_ENABLED=true
  }
  claim_enrollment() {
    CLAIM_OUTCOME=already_connected
    : >"$tmp_dir/connected-claim"
  }
  load_enrollment_file() {
    : >"$tmp_dir/connected-response-loaded"
  }
  write_service_env() {
    : >"$tmp_dir/connected-env-written"
  }
  write_enrollment_fingerprint() {
    : >"$tmp_dir/connected-fingerprint-written"
  }
  ENV_FILE=$tmp_dir/mock.env
  SAVED_RESPONSE=$tmp_dir/mock-response.json
  PENDING_RESPONSE=$tmp_dir/mock-response.pending
  CLAIM_RESPONSE_FILE=$tmp_dir/mock-response.candidate
  refresh_existing_enrollment \
    https://browser.example.com \
    "$tmp_dir/mock-token" \
    "$old_fingerprint" \
    renew >/dev/null
)

expect_success "matching local state accepts already_connected without secrets" \
  mock_already_connected_resume
[ -e "$tmp_dir/connected-claim" ] &&
  [ ! -e "$tmp_dir/connected-response-loaded" ] &&
  [ -e "$tmp_dir/connected-env-written" ] &&
  [ ! -e "$tmp_dir/connected-fingerprint-written" ] || {
  printf 'FAIL: already_connected did not update only the runtime configuration\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_replacement_already_connected() {
  load_existing_env() {
    CONFIG_EGRESS_ID=hk-egress-01
    CONFIG_DOMAIN=egress.example.com
    CONFIG_CONTROL_TOKEN=$test_control_token
    CONFIG_TLS_ENABLED=true
  }
  claim_enrollment() {
    CLAIM_OUTCOME=already_connected
  }
  write_service_env() {
    : >"$tmp_dir/replacement-connected-env-written"
  }
  ENV_FILE=$tmp_dir/mock.env
  SAVED_RESPONSE=$tmp_dir/mock-response.json
  PENDING_RESPONSE=$tmp_dir/mock-response.pending
  CLAIM_RESPONSE_FILE=$tmp_dir/mock-response.candidate
  refresh_existing_enrollment \
    https://browser.example.com \
    "$tmp_dir/mock-token" \
    "$new_fingerprint" \
    replace
}

new_fingerprint="sha256:$(printf 'b%.0s' {1..64})"
expect_failure "replacement mode rejects already_connected" mock_replacement_already_connected
[ ! -e "$tmp_dir/replacement-connected-env-written" ] || {
  printf 'FAIL: connected replacement rewrote protected configuration\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_replacement_mismatch() {
  load_existing_env() {
    CONFIG_EGRESS_ID=hk-egress-01
    CONFIG_DOMAIN=egress.example.com
    CONFIG_CONTROL_TOKEN=$test_control_token
  }
  claim_enrollment() {
    : >"$tmp_dir/replacement-claimed"
    CLAIM_OUTCOME=claimed
  }
  load_enrollment_file() {
    CONFIG_EGRESS_ID=hk-egress-01
    # shellcheck disable=SC2034
    CONFIG_DOMAIN=other.example.com
    CONFIG_CONTROL_TOKEN=replacement-control-token-value-123456
    CONFIG_TLS_ENABLED=true
  }
  write_service_env() {
    : >"$tmp_dir/replacement-env-written"
  }
  write_enrollment_fingerprint() {
    : >"$tmp_dir/replacement-fingerprint-written"
  }
  ENV_FILE=$tmp_dir/mock.env
  # shellcheck disable=SC2034
  SAVED_RESPONSE=$tmp_dir/mock-response.json
  # shellcheck disable=SC2034
  PENDING_RESPONSE=$tmp_dir/mock-response.pending
  CLAIM_RESPONSE_FILE=$tmp_dir/mock-response.candidate
  refresh_existing_enrollment \
    https://browser.example.com \
    "$tmp_dir/mock-token" \
    "sha256:$(printf 'b%.0s' {1..64})" \
    replace
}

expect_failure "mismatched replacement fails after claim" mock_replacement_mismatch
[ -e "$tmp_dir/replacement-claimed" ] &&
  [ ! -e "$tmp_dir/replacement-env-written" ] &&
  [ ! -e "$tmp_dir/replacement-fingerprint-written" ] || {
  printf 'FAIL: mismatched replacement changed protected local state\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_partial_replacement() (
  local returned_domain=$1
  load_partial_enrollment_identity() {
    # shellcheck disable=SC2034
    PARTIAL_EGRESS_ID=hk-egress-01
    # shellcheck disable=SC2034
    PARTIAL_DOMAIN=egress.example.com
    # shellcheck disable=SC2034
    PARTIAL_TLS_ENABLED=true
    return 0
  }
  claim_enrollment() {
    # shellcheck disable=SC2034
    CLAIM_OUTCOME=claimed
    : >"$tmp_dir/partial-claimed"
  }
  load_enrollment_file() {
    CONFIG_EGRESS_ID=hk-egress-01
    # shellcheck disable=SC2034
    CONFIG_DOMAIN=$returned_domain
    CONFIG_CONTROL_TOKEN=replacement-control-token-value-123456
    CONFIG_TLS_ENABLED=true
  }
  commit_claim_response() {
    : >"$tmp_dir/partial-committed"
  }
  write_service_env() {
    : >"$tmp_dir/partial-env-written"
  }
  write_enrollment_fingerprint() {
    : >"$tmp_dir/partial-fingerprint-written"
  }
  FINGERPRINT_FILE=$tmp_dir/partial-fingerprint-old
  # shellcheck disable=SC2034
  SAVED_RESPONSE=$tmp_dir/partial-response-old
  # shellcheck disable=SC2034
  PENDING_RESPONSE=$tmp_dir/partial-pending-old
  # shellcheck disable=SC2034
  CLAIM_RESPONSE_FILE=$tmp_dir/partial-candidate
  install_unconfigured_enrollment \
    https://browser.example.com \
    "$tmp_dir/mock-token" \
    "$new_fingerprint" \
    1 >/dev/null
)

: >"$tmp_dir/partial-response-old"
: >"$tmp_dir/partial-pending-old"
expect_success "matching partial-state replacement commits atomically" \
  mock_partial_replacement egress.example.com
[ -e "$tmp_dir/partial-claimed" ] &&
  [ -e "$tmp_dir/partial-committed" ] &&
  [ -e "$tmp_dir/partial-env-written" ] &&
  [ -e "$tmp_dir/partial-fingerprint-written" ] &&
  [ ! -e "$tmp_dir/partial-response-old" ] &&
  [ ! -e "$tmp_dir/partial-pending-old" ] || {
  printf 'FAIL: matching partial replacement did not complete its commit\n' >&2
  exit 1
}
pass

rm -f "$tmp_dir/partial-claimed" "$tmp_dir/partial-committed" \
  "$tmp_dir/partial-env-written" "$tmp_dir/partial-fingerprint-written"
: >"$tmp_dir/partial-response-old"
: >"$tmp_dir/partial-pending-old"
expect_failure "mismatched partial-state replacement keeps old state" \
  mock_partial_replacement other.example.com
[ -e "$tmp_dir/partial-claimed" ] &&
  [ ! -e "$tmp_dir/partial-committed" ] &&
  [ ! -e "$tmp_dir/partial-env-written" ] &&
  [ ! -e "$tmp_dir/partial-fingerprint-written" ] &&
  [ -e "$tmp_dir/partial-response-old" ] &&
  [ -e "$tmp_dir/partial-pending-old" ] || {
  printf 'FAIL: mismatched partial replacement changed old state\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_partial_claim_failure() (
  load_partial_enrollment_identity() {
    # shellcheck disable=SC2034
    PARTIAL_EGRESS_ID=hk-egress-01
    # shellcheck disable=SC2034
    PARTIAL_DOMAIN=egress.example.com
    return 0
  }
  claim_enrollment() {
    : >"$tmp_dir/partial-failed-claim-attempted"
    die "mock enrollment request failed"
  }
  commit_claim_response() {
    : >"$tmp_dir/partial-failed-committed"
  }
  write_service_env() {
    : >"$tmp_dir/partial-failed-env-written"
  }
  write_enrollment_fingerprint() {
    : >"$tmp_dir/partial-failed-fingerprint-written"
  }
  FINGERPRINT_FILE=$tmp_dir/partial-failed-fingerprint-old
  # shellcheck disable=SC2034
  SAVED_RESPONSE=$tmp_dir/partial-failed-response-old
  # shellcheck disable=SC2034
  PENDING_RESPONSE=$tmp_dir/partial-failed-pending-old
  # shellcheck disable=SC2034
  CLAIM_RESPONSE_FILE=$tmp_dir/partial-failed-candidate
  install_unconfigured_enrollment \
    https://browser.example.com \
    "$tmp_dir/mock-token" \
    "$new_fingerprint" \
    1
)

: >"$tmp_dir/partial-failed-response-old"
: >"$tmp_dir/partial-failed-pending-old"
expect_failure "partial-state claim failure preserves old state" \
  mock_partial_claim_failure
[ -e "$tmp_dir/partial-failed-claim-attempted" ] &&
  [ ! -e "$tmp_dir/partial-failed-committed" ] &&
  [ ! -e "$tmp_dir/partial-failed-env-written" ] &&
  [ ! -e "$tmp_dir/partial-failed-fingerprint-written" ] &&
  [ -e "$tmp_dir/partial-failed-response-old" ] &&
  [ -e "$tmp_dir/partial-failed-pending-old" ] || {
  printf 'FAIL: failed partial claim changed old state\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2329
mock_unconfigured_already_connected() (
  load_partial_enrollment_identity() {
    return 1
  }
  claim_enrollment() {
    # shellcheck disable=SC2034
    CLAIM_OUTCOME=already_connected
  }
  load_enrollment_file() {
    : >"$tmp_dir/unconfigured-connected-response-loaded"
  }
  write_service_env() {
    : >"$tmp_dir/unconfigured-connected-env-written"
  }
  write_enrollment_fingerprint() {
    : >"$tmp_dir/unconfigured-connected-fingerprint-written"
  }
  FINGERPRINT_FILE=$tmp_dir/unconfigured-fingerprint
  # shellcheck disable=SC2034
  SAVED_RESPONSE=$tmp_dir/unconfigured-response
  # shellcheck disable=SC2034
  PENDING_RESPONSE=$tmp_dir/unconfigured-pending
  # shellcheck disable=SC2034
  CLAIM_RESPONSE_FILE=$tmp_dir/unconfigured-candidate
  install_unconfigured_enrollment \
    https://browser.example.com \
    "$tmp_dir/mock-token" \
    "$new_fingerprint" \
    0
)

expect_failure "fresh host rejects already_connected without local secrets" \
  mock_unconfigured_already_connected
[ ! -e "$tmp_dir/unconfigured-connected-response-loaded" ] &&
  [ ! -e "$tmp_dir/unconfigured-connected-env-written" ] &&
  [ -e "$tmp_dir/unconfigured-connected-fingerprint-written" ] || {
  printf 'FAIL: unconfigured already_connected response was accepted\n' >&2
  exit 1
}
pass

FINGERPRINT_FILE=$tmp_dir/enrollment-fingerprint
printf '%s\n' "$old_fingerprint" >"$FINGERPRINT_FILE"
# shellcheck disable=SC2329
chown() { :; }
[ "$(existing_enrollment_mode "$old_fingerprint" 0)" = renew ] || {
  printf 'FAIL: matching fingerprint did not select renewal\n' >&2
  exit 1
}
pass
expect_failure "different fingerprint is rejected by default" \
  existing_enrollment_mode "$new_fingerprint" 0
[ "$(existing_enrollment_mode "$new_fingerprint" 1)" = replace ] || {
  printf 'FAIL: explicit replacement did not select replacement mode\n' >&2
  exit 1
}
pass
unset -f chown

jq 'del(.max_streams)' "$response_file" >"$tmp_dir/missing-capacity.json"
expect_failure "response missing max_streams" validate_enrollment_file "$tmp_dir/missing-capacity.json"
jq '.public_endpoint = "other.example.com:27600"' "$response_file" >"$tmp_dir/wrong-endpoint.json"
expect_failure "response endpoint differs from domain" load_enrollment_file "$tmp_dir/wrong-endpoint.json"

INSTALL_DIR=$tmp_dir/install
ENV_FILE=$INSTALL_DIR/.env
COMPOSE_FILE=$INSTALL_DIR/docker-compose.yml
INSTALL_RECORD=$INSTALL_DIR/.installation
mkdir -p "$INSTALL_DIR"
# shellcheck disable=SC2034
INSTALL_MODE=docker
RESOLVED_VERSION=latest
# shellcheck disable=SC2034
EGRESS_IMAGE_REPOSITORY=ghcr.io/voiceofhu/one-browser-egress
# shellcheck disable=SC2329
chown() { :; }
write_service_env
write_compose_file
# shellcheck disable=SC2034
HOST_PLATFORM=linux-amd64
write_installation_record
unset -f chown
grep -qx 'EGRESS_MAX_CONNECTIONS_PER_IP=64' "$ENV_FILE" || {
  printf 'FAIL: generated per-IP limit is not bounded as expected\n' >&2
  exit 1
}
pass
if ! grep -qx 'runtime=docker' "$INSTALL_RECORD" ||
  ! grep -qx 'platform=linux-amd64' "$INSTALL_RECORD" ||
  ! grep -qx 'version=latest' "$INSTALL_RECORD"; then
  printf 'FAIL: installation record is incomplete\n' >&2
  exit 1
fi
pass
grep -qx 'EGRESS_MAX_STREAMS_PER_CONNECTION=256' "$ENV_FILE" || {
  printf 'FAIL: generated per-connection stream limit is not bounded as expected\n' >&2
  exit 1
}
pass
grep -q 'no-new-privileges:true' "$COMPOSE_FILE" || {
  printf 'FAIL: generated Compose is missing hardened security options\n' >&2
  exit 1
}
pass
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  docker compose --project-name one-browser-egress-installer-test \
    --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet
  pass
fi

CONFIG_TLS_ENABLED=false
# shellcheck disable=SC2034
CONFIG_CONTROL_URL=http://host.orb.internal:27512
# shellcheck disable=SC2034
REQUESTED_TLS_ENABLED=false
# shellcheck disable=SC2329
chown() { :; }
write_service_env
write_compose_file
unset -f chown
grep -qx 'EGRESS_TLS_ENABLED=false' "$ENV_FILE" || {
  printf 'FAIL: development environment did not disable TLS explicitly\n' >&2
  exit 1
}
pass
if grep -q '/app/tls\\|EGRESS_TLS_CERT_FILE\\|EGRESS_TLS_KEY_FILE' "$COMPOSE_FILE"; then
  printf 'FAIL: development Compose still mounts or configures TLS files\n' >&2
  exit 1
fi
pass

# shellcheck disable=SC2034
INSTALL_MODE=native
CONFIG_TLS_ENABLED=true
CERT_DIR=$INSTALL_DIR/certs
# shellcheck disable=SC2329
chown() { :; }
write_service_env
unset -f chown
if grep -q '^DOCKER_IMAGE=' "$ENV_FILE" ||
  ! grep -qx "EGRESS_TLS_CERT_FILE=$CERT_DIR/fullchain.pem" "$ENV_FILE" ||
  ! grep -qx "EGRESS_TLS_KEY_FILE=$CERT_DIR/privkey.pem" "$ENV_FILE"; then
  printf 'FAIL: native service environment contains incorrect runtime paths\n' >&2
  exit 1
fi
pass

preloaded_trace=$tmp_dir/preloaded-image-trace
# shellcheck disable=SC2329
mock_preloaded_development_start() (
  docker() {
    case "$1 $2" in
      "network inspect") return 1 ;;
      "network create") return 0 ;;
      "image inspect") return 0 ;;
      *) return 1 ;;
    esac
  }
  compose() {
    printf '%s\n' "$*" >>"$preloaded_trace"
  }
  wait_for_health() { :; }
  # shellcheck disable=SC2034
  CONFIG_TLS_ENABLED=false
  # shellcheck disable=SC2034
  CONFIG_IMAGE=host.orb.internal:5000/one-browser-egress:dev
  start_docker_egress >/dev/null
)
expect_success "development start accepts a preloaded local image" \
  mock_preloaded_development_start
if grep -qx 'pull egress' "$preloaded_trace"; then
  printf 'FAIL: development start pulled an image that was already preloaded\n' >&2
  exit 1
fi
pass

printf 'HTTP/1.1 200 OK\r\nCache-Control: private, no-store\r\n\r\n' >"$tmp_dir/headers"
expect_success "enrollment response is explicitly non-cacheable" response_has_no_store "$tmp_dir/headers"
printf 'HTTP/1.1 200 OK\r\nCache-Control: no-cache\r\n\r\n' >"$tmp_dir/headers"
expect_failure "no-cache alone is insufficient" response_has_no_store "$tmp_dir/headers"
printf 'HTTP/1.1 100 Continue\r\nCache-Control: no-store\r\n\r\nHTTP/2 200\r\nCache-Control: no-cache\r\n\r\n' \
  >"$tmp_dir/headers"
expect_failure "an interim no-store header cannot validate the final response" \
  response_has_no_store "$tmp_dir/headers"

# shellcheck disable=SC2030,SC2034,SC2329
mock_up_to_date_installation() (
  load_existing_env() {
    CONFIG_EGRESS_ID=hk-egress-01
    CONFIG_PUBLIC_ENDPOINT=egress.example.com:27600
    CONFIG_CONTROL_TOKEN=$valid_token
  }
  prepare_runtime_config() {
    RESOLVED_VERSION=26.725.1317
  }
  ensure_tls_configuration() { :; }
  installed_version() { printf '26.725.1317'; }
  runtime_installation_complete() { return 0; }
  write_service_env() { : >"$tmp_dir/up-to-date-env-written"; }
  start_native_egress() { : >"$tmp_dir/up-to-date-runtime-started"; }
  write_installation_record() { : >"$tmp_dir/up-to-date-record-written"; }
  ENV_FILE=$tmp_dir/mock.env
  INSTALL_MODE=native
  update_existing_installation >/dev/null
)
expect_success "matching installed version exits without overwriting the runtime" \
  mock_up_to_date_installation
[ ! -e "$tmp_dir/up-to-date-env-written" ] &&
  [ ! -e "$tmp_dir/up-to-date-runtime-started" ] &&
  [ ! -e "$tmp_dir/up-to-date-record-written" ] || {
  printf 'FAIL: up-to-date installation was overwritten\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2030,SC2034,SC2329
mock_outdated_installation() (
  load_existing_env() {
    CONFIG_EGRESS_ID=hk-egress-01
    CONFIG_PUBLIC_ENDPOINT=egress.example.com:27600
    CONFIG_CONTROL_TOKEN=$valid_token
  }
  prepare_runtime_config() {
    RESOLVED_VERSION=26.725.1317
  }
  ensure_tls_configuration() { :; }
  installed_version() { printf '26.724.1'; }
  runtime_installation_complete() { return 0; }
  write_service_env() { : >"$tmp_dir/outdated-env-written"; }
  start_native_egress() { : >"$tmp_dir/outdated-runtime-started"; }
  write_installation_record() { : >"$tmp_dir/outdated-record-written"; }
  ENV_FILE=$tmp_dir/mock.env
  INSTALL_MODE=native
  update_existing_installation >/dev/null
)
expect_success "outdated installation is overwritten in place" \
  mock_outdated_installation
[ -e "$tmp_dir/outdated-env-written" ] &&
  [ -e "$tmp_dir/outdated-runtime-started" ] &&
  [ -e "$tmp_dir/outdated-record-written" ] || {
  printf 'FAIL: outdated installation was not fully updated\n' >&2
  exit 1
}
pass

# shellcheck disable=SC2034,SC2329
mock_missing_tls_repair() (
  local calls=
  log() { :; }
  ensure_certificate_directory() { calls="${calls}directory "; }
  verify_domain_points_here() {
    [ "$1" = egress.example.com ] || return 1
    calls="${calls}dns "
  }
  issue_and_install_certificate() { calls="${calls}certificate "; }
  write_renewal_hook() { calls="${calls}hook"; }
  CONFIG_TLS_ENABLED=true
  CONFIG_DOMAIN=egress.example.com
  CERT_DIR=$tmp_dir/missing-certs
  ensure_tls_configuration
  printf '%s' "$calls"
)
[ "$(mock_missing_tls_repair)" = 'directory dns certificate hook' ] || {
  printf 'FAIL: missing TLS files were not repaired before runtime validation\n' >&2
  exit 1
}
pass

printf 'PASS: %d installer tests\n' "$tests_run"
