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
  require_command systemctl sed install

  local service_src
  local timer_src
  service_src="${REPO_ROOT}/systemd/${SERVICE_NAME}"
  timer_src="${REPO_ROOT}/systemd/${TIMER_NAME}"

  if [[ ! -f "${service_src}" ]]; then
    fail "Service template missing: ${service_src}"
  fi
  if [[ ! -f "${timer_src}" ]]; then
    fail "Timer template missing: ${timer_src}"
  fi

  local escaped_repo
  escaped_repo="$(printf '%s' "${REPO_ROOT}" | sed 's/[\&/]/\\&/g')"

  sed "s#__REPO_ROOT__#${escaped_repo}#g" "${service_src}" > "${SYSTEMD_DIR}/${SERVICE_NAME}"
  install -m 644 "${timer_src}" "${SYSTEMD_DIR}/${TIMER_NAME}"
  chmod 644 "${SYSTEMD_DIR}/${SERVICE_NAME}" "${SYSTEMD_DIR}/${TIMER_NAME}"

  systemctl daemon-reload
  systemctl enable --now "${TIMER_NAME}"

  log "INFO" "Installed ${SERVICE_NAME} and ${TIMER_NAME} into ${SYSTEMD_DIR}."
  log "INFO" "Timer status: systemctl status ${TIMER_NAME}"
  log "INFO" "Next runs: systemctl list-timers ${TIMER_NAME}"
  log "INFO" "Run backup now: systemctl start ${SERVICE_NAME}"
}

main "$@"
