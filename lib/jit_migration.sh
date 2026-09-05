# shellcheck shell=bash

jit_remote_runners() {
  jit_api GET "repos/${JIT_POLICY_REPOSITORY}/actions/runners?per_page=100"
}

jit_forbidden_online_runners() {
  local runners="$1"
  jq --slurpfile policy "$JIT_POLICY_FILE" '
    [.runners[] |
      . + {label_names:[.labels[].name]} |
      select(.status=="online") |
      select(any(.label_names[]; . as $label | $policy[0].forbidden_online_labels | index($label) != null)) |
      {id,name,status,busy,labels:.label_names,ephemeral:(.ephemeral // false)}
    ]
  ' <<<"$runners"
}

jit_service_is_active() {
  local service="$1"
  if jit_test_backend_enabled; then [[ -e "${GHRCTL_JIT_FAKE_SERVICES_DIR}/${service}.active" ]]; else systemctl is-active --quiet "$service"; fi
}

jit_service_is_enabled() {
  local service="$1"
  if jit_test_backend_enabled; then [[ -e "${GHRCTL_JIT_FAKE_SERVICES_DIR}/${service}.enabled" ]]; else systemctl is-enabled --quiet "$service"; fi
}

jit_stop_disable_service() {
  local service="$1"
  if jit_test_backend_enabled; then
    rm -f "${GHRCTL_JIT_FAKE_SERVICES_DIR}/${service}.active" "${GHRCTL_JIT_FAKE_SERVICES_DIR}/${service}.enabled"
  else
    systemctl stop "$service"
    systemctl disable "$service"
  fi
}

jit_local_persistent_inventory() {
  local inventory='[]' file base dir service active enabled
  [[ -n "$JIT_POLICY_PERSISTENT_PROJECT" ]] || { printf '%s\n' "$inventory"; return 0; }
  file="$(project_file "$JIT_POLICY_PERSISTENT_PROJECT")"
  [[ -r "$file" ]] || die "Configured persistent project is missing: $JIT_POLICY_PERSISTENT_PROJECT"
  validate_project_json "$file"
  base="$(jq -r .base_dir "$file")"
  while IFS= read -r dir; do
    service="$(runner_service_from_dir "$dir")"
    [[ -n "$service" ]] || die "Persistent runner has no service record: $dir"
    jit_service_is_active "$service" && active=true || active=false
    jit_service_is_enabled "$service" && enabled=true || enabled=false
    inventory="$(jq --arg directory "$dir" --arg service "$service" --argjson active "$active" --argjson enabled "$enabled" '. + [{directory:$directory,service:$service,active:$active,enabled:$enabled}]' <<<"$inventory")"
  done < <(runner_dirs "$base")
  printf '%s\n' "$inventory"
}

jit_migration_plan() {
  need_root
  jit_init_dirs
  local project="${1:-}" auth=gh runners forbidden local_inventory
  [[ -n "$project" ]] || die "JIT policy project is required."
  shift || true
  while (($#)); do case "$1" in --auth) auth="${2:-}"; shift 2 ;; *) die "Unknown migration-plan option: $1" ;; esac; done
  jit_load_policy "$project"
  jit_configure_auth "$auth"
  runners="$(jit_remote_runners)"; forbidden="$(jit_forbidden_online_runners "$runners")"; local_inventory="$(jit_local_persistent_inventory)"
  jq -n --arg project "$project" --arg repository "$JIT_POLICY_REPOSITORY" --argjson local "$local_inventory" --argjson forbidden_online "$forbidden" \
    '{project:$project,repository:$repository,local_persistent_services:$local,forbidden_online_runners:$forbidden_online,steps:["review inventory","drain active jobs","stop and disable persistent services","verify no forbidden broad-label runner remains online","launch only a separately verified admission"],rollback:"cleanup JIT workers and keep broad-label persistent services stopped until an explicit owner review and resume-project command"}'
  unset JIT_API_TOKEN
}

jit_quarantine_persistent() {
  need_root
  acquire_lock
  jit_init_dirs
  local project="${1:-}" auth=gh timeout=3600 inventory runners forbidden record file dir service
  [[ -n "$project" ]] || die "JIT policy project is required."
  shift || true
  while (($#)); do
    case "$1" in
      --auth) auth="${2:-}"; shift 2 ;;
      --timeout) timeout="${2:-}"; shift 2 ;;
      *) die "Unknown quarantine-persistent option: $1" ;;
    esac
  done
  jit_validate_positive_integer "$timeout" timeout
  jit_load_policy "$project"
  inventory="$(jit_local_persistent_inventory)"
  jit_configure_auth "$auth"
  runners="$(jit_remote_runners)"; forbidden="$(jit_forbidden_online_runners "$runners")"
  record="$(jit_migration_file "$project")"
  if (( DRY_RUN == 1 )); then
    jq -n --arg action quarantine-persistent --arg project "$project" --argjson local "$inventory" --argjson remote "$forbidden" '{action:$action,project:$project,local_services:$local,forbidden_online_runners:$remote,mutated:false}'
    unset JIT_API_TOKEN
    return 0
  fi
  confirm "Drain, stop, and disable every persistent runner service for '$project'? This does not enable JIT." "N" || die "Cancelled."
  while IFS= read -r file; do
    dir="$(jq -r .directory <<<"$file")"; service="$(jq -r .service <<<"$file")"
    wait_runner_idle "$dir" "$timeout"
    jit_stop_disable_service "$service"
  done < <(jq -c '.[]' <<<"$inventory")
  runners="$(jit_remote_runners)"; forbidden="$(jit_forbidden_online_runners "$runners")"
  [[ "$(jq 'length' <<<"$forbidden")" == 0 ]] || die "Broad-label runners remain online; quarantine is incomplete."
  jq -n --argjson schema_version "$JIT_SCHEMA_VERSION" --arg project "$project" --arg repository "$JIT_POLICY_REPOSITORY" --arg status quarantined --arg quarantined_at "$(utc_now)" --argjson services "$inventory" --argjson remote_before "$runners" \
    '{schema_version:$schema_version,project:$project,repository:$repository,status:$status,quarantined_at:$quarantined_at,rolled_back_at:null,persistent_services:$services,remote_inventory_before:$remote_before,automatic_resume:false}' \
    | jit_atomic_write "$record"
  unset JIT_API_TOKEN
  success "Persistent runners are quarantined. JIT remains off until an explicit admission launch."
}

jit_assert_persistent_quarantined() {
  local record inventory file service runners forbidden
  record="$(jit_migration_file "$JIT_POLICY_PROJECT")"
  [[ -r "$record" ]] || die "No reviewed persistent-runner quarantine record exists."
  jq -e --arg project "$JIT_POLICY_PROJECT" --arg repository "$JIT_POLICY_REPOSITORY" '.schema_version==1 and .project==$project and .repository==$repository and .status=="quarantined" and .automatic_resume==false' "$record" >/dev/null || die "Persistent-runner quarantine record is invalid or inactive."
  inventory="$(jq -c .persistent_services "$record")"
  while IFS= read -r file; do
    service="$(jq -r .service <<<"$file")"
    if jit_service_is_active "$service" || jit_service_is_enabled "$service"; then die "Persistent runner service escaped quarantine: $service"; fi
  done < <(jq -c '.[]' <<<"$inventory")
  runners="$(jit_remote_runners)"; forbidden="$(jit_forbidden_online_runners "$runners")"
  [[ "$(jq 'length' <<<"$forbidden")" == 0 ]] || die "A broad-label persistent runner is online; JIT launch rejected."
}

jit_rollback_project() {
  need_root
  acquire_lock
  jit_init_dirs
  local project="${1:-}" auth=gh record admission_file admission_project failures=0 temporary
  [[ -n "$project" ]] || die "JIT policy project is required."
  shift || true
  while (($#)); do case "$1" in --auth) auth="${2:-}"; shift 2 ;; *) die "Unknown rollback option: $1" ;; esac; done
  jit_load_policy "$project"
  record="$(jit_migration_file "$project")"
  [[ -r "$record" ]] || die "No migration record exists for $project."
  jit_configure_auth "$auth"
  shopt -s nullglob
  for admission_file in "$JIT_ADMISSIONS_DIR"/*.json; do
    admission_project="$(jq -r .project "$admission_file")"
    [[ "$admission_project" == "$project" ]] || continue
    jit_load_admission "$(jq -r .id "$admission_file")"
    jit_cleanup_admission_workers || failures=$((failures + 1))
    (( failures == 0 )) && jit_set_admission_status cleaned "Project rollback cleanup completed."
  done
  shopt -u nullglob
  (( failures == 0 )) || die "Rollback cleanup is incomplete; persistent runners remain quarantined."
  temporary="${record}.tmp.$$.$RANDOM"
  jq --arg now "$(utc_now)" '.status="rolled-back" | .rolled_back_at=$now | .automatic_resume=false' "$record" >"$temporary"
  chmod 600 "$temporary"; mv "$temporary" "$record"
  unset JIT_API_TOKEN
  if (( JSON_OUTPUT == 1 )); then
    jq '. + {persistent_runners_resumed:false,next_step:"owner review, then explicit ghrctl resume-project if broad-label access is intended"}' "$record"
  else
    success "JIT rollback cleanup completed. Persistent runners were intentionally NOT restarted."
    warn "After owner review only, use '$0 resume-project ${JIT_POLICY_PERSISTENT_PROJECT:-<persistent-project>}' explicitly if broad-label access is intended."
  fi
}

jit_command() {
  local subcommand="${1:-help}"; shift || true
  case "$subcommand" in
    install-policy) jit_install_policy "$@" ;;
    prepare) jit_prepare_admission "$@" ;;
    launch) jit_launch_admission "$@" ;;
    status) jit_status_admission "$@" ;;
    cleanup) jit_cleanup_admission "$@" ;;
    resume) jit_resume_admission "$@" ;;
    migration-plan) jit_migration_plan "$@" ;;
    quarantine-persistent) jit_quarantine_persistent "$@" ;;
    rollback) jit_rollback_project "$@" ;;
    help|--help|-h)
      usage
      ;;
    *) die "Unknown JIT command: $subcommand" ;;
  esac
}
