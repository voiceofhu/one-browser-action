#!/usr/bin/env bash

set -Eeuo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: resolve-egress-targets.sh <targets.json>" >&2
  exit 1
fi

config_file=$1
selection=${EGRESS_TARGETS_INPUT:-all}
selection=$(printf '%s' "$selection" | tr -d '[:space:]')
rollout=${EGRESS_ROLLOUT_INPUT:-full}

case "$rollout" in
  canary|full) ;;
  *)
    echo "rollout must be 'canary' or 'full'" >&2
    exit 1
    ;;
esac

if [ ! -f "$config_file" ]; then
  echo "Egress target configuration does not exist: $config_file" >&2
  exit 1
fi

if ! jq -e '
  .version == 1
  and (.targets | type == "array" and length > 0)
  and ([.targets[].id] | length == (unique | length))
  and all(.targets[];
    (.id | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$"))
    and (.enabled | type == "boolean")
    and (.wave | type == "number" and floor == . and . >= 1 and . <= 10)
    and (.environment | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"))
    and (.host | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]{0,252}[A-Za-z0-9]$"))
    and (.port | type == "number" and floor == . and . >= 1 and . <= 65535)
    and (.user | type == "string" and test("^[a-z_][a-z0-9_-]{0,31}$"))
    and (.endpoint | type == "string" and test("^[A-Za-z0-9.-]+:[0-9]{1,5}$"))
    and (.control_url | type == "string" and test("^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$"))
    and (.remote_dir == "/opt/one-browser-egress")
    and (.compose_project_name | type == "string" and test("^[a-z0-9][a-z0-9_-]{0,62}$"))
    and (.compose_service_name | type == "string" and test("^[a-z0-9][a-z0-9_-]{0,62}$"))
    and (.container_name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"))
    and (.control_network | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"))
    and (.use_sudo == "0" or .use_sudo == "1")
    and (.public_check | type == "boolean")
    and (.log_tail | type == "number" and floor == . and . >= 1 and . <= 10000)
    and (.log_follow_seconds | type == "number" and floor == . and . >= 0 and . <= 60)
  )
' "$config_file" >/dev/null; then
  echo "Invalid Egress target configuration: $config_file" >&2
  exit 1
fi

if [ -z "$selection" ] || [ "$selection" = all ]; then
  requested=$(jq -c '[.targets[] | select(.enabled) | .id]' "$config_file")
else
  requested=$(printf '%s' "$selection" | jq -Rc 'split(",")')
  if ! jq -e 'length > 0 and all(.[]; test("^[a-z0-9][a-z0-9-]{0,62}$")) and length == (unique | length)' \
    <<<"$requested" >/dev/null; then
    echo "deploy_targets must be 'all' or unique comma-separated target IDs" >&2
    exit 1
  fi
fi

if ! jq -e --argjson requested "$requested" '
  [.targets[] | select(.enabled) | .id] as $enabled
  | ($requested - $enabled | length) == 0
' "$config_file" >/dev/null; then
  echo "One or more requested Egress targets are unknown or disabled: $selection" >&2
  exit 1
fi

matrices=$(jq -c \
  --argjson requested "$requested" \
  --arg rollout "$rollout" '
  def workflow_target: {
    id: .id,
    wave: .wave,
    environment: .environment,
    host: .host,
    port: .port,
    user: .user,
    endpoint: .endpoint,
    control_url: .control_url,
    remote_dir: .remote_dir,
    compose_project_name: .compose_project_name,
    compose_service_name: .compose_service_name,
    container_name: .container_name,
    control_network: .control_network,
    use_sudo: .use_sudo,
    public_check: .public_check,
    log_tail: .log_tail,
    log_follow_seconds: .log_follow_seconds
  };

  [
    .targets[]
    | select(.enabled)
    | select(.id as $id | $requested | index($id))
  ] as $selected
  | ($selected | map(.wave) | min) as $first_wave
  | {
      canary_matrix: {
        include: [
          $selected[]
          | select(.wave == $first_wave)
          | {target: workflow_target}
        ]
      },
      rollout_matrix: {
        include: [
          if $rollout == "full" then
            $selected[]
            | select(.wave > $first_wave)
            | {target: workflow_target}
          else
            empty
          end
        ]
      }
    }
' "$config_file")

canary_matrix=$(jq -c '.canary_matrix' <<<"$matrices")
canary_count=$(jq -r '.canary_matrix.include | length' <<<"$matrices")
rollout_matrix=$(jq -c '.rollout_matrix' <<<"$matrices")
rollout_count=$(jq -r '.rollout_matrix.include | length' <<<"$matrices")
total_count=$((canary_count + rollout_count))

if [ "$canary_count" -lt 1 ]; then
  echo "No enabled Egress deploy targets were selected" >&2
  exit 1
fi

{
  printf 'canary_matrix=%s\n' "$canary_matrix"
  printf 'canary_count=%s\n' "$canary_count"
  printf 'rollout_matrix=%s\n' "$rollout_matrix"
  printf 'rollout_count=%s\n' "$rollout_count"
} >> "$GITHUB_OUTPUT"

echo "Selected $total_count Egress deploy target(s) with rollout=$rollout:"
jq -r '
  .canary_matrix.include[].target
  | "- canary: \(.id) wave=\(.wave) \(.user)@\(.host):\(.port) -> \(.endpoint)"
' <<<"$matrices"
jq -r '
  .rollout_matrix.include[].target
  | "- rollout: \(.id) wave=\(.wave) \(.user)@\(.host):\(.port) -> \(.endpoint)"
' <<<"$matrices"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Egress deploy targets"
    echo
    echo '| Stage | Wave | ID | SSH | Public endpoint | Environment |'
    echo '| --- | --- | --- | --- | --- | --- |'
    jq -r '
      .canary_matrix.include[].target
      | "| Canary | `\(.wave)` | `\(.id)` | `\(.user)@\(.host):\(.port)` | `\(.endpoint)` | `\(.environment)` |"
    ' <<<"$matrices"
    jq -r '
      .rollout_matrix.include[].target
      | "| Rollout | `\(.wave)` | `\(.id)` | `\(.user)@\(.host):\(.port)` | `\(.endpoint)` | `\(.environment)` |"
    ' <<<"$matrices"
  } >> "$GITHUB_STEP_SUMMARY"
fi
