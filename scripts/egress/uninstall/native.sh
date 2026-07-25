# shellcheck shell=bash

uninstall_native() {
  command -v systemctl >/dev/null 2>&1 ||
    die "systemctl is required to remove the native Egress service"
  systemctl stop one-browser-egress >/dev/null 2>&1 || true
  if systemctl is-active --quiet one-browser-egress; then
    die "The native Egress service could not be stopped"
  fi
  systemctl disable one-browser-egress >/dev/null 2>&1 || true
  rm -f -- "$NATIVE_SERVICE_FILE" "$NATIVE_BINARY"
  systemctl daemon-reload
  systemctl reset-failed one-browser-egress >/dev/null 2>&1 || true
  if id one-browser-egress >/dev/null 2>&1 && command -v userdel >/dev/null 2>&1; then
    userdel one-browser-egress >/dev/null 2>&1 || true
  fi
}
