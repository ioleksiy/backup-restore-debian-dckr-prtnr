#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-/etc/backup-restore.env}"

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$level" "$*"
}

fail() {
  log "ERROR" "$*"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "This script must run as root."
  fi
}

require_command() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      fail "Required command not found: ${cmd}"
    fi
  done
}

load_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    fail "Environment file not found: ${ENV_FILE}. Run scripts/setup-env.sh first."
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

require_env() {
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      fail "Required environment variable is missing or empty: ${var}"
    fi
  done
}

ensure_dir() {
  local dir="$1"
  mkdir -p "${dir}"
}

configure_restic_transport() {
  if [[ -n "${RESTIC_SFTP_PASSWORD:-}" ]]; then
    require_command sshpass
    export SSHPASS="${RESTIC_SFTP_PASSWORD}"

    if [[ -z "${RESTIC_SFTP_COMMAND:-}" ]]; then
      RESTIC_SFTP_COMMAND="sshpass -e ssh -o BatchMode=no -o StrictHostKeyChecking=accept-new"
    fi
  fi
}

run_restic() {
  local -a opts=()
  if [[ -n "${RESTIC_SFTP_COMMAND:-}" ]]; then
    opts+=( -o "sftp.command=${RESTIC_SFTP_COMMAND}" )
  fi

  restic "${opts[@]}" "$@"
}

sanitize_filename() {
  local name="$1"
  name="${name// /_}"
  name="${name//\//_}"
  name="${name//:/_}"
  name="${name//[^a-zA-Z0-9._-]/_}"
  printf '%s' "${name}"
}

notify_slack() {
  local status="$1"
  local action="$2"
  local message="${3:-}"

  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    return 0
  fi

  local hostname_value
  hostname_value="$(hostname -f 2>/dev/null || hostname)"

  local text
  text="[${status}] ${action} on ${hostname_value}"
  if [[ -n "${message}" ]]; then
    text+=" - ${message}"
  fi

  local escaped_text
  escaped_text="$(printf '%s' "${text}" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  local payload
  if [[ -n "${SLACK_NOTIFY_CHANNEL:-}" ]]; then
    local escaped_channel
    escaped_channel="$(printf '%s' "${SLACK_NOTIFY_CHANNEL}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    payload="{\"text\":\"${escaped_text}\",\"channel\":\"${escaped_channel}\"}"
  else
    payload="{\"text\":\"${escaped_text}\"}"
  fi

  if ! curl -fsS -X POST -H 'Content-Type: application/json' --data "${payload}" "${SLACK_WEBHOOK_URL}" >/dev/null; then
    log "WARN" "Slack/webhook notification failed."
  fi
}
