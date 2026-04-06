#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

WORKSPACE=""

cleanup() {
  if [[ -n "${WORKSPACE}" && -d "${WORKSPACE}" ]]; then
    rm -rf "${WORKSPACE}"
  fi
}

on_exit() {
  local status="$1"
  cleanup
  if [[ "${status}" -ne 0 ]]; then
    notify_slack "FAIL" "backup" "Backup failed"
  fi
}

collect_command() {
  local output_file="$1"
  shift
  if ! "$@" >"${output_file}" 2>&1; then
    log "WARN" "Command failed: $*"
    return 1
  fi
}

collect_docker_metadata() {
  local meta_dir="$1"

  ensure_dir "${meta_dir}/stack-services"
  ensure_dir "${meta_dir}/service-inspect"
  ensure_dir "${meta_dir}/network-inspect"
  ensure_dir "${meta_dir}/config-inspect"
  ensure_dir "${meta_dir}/secret-inspect"
  ensure_dir "${meta_dir}/volume-inspect"

  collect_command "${meta_dir}/docker-info.txt" docker info || true
  collect_command "${meta_dir}/docker-version.txt" docker version || true
  collect_command "${meta_dir}/docker-ps-a.txt" docker ps -a || true
  collect_command "${meta_dir}/docker-stack-ls.txt" docker stack ls || true
  collect_command "${meta_dir}/docker-service-ls.txt" docker service ls || true
  collect_command "${meta_dir}/docker-network-ls.txt" docker network ls || true
  collect_command "${meta_dir}/docker-secret-ls.txt" docker secret ls || true
  collect_command "${meta_dir}/docker-config-ls.txt" docker config ls || true
  collect_command "${meta_dir}/docker-volume-ls.txt" docker volume ls || true

  local stack
  while IFS= read -r stack; do
    [[ -z "${stack}" ]] && continue
    collect_command "${meta_dir}/stack-services/$(sanitize_filename "${stack}").txt" docker stack services "${stack}" || true
  done < <(docker stack ls --format '{{.Name}}' 2>/dev/null || true)

  local service
  while IFS= read -r service; do
    [[ -z "${service}" ]] && continue
    collect_command "${meta_dir}/service-inspect/$(sanitize_filename "${service}").json" docker service inspect "${service}" || true
  done < <(docker service ls --format '{{.Name}}' 2>/dev/null || true)

  local network
  while IFS= read -r network; do
    [[ -z "${network}" ]] && continue
    collect_command "${meta_dir}/network-inspect/$(sanitize_filename "${network}").json" docker network inspect "${network}" || true
  done < <(docker network ls --format '{{.Name}}' 2>/dev/null || true)

  local cfg
  while IFS= read -r cfg; do
    [[ -z "${cfg}" ]] && continue
    collect_command "${meta_dir}/config-inspect/$(sanitize_filename "${cfg}").json" docker config inspect "${cfg}" || true
  done < <(docker config ls --format '{{.Name}}' 2>/dev/null || true)

  local secret
  while IFS= read -r secret; do
    [[ -z "${secret}" ]] && continue
    collect_command "${meta_dir}/secret-inspect/$(sanitize_filename "${secret}").json" docker secret inspect "${secret}" || true
  done < <(docker secret ls --format '{{.Name}}' 2>/dev/null || true)

  local volume
  while IFS= read -r volume; do
    [[ -z "${volume}" ]] && continue
    collect_command "${meta_dir}/volume-inspect/$(sanitize_filename "${volume}").json" docker volume inspect "${volume}" || true
  done < <(docker volume ls --format '{{.Name}}' 2>/dev/null || true)
}

collect_volume_mount_paths() {
  local meta_dir="$1"
  local paths_file="$2"
  local read_only_check="${VOLUME_READONLY_CHECK:-true}"

  case "${BACKUP_DOCKER_VOLUMES:-true}" in
    0|false|FALSE|no|NO)
      log "INFO" "BACKUP_DOCKER_VOLUMES is disabled; skipping Docker volume backup."
      : > "${paths_file}"
      return 0
      ;;
  esac

  local -a volumes=()
  mapfile -t volumes < <(docker volume ls --format '{{.Name}}' 2>/dev/null || true)

  : > "${paths_file}"
  local metadata_file="${meta_dir}/volume-mountpoints.tsv"
  : > "${metadata_file}"

  if [[ "${#volumes[@]}" -eq 0 ]]; then
    log "INFO" "No Docker volumes found; skipping volume backup step."
    return 0
  fi

  local volume
  local included_count=0
  local skipped_count=0
  local failed_count=0

  for volume in "${volumes[@]}"; do
    [[ -z "${volume}" ]] && continue

    if [[ -n "${VOLUME_EXCLUDE_REGEX:-}" ]]; then
      if printf '%s' "${volume}" | grep -Eq "${VOLUME_EXCLUDE_REGEX}"; then
        log "INFO" "Skipping volume by VOLUME_EXCLUDE_REGEX: ${volume}"
        skipped_count=$((skipped_count + 1))
        continue
      fi
    fi

    local mountpoint
    mountpoint="$(docker volume inspect "${volume}" 2>/dev/null | jq -r '.[0].Mountpoint // empty' || true)"

    if [[ -z "${mountpoint}" ]]; then
      log "WARN" "Volume has no mountpoint (skipped): ${volume}"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    if [[ ! -d "${mountpoint}" ]]; then
      log "WARN" "Volume mountpoint does not exist on host (skipped): ${volume} -> ${mountpoint}"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    case "${read_only_check}" in
      1|true|TRUE|yes|YES)
        if ! docker run --rm -v "${volume}:/volume:ro" busybox sh -c 'ls -la /volume >/dev/null'; then
          log "WARN" "Read-only check failed for volume: ${volume}"
          failed_count=$((failed_count + 1))
          continue
        fi
        ;;
    esac

    printf '%s\t%s\n' "${volume}" "${mountpoint}" >> "${metadata_file}"
    printf '%s\n' "${mountpoint}" >> "${paths_file}"
    included_count=$((included_count + 1))
  done

  log "INFO" "Docker volume path summary: included=${included_count}, skipped=${skipped_count}, failed=${failed_count}"

  if [[ "${failed_count}" -gt 0 ]]; then
    fail "One or more Docker volumes failed read-only validation."
  fi
}

copy_stack_and_config_files() {
  local stacks_dir="$1"
  local configs_dir="$2"

  local -a configured_paths=()
  local -a default_paths=(
    "/opt/stacks"
    "/srv/stacks"
    "/etc/docker/stacks"
    "/opt/portainer/stacks"
    "/srv/portainer/stacks"
  )
  local -a effective_paths=()

  if [[ -n "${STACK_CONFIG_PATHS:-}" ]]; then
    IFS=':' read -r -a configured_paths <<< "${STACK_CONFIG_PATHS}"
  else
    configured_paths=("${default_paths[@]}")
    log "INFO" "STACK_CONFIG_PATHS is empty; trying Debian-friendly defaults."
  fi

  local src
  for src in "${configured_paths[@]}"; do
    src="${src%/}"
    [[ -z "${src}" ]] && continue
    if [[ -d "${src}" ]]; then
      effective_paths+=("${src}")
    fi
  done

  if [[ "${#effective_paths[@]}" -eq 0 && -n "${STACK_CONFIG_PATHS:-}" ]]; then
    log "WARN" "No configured STACK_CONFIG_PATHS exist; trying Debian-friendly defaults."
    for src in "${default_paths[@]}"; do
      if [[ -d "${src}" ]]; then
        effective_paths+=("${src}")
      fi
    done
  fi

  if [[ "${#effective_paths[@]}" -eq 0 ]]; then
    log "INFO" "No stack/config source directories found; skipping filesystem export."
    return 0
  fi

  for src in "${effective_paths[@]}"; do
    local source_key
    source_key="$(sanitize_filename "${src#/}")"

    log "INFO" "Scanning stack/config files in: ${src}"

    while IFS= read -r -d '' file; do
      local rel
      rel="${file#"${src}"/}"
      local base
      base="$(basename "${file}")"

      local destination_root
      case "${base}" in
        docker-compose*.yml|docker-compose*.yaml|compose*.yml|compose*.yaml)
          destination_root="${stacks_dir}"
          ;;
        *)
          destination_root="${configs_dir}"
          ;;
      esac

      local destination
      destination="${destination_root}/${source_key}/${rel}"
      ensure_dir "$(dirname "${destination}")"
      cp -a "${file}" "${destination}"
    done < <(
      find "${src}" -type f \(
        -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o
        -name 'compose*.yml' -o -name 'compose*.yaml' -o
        -name '.env' -o -name '.env.*' -o
        -name '*.conf' -o -name '*.cfg' -o
        -name '*.yaml' -o -name '*.yml'
      \) -print0
    )
  done
}

export_portainer_stacks() {
  local portainer_dir="$1"

  local portainer_base_url="${PORTAINER_URL:-}"
  portainer_base_url="${portainer_base_url%/}"

  if [[ -z "${portainer_base_url}" || -z "${PORTAINER_USERNAME:-}" || -z "${PORTAINER_PASSWORD:-}" ]]; then
    log "INFO" "Portainer API credentials not fully configured; skipping Portainer export."
    return 0
  fi

  # Skip obvious placeholder URLs to avoid unnecessary waits during backup.
  if [[ "${portainer_base_url}" == *"example.com"* || "${portainer_base_url}" == *"example.invalid"* ]]; then
    log "INFO" "PORTAINER_URL appears to be a placeholder; skipping Portainer export."
    return 0
  fi

  local curl_connect_timeout="${PORTAINER_CONNECT_TIMEOUT:-5}"
  local curl_max_time="${PORTAINER_MAX_TIME:-20}"
  local -a curl_opts=(
    -fsS
    --connect-timeout "${curl_connect_timeout}"
    --max-time "${curl_max_time}"
  )

  case "${PORTAINER_INSECURE_SKIP_VERIFY:-false}" in
    1|true|TRUE|yes|YES)
      curl_opts+=( -k )
      log "WARN" "PORTAINER_INSECURE_SKIP_VERIFY is enabled; TLS certificate verification is disabled."
      ;;
  esac

  local auth_response
  if ! auth_response="$(curl "${curl_opts[@]}" -X POST -H 'Content-Type: application/json' \
      -d "{\"Username\":\"${PORTAINER_USERNAME}\",\"Password\":\"${PORTAINER_PASSWORD}\"}" \
      "${portainer_base_url}/api/auth")"; then
    log "WARN" "Portainer authentication failed; skipping Portainer export."
    return 0
  fi

  local jwt
  jwt="$(printf '%s' "${auth_response}" | jq -r '.jwt // empty')"
  if [[ -z "${jwt}" ]]; then
    log "WARN" "Portainer authentication token not found; skipping Portainer export."
    return 0
  fi

  local list_url
  list_url="${portainer_base_url}/api/stacks"
  if [[ -n "${PORTAINER_ENDPOINT_ID:-}" ]]; then
    list_url+="?endpointId=${PORTAINER_ENDPOINT_ID}"
  fi

  local stacks_json
  if ! stacks_json="$(curl "${curl_opts[@]}" -H "Authorization: Bearer ${jwt}" "${list_url}")"; then
    log "WARN" "Unable to list Portainer stacks; skipping Portainer export."
    return 0
  fi

  printf '%s\n' "${stacks_json}" > "${portainer_dir}/stacks-list.json"

  local stack_encoded
  while IFS= read -r stack_encoded; do
    local stack_json
    local stack_id
    local stack_name
    local safe_name
    local stack_file_response
    local stack_content

    stack_json="$(printf '%s' "${stack_encoded}" | base64 -d)"
    stack_id="$(printf '%s' "${stack_json}" | jq -r '.Id // empty')"
    stack_name="$(printf '%s' "${stack_json}" | jq -r '.Name // .name // "stack"')"
    safe_name="$(sanitize_filename "${stack_name}")"

    printf '%s\n' "${stack_json}" > "${portainer_dir}/${safe_name}.metadata.json"

    if [[ -z "${stack_id}" ]]; then
      log "WARN" "Skipping Portainer stack with missing id: ${stack_name}"
      continue
    fi

    if ! stack_file_response="$(curl "${curl_opts[@]}" -H "Authorization: Bearer ${jwt}" "${portainer_base_url}/api/stacks/${stack_id}/file")"; then
      log "WARN" "Failed to export Portainer stack file for ${stack_name}"
      continue
    fi

    stack_content="$(printf '%s' "${stack_file_response}" | jq -r '.StackFileContent // .stackFileContent // empty' 2>/dev/null || true)"
    if [[ -n "${stack_content}" ]]; then
      printf '%s\n' "${stack_content}" > "${portainer_dir}/${safe_name}.yml"
    else
      printf '%s\n' "${stack_file_response}" > "${portainer_dir}/${safe_name}.file.json"
    fi
  done < <(printf '%s' "${stacks_json}" | jq -r '.[] | @base64' 2>/dev/null || true)

  if [[ -n "${PORTAINER_ENDPOINT_ID:-}" ]]; then
    printf '{"endpoint_id":"%s"}\n' "${PORTAINER_ENDPOINT_ID}" > "${portainer_dir}/endpoint-context.json"
  fi
}

ensure_restic_repository() {
  if run_restic cat config >/dev/null 2>&1; then
    log "INFO" "Restic repository already initialized."
  else
    log "INFO" "Initializing restic repository."
    run_restic init
  fi
}

main() {
  require_root
  require_command docker restic curl jq find cp hostname
  load_env_file
  configure_restic_transport
  require_env RESTIC_REPOSITORY RESTIC_PASSWORD BACKUP_ROOT RESTIC_FORGET_ARGS

  local backup_root
  backup_root="${BACKUP_ROOT%/}"

  local ts
  ts="$(date '+%Y%m%d-%H%M%S')"
  WORKSPACE="${backup_root}/current/${ts}"

  local meta_dir="${WORKSPACE}/meta"
  local stacks_dir="${WORKSPACE}/stacks"
  local portainer_dir="${WORKSPACE}/portainer"
  local configs_dir="${WORKSPACE}/configs"
  local volume_paths_file="${meta_dir}/volume-mountpaths.list"

  ensure_dir "${meta_dir}"
  ensure_dir "${stacks_dir}"
  ensure_dir "${portainer_dir}"
  ensure_dir "${configs_dir}"

  local default_host
  default_host="$(hostname -f 2>/dev/null || hostname)"
  local backup_host
  backup_host="${RESTIC_HOST:-${default_host}}"

  trap 'on_exit "$?"' EXIT

  log "INFO" "Collecting Docker and Swarm metadata."
  collect_docker_metadata "${meta_dir}"

  log "INFO" "Collecting stack and configuration files from filesystem paths."
  copy_stack_and_config_files "${stacks_dir}" "${configs_dir}"

  log "INFO" "Collecting Portainer stack exports when API settings are available."
  export_portainer_stacks "${portainer_dir}"

  log "INFO" "Collecting Docker volume mount paths for direct restic backup."
  collect_volume_mount_paths "${meta_dir}" "${volume_paths_file}"

  log "INFO" "Ensuring restic repository is initialized."
  ensure_restic_repository

  local excludes_file
  excludes_file="${REPO_ROOT}/restic-excludes.txt"
  if [[ ! -f "${excludes_file}" ]]; then
    fail "Exclude file not found: ${excludes_file}"
  fi

  log "INFO" "Running restic backup upload."
  local -a backup_paths=("${meta_dir}" "${stacks_dir}" "${portainer_dir}" "${configs_dir}")
  local -a volume_paths=()
  if [[ -s "${volume_paths_file}" ]]; then
    mapfile -t volume_paths < "${volume_paths_file}"
    backup_paths+=("${volume_paths[@]}")
    log "INFO" "Adding ${#volume_paths[@]} Docker volume mount paths to restic backup."
  fi

  run_restic backup \
    --exclude-file "${excludes_file}" \
    --host "${backup_host}" \
    --tag docker \
    --tag swarm \
    --tag stacks \
    --tag volumes \
    --tag nightly \
    "${backup_paths[@]}"

  log "INFO" "Applying retention policy with restic forget."
  local forget_args
  # shellcheck disable=SC2206
  forget_args=( ${RESTIC_FORGET_ARGS} )

  local has_prune="false"
  local arg
  for arg in "${forget_args[@]}"; do
    if [[ "${arg}" == "--prune" ]]; then
      has_prune="true"
      break
    fi
  done
  if [[ "${has_prune}" != "true" ]]; then
    forget_args+=(--prune)
  fi

  run_restic forget "${forget_args[@]}"

  log "INFO" "Backup completed successfully."
  notify_slack "OK" "backup" "Backup completed successfully"
}

main "$@"
