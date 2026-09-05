# shellcheck shell=bash

export GHRCTL_TEST_MODE=1
export GHRCTL_JIT_HOST_BACKEND=fake
export GHRCTL_JIT_FAKE_RUNNER_ROOT="$ROOT/tests/fixtures/fake-actions-runner"
export GHRCTL_JIT_FAKE_SERVICES_DIR="$TMP/fake-services"
mkdir -p "$GHRCTL_JIT_FAKE_SERVICES_DIR"

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

TEST_POLICY="$TMP/jit-policy.json"
jq -e '.project=="mazaya-backend" and .persistent_project=="mazaya-backend" and (.forbidden_online_labels | index("mazaya-backend-ci"))!=null' "$ROOT/examples/jit-policy.mazaya.json" >/dev/null \
  || fail "Mazaya policy does not match the managed project and repository label"
jq '.project="mazaya-test" | .repository="owner/repo" | .persistent_project="fixture" | .poll_seconds=1 | .max_replacements=10' "$ROOT/examples/jit-policy.mazaya.json" >"$TEST_POLICY"
jit_init_dirs
jit_validate_policy_json "$TEST_POLICY"
jit_validate_policy_project_binding "$TEST_POLICY"
jq . "$TEST_POLICY" | jit_atomic_write "$(jit_policy_file mazaya-test)"
jit_load_policy mazaya-test

JIT_TEST_EVIDENCE_DIR="$TMP/evidence"
JIT_TEST_EVIDENCE_ARCHIVE="$TMP/evidence.zip"
JIT_TEST_BAD_EVIDENCE_ARCHIVE="$TMP/evidence-bad.zip"
JIT_TEST_UNSAFE_EVIDENCE_DIR="$TMP/evidence-unsafe"
JIT_TEST_UNSAFE_EVIDENCE_ARCHIVE="$TMP/evidence-unsafe.zip"
JIT_TEST_OVERSIZED_EVIDENCE_DIR="$TMP/evidence-oversized"
JIT_TEST_OVERSIZED_EVIDENCE_ARCHIVE="$TMP/evidence-oversized.zip"
mkdir -p "$JIT_TEST_EVIDENCE_DIR"
jq -n --arg repository "$JIT_POLICY_REPOSITORY" --arg workflow_path "$JIT_POLICY_WORKFLOW_PATH" --arg workflow_name "$JIT_POLICY_WORKFLOW_NAME" --arg job_name "$JIT_POLICY_ADMISSION_JOB" \
  --argjson workflow_id 7654 --argjson job_id 9001 --argjson run_id "$JIT_TEST_RUN_ID" --argjson run_attempt "$JIT_TEST_ATTEMPT" --argjson pr_number "$JIT_TEST_PR" \
  --arg base "$JIT_TEST_BASE" --arg head "$JIT_TEST_HEAD" --arg merge "$JIT_TEST_MERGE" --arg tree "$JIT_TEST_TREE" --arg label "$JIT_TEST_LABEL" --arg generated_at "$JIT_TEST_CREATED" \
  '{schema_version:1,repository:$repository,workflow_path:$workflow_path,workflow_name:$workflow_name,workflow_id:$workflow_id,run_id:$run_id,run_attempt:$run_attempt,admission_job_id:$job_id,admission_job_name:$job_name,pr_number:$pr_number,base_sha:$base,head_sha:$head,merge_sha:$merge,tree_sha:$tree,label:$label,generated_at:$generated_at}' \
  >"$JIT_TEST_EVIDENCE_DIR/admission.json"
(cd "$JIT_TEST_EVIDENCE_DIR" && python3 -m zipfile -c "$JIT_TEST_EVIDENCE_ARCHIVE" admission.json)
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
JIT_TEST_UNSAFE_EVIDENCE_DIGEST="sha256:$(sha256sum "$JIT_TEST_UNSAFE_EVIDENCE_ARCHIVE" | awk '{print $1}')"
JIT_TEST_OVERSIZED_EVIDENCE_DIGEST="sha256:$(sha256sum "$JIT_TEST_OVERSIZED_EVIDENCE_ARCHIVE" | awk '{print $1}')"

jit_download_api() {
  local _endpoint="$1" destination="$2"
  case "$JIT_TEST_CASE" in
    evidence-mismatch) cp "$JIT_TEST_BAD_EVIDENCE_ARCHIVE" "$destination" ;;
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
  local artifact_name artifact_digest artifact_archive artifact_size artifact_json
  created_at="$JIT_TEST_CREATED"
  repository="$JIT_POLICY_REPOSITORY"; event=workflow_dispatch; attempt="$JIT_TEST_ATTEMPT"; head_branch=main; head_sha="$JIT_TEST_BASE"
  path="$JIT_POLICY_WORKFLOW_PATH"; actor=mufarri7; triggering_actor=mufarri7; job_status=completed; job_conclusion=success
  artifact_name="${JIT_POLICY_EVIDENCE_ARTIFACT_PREFIX}${JIT_TEST_RUN_ID}-${JIT_TEST_ATTEMPT}-9001"
  artifact_archive="$JIT_TEST_EVIDENCE_ARCHIVE"; artifact_digest="$JIT_TEST_EVIDENCE_DIGEST"
  if [[ "$JIT_TEST_CASE" == evidence-mismatch ]]; then artifact_archive="$JIT_TEST_BAD_EVIDENCE_ARCHIVE"; artifact_digest="$JIT_TEST_BAD_EVIDENCE_DIGEST"; fi
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
      controller_finished="$(jq -s --argjson minimum "$controller_min" '[.[] | select((.sequence // 0) >= $minimum and .status=="finished")] | length' "$worker_state_dir"/worker-*.json)"
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
      if [[ "$JIT_TEST_CASE" == default-labels ]]; then
        jq -cn --arg label "$JIT_TEST_LABEL" '{runner:{id:7001,labels:[{name:$label,type:"custom"},{name:"self-hosted",type:"read-only"}]},encoded_jit_config:"jit-secret-material-123456"}'
      else
        jq -cn --arg label "$JIT_TEST_LABEL" '{runner:{id:7001,labels:[{name:$label,type:"custom"}]},encoded_jit_config:"jit-secret-material-123456"}'
      fi
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
      elif [[ "$JIT_TEST_CASE" == forbidden-runner || -e "$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.active" ]]; then
        jq -cn '{total_count:1,runners:[{id:41,name:"persistent",status:"online",busy:false,ephemeral:false,labels:[{name:"self-hosted"},{name:"Linux"},{name:"X64"},{name:"fixture-ci"},{name:"shared-ci"}]}]}'
      else
        jq -cn --arg label "$JIT_TEST_LABEL" '{total_count:1,runners:[{id:7001,name:"jit",status:"offline",busy:false,ephemeral:true,labels:[{name:$label}]}]}'
      fi
      ;;
    DELETE:repos/*/actions/runners/7001)
      : >"$TMP/jit-delete-called"
      printf '{}\n'
      ;;
    *) fail "unexpected fake GitHub API call: $method $endpoint body=$body" ;;
  esac
}

JIT_TEST_CASE=valid
verification="$(jit_verify_admission "$JIT_TEST_RUN_ID" "$JIT_TEST_ATTEMPT" "$JIT_TEST_PR" "$JIT_TEST_BASE" "$JIT_TEST_HEAD" "$JIT_TEST_MERGE" "$JIT_TEST_TREE" "$JIT_TEST_LABEL")"
jq -e '.workflow_id==7654 and .admission_job_id==9001 and .evidence.artifact_id==6001' >/dev/null <<<"$verification" || fail "valid artifact-backed admission verification failed"

for JIT_TEST_CASE in admission-page-2 evidence-page-2; do
  jit_verify_admission "$JIT_TEST_RUN_ID" "$JIT_TEST_ATTEMPT" "$JIT_TEST_PR" "$JIT_TEST_BASE" "$JIT_TEST_HEAD" "$JIT_TEST_MERGE" "$JIT_TEST_TREE" "$JIT_TEST_LABEL" >/dev/null \
    || fail "paginated trusted admission evidence failed: $JIT_TEST_CASE"
done

for JIT_TEST_CASE in wrong-repository wrong-event wrong-attempt wrong-workflow wrong-actor skipped-admission failed-admission stale evidence-mismatch unsafe-evidence oversized-evidence artifact-digest-mismatch missing-evidence; do
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

jit_prepare_runner_cache
state_dir="$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
mkdir -p "$state_dir"
state_one="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-001)"
jit_spawn_worker 1
wait "$(jq -r .controller_pid "$state_one")"
assert_eq "$(jq -r .status "$state_one")" "finished"
[[ ! -e "$(jq -r .root "$state_one")" ]] || fail "successful worker boundary survived cleanup"
diagnostics="${JIT_DIAGNOSTICS_DIR}/${JIT_ADMISSION_ID}/worker-001"
[[ -r "$diagnostics/runner.log" ]] || fail "external runner diagnostics were not retained"
if grep -R -F 'jit-secret-material-123456' "$JIT_DATA_DIR" "$JIT_DIAGNOSTICS_DIR" >/dev/null 2>&1; then fail "JIT secret leaked into state or diagnostics"; fi
if grep -q '^ACTIONS_RUNNER_INPUT_JITCONFIG=' "$diagnostics/job-environment.log"; then fail "JIT configuration reached the job environment"; fi

state_two="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-002)"
state_three="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-003)"
jit_write_worker_state "$state_two" allocated; jit_plan_worker_identity "$state_two" 2; jit_create_worker_boundary "$state_two"
user_two="$JIT_WORKER_USER"; root_two="$JIT_WORKER_ROOT"; socket_two="$JIT_WORKER_DOCKER_SOCKET"
jit_write_worker_state "$state_three" allocated; jit_plan_worker_identity "$state_three" 3; jit_create_worker_boundary "$state_three"
user_three="$JIT_WORKER_USER"; root_three="$JIT_WORKER_ROOT"; socket_three="$JIT_WORKER_DOCKER_SOCKET"
[[ "$user_two" != "$user_three" && "$root_two" != "$root_three" && "$socket_two" != "$socket_three" ]] || fail "simultaneous slots share an identity, filesystem, or Docker socket"
jit_cleanup_worker_state "$state_two"; jit_cleanup_worker_state "$state_three"
[[ ! -e "$root_two" && ! -e "$root_three" ]] || fail "cancel/restart cleanup left mutable worker state"

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

state_seven="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-007)"
jit_write_worker_state "$state_seven" allocated
jit_plan_worker_identity "$state_seven" 7
jit_create_worker_boundary "$state_seven"
jit_write_worker_state "$state_seven" running "simulated host restart"
jit_cleanup_stale_worker_states "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
assert_eq "$(jq -r .status "$state_seven")" "cleaned"
[[ ! -e "$(jq -r .root "$state_seven")" ]] || fail "host-restart cleanup left mutable worker state"

saved_admission_id="$JIT_ADMISSION_ID"
JIT_ADMISSION_ID=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
mkdir -p "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
worker_fault_points=(
  worker-after-boundary-mutation worker-after-group-mutation worker-after-user-mutation worker-after-subids-mutation
  worker-after-runner-seed-mutation worker-after-linger-mutation worker-after-user-manager-mutation worker-after-docker-mutation
)
fault_sequence=1
for fault_point in "${worker_fault_points[@]}"; do
  fault_state="$(jit_worker_state_file "$JIT_ADMISSION_ID" "worker-$(printf '%03d' "$fault_sequence")")"
  jit_write_worker_state "$fault_state" allocated
  jit_plan_worker_identity "$fault_state" "$fault_sequence"
  GHRCTL_JIT_FAULT_POINT="$fault_point"
  if (jit_create_worker_boundary "$fault_state" >/dev/null 2>&1); then fail "worker fault injection did not fire: $fault_point"; fi
  unset GHRCTL_JIT_FAULT_POINT
  jq -e '.status=="creating" and .creation_stage!=null and .user!=null and .uid!=null and .group!=null and .root!=null and .home!=null and .docker_socket!=null' "$fault_state" >/dev/null \
    || fail "partial worker identity was not journaled before fault: $fault_point"
  fault_root="$(jq -r .root "$fault_state")"
  jit_cleanup_worker_state "$fault_state"
  assert_eq "$(jq -r .status "$fault_state")" "cleaned"
  [[ ! -e "$fault_root" ]] || fail "partial worker boundary survived cleanup: $fault_point"
  fault_sequence=$((fault_sequence + 1))
done
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
assert_eq "$(find "$(jit_worker_state_dir "$JIT_ADMISSION_ID")" -maxdepth 1 -type f -name 'worker-*.json' | wc -l | tr -d ' ')" "10"
assert_eq "$(jq -s '[.[] | select((.sequence // 0) >= 8 and .status=="finished")] | length' "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"/worker-*.json)" "3"
jit_set_admission_status running
jit_set_admission_status cancelled "simulated host restart"
DRY_RUN=1
resume_plan="$(jit_resume_admission "$JIT_ADMISSION_ID" --slots 2 --auth test)"
jq -e '.action=="resume-jit" and .replacements_launched==false' >/dev/null <<<"$resume_plan" || fail "JIT resume dry-run JSON is invalid"
DRY_RUN=0
JIT_TEST_CONTROLLER_MIN_SEQUENCE=11
jit_resume_admission "$JIT_ADMISSION_ID" --slots 2 --auth test >/dev/null
assert_eq "$(jq -r .status "$JIT_ADMISSION_FILE")" "completed"
assert_eq "$(find "$(jit_worker_state_dir "$JIT_ADMISSION_ID")" -maxdepth 1 -type f -name 'worker-*.json' | wc -l | tr -d ' ')" "13"
assert_eq "$(jq -s '[.[] | select((.sequence // 0) >= 11 and .status=="finished")] | length' "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"/worker-*.json)" "3"
JIT_TEST_CONTROLLER=0
unset JIT_TEST_CONTROLLER_MIN_SEQUENCE

JSON_OUTPUT=1
status_json="$(jit_status_admission "$JIT_ADMISSION_ID")"
jq -e '.admission.id and (.workers|length)>=3' >/dev/null <<<"$status_json" || fail "JIT status JSON is invalid"
JSON_OUTPUT=0

jit_rollback_project mazaya-test --auth test >/dev/null 2>&1
assert_eq "$(jq -r .status "$(jit_migration_file mazaya-test)")" "rolled-back"
[[ ! -e "$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.active" ]] || fail "rollback silently resumed a persistent runner"

unset JIT_TEST_CASE JIT_TEST_CONTROLLER verification dry_run_json launch_plan resume_plan valid_jobs invalid_jobs paginated_jobs state_dir state_one state_two state_three state_four state_five state_six state_seven user_two user_three root_two root_three socket_two socket_three diagnostics status_json failure_seed saved_admission_id worker_fault_points migration_fault_points migration_record fault_sequence fault_point fault_state fault_root
