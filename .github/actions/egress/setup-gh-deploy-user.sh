#!/usr/bin/env bash

set -Eeuo pipefail

export LC_ALL=C
umask 077

readonly DEPLOY_USER=gh-deploy
readonly DEPLOY_GROUP=one-browser-deploy
readonly DEPLOY_HOME=/home/gh-deploy
readonly DEPLOY_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINAg0AqSzCO0PUitKd2Y/pHbH5lRxC1W2WddH9gB3yQ7 gh-deploy@one-browser'

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
创建或修复 One Browser 的 gh-deploy 部署账号，并安装仓库内固定的 SSH 公钥。

Usage:
  sudo bash setup-gh-deploy-user.sh

该脚本要求 Docker 已安装。它会将 gh-deploy 加入 docker 和
one-browser-deploy 组，并将 authorized_keys 设置为固定公钥。
USAGE
}

case "${1:-}" in
  -h|--help)
    (($# == 1)) || die '--help 不能与其他参数一起使用'
    usage
    exit 0
    ;;
  '') ;;
  *) die '该脚本不接受参数' ;;
esac

((EUID == 0)) || die '请使用 root 运行，例如：sudo bash setup-gh-deploy-user.sh'
[[ -r /etc/os-release ]] || die '/etc/os-release is missing'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == debian ]] || die 'this script supports Debian only'

command -v ssh-keygen >/dev/null 2>&1 || die 'ssh-keygen is required'
command -v chage >/dev/null 2>&1 || die 'chage is required'
getent group docker >/dev/null 2>&1 || \
  die 'the docker group does not exist; install Docker before running this script'
printf '%s\n' "$DEPLOY_PUBLIC_KEY" | ssh-keygen -lf - >/dev/null || \
  die 'the embedded SSH public key is invalid'

groupadd --force "$DEPLOY_GROUP"

if id "$DEPLOY_USER" >/dev/null 2>&1; then
  actual_home=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
  [[ "$actual_home" == "$DEPLOY_HOME" ]] || \
    die "$DEPLOY_USER already exists with unexpected home directory $actual_home"
  usermod --shell /bin/bash "$DEPLOY_USER"
else
  if getent group "$DEPLOY_USER" >/dev/null 2>&1; then
    useradd \
      --create-home \
      --home-dir "$DEPLOY_HOME" \
      --shell /bin/bash \
      --gid "$DEPLOY_USER" \
      "$DEPLOY_USER"
  else
    useradd \
      --create-home \
      --home-dir "$DEPLOY_HOME" \
      --shell /bin/bash \
      --user-group \
      "$DEPLOY_USER"
  fi
fi

# Disable password authentication without locking public-key authentication.
usermod --password '*NP*' "$DEPLOY_USER"
chage --expiredate -1 --inactive -1 --maxdays -1 "$DEPLOY_USER"
usermod --append --groups "docker,$DEPLOY_GROUP" "$DEPLOY_USER"

primary_group=$(id -gn "$DEPLOY_USER")
install -d -m 0750 -o "$DEPLOY_USER" -g "$primary_group" "$DEPLOY_HOME"
install -d -m 0700 -o "$DEPLOY_USER" -g "$primary_group" "$DEPLOY_HOME/.ssh"

authorized_keys="$DEPLOY_HOME/.ssh/authorized_keys"
printf '%s\n' "$DEPLOY_PUBLIC_KEY" > "$authorized_keys"
chown "$DEPLOY_USER:$primary_group" "$authorized_keys"
chmod 0600 "$authorized_keys"

password_field=$(getent shadow "$DEPLOY_USER" | cut -d: -f2)
[[ "$password_field" == '*NP*' ]] || die "$DEPLOY_USER account is locked"
grep -Fqx -- "$DEPLOY_PUBLIC_KEY" "$authorized_keys" || \
  die "$authorized_keys does not contain the managed SSH public key"

printf 'Configured %s as a key-only deployment account.\n' "$DEPLOY_USER"
id "$DEPLOY_USER"
ssh-keygen -lf "$authorized_keys"
