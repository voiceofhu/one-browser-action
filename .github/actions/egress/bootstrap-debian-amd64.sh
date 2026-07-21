#!/usr/bin/env bash

set -Eeuo pipefail

export LC_ALL=C
umask 077

readonly DEPLOY_USER=gh-deploy
readonly DEPLOY_GROUP=one-browser-deploy
readonly DEPLOY_HOME=/home/gh-deploy
readonly DEPLOY_DIR=/opt/one-browser-egress
readonly CERT_DIR="$DEPLOY_DIR/certs"
readonly CONTROL_NETWORK=one-browser-control
readonly CONTAINER_NAME=one-browser-egress

node_id=''
domain=''
control_url='https://browser.aicbe.com'
control_token_file=''
control_token=''
ssh_public_key=''
certbot_email=''
temp_files=()

usage() {
  cat <<'USAGE'
通过交互问答初始化一台 Debian amd64 Egress 服务器。

Usage:
  sudo bash bootstrap-debian-amd64.sh

脚本会依次询问节点编号、Egress 域名、证书邮箱和 gh-deploy SSH 公钥。
Server 控制地址固定为 https://browser.aicbe.com。节点控制 Token 由脚本自动生成，
不会显示在终端。

脚本安装 Docker Engine、Compose、Certbot 和 OpenSSH，创建 gh-deploy，准备
/opt/one-browser-egress、.env、TLS 证书和续期配置。它不会拉取镜像或启动
Egress；第一次部署仍由 GitHub Action 完成。
USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n==> %s\n' "$*"
}

cleanup() {
  local path
  for path in "${temp_files[@]-}"; do
    if [[ -n "$path" ]]; then
      rm -f -- "$path"
    fi
  done
}
trap cleanup EXIT

new_temp_file() {
  local result_name=$1
  local path
  path=$(mktemp /tmp/one-browser-egress-bootstrap.XXXXXX)
  temp_files+=("$path")
  printf -v "$result_name" '%s' "$path"
}

validate_hostname() {
  local hostname=$1
  local label
  local -a labels

  ((${#hostname} <= 253)) || return 1
  [[ "$hostname" == *.* ]] || return 1
  IFS='.' read -r -a labels <<<"$hostname"
  for label in "${labels[@]}"; do
    ((${#label} >= 1 && ${#label} <= 63)) || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

validate_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

collect_configuration() {
  local input=''
  local default_domain
  local answer

  while true; do
    IFS= read -r -p '节点编号或 ID [1]: ' input || die '无法读取节点编号'
    input=${input:-1}
    if [[ "$input" =~ ^[0-9]+$ ]]; then
      node_id="egress-$input"
    else
      node_id=$input
    fi
    if [[ "$node_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$ ]]; then
      break
    fi
    printf '节点 ID 只能包含 1-128 个字母、数字、连字符或下划线。\n' >&2
  done

  default_domain="${node_id,,}.aicbe.com"
  while true; do
    IFS= read -r -p "Egress 公网域名 [$default_domain]: " input || \
      die '无法读取 Egress 域名'
    domain=${input:-$default_domain}
    domain=${domain,,}
    if validate_hostname "$domain"; then
      break
    fi
    printf '请输入有效的 DNS 域名。\n' >&2
  done

  while true; do
    IFS= read -r -p "Let's Encrypt 联系邮箱: " certbot_email || \
      die '无法读取证书邮箱'
    if validate_email "$certbot_email"; then
      break
    fi
    printf '请输入有效邮箱。\n' >&2
  done

  while true; do
    IFS= read -r -p '粘贴 gh-deploy SSH 公钥: ' ssh_public_key || \
      die '无法读取 SSH 公钥'
    ssh_public_key=${ssh_public_key%$'\r'}
    if [[ -n "$ssh_public_key" && "$ssh_public_key" != *$'\n'* ]]; then
      break
    fi
    printf 'SSH 公钥不能为空。\n' >&2
  done

  control_token_file="/root/${node_id}.control-token"

  printf '\n即将初始化：\n'
  printf '  节点 ID:      %s\n' "$node_id"
  printf '  公网地址:     %s:27600\n' "$domain"
  printf '  Server 地址:  %s\n' "$control_url"
  printf '  证书邮箱:     %s\n' "$certbot_email"
  printf '  部署用户:     %s\n' "$DEPLOY_USER"
  printf '  部署目录:     %s\n' "$DEPLOY_DIR"
  printf '  Token 备份:   %s\n' "$control_token_file"
  IFS= read -r -p '确认继续？[y/N]: ' answer || die '无法读取确认结果'
  [[ "$answer" =~ ^[Yy]$ ]] || die '已取消'
}

case "${1:-}" in
  -h|--help)
    (($# == 1)) || die '--help 不能与其他参数一起使用'
    usage
    exit 0
    ;;
  '') ;;
  *) die '脚本不接受命令行配置参数，请直接运行并按照提示填写' ;;
esac

((EUID == 0)) || die '请使用 root 运行，例如：sudo bash bootstrap-debian-amd64.sh'
[[ -t 0 ]] || die '该脚本需要交互终端，请登录服务器后直接运行'

[[ -r /etc/os-release ]] || die '/etc/os-release is missing'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == debian ]] || die 'this script supports Debian only'
[[ "$(dpkg --print-architecture)" == amd64 ]] || die 'this script supports amd64 only'
[[ -n "${VERSION_CODENAME:-}" ]] || die 'Debian VERSION_CODENAME is missing'
[[ -d /run/systemd/system ]] || die 'this host must use systemd'

collect_configuration

package_is_installed() {
  dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -Fxq installed
}

check_docker_conflicts() {
  local package
  local -a conflicts=()
  local -a candidates=(
    docker.io
    docker-compose
    docker-compose-v2
    docker-doc
    podman-docker
    containerd
    runc
  )

  for package in "${candidates[@]}"; do
    if package_is_installed "$package"; then
      conflicts+=("$package")
    fi
  done

  if ((${#conflicts[@]} > 0)); then
    die "conflicting Docker packages are installed: ${conflicts[*]}. Remove them deliberately, then rerun this script"
  fi
}

install_docker() {
  local docker_key
  local docker_sources

  step 'Installing host packages'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates \
    certbot \
    curl \
    iproute2 \
    openssh-client \
    openssh-server \
    openssl

  check_docker_conflicts

  step "Configuring Docker's official Debian repository"
  install -d -m 0755 /etc/apt/keyrings
  new_temp_file docker_key
  curl -fsSL https://download.docker.com/linux/debian/gpg -o "$docker_key"
  install -m 0644 "$docker_key" /etc/apt/keyrings/docker.asc

  new_temp_file docker_sources
  cat > "$docker_sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  install -m 0644 "$docker_sources" /etc/apt/sources.list.d/docker.sources

  apt-get update
  apt-get install -y \
    containerd.io \
    docker-buildx-plugin \
    docker-ce \
    docker-ce-cli \
    docker-compose-plugin

  systemctl enable --now docker.service
  systemctl enable --now ssh.service
  ssh-keygen -A
  docker version >/dev/null
  docker compose version >/dev/null
}

create_deploy_user() {
  local actual_home
  local primary_group
  local authorized_keys
  local public_key_temp

  step "Creating $DEPLOY_USER and deployment directories"
  new_temp_file public_key_temp
  printf '%s\n' "$ssh_public_key" > "$public_key_temp"
  ssh-keygen -l -f "$public_key_temp" >/dev/null 2>&1 || \
    die '粘贴的 SSH 公钥无效'
  groupadd --force "$DEPLOY_GROUP"

  if id "$DEPLOY_USER" >/dev/null 2>&1; then
    actual_home=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
    [[ "$actual_home" == "$DEPLOY_HOME" ]] || \
      die "$DEPLOY_USER already exists with unexpected home directory $actual_home"
    usermod --shell /bin/bash "$DEPLOY_USER"
  else
    useradd \
      --create-home \
      --home-dir "$DEPLOY_HOME" \
      --shell /bin/bash \
      --user-group \
      "$DEPLOY_USER"
  fi

  passwd --lock "$DEPLOY_USER" >/dev/null
  usermod --append --groups "docker,$DEPLOY_GROUP" "$DEPLOY_USER"
  primary_group=$(id -gn "$DEPLOY_USER")

  install -d -m 0700 -o "$DEPLOY_USER" -g "$primary_group" "$DEPLOY_HOME/.ssh"
  authorized_keys="$DEPLOY_HOME/.ssh/authorized_keys"
  touch "$authorized_keys"
  chown "$DEPLOY_USER:$primary_group" "$authorized_keys"
  chmod 0600 "$authorized_keys"
  if ! grep -Fqx -- "$ssh_public_key" "$authorized_keys"; then
    printf '%s\n' "$ssh_public_key" >> "$authorized_keys"
  fi

  install -d -m 2770 -o root -g "$DEPLOY_GROUP" "$DEPLOY_DIR"
  install -d -m 0750 -o root -g 65532 "$CERT_DIR"
}

read_env_value() {
  local env_file=$1
  local key=$2
  local line
  local value=''
  local count=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    case "$line" in
      "$key="*)
        value=${line#*=}
        count=$((count + 1))
        ;;
    esac
  done < "$env_file"

  [[ "$count" -eq 1 ]] || die "$key must appear exactly once in $env_file"

  if ((${#value} >= 2)); then
    if [[ "$value" == \"*\" && "$value" == *\" ]] ||
       [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value=${value:1:${#value}-2}
    fi
  fi

  printf '%s' "$value"
}

prepare_control_token() {
  local env_file="$DEPLOY_DIR/.env"
  local token_temp
  local token_permissions
  local -a token_lines=()

  step 'Preparing the node control token'
  if [[ -e "$control_token_file" ]]; then
    [[ -f "$control_token_file" && -r "$control_token_file" ]] || \
      die "$control_token_file 必须是 root 可读的普通文件"
    token_permissions=$(stat -c '%A' "$control_token_file")
    [[ "${token_permissions:4:6}" == '------' ]] || \
      die "$control_token_file 不能允许组用户或其他用户读取"
    mapfile -t token_lines < "$control_token_file"
    ((${#token_lines[@]} == 1)) || die "$control_token_file 必须只有一行"
    control_token=${token_lines[0]}
    printf '保留已有节点 Token：%s\n' "$control_token_file"
  elif [[ -f "$env_file" ]]; then
    control_token=$(read_env_value "$env_file" EGRESS_CONTROL_TOKEN)
  else
    control_token=$(openssl rand -hex 32)
  fi

  if [[ ! "$control_token" =~ ^[A-Za-z0-9._~-]{32,4096}$ ]]; then
    die '节点 Token 必须是 32-4096 个不含空白的 URL-safe ASCII 字符'
  fi

  if [[ ! -e "$control_token_file" ]]; then
    new_temp_file token_temp
    printf '%s\n' "$control_token" > "$token_temp"
    install -m 0600 -o root -g root "$token_temp" "$control_token_file"
  fi
}

expect_env_value() {
  local env_file=$1
  local key=$2
  local expected=$3
  local actual

  actual=$(read_env_value "$env_file" "$key")
  [[ "$actual" == "$expected" ]] || \
    die "$key in $env_file does not match the requested node configuration"
}

create_or_validate_env() {
  local env_file="$DEPLOY_DIR/.env"
  local env_temp
  local existing_control_url

  step 'Creating the persistent Egress environment'
  if [[ -e "$env_file" ]]; then
    [[ -f "$env_file" ]] || die "$env_file exists but is not a regular file"
    expect_env_value "$env_file" EGRESS_ID "$node_id"
    expect_env_value "$env_file" EGRESS_PUBLIC_ENDPOINT "$domain:27600"
    existing_control_url=$(read_env_value "$env_file" EGRESS_CONTROL_URL)
    [[ "${existing_control_url%/}" == "$control_url" ]] || \
      die "EGRESS_CONTROL_URL in $env_file does not match the requested control URL"
    expect_env_value "$env_file" EGRESS_CONTROL_TOKEN "$control_token"
    expect_env_value "$env_file" EGRESS_PUBLISH_ADDR '0.0.0.0'
    expect_env_value "$env_file" EGRESS_HOST_PORT '27600'
    expect_env_value "$env_file" EGRESS_CERT_DIR './certs'
    expect_env_value "$env_file" EGRESS_BIND_ADDR '0.0.0.0:27600'
    expect_env_value "$env_file" EGRESS_TLS_CERT_FILE '/app/tls/fullchain.pem'
    expect_env_value "$env_file" EGRESS_TLS_KEY_FILE '/app/tls/privkey.pem'
    printf 'Preserving validated existing %s\n' "$env_file"
  else
    new_temp_file env_temp
    {
      printf 'EGRESS_CONTROL_URL=%s\n' "$control_url"
      printf 'EGRESS_CONTROL_TOKEN=%s\n' "$control_token"
      printf '\n'
      printf 'EGRESS_ID=%s\n' "$node_id"
      printf 'EGRESS_PUBLIC_ENDPOINT=%s:27600\n' "$domain"
      printf 'EGRESS_BIND_ADDR=0.0.0.0:27600\n'
      printf 'EGRESS_PUBLISH_ADDR=0.0.0.0\n'
      printf 'EGRESS_HOST_PORT=27600\n'
      printf 'EGRESS_TLS_CERT_FILE=/app/tls/fullchain.pem\n'
      printf 'EGRESS_TLS_KEY_FILE=/app/tls/privkey.pem\n'
      printf 'EGRESS_CERT_DIR=./certs\n'
      printf '\n'
      printf 'EGRESS_MAX_CONNECTIONS=256\n'
      printf 'EGRESS_MAX_CONNECTIONS_PER_IP=64\n'
      printf 'EGRESS_MAX_STREAMS_PER_CONNECTION=256\n'
      printf 'EGRESS_MAX_STREAMS_GLOBAL=2048\n'
      printf 'EGRESS_AUTHORIZATION_TIMEOUT_SECONDS=5\n'
      printf '\n'
      printf 'RUST_LOG=one_browser_egress=info\n'
    } > "$env_temp"
    install -m 0640 -o root -g "$DEPLOY_GROUP" "$env_temp" "$env_file"
  fi

  chown "root:$DEPLOY_GROUP" "$env_file"
  chmod 0640 "$env_file"
}

certificate_pair_is_valid() {
  local certificate=$1
  local private_key=$2
  local expected_domain=$3
  local certificate_public_key
  local private_public_key

  [[ -s "$certificate" && -s "$private_key" ]] || return 1
  openssl x509 -in "$certificate" -noout -checkhost "$expected_domain" >/dev/null 2>&1 || \
    return 1
  openssl x509 -in "$certificate" -noout -checkend 0 >/dev/null 2>&1 || return 1
  certificate_public_key=$(
    openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null |
      openssl pkey -pubin -outform DER 2>/dev/null |
      sha256sum
  ) || return 1
  private_public_key=$(
    openssl pkey -in "$private_key" -pubout -outform DER 2>/dev/null |
      sha256sum
  ) || return 1
  [[ "${certificate_public_key%% *}" == "${private_public_key%% *}" ]]
}

port_80_is_in_use() {
  ss -H -ltn 'sport = :80' | grep -q .
}

install_certificate() {
  local lineage="/etc/letsencrypt/live/$domain"

  step "Issuing or reusing the TLS certificate for $domain"
  if ! certificate_pair_is_valid "$lineage/fullchain.pem" "$lineage/privkey.pem" "$domain"; then
    if port_80_is_in_use; then
      ss -lntp 'sport = :80' >&2 || true
      die 'TCP port 80 is already in use; free it or issue the certificate with a compatible Certbot method before rerunning'
    fi
    certbot certonly \
      --standalone \
      --non-interactive \
      --agree-tos \
      --email "$certbot_email" \
      --cert-name "$domain" \
      --keep-until-expiring \
      -d "$domain"
  fi

  certificate_pair_is_valid "$lineage/fullchain.pem" "$lineage/privkey.pem" "$domain" || \
    die "the issued certificate or private key for $domain is invalid"

  install -m 0640 -o root -g 65532 "$lineage/privkey.pem" "$CERT_DIR/privkey.pem"
  install -m 0644 -o root -g 65532 "$lineage/fullchain.pem" "$CERT_DIR/fullchain.pem"
  certificate_pair_is_valid "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" "$domain" || \
    die 'the installed Egress certificate and private key do not match'
}

install_certbot_hook() {
  local hook_dir=/etc/letsencrypt/renewal-hooks/deploy
  local hook_file="$hook_dir/one-browser-egress"
  local hook_temp
  local domain_quoted
  local cert_dir_quoted
  local container_quoted

  step 'Installing the Certbot renewal hook'
  install -d -m 0755 "$hook_dir"
  new_temp_file hook_temp
  printf -v domain_quoted '%q' "$domain"
  printf -v cert_dir_quoted '%q' "$CERT_DIR"
  printf -v container_quoted '%q' "$CONTAINER_NAME"
  cat > "$hook_temp" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

domain=$domain_quoted
cert_dir=$cert_dir_quoted
container_name=$container_quoted
renewed_domains=\${RENEWED_DOMAINS:-}
renewed_lineage=\${RENEWED_LINEAGE:-}

case " \$renewed_domains " in
  *" \$domain "*) ;;
  *) exit 0 ;;
esac

[[ -n "\$renewed_lineage" ]] || exit 1
openssl x509 -in "\$renewed_lineage/fullchain.pem" -noout -checkhost "\$domain" >/dev/null
openssl x509 -in "\$renewed_lineage/fullchain.pem" -noout -checkend 0 >/dev/null

install -m 0640 -o root -g 65532 \
  "\$renewed_lineage/privkey.pem" "\$cert_dir/privkey.pem"
install -m 0644 -o root -g 65532 \
  "\$renewed_lineage/fullchain.pem" "\$cert_dir/fullchain.pem"

if docker inspect "\$container_name" >/dev/null 2>&1; then
  docker restart "\$container_name" >/dev/null
fi
EOF
  install -m 0750 -o root -g root "$hook_temp" "$hook_file"

  if systemctl list-unit-files certbot.timer --no-legend 2>/dev/null |
     grep -q '^certbot.timer'; then
    systemctl enable --now certbot.timer
  fi
}

verify_control_plane() {
  local status

  step "Verifying the Server control route at $control_url"
  status=$(curl \
    --silent \
    --show-error \
    --output /dev/null \
    --write-out '%{http_code}' \
    --connect-timeout 10 \
    --max-time 20 \
    "$control_url/internal/egress/v1/ready")
  [[ "$status" == 401 ]] || \
    die "the unauthenticated Server readiness route returned HTTP $status; expected 401"
}

verify_deploy_contract() {
  step 'Verifying GitHub Actions host permissions'
  docker network inspect "$CONTROL_NETWORK" >/dev/null 2>&1 || \
    docker network create "$CONTROL_NETWORK" >/dev/null
  runuser -u "$DEPLOY_USER" -- test -w "$DEPLOY_DIR" || \
    die "$DEPLOY_USER cannot write to $DEPLOY_DIR"
  runuser -u "$DEPLOY_USER" -- test -r "$DEPLOY_DIR/.env" || \
    die "$DEPLOY_USER cannot read $DEPLOY_DIR/.env"
  runuser -u "$DEPLOY_USER" -- docker info >/dev/null || \
    die "$DEPLOY_USER cannot access Docker directly"
  runuser -u "$DEPLOY_USER" -- docker compose version >/dev/null || \
    die "$DEPLOY_USER cannot run Docker Compose"
}

install_docker
prepare_control_token
create_deploy_user
create_or_validate_env
install_certificate
install_certbot_hook
verify_control_plane
verify_deploy_contract

step 'Bootstrap complete'
printf 'Node ID:              %s\n' "$node_id"
printf 'Public endpoint:      %s:27600\n' "$domain"
printf 'Control URL:          %s\n' "$control_url"
printf 'Deploy user:          %s\n' "$DEPLOY_USER"
printf 'Persistent directory: %s\n' "$DEPLOY_DIR"
printf 'Control token file:   %s (not printed; retain until Server registration)\n' \
  "$control_token_file"
printf '\nSSH host fingerprint to verify before creating DEPLOY_KNOWN_HOSTS:\n'
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
printf '\nNo Egress image was pulled and no Egress container was started.\n'
printf 'Register this node in Server, configure the matching GitHub Environment,\n'
printf 'enable it in egress-targets.json, then run make deploy-egress <node-number>.\n'
