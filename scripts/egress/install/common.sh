#!/usr/bin/env bash

# Shared logging, help text, and input validation for the Egress installer.

set +x
set -Eeuo pipefail

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

print_uninstall_command() {
  cat <<'EOF'
( set -o pipefail; r=; if [ "$(id -u)" -ne 0 ]; then command -v sudo >/dev/null 2>&1 || { echo 'root privileges or sudo are required' >&2; exit 1; }; r=sudo; fi; curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 'https://raw.githubusercontent.com/voiceofhu/one-browser-action/main/uninstall.sh' | $r bash )
EOF
}

die_runtime_switch() {
  local existing_runtime=$1
  local requested_runtime=$2

  printf 'Error: Egress is installed in %s mode; uninstall it before switching to %s mode.\n' \
    "$existing_runtime" "$requested_runtime" >&2
  printf 'Run the complete uninstall command:\n' >&2
  print_uninstall_command >&2
  exit 1
}

show_help() {
  cat <<'EOF'
Install and enroll one One Browser Egress node.

Usage:
  ONE_BROWSER_ENROLLMENT_TOKEN=<one-time-token> \
    install.sh --mode <native|docker> --control-url <origin> \
      --tls-enabled <true|false> [--version <version>]

Compatibility:
  install.sh --mode <native|docker> --control-url <origin> \
    --tls-enabled <true|false> \
    --enrollment-token <one-time-token>

Options:
  --mode              native installs a systemd service; docker installs a
                      Docker Compose service
  --version           Optional Egress version such as 26.724.1. When omitted
                      or set to latest, install the latest published version.
  --control-url       Public One Browser Server origin, for example
                      https://browser.example.com
  --tls-enabled       Expected data-plane mode from the generated command.
                      true requires production HTTPS/DNS/Certbot; false permits
                      explicit development HTTP and plaintext H2.
  --enrollment-token Compatibility input; mutually exclusive with the
                     ONE_BROWSER_ENROLLMENT_TOKEN environment variable
  --replace-existing-enrollment
                     Explicitly replace an expired or cancelled local
                     enrollment. The new claim must have the same node ID and
                     domain. Disabled by default.
  -h, --help          Show this help

Run as root. The generated Web command uses sudo automatically.
Running the generated command again keeps the enrolled node identity. It exits
without changing the runtime when the requested version is already installed,
or updates the existing runtime in place when the requested version differs.
EOF
}

validate_secret_token() {
  local value=${1-}
  [ "${#value}" -ge 32 ] &&
    [ "${#value}" -le 4096 ] &&
    [[ "$value" =~ ^[A-Za-z0-9._~-]+$ ]]
}

validate_domain() {
  local domain=${1-}
  local label
  local old_ifs

  [ -n "$domain" ] || return 1
  [ "${#domain}" -le 253 ] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1

  old_ifs=$IFS
  IFS=.
  # shellcheck disable=SC2206
  local labels=($domain)
  IFS=$old_ifs
  for label in "${labels[@]}"; do
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

validate_ipv4() {
  local value=${1-}
  local octet
  local old_ifs=$IFS

  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=.
  # shellcheck disable=SC2206
  local octets=($value)
  IFS=$old_ifs
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
}

validate_boolean() {
  [ "${1-}" = true ] || [ "${1-}" = false ]
}

validate_lower_sha256() {
  local value=${1-}
  [ "${#value}" -eq 64 ] && [[ "$value" =~ ^[a-f0-9]+$ ]]
}

validate_install_mode() {
  [ "${1-}" = native ] || [ "${1-}" = docker ]
}

normalize_version() {
  local value=${1-latest}

  value=${value#egress-}
  value=${value#v}
  if [ -z "$value" ] || [ "$value" = latest ]; then
    printf 'latest'
    return 0
  fi
  [[ "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$ ]] ||
    return 1
  printf '%s' "$value"
}

validate_control_url() {
  local url=${1-}
  local tls_enabled=${2-true}
  local authority host port scheme

  validate_boolean "$tls_enabled" || return 1
  case "$url" in
    https://*) scheme=https; authority=${url#https://} ;;
    http://*)
      [ "$tls_enabled" = false ] || return 1
      scheme=http
      authority=${url#http://}
      ;;
    *) return 1 ;;
  esac
  authority=${authority%/}
  [ -n "$authority" ] || return 1
  [[ "$authority" != */* && "$authority" != *\?* && "$authority" != *\#* ]] || return 1
  [[ "$authority" != *@* ]] || return 1

  host=$authority
  if [[ "$authority" == *:* ]]; then
    host=${authority%:*}
    port=${authority##*:}
    validate_positive_integer "$port" 1 65535 || return 1
  fi
  if [ "$tls_enabled" = true ]; then
    [ "$scheme" = https ] && validate_domain "$host"
  else
    validate_domain "$host" || validate_ipv4 "$host" ||
      [[ "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
  fi
}

normalize_control_url() {
  printf '%s' "${1%/}"
}

validate_egress_id() {
  local value=${1-}
  [ "${#value}" -ge 1 ] &&
    [ "${#value}" -le 128 ] &&
    [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]]
}

validate_positive_integer() {
  local value=${1-}
  local minimum=${2-}
  local maximum=${3-}
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ]
}

validate_public_endpoint() {
  local domain=${1-}
  local endpoint=${2-}
  local host port

  [[ "$endpoint" == *:* ]] || return 1
  host=${endpoint%:*}
  port=${endpoint##*:}
  [ "$host" = "$domain" ] || return 1
  validate_positive_integer "$port" 1 65535
}

validate_image_reference() {
  local image=${1-}
  local last_component tag

  [ "${#image}" -ge 3 ] && [ "${#image}" -le 512 ] || return 1
  [[ "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]+$ ]] || return 1
  [[ "$image" != */ && "$image" != *//* && "$image" != *..* ]] || return 1

  if [[ "$image" == *@* ]]; then
    [[ "$image" =~ @sha256:[a-f0-9]{64}$ ]] || return 1
  else
    last_component=${image##*/}
    [[ "$last_component" == *:* ]] || return 1
    tag=${last_component##*:}
    [ -n "$tag" ] || return 1
  fi
}

all_addresses_equal() {
  local records=${1-}
  local expected=${2-}
  local record
  local found=0

  [ -n "$records" ] && [ -n "$expected" ] || return 1
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    [ "$record" = "$expected" ] || return 1
    found=1
  done <<<"$records"
  [ "$found" -eq 1 ]
}
