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
GITHUB_API_VERSION="2022-11-28"

ASSUME_YES=0
NON_INTERACTIVE=0
DRY_RUN=0
JSON_OUTPUT=0
VERBOSE=0
LOCK_HELD=0
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
    >"$ACTIVE_OPERATION_FILE"
  chmod 600 "$ACTIVE_OPERATION_FILE"
  ln -sfn "$ACTIVE_OPERATION_FILE" "${OPERATIONS_DIR}/last.json"
  json_log info operation_started "Operation started: $name" "$(jq -cn --arg id "$id" --arg name "$name" '{operation_id:$id,operation:$name}')"
}

mark_operation() {
  local status="$1" exit_code="${2:-0}" note="${3:-}"
  [[ -n "$ACTIVE_OPERATION_FILE" && -f "$ACTIVE_OPERATION_FILE" ]] || return 0
  local tmp="${ACTIVE_OPERATION_FILE}.tmp"
  jq \
    --arg status "$status" --arg updated_at "$(utc_now)" --arg note "$note" \
    --argjson exit_code "$exit_code" \
    '.status=$status | .updated_at=$updated_at | .exit_code=$exit_code | .note=(if $note=="" then null else $note end)' \
    "$ACTIVE_OPERATION_FILE" >"$tmp" && mv "$tmp" "$ACTIVE_OPERATION_FILE"
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
