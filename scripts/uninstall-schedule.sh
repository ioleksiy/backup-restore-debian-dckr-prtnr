#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

SERVICE_NAME="restic-docker-backup.service"
TIMER_NAME="restic-docker-backup.timer"
SYSTEMD_DIR="/etc/systemd/system"

main() {
  require_root
  require_command systemctl

  if systemctl list-unit-files | grep -q "^${TIMER_NAME}"; then
    systemctl disable --now "${TIMER_NAME}" || true
    log "INFO" "Disabled and stopped ${TIMER_NAME}."
  else
    log "INFO" "Timer ${TIMER_NAME} not installed."
  fi

  rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}" "${SYSTEMD_DIR}/${TIMER_NAME}"
  log "INFO" "Removed unit files from ${SYSTEMD_DIR}."

  systemctl daemon-reload
  systemctl reset-failed

  log "INFO" "Schedule uninstall complete."
}

main "$@"
