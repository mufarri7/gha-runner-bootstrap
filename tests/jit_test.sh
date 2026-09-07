# shellcheck shell=bash

export GHRCTL_TEST_MODE=1
export GHRCTL_JIT_HOST_BACKEND=fake
export GHRCTL_JIT_FAKE_RUNNER_ROOT="$ROOT/tests/fixtures/fake-actions-runner"
export GHRCTL_JIT_FAKE_SERVICES_DIR="$TMP/fake-services"
export GHRCTL_JIT_FAKE_UNITS_DIR="$TMP/fake-jit-units"
mkdir -p "$GHRCTL_JIT_FAKE_SERVICES_DIR" "$GHRCTL_JIT_FAKE_UNITS_DIR"
JIT_TEST_REMOTE_RUNNERS_FILE="$TMP/fake-remote-runners.json"
printf '[]\n' >"$JIT_TEST_REMOTE_RUNNERS_FILE"

JIT_TEST_RUN_ID=987654321
JIT_TEST_ATTEMPT=2
JIT_TEST_PR=113
JIT_TEST_BASE=1111111111111111111111111111111111111111
JIT_TEST_HEAD=2222222222222222222222222222222222222222
JIT_TEST_MERGE=3333333333333333333333333333333333333333
JIT_TEST_TREE=4444444444444444444444444444444444444444
JIT_TEST_LABEL="mazaya-admission-${JIT_TEST_RUN_ID}-${JIT_TEST_ATTEMPT}"
JIT_TEST_CASE=valid
JIT_TEST_CREATED="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
JIT_TEST_JIT_SECRET='jit-secret-material-123456'

jit_test_encoded_config() {
  local mode="${1:-valid}" runner_json runner_encoded credentials_encoded rsa_encoded
  case "$mode" in
    valid) runner_json='{"DisableUpdate":true,"AgentName":"fixture"}' ;;
    missing) runner_json='{"AgentName":"fixture"}' ;;
    false) runner_json='{"DisableUpdate":false,"AgentName":"fixture"}' ;;
    string) runner_json='{"DisableUpdate":"true","AgentName":"fixture"}' ;;
    null) runner_json='{"DisableUpdate":null,"AgentName":"fixture"}' ;;
    malformed) runner_json='{"DisableUpdate":true' ;;
    mixed-case) runner_json='{"DisableUpdate":true,"disableUpdate":false,"AgentName":"fixture"}' ;;
    *) return 2 ;;
  esac
  runner_encoded="$(printf '%s' "$runner_json" | base64 -w0)"
  credentials_encoded="$(printf '{"token":"%s"}' "$JIT_TEST_JIT_SECRET" | base64 -w0)"
  rsa_encoded="$(printf '{"privateKey":"%s-rsa"}' "$JIT_TEST_JIT_SECRET" | base64 -w0)"
  jq -cn --arg runner "$runner_encoded" --arg credentials "$credentials_encoded" --arg rsa "$rsa_encoded" \
    '{".runner":$runner,".credentials":$credentials,".credentials_rsaparams":$rsa}' | base64 -w0
}

JIT_TEST_ENCODED_CONFIG="$(jit_test_encoded_config valid)"
JIT_TEST_SECRET_BASE64="$(printf '%s' "$JIT_TEST_JIT_SECRET" | base64 -w0)"
JIT_TEST_CREDENTIALS_BLOB="$(printf '{"token":"%s"}' "$JIT_TEST_JIT_SECRET" | base64 -w0)"
JIT_TEST_RSA_BLOB="$(printf '{"privateKey":"%s-rsa"}' "$JIT_TEST_JIT_SECRET" | base64 -w0)"
JIT_TEST_BOUNDARY="$(jq -cn --arg image "ghcr.io/mufarri7/mazaya-ci@sha256:$(printf 'a%.0s' {1..64})" \
  '{schema_version:1,job_container_required:true,job_container_images:[$image],service_container_images:[],container_options:[],container_volumes:[]}')"

jit_validate_workload_boundary_json "$JIT_TEST_BOUNDARY" || fail "valid workload-boundary attestation was rejected"
if jit_validate_workload_boundary_json "$(jq '.job_container_required=false' <<<"$JIT_TEST_BOUNDARY")"; then fail "host-mode workload attestation was accepted"; fi
if jit_validate_workload_boundary_json "$(jq '.job_container_images=["ghcr.io/mufarri7/mazaya-ci:latest"]' <<<"$JIT_TEST_BOUNDARY")"; then fail "mutable workload image was accepted"; fi
if jit_validate_workload_boundary_json "$(jq '.container_options=["--pid=host"]' <<<"$JIT_TEST_BOUNDARY")"; then fail "custom container options were accepted"; fi
if jit_validate_workload_boundary_json "$(jq '.container_volumes=["/run/ghrctl-jit:/runtime"]' <<<"$JIT_TEST_BOUNDARY")"; then fail "custom container volumes were accepted"; fi

TEST_POLICY="$TMP/jit-policy.json"
jq -e '.project=="mazaya-backend" and .persistent_project=="mazaya-backend" and (.forbidden_online_labels | index("mazaya-backend-ci"))!=null' "$ROOT/examples/jit-policy.mazaya.json" >/dev/null \
  || fail "Mazaya policy does not match the managed project and repository label"
jq '.project="mazaya-test" | .repository="owner/repo" | .persistent_project="fixture" | .poll_seconds=1 | .max_replacements=10' "$ROOT/examples/jit-policy.mazaya.json" >"$TEST_POLICY"
jit_init_dirs
jit_validate_policy_json "$TEST_POLICY"
jit_validate_policy_project_binding "$TEST_POLICY"
INVALID_POOL_POLICY="$TMP/jit-policy-overlap.json"
jq '.subordinate_id_pool.start=55000 | .subordinate_id_pool.end=120535' "$TEST_POLICY" >"$INVALID_POOL_POLICY"
if (jit_validate_policy_json "$INVALID_POOL_POLICY" >/dev/null 2>&1); then fail "overlapping configured real/subordinate ID pools were accepted"; fi
jq . "$TEST_POLICY" | jit_atomic_write "$(jit_policy_file mazaya-test)"
jit_load_policy mazaya-test

# Force the production validator without invoking any production mutation.
(
  GHRCTL_JIT_HOST_BACKEND=production
  production_admission=abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890
  production_worker=worker-001
  production_runtime="${JIT_WORKER_RUNTIME_ROOT}/$(jit_worker_runtime_id "$production_admission" "$production_worker")"
  jit_validate_worker_runtime_socket "$production_runtime" "$production_runtime/docker.sock" "$production_admission" "$production_worker" \
    || fail "production runtime validator rejected the deterministic runtime identity"
  if jit_validate_worker_runtime_socket "${JIT_WORKER_RUNTIME_ROOT}/abcdef123456-002" "${JIT_WORKER_RUNTIME_ROOT}/abcdef123456-002/docker.sock" "$production_admission" "$production_worker"; then
    fail "production runtime validator accepted a deterministic sibling identity"
  fi
  if jit_validate_worker_runtime_socket "${JIT_WORKER_RUNTIME_ROOT}/abcdef1234560001" "${JIT_WORKER_RUNTIME_ROOT}/abcdef1234560001/docker.sock" "$production_admission" "$production_worker"; then
    fail "production runtime validator accepted the obsolete runtime identity shape"
  fi
)

SLIRP_CAPABILITY_INVENTORY=$'NAME NUMBER\ncap_setpcap 8\ncap_net_bind_service 10\ncap_net_admin 12\ncap_sys_ptrace 19\ncap_sys_admin 21'
jit_validate_slirp_startup_capability_inventory "$SLIRP_CAPABILITY_INVENTORY" 40 \
  || fail "exact slirp startup capability inventory was rejected"
if jit_validate_slirp_startup_capability_inventory "${SLIRP_CAPABILITY_INVENTORY%$'\ncap_sys_admin 21'}" 40; then
  fail "incomplete slirp startup capability inventory was accepted"
fi
if jit_validate_slirp_startup_capability_inventory "${SLIRP_CAPABILITY_INVENTORY}"$'\ncap_sys_chroot 18' 40; then
  fail "overprivileged slirp startup capability inventory was accepted"
fi
SLIRP_SAFE_STATUS="$TMP/slirp-safe.status"
SLIRP_UNSAFE_STATUS="$TMP/slirp-unsafe.status"
{
  printf 'CapInh:\t%s\n' "$JIT_SLIRP_RUNTIME_CAP_MASK"
  printf 'CapPrm:\t%s\n' "$JIT_SLIRP_RUNTIME_CAP_MASK"
  printf 'CapEff:\t%s\n' "$JIT_SLIRP_RUNTIME_CAP_MASK"
  printf 'CapBnd:\t%s\n' "$JIT_SLIRP_RUNTIME_CAP_MASK"
  printf 'CapAmb:\t%s\n' "$JIT_EMPTY_CAP_MASK"
} >"$SLIRP_SAFE_STATUS"
jit_validate_slirp_capability_status "$SLIRP_SAFE_STATUS" || fail "minimal slirp runtime capabilities were rejected"
sed "s/^CapEff:.*/CapEff:\t${JIT_SLIRP_STARTUP_CAP_MASK}/" "$SLIRP_SAFE_STATUS" >"$SLIRP_UNSAFE_STATUS"
if jit_validate_slirp_capability_status "$SLIRP_UNSAFE_STATUS"; then fail "slirp runtime retained startup capabilities"; fi

jit_validate_jit_config_disable_update "$JIT_TEST_ENCODED_CONFIG" \
  || fail "valid DisableUpdate=true JIT configuration was rejected"
for invalid_jit_mode in missing false string null malformed mixed-case; do
  invalid_jit_config="$(jit_test_encoded_config "$invalid_jit_mode")"
  validation_output="$TMP/jit-config-${invalid_jit_mode}.output"
  if jit_validate_jit_config_disable_update "$invalid_jit_config" >"$validation_output" 2>&1; then
    fail "unsafe JIT DisableUpdate configuration was accepted: $invalid_jit_mode"
  fi
  if grep -F "$JIT_TEST_JIT_SECRET" "$validation_output" >/dev/null 2>&1 || grep -F "$JIT_TEST_SECRET_BASE64" "$validation_output" >/dev/null 2>&1 || \
     grep -F "$JIT_TEST_CREDENTIALS_BLOB" "$validation_output" >/dev/null 2>&1 || grep -F "$JIT_TEST_RSA_BLOB" "$validation_output" >/dev/null 2>&1; then
    fail "JIT configuration validator leaked credential material: $invalid_jit_mode"
  fi
done
if printf '%s' "$JIT_TEST_ENCODED_CONFIG" | python3 "$ROOT/libexec/validate_jit_config.py" invalid >/dev/null 2>&1; then
  fail "JIT configuration validator accepted an invalid size contract"
fi
if jit_validate_jit_config_disable_update "${JIT_TEST_ENCODED_CONFIG%?}"; then
  fail "truncated JIT configuration was accepted"
fi

jit_validate_pinned_runner_release "$JIT_PINNED_RUNNER_VERSION" x64 \
  "actions-runner-linux-x64-${JIT_PINNED_RUNNER_VERSION}.tar.gz" \
  "https://github.com/actions/runner/releases/download/v${JIT_PINNED_RUNNER_VERSION}/actions-runner-linux-x64-${JIT_PINNED_RUNNER_VERSION}.tar.gz" \
  "sha256:${JIT_PINNED_RUNNER_X64_SHA256}" || fail "reviewed JIT runner release identity was rejected"
if jit_validate_pinned_runner_release 2.336.0 x64 "actions-runner-linux-x64-2.336.0.tar.gz" \
  "https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-linux-x64-2.336.0.tar.gz" \
  "sha256:${JIT_PINNED_RUNNER_X64_SHA256}"; then fail "JIT runner version drift was accepted"; fi
if jit_validate_pinned_runner_release "$JIT_PINNED_RUNNER_VERSION" x64 \
  "actions-runner-linux-x64-${JIT_PINNED_RUNNER_VERSION}.tar.gz" \
  "https://github.com/actions/runner/releases/download/v${JIT_PINNED_RUNNER_VERSION}/actions-runner-linux-x64-${JIT_PINNED_RUNNER_VERSION}.tar.gz" \
  "sha256:$(printf '0%.0s' {1..64})"; then fail "JIT runner digest drift was accepted"; fi
drift_runner_seed="$TMP/drift-actions-runner"
cp -a "$ROOT/tests/fixtures/fake-actions-runner" "$drift_runner_seed"
sed -i 's/2\.337\.0/2.336.0/' "$drift_runner_seed/bin/Runner.Listener"
if jit_verify_runner_seed_version "$drift_runner_seed" "$JIT_PINNED_RUNNER_VERSION"; then
  fail "JIT runner listener version drift was accepted"
fi

JIT_TEST_EVIDENCE_DIR="$TMP/evidence"
JIT_TEST_EVIDENCE_ARCHIVE="$TMP/evidence.zip"
JIT_TEST_BAD_EVIDENCE_ARCHIVE="$TMP/evidence-bad.zip"
JIT_TEST_UNSAFE_BOUNDARY_DIR="$TMP/evidence-unsafe-boundary"
JIT_TEST_UNSAFE_BOUNDARY_ARCHIVE="$TMP/evidence-unsafe-boundary.zip"
JIT_TEST_UNSAFE_EVIDENCE_DIR="$TMP/evidence-unsafe"
JIT_TEST_UNSAFE_EVIDENCE_ARCHIVE="$TMP/evidence-unsafe.zip"
JIT_TEST_OVERSIZED_EVIDENCE_DIR="$TMP/evidence-oversized"
JIT_TEST_OVERSIZED_EVIDENCE_ARCHIVE="$TMP/evidence-oversized.zip"
mkdir -p "$JIT_TEST_EVIDENCE_DIR" "$JIT_TEST_UNSAFE_BOUNDARY_DIR"
jq -n --arg repository "$JIT_POLICY_REPOSITORY" --arg workflow_path "$JIT_POLICY_WORKFLOW_PATH" --arg workflow_name "$JIT_POLICY_WORKFLOW_NAME" --arg job_name "$JIT_POLICY_ADMISSION_JOB" \
  --argjson workflow_id 7654 --argjson job_id 9001 --argjson run_id "$JIT_TEST_RUN_ID" --argjson run_attempt "$JIT_TEST_ATTEMPT" --argjson pr_number "$JIT_TEST_PR" \
  --arg base "$JIT_TEST_BASE" --arg head "$JIT_TEST_HEAD" --arg merge "$JIT_TEST_MERGE" --arg tree "$JIT_TEST_TREE" --arg label "$JIT_TEST_LABEL" --arg generated_at "$JIT_TEST_CREATED" --argjson workload_boundary "$JIT_TEST_BOUNDARY" \
  '{schema_version:2,repository:$repository,workflow_path:$workflow_path,workflow_name:$workflow_name,workflow_id:$workflow_id,run_id:$run_id,run_attempt:$run_attempt,admission_job_id:$job_id,admission_job_name:$job_name,pr_number:$pr_number,base_sha:$base,head_sha:$head,merge_sha:$merge,tree_sha:$tree,label:$label,generated_at:$generated_at,workload_boundary:$workload_boundary}' \
  >"$JIT_TEST_EVIDENCE_DIR/admission.json"
(cd "$JIT_TEST_EVIDENCE_DIR" && python3 -m zipfile -c "$JIT_TEST_EVIDENCE_ARCHIVE" admission.json)
jq '.workload_boundary.job_container_required=false' "$JIT_TEST_EVIDENCE_DIR/admission.json" >"$JIT_TEST_UNSAFE_BOUNDARY_DIR/admission.json"
(cd "$JIT_TEST_UNSAFE_BOUNDARY_DIR" && python3 -m zipfile -c "$JIT_TEST_UNSAFE_BOUNDARY_ARCHIVE" admission.json)
jq '.head_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$JIT_TEST_EVIDENCE_DIR/admission.json" >"$JIT_TEST_EVIDENCE_DIR/admission-bad.json"
mv "$JIT_TEST_EVIDENCE_DIR/admission-bad.json" "$JIT_TEST_EVIDENCE_DIR/admission.json"
(cd "$JIT_TEST_EVIDENCE_DIR" && python3 -m zipfile -c "$JIT_TEST_BAD_EVIDENCE_ARCHIVE" admission.json)
jq '.head_sha=$head' --arg head "$JIT_TEST_HEAD" "$JIT_TEST_EVIDENCE_DIR/admission.json" >"$JIT_TEST_EVIDENCE_DIR/admission-restored.json"
mv "$JIT_TEST_EVIDENCE_DIR/admission-restored.json" "$JIT_TEST_EVIDENCE_DIR/admission.json"
mkdir -p "$JIT_TEST_UNSAFE_EVIDENCE_DIR" "$JIT_TEST_OVERSIZED_EVIDENCE_DIR"
cp "$JIT_TEST_EVIDENCE_DIR/admission.json" "$JIT_TEST_UNSAFE_EVIDENCE_DIR/admission.json"
printf 'unexpected\n' >"$JIT_TEST_UNSAFE_EVIDENCE_DIR/extra.txt"
(cd "$JIT_TEST_UNSAFE_EVIDENCE_DIR" && python3 -m zipfile -c "$JIT_TEST_UNSAFE_EVIDENCE_ARCHIVE" admission.json extra.txt)
dd if=/dev/zero of="$JIT_TEST_OVERSIZED_EVIDENCE_DIR/admission.json" bs=17000 count=1 status=none
(cd "$JIT_TEST_OVERSIZED_EVIDENCE_DIR" && python3 -m zipfile -c "$JIT_TEST_OVERSIZED_EVIDENCE_ARCHIVE" admission.json)
JIT_TEST_EVIDENCE_DIGEST="sha256:$(sha256sum "$JIT_TEST_EVIDENCE_ARCHIVE" | awk '{print $1}')"
JIT_TEST_BAD_EVIDENCE_DIGEST="sha256:$(sha256sum "$JIT_TEST_BAD_EVIDENCE_ARCHIVE" | awk '{print $1}')"
JIT_TEST_UNSAFE_BOUNDARY_DIGEST="sha256:$(sha256sum "$JIT_TEST_UNSAFE_BOUNDARY_ARCHIVE" | awk '{print $1}')"
JIT_TEST_UNSAFE_EVIDENCE_DIGEST="sha256:$(sha256sum "$JIT_TEST_UNSAFE_EVIDENCE_ARCHIVE" | awk '{print $1}')"
JIT_TEST_OVERSIZED_EVIDENCE_DIGEST="sha256:$(sha256sum "$JIT_TEST_OVERSIZED_EVIDENCE_ARCHIVE" | awk '{print $1}')"

jit_download_api() {
  local _endpoint="$1" destination="$2"
  case "$JIT_TEST_CASE" in
    evidence-mismatch) cp "$JIT_TEST_BAD_EVIDENCE_ARCHIVE" "$destination" ;;
    unsafe-workload-boundary) cp "$JIT_TEST_UNSAFE_BOUNDARY_ARCHIVE" "$destination" ;;
    unsafe-evidence) cp "$JIT_TEST_UNSAFE_EVIDENCE_ARCHIVE" "$destination" ;;
    oversized-evidence) cp "$JIT_TEST_OVERSIZED_EVIDENCE_ARCHIVE" "$destination" ;;
    *) cp "$JIT_TEST_EVIDENCE_ARCHIVE" "$destination" ;;
  esac
}

jit_configure_auth() {
  JIT_AUTH_MODE=test
  JIT_API_TOKEN=test-token
  JIT_API_TOKEN_EXPIRES_EPOCH=0
}

jit_api() {
  local method="$1" endpoint="$2" body="${3:-}" created_at repository event attempt head_branch head_sha path actor triggering_actor job_status job_conclusion controller_finished=0 controller_min worker_state_dir page
  local runner_name runner_label runner_id remote temporary state_file intent_found=0
  local artifact_name artifact_digest artifact_archive artifact_size artifact_json
  created_at="$JIT_TEST_CREATED"
  repository="$JIT_POLICY_REPOSITORY"; event=workflow_dispatch; attempt="$JIT_TEST_ATTEMPT"; head_branch=main; head_sha="$JIT_TEST_BASE"
  path="$JIT_POLICY_WORKFLOW_PATH"; actor=mufarri7; triggering_actor=mufarri7; job_status=completed; job_conclusion=success
  artifact_name="${JIT_POLICY_EVIDENCE_ARTIFACT_PREFIX}${JIT_TEST_RUN_ID}-${JIT_TEST_ATTEMPT}-9001"
  artifact_archive="$JIT_TEST_EVIDENCE_ARCHIVE"; artifact_digest="$JIT_TEST_EVIDENCE_DIGEST"
  if [[ "$JIT_TEST_CASE" == evidence-mismatch ]]; then artifact_archive="$JIT_TEST_BAD_EVIDENCE_ARCHIVE"; artifact_digest="$JIT_TEST_BAD_EVIDENCE_DIGEST"; fi
  if [[ "$JIT_TEST_CASE" == unsafe-workload-boundary ]]; then artifact_archive="$JIT_TEST_UNSAFE_BOUNDARY_ARCHIVE"; artifact_digest="$JIT_TEST_UNSAFE_BOUNDARY_DIGEST"; fi
  if [[ "$JIT_TEST_CASE" == unsafe-evidence ]]; then artifact_archive="$JIT_TEST_UNSAFE_EVIDENCE_ARCHIVE"; artifact_digest="$JIT_TEST_UNSAFE_EVIDENCE_DIGEST"; fi
  if [[ "$JIT_TEST_CASE" == oversized-evidence ]]; then artifact_archive="$JIT_TEST_OVERSIZED_EVIDENCE_ARCHIVE"; artifact_digest="$JIT_TEST_OVERSIZED_EVIDENCE_DIGEST"; fi
  [[ "$JIT_TEST_CASE" != artifact-digest-mismatch ]] || artifact_digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"
  artifact_size="$(stat -c '%s' "$artifact_archive")"
  artifact_json="$(jq -cn --argjson id 6001 --arg name "$artifact_name" --argjson size "$artifact_size" --arg digest "$artifact_digest" --arg repository "$JIT_POLICY_REPOSITORY" --argjson run_id "$JIT_TEST_RUN_ID" --argjson repository_id 4242 --arg branch main --arg sha "$JIT_TEST_BASE" --arg created_at "$JIT_TEST_CREATED" \
    '{id:$id,name:$name,size_in_bytes:$size,url:("https://api.github.com/repos/"+$repository+"/actions/artifacts/"+($id|tostring)),archive_download_url:("https://api.github.com/repos/"+$repository+"/actions/artifacts/"+($id|tostring)+"/zip"),expired:false,created_at:$created_at,expires_at:"2099-01-01T00:00:00Z",updated_at:$created_at,digest:$digest,workflow_run:{id:$run_id,repository_id:$repository_id,head_repository_id:$repository_id,head_branch:$branch,head_sha:$sha}}')"
  if [[ "${JIT_TEST_CONTROLLER:-0}" == 1 && -n "${JIT_ADMISSION_ID:-}" ]]; then
    worker_state_dir="$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
    controller_min="${JIT_TEST_CONTROLLER_MIN_SEQUENCE:-8}"
    if compgen -G "$worker_state_dir/worker-*.json" >/dev/null; then
      controller_finished="$(jq -s --argjson minimum "$controller_min" '[.[] | select((.sequence // 0) >= $minimum)] | length' "$worker_state_dir"/worker-*.json)"
    fi
  fi
  case "$JIT_TEST_CASE" in
    wrong-repository) repository=attacker/repository ;;
    wrong-event) event=pull_request ;;
    wrong-attempt) attempt=3 ;;
    wrong-workflow) path=.github/workflows/untrusted.yml ;;
    wrong-actor) actor=attacker ;;
    skipped-admission) job_conclusion=skipped ;;
    failed-admission) job_conclusion=failure ;;
    stale) created_at=2020-01-01T00:00:00Z ;;
  esac
  case "$method:$endpoint" in
    GET:repos/*/actions/runs/${JIT_TEST_RUN_ID}/attempts/${JIT_TEST_ATTEMPT})
      jq -cn --arg repository "$repository" --arg event "$event" --arg attempt "$attempt" --arg branch "$head_branch" --arg sha "$head_sha" --arg path "$path" --arg actor "$actor" --arg triggering_actor "$triggering_actor" --arg created_at "$created_at" \
        '{repository:{id:4242,full_name:$repository},event:$event,run_attempt:($attempt|tonumber),head_branch:$branch,head_sha:$sha,path:$path,actor:{login:$actor},triggering_actor:{login:$triggering_actor},workflow_id:7654,created_at:$created_at,html_url:"https://github.com/example/actions/runs/987654321"}'
      ;;
    GET:repos/*/actions/runs/${JIT_TEST_RUN_ID})
      if [[ "${JIT_TEST_CONTROLLER:-0}" == 1 && "$controller_finished" -ge 3 ]]; then
        jq -cn --arg attempt "$attempt" '{run_attempt:($attempt|tonumber),status:"completed",conclusion:"success"}'
      else
        jq -cn --arg attempt "$attempt" '{run_attempt:($attempt|tonumber),status:"in_progress",conclusion:null}'
      fi
      ;;
    GET:repos/*/actions/workflows/7654)
      jq -cn --arg path "$path" --arg name "$JIT_POLICY_WORKFLOW_NAME" '{path:$path,name:$name,state:"active"}'
      ;;
    GET:repos/*/actions/runs/${JIT_TEST_RUN_ID}/attempts/${JIT_TEST_ATTEMPT}/jobs\?per_page=100\&page=*)
      page="${endpoint##*page=}"
      if [[ "$JIT_TEST_CASE" == truncated-jobs ]]; then
        jq -cn --arg name "$JIT_POLICY_ADMISSION_JOB" --arg sha "$JIT_TEST_BASE" '{total_count:2,jobs:[{id:9001,name:$name,status:"completed",conclusion:"success",head_sha:$sha,labels:["ubuntu-latest"]}]}'
      elif [[ "$JIT_TEST_CASE" == admission-page-2 ]]; then
        if [[ "$page" == 1 ]]; then
          jq -cn '{total_count:101,jobs:[range(1;101) as $n | {id:(10000+$n),name:("filler-"+($n|tostring)),status:"completed",conclusion:"success",head_sha:"1111111111111111111111111111111111111111",labels:["ubuntu-latest"]}]}'
        else
          jq -cn --arg name "$JIT_POLICY_ADMISSION_JOB" --arg sha "$JIT_TEST_BASE" '{total_count:101,jobs:[{id:9001,name:$name,status:"completed",conclusion:"success",head_sha:$sha,labels:["ubuntu-latest"]}]}'
        fi
      elif [[ "$JIT_TEST_CASE" == target-page-2 ]]; then
        if [[ "$page" == 1 ]]; then
          jq -cn --arg name "$JIT_POLICY_ADMISSION_JOB" --arg sha "$JIT_TEST_BASE" '{total_count:102,jobs:([{id:9001,name:$name,status:"completed",conclusion:"success",head_sha:$sha,labels:["ubuntu-latest"]}] + [range(1;100) as $n | {id:(10000+$n),name:("filler-"+($n|tostring)),status:"completed",conclusion:"success",head_sha:$sha,labels:["ubuntu-latest"]}])}'
        else
          jq -cn --arg label "$JIT_TEST_LABEL" '{total_count:102,jobs:[{id:9101,name:"page-two-one",status:"queued",conclusion:null,labels:[$label]},{id:9102,name:"page-two-two",status:"queued",conclusion:null,labels:[$label]}]}'
        fi
      elif [[ "${JIT_TEST_CONTROLLER:-0}" == 1 ]]; then
        jq -cn --arg name "$JIT_POLICY_ADMISSION_JOB" --arg status "$job_status" --arg conclusion "$job_conclusion" --arg sha "$JIT_TEST_BASE" --arg label "$JIT_TEST_LABEL" --argjson done "$controller_finished" '
          def target($id;$name;$complete): {id:$id,name:$name,status:(if $complete then "completed" else "queued" end),conclusion:(if $complete then "success" else null end),head_sha:$sha,labels:[$label],runner_id:null,runner_name:null};
          {total_count:4,jobs:[{id:9001,name:$name,status:$status,conclusion:$conclusion,head_sha:$sha,labels:["ubuntu-latest"]},target(9101;"data-one";$done>=1),target(9102;"data-two";$done>=2),target(9103;"data-three";$done>=3)]}'
      else
        jq -cn --arg name "$JIT_POLICY_ADMISSION_JOB" --arg status "$job_status" --arg conclusion "$job_conclusion" --arg sha "$JIT_TEST_BASE" '{total_count:1,jobs:[{id:9001,name:$name,status:$status,conclusion:$conclusion,head_sha:$sha,labels:["ubuntu-latest"]}]}'
      fi
      ;;
    GET:repos/*/actions/runs/${JIT_TEST_RUN_ID}/artifacts\?per_page=100\&page=*)
      page="${endpoint##*page=}"
      if [[ "$JIT_TEST_CASE" == missing-evidence ]]; then
        jq -cn '{total_count:0,artifacts:[]}'
      elif [[ "$JIT_TEST_CASE" == evidence-page-2 ]]; then
        if [[ "$page" == 1 ]]; then
          jq -cn '{total_count:101,artifacts:[range(1;101) as $n | {id:(20000+$n),name:("unrelated-"+($n|tostring))}]}'
        else
          jq -cn --argjson artifact "$artifact_json" '{total_count:101,artifacts:[$artifact]}'
        fi
      else
        jq -cn --argjson artifact "$artifact_json" '{total_count:1,artifacts:[$artifact]}'
      fi
      ;;
    GET:repos/*/actions/artifacts/6001)
      printf '%s\n' "$artifact_json"
      ;;
    GET:repos/*/pulls/${JIT_TEST_PR})
      jq -cn --arg base "$JIT_TEST_BASE" --arg head "$JIT_TEST_HEAD" --arg merge "$JIT_TEST_MERGE" --arg repository "$JIT_POLICY_REPOSITORY" '{state:"open",base:{ref:"main",sha:$base},head:{sha:$head,repo:{full_name:$repository}},merge_commit_sha:$merge}'
      ;;
    GET:repos/*/git/commits/${JIT_TEST_MERGE})
      jq -cn --arg merge "$JIT_TEST_MERGE" --arg tree "$JIT_TEST_TREE" --arg base "$JIT_TEST_BASE" --arg head "$JIT_TEST_HEAD" '{sha:$merge,tree:{sha:$tree},parents:[{sha:$base},{sha:$head}]}'
      ;;
    POST:repos/*/actions/runners/generate-jitconfig)
      runner_name="$(jq -r .name <<<"$body")"; runner_label="$(jq -r .labels[0] <<<"$body")"; runner_id=$((7000 + 10#${runner_name##*-}))
      shopt -s nullglob
      for state_file in "$JIT_WORKERS_DIR"/*/*.json; do
        if jq -e --arg name "$runner_name" --arg label "$runner_label" '.status=="registration-requested" and .registration.status=="requested" and .registration.runner_name==$name and .registration.label==$label and (.registration.request_id|length)==64' "$state_file" >/dev/null 2>&1; then intent_found=1; break; fi
      done
      shopt -u nullglob
      [[ "$intent_found" == 1 ]] || fail "remote JIT creation happened before durable registration intent"
      exec 7>"$TMP/fake-api.lock"; flock 7
      remote="$(cat "$JIT_TEST_REMOTE_RUNNERS_FILE")"
      encoded_config="$JIT_TEST_ENCODED_CONFIG"
      [[ "$JIT_TEST_CASE" != jit-config-disable-update-false ]] || encoded_config="$(jit_test_encoded_config false)"
      if [[ "$JIT_TEST_CASE" == default-labels ]]; then
        temporary="${JIT_TEST_REMOTE_RUNNERS_FILE}.tmp.$$"
        jq --arg id "$runner_id" --arg name "$runner_name" --arg label "$runner_label" '. + [{id:($id|tonumber),name:$name,status:"offline",busy:false,ephemeral:true,labels:[{name:$label},{name:"self-hosted"}]}]' <<<"$remote" >"$temporary"; mv "$temporary" "$JIT_TEST_REMOTE_RUNNERS_FILE"
        jq -cn --arg id "$runner_id" --arg name "$runner_name" --arg label "$runner_label" --arg encoded_config "$encoded_config" '{runner:{id:($id|tonumber),name:$name,status:"offline",busy:false,labels:[{name:$label,type:"custom"},{name:"self-hosted",type:"read-only"}]},encoded_jit_config:$encoded_config}'
      else
        temporary="${JIT_TEST_REMOTE_RUNNERS_FILE}.tmp.$$"
        jq --arg id "$runner_id" --arg name "$runner_name" --arg label "$runner_label" '. + [{id:($id|tonumber),name:$name,status:"offline",busy:false,ephemeral:true,labels:[{name:$label}]}]' <<<"$remote" >"$temporary"; mv "$temporary" "$JIT_TEST_REMOTE_RUNNERS_FILE"
        if [[ "$JIT_TEST_CASE" == registration-lost-response ]]; then flock -u 7; return 75; fi
        jq -cn --arg id "$runner_id" --arg name "$runner_name" --arg label "$runner_label" --arg encoded_config "$encoded_config" '{runner:{id:($id|tonumber),name:$name,status:"offline",busy:false,labels:[{name:$label,type:"custom"}]},encoded_jit_config:$encoded_config}'
      fi
      flock -u 7
      ;;
    GET:repos/*/actions/runners\?per_page=100\&page=*)
      page="${endpoint##*page=}"
      if [[ "$JIT_TEST_CASE" == duplicate-runners ]]; then
        if [[ "$page" == 1 ]]; then
          jq -cn '{total_count:101,runners:[range(1;101) as $n | {id:(30000+$n),name:("safe-"+($n|tostring)),status:"offline",busy:false,ephemeral:true,labels:[{name:"isolated"}]}]}'
        else
          jq -cn '{total_count:101,runners:[{id:30001,name:"duplicate",status:"offline",busy:false,ephemeral:true,labels:[{name:"isolated"}]}]}'
        fi
      elif [[ "$JIT_TEST_CASE" == forbidden-page-2 || "$JIT_TEST_CASE" == runner-page-2 ]]; then
        if [[ "$page" == 1 ]]; then
          jq -cn '{total_count:101,runners:[range(1;101) as $n | {id:(30000+$n),name:("safe-"+($n|tostring)),status:"offline",busy:false,ephemeral:true,labels:[{name:"isolated"}]}]}'
        elif [[ "$JIT_TEST_CASE" == forbidden-page-2 ]]; then
          jq -cn '{total_count:101,runners:[{id:41,name:"persistent",status:"online",busy:false,ephemeral:false,labels:[{name:"SELF-HOSTED"},{name:"Linux"},{name:"X64"},{name:"MAZAYA-BACKEND-CI"}]}]}'
        else
          jq -cn --arg label "$JIT_TEST_LABEL" '{total_count:101,runners:[{id:7001,name:"jit",status:"offline",busy:false,ephemeral:true,labels:[{name:$label}]}]}'
        fi
      elif [[ "$JIT_TEST_CASE" == stale-exact-label ]]; then
        jq -cn --arg label "$JIT_TEST_LABEL" '{total_count:1,runners:[{id:73,name:"stale-jit",status:"offline",busy:false,ephemeral:true,labels:[{name:$label}]}]}'
      elif [[ "$JIT_TEST_CASE" == forbidden-runner || -e "$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.active" ]]; then
        jq -cn '{total_count:1,runners:[{id:41,name:"persistent",status:"online",busy:false,ephemeral:false,labels:[{name:"self-hosted"},{name:"Linux"},{name:"X64"},{name:"fixture-ci"},{name:"shared-ci"}]}]}'
      else
        remote="$(cat "$JIT_TEST_REMOTE_RUNNERS_FILE")"
        jq -cn --argjson runners "$remote" '{total_count:($runners|length),runners:$runners}'
      fi
      ;;
    DELETE:repos/*/actions/runners/*)
      runner_id="${endpoint##*/}"
      exec 7>"$TMP/fake-api.lock"; flock 7
      temporary="${JIT_TEST_REMOTE_RUNNERS_FILE}.tmp.$$"
      jq --arg id "$runner_id" '[.[] | select((.id|tostring)!=$id)]' "$JIT_TEST_REMOTE_RUNNERS_FILE" >"$temporary"; mv "$temporary" "$JIT_TEST_REMOTE_RUNNERS_FILE"
      flock -u 7
      : >"$TMP/jit-delete-called"
      printf '{}\n'
      ;;
    *) fail "unexpected fake GitHub API call: $method $endpoint body=$body" ;;
  esac
}

JIT_TEST_CASE=valid
verification="$(jit_verify_admission "$JIT_TEST_RUN_ID" "$JIT_TEST_ATTEMPT" "$JIT_TEST_PR" "$JIT_TEST_BASE" "$JIT_TEST_HEAD" "$JIT_TEST_MERGE" "$JIT_TEST_TREE" "$JIT_TEST_LABEL")"
jq -e '.workflow_id==7654 and .admission_job_id==9001 and .evidence.artifact_id==6001 and .evidence.workload_boundary.job_container_required==true' >/dev/null <<<"$verification" || fail "valid artifact-backed admission verification failed"

for JIT_TEST_CASE in admission-page-2 evidence-page-2; do
  jit_verify_admission "$JIT_TEST_RUN_ID" "$JIT_TEST_ATTEMPT" "$JIT_TEST_PR" "$JIT_TEST_BASE" "$JIT_TEST_HEAD" "$JIT_TEST_MERGE" "$JIT_TEST_TREE" "$JIT_TEST_LABEL" >/dev/null \
    || fail "paginated trusted admission evidence failed: $JIT_TEST_CASE"
done

for JIT_TEST_CASE in wrong-repository wrong-event wrong-attempt wrong-workflow wrong-actor skipped-admission failed-admission stale evidence-mismatch unsafe-workload-boundary unsafe-evidence oversized-evidence artifact-digest-mismatch missing-evidence; do
  if (jit_verify_admission "$JIT_TEST_RUN_ID" "$JIT_TEST_ATTEMPT" "$JIT_TEST_PR" "$JIT_TEST_BASE" "$JIT_TEST_HEAD" "$JIT_TEST_MERGE" "$JIT_TEST_TREE" "$JIT_TEST_LABEL" >/dev/null 2>&1); then
    fail "unsafe admission case was accepted: $JIT_TEST_CASE"
  fi
done
JIT_TEST_CASE=valid
if (jit_verify_admission "$JIT_TEST_RUN_ID" "$JIT_TEST_ATTEMPT" "$JIT_TEST_PR" "$JIT_TEST_BASE" "$JIT_TEST_HEAD" "$JIT_TEST_MERGE" "$JIT_TEST_TREE" "mazaya-admission-1-1" >/dev/null 2>&1); then
  fail "mismatched admission label was accepted"
fi

DRY_RUN=1
dry_run_json="$(jit_prepare_admission mazaya-test --run-id "$JIT_TEST_RUN_ID" --run-attempt "$JIT_TEST_ATTEMPT" --pr-number "$JIT_TEST_PR" --base-sha "$JIT_TEST_BASE" --head-sha "$JIT_TEST_HEAD" --merge-sha "$JIT_TEST_MERGE" --tree-sha "$JIT_TEST_TREE" --label "$JIT_TEST_LABEL" --auth test)"
jq -e '.verified==true and .persisted==false and .jit_config_generated==false' >/dev/null <<<"$dry_run_json" || fail "JIT prepare dry-run JSON is invalid"
DRY_RUN=0
jit_prepare_admission mazaya-test --run-id "$JIT_TEST_RUN_ID" --run-attempt "$JIT_TEST_ATTEMPT" --pr-number "$JIT_TEST_PR" --base-sha "$JIT_TEST_BASE" --head-sha "$JIT_TEST_HEAD" --merge-sha "$JIT_TEST_MERGE" --tree-sha "$JIT_TEST_TREE" --label "$JIT_TEST_LABEL" --auth test >/dev/null
if (jit_prepare_admission mazaya-test --run-id "$JIT_TEST_RUN_ID" --run-attempt "$JIT_TEST_ATTEMPT" --pr-number "$JIT_TEST_PR" --base-sha "$JIT_TEST_BASE" --head-sha "$JIT_TEST_HEAD" --merge-sha "$JIT_TEST_MERGE" --tree-sha "$JIT_TEST_TREE" --label "$JIT_TEST_LABEL" --auth test >/dev/null 2>&1); then
  fail "admission replay was accepted"
fi

JIT_ADMISSION_ID="$(find "$JIT_ADMISSIONS_DIR" -maxdepth 1 -type f -name '*.json' -printf '%f\n' | sed 's/\.json$//' | head -n1)"
jit_load_admission "$JIT_ADMISSION_ID"
admission_file="$(jit_admission_file "$JIT_ADMISSION_ID")"
assert_eq "$(jq -r .schema_version "$admission_file")" "$JIT_ADMISSION_SCHEMA_VERSION" "new admissions should persist the workload-boundary schema"
jq -e '.verification.evidence.workload_boundary.job_container_required==true' "$admission_file" >/dev/null \
  || fail "admission did not persist the verified workload-boundary attestation"
legacy_admission="$TMP/${JIT_ADMISSION_ID}.json"
jq --argjson schema "$JIT_SCHEMA_VERSION" '.schema_version=$schema' "$admission_file" >"$legacy_admission"
if jit_validate_admission_lease_state "$legacy_admission"; then fail "legacy admission schema failed open"; fi

# Staging uses explicit output parameters so controller state is not lost when
# the helper is invoked from a subshell or a command substitution.
jit_prepare_runner_cache
staged_test_helper=""; staged_test_manifest=""
jit_stage_runtime_helper staged_test_helper staged_test_manifest
[[ "$staged_test_helper" == "$JIT_RUNTIME_HELPER" && "$staged_test_manifest" == "$JIT_RUNTIME_MANIFEST" ]] || fail "runtime staging output parameters were not propagated"
[[ "$staged_test_manifest" == "$JIT_DATA_DIR/runtime/manifest.json" ]] || fail "fake runtime manifest path is not private and deterministic"
jq -e --arg helper "$staged_test_helper" --arg helper_sha256 "$(sha256sum "$staged_test_helper" | awk '{print $1}')" '.helper==$helper and .helper_sha256==$helper_sha256' "$staged_test_manifest" >/dev/null || fail "runtime manifest does not bind the staged helper"
jit_prepare_admission_runtime
short_runtime="$(jit_worker_runtime_dir "$JIT_ADMISSION_ID" worker-001 "$JIT_BOUNDARY_ROOT/$JIT_ADMISSION_ID/worker-001.boundary")"
jit_assert_unix_socket_path "$short_runtime/docker.sock" || fail "worker Docker socket path exceeded AF_UNIX limits"
long_socket="/tmp/$(printf 'x%.0s' $(seq 1 120))"
if jit_assert_unix_socket_path "$long_socket"; then fail "overlong filesystem socket path was accepted"; fi

JIT_TEST_CASE=target-page-2
paginated_jobs="$(jit_get_run_jobs)"
assert_eq "$(jit_target_jobs "$paginated_jobs" | jq length)" "2"
assert_eq "$(jit_desired_worker_count "$(jit_target_jobs "$paginated_jobs" | jq '[.[] | select(.status=="queued")] | length')" 0 2)" "2"
JIT_TEST_CASE=truncated-jobs
if (jit_get_run_jobs >/dev/null 2>&1); then fail "truncated workflow-job collection was accepted"; fi
JIT_TEST_CASE=duplicate-runners
if (jit_remote_runners >/dev/null 2>&1); then fail "duplicate runner identities across pages were accepted"; fi
JIT_TEST_CASE=valid

assert_eq "$(jit_desired_worker_count 3 0 2)" "2"
assert_eq "$(jit_desired_worker_count 2 1 2)" "1"
assert_eq "$(jit_desired_worker_count 1 2 2)" "0"
assert_eq "$(jit_bounded_spawn_count 2 6 3 4)" "1"
assert_eq "$(jit_bounded_spawn_count 2 7 3 4)" "0"
if (jit_assert_safe_worker_path "$TMP/outside-jit-boundary" >/dev/null 2>&1); then
  fail "unsafe worker path passed the destructive-path guard"
fi

valid_jobs="$(jq -cn --arg label "$JIT_TEST_LABEL" '{jobs:[{id:1,name:"one",status:"queued",conclusion:null,labels:[$label]},{id:2,name:"two",status:"completed",conclusion:"success",labels:[$label]}]}')"
assert_eq "$(jit_target_jobs "$valid_jobs" | jq length)" "2"
invalid_jobs="$(jq -cn --arg label "$JIT_TEST_LABEL" '{jobs:[{id:1,name:"unsafe",status:"queued",conclusion:null,labels:[$label,"self-hosted"]}]}')"
if (jit_target_jobs "$invalid_jobs" >/dev/null 2>&1); then fail "reusable/default job labels were accepted"; fi

id_maps="$TMP/id-maps"; mkdir -p "$id_maps"
printf 'root:x:0:0:root:/root:/bin/bash\n' >"$id_maps/passwd"
printf 'root:x:0:\n' >"$id_maps/group"
printf 'legacy:100000:65536\n' >"$id_maps/subuid"
printf 'legacy:200000:65536\n' >"$id_maps/subgid"
identity_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-900)"
mkdir -p "$(dirname "$identity_state")"; jit_write_worker_state "$identity_state" allocated; jit_plan_worker_identity "$identity_state" 900
GHRCTL_JIT_PASSWD_FILE="$id_maps/passwd" GHRCTL_JIT_GROUP_FILE="$id_maps/group" GHRCTL_JIT_SUBUID_FILE="$id_maps/subuid" GHRCTL_JIT_SUBGID_FILE="$id_maps/subgid" \
  jit_validate_host_id_maps "$identity_state"
printf 'legacy:50000:1\n' >>"$id_maps/subuid"
if GHRCTL_JIT_PASSWD_FILE="$id_maps/passwd" GHRCTL_JIT_GROUP_FILE="$id_maps/group" GHRCTL_JIT_SUBUID_FILE="$id_maps/subuid" GHRCTL_JIT_SUBGID_FILE="$id_maps/subgid" jit_validate_host_id_maps "$identity_state" >/dev/null 2>&1; then
  fail "a subordinate UID range overlapping the configured real-ID pool was accepted"
fi
sed -i '$d' "$id_maps/subuid"
printf 'mapped:x:1000000000:1000000000:mapped:/nonexistent:/usr/sbin/nologin\n' >>"$id_maps/passwd"
if GHRCTL_JIT_PASSWD_FILE="$id_maps/passwd" GHRCTL_JIT_GROUP_FILE="$id_maps/group" GHRCTL_JIT_SUBUID_FILE="$id_maps/subuid" GHRCTL_JIT_SUBGID_FILE="$id_maps/subgid" jit_validate_host_id_maps "$identity_state" >/dev/null 2>&1; then
  fail "a real UID inside the configured subordinate-ID pool was accepted"
fi
sed -i '$d' "$id_maps/passwd"
printf 'overlap:120000:65536\n' >>"$id_maps/subuid"
if GHRCTL_JIT_PASSWD_FILE="$id_maps/passwd" GHRCTL_JIT_GROUP_FILE="$id_maps/group" GHRCTL_JIT_SUBUID_FILE="$id_maps/subuid" GHRCTL_JIT_SUBGID_FILE="$id_maps/subgid" jit_validate_host_id_maps "$identity_state" >/dev/null 2>&1; then
  fail "overlapping subordinate UID records were accepted"
fi
rm -f "$identity_state"

diagnostic_boundary="$TMP/diagnostic-boundary"
diagnostic_destination="$TMP/diagnostic-retention"
mkdir -p "$diagnostic_boundary/source/nested"
printf 'safe\n' >"$diagnostic_boundary/source/nested/runner.log"
python3 "$ROOT/libexec/collect_diagnostics.py" --boundary "$diagnostic_boundary" --source "$diagnostic_boundary/source" --destination "$diagnostic_destination/valid" \
  --max-files 200 --max-file-bytes 4194304 --max-total-bytes 33554432
[[ "$(<"$diagnostic_destination/valid/nested/runner.log")" == safe ]] || fail "bounded diagnostic collector lost a regular file"

diagnostic_reject() {
  local case_name="$1" source="$2"
  if python3 "$ROOT/libexec/collect_diagnostics.py" --boundary "$diagnostic_boundary" --source "$source" --destination "$diagnostic_destination/$case_name" \
    --max-files 200 --max-file-bytes 4194304 --max-total-bytes 33554432 >/dev/null 2>&1; then
    fail "unsafe diagnostic source was accepted: $case_name"
  fi
  [[ ! -e "$diagnostic_destination/$case_name" ]] || fail "partial diagnostics survived rejection: $case_name"
}
ln -s /etc "$diagnostic_boundary/top-link"; diagnostic_reject top-symlink "$diagnostic_boundary/top-link"; rm "$diagnostic_boundary/top-link"
mkdir "$diagnostic_boundary/nested-link"; ln -s /etc/passwd "$diagnostic_boundary/nested-link/passwd"; diagnostic_reject nested-symlink "$diagnostic_boundary/nested-link"
mkdir "$diagnostic_boundary/fifo"; mkfifo "$diagnostic_boundary/fifo/pipe"; diagnostic_reject fifo "$diagnostic_boundary/fifo"
mkdir "$diagnostic_boundary/socket"; python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.close()' "$diagnostic_boundary/socket/probe"; diagnostic_reject socket "$diagnostic_boundary/socket"
mkdir "$diagnostic_boundary/hardlink"; printf data >"$diagnostic_boundary/hardlink/a"; ln "$diagnostic_boundary/hardlink/a" "$diagnostic_boundary/hardlink/b"; diagnostic_reject hardlink "$diagnostic_boundary/hardlink"
mkdir "$diagnostic_boundary/sparse"; truncate -s 1048576 "$diagnostic_boundary/sparse/file"; diagnostic_reject sparse "$diagnostic_boundary/sparse"
mkdir "$diagnostic_boundary/per-file"; dd if=/dev/zero of="$diagnostic_boundary/per-file/file" bs=1048576 count=4 status=none; printf x >>"$diagnostic_boundary/per-file/file"; diagnostic_reject per-file "$diagnostic_boundary/per-file"
mkdir "$diagnostic_boundary/count"; for diagnostic_index in $(seq 1 201); do : >"$diagnostic_boundary/count/$diagnostic_index"; done; diagnostic_reject file-count "$diagnostic_boundary/count"
mkdir "$diagnostic_boundary/aggregate"; for diagnostic_index in $(seq 1 9); do dd if=/dev/zero of="$diagnostic_boundary/aggregate/$diagnostic_index" bs=1048576 count=4 status=none; done; diagnostic_reject aggregate "$diagnostic_boundary/aggregate"
diagnostic_reject outside-boundary /etc
rm -rf --one-file-system "$diagnostic_boundary"

# Project/host retention is serialized by a root-only lock and prunes
# successful evidence before older failure evidence.
retention_root="$TMP/retention-policy"
mkdir -p "$retention_root/admission-a/worker-failed" "$retention_root/admission-b/worker-success"
printf failure >"$retention_root/admission-a/worker-failed/evidence.log"
printf success >"$retention_root/admission-b/worker-success/evidence.log"
jit_write_diagnostic_retention_marker "$retention_root/admission-a/worker-failed" mazaya-test admission-a worker-failed failed 0
jit_write_diagnostic_retention_marker "$retention_root/admission-b/worker-success" mazaya-test admission-b worker-success finished 0
python3 "$ROOT/libexec/prune_diagnostics.py" --root "$retention_root" --project mazaya-test \
  --host-max-bytes 1048576 --project-max-bytes 1048576 --min-free-bytes 0 --retention-seconds 86400 \
  --project-max-workers 1 --now-epoch "$(date +%s)"
[[ -d "$retention_root/admission-a/worker-failed" && ! -e "$retention_root/admission-b/worker-success" ]] \
  || fail "diagnostic pruning did not preserve failure evidence preferentially"
if python3 "$ROOT/libexec/prune_diagnostics.py" --root "$TMP/retention-no-space" --project mazaya-test \
  --host-max-bytes 1048576 --project-max-bytes 1048576 --min-free-bytes 999999999999999999 \
  --retention-seconds 86400 --project-max-workers 1 --reserve-bytes 1 --reserve-workers 1 >/dev/null 2>&1; then
  fail "diagnostic minimum-free-space guard failed open"
fi
if python3 "$ROOT/libexec/prune_diagnostics.py" --root "$TMP/retention-no-project-quota" --project mazaya-test \
  --host-max-bytes 4096 --project-max-bytes 1024 --min-free-bytes 0 \
  --retention-seconds 86400 --project-max-workers 1 --reserve-bytes 2048 --reserve-workers 1 >/dev/null 2>&1; then
  fail "diagnostic project quota failed open"
fi
if python3 "$ROOT/libexec/prune_diagnostics.py" --root "$TMP/retention-no-host-quota" --project mazaya-test \
  --host-max-bytes 1024 --project-max-bytes 4096 --min-free-bytes 0 \
  --retention-seconds 86400 --project-max-workers 1 --reserve-bytes 2048 --reserve-workers 1 >/dev/null 2>&1; then
  fail "diagnostic host quota failed open"
fi
mkdir -p "$retention_root/admission-c/worker-expired"
jit_write_diagnostic_retention_marker "$retention_root/admission-c/worker-expired" mazaya-test admission-c worker-expired finished 0
jq '.created_epoch=1' "$retention_root/admission-c/worker-expired/.retention.json" | jit_atomic_write "$retention_root/admission-c/worker-expired/.retention.json"
python3 "$ROOT/libexec/prune_diagnostics.py" --root "$retention_root" --project mazaya-test \
  --host-max-bytes 1048576 --project-max-bytes 1048576 --min-free-bytes 0 --retention-seconds 1 \
  --project-max-workers 100 --now-epoch "$(date +%s)"
[[ ! -e "$retention_root/admission-c/worker-expired" ]] || fail "diagnostic TTL pruning failed"
retention_sentinel="$TMP/retention-sentinel"
printf sentinel >"$retention_sentinel"
mkdir -p "$retention_root/admission-d/worker-unsafe"
jit_write_diagnostic_retention_marker "$retention_root/admission-d/worker-unsafe" mazaya-test admission-d worker-unsafe finished 0
ln -s "$retention_sentinel" "$retention_root/admission-d/worker-unsafe/nested-link"
if python3 "$ROOT/libexec/prune_diagnostics.py" --root "$retention_root" --project mazaya-test \
  --host-max-bytes 1048576 --project-max-bytes 1048576 --min-free-bytes 0 --retention-seconds 86400 \
  --project-max-workers 1 --now-epoch "$(date +%s)" >/dev/null 2>&1; then
  fail "diagnostic pruner accepted a no-follow retention violation"
fi
[[ "$(<"$retention_sentinel")" == sentinel ]] || fail "diagnostic pruning followed an unsafe retention entry"
rm "$retention_root/admission-d/worker-unsafe/nested-link"
jit_acquire_diagnostic_retention_lock retention_test_fd
assert_eq "$(stat -c '%a' "$JIT_DIAGNOSTIC_RETENTION_LOCK_FILE")" 600
jit_release_diagnostic_retention_lock "$retention_test_fd"

jit_prepare_runner_cache
state_dir="$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
mkdir -p "$state_dir"
state_one="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-001)"
jit_spawn_worker 1
wait "$(jq -r .controller_pid "$state_one")"
assert_eq "$(jq -r .status "$state_one")" "finished"
[[ ! -e "$(jq -r .root "$state_one")" ]] || fail "successful worker boundary survived cleanup"
[[ ! -e "$(jq -r .runtime_dir "$state_one")" ]] || fail "successful worker runtime survived cleanup"
diagnostics="${JIT_DIAGNOSTICS_DIR}/${JIT_ADMISSION_ID}/worker-001"
[[ -r "$diagnostics/runner/runner.log" ]] || fail "external runner diagnostics were not retained"
if grep -R -F "$JIT_TEST_JIT_SECRET" "$JIT_DATA_DIR" "$JIT_DIAGNOSTICS_DIR" >/dev/null 2>&1 || \
   grep -R -F "$JIT_TEST_SECRET_BASE64" "$JIT_DATA_DIR" "$JIT_DIAGNOSTICS_DIR" >/dev/null 2>&1 || \
   grep -R -F "$JIT_TEST_CREDENTIALS_BLOB" "$JIT_DATA_DIR" "$JIT_DIAGNOSTICS_DIR" >/dev/null 2>&1 || \
   grep -R -F "$JIT_TEST_RSA_BLOB" "$JIT_DATA_DIR" "$JIT_DIAGNOSTICS_DIR" >/dev/null 2>&1 || \
   grep -R -F "$JIT_TEST_ENCODED_CONFIG" "$JIT_DATA_DIR" "$JIT_DIAGNOSTICS_DIR" >/dev/null 2>&1; then
  fail "JIT credential material leaked into state or diagnostics"
fi
if grep -q '^ACTIONS_RUNNER_INPUT_JITCONFIG=' "$diagnostics/runner/job-environment.log"; then fail "JIT configuration reached the job environment"; fi

state_two="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-002)"
state_three="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-003)"
jit_write_worker_state "$state_two" allocated; jit_plan_worker_identity "$state_two" 2; jit_create_worker_boundary "$state_two"
user_two="$JIT_WORKER_USER"; root_two="$JIT_WORKER_ROOT"; runtime_two="$JIT_WORKER_RUNTIME_DIR"; socket_two="$JIT_WORKER_DOCKER_SOCKET"
jit_write_worker_state "$state_three" allocated; jit_plan_worker_identity "$state_three" 3; jit_create_worker_boundary "$state_three"
user_three="$JIT_WORKER_USER"; root_three="$JIT_WORKER_ROOT"; runtime_three="$JIT_WORKER_RUNTIME_DIR"; socket_three="$JIT_WORKER_DOCKER_SOCKET"
[[ "$user_two" != "$user_three" && "$root_two" != "$root_three" && "$socket_two" != "$socket_three" ]] || fail "simultaneous slots share an identity, filesystem, or Docker socket"
[[ "$(jq -r .runtime_dir "$state_two")" != "$(jq -r .runtime_dir "$state_three")" ]] || fail "simultaneous slots share a runtime directory"
jit_cleanup_worker_state "$state_two"; jit_cleanup_worker_state "$state_three"
[[ ! -e "$root_two" && ! -e "$root_three" && ! -e "$runtime_two" && ! -e "$runtime_three" ]] || fail "cancel/restart cleanup left mutable worker state"

# Same-boot PID reuse must not authorize traversal or signalling of an unrelated
# root, sandbox MainPID, slirp process, or any of their current children.
reuse_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-850)"
jit_write_worker_state "$reuse_state" allocated
jit_plan_worker_identity "$reuse_state" 850
reuse_pids=()
spawn_reused_process_tree() {
  local child_file="$1" output_parent="$2" output_child="$3" parent child
  /bin/bash -c 'sleep 300 & printf "%s\n" "$!" >"$1"; wait' reused-tree "$child_file" &
  parent=$!
  for _attempt in $(seq 1 100); do [[ -s "$child_file" ]] && break; sleep 0.01; done
  child="$(cat "$child_file")"
  [[ "$parent" =~ ^[1-9][0-9]*$ && "$child" =~ ^[1-9][0-9]*$ ]] || fail "PID-reuse fixture did not publish a process tree"
  printf -v "$output_parent" '%s' "$parent"
  printf -v "$output_child" '%s' "$child"
  reuse_pids+=("$parent" "$child")
}
spawn_reused_process_tree "$TMP/reuse-root-child" reuse_root reuse_root_child
spawn_reused_process_tree "$TMP/reuse-main-child" reuse_main reuse_main_child
spawn_reused_process_tree "$TMP/reuse-slirp-child" reuse_slirp reuse_slirp_child
trap 'kill -TERM "${reuse_pids[@]}" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
reuse_boot="$(cat /proc/sys/kernel/random/boot_id)"
reuse_root_ticks="$(( $(jit_process_start_ticks "$reuse_root") + 1 ))"
reuse_main_ticks="$(( $(jit_process_start_ticks "$reuse_main") + 1 ))"
reuse_slirp_ticks="$(( $(jit_process_start_ticks "$reuse_slirp") + 1 ))"
jq --arg root "$reuse_root" --arg main "$reuse_main" --arg slirp "$reuse_slirp" --arg boot "$reuse_boot" \
  --arg root_ticks "$reuse_root_ticks" --arg main_ticks "$reuse_main_ticks" --arg slirp_ticks "$reuse_slirp_ticks" '
  .controller_pid=($root|tonumber) | .controller_boot_id=$boot | .controller_start_ticks=($root_ticks|tonumber) |
  .worker_pid=($root|tonumber) | .worker_boot_id=$boot | .worker_start_ticks=($root_ticks|tonumber) |
  .sandbox_main_pid=($main|tonumber) | .sandbox_main_boot_id=$boot | .sandbox_main_start_ticks=($main_ticks|tonumber) |
  .sandbox_slirp_pid=($slirp|tonumber) | .sandbox_slirp_boot_id=$boot | .sandbox_slirp_start_ticks=($slirp_ticks|tonumber)
' "$reuse_state" | jit_atomic_write "$reuse_state"
jit_terminate_worker_tree "$reuse_state"
for reuse_pid in "${reuse_pids[@]}"; do kill -0 "$reuse_pid" 2>/dev/null || fail "stale persisted PID signalled an unrelated reused process or child: $reuse_pid"; done
kill -TERM "${reuse_pids[@]}" >/dev/null 2>&1 || true
wait "$reuse_root" "$reuse_main" "$reuse_slirp" >/dev/null 2>&1 || true
trap 'rm -rf "$TMP"' EXIT
rm -f "$reuse_state"

JIT_TEST_CASE=default-labels
state_four="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-004)"
jit_spawn_worker 4 >/dev/null 2>&1
wait "$(jq -r .controller_pid "$state_four")" 2>/dev/null || true
assert_eq "$(jq -r .status "$state_four")" "failed"
[[ -e "$TMP/jit-delete-called" ]] || fail "rejected default-label registration was not deregistered"
[[ ! -e "$(jq -r .root "$state_four")" ]] || fail "rejected default-label worker boundary survived cleanup"
JIT_TEST_CASE=valid

failure_seed="$TMP/failing-actions-runner"
cp -a "$ROOT/tests/fixtures/fake-actions-runner" "$failure_seed"
: >"$failure_seed/.fail"
GHRCTL_JIT_FAKE_RUNNER_ROOT="$failure_seed"
jit_prepare_runner_cache
state_five="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-005)"
jit_spawn_worker 5
wait "$(jq -r .controller_pid "$state_five")" 2>/dev/null || true
assert_eq "$(jq -r .status "$state_five")" "failed"
[[ ! -e "$(jq -r .root "$state_five")" ]] || fail "failed worker boundary survived cleanup"
GHRCTL_JIT_FAKE_RUNNER_ROOT="$ROOT/tests/fixtures/fake-actions-runner"
jit_prepare_runner_cache

state_six="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-006)"
jit_write_worker_state "$state_six" allocated
jit_plan_worker_identity "$state_six" 6
jit_create_worker_boundary "$state_six"
jit_write_worker_state "$state_six" cancelled "simulated controller cancellation" 7001
jit_cleanup_worker_state "$state_six"
assert_eq "$(jq -r .status "$state_six")" "cleaned"
[[ ! -e "$(jq -r .root "$state_six")" ]] || fail "cancelled worker boundary survived cleanup"

legacy_runner_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-096)"
jit_write_worker_state "$legacy_runner_state" allocated
jit_plan_worker_identity "$legacy_runner_state" 96
jit_create_worker_boundary "$legacy_runner_state"
jq 'del(.runner_version,.runner_arch,.runner_asset,.runner_asset_digest) | .status="running"' "$legacy_runner_state" | jit_atomic_write "$legacy_runner_state"
if jit_validate_worker_journal "$legacy_runner_state" "$JIT_ADMISSION_ID"; then
  fail "active legacy worker without runner provenance was admitted"
fi
legacy_runner_root="$(jq -r .root "$legacy_runner_state")"
jit_cleanup_worker_state "$legacy_runner_state"
assert_eq "$(jq -r .status "$legacy_runner_state")" cleaned
[[ ! -e "$legacy_runner_root" ]] || fail "legacy worker cleanup left its deterministic boundary"
jit_validate_worker_journal "$legacy_runner_state" "$JIT_ADMISSION_ID" \
  || fail "terminal legacy worker history blocked admission after safe cleanup"
rm -f "$legacy_runner_state"

state_seven="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-007)"
jit_write_worker_state "$state_seven" allocated
jit_plan_worker_identity "$state_seven" 7
jit_create_worker_boundary "$state_seven"
jit_write_worker_state "$state_seven" running "simulated host restart"
jit_cleanup_stale_worker_states "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
assert_eq "$(jq -r .status "$state_seven")" "cleaned"
[[ ! -e "$(jq -r .root "$state_seven")" ]] || fail "host-restart cleanup left mutable worker state"

# A controller can disappear without leaving its global fd9 lock held by a
# worker. The replacement process must acquire the lock and recover the stale
# worker state deterministically.
global_lock_was_held="$LOCK_HELD"
abrupt_saved_admission_id="$JIT_ADMISSION_ID"
JIT_ADMISSION_ID=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
jq --arg id "$JIT_ADMISSION_ID" '.id=$id | .status="cleaned"' "$(jit_admission_file "$abrupt_saved_admission_id")" | jit_atomic_write "$(jit_admission_file "$JIT_ADMISSION_ID")"
mkdir -p "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
if [[ "$global_lock_was_held" == 1 ]]; then
  flock -u 9
  exec 9>&-
  LOCK_HELD=0
fi
GHRCTL_JIT_FAKE_RUNNER_ROOT="$ROOT/tests/fixtures/holding-actions-runner"
jit_prepare_runner_cache
abrupt_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-700)"
(
  acquire_lock
  jit_spawn_worker 700
  wait "$(jq -r '.controller_pid // 0' "$abrupt_state")" >/dev/null 2>&1 || true
) & abrupt_controller_pid=$!
abrupt_worker_pid=0
for _attempt in $(seq 1 200); do
  if [[ "$(jq -r '.status // empty' "$abrupt_state" 2>/dev/null)" == running ]]; then
    abrupt_worker_pid="$(jq -r '.controller_pid // 0' "$abrupt_state")"
    [[ "$abrupt_worker_pid" =~ ^[1-9][0-9]*$ ]] && break
  fi
  sleep 0.1
done
[[ "$abrupt_worker_pid" =~ ^[1-9][0-9]*$ ]] || fail "abrupt-controller worker did not reach running state"
abrupt_boot_id="$(jq -r '.worker_boot_id // .controller_boot_id' "$abrupt_state")"
abrupt_start_ticks="$(jq -r '.worker_start_ticks // .controller_start_ticks' "$abrupt_state")"
[[ "$(jq -r .controller_process "$abrupt_state")" == jit_worker_process ]] || fail "worker journal did not identify the actual jit_worker_process"
for _attempt in $(seq 1 100); do
  [[ -r "$(jq -r .root "$abrupt_state")/home/actions-runner/_diag/runner.pid" ]] && break
  sleep 0.1
done
abrupt_child_pid="$(cat "$(jq -r .root "$abrupt_state")/home/actions-runner/_diag/runner.pid")"
[[ "$abrupt_child_pid" =~ ^[1-9][0-9]*$ ]] || fail "holding runner did not publish a descendant PID"
kill -KILL "$abrupt_controller_pid" >/dev/null 2>&1 || true
wait "$abrupt_controller_pid" >/dev/null 2>&1 || true
exec {recovery_lock_fd}>"$GHRCTL_LOCK_FILE"
flock -n "$recovery_lock_fd" || fail "global lock remained held after abrupt controller death"
flock -u "$recovery_lock_fd"; exec {recovery_lock_fd}>&-
# Kill the actual worker root as well. Recovery must use its durable descendant
# journal rather than relying on the root process still being discoverable.
kill -KILL "$abrupt_worker_pid" >/dev/null 2>&1 || true
wait "$abrupt_worker_pid" >/dev/null 2>&1 || true
jit_cleanup_admission_workers
[[ "$(jq -r .status "$abrupt_state")" =~ ^(finished|cleaned)$ ]] || fail "abrupt-controller recovery did not reach a terminal cleanup state"
assert_eq "$(jq 'length' "$JIT_TEST_REMOTE_RUNNERS_FILE")" 0
[[ ! -e "$(jq -r .root "$abrupt_state")" ]] || fail "abrupt-controller worker boundary survived recovery cleanup"
! jit_process_identity_active "$abrupt_worker_pid" "$abrupt_boot_id" "$abrupt_start_ticks" || fail "recovery cleanup left the actual worker process alive"
[[ ! -e "/proc/$abrupt_child_pid" ]] || fail "recovery cleanup left a worker descendant alive"
GHRCTL_JIT_FAKE_RUNNER_ROOT="$ROOT/tests/fixtures/fake-actions-runner"
jit_prepare_runner_cache
if [[ "$global_lock_was_held" == 1 ]]; then acquire_lock; fi
JIT_ADMISSION_ID="$abrupt_saved_admission_id"
jit_load_admission "$JIT_ADMISSION_ID"

# A durable host lease blocks a second admission while the first is live, then
# becomes eligible only after the owner records complete cleanup.
lease_saved_admission_id="$JIT_ADMISSION_ID"
lease_a="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
lease_b="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
jq --arg id "$lease_a" '.id=$id | .status="running" | .project="mazaya-test"' "$JIT_ADMISSION_FILE" | jit_atomic_write "$(jit_admission_file "$lease_a")"
jq --arg id "$lease_b" '.id=$id | .status="prepared" | .project="mazaya-test"' "$JIT_ADMISSION_FILE" | jit_atomic_write "$(jit_admission_file "$lease_b")"
jit_write_active_admission_lease "$lease_a" mazaya-test owner/repo
if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "second admission bypassed the durable active-admission lease"; fi
jq '.status="cleanup-pending"' "$(jit_admission_file "$lease_a")" | jit_atomic_write "$(jit_admission_file "$lease_a")"
if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "cleanup-pending admission did not block a second launch"; fi
jq '.status="cleaned"' "$(jit_admission_file "$lease_a")" | jit_atomic_write "$(jit_admission_file "$lease_a")"
jit_release_active_admission_lease "$lease_a"
jit_assert_active_admission_available "$lease_b" || fail "second admission remained blocked after complete cleanup"

# Every persisted worker journal is a launch gate. Truncation, schema drift,
# unknown status, or a non-deterministic identity must fail closed.
JIT_ADMISSION_ID="$lease_a"
lease_worker="$(jit_worker_state_file "$lease_a" worker-901)"
jit_write_worker_state "$lease_worker" allocated
jit_plan_worker_identity "$lease_worker" 901
valid_lease_worker="$(cat "$lease_worker")"
assert_eq "$(jq -r '.schema_version' "$lease_worker")" "$JIT_WORKER_SCHEMA_VERSION" "new worker journals should use the resource-checkpoint schema"
printf '{"schema_version":' >"$lease_worker"
if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "truncated worker journal failed open"; fi
printf '%s\n' "$valid_lease_worker" | jit_atomic_write "$lease_worker"
jq --argjson old_schema "$JIT_SCHEMA_VERSION" '.schema_version=$old_schema' "$lease_worker" | jit_atomic_write "$lease_worker"
if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "legacy worker journal schema failed open"; fi
printf '%s\n' "$valid_lease_worker" | jit_atomic_write "$lease_worker"
jq '.schema_version=999' "$lease_worker" | jit_atomic_write "$lease_worker"
if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "unknown worker journal schema failed open"; fi
printf '%s\n' "$valid_lease_worker" | jit_atomic_write "$lease_worker"
jq '.status="future-status"' "$lease_worker" | jit_atomic_write "$lease_worker"
if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "unknown worker journal status failed open"; fi
printf '%s\n' "$valid_lease_worker" | jit_atomic_write "$lease_worker"
  jq '.sandbox_unit="attacker-selected.service"' "$lease_worker" | jit_atomic_write "$lease_worker"
  if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "invalid deterministic worker identity failed open"; fi
  printf '%s\n' "$valid_lease_worker" | jit_atomic_write "$lease_worker"
  jq '.resources.user.mutation_started="yes"' "$lease_worker" | jit_atomic_write "$lease_worker"
  if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "malformed resource checkpoint failed open"; fi
  printf '%s\n' "$valid_lease_worker" | jit_atomic_write "$lease_worker"
  jq '.root=null' "$lease_worker" | jit_atomic_write "$lease_worker"
if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "missing required worker identity failed open"; fi
rm -f "$lease_worker"

# A terminal journal cannot release/replace its lease while deterministic host
# or exact-label GitHub resources from that admission survive.
jit_write_active_admission_lease "$lease_a" mazaya-test owner/repo
stale_unit="${GHRCTL_JIT_FAKE_UNITS_DIR}/ghrctl-jit-${lease_a:0:12}-999.service"
: >"$stale_unit"
if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "missing worker journal with a surviving deterministic unit failed open"; fi
rm -f "$stale_unit"
stale_runtime="${JIT_DATA_DIR}/worker-runtime/${lease_a:0:12}-999"
mkdir -p "$stale_runtime"
if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "missing worker journal with a surviving deterministic runtime failed open"; fi
rmdir "$stale_runtime"
JIT_TEST_CASE=stale-exact-label
if (jit_assert_active_admission_available "$lease_b" >/dev/null 2>&1); then fail "surviving exact-label remote registration failed open"; fi
JIT_TEST_CASE=valid
jit_release_active_admission_lease "$lease_a"
jit_assert_active_admission_available "$lease_b" || fail "reconciled stale admission remained blocked"
JIT_ADMISSION_ID="$lease_saved_admission_id"
rmdir "$(jit_worker_state_dir "$lease_a")"
rm -f "$(jit_admission_file "$lease_a")" "$(jit_admission_file "$lease_b")"

saved_admission_id="$JIT_ADMISSION_ID"
JIT_ADMISSION_ID=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
jq --arg id "$JIT_ADMISSION_ID" '.id=$id | .status="cleaned"' "$(jit_admission_file "$saved_admission_id")" | jit_atomic_write "$(jit_admission_file "$JIT_ADMISSION_ID")"
mkdir -p "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
worker_fault_points=(
  worker-after-boundary-mutation worker-after-group-mutation worker-after-user-mutation worker-after-subids-mutation
  worker-after-runner-seed-mutation worker-after-sandbox-mutation worker-after-docker-mutation
)
fault_sequence=1
for fault_point in "${worker_fault_points[@]}"; do
  fault_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" "worker-$(printf '%03d' "$fault_sequence")")"
  rm -f "$fault_state"
  GHRCTL_JIT_FAULT_POINT="$fault_point"
  jit_spawn_worker "$fault_sequence"
  unset GHRCTL_JIT_FAULT_POINT
  fault_pid="$(jq -r '.controller_pid // 0' "$fault_state")"
  [[ "$fault_pid" =~ ^[1-9][0-9]*$ ]] || fail "real jit_worker_process did not publish a controller PID: $fault_point"
  for _attempt in $(seq 1 100); do
    [[ "$(jq -r '.status // empty' "$fault_state")" =~ ^(failed|finished|cleaned)$ ]] && break
    sleep 0.1
  done
  wait "$fault_pid" >/dev/null 2>&1 || true
  assert_eq "$(jq -r .status "$fault_state")" failed
  jq -e '.creation_stage!=null and .user!=null and .uid!=null and .group!=null and .root!=null and .home!=null and .runtime_dir!=null and .docker_socket!=null' "$fault_state" >/dev/null \
    || fail "partial worker identity was not journaled before fault: $fault_point"
  jq -e '.resources.boundary.mutation_started==true and
    ([.resources.boundary,.resources.group,.resources.user,.resources.subids,.resources.runner_seed,.resources.runtime] | all(.mutation_started|type=="boolean") and all(.created|type=="boolean"))' "$fault_state" >/dev/null \
    || fail "durable resource checkpoints were not preserved before fault cleanup: $fault_point"
  fault_root="$(jq -r .root "$fault_state")"
  fault_runtime="$(jq -r .runtime_dir "$fault_state")"
  jit_cleanup_worker_state "$fault_state"
  assert_eq "$(jq -r .status "$fault_state")" "cleaned"
  [[ ! -e "$fault_root" && ! -e "$fault_runtime" ]] || fail "partial worker boundary/runtime survived cleanup: $fault_point"
  fault_sequence=$((fault_sequence + 1))
done

registration_sequence=100
for registration_fault in registration-after-intent-before-request registration-after-response-before-id registration-after-id-persisted; do
  registration_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" "worker-$(printf '%03d' "$registration_sequence")")"
  jit_write_worker_state "$registration_state" allocated; jit_plan_worker_identity "$registration_state" "$registration_sequence"
  GHRCTL_JIT_FAULT_POINT="$registration_fault"
  if (jit_generate_config "$(jq -r .user "$registration_state")" "$registration_state" >/dev/null 2>&1); then fail "registration fault injection did not fire: $registration_fault"; fi
  unset GHRCTL_JIT_FAULT_POINT
  jq -e '.registration.request_id|length==64' "$registration_state" >/dev/null || fail "registration intent was not durable before fault: $registration_fault"
  jit_cleanup_worker_state "$registration_state"
  assert_eq "$(jq -r .status "$registration_state")" cleaned
  assert_eq "$(jq 'length' "$JIT_TEST_REMOTE_RUNNERS_FILE")" 0
  registration_sequence=$((registration_sequence + 1))
done

registration_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-099)"
jit_write_worker_state "$registration_state" allocated; jit_plan_worker_identity "$registration_state" 99
JIT_TEST_CASE=jit-config-disable-update-false
validation_output="$TMP/jit-config-integration.output"
if (jit_generate_config "$(jq -r .user "$registration_state")" "$registration_state") >"$validation_output" 2>&1; then
  fail "generate-jitconfig accepted DisableUpdate=false"
fi
JIT_TEST_CASE=valid
jq -e '.status=="registered" and (.runner_id|type=="number")' "$registration_state" >/dev/null \
  || fail "unsafe JIT configuration runner identity was not persisted for cleanup"
if grep -F "$JIT_TEST_JIT_SECRET" "$validation_output" >/dev/null 2>&1 || grep -F "$JIT_TEST_SECRET_BASE64" "$validation_output" >/dev/null 2>&1 || \
   grep -F "$JIT_TEST_CREDENTIALS_BLOB" "$validation_output" >/dev/null 2>&1 || grep -F "$JIT_TEST_RSA_BLOB" "$validation_output" >/dev/null 2>&1; then
  fail "unsafe JIT configuration failure leaked credential material"
fi
jit_cleanup_worker_state "$registration_state"
assert_eq "$(jq -r .status "$registration_state")" cleaned
assert_eq "$(jq 'length' "$JIT_TEST_REMOTE_RUNNERS_FILE")" 0

registration_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-103)"
jit_write_worker_state "$registration_state" allocated; jit_plan_worker_identity "$registration_state" 103
JIT_TEST_CASE=registration-lost-response
if (jit_generate_config "$(jq -r .user "$registration_state")" "$registration_state" >/dev/null 2>&1); then fail "lost JIT registration response was accepted"; fi
JIT_TEST_CASE=valid
jq -e '.status=="registration-requested" and .registration.status=="requested" and .runner_id==null' "$registration_state" >/dev/null || fail "ambiguous registration intent was not recoverable after process failure"
assert_eq "$(jq 'length' "$JIT_TEST_REMOTE_RUNNERS_FILE")" 1
jit_cleanup_stale_worker_states "$(dirname "$registration_state")"
assert_eq "$(jq -r .status "$registration_state")" cleaned
assert_eq "$(jq 'length' "$JIT_TEST_REMOTE_RUNNERS_FILE")" 0

registration_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-104)"
jit_write_worker_state "$registration_state" allocated; jit_plan_worker_identity "$registration_state" 104
JIT_TEST_CASE=registration-lost-response
if (jit_generate_config "$(jq -r .user "$registration_state")" "$registration_state" >/dev/null 2>&1); then fail "lost JIT registration response was accepted"; fi
JIT_TEST_CASE=valid
jq '.[0].labels=[{name:"wrong-admission"}]' "$JIT_TEST_REMOTE_RUNNERS_FILE" >"${JIT_TEST_REMOTE_RUNNERS_FILE}.tmp"; mv "${JIT_TEST_REMOTE_RUNNERS_FILE}.tmp" "$JIT_TEST_REMOTE_RUNNERS_FILE"
if jit_cleanup_worker_state "$registration_state" >/dev/null 2>&1; then fail "mismatched orphan registration was deleted by name alone"; fi
assert_eq "$(jq -r .status "$registration_state")" cleanup-pending
printf '[]\n' >"$JIT_TEST_REMOTE_RUNNERS_FILE"; jit_cleanup_worker_state "$registration_state"

registration_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-105)"
jit_write_worker_state "$registration_state" allocated; jit_plan_worker_identity "$registration_state" 105
JIT_TEST_CASE=registration-lost-response
if (jit_generate_config "$(jq -r .user "$registration_state")" "$registration_state" >/dev/null 2>&1); then fail "lost JIT registration response was accepted"; fi
JIT_TEST_CASE=valid
jq '. + [.[0] | .id=9999]' "$JIT_TEST_REMOTE_RUNNERS_FILE" >"${JIT_TEST_REMOTE_RUNNERS_FILE}.tmp"; mv "${JIT_TEST_REMOTE_RUNNERS_FILE}.tmp" "$JIT_TEST_REMOTE_RUNNERS_FILE"
if jit_cleanup_worker_state "$registration_state" >/dev/null 2>&1; then fail "multiple ambiguous registrations were not rejected"; fi
printf '[]\n' >"$JIT_TEST_REMOTE_RUNNERS_FILE"; jit_cleanup_worker_state "$registration_state"

JIT_ADMISSION_ID="$saved_admission_id"
jit_load_admission "$JIT_ADMISSION_ID"

mkdir -p "$GHRCTL_BASE_ROOT/fixture/actions-runner-01"
printf '%s\n' 'actions.runner.fixture.service' >"$GHRCTL_BASE_ROOT/fixture/actions-runner-01/.service"
printf '%s\n' '{"agentName":"fixture"}' >"$GHRCTL_BASE_ROOT/fixture/actions-runner-01/.runner"
mkdir -p "$GHRCTL_BASE_ROOT/fixture/actions-runner-02"
printf '%s\n' 'actions.runner.fixture-02.service' >"$GHRCTL_BASE_ROOT/fixture/actions-runner-02/.service"
printf '%s\n' '{"agentName":"fixture-02"}' >"$GHRCTL_BASE_ROOT/fixture/actions-runner-02/.runner"
ASSUME_YES=1
migration_fault_points=(
  migration-after-journal
  migration-actions.runner.fixture.service-after-drain-before-checkpoint migration-actions.runner.fixture.service-after-stop-before-checkpoint migration-actions.runner.fixture.service-after-disable-before-checkpoint
  migration-actions.runner.fixture-02.service-after-drain-before-checkpoint migration-actions.runner.fixture-02.service-after-stop-before-checkpoint migration-actions.runner.fixture-02.service-after-disable-before-checkpoint
  migration-before-remote-verification migration-after-remote-call-before-checkpoint migration-after-remote-verification
)
migration_record="$(jit_migration_file mazaya-test)"
for fault_point in "${migration_fault_points[@]}"; do
  rm -f "$migration_record"
  : >"$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.active"
  : >"$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.enabled"
  : >"$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture-02.service.active"
  : >"$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture-02.service.enabled"
  GHRCTL_JIT_FAULT_POINT="$fault_point"
  if (jit_quarantine_persistent mazaya-test --timeout 1 --auth test >/dev/null 2>&1); then fail "migration fault injection did not fire: $fault_point"; fi
  unset GHRCTL_JIT_FAULT_POINT
  jq -e '.status=="preparing" and .automatic_resume==false and (.persistent_services|length)==2' "$migration_record" >/dev/null \
    || fail "write-ahead migration journal was not recoverable: $fault_point"
  jit_quarantine_persistent mazaya-test --timeout 1 --auth test >/dev/null
  assert_eq "$(jq -r .status "$migration_record")" "quarantined"
done
assert_eq "$(jq -r .status "$(jit_migration_file mazaya-test)")" "quarantined"
[[ ! -e "$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.active" && ! -e "$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.enabled" ]] || fail "persistent service was not quarantined"
jit_assert_persistent_quarantined

JIT_TEST_CASE=forbidden-runner
if (jit_assert_persistent_quarantined >/dev/null 2>&1); then fail "online broad-label runner did not block JIT"; fi
JIT_TEST_CASE=forbidden-page-2
if (jit_assert_persistent_quarantined >/dev/null 2>&1); then fail "page-two broad-label runner did not block JIT"; fi
JIT_TEST_CASE=runner-page-2
rm -f "$TMP/jit-delete-called"
jit_deregister_runner 7001
[[ -e "$TMP/jit-delete-called" ]] || fail "page-two JIT runner was not deregistered"
JIT_TEST_CASE=valid

DRY_RUN=1
launch_plan="$(jit_launch_admission "$JIT_ADMISSION_ID" --slots 2 --auth test)"
jq -e '.action=="launch-jit" and .slots==2 and .jit_config_generated==false and .workers_created==false' >/dev/null <<<"$launch_plan" || fail "JIT launch dry-run JSON is invalid"
DRY_RUN=0
JIT_TEST_CONTROLLER=1
jit_launch_admission "$JIT_ADMISSION_ID" --slots 2 --auth test >/dev/null
assert_eq "$(jq -r .status "$JIT_ADMISSION_FILE")" "completed"
jq -e --arg version "$JIT_PINNED_RUNNER_VERSION" --arg arch "$(arch_name)" --arg digest "sha256:$(jit_pinned_runner_digest "$(arch_name)")" '
  .runtime_selection.helper and .runtime_selection.manifest and (.runtime_selection.helper_sha256|test("^[0-9a-f]{64}$")) and
  .runtime_selection.controller_revision and (.runtime_selection.controller_digest|test("^[0-9a-f]{64}$")) and
  .runtime_selection.runner_version==$version and .runtime_selection.runner_arch==$arch and
  .runtime_selection.runner_asset==("actions-runner-linux-"+$arch+"-"+$version+".tar.gz") and .runtime_selection.runner_asset_digest==$digest
' "$JIT_ADMISSION_FILE" >/dev/null || fail "controller did not persist immutable controller and runner selection before spawning workers"
first_runtime_helper="$(jq -r '.runtime_selection.helper' "$JIT_ADMISSION_FILE")"
jq -s -e --arg helper "$first_runtime_helper" --arg version "$JIT_PINNED_RUNNER_VERSION" --arg digest "sha256:$(jit_pinned_runner_digest "$(arch_name)")" \
  '[.[] | select(.sequence>=8 and .worker_id!="worker-096") | .runtime_helper == $helper and .runner_version==$version and .runner_asset_digest==$digest] | all' \
  "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"/worker-*.json >/dev/null || fail "worker journal did not inherit immutable controller and runner provenance"
jq -e '.runtime_selection.controller_manifest.files|length==8 and all(.[]; (.path|startswith("libexec/")) and (.sha256|test("^[0-9a-f]{64}$")) )' "$JIT_ADMISSION_FILE" >/dev/null || fail "runtime provenance did not persist the deterministic libexec manifest"
provenance_root="$TMP/runtime-provenance"
mkdir -p "$provenance_root/libexec"
while IFS= read -r provenance_file; do cp "$ROOT/libexec/$provenance_file" "$provenance_root/libexec/$provenance_file"; done < <(jit_runtime_critical_libexec_files)
GHRCTL_JIT_PROVENANCE_ROOT="$provenance_root"
jit_load_admission "$JIT_ADMISSION_ID"
jit_validate_admission_runtime_selection || fail "unchanged runtime provenance failed validation"
admission_provenance_backup="$TMP/admission-provenance.json"
cp "$JIT_ADMISSION_FILE" "$admission_provenance_backup"
for runner_field in runner_version runner_asset_digest; do
  jq --arg field "$runner_field" '.runtime_selection[$field]="drift"' "$admission_provenance_backup" | jit_atomic_write "$JIT_ADMISSION_FILE"
  jit_load_admission "$JIT_ADMISSION_ID"
  if jit_validate_admission_runtime_selection >/dev/null 2>&1; then fail "admission runner provenance drift was accepted: $runner_field"; fi
  cp "$admission_provenance_backup" "$JIT_ADMISSION_FILE"
done
jit_load_admission "$JIT_ADMISSION_ID"
worker_provenance_sample="$(find "$(jit_worker_state_dir "$JIT_ADMISSION_ID")" -type f -name 'worker-*.json' | sort | tail -n1)"
worker_provenance_backup="$TMP/worker-provenance.json"
cp "$worker_provenance_sample" "$worker_provenance_backup"
jq '.runner_asset_digest="sha256:0000000000000000000000000000000000000000000000000000000000000000"' "$worker_provenance_backup" | jit_atomic_write "$worker_provenance_sample"
if jit_validate_worker_journal "$worker_provenance_sample" "$JIT_ADMISSION_ID"; then fail "worker runner digest drift was accepted"; fi
cp "$worker_provenance_backup" "$worker_provenance_sample"
while IFS= read -r provenance_file; do
  printf '# mutation\n' >>"$provenance_root/libexec/$provenance_file"
  if jit_validate_admission_runtime_selection >/dev/null 2>&1; then fail "mutated runtime-critical libexec helper remained trusted: $provenance_file"; fi
  cp "$ROOT/libexec/$provenance_file" "$provenance_root/libexec/$provenance_file"
done < <(jit_runtime_critical_libexec_files)
unset GHRCTL_JIT_PROVENANCE_ROOT
jit_load_admission "$JIT_ADMISSION_ID"
first_launch_count="$(find "$(jit_worker_state_dir "$JIT_ADMISSION_ID")" -maxdepth 1 -type f -name 'worker-*.json' | wc -l | tr -d ' ')"
(( first_launch_count >= 10 && first_launch_count <= 20 )) || fail "controller replacement count escaped the configured bound"
(( $(jq -s '[.[] | select((.sequence // 0) >= 8 and .status=="finished")] | length' "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"/worker-*.json) >= 3 )) || fail "controller did not finish all simulated jobs"
jit_set_admission_status running
jit_set_admission_status cancelled "simulated host restart"
DRY_RUN=1
resume_plan="$(jit_resume_admission "$JIT_ADMISSION_ID" --slots 2 --auth test)"
jq -e '.action=="resume-jit" and .replacements_launched==false' >/dev/null <<<"$resume_plan" || fail "JIT resume dry-run JSON is invalid"
DRY_RUN=0
JIT_TEST_CONTROLLER_MIN_SEQUENCE="$(jit_next_worker_sequence "$(jit_worker_state_dir "$JIT_ADMISSION_ID")")"
resume_before_count="$first_launch_count"
jit_resume_admission "$JIT_ADMISSION_ID" --slots 2 --auth test >/dev/null
assert_eq "$(jq -r .status "$JIT_ADMISSION_FILE")" "completed"
resume_after_count="$(find "$(jit_worker_state_dir "$JIT_ADMISSION_ID")" -maxdepth 1 -type f -name 'worker-*.json' | wc -l | tr -d ' ')"
(( resume_after_count >= resume_before_count + 3 && resume_after_count <= resume_before_count + 13 )) || fail "resume replacement count escaped the configured bound"
(( $(jq -s --argjson minimum "$JIT_TEST_CONTROLLER_MIN_SEQUENCE" '[.[] | select((.sequence // 0) >= $minimum and .status=="finished")] | length' "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"/worker-*.json) >= 3 )) || fail "resumed controller did not finish all simulated jobs"
JIT_TEST_CONTROLLER=0
unset JIT_TEST_CONTROLLER_MIN_SEQUENCE

JSON_OUTPUT=1
status_json="$(jit_status_admission "$JIT_ADMISSION_ID")"
jq -e '.admission.id and (.workers|length)>=3' >/dev/null <<<"$status_json" || fail "JIT status JSON is invalid"
JSON_OUTPUT=0

if command -v zstd >/dev/null 2>&1; then
  jit_backup="$TMP/jit-secret-free-backup.tar.zst"
  jit_backup_validation="$TMP/jit-secret-free-backup-validation"
  mkdir -p "$jit_backup_validation/extract"
  create_backup_archive project fixture "$jit_backup" >/dev/null
  validate_backup_archive "$jit_backup" "$jit_backup_validation" >/dev/null
  if grep -R -F "$JIT_TEST_JIT_SECRET" "$jit_backup_validation/extract" >/dev/null 2>&1 || \
     grep -R -F "$JIT_TEST_SECRET_BASE64" "$jit_backup_validation/extract" >/dev/null 2>&1 || \
     grep -R -F "$JIT_TEST_CREDENTIALS_BLOB" "$jit_backup_validation/extract" >/dev/null 2>&1 || \
     grep -R -F "$JIT_TEST_RSA_BLOB" "$jit_backup_validation/extract" >/dev/null 2>&1 || \
     grep -R -F "$JIT_TEST_ENCODED_CONFIG" "$jit_backup_validation/extract" >/dev/null 2>&1; then
    fail "JIT credential material leaked into a managed backup"
  fi
fi

jit_rollback_project mazaya-test --auth test >/dev/null 2>&1
assert_eq "$(jq -r .status "$(jit_migration_file mazaya-test)")" "rolled-back"
[[ ! -e "$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.active" ]] || fail "rollback silently resumed a persistent runner"

unset JIT_TEST_CASE JIT_TEST_CONTROLLER verification dry_run_json launch_plan resume_plan valid_jobs invalid_jobs paginated_jobs state_dir state_one state_two state_three state_four state_five state_six state_seven user_two user_three root_two root_three socket_two socket_three diagnostics status_json failure_seed saved_admission_id worker_fault_points migration_fault_points migration_record fault_sequence fault_point fault_state fault_root
