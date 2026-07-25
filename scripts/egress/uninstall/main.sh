# shellcheck shell=bash

main() {
  local detected_mode requested_mode=

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        [ "$#" -ge 2 ] || die "--mode requires a value"
        [ -z "$requested_mode" ] || die "--mode may be supplied only once"
        requested_mode=$2
        shift 2
        ;;
      -h|--help)
        show_help
        return 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  if [ -n "$requested_mode" ]; then
    validate_mode "$requested_mode" || die "--mode must be native or docker"
  fi
  [ "${EUID:-$(id -u)}" -eq 0 ] ||
    die "Run this uninstaller as root (the generated command uses sudo)"
  umask 077
  install -d -m 0700 -o root -g root "$RUN_DIR"
  exec 9>"$RUN_DIR/install.lock"
  flock -n 9 || die "An Egress installation or uninstall is already running"

  detected_mode=$(detect_mode)
  if [ -z "$detected_mode" ]; then
    log "No One Browser Egress installation was found"
    return 0
  fi
  if [ -n "$requested_mode" ] && [ "$requested_mode" != "$detected_mode" ]; then
    die "Installed mode is $detected_mode, not $requested_mode"
  fi

  log "Stopping and removing the $detected_mode Egress runtime"
  if [ "$detected_mode" = native ]; then
    uninstall_native
  else
    uninstall_docker
  fi
  rm -f -- "$RENEWAL_HOOK"
  rm -rf -- "$INSTALL_DIR"
  log "One Browser Egress was uninstalled; Docker and Certbot certificates were preserved"
}
