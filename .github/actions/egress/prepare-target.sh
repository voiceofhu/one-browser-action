#!/usr/bin/env bash

set -Eeuo pipefail

: "${SSH_HOST:?SSH_HOST is required}"
: "${REMOTE_DIR:?REMOTE_DIR is required}"
: "${EXPECTED_EGRESS_ID:?EXPECTED_EGRESS_ID is required}"
: "${EXPECTED_PUBLIC_ENDPOINT:?EXPECTED_PUBLIC_ENDPOINT is required}"
: "${EXPECTED_CONTROL_URL:?EXPECTED_CONTROL_URL is required}"

if [ "$REMOTE_DIR" != "/opt/one-browser-egress" ]; then
  echo "REMOTE_DIR must be /opt/one-browser-egress" >&2
  exit 1
fi

shell_quote() {
  printf '%q' "$1"
}

# Values are validated locally and escaped with printf %q before remote expansion.
# shellcheck disable=SC2029
ssh "$SSH_HOST" \
  "bash -s -- \
  $(shell_quote "$REMOTE_DIR") \
  $(shell_quote "$EXPECTED_EGRESS_ID") \
  $(shell_quote "$EXPECTED_PUBLIC_ENDPOINT") \
  $(shell_quote "$EXPECTED_CONTROL_URL")" <<'REMOTE_PREPARE'
set -Eeuo pipefail

remote_dir=$1
expected_id=$2
expected_endpoint=$3
expected_control_url=${4%/}

cd "$remote_dir"
if [ ! -r .env ]; then
  echo "$remote_dir/.env must exist and be readable by the deploy user" >&2
  exit 1
fi

read_env_value() {
  local key=$1
  local line value=''
  local count=0

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      "$key="*)
        value=${line#*=}
        count=$((count + 1))
        ;;
    esac
  done < .env

  if [ "$count" -ne 1 ]; then
    echo "$key must appear exactly once in $remote_dir/.env" >&2
    return 1
  fi

  if [ "${#value}" -ge 2 ]; then
    if [[ "$value" == \"*\" && "$value" == *\" ]] ||
       [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value=${value:1:${#value}-2}
    fi
  fi

  printf '%s' "$value"
}

actual_id=$(read_env_value EGRESS_ID)
actual_endpoint=$(read_env_value EGRESS_PUBLIC_ENDPOINT)
actual_control_url=$(read_env_value EGRESS_CONTROL_URL)
actual_control_url=${actual_control_url%/}

if [ "$actual_id" != "$expected_id" ]; then
  echo "EGRESS_ID does not match deployment target $expected_id" >&2
  exit 1
fi
if [ "$actual_endpoint" != "$expected_endpoint" ]; then
  echo "EGRESS_PUBLIC_ENDPOINT does not match target $expected_id" >&2
  exit 1
fi
if [ "$actual_control_url" != "$expected_control_url" ]; then
  echo "EGRESS_CONTROL_URL does not match target $expected_id" >&2
  exit 1
fi

previous_compose=docker-compose.yml.action-previous
rm -f -- "$previous_compose"
if [ -f docker-compose.yml ]; then
  cp -p -- docker-compose.yml "$previous_compose"
fi

echo "Verified Egress target identity: $expected_id"
REMOTE_PREPARE
