# shellcheck shell=bash

jit_remote_runners() {
  jit_api_collection "repos/${JIT_POLICY_REPOSITORY}/actions/runners" runners
}

jit_effective_forbidden_labels() {
  local project_state
  project_state="$(project_file "$JIT_POLICY_PERSISTENT_PROJECT")"
  jit_validate_policy_project_binding "$JIT_POLICY_FILE"
  jq -cn --slurpfile policy "$JIT_POLICY_FILE" --slurpfile project "$project_state" '
    (["self-hosted","linux","x64","arm64"] + $policy[0].forbidden_online_labels + $project[0].labels)
    | map(ascii_downcase) | unique
  '
}

jit_forbidden_online_runners() {
  local runners="$1" forbidden_labels="${2:-}"
  [[ -n "$forbidden_labels" ]] || forbidden_labels="$(jit_effective_forbidden_labels)"
  jq --argjson forbidden "$forbidden_labels" '
    [.runners[] |
      . + {label_names:[.labels[].name],normalized_labels:[.labels[].name | ascii_downcase]} |
      select(.status=="online") |
      select(any(.normalized_labels[]; . as $label | $forbidden | index($label) != null)) |
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

jit_stop_service() {
  local service="$1"
  if jit_test_backend_enabled; then
    rm -f "${GHRCTL_JIT_FAKE_SERVICES_DIR}/${service}.active"
  else
    systemctl stop "$service"
  fi
}

jit_disable_service() {
  local service="$1"
  if jit_test_backend_enabled; then
    rm -f "${GHRCTL_JIT_FAKE_SERVICES_DIR}/${service}.enabled"
  else
    systemctl disable "$service"
  fi
}

jit_local_persistent_inventory() {
  local inventory='[]' file base dir service active enabled
  file="$(project_file "$JIT_POLICY_PERSISTENT_PROJECT")"
  [[ -r "$file" ]] || die "Configured persistent project is missing: $JIT_POLICY_PERSISTENT_PROJECT"
  validate_project_json "$file"
  base="$(jq -r .base_dir "$file")"
  while IFS= read -r dir; do
    service="$(runner_service_from_dir "$dir")"
    [[ -n "$service" ]] || die "Persistent runner has no service record: $dir"
    jit_service_is_active "$service" && active=true || active=false
    jit_service_is_enabled "$service" && enabled=true || enabled=false
    inventory="$(jq --arg directory "$dir" --arg service "$service" --argjson active "$active" --argjson enabled "$enabled" '. + [{directory:$directory,service:$service,was_active:$active,was_enabled:$enabled,drain:"pending",stop:"pending",disable:"pending"}]' <<<"$inventory")"
  done < <(runner_dirs "$base")
  [[ "$(jq 'length' <<<"$inventory")" -gt 0 ]] || die "Persistent project has no managed runner directories to quarantine."
  printf '%s\n' "$inventory"
}

jit_migration_checkpoint_service() {
  local record="$1" service="$2" step="$3" status="$4" temporary
  temporary="${record}.tmp.$$.$RANDOM"
  jq --arg service "$service" --arg step "$step" --arg status "$status" --arg now "$(utc_now)" '
    (.persistent_services[] | select(.service==$service) | .[$step])=$status |
    .current_action={service:$service,step:$step,status:$status} | .updated_at=$now
  ' "$record" >"$temporary"
  chmod 600 "$temporary"; mv "$temporary" "$record"
}

jit_migration_checkpoint_remote() {
  local record="$1" status="$2" runners="${3:-null}" forbidden="${4:-null}" temporary
  temporary="${record}.tmp.$$.$RANDOM"
  jq --arg status "$status" --arg now "$(utc_now)" --argjson runners "$runners" --argjson forbidden "$forbidden" '
    .remote_verification={status:$status,checked_at:(if $status=="checking" then null else $now end),runners:$runners,forbidden_online:$forbidden} |
    .current_action={service:null,step:"remote-verification",status:$status} | .updated_at=$now
  ' "$record" >"$temporary"
  chmod 600 "$temporary"; mv "$temporary" "$record"
}

jit_initialize_migration_journal() {
  local record="$1" project="$2" inventory="$3" runners="$4" forbidden_labels="$5"
  jq -n --argjson schema_version "$JIT_SCHEMA_VERSION" --arg project "$project" --arg repository "$JIT_POLICY_REPOSITORY" --arg persistent_project "$JIT_POLICY_PERSISTENT_PROJECT" \
    --arg started_at "$(utc_now)" --argjson services "$inventory" --argjson remote_before "$runners" --argjson forbidden_labels "$forbidden_labels" '
    {schema_version:$schema_version,project:$project,repository:$repository,persistent_project:$persistent_project,status:"preparing",started_at:$started_at,updated_at:$started_at,quarantined_at:null,rolled_back_at:null,
     persistent_services:$services,effective_forbidden_labels:$forbidden_labels,remote_inventory_before:$remote_before,
     remote_verification:{status:"pending",checked_at:null,runners:null,forbidden_online:null},current_action:{service:null,step:"journal-created",status:"completed"},automatic_resume:false}
  ' | jit_atomic_write "$record"
}

jit_validate_migration_journal() {
  local record="$1" project="$2" current_labels
  jq -e --argjson schema "$JIT_SCHEMA_VERSION" --arg project "$project" --arg repository "$JIT_POLICY_REPOSITORY" --arg persistent_project "$JIT_POLICY_PERSISTENT_PROJECT" '
    .schema_version==$schema and .project==$project and .repository==$repository and .persistent_project==$persistent_project and
    (.status=="preparing" or .status=="quarantined" or .status=="rolled-back") and .automatic_resume==false and
    (.persistent_services|type=="array" and length>0 and all(.[];
      (.directory|type=="string" and length>0) and (.service|type=="string" and length>0) and
      (.drain=="pending" or .drain=="in-progress" or .drain=="completed") and
      (.stop=="pending" or .stop=="in-progress" or .stop=="completed") and
      (.disable=="pending" or .disable=="in-progress" or .disable=="completed"))) and
    (.effective_forbidden_labels|type=="array" and length>0) and (.remote_verification.status|type=="string")
  ' "$record" >/dev/null || die "Persistent-runner migration journal is invalid."
  current_labels="$(jit_effective_forbidden_labels)"
  [[ "$(jq -Sc . <<<"$current_labels")" == "$(jq -Sc .effective_forbidden_labels "$record")" ]] \
    || die "Persistent project labels changed after migration journaling; owner reconciliation is required."
}

jit_migration_plan() {
  need_root
  jit_init_dirs
  local project="${1:-}" auth=gh runners forbidden local_inventory forbidden_labels
  [[ -n "$project" ]] || die "JIT policy project is required."
  shift || true
  while (($#)); do case "$1" in --auth) auth="${2:-}"; shift 2 ;; *) die "Unknown migration-plan option: $1" ;; esac; done
  jit_load_policy "$project"
  jit_configure_auth "$auth"
  forbidden_labels="$(jit_effective_forbidden_labels)"
  runners="$(jit_remote_runners)"; forbidden="$(jit_forbidden_online_runners "$runners" "$forbidden_labels")"; local_inventory="$(jit_local_persistent_inventory)"
  jq -n --arg project "$project" --arg repository "$JIT_POLICY_REPOSITORY" --argjson local "$local_inventory" --argjson forbidden_online "$forbidden" --argjson forbidden_labels "$forbidden_labels" \
    '{project:$project,repository:$repository,local_persistent_services:$local,effective_forbidden_labels:$forbidden_labels,forbidden_online_runners:$forbidden_online,steps:["write preparing journal","drain and checkpoint each service","stop and checkpoint each service","disable and checkpoint each service","verify all paginated runner inventory","mark quarantined","launch only a separately verified admission"],rollback:"cleanup JIT workers and keep broad-label persistent services stopped until an explicit owner review and resume-project command"}'
  unset JIT_API_TOKEN
}

jit_quarantine_persistent() {
  need_root
  acquire_lock
  jit_init_dirs
  local project="${1:-}" auth=gh timeout=3600 inventory runners forbidden record file dir service step_status forbidden_labels journal_status
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
  jit_configure_auth "$auth"
  record="$(jit_migration_file "$project")"
  forbidden_labels="$(jit_effective_forbidden_labels)"
  inventory="$(jit_local_persistent_inventory)"
  runners="$(jit_remote_runners)"; forbidden="$(jit_forbidden_online_runners "$runners" "$forbidden_labels")"
  if (( DRY_RUN == 1 )); then
    jq -n --arg action quarantine-persistent --arg project "$project" --argjson local "$inventory" --argjson remote "$forbidden" --argjson labels "$forbidden_labels" '{action:$action,project:$project,local_services:$local,effective_forbidden_labels:$labels,forbidden_online_runners:$remote,journal_written:false,mutated:false}'
    unset JIT_API_TOKEN
    return 0
  fi
  if [[ -r "$record" ]]; then
    jit_validate_migration_journal "$record" "$project"
    journal_status="$(jq -r .status "$record")"
    [[ "$journal_status" != rolled-back ]] || die "Migration was rolled back; owner review must create a new policy attempt."
    if [[ "$journal_status" == quarantined ]]; then
      jit_assert_persistent_quarantined
      unset JIT_API_TOKEN
      success "Persistent runners remain quarantined. JIT was not launched."
      return 0
    fi
    confirm "Resume the journaled persistent-runner quarantine for '$project'? This does not enable JIT." "N" || die "Cancelled."
    inventory="$(jq -c .persistent_services "$record")"
    forbidden_labels="$(jq -c .effective_forbidden_labels "$record")"
  else
    confirm "Journal, drain, stop, and disable every persistent runner service for '$project'? This does not enable JIT." "N" || die "Cancelled."
    jit_initialize_migration_journal "$record" "$project" "$inventory" "$runners" "$forbidden_labels"
    jit_fault_inject migration-after-journal
  fi
  while IFS= read -r file; do
    dir="$(jq -r .directory <<<"$file")"; service="$(jq -r .service <<<"$file")"
    step_status="$(jq -r --arg service "$service" '.persistent_services[] | select(.service==$service) | .drain' "$record")"
    if [[ "$step_status" != completed ]]; then
      jit_migration_checkpoint_service "$record" "$service" drain in-progress
      wait_runner_idle "$dir" "$timeout"
      jit_fault_inject "migration-${service}-after-drain-before-checkpoint"
      jit_migration_checkpoint_service "$record" "$service" drain completed
    fi
    step_status="$(jq -r --arg service "$service" '.persistent_services[] | select(.service==$service) | .stop' "$record")"
    if [[ "$step_status" != completed ]]; then
      jit_migration_checkpoint_service "$record" "$service" stop in-progress
      jit_service_is_active "$service" && jit_stop_service "$service"
      jit_fault_inject "migration-${service}-after-stop-before-checkpoint"
      jit_migration_checkpoint_service "$record" "$service" stop completed
    fi
    step_status="$(jq -r --arg service "$service" '.persistent_services[] | select(.service==$service) | .disable' "$record")"
    if [[ "$step_status" != completed ]]; then
      jit_migration_checkpoint_service "$record" "$service" disable in-progress
      jit_service_is_enabled "$service" && jit_disable_service "$service"
      jit_fault_inject "migration-${service}-after-disable-before-checkpoint"
      jit_migration_checkpoint_service "$record" "$service" disable completed
    fi
  done < <(jq -c '.[]' <<<"$inventory")
  jit_migration_checkpoint_remote "$record" checking
  jit_fault_inject migration-before-remote-verification
  runners="$(jit_remote_runners)"; forbidden="$(jit_forbidden_online_runners "$runners" "$forbidden_labels")"
  jit_fault_inject migration-after-remote-call-before-checkpoint
  if [[ "$(jq 'length' <<<"$forbidden")" != 0 ]]; then
    jit_migration_checkpoint_remote "$record" failed "$runners" "$forbidden"
    die "Broad-label runners remain online; quarantine is journaled but incomplete."
  fi
  jit_migration_checkpoint_remote "$record" passed "$runners" "$forbidden"
  jit_fault_inject migration-after-remote-verification
  jq --arg now "$(utc_now)" '.status="quarantined" | .quarantined_at=$now | .updated_at=$now | .current_action={service:null,step:"quarantine",status:"completed"}' "$record" | jit_atomic_write "$record"
  unset JIT_API_TOKEN
  success "Persistent runners are quarantined. JIT remains off until an explicit admission launch."
}

jit_assert_persistent_quarantined() {
  local record inventory file service runners forbidden forbidden_labels
  record="$(jit_migration_file "$JIT_POLICY_PROJECT")"
  [[ -r "$record" ]] || die "No reviewed persistent-runner quarantine record exists."
  jit_validate_migration_journal "$record" "$JIT_POLICY_PROJECT"
  jq -e --arg project "$JIT_POLICY_PROJECT" --arg repository "$JIT_POLICY_REPOSITORY" '
    .schema_version==1 and .project==$project and .repository==$repository and .status=="quarantined" and .automatic_resume==false and
    .remote_verification.status=="passed" and all(.persistent_services[]; .drain=="completed" and .stop=="completed" and .disable=="completed")
  ' "$record" >/dev/null || die "Persistent-runner quarantine journal is incomplete or inactive."
  inventory="$(jq -c .persistent_services "$record")"
  forbidden_labels="$(jq -c .effective_forbidden_labels "$record")"
  while IFS= read -r file; do
    service="$(jq -r .service <<<"$file")"
    if jit_service_is_active "$service" || jit_service_is_enabled "$service"; then die "Persistent runner service escaped quarantine: $service"; fi
  done < <(jq -c '.[]' <<<"$inventory")
  runners="$(jit_remote_runners)"; forbidden="$(jit_forbidden_online_runners "$runners" "$forbidden_labels")"
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
  jit_validate_migration_journal "$record" "$project"
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
