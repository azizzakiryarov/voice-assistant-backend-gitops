#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2026-06-16"
SCRIPT_NAME="$(basename "$0")"
LOG_READY=false

plain_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

log() {
  local level=$1
  local event=$2
  local message=$3
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [[ "${LOG_READY}" == "true" ]]; then
    printf '{"timestamp":"%s","level":"%s","event":"%s","message":"%s"}\n' \
      "$timestamp" "$level" "$event" "$(json_escape "$message")" | tee -a "$LOG_FILE" >&2
  else
    printf '{"timestamp":"%s","level":"%s","event":"%s","message":"%s"}\n' \
      "$timestamp" "$level" "$event" "$(json_escape "$message")" >&2
  fi
}

die() {
  log "error" "fatal" "$*"
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    plain_error "Run ${SCRIPT_NAME} as root so it can read Restic credentials and restore files with original ownership."
    exit 1
  fi
}

assert_private_file() {
  local file=$1
  local description=$2
  local mode
  local owner

  [[ -f "$file" ]] || die "$description does not exist: $file"

  mode=$(stat -c '%a' "$file")
  owner=$(stat -c '%u' "$file")
  if [[ "$owner" != "0" ]]; then
    die "$description must be owned by root: $file"
  fi
  if (( (8#$mode & 077) != 0 )); then
    die "$description must be root-only, expected mode 600 or stricter: $file has mode $mode"
  fi
}

load_config() {
  CONFIG_DIR="${CONFIG_DIR:-/etc/raspberry-backup}"
  ENV_FILE="${ENV_FILE:-$CONFIG_DIR/backup.env}"

  if [[ -f "$ENV_FILE" ]]; then
    assert_private_file "$ENV_FILE" "Backup environment file"
    # shellcheck source=/etc/raspberry-backup/backup.env
    source "$ENV_FILE"
  fi

  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
  RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$CONFIG_DIR/restic-password}"
  RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/raspberry-backup/restic}"
  RESTORE_ROOT="${RESTORE_ROOT:-/var/lib/raspberry-backup/restore}"
  LOG_DIR="${LOG_DIR:-/var/log/raspberry-backup}"
  LOCK_FILE="${LOCK_FILE:-/run/raspberry-backup.lock}"
  SSH_KEY_FILE="${SSH_KEY_FILE:-$CONFIG_DIR/ssh/raspberry-backup-ed25519}"
  SSH_KNOWN_HOSTS_FILE="${SSH_KNOWN_HOSTS_FILE:-$CONFIG_DIR/ssh/known_hosts}"
  SSH_PORT="${SSH_PORT:-22}"
  RESTIC_SFTP_COMMAND="${RESTIC_SFTP_COMMAND:-}"
  ALLOW_ANY_RESTORE_TARGET="${ALLOW_ANY_RESTORE_TARGET:-false}"

  KUBECTL_BIN="${KUBECTL_BIN:-}"
  KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"
  POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-voice-assistant}"
  POSTGRES_SELECTOR="${POSTGRES_SELECTOR:-app=postgres}"
  POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres}"
  POSTGRES_SECRET_NAME="${POSTGRES_SECRET_NAME:-postgres-secret}"
  POSTGRES_USER_KEY="${POSTGRES_USER_KEY:-postgres-user}"
  POSTGRES_PASSWORD_KEY="${POSTGRES_PASSWORD_KEY:-postgres-password}"
  POSTGRES_USER="${POSTGRES_USER:-}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
}

setup_logging() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  LOG_FILE="$LOG_DIR/restore-$(date -u +%F).jsonl"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  LOG_READY=true
}

finish() {
  local rc=$?
  if [[ "${LOG_READY}" == "true" ]]; then
    if (( rc == 0 )); then
      log "info" "exit" "${SCRIPT_NAME} completed successfully"
    else
      log "error" "exit" "${SCRIPT_NAME} failed with exit code ${rc}"
    fi
  fi
  exit "$rc"
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    die "Another backup, restore, or check process is already running: $LOCK_FILE"
  fi
}

require_commands() {
  local missing=()
  local command
  for command in restic jq base64 flock stat date find sort tail; do
    if ! command -v "$command" >/dev/null 2>&1; then
      missing+=("$command")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    die "Missing required command(s): ${missing[*]}"
  fi
}

kubectl_cmd() {
  local cmd=()

  if [[ -n "$KUBECTL_BIN" ]]; then
    cmd=("$KUBECTL_BIN")
    if [[ "${KUBECTL_BIN##*/}" == "microk8s" ]]; then
      cmd+=("kubectl")
    fi
  elif command -v microk8s >/dev/null 2>&1; then
    cmd=("microk8s" "kubectl")
  else
    cmd=("kubectl")
  fi

  if [[ "${cmd[0]##*/}" != "microk8s" ]] && [[ -n "$KUBECTL_CONTEXT" ]]; then
    cmd+=("--context" "$KUBECTL_CONTEXT")
  fi

  "${cmd[@]}" "$@"
}

kubernetes_secret_value() {
  local namespace=$1
  local secret=$2
  local key=$3
  local value

  value=$(
    kubectl_cmd -n "$namespace" get secret "$secret" -o json \
      | jq -r --arg key "$key" '.data[$key] // empty' \
      | base64 -d
  ) || return 1

  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

load_postgres_credentials() {
  if [[ -z "$POSTGRES_USER" ]]; then
    POSTGRES_USER=$(kubernetes_secret_value "$POSTGRES_NAMESPACE" "$POSTGRES_SECRET_NAME" "$POSTGRES_USER_KEY") \
      || die "Could not read PostgreSQL user from secret ${POSTGRES_NAMESPACE}/${POSTGRES_SECRET_NAME}"
  fi
  if [[ -z "$POSTGRES_PASSWORD" ]]; then
    POSTGRES_PASSWORD=$(kubernetes_secret_value "$POSTGRES_NAMESPACE" "$POSTGRES_SECRET_NAME" "$POSTGRES_PASSWORD_KEY") \
      || die "Could not read PostgreSQL password from secret ${POSTGRES_NAMESPACE}/${POSTGRES_SECRET_NAME}"
  fi
}

postgres_pod_name() {
  kubectl_cmd -n "$POSTGRES_NAMESPACE" get pods -l "$POSTGRES_SELECTOR" -o json \
    | jq -r '[.items[] | select(.status.phase == "Running") | .metadata.name][0] // empty'
}

safe_filename() {
  local value=$1
  printf '%s' "$value" | tr -c 'A-Za-z0-9_.-' '_'
}

extract_sftp_userhost() {
  local repo=$1
  local without_scheme
  local userhost

  [[ "$repo" == sftp:* ]] || return 1
  without_scheme=${repo#sftp:}
  userhost=${without_scheme%%:*}
  [[ -n "$userhost" ]] || return 1
  [[ "$userhost" != /* ]] || return 1
  printf '%s' "$userhost"
}

build_restic_options() {
  RESTIC_OPTIONS=()

  if [[ -n "$RESTIC_SFTP_COMMAND" ]]; then
    RESTIC_OPTIONS+=("-o" "sftp.command=$RESTIC_SFTP_COMMAND")
    return
  fi

  if [[ "$RESTIC_REPOSITORY" == sftp:* ]] && [[ -f "$SSH_KEY_FILE" ]]; then
    local userhost
    userhost=$(extract_sftp_userhost "$RESTIC_REPOSITORY") \
      || die "RESTIC_REPOSITORY is SFTP but no user@host could be parsed; set RESTIC_SFTP_COMMAND explicitly"
    RESTIC_OPTIONS+=(
      "-o"
      "sftp.command=ssh -i $SSH_KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$SSH_KNOWN_HOSTS_FILE -p $SSH_PORT $userhost -s sftp"
    )
  fi
}

restic_cmd() {
  restic "${RESTIC_OPTIONS[@]}" "$@"
}

validate_config() {
  [[ -n "$RESTIC_REPOSITORY" ]] || die "RESTIC_REPOSITORY is not set in $ENV_FILE"
  assert_private_file "$RESTIC_PASSWORD_FILE" "Restic password file"
  if [[ "$RESTIC_REPOSITORY" == sftp:* ]]; then
    assert_private_file "$SSH_KEY_FILE" "SSH private key"
    [[ -f "$SSH_KNOWN_HOSTS_FILE" ]] || die "SSH known_hosts file does not exist: $SSH_KNOWN_HOSTS_FILE"
  fi

  mkdir -p "$RESTIC_CACHE_DIR" "$RESTORE_ROOT"
  chmod 700 "$RESTIC_CACHE_DIR" "$RESTORE_ROOT"
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR
  build_restic_options
}

ensure_safe_restore_target() {
  local target=$1
  local first_entry

  if [[ "$ALLOW_ANY_RESTORE_TARGET" != "true" ]]; then
    case "$target" in
      "$RESTORE_ROOT"/*) ;;
      *)
        die "Restore target must be under $RESTORE_ROOT unless ALLOW_ANY_RESTORE_TARGET=true"
        ;;
    esac
  fi

  if [[ -e "$target" && ! -d "$target" ]]; then
    die "Restore target exists and is not a directory: $target"
  fi

  mkdir -p "$target"
  chmod 700 "$target"
  first_entry=$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)
  if [[ -n "$first_entry" ]]; then
    die "Restore target is not empty: $target"
  fi
}

latest_run_dir() {
  local target=$1
  local staging_root="$target/var/lib/raspberry-backup/staging"
  [[ -d "$staging_root" ]] || die "No restored backup staging directory found under $staging_root"
  find "$staging_root" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
}

list_snapshots() {
  restic_cmd snapshots
}

restore_snapshot() {
  local snapshot=${1:-latest}
  local target=${2:-}

  if [[ -z "$target" ]]; then
    target="$RESTORE_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
  fi

  ensure_safe_restore_target "$target"
  log "info" "restic_restore_start" "Restoring snapshot ${snapshot} into ${target}"
  restic_cmd restore "$snapshot" --target "$target"
  log "info" "restic_restore_complete" "Restored snapshot ${snapshot} into ${target}"
}

apply_kubernetes_manifests() {
  local target=""
  local execute=false
  local mode_args=("--dry-run=server")
  local run_dir
  local manifest_root
  local file
  local root
  local crd_file
  local files=()

  while (( $# > 0 )); do
    case "$1" in
      --target)
        target=${2:-}
        shift 2
        ;;
      --execute)
        execute=true
        shift
        ;;
      *)
        die "Unknown apply-k8s argument: $1"
        ;;
    esac
  done

  [[ -n "$target" ]] || die "apply-k8s requires --target <restored-directory>"
  run_dir=$(latest_run_dir "$target")
  manifest_root="$run_dir/kubernetes"
  [[ -d "$manifest_root" ]] || die "No Kubernetes manifests found under $manifest_root"

  if [[ "$execute" == "true" ]]; then
    mode_args=()
    log "warn" "kubernetes_apply_execute" "Applying Kubernetes manifests to the current cluster"
  else
    log "info" "kubernetes_apply_dry_run" "Dry-running Kubernetes manifests against the current cluster"
  fi

  crd_file="$manifest_root/cluster/customresourcedefinitions.json"
  if [[ -f "$crd_file" ]]; then
    files+=("$crd_file")
  fi

  for root in "$manifest_root/namespaces" "$manifest_root/cluster" "$manifest_root/namespaced"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r file; do
      [[ "$file" == "$crd_file" ]] && continue
      files+=("$file")
    done < <(find "$root" -type f -name '*.json' | sort)
  done

  if (( ${#files[@]} == 0 )); then
    die "No Kubernetes manifest files found under $manifest_root"
  fi

  for file in "${files[@]}"; do
    if jq -e '.kind == "List" and ((.items // []) | length == 0)' "$file" >/dev/null; then
      log "info" "kubernetes_apply_skip_empty" "Skipping empty Kubernetes resource list: $file"
      continue
    fi
    log "info" "kubernetes_apply_file" "kubectl apply ${mode_args[*]} -f $file"
    kubectl_cmd apply "${mode_args[@]}" -f "$file"
  done
}

restore_postgres_to_new_database() {
  local target=""
  local database=""
  local dump_file=""
  local target_database=""
  local execute=false
  local run_dir
  local pod
  local exists

  while (( $# > 0 )); do
    case "$1" in
      --target)
        target=${2:-}
        shift 2
        ;;
      --database)
        database=${2:-}
        shift 2
        ;;
      --dump)
        dump_file=${2:-}
        shift 2
        ;;
      --target-database)
        target_database=${2:-}
        shift 2
        ;;
      --execute)
        execute=true
        shift
        ;;
      *)
        die "Unknown restore-postgres argument: $1"
        ;;
    esac
  done

  [[ -n "$target_database" ]] || die "restore-postgres requires --target-database <new-db-name>"
  if [[ -z "$dump_file" ]]; then
    [[ -n "$target" ]] || die "restore-postgres requires --target <restored-directory> when --dump is not provided"
    [[ -n "$database" ]] || die "restore-postgres requires --database <source-db-name> when --dump is not provided"
    run_dir=$(latest_run_dir "$target")
    dump_file="$run_dir/postgres/$(safe_filename "$database").dump"
  fi

  [[ -f "$dump_file" ]] || die "PostgreSQL dump file does not exist: $dump_file"

  if [[ "$execute" != "true" ]]; then
    log "info" "postgres_restore_plan" "Would restore $dump_file into new PostgreSQL database $target_database. Re-run with --execute to perform it."
    return
  fi

  load_postgres_credentials
  pod=$(postgres_pod_name)
  [[ -n "$pod" ]] || die "No running PostgreSQL pod found in ${POSTGRES_NAMESPACE} matching selector ${POSTGRES_SELECTOR}"

  exists=$(
    kubectl_cmd -n "$POSTGRES_NAMESPACE" exec "$pod" -c "$POSTGRES_CONTAINER" -- \
      env "PGPASSWORD=$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d postgres \
        -v "db=$target_database" -Atc "select 1 from pg_database where datname = :'db';"
  ) || die "Failed to check whether target database exists"

  if [[ "$exists" == "1" ]]; then
    die "Target database already exists; refusing to overwrite: $target_database"
  fi

  log "info" "postgres_create_database" "Creating PostgreSQL database $target_database"
  kubectl_cmd -n "$POSTGRES_NAMESPACE" exec "$pod" -c "$POSTGRES_CONTAINER" -- \
    env "PGPASSWORD=$POSTGRES_PASSWORD" createdb -U "$POSTGRES_USER" "$target_database"

  log "info" "postgres_restore_start" "Restoring $dump_file into database $target_database"
  kubectl_cmd -n "$POSTGRES_NAMESPACE" exec -i "$pod" -c "$POSTGRES_CONTAINER" -- \
    env "PGPASSWORD=$POSTGRES_PASSWORD" pg_restore -U "$POSTGRES_USER" -d "$target_database" \
      --no-owner --no-acl < "$dump_file"
}

usage() {
  local restore_root=${RESTORE_ROOT:-/var/lib/raspberry-backup/restore}
  cat <<USAGE
Usage: $SCRIPT_NAME <command> [options]

Commands:
  list
      List Restic snapshots.

  restore [snapshot] [target-directory]
      Restore a Restic snapshot into an empty directory. Defaults to latest and
      $restore_root/<timestamp>. This does not overwrite production data.

  apply-k8s --target <restored-directory> [--execute]
      Dry-run Kubernetes manifests from a restored backup. Add --execute to apply
      them to the current cluster.

  restore-postgres --target <restored-directory> --database <source-db> --target-database <new-db> [--execute]
      Plan or execute a PostgreSQL restore into a new database. Existing databases
      are never overwritten.
USAGE
}

main() {
  local command=${1:-help}
  shift || true

  case "$command" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  require_root
  load_config
  setup_logging
  trap finish EXIT
  acquire_lock
  require_commands
  validate_config

  log "info" "start" "Starting ${SCRIPT_NAME} command=${command}"

  case "$command" in
    list|snapshots)
      list_snapshots
      ;;
    restore)
      restore_snapshot "${1:-latest}" "${2:-}"
      ;;
    apply-k8s)
      apply_kubernetes_manifests "$@"
      ;;
    restore-postgres)
      restore_postgres_to_new_database "$@"
      ;;
    *)
      usage >&2
      die "Unknown command: $command"
      ;;
  esac
}

main "$@"
