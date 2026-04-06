#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

on_exit() {
  local status="$1"
  if [[ "${status}" -ne 0 ]]; then
    notify_slack "FAIL" "restore" "Restore failed"
  fi
}

main() {
  require_root
  require_command restic
  load_env_file
  configure_restic_transport
  require_env RESTIC_REPOSITORY RESTIC_PASSWORD

  local snapshot
  local target
  snapshot="${1:-${RESTIC_SNAPSHOT:-latest}}"
  target="${2:-${RESTORE_TARGET:-/restore-output}}"

  trap 'on_exit "$?"' EXIT

  if [[ "${target}" == "/" ]]; then
    fail "Refusing to restore to /. Choose a safe target directory."
  fi

  log "WARN" "Restore will write files to: ${target}"
  log "WARN" "This operation can overwrite files in the target directory."

  log "INFO" "Available snapshots:"
  run_restic snapshots

  printf 'Type RESTORE to continue: '
  local confirm
  read -r confirm
  if [[ "${confirm}" != "RESTORE" ]]; then
    fail "Confirmation mismatch. Restore aborted."
  fi

  ensure_dir "${target}"
  run_restic restore "${snapshot}" --target "${target}"

  log "INFO" "Restore completed successfully."
  notify_slack "OK" "restore" "Restore completed successfully"
}

main "$@"
