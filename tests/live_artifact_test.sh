#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf --one-file-system "$TEST_ROOT"' EXIT
export GHRCTL_STATE_DIR="$TEST_ROOT/etc/ghrctl"
export GHRCTL_DATA_DIR="$TEST_ROOT/var/lib/ghrctl"
export GHRCTL_LOG_DIR="$TEST_ROOT/var/log/ghrctl"
export GHRCTL_LOCK_FILE="$TEST_ROOT/var/lock/ghrctl.lock"
export GHRCTL_BASE_ROOT="$TEST_ROOT/srv/github-runners"
export GHRCTL_JIT_BOUNDARY_ROOT="$TEST_ROOT/srv/jit-boundaries"
# shellcheck source=../ghrctl
source "$ROOT/ghrctl"

JIT_AUTH_MODE=live-test
JIT_API_TOKEN="$GITHUB_TOKEN"
JIT_API_TOKEN_EXPIRES_EPOCH=0
unset GITHUB_TOKEN

run="$(jit_api GET "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}")"
jobs="$(jit_api_collection "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}/jobs" jobs)"
job_count="$(jq --arg name "$GITHUB_JOB" '[.jobs[] | select(.name==$name)] | length' <<<"$jobs")"
[[ "$job_count" == 1 ]] || die "Live evidence test could not resolve its exact GitHub job."
job="$(jq -c --arg name "$GITHUB_JOB" '.jobs[] | select(.name==$name)' <<<"$jobs")"
job_id="$(jq -r .id <<<"$job")"
run_sha="$(jq -r .head_sha <<<"$run")"
run_branch="$(jq -r .head_branch <<<"$run")"
workflow_id="$(jq -r .workflow_id <<<"$run")"
workflow_path="$(jq -r .path <<<"$run")"
pr_number="$(jq -r '.pull_request.number // 0' "$GITHUB_EVENT_PATH")"
artifact_prefix=ghrctl-live-admission-
artifact_name="${artifact_prefix}${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${job_id}"

case "$MODE" in
  prepare)
    : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
    evidence_dir="$(mktemp -d "${RUNNER_TEMP}/ghrctl-live-evidence.XXXXXX")"
    jq -n --arg repository "$GITHUB_REPOSITORY" --arg workflow_path "$workflow_path" --arg workflow_name "$GITHUB_WORKFLOW" --arg job_name "$GITHUB_JOB" \
      --argjson workflow_id "$workflow_id" --argjson job_id "$job_id" --argjson run_id "$GITHUB_RUN_ID" --argjson run_attempt "$GITHUB_RUN_ATTEMPT" --argjson pr_number "$pr_number" \
      --arg sha "$run_sha" --arg label "ghrctl-live-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" --arg generated_at "$(utc_now)" \
      '{schema_version:1,repository:$repository,workflow_path:$workflow_path,workflow_name:$workflow_name,workflow_id:$workflow_id,run_id:$run_id,run_attempt:$run_attempt,admission_job_id:$job_id,admission_job_name:$job_name,pr_number:$pr_number,base_sha:$sha,head_sha:$sha,merge_sha:$sha,tree_sha:$sha,label:$label,generated_at:$generated_at}' \
      >"${evidence_dir}/admission.json"
    {
      printf 'artifact_name=%s\n' "$artifact_name"
      printf 'evidence_path=%s\n' "${evidence_dir}/admission.json"
      printf 'job_id=%s\n' "$job_id"
      printf 'run_sha=%s\n' "$run_sha"
      printf 'run_branch=%s\n' "$run_branch"
      printf 'workflow_id=%s\n' "$workflow_id"
      printf 'workflow_path=%s\n' "$workflow_path"
      printf 'pr_number=%s\n' "$pr_number"
    } >>"$GITHUB_OUTPUT"
    ;;
  verify)
    : "${EXPECTED_ARTIFACT_NAME:?EXPECTED_ARTIFACT_NAME is required}"
    init_dirs
    save_project live-evidence "https://github.com/${GITHUB_REPOSITORY}" "$GITHUB_REPOSITORY" root "$GHRCTL_BASE_ROOT/live-evidence" live-evidence-ci false
    mkdir -p "$GHRCTL_BASE_ROOT/live-evidence"
    policy_file="$TEST_ROOT/live-policy.json"
    jq -n --arg repository "$GITHUB_REPOSITORY" --arg workflow_path "$workflow_path" --arg workflow_name "$GITHUB_WORKFLOW" --arg job_name "$GITHUB_JOB" --arg branch "$run_branch" --arg artifact_prefix "$artifact_prefix" \
      '{schema_version:1,project:"live-evidence",repository:$repository,workflow_path:$workflow_path,workflow_name:$workflow_name,admission_job_name:$job_name,evidence_artifact_prefix:$artifact_prefix,trusted_branch:$branch,allowed_actors:["github-actions"],label_prefix:"ghrctl-live-",runner_group_id:1,max_slots:1,max_replacements:0,freshness_seconds:3600,poll_seconds:1,max_runtime_seconds:60,rootless_docker:true,forbidden_online_labels:["self-hosted"],persistent_project:"live-evidence"}' \
      >"$policy_file"
    jit_init_dirs
    jq . "$policy_file" | jit_atomic_write "$(jit_policy_file live-evidence)"
    jit_load_policy live-evidence
    evidence=""
    evidence_error="$TEST_ROOT/evidence-error.log"
    for retry in {1..10}; do
      if evidence="$(jit_fetch_admission_evidence "$run" "$job" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$pr_number" "$run_sha" "$run_sha" "$run_sha" "$run_sha" "ghrctl-live-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" 2>"$evidence_error")"; then
        break
      fi
      (( retry < 10 )) && sleep 2
    done
    if [[ -z "$evidence" ]]; then
      sed 's/^/artifact verification: /' "$evidence_error" >&2
      die "Live admission artifact did not become verifiable within the bounded retry window."
    fi
    [[ "$(jq -r .artifact_name <<<"$evidence")" == "$EXPECTED_ARTIFACT_NAME" ]] || die "Live artifact name mismatch."
    printf 'Live GitHub artifact admission transport passed for artifact %s.\n' "$EXPECTED_ARTIFACT_NAME"
    ;;
  *)
    printf 'Usage: %s prepare|verify\n' "$0" >&2
    exit 2
    ;;
esac
