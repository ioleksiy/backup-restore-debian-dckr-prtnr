#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

on_exit() {
  local status="$1"
  local notify="${2}"
  if [[ "${notify}" == "true" && "${status}" -ne 0 ]]; then
    notify_slack "FAIL" "check" "restic check failed"
  fi
}

main() {
  require_root
  require_command restic
  load_env_file
  configure_restic_transport
  require_env RESTIC_REPOSITORY RESTIC_PASSWORD

  local read_data_subset=""
  local should_unlock="false"
  local should_notify="false"

  local arg
  for arg in "$@"; do
    case "${arg}" in
      --read-data-subset=*)
        read_data_subset="${arg#*=}"
        ;;
      --unlock)
        should_unlock="true"
        ;;
      --notify)
        should_notify="true"
        ;;
      *)
        fail "Unknown argument: ${arg}. Supported: --read-data-subset=..., --unlock, --notify"
        ;;
    esac
  done

  trap 'on_exit "$?" "${should_notify}"' EXIT

  if [[ "${should_unlock}" == "true" ]]; then
    log "INFO" "Running restic unlock as explicitly requested."
    run_restic unlock
  fi

  log "INFO" "Listing snapshots."
  run_restic snapshots

  log "INFO" "Running restic check."
  if [[ -n "${read_data_subset}" ]]; then
    run_restic check --read-data-subset="${read_data_subset}"
  else
    run_restic check
  fi

  log "INFO" "restic check completed successfully."
  if [[ "${should_notify}" == "true" ]]; then
    notify_slack "OK" "check" "restic check completed successfully"
  fi
}

main "$@"
