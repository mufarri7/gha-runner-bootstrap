# shellcheck shell=bash

jit_init_dirs() {
  durable_ensure_dir "$JIT_DATA_DIR" 700
  durable_ensure_dir "$JIT_POLICY_DIR" 700
  durable_ensure_dir "$JIT_ADMISSIONS_DIR" 700
  durable_ensure_dir "$JIT_WORKERS_DIR" 700
  durable_ensure_dir "$JIT_RUNNER_CACHE_DIR" 700
  durable_ensure_dir "$JIT_MIGRATIONS_DIR" 700
  durable_ensure_dir "$JIT_DIAGNOSTICS_DIR" 700
  durable_ensure_dir "$JIT_BOUNDARY_ROOT" 711
}

jit_policy_file() { printf '%s/%s.json' "$JIT_POLICY_DIR" "$1"; }
jit_admission_file() { printf '%s/%s.json' "$JIT_ADMISSIONS_DIR" "$1"; }
jit_worker_state_dir() { printf '%s/%s' "$JIT_WORKERS_DIR" "$1"; }
jit_migration_file() { printf '%s/%s.json' "$JIT_MIGRATIONS_DIR" "$1"; }

jit_atomic_write() {
  local destination="$1"
  jq -e . | durable_replace_file "$destination"
}

jit_validate_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die "Invalid ${2:-SHA}: $1"
}

jit_validate_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || die "Invalid ${2:-integer}: $1"
}

jit_validate_policy_json() {
  local file="$1" project repository workflow_path workflow_name admission_job evidence_prefix trusted_branch label_prefix actor forbidden_label
  [[ -r "$file" ]] || die "JIT policy is not readable: $file"
  jq -e --argjson schema "$JIT_SCHEMA_VERSION" '
    . as $policy |
    .schema_version == $schema and
    (.project | type == "string" and length > 0) and
    (.repository | type == "string" and length > 2) and
    (.workflow_path | type == "string" and startswith(".github/workflows/")) and
    (.workflow_name | type == "string" and length > 0) and
    (.admission_job_name | type == "string" and length > 0) and
    (.evidence_artifact_prefix | type == "string" and length > 0) and
    (.trusted_branch | type == "string" and length > 0) and
    (.allowed_actors | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
    (.label_prefix | type == "string" and length > 0) and
    (.runner_group_id | type == "number" and floor == . and . >= 1) and
    (.max_slots | type == "number" and floor == . and . >= 1 and . <= 16) and
    (.max_replacements | type == "number" and floor == . and . >= 0 and . <= 64) and
    (.freshness_seconds | type == "number" and floor == . and . >= 60 and . <= 86400) and
    (.poll_seconds | type == "number" and floor == . and . >= 1 and . <= 300) and
    (.max_runtime_seconds | type == "number" and floor == . and . >= 60 and . <= 86400) and
    (.rootless_docker == true) and
    (.real_id_pool.start | type == "number" and floor == . and . >= 1) and
    (.real_id_pool.end | type == "number" and floor == . and . >= $policy.real_id_pool.start and . <= 4294967294) and
    (.subordinate_id_pool.start | type == "number" and floor == . and . >= 1) and
    (.subordinate_id_pool.end | type == "number" and floor == . and . >= $policy.subordinate_id_pool.start and . <= 4294967294) and
    (.subordinate_id_pool.range_size | type == "number" and floor == . and . >= 65536) and
    ($policy.real_id_pool.end < $policy.subordinate_id_pool.start or $policy.subordinate_id_pool.end < $policy.real_id_pool.start) and
    (($policy.real_id_pool.end - $policy.real_id_pool.start + 1) >= $policy.max_slots) and
    (((($policy.subordinate_id_pool.end - $policy.subordinate_id_pool.start + 1) / $policy.subordinate_id_pool.range_size) | floor) >= $policy.max_slots) and
    (.forbidden_online_labels | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
    (.persistent_project | type == "string" and length > 0)
  ' "$file" >/dev/null || die "Invalid or unsafe JIT policy: $file"

  project="$(jq -r .project "$file")"
  repository="$(jq -r .repository "$file")"
  workflow_path="$(jq -r .workflow_path "$file")"
  workflow_name="$(jq -r .workflow_name "$file")"
  admission_job="$(jq -r .admission_job_name "$file")"
  evidence_prefix="$(jq -r .evidence_artifact_prefix "$file")"
  trusted_branch="$(jq -r .trusted_branch "$file")"
  label_prefix="$(jq -r .label_prefix "$file")"

  [[ "$(sanitize_slug "$project")" == "$project" ]] || die "JIT policy project must already be a sanitized slug."
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid JIT policy repository."
  [[ "$workflow_path" != *..* && "$workflow_path" =~ ^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]] || die "Unsafe JIT workflow path."
  [[ "$workflow_name" != *$'\n'* && "$admission_job" != *$'\n'* ]] || die "JIT workflow and job names must be single-line strings."
  [[ "$evidence_prefix" =~ ^[a-z0-9][a-z0-9-]{0,63}-$ ]] || die "Unsafe JIT evidence artifact prefix."
  [[ "$trusted_branch" =~ ^[A-Za-z0-9._/-]+$ && "$trusted_branch" != *..* ]] || die "Unsafe trusted branch."
  [[ "$label_prefix" =~ ^[a-z0-9][a-z0-9-]{0,39}-$ ]] || die "Unsafe JIT label prefix."
  while IFS= read -r actor; do
    [[ "$actor" =~ ^[A-Za-z0-9-]+$ ]] || die "Unsafe allowed actor in JIT policy: $actor"
  done < <(jq -r '.allowed_actors[]' "$file")
  while IFS= read -r forbidden_label; do
    [[ "$forbidden_label" =~ ^[A-Za-z0-9._-]+$ ]] || die "Unsafe forbidden runner label in JIT policy: $forbidden_label"
  done < <(jq -r '.forbidden_online_labels[]' "$file")
}

jit_validate_policy_project_binding() {
  local policy_file="$1" persistent_project project_state policy_repository state_repository
  persistent_project="$(jq -r .persistent_project "$policy_file")"
  project_state="$(project_file "$persistent_project")"
  [[ -r "$project_state" ]] || die "JIT policy must reference an existing ghrctl project: $persistent_project"
  validate_project_json "$project_state"
  policy_repository="$(jq -r '.repository | ascii_downcase' "$policy_file")"
  state_repository="$(jq -r '.repo_full_name | ascii_downcase' "$project_state")"
  [[ "$policy_repository" == "$state_repository" ]] || die "JIT policy repository does not match persistent project state."
  jq -e '.labels | length>0 and all(.[]; type=="string" and length>0 and test("^[A-Za-z0-9._-]+$"))' "$project_state" >/dev/null \
    || die "Persistent project state has no safe reusable labels to quarantine."
}

jit_load_policy() {
  local project="$1" file
  file="$(jit_policy_file "$project")"
  jit_validate_policy_json "$file"
  JIT_POLICY_FILE="$file"
  JIT_POLICY_PROJECT="$(jq -r .project "$file")"
  JIT_POLICY_REPOSITORY="$(jq -r .repository "$file")"
  JIT_POLICY_WORKFLOW_PATH="$(jq -r .workflow_path "$file")"
  JIT_POLICY_WORKFLOW_NAME="$(jq -r .workflow_name "$file")"
  JIT_POLICY_ADMISSION_JOB="$(jq -r .admission_job_name "$file")"
  JIT_POLICY_EVIDENCE_ARTIFACT_PREFIX="$(jq -r .evidence_artifact_prefix "$file")"
  JIT_POLICY_TRUSTED_BRANCH="$(jq -r .trusted_branch "$file")"
  JIT_POLICY_LABEL_PREFIX="$(jq -r .label_prefix "$file")"
  JIT_POLICY_RUNNER_GROUP_ID="$(jq -r .runner_group_id "$file")"
  JIT_POLICY_MAX_SLOTS="$(jq -r .max_slots "$file")"
  JIT_POLICY_MAX_REPLACEMENTS="$(jq -r .max_replacements "$file")"
  JIT_POLICY_FRESHNESS_SECONDS="$(jq -r .freshness_seconds "$file")"
  JIT_POLICY_POLL_SECONDS="$(jq -r .poll_seconds "$file")"
  JIT_POLICY_MAX_RUNTIME_SECONDS="$(jq -r .max_runtime_seconds "$file")"
  JIT_POLICY_REAL_ID_START="$(jq -r .real_id_pool.start "$file")"
  JIT_POLICY_REAL_ID_END="$(jq -r .real_id_pool.end "$file")"
  JIT_POLICY_SUBID_START="$(jq -r .subordinate_id_pool.start "$file")"
  JIT_POLICY_SUBID_END="$(jq -r .subordinate_id_pool.end "$file")"
  JIT_POLICY_SUBID_COUNT="$(jq -r .subordinate_id_pool.range_size "$file")"
  JIT_POLICY_PERSISTENT_PROJECT="$(jq -r .persistent_project "$file")"
  jit_validate_policy_project_binding "$file"
}

jit_install_policy() {
  need_root
  acquire_lock
  jit_init_dirs
  local source_file="${1:-}" project target
  [[ -n "$source_file" ]] || die "Usage: $0 jit install-policy FILE"
  jit_validate_policy_json "$source_file"
  jit_validate_policy_project_binding "$source_file"
  project="$(jq -r .project "$source_file")"
  target="$(jit_policy_file "$project")"
  if [[ -e "$target" ]]; then
    confirm "Replace the existing root-owned JIT policy for '$project'?" "N" || die "Cancelled."
  fi
  if (( DRY_RUN == 1 )); then
    jq -n --arg action install-jit-policy --arg project "$project" --arg target "$target" '{action:$action,project:$project,target:$target,enables_data_plane:false}'
    return 0
  fi
  jq . "$source_file" | jit_atomic_write "$target"
  success "Installed JIT policy for $project. The JIT data plane remains disabled until an admission is explicitly launched."
}

jit_base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

jit_app_jwt() {
  local now issued expires header payload signing_input signature key_file="$GHRCTL_JIT_APP_PRIVATE_KEY_FILE"
  [[ -r "$key_file" ]] || die "GitHub App private key is not readable."
  [[ "$(stat -c '%U' "$key_file")" == root ]] || die "GitHub App private key must be root-owned."
  local key_mode
  key_mode="$(stat -c '%a' "$key_file")"
  (( (8#$key_mode & 077) == 0 )) || die "GitHub App private key must not be group/world accessible."
  now="$(date +%s)"; issued=$((now - 60)); expires=$((now + 540))
  header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | jit_base64url)"
  payload="$(jq -cn --argjson iat "$issued" --argjson exp "$expires" --arg iss "$GHRCTL_JIT_APP_ID" '{iat:$iat,exp:$exp,iss:$iss}' | jit_base64url)"
  signing_input="${header}.${payload}"
  signature="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$key_file" | jit_base64url)"
  printf '%s.%s' "$signing_input" "$signature"
}

jit_curl_api_with_token() {
  local token="$1" method="$2" endpoint="$3" body="${4:-}" url
  [[ "$token" =~ ^[A-Za-z0-9_.-]+$ ]] || die "GitHub API credential has an unexpected format."
  grep -Eq '^[A-Za-z0-9_./?=&%:-]+$' <<<"$endpoint" && [[ "$endpoint" != *..* ]] || die "Unsafe GitHub API endpoint."
  url="https://api.github.com/${endpoint}"
  if [[ -n "$body" ]]; then
    curl --silent --show-error --fail-with-body --connect-timeout "$JIT_API_CONNECT_TIMEOUT_SECONDS" --max-time "$JIT_API_REQUEST_TIMEOUT_SECONDS" --request "$method" --url "$url" \
      --header 'Accept: application/vnd.github+json' \
      --header "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
      --header 'Content-Type: application/json' \
      --data-binary "$body" --config - <<EOF_CURL
header = "Authorization: Bearer ${token}"
EOF_CURL
  else
    curl --silent --show-error --fail-with-body --connect-timeout "$JIT_API_CONNECT_TIMEOUT_SECONDS" --max-time "$JIT_API_REQUEST_TIMEOUT_SECONDS" --request "$method" --url "$url" \
      --header 'Accept: application/vnd.github+json' \
      --header "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
      --config - <<EOF_CURL
header = "Authorization: Bearer ${token}"
EOF_CURL
  fi
}

jit_refresh_app_token() {
  local jwt response expires_at
  jwt="$(jit_app_jwt)"
  response="$(jit_curl_api_with_token "$jwt" POST "app/installations/${GHRCTL_JIT_APP_INSTALLATION_ID}/access_tokens" '{}')"
  unset jwt
  JIT_API_TOKEN="$(jq -r .token <<<"$response")"
  expires_at="$(jq -r .expires_at <<<"$response")"
  [[ -n "$JIT_API_TOKEN" && "$JIT_API_TOKEN" != null ]] || die "GitHub App installation token exchange failed."
  JIT_API_TOKEN_EXPIRES_EPOCH="$(date -d "$expires_at" +%s)"
  unset response
}

jit_configure_auth() {
  local mode="${1:-gh}"
  JIT_AUTH_MODE="$mode"
  JIT_API_TOKEN=""
  JIT_API_TOKEN_EXPIRES_EPOCH=0
  case "$mode" in
    gh)
      have gh || die "gh CLI is required for --auth gh."
      gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated."
      JIT_API_TOKEN="$(gh auth token)"
      ;;
    token)
      prompt_secret JIT_API_TOKEN "One-time GitHub credential with Actions:read, Contents:read, Pull requests:read, and Administration:write"
      ;;
    app)
      : "${GHRCTL_JIT_APP_ID:?GHRCTL_JIT_APP_ID is required for --auth app}"
      : "${GHRCTL_JIT_APP_INSTALLATION_ID:?GHRCTL_JIT_APP_INSTALLATION_ID is required for --auth app}"
      : "${GHRCTL_JIT_APP_PRIVATE_KEY_FILE:?GHRCTL_JIT_APP_PRIVATE_KEY_FILE is required for --auth app}"
      [[ "$GHRCTL_JIT_APP_ID" =~ ^[0-9]+$ && "$GHRCTL_JIT_APP_INSTALLATION_ID" =~ ^[0-9]+$ ]] || die "Invalid GitHub App identifiers."
      jit_refresh_app_token
      ;;
    *) die "Unsupported JIT authentication mode: $mode" ;;
  esac
}

jit_ensure_api_token() {
  if [[ "$JIT_AUTH_MODE" == app ]] && (( $(date +%s) + 300 >= JIT_API_TOKEN_EXPIRES_EPOCH )); then
    jit_refresh_app_token
  fi
  [[ -n "$JIT_API_TOKEN" ]] || die "GitHub API credential is unavailable."
}

jit_api() {
  local method="$1" endpoint="$2" body="${3:-}"
  jit_ensure_api_token
  jit_curl_api_with_token "$JIT_API_TOKEN" "$method" "$endpoint" "$body"
}

jit_verify_admission() {
  local run_id="$1" run_attempt="$2" pr_number="$3" base_sha="$4" head_sha="$5" merge_sha="$6" tree_sha="$7" label="$8"
  local run latest_run workflow jobs job_count job evidence pr merge_commit created_epoch now expected_label
  run="$(jit_api GET "repos/${JIT_POLICY_REPOSITORY}/actions/runs/${run_id}/attempts/${run_attempt}")"
  latest_run="$(jit_api GET "repos/${JIT_POLICY_REPOSITORY}/actions/runs/${run_id}")"

  [[ "$(jq -r .repository.full_name <<<"$run")" == "$JIT_POLICY_REPOSITORY" ]] || die "Admission repository mismatch."
  [[ "$(jq -r .event <<<"$run")" == workflow_dispatch ]] || die "Admission must originate from workflow_dispatch."
  [[ "$(jq -r .run_attempt <<<"$run")" == "$run_attempt" ]] || die "Admission run attempt mismatch."
  [[ "$(jq -r .run_attempt <<<"$latest_run")" == "$run_attempt" ]] || die "A newer run attempt exists; stale admission rejected."
  [[ "$(jq -r .head_branch <<<"$run")" == "$JIT_POLICY_TRUSTED_BRANCH" ]] || die "Admission did not execute from the trusted branch."
  [[ "$(jq -r .head_sha <<<"$run")" == "$base_sha" ]] || die "Admission workflow SHA does not match the expected base."
  [[ "$(jq -r .path <<<"$run")" == "$JIT_POLICY_WORKFLOW_PATH" ]] || die "Admission workflow path mismatch."
  jq -e --arg actor "$(jq -r .actor.login <<<"$run")" '.allowed_actors | index($actor) != null' "$JIT_POLICY_FILE" >/dev/null || die "Admission actor is not allowed."
  jq -e --arg actor "$(jq -r .triggering_actor.login <<<"$run")" '.allowed_actors | index($actor) != null' "$JIT_POLICY_FILE" >/dev/null || die "Admission triggering actor is not allowed."

  workflow="$(jit_api GET "repos/${JIT_POLICY_REPOSITORY}/actions/workflows/$(jq -r .workflow_id <<<"$run")")"
  [[ "$(jq -r .path <<<"$workflow")" == "$JIT_POLICY_WORKFLOW_PATH" ]] || die "Resolved workflow path mismatch."
  [[ "$(jq -r .name <<<"$workflow")" == "$JIT_POLICY_WORKFLOW_NAME" ]] || die "Resolved workflow name mismatch."
  [[ "$(jq -r .state <<<"$workflow")" == active ]] || die "Admission workflow is not active."

  jobs="$(jit_api_collection "repos/${JIT_POLICY_REPOSITORY}/actions/runs/${run_id}/attempts/${run_attempt}/jobs" jobs)"
  job_count="$(jq --arg name "$JIT_POLICY_ADMISSION_JOB" '[.jobs[] | select(.name == $name)] | length' <<<"$jobs")"
  [[ "$job_count" == 1 ]] || die "Expected exactly one trusted admission job."
  job="$(jq -c --arg name "$JIT_POLICY_ADMISSION_JOB" '.jobs[] | select(.name == $name)' <<<"$jobs")"
  [[ "$(jq -r .status <<<"$job")" == completed && "$(jq -r .conclusion <<<"$job")" == success ]] || die "Trusted admission job did not complete successfully."
  [[ "$(jq -r .head_sha <<<"$job")" == "$base_sha" ]] || die "Admission job head SHA mismatch."
  evidence="$(jit_fetch_admission_evidence "$run" "$job" "$run_id" "$run_attempt" "$pr_number" "$base_sha" "$head_sha" "$merge_sha" "$tree_sha" "$label")"

  pr="$(jit_api GET "repos/${JIT_POLICY_REPOSITORY}/pulls/${pr_number}")"
  [[ "$(jq -r .state <<<"$pr")" == open ]] || die "Admission pull request is not open."
  [[ "$(jq -r .base.ref <<<"$pr")" == "$JIT_POLICY_TRUSTED_BRANCH" ]] || die "Pull request base branch mismatch."
  [[ "$(jq -r .base.sha <<<"$pr")" == "$base_sha" ]] || die "Pull request base SHA is stale."
  [[ "$(jq -r .head.repo.full_name <<<"$pr")" == "$JIT_POLICY_REPOSITORY" ]] || die "Candidate-origin or fork pull request rejected."
  [[ "$(jq -r .head.sha <<<"$pr")" == "$head_sha" ]] || die "Pull request head SHA is stale."
  [[ "$(jq -r .merge_commit_sha <<<"$pr")" == "$merge_sha" ]] || die "Pull request merge SHA is stale."

  merge_commit="$(jit_api GET "repos/${JIT_POLICY_REPOSITORY}/git/commits/${merge_sha}")"
  [[ "$(jq -r .sha <<<"$merge_commit")" == "$merge_sha" ]] || die "Merge commit identity mismatch."
  [[ "$(jq -r .tree.sha <<<"$merge_commit")" == "$tree_sha" ]] || die "Merge tree identity mismatch."
  [[ "$(jq '.parents | length' <<<"$merge_commit")" == 2 ]] || die "Merge candidate must have exactly two parents."
  [[ "$(jq -r '.parents[0].sha' <<<"$merge_commit")" == "$base_sha" ]] || die "Merge candidate first parent mismatch."
  [[ "$(jq -r '.parents[1].sha' <<<"$merge_commit")" == "$head_sha" ]] || die "Merge candidate second parent mismatch."

  expected_label="${JIT_POLICY_LABEL_PREFIX}${run_id}-${run_attempt}"
  [[ "$label" == "$expected_label" ]] || die "Admission label must be exactly $expected_label"
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]{0,99}$ ]] || die "Admission label has an unsafe format."
  created_epoch="$(date -d "$(jq -r .created_at <<<"$run")" +%s)"
  now="$(date +%s)"
  (( created_epoch <= now + 300 )) || die "Admission timestamp is in the future."
  (( now - created_epoch <= JIT_POLICY_FRESHNESS_SECONDS )) || die "Admission evidence is stale."

  jq -n \
    --arg workflow_id "$(jq -r .workflow_id <<<"$run")" \
    --arg run_created_at "$(jq -r .created_at <<<"$run")" \
    --arg run_url "$(jq -r .html_url <<<"$run")" \
    --arg admission_job_id "$(jq -r .id <<<"$job")" \
    --argjson evidence "$evidence" \
    '{workflow_id:($workflow_id|tonumber),run_created_at:$run_created_at,run_url:$run_url,admission_job_id:($admission_job_id|tonumber),evidence:$evidence}'
}

jit_parse_prepare_args() {
  JIT_ARG_RUN_ID=""; JIT_ARG_RUN_ATTEMPT=""; JIT_ARG_PR_NUMBER=""; JIT_ARG_BASE_SHA=""; JIT_ARG_HEAD_SHA=""; JIT_ARG_MERGE_SHA=""; JIT_ARG_TREE_SHA=""; JIT_ARG_LABEL=""; JIT_ARG_AUTH=gh
  while (($#)); do
    case "$1" in
      --run-id) JIT_ARG_RUN_ID="${2:-}"; shift 2 ;;
      --run-attempt) JIT_ARG_RUN_ATTEMPT="${2:-}"; shift 2 ;;
      --pr-number) JIT_ARG_PR_NUMBER="${2:-}"; shift 2 ;;
      --base-sha) JIT_ARG_BASE_SHA="${2:-}"; shift 2 ;;
      --head-sha) JIT_ARG_HEAD_SHA="${2:-}"; shift 2 ;;
      --merge-sha) JIT_ARG_MERGE_SHA="${2:-}"; shift 2 ;;
      --tree-sha) JIT_ARG_TREE_SHA="${2:-}"; shift 2 ;;
      --label) JIT_ARG_LABEL="${2:-}"; shift 2 ;;
      --auth) JIT_ARG_AUTH="${2:-}"; shift 2 ;;
      *) die "Unknown jit prepare option: $1" ;;
    esac
  done
}

jit_prepare_admission() {
  need_root
  acquire_lock
  jit_init_dirs
  local project="${1:-}" verification admission_id admission_file verified_at expires_epoch
  [[ -n "$project" ]] || die "A JIT policy project is required."
  shift || true
  jit_load_policy "$project"
  jit_parse_prepare_args "$@"
  jit_validate_positive_integer "$JIT_ARG_RUN_ID" run-id
  jit_validate_positive_integer "$JIT_ARG_RUN_ATTEMPT" run-attempt
  jit_validate_positive_integer "$JIT_ARG_PR_NUMBER" pr-number
  jit_validate_sha "$JIT_ARG_BASE_SHA" base-sha
  jit_validate_sha "$JIT_ARG_HEAD_SHA" head-sha
  jit_validate_sha "$JIT_ARG_MERGE_SHA" merge-sha
  jit_validate_sha "$JIT_ARG_TREE_SHA" tree-sha
  [[ -n "$JIT_ARG_LABEL" ]] || die "--label is required."
  jit_configure_auth "$JIT_ARG_AUTH"
  verification="$(jit_verify_admission "$JIT_ARG_RUN_ID" "$JIT_ARG_RUN_ATTEMPT" "$JIT_ARG_PR_NUMBER" "$JIT_ARG_BASE_SHA" "$JIT_ARG_HEAD_SHA" "$JIT_ARG_MERGE_SHA" "$JIT_ARG_TREE_SHA" "$JIT_ARG_LABEL")"
  admission_id="$(printf '%s\0%s\0%s\0%s\0%s\0%s\0%s' "$JIT_POLICY_REPOSITORY" "$JIT_ARG_RUN_ID" "$JIT_ARG_RUN_ATTEMPT" "$JIT_ARG_BASE_SHA" "$JIT_ARG_HEAD_SHA" "$JIT_ARG_MERGE_SHA" "$JIT_ARG_LABEL" | sha256sum | awk '{print $1}')"
  admission_file="$(jit_admission_file "$admission_id")"
  [[ ! -e "$admission_file" ]] || die "Admission replay rejected: $admission_id already exists."
  verified_at="$(utc_now)"; expires_epoch=$(( $(date -d "$(jq -r .run_created_at <<<"$verification")" +%s) + JIT_POLICY_FRESHNESS_SECONDS ))
  if (( DRY_RUN == 1 )); then
    jq -n --arg action verify-admission --arg admission_id "$admission_id" --arg project "$project" --arg label "$JIT_ARG_LABEL" '{action:$action,admission_id:$admission_id,project:$project,label:$label,verified:true,persisted:false,jit_config_generated:false}'
    unset JIT_API_TOKEN
    return 0
  fi
  jq -n \
    --argjson schema_version "$JIT_SCHEMA_VERSION" --arg id "$admission_id" --arg project "$project" --arg repository "$JIT_POLICY_REPOSITORY" \
    --arg run_id "$JIT_ARG_RUN_ID" --arg run_attempt "$JIT_ARG_RUN_ATTEMPT" --arg pr_number "$JIT_ARG_PR_NUMBER" \
    --arg base_sha "$JIT_ARG_BASE_SHA" --arg head_sha "$JIT_ARG_HEAD_SHA" --arg merge_sha "$JIT_ARG_MERGE_SHA" --arg tree_sha "$JIT_ARG_TREE_SHA" --arg label "$JIT_ARG_LABEL" \
    --arg verified_at "$verified_at" --arg expires_epoch "$expires_epoch" --argjson verification "$verification" \
    '{schema_version:$schema_version,id:$id,project:$project,repository:$repository,run_id:($run_id|tonumber),run_attempt:($run_attempt|tonumber),pr_number:($pr_number|tonumber),base_sha:$base_sha,head_sha:$head_sha,merge_sha:$merge_sha,tree_sha:$tree_sha,label:$label,status:"prepared",verified_at:$verified_at,expires_epoch:($expires_epoch|tonumber),consumed_at:null,completed_at:null,note:null,runtime_selection:null,verification:$verification}' \
    | jit_atomic_write "$admission_file"
  unset JIT_API_TOKEN
  if (( JSON_OUTPUT == 1 )); then jq . "$admission_file"; else success "Prepared verified admission: $admission_id"; fi
}

jit_load_admission() {
  local admission_id="$1" file
  [[ "$admission_id" =~ ^[0-9a-f]{64}$ ]] || die "Invalid admission ID."
  file="$(jit_admission_file "$admission_id")"
  [[ -r "$file" ]] || die "Unknown admission: $admission_id"
  jq -e --argjson schema "$JIT_SCHEMA_VERSION" --arg id "$admission_id" '.schema_version==$schema and .id==$id and (.status|type=="string")' "$file" >/dev/null || die "Invalid admission state: $file"
  JIT_ADMISSION_FILE="$file"
  JIT_ADMISSION_ID="$admission_id"
  JIT_ADMISSION_PROJECT="$(jq -r .project "$file")"
  JIT_ADMISSION_REPOSITORY="$(jq -r .repository "$file")"
  JIT_ADMISSION_RUN_ID="$(jq -r .run_id "$file")"
  JIT_ADMISSION_RUN_ATTEMPT="$(jq -r .run_attempt "$file")"
  JIT_ADMISSION_LABEL="$(jq -r .label "$file")"
  JIT_ADMISSION_RUNTIME_HELPER="$(jq -r '.runtime_selection.helper // empty' "$file")"
  JIT_ADMISSION_RUNTIME_MANIFEST="$(jq -r '.runtime_selection.manifest // empty' "$file")"
  JIT_ADMISSION_RUNTIME_HELPER_SHA256="$(jq -r '.runtime_selection.helper_sha256 // empty' "$file")"
  JIT_ADMISSION_RUNTIME_CONTROLLER_REVISION="$(jq -r '.runtime_selection.controller_revision // empty' "$file")"
  JIT_ADMISSION_RUNTIME_CONTROLLER_DIGEST="$(jq -r '.runtime_selection.controller_digest // empty' "$file")"
  JIT_ADMISSION_RUNTIME_CONTROLLER_MANIFEST="$(jq -c '.runtime_selection.controller_manifest // empty' "$file")"
  JIT_ADMISSION_RUNTIME_CONTROLLER_MANIFEST_SHA256="$(jq -r '.runtime_selection.controller_manifest_sha256 // empty' "$file")"
  jit_load_policy "$JIT_ADMISSION_PROJECT"
  [[ "$JIT_ADMISSION_REPOSITORY" == "$JIT_POLICY_REPOSITORY" ]] || die "Admission policy repository drift detected."
}

jit_persist_admission_runtime_selection() {
  local helper="$1" manifest="$2" helper_sha256="$3" controller_revision="$4" controller_digest="$5" controller_manifest="${6:-}" controller_manifest_sha256="${7:-}"
  [[ -n "$controller_manifest" ]] || controller_manifest="$(jit_runtime_controller_manifest_json)"
  [[ -n "$controller_manifest_sha256" ]] || controller_manifest_sha256="$(printf '%s' "$controller_manifest" | sha256sum | awk '{print $1}')"
  jq --arg helper "$helper" --arg manifest "$manifest" --arg helper_sha256 "$helper_sha256" \
    --arg controller_revision "$controller_revision" --arg controller_digest "$controller_digest" --arg controller_manifest_sha256 "$controller_manifest_sha256" --argjson controller_manifest "$controller_manifest" --arg now "$(utc_now)" '
    .runtime_selection={helper:$helper,manifest:$manifest,helper_sha256:$helper_sha256,controller_revision:$controller_revision,controller_digest:$controller_digest,controller_manifest:$controller_manifest,controller_manifest_sha256:$controller_manifest_sha256,staged_at:$now} |
    .updated_at=$now
  ' "$JIT_ADMISSION_FILE" | jit_atomic_write "$JIT_ADMISSION_FILE"
  JIT_ADMISSION_RUNTIME_HELPER="$helper"
  JIT_ADMISSION_RUNTIME_MANIFEST="$manifest"
  JIT_ADMISSION_RUNTIME_HELPER_SHA256="$helper_sha256"
  JIT_ADMISSION_RUNTIME_CONTROLLER_REVISION="$controller_revision"
  JIT_ADMISSION_RUNTIME_CONTROLLER_DIGEST="$controller_digest"
  JIT_ADMISSION_RUNTIME_CONTROLLER_MANIFEST="$controller_manifest"
  JIT_ADMISSION_RUNTIME_CONTROLLER_MANIFEST_SHA256="$controller_manifest_sha256"
}

jit_admission_worker_state_is_live() {
  local state_file="$1" admission_id="${2:-}" status
  [[ -n "$admission_id" ]] || admission_id="$(basename -- "$(dirname -- "$state_file")")"
  jit_validate_worker_journal "$state_file" "$admission_id" || die "Worker journal is malformed or deterministically invalid; recovery is required before another launch: $state_file"
  status="$(jq -r '.status' "$state_file")"
  [[ "$status" =~ ^(allocated|creating|boundary-ready|registration-requested|registered|running|cleanup-pending)$ ]]
}

jit_validate_worker_journal() {
  local state_file="$1" expected_admission="$2" expected_worker
  [[ -r "$state_file" && "$expected_admission" =~ ^[0-9a-f]{64}$ ]] || return 1
  expected_worker="$(basename -- "$state_file" .json)"
  [[ "$expected_worker" =~ ^worker-[0-9]{3,}$ ]] || return 1
  jq -e --argjson schema "$JIT_SCHEMA_VERSION" --arg admission "$expected_admission" --arg worker "$expected_worker" '
    .schema_version==$schema and .admission_id==$admission and .worker_id==$worker and
    (.sequence|type=="number" and floor==. and .>=1) and
    (.status|type=="string" and test("^(allocated|creating|boundary-ready|registration-requested|registered|running|cancelled|cleanup-pending|cleaned|finished|failed)$")) and
    (.controller_children|type=="array" and all(.[];
      (.pid|type=="number" and floor==. and .>=1) and
      (.boot_id|type=="string" and length>0) and
      (.start_ticks|type=="number" and floor==. and .>=1))) and
    ((.sandbox_main_pid==null and .sandbox_main_boot_id==null and .sandbox_main_start_ticks==null) or
      ((.sandbox_main_pid|type=="number" and floor==. and .>=1) and
       (.sandbox_main_boot_id|type=="string" and length>0) and
       (.sandbox_main_start_ticks|type=="number" and floor==. and .>=1))) and
    ((.sandbox_slirp_pid==null and .sandbox_slirp_boot_id==null and .sandbox_slirp_start_ticks==null) or
      ((.sandbox_slirp_pid|type=="number" and floor==. and .>=1) and
       (.sandbox_slirp_boot_id|type=="string" and length>0) and
       (.sandbox_slirp_start_ticks|type=="number" and floor==. and .>=1)))
  ' "$state_file" >/dev/null 2>&1 || return 1
  (jit_validate_worker_identity_state "$state_file" >/dev/null 2>&1)
}

jit_validate_all_worker_journals() {
  local state_dir state_file admission_id
  [[ -d "$JIT_WORKERS_DIR" ]] || return 0
  shopt -s nullglob
  for state_dir in "$JIT_WORKERS_DIR"/*; do
    [[ -d "$state_dir" ]] || continue
    admission_id="$(basename -- "$state_dir")"
    [[ "$admission_id" =~ ^[0-9a-f]{64}$ && -r "$(jit_admission_file "$admission_id")" ]] || {
      shopt -u nullglob
      return 1
    }
    for state_file in "$state_dir"/worker-*.json; do
      jit_validate_worker_journal "$state_file" "$admission_id" || {
        shopt -u nullglob
        return 1
      }
    done
  done
  shopt -u nullglob
}

jit_admission_has_live_workers() {
  local admission_id="$1" state_dir state_file
  state_dir="$(jit_worker_state_dir "$admission_id")"
  [[ -d "$state_dir" ]] || return 1
  shopt -s nullglob
  for state_file in "$state_dir"/worker-*.json; do
    if jit_admission_worker_state_is_live "$state_file" "$admission_id"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

jit_admission_state_blocks_new_launch() {
  local admission_file="$1" admission_id status
  [[ -r "$admission_file" ]] || return 1
  admission_id="$(jq -r '.id // empty' "$admission_file" 2>/dev/null || true)"
  status="$(jq -r '.status // empty' "$admission_file" 2>/dev/null || true)"
  [[ "$status" =~ ^(creating|registration-requested|registered|running|cancelled-with-live-workers|cleanup-pending)$ ]] && return 0
  # Worker journals remain authoritative even if a controller persisted a
  # terminal admission status immediately before it crashed.
  jit_admission_has_live_workers "$admission_id"
}

jit_validate_admission_lease_state() {
  local admission_file="$1" expected_id
  expected_id="$(basename -- "$admission_file" .json)"
  jq -e --argjson schema "$JIT_SCHEMA_VERSION" --arg expected_id "$expected_id" '
    .schema_version==$schema and .id==$expected_id and (.id|type=="string" and test("^[0-9a-f]{64}$")) and
    (.project|type=="string" and test("^[a-z0-9][a-z0-9-]*$")) and
    (.repository|type=="string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
    (.label|type=="string" and test("^[a-z0-9][a-z0-9-]*$")) and
    (.status|type=="string" and test("^(prepared|creating|registration-requested|registered|running|cancelled|cancelled-with-live-workers|cleanup-pending|completed|failed|cleaned)$"))
  ' "$admission_file" >/dev/null 2>&1
}

jit_admission_has_deterministic_units() {
  local admission_id="$1" prefix units
  prefix="ghrctl-jit-${admission_id:0:12}-"
  if jit_test_backend_enabled; then
    [[ -n "${GHRCTL_JIT_FAKE_UNITS_DIR:-}" && -d "$GHRCTL_JIT_FAKE_UNITS_DIR" ]] || return 1
    compgen -G "${GHRCTL_JIT_FAKE_UNITS_DIR}/${prefix}*.service" >/dev/null
    return
  fi
  units="$(systemctl list-units --all --plain --no-legend "${prefix}*.service" 2>/dev/null)" || return 0
  [[ -n "$units" ]]
}

jit_admission_has_runtime_paths() {
  local admission_id="$1" boundary_dir runtime_path runtime_root
  boundary_dir="${JIT_BOUNDARY_ROOT}/${admission_id}"
  if [[ -d "$boundary_dir" ]] && find "$boundary_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    return 0
  fi
  runtime_root="$JIT_WORKER_RUNTIME_ROOT"
  jit_test_backend_enabled && runtime_root="${JIT_DATA_DIR}/worker-runtime"
  shopt -s nullglob
  for runtime_path in "${runtime_root}/${admission_id:0:12}-"*; do
    shopt -u nullglob
    return 0
  done
  shopt -u nullglob
  return 1
}

jit_admission_has_exact_label_runner() {
  local repository="$1" label="$2" runners
  runners="$(jit_api_collection "repos/${repository}/actions/runners" runners)"
  jq -e 'all(.runners[]; (.labels|type=="array") and all(.labels[]; (.name|type=="string")))' >/dev/null <<<"$runners" \
    || die "GitHub returned malformed runner labels while reconciling a stale admission."
  jq -e --arg label "$label" '.runners | any(.labels | any(.name==$label))' >/dev/null <<<"$runners"
}

jit_reconcile_inactive_admission() {
  local admission_file="$1" admission_id repository label
  admission_id="$(jq -r .id "$admission_file")"
  repository="$(jq -r .repository "$admission_file")"
  label="$(jq -r .label "$admission_file")"
  jit_admission_has_live_workers "$admission_id" && return 1
  jit_admission_has_deterministic_units "$admission_id" && return 1
  jit_admission_has_runtime_paths "$admission_id" && return 1
  jit_admission_has_exact_label_runner "$repository" "$label" && return 1
  return 0
}

jit_active_admission_lease_is_valid() {
  local lease="$JIT_ACTIVE_ADMISSION_LEASE_FILE"
  [[ -r "$lease" ]] || return 1
  jq -e --argjson schema "$JIT_SCHEMA_VERSION" '
    .schema_version==$schema and (.state=="active" or .state=="released") and (.admission_id|type=="string" and test("^[0-9a-f]{64}$")) and
    (.project|type=="string" and length>0) and (.repository|type=="string" and length>2) and
    (.pid|type=="number" and floor==. and .>=1) and (.boot_id|type=="string" and length>0) and
    (.start_ticks|type=="number" and floor==. and .>=1)
  ' "$lease" >/dev/null 2>&1
}

jit_write_active_admission_lease() {
  local admission_id="$1" project="$2" repository="$3" now pid boot_id start_ticks
  pid="${BASHPID:-$$}"
  boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)"
  start_ticks="$(jit_process_start_ticks "$pid" 2>/dev/null || printf 1)"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$start_ticks" =~ ^[1-9][0-9]*$ ]] || die "Unable to journal the active admission lease owner."
  now="$(utc_now)"
  jq -n --argjson schema "$JIT_SCHEMA_VERSION" --arg state active --arg admission_id "$admission_id" --arg project "$project" --arg repository "$repository" \
    --arg pid "$pid" --arg boot_id "$boot_id" --arg start_ticks "$start_ticks" --arg acquired_at "$now" --arg updated_at "$now" \
    '{schema_version:$schema,state:$state,admission_id:$admission_id,project:$project,repository:$repository,pid:($pid|tonumber),boot_id:$boot_id,start_ticks:($start_ticks|tonumber),acquired_at:$acquired_at,updated_at:$updated_at}' \
    | jit_atomic_write "$JIT_ACTIVE_ADMISSION_LEASE_FILE"
}

jit_release_active_admission_lease() {
  local admission_id="${1:-}" now current
  [[ -r "$JIT_ACTIVE_ADMISSION_LEASE_FILE" ]] || return 0
  current="$(jq -r '.admission_id // empty' "$JIT_ACTIVE_ADMISSION_LEASE_FILE" 2>/dev/null || true)"
  [[ -z "$admission_id" || "$current" == "$admission_id" ]] || return 0
  now="$(utc_now)"
  jq --arg state released --arg now "$now" '.state=$state | .released_at=$now | .updated_at=$now' "$JIT_ACTIVE_ADMISSION_LEASE_FILE" | jit_atomic_write "$JIT_ACTIVE_ADMISSION_LEASE_FILE"
}

jit_assert_active_admission_available() {
  local requested_id="$1" state_file state_id lease_id lease_state found=0
  jit_validate_all_worker_journals || die "A worker journal is malformed, orphaned, or deterministically invalid; recovery is required before another launch."
  if [[ -e "$JIT_ACTIVE_ADMISSION_LEASE_FILE" ]]; then
    jit_active_admission_lease_is_valid || die "The active-admission lease is malformed; recovery is required before another launch."
    lease_state="$(jq -r .state "$JIT_ACTIVE_ADMISSION_LEASE_FILE")"
    lease_id="$(jq -r .admission_id "$JIT_ACTIVE_ADMISSION_LEASE_FILE")"
    if [[ "$lease_state" == active && "$lease_id" != "$requested_id" ]]; then
      [[ -r "$(jit_admission_file "$lease_id")" ]] || die "Active-admission lease owner state is missing; recovery is required before another launch."
      jit_validate_admission_lease_state "$(jit_admission_file "$lease_id")" \
        || die "Active-admission lease owner journal is malformed; recovery is required before another launch."
      if jit_admission_state_blocks_new_launch "$(jit_admission_file "$lease_id")"; then
        die "Another admission is active ($lease_id); resume or clean it before launching $requested_id."
      fi
      jit_reconcile_inactive_admission "$(jit_admission_file "$lease_id")" \
        || die "The stale admission still owns a deterministic unit, runtime path, or exact-label remote runner: $lease_id"
      # A released or terminal lease is retained as durable history and can be
      # replaced by the next owner under the global CLI lock.
      jit_release_active_admission_lease "$lease_id"
    fi
  fi
  shopt -s nullglob
  for state_file in "$JIT_ADMISSIONS_DIR"/*.json; do
    jit_validate_admission_lease_state "$state_file" || die "Admission journal is malformed; recovery is required before another launch: $state_file"
    state_id="$(jq -r '.id // empty' "$state_file" 2>/dev/null || true)"
    [[ -n "$state_id" && "$state_id" != "$requested_id" ]] || continue
    if jit_admission_state_blocks_new_launch "$state_file"; then
      found=1
      break
    fi
    jit_reconcile_inactive_admission "$state_file" || {
      found=1
      break
    }
  done
  shopt -u nullglob
  (( found == 0 )) || die "Another admission has live or cleanup-pending workers; launch is fail-closed until it is recovered."
}

jit_acquire_active_admission_lease() {
  local admission_id="$1" project="$2" repository="$3"
  jit_assert_active_admission_available "$admission_id"
  jit_write_active_admission_lease "$admission_id" "$project" "$repository"
}

jit_set_admission_status() {
  local status="$1" note="${2:-}"
  jq --arg status "$status" --arg note "$note" --arg now "$(utc_now)" '
    .status=$status |
    .note=(if $note=="" then null else $note end) |
    (if $status=="running" and .consumed_at==null then .consumed_at=$now else . end) |
    (if ($status=="completed" or $status=="failed" or $status=="cancelled" or $status=="cleaned") then .completed_at=$now else . end)
  ' "$JIT_ADMISSION_FILE" | jit_atomic_write "$JIT_ADMISSION_FILE"
}

jit_get_run_jobs() {
  jit_api_collection "repos/${JIT_ADMISSION_REPOSITORY}/actions/runs/${JIT_ADMISSION_RUN_ID}/attempts/${JIT_ADMISSION_RUN_ATTEMPT}/jobs" jobs
}

jit_target_jobs() {
  local jobs_json="$1" invalid_count
  invalid_count="$(jq --arg label "$JIT_ADMISSION_LABEL" '[.jobs[] | select((.labels // []) | index($label)) | select(((.labels // []) | sort) != [$label])] | length' <<<"$jobs_json")"
  [[ "$invalid_count" == 0 ]] || die "A data-plane job requested reusable/default labels in addition to the unique admission label."
  jq --arg label "$JIT_ADMISSION_LABEL" '[.jobs[] | select(((.labels // []) | sort) == [$label]) | {id,name,status,conclusion,runner_id,runner_name,started_at,completed_at}]' <<<"$jobs_json"
}
