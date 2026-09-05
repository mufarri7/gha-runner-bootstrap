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

TEST_POLICY="$TMP/jit-policy.json"
jq '.project="mazaya-test" | .persistent_project="fixture" | .poll_seconds=1 | .max_replacements=10' "$ROOT/examples/jit-policy.mazaya.json" >"$TEST_POLICY"
jit_init_dirs
jit_validate_policy_json "$TEST_POLICY"
jq . "$TEST_POLICY" | jit_atomic_write "$(jit_policy_file mazaya-test)"
jit_load_policy mazaya-test

jit_configure_auth() {
  JIT_AUTH_MODE=test
  JIT_API_TOKEN=test-token
  JIT_API_TOKEN_EXPIRES_EPOCH=0
}

jit_api() {
  local method="$1" endpoint="$2" body="${3:-}" created_at repository event attempt head_branch head_sha path actor triggering_actor job_status job_conclusion summary controller_finished=0 controller_min worker_state_dir
  created_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  repository="$JIT_POLICY_REPOSITORY"; event=workflow_dispatch; attempt="$JIT_TEST_ATTEMPT"; head_branch=main; head_sha="$JIT_TEST_BASE"
  path="$JIT_POLICY_WORKFLOW_PATH"; actor=mufarri7; triggering_actor=mufarri7; job_status=completed; job_conclusion=success
  summary="### Trusted self-hosted admission
- Base: $JIT_TEST_BASE
- Head: $JIT_TEST_HEAD
- Merge: $JIT_TEST_MERGE
- Tree: $JIT_TEST_TREE
- Per-run JIT label: $JIT_TEST_LABEL"
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
    summary-mismatch) summary="${summary/$JIT_TEST_HEAD/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
  esac
  case "$method:$endpoint" in
    GET:repos/*/actions/runs/${JIT_TEST_RUN_ID}/attempts/${JIT_TEST_ATTEMPT})
      jq -cn --arg repository "$repository" --arg event "$event" --arg attempt "$attempt" --arg branch "$head_branch" --arg sha "$head_sha" --arg path "$path" --arg actor "$actor" --arg triggering_actor "$triggering_actor" --arg created_at "$created_at" \
        '{repository:{full_name:$repository},event:$event,run_attempt:($attempt|tonumber),head_branch:$branch,head_sha:$sha,path:$path,actor:{login:$actor},triggering_actor:{login:$triggering_actor},workflow_id:7654,created_at:$created_at,html_url:"https://github.com/example/actions/runs/987654321"}'
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
    GET:repos/*/actions/runs/${JIT_TEST_RUN_ID}/attempts/${JIT_TEST_ATTEMPT}/jobs?per_page=100)
      if [[ "${JIT_TEST_CONTROLLER:-0}" == 1 ]]; then
        jq -cn --arg name "$JIT_POLICY_ADMISSION_JOB" --arg status "$job_status" --arg conclusion "$job_conclusion" --arg sha "$JIT_TEST_BASE" --arg label "$JIT_TEST_LABEL" --argjson done "$controller_finished" '
          def target($id;$name;$complete): {id:$id,name:$name,status:(if $complete then "completed" else "queued" end),conclusion:(if $complete then "success" else null end),head_sha:$sha,labels:[$label],runner_id:null,runner_name:null};
          {jobs:[{id:9001,name:$name,status:$status,conclusion:$conclusion,head_sha:$sha,labels:["ubuntu-latest"],check_run_url:"https://api.github.com/repos/mufarri7/mazaya_backend/check-runs/8001"},target(9101;"data-one";$done>=1),target(9102;"data-two";$done>=2),target(9103;"data-three";$done>=3)]}'
      else
        jq -cn --arg name "$JIT_POLICY_ADMISSION_JOB" --arg status "$job_status" --arg conclusion "$job_conclusion" --arg sha "$JIT_TEST_BASE" '{jobs:[{id:9001,name:$name,status:$status,conclusion:$conclusion,head_sha:$sha,check_run_url:"https://api.github.com/repos/mufarri7/mazaya_backend/check-runs/8001"}]}'
      fi
      ;;
    GET:repos/*/check-runs/8001)
      jq -cn --arg summary "$summary" --arg sha "$JIT_TEST_BASE" '{id:8001,status:"completed",conclusion:"success",head_sha:$sha,output:{summary:$summary}}'
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
    GET:repos/*/actions/runners?per_page=100)
      if [[ "$JIT_TEST_CASE" == forbidden-runner || -e "$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.active" ]]; then
        jq -cn '{runners:[{id:41,name:"persistent",status:"online",busy:false,ephemeral:false,labels:[{name:"self-hosted"},{name:"linux"},{name:"x64"},{name:"shared-ci"}]}]}'
      else
        jq -cn '{runners:[{id:7001,name:"jit",status:"offline",busy:false,ephemeral:true,labels:[{name:"mazaya-admission-987654321-2"}]}]}'
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
jq -e '.workflow_id==7654 and .admission_job_id==9001 and .check_run_id==8001' >/dev/null <<<"$verification" || fail "valid admission verification failed"

for JIT_TEST_CASE in wrong-repository wrong-event wrong-attempt wrong-workflow wrong-actor skipped-admission failed-admission stale summary-mismatch; do
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
jit_write_worker_state "$state_two" allocated; jit_create_worker_boundary "$JIT_ADMISSION_ID" worker-002 2; jit_record_worker_boundary "$state_two" 2
user_two="$JIT_WORKER_USER"; root_two="$JIT_WORKER_ROOT"; socket_two="$JIT_WORKER_DOCKER_SOCKET"
jit_write_worker_state "$state_three" allocated; jit_create_worker_boundary "$JIT_ADMISSION_ID" worker-003 3; jit_record_worker_boundary "$state_three" 3
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
jit_create_worker_boundary "$JIT_ADMISSION_ID" worker-006 6
jit_record_worker_boundary "$state_six" 6
jit_write_worker_state "$state_six" cancelled "simulated controller cancellation" 7001
jit_cleanup_worker_state "$state_six"
assert_eq "$(jq -r .status "$state_six")" "cleaned"
[[ ! -e "$(jq -r .root "$state_six")" ]] || fail "cancelled worker boundary survived cleanup"

state_seven="$(jit_worker_state_file "$JIT_ADMISSION_ID" worker-007)"
jit_write_worker_state "$state_seven" allocated
jit_create_worker_boundary "$JIT_ADMISSION_ID" worker-007 7
jit_record_worker_boundary "$state_seven" 7
jit_write_worker_state "$state_seven" running "simulated host restart"
jit_cleanup_stale_worker_states "$(jit_worker_state_dir "$JIT_ADMISSION_ID")"
assert_eq "$(jq -r .status "$state_seven")" "cleaned"
[[ ! -e "$(jq -r .root "$state_seven")" ]] || fail "host-restart cleanup left mutable worker state"

mkdir -p "$GHRCTL_BASE_ROOT/fixture/actions-runner-01"
printf '%s\n' 'actions.runner.fixture.service' >"$GHRCTL_BASE_ROOT/fixture/actions-runner-01/.service"
printf '%s\n' '{"agentName":"fixture"}' >"$GHRCTL_BASE_ROOT/fixture/actions-runner-01/.runner"
: >"$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.active"
: >"$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.enabled"
ASSUME_YES=1
jit_quarantine_persistent mazaya-test --timeout 1 --auth test >/dev/null
assert_eq "$(jq -r .status "$(jit_migration_file mazaya-test)")" "quarantined"
[[ ! -e "$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.active" && ! -e "$GHRCTL_JIT_FAKE_SERVICES_DIR/actions.runner.fixture.service.enabled" ]] || fail "persistent service was not quarantined"
jit_assert_persistent_quarantined

JIT_TEST_CASE=forbidden-runner
if (jit_assert_persistent_quarantined >/dev/null 2>&1); then fail "online broad-label runner did not block JIT"; fi
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

unset JIT_TEST_CASE JIT_TEST_CONTROLLER verification dry_run_json launch_plan resume_plan valid_jobs invalid_jobs state_dir state_one state_two state_three state_four state_five state_six state_seven user_two user_three root_two root_three socket_two socket_three diagnostics status_json failure_seed
