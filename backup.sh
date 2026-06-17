#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2026-06-16"
SCRIPT_NAME="$(basename "$0")"
LOG_READY=false
RUN_DIR=""

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
    plain_error "Run ${SCRIPT_NAME} as root so it can read credentials, /etc, and MicroK8s data."
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
  WORK_ROOT="${WORK_ROOT:-/var/lib/raspberry-backup/staging}"
  LOG_DIR="${LOG_DIR:-/var/log/raspberry-backup}"
  LOCK_FILE="${LOCK_FILE:-/run/raspberry-backup.lock}"
  EXCLUDES_FILE="${EXCLUDES_FILE:-$CONFIG_DIR/restic-excludes.txt}"
  SSH_KEY_FILE="${SSH_KEY_FILE:-$CONFIG_DIR/ssh/raspberry-backup-ed25519}"
  SSH_KNOWN_HOSTS_FILE="${SSH_KNOWN_HOSTS_FILE:-$CONFIG_DIR/ssh/known_hosts}"
  SSH_PORT="${SSH_PORT:-22}"
  RESTIC_SFTP_COMMAND="${RESTIC_SFTP_COMMAND:-}"
  RESTIC_INIT_IF_MISSING="${RESTIC_INIT_IF_MISSING:-false}"
  RESTIC_CHECK_OPTIONS="${RESTIC_CHECK_OPTIONS:-}"

  RETENTION_KEEP_DAILY="${RETENTION_KEEP_DAILY:-7}"
  RETENTION_KEEP_WEEKLY="${RETENTION_KEEP_WEEKLY:-5}"
  RETENTION_KEEP_MONTHLY="${RETENTION_KEEP_MONTHLY:-12}"

  KUBECTL_BIN="${KUBECTL_BIN:-}"
  KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"
  K8S_NAMESPACES="${K8S_NAMESPACES:-voice-assistant voice-assistant-ci argocd cert-manager ingress metallb-system tekton-pipelines tekton-pipelines-resolvers}"
  K8S_NAMESPACE_RESOURCES="${K8S_NAMESPACE_RESOURCES:-deployments statefulsets daemonsets services ingresses configmaps persistentvolumeclaims serviceaccounts roles rolebindings networkpolicies cronjobs jobs tasks.tekton.dev pipelines.tekton.dev pipelineruns.tekton.dev taskruns.tekton.dev eventlisteners.triggers.tekton.dev triggerbindings.triggers.tekton.dev triggertemplates.triggers.tekton.dev interceptors.triggers.tekton.dev issuers.cert-manager.io certificates.cert-manager.io certificaterequests.cert-manager.io orders.acme.cert-manager.io challenges.acme.cert-manager.io secrets}"
  K8S_CLUSTER_RESOURCES="${K8S_CLUSTER_RESOURCES:-customresourcedefinitions storageclasses persistentvolumes ingressclasses.networking.k8s.io clusterroles clusterrolebindings clusterissuers.cert-manager.io clusterinterceptors.triggers.tekton.dev}"
  ARGOCD_RESOURCES="${ARGOCD_RESOURCES:-applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io}"
  EXPORT_K8S_SECRETS="${EXPORT_K8S_SECRETS:-true}"

  POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-voice-assistant}"
  POSTGRES_SELECTOR="${POSTGRES_SELECTOR:-app=postgres}"
  POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres}"
  POSTGRES_SECRET_NAME="${POSTGRES_SECRET_NAME:-postgres-secret}"
  POSTGRES_USER_KEY="${POSTGRES_USER_KEY:-postgres-user}"
  POSTGRES_PASSWORD_KEY="${POSTGRES_PASSWORD_KEY:-postgres-password}"
  POSTGRES_DATABASES="${POSTGRES_DATABASES:-}"
  POSTGRES_USER="${POSTGRES_USER:-}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

  CONFIG_BACKUP_PATHS="${CONFIG_BACKUP_PATHS:-/etc /var/snap/microk8s/current/args /var/snap/microk8s/common/args}"
  APP_DATA_PATHS="${APP_DATA_PATHS:-/var/snap/microk8s/common/default-storage /home/azizzakiryarov/ollama-models /home/azizzakiryarov/openwebui-data}"
  HOME_BACKUP_PATHS="${HOME_BACKUP_PATHS:-}"
  EXTRA_BACKUP_PATHS="${EXTRA_BACKUP_PATHS:-}"
  RESTIC_TAGS="${RESTIC_TAGS:-raspberry-pi microk8s postgres voice-assistant}"
  CLEANUP_ON_SUCCESS="${CLEANUP_ON_SUCCESS:-true}"
}

setup_logging() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  LOG_FILE="$LOG_DIR/backup-$(date -u +%F).jsonl"
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

  if (( rc == 0 )) && [[ "${CLEANUP_ON_SUCCESS:-true}" == "true" ]] && [[ -n "$RUN_DIR" ]] && [[ -d "$RUN_DIR" ]]; then
    rm -rf "$RUN_DIR"
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
  for command in restic jq base64 flock stat date; do
    if ! command -v "$command" >/dev/null 2>&1; then
      missing+=("$command")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    die "Missing required command(s): ${missing[*]}"
  fi
}

split_list() {
  local value=$1
  local normalized
  normalized=${value//,/ }
  # shellcheck disable=SC2034
  SPLIT_LIST_RESULT=()
  read -r -a SPLIT_LIST_RESULT <<< "$normalized"
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

sanitize_kubernetes_json() {
  jq '
    def scrub:
      del(
        .metadata.uid,
        .metadata.resourceVersion,
        .metadata.generation,
        .metadata.creationTimestamp,
        .metadata.managedFields,
        .metadata.selfLink,
        .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
        .spec.claimRef.uid,
        .spec.claimRef.resourceVersion,
        .status
      )
      | if has("items") then .items |= map(scrub) else . end;
    scrub
  '
}

export_resource_json() {
  local output=$1
  shift
  local tmp
  tmp="${output}.tmp"

  if kubectl_cmd "$@" -o json > "$tmp"; then
    sanitize_kubernetes_json < "$tmp" > "$output"
    rm -f "$tmp"
    log "info" "kubernetes_export" "Exported kubectl $* to $output"
    return 0
  fi

  rm -f "$tmp"
  log "warn" "kubernetes_export_skipped" "Skipped kubectl $* because the resource is unavailable or has no API on this cluster"
  return 0
}

namespace_exists() {
  local namespace=$1
  kubectl_cmd get namespace "$namespace" >/dev/null 2>&1
}

export_kubernetes() {
  local output_dir="$RUN_DIR/kubernetes"
  local namespace
  local resource
  local resources=()
  local cluster_resources=()
  local argocd_resources=()

  mkdir -p "$output_dir/cluster" "$output_dir/namespaces" "$output_dir/namespaced"

  if ! kubectl_cmd get namespace default >/dev/null 2>&1; then
    die "Kubernetes API is not reachable; refusing to run a backup without current manifests"
  fi

  split_list "$K8S_NAMESPACE_RESOURCES"
  resources=("${SPLIT_LIST_RESULT[@]}")
  if [[ "$EXPORT_K8S_SECRETS" != "true" ]]; then
    local filtered=()
    for resource in "${resources[@]}"; do
      if [[ "$resource" != "secrets" ]]; then
        filtered+=("$resource")
      fi
    done
    resources=("${filtered[@]}")
  fi

  split_list "$K8S_CLUSTER_RESOURCES"
  cluster_resources=("${SPLIT_LIST_RESULT[@]}")
  split_list "$ARGOCD_RESOURCES"
  argocd_resources=("${SPLIT_LIST_RESULT[@]}")

  export_resource_json "$output_dir/cluster/namespaces.json" get namespaces
  for resource in "${cluster_resources[@]}"; do
    export_resource_json "$output_dir/cluster/${resource//\//_}.json" get "$resource"
  done

  split_list "$K8S_NAMESPACES"
  for namespace in "${SPLIT_LIST_RESULT[@]}"; do
    if ! namespace_exists "$namespace"; then
      log "warn" "namespace_missing" "Configured namespace does not exist on this cluster: $namespace"
      continue
    fi

    mkdir -p "$output_dir/namespaced/$namespace"
    export_resource_json "$output_dir/namespaces/${namespace}.json" get namespace "$namespace"

    for resource in "${resources[@]}"; do
      export_resource_json "$output_dir/namespaced/$namespace/${resource//\//_}.json" -n "$namespace" get "$resource"
    done
  done

  if namespace_exists "argocd"; then
    mkdir -p "$output_dir/namespaced/argocd"
    for resource in "${argocd_resources[@]}"; do
      export_resource_json "$output_dir/namespaced/argocd/${resource//\//_}.json" -n argocd get "$resource"
    done
  fi
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

postgres_pod_name() {
  kubectl_cmd -n "$POSTGRES_NAMESPACE" get pods -l "$POSTGRES_SELECTOR" -o json \
    | jq -r '[.items[] | select(.status.phase == "Running") | .metadata.name][0] // empty'
}

safe_filename() {
  local value=$1
  printf '%s' "$value" | tr -c 'A-Za-z0-9_.-' '_'
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

dump_postgres() {
  local output_dir="$RUN_DIR/postgres"
  local pod
  local databases_output
  local database
  local dump_file
  local tmp_file
  local database_filename
  local databases=()

  mkdir -p "$output_dir"
  chmod 700 "$output_dir"

  load_postgres_credentials
  pod=$(postgres_pod_name)
  [[ -n "$pod" ]] || die "No running PostgreSQL pod found in ${POSTGRES_NAMESPACE} matching selector ${POSTGRES_SELECTOR}"

  log "info" "postgres_dump_start" "Creating PostgreSQL dumps from pod ${POSTGRES_NAMESPACE}/${pod}"

  tmp_file="$output_dir/globals.sql.tmp"
  if kubectl_cmd -n "$POSTGRES_NAMESPACE" exec "$pod" -c "$POSTGRES_CONTAINER" -- \
    env "PGPASSWORD=$POSTGRES_PASSWORD" pg_dumpall -U "$POSTGRES_USER" --globals-only > "$tmp_file"; then
    mv "$tmp_file" "$output_dir/globals.sql"
  else
    rm -f "$tmp_file"
    die "Failed to dump PostgreSQL globals"
  fi

  if [[ -n "$POSTGRES_DATABASES" ]]; then
    split_list "$POSTGRES_DATABASES"
    databases=("${SPLIT_LIST_RESULT[@]}")
  else
    databases_output=$(
      kubectl_cmd -n "$POSTGRES_NAMESPACE" exec "$pod" -c "$POSTGRES_CONTAINER" -- \
        env "PGPASSWORD=$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d postgres -Atc \
        "select datname from pg_database where datallowconn and not datistemplate order by datname;"
    ) || die "Failed to list PostgreSQL databases"
    mapfile -t databases <<< "$databases_output"
  fi

  if (( ${#databases[@]} == 0 )); then
    die "No PostgreSQL databases were found to dump"
  fi

  for database in "${databases[@]}"; do
    [[ -n "$database" ]] || continue
    database_filename=$(safe_filename "$database")
    dump_file="$output_dir/${database_filename}.dump"
    tmp_file="${dump_file}.tmp"
    log "info" "postgres_dump_database" "Dumping PostgreSQL database ${database}"
    if kubectl_cmd -n "$POSTGRES_NAMESPACE" exec "$pod" -c "$POSTGRES_CONTAINER" -- \
      env "PGPASSWORD=$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$database" \
        --format=custom --blobs --no-owner --no-acl > "$tmp_file"; then
      mv "$tmp_file" "$dump_file"
      chmod 600 "$dump_file"
    else
      rm -f "$tmp_file"
      die "Failed to dump PostgreSQL database ${database}"
    fi
  done

  printf 'created_at=%s\npostgres_namespace=%s\npostgres_selector=%s\npostgres_pod=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$POSTGRES_NAMESPACE" "$POSTGRES_SELECTOR" "$pod" \
    > "$output_dir/metadata.env"
  chmod 600 "$output_dir/metadata.env"
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

  if [[ ! -f "$EXCLUDES_FILE" ]]; then
    local script_dir
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    if [[ -f "$script_dir/restic-excludes.txt" ]]; then
      EXCLUDES_FILE="$script_dir/restic-excludes.txt"
    else
      die "Restic excludes file does not exist: $EXCLUDES_FILE"
    fi
  fi

  mkdir -p "$RESTIC_CACHE_DIR" "$WORK_ROOT"
  chmod 700 "$RESTIC_CACHE_DIR" "$WORK_ROOT"
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR
  build_restic_options
}

ensure_restic_repository() {
  if restic_cmd snapshots >/dev/null 2>&1; then
    return
  fi

  if [[ "$RESTIC_INIT_IF_MISSING" == "true" ]]; then
    log "warn" "restic_init" "Restic repository was not reachable as an initialized repo; attempting restic init"
    restic_cmd init
    return
  fi

  die "Restic repository is not initialized or is not reachable. Run '${SCRIPT_NAME} init' after verifying the destination."
}

append_existing_paths() {
  local value=$1
  local path

  split_list "$value"
  for path in "${SPLIT_LIST_RESULT[@]}"; do
    [[ -n "$path" ]] || continue
    if [[ -e "$path" ]]; then
      BACKUP_SOURCES+=("$path")
    else
      log "warn" "backup_path_missing" "Configured backup path does not exist and will be skipped: $path"
    fi
  done
}

write_run_metadata() {
  local output="$RUN_DIR/backup-metadata.env"
  {
    printf 'created_at=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'script_version=%s\n' "$VERSION"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'restic_repository=%s\n' "$RESTIC_REPOSITORY"
    printf 'k8s_namespaces=%s\n' "$K8S_NAMESPACES"
  } > "$output"
  chmod 600 "$output"
}

run_restic_backup() {
  local restic_args=()
  local tag

  BACKUP_SOURCES=("$RUN_DIR")
  append_existing_paths "$CONFIG_BACKUP_PATHS"
  append_existing_paths "$APP_DATA_PATHS"
  append_existing_paths "$HOME_BACKUP_PATHS"
  append_existing_paths "$EXTRA_BACKUP_PATHS"

  split_list "$RESTIC_TAGS"
  for tag in "${SPLIT_LIST_RESULT[@]}"; do
    restic_args+=("--tag" "$tag")
  done

  log "info" "restic_backup_start" "Starting Restic backup with ${#BACKUP_SOURCES[@]} source path(s)"
  restic_cmd backup \
    --one-file-system \
    --exclude-file "$EXCLUDES_FILE" \
    "${restic_args[@]}" \
    "${BACKUP_SOURCES[@]}"

  log "info" "restic_forget_start" "Applying retention policy: ${RETENTION_KEEP_DAILY} daily, ${RETENTION_KEEP_WEEKLY} weekly, ${RETENTION_KEEP_MONTHLY} monthly"
  restic_cmd forget \
    --keep-daily "$RETENTION_KEEP_DAILY" \
    --keep-weekly "$RETENTION_KEEP_WEEKLY" \
    --keep-monthly "$RETENTION_KEEP_MONTHLY" \
    --prune
}

run_backup() {
  local run_id
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_DIR="$WORK_ROOT/$run_id"
  mkdir -p "$RUN_DIR"
  chmod 700 "$RUN_DIR"

  write_run_metadata
  dump_postgres
  export_kubernetes
  ensure_restic_repository
  run_restic_backup
}

run_check() {
  local check_options=()

  ensure_restic_repository
  split_list "$RESTIC_CHECK_OPTIONS"
  check_options=("${SPLIT_LIST_RESULT[@]}")
  log "info" "restic_check_start" "Starting Restic repository check"
  restic_cmd check "${check_options[@]}"
}

run_init() {
  log "info" "restic_init_start" "Initializing Restic repository"
  restic_cmd init
}

run_snapshots() {
  restic_cmd snapshots
}

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [backup|check|init|snapshots]

Commands:
  backup     Create PostgreSQL dumps, export Kubernetes resources, run Restic, then apply retention.
  check      Run restic check using the configured repository and credentials.
  init       Initialize the configured Restic repository.
  snapshots  List Restic snapshots.
USAGE
}

main() {
  local command=${1:-backup}

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
    backup)
      run_backup
      ;;
    check)
      run_check
      ;;
    init)
      run_init
      ;;
    snapshots)
      run_snapshots
      ;;
    *)
      usage >&2
      die "Unknown command: $command"
      ;;
  esac
}

main "$@"
