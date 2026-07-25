# shellcheck shell=bash

discover_public_ip() {
  local family=$1
  local candidate url

  for url in https://api.ipify.org https://ifconfig.me/ip; do
    candidate=$(curl -q --proto '=https' --tlsv1.2 "-$family" \
      --fail --silent --show-error --noproxy '*' \
      --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)
    candidate=${candidate//$'\r'/}
    candidate=${candidate//$'\n'/}
    if [ "$family" = 4 ] && [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    if [ "$family" = 6 ] && [[ "$candidate" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$candidate" == *:* ]]; then
      if canonicalize_ipv6 "$candidate"; then
        return 0
      fi
    fi
  done
  return 1
}

canonicalize_ipv6() {
  local value=$1

  python3 -c '
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if address.version != 6:
    raise SystemExit(1)
print(address.compressed)
' "$value"
}

query_ipv4_records() {
  local domain=$1

  dig +time=5 +tries=2 +short "$domain" A 2>/dev/null |
    filter_ipv4_records
}

filter_ipv4_records() {
  local record

  while IFS= read -r record; do
    if validate_ipv4 "$record"; then
      printf '%s\n' "$record"
    fi
  done | sort -u
}

query_public_dns_records() {
  local domain=$1
  local record_type=$2
  local endpoint=$3

  curl -q --proto '=https' --tlsv1.2 \
    --fail --silent --show-error --no-location \
    --connect-timeout 5 --max-time 10 --max-filesize 65536 \
    --header 'Accept: application/dns-json' \
    --get \
    --data-urlencode "name=$domain" \
    --data-urlencode "type=$record_type" \
    "$endpoint" 2>/dev/null |
    jq -r --arg record_type "$record_type" '
      select(type == "object" and .Status == 0)
      | (.Answer // [])[]
      | select(
          type == "object"
          and (.type | tostring) == $record_type
          and (.data | type) == "string"
        )
      | .data
    '
}

query_public_ipv4_records() {
  local domain=$1

  {
    query_public_dns_records "$domain" 1 'https://dns.google/resolve' || true
    query_public_dns_records "$domain" 1 'https://cloudflare-dns.com/dns-query' || true
  } |
    filter_ipv4_records
}

resolve_ipv4() {
  local domain=$1
  local records

  records=$(query_ipv4_records "$domain" || true)
  if [ -z "$records" ]; then
    log "System DNS returned no A records for $domain; checking public DNS resolvers" >&2
    records=$(query_public_ipv4_records "$domain" || true)
  fi
  printf '%s' "$records"
}

query_ipv6_records() {
  local domain=$1
  local normalized record

  dig +time=5 +tries=2 +short "$domain" AAAA 2>/dev/null |
    awk '/^[0-9A-Fa-f:]+$/ && /:/ {print tolower($0)}' |
    while IFS= read -r record; do
      normalized=$(canonicalize_ipv6 "$record" 2>/dev/null || true)
      [ -n "$normalized" ] && printf '%s\n' "$normalized"
    done | sort -u
}

query_public_ipv6_records() {
  local domain=$1
  local normalized record

  {
    query_public_dns_records "$domain" 28 'https://dns.google/resolve' || true
    query_public_dns_records "$domain" 28 'https://cloudflare-dns.com/dns-query' || true
  } |
    awk '/^[0-9A-Fa-f:]+$/ && /:/ {print tolower($0)}' |
    while IFS= read -r record; do
      normalized=$(canonicalize_ipv6 "$record" 2>/dev/null || true)
      [ -n "$normalized" ] && printf '%s\n' "$normalized"
    done | sort -u
}

resolve_ipv6() {
  local domain=$1
  local records

  records=$(query_ipv6_records "$domain" || true)
  if [ -z "$records" ]; then
    records=$(query_public_ipv6_records "$domain" || true)
  fi
  printf '%s' "$records"
}

verify_domain_points_here() {
  local domain=$1
  local dns_v4 dns_v6 public_v4

  dns_v4=$(resolve_ipv4 "$domain" || true)
  dns_v6=$(resolve_ipv6 "$domain" || true)
  [ -z "$dns_v6" ] ||
    die "$domain publishes AAAA records, but one-click enrollment currently supports IPv4 only"
  [ -n "$dns_v4" ] || die "$domain must publish at least one IPv4 A record"
  public_v4=$(discover_public_ip 4 || true)
  [ -n "$public_v4" ] || die "Unable to determine this host's public IPv4 address"
  all_addresses_equal "$dns_v4" "$public_v4" ||
    die "$domain has an A record that does not point to this host; fix DNS before requesting TLS"
  log "Every DNS A record points to this host's public IPv4 address"
}

issue_and_install_certificate() {
  local cert_group live_dir

  log "Requesting or reusing the Let's Encrypt certificate for $CONFIG_DOMAIN"
  if ! certbot certonly \
    --standalone \
    --preferred-challenges http \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --keep-until-expiring \
    --cert-name "$CONFIG_DOMAIN" \
    -d "$CONFIG_DOMAIN"; then
    die "Certificate issuance failed; ensure inbound TCP 80 is open and not in use"
  fi
  live_dir="/etc/letsencrypt/live/$CONFIG_DOMAIN"
  [ -r "$live_dir/fullchain.pem" ] && [ -r "$live_dir/privkey.pem" ] ||
    die "Certbot succeeded but certificate files are unavailable"
  if [ "$INSTALL_MODE" = native ]; then
    cert_group=one-browser-egress
  else
    cert_group=65532
  fi
  install -m 0644 -o root -g "$cert_group" "$live_dir/fullchain.pem" "$CERT_DIR/fullchain.pem"
  install -m 0640 -o root -g "$cert_group" "$live_dir/privkey.pem" "$CERT_DIR/privkey.pem"
}

ensure_tls_configuration() {
  [ "$CONFIG_TLS_ENABLED" = true ] || return 0

  ensure_certificate_directory
  if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ -L "$CERT_DIR/fullchain.pem" ] ||
    [ ! -f "$CERT_DIR/privkey.pem" ] || [ -L "$CERT_DIR/privkey.pem" ]; then
    log "Egress TLS files are incomplete; requesting or restoring the certificate"
    verify_domain_points_here "$CONFIG_DOMAIN"
    issue_and_install_certificate
  fi
  write_renewal_hook
}

write_renewal_hook() {
  local hook_dir=/etc/letsencrypt/renewal-hooks/deploy
  local hook_file=$hook_dir/one-browser-egress.sh
  local cert_group hook_tmp restart_command

  if [ "$INSTALL_MODE" = native ]; then
    cert_group=one-browser-egress
    restart_command="systemctl restart one-browser-egress"
  else
    cert_group=65532
    restart_command="docker compose --project-name one-browser-egress --env-file '$ENV_FILE' -f '$COMPOSE_FILE' restart egress"
  fi

  install -d -m 0755 -o root -g root "$hook_dir"
  hook_tmp=$(mktemp "$hook_dir/one-browser-egress.sh.tmp.XXXXXX")
  cat >"$hook_tmp" <<EOF
#!/usr/bin/env bash
set +x
set -Eeuo pipefail

domain='$CONFIG_DOMAIN'
case " \${RENEWED_DOMAINS:-} " in
  *" \${domain} "*) ;;
  *) exit 0 ;;
esac

install -d -m 0750 -o root -g '$cert_group' '$CERT_DIR'
install -m 0644 -o root -g '$cert_group' \
  "/etc/letsencrypt/live/\${domain}/fullchain.pem" \
  '$CERT_DIR/fullchain.pem'
install -m 0640 -o root -g '$cert_group' \
  "/etc/letsencrypt/live/\${domain}/privkey.pem" \
  '$CERT_DIR/privkey.pem'
$restart_command
EOF
  chown root:root "$hook_tmp"
  chmod 0755 "$hook_tmp"
  mv -f "$hook_tmp" "$hook_file"
}
