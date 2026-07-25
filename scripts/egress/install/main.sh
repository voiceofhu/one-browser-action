# shellcheck shell=bash
# Installer globals are shared across sourced modules.
# shellcheck disable=SC2034

cleanup_sensitive_files() {
  set +e
  if [ -n "${CURL_CONFIG_FILE:-}" ]; then
    rm -f "$CURL_CONFIG_FILE"
  fi
  if [ -n "${TOKEN_FILE:-}" ]; then
    rm -f "$TOKEN_FILE"
  fi
  if [ -n "${RESPONSE_HEADER_FILE:-}" ]; then
    rm -f "$RESPONSE_HEADER_FILE"
  fi
  if [ -n "${CLAIM_RESPONSE_FILE:-}" ]; then
    rm -f "$CLAIM_RESPONSE_FILE"
  fi
}

installer_main() {
  local requested_control_url=$1
  local token_file=$2
  local requested_fingerprint=$3
  local replace_existing=$4
  local requested_tls_enabled=$5
  local install_mode=$6
  local requested_version=$7
  local existing_mode existing_runtime installation_state

  set +x
  set -Eeuo pipefail
  umask 077
  INSTALL_DIR=/opt/one-browser-egress
  CERT_DIR=$INSTALL_DIR/certs
  ENV_FILE=$INSTALL_DIR/.env
  COMPOSE_FILE=$INSTALL_DIR/docker-compose.yml
  NATIVE_BINARY=/usr/local/bin/one-browser-egress
  NATIVE_SERVICE_FILE=/etc/systemd/system/one-browser-egress.service
  SAVED_RESPONSE=$INSTALL_DIR/.enrollment-response.json
  PENDING_RESPONSE=$INSTALL_DIR/.enrollment-response.json.pending
  CLAIM_RESPONSE_FILE=$INSTALL_DIR/.enrollment-response.json.candidate
  FINGERPRINT_FILE=$INSTALL_DIR/.enrollment-fingerprint
  INSTALL_RECORD=$INSTALL_DIR/.installation
  RUN_DIR=/run/one-browser-egress-installer
  TOKEN_FILE=$token_file
  CURL_CONFIG_FILE=
  RESPONSE_HEADER_FILE=
  CLAIM_OUTCOME=
  CONFIG_EGRESS_ID=
  CONFIG_DOMAIN=
  CONFIG_PUBLIC_ENDPOINT=
  CONFIG_TLS_ENABLED=
  CONFIG_CONTROL_URL=
  CONFIG_CONTROL_TOKEN=
  CONFIG_IMAGE=
  CONFIG_MAX_CONNECTIONS=
  CONFIG_MAX_STREAMS=
  PARTIAL_EGRESS_ID=
  PARTIAL_DOMAIN=
  PARTIAL_TLS_ENABLED=
  REQUESTED_TLS_ENABLED=$requested_tls_enabled
  INSTALL_MODE=$install_mode
  REQUESTED_VERSION=$requested_version
  RESOLVED_VERSION=
  EGRESS_IMAGE_REPOSITORY=ghcr.io/voiceofhu/one-browser-egress
  [ "$replace_existing" = 0 ] || [ "$replace_existing" = 1 ] ||
    die "Internal replacement mode is invalid"
  validate_boolean "$REQUESTED_TLS_ENABLED" ||
    die "Internal TLS mode is invalid"
  validate_install_mode "$INSTALL_MODE" || die "Internal install mode is invalid"
  [ "$(normalize_version "$REQUESTED_VERSION")" = "$REQUESTED_VERSION" ] ||
    die "Internal Egress version is invalid"
  trap cleanup_sensitive_files EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP

  install -d -m 0700 -o root -g root "$RUN_DIR"
  exec 9>"$RUN_DIR/install.lock"
  flock -n 9 || die "Another Egress installation is already running"
  verify_supported_os
  HOST_PLATFORM=$(detect_host_platform)
  installation_state=$(detect_installation_state)
  if existing_runtime=$(installed_runtime 2>/dev/null); then
    [ "$existing_runtime" = "$INSTALL_MODE" ] ||
      die_runtime_switch "$existing_runtime" "$INSTALL_MODE"
  elif [ -e "$COMPOSE_FILE" ]; then
    [ "$INSTALL_MODE" = docker ] ||
      die_runtime_switch docker native
  elif [ -e "$NATIVE_SERVICE_FILE" ] || [ -e "$NATIVE_BINARY" ]; then
    [ "$INSTALL_MODE" = native ] ||
      die_runtime_switch native docker
  fi
  ensure_install_directories
  case "$installation_state" in
    fresh)
      log "No existing Egress installation detected; starting a fresh install for $HOST_PLATFORM"
      ;;
    installed)
      log "Existing Egress installation detected; checking its runtime version"
      ;;
    partial)
      log "Partial Egress installation state detected; resuming protected installation"
      ;;
    *) die "Internal installation state is invalid" ;;
  esac
  install_base_packages "$REQUESTED_TLS_ENABLED"
  if [ "$installation_state" = installed ] && [ "$replace_existing" = 0 ]; then
    log "Preserving the existing node enrollment while checking its runtime version;" \
      "the supplied enrollment token will not be consumed"
    update_existing_installation
    return 0
  fi

  if [ -e "$ENV_FILE" ]; then
    if ! existing_mode=$(existing_enrollment_mode \
      "$requested_fingerprint" "$replace_existing"); then
      die "This host is already configured with a different enrollment; the new token was not consumed. Use --replace-existing-enrollment only for a replacement issued for this same node"
    fi
    if [ "$existing_mode" = replace ]; then
      log "Explicit enrollment replacement requested; existing configuration stays unchanged until node ID and domain match"
    fi
  elif [ -e "$SAVED_RESPONSE" ] || [ -e "$PENDING_RESPONSE" ] ||
    [ -e "$FINGERPRINT_FILE" ]; then
    if [ "$replace_existing" = 0 ]; then
      require_matching_fingerprint "$requested_fingerprint"
    else
      log "Explicit replacement requested for interrupted local enrollment state"
    fi
  elif [ "$replace_existing" = 1 ]; then
    log "No local enrollment state exists; proceeding as a fresh installation"
  fi

  if [ -e "$ENV_FILE" ]; then
    if [ "$existing_mode" = renew ]; then
      log "Renewing the claimed installation lease before resuming"
    else
      log "Claiming the explicit replacement enrollment"
    fi
    refresh_existing_enrollment \
      "$requested_control_url" \
      "$TOKEN_FILE" \
      "$requested_fingerprint" \
      "$existing_mode"
  else
    install_unconfigured_enrollment \
      "$requested_control_url" \
      "$TOKEN_FILE" \
      "$requested_fingerprint" \
      "$replace_existing"
  fi
  CONFIG_CONTROL_TOKEN=

  ensure_tls_configuration
  if [ "$INSTALL_MODE" = native ]; then
    start_native_egress
  else
    write_compose_file
    install_docker
    start_docker_egress
  fi
  write_installation_record
  printf 'One Browser Egress %s (%s, %s) is installed and healthy at %s.\n' \
    "$CONFIG_EGRESS_ID" "$INSTALL_MODE" "$RESOLVED_VERSION" "$CONFIG_PUBLIC_ENDPOINT"
}

bootstrap() {
  local environment_token_present=${ONE_BROWSER_ENROLLMENT_TOKEN+x}
  local enrollment_token=${ONE_BROWSER_ENROLLMENT_TOKEN-}
  local staged_token_file=${ONE_BROWSER_EGRESS_ENROLLMENT_TOKEN_FILE-}
  local staged_token_present=${ONE_BROWSER_EGRESS_ENROLLMENT_TOKEN_FILE+x}
  unset ONE_BROWSER_ENROLLMENT_TOKEN
  unset ONE_BROWSER_EGRESS_ENROLLMENT_TOKEN_FILE
  local control_url=
  local install_mode=
  local tls_enabled=
  local requested_version=latest
  local version_argument_seen=0
  local enrollment_fingerprint token_file stage_code
  local replace_existing=0
  local token_argument_seen=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        [ "$#" -ge 2 ] || die "--mode requires a value"
        [ -z "$install_mode" ] || die "--mode may be supplied only once"
        install_mode=$2
        shift 2
        ;;
      --version)
        [ "$#" -ge 2 ] || die "--version requires a value"
        [ "$version_argument_seen" -eq 0 ] ||
          die "--version may be supplied only once"
        requested_version=$(normalize_version "$2") ||
          die "--version must be latest or a semantic version such as 26.724.1"
        version_argument_seen=1
        shift 2
        ;;
      --control-url)
        [ "$#" -ge 2 ] || die "--control-url requires a value"
        [ -z "$control_url" ] || die "--control-url may be supplied only once"
        control_url=$2
        shift 2
        ;;
      --tls-enabled)
        [ "$#" -ge 2 ] || die "--tls-enabled requires a value"
        [ -z "$tls_enabled" ] || die "--tls-enabled may be supplied only once"
        tls_enabled=$2
        shift 2
        ;;
      --enrollment-token)
        [ "$#" -ge 2 ] || die "--enrollment-token requires a value"
        [ "$token_argument_seen" -eq 0 ] || die "--enrollment-token may be supplied only once"
        [ -z "$environment_token_present" ] && [ -z "$staged_token_present" ] ||
          die "Use only one enrollment token input"
        enrollment_token=$2
        token_argument_seen=1
        shift 2
        ;;
      --replace-existing-enrollment)
        [ "$replace_existing" -eq 0 ] ||
          die "--replace-existing-enrollment may be supplied only once"
        replace_existing=1
        shift
        ;;
      -h|--help)
        show_help
        return 0
        ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  if [ -n "$staged_token_present" ]; then
    [ -z "$environment_token_present" ] ||
      die "Use only one enrollment token input"
    [[ "$staged_token_file" =~ ^/run/one-browser-egress-installer/enrollment-token\.[A-Za-z0-9]+$ ]] ||
      die "Staged enrollment token path is invalid"
    [ -f "$staged_token_file" ] && [ ! -L "$staged_token_file" ] ||
      die "Staged enrollment token is unavailable"
    token_file=$staged_token_file
    enrollment_token=$(<"$token_file")
  fi

  validate_install_mode "$install_mode" || die "--mode must be native or docker"
  validate_boolean "$tls_enabled" || die "--tls-enabled must be true or false"
  validate_control_url "$control_url" "$tls_enabled" ||
    die "--control-url is invalid for --tls-enabled $tls_enabled"
  control_url=$(normalize_control_url "$control_url")
  validate_secret_token "$enrollment_token" || die "--enrollment-token is invalid"
  [ "${EUID:-$(id -u)}" -eq 0 ] ||
    die "Run this installer as root (the generated command uses sudo)"
  command -v flock >/dev/null || die "The required flock command is unavailable"
  command -v sha256sum >/dev/null || die "The required sha256sum command is unavailable"

  umask 077
  install -d -m 0700 -o root -g root /run/one-browser-egress-installer
  if [ -z "$staged_token_present" ]; then
    token_file=$(mktemp /run/one-browser-egress-installer/enrollment-token.XXXXXX)
    printf '%s' "$enrollment_token" >"$token_file"
  fi
  chown root:root "$token_file"
  chmod 0600 "$token_file"
  trap 'rm -f "$token_file"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  enrollment_fingerprint="sha256:$(printf '%s' "$enrollment_token" | sha256sum | awk '{print $1}')"
  enrollment_token=
  set --

  # Replace the downloaded installer process immediately. The second-stage
  # command line contains only the token-file path, one-way fingerprint,
  # replacement bit, and validated non-secret options.
  stage_code=$(declare -f \
    die log validate_secret_token validate_domain validate_ipv4 validate_boolean validate_lower_sha256 \
    validate_install_mode normalize_version validate_control_url \
    normalize_control_url validate_egress_id validate_positive_integer \
    validate_public_endpoint validate_image_reference all_addresses_equal \
    validate_enrollment_file validate_already_connected_file response_has_no_store \
    load_enrollment_file validate_loaded_config \
    read_env_value load_existing_env ensure_install_directories ensure_certificate_directory \
    package_installed install_base_packages verify_supported_os detect_host_platform \
    detect_installation_state write_installation_record installed_runtime \
    installed_version runtime_installation_complete \
    configure_docker_repository enable_docker_service install_docker \
    ensure_native_user resolve_latest_version prepare_runtime_config \
    download_native_binary write_native_service run_native_command \
    wait_for_native_health start_native_egress \
    claim_enrollment commit_claim_response write_enrollment_fingerprint \
    require_matching_fingerprint \
    fingerprint_matches existing_enrollment_mode claim_matches_existing_config \
    load_partial_enrollment_identity refresh_existing_enrollment \
    install_unconfigured_enrollment \
    write_service_env write_compose_file \
    discover_public_ip canonicalize_ipv6 filter_ipv4_records query_ipv4_records \
    query_public_dns_records query_public_ipv4_records resolve_ipv4 \
    query_ipv6_records query_public_ipv6_records resolve_ipv6 \
    verify_domain_points_here \
    issue_and_install_certificate ensure_tls_configuration write_renewal_hook compose wait_for_health \
    start_docker_egress update_existing_installation cleanup_sensitive_files installer_main)
  exec -a one-browser-egress-installer /bin/bash -c \
    "${stage_code}"$'\n''installer_main "$@"' \
    one-browser-egress-installer-stage2 \
    "$control_url" "$token_file" "$enrollment_fingerprint" "$replace_existing" "$tls_enabled" \
    "$install_mode" "$requested_version"
}
