# shellcheck shell=bash
set -Eeuo pipefail
IFS=$'\n\t'

# ghrctl — GitHub Actions self-hosted runner host manager.
# Public beta: the state format and CLI may still evolve before 1.0.

GHRCTL_VERSION="0.2.0-beta.1"
GHRCTL_REPOSITORY="mufarri7/gha-runner-bootstrap"
STATE_SCHEMA_VERSION=2
BACKUP_SCHEMA_VERSION=1
TOOL_PROFILE_SCHEMA_VERSION=1

STATE_DIR="${GHRCTL_STATE_DIR:-/etc/ghrctl}"
PROJECTS_DIR="${STATE_DIR}/projects.d"
DATA_DIR="${GHRCTL_DATA_DIR:-/var/lib/ghrctl}"
PROFILES_DIR="${DATA_DIR}/tool-profiles"
OPERATIONS_DIR="${DATA_DIR}/operations"
BACKUP_WORK_DIR="${DATA_DIR}/backup-work"
LOG_DIR="${GHRCTL_LOG_DIR:-/var/log/ghrctl}"
LOG_FILE="${GHRCTL_LOG_FILE:-${LOG_DIR}/ghrctl.jsonl}"
LOCK_FILE="${GHRCTL_LOCK_FILE:-/var/lock/ghrctl.lock}"
BASE_ROOT="${GHRCTL_BASE_ROOT:-/srv/github-runners}"
DEFAULT_SHARED_LABEL="shared-ci"
GITHUB_API_VERSION="2026-03-10"
JIT_SCHEMA_VERSION=2
JIT_SYSTEM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
JIT_API_PAGE_SIZE=100
JIT_API_MAX_PAGES=1000
JIT_API_CONNECT_TIMEOUT_SECONDS=15
JIT_API_REQUEST_TIMEOUT_SECONDS=60
JIT_REGISTRATION_RECONCILE_SECONDS=30
JIT_EVIDENCE_MAX_ARCHIVE_BYTES=65536
JIT_EVIDENCE_MAX_JSON_BYTES=16384
JIT_DIAGNOSTIC_MAX_FILES=200
JIT_DIAGNOSTIC_MAX_FILE_BYTES=4194304
JIT_DIAGNOSTIC_MAX_TOTAL_BYTES=33554432
JIT_DIAGNOSTIC_HOST_MAX_BYTES="${GHRCTL_JIT_DIAGNOSTIC_HOST_MAX_BYTES:-4294967296}"
JIT_DIAGNOSTIC_PROJECT_MAX_BYTES="${GHRCTL_JIT_DIAGNOSTIC_PROJECT_MAX_BYTES:-1073741824}"
JIT_DIAGNOSTIC_MIN_FREE_BYTES="${GHRCTL_JIT_DIAGNOSTIC_MIN_FREE_BYTES:-2147483648}"
JIT_DIAGNOSTIC_RETENTION_SECONDS="${GHRCTL_JIT_DIAGNOSTIC_RETENTION_SECONDS:-1209600}"
JIT_DIAGNOSTIC_PROJECT_MAX_WORKERS="${GHRCTL_JIT_DIAGNOSTIC_PROJECT_MAX_WORKERS:-100}"
JIT_POLICY_DIR="${STATE_DIR}/jit.d"
JIT_DATA_DIR="${DATA_DIR}/jit"
JIT_ADMISSIONS_DIR="${JIT_DATA_DIR}/admissions"
JIT_WORKERS_DIR="${JIT_DATA_DIR}/workers"
JIT_RUNNER_CACHE_DIR="${JIT_DATA_DIR}/runner-cache"
JIT_MIGRATIONS_DIR="${JIT_DATA_DIR}/migrations"
JIT_DIAGNOSTICS_DIR="${LOG_DIR}/jit"
JIT_BOUNDARY_ROOT="${GHRCTL_JIT_BOUNDARY_ROOT:-${BASE_ROOT}/.jit}"
JIT_WORKER_RUNTIME_ROOT="${GHRCTL_JIT_WORKER_RUNTIME_ROOT:-/run/ghrctl-jit}"
JIT_RUNTIME_DIR="${GHRCTL_JIT_RUNTIME_DIR:-/usr/local/lib/ghrctl/jit-runtime}"
JIT_RUNTIME_STAGING_LOCK_FILE="${GHRCTL_JIT_RUNTIME_STAGING_LOCK_FILE:-/var/lock/ghrctl-jit-runtime.lock}"
JIT_ACTIVE_ADMISSION_LEASE_FILE="${GHRCTL_JIT_ACTIVE_ADMISSION_LEASE_FILE:-${JIT_DATA_DIR}/active-admission.json}"
JIT_DIAGNOSTIC_RETENTION_LOCK_FILE="${GHRCTL_JIT_DIAGNOSTIC_RETENTION_LOCK_FILE:-${JIT_DATA_DIR}/diagnostics-retention.lock}"
JIT_RUNTIME_HELPER=""
JIT_RUNTIME_MANIFEST=""
JIT_RUNTIME_CONTROLLER_MANIFEST=""
JIT_RUNTIME_CONTROLLER_MANIFEST_SHA256=""
JIT_ADMISSION_RUNTIME_CONTROLLER_MANIFEST=""
JIT_ADMISSION_RUNTIME_CONTROLLER_MANIFEST_SHA256=""

ASSUME_YES=0
NON_INTERACTIVE=0
DRY_RUN=0
JSON_OUTPUT=0
VERBOSE=0
LOCK_HELD=0
JIT_WORKER_HOST_MUTATION_LOCK_FD=""
JIT_WORKER_EXIT_STATE_FILE=""
ACTIVE_OPERATION_FILE=""

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

log() { printf '%s\n' "$*"; }
info() { log "${BLUE}==>${RESET} $*"; json_log info info "$*"; }
success() { log "${GREEN}OK${RESET}  $*"; json_log info success "$*"; }
warn() { log "${YELLOW}WARN${RESET} $*" >&2; json_log warn warning "$*"; }
die() { log "${RED}ERROR${RESET} $*" >&2; json_log error fatal "$*"; exit 1; }
debug() {
  if (( VERBOSE == 1 )); then
    log "${DIM}DEBUG${RESET} $*" >&2
  fi
  json_log debug debug "$*"
}

utc_now() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

jit_process_stat_snapshot() {
  local pid="$1" stat_line remainder
  local -a fields=()
  [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/stat" ]] || return 1
  stat_line="$(<"/proc/${pid}/stat")" || return 1
  remainder="${stat_line##*) }"
  IFS=' ' read -r -a fields <<<"$remainder"
  ((${#fields[@]} >= 20)) || return 1
  [[ "${fields[1]}" =~ ^[0-9]+$ && "${fields[19]}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\t%s\t%s\n' "${fields[0]}" "${fields[1]}" "${fields[19]}"
}

jit_process_stat_identity() {
  local snapshot state _parent ticks
  snapshot="$(jit_process_stat_snapshot "$1")" || return 1
  IFS=$'\t' read -r state _parent ticks <<<"$snapshot"
  printf '%s\t%s\n' "$state" "$ticks"
}

jit_process_start_ticks() {
  local identity _state ticks
  identity="$(jit_process_stat_identity "$1")" || return 1
  IFS=$'\t' read -r _state ticks <<<"$identity"
  printf '%s' "$ticks"
}

json_log() {
  local level="${1:-info}" event="${2:-event}" message="${3:-}" extra="${4:-{}}"
  [[ -d "$LOG_DIR" ]] || return 0
  [[ -w "$LOG_DIR" || -w "$LOG_FILE" ]] || return 0
  if ! jq -e . >/dev/null 2>&1 <<<"$extra"; then extra='{}'; fi
  jq -cn \
    --arg ts "$(utc_now)" \
    --arg level "$level" \
    --arg event "$event" \
    --arg message "$message" \
    --arg version "$GHRCTL_VERSION" \
    --argjson extra "$extra" \
    '{ts:$ts,level:$level,event:$event,message:$message,version:$version} + $extra' \
    >>"$LOG_FILE" 2>/dev/null || true
}

on_error() {
  local ec=$? line="${BASH_LINENO[0]:-unknown}" cmd="${BASH_COMMAND:-unknown}"
  trap - ERR
  mark_operation failed "$ec" "line=${line}"
  warn "Command failed (exit=${ec}) near line ${line}."
  if [[ -n "$ACTIVE_OPERATION_FILE" ]]; then
    warn "The operation journal is preserved. Run '${0##*/} resume' after fixing the cause."
  fi
  debug "Failed command: ${cmd}"
  exit "$ec"
}
trap on_error ERR

on_exit() {
  local ec=$?
  if (( ec == 0 )) && [[ -n "$ACTIVE_OPERATION_FILE" ]]; then
    mark_operation completed 0 ""
  fi
}
trap on_exit EXIT

have() { command -v "$1" >/dev/null 2>&1; }
need_root() { [[ ${EUID} -eq 0 ]] || die "This operation must run as root. Re-run it with sudo."; }

durable_replace_file() {
  local destination="$1" mode="${2:-600}"
  python3 "${GHRCTL_ROOT}/libexec/durable_replace.py" --mode "$mode" "$destination"
}

durable_ensure_dir() {
  local directory="$1" mode="${2:-700}"
  python3 "${GHRCTL_ROOT}/libexec/durable_directory.py" --mode "$mode" "$directory"
}

shell_quote_join() {
  local out="" part
  for part in "$@"; do printf -v part '%q' "$part"; out+="${out:+ }${part}"; done
  printf '%s' "$out"
}

redact_url() {
  local value="$1"
  # Drop any accidental https://TOKEN@host syntax from logs.
  value="$(sed -E 's#(https?://)[^/@]+@#\1***@#g' <<<"$value")"
  printf '%s' "$value"
}

confirm() {
  local prompt_text="$1" default="${2:-N}" answer
  if (( ASSUME_YES == 1 )); then return 0; fi
  if (( NON_INTERACTIVE == 1 )); then
    [[ "$default" == "Y" ]] && return 0
    return 1
  fi
  if [[ "$default" == "Y" ]]; then
    read -r -p "$prompt_text [Y/n]: " answer || true
    answer="${answer:-Y}"
  else
    read -r -p "$prompt_text [y/N]: " answer || true
    answer="${answer:-N}"
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

prompt() {
  local __var="$1" text="$2" default="${3:-}" value
  if (( NON_INTERACTIVE == 1 )); then
    [[ -n "$default" ]] || die "Non-interactive mode requires a value for: $text"
    printf -v "$__var" '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$text [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$text: " value
  fi
  printf -v "$__var" '%s' "$value"
}

prompt_secret() {
  local __var="$1" text="$2" value
  (( NON_INTERACTIVE == 0 )) || die "Secrets must be supplied interactively; non-interactive secret input is intentionally unsupported."
  read -r -s -p "$text: " value
  printf '\n'
  [[ -n "$value" ]] || die "A value is required."
  printf -v "$__var" '%s' "$value"
}

init_dirs() {
  mkdir -p "$PROJECTS_DIR" "$PROFILES_DIR" "$OPERATIONS_DIR" "$BACKUP_WORK_DIR" "$LOG_DIR" "$BASE_ROOT" "$(dirname "$LOCK_FILE")" "$(dirname "$LOG_FILE")"
  chmod 700 "$STATE_DIR" "$PROJECTS_DIR" "$DATA_DIR" "$PROFILES_DIR" "$OPERATIONS_DIR" "$BACKUP_WORK_DIR"
  chmod 755 "$LOG_DIR" "$BASE_ROOT"
  touch "$LOG_FILE" "$LOCK_FILE"
  chmod 600 "$LOG_FILE" "$LOCK_FILE"
}

acquire_lock() {
  need_root
  [[ "$LOCK_HELD" == "1" ]] && return 0
  init_dirs
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another ghrctl process is running."
  LOCK_HELD=1
}

begin_operation() {
  local name="$1" args_json="${2:-[]}" id
  [[ -n "$ACTIVE_OPERATION_FILE" ]] && return 0
  [[ "${GHRCTL_RESUMING:-0}" == "1" ]] && return 0
  init_dirs
  id="$(date -u +'%Y%m%dT%H%M%SZ')-$$-${RANDOM}"
  ACTIVE_OPERATION_FILE="${OPERATIONS_DIR}/${id}.json"
  jq -n \
    --arg id "$id" --arg name "$name" --arg status running \
    --arg started_at "$(utc_now)" --arg version "$GHRCTL_VERSION" \
    --argjson args "$args_json" \
    '{schema_version:1,id:$id,name:$name,args:$args,status:$status,started_at:$started_at,updated_at:$started_at,ghrctl_version:$version,exit_code:null,note:null}' \
    | durable_replace_file "$ACTIVE_OPERATION_FILE"
  ln -sfn "$ACTIVE_OPERATION_FILE" "${OPERATIONS_DIR}/last.json"
  json_log info operation_started "Operation started: $name" "$(jq -cn --arg id "$id" --arg name "$name" '{operation_id:$id,operation:$name}')"
}

mark_operation() {
  local status="$1" exit_code="${2:-0}" note="${3:-}"
  [[ -n "$ACTIVE_OPERATION_FILE" && -f "$ACTIVE_OPERATION_FILE" ]] || return 0
  jq \
    --arg status "$status" --arg updated_at "$(utc_now)" --arg note "$note" \
    --argjson exit_code "$exit_code" \
    '.status=$status | .updated_at=$updated_at | .exit_code=$exit_code | .note=(if $note=="" then null else $note end)' \
    "$ACTIVE_OPERATION_FILE" | durable_replace_file "$ACTIVE_OPERATION_FILE"
}

resume_last_operation() {
  need_root
  init_dirs
  local last="${OPERATIONS_DIR}/last.json" name args
  [[ -r "$last" ]] || die "No operation journal is available."
  name="$(jq -r .name "$last")"
  args="$(jq -c .args "$last")"
  [[ "$(jq -r .status "$last")" != "completed" ]] || die "The last operation already completed."
  info "Resuming idempotent operation: $name"
  export GHRCTL_RESUMING=1
  mapfile -t _resume_args < <(jq -r '.[]' <<<"$args")
  dispatch_command "$name" "${_resume_args[@]}"
}
