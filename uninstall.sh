#!/usr/bin/env bash

# Stable public entrypoint. The implementation is split under
# scripts/egress/uninstall so the production curl command can stay unchanged.

set +x
set -Eeuo pipefail

readonly ONE_BROWSER_EGRESS_DEFAULT_SCRIPT_BASE_URL='https://raw.githubusercontent.com/voiceofhu/one-browser-action'
readonly -a ONE_BROWSER_EGRESS_UNINSTALL_MODULES=(
  common.sh
  native.sh
  docker.sh
  main.sh
)

egress_entrypoint_die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

egress_entrypoint_local_source_dir() {
  local entrypoint_dir

  [ -n "${BASH_SOURCE[0]:-}" ] || return 1
  entrypoint_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) ||
    return 1
  [ -f "$entrypoint_dir/scripts/egress/uninstall/main.sh" ] || return 1
  printf '%s/scripts/egress/uninstall' "$entrypoint_dir"
}

egress_entrypoint_resolve_default_base_url() {
  local response revision

  response=$(curl -q --proto '=https' --tlsv1.2 \
    --fail --silent --show-error --no-location \
    --connect-timeout 10 --max-time 30 --max-filesize 262144 \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    'https://api.github.com/repos/voiceofhu/one-browser-action/git/ref/heads/main') ||
    egress_entrypoint_die "Unable to resolve the Egress uninstaller commit from GitHub"
  revision=$(printf '%s' "$response" | tr ',' '\n' |
    awk -F'"' '$2 == "sha" { print $4; exit }')
  [ "${#revision}" -eq 40 ] && [[ "$revision" =~ ^[a-f0-9]+$ ]] ||
    egress_entrypoint_die "GitHub returned an invalid Egress uninstaller commit"
  printf '==> Loading Egress uninstaller modules from commit %.12s\n' "$revision" >&2
  printf '%s/%s/scripts/egress' \
    "$ONE_BROWSER_EGRESS_DEFAULT_SCRIPT_BASE_URL" \
    "$revision"
}

egress_entrypoint_download_modules() {
  local destination=$1
  local base_url module
  local -a curl_transport

  command -v curl >/dev/null ||
    egress_entrypoint_die "curl is required to load the Egress uninstaller"
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

  for module in "${ONE_BROWSER_EGRESS_UNINSTALL_MODULES[@]}"; do
    curl -q "${curl_transport[@]}" \
      --fail --silent --show-error --no-location \
      --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
      "$base_url/uninstall/$module" \
      --output "$destination/$module" ||
      egress_entrypoint_die "Unable to download Egress uninstaller module: $module"
    [ -s "$destination/$module" ] ||
      egress_entrypoint_die "Downloaded Egress uninstaller module is empty: $module"
    chmod 0600 "$destination/$module"
    /bin/bash -n "$destination/$module" ||
      egress_entrypoint_die "Downloaded Egress uninstaller module has invalid syntax: $module"
  done
}

egress_entrypoint_load_modules() {
  local source_dir module temporary_dir=

  source_dir=$(egress_entrypoint_local_source_dir 2>/dev/null || true)
  if [ -z "$source_dir" ]; then
    temporary_dir=$(mktemp -d "/tmp/one-browser-egress-uninstaller.XXXXXX")
    chmod 0700 "$temporary_dir"
    trap 'rm -rf -- "$temporary_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    egress_entrypoint_download_modules "$temporary_dir"
    source_dir=$temporary_dir
  fi

  for module in "${ONE_BROWSER_EGRESS_UNINSTALL_MODULES[@]}"; do
    # shellcheck disable=SC1090
    . "$source_dir/$module"
  done

  if [ -n "$temporary_dir" ]; then
    rm -rf -- "$temporary_dir"
    trap - EXIT INT TERM HUP
  fi
}

egress_entrypoint_load_modules

if [ "${ONE_BROWSER_UNINSTALLER_LIBRARY_ONLY:-0}" != 1 ]; then
  main "$@"
fi
