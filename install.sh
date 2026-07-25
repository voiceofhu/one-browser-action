#!/usr/bin/env bash

# Stable public entrypoint. The implementation is split under
# scripts/egress/install so the production curl command can stay unchanged.

set +x
set -Eeuo pipefail

readonly ONE_BROWSER_EGRESS_DEFAULT_SCRIPT_BASE_URL='https://raw.githubusercontent.com/voiceofhu/one-browser-action'
readonly -a ONE_BROWSER_EGRESS_INSTALL_MODULES=(
  common.sh
  config.sh
  host.sh
  native.sh
  enrollment.sh
  compose-config.sh
  tls.sh
  docker.sh
  main.sh
)
ONE_BROWSER_EGRESS_MODULE_TEMP_DIR=
ONE_BROWSER_EGRESS_STAGED_TOKEN_FILE=

egress_entrypoint_die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

egress_entrypoint_local_source_dir() {
  local entrypoint_dir

  [ -n "${BASH_SOURCE[0]:-}" ] || return 1
  entrypoint_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) ||
    return 1
  [ -f "$entrypoint_dir/scripts/egress/install/main.sh" ] || return 1
  printf '%s/scripts/egress/install' "$entrypoint_dir"
}

egress_entrypoint_resolve_default_base_url() {
  local response revision

  response=$(curl -q --proto '=https' --tlsv1.2 \
    --fail --silent --show-error --no-location \
    --connect-timeout 10 --max-time 30 --max-filesize 262144 \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    'https://api.github.com/repos/voiceofhu/one-browser-action/git/ref/heads/main') ||
    egress_entrypoint_die "Unable to resolve the Egress installer commit from GitHub"
  revision=$(printf '%s' "$response" | tr ',' '\n' |
    awk -F'"' '$2 == "sha" { print $4; exit }')
  [ "${#revision}" -eq 40 ] && [[ "$revision" =~ ^[a-f0-9]+$ ]] ||
    egress_entrypoint_die "GitHub returned an invalid Egress installer commit"
  printf '==> Loading Egress installer modules from commit %.12s\n' "$revision" >&2
  printf '%s/%s/scripts/egress' \
    "$ONE_BROWSER_EGRESS_DEFAULT_SCRIPT_BASE_URL" \
    "$revision"
}

egress_entrypoint_download_modules() {
  local destination=$1
  local base_url module
  local -a curl_transport

  command -v curl >/dev/null ||
    egress_entrypoint_die "curl is required to load the Egress installer"
  if [ -n "${ONE_BROWSER_EGRESS_SCRIPT_BASE_URL:-}" ]; then
    base_url=$ONE_BROWSER_EGRESS_SCRIPT_BASE_URL
  else
    base_url=$(egress_entrypoint_resolve_default_base_url)
  fi
  base_url=${base_url%/}
  case "$base_url" in
    https://*)
      curl_transport=(--proto '=https' --tlsv1.2)
      ;;
    http://127.0.0.1:*|http://localhost:*|http://host.orb.internal:*)
      curl_transport=(--proto '=http')
      ;;
    *)
      egress_entrypoint_die \
        "ONE_BROWSER_EGRESS_SCRIPT_BASE_URL must use HTTPS or an approved local development host"
      ;;
  esac

  for module in "${ONE_BROWSER_EGRESS_INSTALL_MODULES[@]}"; do
    curl -q "${curl_transport[@]}" \
      --fail --silent --show-error --no-location \
      --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
      "$base_url/install/$module" \
      --output "$destination/$module" ||
      egress_entrypoint_die "Unable to download Egress installer module: $module"
    [ -s "$destination/$module" ] ||
      egress_entrypoint_die "Downloaded Egress installer module is empty: $module"
    chmod 0600 "$destination/$module"
    /bin/bash -n "$destination/$module" ||
      egress_entrypoint_die "Downloaded Egress installer module has invalid syntax: $module"
  done
}

egress_entrypoint_load_modules() {
  local source_dir module temporary_dir=

  source_dir=$(egress_entrypoint_local_source_dir 2>/dev/null || true)
  if [ -z "$source_dir" ]; then
    temporary_dir=$(mktemp -d "/tmp/one-browser-egress-installer.XXXXXX")
    chmod 0700 "$temporary_dir"
    ONE_BROWSER_EGRESS_MODULE_TEMP_DIR=$temporary_dir
    egress_entrypoint_download_modules "$temporary_dir"
    source_dir=$temporary_dir
  fi

  for module in "${ONE_BROWSER_EGRESS_INSTALL_MODULES[@]}"; do
    # shellcheck disable=SC1090
    . "$source_dir/$module"
  done

  if [ -n "$temporary_dir" ]; then
    rm -rf -- "$temporary_dir"
    ONE_BROWSER_EGRESS_MODULE_TEMP_DIR=
  fi
}

egress_entrypoint_cleanup_remote() {
  set +e
  if [ -n "$ONE_BROWSER_EGRESS_MODULE_TEMP_DIR" ]; then
    rm -rf -- "$ONE_BROWSER_EGRESS_MODULE_TEMP_DIR"
  fi
  if [ -n "$ONE_BROWSER_EGRESS_STAGED_TOKEN_FILE" ]; then
    rm -f -- "$ONE_BROWSER_EGRESS_STAGED_TOKEN_FILE"
  fi
}

egress_entrypoint_run_loaded() {
  ONE_BROWSER_EGRESS_STAGED_TOKEN_FILE=${ONE_BROWSER_EGRESS_ENROLLMENT_TOKEN_FILE-}
  trap egress_entrypoint_cleanup_remote EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  egress_entrypoint_load_modules
  bootstrap "$@"
}

egress_entrypoint_validate_token() {
  local value=${1-}

  [ "${#value}" -ge 32 ] &&
    [ "${#value}" -le 4096 ] &&
    [[ "$value" =~ ^[A-Za-z0-9._~-]+$ ]]
}

egress_entrypoint_stage_remote_install() {
  local environment_token_present=${ONE_BROWSER_ENROLLMENT_TOKEN+x}
  local enrollment_token=${ONE_BROWSER_ENROLLMENT_TOKEN-}
  local token_argument_seen=0
  local token_file loader_code
  local -a sanitized_arguments=()

  token_file=
  loader_code=
  unset ONE_BROWSER_ENROLLMENT_TOKEN
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --enrollment-token)
        [ "$#" -ge 2 ] ||
          egress_entrypoint_die "--enrollment-token requires a value"
        [ "$token_argument_seen" -eq 0 ] ||
          egress_entrypoint_die "--enrollment-token may be supplied only once"
        [ -z "$environment_token_present" ] ||
          egress_entrypoint_die \
            "Use either ONE_BROWSER_ENROLLMENT_TOKEN or --enrollment-token, not both"
        enrollment_token=$2
        token_argument_seen=1
        shift 2
        ;;
      *)
        sanitized_arguments+=("$1")
        shift
        ;;
    esac
  done

  if [ -n "$environment_token_present" ] || [ "$token_argument_seen" -eq 1 ]; then
    egress_entrypoint_validate_token "$enrollment_token" ||
      egress_entrypoint_die "--enrollment-token is invalid"
    [ "${EUID:-$(id -u)}" -eq 0 ] ||
      egress_entrypoint_die "Run this installer as root (the generated command uses sudo)"
    umask 077
    install -d -m 0700 -o root -g root /run/one-browser-egress-installer
    token_file=$(mktemp /run/one-browser-egress-installer/enrollment-token.XXXXXX)
    printf '%s' "$enrollment_token" >"$token_file"
    chmod 0600 "$token_file"
    enrollment_token=
    export ONE_BROWSER_EGRESS_ENROLLMENT_TOKEN_FILE=$token_file
    ONE_BROWSER_EGRESS_STAGED_TOKEN_FILE=$token_file
    trap egress_entrypoint_cleanup_remote EXIT
  fi
  set --

  loader_code=$(
    declare -p \
      ONE_BROWSER_EGRESS_DEFAULT_SCRIPT_BASE_URL \
      ONE_BROWSER_EGRESS_INSTALL_MODULES \
      ONE_BROWSER_EGRESS_MODULE_TEMP_DIR \
      ONE_BROWSER_EGRESS_STAGED_TOKEN_FILE
    declare -f \
      egress_entrypoint_die \
      egress_entrypoint_local_source_dir \
      egress_entrypoint_resolve_default_base_url \
      egress_entrypoint_download_modules \
      egress_entrypoint_load_modules \
      egress_entrypoint_cleanup_remote \
      egress_entrypoint_run_loaded
  )
  exec -a one-browser-egress-loader /bin/bash -c \
    "${loader_code}"$'\n''egress_entrypoint_run_loaded "$@"' \
    one-browser-egress-loader \
    "${sanitized_arguments[@]}"
}

if [ "${ONE_BROWSER_INSTALLER_LIBRARY_ONLY:-0}" = 1 ]; then
  egress_entrypoint_load_modules
elif egress_entrypoint_local_source_dir >/dev/null 2>&1; then
  egress_entrypoint_load_modules
  bootstrap "$@"
else
  egress_entrypoint_stage_remote_install "$@"
fi
